"""Read retained synthetic evidence; write only compact publication-candidate files."""
import copy, hashlib, json, plistlib, re
from datetime import datetime, timezone
from pathlib import Path
ROOT=Path('/Users/palatis/Room in the Cart')
P=ROOT/'.build/SelectedTextSaveUI20261106/run1';O=P.parent/'publication-candidate';PREP=P.parent/'preparation'
def read(path):return json.loads(path.read_text())
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
 return h.hexdigest()
def write(name,value):(O/name).write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')
def verify_manifest(name,base):
 entries=read(P/name)
 for relative,expected in entries.items():assert sha(base/relative)==expected,relative
 return len(entries)
source_count=verify_manifest('source-manifest.json',P/'source')
product_count=verify_manifest('products-manifest.json',P/'DerivedData/Build/Products')
controller_count=verify_manifest('controller-manifest.json',P)
sender_count=verify_manifest('sender-product-manifest.json',ROOT/'.build/SelectedTextSystem20261104/ShareProbe.app')
base=read(P/'source-baseline.json')['files'];final=read(P/'source-manifest.json');v1=read(P/'build-v1/source-manifest.json')
changed=[name for name in final if final[name]!=base[name]]
assert changed==['ios/UITests/FreeJourneyUITests.swift']
assert [name for name in final if final[name]!=v1[name]]==changed
assert (P/'source/ios/UITests/FreeJourneyUITests.swift').read_bytes()==(PREP/'FreeJourneyUITests-v2.swift').read_bytes()
identity=read(P/'native-identity.json');token=identity['token']
plan=plistlib.loads((P/'SelectedTextSave.xctestrun').read_bytes())
generated=P/'DerivedData/Build/Products/RoomInTheCart_iphonesimulator27.1-arm64.xctestrun'
assert sha(generated)==identity['generatedPlanSHA256']
original=plistlib.loads(generated.read_bytes())
def normalize(value):
 if isinstance(value,str):return value.replace('__TESTROOT__',str(generated.parent))
 if isinstance(value,list):return [normalize(x) for x in value]
 if isinstance(value,dict):return {k:normalize(v) for k,v in value.items()}
 return value
expected=normalize(original)
expected['RoomInTheCartUITests'].setdefault('EnvironmentVariables',{})['RITC_SELECTED_TEXT_SAVE_TOKEN']=token
assert plan==expected,'Unexpected token plan edit'
assert 'RITC_SELECTED_TEXT_SAVE_TOKEN' not in plan['RoomInTheCartTests'].get('EnvironmentVariables',{})
assert 'RITC_SELECTED_TEXT_SAVE_TOKEN' not in plan['RoomInTheCartUITests'].get('UITargetAppEnvironmentVariables',{})
assert 'testSystemSelectedTextReviewCancelSaveAndDismissPreserveExplicitDraft' in (P/'enumeration.json').read_text()
summary=read(P/'inspection/summary.json');assert summary['passedTests']==summary['totalTestCount']==1 and summary['failedTests']==summary['skippedTests']==summary['expectedFailures']==0
runtime=read(P/'runtime.json');device=summary['devicesAndConfigurations'][0]['device']
assert device['deviceId']==identity['simulator'] and device['osVersion']=='26.2' and device['osBuildNumber']=='23C54'
assert runtime['systemVersion']['ProductVersion']=='26.2' and runtime['systemVersion']['ProductBuildVersion']=='23C54'
assert runtime['xcode']=='Xcode 27.1\nBuild version 27A9275'
native=read(P/'native-result.json');host=read(P/'host-run/result.json')
assert native['nativeExitCode']==native['driverExitCode']==host['nativeExitCode']==0 and host['status']=='protocol-and-native-exit-success'
assert read(P/'host-run/native-exit.json')=={'token':token,'exitCode':0}
phases=['bootstrap','baseline','initial-review','cancel-reset','saved-merge','unsaved-skip','swipe-dismissed','restarted-before-add','added','final-restart']
events=[json.loads(line) for line in (P/'host-run/events.jsonl').read_text().splitlines()]
verified=[e for e in events if e['event']=='verified'];assert [x['phase'] for x in verified]==phases
requests=[e['request'] for e in events if e['event']=='request'];assert [x['phase'] for x in requests]==phases
M=P/'inspection/runner-markers';reqids=set();checkpoint=[];S={x['phase']:x['snapshot'] for x in verified}
for index,phase in enumerate(phases):
 req=read(M/(phase+'.request.json'));ack=read(M/(phase+'.ack.json'))
 assert req==requests[index]
 for field in ('token','phase','sequence','requestID'):assert req[field]==ack[field]
 assert req['token']==token and req['sequence']==index and req['requestID'] not in reqids
 reqids.add(req['requestID']);assert ack['state']==('bound' if index==0 else 'verified') and ack['error'] is None
 assert req['requestedUnixUTC']<=ack['acknowledgedUnixUTC']<=verified[index]['unixUTC']
 st=S[phase];row={'phase':phase,'sequence':index,'state':ack['state'],'requestID':req['requestID'],'requestUTC':datetime.fromtimestamp(req['requestedUnixUTC'],timezone.utc).isoformat(),'ackUTC':datetime.fromtimestamp(ack['acknowledgedUnixUTC'],timezone.utc).isoformat()}
 if st:
  row.update(ledgerHead=st['ledger']['head'],ledgerPayloadSHA256=st['ledger']['history'][-1]['sha256'],reviewSHA256=None if st['journal'] is None else st['journal']['sha256'],receiptState=None if not st['inbox'] else st['inbox'][0]['disposition'])
 checkpoint.append(row)
