#!/usr/bin/env python3
"""Audit retained negative evidence only; no test/native/simulator/Git actions."""
from pathlib import Path
import datetime, difflib, hashlib, json, re, shutil, sqlite3
OUT=Path(__file__).resolve().parent;ROOT=OUT.parent;NEG=ROOT/'timeout-negative';RUN=NEG/'corrected-selection';POS=ROOT/'local-diagnostic';WORK=ROOT/'negative-payload-audit-inputs'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text())
def save(f,x):
 p=OUT/f;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(x,indent=2,ensure_ascii=False)+'\n')
def manifest(p):return {str(f.relative_to(p)):sha(f) for f in sorted(p.rglob('*')) if f.is_file()}
def check(p,m):
 assert all((p/f).is_file() and sha(p/f)==h for f,h in m.items());return len(m)
original=RUN/'StoreKit.xcresult';original_manifest=read(RUN/'original-bundle-sha256.json')
assert manifest(original)==original_manifest and len(original_manifest)==93
save('original-negative-bundle-sha256.json',original_manifest)
# Existing copied metadata only. Decoder proof is bound to the stored original
# payload hash and to the exact expected line, never accepted by filename alone.
db=RUN/'inspection/StoreKit.xcresult/database.sqlite3';db_sha=sha(db)
assert sha(WORK/'database.sqlite3')==db_sha
c=sqlite3.connect((WORK/'database.sqlite3').as_uri()+'?mode=ro',uri=True);c.row_factory=sqlite3.Row
rows=[dict(x) for x in c.execute("select a.name,a.uuid,a.uniformTypeIdentifier,a.lifetime,a.xcResultKitPayloadRefId,tr.result,t.identifier,tr.identifierURL from Attachments a join Activities b on a.activity_fk=b.rowid join TestCaseRuns tr on b.testCaseRun_fk=tr.rowid join TestCases t on tr.testCase_fk=t.rowid where t.identifier='StoreKitScenarioTests/testSimulatedPurchaseCancellationGrantsNothing()'")];c.close()
assert len(rows)==25
log=(RUN/'native.log').read_text();lines=re.findall(r'^StoreKitCancellationTrace seq=(\d+) elapsed=(.+?) stage=(\S+)$',log,re.M)
assert [int(n) for n,e,s in lines]==list(range(1,26))
expected={int(n):f'StoreKitCancellationTrace seq={n} elapsed={e} stage={s}' for n,e,s in lines}
decoding=read(OUT/'payload-storage-decoding.json');audit=[]
for row in rows:
 match=re.fullmatch('StoreKitCancellation-stage-(\d+)',row['name']);assert match
 seq=int(match[1]);assert row['result']=='Failure' and row['lifetime']=='keepAlways' and row['uniformTypeIdentifier']=='public.plain-text'
 ref=row['xcResultKitPayloadRefId'];assert re.fullmatch(r'0~[A-Za-z0-9_=-]+',ref)
 member='Data/data.'+ref;stored=(RUN/'inspection/StoreKit.xcresult'/member).read_bytes();stored_sha=hashlib.sha256(stored).hexdigest();assert original_manifest[member]==stored_sha
 entry=next(x for x in decoding['payloads'] if x['payloadID']==ref);assert entry['storedSHA256']==stored_sha
 data=(WORK/'decoded'/ref).read_bytes();assert len(data)<=4096 and hashlib.sha256(data).hexdigest()==entry['decodedSHA256']
 assert data.decode('utf-8')==expected[seq]
 name=f'attachments/stage-{seq:02}.txt';(OUT/name).parent.mkdir(exist_ok=True);(OUT/name).write_bytes(data)
 row.update({'sequence':seq,'exportedPath':name,'sha256':entry['decodedSHA256'],'storageEncoding':entry['encoding'],'originalBundleMember':member,'storedMemberSHA256':stored_sha,'matchesOriginalBundle':True});audit.append(row)
