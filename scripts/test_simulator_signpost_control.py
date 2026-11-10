"""File-only helper/workflow controls. Never instantiate native Identity or launch tools."""
import copy
import ast
import builtins
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
from app_scroll_observation import contract, owned

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
    def test_lifecycle_spawn_exact_single_child_and_minimal_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            r=object.__new__(runner.HelperRunner);r.device=DEVICE;r.processes=[];r.out=Path(tmp)
            r.tools={'simctl':{'path':'/launcher','sha256':'launcher','executable':'/actual','executableSHA256':'digest'}}
            r.args=SimpleNamespace(xctrace=Path('/Xcode/Contents/Developer/usr/bin/xctrace'))
            r.receipt={'processes':[]};r.save=mock.Mock();r.budget=mock.Mock()
            proc=SimpleNamespace(pid=42,poll=lambda:None)
            with mock.patch.object(runner,'launcher_identity'),mock.patch.object(runner.subprocess,'Popen',return_value=proc) as popen,mock.patch.dict(os.environ,{'HOME':tmp,'SDKROOT':'wrong','SECRET':'no'},clear=True):
                item=r.spawn_lifecycle('delete',['delete',DEVICE['createdUDID']],runner.time.monotonic()+30)
                popen.assert_called_once();self.assertEqual(popen.call_args.args[0],['/launcher','delete',DEVICE['createdUDID']])
                self.assertNotIn('SECRET',popen.call_args.kwargs['env']);self.assertNotIn('SDKROOT',popen.call_args.kwargs['env'])
                self.assertTrue(popen.call_args.kwargs['start_new_session']);self.assertIsNone(item['binding'])
                self.assertIs(r.processes[0],item);self.assertEqual(item['record']['pid'],42)
            for stream in item['streams']:stream.close()
    def test_lifecycle_spawn_rejects_other_device_before_popen(self):
        r=object.__new__(runner.HelperRunner);r.device=DEVICE
        with mock.patch.object(runner.subprocess,'Popen') as popen,self.assertRaisesRegex(ValueError,'lifecycle_scope'):
            r.spawn_lifecycle('delete',['delete',DEVICE['sourceUDID']],30)
        popen.assert_not_called()
    def test_lifecycle_spawn_deadline_before_creation(self):
        r=object.__new__(runner.HelperRunner);r.device=DEVICE;r.processes=[];r.budget=mock.Mock()
        with mock.patch.object(runner.subprocess,'Popen') as popen,self.assertRaisesRegex(ValueError,'lifecycle_deadline'):
            r.spawn_lifecycle('delete',['delete',DEVICE['createdUDID']],0)
        popen.assert_not_called()
    def test_lifecycle_spawn_tool_drift_does_not_create_child(self):
        r=object.__new__(runner.HelperRunner);r.device=DEVICE;r.processes=[];r.budget=mock.Mock()
        r.tools={'simctl':{'path':'/launcher','sha256':'launcher','executable':'/actual','executableSHA256':'digest'}}
        with mock.patch.object(runner,'launcher_identity',side_effect=ValueError('tool_file_identity')),mock.patch.object(runner.subprocess,'Popen') as popen,self.assertRaisesRegex(ValueError,'tool_file_identity'):
            r.spawn_lifecycle('delete',['delete',DEVICE['createdUDID']],runner.time.monotonic()+30)
        popen.assert_not_called()
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
        self.item={'process':self.process,'record':{'label':'before','argv':['/launcher','list','-j'],'spawnEpoch':100.,'signals':[],'pid':42,'executableSHA256':'digest'},
                   'expected':'/actual','digest':'digest','binding':None}
        self.r.processes=[self.item]
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
    def acquire(self,deadline=30):return self.r.acquire_lifecycle(self.item,deadline)
    def test_same_child_interpreter_then_exact_binding_after_two_seconds(self):
        self.read_value=lambda:{**self.value,'executable':str(Path('/bin/bash').resolve())} if self.clock<3 else self.value
        self.assertIs(self.acquire(),self.item);self.assertGreaterEqual(self.clock,3)
        self.assertEqual(self.item['binding'],self.value);self.assertEqual(self.item['record']['signals'],[])
        d=self.item['record']['lifecycleAcquisition'];self.assertGreater(d['interpreter'],0);self.assertEqual(d['outcome'],'bound')
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
        for tail in (['boot',DEVICE['sourceUDID']],['spawn',DEVICE['createdUDID'],'helper'],['list','devices','-j']):
            self.item['record']['argv']=['/launcher',*tail]
            with self.assertRaisesRegex(ValueError,'acquisition_scope'):self.acquire()
    def test_lifecycle_does_not_respawn_or_reset_timeout(self):
        self.r.device=DEVICE;self.r.started=0;self.r.seconds=90;self.r.receipt={};self.r.processes=[];self.r.out=Path('/owned')
        def spawn(*a):
            self.r.processes.append(self.item);self.clock=2.1
            return self.item
        self.r.spawn_lifecycle=mock.Mock(side_effect=spawn);self.r.cleanup=mock.Mock()
        self.read_value=lambda:None;self.terminal=3
        self.assertEqual(self.r.lifecycle('before',['list','-j'],30),Path('/owned/before-stdout.log'))
        self.r.spawn_lifecycle.assert_called_once();self.r.cleanup.assert_called_once()
        self.assertEqual(self.item['record']['lifecycleAcquisition']['deadlineMonotonic'],30)
        self.assertEqual(self.r.receipt['lifecycleCommands'][0]['outcome'],'normal_exit')
    def test_phase_budget_is_not_reset_by_command(self):
        self.r.device=DEVICE;self.r.started=0;self.r.seconds=10;self.r.receipt={};self.r.processes=[];self.r.out=Path('/owned')
        self.clock=9
        def spawn(*a):self.r.processes.append(self.item);return self.item
        self.r.spawn_lifecycle=mock.Mock(side_effect=spawn);self.read_value=lambda:None
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.r.lifecycle('before',['list','-j'],30)
        self.assertEqual(self.r.receipt['lifecycleCommands'][0]['deadlineMonotonic'],10)
        self.assertAlmostEqual(self.clock,10);self.r.spawn_lifecycle.assert_called_once()

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
        def spawn(*a):self.r.processes.append(self.item);return self.item
        self.r.spawn_lifecycle=mock.Mock(side_effect=spawn);self.read_value=lambda:None
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):
            self.r.lifecycle('before',['list','-j'],30,absolute_deadline=5)
        self.assertEqual(self.r.receipt['lifecycleCommands'][0]['deadlineMonotonic'],5)
        self.assertAlmostEqual(self.clock,5);self.r.spawn_lifecycle.assert_called_once()
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

