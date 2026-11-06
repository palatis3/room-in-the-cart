#!/usr/bin/env python3
"""One fixed 8f qualification; no acceptance, alternate environment, or retry."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time
from uuid import UUID, uuid4

from check_ios_test_results import XCTEST_CASE_LINE
from plan_ios_tests import make_plan, DURATIONS_PATH

BASE = '8f864eafc3887ea16be996124d55fa2ca2708706'
OUT = Path('.build/toolchain-qualification')
PRODUCTS = Path('.build/DerivedData/Build/Products')
RUNTIME_NAMESPACE = 'com.apple.CoreSimulator.SimRuntime.iOS-'
DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
BUILD = '23E254a'
TOOLCHAIN = 'Xcode 26.4.1\nBuild version 17E202'
ALLOWED = {'.github/workflows/ios-performance.yml', 'scripts/qualify_ios_toolchain.py',
           'scripts/test_qualify_ios_toolchain.py', 'scripts/run_ios_toolchain_qualification.sh'}
INVENTORY_SHA = '1f5f4a17ba3865beed35b0effef1aa8800b0c27e1c7d73c9ecbda7500d9443c8'
CASES = {
    'ui06': [
        'ContextualReminderUITests/testNextShopDeferralRequestsReminderOnlyAfterExplicitScheduleAndCanCancel',
        'ContextualReminderUITests/testSavedOfferRequestsDeadlineReminderFromThatOfferAndCancelKeepsDecisionPending',
        'FreeJourneyUITests/testUrgentRepairWithoutAnOrderPersistsAcrossRestart',
        'RoomInTheCartUITests/testKnownComparisonSavesAndReopensWithItemOnlyLimit',
        'RoomInTheCartUITests/testLargestDynamicTypeAndDarkAppearanceComparisonSmoke'],
    'spanish': [
        'FreeJourneyUITests/testRecipeCaptureOpensOnFirstAttemptAndReopensAfterCancel',
        'PickupOfferUITests/testSavedOfferReopensAndUpdatesResponseAfterRestart',
        'RoomInTheCartUITests/testConfirmedComparisonDeletionSurvivesRestart',
        'RoomInTheCartUITests/testSpanishEntryPreservesOriginalFoodNameAndSavedAnswer'],
    'scroll': ['ReleasePerformanceUITests/testScrollingPerformanceOnFiveHundredItemPickup'],
}
CASES = {key: ['RoomInTheCartUITests/' + value for value in values] for key, values in CASES.items()}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(args, timeout=90):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def runtime_match(inventory, expected_identifier=None):
    matches = [r for r in inventory['runtimes'] if r.get('platform') == 'iOS' and
               isinstance(r.get('identifier'), str) and r['identifier'].startswith(RUNTIME_NAMESPACE) and
               r.get('isAvailable') is True and r.get('version') == '26.4.1' and r.get('buildversion') == BUILD]
    require(len(matches) == 1, 'Exactly one available iOS 26.4.1/23E254a runtime required; no substitution')
    runtime = matches[0]
    require(sum(r.get('identifier') == runtime['identifier'] for r in inventory['runtimes']) == 1,
            'Observed CoreSimulator runtime identifier is ambiguous')
    require(expected_identifier is None or runtime['identifier'] == expected_identifier,
            'Runtime identifier changed after initial selection')
    return runtime


def source_files():
    require(os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Qualification must be attempt 1; no reruns')
    require(command(['git', 'rev-parse', 'HEAD']) == os.environ['GITHUB_SHA'], 'Checkout SHA mismatch')
    require(not command(['git', 'status', '--porcelain']), 'Checkout is not clean')
    subprocess.run(['git', 'merge-base', '--is-ancestor', BASE, 'HEAD'], check=True)
    changes = set(command(['git', 'diff', '--name-only', BASE, 'HEAD']).splitlines())
    require(changes <= ALLOWED, f'Unexpected changes from exact 8f source: {sorted(changes - ALLOWED)}')
    return [Path(p) for p in command(['git', 'ls-files']).splitlines()]


def manifest(paths, root):
    entries = {}
    for path in sorted(paths):
        if path.is_symlink():
            value = {'symlink': os.readlink(path)}
        elif path.is_file():
            h = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    h.update(chunk)
            value = {'sha256': h.hexdigest(), 'mode': path.stat().st_mode & 0o777}
        else:
            continue
        entries[str(path.relative_to(root))] = value
    require(bool(entries), 'Empty immutable input manifest')
    return entries


def snapshot():
    return {'source': manifest(source_files(), Path('.')),
            'products': manifest(PRODUCTS.rglob('*'), PRODUCTS)}


def frozen():
    require(snapshot() == json.loads((OUT / 'frozen.json').read_text()), 'Frozen source/products changed')


def prepare(name):
    source_files()
    directory = OUT / name
    directory.mkdir(parents=True, exist_ok=False)
    actual = command(['xcodebuild', '-version'])
    (directory / 'toolchain.txt').write_text(actual + '\n')
    require(actual == TOOLCHAIN and platform.machine() == 'arm64' and
            platform.mac_ver()[0].split('.')[0] == '26', 'Exact Xcode26.4.1/17E202 on macOS26 arm64 required')
    inventory = json.loads(command(['xcrun', 'simctl', 'list', '-j'], timeout=180))
    write(directory / 'simulator-inventory.json', inventory)
    runtime = runtime_match(inventory)['identifier']
    identity = {'sourceCommit': os.environ['GITHUB_SHA'], 'baseCommit': BASE, 'runtime': runtime,
                'version': '26.4.1', 'runtimeBuild': BUILD, 'deviceType': DEVICE_TYPE,
                'architecture': platform.machine(), 'host': command(['sw_vers']),
                'imageOS': os.environ.get('ImageOS'), 'imageVersion': os.environ.get('ImageVersion'),
                'runID': os.environ['GITHUB_RUN_ID'], 'runAttempt': os.environ['GITHUB_RUN_ATTEMPT'],
                'releaseAcceptance': False, 'name': 'RITC qualification ' + name + ' ' + str(uuid4())}
    identity['simulatorID'] = command(['xcrun', 'simctl', 'create', identity['name'], DEVICE_TYPE, runtime])
    UUID(identity['simulatorID'])
    write(directory / 'identity.json', identity)
    with (directory / 'boot.log').open('w') as log:
        subprocess.run(['python3', 'scripts/boot_ios_simulator.py', identity['simulatorID']],
                       stdout=log, stderr=subprocess.STDOUT, timeout=420, check=True)
    verify_runtime(name)
    if name in CASES:
        frozen()
        (directory / 'selectors.txt').write_text('\n'.join(CASES[name]) + '\n')


def verify_runtime(name):
    directory = OUT / name
    identity = json.loads((directory / 'identity.json').read_text())
    simulator = identity['simulatorID']
    inventory = json.loads(command(['xcrun', 'simctl', 'list', '-j'], timeout=180))
    number = len(list(directory.glob('runtime-observation-*.json'))) + 1
    write(directory / f'runtime-observation-{number:02d}.json', inventory)
    require(identity['version'] == '26.4.1' and identity['runtimeBuild'] == BUILD, 'Runtime identity changed')
    runtime = runtime_match(inventory, identity['runtime'])['identifier']
    devices = [d for d in inventory['devices'].get(runtime, []) if d['udid'] == simulator]
    require(len(devices) == 1 and devices[0]['state'] == 'Booted' and
            devices[0]['deviceTypeIdentifier'] == DEVICE_TYPE, 'Owned exact iPhone17 is not booted')
    actual = command(['xcrun', 'simctl', 'getenv', simulator, 'SIMULATOR_RUNTIME_BUILD_VERSION'])
    check = {'runtime': runtime, 'version': '26.4.1', 'expectedBuild': BUILD, 'actualBuild': actual, 'matched': actual == BUILD,
             'observedUTC': time.time(), 'simulatorID': simulator}
    number = len(list(directory.glob('runtime-check-*.json'))) + 1
    write(directory / f'runtime-check-{number:02d}.json', check)
    require(check['matched'], 'Booted runtime build mismatch; no retry')
    return simulator


def inventory_check(path):
    enumeration = json.loads(path.read_text())
    plan = make_plan(enumeration, json.loads(DURATIONS_PATH.read_text()), ui_shards=10)
    config = enumeration['values'][0]
    canonical = {key: sorted(item['identifier'].removesuffix('()') for item in config[key])
                 for key in ('enabledTests', 'disabledTests')}
    require(digest(canonical) == INVENTORY_SHA, 'Full compiled Debug inventory differs from retained exact 8f')
    require(all(item in canonical['enabledTests'] for name in ('ui06', 'spanish') for item in CASES[name]),
            'Fixed history selector absent from compiled enabled inventory')
    return {'sha256': digest(canonical), 'enabledCount': len(canonical['enabledTests']),
            'disabledStoreKitCount': len(canonical['disabledTests']), 'plan': plan}


def order_check(text, expected):
    starts = []
    for line in text.splitlines():
        match = XCTEST_CASE_LINE.fullmatch(line)
        if match and match['event'] == 'started.':
            starts.append('/'.join(match.group('target', 'suite', 'method')))
    require(starts == expected, f'Exact single ordered history required; observed {starts}')
    return starts


def finish_case(name):
    directory = OUT / name
    frozen()
    simulator = verify_runtime(name)
    require((directory / 'selectors.txt').read_text() == '\n'.join(CASES[name]) + '\n', 'Selector file changed')
    starts = order_check((directory / 'Tests.log').read_text(), CASES[name])
    summary = json.loads((directory / 'test-summary.json').read_text())
    configuration, = summary['devicesAndConfigurations']
    require(configuration['testPlanConfiguration']['configurationName'] == 'Test Scheme Action',
            'Unexpected test plan configuration')
    device = configuration['device']
    require(all(device[key] == value for key, value in {
        'deviceId': simulator, 'osVersion': '26.4.1', 'osBuildNumber': BUILD,
        'modelName': 'iPhone 17', 'architecture': 'arm64', 'platform': 'iOS Simulator'}.items()),
        'XCTest result environment differs from pinned runtime')
    report = {'case': name, 'orderedStarts': starts, 'releaseAcceptance': False,
              'status': 'qualification-completed-once', 'causeFixed': False}
    if name == 'scroll':
        calibration = json.loads((directory / 'calibration.json').read_text())
        require(calibration['status'] == 'calibration-only', 'Only structural calibration is authorized')
        profiles = json.loads(Path('scripts/ios_performance_baselines.json').read_text())['profiles']
        require(not any(p['environment'] == calibration['environment'] for p in profiles),
                'Expected an explicitly unapproved environment; review any baseline change')
        require(len(profiles) == 1, 'Original single baseline profile required')
        reference = profiles[0]
        report.update(status='structural-calibration-only-unapproved-environment',
                      approvedEnvironmentMatch=False, baselineAcceptance='unavailable',
                      environment=calibration['environment'],
                      unapprovedReference={'environment': reference['environment'],
                          'comparisons': {key: {'measured': value, 'oldLimit': reference['limits']['scroll'][key],
                                               'withinOldLimit': value <= reference['limits']['scroll'][key]}
                                          for key, value in calibration['baselineValues'].items()},
                          'comparableForAcceptance': False})
    write(directory / 'qualification.json', report)


def cleanup_operation(args):
    """Retain bounded output even on timeout/error; caller always attempts delete."""
    started = time.monotonic()
    result = {'argv': args, 'timeoutSeconds': 90, 'exitCode': None, 'timedOut': False,
              'error': None, 'stdout': '', 'stderr': ''}
    stdout = stderr = ''
    try:
        completed = subprocess.run(args, capture_output=True, text=True, timeout=90, check=False)
        result['exitCode'] = completed.returncode
        stdout, stderr = completed.stdout, completed.stderr
    except subprocess.TimeoutExpired as error:
        result['timedOut'] = True
        result['error'] = str(error)
        stdout, stderr = error.stdout or '', error.stderr or ''
    except OSError as error:
        result['error'] = str(error)
    def decoded(value):
        return value.decode('utf-8', errors='replace') if isinstance(value, bytes) else value
    stdout, stderr = decoded(stdout), decoded(stderr)
    result.update(stdout=stdout[:16384], stderr=stderr[:16384],
                  stdoutTruncated=len(stdout) > 16384, stderrTruncated=len(stderr) > 16384,
                  elapsedSeconds=time.monotonic() - started)
    result['succeeded'] = result['exitCode'] == 0 and not result['timedOut'] and result['error'] is None
    return result, stdout


def cleanup():
    OUT.mkdir(parents=True, exist_ok=True)
    report = {'status': 'in-progress', 'releaseAcceptance': False, 'devices': [],
              'allOwnedDevicesProvenAbsent': False, 'cleanupSucceeded': False}
    destination = OUT / 'cleanup.json'
    write(destination, report)
    for name in ['build', *CASES]:
        path = OUT / name / 'identity.json'
        if not path.exists():
            continue
        item = {'identityPath': str(path), 'simulatorID': None, 'operations': [],
                'remainingOwnedDevice': None, 'absenceProven': False, 'identityError': None}
        report['devices'].append(item)
        try:
            identity = json.loads(path.read_text())
            simulator = str(UUID(identity['simulatorID']))
            require(identity['runID'] == os.environ['GITHUB_RUN_ID'] and
                    identity['runAttempt'] == os.environ['GITHUB_RUN_ATTEMPT'],
                    'Refusing cleanup of an identity from another run/attempt')
            item['simulatorID'] = simulator
        except (OSError, ValueError, KeyError, TypeError) as error:
            item['identityError'] = str(error)
            write(destination, report)
            continue
        # Only the exact UUID recorded at creation in this job; no broad shutdown/delete.
        # A shutdown error or timeout must not prevent the separate delete attempt.
        for operation in ('shutdown', 'delete'):
            operation_result, _ = cleanup_operation(['xcrun', 'simctl', operation, simulator])
            item['operations'].append(operation_result)
            write(destination, report)
        query, stdout = cleanup_operation(['xcrun', 'simctl', 'list', 'devices', '-j'])
        item['verification'] = query
        if query['succeeded']:
            try:
                groups = json.loads(stdout)['devices']
                require(isinstance(groups, dict) and all(isinstance(rows, list) for rows in groups.values()),
                        'Malformed post-cleanup device inventory')
                remaining = []
                for runtime, rows in groups.items():
                    for device in rows:
                        # Validate the UUID field before using absence as evidence.
                        observed = str(UUID(device['udid']))
                        if observed == simulator:
                            remaining.append({'runtime': runtime, 'device': device})
                item['remainingOwnedDevice'] = remaining
                item['absenceProven'] = not remaining
            except (ValueError, KeyError, TypeError) as error:
                item['verificationError'] = str(error)
        write(destination, report)
    report['allOwnedDevicesProvenAbsent'] = bool(report['devices']) and all(
        item['absenceProven'] for item in report['devices'])
    report['cleanupSucceeded'] = all(item['identityError'] is None and item['absenceProven'] and
        len(item['operations']) == 2 and all(operation['succeeded'] for operation in item['operations'])
        for item in report['devices'])
    report['status'] = ('no-owned-identity-recorded' if not report['devices'] else
                        'completed-and-absence-verified' if report['cleanupSucceeded'] else 'failed-or-unverified')
    write(destination, report)
    require(report['cleanupSucceeded'], 'Cleanup failed or could not be verified; see cleanup.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'verify-runtime', 'preflight', 'inventory', 'freeze', 'frozen', 'finish', 'cleanup'])
    parser.add_argument('name', nargs='?', choices=['build', *CASES])
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.name)
    elif args.action == 'verify-runtime':
        print(verify_runtime(args.name))
    elif args.action == 'preflight':
        require(args.name in CASES, 'Only a fixed qualification case is allowed')
        frozen()
        require((OUT / args.name / 'selectors.txt').read_text() == '\n'.join(CASES[args.name]) + '\n', 'Fixed selectors changed before execution')
        require(not (OUT / args.name / 'invocation.txt').exists(), 'No second invocation')
        print(verify_runtime(args.name))
    elif args.action == 'inventory':
        write(OUT / 'debug-inventory-proof.json', inventory_check(OUT / 'debug-enumeration.json'))
    elif args.action == 'freeze':
        require(not (OUT / 'frozen.json').exists(), 'Do not overwrite frozen inputs')
        write(OUT / 'frozen.json', snapshot())
    elif args.action == 'frozen':
        frozen()
    elif args.action == 'finish':
        finish_case(args.name)
    else:
        cleanup()


if __name__ == '__main__':
    main()
