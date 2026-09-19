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

#pragma mark - stubs

static BOOL XNASelectorReturnsCollection(const char *selector) {
    static const char *const markers[] = { "Array", "List", "Models", "Infos", "Items", "Ads", "ADs", "Results" };
    for (size_t i = 0; i < sizeof(markers) / sizeof(markers[0]); i++) {
        if (strstr(selector, markers[i])) return YES;
    }
    return NO;
}

static void XNAStubVoid(id self, SEL _cmd) {}

static NSInteger XNAStubScalar(id self, SEL _cmd) { return 0; }

static double XNAStubNumber(id self, SEL _cmd) { return 0; }

static id XNAStubObject(id self, SEL _cmd) {
    return XNASelectorReturnsCollection(sel_getName(_cmd)) ? (id)@[] : nil;
}

static BOOL XNASignatureStubbable(const char *encoding, char *returnType) {
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

static IMP XNAStubForReturnType(char type) {
    switch (type) {
        case 'v': return (IMP)XNAStubVoid;
        case '@': return (IMP)XNAStubObject;
        case 'f': case 'd': return (IMP)XNAStubNumber;
        default: return (IMP)XNAStubScalar;
    }
}

#pragma mark - defuse

static const void *XNADefusedKey = &XNADefusedKey;

static void XNADefuse(id target) {
    if (!target) return;
    @synchronized(target) {
        if (objc_getAssociatedObject(target, XNADefusedKey)) return;
        objc_setAssociatedObject(target, XNADefusedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    void (^work)(void) = ^{
        if ([target isKindOfClass:UIViewController.class]) {
            UIViewController *vc = target;
            if (vc.isViewLoaded) {
                vc.view.hidden = YES;
                vc.view.alpha = 0;
            }
            if (vc.presentingViewController) {
                [vc.presentingViewController dismissViewControllerAnimated:NO completion:nil];
            } else if (vc.navigationController.viewControllers.count > 1 &&
                       vc.navigationController.viewControllers.lastObject == vc) {
                [vc.navigationController popViewControllerAnimated:NO];
            }
            return;
        }
        if ([target isKindOfClass:UIView.class]) {
            UIView *view = target;
            view.hidden = YES;
            view.alpha = 0;
            UIView *parent = view.superview;
            if (parent) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [view removeFromSuperview];
                });
            }
        }
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

static IMP XNADefuseIMP(IMP original, char returnType) {
    void (^block)(id, SEL, void *, void *, void *) = ^(id self, SEL _cmd, void *a0, void *a1, void *a2) {
        switch (returnType) {
            case '@': ((id (*)(id, SEL, void *, void *, void *))original)(self, _cmd, a0, a1, a2); break;
            case 'f': case 'd': ((double (*)(id, SEL, void *, void *, void *))original)(self, _cmd, a0, a1, a2); break;
            case 'v': ((void (*)(id, SEL, void *, void *, void *))original)(self, _cmd, a0, a1, a2); break;
            default: ((NSInteger(*)(id, SEL, void *, void *, void *))original)(self, _cmd, a0, a1, a2); break;
        }
        XNADefuse(self);
    };
    @synchronized(XNAKeepAlive()) {
        [XNAKeepAlive() addObject:block];
    }
    return imp_implementationWithBlock(block);
}

#pragma mark - installation

static NSUInteger XNAHookedCount = 0;

// 只处理 App 自带可执行文件与内嵌框架里的类，系统框架一律跳过。
static BOOL XNAClassIsAppOwned(Class cls) {
    const char *image = class_getImageName(cls);
    return image && strstr(image, ".app/");
}

static void XNAHookMethod(Class cls, Method method, BOOL isClassMethod, XNAAction action) {
    SEL selector = method_getName(method);
    const char *selectorName = sel_getName(selector);
    const char *encoding = method_getTypeEncoding(method);
    char returnType = 'v';
    if (!XNASignatureStubbable(encoding, &returnType)) {
        if (XNAHookedCount < 40) {
            XNALog(@"skip [%@ %@] unsafe return %s", NSStringFromClass(cls), NSStringFromSelector(selector),
                   encoding ?: "?");
        }
        return;
    }
    if (action == XNAActionStubData && !XNAIsDataGetter(selectorName, method_getNumberOfArguments(method))) {
        return;
    }
    IMP original = method_getImplementation(method);
    IMP replacement = action == XNAActionDefuse ? XNADefuseIMP(original, returnType) : XNAStubForReturnType(returnType);
    if (!replacement || original == replacement) return;
    method_setImplementation(method, replacement);
    XNAHookedCount++;
    XNALog(@"%@ %@[%@ %@] %s", action == XNAActionDefuse ? @"defuse" : @"stub", isClassMethod ? @"+@" : @"-",
           NSStringFromClass(cls), NSStringFromSelector(selector), encoding);
}

static void XNAInstallIn(Class cls) {
    if (!cls || class_isMetaClass(cls) || !XNAClassIsAppOwned(cls)) return;
    const char *className = class_getName(cls);
    for (BOOL classMethod = NO;; classMethod = YES) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(classMethod ? object_getClass(cls) : cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            SEL selector = method_getName(methods[i]);
            XNAAction action = XNAActionForClass(className, sel_getName(selector));
            if (action != XNAActionNone) XNAHookMethod(cls, methods[i], classMethod, action);
        }
        free(methods);
        if (classMethod) break;
    }
}

static void XNAInstallAll(NSString *pass) {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSUInteger matched = 0;
    for (unsigned int i = 0; i < count; i++) {
        if (!XNAIsInterestingClassName(class_getName(classes[i]))) continue;
        matched++;
        XNAInstallIn(classes[i]);
    }
    free(classes);
    XNALog(@"pass %@: %u classes, %lu candidates, %lu hooks in %.0f ms", pass, count, (unsigned long)matched,
           (unsigned long)XNAHookedCount, (NSProcessInfo.processInfo.systemUptime - started) * 1000);
    XNAFlushLog();
}

__attribute__((constructor)) static void XrkNoAdEntry(void) {
    @autoreleasepool {
        XNALog(@"XrkNoAd attached to %@ / %@", NSProcessInfo.processInfo.processName,
               NSBundle.mainBundle.bundleIdentifier);
        XNAInstallAll(@"eager");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            XNAInstallAll(@"late");
        });
    }
}
