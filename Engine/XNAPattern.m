#import "XNAPattern.h"
#import <string.h>

typedef struct {
    const char *classes;
    const char *selectors;
    XNAAction action;
} XNARule;

// 前缀取自 App 自身符号表：AT* 是 TopOn，BU*/CSJ* 是穿山甲，GDT*/GAD* 是优量汇，MS*/SDM* 是美数，
// UMP* 是友盟 PUnion，WM*/Taku* 是 Taku，Baidu*/BDMob* 是百度，ISA*/IS*Ad* 是 IronSource AdQuality。
// 匹配区分大小写，且刻意不写 Ad*：业务侧有 AddDeviceViewController 这类以 Ad 开头的类名。
// 三段拼接：广告 SDK 自带的类、名字里带广告术语的类、App 自己的广告界面。
#define XNA_AD_CLASSES                                                         \
    "AT*|BU*|CSJ*|GDT*|GAD*|GAM*|GMA*|MS*|UMP*|UMUnion*|UADS*|Taku*|WM*|"      \
    "Baidu*|BDMob*|Smartdigimkt*|SDM*|MeiShu*|KSAd*|KSAD*|TopOn*|Klevin*|"     \
    "Octopus*|beizi*|HyBid*|FAD*|FBAd*|FBInterstitial*|FBRewarded*|CHB*|DTB*|" \
    "ALAd*|BidMachine*|ISA*|ISDK*|ISImpression*|IS*Ad*|"                       \
    "*AD*|*Ad|*Ads|*Splash*|*InsertAd*|*Interstitial*|*Intersititial*|"        \
    "*BannerAd*|*NativeAd*|*NativeAD*|*RewardedVideo*|*RewardVideo*|*AppOpenAd*|" \
    "*AdView*|*ADView*|*AdManager*|*ADManager*|*AdLoader*|*AdModel*|*ADModel*|" \
    "*AdInfo*|*ADInfo*|*AdSlot*|*ADSlot*|*AdContainer*|*AdSource*|*Mediation*|" \
    "*AdRender*|*ADRender*|*AdDispatcher*|*AdProxy*|*AdAdapter*|*AdCustomEvent*|" \
    "AD*|ADTEST*|ADTest*|ADFullScreenViewController|ADTestViewController|"     \
    "DeviceADTableViewCell|HistoryADView|ReserveCentralADView|InsertAdBottomView|" \
    "DiscoverAdTableViewCell|AdPlaceholderView|AdModel|Advert"

// 只挂「展示」这一层：原实现照常跑完，SDK 的加载、倒计时、关闭回调都不被截断，
// 宿主 App 的开屏流程因此不会卡住（v0.0.1 直接 stub load*/start* 就是把这条链掐断了）。
#define XNA_PRESENT_SEL                                                          \
    "viewDidAppear:|viewWillAppear:|viewDidLayoutSubviews|didMoveToWindow|"      \
    "willMoveToWindow:|layoutSubviews|makeKeyAndVisible|show*|present*|render*"

static const XNARule XNARules[] = {
    { XNA_AD_CLASSES, XNA_PRESENT_SEL, XNAActionDefuse },
};

static const char *XNAForbiddenSelectors[] = {
    "load", "initialize", "dealloc", ".cxx_destruct", "forwardInvocation:", "class",
    "methodSignatureForSelector:", "respondsToSelector:", "isKindOfClass:", "release", "retain",
    "copy", "copyWithZone:", "init", "new", "viewDidLoad", "encodeWithCoder:", "initWithCoder:", "description",
};

static const char *XNASplashMarkers[] = { "Splash", "splash", "SPLASH", "LaunchAd", "launchad" };

BOOL XNAIsInterestingClassName(const char *name) {
    if (!name) return NO;
    for (size_t r = 0; r < sizeof(XNARules) / sizeof(XNARules[0]); r++) {
        if (XNAMatchGlob(name, XNARules[r].classes)) return YES;
    }
    return NO;
}

XNAAction XNAActionForClass(const char *className, const char *selector) {
    if (!className || !selector) return XNAActionNone;
    for (size_t i = 0; i < sizeof(XNAForbiddenSelectors) / sizeof(XNAForbiddenSelectors[0]); i++) {
        if (strcmp(selector, XNAForbiddenSelectors[i]) == 0) return XNAActionNone;
    }
    for (size_t r = 0; r < sizeof(XNARules) / sizeof(XNARules[0]); r++) {
        if (XNAMatchGlob(className, XNARules[r].classes) && XNAMatchGlob(selector, XNARules[r].selectors)) {
            return XNARules[r].action;
        }
    }
    return XNAActionNone;
}

BOOL XNAIsSplashLikeName(const char *name) {
    if (!name) return NO;
    for (size_t i = 0; i < sizeof(XNASplashMarkers) / sizeof(XNASplashMarkers[0]); i++) {
        if (strstr(name, XNASplashMarkers[i])) return YES;
    }
    return NO;
}
