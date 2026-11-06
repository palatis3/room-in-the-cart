#!/usr/bin/env python3
"""Opt-in hosted diagnostic orchestration. No retries or release-acceptance override."""
import argparse
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
PREDICATE = 'subsystem == "dev.roominthecart.urgentkeyboarddiagnostic" AND category == "events"'
INITIAL_INVENTORY_SECONDS = 180
SIMULATOR_CONTROL_SECONDS = 90
PARENT_STOP_SECONDS = 17  # Existing 12 + 5 seconds; now includes identity checks.
CHILD_STOP_SECONDS = 10  # Existing 5 + 5 seconds.
PRODUCT_DEBUG_DYLIB_MEMBER = 'Products/Debug-iphonesimulator/RoomInTheCart.app/RoomInTheCart.debug.dylib'
PRODUCT_DEBUG_DYLIB_LIMIT = 80_000_000  # Exclusive, regular file at exact path only; see PRODUCT-EXCEPTION.md.
STATE = Path(os.environ.get('KEYBOARD_STATE', '.build/keyboard-run'))


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
    print(f'Keyboard diagnostic: {name} started', flush=True)
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
    save(STATE/'identity.json', {'base':BASE, 'head':head, 'role':os.environ['KEYBOARD_ROLE'],
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
    name = 'RITC keyboard '+os.environ['KEYBOARD_ROLE']+' '+str(uuid4())
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


def build_arguments():
    return ['xcodebuild','-project','ios/RoomInTheCart.xcodeproj','-scheme','RoomInTheCart','-configuration','Debug',
        '-destination','platform=iOS Simulator,id='+device(),'-parallel-testing-enabled','NO','-jobs','2',
        '-derivedDataPath','.build/DerivedData','CODE_SIGN_IDENTITY=-',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG KEYBOARD_DISMISS_DIAGNOSTIC']


def validate_conditions(settings):
    app=[row['buildSettings'] for row in settings if row.get('target')=='RoomInTheCart']
    if len(app)!=1: raise ValueError('Require one app build setting')
    actual=app[0]
    if actual.get('CONFIGURATION')!='Debug' or actual.get('PLATFORM_NAME')!='iphonesimulator':
        raise ValueError('Ordinary Debug simulator configuration required')
    if actual.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS','').split()!=['DEBUG','KEYBOARD_DISMISS_DIAGNOSTIC']:
        raise ValueError('Only ordinary Debug plus reviewed instrumentation flag permitted')


def build():
    run('conditions',build_arguments()+['-showBuildSettings','-json'],timeout=120,separate_stderr=True)
    validate_conditions(json.loads(read_log('conditions')))
    run('build',build_arguments()+['build-for-testing'])
    run('built-app',[sys.executable,'scripts/check_built_app.py',str(PRODUCTS/'Debug-iphonesimulator/RoomInTheCart.app'),
        '--configuration','Debug'],timeout=60)


def original_xctestrun():
    originals=list(PRODUCTS.glob('RoomInTheCart_iphonesimulator*.xctestrun'))
    if len(originals)!=1: raise ValueError('Ambiguous original xctestrun')
    original=originals[0]
    content=plistlib.loads(original.read_bytes())
    if 'TestConfigurations' in content:
        targets=[t for c in content['TestConfigurations'] for t in c['TestTargets'] if t.get('IsUITestBundle') and t.get('BlueprintName')=='RoomInTheCartUITests']
    else: targets=[v for k,v in content.items() if k=='RoomInTheCartUITests' and isinstance(v,dict) and v.get('IsUITestBundle')]
    if len(targets)!=1: raise ValueError('Require exactly one original UI test target')
    for key in ['EnvironmentVariables','UITargetAppEnvironmentVariables']:
        if any(name.startswith('RITC_MEASUREMENT_') or name=='RITC_KEYBOARD_DIAGNOSTIC' for name in targets[0].get(key,{})):
            raise ValueError('Unrelated diagnostic environment forbidden')
    return original


def freeze():
    original=original_xctestrun()
    run('enumeration',['xcodebuild','-xctestrun',str(original),'-destination','platform=iOS Simulator,id='+device(),
        '-parallel-testing-enabled','NO','-enumerate-tests','-test-enumeration-style','flat','-test-enumeration-format','json',
        '-test-enumeration-output-path',str((STATE/'enumeration.json').resolve()),'test-without-building'])
    run('plan',[sys.executable,'scripts/plan_ios_tests.py','--enumeration',str(STATE/'enumeration.json'),'--output-dir',str(STATE/'compiled-plan')],timeout=30)
    plan=json.loads((STATE/'compiled-plan/manifest.json').read_text())
    if plan!=json.loads((HERE/'reference-plan.json').read_text()): raise ValueError('Compiled ordinary inventory/order changed')
    selection=(STATE/'compiled-plan/ui-07.txt').read_text()
    if selection!=(HERE/'selectors.txt').read_text(): raise ValueError('Six selectors/order changed')
    (STATE/'selectors.txt').write_text(selection)
    save(STATE/'xctestrun-original.json', {'original':original.name,'originalSHA256':file_digest(original),
        'modified':False,'runtimeEnvironmentChanged':False})
    save(STATE/'products-before.json',inventory(PRODUCTS))
    transfer=Path('.build/keyboard-transfer');transfer.mkdir(parents=True,exist_ok=False)
    for name in ['products-before.json','source-before.json','selectors.txt','xctestrun-original.json','owned-device.json']:
        (transfer/name).write_bytes((STATE/name).read_bytes())
    verify_frozen()
    archive=Path(os.environ['RUNNER_TEMP'])/'keyboard-products.tar.gz'
    with tarfile.open(archive,'w:gz') as tar:
        tar.add(PRODUCTS,arcname='Products');tar.add(transfer,arcname='keyboard-transfer')
    validate_transport_bounds(archive)
    archive_hash=file_digest(archive)
    save(STATE/'product-archive.json',{'sha256':archive_hash,'name':archive.name,'bytes':archive.stat().st_size})
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as output: output.write('sha256='+archive_hash+'\n')


def validate_transport_bounds(archive):
    # Product-tar-only exception; original result/download limits are unchanged.
    size=Path(archive).stat().st_size
    if not 0<size<256_000_000: raise ValueError('Archive byte bound')
    with tarfile.open(archive) as tar:
        entries=tar.getmembers()
        total=sum(member.size for member in entries)
        if len(entries)>=50000 or total>=1_000_000_000 or total>max(size,1)*1000:
            raise ValueError('Archive expansion bound')
        for member in entries:
            limit=PRODUCT_DEBUG_DYLIB_LIMIT if member.name==PRODUCT_DEBUG_DYLIB_MEMBER and member.isfile() else 50_000_000
            if member.size<0 or member.size>=limit: raise ValueError('Archive member bound')


def extract_transport(archive, destination):
    # Manual extraction works on the system Python 3.9 as well as newer runners.
    # Validate the entire archive before creating anything; never traverse links.
    validate_transport_bounds(archive)
    destination=Path(destination)
    if any((destination/name).exists() or (destination/name).is_symlink() for name in ('Products','keyboard-transfer')):
        raise ValueError('Transport destination must be fresh')
    with tarfile.open(archive) as tar:
        entries={}
        for member in tar.getmembers():
            path=PurePosixPath(member.name)
            if path.is_absolute() or not path.parts or '..' in path.parts or path.parts[0] not in ('Products','keyboard-transfer'):
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
        if any(name not in entries or not entries[name].isdir() for name in ('Products','keyboard-transfer')):
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
    archive=Path('.build/download/keyboard-products.tar.gz')
    expected=os.environ.get('BUILD_PRODUCT_SHA256','')
    if not re.fullmatch('[0-9a-f]{64}',expected) or file_digest(archive)!=expected: raise ValueError('Transferred archive digest mismatch')
    destination=PRODUCTS.parent
    extract_transport(archive,destination)
    transfer=destination/'keyboard-transfer'
    if json.loads((transfer/'owned-device.json').read_text())['udid']==device(): raise ValueError('Build/run device must differ')
    for name in ['products-before.json','selectors.txt','xctestrun-original.json']:
        (STATE/name).write_bytes((transfer/name).read_bytes())
    if json.loads((transfer/'source-before.json').read_text())!=json.loads((STATE/'source-before.json').read_text()): raise ValueError('Build/run source mismatch')
    if inventory(PRODUCTS)!=json.loads((STATE/'products-before.json').read_text()): raise ValueError('Restored products differ')
    if (STATE/'selectors.txt').read_text()!=(HERE/'selectors.txt').read_text(): raise ValueError('Restored selector mismatch')
    original=original_xctestrun(); recorded=json.loads((STATE/'xctestrun-original.json').read_text())
    if original.name!=recorded['original'] or file_digest(original)!=recorded['originalSHA256']: raise ValueError('Original xctestrun mismatch')
    save(STATE/'restore.json',{'archiveSHA256':file_digest(archive),'productsMatch':True,'sourceMatchesBuild':True})


def fingerprint(pid, timeout=10):
    try:
        result=subprocess.run(['ps','-p',str(pid),'-o','lstart=,command='],capture_output=True,text=True,timeout=timeout)
    except (OSError,subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode==0 else None


def stream_command():
    # log stream has no --timezone option; retain its raw wall time with unknown zone.
    return ['xcrun','simctl','spawn',device(),'log','stream','--style','compact','--level','info','--timeout','45m','--predicate',PREDICATE]


class _CaptureStop(Exception):
    """Private control flow: must not be consumed by a library OSError catch."""


def capture_stop_receipt(stage, event, **fields):
    record={'stage':stage,'event':event,'atUTC':datetime.now(timezone.utc).isoformat(),
            'atMonotonic':time.monotonic(),**fields}
    # One O_APPEND write per small record; never truncate an earlier phase.
    data=(json.dumps(record,allow_nan=False)+'\n').encode()
    descriptor=os.open(STATE/'capture-stop-events.jsonl',os.O_WRONLY|os.O_APPEND|os.O_CREAT,0o600)
    try:
        if os.write(descriptor,data)!=len(data): raise OSError('Incomplete stop receipt write')
    finally: os.close(descriptor)


def stop_remaining(deadline): return max(0.0,deadline-time.monotonic())


def recorded_capture(name):
    path=STATE/name
    return json.loads(path.read_text()) if path.exists() else None


def signal_recorded_capture(record, sig, stage, deadline):
    if not record:
        capture_stop_receipt(stage,'missing_identity');return False
    pid=record['pid'];remaining=stop_remaining(deadline)
    if remaining<=0:
        capture_stop_receipt(stage,'budget_exhausted',pid=pid);return False
    capture_stop_receipt(stage,'identity_check_started',pid=pid,maximumSeconds=min(10,remaining))
    actual=fingerprint(pid,timeout=min(10,remaining))
    same=bool(record.get('fingerprint')) and actual==record['fingerprint']
    capture_stop_receipt(stage,'identity_checked',pid=pid,matched=same)
    if not same or stop_remaining(deadline)<=0:
        capture_stop_receipt(stage,'signal_refused',pid=pid,identityMatched=same);return False
    capture_stop_receipt(stage,'signal_requested',pid=pid,signal=sig.name)
    try: os.killpg(pid,sig)
    except ProcessLookupError:
        capture_stop_receipt(stage,'already_exited',pid=pid);return False
    capture_stop_receipt(stage,'signal_sent',pid=pid,signal=sig.name)
    return True


def wait_capture(process, seconds, stage, deadline):
    if process.poll() is not None:
        capture_stop_receipt(stage,'already_reaped',pid=process.pid,exitCode=process.returncode);return True
    allowance=min(seconds,stop_remaining(deadline))
    if allowance<=0:
        capture_stop_receipt(stage,'budget_exhausted',pid=process.pid);return False
    capture_stop_receipt(stage,'wait_started',pid=process.pid,maximumSeconds=allowance)
    try: process.wait(timeout=allowance)
    except subprocess.TimeoutExpired:
        capture_stop_receipt(stage,'wait_timed_out',pid=process.pid);return False
    capture_stop_receipt(stage,'reaped',pid=process.pid,exitCode=process.returncode)
    return True


def finish_capture_child(process, record):
    deadline=time.monotonic()+CHILD_STOP_SECONDS
    capture_stop_receipt('helper','stop_started',maximumSeconds=CHILD_STOP_SECONDS)
    if process.poll() is not None: return True
    signal_recorded_capture(record,signal.SIGTERM,'helper-term',deadline)
    if wait_capture(process,5,'helper-grace',deadline): return True
    signal_recorded_capture(record,signal.SIGKILL,'helper-kill',deadline)
    return wait_capture(process,stop_remaining(deadline),'helper-reap',deadline)


def capture_stream():
    # Independent bounded helper: 45 minutes exceeds the unchanged native step.
    def stop_signal(signum, frame): raise _CaptureStop()
    signal.signal(signal.SIGTERM,stop_signal);signal.signal(signal.SIGINT,stop_signal)
    code=None;process=None;record=None;shutdown_complete=True
    with (STATE/'events-live.log').open('wb') as stdout,(STATE/'events-live.stderr').open('wb') as stderr:
        try:
            process=subprocess.Popen(stream_command(),stdout=stdout,stderr=stderr,start_new_session=True)
            record={'pid':process.pid,'fingerprint':fingerprint(process.pid),'maximumSeconds':2700,
                'createdUTC':datetime.now(timezone.utc).isoformat(),'createdMonotonic':time.monotonic(),
                'subscriptionReadinessEstablished':False}
            save(STATE/'capture-child.json',record)
            code=process.wait(timeout=2700)
        except subprocess.TimeoutExpired: code=124
        except _CaptureStop: code=0
        finally:
            # Repeated TERM must not interrupt the one bounded finalization path.
            signal.signal(signal.SIGTERM,signal.SIG_IGN);signal.signal(signal.SIGINT,signal.SIG_IGN)
            if process: shutdown_complete=finish_capture_child(process,record)
            save(STATE/'capture-final.json',{'operationExit':code,'helperExit':0 if code==0 and shutdown_complete else 1,
                'streamExit':process.returncode if process else None,'shutdownComplete':shutdown_complete,
                'completeDeliveryProven':False,'wallTimeZone':'unknown'})
    if code!=0 or not shutdown_complete: raise RuntimeError('Capture operation failed or finalization incomplete')


def stop_owned_capture(stage='cleanup', deadline=None):
    # Called from separate collect/cleanup processes: signal only; do not claim reaping.
    deadline=time.monotonic()+PARENT_STOP_SECONDS if deadline is None else deadline
    for name in ['capture-owner.json','capture-child.json']:
        signal_recorded_capture(recorded_capture(name),signal.SIGTERM,stage+'-'+name,deadline)
    capture_stop_receipt(stage,'signal_phase_finished',completionEstablished=False)


def finish_capture_owner(owner):
    deadline=time.monotonic()+PARENT_STOP_SECONDS
    capture_stop_receipt('execute','stop_started',maximumSeconds=PARENT_STOP_SECONDS)
    record=recorded_capture('capture-owner.json')
    if owner.poll() is not None: return True
    signal_recorded_capture(record,signal.SIGTERM,'execute-owner-term',deadline)
    if wait_capture(owner,12,'execute-owner-grace',deadline): return True
    # Help a blocked helper by stopping its recorded child, then allow finalization.
    child=recorded_capture('capture-child.json')
    signal_recorded_capture(child,signal.SIGTERM,'execute-child-term',deadline)
    if wait_capture(owner,2,'execute-finalization-grace',deadline): return True
    # The remaining part of the original 17-second allowance covers escalation/reap.
    signal_recorded_capture(child,signal.SIGKILL,'execute-child-kill',deadline)
    signal_recorded_capture(record,signal.SIGKILL,'execute-owner-kill',deadline)
    return wait_capture(owner,stop_remaining(deadline),'execute-owner-reap',deadline)


def test_command():
    selectors=(STATE/'selectors.txt').read_text().splitlines()
    expected=(HERE/'selectors.txt').read_text().splitlines()
    if selectors!=expected or len(selectors)!=6 or any('/RecordsMedia' in x for x in selectors): raise ValueError('Wrong fixed selectors')
    return ['xcodebuild','-xctestrun',str(original_xctestrun()),'-destination','platform=iOS Simulator,id='+device(),
        '-resultBundlePath',str(STATE/'Tests.xcresult'),'-parallel-testing-enabled','NO','-test-timeouts-enabled','YES',
        '-default-test-execution-time-allowance','720','-maximum-test-execution-time-allowance','900','-collect-test-diagnostics','never',
        *['-only-testing:'+x for x in selectors],'test-without-building']


def execute():
    if any((STATE/name).exists() for name in ('Tests.status.json','Tests.log','Tests.xcresult','capture-window.json')):
        raise ValueError('Original invocation evidence exists; no retry or overwrite')
    verify_frozen()
    save(STATE/'capture-window.json',{'startUTC':datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S%z')})
    owner=subprocess.Popen([sys.executable,str(HERE/'harness.py'),'capture-stream'],start_new_session=True)
    save(STATE/'capture-owner.json',{'pid':owner.pid,'fingerprint':fingerprint(owner.pid)})
    try: code=run('Tests',test_command(),check=False)  # Workflow 40 minutes; no reduced inner test deadline.
    finally:
        save(STATE/'capture-liveness.json',{'ownerAliveBeforeStop':owner.poll() is None,'completeDeliveryProven':False})
        complete=finish_capture_owner(owner)
        final=recorded_capture('capture-final.json')
        save(STATE/'capture-owner-final.json',{'exitCode':owner.returncode,'ownerReaped':complete,
            'helperFinalReceiptPresent':final is not None,
            'gracefulFinalizationConfirmed':bool(owner.returncode==0 and final and final.get('helperExit')==0 and final.get('shutdownComplete') is True),
            'shutdownBudgetSeconds':PARENT_STOP_SECONDS,'completeDeliveryProven':False})
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
    stop_owned_capture('collect')
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
    strict=run('strict',[sys.executable,'scripts/check_ios_test_results.py','--selectors',str(STATE/'selectors.txt'),'--expected-count','6',
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
    run('reconciliation',[sys.executable,str(HERE/'reconcile_keyboard_logs.py'),'--live',str(STATE/'events-live.log'),'--export',str(STATE/'events-export.log'),
        '--capture-receipts-dir',str(STATE),'--output',str(STATE/'reconciliation.json')],timeout=15,check=False)
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
        'logAbsenceNeverProvesNoDone':True})
    if not success: raise RuntimeError('Original execution, strict evidence, order or frozen-input check failed')


def cleanup():
    stop_owned_capture('cleanup')
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
        print('Keyboard diagnostic stage failed: '+command,file=sys.stderr);return 1
    return 0


if __name__=='__main__': raise SystemExit(main())
