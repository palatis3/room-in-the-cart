#!/usr/bin/env python3
"""Opt-in hosted diagnostic orchestration. No retries or release-acceptance override."""
import argparse
import copy
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import signal
import shutil
import stat
import subprocess
import sys
import tarfile
import time
from uuid import UUID, uuid4

BASE = '804030e68473d022e72b464940061c01c611a0bd'
HERE = Path(__file__).resolve().parent
PRODUCTS = Path('.build/DerivedData/Build/Products')
FLAG = 'RITC_MEASUREMENT_CONSENT_DIAGNOSTIC'
PREDICATE = 'subsystem == "dev.roominthecart.measurementconsentdiagnostic" AND category == "events"'
COPY_NAME = 'MeasurementConsentDiagnostic.xctestrun'
INITIAL_INVENTORY_SECONDS = 180
SIMULATOR_CONTROL_SECONDS = 90
STATE = Path(os.environ.get('CONSENT_STATE', '.build/consent-run'))


def save(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False)+'\n'); temporary.replace(path)


def digest(data): return hashlib.sha256(data).hexdigest()


def file_digest(path):
    value=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''): value.update(block)
    return value.hexdigest()


def run(name, argv, *, timeout=None, check=True, separate_stderr=False):
    STATE.mkdir(parents=True, exist_ok=True)
    record = {'stage': name, 'status': 'running', 'timeoutSeconds': timeout, 'argv': argv, 'stderrSeparate': separate_stderr,
              'startedUTC': datetime.now(timezone.utc).isoformat(), 'startedMonotonic': time.monotonic()}
    save(STATE/(name+'.status.json'), record)
    print(f'Consent diagnostic: {name} started', flush=True)
    start = time.monotonic()
    try:
        with ExitStack() as stack:
            stream = stack.enter_context((STATE/(name+'.log')).open('wb'))
            stderr = stack.enter_context((STATE/(name+'.stderr')).open('wb')) if separate_stderr else subprocess.STDOUT
            result = subprocess.run(argv, stdout=stream, stderr=stderr, timeout=timeout)
        code = result.returncode
    except subprocess.TimeoutExpired:
        code = 124
    except OSError:
        code = 127
    record.update(status='passed' if code == 0 else 'failed', exitCode=code,
                  elapsedSeconds=round(time.monotonic()-start, 3))
    save(STATE/(name+'.status.json'), record)
    if check and code: raise RuntimeError(f'{name} failed with exit {code}')
    return code


def read_log(name): return (STATE/(name+'.log')).read_text()


def inventory(folder):
    folder = Path(folder); result = {}
    if not folder.is_dir(): raise ValueError('Missing manifest root')
    for path in sorted(folder.rglob('*')):
        relative = str(path.relative_to(folder)); mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            target = os.readlink(path)
            if not path.resolve().is_relative_to(folder.resolve()): raise ValueError('Escaping product symlink')
            result[relative] = {'kind': 'symlink', 'target': target, 'mode': mode}
        elif path.is_file(): result[relative] = {'kind': 'file', 'sha256': file_digest(path), 'mode': mode}
        elif path.is_dir(): result[relative] = {'kind': 'directory', 'mode': mode}
        else: raise ValueError('Unexpected manifest file type')
    if not result: raise ValueError('Empty manifest')
    return result


def git_bytes(*args): return subprocess.check_output(['git', *args])


def source_snapshot():
    paths = git_bytes('ls-files', '-z').decode().split('\0')
    result = {}
    for name in filter(None, paths):
        path = Path(name)
        content = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
        if content != git_bytes('show', 'HEAD:'+name): raise ValueError('Tracked source differs from checked-out commit')
        result[name] = digest(content)
    return result


