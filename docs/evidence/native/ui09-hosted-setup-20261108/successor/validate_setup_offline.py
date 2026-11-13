#!/usr/bin/env python3
"""Pure/mocked setup checks. The only real child process is a simulated bash status wrapper."""
import importlib.util, json, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch

BASE=Path(__file__).resolve().parent
HELPER=BASE/'payload/diagnostics/ui09-hosted'
spec=importlib.util.spec_from_file_location('collect',HELPER/'collect.py')
collector=importlib.util.module_from_spec(spec);sys.modules['collect']=collector;spec.loader.exec_module(collector)
spec=importlib.util.spec_from_file_location('hosted_setup',HELPER/'hosted.py')
hosted=importlib.util.module_from_spec(spec);spec.loader.exec_module(hosted)
REAL_RUN=subprocess.run
DEVICE='00000000-0000-0000-0000-000000000001'

class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.out=self.root/'evidence';self.out.mkdir()
        self.patches=[patch.object(hosted,'ROOT',self.root),patch.object(hosted,'OUT',self.out),
                      patch.object(hosted,'DD',self.root/'dd'),patch.object(hosted,'HERE',HELPER),
                      patch.object(hosted,'capture',side_effect=AssertionError('unmocked capture forbidden')),
                      patch.object(hosted.subprocess,'run',side_effect=AssertionError('native subprocess forbidden')),
                      patch.object(hosted.subprocess,'Popen',side_effect=AssertionError('native subprocess forbidden'))]
        for p in self.patches:p.start()
    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.temp.cleanup()
    def receipt(self,**updates):
        r=dict(status='setupFailed',nativeStarted=False,nativeExit=None,
               primaryFailure=dict(stage='sourcePins',kind='AssertionError',message='changed source'))
        r.update(updates);(self.out/'run.json').write_text(json.dumps(r));return r
    def make_products(self):
        products=hosted.DD/'Build/Products';products.mkdir(parents=True)
        (products/'RoomInTheCart_iphonesimulator.xctestrun').write_text('fixture')
        (self.out/'product-pins.json').write_text('{}')
    def test_optional_timeout_is_unknown_and_does_not_retry(self):
        with patch.object(hosted,'capture',side_effect=subprocess.TimeoutExpired('fixture',30)) as call:
            r=hosted.observe_appearance(DEVICE)
        self.assertEqual(call.call_count,1);self.assertEqual(r['status'],'unavailable');self.assertIsNone(r['defaultsMatch'])
        self.assertEqual(r['values'],{});self.assertEqual(r['errors'][0]['kind'],'TimeoutExpired')
        self.assertFalse(r['acceptanceInvariant']);self.assertFalse(r['settingsChanged'])
        self.assertLessEqual(call.call_args.kwargs['timeout'],30)
    def test_optional_error_is_recorded_without_inventing_defaults(self):
        with patch.object(hosted,'capture',side_effect=subprocess.CalledProcessError(71,'fixture')) as call:
            r=hosted.observe_appearance(DEVICE)
        self.assertEqual(call.call_count,1);self.assertEqual(r['errors'][0]['exitCode'],71)
        self.assertIsNone(r['defaultsMatch']);self.assertEqual(r['notAttempted'],['content_size','increase_contrast'])
    def test_partial_metadata_is_preserved_and_remaining_queries_stop(self):
        with patch.object(hosted,'capture',side_effect=['light',subprocess.TimeoutExpired('fixture',30)]) as call:
            r=hosted.observe_appearance(DEVICE)
        self.assertEqual(call.call_count,2);self.assertEqual(r['status'],'partial');self.assertEqual(r['values'],{'appearance':'light'})
        self.assertIsNone(r['defaultsMatch']);self.assertEqual(r['notAttempted'],['increase_contrast'])
        self.assertLessEqual(call.call_args_list[1].kwargs['timeout'],call.call_args_list[0].kwargs['timeout'])
    def test_known_difference_is_metadata_not_acceptance_gate(self):
        with patch.object(hosted,'capture',side_effect=['dark','large','disabled']):r=hosted.observe_appearance(DEVICE)
        self.assertEqual(r['status'],'observed');self.assertFalse(r['defaultsMatch'])
        self.assertEqual(r['observedDifferences'],{'appearance':{'expected':'light','observed':'dark'}})
    def test_total_budget_exhaustion_makes_no_query(self):
        with patch.object(hosted,'capture') as call:r=hosted.observe_appearance(DEVICE,budget=0)
        call.assert_not_called();self.assertEqual(r['status'],'unavailable');self.assertIsNone(r['defaultsMatch'])
    def test_receipt_precedes_mandatory_failure_and_native_is_not_started(self):
        def reject():
            initial=json.loads((self.out/'run.json').read_text())
            self.assertFalse(initial['nativeStarted']);raise RuntimeError('mandatory identity failed')
        with patch.object(hosted,'guard',side_effect=reject),patch.object(hosted,'observe_appearance') as optional:
            with self.assertRaisesRegex(RuntimeError,'mandatory identity'):hosted.test()
        optional.assert_not_called();r=json.loads((self.out/'run.json').read_text())
        self.assertEqual(r['status'],'setupFailed');self.assertFalse(r['nativeStarted'])
        self.assertEqual(r['primaryFailure']['stage'],'mandatoryGuard')
        hosted.subprocess.Popen.assert_not_called()
        self.assertFalse((self.out/'Tests.log').exists());self.assertFalse((self.out/'Tests.xcresult').exists())
    def test_optional_timeout_does_not_block_original_native_path(self):
        self.make_products()
        def native(receipt,*args):
            self.assertEqual(receipt['appearanceObservation']['status'],'unavailable')
            receipt.update(nativeStarted=True,nativeExit=0,captureStatus='complete')
        with patch.object(hosted,'guard'),patch.object(hosted,'verify_sources'),patch.object(hosted,'tree',return_value={}),\
             patch.object(hosted,'device',return_value=DEVICE),patch.object(hosted,'capture',side_effect=subprocess.TimeoutExpired('fixture',30)),\
             patch.object(hosted,'_run_test',side_effect=native) as run:
            hosted.test()
        run.assert_called_once();self.assertEqual(json.loads((self.out/'run.json').read_text())['status'],'passed-instrumented-tests')
    def test_recorded_prelaunch_failure_skips_inspection_without_masking(self):
        self.receipt();before=(self.out/'run.json').read_bytes();hosted.inspect()
        result=json.loads((self.out/'inspection.json').read_text())
        self.assertEqual(result['status'],'skipped');self.assertFalse(result['nativeAccepted']);self.assertFalse(result['strictCheckRun'])
        self.assertEqual((self.out/'run.json').read_bytes(),before);hosted.subprocess.run.assert_not_called()
    def test_missing_result_after_native_started_is_failure(self):
        for status,code in [('failed',65),('passed-instrumented-tests',0)]:
            with self.subTest(status=status):
                self.receipt(status=status,nativeStarted=True,nativeExit=code,nativePID=42)
                before=(self.out/'run.json').read_bytes()
                with self.assertRaisesRegex(RuntimeError,'Missing or empty native result'):hosted.inspect()
                self.assertEqual(json.loads((self.out/'inspection.json').read_text())['status'],'failed')
                self.assertEqual((self.out/'run.json').read_bytes(),before)
    def test_missing_or_inconsistent_receipt_does_not_allow_skip(self):
        with self.assertRaises(RuntimeError):hosted.inspect()
        self.receipt(nativePID=42)
        with self.assertRaises(RuntimeError):hosted.inspect()
    def test_empty_result_after_native_started_is_failure(self):
        self.receipt(status='failed',nativeStarted=True,nativeExit=65,nativePID=42)
        (self.out/'Tests.xcresult').mkdir()
        with self.assertRaises(RuntimeError):hosted.inspect()
        self.assertEqual(json.loads((self.out/'inspection.json').read_text())['status'],'failed')
    def test_existing_receipt_is_not_overwritten_or_retried(self):
        self.receipt();before=(self.out/'run.json').read_bytes()
        with self.assertRaises(FileExistsError):hosted.test()
        self.assertEqual((self.out/'run.json').read_bytes(),before)
    def test_original_eight_selectors_and_native_timeouts_are_retained(self):
        self.make_products();receipt={};runs=list((hosted.DD/'Build/Products').glob('*.xctestrun'))
        with patch.object(hosted,'device',return_value=DEVICE),patch.object(hosted,'Collector',side_effect=RuntimeError('stop before native')):
            with self.assertRaisesRegex(RuntimeError,'stop before native'):hosted._run_test(receipt,hosted.DD/'Build/Products',{},runs)
        command=receipt['command']
        self.assertEqual([s.split(':',1)[1] for s in command if s.startswith('-only-testing:')],hosted.selectors())
        self.assertEqual(len(hosted.selectors()),8)
        for flag,value in [('-parallel-testing-enabled','NO'),('-test-timeouts-enabled','YES'),
                           ('-default-test-execution-time-allowance','720'),('-maximum-test-execution-time-allowance','900'),
                           ('-collect-test-diagnostics','never')]:self.assertEqual(command[command.index(flag)+1],value)
        self.assertEqual(command[-1],'test-without-building')

