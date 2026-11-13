#!/usr/bin/env python3
"""Scratch-only checks; never invokes xcodebuild, xcrun, ps or lsof."""
import ast, copy, hashlib, importlib.util, json, subprocess, sys, tempfile, unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

BASE=Path(__file__).resolve().parent
REPO=BASE.parents[2]
PAYLOAD=BASE/'payload'; HELPER=PAYLOAD/'diagnostics/ui09-hosted'
spec=importlib.util.spec_from_file_location('ui09collector',HELPER/'collect.py')
collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)
def sha(data): return hashlib.sha256(data).hexdigest()
def complete():
    line=b'{"event":"beforeDismiss","t":0}\n'
    return line+(json.dumps(dict(event='sinkFinished',bytesBeforeFooter=len(line),droppedRecords=0))+'\n').encode()

def full_window_rows():
    def sample(event,due):
        return dict(event=event,due=due,t=due+0.01,truncatedTraversal=False,
                    skippedInterestingRecords=0,truncatedAnimationKeys=0,skippedChildren=0,
                    windowCount=1,windows=[dict(layer=1)],layers=[dict(layer=1,parent=0)],scrolls=[],responders=[])
    return [sample('beforeDismiss',0),dict(event='dismissReturned',t=.005)] + [
        sample('afterDismiss',due) for due in collector.OFFSETS] + [
        dict(event='finished',reason='windowComplete',t=64.02),
        dict(event='sinkFinished',droppedRecords=0)]

def encoded_rows(rows):
    rows=copy.deepcopy(rows)
    prefix=b''.join((json.dumps(r)+'\n').encode() for r in rows[:-1])
    rows[-1]['bytesBeforeFooter']=len(prefix)
    return prefix+(json.dumps(rows[-1])+'\n').encode()

