#!/usr/bin/env python3
"""Read existing positive evidence; write only this scratch evidence directory."""
from pathlib import Path
import datetime, hashlib, json, re, shutil, sqlite3
OUT = Path(__file__).resolve().parent
ROOT = OUT.parent
LOCAL = ROOT / 'local-diagnostic'
REPO = ROOT.parents[1]
HOSTED = REPO / '.build/CIResearch20261106/candidate-8d1a79b/core-collection'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
def save(name, obj):
    p = OUT/name; p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, indent=2, ensure_ascii=False)+'\n')
def manifest(root):
    return {str(p.relative_to(root)):sha(p) for p in sorted(root.rglob('*')) if p.is_file()}
def check_manifest(root, expected):
    missing=[f for f in expected if not (root/f).is_file()]
    changed=[f for f,h in expected.items() if (root/f).is_file() and sha(root/f)!=h]
    assert not missing and not changed, (missing,changed)
    return len(expected)
original = LOCAL/'StoreKit.xcresult'
original_before = manifest(original)
save('original-positive-bundle-sha256.json',original_before)
hosted_bundle=HOSTED/'storekit-en-1/StoreKit.xcresult'
hosted_before=json.loads((ROOT/'original-xcresult-member-sha256.json').read_text())
assert manifest(hosted_bundle)==hosted_before
assert sha(HOSTED/'storekit-en-1.zip')=='f2d7d89ed4221654e391043fed88249249c36f6e1325c2f39ac6350d67fd432c'
save('original-hosted-bundle-sha256.json',hosted_before)
# Existing inspection SQLite is an xcresulttool-produced derivative. Copy it,
# query read-only, and bind every selected raw text payload to the original bundle.
db=LOCAL/'inspection/StoreKit.xcresult/database.sqlite3'
db_before=sha(db)
work=ROOT/'positive-payload-audit-inputs';work.mkdir(exist_ok=True)
shutil.copy2(db,work/'database.sqlite3')
c=sqlite3.connect((work/'database.sqlite3').as_uri()+'?mode=ro',uri=True)
c.row_factory=sqlite3.Row
case='StoreKitScenarioTests/testSimulatedPurchaseCancellationGrantsNothing()'
rows=[dict(row) for row in c.execute('''
SELECT a.name,a.uuid,a.lifetime,a.uniformTypeIdentifier,a.timestamp,
       a.xcResultKitPayloadRefId, a.filenameOverride,
       t.identifier AS testIdentifier, tr.result AS testResult,
       tr.identifierURL AS testIdentifierURL
FROM Attachments a JOIN Activities b ON a.activity_fk=b.rowid
JOIN TestCaseRuns tr ON b.testCaseRun_fk=tr.rowid
JOIN TestCases t ON tr.testCase_fk=t.rowid
WHERE t.identifier=? ORDER BY a.rowid''',(case,))]
c.close()
assert len(rows)==51
raw_log=(LOCAL/'native.log').read_text()
raw_markers=re.findall(r'^StoreKitCancellationTrace seq=(\d+) elapsed=(.+?) stage=(\S+)$',raw_log,re.M)
assert [int(n) for n,_,_ in raw_markers]==list(range(1,51))
expected_lines={int(n):f'StoreKitCancellationTrace seq={n} elapsed={elapsed} stage={stage}' for n,elapsed,stage in raw_markers}
trace_review=json.loads((LOCAL/'trace-review.json').read_text())
assert trace_review['markers']==[{'sequence':int(n),'elapsed':e,'stage':s} for n,e,s in raw_markers]
assert trace_review['strictExit']==0
stage_rows=[]; summary_rows=[]
for row in rows:
    assert row['testResult']=='Success'  # Recorded SQLite enum; public export says Passed.
    assert row['lifetime']=='keepAlways' and row['uniformTypeIdentifier']=='public.plain-text'
    stage=re.fullmatch(r'StoreKitCancellation-stage-(\d+)',row['name'])
    assert stage or row['name']=='Cancelled purchase — structural state only'
    ref=row['xcResultKitPayloadRefId']
    assert re.fullmatch(r'0~[A-Za-z0-9_=-]+',ref)
    member='Data/data.'+ref
    # Only the 51 allowlisted cancellation text payloads are read/exported.
    data=(LOCAL/'inspection/StoreKit.xcresult'/member).read_bytes()
    assert hashlib.sha256(data).hexdigest()==original_before[member]
    stored_sha=hashlib.sha256(data).hexdigest()
    decoding=json.loads((OUT/'payload-storage-decoding.json').read_text())
    entry=next(x for x in decoding['payloads'] if x['payloadID']==ref)
    assert entry['storedSHA256']==stored_sha
    if data.startswith(bytes.fromhex('28b52ffd')):
        assert entry['encoding']=='zstd'
        data=(work/'decoded'/ref).read_bytes()
    else:
        assert entry['encoding']=='raw'
    assert len(data)<=4096 and hashlib.sha256(data).hexdigest()==entry['decodedSHA256']
    text=data.decode('utf-8')
    if stage:
        n=int(stage[1]); assert text==expected_lines[n]
        path=f'attachments/stage-{n:02}.txt'
        row['sequence']=n;stage_rows.append(row)
    else:
        assert text=='historyStates=[2]; current=0; unfinished=0'
        path='attachments/cancellation-summary.txt';summary_rows.append(row)
    (OUT/path).parent.mkdir(exist_ok=True)
    (OUT/path).write_bytes(data)
    row.update({'exportedPath':path,'sha256':hashlib.sha256(data).hexdigest(),'originalBundleMember':member,'storedMemberSHA256':stored_sha,'storageEncoding':entry['encoding'],'storedPayloadMatchesOriginalBundleMember':True})
