"""Read-only app transport validation. Does not replace XCTest result/metric checkers."""
import argparse
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

from .support import SELECTOR, atomic_json, manifest, modes, require, sha

COLUMNS = [('time','event-time'),('thread','thread'),('process','process'),('event-type','event-type'),
           ('scope','string'),('identifier','os-signpost-identifier'),('name','signpost-name'),
           ('format-string','format-string'),('backtrace','text-backtrace'),('subsystem','subsystem'),
           ('category','category'),('message','os-log-metadata'),('emit-location','return-location')]


def parse(raw):
    require(len(raw) <= 64*1024**2, 'xml_size')
    require(b'<!DOCTYPE' not in raw.upper() and b'<!ENTITY' not in raw.upper(), 'xml_declaration')
    return ET.fromstring(raw)


def table_records(raw, toc_raw, pid, device):
    root,toc = parse(raw),parse(toc_raw)
    require(root.tag == 'trace-query-result' and len(root) == 1 and root[0].tag == 'node', 'query_shape')
    node=root[0]
    match=re.fullmatch(r'//trace-toc\[1\]/run\[1\]/data\[1\]/table\[(\d+)\]',node.get('xpath',''))
    require(match is not None,'table_reference')
    require(toc.tag == 'trace-toc' and len(toc.findall('run')) == 1,'toc_runs')
    run=toc.find('run'); require(run.get('number') == '1','run_number')
    target=run.find('info/target/process'); dev=run.find('info/target/device')
    require(target is not None and target.get('pid') == str(pid) and target.get('type') == 'attached','target_pid')
    require(dev is not None and dev.get('uuid') == device and dev.get('platform') == 'iOS Simulator','target_device')
    require(run.findtext('info/summary/template-name') == 'Logging','template')
    require(run.findtext('info/summary/end-reason') == 'Time limit reached','normal_trace_end')
    duration=int(float(run.findtext('info/summary/duration'))*1e9)
    require(59e9 <= duration <= 65e9,'recording_duration')
    tables=run.findall('data/table'); index=int(match[1])-1
    require(0 <= index < len(tables) and tables[index].get('schema') == 'os-signpost','table_schema')
    schema=node.find('schema')
    require(schema is not None and schema.get('name') == 'os-signpost','schema_name')
    require([(x.findtext('mnemonic'),x.findtext('engineering-type')) for x in schema] == COLUMNS,'schema_columns')
    require(all(x.tag in ('schema','row') for x in node) and len(node.findall('schema')) == 1,'schema_shape')
    definitions={}
    for element in node.iter():
        key=element.get('id')
        if key is not None:
            require(key not in definitions and element.get('ref') is None,'duplicate_or_mixed_id');definitions[key]=element
    def resolve(element,seen=None):
        require(element is not None,'missing_element')
        ref=element.get('ref')
        if ref is None:return element
        seen=set() if seen is None else seen
        require(ref in definitions and ref not in seen,'unresolved_or_cyclic_reference')
        require(set(element.attrib)=={'ref'} and not len(element) and not (element.text or '').strip(),'reference_shape')
        require(element.tag==definitions[ref].tag,'reference_type')
        return resolve(definitions[ref],seen|{ref})
    for element in node.iter():resolve(element)
    def scalar(element):
        value=resolve(element)
        if value.tag=='sentinel':return None
        require(not len(value) and value.text is not None,'scalar_shape');return value.text
    def number(element):
        value=scalar(element);require(value is not None and re.fullmatch(r'[0-9]+',value),'number_shape');return int(value)
    records=[]
    for row in node.findall('row'):
        require(len(row)==len(COLUMNS),'row_width')
        for (_,kind),element in zip(COLUMNS,row):require(element.tag in (kind,'sentinel'),'column_type')
        fields={name:element for (name,_),element in zip(COLUMNS,row)}
        process=resolve(fields['process']);thread=resolve(fields['thread'])
        row_pid=None if process.tag=='sentinel' else number(process.find('pid'))
        if thread.tag!='sentinel':require(number(resolve(thread.find('process')).find('pid'))==row_pid,'thread_process')
        records.append({'pid':row_pid,'name':scalar(fields['name']),'type':scalar(fields['event-type']),
            'time':number(fields['time']),'id':number(fields['identifier']),
            'subsystem':scalar(fields['subsystem']),'category':scalar(fields['category']),'scope':scalar(fields['scope'])})
    return records,duration,index+1


