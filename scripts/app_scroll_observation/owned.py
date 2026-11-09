#!/usr/bin/env python3
"""Qualified exact-process ownership primitives; importing creates no process or native handle."""
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
    def save(self):
        temporary = self.out / 'receipt.tmp'
        temporary.write_text(json.dumps(self.receipt, indent=2) + '\n')
        temporary.replace(self.out / 'receipt.json')


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


