"""Helper-only compiler SDK adapter and exact bounded lifecycle commands."""
import os
import hashlib
import stat
import signal
import threading
from pathlib import Path
import subprocess
import time
from app_scroll_observation.runner import Runner
from app_scroll_observation.support import require, sha, launcher_identity

# Exact observed hosted sample bytes/handler, scoped only to optional timeout cleanup.
HANDLED_SIGINT_SAMPLE_SHA256='0527abd95ea1c5a2885489e0d6a76e06c69b66b8a69c7eab4f9276688815791b'
HANDLED_SIGINT_STDERR=b' [Interrupted]\nNot currently sampling -- exiting immediately.\n'

class SampleObservationTimeout(Exception):pass
class SampleStartupReserveExhausted(Exception):pass

INCOMPLETE_REASONS={SampleObservationTimeout:'observation_timeout',
                    SampleStartupReserveExhausted:'post_startup_reserve_exhausted'}

def sample_continuable(sample):
    if not sample:return True
    if sample.get('status')=='passed':return not sample.get('cleanupError')
    if sample.get('status')=='not_needed':
        return (sample.get('reason')=='owned_normal_exit_before_sampler'
                and sample.get('targetExitCode')==0 and sample.get('samplerSpawned') is False)
    return (sample.get('status')=='incomplete' and sample.get('reason') in INCOMPLETE_REASONS.values()
            and sample.get('incompleteSafetyVerified') is True and sample.get('sourceUnchanged') is True
            and sample.get('terminalVerified') is True and sample.get('toolUnchanged') is True
            and not any(sample.get(k) for k in ('cleanupError','toolAfterError','incompleteProofError')))

