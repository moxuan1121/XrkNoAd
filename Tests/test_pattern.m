#import <Foundation/Foundation.h>
#import "XNAPattern.h"

static int failures = 0;

#define CHECK(cond) do { if (!(cond)) { failures++; printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

static const char *const verbs[] = {
    "loadAdData", "showAdInView", "startWithAppID:", "requestADInfoWithCompletion:", "getAdData",
    "fetchAd", "renderAd", "prepareToShow", "setUpWithConfig:", "configureWithAppId:", "registerAdapter:",
};

int main(void) {
    @autoreleasepool {
        CHECK(XNAMatchGlob("ATSplashAd", "*SplashAd"));
        CHECK(XNAMatchGlob("ATAdManager", "ATAdManager|ATInitModule"));
        CHECK(XNAMatchGlob("GDTSplashAd", "GDT*"));
        CHECK(!XNAMatchGlob("DownloadViewController", "AD*"));
        CHECK(!XNAMatchGlob("AddressBookViewController", "*Ad"));
        CHECK(!XNAMatchGlob("oad", "*ad"));

        const char *const adClasses[] = {
            "ATAdManager", "ATInitModule", "ATBanner", "ATInterstitial", "ATSplashManager", "ATSplash",
            "ADInfoManager", "ADInfoModel", "ADRule", "ADFullScreenViewController", "DeviceADTableViewCell",
            "HistoryADView", "ReserveCentralADView", "InsertAdManager", "TakuADManager", "WMADManager",
            "UMPADViewController", "UMPUnionAdSdk", "GADManager", "GADAppOpenAd", "MSBUSplash", "GDTSplashAd",
            "BaiduMobAdSplash", "CSJSplashAd", "BUSplashAd", "GDTSDKConfig", "BUAdSDKManager",
        };
        for (size_t i = 0; i < sizeof(adClasses) / sizeof(adClasses[0]); i++) {
            BOOL caught = XNAIsInterestingClassName(adClasses[i]);
            for (size_t v = 0; !caught && v < sizeof(verbs) / sizeof(verbs[0]); v++) {
                caught = XNAActionForClass(adClasses[i], verbs[v]) != XNAActionNone;
            }
            if (!caught) {
                failures++;
                printf("FAIL ad class not covered: %s\n", adClasses[i]);
            }
        }

        const char *const ignoredClasses[] = {
            "DownloadViewController", "AddressBookViewController", "DeviceOverviewTableViewCell",
            "QRCodeAuthConfirmViewController", "KVMVerifyVisitCodeViewController", "SSKeychain",
            "RDEditCommonadEditableView", "LoginViewController", "HomeViewController",
        };
        for (size_t i = 0; i < sizeof(ignoredClasses) / sizeof(ignoredClasses[0]); i++) {
            for (size_t v = 0; v < sizeof(verbs) / sizeof(verbs[0]); v++) {
                CHECK(XNAActionForClass(ignoredClasses[i], verbs[v]) == XNAActionNone);
            }
        }

        CHECK(XNAActionForClass("ATAdManager", "startWithAppID:appKey:error:") == XNAActionStub);
        CHECK(!XNAIsDataGetter("sharedInstance", 2));
        CHECK(XNAActionForClass("GDTSplashAd", "loadAd") == XNAActionStub);
        CHECK(XNAActionForClass("ADFullScreenViewController", "viewDidAppear:") == XNAActionDefuse);
        CHECK(XNAActionForClass("DeviceADTableViewCell", "layoutSubviews") == XNAActionDefuse);
        CHECK(XNAActionForClass("ADInfoManager", "setADInfoModel:") == XNAActionStubData);
        CHECK(XNAActionForClass("ADInfoManager", "adInfoModels") == XNAActionStubData);
        CHECK(XNAActionForClass("ATBanner", "dealloc") == XNAActionNone);
        CHECK(XNAActionForClass("ATBanner", "viewDidLoad") == XNAActionNone);

        CHECK(XNAIsDataGetter("adInfoModels", 2));
        CHECK(XNAIsDataGetter("getADRule", 2));
        CHECK(!XNAIsDataGetter("setADInfoModel:", 3));
        CHECK(!XNAIsDataGetter("updateWithJson:", 3));
        CHECK(XNAIsDataGetter("hasAdCache", 2));

        printf(failures ? "%d checks failed\n" : "pattern rules ok\n", failures);
        return failures ? 1 : 0;
    }
}
