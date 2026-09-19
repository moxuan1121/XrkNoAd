#import "XNAPattern.h"
#import <objc/runtime.h>
#import <string.h>

typedef struct {
    const char *classes;
    const char *selectors;
    XNAAction action;
} XNARule;

#define XNA_AD_NAMES \
    "AT*|BU*|CSJ*|GDT*|GAD*|MS*|UMP*|UMUnion*|UADS*|Taku*|WM*|Baidu*|Smartdigimkt*|KSAd*|KSAD*|" \
    "TopOn*|Klevin*|Octopus*|beizi*|BZ*|IS*|ISA*|AD*|*AD*|*Ad|*Ads|*AD|" \
    "*AdManager|*ADManager|*SplashAd|*BannerAd|*InterstitialAd|*IntersititialAd|*NativeAd|*NativeAD|" \
    "*RewardedVideoAd|*AppOpenAd|*AdLoader|*AdModel|*ADModel|*AdInfo|*ADInfo|*InsertAd*|*AdSlot|*ADSlot"

#define XNA_SDK_INIT_SEL "start*|setUp*|setup*|init*|configure*|register*|load*Config*|request*Config*"

#define XNA_AD_VERB_SEL "load*|show*|fetch*|request*|render*|prepare*|getAd*|start*"

#define XNA_APP_DATA "ADInfo*|ADRule|*AdManager|*ADManager|InsertAdManager|TakuADManager|WMADManager"

#define XNA_AD_UI \
    "ADFullScreenViewController|ADTestViewController|ADTESTTableViewCell|DeviceADTableViewCell|HistoryADView|" \
    "ReserveCentralADView|*AdViewController|*ADViewController|*SplashViewController|*InterstitialViewController|" \
    "ATAlertViewController|ATAccidentalClickView"

#define XNA_AD_UI_SEL "viewDidAppear:|viewWillAppear:|layoutSubviews|didMoveToWindow|showAd*"

static const XNARule XNARules[] = {
    { XNA_AD_NAMES, XNA_SDK_INIT_SEL, XNAActionStub },
    { XNA_AD_NAMES, XNA_AD_VERB_SEL, XNAActionStub },
    { XNA_APP_DATA, "*", XNAActionStubData },
    { XNA_AD_UI, XNA_AD_UI_SEL, XNAActionDefuse },
};

static const char *XNAForbiddenSelectors[] = {
    "load", "initialize", "dealloc", ".cxx_destruct", "forwardInvocation:", "class",
    "methodSignatureForSelector:", "respondsToSelector:", "isKindOfClass:", "release", "retain",
    "copy", "copyWithZone:", "init", "new", "viewDidLoad", "encodeWithCoder:", "initWithCoder:", "description",
};

static const char *XNADataGetterPrefixes[] = {
    "get", "fetch", "ad", "AD", "current", "request", "load", "is", "has",
};

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

BOOL XNAIsDataGetter(const char *selector, NSUInteger argumentCount) {
    if (!selector || argumentCount != 2) return NO;
    for (size_t i = 0; i < sizeof(XNADataGetterPrefixes) / sizeof(XNADataGetterPrefixes[0]); i++) {
        if (!strncmp(selector, XNADataGetterPrefixes[i], strlen(XNADataGetterPrefixes[i]))) return YES;
    }
    return NO;
}
