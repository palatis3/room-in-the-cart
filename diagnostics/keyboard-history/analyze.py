#!/usr/bin/env python3
"""Read-only post-run accounting; never retries or changes the app/test runner."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import os
from restore import BASE, SELECTOR_SHA, digest, dump, require, verify_products

OUT = Path('.build/keyboard-history')


def freeze():
    source = json.loads((OUT / 'source-sha256.json').read_text())
    tracked = set(subprocess.check_output(['git', 'ls-files', '-z']).decode().strip('\0').split('\0'))
    require(tracked == set(source), 'Tracked source inventory changed')
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip() == os.environ['EXPECTED_SHA'],
            'Diagnostic HEAD changed')
    require(all(Path(p).is_file() and not Path(p).is_symlink() and digest(p) == sha for p, sha in source.items()),
            'Frozen checkout bytes changed')
    expected = json.loads((OUT / 'product-sha256.json').read_text())
    verify_products(expected, Path('.build/DerivedData/Build'))
    require(digest(OUT / 'selectors.txt') == SELECTOR_SHA, 'Frozen selector bytes changed')
    return {'source': True, 'products': True, 'selectors': True, 'productFileCount': len(expected),
            'sourceCommit': BASE, 'diagnosticOnly': True, 'releaseAcceptance': False}


def events(path):
    parsed = []; unparsed = []
    pattern = re.compile(r'RoomInTheCart\[(\d+):[^]]+\].*uptime=([0-9.]+) event=([^ ]+) site=([^ ]+)')
    if not path.exists():
        return parsed, [{'missingFile': path.name}]
    for number, line in enumerate(path.read_text(errors='replace').splitlines(), 1):
        match = pattern.search(line)
        if match:
            parsed.append({'pid': int(match[1]), 'uptime': match[2], 'event': match[3], 'site': match[4], 'line': number})
        elif 'uptime=' in line or 'event=' in line:
            unparsed.append({'line': number, 'text': line})
    return parsed, unparsed


def main():
    p = argparse.ArgumentParser(); p.add_argument('--preflight', action='store_true'); args = p.parse_args()
    if args.preflight:
        dump(OUT / 'preflight-inputs-unchanged.json', freeze())
        return
    errors = []
    try:
        dump(OUT / 'frozen-inputs-unchanged.json', freeze())
    except Exception as exc:
        errors.append('Frozen-input verification failed: ' + str(exc))
        dump(OUT / 'frozen-inputs-unchanged.json', {'verified': False, 'error': str(exc)})
    expected_order = (OUT / 'selectors.txt').read_text().splitlines()
    text = (OUT / 'Tests.log').read_text(errors='replace') if (OUT / 'Tests.log').exists() else ''
    order = []; cases = []; current = None; onboarding = []; stalls = []; restarts = []
    case_pattern = re.compile(r"Test Case '-\[RoomInTheCartUITests\.(\w+) (\w+)\]' (started\.|passed|failed|exceeded)")
    for number, line in enumerate(text.splitlines(), 1):
        match = case_pattern.search(line)
        if match:
            selector = 'RoomInTheCartUITests/' + match[1] + '/' + match[2]
            if match[3] == 'started.':
                order.append(selector)
                current = {'selector': selector, 'startLogLine': number, 'launches': [], 'terminations': [], 'outcomes': []}
                cases.append(current)
            elif current:
                current['outcomes'].append({'line': number, 'text': line})
        if 'Launch dev.roominthecart.app.debug' in line and current:
            current['launches'].append({'line': number, 'text': line})
        pid = re.search(r'Terminate dev\.roominthecart\.app\.debug:(\d+)', line)
        if pid and current:
            current['terminations'].append({'line': number, 'pid': int(pid[1]), 'text': line})
        if any(x in line for x in ['Dismiss the identified bilingual keyboard onboarding card',
                                  'Bilingual keyboard onboarding absent', 'Bilingual-keyboard-card-before-dismissal',
                                  'Bilingual-keyboard-card-dismissed']):
            onboarding.append({'selector': current['selector'] if current else None, 'line': number, 'text': line})
        if 'App animations complete notification not received' in line:
            stalls.append({'selector': current['selector'] if current else None, 'line': number, 'text': line})
        if 'Restarting after unexpected exit' in line:
            restarts.append({'line': number, 'text': line})
    streams = {}; malformed = {}
    for name in ['events.log', 'events-export.log']:
        streams[name], malformed[name] = events(OUT / name)
    def normalized(rows):
        return [(r['pid'], r['uptime'], r['event'], r['site']) for r in rows]
    live = normalized(streams['events.log']); persisted = normalized(streams['events-export.log'])
    same_order = live == persisted
    same_multiset = Counter(live) == Counter(persisted)
    per_pid = {}
    for row in streams['events.log']:
        per_pid.setdefault(str(row['pid']), []).append(row)
    def status(name):
        path = OUT / name
        return path.read_text().strip() if path.exists() else 'missing'
    capture = {'aliveBeforeStop': status('capture-alive-before-stop.txt'), 'persistedExportExit': status('event-export-exit.txt'),
               'counts': {k: len(v) for k, v in streams.items()}, 'sameSequence': same_order, 'sameEventMultiset': same_multiset,
               'unparsedEventLines': malformed}
    if order != expected_order:
        errors.append('Actual started-test order differs from original six selectors (including missing/duplicate cases).')
    if not live or not any(r['event'] == 'observer.installed' for r in streams['events.log']):
        errors.append('No diagnostic observer events captured.')
    if capture['aliveBeforeStop'] != '1' or capture['persistedExportExit'] != '0':
        errors.append('Event capture/export did not complete normally.')
    if not same_multiset or any(malformed.values()):
        errors.append('Live and persisted diagnostic captures are incomplete or disagree; inspect raw logs.')
    proof = {'diagnosticOnly': True, 'releaseAcceptance': False, 'expectedOrder': expected_order, 'actualOrder': order,
             'orderMatchesOriginal': order == expected_order, 'cases': cases, 'onboardingObservations': onboarding,
             'animationWaitTimeouts': stalls, 'runnerRestarts': restarts, 'capture': capture,
             'xcodebuildExit': status('xcodebuild-exit.txt'), 'errors': errors,
             'limits': ['No causation inferred from one result.', 'Passing is nonreproduction, not a fix or release acceptance.',
                        'Prefix varies language, keyboard use, elapsed time, and app launches together.',
                        'Fresh owned simulator does not recreate unknown original hosted-image history.',
                        'Capture agreement does not guarantee Unified Logging delivered every application event.']}
    dump(OUT / 'history-observations.json', proof)
    dump(OUT / 'parsed-events.json', {'streams': streams, 'liveEventsByPID': per_pid})
    print(json.dumps(proof, indent=2))
    require(not errors, 'Diagnostic collection/verification incomplete; preserved original test outcome.')


if __name__ == '__main__':
    main()