def verify_source():
    head = git_bytes('rev-parse', 'HEAD').decode().strip()
    if not re.fullmatch('[0-9a-f]{40}', os.environ.get('EXPECTED_SHA', '')) or head != os.environ['EXPECTED_SHA'] or head != os.environ.get('GITHUB_SHA'):
        raise ValueError('Dispatch and checkout must equal exact reviewed SHA')
    if os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch': raise ValueError('Manual diagnostic only')
    spec = json.loads((HERE/'overlay-index.json').read_text())
    if spec['base'] != BASE: raise ValueError('Overlay base mismatch')
    current = source_snapshot()
    baseline = set(filter(None, git_bytes('ls-tree','-r','--name-only','-z',BASE).decode().split('\0')))
    allowed = spec['files']
    index = str((HERE/'overlay-index.json').relative_to(Path.cwd()))
    if set(current) != baseline | set(allowed) | {index}: raise ValueError('Unexpected added/deleted source files')
    for name, actual in current.items():
        if name == index: continue  # Its exact bytes are bound by reviewed expected_sha.
        expected = allowed[name] if name in allowed else digest(git_bytes('show',BASE+':'+name))
        if actual != expected: raise ValueError('Source is not exact base plus reviewed overlay')
    save(STATE/'source-before.json', current)
    save(STATE/'identity.json', {'base':BASE, 'head':head, 'role':os.environ['CONSENT_ROLE'],
        'runID':os.environ.get('GITHUB_RUN_ID'), 'attempt':os.environ.get('GITHUB_RUN_ATTEMPT'),
        'imageOS':os.environ.get('ImageOS'), 'imageVersion':os.environ.get('ImageVersion'),
        'diagnosticOnly':True, 'releaseAcceptance':False})


def select_runtime(data):
    values = [r for r in data['runtimes'] if r.get('isAvailable') and r.get('version') == '26.2' and r.get('buildversion') == '23C54']
    if len(values) != 1: raise ValueError('Require one available iOS 26.2 / 23C54 runtime')
    value = values[0]
    if not value['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-'): raise ValueError('Not iOS runtime')
    devices = [d for d in data['devicetypes'] if d['identifier'] == 'com.apple.CoreSimulator.SimDeviceType.iPhone-17']
    if len(devices) != 1: raise ValueError('iPhone 17 device type unavailable')
    return value['identifier']


def prepare():
    verify_source()
    run('toolchain', ['xcodebuild','-version'], timeout=30)
    run('architecture',['uname','-m'],timeout=10)
    if read_log('toolchain').strip() != 'Xcode 26.3\nBuild version 17C529' or read_log('architecture').strip() != 'arm64':
        raise ValueError('Wrong hosted toolchain/architecture; no fallback')
    run('host',['sw_vers'],timeout=10)
    run('simulator-inventory',['xcrun','simctl','list','-j'],timeout=INITIAL_INVENTORY_SECONDS)
    runtime = select_runtime(json.loads(read_log('simulator-inventory')))
    name = 'RITC consent '+os.environ['CONSENT_ROLE']+' '+str(uuid4())
    save(STATE/'owned-device.json', {'name':name,'runtime':runtime,'udid':None})
    run('create-device',['xcrun','simctl','create',name,'com.apple.CoreSimulator.SimDeviceType.iPhone-17',runtime],timeout=SIMULATOR_CONTROL_SECONDS)
    device = read_log('create-device').strip(); UUID(device)
    save(STATE/'owned-device.json', {'name':name,'runtime':runtime,'udid':device})


def device():
    value = json.loads((STATE/'owned-device.json').read_text())['udid']; UUID(value); return value


def boot():
    # The unchanged workflow eight-minute step deadline is authoritative.
    run('boot',[sys.executable,'scripts/boot_ios_simulator.py',device()])
    run('booted-build',['xcrun','simctl','getenv',device(),'SIMULATOR_RUNTIME_BUILD_VERSION'],timeout=SIMULATOR_CONTROL_SECONDS)
    if read_log('booted-build').strip() != '23C54':
        raise ValueError('Booted runtime readback mismatch')
    run('booted-device',['xcrun','simctl','list','devices','-j'],timeout=SIMULATOR_CONTROL_SECONDS)
    known=json.loads((STATE/'owned-device.json').read_text())
    actual=[x for x in json.loads(read_log('booted-device'))['devices'].get(known['runtime'],[]) if x['udid']==device()]
    if len(actual)!=1 or actual[0]['state']!='Booted' or actual[0]['name']!=known['name'] or actual[0].get('deviceTypeIdentifier')!='com.apple.CoreSimulator.SimDeviceType.iPhone-17': raise ValueError('Owned device readback mismatch')


