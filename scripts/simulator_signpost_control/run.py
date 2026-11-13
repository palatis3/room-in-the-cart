"""One manual standalone helper transport control. No application or XCTest commands."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import signal
import time
from types import SimpleNamespace
import uuid
from app_scroll_observation import archive
from app_scroll_observation.contract import (ROOT, frozen, read, tools, tool_inventory, verify_tools,
                                            selected_snapshot, snapshot, copy_snapshot, HOSTED_TOOL_PROFILE)
from app_scroll_observation.producer import verify_logging_template
from app_scroll_observation.support import require, sha, atomic_json
from boot_ios_simulator import MIGRATION_FAILED
from select_ci_iphone import owner_identity, owned_name, select_iphone
from .runner import HelperRunner
from .control import SimulatorSupervisor
from .validate import validate_run, validate_events, SELECTOR

RUNTIME='com.apple.CoreSimulator.SimRuntime.iOS-27-0'
BOOT_PREPARATION_SECONDS=240  # Helper-only prospective cold-boot infrastructure allowance.
POST_BOOT_VERIFICATION_RESERVE_SECONDS=30
MIXED=('ENFORCE_BASELINES','OBSERVE_APP_SCROLL_SIGNPOSTS','CAPTURE_SCROLL_SIGNPOSTS',
       'CAPTURE_PREFLIGHT_ONLY','ENABLE_PERFORMANCE_DIAGNOSTICS','FRESH_PERFORMANCE_SIMULATOR')

def direct_inventory_requested(env):
    flag=env.get('SIMULATOR_HELPER_DIRECT_INVENTORY','false')
    require(flag in ('true','false'),'helper_direct_inventory_boolean')
    if flag=='false':return False
    require(env.get('SIMULATOR_SIGNPOST_CONTROL')=='true'
            and env.get('GITHUB_EVENT_NAME')=='workflow_dispatch'
            and env.get('GITHUB_ACTIONS')=='true' and env.get('RUNNER_OS')=='macOS',
            'helper_direct_inventory_hosted_only')
    return True

def validate_request(env):
    direct_inventory_requested(env)  # Plan-time opt-in; never a failure fallback.
    flag=env.get('SIMULATOR_SIGNPOST_CONTROL','false')
    require(flag in ('true','false'),'helper_boolean')
    if flag=='false':return False
    require(env.get('GITHUB_EVENT_NAME')=='workflow_dispatch','helper_manual_only')
    require(env.get('REQUESTED_PERFORMANCE_CASE','')=='','helper_case_all_only')
    require(all(env.get(k,'false')=='false' for k in MIXED),'helper_mixed_mode')
    return True

def runtime(inventory):
    rows=[r for r in inventory['runtimes'] if r['identifier']==RUNTIME]
    require(len(rows)==1 and rows[0].get('isAvailable') is True,'helper_runtime_inventory')
    row=rows[0]
    require(row['version']=='27.0' and row['buildversion']=='24A434','helper_exact_runtime')
    require(isinstance(row.get('bundlePath'),str) and Path(row['bundlePath']).is_absolute(),'helper_runtime_path')
    return {k:row[k] for k in ('identifier','version','buildversion','bundlePath')}

def current_device(inventory, device, state=None, absent=False):
    require(runtime(inventory)==device['runtime'],'helper_runtime_changed')
    rows=[(r,d) for r,ds in inventory['devices'].items() for d in ds if d['udid']==device['createdUDID']]
    if absent:require(not rows,'helper_delete_not_verified');return None
    require(len(rows)==1,'helper_device_missing_or_ambiguous');r,d=rows[0]
    require(r==RUNTIME and d.get('name')==device['createdName'] and d.get('isAvailable') is True
            and d.get('deviceTypeIdentifier')==device['deviceTypeIdentifier'],'helper_device_identity')
    if state:require(d.get('state')==state,'helper_device_state')
    return d

def verify_scoped_device(runner, device, label, state=None, absent=False):
    """Fresh runtime + exact UUID listing; both commands share the original 30 seconds."""
    deadline=min(time.monotonic()+30,runner.started+runner.seconds)
    runner.lifecycle_check(deadline)
    runtimes=read(runner.lifecycle(label+'-runtimes',['list','-j','runtimes'],absolute_deadline=deadline))
    require(set(runtimes)=={'runtimes'},'helper_runtime_inventory_shape')
    require(runtime(runtimes)==device['runtime'],'helper_runtime_changed')
    runner.lifecycle_check(deadline)
    devices=read(runner.lifecycle(label+'-device',['list','-j','devices',device['createdUDID']],absolute_deadline=deadline))
    require(set(devices)=={'devices'},'helper_device_inventory_shape')
    rows=[d for group in devices['devices'].values() for d in group]
    require((not rows) if absent else (len(rows)==1 and rows[0].get('udid')==device['createdUDID']),
            'helper_delete_not_verified' if absent else 'helper_scoped_device_ambiguity')
    # The public filter is substring matching, not authorization. Reuse exact equality,
    # uniqueness, name/type/runtime/state and availability gates on fresh returned rows.
    value=current_device({**runtimes,**devices},device,state,absent)
    runner.lifecycle_check(deadline)
    return value

def verify_post_boot_device(runner, device):
    # One fresh response proves both runtime and owned device after normal boot.
    # Keep cleanup scoped; this avoids a second post-boot process startup only.
    deadline=min(time.monotonic()+30,runner.started+runner.seconds)
    runner.lifecycle_check(deadline)
    listing=read(runner.lifecycle('booted-inventory',['list','-j'],absolute_deadline=deadline))
    require(set(listing)=={'devicetypes','runtimes','devices','pairs'},'helper_combined_inventory_shape')
    value=current_device(listing,device,'Booted')
    runner.lifecycle_check(deadline)
    return value

def wait_for_boot(runner, device, shutdown_inventory):
    # Boot and monitor once, only after the immediately preceding owned-device proof.
    current_device(shutdown_inventory,device,'Shutdown')
    # Keep the original total prepare budget; boot cannot consume the final
    # verification reserve. This is infrastructure calibration, not a transport gate.
    deadline=min(time.monotonic()+BOOT_PREPARATION_SECONDS,
                 runner.started+runner.seconds-POST_BOOT_VERIFICATION_RESERVE_SECONDS)
    runner.lifecycle_check(deadline)  # Exhaustion must fail before launching a child.
    return runner.lifecycle('bootstatus',['bootstatus',device['createdUDID'],'-b'],
                            BOOT_PREPARATION_SECONDS,absolute_deadline=deadline)

def verify_boot_output(stdout, stderr):
    # Same public boot guard as boot_ios_simulator.py; raw streams remain separate and unchanged.
    require(len(stdout)<=1024**2 and len(stderr)<=1024**2,'helper_boot_log_cap')
    for raw in (stdout,stderr):
        for line in raw.decode('utf-8',errors='replace').splitlines():
            require(line.strip()!='Data Migration Failed' and not MIGRATION_FAILED.match(line),'helper_boot_migration_failed')

def terminal_capture(receipt):
    require(receipt.get('allOwnedProcessesTerminal') is True and not receipt.get('unboundHelperRisk'),'helper_capture_not_terminal')
    require(all(p.get('terminalVerified') is True for p in receipt['processes']),'helper_child_not_terminal')

def compile_args(tool, source, binary):
    swiftc=Path(tool['swift-frontend']['path']).with_name('swiftc')
    require(swiftc.resolve()==Path(tool['swift-frontend']['path']) and sha(swiftc)==tool['swift-frontend']['sha256'],'helper_swiftc_driver_binding')
    return [str(swiftc),'-sdk',tool['SDKROOT'],'-target','arm64-apple-ios17.0-simulator',str(source),'-o',str(binary)]

def sampler_summary(receipt):
    attempts=[d['stackSample'] for d in receipt.get('lifecycleCommands',[]) if 'stackSample' in d]
    rows=[{k:s[k] for k in ('status','reason','error','cleanupError','incompleteProofError','terminalVerified','originalCommandVerified','terminationClassification') if k in s} for s in attempts]
    return {'samplerDiagnosticsComplete':all(s.get('status') in ('passed','not_needed') for s in attempts),
            'samplerDiagnostics':{'attempted':bool(attempts),'attempts':rows}}

def run(output, developer):
    output=Path(output).resolve();output.mkdir(parents=True,exist_ok=False)
    result={'diagnosticOnly':True,'releaseAcceptance':False,'helperTransportQualified':False,
            'scope':'Standalone simulator helper only; no app observation, XCTest, baseline, or implicit warm-up.',
            'startedEpoch':time.time(),'stage':'request','processesStarted':False}
    runner=None;preparation_runner=None;error=None
    try:
        require(validate_request(os.environ),'helper_opt_in_required')
        require(platform.machine()=='arm64','helper_arm64_host')
        result['stage']='source-contract';expected=frozen()
        sources=selected_snapshot(ROOT,expected['files'])
        atomic_json(output/'sources.json',sources)
        result['contractSHA256']=sha(ROOT/'scripts/app_scroll_observation/contract.json')
        result['stage']='tool-inventory';inventory=tool_inventory(developer,expected)
        atomic_json(output/'identity-inventory.json',inventory)
        require(inventory['complete'],'helper_tool_inventory_incomplete')
        result['stage']='exact-tool-admission';tool=tools(developer)
        require(tool['toolProfile']==HOSTED_TOOL_PROFILE,'helper_reviewed_hosted_profile_required')
        result['tools']=tool;result['stage']='prerequisites'
        runner=HelperRunner(output/'prepare',tool,300,1024**2);runner.device={}
        preparation_runner=runner
        result['postBootInventoryRoute']='supported_launcher_unsampled_diagnostic'
        runner.receipt['postBootInventoryRoute']='supported_launcher_unsampled_diagnostic'
        result['postBootInventorySampling']='disabled_one_factor_diagnostic'
        runner.receipt['postBootInventorySampling']='disabled_one_factor_diagnostic'
        def check_sample_sources():
            # Exact bytes/modes, but only after target teardown. Check the existing
            # preparation bound between files rather than one uninterrupted 50-file pass.
            for name,digest in sources['files'].items():
                preparation_runner.budget()
                require(selected_snapshot(ROOT,[name])=={'files':{name:digest},'modes':{name:sources['modes'][name]}},
                        'helper_sampler_sources_changed')
                preparation_runner.budget()
            require(sha(ROOT/'scripts/app_scroll_observation/contract.json')==result['contractSHA256'],'helper_sampler_contract_changed')
            preparation_runner.budget()
        runner.sample_source_check=check_sample_sources
        result['processesStarted']=True
        template=runner.command('templates','xctrace',['list','templates'],10,terminal_query=True)
        result['template']=verify_logging_template(template.read_bytes())
        listing=read(runner.command('inventory','simctl',['list','-j'],30,terminal_query=True))
        if direct_inventory_requested(os.environ):runner.enable_direct_inventory(inventory)
        rt=runtime(listing);_,source_device=select_iphone(listing['devices'],RUNTIME,'iPhone 17')
        require(source_device.get('deviceTypeIdentifier')=='com.apple.CoreSimulator.SimDeviceType.iPhone-17','helper_exact_device_type')
        owner=owner_identity();nonce=str(uuid.uuid4())
        device={'owner':owner,'nonce':nonce,'createdName':owned_name(owner,nonce),'runtime':rt,
                'deviceTypeIdentifier':source_device['deviceTypeIdentifier'],'sourceUDID':source_device['udid'],
                'initialUDIDs':[d['udid'] for ds in listing['devices'].values() for d in ds], 'creation':'pending'}
        runner.device=device
        result['stage']='compile'
        source=Path(__file__).with_name('SignpostControl.swift');binary=output/'prepare/SignpostControl'
        argv=compile_args(tool,source,binary)
        item=runner.spawn('helper-compile',argv,Path(tool['swift-frontend']['path']),tool['swift-frontend']['sha256'])
        try:code=runner.wait(item,120)
        finally:runner.cleanup(item)
        runner.budget();require(code==0 and not item['record']['signals'],'helper_compile_normal_exit')
        require(all((runner.out/('helper-compile-'+s+'.log')).stat().st_size==0 for s in ('stdout','stderr')),'helper_compile_diagnostics')
        require(binary.is_file() and not binary.is_symlink() and binary.stat().st_size<=8*1024**2,'helper_binary_shape')
        result['compile']={'argv':argv,'sourceSHA256':sha(source),'binarySHA256':sha(binary),'SDKROOT':tool['SDKROOT']}
        result['stage']='create';atomic_json(output/'device.json',device)
        created=runner.lifecycle('create',['create',device['createdName'],device['deviceTypeIdentifier'],RUNTIME]).read_text().strip()
        require(str(uuid.UUID(created)).upper()==created.upper() and created not in device['initialUDIDs'],'helper_new_uuid')
        device.update(createdUDID=created,creation='created');atomic_json(output/'device.json',device)
        shutdown_inventory=read(runner.lifecycle('created',['list','-j']))
        result['stage']='boot'
        result['bootMode']='single_owned_bootstatus'
        result['bootstatusSampling']='disabled_before_dispatch'
        result['bootPreparationSeconds']=BOOT_PREPARATION_SECONDS
        result['postBootVerificationReserveSeconds']=POST_BOOT_VERIFICATION_RESERVE_SECONDS
        status=wait_for_boot(runner,device,shutdown_inventory)
        verify_boot_output(status.read_bytes(),(runner.out/'bootstatus-stderr.log').read_bytes())
        runner.budget()
        verify_post_boot_device(runner,device)
        runner.finish();require(runner.receipt['allKnownChildrenTerminal'],'helper_prepare_not_terminal')
        result.update(sampler_summary(runner.receipt))
        verify_tools(tool);require(selected_snapshot(ROOT,sources['files'])==sources,'helper_source_changed_before_capture')
        result['stage']='capture';atomic_json(output/'receipt.json',result)
        args=SimpleNamespace(output=output/'capture',helper=binary,helper_sha256=sha(binary),simulator=created,
            simctl=Path(tool['simctl']['path']),simctl_sha256=tool['simctl']['sha256'],
            simctl_executable=Path(tool['simctl']['executable']),simctl_executable_sha256=tool['simctl']['executableSHA256'],
            xctrace=Path(tool['xctrace']['path']),xctrace_sha256=tool['xctrace']['sha256'])
        controller=SimulatorSupervisor(args)
        handlers={s:signal.getsignal(s) for s in (signal.SIGINT,signal.SIGTERM)}
        try:controller.run()
        finally:
            for sig,handler in handlers.items():signal.signal(sig,handler)
        capture=read(output/'capture/receipt.json');terminal_capture(capture)
        require(capture['outcome']=='exported_pending_event_schema_review','helper_collection_failed:'+str(capture.get('error')))
        pid=capture['helper']['binding']['pid'];subsystem=capture['subsystem']
        validate_run(capture,read(output/'capture/helper-status.json'),(output/'capture/helper-command.txt').read_text(),pid,subsystem,created)
        require(capture['helper']['executableSHA256']==result['compile']['binarySHA256']==sha(binary),'helper_binary_changed')
        require(capture['helper']['binding']['executable']==str(binary),'helper_executable_path')
        require(capture['preparedSources']=={n:sha(Path(__file__).with_name(n)) for n in
                ('control.py','host_control.py','SignpostControl.swift')},'helper_capture_source_binding')
        for entry in capture['processes']:
            expected=tool['simctl'] if entry['label']=='simctl-spawn' else tool['xctrace']
            require(entry['argv'][0]==expected['path'] and entry['binding']['executable']==expected.get('executable',expected['path'])
                    and entry['executableSHA256']==expected.get('executableSHA256',expected['sha256']),'helper_capture_tool_binding')
        result['stage']='export'
        runner=HelperRunner(output/'export',tool,30,1024**2)
        original=snapshot(output/'capture',64*1024**2,2048)
        trace=snapshot(output/'capture/control.trace',64*1024**2,2048)
        atomic_json(runner.out/'original.json',original)
        copy_snapshot(output/'capture/control.trace',runner.out/'inspection.trace',trace,runner.budget,cap=64*1024**2)
        xml=runner.command('signposts','xctrace',['export','--input',str(runner.out/'inspection.trace'),'--xpath',SELECTOR],10)
        require(snapshot(output/'capture',64*1024**2,2048)==original,'helper_original_changed')
        result['events']=validate_events(xml.read_bytes(),(output/'capture/toc-stdout.log').read_bytes(),pid,subsystem,created)
        verify_tools(tool);require(selected_snapshot(ROOT,sources['files'])==sources,'helper_sources_changed')
        require(sha(ROOT/'scripts/app_scroll_observation/contract.json')==result['contractSHA256'],'helper_contract_changed')
        require(sha(binary)==result['compile']['binarySHA256'],'helper_binary_changed_after_export')
        runner.finish();require(runner.receipt['allKnownChildrenTerminal'],'helper_export_not_terminal')
        result.update(stage='validated',helperTransportQualified=True,captureReceiptSHA256=sha(output/'capture/receipt.json'),
                      exportReceiptSHA256=sha(output/'export/receipt.json'),xmlSHA256=sha(xml),deviceSHA256=sha(output/'device.json'))
    except BaseException as exc:
        error=type(exc).__name__+': '+str(exc)[:2048];result['error']=error
    finally:
        if runner is not None:
            try:runner.finish(error)
            except BaseException as exc:
                result['finalizationError']=type(exc).__name__+': '+str(exc)[:2048]
                error=error or result['finalizationError'];result['error']=error
                result['helperTransportQualified']=False
        if preparation_runner is not None:result.update(sampler_summary(preparation_runner.receipt))
        result['finishedEpoch']=time.time();atomic_json(output/'receipt.json',result)
    return 1 if error else 0

def archive_evidence(output, destination):
    output=Path(output).absolute();destination=Path(destination).absolute()
    require(output==output.resolve() and destination==destination.resolve(),'archive_redirected_root')
    require(not destination.is_relative_to(output) and not output.is_relative_to(destination),'archive_outside_input_tree')
    try:
        snapshot(output,512*1024**2,8192)
    except BaseException as exc:
        # Refused evidence must not become an unsafe raw-tree upload. Keep only a
        # bounded report, including scalar first-fault fields from exact receipts.
        destination.mkdir(parents=True,exist_ok=False)
        report=destination/'report';report.mkdir()
        failures={}
        for name in ('receipt.json','prepare/receipt.json','capture/receipt.json','export/receipt.json'):
            path=output/name
            try:
                require(path.absolute()==path.resolve(),'unsafe_failure_receipt')
                value=read(path,64*1024)
                failures[name]={k:v[:2048] if isinstance(v,str) else v for k,v in value.items()
                    if k in ('stage','status','outcome','error','diagnosticOnly','releaseAcceptance',
                             'helperTransportQualified','captureQualified','allOwnedProcessesTerminal')
                    and isinstance(v,(str,bool))}
            except (ValueError,OSError,TypeError,AttributeError):
                continue
        receipt={'diagnosticOnly':True,'releaseAcceptance':False,'archivePreserved':False,
                 'rawFallbackQualified':False,'error':type(exc).__name__+': '+str(exc)[:2048],
                 'failureReceipts':failures,'artifactPath':str(report)}
        atomic_json(report/'receipt.json',receipt)
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'],'a') as stream:stream.write('artifact_path='+str(report)+'\n')
        return 1
    return archive.run(output,destination)

def require_archived_inputs(output, archived):
    archive.require_preserved(archived)
    preserved=read(Path(archived)/'report/receipt.json')
    # Bind deletion authority and terminal-process evidence to the same bytes
    # already preserved. A valid TAR from another run is insufficient.
    snapshot(output,512*1024**2,8192)
    current=archive.inventory(Path(output).resolve(),512*1024**2,time.monotonic()+30,exclude_copies=True)
    require(current==preserved['members'],'helper_archive_input_changed')

def cleanup(output, archived, destination):
    output=Path(output);destination=Path(destination);runner=None;error=None
    try:
        require(validate_request(os.environ),'helper_opt_in_required');require_archived_inputs(output,archived)
        device=read(output/'device.json');require(device['owner']==owner_identity(),'helper_cleanup_owner')
        require(device['createdName']==owned_name(device['owner'],device['nonce']) and device['createdUDID'] not in device['initialUDIDs'],'helper_cleanup_scope')
        receipt=read(output/'receipt.json');tool=receipt['tools']
        for path in (output/'prepare/receipt.json',output/'export/receipt.json'):
            if path.exists():require(read(path)['allKnownChildrenTerminal'] is True,'helper_phase_not_terminal')
        if (output/'capture').exists():terminal_capture(read(output/'capture/receipt.json'))
        runner=HelperRunner(destination,tool,90);runner.device=device
        now=verify_scoped_device(runner,device,'before')
        require(now['state'] in ('Booted','Shutdown'),'helper_cleanup_state')
        if now['state']=='Booted':runner.lifecycle('shutdown',['shutdown',device['createdUDID']],30)
        verify_scoped_device(runner,device,'shutdown-verified','Shutdown')
        runner.lifecycle('delete',['delete',device['createdUDID']],30)
        verify_scoped_device(runner,device,'deleted',absent=True)
        runner.receipt.update(ownedDeviceDeleted=True,deviceReceiptSHA256=sha(output/'device.json'))
    except BaseException as exc:error=type(exc).__name__+': '+str(exc)
    finally:
        if runner:runner.finish(error)
        else:
            destination.mkdir(parents=True,exist_ok=False)
            atomic_json(destination/'receipt.json',{'diagnosticOnly':True,'releaseAcceptance':False,'status':'failed','error':error,'ownedDeviceDeleted':False})
    return 1 if error else 0

def terminal_summary(phase, path, failure=None):
    """Print only fixed fields/codes, never raw payloads, paths, arguments or environment."""
    value={}
    try:
        value=read(path);require(isinstance(value,dict),'summary_receipt_shape')
    except (ValueError,OSError,TypeError):
        value={'error':'RuntimeError: summary_receipt_unavailable'}
    error=failure or value.get('error','')
    match=re.fullmatch(r'([A-Za-z]+Error|KeyboardInterrupt): ([A-Za-z0-9_-]+).*',str(error),re.DOTALL)
    cause=(match[1]+':'+match[2])[:120] if match else 'unclassified_failure' if error else None
    qualified=value.get('helperTransportQualified') is True and failure is None
    passed=qualified if phase=='run' else value.get('archivePreserved') is True if phase=='archive' else value.get('status')=='passed' and value.get('ownedDeviceDeleted') is True
    if failure:passed=False
    stage=value.get('stage')
    if stage not in ('request','source-contract','tool-inventory','exact-tool-admission','prerequisites',
                     'compile','create','boot','capture','export','validated'):stage=phase
    summary={'phase':phase,'stage':stage,'status':'passed' if passed else 'failed',
             'firstCause':cause,'helperTransportQualified':qualified,'releaseAcceptance':False,
             'cleanup':'deleted' if value.get('ownedDeviceDeleted') is True else 'not_verified' if phase=='cleanup' else 'not_applicable'}
    if phase=='run' and 'samplerDiagnosticsComplete' in value:
        summary['samplerDiagnosticsComplete']=value['samplerDiagnosticsComplete'] is True
        attempts=value.get('samplerDiagnostics',{}).get('attempts',[])
        summary['samplerStatuses']=[s.get('status') for s in attempts][:1]
        summary['samplerTerminations']=[s.get('terminationClassification') for s in attempts if s.get('terminationClassification') in
                                        ('normal_exit','signal_exit','handled_sigint_exit1')][:1]
        summary['samplerReasons']=[s.get('reason') for s in attempts if s.get('reason') in
                                   ('observation_timeout','post_startup_reserve_exhausted')][:1]
    print(json.dumps(summary,sort_keys=True));return summary

def main():
    def interrupted(signum, frame):raise KeyboardInterrupt('helper_supervisor_signal_'+str(signum))
    signal.signal(signal.SIGTERM,interrupted)
    p=argparse.ArgumentParser();p.add_argument('phase',choices=('validate-request','run','archive','cleanup'))
    p.add_argument('--output',type=Path);p.add_argument('--archive',type=Path);p.add_argument('--cleanup',type=Path)
    a=p.parse_args()
    if a.phase=='validate-request':print(json.dumps({'helperMode':validate_request(os.environ),'diagnosticOnly':True}));return 0
    require(a.output is not None,'helper_output_required')
    if a.phase=='run':path=a.output/'receipt.json'
    elif a.phase=='archive':
        require(a.archive is not None,'helper_archive_required');path=a.archive/'report/receipt.json'
    else:
        require(a.archive is not None and a.cleanup is not None,'helper_cleanup_output_required');path=a.cleanup/'receipt.json'
    failure=None
    try:
        if a.phase=='run':return run(a.output,os.environ['DEVELOPER_DIR'])
        if a.phase=='archive':return archive_evidence(a.output,a.archive)
        return cleanup(a.output,a.archive,a.cleanup)
    except BaseException as exc:
        failure=type(exc).__name__+': '+str(exc);raise
    finally:terminal_summary(a.phase,path,failure)
