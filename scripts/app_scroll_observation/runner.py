"""Bounded owned tools; SDKROOT override only for reviewed xcodebuild children."""
import os
from pathlib import Path
import subprocess
import time
import shutil
from types import SimpleNamespace
from .owned import Supervisor, Identity
from .support import require, sha
from .contract import verify_tools

class SimulatorSDKRootSpawn:
    # Root-executor override only. All other tools use the unchanged qualified supervisor.
    def spawn(self, label, argv, expected, digest, stdin=False):
        if argv[0] != self.tools['xcodebuild']['path']:
            return super().spawn(label, argv, expected, digest, stdin)
        require(str(expected.resolve()) == self.tools['xcodebuild']['path'] and digest == self.tools['xcodebuild']['sha256'], 'xcodebuild invocation/executable identity mismatch')
        require('-sdk' in argv and Path(argv[argv.index('-sdk') + 1]).resolve() == Path(self.tools["SDKROOT"]), 'xcodebuild command SDK differs from reviewed simulator SDKROOT')
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

class Runner(SimulatorSDKRootSpawn, Supervisor):
    def __init__(self, output, tools, seconds=240, xml_limit=8*1024**2):
        self.out=Path(output);self.out.mkdir(parents=True,exist_ok=False)
        self.tools=tools;verify_tools(tools)
        self.args=SimpleNamespace(xctrace=Path(tools['xctrace']['path']))
        self.identity=Identity();self.processes=[];self.notifications=[];self.started=time.monotonic()
        self.seconds=seconds;self.xml_limit=xml_limit
        self.receipt={'diagnosticOnly':True,'releaseAcceptance':False,'status':'running','tools':tools,'processes':[],
                      'limits':{'wallSeconds':seconds,'xmlBytes':xml_limit,'otherBytes':256*1024**2,'copyBytes':512*1024**2,'files':4096}}
        self.save()
    def budget(self):
        require(time.monotonic()-self.started<=self.seconds,'phase_wall_cap')
        require(shutil.disk_usage(self.out).free>=8*1024**3,'disk_reserve')
        total=copy=count=trace=attachments=0
        for p in self.out.rglob('*'):
            require(not p.is_symlink(),'phase_symlink')
            if p.is_dir():continue
            require(p.is_file(),'phase_nonregular');count+=1;size=p.stat().st_size
            if 'Inspection.xcresult' in p.parts:copy+=size
            else:total+=size
            require(count<=4096 and total<=256*1024**2 and copy<=512*1024**2,'phase_artifact_cap')
            if 'inspection.trace' in p.relative_to(self.out).parts:trace+=size
            if 'attachments' in p.relative_to(self.out).parts:attachments+=size
            require(trace<=128*1024**2 and attachments<=64*1024**2,'phase_trace_or_attachment_cap')
            if p.name=='signposts-stdout.log':require(size<=self.xml_limit,'xml_cap')
            elif p.suffix=='.log':
                cap=16*1024**2 if p.name in ('build-stdout.log','build-stderr.log','Performance.log') else 8*1024**2 if p.name in ('summary-stdout.log','tests-stdout.log','metrics-stdout.log','case-details-stdout.log','case-activities-stdout.log') else 1024**2
                require(size<=cap,'phase_log_cap')
    def command(self,label,key,tail,seconds=30,terminal_query=False):
        require(all(p['process'].poll() is not None for p in self.processes),'previous_tool_not_terminal')
        tool=self.tools[key];started=time.monotonic()
        try:item=self.spawn(label,[tool['path'],*map(str,tail)],Path(tool.get('executable',tool['path'])),tool.get('executableSHA256',tool['sha256']))
        except RuntimeError:
            # Only short read-only inventories/help may finish before live binding. Never signal them.
            allowed=(key=='simctl' and list(tail)[:2]==['list','-j']) or (key=='xctrace' and list(tail)==['list','templates'])
            if not(terminal_query and allowed and self.processes and self.processes[-1]['record']['label']==label and self.processes[-1]['process'].poll() is not None):raise
            item=self.processes[-1];item['record']['terminalQueryBeforeBinding']=True
        try:code=self.wait(item,max(.001,seconds-(time.monotonic()-started)))
        finally:self.cleanup(item)
        require(code==0 and item['record']['signals']==[],label+'_normal_exit');self.budget()
        return self.out/(label+'-stdout.log')
    def finish(self,error=None):
        for item in reversed(self.processes):
            try:self.cleanup(item)
            except BaseException as exc:item['record']['cleanupError']=str(exc)
        self.receipt.update(status='failed' if error else 'passed',error=error,
                            allKnownChildrenTerminal=all(p['process'].poll() is not None for p in self.processes))
        if error:self.receipt['rootAction']='Stop and audit unknown diagnostic descendants; no global kill or automatic retry.'
        self.save()
