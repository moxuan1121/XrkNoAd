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

        printf(failures ? "%d checks failed\n" : "pattern rules ok\n", failures);
        return failures ? 1 : 0;
    }
}
