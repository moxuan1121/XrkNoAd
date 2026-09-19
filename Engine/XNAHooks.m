#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>
#import "XNAPattern.h"

static os_log_t XNALogger(void) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logger = os_log_create("com.moxuan.xrknoad", "ads"); });
    return logger;
}

static NSMutableArray<NSString *> *XNAJournal(void) {
    static NSMutableArray *journal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ journal = [NSMutableArray new]; });
    return journal;
}

// 进程起点的 uptime，日志按它做相对时间戳。
static NSTimeInterval XNALaunchUptime = 0;

static void XNALog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    // 不记时间的话，事后根本分不清开屏那几百毫秒里谁先谁后。
    NSString *line = [NSString stringWithFormat:@"+%7.3f %@",
                      NSProcessInfo.processInfo.systemUptime - XNALaunchUptime, message];
    os_log(XNALogger(), "%{public}@", line);
    @synchronized(XNAJournal()) {
        [XNAJournal() addObject:line];
        // 留够篇幅：一次全量扫描就要写上千行钩子记录，再早的环形裁剪会把开屏那段时序挤掉。
        if (XNAJournal().count > 2500) [XNAJournal() removeObjectsInRange:NSMakeRange(0, XNAJournal().count - 2500)];
    }
}

static void XNAFlushLog(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"XrkNoAd.log"];
    NSArray<NSString *> *snapshot;
    @synchronized(XNAJournal()) {
        snapshot = [XNAJournal() copy];
    }
    [[snapshot componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static NSMutableArray<id> *XNAKeepAlive(void) {
    static NSMutableArray *kept;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kept = [NSMutableArray new]; });
    return kept;
}

static void XNAKeep(id object) {
    @synchronized(XNAKeepAlive()) {
        [XNAKeepAlive() addObject:object];
    }
}

static NSUInteger XNAActionCount = 0;

#pragma mark - skip button

// 广告只认「跳过」：按下后广告会走自己的关闭分支，宿主 App 拿得到回调。
// 「关闭」一类的不点——它可能属于业务弹窗，而且误触广告比广告本身更糟。
// 会员推广那条路径是另一套词表，见 XNACloseWords。
static BOOL XNAMatchText(NSString *text, NSArray<NSString *> *keywords) {
    if (text.length == 0) return NO;
    NSString *lower = text.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lower rangeOfString:keyword].location != NSNotFound) return YES;
    }
    return NO;
}

static NSArray<NSString *> *XNASkipWords(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ words = @[ @"跳过", @"skip" ]; });
    return words;
}

// 推广弹窗是自己人（App 的会员提示），关掉它的 ✕ 没有误触广告的风险，反而比硬摘视图干净。
static NSArray<NSString *> *XNACloseWords(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ words = @[ @"跳过", @"skip", @"关闭", @"close", @"dismiss" ]; });
    return words;
}

static BOOL XNALooksLikeSkip(UIControl *control, NSArray<NSString *> *keywords) {
    if ([control isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)control;
        if (XNAMatchText(button.currentTitle, keywords) || XNAMatchText(button.currentAttributedTitle.string, keywords)) return YES;
    }
    if (control.allTargets.count == 0) return NO;
    return XNAMatchText(control.accessibilityLabel, keywords) || XNAMatchText(control.accessibilityValue, keywords);
}

