"""Scoped rendered target measurement on unchanged product source; no audit suppression."""
from pathlib import Path
import sys,json,os,time,signal,subprocess,shutil
ROOT=Path('/Users/palatis/Room in the Cart');QUAL=ROOT/'.build/DisclosureStableIndicatorNov08/execution-r1';sys.path.insert(0,str(QUAL))
from qualification_common import SOURCE_SHA,ENV,XCODE,RESERVE,sources,sha,tree,write,lane,free_space,require_pass,toolchain,no_native_job,device_identity,now
BASE=Path(__file__).resolve().parent;SOURCE_ROOT=BASE/'source';MANIFEST=BASE/'measurement-source-manifest.json'
SELECTORS=['RoomInTheCartUITests/HouseholdRequestPackUITests/testAuditNamedTargetsAtStandardText','RoomInTheCartUITests/HouseholdRequestPackUITests/testAuditNamedTargetsAtLargestText']
def audit_sources():
 sources();pins=json.loads(MANIFEST.read_text());assert len(pins)==556
 assert all(sha(SOURCE_ROOT/name)==want for name,want in pins.items())
 original=json.loads((BASE/'canonical-source-manifest.json').read_text())
 assert [name for name in pins if pins[name]!=original[name]]==['ios/UITests/HouseholdRequestPackUITests.swift']
 return pins

def main():
 out=BASE/'run';uid='858A2244-001F-4BAD-AFE0-A6E7AF02F41A'
 flags='DEBUG CONTRIBUTOR_CAPTURE_UI_FIXTURE STOCK_REVIEW_UI_FIXTURE AWAY_CARRYOVER_UI_FIXTURE'
 cmd=[str(XCODE),'-project','ios/RoomInTheCart.xcodeproj','-scheme','RoomInTheCart','-configuration','Debug','-destination',f'platform=iOS Simulator,id={uid},arch=arm64','-derivedDataPath',str(BASE/'dd'),'-jobs','2','-parallel-testing-enabled','NO','CODE_SIGN_IDENTITY=-','SWIFT_ACTIVE_COMPILATION_CONDITIONS='+flags,'-resultBundlePath',str(out/'native.xcresult'),'-test-timeouts-enabled','YES','-default-test-execution-time-allowance','720','-maximum-test-execution-time-allowance','900','-collect-test-diagnostics','on-failure',*['-only-testing:'+v for v in SELECTORS],'test']
 if '--plan' in sys.argv:print(json.dumps({'command':cmd,'cwd':str(SOURCE_ROOT),'expectedCount':2,'canonicalSourceSHA256':SOURCE_SHA,'auditSourceSHA256':sha(MANIFEST)},indent=2));return
 with lane():
  pins=audit_sources();free_space();assert not out.exists() and not (BASE/'dd').exists(),'unique audit output only'
  for phase in ['minimum17','current-light','current-dark-AX5']:require_pass(QUAL/(phase+'-run'))
  release=json.loads((ROOT/'.build/DisclosureStableIndicatorNov08/release-r1/run/run.json').read_text());assert release['status']=='completed' and release['buildExit']==0 and release['bundleCheckExit']==0 and release['sourceUnchanged']
  out.mkdir();(out/'selectors.txt').write_text('\n'.join(SELECTORS)+'\n')
  record={'status':'preparing','startedAtUTC':now(),'canonicalSourceManifestSHA256':SOURCE_SHA,'auditSourceManifestSHA256':sha(MANIFEST),'expectedCount':2,'command':cmd,'cwd':str(SOURCE_ROOT),'scope':'Rendered full visibility, native text bounds and screenshot contrast for Review decision, protected heading and expiry title/date at standard and AX5 text. No product edits or audit waivers.'};write(out/'run.json',record);process=None
  try:
   record['toolchain']=toolchain();record.update(device_identity(uid,'26.2','23C54','light','large'));audit_sources();free_space();no_native_job();began=time.monotonic()
   with (out/'native.log').open('xb') as log:
    process=subprocess.Popen(cmd,cwd=SOURCE_ROOT,env=ENV,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);record.update(status='running',pid=process.pid);write(out/'run.json',record);print(json.dumps({'pid':process.pid,'auditSource':sha(MANIFEST)}),flush=True)
    while process.poll() is None:
     time.sleep(1);reason='reservedDiskFloor' if shutil.disk_usage(ROOT).free<RESERVE else 'outerWatchdog' if time.monotonic()-began>3780 else None
     if reason:
      record['stopReason']=reason;os.killpg(process.pid,signal.SIGTERM)
      try:process.wait(timeout=15)
      except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=15)
      break
    record['nativeExit']=process.wait()
   audit_sources();record.update(status='completed',finishedAtUTC=now(),sourceUnchanged=True,productManifest=tree(BASE/'dd/Build/Products'));write(out/'run.json',record);print(json.dumps({k:v for k,v in record.items() if k not in ['productManifest','command','toolchain','device','systemVersion']},indent=2));sys.exit(record['nativeExit'] or (1 if 'stopReason' in record else 0))
  finally:
   if process is not None and process.poll() is None:
    os.killpg(process.pid,signal.SIGTERM)
    try:process.wait(timeout=15)
    except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=15)
if __name__=='__main__':main()
