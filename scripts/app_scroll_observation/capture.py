#!/usr/bin/env python3
"""Bounded hosted app collection only; export and original result validation are separate phases."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import time
from types import SimpleNamespace
import uuid

from .owned import Supervisor, Identity, Notification
from .support import SELECTOR, require, sha, manifest, modes, atomic_json, derive_plan, arm64_uuid, launcher_identity

BASE = Path(__file__).resolve().parent


from .native_environment import NativeEnvironmentSpawn


class Capture(NativeEnvironmentSpawn, Supervisor):
    def __init__(self, config, output):
        self.config = config
        self.device = config["simulatorUDID"]
        self.out = output.resolve(); self.out.mkdir(parents=True, exist_ok=False); self.out.chmod(0o700)
        self.args = SimpleNamespace(xctrace=Path(config['tools']['xctrace']['path']))
        self.identity = Identity()  # No native identity query occurs merely by importing this module.
        self.processes, self.notifications = [], []
        self.bound = {}; self.control_directory = None; self.native_started = None; self.cleaning = False
        self.nonce = uuid.uuid4().hex
        self.receipt = {'schemaVersion': 1, 'diagnosticOnly': True, 'releaseAcceptance': False,
            'captureQualified': False, 'expectedEventsProven': False, 'outcome': 'running',
            'nonce': self.nonce, 'subsystem': 'dev.roominthecart.appcapture.' + self.nonce,
            'simulatorUDID': self.device, 'selector': SELECTOR, 'startedEpoch': time.time(),
            'readinessObserved': False, 'processes': [], 'bindings': {}, 'hostCommands': [],
            'limits': {'nativeToArmSeconds': 120, 'readinessSeconds': 15, 'recordSeconds': 60,
                'postRecordFinalizationSeconds': 30, 'waitAfterReadinessSeconds': 90,
                'nativeWallSeconds': 240, 'cleanupSecondsPerProcess': 7,
                'artifactBytes': 256*1024**2, 'traceBytesEach': 128*1024**2, 'xcresultBytes': 512*1024**2,
                'nativeLogBytes': 16*1024**2, 'files': 2048},
            'preparedSources': {p.name: sha(p) for p in BASE.iterdir() if p.suffix in ('.py', '.json', '.fragment')}}
        self.save()

    def budget(self):
        if not self.cleaning and self.native_started is not None:
            require(time.monotonic() - self.native_started <= 240, 'native_wall_deadline')
        require(shutil.disk_usage(self.out).free >= 8 * 1024**3, 'disk_reserve')
        total = results = count = 0
        traces = {'app.trace': 0, 'inspection.trace': 0}
        for folder, dirs, names in os.walk(self.out, followlinks=False):
            for name in dirs + names: require(not (Path(folder)/name).is_symlink(), 'artifact_symlink')
            for name in names:
                path = Path(folder)/name; size = path.stat().st_size; count += 1
                require(count <= 2048, 'artifact_file_cap')
                if 'Performance.xcresult' in path.parts:
                    results += size; require(results <= 512*1024**2, 'xcresult_cap'); continue
                trace = path.relative_to(self.out).parts[0]
                if trace in traces:
                    traces[trace] += size; require(traces[trace] <= 128*1024**2, 'trace_cap:'+trace)
                total += size; require(total <= 256*1024**2, 'artifact_cap')
                if path.name == 'native-stdout.log':
                    require(size <= 16*1024**2, 'native_log_cap'); continue
                if path.name in ('signposts.xml', 'signposts-stdout.log'):
                    require(size <= 8*1024**2, 'xml_cap')
                elif path.suffix == '.log': require(size <= 1024**2, 'tool_log_cap')

    def tool_spawn(self, label, key, tail, allow_terminal_query=False):
        tool = self.config['tools'][key]
        path, digest = Path(tool['path']), tool['sha256']
        expected = Path(tool.get('executable', tool['path']))
        expected_digest = tool.get('executableSHA256', digest)
        require(sha(path) == digest, key + '_invocation_hash')
        try:
            return self.spawn(label, [str(path.resolve()), *tail], expected, expected_digest)
        except RuntimeError:
            # A completed query can exit before libproc samples its image. Its owned Popen is reaped;
            # it never becomes a signaling target. Native/tracer/exporter must bind live as usual.
            if allow_terminal_query and self.processes and self.processes[-1]['record']['label'] == label:
                item = self.processes[-1]
                if item['process'].poll() is not None:
                    item['record']['terminalQueryBeforeBinding'] = True; self.save(); return item
            raise

    def query_container(self, bundle, kind, label, startup_native=None):
        started = time.monotonic()
        startup = startup_native is not None
        if startup:
            require(bundle == 'dev.roominthecart.app' and kind == 'data' and not self.bound
                    and self.native_started is not None and startup_native['record']['label'] == 'native',
                    'startup_container_scope')
        deadline = self.native_started + 120 if startup else started + 5
        def check_native():
            if startup:
                require(startup_native['process'].poll() is None, 'native_exited_before_app')
                value = startup_native['binding']
                require(value is not None and self.identity.read(value['pid']) == value, 'native_identity_before_app')
                require(time.monotonic() < deadline, 'app_data_deadline')
        check_native(); self.budget()
        item = self.tool_spawn(label, 'simctl', ['get_app_container', self.device, bundle, kind], True)
        item['record'].update(containerLookupPhase='startup' if startup else 'installed',
                              containerLookupBudgetSeconds=max(0, deadline-started))
        self.save()
        while True:
            self.budget(); check_native()
            require(time.monotonic() < deadline, label+'_deadline')
            code = item['process'].poll()
            if code is not None: break
            value = item['binding']
            if value is None or self.identity.read(value['pid']) != value:
                # The owned query may exit between poll and libproc. Only its terminal
                # Popen state permits this race; a changed live identity remains fatal.
                require(item['process'].poll() is not None, label+'_identity_changed')
                continue
            # Full tuple liveness only: tool bytes are checked at invocation and before cleanup signals.
            time.sleep(min(0.05, max(0, deadline-time.monotonic())))
        item['record'].update(exitCode=code, containerLookupElapsedSeconds=time.monotonic()-started)
        self.cleanup(item)
        self.budget()  # Include bytes written between the last poll and terminal exit.
        stdout = (self.out/(label+'-stdout.log')).read_text()
        stderr = (self.out/(label+'-stderr.log')).read_text()
        absent = code == 2 and not stdout and stderr.splitlines() == [
            'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=2):',
            'The operation couldn’t be completed. No such file or directory', 'No such file or directory']
        item['record']['expectedContainerAbsent'] = absent; self.save()
        if absent: return None
        require(code == 0 and not stderr, 'container_query_failed:'+label)
        lines = stdout.splitlines()
        require(len(lines) == 1, 'container_response')
        path = Path(lines[0]).resolve()
        expected = (Path.home()/'Library/Developer/CoreSimulator/Devices')/self.device/'data/Containers'
        require(path.is_relative_to(expected.resolve()) and path.is_dir(), 'container_device_scope')
        return path

    def status(self):
        path = self.control_directory/'status.json'
        if not path.exists(): return None
        require(not path.is_symlink() and path.stat().st_size <= 8192, 'status_file')
        value = json.loads(path.read_text())
        if self.receipt.get('lastObservedStatus') != value:
            self.receipt['lastObservedStatus'] = value; self.save()
        require(value['nonce'] == self.nonce and value['subsystem'] == self.receipt['subsystem'], 'status_nonce')
        require(value['simulatorUDID'] == self.device and value['compiledForSimulator'] is True, 'status_device')
        if 'app' in self.bound:
            bound = self.bound['app']['binding']
            require(value['pid'] == bound['pid'] and value['uid'] == bound['uid']
                    and value['parentPID'] == bound['parentPID'] and str(Path(value['executable']).resolve()) == bound['executable'], 'status_process_changed')
        if 'runner' in self.bound: require(value['runnerPID'] == self.bound['runner']['binding']['pid'], 'status_runner_changed')
        require('error' not in value and value['stage'] != 'failed', 'app_protocol_failed:' + str(value.get('error')))
        return value

    def bind(self, role, pid, installed, product, status):
        require(type(pid) is int and pid > 1, role+'_pid')
        value = self.identity.read(pid)
        require(value is not None and value['uid'] == os.getuid(), role+'_identity')
        require(value['startTimeMicros'] >= int(self.receipt['nativeDispatchEpoch'] * 1e6), role+'_start_time')
        require(value['executable'] == str(installed.resolve()), role+'_exact_installed_path')
        require(sha(installed) == sha(product) and arm64_uuid(installed) == arm64_uuid(product), role+'_binary')
        require(manifest(installed.parent) == manifest(product.parent), role+'_installed_bundle')
        require(self.identity.read(pid) == value, role+'_changed_while_hashing')
        if role == 'app':
            require(status['uid'] == value['uid'] and status['parentPID'] == value['parentPID']
                    and str(Path(status['executable']).resolve()) == value['executable'], 'app_self_identity')
        record = {'binding': value, 'executableSHA256': sha(installed), 'arm64UUID': arm64_uuid(installed),
                  'installedBundleManifest': manifest(installed.parent), 'installedModes': modes(installed.parent), 'signals': [], 'terminalVerified': False}
        self.bound[role] = record; self.receipt['bindings'][role] = record; self.save()

    def bound_valid(self, role):
        item = self.bound[role]; value = item['binding']
        return self.identity.read(value['pid']) == value and sha(value['executable']) == item['executableSHA256']

    def bound_alive(self, role):
        # During measurement, avoid repeated executable I/O. Full tuple equality still detects
        # PID reuse, exec, UID or parent changes; byte revalidation occurs at owned boundaries.
        value = self.bound[role]['binding']
        return self.identity.read(value['pid']) == value

    def bound_terminal(self, role):
        value = self.bound[role]['binding']; current = self.identity.read(value['pid'])
        if current is not None: return current['startTimeMicros'] != value['startTimeMicros']
        try: os.kill(value['pid'], 0)
        except ProcessLookupError: return True
        except PermissionError: return False
        return False

    def host_command(self, action):
        require(action in ('GO', 'Q', 'ABORT') and self.control_directory is not None, 'host_command_phase')
        if action != 'ABORT':
            require(self.bound_valid('app') and self.bound_valid('runner'), 'identity_before_release')
        if action == 'GO': require(self.receipt['readinessObserved'] is True, 'early_go')
        if action == 'Q': require(self.receipt.get('normalTracerExit') is True, 'early_q')
        temp = self.control_directory/'host-command.tmp'
        temp.write_text(action+' '+self.nonce+'\n'); temp.replace(self.control_directory/'host-command.txt')
        self.receipt['hostCommands'].append({'command': action, 'epoch': time.time()}); self.save()

    def preflight(self):
        from .contract import verify_config
        verify_config(self.config)
        c = self.config
        self.receipt['sourceModes'] = c['sourceSnapshot']['modes']
        self.receipt['productsModes'] = modes(c['productsRoot'])
        self.receipt['inputs'] = {k: c[k] for k in ('sourceRoot','productsRoot','plan','planSHA256','sourceSnapshot','productsSnapshot','setupReceipt','setupReceiptSHA256')}
        self.receipt['simctlLaunchIdentity'] = launcher_identity(**c['launcherArguments'])
        self.receipt['config'] = c
        self.save(); self.budget()

    def run(self):
        try:
            self.preflight()
            (self.out/'selected.txt').write_text(SELECTOR+'\n')
            derived = self.out/'Capture.xctestrun'
            derived.write_bytes(derive_plan(Path(self.config['plan']).read_bytes(), self.config['productsRoot'], self.nonce, self.device))
            self.receipt['derivedPlanSHA256'] = sha(derived)
            control = Notification('dev.roominthecart.capture.self.'+uuid.uuid4().hex); self.notifications.append(control)
            require(control.lib.notify_post(control.name.encode()) == 0 and control.received(2), 'notification_self_control')
            self.receipt['notificationControlPassed'] = True
            ready = Notification('dev.roominthecart.capture.ready.'+uuid.uuid4().hex); self.notifications.append(ready)
            native_tail = ['-xctestrun',str(derived),'-destination','platform=iOS Simulator,id='+self.device,
                '-parallel-testing-enabled','NO','-test-timeouts-enabled','YES',
                '-default-test-execution-time-allowance','900','-maximum-test-execution-time-allowance','1200',
                '-resultBundlePath',str(self.out/'Performance.xcresult'),'-collect-test-diagnostics','on-failure',
                '-only-testing:'+SELECTOR,'test-without-building']
            self.native_started = time.monotonic(); self.receipt['nativeDispatchEpoch'] = time.time()
            native = self.tool_spawn('native','xcodebuild',native_tail)
            deadline = self.native_started+120
            data = None; query = 0
            while data is None and time.monotonic() < deadline:
                require(native['process'].poll() is None, 'native_exited_before_app')
                self.budget(); query += 1
                data = self.query_container('dev.roominthecart.app','data','container-data-'+str(query),startup_native=native)
                if data is None: time.sleep(0.25)
            require(data is not None, 'app_data_deadline')
            self.control_directory = data/'Library/Application Support/AppCaptureControl'/self.nonce
            value = None
            while time.monotonic() < deadline:
                self.budget(); require(native['process'].poll() is None, 'native_exited_before_arm')
                value = self.status()
                if value: break
                time.sleep(0.05)
            require(value is not None, 'app_identity_receipt_deadline')
            installed = self.query_container('dev.roominthecart.app','app','container-app')
            runner = self.query_container('dev.roominthecart.RoomInTheCartUITests.xctrunner','app','container-runner')
            require(installed is not None and runner is not None, 'installed_containers')
            product = Path(self.config['productsRoot'])/'Release-iphonesimulator'
            self.bind('app',value['pid'],installed/'RoomInTheCart',product/'RoomInTheCart.app/RoomInTheCart',value)
            self.bind('runner',value['runnerPID'],runner/'RoomInTheCartUITests-Runner',product/'RoomInTheCartUITests-Runner.app/RoomInTheCartUITests-Runner',value)
            self.receipt['initialStatus'] = value; self.save()
            # Bind early while the original fixture runs: a setup failure must not lose known
            # app/runner cleanup ownership. No collector starts until ARM.
            while value['stage'] != 'waitingForCollector' and time.monotonic() < deadline:
                self.budget(); require(native['process'].poll() is None, 'native_exited_before_arm')
                require(self.bound_alive('app') and self.bound_alive('runner'), 'target_identity_before_arm')
                time.sleep(0.05); value = self.status()
                require(value is not None, 'app_identity_receipt_disappeared')
            require(value['stage'] == 'waitingForCollector', 'arm_deadline')
            self.receipt['armedStatus'] = value; self.save()
            require(self.bound_valid('app') and self.bound_valid('runner'), 'identity_before_attach')
            tracer_started = time.monotonic()
            tracer = self.tool_spawn('tracer','xctrace',['record','--template','Logging','--device',self.device,
                '--attach',str(value['pid']),'--time-limit','60s','--output',str(self.out/'app.trace'),
                '--notify-tracing-started',ready.name])
            ready_deadline = tracer_started+15
            while time.monotonic() < ready_deadline and tracer['process'].poll() is None:
                self.budget()
                if ready.received(0.05):
                    self.receipt.update(readinessObserved=True,readinessEpoch=time.time()); self.save(); break
            require(self.receipt['readinessObserved'], 'collector_readiness_deadline')
            require(self.valid(tracer), 'tracer_changed_before_go')
            self.host_command('GO')
            trace_deadline = time.monotonic()+90
            while tracer['process'].poll() is None and time.monotonic() < trace_deadline:
                self.budget(); require(native['process'].poll() is None, 'native_exited_during_capture')
                require(self.bound_alive('app') and self.bound_alive('runner'), 'target_identity_during_capture')
                current = self.status()
                if current and current['stage'] == 'waitingForFinalization':
                    if 'completedStatus' not in self.receipt:
                        self.receipt['completedStatus'] = current; self.save()
                time.sleep(0.05)
            require(tracer['process'].poll() == 0, 'tracer_not_naturally_complete')
            tracer['record']['exitCode'] = 0
            require('completedStatus' in self.receipt, 'trace_ended_before_samples_completed')
            self.receipt.update(normalTracerExit=True,tracerExitEpoch=time.time()); self.save()
            self.host_command('Q')
            require(self.wait(native,max(0.1,240-(time.monotonic()-self.native_started))) == 0, 'original_native_failed')
            self.receipt['finalStatus'] = self.status()
            require(self.receipt['finalStatus']['stage'] == 'finished', 'finish_ack_missing')
            atomic_json(self.out/'app-status-final.json', self.receipt['finalStatus'])
            for role in self.bound:
                require(self.bound_terminal(role), role+'_not_terminal_after_native')
                record = self.bound[role]
                require(manifest(Path(record['binding']['executable']).parent) == record['installedBundleManifest'], role+'_installed_bundle_changed')
                require(modes(Path(record['binding']['executable']).parent) == record['installedModes'], role+'_installed_modes_changed')
                record['installedBundleUnchanged'] = True
            from .contract import verify_config
            verify_config(self.config)
            self.receipt["originalTrace"] = {"files": manifest(self.out/"app.trace"), "modes": modes(self.out/"app.trace")}
            self.receipt["originalResult"] = {"files": manifest(self.out/"Performance.xcresult"), "modes": modes(self.out/"Performance.xcresult")}
            require(modes(self.config['productsRoot']) == self.receipt['productsModes'], 'product_modes_changed')
            self.receipt.update(sourceUnchanged=True, productsUnchanged=True, outcome='collected_pending_independent_validation')
        except BaseException as error:
            self.receipt.update(outcome='unqualified',error=type(error).__name__+': '+str(error))
        finally:
            self.cleaning = True
            signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN)
            if self.receipt['outcome'] == 'unqualified' and self.control_directory and self.control_directory.is_dir():
                try: self.host_command('ABORT')
                except BaseException as error: self.receipt['abortError'] = str(error)
            # Stop collector/exporters first, then exact owned app/runner, then native parent.
            for item in reversed(self.processes):
                if item['record']['label'] == 'native': continue
                try: self.cleanup(item)
                except BaseException as error: item['record']['cleanupError'] = str(error)
            for role in ('app','runner'):
                if role in self.bound:
                    try: self.cleanup_bound(role)
                    except BaseException as error: self.bound[role]['cleanupError'] = str(error)
            for item in self.processes:
                if item['record']['label'] == 'native':
                    try: self.cleanup(item)
                    except BaseException as error: item['record']['cleanupError'] = str(error)
            self.receipt['notificationCancelStatus'] = []
            for notice in self.notifications:
                try: self.receipt['notificationCancelStatus'].append(notice.close())
                except BaseException as error: self.receipt['notificationCancelStatus'].append(str(error))
            known_terminal = (all(p['process'].poll() is not None for p in self.processes)
                and all(self.bound_terminal(role) for role in self.bound)
                and (self.native_started is None or set(self.bound) == {'app','runner'}))
            self.receipt['allKnownOwnedProcessesTerminal'] = known_terminal
            self.receipt['allOwnedProcessesTerminal'] = known_terminal and self.receipt['outcome'] == 'collected_pending_independent_validation'
            if self.receipt['outcome'] == 'unqualified' and self.native_started is not None:
                self.receipt['failureDescendantsNotVerified'] = 'Known exact app/runner/native/tracer processes were bounded. XCTest may have launched diagnostic descendants; root must separately verify their termination. No global kill was attempted.'
            if self.native_started is not None and set(self.bound) != {'app','runner'}:
                self.receipt['unboundTargetRisk'] = 'App/runner not both bound. No process-name kill attempted; root must verify terminal state.'
            self.receipt['finishedEpoch'] = time.time(); self.save()
        return 0 if self.receipt['outcome'] == 'collected_pending_independent_validation' and self.receipt['allOwnedProcessesTerminal'] else 1

    def cleanup_bound(self, role):
        record = self.bound[role]
        for sig, seconds in ((signal.SIGINT,2),(signal.SIGTERM,3),(signal.SIGKILL,2)):
            if self.bound_terminal(role): break
            if not self.bound_valid(role): record['cleanupError'] = 'identity_unverified_no_signal'; break
            try: os.kill(record['binding']['pid'],sig)
            except ProcessLookupError: break
            record['signals'].append(sig.name); self.save()
            deadline = time.monotonic()+seconds
            while time.monotonic() < deadline and not self.bound_terminal(role): time.sleep(0.05)
        record['terminalVerified'] = self.bound_terminal(role); self.save()