assert len(list(M.glob('*.request.json')))==len(list(M.glob('*.ack.json')))==10
baseline=S['baseline'];initial=S['initial-review'];saved=S['saved-merge'];added=S['added']
assert S['cancel-reset']==initial
assert saved['ledger']==baseline['ledger'] and initial['ledger']==baseline['ledger']
assert initial['inbox']==saved['inbox']
for phase in ['unsaved-skip','swipe-dismissed','restarted-before-add']:assert S[phase]==saved
assert S['final-restart']==added
bshop=baseline['ledger']['document']['workspace']['shops'][0];ashop=added['ledger']['document']['workspace']['shops'][0]
assert baseline['ledger']['head']==2 and added['ledger']['head']==3
assert added['ledger']['history'][:-1]==baseline['ledger']['history'] and len(added['ledger']['history'])==3
assert len(bshop['lines'])==len(bshop['contributions'])==len(bshop['importBatches'])==1
assert len(ashop['lines'])==2 and len(ashop['contributions'])==3 and len(ashop['importBatches'])==2 and len(ashop['allocations'])==1
assert sorted(x['name'] for x in ashop['lines'])==['Pears','Wraps']
def mapping(a):return dict(zip(a[::2],a[1::2]))
initial_draft=initial['journal']['document']['draft'];saved_draft=saved['journal']['document']['draft']
wraps,pears=saved_draft['preview']['lines'];assert wraps['name']=='Wraps' and pears['name']=='Pears'
assert mapping(initial_draft['decisions'])=={pears['id']:{'addNew':{}}}
assert mapping(saved_draft['decisions'])=={pears['id']:{'addNew':{}},wraps['id']:{'mergeDuplicate':{'_0':bshop['lines'][0]['id']}}}
assert {k:v for k,v in initial_draft.items() if k!='decisions'}=={k:v for k,v in saved_draft.items() if k!='decisions'}
operation=saved_draft['operationID'];batch=next(x for x in ashop['importBatches'] if x['id']==operation)
assert batch['preview']==saved_draft['preview'] and batch['decisions']==saved_draft['decisions']
assert batch['contributionIDs']==[wraps['id'],pears['id']]
receipt=added['inbox'][0];assert receipt['id']==operation and receipt['disposition']=='consumed' and receipt['bytes']==0 and receipt['original'] is None and receipt['edited'] is None
assert added['journal'] is None
allocation=ashop['allocations'][0];assert allocation['kind']=='duplicate' and allocation['demandContributionID']==wraps['id'] and allocation['supplyContributionID']==bshop['contributions'][0]['id']
assert allocation['quantity']['amount']=={'numerator':2,'denominator':1} and allocation['quantity']['unit']=='count'
for row in ashop['contributions']:
 n=2 if row['productName']=='Wraps' else 3
 assert row['quantity']['amount']=={'numerator':n,'denominator':1} and row['quantity']['unit']=='count'
expected_choices={'initial-review':'Choose how to add','cancel-reset':'Choose how to add','saved-merge':'Merge same need: Wraps','unsaved-skip':'Skip this line','restarted-before-add':'Merge same need: Wraps'}
ui={}
for phase,label in expected_choices.items():
 items=read(M/(phase+'.pickers.json'));assert len(items)==2
 assert sum(x['label']=='How to add this line, '+label for x in items)==1
 assert sum(x['label']=='How to add this line, Add as a separate line' for x in items)==1
 ui[phase]=items
