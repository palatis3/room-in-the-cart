#!/usr/bin/env python3
"""PREPARED, NOT EXECUTED. Simulator transport control; never app qualification."""
import argparse
import json
import os
from pathlib import Path
import signal
import time
import uuid

from .host_control import Supervisor, Notification, sha, STARTUP_SECONDS, EXPORT_SECONDS

# Simulator r2 entered finalization before its original deadline but required cleanup.
# One bounded diagnostic allows thirty seconds; hosted/app budgets are unchanged.
FINALIZE_SECONDS = 30
FAILED_READINESS_OBSERVATION_SECONDS = 15


def reviewed_simctl_identity(args):
    """Keep Apple's public launcher; bind the reviewed executable it literally execs."""
    launcher, executable = args.simctl, args.simctl_executable
    for label, path, digest in (
        ('launcher', launcher, args.simctl_sha256),
        ('executable', executable, args.simctl_executable_sha256),
    ):
        if path.is_symlink() or not path.is_file() or sha(path) != digest:
            raise RuntimeError('simctl_' + label + '_identity')
    source = launcher.read_text()
    lines = [line for line in source.splitlines() if line.strip()]
    expected_exec = 'exec "' + str(executable.resolve()) + '" "${@}"'
    if not source.startswith('#!/bin/bash\n') or not lines or lines[-1] != expected_exec:
        raise RuntimeError('simctl_launcher_exec_contract_changed')
    return {'launcher': str(launcher.resolve()), 'launcherSHA256': args.simctl_sha256,
            'executable': str(executable.resolve()), 'executableSHA256': args.simctl_executable_sha256,
            'reviewedFinalExec': expected_exec}


