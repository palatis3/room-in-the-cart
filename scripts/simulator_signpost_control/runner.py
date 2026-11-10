"""Helper-only compiler SDK adapter and exact bounded lifecycle commands."""
import os
from pathlib import Path
import subprocess
import time
from app_scroll_observation.runner import Runner
from app_scroll_observation.support import require, sha, launcher_identity

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

    def lifecycle_check(self, deadline):
        self.budget()
        require(time.monotonic() < deadline, 'helper_lifecycle_deadline')

    def acquire_inventory(self, item, deadline):
        """Only exact read-only inventory shapes: acquire the same owned Popen inside its budget."""
        tool=self.tools['simctl'];process=item['process'];record=item['record'];label=record['label']
        require(record['argv'][0]==tool['path'] and inventory_allowed(record['argv'][1:],self.device),'helper_inventory_acquisition_scope')
        self.lifecycle_check(deadline)
        launcher_identity(tool['path'],tool['sha256'],item['expected'],item['digest'])
        interpreter=str(Path('/bin/bash').resolve())
        diagnostic={'startMonotonic':time.monotonic(),'deadlineMonotonic':deadline,
                    'initialLiveBindingWindowSeconds':2,'samples':0,'first':[],'last':None}
        record['inventoryAcquisition']=diagnostic;self.save();origin=None
        while True:
            self.lifecycle_check(deadline)
            if process.poll() is not None:
                record.update(terminalOwnedCommandBeforeBinding=True,exitCode=process.returncode)
                diagnostic['outcome']='terminal_before_binding';self.save();return item
            value=self.identity.read(process.pid)
            kind='missing' if value is None else 'expected' if value['executable']==item['expected'] else 'interpreter' if value['executable']==interpreter else 'other'
            sample={'monotonic':time.monotonic(),'kind':kind,'identity':value}
            diagnostic['samples']+=1;diagnostic['last']=sample
            diagnostic[kind]=diagnostic.get(kind,0)+1
            if len(diagnostic['first'])<4:diagnostic['first'].append(sample)
            if diagnostic['samples']<=4 or diagnostic['samples']%20==0 or kind=='other':self.save()
            self.lifecycle_check(deadline)
            if process.poll() is not None:continue  # An owned normal exit may race libproc.
            if value is not None:
                require(value['pid']==process.pid and value['parentPID']==os.getpid() and value['uid']==os.getuid()
                        and value['startTimeMicros']>=int(record['spawnEpoch']*1_000_000),label+'_inventory_identity')
                current={k:value[k] for k in ('pid','parentPID','uid','startTimeMicros')}
                require(origin is None or current==origin,label+'_inventory_identity_changed');origin=current
                require(kind in ('expected','interpreter'),label+'_inventory_executable')
                if kind=='expected':
                    require(sha(item['expected'])==item['digest'],label+'_binary_identity')
                    self.lifecycle_check(deadline)
                    if process.poll() is not None:continue
                    latest=self.identity.read(process.pid)
                    if latest!=value:
                        require(process.poll() is not None,label+'_inventory_identity_changed');continue
                    self.lifecycle_check(deadline)
                    item['binding']=value;record['binding']=value
                    diagnostic['outcome']='bound';self.save();return item
            time.sleep(min(.05,max(0,deadline-time.monotonic())))

    def lifecycle_wait(self, item, deadline, diagnostic):
        process=item['process'];next_sample=0
        while True:
            self.lifecycle_check(deadline)
            code=process.poll()
            if code is not None:
                item['record']['exitCode']=code;self.save();return code
            now=time.monotonic()
            if now>=next_sample:
                value=self.identity.read(process.pid)
                sample={'monotonic':now,'epoch':time.time(),'identity':value,
                        'stdoutBytes':(self.out/(item['record']['label']+'-stdout.log')).stat().st_size,
                        'stderrBytes':(self.out/(item['record']['label']+'-stderr.log')).stat().st_size}
                diagnostic['progressSamples']=diagnostic.get('progressSamples',0)+1
                diagnostic['lastProgress']=sample
                first=diagnostic.setdefault('firstProgress',[])
                if len(first)<4:first.append(sample)
                self.save();self.lifecycle_check(deadline)
                if process.poll() is None:require(item['binding'] is not None and value==item['binding'],'helper_lifecycle_identity_changed')
                next_sample=now+1  # No repeated whole-binary hashing during wait.
            time.sleep(min(.05,max(0,deadline-time.monotonic())))

    def lifecycle(self, label, tail, seconds=30, *, absolute_deadline=None):
        require(lifecycle_allowed(tail,self.device),'helper_lifecycle_scope')
        require(all(p['process'].poll() is not None for p in self.processes),'previous_tool_not_terminal')
        tool=self.tools['simctl'];started=time.monotonic();deadline=min(started+seconds,self.started+self.seconds)
        if absolute_deadline is not None:deadline=min(deadline,absolute_deadline)
        diagnostic={'label':label,'startedEpoch':time.time(),'startedMonotonic':started,
                    'commandSeconds':seconds,'deadlineMonotonic':deadline,'phaseDeadlineMonotonic':self.started+self.seconds,
                    'outcome':'spawning'}
        self.receipt.setdefault('lifecycleCommands',[]).append(diagnostic);self.save();item=None
        try:
            self.lifecycle_check(deadline)
            try:item=self.spawn(label,[tool['path'],*tail],Path(tool['executable']),tool['executableSHA256'])
            except RuntimeError as exc:
                require(str(exc)==label+'_unbound_or_early_exit','helper_spawn_identity_failure')
                require(self.processes and self.processes[-1]['record']['label']==label,'helper_spawn_inventory')
                item=self.processes[-1]
                if item['process'].poll() is None:
                    require(inventory_allowed(tail,self.device),'helper_unbound_live_no_signal')
                    item=self.acquire_inventory(item,deadline)
                else:item['record']['terminalOwnedCommandBeforeBinding']=True
            self.lifecycle_check(deadline)
            diagnostic.update(acquiredMonotonic=time.monotonic(),pid=item['process'].pid,outcome='waiting')
            try:code=self.lifecycle_wait(item,deadline,diagnostic)
            finally:self.cleanup(item)
            self.lifecycle_check(deadline)  # No late terminal/output success or fresh timeout after acquisition.
            require(code==0 and not item['record']['signals'],label+'_normal_exit')
            diagnostic['outcome']='normal_exit'
            return self.out/(label+'-stdout.log')
        except BaseException as exc:
            diagnostic.update(outcome='failed',error=type(exc).__name__+': '+str(exc)[:1024]);raise
        finally:
            diagnostic.update(finishedMonotonic=time.monotonic(),finishedEpoch=time.time())
            if item is not None:diagnostic['pid']=item['process'].pid
            self.save()

def inventory_allowed(tail, device):
    if tail in (['list','-j'],['list','-j','runtimes']):return True
    identifier=device.get('createdUDID')
    return bool(identifier) and tail==['list','-j','devices',identifier]

def lifecycle_allowed(tail, device):
    if inventory_allowed(tail,device):return True
    if tail==['create',device['createdName'],device['deviceTypeIdentifier'],device['runtime']['identifier']]:return True
    identifier=device.get('createdUDID')
    return identifier is not None and tail in (["boot",identifier],["bootstatus",identifier,"-b"],
                                                ["shutdown",identifier],["delete",identifier])
