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
    // 写盘的两条线：后台挂钩 pass 在主线程外，推广扫描在主线程。atomically 各自的中转文件同名，
    // 撞在一起就是 ENOTEMPTY（0.0.6 那份日志只到 +256s 就是这个），所以直接覆盖。
    [[snapshot componentsJoinedByString:@"\n"] writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
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
static NSArray<NSString *> *XNARejectWords(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[ @"再想想", @"暂不", @"以后再说", @"不用了", @"知道了", @"取消", @"关闭", @"close", @"dismiss" ];
    });
    return words;
}

static NSArray<NSString *> *XNACloseWords(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ words = [XNARejectWords() arrayByAddingObjectsFromArray:XNASkipWords()]; });
    return words;
}

// 会员弹窗的文案是服务端下发的，二进制里一个字都搜不到，只能认「升级」这类字眼。
static NSArray<NSString *> *XNAUpsellWords(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[ @"升级", @"开通", @"购买", @"续费", @"立即", @"会员", @"独享", @"专属", @"专享" ];
    });
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

#pragma mark - membership alert muting

// 会员弹窗的文案是服务端下发的，二进制里一个字都搜不到，类名规则永远点不到它。但它要走界面，
// 总得把文案原样传进 App 自己的弹窗助手——所以在「要弹」这一刻掐掉是可行的，比视图层轮询干净：
// 没有 0.25 秒的闪现，也不会出现摘了卡片留下蒙层的残局。
// 词表刻意不收「升级」：固件强更那一类也喊升级，那是业务，不能吞。
static NSArray<NSString *> *XNAMemberWords(void) {
    static NSArray<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ words = @[ @"会员", @"专享", @"专属", @"独享", @"vip" ]; });
    return words;
}

// 参数按 void * 收，取用时才桥成对象——和 XNADefuseIMP 一样，免得 ARC 去 retain 一个栈上 block。
static NSString *XNAMembershipCopy(void *arg) {
    if (!arg) return nil;
    id value = (__bridge id)arg;
    NSString *text = nil;
    if ([value isKindOfClass:NSString.class]) {
        text = value;
    } else if ([value isKindOfClass:NSAttributedString.class]) {
        text = [(NSAttributedString *)value string];
    }
    if (text.length == 0 || !XNAMatchText(text, XNAMemberWords())) return nil;
    return text;
}

// 命中就记一行原文：这批日志是判断「这个弹窗到底走哪条路」的唯一证据，别只留个 bool。
// 没命中也要记一行调用本身——只有对着时间戳看，才知道那个大弹窗是不是真走这条路，
// 也才知道钩子挂上了没有。这里不回显业务文案，宿主密码提示那类会把秘密写进日志。
static BOOL XNAIsMembershipAlert(NSString *via, void **args, NSUInteger count) {
    XNALog(@"alert-call %@", via);
    for (NSUInteger i = 0; i < count; i++) {
        NSString *text = XNAMembershipCopy(args[i]);
        if (!text) continue;
        NSString *clip = text.length > 40 ? [text substringToIndex:40] : text;
        XNALog(@"alert-mute %@ text=%@", via, clip);
        return YES;
    }
    return NO;
}

// 工厂已经造好了视图，只能就地做成看不见：从父视图里摘掉会在宿主那一格留个空洞。
static void XNAHideBuiltView(void *arg) {
    if (!arg) return;
    id value = (__bridge id)arg;
    if (![value isKindOfClass:UIView.class]) return;
    UIView *view = value;
    view.hidden = YES;
    view.alpha = 0;
}

// 原 IMP 存文件作用域的静态量：block 捕获静态变量是按地址取的，捕获局部变量的话，
// block 建出来那一刻局部量还没写进去，转发时就是调空指针。
static IMP XNAAlertPlain = NULL;
static IMP XNAAlertHeight = NULL;
static IMP XNAAlertSolt = NULL;
static IMP XNAAlertAttributed = NULL;
static IMP XNARCFreePrompt = NULL;
static IMP XNARCVipPrompt = NULL;

