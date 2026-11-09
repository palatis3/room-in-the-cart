"""Offline admission, source, ownership, protocol, schema and artifact controls; no native execution."""
import ast
import copy
import hashlib
import inspect
import json
import os
from pathlib import Path
import plistlib
import struct
import tempfile
import time
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
from app_scroll_observation import capture, contract, consumer, export, producer, results, runner, native_environment, archive
from app_scroll_observation.contract import ROOT, CONDITION
from app_scroll_observation.protocol import Model, command, classify_ack, SUCCESS, FAILURE
from app_scroll_observation.support import SELECTOR, arm64_uuid, derive_plan as original_derive_plan, launcher_identity, sha
from app_scroll_observation.schema import COLUMNS, classify_uikit, parse, table_records as original_table_records, validate_envelopes, validate_receipt as original_validate_receipt
from plan_ios_performance_tests import validate_app_observation_request
DEVICE='A50C91FC-4966-47FF-A8CB-7640FBD513EB'  # Synthetic fixture only.
def derive_plan(original, products, nonce):return original_derive_plan(original,products,nonce,DEVICE)
def table_records(raw,toc,pid):return original_table_records(raw,toc,pid,DEVICE)
def validate_receipt(receipt):return original_validate_receipt(receipt,DEVICE)

def record(name,kind,when,ident=1,subsystem='control',category='CoverageControl',pid=101):
    return dict(pid=pid,name=name,type=kind,time=when,id=ident,subsystem=subsystem,category=category,scope='Process')


def ledger(n=2):
    return [dict(ordinal=i,signpostID=i,beginSequence=2*i,endSequence=2*i+1) for i in range(1,n+1)]


def controls(n=2):
    rows=[record('CaptureReady','Event',1)]
    for i in range(1,n+1): rows += [record('ObservedInvocation','Begin',i*100,i),record('ObservedInvocation','End',i*100+50,i)]
    rows.append(record('CaptureComplete','Event',(n+1)*100))
    return rows


def xml_fixture(rows):
    toc=ET.Element('trace-toc');run=ET.SubElement(toc,'run',number='1');info=ET.SubElement(run,'info');target=ET.SubElement(info,'target')
    ET.SubElement(target,'process',pid='101',type='attached');ET.SubElement(target,'device',uuid=DEVICE,platform='iOS Simulator')
    summary=ET.SubElement(info,'summary')
    for k,v in [('template-name','Logging'),('end-reason','Time limit reached'),('duration','60.5')]:ET.SubElement(summary,k).text=v
    ET.SubElement(ET.SubElement(run,'data'),'table',schema='os-signpost')
    root=ET.Element('trace-query-result');node=ET.SubElement(root,'node',xpath='//trace-toc[1]/run[1]/data[1]/table[1]')
    schema=ET.SubElement(node,'schema',name='os-signpost')
    for name,kind in COLUMNS:
        column=ET.SubElement(schema,'col');ET.SubElement(column,'mnemonic').text=name;ET.SubElement(column,'engineering-type').text=kind
    for i,value in enumerate(rows):
        row=ET.SubElement(node,'row')
        for name,kind in COLUMNS:
            if name=='process':
                if i:ET.SubElement(row,kind,ref='process1')
                else:
                    element=ET.SubElement(row,kind,id='process1');ET.SubElement(element,'pid').text=str(value['pid'])
            elif name=='thread':
                if i:ET.SubElement(row,kind,ref='thread1')
                else:
                    element=ET.SubElement(row,kind,id='thread1');ET.SubElement(element,'process',id='threadprocess1');ET.SubElement(element[0],'pid').text=str(value['pid'])
            elif name in ('format-string','backtrace','message','emit-location'):ET.SubElement(row,'sentinel')
            else:
                key={'event-type':'type','identifier':'id'}.get(name,name)
                ET.SubElement(row,kind).text=str(value[key])
    return ET.tostring(root),ET.tostring(toc)


def good_receipt():
    n=2;finish=command(4,2*n+2,n)
    phases=[]
    for stage in ('waitingForCollector','waitingForFinalization','finished'):
        phases.append(dict(stage=stage,nonce='a'*32,pid=101,runnerPID=102,simulatorUDID=DEVICE,subsystem='control',compiledForSimulator=True,
                           uid=501,parentPID=50,executable='/reviewed/App',
                           invocations=ledger(n),pendingCommand=finish,acknowledgedCommand=finish,lastSequence=2*n+2))
    processes=[]
    for label in ('native','tracer'):
        argv=['tool']
        if label=='native':argv+=['-only-testing:'+SELECTOR,'test-without-building']
        if label=='tracer':argv+=['--template','Logging','--device',DEVICE,'--attach','101','--time-limit','60s']
        processes.append(dict(label=label,argv=argv,exitCode=0,signals=[],terminalVerified=True,binding={'pid':200}))
    return dict(outcome='collected_pending_independent_validation',diagnosticOnly=True,releaseAcceptance=False,simulatorUDID=DEVICE,selector=SELECTOR,
                readinessObserved=True,notificationControlPassed=True,normalTracerExit=True,allOwnedProcessesTerminal=True,notificationCancelStatus=[0,0],
                sourceUnchanged=True,productsUnchanged=True,nonce='a'*32,subsystem='control',readinessEpoch=10,tracerExitEpoch=80,
                hostCommands=[dict(command='GO',epoch=11),dict(command='Q',epoch=81)],armedStatus=phases[0],completedStatus=phases[1],finalStatus=phases[2],
                bindings={'app':dict(binding={'pid':101,'uid':501,'parentPID':50,'executable':'/reviewed/App'},signals=[],terminalVerified=True,installedBundleUnchanged=True),'runner':dict(binding={'pid':102},signals=[],terminalVerified=True,installedBundleUnchanged=True)},processes=processes)


