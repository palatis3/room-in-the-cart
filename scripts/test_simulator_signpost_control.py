"""File-only helper/workflow controls. Never instantiate native Identity or launch tools."""
import copy
import inspect
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import sys
from types import SimpleNamespace
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
from simulator_signpost_control import run, runner, control, host_control, validate
from app_scroll_observation import contract

FIXTURES=Path(__file__).with_name('simulator_signpost_control')/'fixtures'
ENV={'SIMULATOR_SIGNPOST_CONTROL':'true','GITHUB_EVENT_NAME':'workflow_dispatch',
     'REQUESTED_PERFORMANCE_CASE':'',**{k:'false' for k in run.MIXED}}
DEVICE={'createdUDID':'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA','sourceUDID':'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB',
        'createdName':'owned-helper','deviceTypeIdentifier':'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
        'runtime':{'identifier':run.RUNTIME,'version':'27.0','buildversion':'24A434','bundlePath':'/runtime'}}
def inventory():
    return {'runtimes':[{**DEVICE['runtime'],'isAvailable':True}],
            'devices':{run.RUNTIME:[{'udid':DEVICE['createdUDID'],'name':DEVICE['createdName'],
                       'deviceTypeIdentifier':DEVICE['deviceTypeIdentifier'],'isAvailable':True,'state':'Booted'}]}}

def receipt():return json.loads((FIXTURES/'receipt.json').read_text())
def validate_receipt(value):
    return validate.validate_run(value,json.loads((FIXTURES/'helper-status.json').read_text()),
        (FIXTURES/'helper-command.txt').read_text(),value['helper']['binding']['pid'],value['subsystem'],value['simulatorUDID'])

def events(xml=None,**kw):
    r=receipt();args={'pid':r['helper']['binding']['pid'],'subsystem':r['subsystem'],'udid':r['simulatorUDID']};args.update(kw)
    return validate.validate_events(xml or (FIXTURES/'signposts.xml').read_bytes(),(FIXTURES/'toc.xml').read_bytes(),**args)

class RequestTests(unittest.TestCase):
    def test_manual_control(self):self.assertTrue(run.validate_request(ENV))
    def test_default_inert_in_all_events(self):
        for event in ('pull_request','workflow_call','workflow_dispatch','push'):
            self.assertFalse(run.validate_request({'GITHUB_EVENT_NAME':event}))
    def test_enabled_nonmanual_rejected(self):
        for event in ('pull_request','workflow_call','push',''):
            with self.subTest(event=event),self.assertRaisesRegex(ValueError,'manual_only'):
                run.validate_request({**ENV,'GITHUB_EVENT_NAME':event})
    def test_every_mixed_mode_rejected(self):
        for key in run.MIXED:
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'mixed_mode'):run.validate_request({**ENV,key:'true'})
    def test_unknown_boolean_and_selected_case_rejected(self):
        for value in ('1','True','yes',''):
            with self.assertRaisesRegex(ValueError,'boolean'):run.validate_request({**ENV,'SIMULATOR_SIGNPOST_CONTROL':value})
        for case in ('scroll','launch','rendered','all'):
            with self.assertRaisesRegex(ValueError,'case_all_only'):run.validate_request({**ENV,'REQUESTED_PERFORMANCE_CASE':case})

class DeviceTests(unittest.TestCase):
    def test_exact_device(self):self.assertEqual(run.current_device(inventory(),DEVICE,'Booted')['udid'],DEVICE['createdUDID'])
    def test_runtime_build_drift(self):
        v=inventory();v['runtimes'][0]['buildversion']='other'
        with self.assertRaisesRegex(ValueError,'exact_runtime'):run.current_device(v,DEVICE)
    def test_runtime_duplicates(self):
        v=inventory();v['runtimes']*=2
        with self.assertRaisesRegex(ValueError,'runtime_inventory'):run.current_device(v,DEVICE)
    def test_name_type_availability_and_state_drift(self):
        for k,v in [('name','other'),('deviceTypeIdentifier','other'),('isAvailable',False),('state','Shutdown')]:
            data=inventory();data['devices'][run.RUNTIME][0][k]=v
            with self.subTest(key=k),self.assertRaises(ValueError):run.current_device(data,DEVICE,'Booted')
    def test_missing_duplicate_and_delete(self):
        v=inventory();v['devices'][run.RUNTIME]=[]
        with self.assertRaisesRegex(ValueError,'missing_or_ambiguous'):run.current_device(v,DEVICE)
        self.assertIsNone(run.current_device(v,DEVICE,absent=True))
        v=inventory();v['devices'][run.RUNTIME]*=2
        with self.assertRaisesRegex(ValueError,'missing_or_ambiguous'):run.current_device(v,DEVICE)
        with self.assertRaisesRegex(ValueError,'delete_not_verified'):run.current_device(inventory(),DEVICE,absent=True)
    def test_lifecycle_exact_scope(self):
        for args in (['list','-j'],['create',DEVICE['createdName'],DEVICE['deviceTypeIdentifier'],run.RUNTIME],
                     ['boot',DEVICE['createdUDID']],['bootstatus',DEVICE['createdUDID'],'-b'],
                     ['shutdown',DEVICE['createdUDID']],['delete',DEVICE['createdUDID']]):
            self.assertTrue(runner.lifecycle_allowed(args,DEVICE))
        for args in (['delete','all'],['shutdown',DEVICE['sourceUDID']],['spawn',DEVICE['createdUDID'],'/helper'],
                     ['erase',DEVICE['createdUDID']],['bootstatus',DEVICE['createdUDID']],['list','devices','-j']):
            self.assertFalse(runner.lifecycle_allowed(args,DEVICE))
    def test_unbound_helper_blocks_cleanup(self):
        r=receipt();r['unboundHelperRisk']='unknown'
        with self.assertRaisesRegex(ValueError,'capture_not_terminal'):run.terminal_capture(r)
    def test_nonterminal_child_blocks_cleanup(self):
        r=receipt();r['processes'][0]['terminalVerified']=False
        with self.assertRaisesRegex(ValueError,'child_not_terminal'):run.terminal_capture(r)

