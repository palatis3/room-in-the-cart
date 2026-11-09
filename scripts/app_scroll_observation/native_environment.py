"""Native-only environment adapter; ownership/binding/cleanup stays qualified."""
import os
import hashlib
from pathlib import Path
import subprocess
import time
from .support import require, sha

class NativeEnvironmentSpawn:
    def spawn(self, label, argv, expected, digest, stdin=False):
        if label != 'native':
            return super().spawn(label, argv, expected, digest, stdin)
        tool = self.config['tools']['xcodebuild']
        require(argv[0] == tool['path'] and str(expected.resolve()) == tool['path'] and digest == tool['sha256'], 'native_executable_adapter')
        if expected.is_symlink() or not expected.is_file() or sha(expected) != digest:
            raise RuntimeError(label + '_binary_identity')
        record = {'label': label, 'argv': argv, 'executableSHA256': digest,
                  'spawnEpoch': time.time(), 'signals': []}
        stdout = (self.out / (label + '-stdout.log')).open('xb')
        stderr = (self.out / (label + '-stderr.log')).open('xb')
        # Deliberate adapter: ordinary hosted xcodebuild inherits this same environment.
        # Observer values are carried only by the exact derived plan, not new native env settings.
        env = dict(os.environ)
        from performance_plan_provenance import settings
        require(settings(env)==self.config['nativeInvocationSettings'],'native_invoking_settings_drift')
        library_hash=hashlib.sha256(env['DYLD_INSERT_LIBRARIES'].encode()).hexdigest() if 'DYLD_INSERT_LIBRARIES' in env else None
        require(library_hash==self.config['nativeLibraryEnvironmentSHA256'],'native_library_environment_drift')
        record['childEnvironment'] = {'mode': 'ordinary-workflow-inheritance',
            'allowlistedSettings': settings(env), 'otherVariablesInherited': True,
            'observerVariables': 'derived-plan-only',
            'DYLD_INSERT_LIBRARIES': 'present' if 'DYLD_INSERT_LIBRARIES' in env else 'absent'}
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