class ProtocolControls(unittest.TestCase):
    def armed(self):
        m=Model('nonce');m.receive(command(1,1));return m

    def recording(self):
        m=self.armed();m.host('GO','nonce',command(1,1),ready=True);return m

    def test_gate_does_not_ack_before_go(self):
        m=self.armed();self.assertEqual(classify_ack(command(1,1),m.ack),'pending')

    def test_timeout_is_failure_not_success(self):
        m=self.armed();m.timeout();self.assertEqual(classify_ack(command(1,1),m.ack),'failure')

    def test_abort_while_pending_fails(self):
        m=self.armed();m.host('ABORT','nonce',command(1,1));self.assertEqual(m.ack>>56,2)

    def test_changed_pending_command_fails(self):
        m=self.armed();m.host('GO','nonce',command(5,1),ready=True);self.assertEqual(m.stage,'failed')

    def test_wrong_nonce_fails(self):
        m=self.armed();m.host('GO','stale',command(1,1),ready=True);self.assertEqual(m.stage,'failed')

    def test_early_go_fails(self):
        m=self.armed();m.host('GO','nonce',command(1,1),ready=False);self.assertEqual(m.stage,'failed')

    def test_early_q_fails(self):
        m=self.recording();m.receive(command(2,2,1));m.receive(command(3,3,1));m.receive(command(4,4,1))
        m.host('Q','nonce',command(4,4,1),tracer_zero=False);self.assertEqual(m.stage,'failed')

    def test_finish_timeout_never_acks_success(self):
        m=self.recording();m.receive(command(2,2,1));m.receive(command(3,3,1));m.receive(command(4,4,1));m.timeout()
        self.assertEqual(classify_ack(command(4,4,1),m.ack),'failure')

    def test_stale_success_does_not_release_new_request(self):
        self.assertEqual(classify_ack(command(2,2,1),command(1,1)|SUCCESS),'pending')

    def test_repeated_notification_is_inert(self):
        m=self.recording();m.receive(command(2,2,1));m.receive(command(2,2,1));self.assertEqual(m.events.count(('begin',1)),1)

    def test_duplicate_sequence_different_command_fails(self):
        m=self.recording();m.receive(command(2,2,1));m.receive(command(3,2,1));self.assertEqual(m.stage,'failed')

    def test_out_of_order_end_fails(self):
        m=self.recording();m.receive(command(3,2,1));self.assertEqual(m.stage,'failed')

    def test_finish_with_open_envelope_fails(self):
        m=self.recording();m.receive(command(2,2,1));m.receive(command(4,3,1));self.assertEqual(m.stage,'failed')

    def test_six_invocations_not_five_sample_assumption(self):
        m=self.recording()
        for i in range(1,7):m.receive(command(2,2*i,i));m.receive(command(3,2*i+1,i))
        finish=command(4,14,6);m.receive(finish);m.host('Q','nonce',finish,tracer_zero=True)
        self.assertEqual(m.stage,'finished');self.assertEqual(len(m.completed),6)

    def test_invocation_bound(self):
        with self.assertRaises(ValueError):command(2,34,17)

    def test_failure_is_terminal(self):
        m=self.armed();m.timeout();m.receive(command(2,2,1));self.assertEqual(m.stage,'failed')
        with self.assertRaises(ValueError):m.success()


