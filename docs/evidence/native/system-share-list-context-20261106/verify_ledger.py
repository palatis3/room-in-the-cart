from pathlib import Path
import sqlite3,json,hashlib,sys
p=Path(sys.argv[1]); con=sqlite3.connect(p.resolve().as_uri()+'?mode=ro',uri=True)
assert con.execute('PRAGMA quick_check').fetchone()[0]=='ok'
rows=con.execute('select revision,payload,payload_sha256 from ledger_revisions order by revision').fetchall()
assert [r[0] for r in rows]==[1,2], 'Unexpected ledger mutation after original import'
for _,data,digest in rows: assert hashlib.sha256(data).digest()==digest
ws=json.loads(rows[-1][1])['workspace']; assert len(ws['shops'])==1
s=ws['shops'][0]; assert ws['selectedShopID']==s['id']; assert s['title']=='Filtered family pickup'
assert len(s['lines'])==len(s['contributions'])==30 and len(s['importBatches'])==1
expected=[]
for i,letter in enumerate('abcdefghijklmnopqrstuvwx'):
 expected.append(('Wrap '+letter,2))
 if i%4==0: expected.append(('Soap '+letter,1))
assert [(r['name'],r['originalOrder']) for r in s['lines']]==[(name,i) for i,(name,_) in enumerate(expected)]
b=s['importBatches'][0]; preview=b['preview']; assert preview['source']=='typed'; assert preview['shopID']==s['id']
assert len(preview['lines'])==30
assert preview['originalText']=='\n'.join(f'{n} {name}' for name,n in expected)
assert b['contributionIDs']==[x['id'] for x in s['contributions']]
for line,c,prior,(name,n) in zip(s['lines'],s['contributions'],preview['lines'],expected):
 assert c['productName']==name and c['quantity']['unit']=='count' and c['quantity']['amount']=={'numerator':n,'denominator':1}
 assert c['quantity']==prior['quantity'] and c['id']==prior['id'] and c['lineID']==prior['proposedLineID']==line['id']
 assert c['source']=={'imported':{'batchID':b['id']}}
 assert set(line)=={'aisle','id','name','notes','originalOrder'}, 'Unexpected changed line state'
 assert set(c)=={'exclusions','id','lineID','notes','originalText','productName','quantity','source'}, 'Unexpected changed contribution state'
assert not any(x['name'] in ['Carrots','Apple'] for x in s['lines'])
print(json.dumps({'sqliteQuickCheck':'ok','revisions':[r[0] for r in rows],'lineCount':30,'contributionCount':30,'importCount':1,'importSource':'typed','originalNamesOrderQuantitiesAndUnitsMatch':True,'identitiesMatchPersistedOriginalPreview':True,'cancelledCarrotsAndAppleAbsent':True,'payloadSHA256':hashlib.sha256(rows[-1][1]).hexdigest(),'copiedDatabaseSHA256':hashlib.sha256(p.read_bytes()).hexdigest(),'scope':'Post-run readback compared with durable original import preview, not independently captured pre-action SQLite bytes'},indent=2))