static void XNAMuteEntry(Class cls, SEL selector, const char *encoding, IMP replacement, IMP *slot) {
    if (!replacement || *slot) return;
    for (BOOL classMethod = NO;; classMethod = YES) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(classMethod ? object_getClass(cls) : cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) != selector) continue;
            // 签名对不上就一动不动：App 改了参数，硬编下去等于用错的调用约定去调它，崩在弹窗里。
            if (strcmp(method_getTypeEncoding(methods[i]), encoding) != 0) {
                XNALog(@"alert-skip %s 签名已变：%s", sel_getName(selector),
                       method_getTypeEncoding(methods[i]));
                break;
            }
            *slot = method_getImplementation(methods[i]);
            method_setImplementation(methods[i], replacement);
            XNALog(@"alert-hook %@%s", classMethod ? @"+[" : @"-[", sel_getName(selector));
            break;
        }
        free(methods);
        if (classMethod) break;
    }
}

static void XNAMuteMembershipAlerts(void) {
    Class cls = objc_getClass("CustomAlertViewController");
    if (cls) {
        void (^plain)(id, SEL, void *, void *, void *, void *, void *, void *) =
            ^(id self_, SEL _cmd, void *vc, void *title, void *message, void *ok, void *cancel,
              void *done) {
                void *args[] = { title, message, ok, cancel };
                if (XNAIsMembershipAlert(@"plain", args, 4)) return;
                if (XNAAlertPlain) {
                    ((void (*)(id, SEL, void *, void *, void *, void *, void *, void *))
                         XNAAlertPlain)(self_, _cmd, vc, title, message, ok, cancel, done);
                }
            };
        XNAKeep(plain);
        XNAMuteEntry(cls,
                     NSSelectorFromString(
                         @"showAlertViewWithViewController:title:textViewMessage:btnOKTitle:"
                         @"btnCancelTitle:completion:"),
                     "v64@0:8@16@24@32@40@48@?56", imp_implementationWithBlock(plain),
                     &XNAAlertPlain);

        void (^height)(id, SEL, void *, double, void *, void *, void *, void *, void *) =
            ^(id self_, SEL _cmd, void *vc, double popupHeight, void *title, void *message,
              void *ok, void *cancel, void *done) {
                void *args[] = { title, message, ok, cancel };
                if (XNAIsMembershipAlert(@"height", args, 4)) return;
                if (XNAAlertHeight) {
                    ((void (*)(id, SEL, void *, double, void *, void *, void *, void *, void *))
                         XNAAlertHeight)(self_, _cmd, vc, popupHeight, title, message, ok, cancel,
                                         done);
                }
            };
        XNAKeep(height);
        XNAMuteEntry(cls,
                     NSSelectorFromString(
                         @"showAlertViewWithViewController:popupHeight:title:textViewMessage:"
                         @"btnOKTitle:btnCancelTitle:completion:"),
                     "v72@0:8@16d24@32@40@48@56@?64", imp_implementationWithBlock(height),
                     &XNAAlertHeight);

        void (^solt)(id, SEL, void *, void *, double, void *, void *, void *, void *, void *) =
            ^(id self_, SEL _cmd, void *vc, void *soltView, double popupHeight, void *title,
              void *message, void *ok, void *cancel, void *done) {
                void *args[] = { title, message, ok, cancel };
                if (XNAIsMembershipAlert(@"solt", args, 4)) return;
                if (XNAAlertSolt) {
                    ((void (*)(id, SEL, void *, void *, double, void *, void *, void *, void *,
                               void *))XNAAlertSolt)(self_, _cmd, vc, soltView, popupHeight, title,
                                                     message, ok, cancel, done);
                }
            };
        XNAKeep(solt);
        XNAMuteEntry(cls,
                     NSSelectorFromString(
                         @"showAlertViewWithViewController:soltView:popupHeight:title:"
                         @"textViewMessage:btnOKTitle:btnCancelTitle:completion:"),
                     "v80@0:8@16@24d32@40@48@56@64@?72", imp_implementationWithBlock(solt),
                     &XNAAlertSolt);

        void (^attributed)(id, SEL, void *, double, void *, void *, void *, void *, BOOL,
                           void *) =
            ^(id self_, SEL _cmd, void *vc, double popupHeight, void *title, void *text, void *ok,
              void *cancel, BOOL canNotClose, void *done) {
                void *args[] = { title, text, ok, cancel };
                if (XNAIsMembershipAlert(@"attributed", args, 4)) return;
                if (XNAAlertAttributed) {
                    ((void (*)(id, SEL, void *, double, void *, void *, void *, void *, BOOL,
                               void *))XNAAlertAttributed)(self_, _cmd, vc, popupHeight, title,
                                                          text, ok, cancel, canNotClose, done);
                }
            };
        XNAKeep(attributed);
        XNAMuteEntry(cls,
                     NSSelectorFromString(
                         @"showAlertViewWithViewController:popupHeight:title:attributedText:"
                         @"btnOKTitle:btnCancelTitle:canNotClose:completion:"),
                     "v76@0:8@16d24@32@40@48@56B64@?68",
                     imp_implementationWithBlock(attributed), &XNAAlertAttributed);
    }

    // 这两个是「造一个推广气泡出来给宿主加进去」的工厂，返回 nil 会把下游的解引用晾在原地。
    // 所以照原样造，只在文案卖会员时把它做成看不见的——调用方拿到的还是真视图，只是不长出来。
    Class freePrompt = objc_getClass("RCFreePromptView");
    if (freePrompt) {
        void *(^block)(id, SEL, void *, void *, void *) = ^(id self_, SEL _cmd, void *title,
                                                           void *actionTitle, void *done) {
            void *result = nil;
            if (XNARCFreePrompt) {
                result = ((void *(*)(id, SEL, void *, void *, void *))XNARCFreePrompt)(
                    self_, _cmd, title, actionTitle, done);
            }
            void *args[] = { title, actionTitle };
            if (XNAIsMembershipAlert(@"free-prompt", args, 2)) XNAHideBuiltView(result);
            return result;
        };
        XNAKeep(block);
        XNAMuteEntry(freePrompt,
                     NSSelectorFromString(@"RCFreePromptViewWithTitle:actionTitle:complete:"),
                     "@40@0:8@16@24@?32", imp_implementationWithBlock(block), &XNARCFreePrompt);
    }

    Class vipPrompt = objc_getClass("RCVipPromptView");
    if (vipPrompt) {
        void *(^block)(id, SEL, void *) = ^(id self_, SEL _cmd, void *title) {
            void *result = nil;
            if (XNARCVipPrompt) {
                result = ((void *(*)(id, SEL, void *))XNARCVipPrompt)(self_, _cmd, title);
            }
            if (XNAIsMembershipAlert(@"vip-prompt", &title, 1)) XNAHideBuiltView(result);
            return result;
        };
        XNAKeep(block);
        XNAMuteEntry(vipPrompt, NSSelectorFromString(@"RCVipPromptViewWithTitle:"),
                     "@24@0:8@16", imp_implementationWithBlock(block), &XNARCVipPrompt);
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

// 只看普通层级的窗口：弹窗爱开在自己的浮窗里，那层窗口的 rootViewController.view 就是弹窗本身，
// 把它当成「不许碰的页面」就等于自己把自己锁死。
static NSArray<UIView *> *XNAPageRoots(void) {
    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.windowLevel > 0.5 || window.windowLevel < -0.5) continue;
            UIView *root = window.rootViewController.viewIfLoaded;
            if (root) [roots addObject:root];
        }
    }
    return roots;
}