def build():
    run('conditions',[sys.executable,'scripts/plan_ios_fixture_tests.py','conditions','contributor'],timeout=30)
    conditions=read_log('conditions').strip()
    if conditions != 'DEBUG CONTRIBUTOR_CAPTURE_UI_FIXTURE STOCK_REVIEW_UI_FIXTURE AWAY_CARRYOVER_UI_FIXTURE': raise ValueError('Unexpected build conditions')
    run('build',['xcodebuild','-project','ios/RoomInTheCart.xcodeproj','-scheme','RoomInTheCart','-configuration','Debug',
        '-destination','platform=iOS Simulator,id='+device(),'-parallel-testing-enabled','NO','-jobs','2',
        '-derivedDataPath','.build/DerivedData','CODE_SIGN_IDENTITY=-','SWIFT_ACTIVE_COMPILATION_CONDITIONS='+conditions,'build-for-testing'])


def copy_xctestrun(original):
    original=Path(original); output=original.with_name(COPY_NAME)
    if output.exists() or output==original: raise ValueError('Diagnostic xctestrun already exists')
    content=plistlib.loads(original.read_bytes()); changed=copy.deepcopy(content)
    if 'TestConfigurations' in changed:
        targets=[t for c in changed['TestConfigurations'] for t in c['TestTargets'] if t.get('IsUITestBundle') and t.get('BlueprintName')=='RoomInTheCartUITests']
    else: targets=[v for k,v in changed.items() if k=='RoomInTheCartUITests' and isinstance(v,dict) and v.get('IsUITestBundle')]
    if len(targets)!=1: raise ValueError('Require exactly one UI test target')
    target=targets[0]; environment=target.setdefault('EnvironmentVariables',{})
    if FLAG in environment: raise ValueError('Opt-in already present in original')
    environment[FLAG]='1'
    output.write_bytes(plistlib.dumps(changed,fmt=plistlib.FMT_XML,sort_keys=False))
    return output


def freeze():
    originals=list(PRODUCTS.glob('RoomInTheCart_iphonesimulator*.xctestrun'))
    if len(originals)!=1: raise ValueError('Ambiguous original xctestrun')
    original=originals[0]
    run('enumeration',['xcodebuild','-xctestrun',str(original),'-destination','platform=iOS Simulator,id='+device(),
        '-parallel-testing-enabled','NO','-enumerate-tests','-test-enumeration-style','flat','-test-enumeration-format','json',
        '-test-enumeration-output-path',str((STATE/'enumeration.json').resolve()),'test-without-building'])
    run('plan',[sys.executable,'scripts/plan_ios_fixture_tests.py','plan','contributor','--enumeration',str(STATE/'enumeration.json'),'--output-dir',str(STATE/'compiled-plan')],timeout=30)
    plan=json.loads((STATE/'compiled-plan/manifest.json').read_text())
    if plan!=json.loads((HERE/'reference-plan.json').read_text()): raise ValueError('Compiled contributor inventory/order changed')
    selection=(STATE/'compiled-plan/contributor-balanced-02.txt').read_text()
    if selection!=(HERE/'selectors.txt').read_text(): raise ValueError('Seven selectors/order changed')
    (STATE/'selectors.txt').write_text(selection)
    before=original.read_bytes(); diagnostic=copy_xctestrun(original)
    if original.read_bytes()!=before: raise ValueError('Original xctestrun changed')
    save(STATE/'xctestrun-copy.json', {'original':original.name,'diagnostic':diagnostic.name,'originalSHA256':digest(before),
        'diagnosticSHA256':digest(diagnostic.read_bytes()),'onlyChange':'RoomInTheCartUITests.EnvironmentVariables.'+FLAG+'=1','besideOriginal':True})
    save(STATE/'products-before.json',inventory(PRODUCTS))
    transfer=Path('.build/consent-transfer');transfer.mkdir(exist_ok=True)
    for name in ['products-before.json','source-before.json','selectors.txt','xctestrun-copy.json','owned-device.json']:
        (transfer/name).write_bytes((STATE/name).read_bytes())
    verify_frozen()
    archive=Path(os.environ['RUNNER_TEMP'])/'consent-products.tar.gz'
    with tarfile.open(archive,'w:gz') as tar:
        tar.add(PRODUCTS,arcname='Products');tar.add(transfer,arcname='consent-transfer')
    save(STATE/'product-archive.json',{'sha256':file_digest(archive),'name':archive.name})


