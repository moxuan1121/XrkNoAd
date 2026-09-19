#import "XNAPattern.h"
#import <pthread.h>
#import <stdlib.h>
#import <string.h>

typedef struct {
    const char *classes;
    const char *selectors;
    XNAAction action;
} XNARule;

// 前缀取自 App 自身符号表：AT* 是 TopOn，BU*/CSJ* 是穿山甲，GDT*/GAD* 是优量汇，MS*/SDM* 是美数，
// UMP* 是友盟 PUnion，WM*/Taku* 是 Taku，Baidu*/BDMob* 是百度，ISA*/IS*Ad* 是 IronSource AdQuality。
// 匹配区分大小写，且刻意不写 Ad*：业务侧有 AddDeviceViewController 这类以 Ad 开头的类名。
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

// 冷启动那次主线程扫描只挂这些类，其余的交给后台补扫。
// 前缀 "AD" 是 App 自己的广告宿主（ADFullScreen*、ADInfo*），片段则是各家 SDK 的开屏命名。
static const char *XNALaunchMarkers[] = { "Splash", "splash", "LaunchAd", "launchad", "AppOpenAd", "appopenad" };

#pragma mark - compiled matcher

// 通用通配匹配在 5 万多个类名上要跑 1 秒（v0.0.2 的开屏卡顿就是这么来的）。
// 这里先把每条规则按 '*' 出现的位置归类成前缀/后缀/包含/全等，匹配时只做一次字符位图
// 和几个 memcmp；只有 '*' 夹在中间的片段（IS*Ad*）才退回通用匹配。
typedef enum {
    XNATokPrefix = 0,
    XNATokSuffix,
    XNATokContains,
    XNATokExact,
    XNATokLoose,
} XNATokKind;

typedef struct {
    char *text;
    size_t length;
    unsigned char kind;
    char head;
} XNAToken;

typedef struct {
    XNAToken *tokens;
    size_t count;
    size_t capacity;
    unsigned char startHeads[16];  // 前缀/全等类片段要求的首字母
    unsigned char anyHeads[16];    // 后缀/包含类片段要求的字母
    unsigned char loose;           // 存在无法预筛的片段时置 1
} XNATokenSet;

static void XNABitSet(unsigned char *bits, char c) {
    if ((unsigned char)c < 128) bits[(unsigned char)c >> 3] |= (unsigned char)(1u << ((unsigned char)c & 7));
}

static BOOL XNABitGet(const unsigned char *bits, char c) {
    return (unsigned char)c < 128 && (bits[(unsigned char)c >> 3] & (1u << ((unsigned char)c & 7))) != 0;
}

static BOOL XNAAnyBit(const unsigned char *a, const unsigned char *b) {
    for (size_t i = 0; i < 16; i++) {
        if (a[i] & b[i]) return YES;
    }
    return NO;
}

static BOOL XNAAllBits(const unsigned char *need, const unsigned char *have) {
    for (size_t i = 0; i < 16; i++) {
        if ((need[i] & have[i]) != need[i]) return NO;
    }
    return YES;
}

// 名字里出现过哪些 ASCII 字符。整套规则都靠它做一次性排除，所以每个名字只扫这一遍。
static void XNANameLetters(const char *name, unsigned char *present) {
    memset(present, 0, 16);
    for (const char *c = name; *c; c++) XNABitSet(present, *c);
}

static char *XNACopy(const char *start, size_t length) {
    char *copy = malloc(length + 1);
    if (!copy) return NULL;
    memcpy(copy, start, length);
    copy[length] = '\0';
    return copy;
}

