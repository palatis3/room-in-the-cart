#!/usr/bin/env python3
"""Explicit hosted phases only. Import performs no native operation."""
import argparse, datetime, hashlib, json, os, re, shutil, signal, subprocess, sys, tarfile, threading, time, uuid
from pathlib import Path
from collect import Collector

ROOT = Path.cwd()
HERE = ROOT / 'diagnostics/ui09-hosted'
OUT = ROOT / '.build/ui09-hosted'
DD = ROOT / '.build/ui09-hosted-dd'
BASE = 'a30506596ad3a0103396fccb29800c629c92bc30'
SELECTORS_SHA = 'cb9657808f4c27eff4ccbb89f712120cd1e990f2e58a0094dd70b6af5aafb022'
FORBIDDEN = ('OS_ACTIVITY_MODE', 'OS_ACTIVITY_DT_MODE', 'DYLD_INSERT_LIBRARIES', 'XCTestConfigurationFilePath')
FLOOR = 8 * 1024**3

def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def sha(p): return hashlib.sha256(os.readlink(p).encode() if p.is_symlink() else p.read_bytes()).hexdigest()
def write(name, data): (OUT/name).write_text(json.dumps(data, indent=2)+'\n')
def capture(cmd, timeout=30): return subprocess.check_output(cmd, text=True, timeout=timeout).strip()
def tree(path):
    return {str(p.relative_to(path)): {'symlink':os.readlink(p)} if p.is_symlink() else
            {'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(path.rglob('*')) if p.is_symlink() or p.is_file()}
def guard():
    for key in FORBIDDEN:
        if key in os.environ: raise RuntimeError('inherited override rejected: '+key)
    if shutil.disk_usage(ROOT).free < FLOOR: raise RuntimeError('reserved 8 GiB disk floor')
    assert os.environ['DEVELOPER_DIR'] == '/Applications/Xcode_26.3.app/Contents/Developer'
    assert sha(HERE/'ui-09.txt') == SELECTORS_SHA
def selectors():
    rows=(HERE/'ui-09.txt').read_text().splitlines(); assert len(rows)==len(set(rows))==8
    return rows
def device():
    value=(OUT/'simulator-id.txt').read_text().strip(); uuid.UUID(value); return value
def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try: process.wait(timeout=15)
        except subprocess.TimeoutExpired: os.killpg(process.pid,signal.SIGKILL); process.wait(timeout=5)

def prepare():
    OUT.mkdir(parents=True, exist_ok=False); guard()
    expected=os.environ['EXPECTED_SHA']
    assert re.fullmatch('[0-9a-f]{40}',expected) and expected==os.environ['GITHUB_SHA']
    assert capture(['git','rev-parse','HEAD'])==expected
    assert not capture(['git','status','--porcelain']), 'checkout must be clean'
    pins=json.loads((HERE/'pins.json').read_text())
    changed=set(capture(['git','diff','--name-only',BASE,'HEAD']).splitlines())
    assert changed==set(pins['candidateDelta']), 'candidate has additional or missing changes'
    for name, want in pins['patchedSources'].items(): assert sha(ROOT/name)==want, name
    for name, want in pins['payloadHashes'].items(): assert sha(ROOT/name)==want, name
    assert capture(['xcodebuild','-version'])=='Xcode 26.3\nBuild version 17C529'
    assert capture(['uname','-m'])=='arm64'
    host=capture(['sw_vers']); assert 'ProductVersion:\t\t15.' in host or re.search(r'ProductVersion:\s+15\.',host)
    inventory=json.loads(capture(['/usr/bin/xcrun','simctl','list','-j'],timeout=180))
    runtime,=[r for r in inventory['runtimes'] if r['identifier']=='com.apple.CoreSimulator.SimRuntime.iOS-26-2' and r.get('isAvailable')]
    assert runtime['buildversion']=='23C54'
    # A fresh job-owned device avoids other app containers and is never erased/reused.
    created=capture(['/usr/bin/xcrun','simctl','create','UI09-'+os.environ['GITHUB_RUN_ID'],
                     'com.apple.CoreSimulator.SimDeviceType.iPhone-17',runtime['identifier']],timeout=180)
    uuid.UUID(created); (OUT/'simulator-id.txt').write_text(created+'\n')
    with open(os.environ['GITHUB_ENV'],'a') as f: f.write('SIMULATOR_ID='+created+'\n')
    tracked=capture(['git','ls-files','-z']).split('\0')
    source={name:sha(ROOT/name) for name in tracked if name}
    write('source-pins.json',source)
    write('identity.json',dict(baseSHA=BASE,candidateSHA=expected,device=created,runtime=runtime,
          host=host,xcode='26.3/17C529',createdUTC=now(),event=os.environ.get('GITHUB_EVENT_NAME'),
          runID=os.environ['GITHUB_RUN_ID'],runAttempt=os.environ['GITHUB_RUN_ATTEMPT'],
          imageOS=os.environ.get('ImageOS'),imageVersion=os.environ.get('ImageVersion')))
    shutil.copytree(HERE,OUT/'recipe')

def verify_sources():
    for name, want in json.loads((OUT/'source-pins.json').read_text()).items(): assert sha(ROOT/name)==want,name

def build():
    guard(); verify_sources(); assert not DD.exists()
    command=['xcodebuild','-project','ios/RoomInTheCart.xcodeproj','-scheme','RoomInTheCart',
      '-configuration','Debug','-destination','platform=iOS Simulator,id='+device(),'-jobs','2',
      '-parallel-testing-enabled','NO','-derivedDataPath',str(DD),'CODE_SIGN_IDENTITY=-',
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG UI09_ANIMATION_DIAGNOSTIC','build-for-testing']
    write('build-command.json',command)
    with (OUT/'Build.log').open('xb') as log:
        status=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT).returncode
    write('build-exit.json',dict(exit=status,finishedUTC=now())); verify_sources()
    if status: raise SystemExit(status)
    products=DD/'Build/Products'; write('product-pins.json',tree(products))
    with tarfile.open(OUT/'test-products.tar.gz','w:gz') as archive: archive.add(products,arcname='Products')

def test():
    guard(); verify_sources(); products=DD/'Build/Products'
    before=json.loads((OUT/'product-pins.json').read_text()); assert tree(products)==before
    runs=list(products.glob('RoomInTheCart_iphonesimulator*.xctestrun')); assert len(runs)==1
    appearance={key:capture(['/usr/bin/xcrun','simctl','ui',device(),key]) for key in ('appearance','content_size','increase_contrast')}
    write('appearance.json',appearance)
    assert appearance==dict(appearance='light',content_size='large',increase_contrast='disabled')
    command=['xcodebuild','-xctestrun',str(runs[0]),'-destination','platform=iOS Simulator,id='+device(),
       '-resultBundlePath',str(OUT/'Tests.xcresult'),'-parallel-testing-enabled','NO',
       '-test-timeouts-enabled','YES','-default-test-execution-time-allowance','720',
       '-maximum-test-execution-time-allowance','900','-collect-test-diagnostics','never']
    command += ['-only-testing:'+s for s in selectors()]+['test-without-building']
    receipt=dict(command=command,startedUTC=now(),nativeExit=None,stopReason=None,
                 nativeOuterLimitSeconds=2280,originalStepLimitSeconds=2400)
    write('run.json',receipt); observer=Collector(device(),OUT)
    thread=threading.Thread(target=observer.run,daemon=True); thread.start()
    assert observer.ready.wait(5), 'observer failed to become ready'
    process=None; started=time.monotonic()
    def interrupted(signum, frame): raise KeyboardInterrupt('hosted cancellation '+str(signum))
    signal.signal(signal.SIGTERM,interrupted)
    try:
        with (OUT/'Tests.log').open('xb') as log:
            process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            receipt['nativePID']=process.pid
            while process.poll() is None:
                time.sleep(1)
                if time.monotonic()-started>2280:
                    receipt['stopReason']='outerNativeBudget'; stop(process); break
                if shutil.disk_usage(ROOT).free<FLOOR:
                    receipt['stopReason']='reservedDiskFloor'; stop(process); break
            receipt['nativeExit']=process.wait()
    except BaseException as error:
        receipt['wrapperError']=type(error).__name__+': '+str(error)
        raise
    finally:
        if process is not None: stop(process)
        observer.stop.set(); thread.join(15)
        receipt.update(finishedUTC=now(),elapsedSeconds=time.monotonic()-started,
                       collectorJoined=not thread.is_alive(),collectorError=observer.error)
        closed=list((OUT/'observer').glob('*.closed.ndjson'))
        partial=list((OUT/'observer').glob('*.incomplete.ndjson'))
        candidate=next(iter(observer.candidates.values())) if len(observer.candidates)==1 else None
        quality=candidate['latest']['quality'] if candidate and candidate['latest'] else None
        receipt['captureAssessment']=dict(transportSealed=bool(candidate and candidate['closed']),quality=quality)
        receipt['captureStatus']=('ambiguous' if observer.ambiguous or len(observer.candidates)>1 else
                                  'complete' if len(closed)==1 and candidate and candidate['closed']
                                                and quality and quality['completeForDeclaredScope'] else
                                  'sealedLimited' if closed else 'partial' if partial else 'unavailable')
        receipt['productsUnchanged']=tree(products)==before
        try: verify_sources(); receipt['sourcesUnchanged']=True
        except Exception: receipt['sourcesUnchanged']=False
        write('run.json',receipt)
    if receipt['nativeExit'] or receipt['stopReason'] or observer.error or not receipt['collectorJoined']:
        raise SystemExit(1)
    if receipt['captureStatus']!='complete': raise SystemExit('native passed but target capture is not complete')
    assert receipt['productsUnchanged'] and receipt['sourcesUnchanged']

def inspect():
    # Copy only after native terminal. Original bundle remains untouched by xcresulttool.
    result=OUT/'Tests.xcresult'; original=tree(result); assert original
    log_before=sha(OUT/'Tests.log')
    write('original-before-inspection.json',original)
    copy=ROOT/'.build/ui09-inspection/Tests.xcresult'; copy.parent.mkdir(exist_ok=False)
    subprocess.run(['/bin/cp','-cR',str(result),str(copy)],check=True,timeout=60)
    assert tree(copy)==original
    try:
        for kind in ('summary','tests'):
            with (OUT/(kind+'.json')).open('xb') as output, (OUT/(kind+'-stderr.txt')).open('xb') as error:
                subprocess.run(['/usr/bin/xcrun','xcresulttool','get','test-results',kind,'--path',str(copy),'--compact'],
                               stdout=output,stderr=error,check=True,timeout=60)
        with (OUT/'strict.log').open('xb') as output:
            code=subprocess.run([sys.executable,'scripts/check_ios_test_results.py','--selectors',str(HERE/'ui-09.txt'),
               '--expected-count','8','--summary',str(OUT/'summary.json'),'--tests',str(OUT/'tests.json'),
               '--result-bundle',str(copy),'--test-log',str(OUT/'Tests.log')],stdout=output,stderr=subprocess.STDOUT,timeout=180).returncode
        write('strict-exit.json',dict(exit=code)); assert code==0
    finally:
        after=tree(result); write('original-after-inspection.json',after)
        assert after==original,'original result changed'
        assert sha(OUT/'Tests.log')==log_before,'original log changed'

def cleanup():
    if not (OUT/'simulator-id.txt').exists(): return
    owned=device()
    inventory=json.loads(capture(['/usr/bin/xcrun','simctl','list','devices','-j'],timeout=60))
    rows=[r for group in inventory['devices'].values() for r in group if r['udid']==owned]
    assert len(rows)==1 and rows[0]['name']=='UI09-'+os.environ['GITHUB_RUN_ID']
    if rows[0]['state']!='Shutdown': subprocess.run(['/usr/bin/xcrun','simctl','shutdown',owned],check=True,timeout=60)
    write('cleanup.json',dict(device=owned,action='shutdownOnly',finishedUTC=now()))

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('phase',choices=('prepare','build','test','inspect','cleanup'))
    globals()[parser.parse_args().phase]()
