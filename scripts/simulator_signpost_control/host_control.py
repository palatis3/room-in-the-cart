#!/usr/bin/env python3
"""PREPARED, NOT EXECUTED. Host-only collector control; never qualification by itself."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import time
import uuid

STARTUP_SECONDS = 15
FINALIZE_SECONDS = 15  # Includes the five-second recording after readiness.
EXPORT_SECONDS = 10
MAX_TRACE_BYTES = 64 * 1024 * 1024
MAX_LOG_BYTES = 1024 * 1024
MAX_FILES = 2048


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()


class BSDInfo(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint32) for n in
                ('flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(n, ctypes.c_uint32) for n in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('startSec', ctypes.c_uint64), ('startUsec', ctypes.c_uint64)]


class Identity:
    def __init__(self):
        assert ctypes.sizeof(BSDInfo) == 136
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib')
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidinfo.restype = ctypes.c_int
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_pidpath.restype = ctypes.c_int

    def read(self, pid):
        info, path = BSDInfo(), ctypes.create_string_buffer(4096)
        if self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info): return None
        if self.lib.proc_pidpath(pid, path, len(path)) <= 0: return None
        return {'pid': info.pid, 'parentPID': info.ppid, 'uid': info.uid,
                'startTimeMicros': info.startSec * 1_000_000 + info.startUsec,
                'executable': str(Path(os.fsdecode(path.value)).resolve())}


class Notification:
    def __init__(self, name):
        self.lib = ctypes.CDLL('/usr/lib/system/libsystem_notify.dylib')
        self.lib.notify_register_file_descriptor.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int), ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
        self.lib.notify_register_file_descriptor.restype = ctypes.c_uint32
        self.lib.notify_post.argtypes = [ctypes.c_char_p]; self.lib.notify_post.restype = ctypes.c_uint32
        self.lib.notify_cancel.argtypes = [ctypes.c_int]; self.lib.notify_cancel.restype = ctypes.c_uint32
        fd, token = ctypes.c_int(-1), ctypes.c_int(-1)
        if self.lib.notify_register_file_descriptor(name.encode(), ctypes.byref(fd), 0, ctypes.byref(token)) != 0:
            raise RuntimeError('notification_registration_failed')
        self.fd, self.token, self.name = fd.value, token.value, name
        self.buffer = b''

    def received(self, timeout=0):
        if not select.select([self.fd], [], [], timeout)[0]: return False
        self.buffer += os.read(self.fd, 4 - len(self.buffer))
        if len(self.buffer) != 4: return False
        value, = struct.unpack('!I', self.buffer); self.buffer = b''
        if value != self.token: raise RuntimeError('notification_token_mismatch')
        return True

    def close(self):
        # notify_cancel closes the FD associated with its last registration.
        return self.lib.notify_cancel(self.token)


class Supervisor:
    def __init__(self, args):
        self.args, self.out = args, args.output.resolve()
        self.out.mkdir(parents=True, exist_ok=False)
        self.identity = Identity()
        self.processes, self.notifications = [], []
        self.receipt = {'diagnosticOnly': True, 'releaseAcceptance': False, 'captureQualified': False,
                        'expectedEventsProven': False, 'eventParsing': 'pending_actual_export_schema',
                        'startedEpoch': time.time(), 'readinessObserved': False, 'processes': [],
                        'limits': {'startupSeconds': 15, 'recordSeconds': 5, 'finalizationSeconds': 15,
                                   'exportSeconds': 10, 'cleanupSecondsPerProcess': 7,
                                   'traceBytes': MAX_TRACE_BYTES, 'logBytesEach': MAX_LOG_BYTES,
                                   'files': MAX_FILES}}
        self.receipt['preparedSources'] = {p.name: sha(p) for p in
            (Path(__file__).resolve(), Path(__file__).with_name('SignpostControl.swift'))}
        self.save()

    def save(self):
        temporary = self.out / 'receipt.tmp'
        temporary.write_text(json.dumps(self.receipt, indent=2) + '\n')
        temporary.replace(self.out / 'receipt.json')

    def budget(self):
        total, count = 0, 0
        for folder, dirs, names in os.walk(self.out, followlinks=False):
            for name in [*dirs, *names]:
                path = Path(folder) / name
                if path.is_symlink(): raise RuntimeError('artifact_symlink')
            for name in names:
                count += 1
                if count > MAX_FILES: raise RuntimeError('artifact_file_cap')
                path = Path(folder) / name; size = path.stat().st_size; total += size
                if path.suffix == '.log' and size > MAX_LOG_BYTES: raise RuntimeError('log_cap')
                if total > MAX_TRACE_BYTES: raise RuntimeError('artifact_byte_cap')

    def spawn(self, label, argv, expected, digest, stdin=False):
        if expected.is_symlink() or not expected.is_file() or sha(expected) != digest:
            raise RuntimeError(label + '_binary_identity')
        record = {'label': label, 'argv': argv, 'executableSHA256': digest,
                  'spawnEpoch': time.time(), 'signals': []}
        stdout = (self.out / (label + '-stdout.log')).open('xb')
        stderr = (self.out / (label + '-stderr.log')).open('xb')
        env = {k: os.environ[k] for k in ('HOME', 'TMPDIR', 'USER', 'LOGNAME') if k in os.environ}
        env.update(PATH='/usr/bin:/bin', LANG='en_US.UTF-8', DEVELOPER_DIR=str(self.args.xctrace.resolve().parents[2]))
        process = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
                                   stdout=stdout, stderr=stderr, env=env, cwd=self.out, start_new_session=True)
        item = {'process': process, 'record': record, 'expected': str(expected.resolve()),
                'digest': digest, 'streams': [stdout, stderr], 'binding': None}
        self.processes.append(item); self.receipt['processes'].append(record)
        record['pid'] = process.pid; self.save()
        deadline = time.monotonic() + 2
        while process.poll() is None and time.monotonic() < deadline:
            value = self.identity.read(process.pid)
            if value and value['executable'] == item['expected'] and value['uid'] == os.getuid() and value['parentPID'] == os.getpid():
                if value['startTimeMicros'] < int(record['spawnEpoch'] * 1_000_000):
                    raise RuntimeError(label + '_start_identity')
                item['binding'] = value; record['binding'] = value; self.save(); return item
            time.sleep(0.02)
        record['exitCode'] = process.poll(); self.save()
        raise RuntimeError(label + '_unbound_or_early_exit')

    def valid(self, item):
        if item['process'].poll() is not None: return False
        current = self.identity.read(item['process'].pid)
        return (item['binding'] is not None and current == item['binding']
                and sha(item['expected']) == item['digest'])

    def wait(self, item, seconds):
        deadline = time.monotonic() + seconds
        while item['process'].poll() is None and time.monotonic() < deadline:
            self.budget(); time.sleep(0.05)
        item['record']['exitCode'] = item['process'].poll(); self.save()
        if item['process'].poll() is None: raise RuntimeError(item['record']['label'] + '_deadline')
        return item['process'].returncode

    def cleanup(self, item):
        p, record = item['process'], item['record']
        for sig, seconds in ((signal.SIGINT, 2), (signal.SIGTERM, 3), (signal.SIGKILL, 2)):
            if p.poll() is not None: break
            if not self.valid(item):
                record['cleanupError'] = 'identity_unverified_no_signal'; break
            p.send_signal(sig); record['signals'].append(sig.name); self.save()
            try: p.wait(timeout=seconds)
            except subprocess.TimeoutExpired: pass
        record['exitCode'] = p.poll(); record['terminalVerified'] = p.poll() is not None
        if p.stdin: p.stdin.close()
        for stream in item['streams']: stream.close()
        self.save()

    def run(self):
        try:
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
            helper = self.spawn('helper', [str(self.args.helper.resolve()), subsystem], self.args.helper, self.args.helper_sha256, True)
            if not self.valid(helper): raise RuntimeError('helper_changed_before_attach')
            tracer = self.spawn('tracer', [str(self.args.xctrace.resolve()), 'record', '--template', 'Logging',
                '--attach', str(helper['process'].pid), '--time-limit', '5s', '--output', str(self.out / 'control.trace'),
                '--notify-tracing-started', ready.name], self.args.xctrace, self.args.xctrace_sha256)
            deadline = time.monotonic() + STARTUP_SECONDS
            while tracer['process'].poll() is None and time.monotonic() < deadline:
                self.budget()
                if ready.received(0.05):
                    self.receipt.update(readinessObserved=True, readinessEpoch=time.time()); self.save(); break
            if not self.receipt['readinessObserved']: raise RuntimeError('tracing_readiness_missing')
            if not self.valid(helper) or not self.valid(tracer): raise RuntimeError('identity_changed_before_emission')
            helper['process'].stdin.write(b'G'); helper['process'].stdin.flush()
            self.receipt['emissionReleasedEpoch'] = time.time(); self.save()
            if self.wait(tracer, FINALIZE_SECONDS) != 0: raise RuntimeError('tracer_failed')
            if not self.valid(helper): raise RuntimeError('helper_exited_before_collector')
            helper['process'].stdin.write(b'Q'); helper['process'].stdin.flush()
            if self.wait(helper, 2) != 0: raise RuntimeError('helper_failed')
            exporter = self.spawn('toc', [str(self.args.xctrace.resolve()), 'export', '--input',
                str(self.out / 'control.trace'), '--toc'], self.args.xctrace, self.args.xctrace_sha256)
            if self.wait(exporter, EXPORT_SECONDS) != 0: raise RuntimeError('toc_export_failed')
            self.receipt['outcome'] = 'exported_pending_event_schema_review'
        except BaseException as error:
            self.receipt.update(outcome='unqualified', error=type(error).__name__ + ': ' + str(error))
        finally:
            # Both target and collector are disposable, owned control processes only.
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            for item in reversed(self.processes):
                try: self.cleanup(item)
                except BaseException as error: item['record']['cleanupError'] = type(error).__name__ + ': ' + str(error)
            self.receipt['notificationCancelStatus'] = []
            for notification in self.notifications:
                try: self.receipt['notificationCancelStatus'].append(notification.close())
                except BaseException as error: self.receipt['notificationCancelStatus'].append(type(error).__name__)
            self.receipt['allOwnedProcessesTerminal'] = all(p['process'].poll() is not None for p in self.processes)
            self.receipt['finishedEpoch'] = time.time(); self.save()
        # Deliberately nonzero until actual exported event schema/counts are reviewed.
        return 1


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--helper', type=Path, required=True)
    p.add_argument('--helper-sha256', required=True)
    p.add_argument('--xctrace', type=Path, required=True)
    p.add_argument('--xctrace-sha256', required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    for value in (args.helper_sha256, args.xctrace_sha256):
        if len(value) != 64 or any(c not in '0123456789abcdef' for c in value): p.error('Expected reviewed SHA256')
    def interrupted(signum, frame): raise KeyboardInterrupt('supervisor_signal_' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(Supervisor(args).run())


if __name__ == '__main__': main()