log=(P/'native.log').read_text();lines=log.splitlines()
for label,count in [('Merge same need: Wraps',2),('Skip this line',1),('Save review draft',1),('Add reviewed list',1),('Save for review',1)]:
 assert len(re.findall(r'Tap "'+re.escape(label)+r'" Button',log))==count,(label,count)
assert len(re.findall('Check for interrupting elements affecting "Cancel" Button',log))==1
assert len(re.findall(r'Press Target Application.*\(201\.0, 86\.0\).*\(201\.0, 654\.1\)',log))==1
assert 'Review draft saved on this iPhone.' in (M/'saved-merge.ax.txt').read_text()
assert "identifier: 'Review selected text'" not in (M/'swipe-dismissed.ax.txt').read_text()
assert len(re.findall(r"Test Case .*testSystemSelectedTextReviewCancelSaveAndDismissPreserveExplicitDraft.* started\.",log))==1
assert len(re.findall(r"Test Case .*testSystemSelectedTextReviewCancelSaveAndDismissPreserveExplicitDraft.* passed",log))==1
warnings=read(P/'inspection/test-runtime-warnings.json');assert warnings['summaryWarningCount']==warnings['runtimeWarningCount']==0
notice_patterns={'xcodeOperatingSystemBuildParse':'invalidDigitCount','xcodeDebuggerVersionLookup':'debugger version lookup failed','simulatorDuplicateAccessibilityClass':'Class UIAccessibilityLoaderWebShared'}
notices={key:{'count':sum(pattern in x for x in lines),'lineNumbers':[i for i,x in enumerate(lines,1) if pattern in x]} for key,pattern in notice_patterns.items()}
assert [x['count'] for x in notices.values()]==[12,3,1]
for stage in ['build-result.json','build-v1/build-result.json','enumeration-result.json']:assert read(P/stage)['exit']==0
assert read(P/'sender-install.json')['exit']==149 and 'Shutdown' in read(P/'sender-install.json')['output'] and read(P/'sender-install-after-boot.json')['exit']==0
entitlements=read(P/'simulator-entitlements.json')
for path,contents in entitlements['entitlements'].items():assert plistlib.loads((P/path).read_bytes())==contents
for relative,bundle in entitlements['ids'].items():assert plistlib.loads((P/'DerivedData/Build/Products'/relative).read_bytes())['CFBundleIdentifier']==bundle
appent=next(v for k,v in entitlements['entitlements'].items() if k.endswith('RoomInTheCart.app-Simulated.xcent'))
shareent=next(v for k,v in entitlements['entitlements'].items() if k.endswith('RoomInTheCartShare.appex-Simulated.xcent'))
assert 'group.dev.roominthecart.app.debug.share-inbox' in appent['com.apple.security.application-groups']==['group.dev.roominthecart.app.debug.widget','group.dev.roominthecart.app.debug.share-inbox']
assert shareent['com.apple.security.application-groups']==['group.dev.roominthecart.app.debug.share-inbox']
assert 'Ran 40 tests' in (P/'controller-tests.log').read_text() and (P/'controller-tests.log').read_text().rstrip().endswith('OK')
# Hash immutable originals only; do not open them with xcresulttool or copy products.
result_files={str(x.relative_to(P/'SelectedTextSave.xcresult')):{'sha256':sha(x),'bytes':x.stat().st_size} for x in sorted((P/'SelectedTextSave.xcresult').rglob('*')) if x.is_file()}
write('original-result-files.json',result_files)
write('checkpoints.json',{'allTenRequestsAndAcknowledgementsVerified':True,'phases':checkpoint,'observedChoices':ui,'dismissGesture':read(M/'dismiss-gesture.json'),'final':{'ledgerRevision':3,'shopRevision':ashop['revision'],'lineCount':2,'contributionCount':3,'totalImportBatches':2,'selectedTextBatches':1,'duplicateAllocationCount':1,'effectiveCounts':{'Wraps':2,'Pears':3},'operationID':operation,'consumedReceipt':{k:receipt[k] for k in ['id','digest','disposition','bytes']},'originalCleared':True,'editedCleared':True,'reviewJournalRemoved':True,'finalRestartExactEquality':True}})
write('warnings.json',{'xctestRuntimeWarnings':warnings,'separateNativeLogNotices':notices,'interpretation':'Zero exported XCTest runtime warnings does not mean the native log contains no SDK/simulator notices.'})
write('validation.json',{'status':'passed','selector':'RoomInTheCartUITests/FreeJourneyUITests/testSystemSelectedTextReviewCancelSaveAndDismissPreserveExplicitDraft','nativeAttempts':1,'sourceBaseline':identity['head'],'testOverlay':'v2','passedTests':1,'failedTests':0,'skippedTests':0,'testSeconds':185.61882996559143,'supervisorSeconds':native['elapsedSeconds'],'nativeExitCode':0,'driverExitCode':0,'hostProtocol':host['status'],'checkpointsVerified':10,'offlineCoordinatorChecks':40,'platform':{'device':device['modelName'],'osVersion':'26.2','osBuild':'23C54','xcode':'27.1','xcodeBuild':'27A9275','locale':'en_US','language':'en'},'claims':{'nativeCancelResetsUnsavedMerge':True,'explicitSavePersistsMerge':True,'unsavedSkipDoesNotOverwriteSavedJournal':True,'oneNativeHeaderDragDismisses':True,'coldRestartRestoresSavedMerge':True,'oneAddCommitsOneSelectedTextBatch':True,'consumedReceiptPayloadCleared':True,'finalColdRestartDoesNotCommitAgain':True},'scopeExclusions':['Permanent CI regression','Late-completion race reproduction','Spanish UI','Physical-device validation','Third-party sender coverage','Any runtime other than actual26.2/23C54'],'gaps':[]})
write('provenance.json',{'sourceFilesVerified':source_count,'productFilesVerified':product_count,'controllerFilesVerified':controller_count,'senderFilesVerified':sender_count,'onlySourceOverlayFile':changed,'v1ToV2OnlyTestHelperChange':True,'v1AndV2BuildExits':[0,0],'senderInstallExits':[149,0],'senderSetupCorrection':'First install attempted while owned simulator was Shutdown; repeated after boot successfully before the only native test.','uiOnlyTokenPlanVerifiedAgainstGeneratedPlan':True,'builtInfoPlistAndSimulatedEntitlementsRechecked':True,'copiedResultExportsUsed':True,'originalResultFileCount':len(result_files),'originalResultBytes':sum(x['bytes'] for x in result_files.values()),'noLiveDatabaseReadNeeded':True,'reviewMethod':'Independent assertions over retained request/ack bytes, AX state, native event log, durable snapshots and frozen source/product hashes; no fresh native execution.'})
# Keep useful compact copied exports and original native event references.
for source,name in [('inspection/summary.json','native-summary.json'),('inspection/tests.json','native-tests.json'),('inspection/strict.log','strict.log')]: (O/name).write_bytes((P/source).read_bytes())
selected=[(i,x) for i,x in enumerate(lines,1) if any(t in x for t in ['Tap "Merge same need: Wraps"','Tap "Skip this line"','Tap "Save review draft"','Tap "Add reviewed list"','Tap "Save for review"','affecting "Cancel"','(201.0, 86.0)','Test Case'])]
(O/'native-action-excerpts.log').write_text('\n'.join(f'{i}: {x}' for i,x in selected)+'\n')
inputs=['native-identity.json','native-result.json','native-invocation.json','native.log','runtime.json','simulator-entitlements.json','source-baseline.json','source-manifest.json','products-manifest.json','controller-manifest.json','sender-product-manifest.json','sender-install.json','sender-install-after-boot.json','build-result.json','build-invocation.json','build-v1/build-result.json','build-v1/build-invocation.json','build-v1/source-manifest.json','enumeration.json','enumeration-result.json','SelectedTextSave.xctestrun','selected_text_coordinator.py','controller-tests.log','host-run/events.jsonl','host-run/result.json','host-run/native-exit.json','inspection/summary.json','inspection/tests.json','inspection/test-runtime-warnings.json','inspection/strict.log']
manifest={str(Path('run1')/name):sha(P/name) for name in inputs}
manifest.update({str(Path('run1/inspection/runner-markers')/x.name):sha(x) for x in sorted(M.iterdir()) if x.is_file()})
write('input-hashes.json',manifest)
print(json.dumps({'verifiedSourceFiles':source_count,'verifiedProducts':product_count,'verifiedControllerFiles':controller_count,'checkpoints':len(checkpoint),'originalResultFiles':len(result_files),'result':'passed'},indent=2))
