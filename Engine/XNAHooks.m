#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <objc/runtime.h>
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

static void XNALog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(XNALogger(), "%{public}@", line);
    @synchronized(XNAJournal()) {
        [XNAJournal() addObject:line];
        if (XNAJournal().count > 600) [XNAJournal() removeObjectsInRange:NSMakeRange(0, XNAJournal().count - 600)];
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

// 只认「跳过」：这类按钮按下后广告会走自己的关闭分支，宿主 App 拿得到回调。
// 「关闭」一类的不点——它可能属于业务弹窗，而且误触广告比广告本身更糟。
static BOOL XNAMatchSkipText(NSString *text) {
    static NSArray<NSString *> *keywords;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keywords = @[ @"跳过", @"skip" ]; });
    if (text.length == 0) return NO;
    NSString *lower = text.lowercaseString;
    for (NSString *keyword in keywords) {
        if ([lower rangeOfString:keyword].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL XNALooksLikeSkip(UIControl *control) {
    if ([control isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)control;
        if (XNAMatchSkipText(button.currentTitle) || XNAMatchSkipText(button.currentAttributedTitle.string)) return YES;
    }
    if (control.allTargets.count == 0) return NO;
    return XNAMatchSkipText(control.accessibilityLabel) || XNAMatchSkipText(control.accessibilityValue);
}

// 广度优先找广告自带的跳过按钮，限定在这块广告视图内部，避免点到业务界面的同名按钮。
static NSUInteger XNATrySkipInView(UIView *root) {
    static const NSUInteger XNAMaxNodes = 400;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger tapped = 0, visited = 0;
    while (queue.count && visited < XNAMaxNodes) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (view != root && [view isKindOfClass:UIControl.class] && XNALooksLikeSkip((UIControl *)view)) {
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
    NSUInteger tapped = XNATrySkipInView(view);
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

static NSUInteger XNAHookedCount = 0;

// 只处理 App 自带可执行文件与内嵌框架里的类，系统框架一律跳过。
static BOOL XNAClassIsAppOwned(Class cls) {
    const char *image = class_getImageName(cls);
    return image && strstr(image, ".app/");
}

static void XNAHookMethod(Class cls, Method method, BOOL isClassMethod) {
    SEL selector = method_getName(method);
    char returnType = 'v';
    if (!XNASignaturePortable(method_getTypeEncoding(method), &returnType)) return;
    // 转发垫片只带 3 个指针参数，self/_cmd 之外更多参数的方法一律不动。
    if (method_getNumberOfArguments(method) > 5) return;
    IMP original = method_getImplementation(method);
    IMP replacement = XNADefuseIMP(original, returnType);
    if (!replacement || original == replacement) return;
    method_setImplementation(method, replacement);
    XNAHookedCount++;
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
    const char *className = class_getName(cls);
    for (BOOL classMethod = NO;; classMethod = YES) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(classMethod ? object_getClass(cls) : cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            if (XNAActionForClass(className, sel_getName(method_getName(methods[i]))) != XNAActionNone) {
                XNAHookMethod(cls, methods[i], classMethod);
            }
        }
        free(methods);
        if (classMethod) break;
    }
}

static void XNAInstallAll(NSString *pass) {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSUInteger scanned = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!XNAIsInterestingClassName(name)) continue;
        NSString *key = @(name);
        @synchronized(XNAVisited()) {
            if ([XNAVisited() containsObject:key]) continue;
            [XNAVisited() addObject:key];
        }
        scanned++;
        if (XNAClassIsAppOwned(classes[i])) XNAInstallIn(classes[i]);
    }
    free(classes);
    XNALog(@"pass %@: %u classes, %lu candidates, %lu hooks in %.0f ms", pass, count, (unsigned long)scanned,
           (unsigned long)XNAHookedCount, (NSProcessInfo.processInfo.systemUptime - started) * 1000);
    XNAFlushLog();
}

__attribute__((constructor)) static void XrkNoAdEntry(void) {
    @autoreleasepool {
        XNALog(@"XrkNoAd attached to %@ / %@", NSProcessInfo.processInfo.processName,
               NSBundle.mainBundle.bundleIdentifier);
        XNAInstallAll(@"eager");
        // 广告视图类大多要等第一次请求广告时才注册，热启动那次也必须重新扫一遍。
        for (NSNumber *delay in @[ @2, @5, @15, @40 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               XNAInstallAll(@"late");
                           });
        }
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                     object:nil
                                                                        queue:NSOperationQueue.mainQueue
                                                                   usingBlock:^(NSNotification *note) {
                                                                       XNAInstallAll(@"active");
                                                                   }];
        XNAKeep(observer);
    }
}
