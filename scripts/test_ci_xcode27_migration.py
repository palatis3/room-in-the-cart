"""Primary toolchain migration contracts; no native tool is executed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from check_ci_workflows import FIXTURE_CONSUMER_RUNNER, FIXTURE_JOBS, FIXTURE_RUNNER, POLICY, native_job, parse_workflow
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
                    runner = (FIXTURE_CONSUMER_RUNNER if name.endswith('-tests') else FIXTURE_RUNNER) if key in FIXTURE_JOBS else 'xcode-27'
                    self.assertEqual(job['runs-on'], runner, key)
                    self.assertEqual(env['DEVELOPER_DIR'], DEVELOPER, key)
                    if key == ('ios-deep.yml', 'storekit'):
                        # Only execution uses the qualified PR compatibility runtime;
                        # the shared producer and every other native job retain 27.0.
                        self.assertNotIn('CI_IPHONE_RUNTIME', env)
                        self.assertEqual(env['REQUIRE_CURRENT_STOREKIT'], '${{ inputs.require_current_storekit }}')
                        self.assertEqual(sum(step.get('id') == 'storekit-runtime' for step in job['steps']), 1)
                    else:
                        self.assertEqual(env['CI_IPHONE_RUNTIME'], RUNTIME, key)
                    self.assertEqual(env['CI_IPHONE_NAME'], 'iPhone 17', key)
                    checkout = next(i for i, step in enumerate(job['steps'])
                                    if step.get('uses', '').startswith('actions/checkout@'))
                    guard = [i for i, step in enumerate(job['steps'])
                             if 'bash scripts/check_ci_xcode27.sh' in step.get('run', '').splitlines()]
                    self.assertEqual(guard, [checkout + 1], key)
                    self.assertNotIn('continue-on-error', job)
        self.assertEqual(seen, set(POLICY))
        self.assertEqual(len(seen), 18)
        self.assertFalse((ROOT / '.github/workflows/ios-xcode27.yml').exists())

    def test_fixture_preflight_rejects_other_runtime_builds_on_both_providers(self):
        jobs = parse_workflow(ROOT / '.github/workflows/ios-fixtures.yml')[0]['jobs']
        for _, name in sorted(FIXTURE_JOBS):
            step = next(s for s in jobs[name]['steps'] if s.get('name') == 'Require the reviewed Xcode 27.1 toolchain')
            command = step['run']
            for diagnostic in ('sw_vers', 'uname -m', '/Applications/Xcode*.app'):
                self.assertLess(command.index(diagnostic), command.index('bash scripts/check_ci_xcode27.sh'))
            code = command.split("python3 - <<'PYCODE'\n", 1)[1].rsplit('\nPYCODE', 1)[0]
            for version, build, passes in [('27.0', '24A434', True), ('27.0', '24A435', False), ('27.1', '24A434', False)]:
                with self.subTest(job=name, version=version, build=build), \
                        patch('select_ci_iphone.runtime_identity', return_value={'version': version, 'buildversion': build}) as identity, \
                        patch.dict(os.environ, {'CI_IPHONE_RUNTIME': RUNTIME}):
                    if passes:
                        exec(code, {})
                    else:
                        with self.assertRaises(SystemExit): exec(code, {})
                    identity.assert_called_once_with(RUNTIME)

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
        self.assertEqual(performance['env']['ENFORCE_BASELINES'],
                         "${{ inputs.enforce_baselines }}")
        gate = parse_workflow(ROOT / '.github/workflows/ci.yml')[0]['jobs']['ci-gate']
        self.assertIn('ios-swift-codeql', gate['needs'])


if __name__ == '__main__':
    unittest.main()
