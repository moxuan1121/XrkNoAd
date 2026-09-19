#import <Foundation/Foundation.h>
#import "XNAPattern.h"
#import <stdio.h>

static int failures = 0;

#define CHECK(cond) do { if (!(cond)) { failures++; printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

// 展示层选择器：这些才允许被挂钩。
static const char *const presentSelectors[] = {
    "viewDidAppear:", "viewWillAppear:", "layoutSubviews", "didMoveToWindow", "showAdInView", "show",
    "presentAd", "renderAd", "makeKeyAndVisible", "viewDidLayoutSubviews",
};

// v0.0.1 就是把这一层钩掉了，导致宿主 App 等不到广告回调、卡在开屏。现在必须一个都不命中。
static const char *const lifecycleSelectors[] = {
    "loadAd", "loadAdData", "loadADInfo", "startWithAppID:", "start", "setUpWithConfig:", "configureWithAppId:",
    "registerAdapter:", "requestADInfoWithCompletion:", "fetchAd", "prepareToShow", "getAdData", "setADInfoModel:",
};

static BOOL AnyPresentHit(const char *className) {
    for (size_t i = 0; i < sizeof(presentSelectors) / sizeof(presentSelectors[0]); i++) {
        if (XNAActionForClass(className, presentSelectors[i]) != XNAActionNone) return YES;
    }
    return NO;
}

