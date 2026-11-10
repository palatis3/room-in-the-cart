"""Helper-only compiler SDK adapter and exact bounded lifecycle commands."""
import os
from pathlib import Path
import subprocess
import time
from app_scroll_observation.runner import Runner
from app_scroll_observation.support import require, sha

class HelperRunner(Runner):
    def spawn(self, label, argv, expected, digest, stdin=False):
        if label != 'helper-compile':
            return super().spawn(label, argv, expected, digest, stdin)
        require(str(expected.resolve()) == self.tools['swift-frontend']['path'] and digest == self.tools['swift-frontend']['sha256'], 'helper compiler invocation/executable identity mismatch')
        require('-sdk' in argv and Path(argv[argv.index('-sdk') + 1]).resolve() == Path(self.tools["SDKROOT"]), 'helper compiler command SDK differs from reviewed simulator SDKROOT')
        require(Path(argv[0]).resolve() == expected.resolve() and Path(argv[0]).name == 'swiftc', 'helper_compiler_driver')
        simulator_sdkroot = self.tools["SDKROOT"]
        if expected.is_symlink() or not expected.is_file() or sha(expected) != digest:
            raise RuntimeError(label + '_binary_identity')
        record = {'label': label, 'argv': argv, 'executableSHA256': digest,
                  'spawnEpoch': time.time(), 'signals': []}
        stdout = (self.out / (label + '-stdout.log')).open('xb')
        stderr = (self.out / (label + '-stderr.log')).open('xb')
        env = {k: os.environ[k] for k in ('HOME', 'TMPDIR', 'USER', 'LOGNAME') if k in os.environ}
        env.update(PATH='/usr/bin:/bin', LANG='en_US.UTF-8', DEVELOPER_DIR=str(self.args.xctrace.resolve().parents[2]))
        env['SDKROOT'] = simulator_sdkroot
        record['childEnvironment'] = {'SDKROOT': env['SDKROOT'], 'DEVELOPER_DIR': env['DEVELOPER_DIR']}
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

    def budget(self):
        super().budget()
        # Prepare/export live under this control's evidence root; cleanup has no captured payload.
        if self.out.name in ('prepare','export'):
            entries=list(self.out.parent.rglob('*'))
            require(len(entries)<=8192 and all(not p.is_symlink() for p in entries),'helper_aggregate_shape')
            require(sum(p.stat().st_size for p in entries if p.is_file())<=512*1024**2,'helper_aggregate_bytes')

    def lifecycle(self, label, tail, seconds=30):
        # A terminal owned Popen proves this command completed; it is never a signal target.
        require(lifecycle_allowed(tail, self.device), 'helper_lifecycle_scope')
        require(all(p['process'].poll() is not None for p in self.processes), 'previous_tool_not_terminal')
        tool=self.tools['simctl']; started=time.monotonic()
        try:
            item=self.spawn(label,[tool['path'],*tail],Path(tool['executable']),tool['executableSHA256'])
        except RuntimeError as exc:
            require(str(exc)==label+'_unbound_or_early_exit','helper_spawn_identity_failure')
            require(self.processes and self.processes[-1]['record']['label']==label,'helper_spawn_inventory')
            item=self.processes[-1]
            require(item['process'].poll() is not None,'helper_unbound_live_no_signal')
            item['record']['terminalOwnedCommandBeforeBinding']=True
        try:code=self.wait(item,max(.001,seconds-(time.monotonic()-started)))
        finally:self.cleanup(item)
        self.budget()
        require(code==0 and not item['record']['signals'],label+'_normal_exit')
        return self.out/(label+'-stdout.log')

def lifecycle_allowed(tail, device):
    if tail==['list','-j']:return True
    if tail==['create',device['createdName'],device['deviceTypeIdentifier'],device['runtime']['identifier']]:return True
    identifier=device.get('createdUDID')
    return identifier is not None and tail in (["boot",identifier],["bootstatus",identifier,"-b"],
                                                ["shutdown",identifier],["delete",identifier])
