from pathlib import Path
import hashlib,json,plistlib,subprocess,datetime
root=Path('/Users/palatis/Room in the Cart');base=root/'.build/S24TraceNov07';app=base/'release-dd/Build/Products/Release-iphoneos/RoomInTheCart.app'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
required=[]
for bundle in [app,*sorted((app/'PlugIns').glob('*.appex'))]:
 info=plistlib.loads((bundle/'Info.plist').read_bytes());binary=bundle/info['CFBundleExecutable'];assert binary.is_file();required.append(binary)
assert len(required)==3
magics={bytes.fromhex(h) for h in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}
found=[]
for p in sorted(app.rglob('*')):
 if p.is_file():
  with p.open('rb') as f:magic=f.read(4)
  if magic in magics:found.append(p)
assert set(required)<=set(found)
needles=['S24_PACK_TRACE','S24_PACK_TRACE_SCOPE'];rows=[]
for p in found:
 data=p.read_bytes();hits={s:{enc:data.count(s.encode(enc)) for enc in ['ascii','utf-16-le','utf-16-be']} for s in needles};assert all(n==0 for es in hits.values() for n in es.values())
 rows.append({'file':str(p.relative_to(app)),'absolutePath':str(p),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'matches':hits})
cmd=['python3','scripts/check_built_app.py',str(app),'--configuration','Release'];result=subprocess.run(cmd,cwd=root,text=True,capture_output=True);assert result.returncode==0; (base/'checks/release-built-app.txt').write_text(result.stdout+result.stderr)
run=json.loads((base/'run.json').read_text());sources=[]
for item in run['sourceFiles']:
 p=root/item['file'];actual=sha(p);assert actual==item['candidateSHA256'];sources.append({'file':item['file'],'actualSHA256':actual,'matchesQualifiedSource':True})
receipt={'checkedAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Read-only scan of every Mach-O file inside existing Release app, including main executable and both embedded extensions. No native execution/build.','rootReportedBuildExit':0,'releaseLog':str(base/'release.log'),'releaseLogSHA256':sha(base/'release.log'),'buildSuccessMarkerPresent':'** BUILD SUCCEEDED **' in (base/'release.log').read_text(),'requiredExecutables':len(required),'machOFilesScanned':len(found),'needles':needles,'encodings':['ascii','utf-16-le','utf-16-be'],'result':'absent in all scanned binaries','binaries':rows,'builtAppCheck':{'command':cmd,'exit':result.returncode,'output':'release-built-app.txt','outputSHA256':sha(base/'checks/release-built-app.txt')},'qualifiedSourceVerification':sources,'limits':'Byte-marker absence verifies these named trace literals are absent from these built binaries; not an assertion that every conceivable diagnostic is absent or production readiness.'}
(base/'checks/release-trace-scan.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps({'executables':len(required),'MachOFiles':len(found),'markerMatches':0,'checkBuiltAppExit':result.returncode,'sourceFilesVerified':len(sources)}))