static CGFloat XNAArea(CGRect rect) {
    return CGRectGetWidth(rect) * CGRectGetHeight(rect);
}

// 页面骨架：rootViewController 那张脸和托着它的几层容器。掏空它等于把界面砸了，比留个弹窗严重得多。
static BOOL XNAIsPageSkeleton(UIView *candidate) {
    for (UIView *root in XNAPageRoots()) {
        for (UIView *v = root; v; v = v.superview) {
            if (v == candidate) return YES;
        }
    }
    return NO;
}

// 推广块是嵌在页面里还是浮在页面上：浮着的那层壳（连蒙层一起）整块端走，嵌着的只摘它自己。
static BOOL XNAIsInsidePage(UIView *candidate) {
    for (UIView *root in XNAPageRoots()) {
        if ([candidate isDescendantOfView:root]) return YES;
    }
    return NO;
}

static BOOL XNAIsOversized(UIView *view) {
    UIWindow *window = view.window;
    return window && XNAArea(view.bounds) > 0.75 * XNAArea(window.bounds);
}

// 盖满全屏、又长在页面里的那层不是弹窗壳，是页面本体。
static BOOL XNAIsPageBody(UIView *view) {
    return XNAIsPageSkeleton(view) || (XNAIsOversized(view) && XNAIsInsidePage(view));
}