def extract_transport(archive, destination):
    # Manual extraction works on the system Python 3.9 as well as newer runners.
    # Validate the entire archive before creating anything; never traverse links.
    destination=Path(destination)
    if any((destination/name).exists() or (destination/name).is_symlink() for name in ('Products','consent-transfer')):
        raise ValueError('Transport destination must be fresh')
    with tarfile.open(archive) as tar:
        entries={}
        for member in tar.getmembers():
            path=PurePosixPath(member.name)
            if path.is_absolute() or not path.parts or '..' in path.parts or path.parts[0] not in ('Products','consent-transfer'):
                raise ValueError('Unsafe archive path')
            if str(path) in entries or not (member.isdir() or member.isfile() or member.issym()):
                raise ValueError('Duplicate or unsupported archive member')
            if member.mode & ~0o777: raise ValueError('Unsupported special archive mode')
            if member.issym():
                target=PurePosixPath(member.linkname)
                resolved=PurePosixPath(os.path.normpath(str(path.parent/target)))
                if path.parts[0]!='Products' or target.is_absolute() or not resolved.parts or resolved.parts[0]!='Products':
                    raise ValueError('Escaping archive symlink')
            entries[str(path)]=member
        for name,member in entries.items():
            for parent in PurePosixPath(name).parents:
                if str(parent)=='.': continue
                if str(parent) not in entries or not entries[str(parent)].isdir():
                    raise ValueError('Archive parent is missing or is a link')
        if any(name not in entries or not entries[name].isdir() for name in ('Products','consent-transfer')):
            raise ValueError('Missing transport root')
        destination.mkdir(parents=True,exist_ok=True)
        directories=[name for name,member in entries.items() if member.isdir()]
        for name in sorted(directories,key=lambda name:len(PurePosixPath(name).parts)):
            (destination/name).mkdir()
        for name,member in entries.items():
            path=destination/name
            if member.isfile():
                with tar.extractfile(member) as source,path.open('xb') as output: shutil.copyfileobj(source,output)
                path.chmod(member.mode)
            elif member.issym(): path.symlink_to(member.linkname)
        for name in sorted(directories,key=lambda name:len(PurePosixPath(name).parts),reverse=True):
            (destination/name).chmod(entries[name].mode)


def restore():
    archive=Path('.build/download/consent-products.tar.gz')
    destination=PRODUCTS.parent
    extract_transport(archive,destination)
    transfer=destination/'consent-transfer'
    if json.loads((transfer/'owned-device.json').read_text())['udid']==device(): raise ValueError('Build/run device must differ')
    for name in ['products-before.json','selectors.txt','xctestrun-copy.json']:
        (STATE/name).write_bytes((transfer/name).read_bytes())
    if json.loads((transfer/'source-before.json').read_text())!=json.loads((STATE/'source-before.json').read_text()): raise ValueError('Build/run source mismatch')
    if inventory(PRODUCTS)!=json.loads((STATE/'products-before.json').read_text()): raise ValueError('Restored products differ')
    if (STATE/'selectors.txt').read_text()!=(HERE/'selectors.txt').read_text(): raise ValueError('Restored selector mismatch')
    save(STATE/'restore.json',{'archiveSHA256':file_digest(archive),'productsMatch':True,'sourceMatchesBuild':True})


