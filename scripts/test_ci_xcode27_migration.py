"""Primary toolchain migration contracts; no native tool is executed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from check_ci_workflows import POLICY, native_job, parse_workflow
from check_ios_performance import compare_baseline

ROOT = Path(__file__).resolve().parents[1]
DEVELOPER = '/Applications/Xcode_27.1.app/Contents/Developer'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'


class Xcode27MigrationTests(unittest.TestCase):
    def test_every_native_job_migrates_except_required_supported_swift_security(self):
        seen = set()
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            workflow, _, _ = parse_workflow(path)
            for name, job in workflow['jobs'].items():
                if not native_job(job):
                    continue
                key = (path.name, name)
                seen.add(key)
                env = {**workflow.get('env', {}), **job.get('env', {})}
                if key == ('ci.yml', 'ios-swift-codeql'):
                    self.assertEqual(job['runs-on'], 'macos-15')
                    self.assertEqual(env['DEVELOPER_DIR'], '/Applications/Xcode_26.3.app/Contents/Developer')
                    self.assertNotIn('CI_IPHONE_RUNTIME', env)
                    self.assertNotIn('CI_IPHONE_NAME', env)
                    init = next(s for s in job['steps'] if s.get('uses', '').startswith('github/codeql-action/init@'))
                    self.assertEqual(init['with']['build-mode'], 'manual')
                    self.assertEqual(init['with']['languages'], 'swift')
                else:
                    self.assertEqual(job['runs-on'], 'xcode-27', key)
                    self.assertEqual(env['DEVELOPER_DIR'], DEVELOPER, key)
                    self.assertEqual(env['CI_IPHONE_RUNTIME'], RUNTIME, key)
                    self.assertEqual(env['CI_IPHONE_NAME'], 'iPhone 17', key)
                    checkout = next(i for i, step in enumerate(job['steps'])
                                    if step.get('uses', '').startswith('actions/checkout@'))
                    guard = [i for i, step in enumerate(job['steps'])
                             if step.get('run') == 'bash scripts/check_ci_xcode27.sh']
                    self.assertEqual(guard, [checkout + 1], key)
                    self.assertNotIn('continue-on-error', job)
        self.assertEqual(seen, set(POLICY))
        self.assertEqual(len(seen), 17)
        self.assertFalse((ROOT / '.github/workflows/ios-xcode27.yml').exists())

    def test_actual_toolchain_guard_rejects_drift_without_running_native_tools(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            for name, text in [('uname', '#!/bin/sh\nprintf "%s\\n" "$FAKE_ARCH"\n'),
                               ('xcodebuild', '#!/bin/sh\nprintf "%s\\n" "$FAKE_XCODE"\n')]:
                file = path / name
                file.write_text(text)
                file.chmod(0o755)
            good = 'Xcode 27.1\nBuild version 27A9275'
            for developer, arch, xcode, expected in [(DEVELOPER, 'arm64', good, 0),
                    ('/Applications/Xcode.app/Contents/Developer', 'arm64', good, 1),
                    (DEVELOPER, 'x86_64', good, 1), (DEVELOPER, 'arm64', 'Xcode 27.2\nBuild version other', 1)]:
                result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/check_ci_xcode27.sh')],
                    env={**os.environ, 'PATH': str(path) + ':/usr/bin:/bin', 'DEVELOPER_DIR': developer,
                         'FAKE_ARCH': arch, 'FAKE_XCODE': xcode}, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_performance_release_cannot_inherit_old_environment_approval(self):
        baseline = json.loads((ROOT / 'scripts/ios_performance_baselines.json').read_text())
        old = baseline['profiles'][0]['environment']
        self.assertEqual(old['xcode'], 'Xcode 26.3\nBuild version 17C529')
        new = {**old, 'xcode': 'Xcode 27.1\nBuild version 27A9275', 'osVersion': '27.0'}
        with self.assertRaisesRegex(ValueError, 'exactly one approved baseline'):
            compare_baseline(baseline, new, 'launch', {'responsiveLaunchMedianSeconds': 1})
        release = parse_workflow(ROOT / '.github/workflows/release-checks.yml')[0]
        self.assertTrue(release['jobs']['performance']['with']['enforce_baselines'])
        performance = parse_workflow(ROOT / '.github/workflows/ios-performance.yml')[0]
        self.assertTrue(performance['on']['workflow_call']['inputs']['enforce_baselines']['default'])
        self.assertEqual(performance['jobs']['performance-tests']['env']['ENFORCE_BASELINES'],
                         "${{ github.event_name == 'pull_request' || inputs.enforce_baselines }}")
        gate = parse_workflow(ROOT / '.github/workflows/ci.yml')[0]['jobs']['ci-gate']
        self.assertIn('ios-swift-codeql', gate['needs'])


if __name__ == '__main__':
    unittest.main()