class ProofTests(unittest.TestCase):
    def test_frozen_local_proof_replay(self):
        self.assertEqual(len(validate_receipt(receipt())),3)
        v=events();self.assertEqual((v['boundaryEventCount'],v['intervalPairCount'],v['rowCount']),(2,3,8))
    def test_runtime_pid_and_subsystem_mismatch(self):
        for kw in ({'pid':999},{'udid':'other'},{'subsystem':'other'}):
            with self.subTest(kw=kw),self.assertRaises(ValueError):events(**kw)
    def test_missing_or_extra_event_rejected(self):
        for extra in (False,True):
            root=ET.fromstring((FIXTURES/'signposts.xml').read_bytes());node=root[0];row=node.findall('row')[-1]
            if extra:node.append(copy.deepcopy(row))
            else:node.remove(row)
            with self.assertRaises(ValueError):events(ET.tostring(root))
    def test_notified_after_budget_and_no_readiness_rejected(self):
        for mutate in ('late','missing'):
            r=receipt()
            if mutate=='late':r['readinessEpoch']=r['processes'][1]['spawnEpoch']+15.01
            else:r['readinessObserved']=False
            with self.assertRaises(ValueError):validate_receipt(r)
    def test_any_signaled_process_or_helper_rejected(self):
        for name in ('simctl-spawn','tracer','toc','helper'):
            r=receipt();target=r['helper'] if name=='helper' else next(x for x in r['processes'] if x['label']==name)
            target['signals']=['SIGINT']
            with self.subTest(name=name),self.assertRaises(ValueError):validate_receipt(r)
    def test_original_failure_is_not_qualification(self):
        r=receipt();r.update(outcome='unqualified',error='tracing_readiness_missing')
        with self.assertRaisesRegex(ValueError,'original_capture_state'):validate_receipt(r)
    def test_nonce_and_parent_identity_rejected(self):
        for key,value in (('nonce','other'),('parentPID',999)):
            r=receipt();r['helperInitialStatus'][key]=value
            with self.assertRaisesRegex(ValueError,'helper_status_binding'):validate_receipt(r)
    def test_budgets_unchanged(self):
        self.assertEqual((host_control.STARTUP_SECONDS,control.FINALIZE_SECONDS,host_control.EXPORT_SECONDS),(15,30,10))
        s=inspect.getsource(control.SimulatorSupervisor.run)
        self.assertIn("'--time-limit', '5s'",s);self.assertIn("self.command('G')",s)
        self.assertNotIn('xcodebuild',s)

