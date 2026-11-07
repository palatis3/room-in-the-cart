#!/usr/bin/env python3
"""Summarize scoped UIKit signposts as diagnostic evidence, never a gate."""
import argparse, json, math, re
from datetime import datetime, timezone
from pathlib import Path

PATTERN = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) Sp RoomInTheCart\[(\d+):[^\]]+\] \[com\.apple\.UIKit:ScrollView\] \[spid (0x[0-9a-f]+), process,\s+(begin|end)\] Scroll_DraggingAndDeceleration:')
SELECTOR = 'ReleasePerformanceUITests/testScrollingPerformanceOnFiveHundredItemPickup()'
URL_SUFFIX = '/RoomInTheCartUITests/' + SELECTOR.removesuffix('()')


# Receipt limits affect diagnostic retention only, never metric acceptance.
ENDPOINT_LIMIT = 128
ENDPOINT_MARGIN_SECONDS = 5.0

def endpoint_receipt(events, windows, reset_start):
    """Retain scoped endpoint fields, never raw lines, PID or signpost IDs."""
    receipt = {'diagnosticOnly': True, 'maximumRetainedEvents': ENDPOINT_LIMIT,
               'marginSeconds': ENDPOINT_MARGIN_SECONDS,
               'timestampBasis': 'seconds from first enclosing swipe activity start; not measurement boundaries'}
    if (not windows or type(reset_start) not in (int, float)
            or not math.isfinite(reset_start) or reset_start > windows[0][0]):
        return {**receipt, 'status': 'scope_unavailable'}
    origin = windows[0][0]
    lower = reset_start - ENDPOINT_MARGIN_SECONDS
    upper = windows[-1][2] + ENDPOINT_MARGIN_SECONDS
    scoped = [e for e in events if lower <= e[0] <= upper]
    pids, ids, retained = {}, {}, []
    for ts, pid, sid, kind in scoped[:ENDPOINT_LIMIT]:
        # Ordinal tokens preserve equality within this receipt, not cross-run identity.
        process = pids.setdefault(pid, f'process-{len(pids) + 1}')
        signpost = ids.setdefault((pid, sid), f'signpost-{len(ids) + 1}')
        indices = [i for i, (start, _, end) in enumerate(windows) if start <= ts <= end]
        retained.append({'offsetSeconds': round(ts - origin, 6), 'kind': kind,
                         'processToken': process, 'signpostToken': signpost,
                         'windowIndices': indices})
    return {**receipt, 'status': 'truncated' if len(scoped) > ENDPOINT_LIMIT else 'retained',
            'originUnixUTC': origin,
            'scopeStartOffsetSeconds': round(lower - origin, 6),
            'scopeEndOffsetSeconds': round(upper - origin, 6),
            'scopedEventCount': len(scoped), 'retainedEventCount': len(retained),
            'omittedEventCount': max(0, len(scoped) - ENDPOINT_LIMIT),
            'ordering': 'captured log order; tokens preserve equality, not unique gesture identity',
            'windows': [{'invocationIndex': i, 'swipeStartOffsetSeconds': round(start-origin, 6),
                         'synthesisStartOffsetSeconds': round(synthesis-origin, 6),
                         'followingActivityStartOffsetSeconds': round(end-origin, 6)}
                        for i, (start, synthesis, end) in enumerate(windows)],
            'events': retained}