def validate_envelopes(records, pid, subsystem, ledger, duration):
    require(1 <= len(ledger) <= 16,'invocation_count')
    require([x['ordinal'] for x in ledger]==list(range(1,len(ledger)+1)),'ordinal_order')
    require(len({x['signpostID'] for x in ledger})==len(ledger),'ledger_id_reuse')
    for i,item in enumerate(ledger,1):
        require(type(item['signpostID']) is int and item['signpostID']>0,'ledger_id')
        require(item['beginSequence']==2*i and item['endSequence']==2*i+1,'ledger_sequence')
    control=[r for r in records if r['subsystem']==subsystem]
    require(len(control)==2+2*len(ledger),'control_count')
    require(all(r['pid']==pid and r['category']=='CoverageControl' and r['scope']=='Process' for r in control),'control_scope')
    expected=[('CaptureReady','Event')]+[pair for _ in ledger for pair in [('ObservedInvocation','Begin'),('ObservedInvocation','End')]]+[('CaptureComplete','Event')]
    require([(r['name'],r['type']) for r in control]==expected,'control_order')
    require(all(a['time']<b['time'] for a,b in zip(control,control[1:])),'control_time_order')
    require(0 <= control[0]['time'] and control[-1]['time'] <= duration,'control_outside_recording')
    envelopes=[]
    for i,item in enumerate(ledger):
        begin,end=control[1+2*i:3+2*i]
        require(begin['id']==end['id']==item['signpostID'],'control_pair_id')
        envelopes.append({'ordinal':item['ordinal'],'signpostID':begin['id'],
                          'beginNanoseconds':begin['time'],'endNanoseconds':end['time']})
    return envelopes


def classify_uikit(records,pid,envelopes):
    relevant=[r for r in records if r['pid']==pid and r['subsystem']=='com.apple.UIKit'
              and r['category']=='ScrollView' and r['name']=='Scroll_DraggingAndDeceleration']
    require(all(a['time']<=b['time'] for a,b in zip(relevant,relevant[1:])),'uikit_time_order')
    active={};pairs=[];partial=[]
    for row in relevant:
        key=(row['scope'],row['id'])
        if row['type']=='Begin':
            if key in active:
                partial.append({'kind':'duplicate_begin','row':active.pop(key)})
                active[key]={**row,'ambiguous':True}
            else: active[key]=row
        elif row['type']=='End':
            begin=active.pop(key,None)
            if begin is None or begin.get('ambiguous') or begin['time']>=row['time']:partial.append({'kind':'unmatched_ambiguous_or_nonpositive_end','row':row})
            else:pairs.append({'id':row['id'],'scope':row['scope'],'beginNanoseconds':begin['time'],'endNanoseconds':row['time']})
        else:partial.append({'kind':'unexpected_event_type','row':row})
    partial.extend({'kind':'missing_end','row':r} for r in active.values())
    report=[]
    for env in envelopes:
        before,after=env['beginNanoseconds'],env['endNanoseconds']
        contained=[p for p in pairs if before<=p['beginNanoseconds']<p['endNanoseconds']<=after]
        overlapping=[p for p in pairs if p not in contained and p['beginNanoseconds']<after and p['endNanoseconds']>before]
        unpaired=[p for p in partial if before<=p['row']['time']<=after]
        report.append({'invocationOrdinal':env['ordinal'],'containedPairs':contained,'overlappingPairs':overlapping,'partialEvents':unpaired,
                       'status':'contained_exact_named_intervals' if contained else ('overlap_or_partial_only' if overlapping or unpaired else 'absent')})
    return {'namedRowCount':len(relevant),'completePairCount':len(pairs),'partialEventCount':len(partial),'invocations':report,
            'scope':'Named UIKit intervals in outer app coverage envelopes; not XCTest sample indexes or metric boundaries'}


