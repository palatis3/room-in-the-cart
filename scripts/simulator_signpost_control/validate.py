"""Read-only validation of retained simulator events; never capture qualification. No native tools/imported controller."""
import hashlib
import json
from pathlib import Path
import re
import time
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parent.parent
OUTPUT = Path(__file__).resolve().parent
PID = 60002
SUBSYSTEM = 'dev.roominthecart.collectorcontrol.85b8546477f743a88c1356d17ea53a03'
UDID = 'A50C91FC-4966-47FF-A8CB-7640FBD513EB'
SELECTOR = '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]'
COLUMNS = [('time', 'event-time'), ('thread', 'thread'), ('process', 'process'),
           ('event-type', 'event-type'), ('scope', 'string'), ('identifier', 'os-signpost-identifier'),
           ('name', 'signpost-name'), ('format-string', 'format-string'), ('backtrace', 'text-backtrace'),
           ('subsystem', 'subsystem'), ('category', 'category'), ('message', 'os-log-metadata'),
           ('emit-location', 'return-location')]


def require(condition, reason):
    if not condition: raise ValueError(reason)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()


def manifest(folder):
    records, total = {}, 0
    require(folder.is_dir() and not folder.is_symlink(), 'manifest_root')
    for path in sorted(folder.rglob('*')):
        require(not path.is_symlink(), 'manifest_symlink')
        if path.is_dir(): continue
        require(path.is_file(), 'manifest_nonregular')
        total += path.stat().st_size
        require(total <= 64 * 1024 * 1024 and len(records) < 2048, 'manifest_cap')
        records[str(path.relative_to(folder))] = sha(path)
    return records


def parse(raw):
    require(len(raw) <= 1024 * 1024, 'xml_size')
    require(b'<!DOCTYPE' not in raw.upper() and b'<!ENTITY' not in raw.upper(), 'xml_declaration')
    return ET.fromstring(raw)


def validate_events(raw, toc_raw, pid, subsystem, udid):
    root, toc = parse(raw), parse(toc_raw)
    require(root.tag == 'trace-query-result' and len(root) == 1 and root[0].tag == 'node', 'query_shape')
    node = root[0]
    match = re.fullmatch(r'//trace-toc\[1\]/run\[1\]/data\[1\]/table\[(\d+)\]', node.get('xpath', ''))
    require(match is not None, 'table_reference')
    require(toc.tag == 'trace-toc' and len(toc.findall('run')) == 1, 'toc_run_count')
    run = toc.find('run'); require(run.get('number') == '1', 'toc_run_identity')
    target = run.find('info/target/process')
    require(target is not None and target.get('pid') == str(pid) and target.get('type') == 'attached', 'toc_target')
    require(run.find('info/target/device').get('platform') == 'iOS Simulator', 'simulator_platform')
    require(run.find('info/target/device').get('uuid') == udid, 'simulator_udid')
    require(run.findtext('info/summary/template-name') == 'Logging', 'template')
    require(run.findtext('info/summary/end-reason') == 'Time limit reached', 'trace_finalization')
    tables = run.findall('data/table'); index = int(match[1]) - 1
    require(0 <= index < len(tables) and tables[index].get('schema') == 'os-signpost', 'toc_schema_reference')
    schema = node.find('schema')
    require(schema is not None and schema.get('name') == 'os-signpost', 'schema_name')
    require([(c.findtext('mnemonic'), c.findtext('engineering-type')) for c in schema] == COLUMNS, 'schema_columns')
    require(all(c.tag in ('schema', 'row') for c in node) and len(node.findall('schema')) == 1, 'schema_count')
    definitions = {}
    for element in node.iter():
        key = element.get('id')
        if key is not None:
            require(key not in definitions and element.get('ref') is None, 'duplicate_or_mixed_id')
            definitions[key] = element

    def resolve(element, seen=None):
        reference = element.get('ref')
        if reference is None: return element
        seen = set() if seen is None else seen
        require(reference not in seen and reference in definitions, 'unresolved_or_cyclic_reference')
        require(set(element.attrib) == {'ref'} and not len(element) and not (element.text or '').strip(), 'reference_shape')
        target = definitions[reference]
        require(target.tag == element.tag, 'reference_type')
        return resolve(target, seen | {reference})

    # Validate every reference, including nested process/thread and unused columns.
    for element in node.iter(): resolve(element)
    def scalar(element):
        value = resolve(element)
        require(len(value) == 0 and value.text is not None, 'scalar_shape')
        return value.text
    def number(element):
        value = scalar(element); require(re.fullmatch(r'[0-9]+', value) is not None, 'integer_shape')
        return int(value)

    rows = node.findall('row'); require(len(rows) == 8, 'event_count')
    records = []
    for row in rows:
        require(len(row) == len(COLUMNS), 'row_width')
        fields = {name: element for (name, _), element in zip(COLUMNS, row)}
        for (_, expected_type), element in zip(COLUMNS, row):
            require(element.tag in (expected_type, 'sentinel'), 'column_type')
        process = resolve(fields['process']); thread = resolve(fields['thread'])
        require(number(process.find('pid')) == pid, 'process_identity')
        require(number(resolve(thread.find('process')).find('pid')) == pid, 'thread_process_identity')
        require(scalar(fields['subsystem']) == subsystem and scalar(fields['category']) == 'OwnedControl', 'event_scope')
        require(scalar(fields['scope']) == 'Process', 'signpost_scope')
        records.append({'name': scalar(fields['name']), 'type': scalar(fields['event-type']),
                        'nanoseconds': number(fields['time']), 'identifier': number(fields['identifier'])})
    expected = [('ControlBefore', 'Event')]
    for i in range(1, 4): expected += [(f'ControlInterval{i}', 'Begin'), (f'ControlInterval{i}', 'End')]
    expected.append(('ControlAfter', 'Event'))
    require([(r['name'], r['type']) for r in records] == expected, 'event_order_or_kind')
    require(all(a['nanoseconds'] < b['nanoseconds'] for a, b in zip(records, records[1:])), 'nonpositive_or_unordered_time')
    duration_ns = int(float(run.findtext('info/summary/duration')) * 1_000_000_000)
    require(records[-1]['nanoseconds'] <= duration_ns, 'outside_recording')
    intervals = []
    for i in (1, 3, 5):
        begin, end = records[i:i+2]
        require(begin['identifier'] == end['identifier'] and begin['identifier'] > 0, 'pair_identity')
        intervals.append({'name': begin['name'], 'identifier': begin['identifier'],
                          'beginNanoseconds': begin['nanoseconds'], 'endNanoseconds': end['nanoseconds'],
                          'durationNanoseconds': end['nanoseconds'] - begin['nanoseconds']})
    require(len({i['identifier'] for i in intervals}) == 3, 'ambiguous_interval_ids')
    return {'pid': pid, 'subsystem': subsystem, 'category': 'OwnedControl', 'rowCount': 8,
            'boundaryEventCount': 2, 'intervalPairCount': 3, 'schema': 'os-signpost',
            'resolvedTableOrdinal': index + 1, 'orderedPositiveIntervals': intervals,
            'recordingDurationNanoseconds': duration_ns}