// 广度优先找广告自带的跳过按钮，限定在这块广告视图内部，避免点到业务界面的同名按钮。
static NSUInteger XNATrySkipInView(UIView *root, NSArray<NSString *> *keywords) {
    static const NSUInteger XNAMaxNodes = 400;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger tapped = 0, visited = 0;
    while (queue.count && visited < XNAMaxNodes) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (view != root && [view isKindOfClass:UIControl.class] && XNALooksLikeSkip((UIControl *)view, keywords)) {
            [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
            tapped++;
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return tapped;
}

static const void *XNASkipStateKey = &XNASkipStateKey;

// 跳过按钮往往要等广告素材到位才建出来，所以按节流重试几次，而不是一次定终身。
static void XNASkipIfNeeded(UIView *view, NSString *className) {
    if (!view) return;
    NSMutableArray *state = objc_getAssociatedObject(view, XNASkipStateKey);
    if (!state) {
        state = [NSMutableArray arrayWithObjects:@0, @0, nil];
        objc_setAssociatedObject(view, XNASkipStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    static const NSInteger XNAMaxSkipAttempts = 6;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([state[0] integerValue] >= XNAMaxSkipAttempts || now - [state[1] doubleValue] < 0.5) return;
    state[0] = @([state[0] integerValue] + 1);
    state[1] = @(now);
    NSUInteger tapped = XNATrySkipInView(view, XNASkipWords());
    if (tapped) {
        state[0] = @(XNAMaxSkipAttempts);
        XNALog(@"skip-button %@ x%lu", className, (unsigned long)tapped);
    }
}

#pragma mark - defuse

static void XNAReleaseViewController(UIViewController *vc) {
    UIViewController *presenter = vc.presentingViewController;
    if (presenter.presentedViewController == vc) {
        [presenter dismissViewControllerAnimated:NO completion:nil];
        return;
    }
    UINavigationController *nav = vc.navigationController;
    if (nav.viewControllers.count > 1 && nav.viewControllers.lastObject == vc) {
        [nav popViewControllerAnimated:NO];
    }
}

// 广告视图常被复用（热启动第二次起就是同一个对象），所以只要它又变成可见的，
// 就重置跳过重试的配额，让它重新有机会按下跳过。
static void XNAHideAndSkip(UIView *view, NSString *className) {
    if (!view) return;
    if (!view.isHidden) {
        objc_setAssociatedObject(view, XNASkipStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.hidden = YES;
    view.alpha = 0;
    XNASkipIfNeeded(view, className);
}

static void XNADefuse(id target) {
    if (!target) return;
    NSString *className = NSStringFromClass(object_getClass(target));
    BOOL splash = XNAIsSplashLikeName(className.UTF8String);
    void (^work)(void) = ^{
        XNAActionCount++;
        if ([target isKindOfClass:UIWindow.class]) {
            XNAHideAndSkip(target, className);
            XNALog(@"defuse window %@", className);
        } else if ([target isKindOfClass:UIViewController.class]) {
            UIViewController *vc = target;
            if (vc.isViewLoaded) XNAHideAndSkip(vc.view, className);
            // 兜底：插屏/激励可能没有自动关闭，宽限期后替它离场，别让用户对着一个看不见的模态。
            // 开屏的宽限期给足，倒计时跑完 SDK 会自己关，抢先销毁反而拿不到回调。
            NSTimeInterval grace = splash ? 8 : 1.2;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(grace * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               XNAReleaseViewController(vc);
                           });
            XNALog(@"defuse vc %@ splash=%d", className, splash);
        } else if ([target isKindOfClass:UIView.class]) {
            UIView *view = target;
            XNAHideAndSkip(view, className);
            // 开屏视图留在视图树里，SDK 的倒计时和关闭回调才能继续跑；其它广告直接摘掉。
            if (!splash && view.superview) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [view removeFromSuperview];
                });
            }
            XNALog(@"defuse view %@ splash=%d", className, splash);
        }
        if ((XNAActionCount % 25) == 0) XNAFlushLog();
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

static IMP XNADefuseIMP(IMP original, char returnType) {
    switch (returnType) {
        case '@': {
            id (^block)(id, SEL, void *, void *, void *) = ^(id self, SEL _cmd, void *a0, void *a1, void *a2) {
                id result = ((id(*)(id, SEL, void *, void *, void *))original)(self, _cmd, a0, a1, a2);
                XNADefuse(self);
                return result;
            };
            XNAKeep(block);
            return imp_implementationWithBlock(block);
        }
        case 'f': {
            float (^block)(id, SEL, void *, void *, void *) = ^(id self, SEL _cmd, void *a0, void *a1, void *a2) {
                float result = ((float(*)(id, SEL, void *, void *, void *))original)(self, _cmd, a0, a1, a2);
                XNADefuse(self);
                return result;
            };
            XNAKeep(block);
            return imp_implementationWithBlock(block);
        }
        case 'd': {
            double (^block)(id, SEL, void *, void *, void *) = ^(id self, SEL _cmd, void *a0, void *a1, void *a2) {
                double result = ((double(*)(id, SEL, void *, void *, void *))original)(self, _cmd, a0, a1, a2);
                XNADefuse(self);
                return result;
            };
            XNAKeep(block);
            return imp_implementationWithBlock(block);
        }
        default: {
            // 'v' 忽略返回值；BOOL/char/int/long 都只看 x0 的低 32 位，按 NSInteger 转发即可。
            NSInteger (^block)(id, SEL, void *, void *, void *) = ^(id self, SEL _cmd, void *a0, void *a1, void *a2) {
                NSInteger result = ((NSInteger(*)(id, SEL, void *, void *, void *))original)(self, _cmd, a0, a1, a2);
                XNADefuse(self);
                return result;
            };
            XNAKeep(block);
            return imp_implementationWithBlock(block);
        }
    }
}

#pragma mark - installation

static BOOL XNASignaturePortable(const char *encoding, char *returnType) {
    if (!encoding || !*encoding) return NO;
    switch (encoding[0]) {
        case 'v': case '@': case '#': case '*': case '^': case 'B': case 'c': case 'i': case 's':
        case 'l': case 'q': case 'I': case 'S': case 'L': case 'Q': case 'f': case 'd':
            *returnType = encoding[0];
            return YES;
        default:
            return NO;
    }
}

// 主线程那次热扫描和后台全量扫描可能同时在挂，计数用原子量。
static _Atomic NSUInteger XNAHookedCount = 0;

// 只处理 App 自带可执行文件与内嵌框架里的类，系统框架一律跳过。
static BOOL XNAClassIsAppOwned(Class cls) {
    const char *image = class_getImageName(cls);
    return image && strstr(image, ".app/");
}

// 标量返回且不吃参数，就是个取值器：showTime / render_delay_time / showVideoDetail 这类。
// 真把展示方法挂上去要付每次读取的代价，而这类 getter 在信息流列表里每秒被调几百次。
static BOOL XNAIsAccessorShaped(const char *encoding, unsigned int argumentCount) {
    if (argumentCount != 2) return NO;
    switch (encoding[0]) {
        case 'v': case '@': case '#': case '*': case '^':
            return NO;
        default:
            return YES;
    }
}

static void XNAHookMethod(Class cls, Method method, BOOL isClassMethod) {
    SEL selector = method_getName(method);
    char returnType = 'v';
    const char *encoding = method_getTypeEncoding(method);
    if (!XNASignaturePortable(encoding, &returnType)) return;
    unsigned int argumentCount = method_getNumberOfArguments(method);
    // 转发垫片只带 3 个指针参数，self/_cmd 之外更多参数的方法一律不动。
    if (argumentCount > 5) return;
    if (XNAIsAccessorShaped(encoding, argumentCount)) return;
    IMP original = method_getImplementation(method);
    IMP replacement = XNADefuseIMP(original, returnType);
    if (!replacement || original == replacement) return;
    method_setImplementation(method, replacement);
    atomic_fetch_add_explicit(&XNAHookedCount, 1, memory_order_relaxed);
    XNALog(@"defuse-hook %@[%@ %@] %s", isClassMethod ? @"+@" : @"-", NSStringFromClass(cls),
           NSStringFromSelector(selector), method_getTypeEncoding(method));
}

static NSMutableSet<NSString *> *XNAVisited(void) {
    static NSMutableSet *visited;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ visited = [NSMutableSet new]; });
    return visited;
}

static void XNAInstallIn(Class cls) {
    for (BOOL classMethod = NO;; classMethod = YES) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(classMethod ? object_getClass(cls) : cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            if (XNAIsPresentationSelector(sel_getName(method_getName(methods[i])))) {
                XNAHookMethod(cls, methods[i], classMethod);
            }
        }
        free(methods);
        if (classMethod) break;
    }
}

#pragma mark - overlay probe

// 「当前使用免费服务，建议升级…」这类推广弹窗不是广告 SDK 的类，而是 App 自己的视图，
// 光靠类名猜会漏。所以每秒瞄一眼界面层，把新冒出来的 App 自有视图记进日志：
// 下一份日志就能直接点名是谁弹的，再决定挂谁。只记不拦。
static NSHashTable<UIView *> *XNASeenViews(void) {
    static NSHashTable *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSHashTable weakObjectsHashTable]; });
    return seen;
}