assert sorted(x['sequence'] for x in stage_rows)==list(range(1,51)) and len(summary_rows)==1
save('attachment-audit.json',{'testIdentifier':case,'metadataSource':'existing xcresulttool-generated inspection SQLite; copied then read-only queried','metadataSourceSHA256':db_before,'stageAttachmentCount':50,'summaryAttachmentCount':1,'allStagePayloadsExactlyMatchNativeLog':True,'allPayloadsBoundToOriginalBundle':True,'attachments':sorted(stage_rows,key=lambda x:x['sequence'])+summary_rows})
counts={}
for filename,base in [('source-manifest.json','source'),('products-manifest.json','positive-products')]:
    m=json.loads((LOCAL/filename).read_text()); counts[base]=check_manifest(LOCAL/base,m)
    shutil.copy2(LOCAL/filename,OUT/filename)
counts['executedProducts']=check_manifest(LOCAL/'DerivedData/Build/Products',json.loads((LOCAL/'products-manifest.json').read_text()))
assert (LOCAL/'source/ios/Tests/StoreKitScenarioTests.swift').read_bytes()==(ROOT/'proposal/ios/Tests/StoreKitScenarioTests.swift').read_bytes()
order_pattern=r"Test Case '-\[RoomInTheCartTests.StoreKitScenarioTests (\w+)\]' started\."
local_order=re.findall(order_pattern,raw_log)
assert len(local_order)==15 and local_order==re.findall(order_pattern,(HOSTED/'storekit-en-1/StoreKit.log').read_text())
assert not re.search(r'Restarting after|exceeded execution time allowance',raw_log)
assert raw_log.count('** TEST EXECUTE SUCCEEDED **')==1
summary=json.loads((LOCAL/'inspection/summary.json').read_text())
assert [summary[k] for k in ['passedTests','failedTests','skippedTests','totalTestCount']]==[15,0,0,15]
warn=json.loads((LOCAL/'inspection/test-runtime-warnings.json').read_text())
assert warn['runtimeWarningCount']==0 and warn['examinedTestCount']==15
for filename in ['build-result.json','native-result.json']:
    assert json.loads((LOCAL/filename).read_text())['exit']==0
