"""Frozen source/tool/profile contracts and portable file custody; no import-time I/O."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time
import uuid
from .support import require, sha, manifest, modes, atomic_json, launcher_identity

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CONDITION = '#if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)'
FLAG = 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) RELEASE APP_SIGNPOST_CAPTURE_CONTROL'
SOURCE_PATHS = ('ios', 'scripts', 'shared', 'config', '.github/workflows/ios-performance.yml')
PRODUCT_METADATA = {'performance-plan-producer.json', 'app-observation-producer.json'}


def read(path, cap=8*1024**2):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= cap, 'JSON_shape_or_cap:'+str(path))
    return json.loads(path.read_bytes())


def frozen():
    value = read(HERE/'contract.json')
    for name, digest in value['files'].items():
        require(sha(ROOT/name) == digest, 'frozen_source_changed:'+name)
    return value


def snapshot(folder, cap=256*1024**2, files=4096):
    folder = Path(folder)
    entries = list(folder.rglob('*'))
    require(folder.is_dir() and not folder.is_symlink() and len(entries) <= files, 'snapshot_root_or_count')
    require(all(not p.is_symlink() and (p.is_file() or p.is_dir()) for p in entries), 'snapshot_links')
    require(sum(p.stat().st_size for p in entries if p.is_file()) <= cap, 'snapshot_bytes')
    return {'files': manifest(folder), 'modes': modes(folder)}


def selected_snapshot(root, names):
    root = Path(root).resolve(); result = {'files':{}, 'modes':{}}
    require(len(names) <= 8192, 'source_count')
    total = 0
    for name in sorted(names):
        path = root/name
        require(not Path(name).is_absolute() and '..' not in Path(name).parts and path.is_file()
                and path.resolve() == path and path.is_relative_to(root), 'source_path')
        total += path.stat().st_size; require(total <= 128*1024**2, 'source_bytes')
        result['files'][name] = sha(path); result['modes'][name] = path.stat().st_mode & 0o777
    return result


def source_snapshot():
    result = subprocess.run(['git','ls-files','-z','--',*SOURCE_PATHS], cwd=ROOT,
                            capture_output=True, check=True, timeout=15)
    require(len(result.stdout) <= 2*1024**2, 'source_inventory_cap')
    names = result.stdout.decode().rstrip('\0').split('\0')
    require(names and len(names) == len(set(names)), 'source_inventory')
    # Include the reviewed new modules before git add as well as in the committed CI checkout.
    names=sorted(set(names)|set(frozen()['files'])|{'scripts/app_scroll_observation/contract.json'})
    return selected_snapshot(ROOT, names)


def products_snapshot(root):
    value = snapshot(root,512*1024**2,8192)
    return {kind:{k:v for k,v in rows.items() if k not in PRODUCT_METADATA} for kind,rows in value.items()}


def tools(developer):
    developer = Path(developer).resolve(); contract = frozen()
    version = plistlib.loads((developer.parent/'version.plist').read_bytes())
    require(version['CFBundleShortVersionString']=='27.1' and version['ProductBuildVersion']=='27A9275','exact_Xcode')
    sdk = (developer/'Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk').resolve()
    settings = plistlib.loads((sdk/'SDKSettings.plist').read_bytes())
    require(settings['Version']=='27.1' and settings['CanonicalName']=='iphonesimulator27.1','exact_SDK')
    require(sha(sdk/'SDKSettings.plist')==contract['qualifiedSDKSettingsSHA256'],'qualified_SDK_metadata_changed')
    result = {}
    for name,relative in {'xcodebuild':'usr/bin/xcodebuild','xctrace':'usr/bin/xctrace','simctl':'usr/bin/simctl',
                         'xcresulttool':'usr/bin/xcresulttool','swift-frontend':'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend'}.items():
        path=developer/relative; require(path.is_file() and not path.is_symlink(),'literal_tool:'+name)
        result[name]={'path':str(path),'sha256':sha(path)}
    for name,digest in contract['qualifiedToolHashes'].items(): require(result[name]['sha256']==digest,'qualified_tool_changed:'+name)
    # The public simctl entrypoint is a launcher; bind its actual executable too.
    lines=Path(result['simctl']['path']).read_text().splitlines()
    match=re.fullmatch(r'exec "([^"]+)" "\$\{@\}"',lines[-1]); require(match is not None,'simctl_launcher')
    actual=Path(match[1]);result['simctl'].update(executable=str(actual),executableSHA256=sha(actual))
    launcher_identity(result['simctl']['path'],result['simctl']['sha256'],str(actual),sha(actual))
    result.update(developer=str(developer),SDKROOT=str(sdk),SDKSettingsSHA256=sha(sdk/'SDKSettings.plist'),
                  versionPlistSHA256=sha(developer.parent/'version.plist'),xcode='Xcode 27.1\nBuild version 27A9275')
    return result


def verify_tools(value):
    require(tools(value['developer'])==value,'tool_or_SDK_changed')


def environment(runner):
    import platform
    from check_ios_performance_environment import runner_environment
    toolchain=runner.tools['xcodebuild']; device=os.environ['SIMULATOR_ID']
    raw=runner.command('runtime','simctl',['list','-j'],30,terminal_query=True).read_bytes()
    observed=runner_environment(os.environ,json.loads(raw),runner.tools['xcode'],platform.machine())
    require(observed==dict(osVersion='27.0',osBuildNumber='24A434',modelName='iPhone 17',architecture='arm64',xcode=runner.tools['xcode']), 'exact_runtime_environment')
    require(str(uuid.UUID(device)).upper()==device,'device_uuid')
    return {'device':device,'observed':observed,'hostOS':platform.mac_ver()[0]}


def verify_config(c):
    frozen(); verify_tools(c['tools'])
    require(c['diagnosticOnly'] is True and c['releaseAcceptance'] is False,'config_scope')
    require(selected_snapshot(c['sourceRoot'],c['sourceSnapshot']['files'])==c['sourceSnapshot'],'source_changed')
    require(snapshot(c['productsRoot'],512*1024**2,8192)==c['productsSnapshot'],'products_changed')
    require(sha(c['plan'])==c['planSHA256'],'plan_changed')
    require(sha(c['setupReceipt'])==c['setupReceiptSHA256'],'setup_changed')
    setup=read(c['setupReceipt'])
    require(setup['status']=='passed' and setup['case']=='scroll'
            and [s['stage'] for s in setup['stages']]==['boot','list-installed-apps','verify-app-absent','seed-pasteboard']
            and all(s['status']=='passed' for s in setup['stages']),'setup_not_passed')
    for name,digest in c['inputReceipts'].items():require(sha(Path(c['evidenceRoot'])/name)==digest,'input_receipt_changed:'+name)
    from preserve_performance_store import owned, binding, load
    evidence=Path(c['evidenceRoot']); owner=owned(evidence)
    require(owner and owner['createdUDID']==c['simulatorUDID'] and owner['creationStatus']=='verified','owned_device')
    attempt=load(evidence/'native-attempt.json')
    require(all(attempt[k]==v for k,v in binding(evidence,owner).items()),'attempt_binding')


def copy_snapshot(source, destination, value, budget):
    source=Path(source);destination=Path(destination);destination.mkdir(parents=True,exist_ok=False)
    for name in value['files']:
        src=source/name;dst=destination/name;dst.parent.mkdir(parents=True,exist_ok=True)
        with src.open('rb') as incoming,dst.open('xb') as outgoing:
            while True:
                chunk=incoming.read(1024**2)
                if not chunk:break
                outgoing.write(chunk);budget()
        shutil.copystat(src,dst)
    require(selected_snapshot(source,value['files'])==value==selected_snapshot(destination,value['files']),'copy_custody')
