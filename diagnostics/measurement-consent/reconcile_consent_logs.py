#!/usr/bin/env python3
"""Offline reconciliation of narrowly filtered compact consent OSLog; never a gate."""
import argparse
from collections import Counter, defaultdict
from datetime import datetime
from decimal import Decimal, InvalidOperation
import hashlib
import json
from pathlib import Path
import re

SUBSYSTEM = 'dev.roominthecart.measurementconsentdiagnostic'
CATEGORY = 'events'
SCOPE = f'[{SUBSYSTEM}:{CATEGORY}]'
FLAGS = ('requested', 'ready', 'workspacePresent', 'enabledValue', 'sameWorkspace',
         'otherReady', 'otherWorkspacePresent', 'workspacesDistinct')
APPLICABLE = {
    'fixture.ready': {'ready', 'workspacePresent', 'otherReady', 'otherWorkspacePresent', 'workspacesDistinct'},
    'binding.enter': {'requested', 'ready', 'workspacePresent', 'enabledValue'},
    'binding.exit': {'requested', 'ready', 'workspacePresent', 'enabledValue', 'sameWorkspace'},
    'consent.set.enter': {'requested', 'workspacePresent', 'enabledValue'},
    'consent.set.exit': {'requested', 'workspacePresent', 'enabledValue'},
    'consent.set.rejectedMissingWorkspace': {'requested', 'workspacePresent'},
    'consent.reset': set(),
}
PREFIX = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+I\s+RoomInTheCart\[(\d+):[0-9a-fA-F]+\]\s+' + re.escape(SCOPE) + r'\s+(.*)$')
MESSAGE = re.compile(r'^sequence=([0-9]{1,20}) uptime=([0-9]{1,20}(?:\.[0-9]{1,12})?) event=([a-zA-Z.]+)' + ''.join(' '+name+r'=(-1|0|1)' for name in FLAGS) + '$')
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
            if any((value not in (0, 1) if key in APPLICABLE[event] else value != -1)
                   for key, value in flags.items()): raise ValueError()
            if event == 'consent.set.rejectedMissingWorkspace' and flags['workspacePresent'] != 0:
                raise ValueError()
            events.append({'line': number, 'timestampUTC': timestamp, 'pid': pid,
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


def source_report(parsed, read_status, capture_status):
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
            'activationObserved': any(event['event'] == 'fixture.ready' for event in selected),
        }
    return {**parsed, 'readStatus': read_status, 'captureStatus': capture_status,
            'eventCount': len(events), 'uniqueEventCount': len(counts),
            'exactDuplicateOccurrences': sum(count - 1 for count in counts.values()),
            'processes': per_process}


def reconcile(live, exported, *, live_status='unknown', export_status='unknown',
              live_read='ok', export_read='ok', expected_pids=()):
    if live_status not in STATUSES or export_status not in STATUSES: raise ValueError('Invalid capture status')
    if any(type(pid) is not int or not 0 < pid <= 2**31-1 for pid in expected_pids):
        raise ValueError('Invalid expected process metadata')
    sources = {
        'live': source_report(parse(live), live_read, live_status),
        'export': source_report(parse(exported), export_read, export_status),
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
            'activationObserved': observed_names['fixture.ready'] > 0,
            'missingPrefixRange': [1, min(sequences)-1] if sequences and min(sequences) > 1 else None,
            'internalGapRanges': gaps(sequences),
            'conflictingSequences': [seq for seq in sequences if len(variants[(pid, seq)]) > 1],
            'pidReuseOrCorruptionPossible': any(len(variants[key]) > 1 for key in keys),
            'observedEventNames': dict(sorted(observed_names.items())),
            'bindingEnterObserved': observed_names['binding.enter'] > 0,
            'records': records,
        })
    reasons = ['Log liveness, export success and matching observed sequences cannot prove exhaustive delivery.',
               'Missing final suffixes or whole launches can leave no visible sequence gap.',
               'Absent setter events mean not observed; no conclusion that a setter did not run.',
               'Geometry does not establish actual touch target or framework event delivery.']
    if not all_pids: reasons.append('No process activation or events observed.')
    if any(not process['activationObserved'] for process in processes): reasons.append('One or more processes lack observed activation.')
    if any(report['readStatus'] != 'ok' or report['captureStatus'] != 'ok' for report in sources.values()): reasons.append('Capture/read status is failed, unavailable or unverified.')
    if any(report['malformedLineNumbers'] for report in sources.values()): reasons.append('Scoped lines could not be parsed under the fixed schema.')
    if live_ids != export_ids: reasons.append('Live and persisted observations differ.')
    if any(process['conflictingSequences'] for process in processes): reasons.append('Conflicting same-process sequence values; do not select a preferred variant.')
    return {
        'schemaVersion': 1, 'diagnosticOnly': True, 'status': 'inconclusive',
        'exhaustiveDeliveryEstablished': False, 'noSetterInferencePermitted': False,
        'absenceMeaning': 'not_observed', 'reasons': reasons,
        'comparison': {'liveOnlyUniqueEvents': len(live_ids-export_ids),
                       'exportOnlyUniqueEvents': len(export_ids-live_ids),
                       'sharedUniqueEvents': len(live_ids & export_ids),
                       'observedEventSetsEqual': live_ids == export_ids},
        'sources': sources, 'processes': processes,
    }


def read_file(path):
    try:
        data = Path(path).read_bytes()
        return data.decode('utf-8'), 'ok', hashlib.sha256(data).hexdigest()
    except (OSError, UnicodeError):
        return '', 'unavailable', None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', required=True)
    parser.add_argument('--export', dest='exported', required=True)
    parser.add_argument('--live-status', choices=STATUSES, default='unknown')
    parser.add_argument('--export-status', choices=STATUSES, default='unknown')
    parser.add_argument('--expected-pid', type=int, action='append', default=[])
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    live, live_read, live_hash = read_file(args.live)
    exported, export_read, export_hash = read_file(args.exported)
    try:
        result = reconcile(live, exported, live_status=args.live_status, export_status=args.export_status,
                           live_read=live_read, export_read=export_read, expected_pids=args.expected_pid)
    except ValueError as error:
        parser.error(str(error))
    result['inputSHA256'] = {'live': live_hash, 'export': export_hash}
    Path(args.output).write_text(json.dumps(result, indent=2, allow_nan=False)+'\n')
    # Exit 0 means a diagnostic report was written, never test acceptance/completeness.
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