class FileControls(unittest.TestCase):
    def test_plan_changes_only_nonce_device_and_root_relocation(self):
        original={'RoomInTheCartUITests':dict(BlueprintName='RoomInTheCartUITests',IsUITestBundle=True,UITargetAppPath='__TESTROOT__/Release-iphonesimulator/RoomInTheCart.app',EnvironmentVariables={'OS_ACTIVITY_DT_MODE':'YES'},TestingEnvironmentVariables={'DYLD_INSERT_LIBRARIES':'keep-original'}),'__xctestrun_metadata__':dict(FormatVersion=1)}
        modified=plistlib.loads(derive_plan(plistlib.dumps(original),'/tmp/reviewed products','a'*32))
        original['RoomInTheCartUITests']['EnvironmentVariables'].update(RITC_CAPTURE_NONCE='a'*32,RITC_CAPTURE_DEVICE=DEVICE)
        original['RoomInTheCartUITests']['UITargetAppPath']=str(Path('/tmp/reviewed products').resolve())+'/Release-iphonesimulator/RoomInTheCart.app'
        self.assertEqual(modified,original)

    def test_unknown_plan_format_rejected(self):
        with self.assertRaises(ValueError):derive_plan(plistlib.dumps({'TestConfigurations':[]}),'/tmp','a'*32)

    def test_reviewed_launcher_still_requires_actual_exec_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);exe=root/'binary';exe.write_bytes(b'never executed')
            launcher=root/'launcher';launcher.write_text('#!/bin/bash\nexec "'+str(exe.resolve())+'" "${@}"\n')
            self.assertEqual(launcher_identity(launcher,sha(launcher),exe,sha(exe))['executable'],str(exe.resolve()))
            launcher.write_text('#!/bin/bash\nexec "/wrong" "${@}"\n')
            with self.assertRaises(ValueError):launcher_identity(launcher,sha(launcher),exe,sha(exe))

    def test_macho_uuid_read_without_native_tool(self):
        raw=struct.pack('<8I',0xfeedfacf,0x0100000c,0,2,1,24,0,0)+struct.pack('<II',0x1b,24)+bytes(range(16))
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'fixture';path.write_bytes(raw)
            self.assertEqual(arm64_uuid(path),'00010203-0405-0607-0809-0A0B0C0D0E0F')
            path.write_bytes(raw[:8]);
            with self.assertRaises(ValueError):arm64_uuid(path)

    def test_supervisor_refuses_early_go_and_q_without_writing(self):
        with tempfile.TemporaryDirectory() as d:
            obj=capture.Capture.__new__(capture.Capture);obj.control_directory=Path(d);obj.bound_valid=lambda role:True
            obj.receipt={'readinessObserved':False};obj.nonce='a'*32
            for action in ('GO','Q'):
                with self.assertRaises(ValueError):obj.host_command(action)
            self.assertEqual(list(Path(d).iterdir()),[])

    def test_polling_checks_identity_without_reading_executable(self):
        obj=capture.Capture.__new__(capture.Capture)
        binding={'pid':101,'startTimeMicros':55,'uid':501,'parentPID':42,'executable':'/no/such/file'}
        obj.bound={'app':{'binding':binding}}
        class FakeIdentity:
            def read(self,pid):return dict(binding)
        obj.identity=FakeIdentity()
        self.assertTrue(obj.bound_alive('app'))
        binding['startTimeMicros']=56
        obj.bound['app']['binding']=dict(binding,startTimeMicros=55)
        self.assertFalse(obj.bound_alive('app'))


class ExportControls(unittest.TestCase):
    def test_reference_resolving_xml_and_envelopes(self):
        raw,toc=xml_fixture(controls());rows,duration,ordinal=table_records(raw,toc,101)
        self.assertEqual(ordinal,1);self.assertEqual(len(validate_envelopes(rows,101,'control',ledger(),duration)),2)

    def test_reference_wrong_type_rejected(self):
        raw,toc=xml_fixture(controls());raw=raw.replace(b'process ref="process1"',b'process ref="thread1"',1)
        with self.assertRaisesRegex(ValueError,'reference_type'):table_records(raw,toc,101)

    def test_unresolved_reference_rejected(self):
        raw,toc=xml_fixture(controls());raw=raw.replace(b'ref="thread1"',b'ref="missing"',1)
        with self.assertRaises(ValueError):table_records(raw,toc,101)

    def test_wrong_device_rejected(self):
        raw,toc=xml_fixture(controls());toc=toc.replace(DEVICE.encode(),b'WRONG')
        with self.assertRaises(ValueError):table_records(raw,toc,101)

    def test_wrong_pid_rejected(self):
        raw,toc=xml_fixture(controls())
        with self.assertRaises(ValueError):table_records(raw,toc,999)

    def test_entity_declarations_rejected(self):
        with self.assertRaises(ValueError):parse(b'<!DOCTYPE x><x/>')

    def test_missing_end_rejected(self):
        rows=controls();del rows[2]
        with self.assertRaises(ValueError):validate_envelopes(rows,101,'control',ledger(),60_000_000_000)

    def test_mismatched_ledger_id_rejected(self):
        wrong=ledger();wrong[0]['signpostID']=55
        with self.assertRaises(ValueError):validate_envelopes(controls(),101,'control',wrong,60_000_000_000)

    def test_wrong_nonce_subsystem_rejected(self):
        with self.assertRaises(ValueError):validate_envelopes(controls(),101,'other',ledger(),60_000_000_000)

    def test_truncated_recording_rejected(self):
        with self.assertRaises(ValueError):validate_envelopes(controls(),101,'control',ledger(),299)

    def test_generic_gesture_never_substitutes_named_uikit_metric(self):
        rows=controls()+[record('GenericDrag','Begin',110,99,'com.apple.UIKit','ScrollView'),record('GenericDrag','End',140,99,'com.apple.UIKit','ScrollView')]
        report=classify_uikit(rows,101,validate_envelopes(rows,101,'control',ledger(),60_000_000_000))
        self.assertEqual(report['namedRowCount'],0);self.assertTrue(all(x['status']=='absent' for x in report['invocations']))

    def test_reset_pair_outside_envelope_not_counted(self):
        rows=controls()+[record('Scroll_DraggingAndDeceleration','Begin',20,99,'com.apple.UIKit','ScrollView'),record('Scroll_DraggingAndDeceleration','End',80,99,'com.apple.UIKit','ScrollView')]
        report=classify_uikit(rows,101,validate_envelopes(rows,101,'control',ledger(),60_000_000_000))
        self.assertEqual(report['completePairCount'],1);self.assertTrue(all(x['status']=='absent' for x in report['invocations']))

    def test_contained_and_overlapping_pairs_report_separately(self):
        rows=controls()+[record('Scroll_DraggingAndDeceleration','Begin',110,88,'com.apple.UIKit','ScrollView'),record('Scroll_DraggingAndDeceleration','End',140,88,'com.apple.UIKit','ScrollView'),record('Scroll_DraggingAndDeceleration','Begin',190,99,'com.apple.UIKit','ScrollView'),record('Scroll_DraggingAndDeceleration','End',240,99,'com.apple.UIKit','ScrollView')]
        report=classify_uikit(rows,101,validate_envelopes(rows,101,'control',ledger(),60_000_000_000))
        self.assertEqual(report['invocations'][0]['status'],'contained_exact_named_intervals');self.assertEqual(report['invocations'][1]['status'],'overlap_or_partial_only')

    def test_duplicate_uikit_begin_is_not_a_valid_pair(self):
        rows=controls()+[record('Scroll_DraggingAndDeceleration','Begin',110,88,'com.apple.UIKit','ScrollView'),record('Scroll_DraggingAndDeceleration','Begin',120,88,'com.apple.UIKit','ScrollView'),record('Scroll_DraggingAndDeceleration','End',140,88,'com.apple.UIKit','ScrollView')]
        report=classify_uikit(rows,101,validate_envelopes(rows,101,'control',ledger(),60_000_000_000))
        self.assertEqual(report['completePairCount'],0);self.assertEqual(report['invocations'][0]['status'],'overlap_or_partial_only')

    def test_normal_receipt_passes(self):self.assertEqual(validate_receipt(good_receipt())[0],101)

    def test_signal_assisted_receipt_rejected(self):
        value=good_receipt();value['processes'][1]['signals']=['SIGINT']
        with self.assertRaises(ValueError):validate_receipt(value)

    def test_q_before_natural_exit_rejected(self):
        value=good_receipt();value['hostCommands'][1]['epoch']=70
        with self.assertRaises(ValueError):validate_receipt(value)

    def test_missing_invocation_end_in_receipt_rejected(self):
        value=good_receipt();value['finalStatus']['invocations']=ledger(1)
        with self.assertRaises(ValueError):validate_receipt(value)


