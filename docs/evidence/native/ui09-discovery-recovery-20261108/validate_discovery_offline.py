#!/usr/bin/env python3
"""Deterministic process-discovery tests. No process query, app, native test or sleep."""
import importlib.util, json, subprocess, tempfile, unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

BASE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('collector_discovery',BASE/'payload/diagnostics/ui09-hosted/collect.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
EXE='data/Containers/Bundle/Application/fixture/RoomInTheCart.app/RoomInTheCart'
START=("Test Case '-["+m.TARGET.replace('/',' ')+"]' started.\n").encode()

class StopAfterWaits:
    def __init__(self,count):self.limit=count;self.waits=[];self.stopped=False
    def is_set(self):return self.stopped
    def set(self):self.stopped=True
    def wait(self,seconds):
        self.waits.append(seconds)
        if len(self.waits)>=self.limit:self.stopped=True
        return self.stopped

class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.c=m.Collector('00000000-0000-0000-0000-000000000001',self.root)
        self.no_native=patch.object(m.subprocess,'run',side_effect=AssertionError('unmocked native query forbidden'))
        self.no_native.start()
    def tearDown(self):
        self.no_native.stop();self.c.events.close();self.temp.cleanup()
    def events(self):return [json.loads(line) for line in (self.c.out/'events.ndjson').read_text().splitlines()]
    def timeout(self):return subprocess.TimeoutExpired(['/bin/ps','-ww','-axo','pid=,comm='],2)
    def candidate(self):return dict(path=self.root/'exact-42.ndjson',executable=EXE,latest=None,closed=False,reads=0,maxReadMS=0.)
    def test_original_first_query_failure_recovers_before_native_or_target(self):
        self.c.stop=StopAfterWaits(3)
        with patch.object(self.c,'processes',side_effect=[self.timeout(),{},{}]) as query:self.c.run()
        self.assertEqual(query.call_count,3);self.assertIsNone(self.c.error)
        self.assertEqual((self.c.poll_attempts,self.c.polls,self.c.poll_failures),(3,2,1))
        self.assertFalse(self.c.ambiguous);self.assertFalse(self.c.target_started)
        self.assertEqual(self.c.discovery_summary()['status'],'recoveredWithLoss')
        self.assertFalse(self.c.discovery_summary()['allProcessObservationsPresent'])
        self.assertEqual(self.c.stop.waits[0],1)
        self.assertEqual(sum(r['event']=='processPollFailed' for r in self.events()),1)
        self.assertEqual(sum(r['event']=='processDiscoveryRecovered' for r in self.events()),1)
        self.assertEqual(self.c.discovery_summary()['initialSnapshotState'],'failed')
        self.assertTrue(self.c.discovery_summary()['successfulSnapshotObserved'])
    def test_thread_started_is_not_successful_discovery(self):
        self.c.stop=StopAfterWaits(1)
        def fail():
            self.assertTrue(self.c.ready.is_set())
            self.assertFalse(self.c.discovery_summary()['successfulSnapshotObserved'])
            raise self.timeout()
        with patch.object(self.c,'processes',side_effect=fail):self.c.run()
        summary=self.c.discovery_summary()
        self.assertEqual(summary['startupHandshake'],'threadStartedOnly')
        self.assertTrue(summary['threadStartedHandshakeObserved'])
        self.assertFalse(summary['successfulSnapshotObserved']);self.assertEqual(summary['initialSnapshotState'],'failed')
    def test_recovered_empty_baseline_allows_later_unambiguous_target(self):
        with patch.object(self.c,'processes',side_effect=[self.timeout(),{}]):
            self.assertIsNone(self.c.poll_processes());self.assertEqual(self.c.poll_processes(),{})
        self.assertIsNone(self.c.discovery_gap)
        self.c.log.write_bytes(START)
        with patch.object(self.c,'processes',return_value={42:EXE}):self.c.poll_processes()
        self.assertTrue(self.c.target_started);self.assertFalse(self.c.ambiguous)
    def test_target_marker_buffered_during_failed_query_taints_gap(self):
        def failed():self.c.log.write_bytes(START);raise self.timeout()
        with patch.object(self.c,'processes',side_effect=failed):self.assertIsNone(self.c.poll_processes())
        self.assertTrue(self.c.target_started);self.assertTrue(self.c.ambiguous)
        self.assertTrue(self.c.discovery_target_affected)
        with patch.object(self.c,'processes',return_value={}):self.c.poll_processes()
        self.assertTrue(self.c.ambiguous);self.assertIsNone(self.c.discovery_gap)
    def test_target_marker_buffered_during_recovery_taints_gap(self):
        with patch.object(self.c,'processes',side_effect=self.timeout()):self.c.poll_processes()
        def recovered():self.c.log.write_bytes(START);return {42:EXE}
        with patch.object(self.c,'processes',side_effect=recovered):self.c.poll_processes()
        self.assertTrue(self.c.target_started);self.assertTrue(self.c.ambiguous)
        recovered_events=[r for r in self.events() if r['event']=='processDiscoveryRecovered']
        self.assertEqual(len(recovered_events),1);self.assertFalse(recovered_events[0]['recoveredBeforeTarget'])
    def test_partial_case_marker_does_not_establish_fresh_baseline(self):
        self.c.log.write_bytes(START[:15])
        with patch.object(self.c,'processes',side_effect=[self.timeout(),{}]):self.c.poll_processes();self.c.poll_processes()
        self.assertIsNotNone(self.c.discovery_gap);self.assertFalse(self.c.target_started)
        with self.c.log.open('ab') as f:f.write(START[15:])
        with patch.object(self.c,'processes',return_value={42:EXE}):self.c.poll_processes()
        self.assertTrue(self.c.target_started);self.assertTrue(self.c.ambiguous)
    def test_nonempty_pre_target_snapshot_does_not_invent_empty_baseline(self):
        with patch.object(self.c,'processes',side_effect=[self.timeout(),{9:EXE}]):self.c.poll_processes();self.c.poll_processes()
        self.assertIsNotNone(self.c.discovery_gap)
        self.c.log.write_bytes(START)
        with patch.object(self.c,'processes',return_value={42:EXE}):self.c.poll_processes()
        self.assertTrue(self.c.ambiguous)
    def test_in_target_loss_neither_invents_absence_nor_pid_reuse(self):
        self.c.current_case=m.TARGET;self.c.target_started=True;self.c.previous={42:EXE};self.c.candidates={42:self.candidate()}
        self.c.stop=StopAfterWaits(2)
        with patch.object(self.c,'processes',side_effect=[self.timeout(),{42:EXE}]),patch.object(self.c,'read_probe') as read:
            self.c.run()
        self.assertTrue(self.c.ambiguous);self.assertEqual([call.args[2] for call in read.call_args_list],[None,True])
        self.assertFalse(any(r['event'] in ('processAbsent','PIDReappeared') for r in self.events()))
        self.assertEqual(self.c.previous,{42:EXE});self.assertEqual(self.c.absent_pids,set())
    def test_failure_budget_is_total_not_consecutive(self):
        self.c.stop=StopAfterWaits(10)
        with patch.object(self.c,'processes',side_effect=[self.timeout(),{},self.timeout(),{},self.timeout(),{}]) as query:
            self.c.run()
        self.assertEqual(query.call_count,5);self.assertEqual(self.c.poll_failures,3)
        self.assertTrue(self.c.discovery_exhausted);self.assertIn('exhausted',self.c.error)
        self.assertEqual(self.c.discovery_summary()['status'],'exhausted')
        self.assertEqual(self.c.recovered_gaps,2)
        receipt=json.loads((self.c.out/'receipt.json').read_text())
        self.assertEqual(receipt['processDiscovery']['totalFailures'],3)
    def test_nonzero_ps_exit_is_explicit_and_bounded(self):
        with patch.object(self.c,'processes',side_effect=subprocess.CalledProcessError(71,'ps')):
            self.assertIsNone(self.c.poll_processes())
        row=[r for r in self.events() if r['event']=='processPollFailed'][0]
        self.assertEqual(row['exitCode'],71);self.assertEqual(self.c.poll_failures,1)
    def test_successful_processes_followed_by_lsof_error_is_not_poll_recovery(self):
        self.c.current_case=m.TARGET;self.c.target_started=True;self.c.previous={42:EXE};self.c.candidates={42:self.candidate()}
        self.c.stop=StopAfterWaits(1)
        with patch.object(self.c,'processes',return_value={42:EXE}),\
             patch.object(self.c,'read_probe',side_effect=subprocess.TimeoutExpired('lsof',2)):
            self.c.run()
        self.assertEqual(self.c.poll_failures,0);self.assertIn('lsof',self.c.error)
        self.assertFalse(self.c.discovery_exhausted)
        self.assertFalse(any(r['event']=='processPollFailed' for r in self.events()))
    def test_other_identity_errors_still_fail_closed(self):
        self.c.stop=StopAfterWaits(1)
        with patch.object(self.c,'processes',side_effect=ValueError('identity malformed')):self.c.run()
        self.assertEqual(self.c.poll_failures,0);self.assertIn('identity malformed',self.c.error)
        self.assertEqual(self.c.discovery_summary()['status'],'fatalSnapshotFailure')
        self.assertFalse(self.c.discovery_summary()['allProcessObservationsPresent'])
    def test_baseline_never_clears_prior_ambiguity(self):
        self.c.ambiguous=True
        with patch.object(self.c,'processes',side_effect=[self.timeout(),{}]):self.c.poll_processes();self.c.poll_processes()
        self.assertTrue(self.c.ambiguous)
    def test_per_query_timeout_and_command_are_unchanged(self):
        with patch.object(m.subprocess,'run',return_value=SimpleNamespace(stdout=b'')) as query:self.c.processes()
        self.assertEqual(query.call_args.args[0],['/bin/ps','-ww','-axo','pid=,comm='])
        self.assertEqual(query.call_args.kwargs,dict(capture_output=True,timeout=2,check=True))

if __name__=='__main__':
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(DiscoveryTests))
    (BASE/'discovery-offline-validation.json').write_text(json.dumps(dict(passed=result.wasSuccessful(),tests=result.testsRun,
         processQueriesExecuted=False,nativeExecution=False,remoteMutation=False),indent=2)+'\n')
    if not result.wasSuccessful():raise SystemExit(1)
