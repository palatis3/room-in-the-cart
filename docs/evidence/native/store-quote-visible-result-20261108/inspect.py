from qualification_common import *
import resource,sys

run=BASE/'run';record=json.loads((run/'run.json').read_text())
assert record['status']=='completed' and record['sourceUnchanged']
with lane():
 sources();free_space();out=run/'inspection';out.mkdir(exist_ok=False)
 original=run/'native.xcresult';preserve=clone_preserve(original,out/'native.xcresult',out/'original-manifest.json');copy=out/'native.xcresult'
 def command(args,name,timeout=60):
  def limit():resource.setrlimit(resource.RLIMIT_FSIZE,(8_000_000,8_000_000))
  with (out/(name+'.stdout')).open('w')as stdout,(out/(name+'.stderr')).open('w')as stderr:
   return subprocess.run(args,cwd=ROOT,env=ENV,stdout=stdout,stderr=stderr,timeout=timeout,preexec_fn=limit).returncode
 for kind in ['summary','tests']:
  assert command(['/usr/bin/xcrun','xcresulttool','get','test-results',kind,'--path',str(copy)],kind)==0
  (out/(kind+'.json')).write_bytes((out/(kind+'.stdout')).read_bytes())
 strict=command(['python3','scripts/check_ios_test_results.py','--selectors',str(run/'selectors.txt'),'--summary',str(out/'summary.json'),'--tests',str(out/'tests.json'),'--result-bundle',str(copy),'--test-log',str(run/'native.log'),'--expected-count','1'],'strict',120)
 selector=(run/'selectors.txt').read_text().strip().split('/',1)[1]+'()'
 exported=command(['/usr/bin/xcrun','xcresulttool','export','attachments','--path',str(copy),'--test-id',selector,'--output-path',str(out/'screens'),'--filter','S27-*.png'],'screens')
 assert exported==0
 sources();result={'inspectedAtUTC':now(),'nativeExit':record['nativeExit'],'strictExit':strict,'expectedCount':1,'sourceManifestSHA256':SOURCE_SHA,'sourceUnchanged':True,'originalUnchanged':tree(original)==preserve['manifest'],'screenExportExit':exported}
 write(out/'verification.json',result);print(json.dumps(result,indent=2));assert result['originalUnchanged'];sys.exit(strict or record['nativeExit'])