def validate_run(receipt, status, command, pid, subsystem, udid):
    require(receipt['captureQualified'] is False and receipt['expectedEventsProven'] is False
            and receipt['outcome'] == 'exported_pending_event_schema_review' and 'error' not in receipt, 'original_capture_state')
    require(receipt['limits']['finalizationSeconds'] == 30 and receipt['limits']['startupSeconds'] == 15
            and receipt['limits']['recordSeconds'] == 5 and receipt['limits']['exportSeconds'] == 10, 'recorded_budgets')
    require(receipt['readinessObserved'] is True and receipt['notificationControlPassed'] is True, 'readiness')
    require(receipt['simulatorUDID'] == udid and receipt['subsystem'] == subsystem, 'receipt_scope')
    stages = [receipt['helperInitialStatus'], receipt['helperEmissionStatus'], receipt['helperFinalStatus']]
    require([s['stage'] for s in stages] == ['waiting', 'emitted', 'finished'], 'helper_stage_order')
    require(status == stages[-1] and command == 'Q ' + receipt['nonce'] + '\n', 'normal_helper_quit')
    binding = receipt['helper']['binding']
    for entry in stages:
        require(entry['compiledForSimulator'] is True and entry['simulatorUDID'] == udid
                and entry['pid'] == pid == binding['pid'] and entry['subsystem'] == subsystem
                and entry['nonce'] == receipt['nonce'] and entry['uid'] == binding['uid']
                and entry['parentPID'] == binding['parentPID'], 'helper_status_binding')
    require(receipt['helper']['signals'] == [] and receipt['helper']['terminalVerified'] is True, 'helper_cleanup')
    records = receipt['processes']; processes = {entry['label']: entry for entry in records}
    require(len(records) == 3 and set(processes) == {'simctl-spawn', 'tracer', 'toc'}, 'process_inventory')
    for entry in records:
        require(entry['exitCode'] == 0 and entry['signals'] == [] and entry['terminalVerified'] is True, 'normal_process_exit')
        require(entry['pid'] == entry['binding']['pid'] and entry['binding']['startTimeMicros'] >= int(entry['spawnEpoch'] * 1e6), 'process_binding')
    require(len({r['binding']['parentPID'] for r in records}) == 1
            and len({r['binding']['uid'] for r in records} | {binding['uid']}) == 1, 'process_owner')
    require(receipt['allOwnedProcessesTerminal'] is True and receipt['notificationCancelStatus'] == [0, 0], 'terminal_cleanup')
    tracer, toc = processes['tracer'], processes['toc']
    argv = tracer['argv']
    require(argv[argv.index('--device') + 1] == udid and argv[argv.index('--attach') + 1] == str(pid)
            and argv[argv.index('--template') + 1] == 'Logging'
            and argv[argv.index('--time-limit') + 1] == '5s' and '--all-processes' not in argv, 'tracer_scope')
    require(tracer['spawnEpoch'] <= receipt['readinessEpoch'] <= receipt['emissionReleasedEpoch'] <= toc['spawnEpoch'] <= receipt['finishedEpoch'], 'phase_order')
    require(receipt['readinessEpoch'] - tracer['spawnEpoch'] <= 15, 'startup_budget')
    require(toc['spawnEpoch'] - receipt['emissionReleasedEpoch'] <= 30, 'finalization_upper_bound')
    require(receipt['finishedEpoch'] - toc['spawnEpoch'] <= 10, 'toc_export_upper_bound')
    return processes
