"""Prepare the pinned GitHub iOS 27 runtime and verify its stability after tests."""
import argparse
import json
import os
import platform
import subprocess
import uuid
from pathlib import Path

evidence = Path('.build/github-ios-runtime')
runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
build = '24A434'

def capture(name):
    raw = subprocess.check_output(['xcrun', 'simctl', 'runtime', 'list', '-j'], text=True)
    (evidence / name).write_text(raw)
    value = json.loads(raw)
    assert isinstance(value, dict)
    return value

def targets(rows):
    return [r for r in rows.values() if r.get('runtimeIdentifier') == runtime and r.get('build') == build]

def prepare():
    before = capture('before.json')
    assert any(r.get('state') == 'Ready' for r in targets(before))
    export = Path('.build/runtime-export')
    export.mkdir()
    with (evidence / 'export.log').open('w') as log:
        result = subprocess.run(['xcodebuild', '-downloadPlatform', 'iOS', '-buildVersion', build,
                                 '-exportPath', str(export.resolve()), '-architectureVariant', 'arm64'],
                                stdout=log, stderr=subprocess.STDOUT)
    (evidence / 'export-exit.json').write_text(json.dumps({'exit': result.returncode}) + '\n')
    # The documented exporter may return 70 even when its exported bundle exists.
    # A real import and exact registration check below remain mandatory.
    assert result.returncode in (0, 70)
    bundles = list(export.glob('*.exportedBundle'))
    assert len(bundles) == 1 and bundles[0].is_dir(), 'Expected one exported platform bundle'
    assert any(f.is_file() and f.stat().st_size > 0 for f in bundles[0].rglob('*'))
    (evidence / 'export-bundle.json').write_text(json.dumps({'bundle': str(bundles[0]),
        'files': [{'name': str(f.relative_to(bundles[0])), 'bytes': f.stat().st_size}
                  for f in bundles[0].rglob('*') if f.is_file()]}, indent=2) + '\n')
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j'], text=True))
    assert all(d['state'] == 'Shutdown' for d in devices['devices'].get(runtime, []))
    current = capture('before-replacement.json')
    replacement = targets(current)
    assert replacement
    for row in replacement:
        uuid.UUID(row['identifier'])
        assert current.get(row['identifier']) == row
        assert row.get('deletable') is True
        assert row.get('path', '').startswith('/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/')
    for row in replacement:
        # Refresh before each deletion: deleting a shared asset can retire both records.
        remaining = capture('replacement-current.json')
        if row['identifier'] not in remaining:
            continue
        active = remaining[row['identifier']]
        assert all(active.get(k) == row.get(k) for k in ('identifier', 'runtimeIdentifier', 'build', 'path', 'deletable'))
        with (evidence / ('replace-' + row['identifier'] + '.log')).open('w') as log:
            subprocess.run(['xcrun', 'simctl', 'runtime', 'delete', row['identifier']],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    assert not targets(capture('after-removal.json'))
    with (evidence / 'import.log').open('w') as log:
        subprocess.run(['sudo', '-n', '/usr/bin/env',
                        'DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer',
                        '/usr/bin/xcodebuild', '-importPlatform', str(bundles[0].resolve())],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    after = capture('after-import.json')
    installed = targets(after)
    assert len(installed) == 1 and installed[0].get('state') == 'Ready'
    target = installed[0]
    path = target.get('path', '')
    assert path.startswith('/Library/Developer/CoreSimulator/') and '/Images/' in path, path
    assert Path(path).exists() and Path(target['runtimeBundlePath']).is_dir()
    assert 'arm64' in target.get('supportedArchitectures', [])
    (evidence / 'target.json').write_text(json.dumps(target, indent=2) + '\n')
    print('Imported iOS 27.0/24A434 runtime verified.')


def verify():
    current = capture('after-tests.json')
    before = json.loads((evidence / 'target.json').read_text())
    installed = targets(current)
    assert len(installed) == 1, 'Expected exactly one target registration'
    after = installed[0]
    assert after['state'] == 'Ready'
    for key in ('identifier', 'build', 'runtimeIdentifier', 'path', 'mountPath', 'runtimeBundlePath'):
        assert before.get(key) == after.get(key), 'Runtime changed during tests: ' + key
    assert Path(after['path']).exists() and Path(after['runtimeBundlePath']).is_dir()
    print('Imported runtime identity, mount and bundle retained.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('prepare', 'verify'))
    args = parser.parse_args()
    assert os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
    assert os.environ.get('GITHUB_ACTIONS') == 'true'
    assert platform.system() == 'Darwin' and platform.machine() == 'arm64'
    assert os.environ.get('CI_IPHONE_RUNTIME') == runtime
    assert os.environ.get('DEVELOPER_DIR') == '/Applications/Xcode_27.1.app/Contents/Developer'
    evidence.mkdir(parents=True, exist_ok=True)
    if args.operation == 'prepare':
        prepare()
    else:
        verify()


if __name__ == '__main__':
    main()
