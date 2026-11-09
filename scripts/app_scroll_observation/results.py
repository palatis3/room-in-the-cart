"""Unchanged checker entry points with narrow hash-bound retained-export adapters."""
import contextlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
from .contract import ROOT, frozen, read, snapshot, copy_snapshot
from .support import require, sha, atomic_json, SELECTOR
from .consumer import verify_seal
from .runner import Runner
TEST_ID='ReleasePerformanceUITests/testScrollingPerformanceOnFiveHundredItemPickup()'

def module(name, path):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


def ack_binding(report, receipt):
    final=receipt['finalStatus'];n=len(final['invocations'])
    require(1<=n<=16,'invocation count')
    require(report['diagnosticOnly'] is True and report['releaseAcceptance'] is False and report['finished'] is True,'runner completion/scope')
    require(report['nonce']==receipt['nonce'] and report['runnerPID']==receipt['bindings']['runner']['binding']['pid'],'runner nonce/PID')
    require(type(report['invocations']) is int and report['invocations']==n,'runner invocation count')
    commands=[1|(1<<8)]
    for i,entry in enumerate(final['invocations'],1):
        require(entry['ordinal']==i and entry['beginSequence']==2*i and entry['endSequence']==2*i+1,'app sequence ledger')
        commands += [2|((2*i)<<8)|(i<<32),3|((2*i+1)<<8)|(i<<32)]
    commands += [4|((2*n+2)<<8)|(n<<32)]
    require(final['acknowledgedCommand']==commands[-1] and final['lastSequence']==2*n+2,'app finish ACK')
    require(all(type(x) is int for x in report['acknowledgements']) and report['acknowledgements']==[x|(1<<56) for x in commands],'runner success ACK sequence')
    require(report['scope']=='Outer app coverage envelopes, not XCTest sample durations or indexes','runner scope text')
    return {'status':'passed','nonce':report['nonce'],'runnerPID':report['runnerPID'],'invocations':n,'successACKCount':len(commands)}


def attachment(directory, receipt):
    groups=read(directory/'manifest.json')
    matches=[a for group in groups for a in group.get('attachments',[])
             if a.get('suggestedHumanReadableName','').startswith('app-capture-runner-control')]
    require(len(matches)==1,'exactly one runner-control attachment globally')
    group_matches=[a for group in groups if group.get('testIdentifier')==TEST_ID for a in group.get('attachments',[]) if a in matches]
    require(len(group_matches)==1,'runner attachment selected-test binding')
    item=matches[0];require(item['deviceId']==receipt['simulatorUDID'] and item['isAssociatedWithFailure'] is False,'runner attachment device/failure binding')
    name=item['exportedFileName'];require(isinstance(name,str) and Path(name).name==name and name not in ('.','..'),'attachment basename')
    path=directory/name;report=read(path,16384)
    return {**ack_binding(report,receipt),'file':name,'sha256':sha(path),'manifestSHA256':sha(directory/'manifest.json')}


class LimitedWriter:
    def __init__(self, stream, limit=1024**2): self.stream,self.limit,self.count=stream,limit,0
    def write(self, value):
        self.count+=len(value.encode());require(self.count<=self.limit,'checker output cap');return self.stream.write(value)
    def flush(self): self.stream.flush()


def invoke(main, argv, log):
    saved=sys.argv
    try:
        sys.argv=argv
        with log.open('x') as stream, contextlib.redirect_stdout(LimitedWriter(stream)), contextlib.redirect_stderr(LimitedWriter(stream)):
            try:
                value=main();return 0 if value is None else int(value)
            except SystemExit as exc:
                if exc.code is None:return 0
                if isinstance(exc.code,int):return exc.code
                print(exc.code);return 1
    finally:sys.argv=saved