class RunnerTests(unittest.TestCase):
    def fixture(self, code):
        r=object.__new__(runner.HelperRunner);r.device=DEVICE;r.processes=[];r.out=Path('/owned')
        r.tools={'simctl':{'path':'/launcher','executable':'/actual','executableSHA256':'digest'}}
        r.started=runner.time.monotonic();r.seconds=90;r.receipt={};r.save=mock.Mock()
        proc=SimpleNamespace(pid=42,returncode=code,poll=lambda:code)
        item={'process':proc,'record':{'label':'query','signals':[]}}
        def spawn(*args):r.processes.append(item);raise RuntimeError('query_unbound_or_early_exit')
        r.spawn=spawn;r.wait=mock.Mock(return_value=code);r.cleanup=mock.Mock();r.budget=mock.Mock()
        return r,item
    def test_owned_early_terminal_normal_query(self):
        r,item=self.fixture(0);self.assertEqual(r.lifecycle('query',['list','-j']),Path('/owned/query-stdout.log'))
        self.assertTrue(item['record']['terminalOwnedCommandBeforeBinding']);r.cleanup.assert_called_once()
    def test_unverified_live_mutation_never_signaled(self):
        r,item=self.fixture(None)
        with self.assertRaisesRegex(ValueError,'unbound_live_no_signal'):r.lifecycle('query',['boot',DEVICE['createdUDID']])
        r.wait.assert_not_called();r.cleanup.assert_not_called()
    def test_terminal_error_not_accepted(self):
        r,item=self.fixture(2)
        with self.assertRaisesRegex(ValueError,'normal_exit'):r.lifecycle('query',['list','-j'])
    def test_identity_failure_not_early_terminal_exception(self):
        r,item=self.fixture(0);r.spawn=mock.Mock(side_effect=RuntimeError('query_binary_identity'))
        with self.assertRaisesRegex(ValueError,'spawn_identity_failure'):r.lifecycle('query',['list','-j'])
        r.wait.assert_not_called()
    def test_compiler_sdk_env_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();binary=root/'swift-frontend';binary.write_bytes(b'compiler');driver=root/'swiftc';driver.symlink_to(binary)
            r=object.__new__(runner.HelperRunner);r.tools={'swift-frontend':{'path':str(binary),'sha256':runner.sha(binary)},'SDKROOT':str(root)}
            r.out=root;r.args=SimpleNamespace(xctrace=Path('/Xcode/Contents/Developer/usr/bin/xctrace'))
            r.processes=[];r.receipt={'processes':[]};r.save=mock.Mock()
            proc=SimpleNamespace(pid=42,poll=lambda:None)
            r.identity=SimpleNamespace(read=lambda pid:{'pid':42,'parentPID':os.getpid(),'uid':os.getuid(),'executable':str(binary),'startTimeMicros':2*10**18})
            with mock.patch.object(runner.subprocess,'Popen',return_value=proc) as popen, mock.patch.dict(os.environ,{'SDKROOT':'/wrong','UNRELATED_SECRET':'no'},clear=True):
                item=r.spawn('helper-compile',[str(driver),'-sdk',str(root)],binary,runner.sha(binary))
                env=popen.call_args.kwargs['env'];self.assertEqual(env['SDKROOT'],str(root));self.assertNotIn('UNRELATED_SECRET',env)
            for stream in item['streams']:stream.close()
    def test_inventory_failure_retained_before_runner(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ,ENV,clear=True),mock.patch.object(run.platform,'machine',return_value='arm64'),mock.patch.object(run,'frozen',return_value={'files':{}}),mock.patch.object(run,'selected_snapshot',return_value={}),mock.patch.object(run,'sha',return_value='digest'),mock.patch.object(run,'tool_inventory',return_value={'complete':False,'entries':{'xctrace':{'observed':'unknown'}}}),mock.patch.object(run,'HelperRunner') as constructor:
            output=Path(tmp)/'evidence';self.assertEqual(run.run(output,Path('/developer')),1)
            data=json.loads((output/'receipt.json').read_text());self.assertEqual(data['stage'],'tool-inventory');self.assertFalse(data['helperTransportQualified'])
            self.assertTrue((output/'identity-inventory.json').exists());constructor.assert_not_called()
    def test_full_source_contract(self):self.assertTrue(contract.frozen()['files'])

