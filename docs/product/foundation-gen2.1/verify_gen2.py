"""Adversarial checks on the *reference* data model and the portable handoff."""
from pathlib import Path
import re, sqlite3, json, hashlib, zipfile
import xml.etree.ElementTree as ET
from compose_master import master
ROOT=Path(__file__).resolve().parent

def integrity():
    db=sqlite3.connect(':memory:',cached_statements=0)
    db.executescript((ROOT/'contracts/model.sql').read_text(encoding='utf8'))
    def run(sql,*args): return db.execute(sql,args)
    def add(t,**kw):
        run(f"INSERT INTO {t} ({','.join(kw)}) VALUES ({','.join(['?']*len(kw))})",*kw.values())
    def row(t,**kw): add(t,household_id='H',**kw)
    def reject(f):
        try: f()
        except sqlite3.IntegrityError: return
        raise AssertionError('invalid state accepted')
    T='2026-11-02T18:00:00Z'
    row('household',mode='service',display_name='Fixture',zone='America/New_York')
    for person in ['Mia','Alex','Dev','Sam']:
        row('member',member_id=person,alias=person,kind='child' if person=='Sam' else 'adult',state='active',
            verified_subject=None if person=='Sam' else 'fixture:'+person)
    reject(lambda:run("UPDATE member SET organizer=1 WHERE member_id='Sam'"))
    relation=dict(child_id='Sam',guardian_id='Mia')
    consent=dict(consent_id='yes',notice_version='1',verification_reference='opaque-vpc-proof',granted_at=T)
    reject(lambda:row('guardian_consent',**relation,**consent))
    reject(lambda:row('guardian_relationship',child_id='Sam',guardian_id='Sam',proof_ref='invalid'))
    row('guardian_relationship',**relation,proof_ref='opaque-proof')
    row('guardian_consent',**relation,**consent)
    run("DELETE FROM guardian_relationship WHERE household_id='H' AND child_id='Sam' AND guardian_id='Mia'")
    assert run('SELECT revoked_at FROM guardian_consent').fetchone()[0]
    reject(lambda:run("UPDATE guardian_consent SET revoked_at=NULL"))
    reject(lambda:row('planning_access',member_id='Sam'))
    row('planning_access',member_id='Mia')
    purchase=dict(environment='sandbox',bundle_id='fixture.app',original_transaction_ref='orig')
    row('apple_purchase_binding',purchaser_id='Mia',**purchase)
    for seq in [1,2]:
        tx='tx'+str(seq)
        add('apple_transaction_identity',transaction_ref=tx,**purchase)
        row('entitlement',entitlement_id=tx,purchaser_id='Mia',product_id='year',transaction_ref=tx,
            state='active',verified_at=T,valid_until='2027-11-02T18:00:00Z',**purchase)
    def seat(person,tx,k):row('seat',seat_id=person,entitlement_id=tx,member_id=person,seat_number=k)
    reject(lambda:seat('Sam','tx1',1))
    seat('Mia','tx1',1);seat('Alex','tx1',2)
    reject(lambda:seat('Dev','tx2',1))
    run("UPDATE member SET state='revoked' WHERE member_id='Alex'")
    seat('Dev','tx2',2)
    row('shop',shop_id='S',shopper_id='Mia',currency='USD',cap_scope='whole',zone='America/New_York')
    reject(lambda:run("UPDATE member SET state='revoked' WHERE member_id='Mia'"))
    for n in (1,2):row('shop_revision',revision_id=f'r{n}',shop_id='S',parent_id='r1' if n==2 else None,
                         display_no=n,author_id='Mia',content_digest=f'h{n}',snapshot_json='{}',committed_at=T)
    row('quantity',quantity_id='q',original_text='one',source_locale='en-US',numerator=1,denominator=1,unit='each')
    row('shop_line',line_id='cereal',shop_id='S',original_text='cereal',source_locale='en-US')
    row('order_line',order_line_id='ol',shop_id='S',order_id='o',line_id='cereal',confirmed_quantity_id='q')
    row('placed_order',order_id='o',shop_id='S',revision_id='r1',reporter_id='Mia',evidence_source='shopper',reported_at=T)
    reject(lambda:run("UPDATE placed_order SET revision_id='r2'"))
    reject(lambda:run("UPDATE order_line SET order_line_id='rewrite'"))
    def entry(k,kind,status,cents,link=None,currency='USD'):
        row('ledger_entry',shop_id='S',entry_id=k,source_record_key=k,kind=kind,status=status,signed_minor=cents,
            linked_charge_id=link,currency=currency,basis='receipt',observed_at=T)
    reject(lambda:entry('self','credit','included',-240,'self'))
    reject(lambda:entry('hold','hold','posted',500))
    entry('charge','charge','posted',3480)
    reject(lambda:entry('wrong','credit','included',-240,'charge','CAD'))
    entry('credit','credit','included',-240,'charge')
    entry('maybe','credit','pending',None)
    reject(lambda:run("UPDATE ledger_entry SET signed_minor=3720 WHERE entry_id='charge'"))
    assert run("SELECT SUM(signed_minor) FROM ledger_entry WHERE status='posted'").fetchone()==(3480,)
    def ingest(fid,digest,state):
        row('file_projection',file_id=fid,origin_ref='device1',source_record_ref='S',source_revision_ref='r1',
            projection_digest='scope1',content_digest=digest,kind='backup',format_version=1,saved_at=T,
            state=state,manifest_json='{}')
    ingest('one','abc','imported');reject(lambda:ingest('two','xyz','imported'))
    ingest('two','xyz','quarantined')
    reject(lambda:run("UPDATE file_projection SET state='imported' WHERE file_id='two'"))
    reject(lambda:run("UPDATE file_projection SET content_digest='changed' WHERE file_id='one'"))
    row('device',device_id='phone',member_id='Mia')
    op=dict(actor_id='Mia',device_id='phone',client_key='one-intent',kind='proposal.apply',committed_at=T)
    row('operation',operation_id='op1',payload_digest='d1',**op)
    row('operation_response',operation_id='op1',outcome_json='{"result":"applied","revision":"r2"}')
    row('shop_head',head_id='head',shop_id='S',revision_id='r1')
    row('proposal',proposal_id='p',shop_id='S',owner_id='Mia',kind='guest',state='submitted',created_at=T)
    row('proposal_revision',proposal_revision_id='pr',shop_id='S',proposal_id='p',revision_no=1,
        base_revision_id='r1',base_authority_epoch=1,editor_id='Mia',inputs_json='{}',effects_json='{}',reviewed_at=T)
    row('proposal_application',application_id='accepted',shop_id='S',proposal_id='p',proposal_revision_id='pr',
        result_revision_id='r2',shopper_id='Mia',operation_id='op1',applied_at=T)
    run("UPDATE proposal SET state='applied' WHERE proposal_id='p'")
    run("UPDATE shop_head SET revision_id='r2' WHERE shop_id='S'")
    run("UPDATE shop SET revision_no=2 WHERE shop_id='S'")
    row('event',event_id='ev',operation_id='op1',actor_id='Mia',shop_id='S',kind='proposal.applied',evidence_json='{}',observed_at=T)
    def replay(digest): # same authenticated, still-authorized actor in a live window
        found=run("""SELECT o.payload_digest,r.outcome_json FROM operation o LEFT JOIN operation_response r
            USING (household_id,operation_id) WHERE o.household_id='H' AND o.actor_id='Mia' AND o.client_key='one-intent'""").fetchone()
        assert found
        if found[1] is None:return 'refresh_required'
        if found[0]!=digest:return 'key_reused'
        return json.loads(found[1])['result']
    assert replay('d1')=='applied' and replay('changed')=='key_reused'
    # A connection policy demonstrates the required ordinary/maintenance split.
    # Production exposes reviewed prepared commands only (no SQL text or REPLACE from clients).
    protected={'operation','operation_response','retired_operation','placed_order','order_line','ledger_entry','shop_revision','file_projection'}
    def ordinary(action,table,column,db_name,trigger):
        return sqlite3.SQLITE_DENY if action==sqlite3.SQLITE_DELETE and table in protected else sqlite3.SQLITE_OK
    db.set_authorizer(ordinary)
    try:run("DELETE FROM placed_order WHERE order_id='o'")
    except sqlite3.DatabaseError as e:assert 'authorized' in str(e)
    else:raise AssertionError('runtime deletion permitted')
    db.set_authorizer(None) # privileged, scoped maintenance, not an ordinary client capability
    run("DELETE FROM operation_response WHERE household_id='H' AND operation_id='op1'")
    assert replay('d1')==replay('changed')=='refresh_required'
    assert run('SELECT COUNT(*) FROM operation_response').fetchone()==(0,)
    assert run("SELECT e.operation_id,a.operation_id,h.revision_id FROM event e JOIN proposal_application a USING(household_id,operation_id) JOIN shop_head h USING(household_id,shop_id)").fetchall()==[('op1','op1','r2')]
    reject(lambda:row('operation_response',operation_id='op1',outcome_json='{}'))
    for digest in ['d1','changed']: reject(lambda:row('operation',operation_id='op2',payload_digest=digest,**op))
    assert run("SELECT COUNT(*) FROM retired_operation").fetchone()==(1,)
    assert not run('PRAGMA foreign_key_check').fetchall()
    db.close()

