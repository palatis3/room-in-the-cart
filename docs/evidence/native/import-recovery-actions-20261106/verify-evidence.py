from pathlib import Path
import json,hashlib,sqlite3,subprocess,datetime
root=Path('/Users/palatis/Room in the Cart');r=root/'.build/ImportRecoveryNative20261106';out=Path(__file__).parent;a=r/'attempt8'
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();read=lambda p:json.loads(p.read_text())
def save(n,d):(out/n).write_text(json.dumps(d,indent=2)+'\n')
def copy(src,n):p=out/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(src.read_bytes());assert h(p)==h(src)
# Product bytes are verified from the unchanged original build directory, never the new CI build.
pbase=root/'.build/S04ProtectedVisibility20261106/DerivedData/Build/Products';pm=read(a/'products-manifest.json');rows={}
for n,s in pm.items():
 p=pbase/n;assert p.is_file() and h(p)==s,n;rows[n]=s
save('product-verification.json',{'verifiedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'productBase':str(pbase),'expectedManifestSHA256':h(a/'products-manifest.json'),'all202Matched':len(rows)==202,'verifiedFiles':rows,'scope':'Independent read-only verification before any overwrite. No claim that later shared products remain identical.'})
# Bind every source input, using exact archived overlay / Git HEAD for intentionally changed current inputs.
sm=read(a/'source-manifest.json');sr={};head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
for n,s in sm.items():
 p=root/n
 if p.is_file() and h(p)==s:sr[n]={'sha256':s,'verifiedFrom':'current matching file'};continue
 if n=='ios/UITests/ContextualNavigationUITests.swift':
  assert h(a/'ContextualNavigationUITests.swift')==s;sr[n]={'sha256':s,'verifiedFrom':'archived attempt8 overlay'};continue
 data=subprocess.check_output(['git','show',head+':'+n],cwd=root)
 assert hashlib.sha256(data).hexdigest()==s,n
 sr[n]={'sha256':s,'verifiedFrom':'git '+head}
six=read(r/'attempt6/source-manifest.json');seven=read(r/'attempt7/source-manifest.json');changed=[n for n in sm if sm[n]!=six.get(n)];assert set(changed)=={'ios/Features/Ledger/LedgerHomeView.swift','ios/UITests/ContextualNavigationUITests.swift'}
for n in ['native_recovery_driver.py','lock_protocol.py','test_native_recovery_driver.py','test_lock_protocol.py']:assert h(a/n)==h(r/'attempt6'/n)
assert (a/'ContextualNavigationUITests.swift').read_text().replace((a/'test-method.swift').read_text(),'')==(a/'original.swift').read_text()
neg=r/'attempt6/negative-app-executables';nb=read(neg/'binding.json');npm=read(r/'attempt6/products-manifest.json')
for n,s in nb.items():assert h(neg/n)==s and npm['Debug-iphonesimulator/RoomInTheCart.app/'+n]==s
save('source-verification.json',{'attempt8SourceCount':len(sm),'allManifestInputsResolved':True,'sources':sr,'changedSinceAttempt6':changed,'changedSinceAttempt7':[n for n in sm if sm[n]!=seven.get(n)],'driverAndProtocolByteIdentical6To8':True,'originalTestReconstructedExactly':True,'negativeExecutableHashesVerified':nb,'laterRegressionInstallationNotCovered':True})
# Read only the exact retained synthetic database identity, within one read transaction.
events=[json.loads(x) for x in (a/'host-run/events.jsonl').read_text().splitlines()];host=read(a/'host-run/result.json');db=Path(host['database']);bound=next(x for x in events if x['event']=='lock-acquired')['databaseIdentity'];st=db.stat();assert (st.st_dev,st.st_ino)==(bound['device'],bound['inode']);assert host['simulator']=='EF2CF945-20C5-4BF4-ACA1-A2D6F9C89C01'
saved=next(x['snapshot'] for x in events if x['event']=='retry-verified');discard=next(x['snapshot'] for x in events if x['event']=='discard-verified');assert saved==discard
c=sqlite3.connect(db.resolve().as_uri()+'?mode=ro',uri=True);c.execute('PRAGMA query_only=ON');c.execute('BEGIN');quick=c.execute('pragma quick_check').fetchone()[0];rows=c.execute('SELECT workspace_id,revision,payload,payload_sha256 FROM ledger_revisions ORDER BY revision').fetchall();heads=c.execute('SELECT id,head_revision FROM ledger_workspace').fetchall();assert quick=='ok' and len(heads)==1
history=[]
for wid,revision,payload,digest in rows:
 assert hashlib.sha256(payload).digest()==digest
 history.append({'workspaceID':wid,'revision':revision,'sha256':digest.hex()})
headrow,=[x for x in rows if x[0]==heads[0][0] and x[1]==heads[0][1]];doc=json.loads(headrow[2]);shop,=doc['workspace']['shops'];c.rollback();c.close();assert history==saved['history'] and headrow[1]==saved['headRevision'] and headrow[3].hex()==saved['payloadSHA256'] and shop==saved['shop'];assert db.stat().st_ino==bound['inode']
compact={k:v for k,v in saved.items() if k!='shop'}
save('final-readonly-sqlite.json',{'observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'openedMode':'ro','queryOnly':True,'singleReadTransaction':True,'databaseIdentityMatched':bound,'quickCheck':quick,'allHistoricalPayloadHashesVerified':True,'savedRetryEqualsDiscardVerified':True,'finalFullShopEqualsSavedRetry':True,'finalHistoryEqualsSavedRetry':True,'snapshot':compact,'databasePath':str(db),'scope':'Exact owned synthetic UITestWorkspace only. No database mutation, backup, simulator action or raw Records media access.'})
# Host protocol, saved marker linkage and immutable refs.
for phase,state in [('bootstrap','bound'),('retry-ready','locked'),('retry-failed','released'),('retry-saved','verified'),('discard-ready','locked'),('discard-failed','released'),('discard-cancelled','verified')]:
 for suffix in ['request','ack']:
  p=a/'inspection/runner-markers'/f'{phase}.{suffix}.json';d=read(p);assert d['token']==host['token'] and d['phase']==phase
  if suffix=='ack':assert d['state']==state
assert read(a/'inspection/runner-markers/done.request.json')['token']==host['token']
assert sum(x['event']=='lock-acquired' for x in events)==2 and all(x['totalChanges']==0 for x in events if x['event'] in ['lock-acquired','failed-save-unchanged'])
# Compact self-contained evidence copies; no raw databases, executables or media.
for i in [6,8]:
 d=r/f'attempt{i}'
 for n in ['native-result.json','native-identity.json','runtime.json','source-manifest.json','products-manifest.json','native-invocation.json','host-run/result.json','host-run/events.jsonl','test-method.swift']:
  copy(d/n,f'attempt{i}/'+n)
 markers=d/('inspection/runner-markers' if i==8 else 'runner-markers')
 for p in markers.glob('*.json'):copy(p,f'attempt{i}/runner-markers/'+p.name)
for n in ['test-summary.json','test-tests.json','test-runtime-warnings.json','strict.log','selectors.txt']:copy(a/'inspection'/n,'attempt8/'+n)
copy(r/'attempt6/post-discard-readback.json','attempt6/post-discard-readback.json');copy(r/'attempt6/test-summary.json','attempt6/test-summary.json');copy(r/'attempt6/discard-fix-review.md','attempt6/discard-fix-review.md')
for n in ['ios/Features/Ledger/LedgerHomeView.swift','ios/Features/Ledger/LedgerSheets.swift','ios/App/Theme.swift']:
 assert h(root/n)==sm[n];copy(root/n,'verified-source/'+n)
refs={}
for i in range(1,9):
 d=r/f'attempt{i}'
 for p in d.rglob('*'):
  if p.is_file() and ('xcresult' not in str(p)) and p.suffix in ['.json','.jsonl','.log','.swift','.py','.xctestrun','.md'] and 'failure-preview' not in p.parts and 'error-preview' not in p.parts:refs[str(p.relative_to(r))]=h(p)
refs['host-run/result.json']=h(r/'host-run/result.json');save('input-references.json',{'files':refs,'scope':'Retained evidence identities; current mutable source/build is not substituted for any earlier attempt.'})
print(json.dumps({'productsVerified':len(pm),'sourceInputsResolved':len(sr),'finalSQLiteMatchesSavedRetry':True,'negativeExecutablesVerified':len(nb),'inputReferences':len(refs)}))