class ArchiveCustodyTests(unittest.TestCase):
    def preserve(self, evidence, destination):
        with mock.patch.object(run.archive.shutil,'disk_usage',return_value=SimpleNamespace(free=16*1024**3)):
            self.assertEqual(run.archive_evidence(evidence,destination),0)
    def test_rejected_symlink_retains_compact_first_fault_without_raw_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();evidence=root/'evidence';evidence.mkdir()
            (evidence/'receipt.json').write_text(json.dumps({'stage':'capture','error':'artifact_symlink','unboundedPayload':'not copied'}))
            (evidence/'bad-link').symlink_to(evidence/'receipt.json')
            destination=root/'archive';github=root/'github-output'
            with mock.patch.dict(os.environ,{'GITHUB_OUTPUT':str(github)}),mock.patch.object(run.archive,'run') as archiver:
                with mock.patch.object(sys,'argv',['helper','archive','--output',str(evidence),'--archive',str(destination)]):
                    self.assertEqual(run.main(),1)
                archiver.assert_not_called()
            value=json.loads((destination/'report/receipt.json').read_text())
            self.assertFalse(value['archivePreserved']);self.assertFalse(value['rawFallbackQualified'])
            self.assertIn('snapshot_links',value['error'])
            self.assertEqual(value['failureReceipts'],{'receipt.json':{'stage':'capture','error':'artifact_symlink'}})
            self.assertEqual(github.read_text(),'artifact_path='+str(destination/'report')+'\n')
            self.assertEqual([str(p.relative_to(destination)) for p in destination.rglob('*') if p.is_file()],['report/receipt.json'])
            with mock.patch.dict(os.environ,ENV),mock.patch.object(run,'HelperRunner') as native:
                self.assertEqual(run.cleanup(evidence,destination,root/'cleanup'),1);native.assert_not_called()
    def test_oversized_evidence_keeps_only_bounded_failure_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();evidence=root/'evidence';evidence.mkdir()
            with (evidence/'oversized').open('wb') as stream:stream.truncate(512*1024**2+1)
            self.assertEqual(run.archive_evidence(evidence,root/'archive'),1)
            value=json.loads((root/'archive/report/receipt.json').read_text())
            self.assertIn('snapshot_bytes',value['error']);self.assertFalse(value['archivePreserved'])
            self.assertLess((root/'archive/report/receipt.json').stat().st_size,4096)
            self.assertFalse((root/'archive/complete').exists())
    def test_exact_preserved_inputs_and_disposable_copy_exclusion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();evidence=root/'evidence';evidence.mkdir()
            (evidence/'device.json').write_text('{"createdUDID":"original"}')
            clone=evidence/'export/inspection.trace';clone.mkdir(parents=True);(clone/'data').write_bytes(b'disposable')
            self.preserve(evidence,root/'archive')
            run.require_archived_inputs(evidence,root/'archive')
            (clone/'data').write_bytes(b'changed inspection copy')
            run.require_archived_inputs(evidence,root/'archive')
    def test_different_valid_archive_blocks_cleanup_before_native_construction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();old=root/'old';old.mkdir();(old/'device.json').write_text('{"createdUDID":"old"}')
            evidence=root/'evidence';evidence.mkdir();(evidence/'device.json').write_text('{"createdUDID":"new"}')
            self.preserve(old,root/'archive')
            with mock.patch.dict(os.environ,ENV),mock.patch.object(run,'HelperRunner') as native:
                self.assertEqual(run.cleanup(evidence,root/'archive',root/'cleanup'),1);native.assert_not_called()
            self.assertIn('helper_archive_input_changed',json.loads((root/'cleanup/receipt.json').read_text())['error'])
    def test_changed_device_phase_receipt_and_modes_rejected(self):
        for name in ('device.json','receipt.json','prepare/receipt.json','capture/receipt.json','export/receipt.json'):
            with self.subTest(name=name),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp).resolve();evidence=root/'evidence';path=evidence/name;path.parent.mkdir(parents=True)
                path.write_text('{"status":"original"}');self.preserve(evidence,root/'archive')
                path.write_text('{"status":"changed"}')
                with self.assertRaisesRegex(ValueError,'helper_archive_input_changed'):run.require_archived_inputs(evidence,root/'archive')
                path.write_text('{"status":"original"}');path.chmod(0o600)
                with self.assertRaisesRegex(ValueError,'helper_archive_input_changed'):run.require_archived_inputs(evidence,root/'archive')
    def test_missing_and_added_live_members_rejected(self):
        for add in (True,False):
            with self.subTest(add=add),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp).resolve();evidence=root/'evidence';evidence.mkdir();path=evidence/'device.json';path.write_text('{}')
                self.preserve(evidence,root/'archive')
                if add:(evidence/'unpreserved.json').write_text('{}')
                else:path.unlink()
                with self.assertRaisesRegex(ValueError,'helper_archive_input_changed'):run.require_archived_inputs(evidence,root/'archive')

class WorkflowTests(unittest.TestCase):
    def setUp(self):self.text=(contract.ROOT/'.github/workflows/ios-performance.yml').read_text()
    def test_default_off_dispatch_only(self):
        dispatch=self.text.split('  workflow_dispatch:',1)[1].split('  workflow_call:',1)[0]
        option=dispatch.split('      simulator_signpost_control:',1)[1].split('      observe_app_scroll_signposts:',1)[0]
        self.assertIn('type: boolean',option);self.assertIn('default: false',option)
        called=self.text.split('  workflow_call:',1)[1].split('permissions:',1)[0]
        self.assertNotIn('simulator_signpost_control',called)
    def test_original_jobs_excluded_only_on_helper_mode(self):
        build=self.text.split('  performance-build:',1)[1].split('  performance-tests:',1)[0]
        consumer=self.text.split('  performance-tests:',1)[1].split('  simulator-signpost-control:',1)[0]
        self.assertIn('if: ${{ !inputs.simulator_signpost_control }}',build)
        self.assertIn('!inputs.capture_preflight_only && !inputs.simulator_signpost_control',consumer)
        self.assertIn('needs: performance-build',consumer)
    def test_one_slot_no_app_commands(self):
        job=self.text.split('  simulator-signpost-control:',1)[1]
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.simulator_signpost_control",job)
        self.assertIn('group: ritc-macos-slot-2',job);self.assertIn('queue: max',job)
        self.assertIn('cancel-in-progress: false',job);self.assertIn('runs-on: xcode-27',job)
        for banned in ('xcodebuild','xctest','run_ios_test_shard','check_ios_performance.py','build-for-testing'):
            self.assertNotIn(banned,job)
    def test_archive_precedes_delete_and_no_duplicate_tree_upload(self):
        job=self.text.split('  simulator-signpost-control:',1)[1]
        self.assertLess(job.index(' run --output'),job.index(' archive --output'))
        self.assertLess(job.index(' archive --output'),job.index(' cleanup --output'))
        self.assertIn("steps.helper-archive.outcome == 'success'",job)
        upload=job.split('          path: |',1)[1].split('          if-no-files-found:',1)[0]
        self.assertIn('steps.helper-archive.outputs.artifact_path',upload)
        self.assertNotIn('\n            .build/simulator-helper\n',upload)

class AcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.clock=0.;self.terminal=None;self.reads=0
        self.r=object.__new__(runner.HelperRunner);self.r.budget=mock.Mock();self.r.save=mock.Mock();self.r.device=DEVICE
        self.r.tools={'simctl':{'path':'/launcher','sha256':'launcher-sha','executable':'/actual','executableSHA256':'digest'}}
        self.process=SimpleNamespace(pid=42,poll=self.poll,returncode=None)
        self.item={'process':self.process,'record':{'label':'before','argv':['/launcher','list','-j'],'spawnEpoch':100.,'signals':[]},
                   'expected':'/actual','digest':'digest','binding':None}
        self.r.identity=SimpleNamespace(read=self.identity)
        self.value={'pid':42,'parentPID':os.getpid(),'uid':os.getuid(),'startTimeMicros':100_000_001,'executable':'/actual'}
        self.read_value=lambda:self.value
        self.patches=[mock.patch.object(runner.time,'monotonic',side_effect=lambda:self.clock),
                      mock.patch.object(runner.time,'sleep',side_effect=self.sleep),
                      mock.patch.object(runner,'launcher_identity'),mock.patch.object(runner,'sha',return_value='digest')]
        for p in self.patches:p.start();self.addCleanup(p.stop)
    def sleep(self,seconds):self.clock+=seconds
    def poll(self):
        if self.terminal is not None and self.clock>=self.terminal:self.process.returncode=0
        return self.process.returncode
    def identity(self,pid):self.reads+=1;return self.read_value()
    def acquire(self,deadline=30):return self.r.acquire_inventory(self.item,deadline)
    def test_same_child_interpreter_then_exact_binding_after_two_seconds(self):
        self.read_value=lambda:{**self.value,'executable':str(Path('/bin/bash').resolve())} if self.clock<3 else self.value
        self.assertIs(self.acquire(),self.item);self.assertGreaterEqual(self.clock,3)
        self.assertEqual(self.item['binding'],self.value);self.assertEqual(self.item['record']['signals'],[])
        d=self.item['record']['inventoryAcquisition'];self.assertGreater(d['interpreter'],0);self.assertEqual(d['outcome'],'bound')
    def test_missing_identity_then_owned_terminal_exit(self):
        self.read_value=lambda:None;self.terminal=.2
        self.assertIs(self.acquire(),self.item);self.assertIsNone(self.item['binding'])
        self.assertTrue(self.item['record']['terminalOwnedCommandBeforeBinding']);self.assertEqual(self.item['record']['signals'],[])
    def test_permanent_missing_times_out_at_original_deadline(self):
        self.read_value=lambda:None
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.acquire(.2)
        self.assertAlmostEqual(self.clock,.2);self.assertIsNone(self.item['binding']);self.assertEqual(self.item['record']['signals'],[])
    def test_terminal_at_deadline_is_not_late_success(self):
        self.read_value=lambda:None;self.terminal=.2
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.acquire(.2)
    def test_unknown_executable_rejected(self):
        self.read_value=lambda:{**self.value,'executable':'/unreviewed'}
        with self.assertRaisesRegex(ValueError,'inventory_executable'):self.acquire()
        self.assertIsNone(self.item['binding']);self.assertEqual(self.item['record']['signals'],[])
    def test_wrong_pid_uid_parent_and_start_rejected(self):
        for key,value in (('pid',43),('uid',os.getuid()+1),('parentPID',os.getpid()+1),('startTimeMicros',99_999_999)):
            self.read_value=lambda k=key,v=value:{**self.value,k:v}
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'inventory_identity'):self.acquire()
            self.assertIsNone(self.item['binding'])
    def test_interpreter_to_reused_identity_rejected(self):
        self.read_value=lambda:{**self.value,'executable':str(Path('/bin/bash').resolve())} if self.reads==1 else {**self.value,'startTimeMicros':100_000_002}
        with self.assertRaisesRegex(ValueError,'inventory_identity_changed'):self.acquire()
    def test_recheck_identity_drift_after_hash_rejected(self):
        self.read_value=lambda:self.value if self.reads==1 else {**self.value,'executable':'/unreviewed'}
        with self.assertRaisesRegex(ValueError,'inventory_identity_changed'):self.acquire()
        self.assertIsNone(self.item['binding'])
    def test_exit_racing_identity_read_is_terminal_only(self):
        def race():self.process.returncode=0;return None
        self.read_value=race
        self.assertIs(self.acquire(),self.item);self.assertIsNone(self.item['binding'])
        self.assertTrue(self.item['record']['terminalOwnedCommandBeforeBinding'])
    def test_slow_identity_or_hash_cannot_bind_late(self):
        for mode in ('identity','hash'):
            self.clock=0;self.item['binding']=None
            if mode=='identity':
                def slow():self.clock=31;return self.value
                self.read_value=slow
                with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.acquire()
            else:
                self.read_value=lambda:self.value
                def slow_hash(path):self.clock=31;return 'digest'
                with mock.patch.object(runner,'sha',side_effect=slow_hash),self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.acquire()
            self.assertIsNone(self.item['binding'])
    def test_budget_failure_no_binding_or_signal(self):
        self.r.budget.side_effect=ValueError('phase_artifact_cap')
        with self.assertRaisesRegex(ValueError,'phase_artifact_cap'):self.acquire()
        self.assertIsNone(self.item['binding']);self.assertEqual(self.item['record']['signals'],[])
    def test_launcher_and_binary_drift_rejected(self):
        with mock.patch.object(runner,'launcher_identity',side_effect=ValueError('tool_file_identity')),self.assertRaisesRegex(ValueError,'tool_file_identity'):self.acquire()
        with mock.patch.object(runner,'sha',return_value='changed'),self.assertRaisesRegex(ValueError,'binary_identity'):self.acquire()
    def test_scope_rejects_mutation_capture_and_other_query(self):
        for tail in (['boot',DEVICE['createdUDID']],['spawn',DEVICE['createdUDID'],'helper'],['list','devices','-j']):
            self.item['record']['argv']=['/launcher',*tail]
            with self.assertRaisesRegex(ValueError,'acquisition_scope'):self.acquire()
    def test_lifecycle_does_not_respawn_or_reset_timeout(self):
        self.r.device=DEVICE;self.r.started=0;self.r.seconds=90;self.r.receipt={};self.r.processes=[];self.r.out=Path('/owned')
        def spawn(*a):
            self.r.processes.append(self.item);self.clock=2.1
            raise RuntimeError('before_unbound_or_early_exit')
        self.r.spawn=mock.Mock(side_effect=spawn);self.r.cleanup=mock.Mock()
        self.read_value=lambda:None;self.terminal=3
        self.assertEqual(self.r.lifecycle('before',['list','-j'],30),Path('/owned/before-stdout.log'))
        self.r.spawn.assert_called_once();self.r.cleanup.assert_called_once()
        self.assertEqual(self.item['record']['inventoryAcquisition']['deadlineMonotonic'],30)
        self.assertEqual(self.r.receipt['lifecycleCommands'][0]['outcome'],'normal_exit')
    def test_phase_budget_is_not_reset_by_command(self):
        self.r.device=DEVICE;self.r.started=0;self.r.seconds=10;self.r.receipt={};self.r.processes=[];self.r.out=Path('/owned')
        self.clock=9
        def spawn(*a):self.r.processes.append(self.item);raise RuntimeError('before_unbound_or_early_exit')
        self.r.spawn=mock.Mock(side_effect=spawn);self.read_value=lambda:None
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.r.lifecycle('before',['list','-j'],30)
        self.assertEqual(self.r.receipt['lifecycleCommands'][0]['deadlineMonotonic'],10)
        self.assertAlmostEqual(self.clock,10);self.r.spawn.assert_called_once()

    def test_wait_progress_is_bounded_and_does_not_rehash_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.r.out=Path(tmp);self.item['binding']=self.value
            for name in ('before-stdout.log','before-stderr.log'):(self.r.out/name).write_bytes(b'')
            self.terminal=2.4;d={}
            with mock.patch.object(runner,'sha') as hashing:
                self.assertEqual(self.r.lifecycle_wait(self.item,30,d),0)
                hashing.assert_not_called()
            self.assertGreaterEqual(d['progressSamples'],3);self.assertLessEqual(len(d['firstProgress']),4)
            self.assertEqual(d['lastProgress']['stdoutBytes'],0)
    def test_live_wait_identity_drift_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.r.out=Path(tmp);self.item['binding']=self.value
            for name in ('before-stdout.log','before-stderr.log'):(self.r.out/name).write_bytes(b'')
            self.read_value=lambda:{**self.value,'executable':'/other'}
            with self.assertRaisesRegex(ValueError,'lifecycle_identity_changed'):self.r.lifecycle_wait(self.item,30,{})
            self.assertEqual(self.item['record']['signals'],[])
    def test_wait_terminal_boundary_and_late_output_budget_fail(self):
        self.process.returncode=0;self.clock=30
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.r.lifecycle_wait(self.item,30,{})
        self.clock=29;self.r.budget.side_effect=ValueError('phase_log_cap')
        with self.assertRaisesRegex(ValueError,'phase_log_cap'):self.r.lifecycle_wait(self.item,30,{})

    def test_actual_lifecycle_honors_shared_absolute_deadline(self):
        self.r.device=DEVICE;self.r.started=0;self.r.seconds=90;self.r.receipt={};self.r.processes=[];self.r.out=Path('/owned')
        def spawn(*a):self.r.processes.append(self.item);raise RuntimeError('before_unbound_or_early_exit')
        self.r.spawn=mock.Mock(side_effect=spawn);self.read_value=lambda:None
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):
            self.r.lifecycle('before',['list','-j'],30,absolute_deadline=5)
        self.assertEqual(self.r.receipt['lifecycleCommands'][0]['deadlineMonotonic'],5)
        self.assertAlmostEqual(self.clock,5);self.r.spawn.assert_called_once()
    def test_new_scoped_queries_retain_same_child_binding(self):
        for tail in (['list','-j','runtimes'],['list','-j','devices',DEVICE['createdUDID']]):
            self.item['record']['argv']=['/launcher',*tail];self.item['binding']=None
            self.assertIs(self.acquire(),self.item);self.assertEqual(self.item['binding'],self.value)
            self.assertEqual(self.item['record']['signals'],[])