assert sorted(x['sequence'] for x in audit)==list(range(1,26))
open_stages=[]
for _,_,stage in lines:
 stem,kind=stage.rsplit('.',1)
 if kind=='begin':open_stages.append(stem)
 elif kind=='end':assert open_stages.pop()==stem
 else:raise AssertionError(stage)
assert open_stages==['body','model.purchase','storefront.purchase']
assert lines[-1][2]=='storefront.purchase.begin' and lines[-1][1]=='0.818443709 seconds'
save('attachment-audit.json',{'stageCount':25,'allExactlyMatchStderr':True,'metadataSourceSHA256':db_sha,'metadataReadFromCopy':True,'otherPayloadsExported':False,'attachments':sorted(audit,key=lambda x:x['sequence'])})
(OUT/'stage-trace.txt').write_text('\n'.join(expected[n] for n in range(1,26))+'\n')
sm=read(NEG/'source-manifest.json');pm=read(POS/'source-manifest.json');counts={'negativeSource':check(NEG/'source',sm),'positiveSource':check(POS/'source',pm),'negativeProducts':check(NEG/'DerivedData/Build/Products',read(NEG/'products-manifest.json'))}
assert set(sm)==set(pm)
changed=[f for f in sm if sm[f]!=pm[f]];assert changed==['ios/Tests/StoreKitScenarioTests.swift']
p=(POS/'source'/changed[0]).read_text();n=(NEG/'source'/changed[0]).read_text()
anchor='            defer { trace("storefront.purchase.end") }\n'
addition='            // NEGATIVE CONTROL ONLY: must hit the unchanged 120-second limit.\n            try await Task.sleep(for: .seconds(180))\n'
assert p.count(anchor)==1 and n==p.replace(anchor,anchor+addition)
(OUT/'negative-source-only.patch').write_text(''.join(difflib.unified_diff(p.splitlines(True),n.splitlines(True),fromfile='positive/ios/Tests/StoreKitScenarioTests.swift',tofile='negative/ios/Tests/StoreKitScenarioTests.swift')))
wrong=read(NEG/'native-invocation.json');correct=read(RUN/'native-invocation.json');positive=read(POS/'native-invocation.json')
for invocation in [wrong,correct,positive]:
 cmd=invocation['command']
 for flag,value in [('-default-test-execution-time-allowance','120'),('-maximum-test-execution-time-allowance','120'),('-parallel-testing-enabled','NO'),('-test-timeouts-enabled','YES')]:assert cmd[cmd.index(flag)+1]==value
assert len(wrong['command'])==len(correct['command'])
diff=[{'index':i,'wrong':a,'corrected':b} for i,(a,b) in enumerate(zip(wrong['command'],correct['command'])) if a!=b]
assert len(diff)==2
assert {x['index'] for x in diff}=={wrong['command'].index('-resultBundlePath')+1,len(wrong['command'])-2}
assert 'RoomInTheCartStoreKitTests/' in diff[-1]['wrong'] and 'RoomInTheCartTests/' in diff[-1]['corrected']
assert wrong['cwd']==correct['cwd']
wrong_log=(NEG/'native.log').read_text();wrong_result=read(NEG/'native-result.json');result=read(RUN/'native-result.json')
assert wrong_result['exit']==70 and not wrong_result['supervisorExpired']
assert 'isn’t a member of the specified test plan or scheme' in wrong_log and 'Test Case ' not in wrong_log and 'StoreKitCancellationTrace' not in wrong_log
assert result['exit']==65 and not result['supervisorExpired']
starts=re.findall(r"Test Case '-\[RoomInTheCartTests.StoreKitScenarioTests (\w+)\]' started\.",log)
assert starts==['testSimulatedPurchaseCancellationGrantsNothing']
assert log.count('exceeded execution time allowance of 2 minutes.')==1 and log.count('Restarting after unexpected exit, crash, or test timeout')==1
assert log.count('** TEST EXECUTE FAILED **')==1 and '** TEST EXECUTE SUCCEEDED **' not in log
summary=read(RUN/'inspection/summary.json');assert [summary[k] for k in ['passedTests','failedTests','skippedTests','totalTestCount']]==[0,1,0,1]
assert read(RUN/'inspection/strict-result.json')['exit']==1
assert '120.00' in (RUN/'inspection/strict.log').read_text()
cleanup=read(NEG/'cleanup.json');assert cleanup['simulator']==read(NEG/'owned-simulator.json')['id']
assert [(x['operation'],x['exit']) for x in cleanup['operations']]==[('shutdown',0),('delete',0)]
for name in ['source-manifest.json','products-manifest.json','build-invocation.json','build-result.json','native-invocation.json','native-result.json','native.log','execution-complete.json','owned-simulator.json','cleanup.json']:
 dest=OUT/('initial-selection/'+name if name in ['native-invocation.json','native-result.json','native.log','execution-complete.json'] else name);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(NEG/name,dest)