static BOOL XNALooksLikeOverlayHost(NSString *className) {
    static NSArray<NSString *> *markers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markers = @[ @"Vip", @"Remind", @"Prompt", @"Upgrade", @"Dialog", @"Popup", @"Alert", @"Toast", @"Tip" ];
    });
    for (NSString *marker in markers) {
        if ([className rangeOfString:marker].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *XNAViewText(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) return ((UILabel *)view).text;
    if ([view isKindOfClass:UIButton.class]) return ((UIButton *)view).currentTitle;
    if ([view isKindOfClass:UIControl.class]) return ((UIControl *)view).accessibilityLabel;
    return nil;
}

// 实机日志点名出来的会员推广宿主（VipRemindView 底部横幅、CommonRemindView/ToastTextView 居中气泡）。
// 这几个类在二进制里自己一个方法都没实现，没有可挂的钩子，只能靠这里按名字认出来再藏。
static BOOL XNAIsPromotionOverlay(NSString *className) {
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[ @"VipRemind", @"CommonRemind", @"ToastText", @"RCVipPrompt" ];
    });
    for (NSString *prefix in prefixes) {
        if ([className hasPrefix:prefix]) return YES;
    }
    return NO;
}

// 气泡里的文字单独藏掉只会留下一个空壳，所以父视图只要还紧贴着这块内容，就继续往上套一层。
static UIView *XNAOverlayShell(UIView *view) {
    UIView *top = view;
    for (;;) {
        UIView *parent = top.superview;
        if (!parent || [parent isKindOfClass:UIWindow.class]) return top;
        if (!XNAClassIsAppOwned(parent.class)) return top;
        if (CGRectGetWidth(parent.bounds) > CGRectGetWidth(top.bounds) * 2.5 ||
            CGRectGetHeight(parent.bounds) > CGRectGetHeight(top.bounds) * 2.5)
            return top;
        top = parent;
    }
}