static void XNATokenSetAdd(XNATokenSet *set, const char *segment, size_t length) {
    if (set->count == set->capacity) {
        size_t capacity = set->capacity ? set->capacity * 2 : 32;
        XNAToken *tokens = realloc(set->tokens, capacity * sizeof(XNAToken));
        if (!tokens) return;
        set->tokens = tokens;
        set->capacity = capacity;
    }
    size_t begin = 0, end = length;
    BOOL lead = NO, trail = NO, inner = NO;
    if (end > begin && segment[begin] == '*') { lead = YES; begin++; }
    if (end > begin && segment[end - 1] == '*') { trail = YES; end--; }
    for (size_t i = begin; i < end; i++) {
        if (segment[i] == '*' || segment[i] == '?') inner = YES;
    }
    if (begin == end) inner = YES;

    XNAToken *token = &set->tokens[set->count];
    token->head = 0;
    if (inner) {
        token->kind = XNATokLoose;
        token->length = length;
        token->text = XNACopy(segment, length);
        if (!token->text) return;
        set->loose = 1;
    } else {
        token->kind = lead ? (trail ? XNATokContains : XNATokSuffix) : (trail ? XNATokPrefix : XNATokExact);
        token->length = end - begin;
        token->text = XNACopy(segment + begin, token->length);
        if (!token->text) return;
        token->head = token->text[0];
        // 前缀/全等只看首字母，后缀/包含要求这个名字里出现过那个字母。
        XNABitSet(token->kind == XNATokPrefix || token->kind == XNATokExact ? set->startHeads : set->anyHeads,
                  token->head);
    }
    set->count++;
}

static void XNATokenSetCompile(XNATokenSet *set, const char *alternatives) {
    memset(set, 0, sizeof(*set));
    for (const char *p = alternatives; p && *p;) {
        const char *bar = strchr(p, '|');
        size_t length = bar ? (size_t)(bar - p) : strlen(p);
        if (length) XNATokenSetAdd(set, p, length);
        if (!bar) break;
        p = bar + 1;
    }
}

typedef struct {
    XNATokenSet classes;
    XNATokenSet selectors;
    XNAAction action;
} XNACompiledRule;

// 开屏标记的字母集合：名字里连这几个字母都没凑齐，就不值得再跑一次 strstr。
#define XNALaunchMarkerCount (sizeof(XNALaunchMarkers) / sizeof(XNALaunchMarkers[0]))
static unsigned char XNALaunchMarkerLetters[XNALaunchMarkerCount][16];

#define XNARuleCount (sizeof(XNARules) / sizeof(XNARules[0]))
static XNACompiledRule XNACompiled[XNARuleCount];
static pthread_once_t XNACompileFlag = PTHREAD_ONCE_INIT;

static void XNACompileRules(void) {
    for (size_t i = 0; i < XNARuleCount; i++) {
        XNATokenSetCompile(&XNACompiled[i].classes, XNARules[i].classes);
        XNATokenSetCompile(&XNACompiled[i].selectors, XNARules[i].selectors);
        XNACompiled[i].action = XNARules[i].action;
    }
    for (size_t i = 0; i < XNALaunchMarkerCount; i++) {
        for (const char *c = XNALaunchMarkers[i]; *c; c++) XNABitSet(XNALaunchMarkerLetters[i], *c);
    }
}

static void XNAEnsureCompiled(void) {
    pthread_once(&XNACompileFlag, XNACompileRules);
}

static BOOL XNAMatchTokenSetMasked(const char *name, const XNATokenSet *set, const unsigned char *present) {
    if (!set->loose && !XNABitGet(set->startHeads, name[0]) && !XNAAnyBit(set->anyHeads, present)) return NO;
    if (!set->tokens) return NO;
    size_t nameLength = 0;
    for (const XNAToken *token = set->tokens, *end = token + set->count; token < end; token++) {
        switch (token->kind) {
            case XNATokLoose:
                if (XNAMatchGlob(name, token->text)) return YES;
                break;
            case XNATokPrefix:
                if (name[0] == token->head && strncmp(name, token->text, token->length) == 0) return YES;
                break;
            case XNATokExact:
                if (name[0] == token->head && strlen(name) == token->length &&
                    memcmp(name, token->text, token->length) == 0) return YES;
                break;
            case XNATokSuffix:
                if (!XNABitGet(present, token->head)) break;
                if (nameLength == 0) nameLength = strlen(name);
                if (nameLength >= token->length &&
                    memcmp(name + nameLength - token->length, token->text, token->length) == 0) return YES;
                break;
            default:
                if (!XNABitGet(present, token->head)) break;
                if (strstr(name, token->text)) return YES;
                break;
        }
    }
    return NO;
}

