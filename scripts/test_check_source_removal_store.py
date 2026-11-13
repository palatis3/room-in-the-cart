import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import check_source_removal_store as check


def uid(n): return f'00000000-0000-4000-8000-{n:012d}'
def q(n): return {'unit':'count','amount':{'numerator':n,'denominator':1},'originalLiteral':str(n)}


def documents():
    workspace=uid(1); target=uid(2); other=uid(3); line=uid(4)
    sources=[{'id':uid(10),'lineID':line,'source':{'manual':{}},'quantity':q(12)},
        {'id':uid(11),'lineID':line,'source':{'meal':{'occurrenceID':target}},'quantity':q(6)},
        {'id':uid(12),'lineID':line,'source':{'meal':{'occurrenceID':other}},'quantity':q(4)},
        {'id':uid(13),'lineID':line,'source':{'protectedNeed':{'purpose':'Lunch'}},'quantity':q(2)}]
    before={'formatVersion':1,'workspace':{'selectedShopID':uid(20),'shops':[{'id':uid(20),'title':'Family pickup',
        'revision':6,'revisionID':uid(21),'basisRevision':0,'revisions':[],
        'lines':[{'id':line}]+[{'id':uid(n),'trashedAt':1.0} for n in (5,6,7)],
        'mealOccurrences':[{'id':target,'title':'Tuesday tacos','ingredientContributionIDs':[uid(11)]},
                           {'id':other,'title':'Wednesday quesadillas','ingredientContributionIDs':[uid(12)]}],
        'contributions':sources,'allocations':[{'id':uid(30+i),'demandContributionID':uid(11+i),'supplyContributionID':uid(10),'kind':'withinExisting','quantity':q(n)} for i,n in enumerate([6,4,2])]}],
        'dinnerPlanning':{'revisionID':uid(40),'applyReceipts':[]},'mealTemplates':[]}}
    after=copy.deepcopy(before);s=after['workspace']['shops'][0];s['revision']=7;s['revisionID']=uid(22)
    s['revisions'].append({'id':uid(22),'parentID':uid(21),'number':7,'basisRevision':0,'createdAt':61.0,'operation':'dinner:'+uid(50)})
    s['mealOccurrences'][0]['removedAt']=61.0;s['contributions'][1]['removedAt']=61.0;s['allocations']=s['allocations'][1:]
    after['workspace']['dinnerPlanning']={'revisionID':uid(41),'applyReceipts':[{'appliedBy':'local-fixture','appliedAt':61.0,'revisionID':uid(22),
        'proposal':{'id':uid(50),'shopID':uid(20),'baseRevisionID':uid(21),'basisRevision':0,'planningRevisionID':uid(40),
        'changes':[{'remove':{'occurrenceID':target}}],'tool':'manual','isIsolatedPreview':False,'namespace':'local:'+workspace,
        'authorID':'local-fixture','proposedRevisionID':uid(22)}}]}
    binding={'schema':1,'sequenceFinished':True,'removedOccurrenceID':target,'survivingOccurrenceID':other,'manualLineID':line}
    return before,after,binding,workspace


class ReadbackControls(unittest.TestCase):
    def test_exact_survivors_pass(self):
        self.assertTrue(check.verify_documents(*documents())['priorTombstonesUnchanged'])
    def test_old_tombstone_retimestamp_is_rejected(self):
        b,a,u,w=documents();a['workspace']['shops'][0]['lines'][1]['trashedAt']=61.0
        with self.assertRaisesRegex(ValueError,'unexpected persisted'):check.verify_documents(b,a,u,w)
    def test_surviving_meal_quantity_or_id_change_rejected(self):
        for field,value in [('quantity',q(3)),('id',uid(99))]:
            b,a,u,w=documents();a['workspace']['shops'][0]['contributions'][2][field]=value
            with self.assertRaises(ValueError):check.verify_documents(b,a,u,w)
    def test_missing_lunch_reservation_rejected(self):
        b,a,u,w=documents();a['workspace']['shops'][0]['allocations'].pop()
        with self.assertRaises(ValueError):check.verify_documents(b,a,u,w)
    def test_wrong_ui_target_or_incomplete_journey_rejected(self):
        for field,value in [('removedOccurrenceID',uid(99)),('sequenceFinished',False)]:
            b,a,u,w=documents();u[field]=value
            with self.assertRaises(ValueError):check.verify_documents(b,a,u,w)
    def test_different_reviewed_base_or_extra_workspace_edit_rejected(self):
        b,a,u,w=documents();a['workspace']['dinnerPlanning']['applyReceipts'][0]['proposal']['baseRevisionID']=uid(99)
        with self.assertRaises(ValueError):check.verify_documents(b,a,u,w)
        b,a,u,w=documents();a['workspace']['mealTemplates']=[{'id':uid(99)}]
        with self.assertRaises(ValueError):check.verify_documents(b,a,u,w)
    def test_real_sqlite_readonly_and_extra_cancel_save_rejected(self):
        b,a,u,w=documents()
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'ledger-snapshot.sqlite';binding=Path(folder)/'binding.json';binding.write_text(json.dumps(u))
            with sqlite3.connect(path) as db:
                db.executescript('CREATE TABLE ledger_workspace(singleton,id,head_revision); CREATE TABLE ledger_revisions(workspace_id,revision,base_revision,payload,payload_sha256,operation_id);')
                db.execute('INSERT INTO ledger_workspace VALUES(1,?,2)',(w,))
                for i,d in enumerate([b,a]):
                    raw=json.dumps(d).encode();db.execute('INSERT INTO ledger_revisions VALUES(?,?,?,?,?,?)',(w,i+1,i,raw,hashlib.sha256(raw).digest(),uid(60+i)))
            original=path.read_bytes();self.assertEqual(check.inspect(path,binding)['status'],'passed');self.assertEqual(path.read_bytes(),original)
            with sqlite3.connect(path) as db:db.execute('INSERT INTO ledger_revisions SELECT workspace_id,3,2,payload,payload_sha256,? FROM ledger_revisions WHERE revision=2',(uid(62),))
            with self.assertRaisesRegex(ValueError,'only seed'):check.inspect(path,binding)
    def test_duplicate_json_and_uncheckpointed_copy_rejected(self):
        with self.assertRaises(ValueError):check.decode('{"a":1,"a":2}')
        with self.assertRaises(ValueError):check.decode('{"a":NaN}')
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'ledger.sqlite';path.write_bytes(b'x');Path(str(path)+'-wal').touch()
            with self.assertRaisesRegex(ValueError,'checkpointed'):check.inspect(path,Path(folder)/'missing.json')


if __name__=='__main__':unittest.main()
