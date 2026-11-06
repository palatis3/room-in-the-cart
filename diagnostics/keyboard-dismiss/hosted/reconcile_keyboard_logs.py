#!/usr/bin/env python3
"""Offline reconciliation of narrowly filtered compact UrgentRepair OSLog; never a gate."""
import argparse
from collections import Counter, defaultdict
from datetime import datetime
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path
import re

SUBSYSTEM = 'dev.roominthecart.urgentkeyboarddiagnostic'
CATEGORY = 'events'
SCOPE = f'[{SUBSYSTEM}:{CATEGORY}]'
FLAGS = ('previousFocus', 'focus', 'previousScene', 'scene')
APPLICABLE = {
    'done.enter': {'focus'}, 'done.exit': {'focus'},
    'focus.change': {'previousFocus', 'focus'},
    'keyboard.willHide': set(), 'keyboard.didHide': set(),
    'scene.observe': {'previousScene', 'scene'},
}
RANGES = {'previousFocus': range(5), 'focus': range(5), 'previousScene': range(4), 'scene': range(4)}
MAX_LOG_BYTES = 32 * 1024 * 1024
PREFIX = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+I\s+RoomInTheCart\[(\d+):[0-9a-fA-F]+\]\s+' + re.escape(SCOPE) + r'\s+(.*)$')
MESSAGE = re.compile(r'^sequence=([0-9]{1,20}) uptime=([0-9]{1,20}(?:\.[0-9]{1,12})?) event=([a-zA-Z.]+)' + ''.join(' '+name+r'=(-1|[0-4])' for name in FLAGS) + '$')
STATUSES = ('ok', 'failed', 'unknown')


def exact_decimal(value):
    # Decimal.normalize uses context precision; do not round distinct event times.
    text = format(value, 'f')
    return text.rstrip('0').rstrip('.') if '.' in text else text


def parse(text):
    """Do not retain raw lines, unknown fields or unrelated diagnostic messages."""
    events, malformed, unrelated, candidates = [], [], 0, 0
    for number, line in enumerate(text.splitlines(), 1):
        if SUBSYSTEM not in line:
            if line.strip(): unrelated += 1
            continue
        candidates += 1
        try:
            prefix = PREFIX.fullmatch(line)
            if prefix is None: raise ValueError()
            timestamp, pid, message = prefix.groups()
            datetime.fromisoformat(timestamp)
            pid = int(pid)
            if not 0 < pid <= 2**31 - 1: raise ValueError()
            match = MESSAGE.fullmatch(message)
            if match is None: raise ValueError()
            sequence, uptime, event, *values = match.groups()
            sequence = int(sequence)
            if not 0 < sequence <= 2**64 - 1 or event not in APPLICABLE: raise ValueError()
            stamp = Decimal(uptime)
            if not stamp.is_finite() or stamp < 0: raise ValueError()
            flags = dict(zip(FLAGS, map(int, values)))
            if any((value not in RANGES[key] if key in APPLICABLE[event] else value != -1)
                   for key, value in flags.items()): raise ValueError()
            if event == 'focus.change' and flags['previousFocus'] == flags['focus']: raise ValueError()
            events.append({'line': number, 'timestampRaw': timestamp, 'pid': pid,
                           'sequence': sequence, 'uptime': exact_decimal(stamp),
                           'event': event, **flags})
        except (ValueError, InvalidOperation):
            # No raw line or exception text: either may contain unrelated/private data.
            malformed.append(number)
    return {'events': events, 'candidateLines': candidates, 'malformedLineNumbers': malformed,
            'ignoredNonCandidateLines': unrelated}


def identity(event):
    return (event['pid'], event['sequence'], event['uptime'], event['event'],
            *(event[name] for name in FLAGS))


def gaps(sequences):
    values = sorted(set(sequences))
    return [[a + 1, b - 1] for a, b in zip(values, values[1:]) if b > a + 1]


