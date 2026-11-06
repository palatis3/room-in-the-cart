#!/usr/bin/env python3
"""Offline synthetic checks only: native commands/processes are always mocked."""
import copy
import importlib.util
import json
import io
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import tarfile
import unittest
from unittest.mock import patch

SPEC=importlib.util.spec_from_file_location('keyboard_harness',Path(__file__).with_name('harness.py'))
h=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(h)
ID='11111111-1111-4111-8111-111111111111'
RUNTIME='com.apple.CoreSimulator.SimRuntime.iOS-26-2'


class StopClock:
    def __init__(self):self.now=0.0
    def __call__(self):return self.now


class StopProcess:
    def __init__(self,clock,actions,pid=123):
        self.clock=clock;self.actions=list(actions);self.pid=pid;self.returncode=None;self.waits=[]
    def poll(self):return self.returncode
    def wait(self,timeout):
        self.waits.append(timeout);action=self.actions.pop(0)
        if callable(action):return action(timeout)
        if action=='timeout':
            self.clock.now+=timeout;raise subprocess.TimeoutExpired('owned synthetic child',timeout)
        self.clock.now+=min(0.1,timeout);self.returncode=action;return action


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name);self.state=self.root/'state';self.state.mkdir()
        self.patcher=patch.object(h,'STATE',self.state);self.patcher.start();self.addCleanup(self.patcher.stop)
        h.save(self.state/'owned-device.json',{'name':'owned random name','runtime':RUNTIME,'udid':ID})
        (self.state/'selectors.txt').write_bytes((h.HERE/'selectors.txt').read_bytes())
        products=self.root/'OriginalProducts';products.mkdir()
        product_patch=patch.object(h,'PRODUCTS',products);product_patch.start();self.addCleanup(product_patch.stop)
        (products/'RoomInTheCart_iphonesimulator.xctestrun').write_bytes(plistlib.dumps({'RoomInTheCartUITests':self.target()}))

    def test_source_guard_binds_dispatch_commit_and_exact_base_plus_allowlist(self):
        here=self.root/'diagnostics/keyboard-dismiss/hosted';here.mkdir(parents=True)
        index='diagnostics/keyboard-dismiss/hosted/overlay-index.json';commit='a'*40
        original={'original.swift':b'original','changed.swift':b'before'}
        allowed={'changed.swift':h.digest(b'after'),'new-helper.py':h.digest(b'helper')}
        h.save(here/'overlay-index.json',{'base':h.BASE,'files':allowed})
        current={'original.swift':h.digest(b'original'),**allowed,index:h.digest((here/'overlay-index.json').read_bytes())}
        def git(*args):
            if args==('rev-parse','HEAD'):return commit.encode()
            if args[0]=='ls-tree':return ('\0'.join(original)+'\0').encode()
            if args[0]=='show':return original[args[1].split(':',1)[1]]
            raise AssertionError('Unexpected Git read')
        env={'EXPECTED_SHA':commit,'GITHUB_SHA':commit,'GITHUB_EVENT_NAME':'workflow_dispatch','KEYBOARD_ROLE':'run'}
        with patch.object(h,'HERE',here),patch.object(h.Path,'cwd',return_value=self.root),patch.object(h,'git_bytes',side_effect=git),patch.object(h,'source_snapshot',return_value=current),patch.dict(h.os.environ,env):
            h.verify_source()
            with patch.dict(h.os.environ,{'EXPECTED_SHA':'b'*40}):
                with self.assertRaises(ValueError):h.verify_source()
            with patch.dict(h.os.environ,{'GITHUB_EVENT_NAME':'pull_request'}):
                with self.assertRaises(ValueError):h.verify_source()
            bad=dict(current);bad['original.swift']=h.digest(b'mutated')
            with patch.object(h,'source_snapshot',return_value=bad):
                with self.assertRaises(ValueError):h.verify_source()
            bad=dict(current);bad['unreviewed.swift']=h.digest(b'extra')
            with patch.object(h,'source_snapshot',return_value=bad):
                with self.assertRaises(ValueError):h.verify_source()
            bad=dict(current);del bad['changed.swift']
            with patch.object(h,'source_snapshot',return_value=bad):
                with self.assertRaises(ValueError):h.verify_source()

    def target(self):
        return {'IsUITestBundle':True,'BlueprintName':'RoomInTheCartUITests',
                'EnvironmentVariables':{'ORIGINAL':'preserved'},'TestHostPath':'__TESTROOT__/Runner.app/Runner',
                'UITargetAppPath':'__TESTROOT__/RoomInTheCart.app','UITargetAppEnvironmentVariables':{'ORIGINAL_APP':'same'}}

    def original(self,content):
        p=self.root/'Products/original.xctestrun';p.parent.mkdir(exist_ok=True)
        p.write_bytes(plistlib.dumps(content));return p

    def test_original_xctestrun_is_not_rewritten_and_diagnostic_flags_forbidden(self):
        original=h.original_xctestrun();before=original.read_bytes()
        self.assertEqual(h.original_xctestrun(),original)
        self.assertEqual(original.read_bytes(),before)
        value=plistlib.loads(before)
        value['RoomInTheCartUITests']['EnvironmentVariables']['RITC_MEASUREMENT_CONSENT_DIAGNOSTIC']='1'
        original.write_bytes(plistlib.dumps(value))
        with self.assertRaises(ValueError):h.original_xctestrun()
        original.write_bytes(before)
        (h.PRODUCTS/'RoomInTheCart_iphonesimulator-other.xctestrun').write_bytes(before)
        with self.assertRaises(ValueError):h.original_xctestrun()

    def test_only_ordinary_debug_and_instrumentation_conditions_allowed(self):
        settings=[{'target':'RoomInTheCart','buildSettings':{'CONFIGURATION':'Debug','PLATFORM_NAME':'iphonesimulator',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG KEYBOARD_DISMISS_DIAGNOSTIC'}}]
        h.validate_conditions(settings)
        for conditions in ('DEBUG','DEBUG CONTRIBUTOR_CAPTURE_UI_FIXTURE KEYBOARD_DISMISS_DIAGNOSTIC',
                           'RELEASE KEYBOARD_DISMISS_DIAGNOSTIC','DEBUG DEBUG KEYBOARD_DISMISS_DIAGNOSTIC'):
            invalid=copy.deepcopy(settings);invalid[0]['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']=conditions
            with self.assertRaises(ValueError):h.validate_conditions(invalid)
        with patch.object(h,'run') as run:
            with patch.object(h,'read_log',return_value=json.dumps(settings)):h.build()
        commands=[call.args[1] for call in run.call_args_list]
        self.assertEqual(len(commands),3)
        self.assertTrue(all('contributor' not in str(command) for command in commands))
        self.assertEqual(commands[1][-1],'build-for-testing')

    def test_manifest_detects_content_modes_and_symlink_target_changes(self):
        folder=self.root/'Products';folder.mkdir();file=folder/'runner';file.write_bytes(b'binary');file.chmod(0o755)
        link=folder/'alias';link.symlink_to('runner');before=h.inventory(folder)
        self.assertEqual(before['alias']['target'],'runner')
        file.write_bytes(b'changed');self.assertNotEqual(h.inventory(folder),before)
        file.write_bytes(b'binary');file.chmod(0o644);self.assertNotEqual(h.inventory(folder),before)

    def test_manifest_rejects_escape_and_empty_input(self):
        folder=self.root/'Products';folder.mkdir()
        with self.assertRaises(ValueError):h.inventory(folder)
        (folder/'escape').symlink_to(self.root/'outside')
        with self.assertRaises(ValueError):h.inventory(folder)

    def test_archive_roundtrip_preserves_product_bytes_modes_and_internal_links(self):
        source=self.root/'archive-source';products=source/'Products';products.mkdir(parents=True)
        (products/'runner').write_bytes(b'compiled executable');(products/'runner').chmod(0o755)
        (products/'alias').symlink_to('runner');transfer=source/'keyboard-transfer';transfer.mkdir();(transfer/'proof').write_text('hashes')
        archive=self.root/'products.tar.gz'
        with tarfile.open(archive,'w:gz') as tar:
            tar.add(products,arcname='Products');tar.add(transfer,arcname='keyboard-transfer')
        destination=self.root/'restore';h.extract_transport(archive,destination)
        self.assertEqual(h.inventory(products),h.inventory(destination/'Products'))
        self.assertEqual((destination/'keyboard-transfer/proof').read_text(),'hashes')
        with self.assertRaises(ValueError):h.extract_transport(archive,destination)

    def test_archive_rejects_traversal_hardlinks_and_link_parent_before_writing(self):
        for variant in ['traversal','hardlink','symlink_escape','link_parent','duplicate']:
            with self.subTest(variant=variant):
                archive=self.root/(variant+'.tar')
                with tarfile.open(archive,'w') as tar:
                    for name in ['Products','keyboard-transfer']:
                        item=tarfile.TarInfo(name);item.type=tarfile.DIRTYPE;item.mode=0o755;tar.addfile(item)
                    item=tarfile.TarInfo('Products/entry');item.mode=0o644
                    if variant=='traversal':item.name='../escape'
                    if variant=='hardlink':item.type=tarfile.LNKTYPE;item.linkname='Products/file'
                    if variant in ('symlink_escape','link_parent'):
                        item.type=tarfile.SYMTYPE;item.linkname='../../escape' if variant=='symlink_escape' else '.'
                    tar.addfile(item,io.BytesIO(b''))
                    if variant=='link_parent':tar.addfile(tarfile.TarInfo('Products/entry/file'),io.BytesIO(b''))
                    if variant=='duplicate':tar.addfile(item,io.BytesIO(b''))
                destination=self.root/('output-'+variant)
                with self.assertRaises(ValueError):h.extract_transport(archive,destination)
                self.assertFalse(destination.exists())

    def runtime_data(self):
        return {'runtimes':[{'isAvailable':True,'version':'26.2','buildversion':'23C54','identifier':RUNTIME}],
                'devicetypes':[{'identifier':'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}]}

    def test_prepare_reuses_evidence_based_single_inventory_and_control_bounds(self):
        calls=[]
        def fake(name,argv,**kwargs):
            calls.append((name,kwargs.get('timeout')))
            values={'toolchain':'Xcode 26.3\nBuild version 17C529','architecture':'arm64','host':'macOS',
                    'simulator-inventory':json.dumps(self.runtime_data()),'create-device':ID}
            (self.state/(name+'.log')).write_text(values[name]);return 0
        with patch.object(h,'verify_source'),patch.object(h,'run',side_effect=fake),patch.dict(h.os.environ,{'KEYBOARD_ROLE':'run'}):h.prepare()
        self.assertEqual([x for x in calls if x[0]=='simulator-inventory'],[('simulator-inventory',180)])
        self.assertEqual([x for x in calls if x[0]=='create-device'],[('create-device',90)])
        self.assertEqual(len(calls),5)

    def test_boot_keeps_outer_deadline_and_one_shot_90_second_readbacks(self):
        calls=[]
        def fake(name,argv,**kwargs):
            calls.append((name,kwargs.get('timeout')))
            value='23C54' if name=='booted-build' else json.dumps({'devices':{RUNTIME:[{'name':'owned random name','udid':ID,'state':'Booted','deviceTypeIdentifier':'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}]}})
            (self.state/(name+'.log')).write_text(value);return 0
        with patch.object(h,'run',side_effect=fake):h.boot()
        self.assertEqual(calls,[('boot',None),('booted-build',90),('booted-device',90)])

    def test_runtime_requires_exact_available_build_and_device(self):
        self.assertEqual(h.select_runtime(self.runtime_data()),RUNTIME)
        for key,value in [('buildversion','23C55'),('version','26.3'),('isAvailable',False)]:
            data=self.runtime_data();data['runtimes'][0][key]=value
            with self.assertRaises(ValueError):h.select_runtime(data)
        data=self.runtime_data();data['runtimes']*=2
        with self.assertRaises(ValueError):h.select_runtime(data)

    def test_exact_six_native_selectors_limits_and_no_retry_option(self):
        command=h.test_command();selectors=[x.removeprefix('-only-testing:') for x in command if x.startswith('-only-testing:')]
        self.assertEqual(selectors,(h.HERE/'selectors.txt').read_text().splitlines());self.assertEqual(len(selectors),6)
        self.assertEqual(command[command.index('-default-test-execution-time-allowance')+1],'720')
        self.assertEqual(command[command.index('-maximum-test-execution-time-allowance')+1],'900')
        self.assertEqual(command[command.index('-collect-test-diagnostics')+1],'never')
        self.assertEqual(command[command.index('-xctestrun')+1],str(h.original_xctestrun()))
        self.assertFalse(any('retry' in value or 'RecordsMedia' in value for value in command))
        (self.state/'selectors.txt').write_text('\n'.join(reversed(selectors))+'\n')
        with self.assertRaises(ValueError):h.test_command()

    def test_stream_has_native_bound_narrow_scope_and_no_unsupported_timezone(self):
        command=h.stream_command()
        self.assertEqual(command[command.index('--timeout')+1],'45m')
        self.assertEqual(command[command.index('--predicate')+1],h.PREDICATE)
        self.assertEqual(command[command.index('--level')+1],'info');self.assertNotIn('--timezone',command)
        self.assertIn(ID,command);self.assertNotIn('booted',command)

    def test_run_records_started_before_execution_and_preserves_native_failure(self):
        calls=[]
        def failure(argv,**kwargs):
            calls.append(argv)
            self.assertEqual(json.loads((self.state/'native.status.json').read_text())['status'],'running')
            kwargs['stdout'].write(b'original failure')
            return subprocess.CompletedProcess(argv,65)
        with patch.object(h.subprocess,'run',side_effect=failure):
            self.assertEqual(h.run('native',['synthetic-native'],check=False),65)
        self.assertEqual(len(calls),1)
        self.assertEqual(json.loads((self.state/'native.status.json').read_text())['exitCode'],65)
        self.assertEqual((self.state/'native.log').read_bytes(),b'original failure')

    def test_bounded_export_failure_has_separate_stderr_and_receipt(self):
        def expired(argv,**kwargs):
            self.assertEqual(kwargs['timeout'],45)
            kwargs['stdout'].write(b'partial output');kwargs['stderr'].write(b'export diagnostic')
            raise subprocess.TimeoutExpired(argv,45)
        with patch.object(h.subprocess,'run',side_effect=expired):
            self.assertEqual(h.run('events-export',['synthetic-export'],timeout=45,check=False,separate_stderr=True),124)
        self.assertEqual((self.state/'events-export.log').read_bytes(),b'partial output')
        self.assertEqual((self.state/'events-export.stderr').read_bytes(),b'export diagnostic')

    def test_capture_timeout_stops_only_its_owned_group_and_keeps_failure_receipt(self):
        class FakeProcess:
            pid=123
            returncode=None
            waits=[]
            def wait(inner,timeout):
                inner.waits.append(timeout)
                if timeout==2700:raise subprocess.TimeoutExpired('stream',timeout)
                inner.returncode=-15;return -15
            def poll(inner):return None
        process=FakeProcess()
        with patch.object(h.subprocess,'Popen',return_value=process),patch.object(h,'fingerprint',return_value='owned'),patch.object(h.signal,'signal'),patch.object(h.os,'killpg') as kill:
            with self.assertRaises(RuntimeError):h.capture_stream()
        kill.assert_called_once_with(123,signal.SIGTERM)
        self.assertEqual(process.waits,[2700,5])
        receipt=json.loads((self.state/'capture-final.json').read_text())
        self.assertEqual(receipt['operationExit'],124);self.assertEqual(receipt['helperExit'],1)
        self.assertFalse(receipt['completeDeliveryProven']);self.assertEqual(receipt['wallTimeZone'],'unknown')

    def stop_identities(self):
        h.save(self.state/'capture-owner.json',{'pid':123,'fingerprint':'owner'})
        h.save(self.state/'capture-child.json',{'pid':124,'fingerprint':'child'})

    def stop_events(self):
        return [json.loads(line) for line in (self.state/'capture-stop-events.jsonl').read_text().splitlines()]

    def test_private_stop_exception_survives_kqueue_style_oserror_catch(self):
        def library_wait(exception):
            try:raise exception
            except OSError:return 'swallowed'
        self.assertEqual(library_wait(InterruptedError()),'swallowed')
        self.assertFalse(issubclass(h._CaptureStop,OSError))
        with self.assertRaises(h._CaptureStop):library_wait(h._CaptureStop())

    def test_real_capture_handler_uses_private_stop_and_finishes_child_receipt(self):
        clock=StopClock();handlers={}
        def install(sig,handler):handlers[sig]=handler
        def stopped(timeout):
            self.assertEqual(timeout,2700)
            handlers[signal.SIGTERM](signal.SIGTERM,None)
        child=StopProcess(clock,[stopped,-15],pid=124)
        with patch.object(h.subprocess,'Popen',return_value=child),patch.object(h,'fingerprint',return_value='child'),patch.object(h.signal,'signal',side_effect=install),patch.object(h.os,'killpg') as kill,patch.object(h.time,'monotonic',clock):
            h.capture_stream()
        kill.assert_called_once_with(124,signal.SIGTERM)
        receipt=json.loads((self.state/'capture-final.json').read_text())
        self.assertEqual(receipt['helperExit'],0);self.assertTrue(receipt['shutdownComplete'])
        self.assertFalse(receipt['completeDeliveryProven']);self.assertEqual(child.waits,[2700,5])
        self.assertIs(handlers[signal.SIGTERM],signal.SIG_IGN)

    def test_child_escalation_keeps_original_ten_second_budget(self):
        clock=StopClock();child=StopProcess(clock,['timeout',-9],pid=124)
        with patch.object(h,'fingerprint',return_value='child'),patch.object(h.os,'killpg') as kill,patch.object(h.time,'monotonic',clock):
            self.assertTrue(h.finish_capture_child(child,{'pid':124,'fingerprint':'child'}))
        self.assertEqual([args.args for args in kill.call_args_list],[(124,signal.SIGTERM),(124,signal.SIGKILL)])
        self.assertEqual(child.waits,[5,5]);self.assertLessEqual(clock.now,10)

    def test_parent_clean_grace_never_signals_child_or_escalates(self):
        self.stop_identities();clock=StopClock();owner=StopProcess(clock,[0])
        with patch.object(h,'fingerprint',return_value='owner'),patch.object(h.os,'killpg') as kill,patch.object(h.time,'monotonic',clock):
            self.assertTrue(h.finish_capture_owner(owner))
        kill.assert_called_once_with(123,signal.SIGTERM);self.assertEqual(owner.waits,[12])

    def test_parent_waits_for_final_receipt_after_child_term_before_kill(self):
        self.stop_identities();clock=StopClock();owner=StopProcess(clock,['timeout',0])
        with patch.object(h,'fingerprint',side_effect=lambda pid,timeout:'owner' if pid==123 else 'child'),patch.object(h.os,'killpg') as kill,patch.object(h.time,'monotonic',clock):
            self.assertTrue(h.finish_capture_owner(owner))
        self.assertEqual([args.args for args in kill.call_args_list],[(123,signal.SIGTERM),(124,signal.SIGTERM)])
        self.assertEqual(owner.waits,[12,2]);self.assertLessEqual(clock.now,17)
        stages=[r['stage'] for r in self.stop_events() if r['event']=='wait_started']
        self.assertEqual(stages,['execute-owner-grace','execute-finalization-grace'])

    def test_parent_escalates_only_matching_processes_within_original_seventeen_seconds(self):
        self.stop_identities();clock=StopClock();owner=StopProcess(clock,['timeout','timeout',-9])
        with patch.object(h,'fingerprint',side_effect=lambda pid,timeout:'owner' if pid==123 else 'child'),patch.object(h.os,'killpg') as kill,patch.object(h.time,'monotonic',clock):
            self.assertTrue(h.finish_capture_owner(owner))
        self.assertEqual([args.args for args in kill.call_args_list],[(123,signal.SIGTERM),(124,signal.SIGTERM),(124,signal.SIGKILL),(123,signal.SIGKILL)])
        self.assertEqual(owner.waits,[12,2,3]);self.assertLessEqual(clock.now,17)
        requests=[(r['pid'],r['signal']) for r in self.stop_events() if r['event']=='signal_requested']
        self.assertEqual(requests,[(123,'SIGTERM'),(124,'SIGTERM'),(124,'SIGKILL'),(123,'SIGKILL')])

    def test_reused_processes_are_never_signaled_even_during_escalation(self):
        self.stop_identities();clock=StopClock();owner=StopProcess(clock,['timeout','timeout','timeout'])
        with patch.object(h,'fingerprint',return_value='different process'),patch.object(h.os,'killpg') as kill,patch.object(h.time,'monotonic',clock):
            self.assertFalse(h.finish_capture_owner(owner))
        kill.assert_not_called();self.assertEqual(clock.now,17)
        self.assertEqual(len([r for r in self.stop_events() if r['event']=='signal_refused']),4)

    def test_identity_is_rechecked_before_escalation(self):
        self.stop_identities();clock=StopClock();owner=StopProcess(clock,['timeout','timeout',0])
        with patch.object(h,'fingerprint',side_effect=['owner','child','replacement child','replacement owner']),patch.object(h.os,'killpg') as kill,patch.object(h.time,'monotonic',clock):
            self.assertTrue(h.finish_capture_owner(owner))
        self.assertEqual([args.args for args in kill.call_args_list],[(123,signal.SIGTERM),(124,signal.SIGTERM)])

    def test_identity_check_exhausting_budget_prevents_signals_and_extra_waits(self):
        self.stop_identities();clock=StopClock();owner=StopProcess(clock,['timeout'])
        def slow_identity(pid,timeout):
            clock.now+=timeout
            return 'owner' if pid==123 else 'child'
        with patch.object(h,'fingerprint',side_effect=slow_identity),patch.object(h.os,'killpg') as kill,patch.object(h.time,'monotonic',clock):
            # Identity consumes 10 seconds; the first wait receives only the remaining 7.
            self.assertFalse(h.finish_capture_owner(owner))
        self.assertEqual(clock.now,17);self.assertEqual(owner.waits,[7])
        self.assertEqual([args.args for args in kill.call_args_list],[(123,signal.SIGTERM)])
        self.assertTrue(any(r['event']=='budget_exhausted' for r in self.stop_events()))

    def test_stop_receipts_append_across_collect_and_cleanup(self):
        self.stop_identities()
        with patch.object(h,'fingerprint',side_effect=lambda pid,timeout:'owner' if pid==123 else 'child'),patch.object(h.os,'killpg'):
            h.stop_owned_capture('collect');first=(self.state/'capture-stop-events.jsonl').read_bytes()
            h.stop_owned_capture('cleanup');second=(self.state/'capture-stop-events.jsonl').read_bytes()
        self.assertTrue(second.startswith(first));self.assertGreater(len(second),len(first))
        stages={r['stage'] for r in self.stop_events()}
        self.assertIn('collect',stages);self.assertIn('cleanup',stages)
        self.assertFalse((self.state/'capture-cleanup.json').exists())

    def test_native_failure_is_preserved_after_clean_collector_stop(self):
        clock=StopClock();owner=StopProcess(clock,[0])
        def native(name,args,**kwargs):
            h.save(self.state/'Tests.status.json',{'exitCode':65});return 65
        with patch.object(h,'verify_frozen'),patch.object(h.subprocess,'Popen',return_value=owner),patch.object(h,'fingerprint',return_value='owner'),patch.object(h.os,'killpg'),patch.object(h.time,'monotonic',clock),patch.object(h,'run',side_effect=native):
            with self.assertRaises(RuntimeError):h.execute()
        self.assertEqual(json.loads((self.state/'Tests.status.json').read_text())['exitCode'],65)
        final=json.loads((self.state/'capture-owner-final.json').read_text())
        self.assertTrue(final['ownerReaped']);self.assertFalse(final['helperFinalReceiptPresent'])
        self.assertFalse(final['gracefulFinalizationConfirmed']);self.assertFalse(final['completeDeliveryProven'])

    def test_order_retains_duplicates_instead_of_hiding_restart(self):
        text="Test Case '-[RoomInTheCartUITests.MeasurementUITests testOne]' started.\n"*2
        self.assertEqual(h.order_from_log(text),['RoomInTheCartUITests/MeasurementUITests/testOne']*2)

    def summary(self):
        return {'devicesAndConfigurations':[{'device':{'deviceId':ID,'architecture':'arm64','modelName':'iPhone 17',
            'osVersion':'26.2','osBuildNumber':'23C54','platform':'iOS Simulator'}}]}

    def test_actual_result_device_requires_exact_identity_and_build(self):
        self.assertTrue(h.validate_test_runtime(self.summary(),ID))
        for key,value in [('osBuildNumber','wrong'),('architecture','x86_64'),('deviceId','different')]:
            data=self.summary();data['devicesAndConfigurations'][0]['device'][key]=value
            self.assertFalse(h.validate_test_runtime(data,ID))
        data=self.summary();data['devicesAndConfigurations']*=2
        self.assertFalse(h.validate_test_runtime(data,ID))

    def test_cleanup_refuses_reused_pid_and_only_signals_recorded_matching_group(self):
        h.save(self.state/'capture-owner.json',{'pid':123,'fingerprint':'recorded owner'})
        h.save(self.state/'capture-child.json',{'pid':124,'fingerprint':'recorded child'})
        with patch.object(h,'fingerprint',side_effect=['different new process','recorded child']),patch.object(h.os,'killpg') as kill:
            h.stop_owned_capture()
        kill.assert_called_once_with(124,signal.SIGTERM)
        records=[json.loads(line) for line in (self.state/'capture-stop-events.jsonl').read_text().splitlines()]
        receipt=next(row for row in records if row['stage']=='cleanup-capture-owner.json' and row['event']=='identity_checked')
        self.assertFalse(receipt['matched'])

    def test_cleanup_does_not_touch_other_simulator_or_runtime(self):
        data={'devices':{RUNTIME:[{'name':'someone else','udid':ID}], 'other-runtime':[{'name':'owned random name','udid':ID}]}}
        calls=[]
        def fake(name,argv,**kwargs):
            calls.append(name);(self.state/(name+'.log')).write_text(json.dumps(data));return 0
        with patch.object(h,'run',side_effect=fake),patch.object(h,'stop_owned_capture'):h.cleanup()
        self.assertEqual(calls,['cleanup-inventory'])

    def test_cleanup_deletes_only_exact_owned_device_even_if_shutdown_failed(self):
        data={'devices':{RUNTIME:[{'name':'owned random name','udid':ID},{'name':'other','udid':'22222222-2222-4222-8222-222222222222'}]}}
        calls=[]
        def fake(name,argv,**kwargs):
            calls.append((name,argv))
            if name=='cleanup-inventory':(self.state/(name+'.log')).write_text(json.dumps(data))
            return 1 if name=='shutdown-owned' else 0
        with patch.object(h,'run',side_effect=fake),patch.object(h,'stop_owned_capture'):h.cleanup()
        self.assertEqual([x[0] for x in calls],['cleanup-inventory','shutdown-owned','delete-owned'])
        self.assertTrue(all(argv[-1]==ID for name,argv in calls[1:]))

    def prepare_collection(self,native=0):
        original=self.state/'Tests.xcresult';original.mkdir();(original/'data').write_bytes(b'original sqlite metadata')
        h.save(self.state/'Tests.status.json',{'exitCode':native})
        h.save(self.state/'capture-window.json',{'startUTC':'2026-11-06 12:00:00+0000'})
        selectors=(h.HERE/'selectors.txt').read_text().splitlines()
        (self.state/'Tests.log').write_text(''.join("Test Case '-[RoomInTheCartUITests.%s %s]' started.\n"%tuple(x.split('/')[1:]) for x in selectors))
        return original

    def collection_runner(self,name,argv,**kwargs):
        output=b'{}'
        if name in ('test-summary','test-details','strict'):
            self.assertIn(str(self.state/'replay/Tests.xcresult'),argv)
            self.assertNotIn(str(self.state/'Tests.xcresult'),argv)
            self.assertTrue((self.state/'replay/Tests.xcresult/data').exists())
            (self.state/'replay/Tests.xcresult/data').write_bytes(b'inspection mutated metadata')
        if name=='test-summary':output=json.dumps(self.summary()).encode()
        if name=='events-export':
            self.assertEqual(kwargs['timeout'],45);self.assertTrue(kwargs['separate_stderr'])
            self.assertTrue(argv[argv.index('--start')+1].endswith('+0000'))
            self.assertEqual(argv[argv.index('--timezone')+1],'UTC')
        (self.state/(name+'.log')).write_bytes(output)
        return 0

    def test_collection_inspects_only_verified_copy_and_preserves_original(self):
        original=self.prepare_collection()
        with patch.object(h,'run',side_effect=self.collection_runner),patch.object(h,'verify_frozen'),patch.object(h,'stop_owned_capture'):
            h.collect()
        self.assertEqual((original/'data').read_bytes(),b'original sqlite metadata')
        outcome=json.loads((self.state/'outcome.json').read_text())
        self.assertTrue(outcome['nativeAndStrictPassed']);self.assertFalse(outcome['releaseAcceptance'])

    def test_failed_native_cannot_be_replaced_by_passing_exports_checker_or_parser(self):
        self.prepare_collection(native=65)
        with patch.object(h,'run',side_effect=self.collection_runner),patch.object(h,'verify_frozen'),patch.object(h,'stop_owned_capture'):
            with self.assertRaises(RuntimeError):h.collect()
        outcome=json.loads((self.state/'outcome.json').read_text())
        self.assertFalse(outcome['nativeAndStrictPassed']);self.assertEqual(outcome['nativeExit'],65)

    def test_copy_mismatch_is_fatal_even_if_replay_tools_return_success(self):
        self.prepare_collection()
        def corrupt_copy(source,destination,**kwargs):
            destination.mkdir();(destination/'data').write_bytes(b'wrong bytes')
        with patch.object(h.shutil,'copytree',side_effect=corrupt_copy),patch.object(h,'run',side_effect=self.collection_runner),patch.object(h,'verify_frozen'),patch.object(h,'stop_owned_capture'):
            with self.assertRaises(RuntimeError):h.collect()
        outcome=json.loads((self.state/'outcome.json').read_text())
        self.assertFalse(outcome['resultCopyVerified']);self.assertFalse(outcome['nativeAndStrictPassed'])

    def test_raw_result_change_after_copy_is_detected(self):
        original=self.prepare_collection()
        def mutate(name,argv,**kwargs):
            value=self.collection_runner(name,argv,**kwargs)
            if name=='strict':(original/'data').write_bytes(b'unexpected mutation')
            return value
        with patch.object(h,'run',side_effect=mutate),patch.object(h,'verify_frozen'),patch.object(h,'stop_owned_capture'):
            with self.assertRaises(RuntimeError):h.collect()
        self.assertFalse(json.loads((self.state/'raw-result-preservation.json').read_text())['unchanged'])



class KeyboardTransportTests(HarnessTests):
    # Inherit the mocked setup only; inherited cases are excluded by load_tests below.
    def test_full_freeze_restore_keeps_six_case_plan_original_xctestrun_and_digest(self):
        source={'app.swift':'exact-frozen-source'};h.save(self.state/'source-before.json',source)
        original=h.original_xctestrun();original_bytes=original.read_bytes()
        output=self.root/'github-output';output.touch()
        def native(name,argv,**kwargs):
            self.assertNotIn('scripts/plan_ios_fixture_tests.py',argv)
            if name=='plan':
                plan=self.state/'compiled-plan';plan.mkdir()
                (plan/'manifest.json').write_bytes((h.HERE/'reference-plan.json').read_bytes())
                (plan/'ui-07.txt').write_bytes((h.HERE/'selectors.txt').read_bytes())
            return 0
        old_cwd=Path.cwd();os.chdir(self.root);self.addCleanup(os.chdir,old_cwd)
        with patch.object(h,'run',side_effect=native),patch.object(h,'source_snapshot',return_value=source),patch.dict(h.os.environ,{'RUNNER_TEMP':str(self.root),'GITHUB_OUTPUT':str(output)}):
            h.freeze()
        self.assertEqual(original.read_bytes(),original_bytes)
        archive=self.root/'keyboard-products.tar.gz';digest=h.file_digest(archive)
        self.assertEqual(output.read_text(),'sha256='+digest+'\n')
        download=self.root/'.build/download';download.mkdir();(download/archive.name).write_bytes(archive.read_bytes())
        restored=self.root/'restored/Products'
        h.save(self.state/'owned-device.json',{'name':'new owned execution','runtime':RUNTIME,'udid':'22222222-2222-4222-8222-222222222222'})
        with patch.object(h,'PRODUCTS',restored),patch.dict(h.os.environ,{'BUILD_PRODUCT_SHA256':digest}):
            h.restore()
            self.assertEqual(h.original_xctestrun().read_bytes(),original_bytes)
        self.assertTrue(json.loads((self.state/'restore.json').read_text())['productsMatch'])
    def test_restore_rejects_digest_before_any_extraction(self):
        old_cwd=Path.cwd();os.chdir(self.root);self.addCleanup(os.chdir,old_cwd)
        p=self.root/'.build/download/keyboard-products.tar.gz';p.parent.mkdir(parents=True);p.write_bytes(b'incorrect transport')
        with patch.dict(h.os.environ,{'BUILD_PRODUCT_SHA256':'0'*64}),patch.object(h,'extract_transport') as extract:
            with self.assertRaises(ValueError):h.restore()
        extract.assert_not_called()
    def test_execute_refuses_existing_native_evidence_without_spawn_or_signal(self):
        (self.state/'Tests.status.json').write_text('{"exitCode":65}')
        with patch.object(h.subprocess,'Popen') as spawn,patch.object(h.os,'killpg') as signal:
            with self.assertRaises(ValueError):h.execute()
        spawn.assert_not_called();signal.assert_not_called()
        self.assertEqual(json.loads((self.state/'Tests.status.json').read_text())['exitCode'],65)
    def test_mismatched_compiled_plan_stops_before_transport(self):
        def native(name,argv,**kwargs):
            if name=='plan':
                plan=self.state/'compiled-plan';plan.mkdir();h.save(plan/'manifest.json',{'wrong':'inventory'})
            return 0
        with patch.object(h,'run',side_effect=native),patch.object(h.tarfile,'open') as archive:
            with self.assertRaises(ValueError):h.freeze()
        archive.assert_not_called()


    def test_archive_bounds_fail_before_destination_creation(self):
        archive=self.root/'bounded.tar';archive.write_bytes(b'x'*60000)
        for sizes in ([50_000_000], [0]*50000, [40_000_000]*25, [40_000_000]*2):
            members=[]
            for size in sizes:
                member=tarfile.TarInfo('Products/item');member.size=size;members.append(member)
            with patch.object(h.tarfile,'open') as tar:
                tar.return_value.__enter__.return_value.getmembers.return_value=members
                with self.assertRaises(ValueError):h.extract_transport(archive,self.root/'must-not-exist')
            self.assertFalse((self.root/'must-not-exist').exists())


    def test_product_exception_only_exact_regular_file_below_exclusive_80mb(self):
        archive=self.root/'product.tar';archive.write_bytes(b'x'*80000)
        def validate(name,size,kind=tarfile.REGTYPE):
            member=tarfile.TarInfo(name);member.size=size;member.type=kind
            with patch.object(h.tarfile,'open') as tar:
                tar.return_value.__enter__.return_value.getmembers.return_value=[member]
                h.validate_transport_bounds(archive)
        path='Products/Debug-iphonesimulator/RoomInTheCart.app/RoomInTheCart.debug.dylib'
        validate(path,52_752_832);validate(path,79_999_999)
        for size in (80_000_000,80_000_001):
            with self.assertRaises(ValueError):validate(path,size)
        for alias in ('./'+path,'/'+path,path.replace('/RoomInTheCart.app/','/Other.app/'),
                      path+'.other',path.replace('Debug-iphonesimulator','Release-iphonesimulator'),
                      path.replace('Products/','Products/../Products/'),path.replace('RoomInTheCart.debug.dylib','roominthecart.debug.dylib')):
            with self.assertRaises(ValueError):validate(alias,50_000_000)
            validate(alias,49_999_999)  # Bounds alone; separate extractor path rules still apply.
        for kind in (tarfile.SYMTYPE,tarfile.DIRTYPE,tarfile.LNKTYPE):
            with self.assertRaises(ValueError):validate(path,50_000_000,kind)
        with self.assertRaises(ValueError):validate('Products/other',50_000_000)


def load_tests(loader, tests, pattern):
    suite=loader.loadTestsFromTestCase(HarnessTests)
    for name in KeyboardTransportTests.__dict__:
        if name.startswith('test_'):suite.addTest(KeyboardTransportTests(name))
    return suite

if __name__=='__main__':unittest.main()