def launch():
    assert (ROOT/'CODEX-MASTER.md').read_text(encoding='utf8')==master()
    data=json.loads((ROOT/'launch/listing.json').read_text(encoding='utf8'))
    ns={'x':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
    with zipfile.ZipFile(ROOT/'launch/Room in the Cart keyword planner.xlsx') as z:
        assert z.testzip() is None
        sheets=ET.fromstring(z.read('xl/workbook.xml')).findall('x:sheets/x:sheet',ns)
        sheet_names=[sh.get('name') for sh in sheets]
        strings=[]
        if 'xl/sharedStrings.xml' in z.namelist():
            strings=[''.join(e.itertext()) for e in ET.fromstring(z.read('xl/sharedStrings.xml'))]
        def cells(name):
            xml=ET.fromstring(z.read(f'xl/worksheets/sheet{1+sheet_names.index(name)}.xml'))
            out={}
            for c in xml.findall('.//x:c',ns):
                v=c.findtext('x:v','',ns)
                out[c.get('r')]=strings[int(v)] if c.get('t')=='s' else ''.join(t.text or '' for t in c.findall('.//x:t',ns)) if c.get('t')=='inlineStr' else v
            return out
        w=cells('Listing workshop')
        assert [w['C'+str(i)] for i in (5,6,7)]==[data[k] for k in ('name','subtitle','keywords')]
        assert all(w[f'G{i}']=='Fits' for i in range(5,14))
        p=cells('Priority phrases')
        assert [p[f'A{i}'] for i in range(5,11)]==[r['phrase'] for r in data['priority']]
        assert all(int(p[f'C{i}'])==r['volume_score'] and int(p[f'D{i}'])==r['difficulty_score'] for i,r in enumerate(data['priority'],5))
        bank=cells('Keyword bank')
        assert len([k for k in bank if re.fullmatch(r'A\d+',k) and int(k[1:])>=5 and bank[k]])==383
    guide=(ROOT/'09-keywords.md').read_text(encoding='utf8')
    assert all(data[k] in guide for k in ('name','subtitle','keywords'))
    assert len(data['name'])==30 and len(data['subtitle'])==28 and len(data['keywords'].encode())==95
    evidence=ROOT/'launch/Gen 15 keyword evidence.zip'
    with zipfile.ZipFile(evidence) as z:assert z.testzip() is None
    assert hashlib.sha256(evidence.read_bytes()).hexdigest()=='3dc8acab0f6158d6f6e977c7f1a460a5377e30861d4b384531cffe614a006a65'
    print('Gen 2: consent, adult seats, week access, immutable order facts, ledger, compacted retry and import collision checks passed.')
    print('Standalone brief matches chapters; editable planner, six measured phrases, 383-row bank, listing fields and original evidence verified.')

if __name__=='__main__':
    integrity();launch()
