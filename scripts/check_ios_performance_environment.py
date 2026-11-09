#!/usr/bin/env python3
"""Reject proven baseline/environment mismatches before expensive performance work."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess


def configured_environment(env, architecture):
    xcode = re.fullmatch(r'/Applications/Xcode_(\d+(?:\.\d+)+)\.app/Contents/Developer', env['DEVELOPER_DIR'])
    runtime = re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+(?:-\d+)+)', env['CI_IPHONE_RUNTIME'])
    if not xcode or not runtime or not env['CI_IPHONE_NAME'] or architecture not in ('arm64', 'x86_64'):
        raise ValueError('Cannot establish the configured performance environment')
    return {'xcodeVersion': xcode[1], 'osVersion': runtime[1].replace('-', '.'),
            'modelName': env['CI_IPHONE_NAME'], 'architecture': architecture}


def runner_environment(env, inventory, toolchain, architecture):
    runtime_id = env['CI_IPHONE_RUNTIME']
    devices = [(runtime, device) for runtime, rows in inventory['devices'].items()
               for device in rows if device.get('udid') == env['SIMULATOR_ID']]
    if len(devices) != 1 or devices[0][0] != runtime_id or not devices[0][1].get('isAvailable'):
        raise ValueError('Selected simulator is missing, unavailable or on a different runtime')
    device = devices[0][1]
    runtimes = [row for row in inventory['runtimes'] if row.get('identifier') == runtime_id and row.get('isAvailable')]
    types = [row for row in inventory['devicetypes'] if row.get('identifier') == device.get('deviceTypeIdentifier')]
    if len(runtimes) != 1 or len(types) != 1:
        raise ValueError('Simulator runtime or device type identity is missing or ambiguous')
    runtime, device_type = runtimes[0], types[0]
    observed = {'osVersion': runtime['version'], 'osBuildNumber': runtime['buildversion'],
                'modelName': device_type['name'], 'architecture': architecture, 'xcode': toolchain.strip()}
    if any(not isinstance(value, str) or not value.strip() for value in observed.values()):
        raise ValueError('Incomplete actual performance environment')
    if not re.fullmatch(r'Xcode \d+(?:\.\d+)+\nBuild version \S+', observed['xcode']):
        raise ValueError('Missing actual Xcode version/build')
    configured = configured_environment(env, architecture)
    if (observed['modelName'] != configured['modelName'] or observed['osVersion'] != configured['osVersion']
            or observed['xcode'].splitlines()[0] != 'Xcode ' + configured['xcodeVersion']):
        raise ValueError('Actual toolchain/runtime/device differs from workflow configuration')
    return observed


def require_compatible_baseline(baseline, environment):
    if type(baseline.get('schemaVersion')) is not int or baseline['schemaVersion'] != 1:
        raise ValueError('Unsupported performance baseline schema')
    profiles = baseline['profiles']
    if not isinstance(profiles, list):
        raise ValueError('Performance profiles must be a list')
    matches = []
    for profile in profiles:
        approved = profile['environment']
        if not isinstance(approved, dict):
            raise ValueError('Invalid approved performance environment')
        if all((approved.get('xcode', '').splitlines()[:1] == ['Xcode ' + value])
               if key == 'xcodeVersion' else approved.get(key) == value
               for key, value in environment.items()):
            matches.append(profile)
    if not matches:
        raise ValueError('No approved baseline is compatible with this performance environment: '
                         + json.dumps(environment, sort_keys=True)
                         + '. Collect and review calibration evidence; do not relabel an old baseline.')
    # Build/test configuration, complete metric limits and measured values remain
    # authoritative in check_ios_performance.py after actual XCTest execution.
    return len(matches)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('configured', 'runner'))
    parser.add_argument('--architecture', choices=('arm64', 'x86_64'), help='configured runner contract, Linux stage only')
    parser.add_argument('--baseline', type=Path, default=Path(__file__).with_name('ios_performance_baselines.json'))
    args = parser.parse_args()
    try:
        enforcement = os.environ.get('ENFORCE_BASELINES')
        if enforcement not in ('true', 'false'):
            raise ValueError('ENFORCE_BASELINES must be explicitly true or false')
        if args.stage == 'configured':
            if not args.architecture:
                raise ValueError('Configured validation requires the runner architecture')
            environment = configured_environment(os.environ, args.architecture)
        else:
            if args.architecture:
                raise ValueError('Runner validation must observe architecture, not accept a supplied value')
            environment = runner_environment(os.environ,
                json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '-j'], text=True)),
                subprocess.check_output(['xcodebuild', '-version'], text=True), platform.machine())
        if enforcement == 'false':
            print(json.dumps({'stage': args.stage, 'environment': environment, 'releaseAcceptance': False,
                              'note': 'Calibration-only: baseline availability is not required. All late evidence/metric checks remain required.'}))
            return
        count = require_compatible_baseline(json.loads(args.baseline.read_text()), environment)
        print(json.dumps({'stage': args.stage, 'environment': environment, 'compatibleProfiles': count,
                          'releaseAcceptance': False, 'note': 'Complete post-test baseline and metric validation is still required.'}))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Performance environment preflight failed: {error}\n')


if __name__ == '__main__':
    main()