for filename in ['build-invocation.json','build-result.json','native-invocation.json','native-result.json','runtime.json','owned-simulator.json','cleanup.json','trace-review.json','selectors.txt','inspection/summary.json','inspection/tests.json','inspection/strict.log','inspection/test-runtime-warnings.json']:
    dest=OUT/filename;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(LOCAL/filename,dest)
shutil.copy2(ROOT/'cancellation-stage-diagnostic.patch',OUT/'diagnostic.patch')
shutil.copy2(ROOT/'source-manifest.json',OUT/'diagnostic-source-manifest.json')
shutil.copy2(ROOT/'test-details.json',OUT/'original-hosted-failed-test-details.json')
shutil.copy2(HOSTED/'evidence/storekit.json',OUT/'original-hosted-storekit.json')
shutil.copy2(HOSTED/'evidence/archive-storekit-en-1.json',OUT/'original-hosted-archive.json')
(OUT/'stage-trace.txt').write_text('\n'.join(expected_lines[n] for n in range(1,51))+'\n')
cleanup=json.loads((LOCAL/'cleanup.json').read_text())
assert cleanup['simulator']==json.loads((LOCAL/'owned-simulator.json').read_text())['id']
assert [(x['operation'],x['exit']) for x in cleanup['operations']]==[('shutdown',0),('delete',0)]
assert manifest(original)==original_before
assert manifest(hosted_bundle)==hosted_before
assert sha(db)==db_before
save('audit-result.json',{
 'candidate':'8d1a79b22981148839c6e3d0827c6710f877a369',
 'scope':'Local diagnostic-only nonreproduction; original hosted timeout unresolved',
 'auditedAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'originalHosted':{'runID':42337977943,'attempt':1,'jobID':128299120073,'artifactID':13560692753,'passed':14,'failed':1,'timeoutSeconds':120,'runnerRestart':True,'originalBundleFilesUnchanged':len(hosted_before)},
 'localPositive':{'passed':15,'failed':0,'skipped':0,'runtimeWarnings':0,'strictExit':0,'cancellationDurationSeconds':0.266,'markers':50,'originalHostedOrderMatches':True,'originalBundleFilesUnchanged':len(original_before)},
 'rehashCounts':counts,'builtTestSourceMatchesProposal':True,
 'attachmentAudit':{'allowlistedTextPayloads':51,'markerPayloads':50,'allMatchOriginalBundle':True,'allMarkersExactlyMatchRawLog':True,'otherMediaExported':False},
 'rootOwnedCleanup':{'simulator':cleanup['simulator'],'shutdownExit':0,'deleteExit':0,'receiptSHA256':sha(LOCAL/'cleanup.json'),'scope':'Only the locally owned positive diagnostic simulator; investigator performed no simulator action'},
 'inputReceiptHashes':{f:sha(LOCAL/f) for f in ['native.log','build.log','trace-review.json','source-manifest.json','products-manifest.json','inspection/strict.log']},
 'limitations':['This run cannot locate or explain the original suspended await.','Instrumentation changes scheduling.','Local iOS26.2/23C54 matches hosted runtime; local Xcode27.1 differs from hosted Xcode26.3 and local iPhone17Pro differs from hosted iPhone17.','Positive completion proves normal-path marker persistence, not timeout/crash persistence.','No Spanish diagnostic run is included. Same-source original Spanish15/15 does not clear English.','Zero runtime warnings is not a warning-free build claim.','Negative supervisor/invocations/results are outside this audit.','Cleanup receipt covers only the root-owned positive diagnostic simulator; no product-fix/release-acceptance claim is included.'],
 'investigatorActions':{'nativeCommands':False,'buildOrTestExecution':False,'simulatorActions':False,'gitOrTrackedSourceChanges':False,'hostedActions':False},
 'releaseAcceptance':False,'productFixEstablished':False})
print(json.dumps({'stagePayloads':50,'summaryPayloads':1,'originalPositiveMembers':len(original_before),'originalHostedMembers':len(hosted_before),'rehashCounts':counts,'allAuditsPassed':True},indent=2))