def summarize(log, activity, capture_status, activity_status):
    out = {'schemaVersion': 2, 'diagnosticOnly': True, 'captureStatus': capture_status,
           'activityStatus': activity_status, 'metric': 'com.apple.UIKit:ScrollView Scroll_DraggingAndDeceleration', 'windows': [],
           'endpointEvidence': {'diagnosticOnly': True, 'status': 'unavailable'}}
    if capture_status != 'ok' or activity_status != 'ok':
        out['status'] = 'capture_unavailable' if capture_status != 'ok' else 'activities_unavailable'
        return out
    try:
        obj = json.loads(activity)
        if (obj.get('testIdentifier') != SELECTOR or len(obj.get('testRuns', [])) != 1
                or not obj.get('testIdentifierURL', '').endswith(URL_SUFFIX)):
            raise ValueError('unexpected test identity or run count')
        activities = obj['testRuns'][0]['activities']
        reset = next(i for i, a in enumerate(activities) if a['title'].startswith('Swipe down CollectionView'))
        events = []
        for line in log.splitlines():
            m = PATTERN.match(line)
            if m:
                stamp, pid, sid, kind = m.groups()
                ts = datetime.fromisoformat(stamp).replace(tzinfo=timezone.utc).timestamp()
                events.append((ts, int(pid), sid, kind))
        out['parsedEventCount'] = len(events)
        out['candidateLineCount'] = sum('Scroll_DraggingAndDeceleration' in line for line in log.splitlines())
        out['unparsedCandidateCount'] = out['candidateLineCount'] - len(events)
        out['timeZoneOfLog'] = 'UTC'
        out['windowBasis'] = 'enclosing swipe activity start to following activity start; not XCTest measurement boundaries'
        previous_end = None
        process_ids = set()
        receipt_windows = []
        for swipe, following in zip(activities[reset:], activities[reset+1:]):
            if not swipe['title'].startswith('Swipe up CollectionView'): continue
            starts = [a['startTime'] for a in swipe.get('childActivities', []) if a['title'] == 'Synthesize event']
            if len(starts) != 1: raise ValueError('missing or ambiguous synthesis')
            # Exported synthesis timestamps can follow UIKit's begin event.
            # Use the enclosing gesture activity, without treating this
            # diagnostic window as the actual XCTest collection interval.
            start, synthesis, end = swipe['startTime'], starts[0], following['startTime']
            if (any(type(value) not in (int, float) or not math.isfinite(value)
                    for value in (start, synthesis, end))
                    or not start <= synthesis < end
                    or (previous_end is not None and start <= previous_end)):
                raise ValueError('invalid or overlapping window')
            previous_end = end
            receipt_windows.append((start, synthesis, end))
            selected = [event for event in events if start <= event[0] <= end]
            process_ids.update(event[1] for event in selected)
            pairs = []
            # Extra, duplicate or interleaved endpoints make this window
            # ambiguous; never silently select one plausible adjacent pair.
            if len(selected) == 2:
                a, b = selected
                if a[3] == 'begin' and b[3] == 'end' and a[1:3] == b[1:3] and b[0] > a[0]:
                    pairs.append({'durationSeconds': round(b[0]-a[0], 3)})
            out['windows'].append({'case': 'warm-up' if not out['windows'] else f'measured swipe {len(out["windows"])}', 'eventCount': len(selected), 'pairCount': len(pairs), 'pairs': pairs})
        out['endpointEvidence'] = endpoint_receipt(events, receipt_windows, activities[reset].get('startTime'))
        out['matchedProcessCount'] = len(process_ids)
        out['status'] = ('unparsed_events' if out['unparsedCandidateCount'] else 'zero_events' if not events
                         else 'incomplete_windows' if len(out['windows']) != 6 or len(process_ids) != 1
                         or any(w['pairCount'] != 1 for w in out['windows']) else 'captured')
    except (ValueError, KeyError, TypeError, AttributeError, IndexError, StopIteration, OverflowError):
        out['status'] = 'parse_error'
    return out

def main():
    p=argparse.ArgumentParser();p.add_argument('--log',required=True);p.add_argument('--activities',required=True);p.add_argument('--capture-status',required=True);p.add_argument('--activity-status',required=True);p.add_argument('--output',required=True);a=p.parse_args()
    def read(path):
        try: return Path(path).read_text()
        except (OSError, UnicodeError): return ''
    out=summarize(read(a.log),read(a.activities),a.capture_status,a.activity_status)
    if 'status' not in out: out['status'] = 'capture_unavailable' if a.capture_status != 'ok' else 'activities_unavailable'
    Path(a.output).write_text(json.dumps(out,indent=2,allow_nan=False)+'\n')
if __name__ == '__main__': main()