class BootstatusAcquisitionTests(unittest.TestCase):
    sleep=AcquisitionTests.sleep
    poll=AcquisitionTests.poll
    identity=AcquisitionTests.identity
    acquire=AcquisitionTests.acquire
    def setUp(self):
        AcquisitionTests.setUp(self)
        self.item['record'].update(label='bootstatus',argv=['/launcher','bootstatus',DEVICE['createdUDID'],'-b'])
        self.previous={'process':SimpleNamespace(pid=41,poll=lambda:0),'record':{'label':'boot','pid':41,
            'argv':['/launcher','boot',DEVICE['createdUDID']],'exitCode':0,'terminalVerified':True,'signals':[],
            'executableSHA256':'digest','spawnEpoch':99.,'binding':{**self.value,'pid':41,'startTimeMicros':99_000_001}}}
        self.r.processes=[self.previous,self.item]
        self.r.receipt={'lifecycleCommands':[{'label':'boot','pid':41,'outcome':'normal_exit'}]}
    def test_exact_existing_bootstatus_can_bind_after_initial_two_seconds(self):
        self.read_value=lambda:{**self.value,'executable':str(Path('/bin/bash').resolve())} if self.clock<3 else self.value
        self.assertIs(self.acquire(180),self.item);self.assertGreaterEqual(self.clock,3)
        self.assertEqual(self.item['binding'],self.value);self.assertEqual(self.item['record']['signals'],[])
        diagnostic=self.item['record']['lifecycleAcquisition']
        self.assertEqual(diagnostic['scope'],'same_owned_allowed_lifecycle');self.assertEqual(diagnostic['outcome'],'bound')
    def test_every_exact_owned_lifecycle_can_acquire(self):
        for tail in (['create',DEVICE['createdName'],DEVICE['deviceTypeIdentifier'],run.RUNTIME],['boot',DEVICE['createdUDID']],
                     ['bootstatus',DEVICE['createdUDID'],'-b'],['shutdown',DEVICE['createdUDID']],['delete',DEVICE['createdUDID']],
                     ['list','-j'],['list','-j','runtimes'],['list','-j','devices',DEVICE['createdUDID']]):
            self.item['record']['argv']=['/launcher',*tail];self.item['binding']=None
            with self.subTest(tail=tail):self.assertIs(self.acquire(30),self.item)
    def test_other_devices_unknown_commands_and_argument_drift_rejected(self):
        for tail in (['bootstatus',DEVICE['sourceUDID'],'-b'],['bootstatus',DEVICE['createdUDID']],['bootstatus','booted','-b'],
                     ['delete','all'],['shutdown',DEVICE['sourceUDID']],['create','arbitrary'],['erase',DEVICE['createdUDID']],
                     ['spawn',DEVICE['createdUDID'],'helper'],['bootstatus',DEVICE['createdUDID'],'-b','extra']):
            self.item['record']['argv']=['/launcher',*tail]
            with self.subTest(tail=tail),self.assertRaisesRegex(ValueError,'acquisition_scope'):self.acquire(30)
    def test_missing_duplicate_or_nonlast_item_rejected(self):
        for items in ([self.previous],[self.item,self.item],[self.item,self.previous]):
            self.r.processes=items
            with self.subTest(items=len(items)),self.assertRaisesRegex(ValueError,'acquisition_scope'):self.acquire(30)
    def test_prior_live_child_blocks_acquisition(self):
        self.previous['process'].poll=lambda:None
        with self.assertRaisesRegex(ValueError,'acquisition_scope'):self.acquire(30)
    def test_item_tool_and_pid_receipts_must_be_exact(self):
        for field,value in (('pid',999),('executableSHA256','changed')):
            old=self.item['record'][field];self.item['record'][field]=value
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'acquisition_scope'):self.acquire(30)
            self.item['record'][field]=old
        for field in ('expected','digest'):
            old=self.item[field];self.item[field]='changed'
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,'acquisition_scope'):self.acquire(30)
            self.item[field]=old
    def test_delete_can_bind_late_without_respawn_or_signal(self):
        self.item['record'].update(label='delete',argv=['/launcher','delete',DEVICE['createdUDID']])
        self.read_value=lambda:None if self.clock<2.8 else self.value
        self.assertIs(self.acquire(30),self.item);self.assertGreaterEqual(self.clock,2.8)
        self.assertEqual(self.item['record']['signals'],[]);self.assertGreater(self.item['record']['lifecycleAcquisition']['missing'],0)
    def test_initial_interpreter_missing_expected_samples_retained(self):
        self.read_value=lambda:None if self.reads==1 else {**self.value,'executable':str(Path('/bin/bash').resolve())} if self.reads==2 else self.value
        self.acquire(30);d=self.item['record']['lifecycleAcquisition']
        self.assertEqual([v['kind'] for v in d['first']],['missing','interpreter','expected'])
        self.assertNotIn('initialLiveBindingWindowSeconds',d)
    def test_unknown_executable_sample_retained_before_failure(self):
        self.read_value=lambda:{**self.value,'executable':'/other'}
        with self.assertRaisesRegex(ValueError,'inventory_executable'):self.acquire(30)
        self.assertEqual(self.item['record']['lifecycleAcquisition']['last']['kind'],'other')
    def test_missing_identity_or_late_binding_cannot_outlive_original180(self):
        self.read_value=lambda:None
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.acquire(180)
        self.assertAlmostEqual(self.clock,180);self.assertIsNone(self.item['binding']);self.assertEqual(self.item['record']['signals'],[])
        self.clock=180;self.read_value=lambda:self.value
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.acquire(180)
    def test_bootstatus_identity_hash_budget_and_unknown_executable_fail_closed(self):
        with mock.patch.object(runner,'sha',return_value='changed'),self.assertRaisesRegex(ValueError,'binary_identity'):self.acquire(180)
        self.read_value=lambda:{**self.value,'executable':'/other'}
        with self.assertRaisesRegex(ValueError,'inventory_executable'):self.acquire(180)
        self.read_value=lambda:{**self.value,'parentPID':os.getpid()+1}
        with self.assertRaisesRegex(ValueError,'inventory_identity'):self.acquire(180)
        self.r.budget.side_effect=ValueError('phase_log_cap')
        with self.assertRaisesRegex(ValueError,'phase_log_cap'):self.acquire(180)
        self.assertIsNone(self.item['binding']);self.assertEqual(self.item['record']['signals'],[])
    def test_full_lifecycle_uses_same_popen_existing_deadline_no_respawn(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.r.out=Path(tmp);self.r.started=0;self.r.seconds=300;self.r.processes=[self.previous]
            for name in ('bootstatus-stdout.log','bootstatus-stderr.log'):(self.r.out/name).write_bytes(b'')
            self.clock=20
            def spawn(*args):self.r.processes.append(self.item);self.clock=22.8;return self.item
            self.r.spawn_lifecycle=mock.Mock(side_effect=spawn);self.r.cleanup=mock.Mock()
            self.read_value=lambda:{**self.value,'executable':str(Path('/bin/bash').resolve())} if self.clock<23.5 else self.value
            self.terminal=24
            self.assertEqual(self.r.lifecycle('bootstatus',['bootstatus',DEVICE['createdUDID'],'-b'],180),self.r.out/'bootstatus-stdout.log')
            self.r.spawn_lifecycle.assert_called_once();self.r.cleanup.assert_called_once()
            self.assertEqual(self.r.receipt['lifecycleCommands'][-1]['deadlineMonotonic'],200)
            self.assertEqual(self.item['record']['lifecycleAcquisition']['deadlineMonotonic'],200)
            self.assertEqual(self.item['record']['signals'],[])
    def test_nonzero_owned_terminal_bootstatus_is_not_success(self):
        self.r.out=Path('/owned');self.r.started=0;self.r.seconds=300;self.r.processes=[self.previous]
        def spawn(*args):self.r.processes.append(self.item);return self.item
        self.r.spawn_lifecycle=mock.Mock(side_effect=spawn);self.r.cleanup=mock.Mock();self.process.returncode=70
        with self.assertRaisesRegex(ValueError,'normal_exit'):self.r.lifecycle('bootstatus',['bootstatus',DEVICE['createdUDID'],'-b'],180)
        self.r.spawn_lifecycle.assert_called_once();self.assertIsNone(self.item['binding'])

    def test_bootstatus_continuation_cannot_extend_prepare300(self):
        self.r.out=Path('/owned');self.r.started=0;self.r.seconds=300;self.r.processes=[self.previous];self.clock=299
        def spawn(*args):self.r.processes.append(self.item);self.clock=299.2;return self.item
        self.r.spawn_lifecycle=mock.Mock(side_effect=spawn);self.read_value=lambda:None
        with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.r.lifecycle('bootstatus',['bootstatus',DEVICE['createdUDID'],'-b'],180)
        self.r.spawn_lifecycle.assert_called_once();self.assertEqual(self.r.receipt['lifecycleCommands'][-1]['deadlineMonotonic'],300)
        self.assertAlmostEqual(self.clock,300);self.assertIsNone(self.item['binding']);self.assertEqual(self.item['record']['signals'],[])
    def test_bootstatus_owned_exit_racing_identity_never_becomes_signal_target(self):
        def race():self.process.returncode=0;return None
        self.read_value=race
        self.assertIs(self.acquire(180),self.item);self.assertIsNone(self.item['binding'])
        self.assertTrue(self.item['record']['terminalOwnedCommandBeforeBinding']);self.assertEqual(self.item['record']['signals'],[])
        self.assertEqual(self.item['record']['lifecycleAcquisition']['outcome'],'terminal_before_binding')

class LifecycleCleanupTests(unittest.TestCase):
    setUp=AcquisitionTests.setUp
    sleep=AcquisitionTests.sleep
    poll=AcquisitionTests.poll
    identity=AcquisitionTests.identity
    acquire=AcquisitionTests.acquire
    def test_unbound_owned_child_is_never_signaled_by_original_cleanup(self):
        self.process.stdin=None;self.process.send_signal=mock.Mock();self.item['streams']=[]
        self.r.cleanup(self.item)
        self.process.send_signal.assert_not_called()
        self.assertEqual(self.item['record']['cleanupError'],'identity_unverified_no_signal')
        self.assertFalse(self.item['record']['terminalVerified'])
    def test_bound_identity_drift_is_never_signaled_by_original_cleanup(self):
        self.item['binding']=self.value;self.read_value=lambda:{**self.value,'startTimeMicros':100_000_002}
        self.process.stdin=None;self.process.send_signal=mock.Mock();self.item['streams']=[]
        self.r.cleanup(self.item);self.process.send_signal.assert_not_called()
        self.assertFalse(self.item['record']['terminalVerified'])
    def test_acquisition_keeps_all_three_phase_bounds(self):
        for deadline in (30,90,180):
            self.clock=deadline;self.read_value=lambda:self.value
            with self.subTest(deadline=deadline),self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.acquire(deadline)
        self.assertIsNone(self.item['binding'])

class RuntimeSampleTests(unittest.TestCase):
    def setUp(self):
        AcquisitionTests.setUp(self)
        p=mock.patch.object(owned,'sha',return_value='digest');p.start();self.addCleanup(p.stop)
        self.sample_stat=SimpleNamespace(st_mode=runner.stat.S_IFREG|0o755,st_uid=0,st_gid=0,
            st_size=4096,st_dev=7,st_ino=11,st_mtime_ns=123456789,st_nlink=1)
        self.sample_resolved=Path('/usr/bin/sample');self.sample_fs_error=None
        self.real_tool_reads=[]
        self.addCleanup(lambda:self.assertEqual(self.real_tool_reads,[],
            'sampler test bypassed synthetic filesystem fixture'))
        # Guard below pathlib so even a production change that bypasses the fixture
        # fails on macOS, where the real binary happens to exist, as well as Linux.
        def target(path):
            if isinstance(path,int):return False
            return os.path.normpath(os.fsdecode(path))=='/usr/bin/sample'
        def guarded(original):
            def call(path,*args,**kwargs):
                if target(path):
                    self.real_tool_reads.append(original.__name__)
                    raise AssertionError('real_sampler_filesystem_access_forbidden')
                return original(path,*args,**kwargs)
            return call
        self.unmocked_sample_lstat=Path.lstat
        self.unmocked_sample_resolve=Path.resolve
        for module,name in ((os,'stat'),(os,'lstat'),(os,'open'),(os,'readlink'),(builtins,'open'),(io,'open')):
            patch=mock.patch.object(module,name,side_effect=guarded(getattr(module,name)))
            patch.start();self.addCleanup(patch.stop)
        # Python 3.9 pathlib caches OS entrypoints in an accessor; newer Python
        # uses os directly. Guard both without depending on either implementation.
        accessor=getattr(Path(),'_accessor',None)
        if accessor is not None:
            for name in ('stat','lstat','open','readlink'):
                patch=mock.patch.object(accessor,name,side_effect=guarded(getattr(accessor,name)))
                patch.start();self.addCleanup(patch.stop)
        original_lstat=Path.lstat;original_resolve=Path.resolve
        def lstat(path,*args,**kwargs):
            if target(path):
                if self.sample_fs_error:raise self.sample_fs_error
                return self.sample_stat
            return original_lstat(path,*args,**kwargs)
        def resolve(path,*args,**kwargs):
            if target(path):
                if self.sample_fs_error:raise self.sample_fs_error
                return self.sample_resolved
            return original_resolve(path,*args,**kwargs)
        for name,method in (('lstat',lstat),('resolve',resolve)):
            patch=mock.patch.object(Path,name,method);patch.start();self.addCleanup(patch.stop)
    sleep=AcquisitionTests.sleep
    poll=AcquisitionTests.poll
    identity=AcquisitionTests.identity
    acquire=AcquisitionTests.acquire
    def prepare(self,tmp):
        self.r.out=Path(tmp);self.r.receipt={'processes':[]};self.r.sample_source_check=mock.Mock()
        self.item['record'].update(label='booted-runtimes',argv=['/launcher','list','-j','runtimes'])
        self.item['binding']=self.value
        for name in ('booted-runtimes-stdout.log','booted-runtimes-stderr.log'):(self.r.out/name).write_bytes(b'')
    def sampler(self,finish=.2,exitcode=0):
        proc=SimpleNamespace(pid=43,returncode=None,stdin=None)
        def poll():
            if self.clock>=finish and proc.returncode is None:proc.returncode=exitcode
            return proc.returncode
        proc.poll=poll
        proc.send_signal=mock.Mock(side_effect=lambda sig:setattr(proc,'returncode',-int(sig)))
        proc.wait=lambda timeout:proc.returncode
        def spawn(*a,**kw):Path(a[0][-1]).write_text('stack IPC wait');return proc
        identity=self.r.identity.read
        self.r.identity.read=lambda pid:({'pid':43,'parentPID':os.getpid(),'uid':os.getuid(),'startTimeMicros':2*10**18,'executable':'/usr/bin/sample'} if pid==43 else identity(pid))
        return proc,spawn
    def test_exact_fixed_sampler_one_second_and_terminal_before_return(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler();d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn) as popen:self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'passed');self.assertTrue(d['stackSample']['terminalVerified'])
            self.assertEqual(popen.call_args.args[0],['/usr/bin/sample','42','1','-file',str(self.r.out/'booted-runtimes-stack.txt')])
            popen.assert_called_once();proc.send_signal.assert_not_called();self.assertEqual(self.item['record']['signals'],[])
            self.assertEqual(d['stackSample']['tool']['sha256'],'digest')
    def test_sampler_timeout_is_separate_and_owned_child_reaped(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(100);d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'incomplete');self.assertEqual(d['stackSample']['reason'],'observation_timeout');self.assertIn('sample_observation_deadline',d['stackSample']['error'])
            self.assertTrue(d['stackSample']['terminalVerified']);proc.send_signal.assert_called_once()
            self.assertIsNone(self.item['process'].poll());self.assertEqual(self.item['record']['signals'],[])
    def test_wrong_or_missing_target_identity_prevents_sampler(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp)
            for v in (None,{**self.value,'startTimeMicros':100_000_002}):
                self.read_value=lambda:v;d={}
                with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
                popen.assert_not_called();self.assertIn('sample_target_identity',d['stackSample']['error'])
    def test_sampler_cannot_target_other_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.item['record']['argv']=['/launcher','list','-j'];d={}
            with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assertIn('sample_target_scope',d['stackSample']['error'])
    def test_insufficient_original_budget_never_spawns(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.clock=20;d={}
            with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assertIn('sample_remaining_budget',d['stackSample']['error'])
    def test_oversized_report_is_failure_and_child_terminal(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler();d={}
            def oversized(*a,**kw):
                result=spawn(*a,**kw);(self.r.out/'booted-runtimes-stack.txt').write_bytes(b'x'*(2*1024**2+1));return result
            with mock.patch.object(runner.subprocess,'Popen',side_effect=oversized):self.r.sample_runtime(self.item,30,d)
            self.assertIn('sample_output_cap',d['stackSample']['error'])
            # No libproc binding is needed to terminate this exact retained direct child.
            proc.send_signal.assert_called_once();self.assertTrue(d['stackSample']['terminalVerified'])
    def test_live_unbound_sampler_is_reaped_before_target_teardown(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(100);self.r.identity.read=lambda pid:self.value if pid==42 else None;d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            proc.send_signal.assert_called_once();self.assertTrue(d['stackSample']['terminalVerified'])
            self.assertIsNone(self.r.sample_child['binding'])
    def test_sampler_nonzero_exit_does_not_claim_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(.2,1);d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertIn('sample_exit',d['stackSample']['error']);self.assertTrue(d['stackSample']['terminalVerified'])
    def test_trigger_once_only_after_ten_seconds_and_zero_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.terminal=12;d={'startedMonotonic':0}
            def sample(*args):self.assertGreaterEqual(self.clock,10);args[2]['stackSample']={'status':'passed'}
            self.r.sample_runtime=mock.Mock(side_effect=sample)
            self.assertEqual(self.r.lifecycle_wait(self.item,30,d),0);self.r.sample_runtime.assert_called_once()
    def test_existing_output_prevents_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.terminal=12;(self.r.out/'booted-runtimes-stderr.log').write_text('progress')
            self.r.sample_runtime=mock.Mock()
            self.assertEqual(self.r.lifecycle_wait(self.item,30,{'startedMonotonic':0}),0);self.r.sample_runtime.assert_not_called()
    def test_original_query_deadline_survives_sampler_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);d={'startedMonotonic':0}
            self.r.sample_runtime=mock.Mock(side_effect=lambda *a:a[2].update(stackSample={'status':'failed','error':'sample_exit'}))
            with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.r.lifecycle_wait(self.item,30,d)
            self.assertAlmostEqual(self.clock,30);self.assertEqual(d['stackSample']['error'],'sample_exit')
            self.r.sample_runtime.assert_called_once()

    def test_system_tool_hash_drift_is_recorded_not_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler();d={};calls=0
            def digest(path):
                nonlocal calls
                if str(path)=='/usr/bin/sample':
                    calls+=1;return 'digest' if calls==1 else 'changed'
                return 'digest'
            with mock.patch.object(runner,'sha',side_effect=digest),mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'failed');self.assertFalse(d['stackSample']['toolUnchanged'])
    def test_system_tool_nonroot_owner_rejected_before_spawn(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.sample_stat.st_uid=501;d={}
            with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assertIn('sample_system_tool_shape',d['stackSample']['error'])
    def test_finish_cannot_reap_target_until_sampler_terminal(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(100);self.r.identity.read=lambda pid:self.value if pid==42 else None;d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertTrue(d['stackSample']['terminalVerified'])
            def target_poll():
                self.assertIsNotNone(proc.poll());return 0
            self.item['process'].poll=target_poll;self.item['process'].stdin=None;self.item['streams']=[]
            self.r.finish('retained_sample_failure')
            self.assertTrue(self.r.receipt['allKnownChildrenTerminal']);proc.send_signal.assert_called_once()
    def test_live_sampling_does_not_poll_or_reap_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler();d={};started=False
            def sample_spawn(*args,**kwargs):
                nonlocal started
                started=True;return spawn(*args,**kwargs)
            def target_poll():
                if started and proc.poll() is None:raise AssertionError('target must remain unreaped while sampler active')
                return None
            self.item['process'].poll=target_poll
            with mock.patch.object(runner.subprocess,'Popen',side_effect=sample_spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'passed')
    def test_target_drift_during_sample_stops_owned_sampler(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(100);d={};self.read_value=lambda:self.value if self.clock<.1 else None
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertIn('sample_target_identity',d['stackSample']['error']);self.assertTrue(d['stackSample']['terminalVerified'])
            self.assertEqual(self.item['record']['signals'],[])
    def test_non_runtime_lifecycle_is_never_sampled(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.item['record']['label']='before'
            for name in ('before-stdout.log','before-stderr.log'):(self.r.out/name).write_bytes(b'')
            self.terminal=12;self.r.sample_runtime=mock.Mock()
            self.assertEqual(self.r.lifecycle_wait(self.item,30,{'startedMonotonic':0}),0);self.r.sample_runtime.assert_not_called()

    def test_nondefault_sigchld_prevents_sampler(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp)
            for disposition in (runner.signal.SIG_IGN,lambda *a:None):
                d={}
                with mock.patch.object(runner.signal,'getsignal',return_value=disposition),mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
                popen.assert_not_called();self.assertIn('exclusive_reaper',d['stackSample']['error'])
    def test_other_threads_prevent_sampler(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);d={}
            with mock.patch.object(runner.threading,'active_count',return_value=2),mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assertIn('exclusive_reaper',d['stackSample']['error'])
    def test_unexpected_sampler_executable_fails_but_direct_child_is_reaped(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(100);identity=self.r.identity.read;d={}
            self.r.identity.read=lambda pid:({**identity(pid),'executable':'/unexpected'} if pid==43 else identity(pid))
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertIn('sample_child_identity',d['stackSample']['error']);self.assertTrue(d['stackSample']['terminalVerified'])
            proc.send_signal.assert_called_once();self.assertIsNone(self.r.sample_child['binding'])
    def test_changed_binary_cannot_disable_direct_child_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(100);d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn),mock.patch.object(owned,'sha',return_value='changed'):self.r.sample_runtime(self.item,30,d)
            self.assertTrue(d['stackSample']['terminalVerified']);proc.send_signal.assert_called_once()
    def test_foreign_reconstructed_and_wrong_owner_items_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler();d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            with self.assertRaisesRegex(ValueError,'cleanup_custody'):self.r.cleanup_sample(dict(self.r.sample_child))
            custody=self.r.sample_custody;self.r.sample_custody=(*custody[:2],os.getpid()+1)
            with self.assertRaisesRegex(ValueError,'cleanup_custody'):self.r.cleanup_sample(self.r.sample_child)
            proc.send_signal.assert_not_called()
    def test_already_reaped_child_not_signaled_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler();d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.r.cleanup_sample(self.r.sample_child);proc.send_signal.assert_not_called()
            self.assertTrue(self.r.sample_child['record']['terminalVerified'])
    def test_real_popen_send_signal_skips_already_reaped_object(self):
        # Invoke only the standard library method on an inert object; no process is created.
        p=object.__new__(runner.subprocess.Popen);p.returncode=0;p._child_created=False
        p.poll=mock.Mock(return_value=0)
        with mock.patch.object(os,'kill') as kill:runner.subprocess.Popen.send_signal(p,runner.signal.SIGINT)
        kill.assert_not_called()
    def test_sampler_cleanup_uses_original_bounded_signal_wait_ladder(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(100);d={};waits=[]
            proc.send_signal=mock.Mock()
            def wait(timeout):
                waits.append(timeout)
                if len(waits)<3:raise runner.subprocess.TimeoutExpired('sample',timeout)
                proc.returncode=-9;return -9
            proc.wait=wait
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(waits,[2,3,2]);self.assertTrue(d['stackSample']['terminalVerified'])
            self.assertEqual(self.r.sample_child['record']['signals'],['SIGINT','SIGTERM','SIGKILL'])

    def test_frozen_sampler_path_has_no_external_reaper_or_thread_start(self):
        from app_scroll_observation import runner as base_runner
        forbidden={'waitpid','waitid','wait3','wait4','fork','forkpty','Thread','set_wakeup_fd'}
        for module in (runner,run,owned,base_runner,control,host_control):
            tree=ast.parse(inspect.getsource(module))
            for call in (n for n in ast.walk(tree) if isinstance(n,ast.Call)):
                name=call.func.attr if isinstance(call.func,ast.Attribute) else call.func.id if isinstance(call.func,ast.Name) else ''
                self.assertNotIn(name,forbidden,module.__name__)
                if name=='signal' and call.args:
                    self.assertNotEqual(ast.unparse(call.args[0]),'signal.SIGCHLD')
    def test_completed_cleanup_ladder_is_not_retried(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(100);d={}
            proc.send_signal=mock.Mock()
            proc.wait=mock.Mock(side_effect=runner.subprocess.TimeoutExpired('sample',2))
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(proc.send_signal.call_count,3);self.assertFalse(d['stackSample']['terminalVerified'])
            with self.assertRaisesRegex(ValueError,'cleanup_not_terminal'):self.r.cleanup_sample(self.r.sample_child)
            self.assertEqual(proc.send_signal.call_count,3)
            with self.assertRaisesRegex(ValueError,'cleanup_not_terminal'):self.r.cleanup(self.item)
            self.assertEqual(self.item['record']['signals'],[])

    def test_setuid_or_setgid_system_sampler_rejected_before_spawn(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp)
            for bit in (0o4000,0o2000):
                self.sample_stat.st_mode=runner.stat.S_IFREG|0o755|bit;d={}
                with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
                popen.assert_not_called();self.assertIn('sample_system_tool_shape',d['stackSample']['error'])
    def test_successful_sigkill_with_wait_timeout_is_not_terminal_proof(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(100);d={}
            proc.send_signal=mock.Mock();proc.wait=mock.Mock(side_effect=runner.subprocess.TimeoutExpired('sample',2))
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            record=self.r.sample_child['record'];self.assertTrue(record['fatalSignalDelivered'])
            self.assertFalse(record['terminalVerified']);self.assertFalse(d['stackSample']['terminalVerified'])
            self.assertEqual([a['waitOutcome'] for a in record['signalAttempts']],['timeout']*3)
            self.assertIn('cleanup_not_terminal',d['stackSample']['cleanupError'])
            with self.assertRaisesRegex(ValueError,'cleanup_not_terminal'):self.r.finish('sample_failed')
            self.assertEqual(proc.send_signal.call_count,3)
    def test_delivery_errors_retained_and_never_claim_fatal_signal(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(100);d={}
            proc.send_signal=mock.Mock(side_effect=PermissionError('denied'));proc.wait=mock.Mock()
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            record=self.r.sample_child['record'];self.assertFalse(record.get('fatalSignalDelivered',False))
            self.assertFalse(record['terminalVerified']);self.assertEqual(record['signals'],[])
            self.assertEqual([a['signal'] for a in record['signalAttempts']],['SIGINT','SIGTERM','SIGKILL'])
            self.assertTrue(all('PermissionError' in a['deliveryError'] for a in record['signalAttempts']))
            proc.wait.assert_not_called()

    def test_missing_system_sampler_rejected_before_spawn(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.sample_fs_error=FileNotFoundError('synthetic sampler absent');d={}
            with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assertEqual(d['stackSample']['status'],'failed')
            self.assertIn('FileNotFoundError',d['stackSample']['error'])
    def test_symlink_system_sampler_rejected_before_spawn(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.sample_stat.st_mode=runner.stat.S_IFLNK|0o755;d={}
            with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assertIn('sample_system_tool_shape',d['stackSample']['error'])
    def test_aliased_resolved_sampler_rejected_before_spawn(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.sample_resolved=Path('/unexpected/sample');d={}
            with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assertIn('sample_system_tool_shape',d['stackSample']['error'])
    def test_guard_rejects_every_direct_sampler_filesystem_entrypoint(self):
        probes=(lambda:os.stat('/usr/bin/sample'),lambda:os.lstat('/usr/bin/sample'),
                lambda:os.open('/usr/bin/sample',os.O_RDONLY),lambda:os.readlink('/usr/bin/sample'),
                lambda:builtins.open('/usr/bin/sample','rb'),lambda:io.open('/usr/bin/sample','rb'),
                lambda:self.unmocked_sample_lstat(Path('/usr/bin/sample')),
                lambda:self.unmocked_sample_resolve(Path('/usr/bin/sample')))
        for probe in probes:
            with self.assertRaisesRegex(AssertionError,'real_sampler_filesystem_access_forbidden'):probe()
        self.assertEqual(len(self.real_tool_reads),len(probes))
        self.real_tool_reads.clear()  # Only these deliberate guard probes are expected.
    def test_synthetic_sampler_metadata_is_retained_without_host_reads(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler();d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'passed');self.assertEqual(self.real_tool_reads,[])
            self.assertEqual(d['stackSample']['tool'],{'path':'/usr/bin/sample','sha256':'digest',
                'bytes':4096,'mode':0o755,'uid':0,'device':7,'inode':11,'mtimeNS':123456789})

class BootstatusSampleTests(unittest.TestCase):
    setUp=RuntimeSampleTests.setUp
    sleep=AcquisitionTests.sleep
    poll=AcquisitionTests.poll
    identity=AcquisitionTests.identity
    acquire=AcquisitionTests.acquire
    sampler=RuntimeSampleTests.sampler
    def prepare(self,tmp):
        RuntimeSampleTests.prepare(self,tmp)
        self.item['record'].update(label='bootstatus',argv=['/launcher','bootstatus',DEVICE['createdUDID'],'-b'])
        for name in ('bootstatus-stdout.log','bootstatus-stderr.log'):(self.r.out/name).write_bytes(b'')
        self.boot={'process':SimpleNamespace(pid=41,poll=lambda:0),'record':{'label':'boot','pid':41,
            'argv':['/launcher','boot',DEVICE['createdUDID']],'exitCode':0,'terminalVerified':True,'signals':[],
            'executableSHA256':'digest','spawnEpoch':99.,'binding':{**self.value,'pid':41,'startTimeMicros':99_000_001}}}
        self.r.processes=[self.boot,self.item]
        self.r.receipt['lifecycleCommands']=[{'label':'boot','pid':41,'outcome':'normal_exit'}]
    def test_exact_owned_bootstatus_threshold_and_no_early_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.clock=149.9;self.terminal=150.1;d={'startedMonotonic':0}
            def sample(*a):self.assertGreaterEqual(self.clock,150);a[2]['stackSample']={'status':'passed'}
            self.r.sample_runtime=mock.Mock(side_effect=sample)
            self.assertEqual(self.r.sample_policy(self.item),(150,'bootstatus'))
            self.assertEqual(self.r.lifecycle_wait(self.item,180,d),0);self.r.sample_runtime.assert_called_once()
    def test_prior_normal_115_second_bootstatus_does_not_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.clock=114.9;self.terminal=115;self.r.sample_runtime=mock.Mock()
            self.assertEqual(self.r.lifecycle_wait(self.item,180,{'startedMonotonic':0}),0)
            self.r.sample_runtime.assert_not_called()
    def test_only_exact_owned_uuid_flags_and_label_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp)
            for tail in (['bootstatus',DEVICE['sourceUDID'],'-b'],['bootstatus','booted','-b'],['bootstatus',DEVICE['createdUDID']],
                         ['bootstatus',DEVICE['createdUDID'],'-b','extra'],['boot',DEVICE['createdUDID']]):
                self.item['record']['argv']=['/launcher',*tail];self.assertIsNone(self.r.sample_policy(self.item))
            self.item['record']['argv']=['/launcher','bootstatus',DEVICE['createdUDID'],'-b'];self.item['record']['label']='other'
            self.assertIsNone(self.r.sample_policy(self.item))
    def test_normal_boot_evidence_is_mandatory_and_exact(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);original=copy.deepcopy(self.boot['record'])
            for change in ({'exitCode':1},{'terminalVerified':False},{'signals':['SIGINT']},{'executableSHA256':'changed'},
                           {'pid':99},{'argv':['/launcher','boot',DEVICE['sourceUDID']]}):
                self.boot['record']={**original,**change};self.assertIsNone(self.r.sample_policy(self.item))
            self.boot['record']=original;self.r.receipt['lifecycleCommands'][0]['outcome']='failed'
            self.assertIsNone(self.r.sample_policy(self.item))
    def test_missing_duplicate_live_or_wrong_bound_boot_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp)
            for items in ([self.item],[self.boot,self.boot,self.item]):
                self.r.processes=items;self.assertIsNone(self.r.sample_policy(self.item))
            self.r.processes=[self.boot,self.item];self.boot['process'].poll=lambda:None
            self.assertIsNone(self.r.sample_policy(self.item));self.boot['process'].poll=lambda:0
            self.boot['record']['binding']['parentPID']=os.getpid()+1;self.assertIsNone(self.r.sample_policy(self.item))
    def test_unregistered_or_tool_mismatched_target_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.assertIsNone(self.r.sample_policy(dict(self.item)))
            self.item['digest']='changed';self.assertIsNone(self.r.sample_policy(self.item))
    def test_only_one_total_attempt_even_when_first_sample_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.clock=150;self.terminal=150.1
            self.r.sample_runtime=mock.Mock(side_effect=lambda *a:a[2].update(stackSample={'status':'failed','error':'diagnostic_failure'}))
            self.assertEqual(self.r.lifecycle_wait(self.item,180,{'startedMonotonic':0}),0)
            self.process.returncode=None;self.clock=160;self.terminal=160.1
            self.item['record'].update(label='booted-runtimes',argv=['/launcher','list','-j','runtimes'])
            self.assertEqual(self.r.lifecycle_wait(self.item,180,{'startedMonotonic':150}),0)
            self.r.sample_runtime.assert_called_once()
    def test_nonempty_bootstatus_output_prevents_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.clock=150;self.terminal=150.1;(self.r.out/'bootstatus-stdout.log').write_text('progress')
            self.r.sample_runtime=mock.Mock();self.assertEqual(self.r.lifecycle_wait(self.item,180,{'startedMonotonic':0}),0)
            self.r.sample_runtime.assert_not_called()
    def test_bootstatus_sampler_uses_fixed_report_path_and_retained_custody(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.clock=150;proc,spawn=self.sampler(150.2);d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn) as popen:self.r.sample_runtime(self.item,180,d)
            self.assertEqual(d['stackSample']['status'],'passed');self.assertEqual(d['stackSample']['triggerAfterSeconds'],150)
            self.assertEqual(popen.call_args.args[0][-1],str(self.r.out/'bootstatus-stack.txt'))
            self.assertTrue(d['stackSample']['terminalVerified']);self.assertEqual(self.r.sample_child['record']['label'],'bootstatus-stack-sample')
    def test_late_budget_cannot_spawn_or_extend_original_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.clock=170;d={}
            with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,180,d)
            popen.assert_not_called();self.assertIn('remaining_budget',d['stackSample']['error']);self.assertEqual(self.clock,170)
    def test_terminal_at_threshold_never_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.clock=150;self.terminal=150;self.r.sample_runtime=mock.Mock()
            self.assertEqual(self.r.lifecycle_wait(self.item,180,{'startedMonotonic':0}),0);self.r.sample_runtime.assert_not_called()
    def test_bootstatus_original_deadline_still_fatal_after_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.clock=150
            self.r.sample_runtime=mock.Mock(side_effect=lambda *a:a[2].update(stackSample={'status':'passed'}))
            with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.r.lifecycle_wait(self.item,180,{'startedMonotonic':0})
            self.assertAlmostEqual(self.clock,180);self.r.sample_runtime.assert_called_once()

class SamplePreSpawnExitTests(unittest.TestCase):
    setUp=RuntimeSampleTests.setUp
    sleep=AcquisitionTests.sleep
    poll=AcquisitionTests.poll
    identity=AcquisitionTests.identity
    acquire=AcquisitionTests.acquire
    prepare=RuntimeSampleTests.prepare
    sampler=RuntimeSampleTests.sampler
    def assert_not_needed(self,report):
        self.assertEqual(report['status'],'not_needed')
        self.assertEqual(report['reason'],'owned_normal_exit_before_sampler')
        self.assertEqual(report['targetExitCode'],0);self.assertFalse(report['samplerSpawned'])
    def test_normal_terminal_at_first_checkpoint_needs_no_sampler(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);self.process.returncode=0;d={}
            with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assert_not_needed(d['stackSample'])
            self.assertNotIn('tool',d['stackSample'])
    def test_exit_racing_first_identity_read_is_rechecked(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);d={}
            def race():self.process.returncode=0;return None
            self.read_value=race
            with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assert_not_needed(d['stackSample'])
    def test_normal_terminal_at_second_checkpoint_needs_no_sampler(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);d={}
            def hash_tool(path):
                if str(path)=='/usr/bin/sample':self.process.returncode=0
                return 'digest'
            with mock.patch.object(runner,'sha',side_effect=hash_tool),mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assert_not_needed(d['stackSample']);self.assertTrue(d['stackSample']['toolUnchanged'])
    def test_exit_racing_second_identity_read_is_rechecked(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);d={}
            def race():
                if self.reads==2:self.process.returncode=0;return None
                return self.value
            self.read_value=race
            with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assert_not_needed(d['stackSample'])
    def test_nonzero_terminal_at_either_checkpoint_remains_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp)
            for checkpoint in (1,2):
                for code in (1,-2):
                    self.process.returncode=None;d={};calls=0;original=self.r.sample_target_live
                    def check(target):
                        nonlocal calls
                        calls+=1
                        if calls==checkpoint:self.process.returncode=code
                        return original(target)
                    with mock.patch.object(self.r,'sample_target_live',side_effect=check),mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
                    popen.assert_not_called();self.assertEqual(d['stackSample']['status'],'failed');self.assertIn('sample_target_exit',d['stackSample']['error'])
    def test_unknown_or_changed_live_identity_at_either_checkpoint_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp)
            for checkpoint in (1,2):
                for observed in (None,{**self.value,'startTimeMicros':100_000_002}):
                    self.reads=0;self.process.returncode=None;d={}
                    self.read_value=lambda:self.value if self.reads<checkpoint else observed
                    with mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
                    popen.assert_not_called();self.assertEqual(d['stackSample']['status'],'failed');self.assertIn('sample_target_identity',d['stackSample']['error'])
    def test_tool_drift_after_normal_terminal_still_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);d={};calls=0;original=self.r.sample_target_live
            def check(target):
                nonlocal calls
                calls+=1
                if calls==2:self.process.returncode=0;self.sample_stat.st_ino+=1
                return original(target)
            with mock.patch.object(self.r,'sample_target_live',side_effect=check),mock.patch.object(runner.subprocess,'Popen') as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_not_called();self.assertEqual(d['stackSample']['status'],'failed');self.assertFalse(d['stackSample']['toolUnchanged'])
    def test_target_exit_after_sampler_spawn_is_not_reclassified(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler();d={};started=False
            def start(*args,**kwargs):
                nonlocal started
                started=True;return spawn(*args,**kwargs)
            self.process.poll=lambda:0 if started and proc.poll() is not None else None
            with mock.patch.object(runner.subprocess,'Popen',side_effect=start) as popen:self.r.sample_runtime(self.item,30,d)
            popen.assert_called_once();self.assertTrue(d['stackSample']['samplerSpawned'])
            self.assertEqual(d['stackSample']['status'],'failed');self.assertIn('after_identity',d['stackSample']['error'])
    def boot_lifecycle(self,tmp,late=False):
        BootstatusSampleTests.prepare(self,tmp);self.r.processes=[self.boot];self.r.started=0;self.r.seconds=300
        def spawn(*args):self.r.processes.append(self.item);self.clock=150;return self.item
        self.r.spawn_lifecycle=mock.Mock(side_effect=spawn);self.r.acquire_lifecycle=mock.Mock(return_value=self.item);self.r.cleanup=mock.Mock()
        def hash_tool(path):
            if str(path)=='/usr/bin/sample':
                self.process.returncode=0
                if late:self.clock=180
            return 'digest'
        return mock.patch.object(runner,'sha',side_effect=hash_tool)
    def test_full_lifecycle_accepts_only_unstarted_not_needed_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.boot_lifecycle(tmp),mock.patch.object(runner.subprocess,'Popen') as popen:
                self.assertEqual(self.r.lifecycle('bootstatus',['bootstatus',DEVICE['createdUDID'],'-b'],180),self.r.out/'bootstatus-stdout.log')
            popen.assert_not_called();d=self.r.receipt['lifecycleCommands'][-1]
            self.assertEqual(d['outcome'],'normal_exit');self.assert_not_needed(d['stackSample'])
            self.assertTrue(self.r.sample_attempted);self.r.spawn_lifecycle.assert_called_once()
    def test_normal_exit_race_does_not_allow_late_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.boot_lifecycle(tmp,late=True),mock.patch.object(runner.subprocess,'Popen') as popen:
                with self.assertRaisesRegex(ValueError,'lifecycle_deadline'):self.r.lifecycle('bootstatus',['bootstatus',DEVICE['createdUDID'],'-b'],180)
            popen.assert_not_called();self.assertEqual(self.r.receipt['lifecycleCommands'][-1]['deadlineMonotonic'],180)


class SamplerTimingTests(unittest.TestCase):
    setUp=RuntimeSampleTests.setUp
    sleep=RuntimeSampleTests.sleep
    poll=RuntimeSampleTests.poll
    identity=RuntimeSampleTests.identity
    acquire=RuntimeSampleTests.acquire
    prepare=RuntimeSampleTests.prepare
    sampler=RuntimeSampleTests.sampler
    def test_timing_preserves_success_command_and_original_three_second_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler();d={}
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn) as popen:self.r.sample_runtime(self.item,30,d)
            report=d['stackSample'];events={row['event']:row for row in report['timing']['events']}
            self.assertEqual(report['status'],'passed');self.assertEqual(report['durationSeconds'],1)
            self.assertEqual(report['samplerObservationSeconds'],3);popen.assert_called_once()
            self.assertAlmostEqual(events['sampler_deadline_set']['deadline']-events['sampler_deadline_set']['monotonic'],3)
            for event in ('sample_started','sampler_popen_before','sampler_popen_after','sampler_first_binding','sampler_terminal_observed','sampler_after_verification'):self.assertIn(event,events)
            self.assertIn('booted-runtimes-stack.txt',report['timing']['firstNonempty'])
            self.assertGreater(report['timing']['operations']['identity.read']['calls'],0)
            self.assertIsNone(self.r._sample_timing)
    def test_delayed_spawn_is_separate_from_three_second_observation(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(finish=100);d={}
            def slow(*args,**kw):self.clock+=3;return spawn(*args,**kw)
            with mock.patch.object(runner.subprocess,'Popen',side_effect=slow) as popen:self.r.sample_runtime(self.item,30,d)
            report=d['stackSample'];self.assertEqual(report['status'],'incomplete');self.assertEqual(report['reason'],'observation_timeout')
            self.assertTrue(report['terminalVerified']);popen.assert_called_once()
            events={row['event']:row for row in report['timing']['events']}
            self.assertEqual(events['sampler_popen_after']['monotonic']-events['sampler_popen_before']['monotonic'],3)
            self.assertIn('sampler_signal_before',events);self.assertIsNone(self.r._sample_timing)
    def test_measure_records_duration_and_preserves_return_and_exception(self):
        self.r._sample_timing={'events':[],'operations':{},'firstNonempty':{},'droppedEvents':0}
        def slow():self.clock+=.25;return 'original'
        self.assertEqual(self.r.sample_measure('budget',slow),'original')
        def failed():self.clock+=.5;raise ValueError('original_failure')
        with self.assertRaisesRegex(ValueError,'original_failure'):self.r.sample_measure('budget',failed)
        row=self.r._sample_timing['operations']['budget']
        self.assertEqual(row['calls'],2);self.assertEqual(row['seconds'],.75);self.assertEqual(row['maxSeconds'],.5)
    def test_no_sampling_no_telemetry_or_changed_budget_body(self):
        self.r._sample_timing=None;self.r.note('ignored')
        with mock.patch.object(self.r,'sample_budget_body',return_value='original') as original:
            self.assertEqual(runner.HelperRunner.budget(self.r),'original');original.assert_called_once_with()
        self.assertIsNone(self.r._sample_timing)
    def test_events_and_first_output_observations_are_bounded(self):
        self.r._sample_timing={'events':[],'operations':{},'firstNonempty':{},'droppedEvents':0}
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'owned.log';path.write_bytes(b'first')
            self.r.sample_observe_outputs((path,));first=self.r._sample_timing['firstNonempty'][path.name]
            self.clock+=1;path.write_bytes(b'second');self.r.sample_observe_outputs((path,))
            self.assertEqual(self.r._sample_timing['firstNonempty'][path.name],first)
        for _ in range(200):self.r.note('bounded')
        self.assertEqual(len(self.r._sample_timing['events']),128);self.assertEqual(self.r._sample_timing['droppedEvents'],73)
    def test_optional_output_observation_failure_retains_error_without_masking_outcome(self):
        self.r._sample_timing={'events':[],'operations':{},'firstNonempty':{},'droppedEvents':0}
        with mock.patch.object(Path,'lstat',side_effect=PermissionError('mock')):
            self.r.sample_observe_outputs((Path('owned.log'),))
        self.assertEqual(self.r._sample_timing['events'][0]['event'],'output_observation_error')
        self.assertEqual(self.r._sample_timing['firstNonempty'],{})
    def test_real_budget_and_save_wrappers_measure_unchanged_parent_operations(self):
        self.r._sample_timing={'events':[],'operations':{},'firstNonempty':{},'droppedEvents':0}
        with mock.patch.object(runner.Runner,'save',return_value='saved') as save:
            self.assertEqual(runner.HelperRunner.save(self.r),'saved');save.assert_called_once_with()
        with mock.patch.object(self.r,'sample_budget_body',return_value='checked') as budget:
            self.assertEqual(runner.HelperRunner.budget(self.r),'checked');budget.assert_called_once_with()
        self.assertEqual(self.r._sample_timing['operations']['receipt.save']['calls'],1)
        self.assertEqual(self.r._sample_timing['operations']['budget']['calls'],1)


class SamplerLifecycleTests(unittest.TestCase):
    setUp=RuntimeSampleTests.setUp
    sleep=RuntimeSampleTests.sleep
    poll=RuntimeSampleTests.poll
    identity=RuntimeSampleTests.identity
    acquire=RuntimeSampleTests.acquire
    prepare=RuntimeSampleTests.prepare
    sampler=RuntimeSampleTests.sampler
    def attempt(self,tmp,*,start=0,delay=0,finish=1000,deadline=30,exitcode=0):
        self.prepare(tmp);self.clock=start;proc,spawn=self.sampler(finish,exitcode);d={}
        self.r.identity.read=mock.Mock(wraps=self.r.identity.read)
        def slow(*args,**kwargs):self.clock+=delay;return spawn(*args,**kwargs)
        with mock.patch.object(runner.subprocess,'Popen',side_effect=slow) as popen:self.r.sample_runtime(self.item,deadline,d)
        popen.assert_called_once();return d['stackSample'],proc
    def test_replay_4480960_second_popen_gets_separate_observation_within_original_180(self):
        with tempfile.TemporaryDirectory() as tmp:
            start=150.93815625;delay=4.480960416
            report,proc=self.attempt(tmp,start=start,delay=delay,finish=start+delay+1,deadline=180)
            self.assertEqual(report['status'],'passed');proc.send_signal.assert_not_called()
            self.assertGreater(report['registeredMonotonic'],start+3)
            self.assertAlmostEqual(report['observationDeadlineMonotonic'],start+delay+3)
            self.assertEqual(report['originalDeadlineMonotonic'],180);self.assertLess(self.clock,180)
            self.assertNotIn('samplerWallSeconds',report)
    def test_reserve_exhaustion_before_binding_is_explicit_incomplete_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            report,proc=self.attempt(tmp,start=150,delay=20,deadline=180)
            self.assertEqual(report['status'],'incomplete');self.assertEqual(report['reason'],'post_startup_reserve_exhausted')
            self.assertEqual(report['samplerBindingStatus'],'not_observed_reserve_exhausted')
            self.assertIsNone(self.r.sample_child['binding']);self.assertNotIn('observationDeadlineMonotonic',report)
            self.assertFalse(any(call.args[0]==43 for call in self.r.identity.read.call_args_list))
            self.assertTrue(report['incompleteSafetyVerified']);self.assertTrue(report['sourceUnchanged'])
            self.assertTrue(report['terminalVerified']);self.assertEqual(proc.send_signal.call_count,1)
            self.r.sample_source_check.assert_called_once()
    def test_registration_save_cost_exhausts_reserve_without_observation(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(1000);d={};delayed=False
            def save():
                nonlocal delayed
                if getattr(self.r,'sample_child',None) is not None and not delayed:self.clock+=20;delayed=True
            self.r.save=save
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['reason'],'post_startup_reserve_exhausted')
            self.assertEqual(d['stackSample']['status'],'incomplete');self.assertNotIn('observationDeadlineMonotonic',d['stackSample'])
    def test_exact_three_second_terminal_is_not_late_report_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            report,proc=self.attempt(tmp,finish=3)
            self.assertEqual(report['status'],'incomplete');self.assertEqual(report['reason'],'observation_timeout')
            self.assertEqual(report['observationDeadlineMonotonic'],3);self.assertNotIn('reportSHA256',report)
    def test_original_absolute_deadline_expired_during_spawn_stays_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            report,proc=self.attempt(tmp,start=150,delay=30,deadline=180)
            self.assertEqual(report['status'],'failed');self.assertIn('lifecycle_deadline',report['error'])
            self.assertNotIn('incompleteSafetyVerified',report);self.assertTrue(report['terminalVerified'])
    def test_outer_phase_expiry_is_not_observation_timeout(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(1000);d={}
            self.r.budget=lambda:run.require(self.clock<2,'phase_wall_cap')
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'failed');self.assertIn('phase_wall_cap',d['stackSample']['error'])
    def test_target_normal_exit_during_popen_is_fatal_not_optional_race(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(1000);d={};started=False
            def start(*args,**kwargs):
                nonlocal started
                started=True;return spawn(*args,**kwargs)
            self.read_value=lambda:None if started else self.value
            def target_poll():
                if started and proc.poll() is None:raise AssertionError('target reaped while sampler alive')
                return 0 if started else None
            self.process.poll=target_poll
            with mock.patch.object(runner.subprocess,'Popen',side_effect=start):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'failed');self.assertIn('sample_target_identity',d['stackSample']['error'])
            self.assertTrue(d['stackSample']['terminalVerified'])
    def test_live_missing_sampler_identity_remains_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(1000);d={};self.r.identity.read=lambda pid:self.value if pid==42 else None
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'failed');self.assertIn('sample_child_identity_missing',d['stackSample']['error'])
            self.assertFalse(runner.sample_continuable(d['stackSample']))
    def test_unknown_child_exit_even_on_reserve_path_is_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            report,proc=self.attempt(tmp,start=150,delay=20,deadline=180,finish=160,exitcode=1)
            self.assertEqual(report['status'],'failed');self.assertIn('unexpected_exit',report['incompleteProofError'])
    def test_source_drift_after_timeout_is_fatal_and_first_error_retained(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(1000);d={}
            self.r.sample_source_check=mock.Mock(side_effect=ValueError('source_changed'))
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            report=d['stackSample'];self.assertEqual(report['status'],'failed')
            self.assertIn('sample_observation_deadline',report['error']);self.assertIn('source_changed',report['incompleteProofError'])
    def test_late_source_verification_cannot_create_optional_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(1000);d={}
            self.r.sample_source_check=lambda:setattr(self,'clock',30)
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            report=d['stackSample'];self.assertEqual(report['status'],'failed');self.assertIn('lifecycle_deadline',report['incompleteProofError'])
    def test_incomplete_tool_drift_stays_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(1000);d={};original=self.r.cleanup_sample
            def cleanup(item):original(item);self.sample_stat.st_ino+=1
            self.r.cleanup_sample=cleanup
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'failed');self.assertFalse(d['stackSample']['toolUnchanged'])
    def test_cleanup_failure_stays_fatal_and_target_unreaped(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(1000);d={};started=False
            def start(*a,**kw):
                nonlocal started
                started=True;return spawn(*a,**kw)
            def target_poll():
                if started and proc.poll() is None:raise AssertionError('target reaped')
                return None
            self.process.poll=target_poll;self.r.cleanup_sample=mock.Mock(side_effect=ValueError('cleanup_failed'))
            with mock.patch.object(runner.subprocess,'Popen',side_effect=start):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'failed');self.assertIn('cleanup_failed',d['stackSample']['cleanupError'])
            self.assertFalse(d['stackSample']['terminalVerified']);self.assertFalse(runner.sample_continuable(d['stackSample']))
            for stream in self.r.sample_child['streams']:stream.close()  # Fake failed cleanup owns no real child.
    def lifecycle(self,tmp,*,code=0,signals=(),late=False):
        self.prepare(tmp);self.r.processes=[];self.r.started=0;self.r.seconds=300;self.terminal=14
        proc,spawn=self.sampler(1000)
        def dispatch(*a):self.r.processes.append(self.item);return self.item
        self.r.spawn_lifecycle=mock.Mock(side_effect=dispatch);self.r.acquire_lifecycle=mock.Mock(return_value=self.item)
        original=self.r.cleanup
        def cleanup(item):
            if item is self.item:
                self.assertIsNotNone(proc.poll());item['record'].update(terminalVerified=True,signals=list(signals));self.process.returncode=code
                if late:self.clock=30
            else:original(item)
        self.r.cleanup=cleanup
        original_poll=self.process.poll
        def poll():
            value=original_poll()
            if value is not None:self.process.returncode=code;return code
            return None
        self.process.poll=poll
        return proc,spawn
    def test_optional_timeout_continues_only_exact_normal_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc,spawn=self.lifecycle(tmp)
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.lifecycle('booted-runtimes',['list','-j','runtimes'])
            d=self.r.receipt['lifecycleCommands'][-1];self.assertEqual(d['commandOutcome'],'normal_exit')
            self.assertEqual(d['stackSample']['status'],'incomplete');self.assertTrue(d['stackSample']['originalCommandVerified'])
            self.r.spawn_lifecycle.assert_called_once()
    def test_nonzero_or_signaled_original_command_cannot_continue(self):
        for code,signals in ((1,()),(0,('SIGINT',))):
            with self.subTest(code=code,signals=signals),tempfile.TemporaryDirectory() as tmp:
                self.clock=0;self.process.returncode=None;self.r.sample_attempted=False
                proc,spawn=self.lifecycle(tmp,code=code,signals=signals)
                with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn),self.assertRaisesRegex(ValueError,'normal_exit'):
                    self.r.lifecycle('booted-runtimes',['list','-j','runtimes'])
    def test_late_original_command_cleanup_cannot_continue(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc,spawn=self.lifecycle(tmp,late=True)
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn),self.assertRaisesRegex(ValueError,'lifecycle_deadline'):
                self.r.lifecycle('booted-runtimes',['list','-j','runtimes'])
    def test_closed_reasons_proofs_and_summary_do_not_manufacture_transport(self):
        with tempfile.TemporaryDirectory() as tmp:
            report,_=self.attempt(tmp)
            self.assertTrue(runner.sample_continuable(report))
            for key,value in (('reason','unknown'),('incompleteSafetyVerified',False),('sourceUnchanged',False),('terminalVerified',False),('toolUnchanged',False),('cleanupError','failure')):
                self.assertFalse(runner.sample_continuable({**report,key:value}))
            summary=run.sampler_summary({'lifecycleCommands':[{'stackSample':report}]})
            self.assertFalse(summary['samplerDiagnosticsComplete']);self.assertEqual(summary['samplerDiagnostics']['attempts'][0]['error'],report['error'])
            result={'helperTransportQualified':False,**summary};self.assertFalse(result['helperTransportQualified'])
            with self.assertRaises(ValueError):run.terminal_capture({'allOwnedProcessesTerminal':False})
            # The unchanged actual transport proof is still required independently.
            validate_receipt(receipt())
            invalid=receipt();invalid['readinessObserved']=False
            with self.assertRaises(ValueError):validate_receipt(invalid)
    def test_late_oversized_output_cannot_become_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(1000);d={};original=self.r.cleanup_sample
            def cleanup(item):
                original(item);(self.r.out/'booted-runtimes-stack.txt').write_bytes(b'x'*(2*1024**2+1))
            self.r.cleanup_sample=cleanup
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'failed');self.assertIn('sample_output_cap',d['stackSample']['incompleteProofError'])
    def test_reconstructed_custody_is_not_optional(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.prepare(tmp);proc,spawn=self.sampler(1000);d={};original=self.r.cleanup_sample
            def cleanup(item):
                original(item);self.r.sample_custody=(dict(item),item['process'],os.getpid())
            self.r.cleanup_sample=cleanup
            with mock.patch.object(runner.subprocess,'Popen',side_effect=spawn):self.r.sample_runtime(self.item,30,d)
            self.assertEqual(d['stackSample']['status'],'failed');self.assertIn('sample_incomplete_custody',d['stackSample']['incompleteProofError'])
    def test_top_level_keeps_first_fault_and_diagnostic_when_finalization_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'out'
            fake=SimpleNamespace(receipt={'lifecycleCommands':[{'stackSample':{'status':'incomplete','reason':'observation_timeout','error':'SampleObservationTimeout: sample_observation_deadline'}}]},
                command=mock.Mock(side_effect=ValueError('original_fault')),finish=mock.Mock(side_effect=ValueError('cleanup_fault')))
            with mock.patch.dict(os.environ,ENV,clear=True),mock.patch.object(run.platform,'machine',return_value='arm64'), \
                 mock.patch.object(run,'frozen',return_value={'files':{}}),mock.patch.object(run,'selected_snapshot',return_value={'files':{}}), \
                 mock.patch.object(run,'tool_inventory',return_value={'complete':True}),mock.patch.object(run,'tools',return_value={'toolProfile':run.HOSTED_TOOL_PROFILE}), \
                 mock.patch.object(run,'sha',return_value='digest'),mock.patch.object(run,'HelperRunner',return_value=fake):
                self.assertEqual(run.run(output,'/mock'),1)
            actual=json.loads((output/'receipt.json').read_text())
            self.assertEqual(actual['error'],'ValueError: original_fault');self.assertEqual(actual['finalizationError'],'ValueError: cleanup_fault')
            self.assertFalse(actual['helperTransportQualified']);self.assertFalse(actual['samplerDiagnosticsComplete'])
            self.assertEqual(actual['samplerDiagnostics']['attempts'][0]['error'],'SampleObservationTimeout: sample_observation_deadline')
    def test_terminal_summary_prominently_retains_incomplete_diagnostic(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'receipt.json';p.write_text(json.dumps({'stage':'validated','helperTransportQualified':True,
                'samplerDiagnosticsComplete':False,'samplerDiagnostics':{'attempts':[{'status':'incomplete','reason':'observation_timeout'}]}}))
            with mock.patch('builtins.print'):value=run.terminal_summary('run',p)
            self.assertTrue(value['helperTransportQualified']);self.assertFalse(value['samplerDiagnosticsComplete'])
            self.assertEqual(value['samplerStatuses'],['incomplete']);self.assertEqual(value['samplerReasons'],['observation_timeout'])

if __name__=='__main__':unittest.main()