// 认不出类名的会员弹窗（「免费跨境节点繁忙」那种）只能看内容：同一棵子树里既长出「立即升级」
// 又长出「再想想」，那就不是普通页面。返回 2 坐实，1 是只凑齐一半。
static NSInteger XNAIsPaywallDialog(UIView *root) {
    if (!root) return 0;
    static const NSUInteger XNAMaxNodes = 150;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    BOOL hasReject = NO, hasUpsell = NO;
    NSUInteger visited = 0;
    while (queue.count && visited < XNAMaxNodes) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        NSString *text = XNAViewText(view);
        if (!hasReject) hasReject = XNAMatchText(text, XNARejectWords());
        if (!hasUpsell) hasUpsell = XNAMatchText(text, XNAUpsellWords());
        if (hasReject && hasUpsell) return 2;
        [queue addObjectsFromArray:view.subviews];
    }
    return hasReject || hasUpsell;
}

// 壳常常是复用过的老视图，只有按钮是新长出来的，所以从按钮往上找壳，别等壳自己变「新鲜」。
// 往上爬到撞到页面本体为止，取最后一个还合格的祖先；系统的转场壳是页面骨架的一环，
// XNAIsPageBody 会把它挡下来，所以这里连系统容器也可以路过。
static UIView *XNAOverlayHostForLeaf(UIView *leaf) {
    UIView *top = nil;
    UIView *parent = leaf.superview;
    for (NSUInteger hop = 0; parent && hop < 8; hop++) {
        if ([parent isKindOfClass:UIWindow.class] || XNAIsPageBody(parent)) break;
        top = parent;
        parent = parent.superview;
    }
    return top;
}

// 一行的两个按钮：「立即升级」旁边还站着一个键，就是弹窗的按钮行。
// 「再想想」那半边常常读不出文字（CustomConfirmButton 读得到，对面那个读不到），
// 光靠文案配对会漏，形状不会漏。
static BOOL XNAIsButtonRowLeaf(UIView *leaf) {
    UIView *parent = leaf.superview;
    if (!parent) return NO;
    NSUInteger controls = 0;
    for (UIView *sibling in parent.subviews) {
        if ([sibling isKindOfClass:UIControl.class] && !sibling.isHidden) controls++;
    }
    return controls >= 2;
}

static NSUInteger XNASubtreeSize(UIView *root) {
    static const NSUInteger XNAMaxNodes = 24;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (queue.count && visited < XNAMaxNodes) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        [queue addObjectsFromArray:view.subviews];
    }
    return visited;
}

// 壳里铺满一层、底下还压着几十号视图的，是用户自己点开的整页，别连着页一起端掉。
static BOOL XNAHostHoldsFullPage(UIView *host) {
    for (UIView *child in host.subviews) {
        if (child.isHidden) continue;
        if (XNAArea(child.bounds) >= 0.9 * XNAArea(host.bounds) && XNASubtreeSize(child) >= 24) return YES;
    }
    return NO;
}