class CollectionBudgetControls(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.control=capture.Capture.__new__(capture.Capture)
        self.control.out=self.root;self.control.cleaning=False;self.control.native_started=None
        self.disk=mock.patch.object(capture.shutil,'disk_usage',return_value=type('Usage',(),{'free':16*1024**3})())
        self.disk.start();self.addCleanup(self.disk.stop)

    def put(self,name,size):
        path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('wb') as stream:stream.truncate(size)

    def test_observed_trace_clone_xml_native_log_fit(self):
        for trace in ('app.trace','inspection.trace'):
            self.put(trace+'/data.atrc',98_779_216);self.put(trace+'/issues',40_960)
        for name in ('signposts.xml','signposts-stdout.log'):self.put(name,8*1024**2)
        self.put('native-stdout.log',16*1024**2);self.put('ordinary.log',1024**2)
        self.control.budget()

    def test_each_trace_at_128_mib_passes_in_isolation(self):
        self.put('app.trace/data',128*1024**2);self.control.budget()

    def test_original_trace_over_limit_fails(self):
        self.put('app.trace/data',128*1024**2+1)
        with self.assertRaisesRegex(ValueError,'trace_cap:app.trace'):self.control.budget()

    def test_clone_over_limit_fails(self):
        self.put('inspection.trace/data',128*1024**2+1)
        with self.assertRaisesRegex(ValueError,'trace_cap:inspection.trace'):self.control.budget()

    def test_aggregate_counts_native_stdout(self):
        self.put('app.trace/data',120*1024**2);self.put('inspection.trace/data',121*1024**2);self.put('native-stdout.log',16*1024**2)
        with self.assertRaisesRegex(ValueError,'artifact_cap'):self.control.budget()

    def test_aggregate_exact_limit_passes(self):
        self.put('app.trace/data',128*1024**2);self.put('inspection.trace/data',128*1024**2);self.control.budget()

    def test_xml_limit_unchanged(self):
        self.put('signposts.xml',8*1024**2+1)
        with self.assertRaisesRegex(ValueError,'xml_cap'):self.control.budget()

    def test_native_stdout_limit_unchanged(self):
        self.put('native-stdout.log',16*1024**2+1)
        with self.assertRaisesRegex(ValueError,'native_log_cap'):self.control.budget()

    def test_ordinary_log_limit_unchanged(self):
        self.put('tracer-stdout.log',1024**2+1)
        with self.assertRaisesRegex(ValueError,'tool_log_cap'):self.control.budget()

    def test_xcresult_limit_independent_and_unchanged(self):
        self.put('Performance.xcresult/data',512*1024**2);self.control.budget()
        self.put('Performance.xcresult/data',512*1024**2+1)
        with self.assertRaisesRegex(ValueError,'xcresult_cap'):self.control.budget()

    def test_native_wall_limit_unchanged(self):
        self.control.native_started=time.monotonic()-241
        with self.assertRaisesRegex(ValueError,'native_wall_deadline'):self.control.budget()


class HostedAdmissionControls(unittest.TestCase):
    def test_only_manual_scroll_calibration_fresh_without_other_collectors(self):
        good=['workflow_dispatch','scroll','true','false','false','false','false','true']
        validate_app_observation_request(*good)
        for index,value in [(0,'pull_request'),(0,'workflow_call'),(1,'launch'),(1,'all'),(3,'true'),(4,'true'),(5,'true'),(6,'true'),(7,'false')]:
            bad=good.copy();bad[index]=value
            with self.subTest(index=index,value=value),self.assertRaises(ValueError):validate_app_observation_request(*bad)
    def test_default_does_not_change_original_admission(self):
        validate_app_observation_request('workflow_call','','false','true','false','false','false','false')
    def test_dynamic_device_plan_rejects_non_uuid(self):
        with self.assertRaises((ValueError,KeyError)):original_derive_plan(b'bad','/tmp','a'*32,'not-a-device')


class HostedSourceControls(unittest.TestCase):
    def test_frozen_contract(self):contract.frozen()
    def test_gated_only_projection_restores_original_sources(self):
        pins=contract.read(contract.HERE/'contract.json')['ungatedSourceSHA256']
        for name,digest in pins.items():
            lines=(ROOT/name).read_text().splitlines(True);kept=[];depth=0
            for line in lines:
                if line.strip()==CONDITION:
                    self.assertEqual(depth,0);depth=1;continue
                if depth:
                    if line.strip().startswith('#if '):depth+=1
                    if line.strip()=='#endif':depth-=1
                    continue
                kept.append(line)
            self.assertEqual(depth,0)
            # Appended helper's single separating newline is not part of the original file.
            projected=''.join(kept)
            self.assertEqual(hashlib.sha256(projected.rstrip('\n').encode()+b'\n').hexdigest(),digest,name)
    def test_exact_measurement_calls_and_source_contract(self):
        text=(ROOT/'ios/UITests/ReleasePerformanceUITests.swift').read_text()
        self.assertIn('            startMeasuring()\n            list.swipeUp(velocity: .fast)\n            stopMeasuring()',text)
        self.assertEqual(text.count('import notify\n'),1)
        self.assertIn('UUID(uuidString: device)?.uuidString == device',text)
        self.assertIn('env["SIMULATOR_UDID"]?.uppercased() == device',text)
        self.assertNotIn('device == "'+DEVICE+'"',text)
    def test_separate_existing_jobs_and_no_consumer_build(self):
        text=(ROOT/'.github/workflows/ios-performance.yml').read_text();consumer_text=text.split('  performance-tests:',1)[1]
        self.assertIn('needs: performance-build',consumer_text)
        self.assertIn("artifact-ids: ${{ needs.performance-build.outputs.artifact }}",consumer_text)
        self.assertNotIn('build-for-testing',consumer_text)
        self.assertIn('python3 scripts/capture_app_scroll_observation.py collect',consumer_text)
        self.assertEqual(text.count('python3 scripts/capture_app_scroll_observation.py collect'),1)
        for phase in ('export','results','qualify'):
            before=text.split('run: python3 scripts/capture_app_scroll_observation.py '+phase,1)[0]
            self.assertIn('if: always() && inputs.observe_app_scroll_signposts',before.rsplit('      - name:',1)[1])
    def test_helper_probe_is_complete_and_only_arm64_target(self):
        source=producer.helper_source()
        self.assertEqual(source.count('import notify'),2)
        self.assertIn('private final class RITCAppCaptureProbe',source)
        self.assertIn('private final class RITCCaptureRunner',source)
        self.assertIn("'arm64-apple-ios17.0-simulator'",inspect.getsource(producer.helper_typecheck))
    def test_result_output_names_are_casefold_distinct(self):
        names=['Performance.log','performance-checker.log','strict-checker.log','test-summary.json','metrics.json']
        self.assertEqual(len(set(n.casefold() for n in names)),len(names))
        self.assertIn("output/'performance-checker.log'",inspect.getsource(results.run))
    def test_original_checker_functions_unchanged(self):
        pins=contract.read(contract.HERE/'contract.json')['checkerSHA256']
        for name,digest in pins.items():self.assertEqual(sha(ROOT/name),digest)
    def test_native_argv_original_metric_options(self):
        source=inspect.getsource(capture.Capture.run)
        for text in ("'-default-test-execution-time-allowance','900'","'-maximum-test-execution-time-allowance','1200'",
                     "'-collect-test-diagnostics','on-failure'","'-only-testing:'+SELECTOR,'test-without-building'"):
            self.assertIn(text,source)
        self.assertNotIn('enablePerformanceTestsDiagnostics',source)


class NativeEnvironmentControls(unittest.TestCase):
    def test_native_inherits_benign_checker_activity_and_other_env_without_receipt_secrets(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve();tool=root/'xcodebuild';tool.write_bytes(b'fake never executed')
            instance=capture.Capture.__new__(capture.Capture);instance.out=root;instance.processes=[]
            instance.config={'tools':{'xcodebuild':{'path':str(tool),'sha256':sha(tool)}}}
            instance.receipt={'processes':[]};instance.save=lambda:None
            process=mock.Mock();process.pid=333;process.poll.return_value=None
            identity={'pid':333,'executable':str(tool),'uid':os.getuid(),'parentPID':os.getpid(),'startTimeMicros':10**30}
            instance.identity=mock.Mock();instance.identity.read.return_value=identity
            values={'HOME':str(root),'BENIGN_EXISTING':'retained','OS_ACTIVITY_MODE':'disable','PERFC_ENABLE_ANTI_PATTERN_CHECKER':'1','FAKE_SECRET':'must-not-be-recorded'}
            from performance_plan_provenance import settings
            instance.config.update(nativeInvocationSettings=settings(values),nativeLibraryEnvironmentSHA256=None)
            with mock.patch.dict(os.environ,values,clear=True),mock.patch.object(native_environment.subprocess,'Popen',return_value=process) as launch:
                item=instance.spawn('native',[str(tool),'test-without-building'],tool,sha(tool))
                self.assertEqual(launch.call_args.kwargs['env'],values)
                self.assertTrue(item['record']['childEnvironment']['otherVariablesInherited'])
                self.assertEqual(item['record']['childEnvironment']['allowlistedSettings']['OS_ACTIVITY_MODE'],'value:disable')
                self.assertNotIn('must-not-be-recorded',json.dumps(item['record']))
                for stream in item['streams']:stream.close()
    def test_non_native_environment_uses_qualified_supervisor(self):
        instance=capture.Capture.__new__(capture.Capture)
        with mock.patch.object(capture.Supervisor,'spawn',return_value='bounded') as spawn:
            self.assertEqual(instance.spawn('tracer',['xctrace'],Path('/xctrace'),'sha'),'bounded');spawn.assert_called_once()
    def test_xcodebuild_sdk_override_does_not_apply_to_tracer(self):
        instance=runner.Runner.__new__(runner.Runner);instance.tools={'xcodebuild':{'path':'/xcodebuild'}}
        with mock.patch.object(runner.Supervisor,'spawn',return_value='bounded') as spawn:
            self.assertEqual(instance.spawn('tracer',['/xctrace'],Path('/xctrace'),'sha'),'bounded');spawn.assert_called_once()


class PortableCustodyControls(unittest.TestCase):
    def test_snapshot_rejects_symlink_and_detects_mode_and_byte_changes(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);f=root/'file';f.write_bytes(b'one');before=contract.snapshot(root)
            f.chmod(0o600);after=contract.snapshot(root)
            self.assertNotEqual(before['modes'],after['modes'])
            f.write_bytes(b'two');self.assertNotEqual(before['files'],contract.snapshot(root)['files'])
            (root/'link').symlink_to(f)
            with self.assertRaises(ValueError):contract.snapshot(root)
    def test_portable_copy_verifies_bytes_and_modes(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);src=root/'source';src.mkdir();(src/'one').write_bytes(b'one');(src/'one').chmod(0o444)
            snap=contract.snapshot(src);contract.copy_snapshot(src,root/'copy',snap,lambda:None)
            self.assertEqual(contract.snapshot(root/'copy'),snap)
            with self.assertRaises(FileExistsError):contract.copy_snapshot(src,root/'copy',snap,lambda:None)
    def test_seal_verification_does_not_query_native_or_deleted_installation(self):
        source=inspect.getsource(consumer.verify_seal)
        self.assertNotIn('Identity(',source);self.assertNotIn('simctl',source)
        self.assertIn("output/'products'/item['productRelativePath']",source)
    def test_failed_collection_blocks_automatic_cleanup(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'native-attempt.json').write_text('{}')
            with mock.patch.object(consumer,'verify_seal',return_value={'collectionQualified':False}),self.assertRaises(ValueError):consumer.cleanup_gate(root)
    def test_export_and_results_are_independent_no_test_rerun(self):
        self.assertIn('require_collection=False',inspect.signature(consumer.verify_seal).__str__())
        for module in (export,results):
            source=inspect.getsource(module)
            self.assertNotIn("'test-without-building'",source)
            self.assertNotIn("'simctl'",source)
        self.assertIn('verify_seal(evidence)',inspect.getsource(results.run))
    def test_xml_cap_is_the_successful_recovery_allowance(self):
        with self.assertRaisesRegex(ValueError,'xml_size'):parse(b' '*(64*1024**2+1))
        self.assertIn('Runner(output,tools,90,64*1024**2)',inspect.getsource(export.run))
    def test_collection_never_exports(self):
        self.assertNotIn('self.export()',inspect.getsource(capture.Capture.run))
        self.assertIn("'collected_pending_independent_validation'",inspect.getsource(capture.Capture.run))



class IndependenceControls(unittest.TestCase):
    def test_source_snapshot_includes_untracked_frozen_modules(self):
        fake=mock.Mock(stdout=b'ios/App/RoomInTheCartApp.swift\0')
        with mock.patch.object(contract.subprocess,'run',return_value=fake):
            value=contract.source_snapshot()
        self.assertIn('scripts/app_scroll_observation/native_environment.py',value['files'])
        self.assertIn('scripts/app_scroll_observation/contract.json',value['files'])
    def test_failed_seal_retains_result_inspection_and_cannot_qualify(self, attachment_failure=False):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as d:
            evidence=Path(d).resolve();capture_dir=evidence/'observation-capture';capture_dir.mkdir()
            (capture_dir/'receipt.json').write_text(json.dumps({'simulatorUDID':DEVICE}))
            original=capture_dir/'Performance.xcresult';original.mkdir();(original/'Info.plist').write_bytes(b'synthetic')
            (capture_dir/'selected.txt').write_text(SELECTOR+'\n');(capture_dir/'native-stdout.log').write_text('synthetic')
            for name in ('test-simulator-ownership.json','native-attempt.json'):(evidence/name).write_text('{}')
            store=evidence/'ledger-snapshot.sqlite';store.write_bytes(b'synthetic; checker mocked')
            (evidence/'store-preservation.json').write_text(json.dumps({'status':'preserved','cleanupAllowed':True,'snapshotSHA256':sha(store),
                'ownershipSHA256':sha(evidence/'test-simulator-ownership.json'),'attemptSHA256':sha(evidence/'native-attempt.json'),'createdUDID':DEVICE}))
            output=evidence/'inspection';called=[]
            class FakeRunner:
                def __init__(self,out,tools,seconds):self.out=out;out.mkdir();self.processes=[]
                def budget(self):pass
                def finish(self,error=None):(self.out/'receipt.json').write_text(json.dumps({'error':error}))
                def command(self,label,key,args):
                    path=self.out/(label+'-stdout.log')
                    if label=='attachments':
                        if attachment_failure:raise RuntimeError('attachment_export_failed')
                        (self.out/'attachments').mkdir();(self.out/'attachments/manifest.json').write_text('[]');path.write_text('')
                    else:
                        value={'summary':{'devicesAndConfigurations':[{'device':{'deviceId':DEVICE}}]},'tests':{'testNodes':[]},'metrics':[]}[label]
                        path.write_text(json.dumps(value))
                    return path
            def strict_main():
                called.append('strict');(output/'test-runtime-warnings.json').write_text('{"status":"passed"}')
            def performance_main():
                called.append('performance');(output/'evidence-validation.json').write_text('{"measurements":{"status":"passed"},"persistedPickup":{"status":"passed"}}')
            strict=SimpleNamespace(main=strict_main,test_cases=lambda _:[])
            performance=SimpleNamespace(main=performance_main)
            with mock.patch.object(results,'Runner',FakeRunner),mock.patch.object(results,'verify_seal',side_effect=ValueError('seal_failed')),\
                    mock.patch.object(results,'module',side_effect=[strict,performance]):
                code=results.run(evidence,output,{'xcode':'Xcode 27.1\nBuild version 27A9275'})
            report=json.loads((output/'inspection.json').read_text())
            self.assertEqual(called,['strict','performance']);self.assertEqual(code,1)
            self.assertEqual(report['custody']['status'],'failed');self.assertFalse(report['resultChecksQualified'])
            self.assertEqual(report['inspectionOnlyDueToCustodyFailure'],'seal_failed')
    def test_attachment_export_failure_does_not_suppress_original_checkers(self):
        self.test_failed_seal_retains_result_inspection_and_cannot_qualify(attachment_failure=True)


class PortableArchiveControls(unittest.TestCase):
    def test_roundtrip_file_bytes_and_executable_modes_excludes_disposable_copies(self):
        import tarfile
        with tempfile.TemporaryDirectory() as d:
            base=Path(d).resolve();evidence=base/'evidence';evidence.mkdir()
            executable=evidence/'observation-custody/products/App';executable.parent.mkdir(parents=True);executable.write_bytes(b'owned executable');executable.chmod(0o751)
            disposable=evidence/'observation-results/Inspection.xcresult/data';disposable.parent.mkdir(parents=True);disposable.write_bytes(b'copy')
            with mock.patch.dict(os.environ,{},clear=True),mock.patch.object(archive.shutil,'disk_usage',return_value=type('Usage',(),{'free':16*1024**3})()):
                self.assertEqual(archive.run(evidence,base/'portable'),0)
            proof=contract.read(base/'portable/report/receipt.json')
            self.assertEqual(proof['artifactPath'],str(base/'portable/complete'))
            self.assertNotIn(str(disposable.relative_to(evidence)),proof['members'])
            archive.require_preserved(base/'portable')
            restored=base/'restored';restored.mkdir()
            with tarfile.open(base/'portable/complete/evidence.tar') as packed:
                for member in packed:
                    target=restored/member.name;target.parent.mkdir(parents=True,exist_ok=True)
                    target.write_bytes(packed.extractfile(member).read());target.chmod(member.mode)
            self.assertEqual(archive.inventory(restored,1024,time.monotonic()+5),proof['members'])
            changed=copy.deepcopy(proof['members']);changed[str(executable.relative_to(evidence))]['mode']=0o644
            with self.assertRaisesRegex(ValueError,'archive_mode_or_size'):archive.verify_tar(base/'portable/complete/evidence.tar',changed,time.monotonic()+5)
    def test_archive_reserves_payload_and_overhead_before_writing(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d).resolve();evidence=base/'evidence';evidence.mkdir();(evidence/'input').write_bytes(b'payload')
            free=8*1024**3+7  # Enough for bytes alone, not the tar headers/padding.
            with mock.patch.dict(os.environ,{},clear=True),mock.patch.object(archive.shutil,'disk_usage',return_value=type('Usage',(),{'free':free})()):
                self.assertEqual(archive.run(evidence,base/'portable'),1)
            self.assertFalse((base/'portable/evidence.tar.partial').exists())
            self.assertIn('archive_headroom',contract.read(base/'portable/report/receipt.json')['error'])
    def test_archive_rechecks_reserve_after_writing_without_per_chunk_queries(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d).resolve();evidence=base/'evidence';evidence.mkdir();(evidence/'input').write_bytes(b'payload')
            values=[type('Usage',(),{'free':16*1024**3})(),type('Usage',(),{'free':16*1024**3})(),type('Usage',(),{'free':8*1024**3-1})()]
            with mock.patch.dict(os.environ,{},clear=True),mock.patch.object(archive.shutil,'disk_usage',side_effect=values) as disk:
                self.assertEqual(archive.run(evidence,base/'portable'),1);self.assertEqual(disk.call_count,3)
            self.assertIn('archive_post_write_reserve',contract.read(base/'portable/report/receipt.json')['error'])
    def test_archive_cannot_be_inside_its_input_tree(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve()
            with self.assertRaisesRegex(ValueError,'archive_outside_input_tree'):archive.run(root,root/'archive')
    def test_symlink_blocks_archive_and_raw_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d).resolve();evidence=base/'evidence';evidence.mkdir();(evidence/'link').symlink_to('/etc/passwd')
            with mock.patch.dict(os.environ,{},clear=True):self.assertEqual(archive.run(evidence,base/'portable'),1)
            proof=contract.read(base/'portable/report/receipt.json')
            self.assertFalse(proof['archivePreserved']);self.assertIn('rawFallbackError',proof)
            self.assertEqual(proof['artifactPath'],str(base/'portable/report'))
    def test_cap_failure_retains_bounded_unqualified_raw_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            base=Path(d).resolve();evidence=base/'evidence';evidence.mkdir();(evidence/'input').write_bytes(b'a'*20)
            with mock.patch.dict(os.environ,{},clear=True),mock.patch.object(archive,'ARCHIVE_BYTES',8):
                self.assertEqual(archive.run(evidence,base/'portable'),1)
            proof=contract.read(base/'portable/report/receipt.json')
            self.assertFalse(proof['archivePreserved']);self.assertFalse(proof['rawFallback']['qualified'])
            self.assertEqual(proof['artifactPath'],str(evidence));self.assertEqual((evidence/'input').read_bytes(),b'a'*20)
            with self.assertRaises(ValueError):archive.require_preserved(base/'portable')
    def test_workflow_upload_selects_archive_or_bounded_fallback_and_keeps_ordinary_default(self):
        text=(ROOT/'.github/workflows/ios-performance.yml').read_text()
        self.assertIn("steps.observation_archive.outputs.artifact_path || '.build/app-observation-portable/report/'",text)
        self.assertIn("|| '.build/performance/'",text)
        self.assertLess(text.index('run: python3 scripts/capture_app_scroll_observation.py archive'),text.index('      - name: Clean up the job-owned performance simulator'))



class LoggingTemplatePreflightControls(unittest.TestCase):
    def test_exact_public_logging_entry_passes(self):
        self.assertEqual(producer.verify_logging_template(b'== Built-in Templates ==\nActivity Monitor\nLogging\nTime Profiler\n'),
                         {'requiredTemplate':'Logging','matchingEntries':1,'status':'passed'})
    def test_missing_near_match_or_duplicate_logging_entry_fails(self):
        for raw in (b'Time Profiler\n',b'Logging Extended\n',b'Custom Logging\n',b'Logging\nLogging\n'):
            with self.subTest(raw=raw),self.assertRaisesRegex(ValueError,'exact_Logging_template'):producer.verify_logging_template(raw)
    def test_template_inventory_precedes_helper_and_records_hashes(self):
        source=inspect.getsource(producer.prepare)
        self.assertLess(source.index("runner.command('templates'"),source.index('helper_typecheck(runner)'))
        self.assertIn("['list','templates'],10,terminal_query=True",source)
        self.assertIn("'stdoutSHA256':sha(templates)",source)
        self.assertIn("'stderrSHA256':sha(runner.out/'templates-stderr.log')",source)
    def test_only_exact_template_inventory_may_exit_before_binding(self):
        with tempfile.TemporaryDirectory() as d:
            instance=runner.Runner.__new__(runner.Runner);instance.out=Path(d);instance.budget=lambda:None
            instance.tools={'xctrace':{'path':'/reviewed/xctrace','sha256':'bound'}}
            instance.wait=lambda item,seconds:0;instance.cleanup=lambda item:None
            def early(label,argv,expected,digest):
                process=mock.Mock();process.poll.return_value=0
                instance.processes.append({'process':process,'record':{'label':label,'signals':[]}})
                raise RuntimeError('early_exit')
            instance.spawn=early
            for tail,accepted in [(['list','templates'],True),(['list','templates','--extra'],False),(['record'],False),(['export'],False)]:
                instance.processes=[]
                if accepted:
                    instance.command('templates','xctrace',tail,10,terminal_query=True)
                    self.assertTrue(instance.processes[-1]['record']['terminalQueryBeforeBinding'])
                else:
                    with self.assertRaises(RuntimeError):instance.command('templates','xctrace',tail,10,terminal_query=True)


if __name__=='__main__':unittest.main()