def strict_adapters(checker, result, url, details, activities):
    detail_hash=sha(details) if details else None;activity_hash=sha(activities) if activities else None
    # Module-local exporter names only. main/inspect_runtime_warnings and every validator remain original.
    def read_details(bundle, requested):
        require(bundle==result and requested==url and details is not None and sha(details)==detail_hash,'strict details binding');return read(details)
    def read_activities(bundle, requested, capture=None):
        require(bundle==result and requested==url and activities is not None and sha(activities)==activity_hash,'strict activities binding')
        raw=activities.read_bytes()
        require(len(raw)<=8*1024**2,'activities cap')
        if capture is not None:capture(requested,raw)
        return json.loads(raw)
    checker.export_test_details=read_details;checker.export_test_activities=read_activities


def run(evidence, output, tools):
    capture=evidence/'observation-capture';proof=None;receipt=None
    runner=Runner(output,tools,240);report={'diagnosticOnly':True,'releaseAcceptance':False,'resultChecksQualified':False,
        'captureReceiptSHA256':None,'sealSHA256':None,
        'strictXCTest':{'status':'not-checked'},'runnerACK':{'status':'not-checked'},'performance':{'status':'not-checked'},
        'entryPoints':{'strict':'original check_ios_test_results.main; only module-local export_test_details/export_test_activities callbacks read retained hash-bound files',
                       'performance':'original check_ios_performance.main; original fixture and preserved ledger; required metrics unchanged; no baseline'}}
    source=ROOT;original=None;error=None
    try:
        frozen()
        # Custody controls qualification, not whether available original results are inspected.
        try:
            proof=verify_seal(evidence);source=evidence/'observation-custody/source'
            report['sealSHA256']=sha(evidence/'observation-custody/seal.json')
        except (ValueError,OSError,KeyError,TypeError) as exc:
            report['inspectionOnlyDueToCustodyFailure']=str(exc)
        receipt=read(capture/'receipt.json');report['captureReceiptSHA256']=sha(capture/'receipt.json')
        result=capture/'Performance.xcresult';original=snapshot(result,512*1024**2)
        copy_snapshot(result,output/'Inspection.xcresult',original,runner.budget);copy=output/'Inspection.xcresult'
        report['exportErrors']={}
        for kind,name in [('summary','test-summary.json'),('tests','test-details.json'),('metrics','metrics.json')]:
            try:
                raw=runner.command(kind,'xcresulttool',['get','test-results',kind,'--path',copy,'--compact']);read(raw)
                raw.rename(output/name)
            except (ValueError,RuntimeError,OSError) as exc:report['exportErrors'][kind]=str(exc)
        try:
            runner.command('attachments','xcresulttool',['export','attachments','--path',copy,'--output-path',output/'attachments'])
            report['runnerACK']=attachment(output/'attachments',receipt)
        except (ValueError,RuntimeError,KeyError,TypeError,OSError) as exc:report['runnerACK']={'status':'failed','error':str(exc)}
        try:
            summary=read(output/'test-summary.json')
            require(len(summary['devicesAndConfigurations'])==1 and summary['devicesAndConfigurations'][0]['device']['deviceId']==receipt['simulatorUDID'],'result_device_binding')
            checker=module('app_observation_strict',source/'scripts/check_ios_test_results.py')
            cases=list(checker.test_cases(read(output/'test-details.json')['testNodes']));url=details=activities=None
            if len(cases)==1 and cases[0][0]==SELECTOR:
                url=cases[0][1]['nodeIdentifierURL']
                details=runner.command('case-details','xcresulttool',['get','test-results','test-details','--path',copy,'--test-id',url,'--compact'])
                parsed=read(details)
                if list(checker.warning_names(checker.result_nodes(parsed['testRuns']))):
                    activities=runner.command('case-activities','xcresulttool',['get','test-results','activities','--path',copy,'--test-id',url,'--compact']);read(activities)
            strict_adapters(checker,copy,url,details,activities)
            report['perCaseExports']={'testIdentifierURL':url,'detailsSHA256':sha(details) if details else None,'activitiesSHA256':sha(activities) if activities else None}
            require((capture/'selected.txt').read_text()==SELECTOR+'\n','selected_test')
            shutil.copy2(capture/'selected.txt',output/'selector.txt');shutil.copy2(capture/'native-stdout.log',output/'Performance.log')
            try:
                code=invoke(checker.main,['check_ios_test_results.py','--selectors',str(output/'selector.txt'),'--expected-count','1',
                    '--summary',str(output/'test-summary.json'),'--tests',str(output/'test-details.json'),'--result-bundle',str(copy),'--test-log',str(output/'Performance.log')],output/'strict-checker.log')
                report['strictXCTest']={'status':'passed' if code==0 else 'failed','exitCode':code,'runtimeWarnings':read(output/'test-runtime-warnings.json')}
            except (ValueError,KeyError,TypeError,OSError) as exc:report['strictXCTest']={'status':'failed','error':str(exc)}
        except (ValueError,RuntimeError,KeyError,TypeError,OSError) as exc:report['strictXCTest']={'status':'failed','error':str(exc)}
        # Metric/fixture checker runs even when strict or ACK validation failed.
        try:
            preservation=read(evidence/'store-preservation.json');store=evidence/'ledger-snapshot.sqlite'
            require(preservation['status']=='preserved' and preservation['cleanupAllowed'] is True
                    and preservation['snapshotSHA256']==sha(store) and store.stat().st_size<=32*1024**2,'fixture_preservation')
            require(preservation['ownershipSHA256']==sha(evidence/'test-simulator-ownership.json')
                    and preservation['attemptSHA256']==sha(evidence/'native-attempt.json')
                    and preservation['createdUDID']==receipt['simulatorUDID'],'fixture_attempt_binding')
            shutil.copy2(store,output/'ledger-snapshot.sqlite')
            (output/'toolchain.txt').write_text(tools['xcode']+'\n')
            performance=module('app_observation_performance',source/'scripts/check_ios_performance.py')
            code=invoke(performance.main,['check_ios_performance.py','scroll','--evidence',str(output),
                '--fixture',str(source/'ios/UITests/Fixtures/ReleaseLedger500.txt'),'--store',str(output/'ledger-snapshot.sqlite')],output/'performance-checker.log')
            report['performance']={'status':'passed' if code==0 else 'failed','exitCode':code,'validation':read(output/'evidence-validation.json')}
            require(sha(store)==preservation['snapshotSHA256']==sha(output/'ledger-snapshot.sqlite'),'fixture_after_check')
            report['storePreservationSHA256']=sha(evidence/'store-preservation.json')
        except (ValueError,KeyError,TypeError,OSError) as exc:report['performance']={'status':'failed','error':str(exc)}
    except BaseException as exc:error=type(exc).__name__+': '+str(exc);report['error']=error
    finally:
        try:
            require(original is not None and snapshot(capture/'Performance.xcresult',512*1024**2)==original,'original_result_custody')
            require(proof is not None and verify_seal(evidence)==proof,'sealed_custody_unavailable_or_changed');runner.budget();report['custody']={'status':'passed'}
        except BaseException as exc:report['custody']={'status':'failed','error':str(exc)}
        runner.finish(error)
        clean=all(p['record']['exitCode']==0 and p['record']['signals']==[] and p['record']['terminalVerified'] is True for p in runner.processes)
        report['resultChecksQualified']=('error' not in report and not report.get('exportErrors') and clean and report['custody']['status']=='passed'
                                        and all(report[k]['status']=='passed' for k in ('strictXCTest','runnerACK','performance')))
        report['originalResultSnapshot']=original
        report['exports']={str(p.relative_to(output)):sha(p) for p in output.rglob('*') if p.is_file() and 'Inspection.xcresult' not in p.parts}
        atomic_json(output/'inspection.json',report)
    return 0 if report['resultChecksQualified'] else 1