static void XNAHidePromotionOverlay(UIView *view, NSString *className) {
    UIView *shell = XNAOverlayShell(view);
    if (shell.isHidden) return;
    UIWindow *window = shell.window;
    // 盖掉大半个屏幕的不是推广条，多半是页面本体，宁可留着也别把界面掏空。
    if (window && CGRectGetWidth(shell.bounds) * CGRectGetHeight(shell.bounds) >
                      0.6 * CGRectGetWidth(window.bounds) * CGRectGetHeight(window.bounds)) {
        XNALog(@"overlay-keep %@ via %@", NSStringFromClass(shell.class), className);
        return;
    }
    NSUInteger tapped = XNATrySkipInView(shell, XNACloseWords());
    // 父视图链要留着：谁把这块气泡加进界面的，下一版就挂谁的 layoutSubviews，
    // 省得靠轮询，也就没有那零点几秒的闪现。
    NSMutableString *chain = [NSMutableString string];
    for (UIView *parent = shell.superview; parent && chain.length < 60; parent = parent.superview) {
        [chain appendFormat:@" <- %@(%.0fx%.0f)", NSStringFromClass(parent.class),
                            CGRectGetWidth(parent.bounds), CGRectGetHeight(parent.bounds)];
    }
    shell.hidden = YES;
    shell.alpha = 0;
    [shell removeFromSuperview];
    XNALog(@"overlay-hide %@ via %@ close=%lu%@", NSStringFromClass(shell.class), className,
           (unsigned long)tapped, chain);
}

static void XNAScanOverlays(void) {
    static BOOL baselined = NO;
    BOOL report = baselined;
    baselined = YES;
    NSUInteger logged;
    @synchronized(XNAJournal()) { logged = XNAJournal().count; }
    NSMutableArray<UIView *> *queue = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        [queue addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    NSUInteger visited = 0;
    while (queue.count && visited < 900) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        [queue addObjectsFromArray:view.subviews];
        if (!XNAClassIsAppOwned(view.class)) continue;
        NSString *className = NSStringFromClass(view.class);
        if (XNAIsPromotionOverlay(className)) {
            if (view.window && !view.isHidden) XNAHidePromotionOverlay(view, className);
            continue;
        }
        BOOL fresh = ![XNASeenViews() containsObject:view];
        [XNASeenViews() addObject:view];
        if (!fresh || !report) continue;
        if (view.isHidden || view.alpha < 0.05 || !view.window) continue;
        // 直接挂在窗口上的新视图一律记（弹窗都这么干）；藏在页面深处的只记名字像推广的。
        if (![view.superview isKindOfClass:UIWindow.class] && !XNALooksLikeOverlayHost(className)) continue;
        NSString *text = XNAViewText(view);
        XNALog(@"overlay %@ frame=%@ text=%@", className, NSStringFromCGRect(view.frame), text ?: @"-");
    }
    // 只在真的写了东西时刷盘：这一秒一秒地跑，每次都重写整份日志太浪费。
    BOOL wrote;
    @synchronized(XNAJournal()) { wrote = XNAJournal().count != logged; }
    if (wrote) XNAFlushLog();
}

