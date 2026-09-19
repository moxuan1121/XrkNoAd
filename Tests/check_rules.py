"""Mirror of Engine/XNAPattern.m so the rule table can be reviewed before a device test.

Reads the real #define strings out of the source, replays the C glob/action logic,
runs the same assertions as Tests/test_pattern.m, and reports coverage over a class
dump of the shipped binary (piped on stdin, one class name per line).
"""
import re, sys

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
FORBIDDEN = [x.strip().strip('",') for x in between(r'XNAForbiddenSelectors\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]
DATA_PREFIXES = [x.strip().strip('",') for x in between(r'XNADataGetterPrefixes\[\] = \{(.*?)\};').split(',') if x.strip().startswith('"')]

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
    if any(sel == f for f in FORBIDDEN):
        return 'None'
    for cpat, spat, act in RULES:
        if any_glob(cls, cpat) and any_glob(sel, spat):
            return act
    return 'None'

def is_interesting(cls):
    return any(any_glob(cls, c) for c, _, _ in RULES)

def is_data_getter(sel, argc=2):
    return argc == 2 and any(sel.startswith(p) for p in DATA_PREFIXES)

VERBS = ['loadAdData', 'showAdInView', 'startWithAppID:', 'requestADInfoWithCompletion:', 'getAdData',
         'fetchAd', 'renderAd', 'prepareToShow', 'setUpWithConfig:', 'configureWithAppId:', 'registerAdapter:']

AD_CLASSES = ['ATAdManager', 'ATInitModule', 'ATBanner', 'ATInterstitial', 'ATSplashManager', 'ATSplash',
              'ADInfoManager', 'ADInfoModel', 'ADRule', 'ADFullScreenViewController', 'DeviceADTableViewCell',
              'HistoryADView', 'ReserveCentralADView', 'InsertAdManager', 'TakuADManager', 'WMADManager',
              'UMPADViewController', 'UMPUnionAdSdk', 'GADManager', 'GADAppOpenAd', 'MSBUSplash', 'GDTSplashAd',
              'BaiduMobAdSplash', 'CSJSplashAd', 'BUSplashAd', 'GDTSDKConfig', 'BUAdSDKManager']

IGNORED = ['DownloadViewController', 'AddressBookViewController', 'DeviceOverviewTableViewCell',
           'QRCodeAuthConfirmViewController', 'KVMVerifyVisitCodeViewController', 'SSKeychain',
           'RDEditCommonadEditableView', 'LoginViewController', 'HomeViewController']

def assertions():
    bad = []
    def ck(cond, label):
        if not cond:
            bad.append(label)
    ck(glob('ATSplashAd', '*SplashAd'), 'glob1')
    ck(glob('GDTSplashAd', 'GDT*'), 'glob2')
    ck(not glob('DownloadViewController', 'AD*'), 'glob3')
    ck(not glob('AddressBookViewController', '*Ad'), 'glob4')
    for c in AD_CLASSES:
        ck(is_interesting(c) or any(action_for(c, v) != 'None' for v in VERBS), 'cover ' + c)
    for c in IGNORED:
        for v in VERBS:
            ck(action_for(c, v) == 'None', f'ignore {c}/{v}')
    ck(action_for('ATAdManager', 'startWithAppID:appKey:error:') == 'XNAActionStub', 'tostart')
    ck(not is_data_getter('sharedInstance'), 'shared')
    ck(action_for('GDTSplashAd', 'loadAd') == 'XNAActionStub', 'loadad')
    ck(action_for('ADFullScreenViewController', 'viewDidAppear:') == 'XNAActionDefuse', 'defuse')
    ck(action_for('DeviceADTableViewCell', 'layoutSubviews') == 'XNAActionDefuse', 'defusecell')
    ck(action_for('ADInfoManager', 'adInfoModels') == 'XNAActionStubData', 'data')
    ck(is_data_getter('adInfoModels') and not is_data_getter('setADInfoModel:', 3), 'getter')
    return bad

def main():
    bad = assertions()
    for b in bad:
        print('FAIL', b)
    classes = [l.strip() for l in sys.stdin if l.strip()]
    if classes:
        hits = {}
        for c in classes:
            actions = {action_for(c, v) for v in VERBS + ['viewDidAppear:', 'layoutSubviews', 'adInfos']} - {'None'}
            if actions:
                hits[c] = sorted(actions)
        print(f'corpus: {len(hits)} / {len(classes)} classes would be scanned', file=sys.stderr)
        with open('rule_hits.txt', 'w', encoding='utf-8') as fh:
            for c in sorted(hits):
                fh.write(f'{c} {hits[c]}\n')
    print('ASSERTIONS', 'FAILED ' + str(len(bad)) if bad else 'ok')
    sys.exit(1 if bad else 0)

main()