int main(void) {
    @autoreleasepool {
        CHECK(XNAMatchGlob("ATSplashAd", "*SplashAd|*Splash*"));
        CHECK(XNAMatchGlob("ATAdManager", "ATAdManager|ATInitModule"));
        CHECK(XNAMatchGlob("GDTSplashAd", "GDT*"));
        CHECK(!XNAMatchGlob("DownloadViewController", "AD*"));
        CHECK(!XNAMatchGlob("AddressBookViewController", "*Ad"));
        CHECK(!XNAMatchGlob("oad", "*AD"));
        CHECK(XNAMatchGlob("BUSplashAd", "AT*Ad*|BU*|CSJ*"));

        const char *const adClasses[] = {
            "ATAdManager", "ATBanner", "ATInterstitial", "ATSplashManager", "ATSplash", "ATNativeADView",
            "ADInfoManager", "ADInfoModel", "ADRule", "ADFullScreenViewController", "DeviceADTableViewCell",
            "HistoryADView", "ReserveCentralADView", "InsertAdManager", "InsertAdBottomView", "TakuADManager",
            "WMADManager", "UMPADViewController", "GADManager", "GADAppOpenAd", "GDTSplashAd", "GDTSDKConfig",
            "BaiduMobAdSplash", "CSJSplashAd", "BUSplashAd", "SDMTSplashViewController", "MSADShowViewController",
            "ISAdQualityUIViewController", "WMADSplashAdInfo", "DiscoverAdTableViewCell", "AdPlaceholderView",
        };
        for (size_t i = 0; i < sizeof(adClasses) / sizeof(adClasses[0]); i++) {
            if (!XNAIsInterestingClassName(adClasses[i]) && !AnyPresentHit(adClasses[i])) {
                failures++;
                printf("FAIL ad class not covered: %s\n", adClasses[i]);
            }
        }

        // 业务类：既不能进候选表，也不能被挂任何展示层钩子。AddDevice* 这类以 Ad 开头的名字是重点回归项。
        const char *const ignoredClasses[] = {
            "DownloadViewController", "AddressBookViewController", "AddDeviceViewController", "AddHostView",
            "AddNewHostViewController", "AccountAddViewController", "CMDListViewAddCommandButton",
            "DeviceOverviewTableViewCell", "MainTabBarController", "QRCodeAuthConfirmViewController",
            "KVMVerifyVisitCodeViewController", "SSKeychain", "LoginViewController", "HomeViewController",
            "RDEditCommonadEditableView", "HMDBUCrashThreadInfo", "EBAppLogDatabaseAdditions",
        };
        for (size_t i = 0; i < sizeof(ignoredClasses) / sizeof(ignoredClasses[0]); i++) {
            CHECK(!XNAIsInterestingClassName(ignoredClasses[i]));
            for (size_t s = 0; s < sizeof(presentSelectors) / sizeof(presentSelectors[0]); s++) {
                CHECK(XNAActionForClass(ignoredClasses[i], presentSelectors[s]) == XNAActionNone);
            }
        }

        for (size_t i = 0; i < sizeof(lifecycleSelectors) / sizeof(lifecycleSelectors[0]); i++) {
            CHECK(XNAActionForClass("ATAdManager", lifecycleSelectors[i]) == XNAActionNone);
            CHECK(XNAActionForClass("GDTSplashAd", lifecycleSelectors[i]) == XNAActionNone);
            CHECK(XNAActionForClass("ADInfoManager", lifecycleSelectors[i]) == XNAActionNone);
            CHECK(XNAActionForClass("InsertAdManager", lifecycleSelectors[i]) == XNAActionNone);
        }

        CHECK(XNAActionForClass("ADFullScreenViewController", "viewDidAppear:") == XNAActionDefuse);
        CHECK(XNAActionForClass("DeviceADTableViewCell", "layoutSubviews") == XNAActionDefuse);
        CHECK(XNAActionForClass("BUSplashView", "didMoveToWindow") == XNAActionDefuse);
        CHECK(XNAActionForClass("GADAppOpenAd", "show") == XNAActionDefuse);
        CHECK(XNAActionForClass("ATBanner", "dealloc") == XNAActionNone);
        CHECK(XNAActionForClass("ATBanner", "viewDidLoad") == XNAActionNone);
        CHECK(XNAActionForClass("ATBanner", "class") == XNAActionNone);

        CHECK(XNAIsSplashLikeName("BUSplashAd"));
        CHECK(XNAIsSplashLikeName("SDMTSplashViewController"));
        CHECK(!XNAIsSplashLikeName("InsertAdManager"));
        CHECK(!XNAIsSplashLikeName("GADAppOpenAd"));

        // 选择器：快速匹配必须和通用通配匹配一字不差（禁用名单两边都有）。
        const char *const selectorCorpus[] = {
            "viewDidAppear:", "viewWillAppear:", "viewDidLayoutSubviews", "didMoveToWindow", "willMoveToWindow:",
            "layoutSubviews", "makeKeyAndVisible", "show", "showAd", "showInView:", "presentAd", "renderAd",
            "loadAd", "loadAdData", "startWithAppID:", "setADInfoModel:", "dealloc", "init", "class",
            "respondsToSelector:", "viewDidLoad", "description", "hidden", "setHidden:", "shareInstance",
        };
        for (size_t i = 0; i < sizeof(selectorCorpus) / sizeof(selectorCorpus[0]); i++) {
            CHECK(XNAIsPresentationSelector(selectorCorpus[i]) == XNAIsPresentationSelectorSlow(selectorCorpus[i]));
        }

        // 类名：拿真机二进制的类名表回归，快速路径和逐条通配匹配不能有半个字的分歧。
        NSString *corpusPath = ProcessInfo.processInfo.arguments.count > 1
                                   ? ProcessInfo.processInfo.arguments[1]
                                   : @"Tests/corpus_classes.txt";
        NSString *corpus = [NSString stringWithContentsOfFile:corpusPath encoding:NSUTF8StringEncoding error:NULL];
        if (!corpus) {
            printf("SKIP corpus %s (fast matcher not regression-checked)\n", corpusPath.UTF8String);
        } else {
            CHECK(XNAIsPresentationSelector("viewDidAppear:"));
            NSArray<NSString *> *names = [corpus componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
            NSUInteger interesting = 0, launch = 0, divergence = 0, missingLaunch = 0;
            for (NSString *name in names) {
                if (name.length == 0) continue;
                const char *utf8 = name.UTF8String;
                if (XNAIsInterestingClassName(utf8) != XNAIsInterestingClassNameSlow(utf8)) {
                    divergence++;
                    if (divergence < 10) printf("FAIL fast/slow mismatch: %s\n", utf8);
                }
                if (!XNAIsInterestingClassName(utf8)) {
                    CHECK(!XNAIsLaunchClassName(utf8));
                    continue;
                }
                interesting++;
                if (XNAIsLaunchClassName(utf8)) {
                    launch++;
                } else if (XNAIsSplashLikeName(utf8) || [name hasPrefix:@"AD"]) {
                    missingLaunch++;
                    if (missingLaunch < 10) printf("FAIL launch-critical class missed: %s\n", utf8);
                }
            }
            CHECK(divergence == 0);
            CHECK(missingLaunch == 0);
            // 冷启动主线程只挂 launch 这一批，太多就说明那道预筛没起作用。
            CHECK(launch < 400);
            printf("corpus: %lu interesting (%lu launch) of %lu classes\n", (unsigned long)interesting,
                   (unsigned long)launch, (unsigned long)names.count);
        }

        printf(failures ? "%d checks failed\n" : "pattern rules ok\n", failures);
        return failures ? 1 : 0;
    }
}