// 居中的一张卡片：宽占屏 0.45~0.98、高占屏 0.12~0.85，中心落在屏幕中间那一带。
// 底部横幅条（428×39 那种）和整页都不长这样，误伤面就靠这一点几何关系兜着。
static BOOL XNAIsCenteredCard(UIView *host) {
    UIWindow *window = host.window;
    if (!window) return NO;
    CGFloat w = CGRectGetWidth(window.bounds), h = CGRectGetHeight(window.bounds);
    if (w < 1 || h < 1) return NO;
    CGRect rect = [host convertRect:host.bounds toView:window];
    CGFloat rw = CGRectGetWidth(rect) / w, rh = CGRectGetHeight(rect) / h;
    if (rw < 0.45 || rw > 0.98 || rh < 0.12 || rh > 0.85) return NO;
    CGFloat cx = CGRectGetMidX(rect) / w, cy = CGRectGetMidY(rect) / h;
    return cx > 0.3 && cx < 0.7 && cy > 0.25 && cy < 0.75;
}

// 这些 nag 都是 present 出来的 ViewController（VipRemindView 的父链里就挂着 _UIParallaxDimmingView）。
// 只摘视图会留下一层吃掉点击的蒙层，让 UIKit 自己收场才干净；不是最上面那层 present 就别按。
static BOOL XNADismissPresentedHost(UIView *host, NSString *via) {
    for (UIResponder *responder = host.nextResponder; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        UIViewController *vc = (UIViewController *)responder;
        if (vc.view != host) return NO;
        UIViewController *presenter = vc.presentingViewController;
        if (!presenter || presenter.presentedViewController != vc) return NO;
        [vc dismissViewControllerAnimated:NO completion:nil];
        XNALog(@"overlay-dismiss %@ via %@", NSStringFromClass(vc.class), via);
        return YES;
    }
    return NO;
}

// 摘掉一块推广，host 就是它的壳。先按壳自带的关闭键，走 App 自己的关闭分支（蒙层跟着一起没，最干净）；
// 像 VipRemindView 那种根本没有可点按钮的，再兜底把壳藏掉。
static void XNAKillHost(UIView *host, NSString *via) {
    if (!host || host.isHidden || [host isKindOfClass:UIWindow.class]) return;
    NSUInteger tapped = XNATrySkipInView(host, XNACloseWords());
    if (XNAIsPageBody(host)) {
        // 摘不动就只留那一按：宁可弹窗挂着，也不能把界面掏空。
        XNALog(@"overlay-keep %@ via %@ close=%lu", NSStringFromClass(host.class), via, (unsigned long)tapped);
        return;
    }
    // 父视图链要留着：谁把这块气泡加进界面的，下一版就挂谁的 layoutSubviews，
    // 省得靠轮询，也就没有那零点几秒的闪现。
    NSMutableString *chain = [NSMutableString string];
    for (UIView *parent = host.superview; parent && chain.length < 60; parent = parent.superview) {
        [chain appendFormat:@" <- %@(%.0fx%.0f)", NSStringFromClass(parent.class),
                            CGRectGetWidth(parent.bounds), CGRectGetHeight(parent.bounds)];
    }
    host.hidden = YES;
    host.alpha = 0;
    [host removeFromSuperview];
    XNALog(@"overlay-hide %@ via %@ frame=%@ close=%lu%@", NSStringFromClass(host.class), via,
           NSStringFromCGRect(host.frame), (unsigned long)tapped, chain);
}

// 按类名认出来的那批（VipRemindView 一类）：壳还得靠紧贴关系往上套一层。
static void XNAKillOverlay(UIView *view, NSString *via) {
    XNAKillHost(XNAOverlayShell(view), via);
}

