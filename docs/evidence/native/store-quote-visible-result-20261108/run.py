from qualification_common import *
import signal, sys, time

out=BASE/'run';uid='858A2244-001F-4BAD-AFE0-A6E7AF02F41A'
selectors=(BASE/'selectors.txt').read_text().splitlines();assert len(selectors)==1
previous=ROOT/'.build/DisclosureStableIndicatorNov08/execution-r1/current-dark-AX5-run'
flags='DEBUG CONTRIBUTOR_CAPTURE_UI_FIXTURE STOCK_REVIEW_UI_FIXTURE AWAY_CARRYOVER_UI_FIXTURE'
cmd=[str(XCODE),'-project','ios/RoomInTheCart.xcodeproj','-scheme','RoomInTheCart','-configuration','Debug','-destination',f'platform=iOS Simulator,id={uid},arch=arm64','-derivedDataPath',str(FIXTURE_DD),'-jobs','2','-parallel-testing-enabled','NO','CODE_SIGN_IDENTITY=-','SWIFT_ACTIVE_COMPILATION_CONDITIONS='+flags,'-resultBundlePath',str(out/'native.xcresult'),'-test-timeouts-enabled','YES','-default-test-execution-time-allowance','720','-maximum-test-execution-time-allowance','900','-collect-test-diagnostics','on-failure','-only-testing:'+selectors[0],'test']
with lane():
 sources();free_space();assert not out.exists()
 prior=json.loads((previous/'run.json').read_text());verified=json.loads((previous/'inspection/verification.json').read_text())
 assert prior['status']=='completed' and prior['nativeExit']==0 and verified['strictExit']==0
 assert tree(FIXTURE_DD/'Build/Products')==prior['productManifest'],'cached product provenance changed'
 out.mkdir();(out/'selectors.txt').write_text('\n'.join(selectors)+'\n')
 products=clone_preserve(FIXTURE_DD/'Build/Products',out/'prior-products',out/'prior-products-preservation.json')
 record={'status':'preparing','startedAtUTC':now(),'sourceManifestSHA256':SOURCE_SHA,'expectedCount':1,'command':cmd,'cwd':str(ROOT),'scope':'Complete original known-trip/unknown-cost/private-proposal/shopper-adoption journey. Only offscreen short-result lookup uses a coherent snapshot. Same assertions and limits; incremental cached build.'};write(out/'run.json',record);process=None
 try:
  record['toolchain']=toolchain();record.update(device_identity(uid,'26.2','23C54','light','large'));sources();free_space();no_native_job();began=time.monotonic()
  with (out/'native.log').open('xb') as log:
   process=subprocess.Popen(cmd,cwd=ROOT,env=ENV,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);record.update(status='running',pid=process.pid);write(out/'run.json',record);print(json.dumps({'pid':process.pid,'source':SOURCE_SHA}),flush=True)
   while process.poll() is None:
    time.sleep(1)
    reason='reservedDiskFloor' if shutil.disk_usage(ROOT).free<RESERVE else 'outerWatchdog' if time.monotonic()-began>3780 else None
    if reason:
     record['stopReason']=reason;os.killpg(process.pid,signal.SIGTERM)
     try:process.wait(timeout=15)
     except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=15)
     break
   record['nativeExit']=process.wait()
  sources();record.update(status='completed',finishedAtUTC=now(),sourceUnchanged=True,preservedProductsUnchanged=tree(Path(products['copy']))==products['manifest'],productManifest=tree(FIXTURE_DD/'Build/Products'));write(out/'run.json',record)
  print(json.dumps({k:v for k,v in record.items() if k not in ['productManifest','command','toolchain','device','systemVersion']},indent=2));assert record['preservedProductsUnchanged'];sys.exit(record['nativeExit'] or (1 if 'stopReason' in record else 0))
 finally:
  if process is not None and process.poll() is None:
   os.killpg(process.pid,signal.SIGTERM)
   try:process.wait(timeout=15)
   except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=15)
