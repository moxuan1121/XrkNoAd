"""Mirror of Engine/XNAPattern.m so the rule table can be reviewed before a device test.

Reads the real #define strings out of the source, replays the C glob/action logic,
runs the same assertions as Tests/test_pattern.m, and reports coverage over a class
dump of the shipped binary (piped on stdin, one class name per line).
"""
import re
import sys

src = open('Engine/XNAPattern.m', encoding='utf-8').read()
src = re.sub(r'\\\n\s*', ' ', src)
# join every string literal that belongs to one #define
defs = {m.group(1): ''.join(re.findall(r'"([^"]*)"', m.group(2)))
        for m in re.finditer(r'#define\s+(XNA_\w+)\s+(.*?)(?=\n\S|\Z)', src, re.S)
        if '"' in m.group(2)}


def between(pattern):
    return re.search(pattern, src, re.S).group(1)


def resolve(token):
    return defs[token] if token in defs else token.strip('"')


RULES = [(resolve(c), resolve(s), a) for c, s, a in
         re.findall(r'\{\s*(XNA_\w+|"[^"]*"),\s*(XNA_\w+|"[^"]*"),\s*(XNAAction\w+)\s*\}',
                    between(r'static const XNARule XNARules\[\] = \{(.*?)\};'))]
FORBIDDEN = [x.strip().strip('",') for x in
             between(r'XNAForbiddenSelectors\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]
SPLASH = [x.strip().strip('",') for x in
          between(r'XNASplashMarkers\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]

PRESENT = ['viewDidAppear:', 'viewWillAppear:', 'layoutSubviews', 'didMoveToWindow', 'showAdInView', 'show',
           'presentAd', 'renderAd', 'makeKeyAndVisible', 'viewDidLayoutSubviews']
# v0.0.1 stubbed these and the host app froze on the splash screen waiting for a callback.
LOADING = ['loadAd', 'loadAdData', 'loadADInfo', 'startWithAppID:', 'start', 'setUpWithConfig:',
           'configureWithAppId:', 'registerAdapter:', 'requestADInfoWithCompletion:', 'fetchAd',
           'prepareToShow', 'getAdData', 'setADInfoModel:']

AD_CLASSES = ['ATAdManager', 'ATBanner', 'ATInterstitial', 'ATSplashManager', 'ATSplash', 'ATNativeADView',
              'ADInfoManager', 'ADInfoModel', 'ADRule', 'ADFullScreenViewController', 'DeviceADTableViewCell',
              'HistoryADView', 'ReserveCentralADView', 'InsertAdManager', 'InsertAdBottomView', 'TakuADManager',
              'WMADManager', 'UMPADViewController', 'GADManager', 'GADAppOpenAd', 'GDTSplashAd', 'GDTSDKConfig',
              'BaiduMobAdSplash', 'CSJSplashAd', 'BUSplashAd', 'SDMTSplashViewController', 'MSADShowViewController',
              'ISAdQualityUIViewController', 'WMADSplashAdInfo', 'DiscoverAdTableViewCell', 'AdPlaceholderView']

# AddDevice*/AddHost* 这类以 Ad 开头的业务类是最容易踩的回归。
IGNORED = ['DownloadViewController', 'AddressBookViewController', 'AddDeviceViewController', 'AddHostView',
           'AddNewHostViewController', 'AccountAddViewController', 'CMDListViewAddCommandButton',
           'DeviceOverviewTableViewCell', 'MainTabBarController', 'QRCodeAuthConfirmViewController',
           'KVMVerifyVisitCodeViewController', 'SSKeychain', 'LoginViewController', 'HomeViewController',
           'RDEditCommonadEditableView', 'HMDBUCrashThreadInfo', 'EBAppLogDatabaseAdditions']


def glob(name, pat):
    while pat:
        if pat[0] == '|':
            return glob(name, pat[1:])
        if pat[0] == '*':
            rest = pat[1:]
            if not rest or rest[0] == '|':
                return True
            return any(glob(name[i:], rest) for i in range(len(name) + 1))
        if not name or (pat[0] != '?' and pat[0] != name[0]):
            return False
        name, pat = name[1:], pat[1:]
    return not name


def any_glob(name, pats):
    return any(glob(name, p) for p in pats.split('|'))


def action_for(cls, sel):
    if sel in FORBIDDEN:
        return 'None'
    for cpat, spat, act in RULES:
        if any_glob(cls, cpat) and any_glob(sel, spat):
            return act
    return 'None'


def is_interesting(cls):
    return any(any_glob(cls, c) for c, _, _ in RULES)


def is_splash(cls):
    return any(m in cls for m in SPLASH)


def assertions():
    bad = []

    def ck(cond, label):
        if not cond:
            bad.append(label)

    ck(any_glob('ATSplashAd', '*SplashAd|*Splash*'), 'glob-splash')
    ck(any_glob('ATAdManager', 'ATAdManager|ATInitModule'), 'glob-alt')
    ck(not any_glob('DownloadViewController', 'AD*'), 'glob-download')
    ck(not any_glob('AddressBookViewController', '*Ad'), 'glob-address')
    for c in AD_CLASSES:
        ck(is_interesting(c) or any(action_for(c, s) != 'None' for s in PRESENT), 'cover ' + c)
    for c in IGNORED:
        ck(not is_interesting(c), 'ignore-class ' + c)
        for s in PRESENT:
            ck(action_for(c, s) == 'None', f'ignore {c}/{s}')
    for c in ('ATAdManager', 'GDTSplashAd', 'ADInfoManager', 'InsertAdManager'):
        for s in LOADING:
            ck(action_for(c, s) == 'None', f'never-hook {c}/{s}')
    ck(action_for('ADFullScreenViewController', 'viewDidAppear:') == 'XNAActionDefuse', 'defuse-vc')
    ck(action_for('DeviceADTableViewCell', 'layoutSubviews') == 'XNAActionDefuse', 'defuse-cell')
    ck(action_for('BUSplashView', 'didMoveToWindow') == 'XNAActionDefuse', 'defuse-view')
    ck(action_for('GADAppOpenAd', 'show') == 'XNAActionDefuse', 'defuse-show')
    ck(action_for('ATBanner', 'dealloc') == 'None', 'forbidden-dealloc')
    ck(action_for('ATBanner', 'viewDidLoad') == 'None', 'forbidden-viewDidLoad')
    ck(is_splash('BUSplashAd') and not is_splash('GADAppOpenAd'), 'splash-marker')
    return bad


def main():
    print('rules:', [(c[:40] + '...', s, a) for c, s, a in RULES])
    bad = assertions()
    for b in bad:
        print('FAIL', b)
    classes = [l.strip() for l in sys.stdin if l.strip()]
    if classes:
        hits = {}
        for c in classes:
            actions = sorted({action_for(c, s) for s in PRESENT + LOADING + ['adInfos']} - {'None'})
            if actions:
                hits[c] = actions
        print(f'corpus: {len(hits)} / {len(classes)} classes would be scanned', file=sys.stderr)
        with open('rule_hits.txt', 'w', encoding='utf-8') as fh:
            for c in sorted(hits):
                fh.write(f'{c} {hits[c]}\n')
    print('ASSERTIONS', 'FAILED ' + str(len(bad)) if bad else 'ok')
    sys.exit(1 if bad else 0)


main()
