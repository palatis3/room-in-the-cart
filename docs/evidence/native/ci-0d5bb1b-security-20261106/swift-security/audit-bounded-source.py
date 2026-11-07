from pathlib import Path,PurePosixPath
import hashlib,io,json,subprocess,zipfile,stat
p=Path(__file__).resolve().parent;c=p.parent/'core-collection';head='0d5bb1b22e9e84cd4b8c2b07317f91cfc703b60c';merge='525d68ae2dbb46f21be8d71a495c10f7c1246f7f';rid=42316648565;gh='.tools/github-cli/bin/gh';api='repos/palatis3/room-in-the-cart/'
read=lambda p:json.loads(p.read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
j,=[j for j in read(c/f'{rid}-jobs.json')['jobs'] if j['name']=='ios-swift-codeql'];assert j['status']=='completed' and j['conclusion']=='success' and j['head_sha']==head
meta=read(c/f'{rid}-artifacts.json');a,=[a for a in meta['artifacts'] if a['name']=='debug-artifacts'];assert not a['expired'] and a['workflow_run']['head_sha']==head and a['workflow_run']['id']==rid and a['size_in_bytes']<50_000_000
archive=p/(str(a['id'])+'.zip')
if not archive.exists():
 part=archive.with_suffix('.zip.part')
 with part.open('wb') as f:subprocess.run([gh,'api',api+f'actions/artifacts/{a["id"]}/zip','--allow-escape-sequences'],stdout=f,check=True,timeout=180)
 part.replace(archive)
assert archive.stat().st_size==a['size_in_bytes'] and 'sha256:'+sha(archive)==a['digest']
def guard(z,label):
 entries=z.infolist();assert len(entries)<50000 and len(entries)==len(set(z.namelist())) and sum(e.file_size for e in entries)<1_000_000_000
 rows=[]
 for e in entries:
  f=PurePosixPath(e.filename);assert not f.is_absolute() and '..' not in f.parts and '\\' not in e.filename and not e.flag_bits&1 and ((e.external_attr>>16)&0o170000) in [0,stat.S_IFDIR,stat.S_IFREG]
  assert e.file_size<50_000_000 and e.file_size<=max(e.compress_size,1)*1000,(label,e.filename,e.file_size)
  rows.append({'name':e.filename,'bytes':e.file_size,'compressedBytes':e.compress_size})
 (p/(label+'-members.json')).write_text(json.dumps(rows,indent=2)+'\n')
 assert z.testzip() is None

def bounded(z,name,limit):
 e=z.getinfo(name);assert e.filename==name and e.file_size<limit and not e.is_dir() and not e.flag_bits&1 and e.file_size<=max(e.compress_size,1)*1000;return z.read(e)
with zipfile.ZipFile(archive) as z:
 guard(z,'outer');raw=bounded(z,'swift.sarif',8_000_000);(p/'swift.sarif').write_bytes(raw);sarif=json.loads(raw)['runs'][0];inner=bounded(z,'db-swift.zip',50_000_000)
with zipfile.ZipFile(io.BytesIO(inner)) as z:
 names=z.namelist();assert len(names)==len(set(names))
 selected=['db-swift/codeql-database.yml','db-swift/src.zip'];receipt=[]
 for name in selected:
  e=z.getinfo(name);assert e.filename==name and ((e.external_attr>>16)&0o170000) in [0,stat.S_IFREG]
  receipt.append({'name':name,'bytes':e.file_size,'compressedBytes':e.compress_size,'CRC':e.CRC})
 info=bounded(z,selected[0],20_000).decode();assert 'finalised: true' in info;source=bounded(z,selected[1],10_000_000)
 (p/'bounded-database-selection.json').write_text(json.dumps({'selectedMembers':receipt,'scope':'Only exact bounded database metadata and source archive members read with CRC/size/ratio/path checks. Database payload including previously refused pageDump remains unread; this is not full database archive acceptance.','defaultGuardRefusalRetained':'archive-guard-refusal.json'},indent=2)+'\n')
tree=read(c/'immutable-source-manifest.json');tracked={x['path'] for x in tree['files']}
expected={f for f in tracked if f.endswith('.swift') and (f.startswith(('ios/App/','ios/Features/','ios/UITestSupport/','ios/Extensions/')) or (f.startswith('ios/Packages/') and '/Sources/' in f))}
prefix='Users/runner/work/room-in-the-cart/room-in-the-cart/';identical={}
with zipfile.ZipFile(io.BytesIO(source)) as z:
 guard(z,'sources');assert all(n.startswith(prefix) for n in z.namelist());paths={n[len(prefix):] for n in z.namelist()};manifests={f for f in paths if f.endswith('/Package.swift')};generated={f for f in paths if f.startswith('.build/')}
 expectedManifests={f for f in tracked if f.startswith('ios/Packages/') and f.endswith('/Package.swift')}
 assert manifests==expectedManifests and paths-manifests-generated==expected
 assert generated=={'.build/SwiftCodeQLDerivedData/Build/Intermediates.noindex/RoomInTheCart.build/Release-iphoneos/RoomInTheCart.build/DerivedSources/GeneratedAssetSymbols.swift'}
 for f in sorted(paths-generated):
  raw=bounded(z,prefix+f,1_000_000);assert raw==(c/'candidate-verifiers'/f).read_bytes(),f;identical[f]=hashlib.sha256(raw).hexdigest()
raw=subprocess.check_output([gh,'api',api+'code-scanning/analyses?ref=refs%2Fpull%2F1%2Fmerge&per_page=100'],timeout=45);(p/'analyses.json').write_bytes(raw)
analysis,=[a for a in json.loads(raw) if a['category']=='/language:swift' and a['commit_sha']==merge and a['analysis_key']=='.github/workflows/ci.yml:ios-swift-codeql'];assert not analysis['error'] and sarif['invocations'][0]['executionSuccessful'];assert len(sarif.get('results',[]))==analysis['results_count']
notes=[n for n in sarif['invocations'][0].get('toolExecutionNotifications',[]) if n.get('descriptor',{}).get('id')=='swift/diagnostics/extraction-errors']
baseline=read(c.parent.parent/'candidate-804030e/swift-security/compiler-diagnostic-notifications.json')
def signature(n):
 loc=n['locations'][0]['physicalLocation'];return (loc['artifactLocation']['uri'],json.dumps(loc.get('region',{}),sort_keys=True),n['message']['text'])
proof={'candidate':head,'merge':merge,'workflowRun':rid,'jobID':j['id'],'conclusion':j['conclusion'],'artifactID':a['id'],'artifactSHA256':sha(archive),'digestVerified':True,'finalized':True,'finalizedDeclarationScope':'Verified bounded database metadata declaration; database payload not inspected','fullDatabaseArchiveGuardPassed':False,'sourceInputCoverageVerified':True,'databasePayloadUninspected':True,'expectedRepositoryRuntimeInputs':len(expected),'generatedRuntimeInputs':sorted(generated),'expectedRuntimeInputsPresent':len(expected)+len(generated),'identicalRepositorySourceFiles':len(identical),'additionalManifests':sorted(manifests),'sourceSHA256':identical,'analysisID':analysis['id'],'rules':analysis['rules_count'],'findings':analysis['results_count'],'compilerDiagnosticCount':len(notes),'compilerDiagnosticsIdenticalTo804':sorted(map(signature,notes))==sorted(map(signature,baseline)),'metrics':{m['ruleId']:m['value'] for m in sarif['properties'].get('metricResults',[])},'scopeNote':'Pinned candidate runtime source inventory is derived from source-generator roots plus package Sources; every archived repository source byte matches the frozen candidate. Generated asset symbols are present but not claimed byte-identical to a tracked source. Semantic extraction limitations remain; zero findings is not complete semantic coverage.','releaseAcceptance':False}
for name,obj in [('verification.json',proof),('compiler-diagnostic-notifications.json',notes),('job.json',j),('artifact-metadata.json',a),('analysis.json',analysis)]: (p/name).write_text(json.dumps(obj,indent=2)+'\n')
files={str(f.relative_to(p)):sha(f) for f in sorted(p.rglob('*')) if f.is_file() and f.name!='freeze.json'};(p/'freeze.json').write_text(json.dumps({'candidate':head,'runID':rid,'files':files,'releaseAcceptance':False},indent=2)+'\n')
print(json.dumps({k:proof[k] for k in ['artifactID','expectedRuntimeInputsPresent','identicalRepositorySourceFiles','rules','findings','compilerDiagnosticCount','compilerDiagnosticsIdenticalTo804','metrics']}))
