from pathlib import Path
import datetime, hashlib, json, os, plistlib, shutil, subprocess
BASE = Path(__file__).resolve().parent
PROPOSAL = BASE.parent / 'thread-owner-adapter-r5'
ROOT = Path('/Users/palatis/.codex/worktrees/cook-owner-r2/Room in the Cart')
CANONICAL = Path('/Users/palatis/Room in the Cart')
PRODUCTS = BASE.parent / 'thread-owner-adapter-r2-execution/dd/Build/Products'
ENV = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', PYTHONDONTWRITEBYTECODE='1')
FLOOR = 8 * 1024**3
UID = '4C7FAE04-D40B-4ADC-8F75-1366C09B1695'
def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()
def tree(path):
    return {str(p.relative_to(path)): ({'symlink': os.readlink(p)} if p.is_symlink() else {'bytes': p.stat().st_size, 'sha256': sha(p)})
            for p in sorted(path.rglob('*')) if p.is_file() or p.is_symlink()}
def write(path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n'); temporary.replace(path)
def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def no_native():
    for line in subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True).splitlines():
        fields = line.strip().split(None, 1)
        assert len(fields) < 2 or Path(fields[1]).name not in ['xcodebuild', 'xctest'], 'Native lane occupied'
def preserved():
    receipt = json.loads((BASE / 'r4-preservation.json').read_text())
    prior = Path(receipt['originalFixturePath'])
    assert tree(BASE / 'prior-r4-products') == receipt['products'], 'R4 product clone changed'
    assert tree(BASE / 'prior-r4-result.xcresult') == receipt['result'], 'R4 result clone changed'
    assert tree(prior / 'native.xcresult') == receipt['result'], 'Original R4 result changed'
    for name, pin in receipt['metadata'].items():
        assert sha(prior / name) == pin['sha256'], name
        assert sha(BASE / 'prior-r4-receipts' / name) == pin['sha256'], name
    return True
def verify():
    assert sha(PROPOSAL / 'file-hashes.json') == '6b7da49637b15e32897c3d5e45625f7eaf3bbd0cb1625faf1d796eec205dc87c'
    for pin in json.loads((PROPOSAL / 'file-hashes.json').read_text())['files']:
        assert sha(PROPOSAL / pin['path']) == pin['sha256'], pin['path']
    for pin in json.loads((PROPOSAL / 'isolated-ios-candidate-manifest.json').read_text())['files']:
        assert sha(ROOT / pin['path']) == pin['sha256'], pin['path']
    for key in ['OS_ACTIVITY_MODE', 'OS_ACTIVITY_DT_MODE', 'DYLD_INSERT_LIBRARIES', 'XCTestConfigurationFilePath']:
        assert key not in ENV, 'Unexpected injected environment: ' + key
    execution = json.loads((BASE / 'execution-file-hashes.json').read_text())
    for pin in execution['files']: assert sha(BASE / pin['path']) == pin['sha256'], pin['path']
    assert sha(CANONICAL / 'scripts/check_ios_test_results.py') == execution['checkerSHA256']
    preserved(); return True
def disk(): assert shutil.disk_usage(BASE).free >= FLOOR, 'Reserved 8 GiB disk floor violated'
def toolchain():
    version = subprocess.check_output(['/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild', '-version'], env=ENV, text=True, timeout=30)
    info = plistlib.loads(Path('/Applications/Xcode.app/Contents/version.plist').read_bytes())
    return {'versionOutput': version, 'bundleVersion': info, 'developerDir': ENV['DEVELOPER_DIR']}
def runtime():
    root = subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'getenv', UID, 'SIMULATOR_ROOT'], env=ENV, text=True, timeout=30).strip()
    identity = plistlib.loads((Path(root) / 'System/Library/CoreServices/SystemVersion.plist').read_bytes())
    assert identity['ProductVersion'] == '26.2' and identity['ProductBuildVersion'] == '23C54'
    return {'udid': UID, 'simulatorRoot': root, 'systemVersion': identity}