class SimulatorSupervisor(Supervisor):
    def __init__(self, args):
        super().__init__(args)
        os.chmod(self.out, 0o700)
        self.target = None
        self.target_attempted = False
        self.receipt['limits']['finalizationSeconds'] = FINALIZE_SECONDS
        self.nonce = uuid.uuid4().hex
        self.receipt.update(scope='Standalone iOS Simulator helper and Logging transport only',
                            simulatorUDID=args.simulator, nonce=self.nonce,
                            helperLifetimeSeconds=60, helperBindingSeconds=5)
        self.receipt['preparedSources'] = {p.name: sha(p) for p in
            (Path(__file__).resolve(), Path(__file__).with_name('host_control.py'),
             Path(__file__).with_name('SignpostControl.swift'))}
        self.save()

    def helper_status(self):
        path = self.out / 'helper-status.json'
        if not path.exists(): return None
        if path.is_symlink() or path.stat().st_size > 4096:
            raise RuntimeError('helper_status_invalid_file')
        value = json.loads(path.read_text())
        if value.get('nonce') != self.nonce or value.get('subsystem') != self.receipt['subsystem']:
            raise RuntimeError('helper_status_binding_mismatch')
        return value

    def bind_target(self, wrapper):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.budget()
            status = self.helper_status()
            if status is not None:
                self.receipt['helperInitialStatus'] = status; self.save()
                pid = status.get('pid')
                if type(pid) is not int or pid < 2: raise RuntimeError('helper_pid_invalid')
                value = self.identity.read(pid)
                if not value: raise RuntimeError('helper_pid_unreadable')
                if (value['executable'] != str(self.args.helper.resolve())
                    or sha(self.args.helper) != self.args.helper_sha256
                    or value['uid'] != os.getuid() or value['uid'] != status.get('uid')
                    or value['parentPID'] != status.get('parentPID')
                    or value['startTimeMicros'] < int(wrapper['record']['spawnEpoch'] * 1_000_000)):
                    raise RuntimeError('helper_process_binding_failed')
                # Record ownership before environment rejection, so this exact helper can be cleaned up.
                self.target = value
                self.receipt['helper'] = {'binding': value, 'executableSHA256': self.args.helper_sha256,
                                          'signals': [], 'terminalVerified': False}
                self.save()
                if (status.get('compiledForSimulator') is not True
                    or status.get('simulatorUDID', '').upper() != self.args.simulator.upper()
                    or status.get('stage') != 'waiting'):
                    raise RuntimeError('helper_simulator_identity_or_stage_rejected')
                return
            if wrapper['process'].poll() is not None:
                raise RuntimeError('simctl_spawn_exited_before_helper_receipt')
            time.sleep(0.05)
        raise RuntimeError('helper_binding_deadline')

    def target_valid(self):
        return (self.target is not None and self.identity.read(self.target['pid']) == self.target
                and sha(self.args.helper) == self.args.helper_sha256)

    def target_terminal(self):
        if self.target is None: return not self.target_attempted
        current = self.identity.read(self.target['pid'])
        if current is not None:
            return current['startTimeMicros'] != self.target['startTimeMicros']
        try: os.kill(self.target['pid'], 0)
        except ProcessLookupError: return True
        except PermissionError: return False
        return False

    def command(self, letter):
        if not self.target_valid(): raise RuntimeError('helper_changed_before_command')
        temporary = self.out / 'helper-command.tmp'
        temporary.write_text(letter + ' ' + self.nonce + '\n')
        temporary.replace(self.out / 'helper-command.txt')

    def cleanup_target(self):
        if self.target is None: return
        record = self.receipt['helper']
        for sig, seconds in ((signal.SIGINT, 2), (signal.SIGTERM, 3), (signal.SIGKILL, 2)):
            if self.target_terminal(): break
            if not self.target_valid():
                record['cleanupError'] = 'identity_unverified_no_signal'; break
            try: os.kill(self.target['pid'], sig)
            except ProcessLookupError: break
            record['signals'].append(sig.name); self.save()
            deadline = time.monotonic() + seconds
            while not self.target_terminal() and time.monotonic() < deadline: time.sleep(0.05)
        record['terminalVerified'] = self.target_terminal(); self.save()

    def observe_failed_readiness(self, tracer, ready, failed_deadline):
        """Observe an already failed gate; never release emission or qualify it.

        No new process is started. Reserve fifteen seconds of the helper's
        original sixty-second lifetime for the unchanged cleanup path.
        """
        started = time.monotonic()
        deadline = min(failed_deadline + FAILED_READINESS_OBSERVATION_SECONDS,
                       self.helper_launch_started + 45)
        observation = {'diagnosticOnly': True, 'originalGateFailed': True,
                       'startedEpoch': time.time(), 'maximumSeconds': FAILED_READINESS_OBSERVATION_SECONDS,
                       'originalDeadlineMonotonic': failed_deadline,
                       'startedMonotonic': started, 'deadlineMonotonic': deadline,
                       'outcome': 'observing', 'samples': []}
        self.receipt['failedReadinessObservation'] = observation
        try:
            self.save()
            next_sample = started
            while time.monotonic() < deadline:
                self.budget()
                if time.monotonic() >= deadline:
                    observation['outcome'] = 'observation_deadline'
                    break
                code = tracer['process'].poll()
                if code is not None:
                    # The same FD may have a queued token. Do not claim absence
                    # or ordering from observing process termination first.
                    observation.update(outcome='tracer_exited_before_notification_check', exitCode=code,
                                       notificationOrdering='unobserved', exitObservedMonotonic=time.monotonic())
                    break
                if not self.target_valid() or not self.valid(tracer):
                    observation['outcome'] = 'identity_unverified'
                    break
                now = time.monotonic()
                if now >= deadline:
                    observation['outcome'] = 'observation_deadline'
                    break
                if now >= next_sample:
                    observation['samples'].append({'elapsedSeconds': round(now-started, 6),
                        'stdoutBytes': (self.out/'tracer-stdout.log').stat().st_size,
                        'stderrBytes': (self.out/'tracer-stderr.log').stat().st_size})
                    next_sample = now + 1
                    self.save()
                remaining = deadline-time.monotonic()
                if remaining <= 0:
                    observation['outcome'] = 'observation_deadline'
                    break
                if ready.received(min(.25, remaining)):
                    observed = time.monotonic()
                    observation.update(outcome='late_notification' if observed <= deadline else 'notification_after_observation_deadline',
                                       notificationEpoch=time.time(), notificationMonotonic=observed)
                    break
            else:
                observation['outcome'] = 'observation_deadline'
        except BaseException as error:
            observation.update(outcome='diagnostic_error', error=type(error).__name__ + ': ' + str(error)[:1024])
        finally:
            observation['finishedEpoch'] = time.time()
            observation['finishedMonotonic'] = time.monotonic()
            observation['elapsedSeconds'] = round(time.monotonic()-started, 6)
            # A receipt failure must not replace the original readiness failure.
            try: self.save()
            except BaseException as error:
                observation['receiptError'] = type(error).__name__ + ': ' + str(error)[:1024]

    def run(self):
        try:
            self.receipt['simctlLaunchIdentity'] = reviewed_simctl_identity(self.args)
            self.save()
            if self.args.helper.is_symlink() or sha(self.args.helper) != self.args.helper_sha256:
                raise RuntimeError('helper_binary_identity')
            control = Notification('dev.roominthecart.collectorcontrol.notify.' + uuid.uuid4().hex)
            self.notifications.append(control)
            if control.lib.notify_post(control.name.encode()) != 0 or not control.received(2):
                raise RuntimeError('notification_self_control_failed')
            self.receipt['notificationControlPassed'] = True
            ready = Notification('dev.roominthecart.collectorcontrol.start.' + uuid.uuid4().hex)
            self.notifications.append(ready)
            subsystem = 'dev.roominthecart.collectorcontrol.' + uuid.uuid4().hex
            self.receipt.update(subsystem=subsystem, notification=ready.name,
                expected={'category': 'OwnedControl', 'events': ['ControlBefore', 'ControlAfter'],
                          'intervals': ['ControlInterval1', 'ControlInterval2', 'ControlInterval3']})
            self.helper_launch_started = time.monotonic()
            self.target_attempted = True
            wrapper = self.spawn('simctl-spawn', [str(self.args.simctl.resolve()), 'spawn', self.args.simulator,
                str(self.args.helper.resolve()), str(self.out), self.nonce, self.args.simulator, subsystem],
                self.args.simctl_executable, self.args.simctl_executable_sha256)
            self.bind_target(wrapper)
            if not self.target_valid(): raise RuntimeError('helper_changed_before_attach')
            tracer = self.spawn('tracer', [str(self.args.xctrace.resolve()), 'record', '--template', 'Logging',
                '--device', self.args.simulator, '--attach', str(self.target['pid']), '--time-limit', '5s',
                '--output', str(self.out / 'control.trace'), '--notify-tracing-started', ready.name],
                self.args.xctrace, self.args.xctrace_sha256)
            deadline = time.monotonic() + STARTUP_SECONDS
            while tracer['process'].poll() is None and time.monotonic() < deadline:
                self.budget()
                if ready.received(0.05):
                    self.receipt.update(readinessObserved=True, readinessEpoch=time.time()); self.save(); break
            if not self.receipt['readinessObserved']:
                self.receipt['readinessFailureEpoch'] = time.time()
                self.receipt.update(outcome='unqualified', error='RuntimeError: tracing_readiness_missing',
                                    readinessFailureMonotonic=time.monotonic(), readinessDeadlineMonotonic=deadline)
                self.observe_failed_readiness(tracer, ready, deadline)
                raise RuntimeError('tracing_readiness_missing')
            if not self.target_valid() or not self.valid(tracer):
                raise RuntimeError('identity_changed_before_emission')
            self.command('G'); self.receipt['emissionReleasedEpoch'] = time.time(); self.save()
            if self.wait(tracer, FINALIZE_SECONDS) != 0: raise RuntimeError('tracer_failed')
            if not self.target_valid(): raise RuntimeError('helper_exited_before_collector')
            status = self.helper_status()
            self.receipt['helperEmissionStatus'] = status; self.save()
            if not status or status.get('stage') != 'emitted': raise RuntimeError('helper_emission_unconfirmed')
            self.command('Q')
            if self.wait(wrapper, 2) != 0: raise RuntimeError('simctl_spawn_failed')
            if not self.target_terminal(): raise RuntimeError('helper_not_terminal_after_wrapper')
            self.receipt['helperFinalStatus'] = self.helper_status()
            exporter = self.spawn('toc', [str(self.args.xctrace.resolve()), 'export', '--input',
                str(self.out / 'control.trace'), '--toc'], self.args.xctrace, self.args.xctrace_sha256)
            if self.wait(exporter, EXPORT_SECONDS) != 0: raise RuntimeError('toc_export_failed')
            self.receipt['outcome'] = 'exported_pending_event_schema_review'
        except BaseException as error:
            self.receipt['outcome'] = 'unqualified'
            value = type(error).__name__ + ': ' + str(error)
            if 'error' in self.receipt:
                if self.receipt['error'] != value: self.receipt['subsequentError'] = value
            else: self.receipt['error'] = value
        finally:
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            # Finish the collector first; helper ownership does not depend on simctl parenting.
            for item in reversed(self.processes):
                if item['record']['label'] == 'simctl-spawn': continue
                try: self.cleanup(item)
                except BaseException as error: item['record']['cleanupError'] = str(error)
            try: self.cleanup_target()
            except BaseException as error: self.receipt['helperCleanupError'] = str(error)
            for item in self.processes:
                if item['record']['label'] != 'simctl-spawn': continue
                try: self.cleanup(item)
                except BaseException as error: item['record']['cleanupError'] = str(error)
            self.receipt['notificationCancelStatus'] = []
            for notification in self.notifications:
                try: self.receipt['notificationCancelStatus'].append(notification.close())
                except BaseException as error: self.receipt['notificationCancelStatus'].append(str(error))
            self.receipt['allOwnedProcessesTerminal'] = (
                all(p['process'].poll() is not None for p in self.processes) and self.target_terminal())
            if self.target is None and self.target_attempted:
                self.receipt['unboundHelperRisk'] = 'No target PID was bound; no heuristic kill permitted. Helper has a 60-second self deadline if it reached Swift entry.'
            self.receipt['finishedEpoch'] = time.time(); self.save()
        return 1  # Event export and independent schema/count review are deliberately still required.


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('helper', 'simctl', 'xctrace'):
        p.add_argument('--' + name, type=Path, required=True)
        p.add_argument('--' + name + '-sha256', required=True)
    p.add_argument('--simctl-executable', type=Path, required=True)
    p.add_argument('--simctl-executable-sha256', required=True)
    p.add_argument('--simulator', required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    for value in (args.helper_sha256, args.simctl_sha256, args.simctl_executable_sha256, args.xctrace_sha256):
        if len(value) != 64 or any(c not in '0123456789abcdef' for c in value): p.error('Expected reviewed SHA256')
    try: uuid.UUID(args.simulator)
    except ValueError: p.error('Expected explicit simulator UUID')
    def interrupted(signum, frame): raise KeyboardInterrupt('supervisor_signal_' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(SimulatorSupervisor(args).run())


if __name__ == '__main__': main()
