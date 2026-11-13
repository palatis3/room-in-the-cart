"""Preserve the audit result, verify its inventory and collect every reported issue."""
from pathlib import Path
import sys,json,subprocess,resource,importlib.util
BASE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('audit_runner',BASE/'run-measurement.py');audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
from qualification_common import clone_preserve,tree,sha,write,lane,free_space,now
run=BASE/'run';record=json.loads((run/'run.json').read_text());assert record['status']=='completed' and isinstance(record['nativeExit'],int) and record['sourceUnchanged']
with lane():
 audit.audit_sources();free_space();out=run/'inspection';out.mkdir(exist_ok=False)
 original=run/'native.xcresult';preserve=clone_preserve(original,out/'native.xcresult',out/'original-manifest.json');copy=out/'native.xcresult'
 def command(args,name,timeout=45):
  def limit():resource.setrlimit(resource.RLIMIT_FSIZE,(4_000_000,4_000_000))
  with (out/(name+'.stdout')).open('w') as stdout,(out/(name+'.stderr')).open('w') as stderr:
   return subprocess.run(args,cwd=audit.ROOT,env=audit.ENV,stdout=stdout,stderr=stderr,timeout=timeout,preexec_fn=limit).returncode
 for kind in ['summary','tests']:
  assert command(['/usr/bin/xcrun','xcresulttool','get','test-results',kind,'--path',str(copy)],kind)==0
  (out/(kind+'.json')).write_bytes((out/(kind+'.stdout')).read_bytes())
 strict=command(['python3','scripts/check_ios_test_results.py','--selectors',str(run/'selectors.txt'),'--summary',str(out/'summary.json'),'--tests',str(out/'tests.json'),'--result-bundle',str(copy),'--test-log',str(run/'native.log'),'--expected-count','2'],'strict',120)
 exports={}
 for index,selector in enumerate(audit.SELECTORS):
  testID=selector.split('/',1)[1]+'()'
  for kind,pattern in [('images','S24-audit-*.png'),('geometry','S24-audit-*.txt')]:
   name=str(index)+'-'+kind
   exports[name]=command(['/usr/bin/xcrun','xcresulttool','export','attachments','--path',str(copy),'--test-id',testID,'--output-path',str(out/name),'--filter',pattern],'export-'+name)
   assert exports[name]==0,name
 total=sum(p.stat().st_size for folder in exports for p in (out/folder).rglob('*') if p.is_file());assert total<20_000_000
 audit.audit_sources();verification={'inspectedAtUTC':now(),'nativeExit':record['nativeExit'],'strictExit':strict,'expectedCount':2,'auditSourceManifestSHA256':audit.sha(audit.MANIFEST),'canonicalSourceManifestSHA256':audit.SOURCE_SHA,'originalUnchanged':tree(original)==preserve['manifest'],'sourceUnchanged':True,'exports':exports,'exportBytes':total,'scope':'Scoped actual rendered measurements on unchanged production. No full-audit closure inferred.'};write(out/'verification.json',verification);assert verification['originalUnchanged'];print(json.dumps(verification,indent=2))