// 没动手的时候把现场抄下来：这颗按钮同层都长了什么、父链上都是谁。看不清结构就只能在猜。
static void XNALogLeafNeighbourhood(UIView *leaf, NSUInteger level, UIView *host) {
    NSMutableString *siblings = [NSMutableString string];
    for (UIView *sibling in leaf.superview.subviews) {
        if (siblings.length > 56) break;
        NSString *title = XNAViewText(sibling);
        [siblings appendFormat:@" %@(%.0fx%.0f)%@", NSStringFromClass(sibling.class),
                               CGRectGetWidth(sibling.bounds), CGRectGetHeight(sibling.bounds),
                               title.length ? [NSString stringWithFormat:@":%@", title] : @""];
    }
    NSMutableString *chain = [NSMutableString string];
    for (UIView *v = leaf.superview; v && chain.length < 56; v = v.superview) {
        [chain appendFormat:@" <- %@(%.0fx%.0f)%@", NSStringFromClass(v.class),
                            CGRectGetWidth(v.bounds), CGRectGetHeight(v.bounds),
                            XNAClassIsAppOwned(v.class) ? @"" : @"/sys"];
    }
    XNALog(@"overlay-leaf d=%lu host=%@ 同层:%@ 父链:%@", (unsigned long)level,
           host ? NSStringFromClass(host.class) : @"-", siblings, chain);
}

static void XNAScanOverlays(void) {
    static BOOL baselined = NO;
    BOOL report = baselined;
    baselined = YES;
    NSUInteger logged;
    @synchronized(XNAJournal()) { logged = XNAJournal().count; }
    NSMutableArray<UIView *> *queue = [NSMutableArray array];
    NSMutableArray<NSNumber *> *levels = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [queue addObject:window];
            [levels addObject:@0];
        }
    }
    NSUInteger visited = 0;
    while (queue.count && visited < 900) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSUInteger level = [levels.firstObject unsignedIntegerValue];
        [levels removeObjectAtIndex:0];
        visited++;
        for (UIView *child in view.subviews) {
            [queue addObject:child];
            [levels addObject:@(level + 1)];
        }
        if (!XNAClassIsAppOwned(view.class)) continue;
        NSString *className = NSStringFromClass(view.class);
        if (XNAIsPromotionOverlay(className)) {
            if (view.window && !view.isHidden) XNAKillOverlay(view, className);
            continue;
        }
        BOOL fresh = ![XNASeenViews() containsObject:view];
        [XNASeenViews() addObject:view];
        if (!fresh || !report) continue;
        if (view.isHidden || view.alpha < 0.05 || !view.window) continue;
        NSString *text = XNAViewText(view);
        if ([view isKindOfClass:UIControl.class] && XNAMatchText(text, XNAUpsellWords())) {
            XNALog(@"overlay-text %@ d=%lu frame=%@ text=%@", className, (unsigned long)level,
                   NSStringFromCGRect(view.frame), text);
            UIView *host = XNAOverlayHostForLeaf(view);
            BOOL pair = XNAIsPaywallDialog(host) == 2;
            // 动手的门槛：文案配对齐全，或者按钮是一行两键的形状；壳还得像张浮着的卡片。
            BOOL shaped = host && (XNAIsCenteredCard(host) || !XNAIsInsidePage(host));
            if (host && shaped && (pair || XNAIsButtonRowLeaf(view)) && !XNAHostHoldsFullPage(host)) {
                if (!XNADismissPresentedHost(host, @"upsell")) XNAKillHost(host, @"upsell");
            } else {
                XNALogLeafNeighbourhood(view, level, host);
            }
        } else if (level <= 6 && XNAIsPaywallDialog(view) == 2) {
            XNAKillOverlay(view, @"paywall");
        } else if ([view.superview isKindOfClass:UIWindow.class] || level <= 3 ||
                   XNALooksLikeOverlayHost(className)) {
            // 直接挂在窗口上的新视图一律记（弹窗都这么干）；藏在页面深处的只记名字像推广的。
            XNALog(@"overlay %@ d=%lu frame=%@ text=%@", className, (unsigned long)level,
                   NSStringFromCGRect(view.frame), text ?: @"-");
        }
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
        XNAMuteMembershipAlerts();
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