def fingerprint(pid):
    result=subprocess.run(['ps','-p',str(pid),'-o','lstart=,command='],capture_output=True,text=True,timeout=10)
    return result.stdout.strip() if result.returncode==0 else None


def stream_command():
    # log stream has no --timezone option; retain its raw wall time with unknown zone.
    return ['xcrun','simctl','spawn',device(),'log','stream','--style','compact','--level','info','--timeout','45m','--predicate',PREDICATE]


def capture_stream():
    # Independent bounded helper: 45 minutes exceeds the unchanged 40-minute native step.
    def stop_signal(signum, frame): raise InterruptedError('capture stop')
    signal.signal(signal.SIGTERM,stop_signal);signal.signal(signal.SIGINT,stop_signal)
    code=None;process=None
    with (STATE/'events-live.log').open('wb') as stdout,(STATE/'events-live.stderr').open('wb') as stderr:
        try:
            process=subprocess.Popen(stream_command(),stdout=stdout,stderr=stderr,start_new_session=True)
            save(STATE/'capture-child.json',{'pid':process.pid,'fingerprint':fingerprint(process.pid),'maximumSeconds':2700,
                'createdUTC':datetime.now(timezone.utc).isoformat(),'createdMonotonic':time.monotonic(),
                'subscriptionReadinessEstablished':False})
            code=process.wait(timeout=2700)
        except subprocess.TimeoutExpired: code=124
        except InterruptedError: code=0
        finally:
            if process and process.poll() is None:
                try: os.killpg(process.pid,signal.SIGTERM)
                except ProcessLookupError: pass
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=5)
            save(STATE/'capture-final.json',{'operationExit':code,'helperExit':0 if code==0 else 1,'streamExit':process.returncode if process else None,'completeDeliveryProven':False,'wallTimeZone':'unknown'})

    if code != 0: raise RuntimeError('Capture operation failed or exceeded its bound')

def stop_owned_capture():
    outcomes={}
    for name in ['capture-owner.json','capture-child.json']:
        path=STATE/name
        if not path.exists(): continue
        value=json.loads(path.read_text());pid=value['pid'];same=value.get('fingerprint') and fingerprint(pid)==value['fingerprint']
        outcomes[name]={'pid':pid,'identityMatched':bool(same)}
        if same:
            try: os.killpg(pid,signal.SIGTERM);outcomes[name]['signalSent']='SIGTERM'
            except ProcessLookupError: outcomes[name]['alreadyExited']=True
    save(STATE/'capture-cleanup.json',outcomes)


def test_command():
    selectors=(STATE/'selectors.txt').read_text().splitlines()
    expected=(HERE/'selectors.txt').read_text().splitlines()
    if selectors!=expected or len(selectors)!=7 or any('/RecordsMedia' in x for x in selectors): raise ValueError('Wrong fixed selectors')
    return ['xcodebuild','-xctestrun',str(PRODUCTS/COPY_NAME),'-destination','platform=iOS Simulator,id='+device(),
        '-resultBundlePath',str(STATE/'Tests.xcresult'),'-parallel-testing-enabled','NO','-test-timeouts-enabled','YES',
        '-default-test-execution-time-allowance','720','-maximum-test-execution-time-allowance','900','-collect-test-diagnostics','never',
        *['-only-testing:'+x for x in selectors],'test-without-building']