def validate_receipt(receipt, device):
    require(receipt['outcome']=='collected_pending_independent_validation' and 'error' not in receipt,'capture_state')
    require(receipt['diagnosticOnly'] is True and receipt['releaseAcceptance'] is False,'diagnostic_scope')
    require(receipt['simulatorUDID']==device and receipt['selector']==SELECTOR,'run_scope')
    require(receipt['readinessObserved'] is True and receipt['notificationControlPassed'] is True,'readiness')
    require(receipt['normalTracerExit'] is True and receipt['allOwnedProcessesTerminal'] is True,'normal_finalization')
    require(receipt['notificationCancelStatus']==[0,0],'notification_cleanup')
    require(receipt['sourceUnchanged'] is True and receipt['productsUnchanged'] is True,'source_product_custody')
    commands=receipt['hostCommands'];require([x['command'] for x in commands]==['GO','Q'],'host_release_commands')
    require(receipt['readinessEpoch']<=commands[0]['epoch']<receipt['tracerExitEpoch']<=commands[1]['epoch'],'release_order')
    require(receipt['tracerExitEpoch']-receipt['readinessEpoch']<=90.5,'record_finalize_budget')
    phases=[receipt['armedStatus'],receipt['completedStatus'],receipt['finalStatus']]
    require([p['stage'] for p in phases]==['waitingForCollector','waitingForFinalization','finished'],'phase_order')
    bound=receipt['bindings'];require(set(bound)=={'app','runner'},'bound_roles')
    for role,item in bound.items():
        require(item['signals']==[] and item['terminalVerified'] is True,'bound_normal_cleanup')
        require(item['installedBundleUnchanged'] is True,'installed_bundle_custody')
    for entry in receipt['processes']:
        require(entry['signals']==[] and entry['terminalVerified'] is True,'process_cleanup')
        require(entry['exitCode']==0 or entry.get('expectedContainerAbsent') is True,'process_exit')
    processes={p['label']:p for p in receipt['processes']}
    for label in ('native','tracer'):
        require(processes[label]['exitCode']==0 and processes[label].get('binding') is not None,'primary_process_identity')
    native=processes['native']['argv']
    require('-only-testing:'+SELECTOR in native and native[-1]=='test-without-building','native_selector')
    require('-enablePerformanceTestsDiagnostics' not in native and '-disable-concurrent-testing' not in native,'extra_native_diagnostics')
    argv=processes['tracer']['argv']
    for flag,value in (('--template','Logging'),('--device',device),('--attach',str(bound['app']['binding']['pid'])),('--time-limit','60s')):
        require(argv[argv.index(flag)+1]==value,'trace_command_scope')
    require('--all-processes' not in argv,'all_processes')
    for phase in phases:
        require(phase['nonce']==receipt['nonce'] and phase['pid']==bound['app']['binding']['pid']
                and phase['runnerPID']==bound['runner']['binding']['pid'] and phase['simulatorUDID']==device
                and phase['subsystem']==receipt['subsystem'] and phase['compiledForSimulator'] is True
                and 'error' not in phase,'status_binding')
        app=bound['app']['binding']
        require(phase['uid']==app['uid'] and phase['parentPID']==app['parentPID']
                and str(Path(phase['executable']).resolve())==app['executable'],'status_full_identity')
    completed,final=phases[1:]
    require(completed['invocations']==final['invocations'],'ledger_changed')
    n=len(final['invocations']);finish=4|((2*n+2)<<8)|(n<<32)
    require(completed['pendingCommand']==finish and final['acknowledgedCommand']==finish,'finish_command')
    require(final['lastSequence']==2*n+2,'final_sequence')
    return bound['app']['binding']['pid'],final['invocations']