class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        self.c=collector.Collector('00000000-0000-0000-0000-000000000001',self.root)
    def tearDown(self): self.c.events.close(); self.temp.cleanup()
    def candidate(self,data):
        p=self.root/'exact-probe.ndjson'; p.write_bytes(data)
        return dict(path=p,latest=None,closed=False,reads=0,maxReadMS=0.)
    def test_complete_footer(self):
        rows,closed=collector.decode_probe(complete()); self.assertTrue(closed); self.assertEqual(len(rows),2)
    def test_partial_line_retained_not_parsed(self):
        data=b'{"event":"beforeDismiss"}\n{"event":'
        rows,closed=collector.decode_probe(data); self.assertFalse(closed); self.assertEqual(len(rows),1)
    def test_wrong_footer_count_rejected(self):
        with self.assertRaises(ValueError): collector.decode_probe(b'{"event":"sinkFinished","bytesBeforeFooter":9}\n')
    def test_oversize_rejected(self):
        with self.assertRaises(ValueError): collector.decode_probe(b' '*(collector.FILE_CAP+1))
    def test_closed_requires_no_descriptor(self):
        candidate=self.candidate(complete())
        with patch.object(collector.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=b'42\n',stderr=b'')):
            self.c.read_probe(42,candidate,True)
        self.assertFalse(candidate['closed']); self.assertFalse(list(self.c.out.glob('*.closed.ndjson')))
    def test_closed_file_preserved(self):
        candidate=self.candidate(complete())
        with patch.object(collector.subprocess,'run',return_value=SimpleNamespace(returncode=1,stdout=b'',stderr=b'')):
            self.c.read_probe(42,candidate,True)
        self.assertTrue(candidate['closed'])
        self.assertEqual((self.c.out/'ui09-animation-42.closed.ndjson').read_bytes(),complete())
    def test_closure_query_failure_preserves_incomplete(self):
        candidate=self.candidate(complete())
        with patch.object(collector.subprocess,'run',side_effect=subprocess.TimeoutExpired('lsof',2)):
            with self.assertRaises(subprocess.TimeoutExpired): self.c.read_probe(42,candidate,True)
        self.c.save(42,candidate,'collectorEndingWithoutVerifiedClosure')
        self.assertFalse(candidate['latest']['closed'])
        self.assertEqual((self.c.out/'ui09-animation-42.incomplete.ndjson').read_bytes(),complete())
    def test_failed_pid_preserves_partial(self):
        data=b'{"event":"beforeDismiss"}\n{"event":'; candidate=self.candidate(data)
        self.c.read_probe(42,candidate,False); self.c.save(42,candidate,'PIDAbsentWithoutFooter')
        self.assertEqual((self.c.out/'ui09-animation-42.incomplete.ndjson').read_bytes(),data)
    def test_symlink_probe_rejected(self):
        candidate=self.candidate(b'{}\n'); p=self.root/'link';p.symlink_to(candidate['path']);candidate['path']=p
        with self.assertRaises(OSError): self.c.read_probe(42,candidate,True)
    def test_case_failure_is_retained(self):
        name=collector.TARGET.replace('/',' ')
        self.c.log.write_bytes(("Test Case '-["+name+"]' started.\n").encode());self.c.cases()
        self.assertEqual(self.c.current_case,collector.TARGET)
        with self.c.log.open('ab') as f:f.write(("Test Case '-["+name+"]' failed (900.0 seconds).\n").encode())
        self.c.cases();self.assertTrue(self.c.target_ended);self.assertIsNone(self.c.current_case)
    def test_unrelated_container_rejected(self):
        with patch.object(collector.subprocess,'run',return_value=SimpleNamespace(stdout='/tmp/unrelated')):
            with self.assertRaises(ValueError): self.c.bind(42,'exact-app-path')
    def test_full_window_no_loss_qualifies(self):
        self.assertTrue(collector.probe_quality(full_window_rows())['completeForDeclaredScope'])
    def test_sink_loss_is_sealed_but_limited_and_preserved(self):
        rows=full_window_rows();rows[-1]['droppedRecords']=4;data=encoded_rows(rows)
        candidate=self.candidate(data)
        with patch.object(collector.subprocess,'run',return_value=SimpleNamespace(returncode=1,stdout=b'',stderr=b'')):
            self.c.read_probe(42,candidate,True)
        self.assertTrue(candidate['closed']);self.assertFalse(candidate['latest']['quality']['completeForDeclaredScope'])
        self.assertFalse(candidate['latest']['quality']['zeroSinkDrops'])
        self.assertEqual((self.c.out/'ui09-animation-42.closed.ndjson').read_bytes(),data)
    def test_early_overhead_finish_is_limited(self):
        rows=full_window_rows();rows[-2]['reason']='inventoryOverheadLimit'
        q=collector.probe_quality(rows);self.assertFalse(q['completeForDeclaredScope']);self.assertFalse(q['windowComplete'])
    def test_unknown_or_missing_finish_is_limited(self):
        for reason in ('unknown',None):
            rows=full_window_rows();rows[-2]['reason']=reason
            self.assertFalse(collector.probe_quality(rows)['completeForDeclaredScope'])
        rows=full_window_rows();del rows[-2]
        self.assertFalse(collector.probe_quality(rows)['completeForDeclaredScope'])
    def test_missing_or_duplicate_schedule_is_limited(self):
        rows=full_window_rows();del rows[2]
        self.assertFalse(collector.probe_quality(rows)['scheduledSamplesComplete'])
        rows=full_window_rows();rows[2]['due']=.016
        self.assertFalse(collector.probe_quality(rows)['scheduledSamplesComplete'])
    def test_sample_inventory_truncation_is_limited(self):
        for key,value in [('truncatedTraversal',True),('skippedInterestingRecords',1),
                          ('truncatedAnimationKeys',1),('skippedChildren',1)]:
            with self.subTest(key=key):
                rows=full_window_rows();rows[2][key]=value
                self.assertFalse(collector.probe_quality(rows)['completeForDeclaredScope'])
    def test_unreported_caps_are_unknown_not_loss_free(self):
        rows=full_window_rows();rows[-2:-2]=[dict(event='didHide',t=1)]*16
        q=collector.probe_quality(rows);self.assertTrue(q['keyboardCapReached']);self.assertFalse(q['completeForDeclaredScope'])
        for key in ('scrolls','responders'):
            rows=full_window_rows();rows[2][key]=[dict(layer=1)]*8
            self.assertFalse(collector.probe_quality(rows)['completeForDeclaredScope'])
    def test_window_and_object_id_limits_are_not_complete(self):
        rows=full_window_rows();rows[2]['windowCount']=9
        self.assertFalse(collector.probe_quality(rows)['completeForDeclaredScope'])
        rows=full_window_rows();rows[2]['layers'][0]['layer']=-1
        self.assertFalse(collector.probe_quality(rows)['completeForDeclaredScope'])
        rows=full_window_rows();rows[2]['layers'][0]['parent']=-1
        self.assertFalse(collector.probe_quality(rows)['completeForDeclaredScope'])
    def test_invalid_bounded_payload_is_preserved(self):
        data=b'{malformed complete line}\n';candidate=self.candidate(data)
        self.c.read_probe(42,candidate,False);self.c.save(42,candidate,'PIDAbsentWithInvalidPayload')
        self.assertEqual((self.c.out/'ui09-animation-42.incomplete.ndjson').read_bytes(),data)
        self.assertFalse(candidate['latest']['quality']['completeForDeclaredScope'])
    def test_same_pid_same_executable_reappearance_is_ambiguous(self):
        self.c.process_events({42:'owned/RoomInTheCart.app/RoomInTheCart'})
        self.c.previous={42:'owned/RoomInTheCart.app/RoomInTheCart'}
        self.c.process_events({});self.c.previous={}
        self.c.process_events({42:'owned/RoomInTheCart.app/RoomInTheCart'})
        self.assertTrue(self.c.ambiguous)
        self.assertIn('PIDReappeared',(self.c.out/'events.ndjson').read_text())
    def test_uninterrupted_same_pid_is_not_reappearance(self):
        current={42:'owned/RoomInTheCart.app/RoomInTheCart'}
        self.c.process_events(current);self.c.previous=current;self.c.process_events(current)
        self.assertFalse(self.c.ambiguous)