class WorkflowStatusTests(unittest.TestCase):
    def test_shell_retains_primary_failure_and_propagates_inspection_failure(self):
        workflow=(BASE/'payload/.github/workflows/ios-toggle-diagnostic.yml').read_text()
        begin=workflow.index('          status=0\n');end=workflow.index('\n      - name:',begin)
        body='\n'.join(line[10:] for line in workflow[begin:end].splitlines())
        for primary,inspection,want in [(73,0,73),(73,1,73),(0,1,1),(0,0,0)]:
            # Local shell simulation: python3 is a function returning fixed statuses, never Python/native execution.
            script=f'python3() {{ if [[ "$2" == test ]]; then return {primary}; else return {inspection}; fi; }}\n'+body
            result=REAL_RUN(['/bin/bash','-e','-c',script],capture_output=True,timeout=5)
            self.assertEqual(result.returncode,want,(primary,inspection,result.stderr))

if __name__=='__main__':
    suite=unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(SetupTests),
                             unittest.defaultTestLoader.loadTestsFromTestCase(WorkflowStatusTests)])
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    (BASE/'setup-offline-validation.json').write_text(json.dumps(dict(passed=result.wasSuccessful(),tests=result.testsRun,
        nativeExecution=False,simulatorOperations=False,remoteMutation=False),indent=2)+'\n')
    if not result.wasSuccessful():raise SystemExit(1)