class HelperRunner(Runner):
    def note(self, event, **details):
        timing=getattr(self,'_sample_timing',None)
        if timing is None:return
        if len(timing['events'])<128:
            timing['events'].append({'event':event,'monotonic':time.monotonic(),**details})
        else:timing['droppedEvents']+=1

    def sample_measure(self, name, function, *args):
        timing=getattr(self,'_sample_timing',None)
        if timing is None:return function(*args)
        started=time.monotonic()
        try:return function(*args)
        finally:
            finished=time.monotonic()
            row=timing['operations'].setdefault(name,{'calls':0,'seconds':0.,'maxSeconds':0.,'firstStart':started})
            row.update(calls=row['calls']+1,seconds=row['seconds']+finished-started,
                       maxSeconds=max(row['maxSeconds'],finished-started),lastEnd=finished)

    def save(self):return self.sample_measure('receipt.save',super().save)
    def budget(self):return self.sample_measure('budget',self.sample_budget_body)

    def sample_observe_outputs(self, paths):
        timing=self._sample_timing
        for path in paths:
            if path.name in timing['firstNonempty']:continue
            try:
                info=path.lstat()
                if stat.S_ISREG(info.st_mode) and info.st_size>0:
                    timing['firstNonempty'][path.name]=time.monotonic()
                    self.note('first_nonempty',file=path.name,bytes=info.st_size)
            except FileNotFoundError:pass
            except OSError as exc:self.note('output_observation_error',file=path.name,error=type(exc).__name__)

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

    def sample_budget_body(self):
        super().budget()
        # Prepare/export live under this control's evidence root; cleanup has no captured payload.
        if self.out.name in ('prepare','export'):
            entries=list(self.out.parent.rglob('*'))
            require(len(entries)<=8192 and all(not p.is_symlink() for p in entries),'helper_aggregate_shape')
            require(sum(p.stat().st_size for p in entries if p.is_file())<=512*1024**2,'helper_aggregate_bytes')

    def lifecycle_check(self, deadline):
        self.budget()
        require(time.monotonic() < deadline, 'helper_lifecycle_deadline')

    def spawn_lifecycle(self, label, tail, deadline):
        """Create one authorized child; acquisition uses the same absolute command budget."""
        require(lifecycle_allowed(tail,self.device),'helper_lifecycle_scope')
        require(all(p['process'].poll() is not None for p in self.processes),'previous_tool_not_terminal')
        self.lifecycle_check(deadline)
        tool=self.tools['simctl'];expected=Path(tool['executable']);digest=tool['executableSHA256']
        launcher_identity(tool['path'],tool['sha256'],str(expected),digest)
        self.lifecycle_check(deadline)
        record={'label':label,'argv':[tool['path'],*tail],'executableSHA256':digest,
                'spawnEpoch':time.time(),'signals':[]}
        stdout=(self.out/(label+'-stdout.log')).open('xb')
        stderr=(self.out/(label+'-stderr.log')).open('xb')
        env={k:os.environ[k] for k in ('HOME','TMPDIR','USER','LOGNAME') if k in os.environ}
        env.update(PATH='/usr/bin:/bin',LANG='en_US.UTF-8',DEVELOPER_DIR=str(self.args.xctrace.resolve().parents[2]))
        try:
            process=subprocess.Popen(record['argv'],stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,
                                     env=env,cwd=self.out,start_new_session=True)
        except BaseException:
            stdout.close();stderr.close();raise
        item={'process':process,'record':record,'expected':str(expected),'digest':digest,
              'streams':[stdout,stderr],'binding':None}
        self.processes.append(item);self.receipt['processes'].append(record)
        record['pid']=process.pid;self.save()
        return item

    def acquisition_allowed(self, item):
        """Waiting is authorized by the exact dispatched command, never by a label exemption."""
        tool=self.tools['simctl'];record=item['record'];argv=record.get('argv',[])
        return (bool(argv) and argv[0]==tool['path'] and lifecycle_allowed(argv[1:],self.device)
                and bool(self.processes) and self.processes[-1] is item
                and sum(p is item for p in self.processes)==1
                and all(p['process'].poll() is not None for p in self.processes[:-1])
                and record.get('pid')==item['process'].pid
                and item['expected']==tool['executable'] and item['digest']==tool['executableSHA256']
                and record.get('executableSHA256')==item['digest'])

    def acquire_lifecycle(self, item, deadline):
        """Acquire the same allowed Popen; the original command/phase deadline never resets."""
        tool=self.tools['simctl'];process=item['process'];record=item['record'];label=record['label']
        require(self.acquisition_allowed(item),'helper_lifecycle_acquisition_scope')
        self.lifecycle_check(deadline)
        launcher_identity(tool['path'],tool['sha256'],item['expected'],item['digest'])
        interpreter=str(Path('/bin/bash').resolve())
        diagnostic={'startMonotonic':time.monotonic(),'deadlineMonotonic':deadline,
                    'samples':0,'first':[],'last':None}
        diagnostic['scope']='same_owned_allowed_lifecycle'
        record['lifecycleAcquisition']=diagnostic;self.save();origin=None
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

    def cleanup_sample(self, item):
        """Sampler-only direct-child custody; executable acceptance never authorizes cleanup."""
        custody=getattr(self,'sample_custody',None)
        require(custody is not None and custody[0] is item and custody[1] is item['process']
                and custody[2]==os.getpid() and item is self.sample_child
                and sum(p is item for p in self.processes)==1,'sample_cleanup_custody')
        process,record=item['process'],item['record']
        if record.get('cleanupLadderComplete'):
            require(process.poll() is not None,'sample_custody_cleanup_not_terminal');return
        record['cleanupAuthority']='retained_direct_Popen_default_SIGCHLD_exclusive_reaper'
        # Only this retained object may reap/signal this child. No PID/group reconstruction,
        # libproc dependency, or tool-hash condition can strand our own sampler.
        for sig,seconds in ((signal.SIGINT,2),(signal.SIGTERM,3),(signal.SIGKILL,2)):
            if process.poll() is not None:break
            attempt={'signal':sig.name,'waitSeconds':seconds}
            record.setdefault('signalAttempts',[]).append(attempt)
            try:
                self.note('sampler_signal_before',signal=sig.name)
                process.send_signal(sig);record['signals'].append(sig.name)
                # Popen may skip os.kill if it discovers an already-reaped child.
                self.note('sampler_signal_returned',signal=sig.name)
                live=process.poll() is None
                attempt['delivery']='returned_while_unreaped' if live else 'terminal_observed_after_send'
                if sig==signal.SIGKILL:
                    record['fatalSignalRequestReturned']=True
                    record['fatalSignalDelivered']=live
            except BaseException as exc:
                attempt['deliveryError']=type(exc).__name__+': '+str(exc)[:256]
                self.save();continue
            self.save()
            self.note('sampler_wait_before',seconds=seconds)
            try:process.wait(timeout=seconds);attempt['waitOutcome']='terminal'
            except subprocess.TimeoutExpired:attempt['waitOutcome']='timeout'
            except BaseException as exc:attempt['waitError']=type(exc).__name__+': '+str(exc)[:256]
            self.note('sampler_wait_after',outcome=attempt.get('waitOutcome'),error=attempt.get('waitError'))
            self.save()
        record['cleanupLadderComplete']=True
        record['exitCode']=process.poll();record['terminalVerified']=process.poll() is not None
        for stream in item['streams']:stream.close()
        self.save();require(record['terminalVerified'],'sample_custody_cleanup_not_terminal')

    def cleanup(self, item):
        if item is getattr(self,'sample_child',None):return self.cleanup_sample(item)
        # Do not reap/signal the target until our sampler is terminal.
        sample=getattr(self,'sample_child',None)
        if item is getattr(self,'sample_target',None) and sample is not None:
            self.cleanup_sample(sample)
        return super().cleanup(item)

    def finish(self, error=None):
        sample=getattr(self,'sample_child',None)
        if sample is not None:self.cleanup_sample(sample)
        return super().finish(error)

    def sample_policy(self, target):
        """Closed target/threshold table; bootstatus additionally requires normal owned boot."""
        tool=self.tools['simctl'];record=target['record'];argv=record.get('argv',[])
        if (sum(p is target for p in self.processes)!=1 or record.get('pid')!=target['process'].pid
                or target.get('expected')!=tool['executable'] or target.get('digest')!=tool['executableSHA256']):return None
        if record.get('label')=='booted-runtimes' and argv==[tool['path'],'list','-j','runtimes']:
            return (10,'booted-runtimes')
        identifier=self.device.get('createdUDID')
        if not identifier or record.get('label')!='bootstatus' or argv!=[tool['path'],'bootstatus',identifier,'-b']:
            return None
        boots=[p for p in self.processes if p['record'].get('label')=='boot']
        phases=[p for p in self.receipt.get('lifecycleCommands',[]) if p.get('label')=='boot']
        if len(boots)!=1 or len(phases)!=1:return None
        previous=boots[0];proof=previous['record'];binding=proof.get('binding')
        normal=(previous['process'].poll()==0 and proof.get('exitCode')==0 and proof.get('terminalVerified') is True
                and proof.get('signals')==[] and proof.get('argv')==[tool['path'],'boot',identifier]
                and proof.get('executableSHA256')==tool['executableSHA256']
                and proof.get('pid')==previous['process'].pid==phases[0].get('pid')
                and phases[0].get('outcome')=='normal_exit')
        if not normal:return None
        if binding is None:
            if proof.get('terminalOwnedCommandBeforeBinding') is not True:return None
        elif not (binding.get('pid')==proof['pid'] and binding.get('parentPID')==os.getpid()
                  and binding.get('uid')==os.getuid() and binding.get('executable')==tool['executable']
                  and binding.get('startTimeMicros',0)>=int(proof['spawnEpoch']*1_000_000)):
            return None
        return (150,'bootstatus')

    def sample_target_live(self, target):
        """Only a contemporaneous owned exit0 makes an unstarted sample unnecessary."""
        process=target['process'];code=process.poll()
        if code is not None:
            require(code==0,'sample_target_exit');return False
        value=self.sample_measure('identity.read',self.identity.read,process.pid)
        if target['binding'] is None or value!=target['binding']:
            code=process.poll()  # An owned exit may race the libproc read.
            if code is not None:
                require(code==0,'sample_target_exit');return False
            raise ValueError('sample_target_identity')
        return True

    def sample_live_identity(self, target, child, observe_child=True):
        # Never poll/reap the target while a sampler may still act on its numeric PID.
        require(target['binding'] is not None and
                self.sample_measure('identity.read',self.identity.read,target['process'].pid)==target['binding'],
                'sample_target_identity')
        if not observe_child:return
        process=child['process'];record=child['record']
        if process.poll() is not None:return
        value=self.sample_measure('identity.read',self.identity.read,process.pid)
        if process.poll() is not None:return
        require(value is not None,'sample_child_identity_missing')
        if value is not None:
            require(value['pid']==process.pid and value['parentPID']==os.getpid() and value['uid']==os.getuid()
                    and value['startTimeMicros']>=int(record['spawnEpoch']*1_000_000)
                    and value['executable']==child['expected'],'sample_child_identity')
            require(child['binding'] is None or value==child['binding'],'sample_child_identity_changed')
            if child['binding'] is None:self.note('sampler_first_binding',pid=process.pid)
            child['binding']=value;record['binding']=value

    def sample_observation_check(self, deadline, stop):
        self.lifecycle_check(deadline)  # Original/phase expiry can never become optional.
        if time.monotonic()>=stop:raise SampleObservationTimeout('sample_observation_deadline')

    def sample_termination_classification(self, child, output, report):
        record=child['record'];code=record.get('exitCode')
        delivered=[attempt['signal'] for attempt in record.get('signalAttempts',[])
                   if attempt.get('delivery') in ('returned_while_unreaped','terminal_observed_after_send')]
        if code==0:return 'normal_exit'
        if any(code==-int(getattr(signal,name)) for name in delivered):return 'signal_exit'
        # An exact observed SIGINT handler exits1; this is not generic nonzero admission.
        binding=child.get('binding') or {};tool=report.get('tool',{})
        require(code==1 and report.get('reason')=='observation_timeout'
                and child.get('expected')=='/usr/bin/sample' and binding.get('executable')=='/usr/bin/sample'
                and record.get('binding')==binding and binding.get('pid')==child['process'].pid
                and binding.get('parentPID')==os.getpid() and binding.get('uid')==os.getuid()
                and binding.get('startTimeMicros',0)>=int(record['spawnEpoch']*1_000_000)
                and child.get('digest')==record.get('executableSHA256')==tool.get('sha256')==HANDLED_SIGINT_SAMPLE_SHA256
                and tool.get('bytes')==272528 and tool.get('mode')==0o755 and tool.get('uid')==0
                and report.get('toolUnchanged') is True and record.get('terminalVerified') is True
                and record.get('cleanupLadderComplete') is True and record.get('signals')==['SIGINT']
                and record.get('signalAttempts')==[{'signal':'SIGINT','waitSeconds':2,
                    'delivery':'returned_while_unreaped','waitOutcome':'terminal'}],
                'sample_incomplete_unexpected_exit')
        require(record['label'] in ('bootstatus-stack-sample','runtime-stack-sample')
                and not output.exists() and not output.is_symlink() and 'reportSHA256' not in report,
                'sample_handled_sigint_report_or_scope')
        for suffix,expected in (('stdout',b''),('stderr',HANDLED_SIGINT_STDERR)):
            path=self.out/(record['label']+'-'+suffix+'.log');before=path.lstat()
            require(stat.S_ISREG(before.st_mode) and before.st_size==len(expected),'sample_handled_sigint_stream_shape')
            with path.open('rb') as stream:raw=stream.read(len(expected)+1)
            after=path.lstat()
            require(raw==expected and (before.st_dev,before.st_ino,before.st_mode,before.st_size,before.st_mtime_ns)==
                    (after.st_dev,after.st_ino,after.st_mode,after.st_size,after.st_mtime_ns),'sample_handled_sigint_stream_bytes')
        report['handledSIGINTStderrSHA256']=hashlib.sha256(HANDLED_SIGINT_STDERR).hexdigest()
        return 'handled_sigint_exit1'

    def verify_incomplete_sample(self, target, child, output, deadline, report):
        custody=getattr(self,'sample_custody',None)
        require(child is not None and custody is not None and custody[0] is child
                and custody[1] is child['process'] and custody[2]==os.getpid()
                and child is self.sample_child and sum(p is child for p in self.processes)==1,
                'sample_incomplete_custody')
        unobserved_reserve=(report.get('reason')=='post_startup_reserve_exhausted'
                           and report.get('samplerBindingStatus')=='not_observed_reserve_exhausted'
                           and child['binding'] is None)
        require(unobserved_reserve or (child['binding'] is not None
                and child['record'].get('binding')==child['binding']),'sample_incomplete_missing_binding')
        require(report.get('terminalVerified') is True and not report.get('cleanupError')
                and report.get('toolUnchanged') is True and not report.get('toolAfterError'),
                'sample_incomplete_custody_or_tool')
        report['terminationClassification']=self.sample_termination_classification(child,output,report)
        self.lifecycle_check(deadline)
        if output.exists() or output.is_symlink():
            require(output.is_file() and not output.is_symlink() and output.stat().st_size<=2*1024**2,'sample_output_cap')
        require(sha(target['expected'])==target['digest'],'sample_target_binary')
        require(target['binding'] is not None and self.sample_measure('identity.read',self.identity.read,target['process'].pid)==target['binding'],
                'sample_target_identity')
        checker=getattr(self,'sample_source_check',None)
        require(callable(checker),'sample_incomplete_source_check_required');checker()
        report['sourceUnchanged']=True
        self.lifecycle_check(deadline)
        report['incompleteSafetyVerified']=True

    def sample_runtime(self, target, deadline, diagnostic):
        """One diagnostic sample of an exact admitted lifecycle target; no timing reset."""
        report={'status':'starting','startedMonotonic':time.monotonic(),
                'targetPID':target['process'].pid,'durationSeconds':1,'samplerObservationSeconds':3,'cleanupReserveSeconds':7,
                'originalDeadlineMonotonic':deadline,
                'reportBytesLimit':2*1024**2,'samplerSpawned':False,'identityPolicy':'observed_root_owned_system_tool_before_after'}
        timing={'events':[],'operations':{},'firstNonempty':{},'droppedEvents':0}
        report['timing']=timing;self._sample_timing=timing
        self.note('sample_started')
        diagnostic['stackSample']=report;self.save();child=None;incomplete_reason=None;tool=Path('/usr/bin/sample')
        try:
            require(signal.getsignal(signal.SIGCHLD)==signal.SIG_DFL and threading.active_count()==1,'sample_exclusive_reaper_required')
            policy=self.sample_policy(target);require(policy is not None,'sample_target_scope')
            stem=policy[1];report.update(targetLabel=stem,triggerAfterSeconds=policy[0])
            if not self.sample_target_live(target):
                report.update(status='not_needed',reason='owned_normal_exit_before_sampler',targetExitCode=0);return
            self.note('target_hash_before')
            require(sha(target['expected'])==target['digest'],'sample_target_binary')
            self.note('target_hash_after')
            self.lifecycle_check(deadline)
            self.note('sampler_tool_observation_before')
            info=tool.lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_uid==0 and not info.st_mode&0o6022
                    and tool.resolve()==tool and 0<info.st_size<=16*1024**2,'sample_system_tool_shape')
            observed={'sha256':sha(tool),'bytes':info.st_size,'mode':stat.S_IMODE(info.st_mode),
                      'uid':info.st_uid,'device':info.st_dev,'inode':info.st_ino,'mtimeNS':info.st_mtime_ns}
            report['tool']={'path':str(tool),**observed}
            self.note('sampler_tool_observation_after')
            self.lifecycle_check(deadline)
            output=self.out/(stem+'-stack.txt');require(not output.exists(),'sample_output_exists')
            # Reserve original budget for the existing bounded terminal cleanup ladder.
            require(deadline-time.monotonic()>10,'sample_remaining_budget')
            if not self.sample_target_live(target):
                report.update(status='not_needed',reason='owned_normal_exit_before_sampler',targetExitCode=0);return
            sample_label='runtime-stack-sample' if stem=='booted-runtimes' else 'bootstatus-stack-sample'
            record={'label':sample_label,'argv':[str(tool),str(target['process'].pid),'1','-file',str(output)],
                    'executableSHA256':observed['sha256'],'spawnEpoch':time.time(),'signals':[]}
            self.note('sampler_output_open_before')
            stdout=(self.out/(sample_label+'-stdout.log')).open('xb')
            stderr=(self.out/(sample_label+'-stderr.log')).open('xb')
            self.note('sampler_output_open_after')
            observed_outputs=(Path(stdout.name),Path(stderr.name),output)
            env={k:os.environ[k] for k in ('HOME','TMPDIR','USER','LOGNAME') if k in os.environ}
            env.update(PATH='/usr/bin:/bin',LANG='en_US.UTF-8')
            require(signal.getsignal(signal.SIGCHLD)==signal.SIG_DFL and threading.active_count()==1,'sample_exclusive_reaper_required')
            report['reaperPolicy']='default_SIGCHLD_single_thread_no_external_waiter'
            self.note('sampler_popen_before')
            try:process=subprocess.Popen(record['argv'],stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,
                                         env=env,cwd=self.out,start_new_session=True)
            except BaseException:stdout.close();stderr.close();raise
            self.note('sampler_popen_after',pid=process.pid)
            child={'process':process,'record':record,'expected':str(tool),'digest':observed['sha256'],
                   'streams':[stdout,stderr],'binding':None}
            report['samplerSpawned']=True
            self.sample_child=child;self.sample_target=target
            self.sample_custody=(child,process,os.getpid())
            self.processes.append(child);self.receipt['processes'].append(record)
            record['pid']=process.pid;self.save()
            report['registeredMonotonic']=time.monotonic();self.note('sampler_registered')
            self.lifecycle_check(deadline)
            self.sample_live_identity(target,child,observe_child=False)
            self.lifecycle_check(deadline)
            if deadline-time.monotonic()<=10:
                report['samplerBindingStatus']='not_observed_reserve_exhausted'
                raise SampleStartupReserveExhausted('sample_post_startup_reserve_exhausted')
            stop=time.monotonic()+3
            report['observationDeadlineMonotonic']=stop
            require(stop<deadline-7,'sample_cleanup_reserve')
            self.note('sampler_deadline_set',deadline=stop)
            while process.poll() is None:
                self.sample_observation_check(deadline,stop)
                self.sample_observe_outputs(observed_outputs)
                if output.exists():require(output.is_file() and not output.is_symlink() and output.stat().st_size<=2*1024**2,'sample_output_cap')
                self.sample_live_identity(target,child)
                time.sleep(min(.05,max(0,stop-time.monotonic())))
            self.note('sampler_terminal_observed',exitCode=process.returncode)
            self.sample_observe_outputs(observed_outputs)
            self.sample_observation_check(deadline,stop)
            require(process.returncode==0,'sample_exit')
            require(output.is_file() and not output.is_symlink() and 0<output.stat().st_size<=2*1024**2,'sample_output_cap')
            after=tool.lstat()
            require(observed=={'sha256':sha(tool),'bytes':after.st_size,'mode':stat.S_IMODE(after.st_mode),
                    'uid':after.st_uid,'device':after.st_dev,'inode':after.st_ino,'mtimeNS':after.st_mtime_ns},'sample_tool_changed')
            require(target['process'].poll() is None and self.sample_measure('identity.read',self.identity.read,target['process'].pid)==target['binding']
                    and sha(target['expected'])==target['digest'],'sample_target_after_identity')
            self.lifecycle_check(deadline)
            report.update(status='passed',reportSHA256=sha(output),reportBytes=output.stat().st_size)
        except (SampleObservationTimeout,SampleStartupReserveExhausted) as exc:
            reason=INCOMPLETE_REASONS[type(exc)]
            self.note('sample_failure',error=type(exc).__name__+': '+str(exc)[:256])
            report.update(status='failed',error=type(exc).__name__+': '+str(exc)[:256],reason=reason)
            try:
                self.sample_live_identity(target,child,observe_child=reason!='post_startup_reserve_exhausted')
                incomplete_reason=reason
            except BaseException as proof_error:
                report['incompleteProofError']=type(proof_error).__name__+': '+str(proof_error)[:256]
        except BaseException as exc:
            self.note('sample_failure',error=type(exc).__name__+': '+str(exc)[:256])
            report.update(status='failed',error=type(exc).__name__+': '+str(exc)[:256])
        finally:
            if child is not None:
                try:self.cleanup(child)
                except BaseException as exc:report['cleanupError']=type(exc).__name__+': '+str(exc)[:256]
                report['terminalVerified']=child['process'].poll() is not None
                self.sample_observe_outputs(observed_outputs)
            if 'tool' in report:
                try:
                    after=tool.lstat()
                    require(stat.S_ISREG(after.st_mode) and after.st_uid==0 and not after.st_mode&0o6022
                            and tool.resolve()==tool and 0<after.st_size<=16*1024**2,'sample_system_tool_shape')
                    report['toolAfterSHA256']=sha(tool)
                    report['toolUnchanged']=(observed=={'sha256':report['toolAfterSHA256'],'bytes':after.st_size,
                        'mode':stat.S_IMODE(after.st_mode),'uid':after.st_uid,'device':after.st_dev,
                        'inode':after.st_ino,'mtimeNS':after.st_mtime_ns})
                    require(report['toolUnchanged'],'sample_tool_changed')
                except BaseException as exc:
                    report['toolAfterError']=type(exc).__name__+': '+str(exc)[:256];report['status']='failed'
            if incomplete_reason is not None:
                try:
                    self.verify_incomplete_sample(target,child,output,deadline,report)
                    report['status']='incomplete'
                except BaseException as exc:
                    report['incompleteProofError']=type(exc).__name__+': '+str(exc)[:256]
                    report['status']='failed'
            self.note('sampler_after_verification')
            report['finishedMonotonic']=time.monotonic();self.save()
            self._sample_timing=None

    def lifecycle_wait(self, item, deadline, diagnostic):
        process=item['process'];next_sample=0
        while True:
            self.lifecycle_check(deadline)
            code=process.poll()
            if code is not None:
                item['record']['exitCode']=code;self.save();return code
            now=time.monotonic()
            policy=self.sample_policy(item) if not getattr(self,'sample_attempted',False) else None
            if (policy is not None and now-diagnostic['startedMonotonic']>=policy[0]
                    and (self.out/(policy[1]+'-stdout.log')).stat().st_size==0
                    and (self.out/(policy[1]+'-stderr.log')).stat().st_size==0):
                self.sample_attempted=True  # One total attempt, even if sampling itself fails.
                self.sample_runtime(item,deadline,diagnostic)
                require(getattr(self,'sample_child',None) is None or self.sample_child['process'].poll() is not None,'sample_not_terminal')
                self.lifecycle_check(deadline)
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
            item=self.spawn_lifecycle(label,tail,deadline)
            self.acquire_lifecycle(item,deadline)
            self.lifecycle_check(deadline)
            diagnostic.update(acquiredMonotonic=time.monotonic(),pid=item['process'].pid,outcome='waiting')
            try:code=self.lifecycle_wait(item,deadline,diagnostic)
            finally:self.cleanup(item)
            self.lifecycle_check(deadline)  # No late terminal/output success or fresh timeout after acquisition.
            require(code==0 and not item['record']['signals'],label+'_normal_exit')
            diagnostic['outcome']='normal_exit';diagnostic['commandOutcome']='normal_exit'
            sample=diagnostic.get('stackSample',{})
            require(sample_continuable(sample),'runtime_stack_sample_failed')
            if sample.get('status')=='incomplete':
                require(item.get('binding') is not None and item['record'].get('terminalVerified') is True
                        and not item['record'].get('cleanupError'),'sample_original_command_custody')
                self.lifecycle_check(deadline)
                sample['originalCommandVerified']=True
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