// 扫描全在一条自己的串行队列上做，主线程只负责开屏那一批。
static dispatch_queue_t XNAInstallQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.moxuan.xrknoad.install", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

// launchOnly 为真时只挂开屏/启动广告那批类，必须在主线程构造函数里同步做完；
// 全量扫描放后台：v0.0.2 把 5 万个类的规则匹配压在构造函数里，冷启动就这么卡了 2 秒。
static void XNAInstallAll(NSString *pass, BOOL launchOnly) {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSUInteger scanned = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (launchOnly ? !XNAIsLaunchClassName(name) : !XNAIsInterestingClassName(name)) continue;
        if (!XNAClassIsAppOwned(classes[i])) continue;
        NSString *key = @(name);
        @synchronized(XNAVisited()) {
            // 先占名再挂，重复的 pass 和并发的两条 pass 都不会把方法套两层。
            if ([XNAVisited() containsObject:key]) continue;
            [XNAVisited() addObject:key];
        }
        scanned++;
        XNAInstallIn(classes[i]);
    }
    free(classes);
    XNALog(@"pass %@: %u classes, %lu candidates, %lu hooks in %.0f ms", pass, count, (unsigned long)scanned,
           (unsigned long)atomic_load_explicit(&XNAHookedCount, memory_order_relaxed),
           (NSProcessInfo.processInfo.systemUptime - started) * 1000);
    XNAFlushLog();
}

// 启动窗口：这之前的补扫全部交给下面的定时任务，最后一次落在 40 s。
static const NSTimeInterval XNAStartupWindow = 45;

__attribute__((constructor)) static void XrkNoAdEntry(void) {
    @autoreleasepool {
        XNALaunchUptime = NSProcessInfo.processInfo.systemUptime;
        XNALog(@"XrkNoAd attached to %@ / %@", NSProcessInfo.processInfo.processName,
               NSBundle.mainBundle.bundleIdentifier);
        XNAInstallAll(@"launch", YES);
        // 先认出来才能屏蔽：主线程扫界面层，记新出现的 App 自有视图、藏掉会员推广弹窗。
        // 挂到 common modes，否则滚动和手势期间根本不扫，弹窗会一直挂着。
        NSTimer *probe = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
            XNAScanOverlays();
        }];
        [NSRunLoop.mainRunLoop addTimer:probe forMode:NSRunLoopCommonModes];
        XNAKeep(probe);
        // 广告视图类大多要等第一次请求广告时才注册，所以要反复补扫；热启动回前台同理。
        for (NSNumber *delay in @[ @0.2, @2, @5, @15, @(XNAStartupWindow - 5) ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           XNAInstallQueue(), ^{
                               XNAInstallAll(@"full", NO);
                           });
        }
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                     object:nil
                                                                        queue:nil
                                                                   usingBlock:^(NSNotification *note) {
                                                                       // 冷启动那次 DidBecomeActive 和上面的定时补扫是同一件事，
                                                                       // 抢在启动窗口里再全量扫一遍只是白占后台 CPU。
                                                                       NSTimeInterval age =
                                                                           NSProcessInfo.processInfo.systemUptime - XNALaunchUptime;
                                                                       if (age < XNAStartupWindow) {
                                                                           XNALog(@"skip active pass at +%0.0fs (startup window)", age);
                                                                           // 这条之后没有 pass 会再刷盘，不主动 flush 就等于没写。
                                                                           XNAFlushLog();
                                                                           return;
                                                                       }
                                                                       dispatch_async(XNAInstallQueue(), ^{
                                                                           XNAInstallAll(@"active", NO);
                                                                       });
                                                                   }];
        XNAKeep(observer);
    }
}
