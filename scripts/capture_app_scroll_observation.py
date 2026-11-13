#!/usr/bin/env python3
"""Opt-in hosted scroll observation. Explicit independent phases; never retries a test/export."""
import argparse
import os
from pathlib import Path
import signal
import sys
sys.dont_write_bytecode = True
from app_scroll_observation import producer, consumer, export, results, archive
from app_scroll_observation.capture import Capture
from app_scroll_observation.contract import ROOT, frozen, read, tools
from app_scroll_observation.support import require
from plan_ios_performance_tests import validate_app_observation_request


def admission():
    validate_app_observation_request(os.environ.get('GITHUB_EVENT_NAME',''),os.environ.get('REQUESTED_PERFORMANCE_CASE',''),
        os.environ.get('OBSERVE_APP_SCROLL_SIGNPOSTS','false'),os.environ.get('ENFORCE_BASELINES',''),
        os.environ.get('CAPTURE_SCROLL_SIGNPOSTS','false'),os.environ.get('CAPTURE_PREFLIGHT_ONLY','false'),
        os.environ.get('ENABLE_PERFORMANCE_DIAGNOSTICS','false'),os.environ.get('FRESH_PERFORMANCE_SIMULATOR','false'))
    require(os.environ.get('OBSERVE_APP_SCROLL_SIGNPOSTS')=='true','explicit_opt_in_required')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('phase',choices=('prepare','build','package','collect','seal','export','results','qualify','archive','cleanup-gate'))
    p.add_argument('--evidence',type=Path,default=ROOT/'.build/performance')
    p.add_argument('--products',type=Path,default=ROOT/'.build/DerivedData/Build/Products')
    p.add_argument('--prepared',type=Path,default=ROOT/'.build/app-observation-producer/prepare')
    p.add_argument('--build-output',type=Path,default=ROOT/'.build/app-observation-producer/build')
    p.add_argument('--output',type=Path)
    p.add_argument('--export-dir',type=Path);p.add_argument('--results-dir',type=Path)
    p.add_argument('--developer',default=os.environ.get('DEVELOPER_DIR',''))
    a=p.parse_args();frozen()
    for key in ('evidence','products','prepared','build_output'):
        setattr(a,key,getattr(a,key).resolve())
    if a.phase in ('prepare','build','package','collect'):admission()
    if a.phase=='prepare':producer.prepare(a.prepared,a.developer)
    elif a.phase=='build':producer.build(a.prepared,a.build_output)
    elif a.phase=='package':producer.package(a.prepared,a.build_output,a.products)
    elif a.phase=='collect':
        consumer.configure(a.evidence,a.products)
        return Capture(read(a.evidence/'observation-config.json'),a.evidence/'observation-capture').run()
    elif a.phase=='seal':consumer.seal(a.evidence)
    elif a.phase=='archive':return archive.run(a.evidence,a.evidence.parent/'app-observation-portable')
    elif a.phase=='cleanup-gate':
        consumer.cleanup_gate(a.evidence)
        if (a.evidence/'native-attempt.json').exists():archive.require_preserved(a.evidence.parent/'app-observation-portable')
    elif a.phase in ('export','results'):
        output=(a.output or a.evidence/('observation-'+a.phase)).resolve()
        require(output.parent==a.evidence and not output.exists(),'fresh_evidence_child_required')
        return (export.run if a.phase=='export' else results.run)(a.evidence,output,tools(a.developer))
    elif a.phase=='qualify':
        return export.qualify(a.evidence,(a.export_dir or a.evidence/'observation-export').resolve(),
            (a.results_dir or a.evidence/'observation-results').resolve(),a.output or a.evidence/'app-observation-qualification.json')
    return 0


if __name__=='__main__':
    def interrupted(signum,frame):raise KeyboardInterrupt('observation_signal_'+str(signum))
    signal.signal(signal.SIGTERM,interrupted)
    try:raise SystemExit(main())
    except Exception as exc:print('STOP: '+type(exc).__name__+': '+str(exc),file=sys.stderr);raise SystemExit(1)