def execute():
    verify_frozen()
    save(STATE/'capture-window.json',{'startUTC':datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S%z')})
    owner=subprocess.Popen([sys.executable,str(HERE/'harness.py'),'capture-stream'],start_new_session=True)
    save(STATE/'capture-owner.json',{'pid':owner.pid,'fingerprint':fingerprint(owner.pid)})
    try: code=run('Tests',test_command(),check=False)  # Workflow 40 minutes; no reduced inner test deadline.
    finally:
        save(STATE/'capture-liveness.json',{'ownerAliveBeforeStop':owner.poll() is None,'completeDeliveryProven':False})
        owner.terminate()
        try: owner.wait(timeout=12)
        except subprocess.TimeoutExpired: stop_owned_capture();owner.kill();owner.wait(timeout=5)
        save(STATE/'capture-owner-final.json',{'exitCode':owner.returncode,'completeDeliveryProven':False})
    if code: raise RuntimeError('Original native invocation failed')


def verify_frozen():
    source=source_snapshot();products=inventory(PRODUCTS)
    ok=source==json.loads((STATE/'source-before.json').read_text()) and products==json.loads((STATE/'products-before.json').read_text())
    save(STATE/'source-after.json',source);save(STATE/'products-after.json',products)
    save(STATE/'frozen-inputs.json',{'unchanged':ok})
    if not ok: raise ValueError('Frozen input mismatch')


def order_from_log(text):
    pattern=re.compile(r"^Test Case '-\[RoomInTheCartUITests\.(\w+) (test\w+)\]' started\.$",re.M)
    return ['RoomInTheCartUITests/'+suite+'/'+method for suite,method in pattern.findall(text)]


def validate_test_runtime(summary, simulator):
    rows=summary['devicesAndConfigurations']
    if len(rows)!=1: return False
    value=rows[0]['device']
    return all(value.get(key)==expected for key,expected in {
        'deviceId':simulator,'architecture':'arm64','modelName':'iPhone 17','osVersion':'26.2',
        'osBuildNumber':'23C54','platform':'iOS Simulator'}.items())


def collect():
    stop_owned_capture()
    if (STATE/'capture-window.json').exists():
        start=json.loads((STATE/'capture-window.json').read_text())['startUTC'];end=datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S%z')
        # Finite persisted window, finite 45-second command; never replaces live log.
        run('events-export',['xcrun','simctl','spawn',device(),'log','show','--start',start,'--end',end,'--info','--style','compact','--timezone','UTC','--predicate',PREDICATE],timeout=45,check=False,separate_stderr=True)
    original_result=STATE/'Tests.xcresult'; replay_result=STATE/'replay/Tests.xcresult'
    raw_before=None; copy_ok=False
    try:
        raw_before=inventory(original_result)
        save(STATE/'raw-result-before.json',raw_before)
        replay_result.parent.mkdir(exist_ok=True)
        shutil.copytree(original_result,replay_result,symlinks=True)
        if inventory(replay_result)!=raw_before: raise ValueError('Result copy differs')
        copy_ok=True
        save(STATE/'result-copy.json',{'original':str(original_result),'inspectionCopy':str(replay_result),'matchedBeforeInspection':True})
    except (OSError,ValueError):
        save(STATE/'result-copy.json',{'original':str(original_result),'inspectionCopy':str(replay_result),'matchedBeforeInspection':False})
    summary=run('test-summary',['xcrun','xcresulttool','get','test-results','summary','--path',str(replay_result),'--compact'],timeout=45,check=False)
    details=run('test-details',['xcrun','xcresulttool','get','test-results','tests','--path',str(replay_result),'--compact'],timeout=45,check=False)
    for name in ['test-summary','test-details']:
        (STATE/(name+'.json')).write_bytes((STATE/(name+'.log')).read_bytes())
    strict=run('strict',[sys.executable,'scripts/check_ios_test_results.py','--selectors',str(STATE/'selectors.txt'),'--expected-count','7',
        '--summary',str(STATE/'test-summary.json'),'--tests',str(STATE/'test-details.json'),'--result-bundle',str(replay_result),'--test-log',str(STATE/'Tests.log')],timeout=120,check=False)
    runtime_ok=False
    if summary==0:
        try: runtime_ok=validate_test_runtime(json.loads((STATE/'test-summary.json').read_text()),device())
        except (ValueError,KeyError,TypeError): pass
    save(STATE/'test-runtime-identity.json',{'matches':runtime_ok,'requiredVersion':'26.2','requiredBuild':'23C54','requiredArchitecture':'arm64'})
    expected=(HERE/'selectors.txt').read_text().splitlines(); actual=order_from_log(read_log('Tests')) if (STATE/'Tests.log').exists() else []
    save(STATE/'order.json',{'expected':expected,'actual':actual,'matches':actual==expected})
    freeze_error=False
    try: verify_frozen()
    except (OSError,ValueError): freeze_error=True
    # Reconciliation cannot convert a native failure into success or become a release gate.
    run('reconciliation',[sys.executable,str(HERE/'reconcile_consent_logs.py'),'--live',str(STATE/'events-live.log'),'--export',str(STATE/'events-export.log'),
        '--export-timezone','UTC','--output',str(STATE/'reconciliation.json')],timeout=15,check=False)
    native=json.loads((STATE/'Tests.status.json').read_text()) if (STATE/'Tests.status.json').exists() else {}
    raw_unchanged=False
    if raw_before is not None:
        try:
            raw_after=inventory(original_result);save(STATE/'raw-result-after.json',raw_after)
            raw_unchanged=raw_after==raw_before
        except (OSError,ValueError): pass
    save(STATE/'raw-result-preservation.json',{'unchanged':raw_unchanged,'original':str(original_result),'inspectionCopy':str(replay_result)})
    success=copy_ok and raw_unchanged and native.get('exitCode')==0 and strict==0 and summary==0 and details==0 and runtime_ok and actual==expected and not freeze_error
    save(STATE/'outcome.json',{'nativeAndStrictPassed':success,'diagnosticOnly':True,'releaseAcceptance':False,
        'nativeExit':native.get('exitCode'),'strictExit':strict,'resultCopyVerified':copy_ok,
        'logAbsenceNeverProvesNoSetter':True})
    if not success: raise RuntimeError('Original execution, strict evidence, order or frozen-input check failed')


def cleanup():
    stop_owned_capture()
    path=STATE/'owned-device.json'
    if not path.exists(): save(STATE/'cleanup.json',{'ownedDeviceRecorded':False});return
    owned=json.loads(path.read_text())
    run('cleanup-inventory',['xcrun','simctl','list','devices','-j'],timeout=SIMULATOR_CONTROL_SECONDS)
    candidates=[x for x in json.loads(read_log('cleanup-inventory'))['devices'].get(owned['runtime'],[])
                if x['name']==owned['name'] and (owned['udid'] is None or x['udid']==owned['udid'])]
    if len(candidates)>1: raise ValueError('Ambiguous owned cleanup target')
    outcomes=[]
    for value in candidates:
        udid=value['udid'];UUID(udid)
        shutdown=run('shutdown-owned',['xcrun','simctl','shutdown',udid],timeout=30,check=False)
        delete=run('delete-owned',['xcrun','simctl','delete',udid],timeout=30,check=False)
        outcomes.append({'udid':udid,'shutdownExit':shutdown,'deleteExit':delete})
    save(STATE/'cleanup.json',{'ownedDeviceRecorded':True,'outcomes':outcomes,'missingAlready':not candidates})
    if any(x['deleteExit']!=0 for x in outcomes): raise RuntimeError('Owned simulator deletion failed')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['prepare','boot','build','freeze','restore','execute','collect','cleanup','capture-stream'])
    command=parser.parse_args().command
    STATE.mkdir(parents=True,exist_ok=True)
    try: globals()[command.replace('-','_')]()
    except Exception as error:
        save(STATE/(command+'-failure.json'),{'kind':type(error).__name__,'diagnosticOnly':True})
        print('Consent diagnostic stage failed: '+command,file=sys.stderr);return 1
    return 0


if __name__=='__main__': raise SystemExit(main())