def main():
    for p in HELPER.glob('*.py'): ast.parse(p.read_text(),filename=str(p))
    pins=json.loads((HELPER/'pins.json').read_text())
    for name,want in pins['payloadHashes'].items(): assert sha((PAYLOAD/name).read_bytes())==want,name
    selectors=(HELPER/'ui-09.txt').read_bytes()
    assert sha(selectors)=='cb9657808f4c27eff4ccbb89f712120cd1e990f2e58a0094dd70b6af5aafb022'
    assert len(selectors.splitlines())==len(set(selectors.splitlines()))==8
    old=REPO/'.build/CIA305065Nov08/ui09-animation-owner-execution-r1'
    assert (old/'diagnostic.patch').read_bytes()==(HELPER/'diagnostic.patch').read_bytes()
    with tempfile.TemporaryDirectory(dir=BASE) as temp:
        temp=Path(temp)
        for name in pins['patchedSources']:
            p=temp/name;p.parent.mkdir(parents=True,exist_ok=True)
            p.write_bytes(subprocess.check_output(['git','show',pins['baseSHA']+':'+name],cwd=REPO))
        subprocess.run(['git','apply','--check',str(HELPER/'diagnostic.patch')],cwd=temp,check=True)
        subprocess.run(['git','apply',str(HELPER/'diagnostic.patch')],cwd=temp,check=True)
        for name,want in pins['patchedSources'].items(): assert sha((temp/name).read_bytes())==want,name
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(BoundaryTests))
    receipt=dict(passed=result.wasSuccessful(),boundaryTests=result.testsRun,exactOriginalSelectors=True,
                 exactPreviouslyCompiledPatch=True,patchedSourceHashesMatchLocalCompiledCandidate=True,
                 nativeExecution=False,remoteMutation=False,
                 workflowLint=json.loads((BASE/'all-original-workflows-lint.json').read_text())['passed']
                    if (BASE/'all-original-workflows-lint.json').exists() else 'pending separate pinned tool')
    (BASE/'offline-validation.json').write_text(json.dumps(receipt,indent=2)+'\n')
    if not result.wasSuccessful():raise SystemExit(1)
if __name__=='__main__':main()
