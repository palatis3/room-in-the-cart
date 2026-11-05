#!/usr/bin/env python3
"""Summarize scoped UIKit signposts as diagnostic evidence, never a gate."""
import argparse, json, math, re
from datetime import datetime, timezone
from pathlib import Path

PATTERN = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) Sp RoomInTheCart\[(\d+):[^\]]+\] \[com\.apple\.UIKit:ScrollView\] \[spid (0x[0-9a-f]+), process,\s+(begin|end)\] Scroll_DraggingAndDeceleration:')
SELECTOR = 'ReleasePerformanceUITests/testScrollingPerformanceOnFiveHundredItemPickup()'
URL_SUFFIX = '/RoomInTheCartUITests/' + SELECTOR.removesuffix('()')

def summarize(log, activity, capture_status, activity_status):
    out = {'schemaVersion': 1, 'diagnosticOnly': True, 'captureStatus': capture_status,
           'activityStatus': activity_status, 'metric': 'com.apple.UIKit:ScrollView Scroll_DraggingAndDeceleration', 'windows': []}
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
        previous_end = None
        process_ids = set()
        for swipe, following in zip(activities[reset:], activities[reset+1:]):
            if not swipe['title'].startswith('Swipe up CollectionView'): continue
            starts = [a['startTime'] for a in swipe.get('childActivities', []) if a['title'] == 'Synthesize event']
            if len(starts) != 1: raise ValueError('missing or ambiguous synthesis')
            start, end = starts[0], following['startTime']
            if (type(start) not in (int, float) or type(end) not in (int, float)
                    or not math.isfinite(start) or not math.isfinite(end) or end <= start
                    or (previous_end is not None and start <= previous_end)):
                raise ValueError('invalid or overlapping window')
            previous_end = end
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
