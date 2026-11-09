"""One bounded export from a fresh verified trace copy; never invokes app/test/simulator."""
from pathlib import Path
from .contract import read, snapshot, copy_snapshot
from .consumer import verify_seal
from .support import require, sha, atomic_json
from .runner import Runner
from .schema import validate_receipt, table_records, validate_envelopes, classify_uikit

XPATH='/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]'


def run(evidence, output, tools):
    proof=verify_seal(evidence,True);capture=evidence/'observation-capture';receipt=read(capture/'receipt.json')
    runner=Runner(output,tools,90,64*1024**2);error=None
    report={'diagnosticOnly':True,'releaseAcceptance':False,'transportQualified':False,
            'originalCaptureReceiptSHA256':sha(capture/'receipt.json'),'sealSHA256':sha(evidence/'observation-custody/seal.json')}
    try:
        original=snapshot(capture/'app.trace',128*1024**2)
        require(original==receipt['originalTrace'],'original_trace_custody')
        copy_snapshot(capture/'app.trace',output/'inspection.trace',original,runner.budget)
        toc=runner.command('toc','xctrace',['export','--input',output/'inspection.trace','--toc'],10)
        xml=runner.command('signposts','xctrace',['export','--input',output/'inspection.trace','--xpath',XPATH],30)
        pid,ledger=validate_receipt(receipt,receipt['simulatorUDID'])
        records,duration,ordinal=table_records(xml.read_bytes(),toc.read_bytes(),pid,receipt['simulatorUDID'])
        envelopes=validate_envelopes(records,pid,receipt['subsystem'],ledger,duration)
        report.update(envelopes=envelopes,uikit=classify_uikit(records,pid,envelopes),resolvedTableOrdinal=ordinal,
                      signpostsSHA256=sha(xml),signpostsBytes=xml.stat().st_size,tocSHA256=sha(toc),originalTraceSnapshot=original)
        require(snapshot(capture/'app.trace',128*1024**2)==original,'original_trace_bytes_or_modes_changed')
        require(verify_seal(evidence,True)==proof,'collection_custody_changed')
        report['transportQualified']=True
    except BaseException as exc:error=type(exc).__name__+': '+str(exc);report['error']=error
    finally:
        runner.finish(error)
        report['exportReceiptSHA256']=sha(output/'receipt.json')
        atomic_json(output/'qualification.json',report)
    return 0 if report['transportQualified'] else 1


def qualify(evidence, export_dir, results_dir, output):
    require(not output.exists(),'qualification_output_exists')
    result={'diagnosticOnly':True,'releaseAcceptance':False,'derivedDiagnosticQualified':False,'questionAnswer':'inconclusive'}
    try:
        proof=verify_seal(evidence,True);transport=read(export_dir/'qualification.json');tests=read(results_dir/'inspection.json')
        capture_sha=sha(evidence/'observation-capture/receipt.json');seal_sha=sha(evidence/'observation-custody/seal.json')
        require(transport['originalCaptureReceiptSHA256']==tests['captureReceiptSHA256']==capture_sha,'same_collection')
        require(transport['sealSHA256']==tests['sealSHA256']==seal_sha,'same_custody')
        for name,digest in tests['exports'].items():require(sha(results_dir/name)==digest,'result_export_changed')
        require(sha(export_dir/'receipt.json')==transport['exportReceiptSHA256'],'export_receipt_changed')
        if transport.get('transportQualified'):
            require(sha(export_dir/'signposts-stdout.log')==transport['signpostsSHA256'] and sha(export_dir/'toc-stdout.log')==transport['tocSHA256'],'transport_export_changed')
        result.update(transportSHA256=sha(export_dir/'qualification.json'),resultSHA256=sha(results_dir/'inspection.json'),captureReceiptSHA256=capture_sha,sealSHA256=seal_sha)
        metrics=tests['performance'].get('validation',{}).get('measurements',{})
        intervals=transport.get('uikit',{}).get('invocations',[])
        named=bool(intervals) and all(x['containedPairs'] for x in intervals)
        # A scientific positive answer does not turn a missing required metric into a passing gate.
        missing=metrics.get('status')=='failed' and metrics.get('error')=='Missing required performance metric: com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration'
        strict=tests['strictXCTest']['status']=='passed' and tests['runnerACK']['status']=='passed'
        fixture=tests['performance'].get('validation',{}).get('persistedPickup',{}).get('status')=='passed'
        if transport['transportQualified'] and strict and fixture and tests['custody']['status']=='passed':
            result['questionAnswer']=('yes_intervals_present_original_duration_missing' if named and missing else
                'missing_metric_condition_not_reproduced' if named and metrics.get('status')=='passed' else 'no_positive_conjunction_observed')
        result['derivedDiagnosticQualified']=bool(transport['transportQualified'] and tests['resultChecksQualified'] and proof['collectionQualified'])
        result.update(requiredMetrics=metrics,exactNamedIntervalsInEveryEnvelope=named,originalFailuresRetained=True,
                      scope='Observed hosted consumer only. Outer envelopes are not XCTest sample boundaries. Observer/source/state interaction remains; no baseline or release approval.')
    except (ValueError,OSError,KeyError,TypeError) as exc:result['error']=str(exc)
    atomic_json(output,result)
    return 0 if result['derivedDiagnosticQualified'] else 1