def source_report(parsed, read_status, capture_status, timezone):
    events = parsed['events']
    counts = Counter(identity(event) for event in events)
    per_process = {}
    for pid in sorted({event['pid'] for event in events}):
        selected = [event for event in events if event['pid'] == pid]
        sequences = [event['sequence'] for event in selected]
        per_process[str(pid)] = {
            'sequenceInInputOrder': sequences,
            'missingPrefixRange': [1, min(sequences) - 1] if min(sequences) > 1 else None,
            'internalGapRanges': gaps(sequences),
            'sequenceRegressions': sum(b < a for a, b in zip(sequences, sequences[1:])),
            'uptimeRegressionsInInputOrder': sum(Decimal(b['uptime']) < Decimal(a['uptime']) for a,b in zip(selected,selected[1:])),
            'sceneObservationPresent': any(event['event'] == 'scene.observe' for event in selected),
        }
    return {**parsed, 'readStatus': read_status, 'captureStatus': capture_status,
            'wallTimeZone': timezone, 'timezoneProvenance': 'caller_declared' if timezone == 'UTC' else 'unknown',
            'eventCount': len(events), 'uniqueEventCount': len(counts),
            'exactDuplicateOccurrences': sum(count - 1 for count in counts.values()),
            'processes': per_process}


def reconcile(live, exported, *, live_status='unknown', export_status='unknown',
              live_read='ok', export_read='ok', expected_pids=(), live_timezone='unknown', export_timezone='unknown'):
    if live_timezone not in ('unknown', 'UTC') or export_timezone not in ('unknown', 'UTC'): raise ValueError('Invalid timezone metadata')
    if live_status not in STATUSES or export_status not in STATUSES: raise ValueError('Invalid capture status')
    if live_read not in ('ok','unavailable') or export_read not in ('ok','unavailable'): raise ValueError('Invalid read status')
    if any(type(pid) is not int or not 0 < pid <= 2**31-1 for pid in expected_pids):
        raise ValueError('Invalid expected process metadata')
    sources = {
        'live': source_report(parse(live), live_read, live_status, live_timezone),
        'export': source_report(parse(exported), export_read, export_status, export_timezone),
    }
    live_ids = {identity(event) for event in sources['live']['events']}
    export_ids = {identity(event) for event in sources['export']['events']}
    variants, observations = defaultdict(set), defaultdict(list)
    for source, report in sources.items():
        for event in report['events']:
            key = (event['pid'], event['sequence'])
            variants[key].add(identity(event))
            observations[key].append({'source': source, **event})
    processes = []
    all_pids = sorted({key[0] for key in variants} | set(expected_pids))
    for pid in all_pids:
        keys = sorted(key for key in variants if key[0] == pid)
        sequences = [key[1] for key in keys]
        records = [{'sequence': seq, 'conflict': len(variants[(pid, seq)]) > 1,
                    'observations': observations[(pid, seq)]} for seq in sequences]
        unique = set().union(*(variants[key] for key in keys)) if keys else set()
        observed_names = Counter(event[3] for event in unique)
        processes.append({
            'pid': pid, 'expected': pid in expected_pids, 'observed': bool(keys),
            'sceneObservationPresent': observed_names['scene.observe'] > 0,
            'missingPrefixRange': [1, min(sequences)-1] if sequences and min(sequences) > 1 else None,
            'internalGapRanges': gaps(sequences),
            'conflictingSequences': [seq for seq in sequences if len(variants[(pid, seq)]) > 1],
            'pidReuseOrCorruptionPossible': any(len(variants[key]) > 1 for key in keys),
            'observedEventNames': dict(sorted(observed_names.items())),
            'doneEnterObserved': observed_names['done.enter'] > 0,
            'records': records,
        })
    reasons = ['Log liveness, export success and matching observed sequences cannot prove exhaustive delivery.',
               'Missing final suffixes or whole launches can leave no visible sequence gap.',
               'Absent Done events mean not observed; no conclusion that the handler did not run.',
               'Done exit is synchronous return only; keyboard notifications are process-wide and do not prove animation quiescence.']
    if not all_pids: reasons.append('No scene observations or events observed.')
    if any(not process['sceneObservationPresent'] for process in processes): reasons.append('One or more processes lack a scene observation; observer lifetime and delivery remain unproven.')
    if any(report['readStatus'] != 'ok' or report['captureStatus'] != 'ok' for report in sources.values()): reasons.append('Capture/read status is failed, unavailable or unverified.')
    if any(report['malformedLineNumbers'] for report in sources.values()): reasons.append('Scoped lines could not be parsed under the fixed schema.')
    if live_ids != export_ids: reasons.append('Live and persisted observations differ.')
    if any(process['conflictingSequences'] for process in processes): reasons.append('Conflicting same-process sequence values; do not select a preferred variant.')
    return {
        'schemaVersion': 1, 'diagnosticOnly': True, 'status': 'inconclusive',
        'exhaustiveDeliveryEstablished': False, 'negativeEventInferencePermitted': False,
        'absenceMeaning': 'not_observed', 'reasons': reasons,
        'comparison': {'liveOnlyUniqueEvents': len(live_ids-export_ids),
                       'exportOnlyUniqueEvents': len(export_ids-live_ids),
                       'sharedUniqueEvents': len(live_ids & export_ids),
                       'observedEventSetsEqual': live_ids == export_ids},
        'sources': sources, 'processes': processes,
    }


