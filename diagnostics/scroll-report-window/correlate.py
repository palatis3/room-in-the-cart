"""Diagnostic observations only; never computes or repairs an acceptance metric."""
import argparse
import hashlib
import json
import math
from pathlib import Path


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def analyze(witness, diagnostic):
    out = {'diagnosticOnly': True, 'status': 'unavailable', 'issues': [], 'reports': [],
           'limits': 'Witness report bounds do not establish built-in collector bounds or receipt. UTC clock jumps and delivery delay are not bounded. No warm-up identity is inferred.'}
    issues = out['issues']
    try:
        if (witness['schemaVersion'] != 1 or witness['diagnosticOnly'] is not True
                or witness['status'] != 'recorded' or witness['omittedEvents'] != 0):
            raise ValueError('witness is absent, truncated, or has no reports')
        events = witness['events']
        if (not isinstance(events, list) or len(events) != witness['totalEvents']
                or len(events) > 128 or witness['maximumRetainedEvents'] != 128
                or [e['sequence'] for e in events] != list(range(1, len(events)+1))):
            raise ValueError('invalid recorder inventory')
        created = [e['instanceOrdinal'] for e in events if e['kind'] == 'created']
        if (len(set(created)) != len(created) or len(created) != int(witness['totalInstances'])
                or any(e['instanceOrdinal'] not in created for e in events)
                or any(e['kind'] not in ('created','willBegin','didStop','report') for e in events)):
            raise ValueError('invalid instance inventory')
        if any(not finite(e['callbackUptime']) or not finite(e['callbackUnixUTC']) for e in events):
            raise ValueError('invalid callback observation clocks')
        reports = [e for e in events if e['kind'] == 'report']
        out['instancesWithoutReports'] = []
        for instance in created:
            lifecycle = [e['kind'] for e in events if e['instanceOrdinal'] == instance]
            if 'report' not in lifecycle:
                out['instancesWithoutReports'].append({'instanceOrdinal':instance,'lifecycle':lifecycle})
                if lifecycle != ['created']:
                    issues.append('instance '+instance+': measurement lifecycle has no report')
        if len(reports) != witness['reportCallbacks'] or not reports:
            raise ValueError('report inventory mismatch')
        receipt = diagnostic['endpointEvidence']
        if (diagnostic['schemaVersion'] != 2 or diagnostic['diagnosticOnly'] is not True
                or diagnostic['captureStatus'] != 'ok' or diagnostic['activityStatus'] != 'ok'
                or diagnostic['status'] != 'captured' or diagnostic['unparsedCandidateCount'] != 0
                or diagnostic['matchedProcessCount'] != 1 or receipt['status'] != 'retained'
                or receipt['omittedEventCount'] != 0 or receipt['diagnosticOnly'] is not True):
            raise ValueError('endpoint receipt unavailable, incomplete, or ambiguous')
        origin = receipt['originUnixUTC']
        lo, hi = receipt['scopeStartOffsetSeconds'], receipt['scopeEndOffsetSeconds']
        endpoints = receipt['events']
        if (not all(finite(x) for x in (origin,lo,hi)) or lo >= hi
                or len(endpoints) != receipt['retainedEventCount']
                or len(endpoints) != receipt['scopedEventCount'] or len(endpoints) > 128):
            raise ValueError('invalid endpoint scope/counts')
        if any(not finite(e['offsetSeconds']) or not lo <= e['offsetSeconds'] <= hi
               or e['kind'] not in ('begin','end') or not e['processToken'] or not e['signpostToken'] for e in endpoints):
            raise ValueError('invalid endpoint fields')
        windows = receipt['windows']
        if len(windows) != 6 or [w['invocationIndex'] for w in windows] != list(range(6)):
            raise ValueError('expected six original gesture activities, with no inferred warm-up mapping')
        previous = None
        for w in windows:
            a,b,c = (w[k] for k in ('swipeStartOffsetSeconds','synthesisStartOffsetSeconds','followingActivityStartOffsetSeconds'))
            if (not all(finite(x) for x in (a,b,c)) or not lo <= a <= b < c <= hi
                    or (previous is not None and a <= previous)):
                raise ValueError('invalid gesture activity chronology')
            previous = c
        for event in endpoints:
            expected = [w['invocationIndex'] for w in windows if w['swipeStartOffsetSeconds'] <= event['offsetSeconds'] <= w['followingActivityStartOffsetSeconds']]
            if event['windowIndices'] != expected:
                raise ValueError('endpoint window inventory mismatch')
        matched_processes = {event['processToken'] for event in endpoints if event['windowIndices']}
        if len(matched_processes) != 1 or len(matched_processes) != diagnostic['matchedProcessCount']:
            raise ValueError('contradictory process inventory across gesture activities')
        seen = set()
        for event in reports:
            instance = event['instanceOrdinal']
            lifecycle = [e['kind'] for e in events if e['instanceOrdinal'] == instance]
            if lifecycle != ['created','willBegin','didStop','report']:
                issues.append('instance '+instance+': unexpected lifecycle '+str(lifecycle))
            start, end = event['suppliedStart'], event['suppliedEnd']
            for bound in (start,end):
                if not finite(bound.get('unixSeconds')) or bound.get('invalidUnixSeconds') is not None:
                    raise ValueError('invalid supplied UTC bound')
                for key in ('absoluteTime','absoluteTimeNanoSeconds'):
                    value = bound[key]
                    if not isinstance(value,str) or not value.isascii() or not value.isdecimal() or not 0 <= int(value) <= 2**64-1:
                        raise ValueError('invalid lossless UInt64 bound')
            a,b = start['unixSeconds'],end['unixSeconds']
            ticks = int(end['absoluteTime'])-int(start['absoluteTime'])
            nanos = int(end['absoluteTimeNanoSeconds'])-int(start['absoluteTimeNanoSeconds'])
            if b <= a or ticks <= 0 or nanos <= 0:
                raise ValueError('reversed or empty supplied interval')
            if abs((b-a)-nanos/1e9) > 0.001:
                issues.append('instance '+instance+': UTC/monotonic deltas differ by more than 1 ms; not a clock-accuracy bound')
            overlap = [w['invocationIndex'] for w in windows if a < origin+w['followingActivityStartOffsetSeconds'] and b > origin+w['swipeStartOffsetSeconds']]
            observation = {'instanceOrdinal':instance,'startUnixUTC':a,'endUnixUTC':b,
                           'suppliedMonotonicSeconds':nanos/1e9,'dateMinusMonotonicSeconds':(b-a)-nanos/1e9,
                           'overlappingActivityIndices':overlap}
            if len(overlap) != 1:
                issues.append('instance '+instance+': missing or ambiguous activity overlap')
            elif overlap[0] in seen:
                issues.append('multiple reports overlap activity '+str(overlap[0]))
            else:
                index=overlap[0];seen.add(index)
                w=windows[index]
                selected=[e for e in endpoints if w['swipeStartOffsetSeconds'] <= e['offsetSeconds'] <= w['followingActivityStartOffsetSeconds']]
                if (len(selected) != 2 or [e['kind'] for e in selected] != ['begin','end']
                        or selected[0]['processToken'] != selected[1]['processToken']
                        or selected[0]['signpostToken'] != selected[1]['signpostToken']
                        or selected[0]['offsetSeconds'] >= selected[1]['offsetSeconds']):
                    issues.append('activity '+str(index)+': ambiguous endpoint pair')
                else:
                    left=origin+selected[0]['offsetSeconds']-a
                    right=b-(origin+selected[1]['offsetSeconds'])
                    observation.update({'endpointStartMarginSeconds':left,'endpointEndMarginSeconds':right,
                                        'numericallyContained':left>0 and right>0,
                                        'edgeWithinOneMillisecond':min(abs(left),abs(right)) <= 0.001})
            out['reports'].append(observation)
        out['unmatchedActivityIndices'] = sorted(set(range(6))-seen)
        if out['unmatchedActivityIndices']:
            issues.append('unmatched activities remain; no automatic warm-up exclusion')
        out['reportCount'] = len(reports)
        out['status'] = 'needs-review' if issues else 'observations-only'
    except (KeyError,TypeError,ValueError,OverflowError,AttributeError) as error:
        issues.append(str(error))
    return out


def unique_object(pairs):
    result = {}
    for key,value in pairs:
        if key in result: raise ValueError('duplicate JSON key: '+key)
        result[key] = value
    return result


def main():
    p=argparse.ArgumentParser();p.add_argument('witness');p.add_argument('endpoints');p.add_argument('output');a=p.parse_args()
    inputs=[]
    try:
        payloads=[]
        for name in (a.witness,a.endpoints):
            data=Path(name).read_bytes()
            if len(data)>1024*1024: raise ValueError('input exceeds 1 MiB')
            inputs.append({'path':name,'sha256':hashlib.sha256(data).hexdigest()})
            payloads.append(json.loads(data, object_pairs_hook=unique_object))
        result=analyze(*payloads)
    except (OSError,ValueError) as error:
        result={'diagnosticOnly':True,'status':'unavailable','issues':[str(error)]}
    result['inputs']=inputs
    Path(a.output).write_text(json.dumps(result,indent=2,allow_nan=False)+'\n')

if __name__=='__main__':main()