static BOOL XNAMatchTokenSet(const char *name, const XNATokenSet *set) {
    unsigned char present[16];
    XNANameLetters(name, present);
    return XNAMatchTokenSetMasked(name, set, present);
}

static BOOL XNASelectorForbidden(const char *selector) {
    for (size_t i = 0; i < sizeof(XNAForbiddenSelectors) / sizeof(XNAForbiddenSelectors[0]); i++) {
        if (strcmp(selector, XNAForbiddenSelectors[i]) == 0) return YES;
    }
    return NO;
}

BOOL XNAIsInterestingClassName(const char *name) {
    if (!name) return NO;
    XNAEnsureCompiled();
    for (size_t i = 0; i < XNARuleCount; i++) {
        if (XNAMatchTokenSet(name, &XNACompiled[i].classes)) return YES;
    }
    return NO;
}

BOOL XNAIsInterestingClassNameSlow(const char *name) {
    if (!name) return NO;
    for (size_t i = 0; i < XNARuleCount; i++) {
        if (XNAMatchGlob(name, XNARules[i].classes)) return YES;
    }
    return NO;
}

BOOL XNAIsPresentationSelector(const char *selector) {
    if (!selector || XNASelectorForbidden(selector)) return NO;
    XNAEnsureCompiled();
    for (size_t i = 0; i < XNARuleCount; i++) {
        if (XNAMatchTokenSet(selector, &XNACompiled[i].selectors)) return YES;
    }
    return NO;
}

BOOL XNAIsPresentationSelectorSlow(const char *selector) {
    if (!selector || XNASelectorForbidden(selector)) return NO;
    for (size_t i = 0; i < XNARuleCount; i++) {
        if (XNAMatchGlob(selector, XNARules[i].selectors)) return YES;
    }
    return NO;
}

static BOOL XNAIsLaunchMarkerAt(const char *name, const unsigned char *present) {
    for (size_t i = 0; i < XNALaunchMarkerCount; i++) {
        if (XNAAllBits(XNALaunchMarkerLetters[i], present) && strstr(name, XNALaunchMarkers[i])) return YES;
    }
    return NO;
}

// 冷启动主线程那道筛：命中规则表、而且名字像开屏宿主。两件事共用一次字符扫描。
BOOL XNAIsLaunchClassName(const char *name) {
    if (!name || !name[0]) return NO;
    XNAEnsureCompiled();
    unsigned char present[16];
    XNANameLetters(name, present);
    // 规则表只有一条，且它的动作就是 defuse；加规则时这里的循环要一并扩。
    for (size_t i = 0; i < XNARuleCount; i++) {
        if (!XNAMatchTokenSetMasked(name, &XNACompiled[i].classes, present)) continue;
        if (name[0] == 'A' && name[1] == 'D') return YES;  // App 自己的广告宿主：ADFullScreen*、ADInfo*
        if (XNAIsLaunchMarkerAt(name, present)) return YES;
    }
    return NO;
}

XNAAction XNAActionForClass(const char *className, const char *selector) {
    if (!className || !selector || XNASelectorForbidden(selector)) return XNAActionNone;
    XNAEnsureCompiled();
    for (size_t i = 0; i < XNARuleCount; i++) {
        if (XNAMatchTokenSet(className, &XNACompiled[i].classes) &&
            XNAMatchTokenSet(selector, &XNACompiled[i].selectors)) return XNACompiled[i].action;
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