def read_file(path):
    try:
        if Path(path).stat().st_size > MAX_LOG_BYTES: return '', 'unavailable', None
        data = Path(path).read_bytes()
        if len(data) > MAX_LOG_BYTES: return '', 'unavailable', None
        return data.decode('utf-8'), 'ok', hashlib.sha256(data).hexdigest()
    except (OSError, UnicodeError):
        return '', 'unavailable', None


MAX_EXPORT_WINDOW_SECONDS = 45 * 60  # Existing finite live-capture cap; no harness timing change.
UUID_TEXT = re.compile(r'[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}')


def strict_utc_timestamp(value):
    if not isinstance(value,str) or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\+0000',value):
        raise ValueError('Invalid UTC timestamp schema')
    return datetime.strptime(value,'%Y-%m-%d %H:%M:%S%z')


def unique_json_object(pairs):
    result={}
    for key,value in pairs:
        if key in result: raise ValueError('Duplicate receipt key')
        result[key]=value
    return result


def capture_provenance(folder):
    folder=Path(folder); records={}; hashes={}; invalid=[]
    for name in ('capture-liveness.json','capture-owner-final.json','capture-final.json','events-export.status.json',
                 'owned-device.json','capture-window.json'):
        try:
            with (folder/name).open('rb') as stream: data=stream.read(65537)
            if len(data)>65536: raise ValueError()
            hashes[name]=hashlib.sha256(data).hexdigest()
            value=json.loads(data,object_pairs_hook=unique_json_object)
            if not isinstance(value,dict): raise ValueError()
            records[name]=value
        except (OSError,ValueError): invalid.append(name)
    owned=records.get('owned-device.json',{});window=records.get('capture-window.json',{})
    owned_valid=(set(owned)=={'name','runtime','udid'} and isinstance(owned.get('name'),str)
        and 0<len(owned['name'])<=512 and owned.get('runtime')=='com.apple.CoreSimulator.SimRuntime.iOS-26-2'
        and isinstance(owned.get('udid'),str) and UUID_TEXT.fullmatch(owned['udid']) is not None
        and owned['udid'].replace('-','')!='0'*32)
    window_valid=False
    try:
        if set(window)!={'startUTC'}: raise ValueError()
        strict_utc_timestamp(window['startUTC']);window_valid=True
    except (ValueError,KeyError): pass
    for name,valid in [('owned-device.json',owned_valid),('capture-window.json',window_valid)]:
        if not valid and name not in invalid: invalid.append(name)
    live=records.get('capture-liveness.json',{});owner=records.get('capture-owner-final.json',{});child=records.get('capture-final.json',{})
    live_ok=(live.get('ownerAliveBeforeStop') is True and owner.get('ownerReaped') is True
        and owner.get('gracefulFinalizationConfirmed') is True and owner.get('helperFinalReceiptPresent') is True
        and type(owner.get('exitCode')) is int and owner['exitCode']==0
        and child.get('shutdownComplete') is True and type(child.get('helperExit')) is int and child['helperExit']==0)
    export=records.get('events-export.status.json',{});argv=export.get('argv',[])
    predicate='subsystem == "'+SUBSYSTEM+'" AND category == "events"'
    def option(key):
        return argv[argv.index(key)+1] if isinstance(argv,list) and argv.count(key)==1 and argv.index(key)+1<len(argv) else None
    exact_command=(isinstance(argv,list) and len(argv)==17 and argv[:3]==['xcrun','simctl','spawn']
        and isinstance(argv[3],str) and re.fullmatch('[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}',argv[3]) is not None
        and argv[4:7]==['log','show','--start'] and argv[8]=='--end'
        and argv[10:14]==['--info','--style','compact','--timezone'] and argv[15]=='--predicate'
        and export.get('stage')=='events-export' and type(export.get('timeoutSeconds')) is int and export['timeoutSeconds']==45 and export.get('stderrSeparate') is True)
    device_matches=bool(exact_command and owned_valid and argv[3]==owned['udid'])
    window_matches=False;window_seconds=None
    try:
        start=strict_utc_timestamp(option('--start'));end=strict_utc_timestamp(option('--end'))
        window_seconds=int((end-start).total_seconds())
        window_matches=(window_valid and option('--start')==window['startUTC']
            and 0<=window_seconds<=MAX_EXPORT_WINDOW_SECONDS)
    except ValueError: pass
    export_scope=bool(exact_command and device_matches and window_matches
        and option('--timezone')=='UTC' and option('--predicate')==predicate)
    export_ok=export_scope and type(export.get('exitCode')) is int and export['exitCode']==0 and export.get('status')=='passed'
    return {'receiptSHA256':hashes,'missingOrInvalidReceipts':invalid,
        'ownedDeviceReceiptValid':owned_valid,'captureWindowReceiptValid':window_valid,
        'exportDeviceMatchesOwned':device_matches,'exportWindowMatchesCapture':window_matches,
        'exportWindowSeconds':window_seconds,'maximumExportWindowSeconds':MAX_EXPORT_WINDOW_SECONDS,
        'liveFinalizationVerified':live_ok,'exportCommandScopeVerified':export_scope,'exportCommandPassed':export_ok,
        'liveWallTimeZone':'unknown','exportWallTimeZone':'UTC' if export_scope else 'unknown',
        'timezoneProvenance':'captured_command_receipt' if export_scope else 'unknown',
        'exhaustiveDeliveryEstablished':False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', required=True)
    parser.add_argument('--export', dest='exported', required=True)
    parser.add_argument('--live-status', choices=STATUSES, default='unknown')
    parser.add_argument('--export-status', choices=STATUSES, default='unknown')
    parser.add_argument('--live-timezone', choices=('unknown', 'UTC'), default='unknown')
    parser.add_argument('--export-timezone', choices=('unknown', 'UTC'), default='unknown')
    parser.add_argument('--expected-pid', type=int, action='append', default=[])
    parser.add_argument('--capture-receipts-dir')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    live, live_read, live_hash = read_file(args.live)
    exported, export_read, export_hash = read_file(args.exported)
    provenance=capture_provenance(args.capture_receipts_dir) if args.capture_receipts_dir else None
    if provenance:
        args.live_status='ok' if provenance['liveFinalizationVerified'] else 'unknown'
        args.export_status='ok' if provenance['exportCommandPassed'] else 'unknown'
        args.live_timezone='unknown'; args.export_timezone=provenance['exportWallTimeZone']
    try:
        result = reconcile(live, exported, live_status=args.live_status, export_status=args.export_status,
                           live_read=live_read, export_read=export_read, expected_pids=args.expected_pid,
                           live_timezone=args.live_timezone, export_timezone=args.export_timezone)
    except ValueError as error:
        parser.error(str(error))
    if provenance:
        result['captureProvenance']=provenance
        result['sources']['export']['timezoneProvenance']=provenance['timezoneProvenance']
    result['inputSHA256'] = {'live': live_hash, 'export': export_hash}
    Path(args.output).write_text(json.dumps(result, indent=2, allow_nan=False)+'\n')
    # Exit 0 means a diagnostic report was written, never test acceptance/completeness.
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