for name in ['native-invocation.json','native-result.json','native.log','selection-correction.json','runtime.json','selectors.txt','inspection/strict-result.json','inspection/strict.log','inspection/summary.json','inspection/tests.json','inspection/test-runtime-warnings.json']:
 dest=OUT/'corrected-selection'/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(RUN/name,dest)
assert manifest(original)==original_manifest and sha(db)==db_sha
save('audit-result.json',{'scope':'Artificial timeout validates diagnostic evidence survival only; original hosted English timeout remains unresolved','auditedAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'baseCandidate':'8d1a79b22981148839c6e3d0827c6710f877a369','negativeChange':'Single 180-second sleep (plus identifying comment) in test-only forwarding purchase before the real adapter call','sourceComparison':{'filesCompared':len(sm),'changedFiles':changed,'exactExpectedChangeOnly':True,'allRecordedHashesMatch':True},'rehashCounts':counts,'deadlineSeconds':120,'initialSelection':{'exit':70,'testCasesStarted':0,'cause':'Nonexistent target not in plan/scheme; not a test outcome','supervisorExpired':False},'correctedSelection':{'exit':65,'strictExit':1,'testCasesStarted':1,'passed':0,'failed':1,'skipped':0,'timeoutSeconds':120,'runnerRestarts':1,'supervisorExpired':False,'firstActualExecution':True,'commandDifferences':diff},'retainedTrace':{'stderrLines':25,'stagePayloads':25,'allPayloadsExactlyMatchStderr':True,'lastStage':'storefront.purchase.begin','lastElapsedSeconds':0.818443709,'openStages':open_stages,'postpurchaseAndTeardownMarkersAbsent':True},'originalBundleMembersUnchanged':93,'rootOwnedCleanup':{'simulator':cleanup['simulator'],'shutdownExit':0,'deleteExit':0,'receiptSHA256':sha(NEG/'cleanup.json')},'positiveEvidenceFreezeSHA256':sha(ROOT/'positive-evidence/freeze.json'),'originalHostedRun':42337977943,'originalHostedArtifact':13560692753,'limitations':['Injected suspension occurs before the real adapter purchase call; this does not reproduce a StoreKit defect.','This proves retention across this local XCTest timeout/restart, not arbitrary process-crash or hosted-toolchain behavior.','Local Xcode27.1 differs from original hosted26.3; iOS26.2/23C54 matches.','Original hosted await/cause remains unknown.','Initial execution-complete expected text describes supervisor intent; exit70 was a selection failure, not a timeout.'],'integrationRecommendation':'Promote only diagnostic.patch from the positive package plus explicitly scoped evidence; never the 180-second sleep. Preserve timeout/failure strict gates and original failure. No additional local repetition needed for logger-survival claim.','nativeCommandsByInvestigator':False,'otherMediaExported':False,'productFixEstablished':False,'releaseAcceptance':False})
print(json.dumps({'auditPassed':True,'stderrLines':25,'stagePayloads':25,'lastStage':lines[-1][2],'openStages':open_stages,'originalBundleMembersUnchanged':93,'rehashCounts':counts,'initialSelectionExit':70,'actualNegativeExit':65,'strictExit':1},indent=2))