class BootAndSummaryTests(unittest.TestCase):
    def test_existing_boot_allowance_and_collector_limits(self):
        self.assertEqual(run.BOOT_PREPARATION_SECONDS,180)
        self.assertEqual((host_control.STARTUP_SECONDS,control.FINALIZE_SECONDS,host_control.EXPORT_SECONDS),(15,30,10))
        s=inspect.getsource(run.run);self.assertIn("HelperRunner(output/'prepare',tool,300",s)
        self.assertIn('BOOT_PREPARATION_SECONDS)',s)
        self.assertIn('HelperRunner(destination,tool,90)',inspect.getsource(run.cleanup))
    def test_zero_exit_migration_failure_output_rejected_on_either_stream(self):
        for text in (b'Data Migration Failed\n',b'  Data Migration Failed  \n',b'[2026-11-09] Status=3, isTerminal=YES, Elapsed=1\n',b'[time] Status=3, isTerminal=YES.\n'):
            for streams in ((text,b''),(b'',text)):
                with self.subTest(text=text,streams=streams),self.assertRaisesRegex(ValueError,'migration_failed'):run.verify_boot_output(*streams)
    def test_normal_already_booted_and_nonterminal_status_accepted(self):
        for raw in (b'',b'Device is already booted.\n',b'[time] Status=3, isTerminal=NO, Elapsed=1\n',b'[time] Status=4, isTerminal=YES.\n'):
            run.verify_boot_output(raw,b'')
    def test_boot_output_cap(self):
        with self.assertRaisesRegex(ValueError,'boot_log_cap'):run.verify_boot_output(b'x'*(1024**2+1),b'')
    def test_summary_is_bounded_and_omits_payload_and_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'receipt.json';p.write_text(json.dumps({'stage':'boot','error':'RuntimeError: bootstatus_deadline /secret arbitrary '+('x'*10000),'helperTransportQualified':False,'tools':{'secret':'never print'}}))
            stream=io.StringIO()
            with contextlib.redirect_stdout(stream):v=run.terminal_summary('run',p)
            self.assertEqual(v['firstCause'],'RuntimeError:bootstatus_deadline');self.assertEqual(v['status'],'failed')
            self.assertLess(len(stream.getvalue()),500);self.assertNotIn('secret',stream.getvalue());self.assertNotIn('arbitrary',stream.getvalue())
    def test_cleanup_summary_does_not_infer_deletion_from_terminal_tools(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'receipt.json';p.write_text(json.dumps({'status':'failed','allKnownChildrenTerminal':True,'error':'ValueError: helper_device_identity'}))
            with contextlib.redirect_stdout(io.StringIO()):v=run.terminal_summary('cleanup',p)
            self.assertEqual(v['cleanup'],'not_verified');self.assertEqual(v['status'],'failed');self.assertFalse(v['helperTransportQualified'])

    def test_malformed_missing_summary_and_invocation_error_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'receipt.json'
            with contextlib.redirect_stdout(io.StringIO()):v=run.terminal_summary('run',p)
            self.assertEqual(v['firstCause'],'RuntimeError:summary_receipt_unavailable')
            p.write_text('[]')
            with contextlib.redirect_stdout(io.StringIO()):v=run.terminal_summary('run',p)
            self.assertEqual(v['status'],'failed')
            p.write_text(json.dumps({'helperTransportQualified':True,'stage':'validated'}))
            with contextlib.redirect_stdout(io.StringIO()):v=run.terminal_summary('run',p,'RuntimeError: final_failure')
            self.assertEqual(v['status'],'failed');self.assertFalse(v['helperTransportQualified'])

class ScopedPostBootTests(unittest.TestCase):
    def setUp(self):
        self.clock=0;self.commands=[];self.response=inventory();self.costs=[1,1];self.read_cost=0
        self.r=SimpleNamespace(started=0,seconds=300,lifecycle=self.command,lifecycle_check=self.check)
        for patch in (mock.patch.object(run.time,'monotonic',side_effect=lambda:self.clock),
                      mock.patch.object(run,'read',side_effect=self.read)):
            patch.start();self.addCleanup(patch.stop)
    def check(self,deadline):
        if self.clock>=deadline:raise ValueError('helper_lifecycle_deadline')
    def command(self,label,tail,**kwargs):
        self.commands.append((label,tail,kwargs['absolute_deadline']))
        self.clock+=self.costs[len(self.commands)-1];self.check(kwargs['absolute_deadline'])
        return tail[2]
    def read(self,key):self.clock+=self.read_cost;return {key:self.response[key]}
    def test_two_fresh_scoped_commands_same_original_budget(self):
        self.assertEqual(run.verify_post_boot_device(self.r,DEVICE)['udid'],DEVICE['createdUDID'])
        self.assertEqual(self.commands,[('booted-runtimes',['list','-j','runtimes'],30),
                                        ('booted-device',['list','-j','devices',DEVICE['createdUDID']],30)])
    def test_missing_duplicate_and_changed_runtime_fail_before_device_query(self):
        for mutate in ('missing','duplicate','build','bundle','availability'):
            self.commands=[];self.clock=0;self.response=inventory()
            if mutate=='missing':self.response['runtimes']=[]
            elif mutate=='duplicate':self.response['runtimes']*=2
            elif mutate=='build':self.response['runtimes'][0]['buildversion']='other'
            elif mutate=='bundle':self.response['runtimes'][0]['bundlePath']='/other'
            else:self.response['runtimes'][0]['isAvailable']=False
            with self.subTest(mutate=mutate),self.assertRaises(ValueError):run.verify_post_boot_device(self.r,DEVICE)
            self.assertEqual(len(self.commands),1)
    def test_missing_duplicate_wrong_uuid_name_type_state_runtime_availability(self):
        for mutate in ('missing','duplicate','extra','uuid','name','type','state','runtime','availability'):
            self.commands=[];self.clock=0;self.response=inventory();rows=self.response['devices'][run.RUNTIME]
            if mutate=='missing':rows.clear()
            elif mutate=='duplicate':rows*=2
            elif mutate=='extra':rows.append({**rows[0],'udid':DEVICE['sourceUDID']})
            elif mutate=='uuid':rows[0]['udid']=DEVICE['createdUDID']+'-substring'
            elif mutate=='name':rows[0]['name']='other-owner'
            elif mutate=='type':rows[0]['deviceTypeIdentifier']='other'
            elif mutate=='state':rows[0]['state']='Shutdown'
            elif mutate=='availability':rows[0]['isAvailable']=False
            else:self.response['devices']={'other-runtime':rows}
            with self.subTest(mutate=mutate),self.assertRaises(ValueError):run.verify_post_boot_device(self.r,DEVICE)
            self.assertEqual(len(self.commands),2)
    def test_fresh_both_commands_required_no_cached_result(self):
        self.response['devices'][run.RUNTIME][0]['name']='new-name'
        with self.assertRaisesRegex(ValueError,'device_identity'):run.verify_post_boot_device(self.r,DEVICE)
        self.assertEqual(len(self.commands),2)
    def test_combined_budget_exhaustion_does_not_retry_or_reset(self):
        self.costs=[20,11]
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):run.verify_post_boot_device(self.r,DEVICE)
        self.assertEqual([x[2] for x in self.commands],[30,30]);self.assertEqual(len(self.commands),2)
    def test_runtime_parse_consumes_shared_budget_before_second_spawn(self):
        self.costs=[29,1];self.read_cost=1
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):run.verify_post_boot_device(self.r,DEVICE)
        self.assertEqual(len(self.commands),1)
    def test_device_parse_cannot_succeed_after_deadline(self):
        self.costs=[1,27];self.read_cost=1
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):run.verify_post_boot_device(self.r,DEVICE)
        self.assertEqual(len(self.commands),2)
    def test_remaining_outer_phase_budget_wins(self):
        self.clock=295
        run.verify_post_boot_device(self.r,DEVICE)
        self.assertEqual([x[2] for x in self.commands],[300,300])
    def test_new_inventory_whitelist_is_exact(self):
        for tail in (['list','-j','runtimes'],['list','-j','devices',DEVICE['createdUDID']]):
            self.assertTrue(runner.inventory_allowed(tail,DEVICE));self.assertTrue(runner.lifecycle_allowed(tail,DEVICE))
        for tail in (['list','-j','devices','available'],['list','-j','devices',DEVICE['sourceUDID']],['list','-j','devices'],['list','-j','runtimes','available'],['list','-j','pairs']):
            self.assertFalse(runner.inventory_allowed(tail,DEVICE));self.assertFalse(runner.lifecycle_allowed(tail,DEVICE))
        self.assertFalse(runner.inventory_allowed(['list','-j','devices',DEVICE['createdUDID']],{}))
    def test_original_creation_and_cleanup_inventory_paths_unchanged(self):
        source=inspect.getsource(run.run)
        self.assertIn("runner.command('inventory','simctl',['list','-j']",source)
        self.assertIn("runner.lifecycle('created',['list','-j'])",source)
        cleanup=inspect.getsource(run.cleanup)
        for label in ('before','shutdown-verified','deleted'):self.assertIn("runner.lifecycle('"+label+"',['list','-j'])",cleanup)

if __name__=='__main__':unittest.main()
