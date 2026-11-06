#!/usr/bin/env python3
"""Guard and stubbed system-Bash tests; never invokes native Apple tools."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
import sys
import subprocess
from unittest.mock import patch
import qualify_ios_toolchain as q


class QualificationGuards(unittest.TestCase):
    def test_exact_runtime_selection_uses_observed_identifier(self):
        # Metadata may advertise a maintenance version under a family identifier.
        row = {'identifier': q.RUNTIME_NAMESPACE + '26-4', 'platform': 'iOS',
               'version': '26.4.1', 'buildversion': q.BUILD, 'isAvailable': True}
        self.assertEqual(q.runtime_match({'runtimes': [row]}), row)
        for key, bad in [('identifier', 'com.apple.CoreSimulator.SimRuntime.tvOS-26-4'),
                         ('identifier', 'untrusted.iOS-26-4'), ('platform', 'tvOS'),
                         ('version', '26.4'), ('buildversion', '23E254'), ('buildversion', '23E252'),
                         ('isAvailable', False)]:
            with self.subTest(key=key, bad=bad), self.assertRaises(ValueError):
                q.runtime_match({'runtimes': [dict(row, **{key: bad})]})
        for rows in ([], [row, row], [row, dict(row, buildversion='23E254')],
                     [row, dict(row, identifier=q.RUNTIME_NAMESPACE + '26-4-1')]):
            with self.assertRaises(ValueError):
                q.runtime_match({'runtimes': rows})
        # A different available OS version is not a second exact candidate or a fallback.
        older = dict(row, identifier=q.RUNTIME_NAMESPACE + '26-2', version='26.2', buildversion='23C54')
        self.assertEqual(q.runtime_match({'runtimes': [row, older]}), row)
        with self.assertRaises(ValueError):
            q.runtime_match({'runtimes': [row]}, expected_identifier=q.RUNTIME_NAMESPACE + '26-4-1')

    def test_identifier_change_after_creation_stops_before_booted_build_query(self):
        simulator = '22222222-2222-4222-8222-222222222222'
        row = {'identifier': q.RUNTIME_NAMESPACE + '26-4-1', 'platform': 'iOS',
               'version': '26.4.1', 'buildversion': q.BUILD, 'isAvailable': True}
        with tempfile.TemporaryDirectory() as temp, patch.object(q, 'OUT', Path(temp)), \
             patch.object(q, 'command', return_value=json.dumps({'runtimes': [row]})) as native:
            directory = Path(temp) / 'ui06'
            directory.mkdir()
            q.write(directory / 'identity.json', {'simulatorID': simulator, 'runtime': q.RUNTIME_NAMESPACE + '26-4',
                                                'version': '26.4.1', 'runtimeBuild': q.BUILD})
            with self.assertRaisesRegex(ValueError, 'identifier changed'):
                q.verify_runtime('ui06')
            self.assertEqual(native.call_count, 1)
            self.assertEqual(native.call_args.args[0], ['xcrun', 'simctl', 'list', '-j'])
            self.assertTrue((directory / 'runtime-observation-01.json').exists())

    def test_exact_order_and_single_invocation(self):
        for selectors in q.CASES.values():
            def log(values):
                return '\n'.join("Test Case '-[" + s.replace('/', '.', 1).replace('/', ' ') + "]' started."
                                 for s in values)
            self.assertEqual(q.order_check(log(selectors), selectors), selectors)
            invalid = [selectors[:-1], selectors + selectors, selectors + ['Other/Suite/testWrong']]
            if len(selectors) > 1:
                invalid.append(list(reversed(selectors)))
            for values in invalid:
                with self.assertRaises(ValueError):
                    q.order_check(log(values), selectors)

    def test_full_inventory_not_just_selected_cases(self):
        enabled = ['RoomInTheCartTests/ModelTests/testModel'] + sorted(set(q.CASES['ui06'] + q.CASES['spanish']))
        enabled.append('RoomInTheCartUITests/ExtraTests/testUnselected')
        disabled = ['RoomInTheCartTests/StoreKitScenarioTests/testPurchase']
        canonical = {'enabledTests': sorted(enabled), 'disabledTests': disabled}
        enumeration = {'errors': [], 'values': [{'testPlan': 'Test Scheme Action',
                       **{key: [{'identifier': value + '()'} for value in values]
                          for key, values in canonical.items()}}]}
        with tempfile.TemporaryDirectory() as temp, patch.object(q, 'INVENTORY_SHA', q.digest(canonical)):
            path = Path(temp) / 'enumeration.json'
            path.write_text(json.dumps(enumeration))
            self.assertEqual(q.inventory_check(path)['enabledCount'], 11)
            mutations = []
            missing = copy.deepcopy(enumeration)
            missing['values'][0]['enabledTests'] = [row for row in missing['values'][0]['enabledTests']
                                                  if 'testUnselected' not in row['identifier']]
            mutations.append(missing)
            extra = copy.deepcopy(enumeration)
            extra['values'][0]['enabledTests'].append({'identifier': 'RoomInTheCartUITests/Other/testExtra()'})
            mutations.append(extra)
            duplicate = copy.deepcopy(enumeration)
            duplicate['values'][0]['enabledTests'].append(duplicate['values'][0]['enabledTests'][0])
            mutations.append(duplicate)
            error = copy.deepcopy(enumeration)
            error['errors'] = ['Enumeration failure']
            mutations.append(error)
            disabled_ui = copy.deepcopy(enumeration)
            disabled_ui['values'][0]['disabledTests'].append({'identifier': enabled[1] + '()'})
            mutations.append(disabled_ui)
            for mutation in mutations:
                path.write_text(json.dumps(mutation))
                with self.assertRaises(ValueError):
                    q.inventory_check(path)

    def test_source_and_attempt_fail_closed(self):
        env = {'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_SHA': 'abc'}
        def answer(args, **_):
            if args[:2] == ['git', 'rev-parse']:
                return 'abc'
            if args[:2] == ['git', 'status']:
                return ''
            if args[:2] == ['git', 'diff']:
                return '.github/workflows/ios-performance.yml'
            return 'ios/App/Theme.swift'
        with patch.dict(os.environ, env), patch.object(q, 'command', side_effect=answer), patch.object(q.subprocess, 'run'):
            self.assertEqual(q.source_files(), [Path('ios/App/Theme.swift')])
            with patch.dict(os.environ, GITHUB_RUN_ATTEMPT='2'), self.assertRaises(ValueError):
                q.source_files()
            for bad in ['ios/App/Theme.swift', 'scripts/check_ios_performance.py', 'scripts/ios_performance_baselines.json']:
                def forbidden(args, **kwargs):
                    return bad if args[:2] == ['git', 'diff'] else answer(args, **kwargs)
                with patch.object(q, 'command', side_effect=forbidden), self.assertRaises(ValueError):
                    q.source_files()

    def test_preflight_rejects_changed_selector_and_reuse_before_native_query(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(q, 'OUT', Path(temp)), \
             patch.object(q, 'frozen'), patch.object(q, 'verify_runtime') as native, \
             patch.object(sys, 'argv', ['guard', 'preflight', 'ui06']):
            directory = Path(temp) / 'ui06'
            directory.mkdir()
            selectors = directory / 'selectors.txt'
            selectors.write_text('RoomInTheCartUITests/Other/testUnexpected\n')
            with self.assertRaises(ValueError):
                q.main()
            native.assert_not_called()
            selectors.write_text('\n'.join(q.CASES['ui06']) + '\n')
            (directory / 'invocation.txt').write_text('already invoked')
            with self.assertRaises(ValueError):
                q.main()
            native.assert_not_called()

    def test_product_digest_detects_bytes_mode_and_symlink_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            file = root / 'binary'
            file.write_bytes(b'compiled-original')
            original = q.manifest(root.rglob('*'), root)
            file.write_bytes(b'compiled-changed')
            self.assertNotEqual(original, q.manifest(root.rglob('*'), root))
            file.write_bytes(b'compiled-original')
            file.chmod(file.stat().st_mode ^ 0o100)
            self.assertNotEqual(original, q.manifest(root.rglob('*'), root))
            link = root / 'link'
            link.symlink_to('binary')
            first = q.manifest(root.rglob('*'), root)
            link.unlink()
            link.symlink_to('different')
            self.assertNotEqual(first, q.manifest(root.rglob('*'), root))


class CleanupGuards(unittest.TestCase):
    OWNED = '22222222-2222-4222-8222-222222222222'
    OTHER = '33333333-3333-4333-8333-333333333333'

    def run_cleanup(self, shutdown=0, delete=0, remaining=False, query=None, foreign=False):
        inventory = {'devices': {'observed-runtime': [{'udid': self.OTHER, 'state': 'Booted'}] +
                     ([{'udid': self.OWNED, 'state': 'Shutdown'}] if remaining else [])}}
        calls = []
        def execute(args, **kwargs):
            calls.append(args)
            self.assertEqual(kwargs['timeout'], 90)
            operation = args[2]
            if operation in ('shutdown', 'delete'):
                self.assertEqual(args[3:], [self.OWNED])
                result = shutdown if operation == 'shutdown' else delete
                if isinstance(result, Exception):
                    raise result
                return subprocess.CompletedProcess(args, result, operation + ' stdout', operation + ' stderr')
            self.assertEqual(args, ['xcrun', 'simctl', 'list', 'devices', '-j'])
            if isinstance(query, Exception):
                raise query
            return subprocess.CompletedProcess(args, 0, json.dumps(inventory) if query is None else query, '')
        with tempfile.TemporaryDirectory() as temp, patch.object(q, 'OUT', Path(temp)), \
             patch.dict(os.environ, GITHUB_RUN_ID='run', GITHUB_RUN_ATTEMPT='1'), \
             patch.object(q.subprocess, 'run', side_effect=execute):
            directory = Path(temp) / 'ui06'
            directory.mkdir()
            q.write(directory / 'identity.json', {'simulatorID': self.OWNED,
                    'runID': 'foreign' if foreign else 'run', 'runAttempt': '1'})
            failed = False
            try:
                q.cleanup()
            except ValueError:
                failed = True
            report = json.loads((Path(temp) / 'cleanup.json').read_text())
        return report, failed, calls

    def test_success_requires_absence_proof_and_does_not_touch_unrelated_device(self):
        report, failed, calls = self.run_cleanup()
        self.assertFalse(failed)
        self.assertTrue(report['cleanupSucceeded'])
        self.assertTrue(report['allOwnedDevicesProvenAbsent'])
        self.assertEqual(report['devices'][0]['remainingOwnedDevice'], [])
        self.assertEqual([args[2] for args in calls], ['shutdown', 'delete', 'list'])
        self.assertTrue(all(self.OTHER not in args for args in calls))

    def test_shutdown_failure_is_retained_even_when_delete_succeeds(self):
        report, failed, calls = self.run_cleanup(shutdown=3)
        self.assertTrue(failed)
        self.assertTrue(report['allOwnedDevicesProvenAbsent'])
        self.assertFalse(report['cleanupSucceeded'])
        self.assertEqual([args[2] for args in calls], ['shutdown', 'delete', 'list'])
        operation = report['devices'][0]['operations'][0]
        self.assertEqual(operation['exitCode'], 3)
        self.assertEqual(operation['stdout'], 'shutdown stdout')
        self.assertEqual(operation['stderr'], 'shutdown stderr')

    def test_timeout_and_errors_still_attempt_delete_and_record_unknown_absence(self):
        timeout = subprocess.TimeoutExpired(['xcrun'], 90, output=b'x' * 17000, stderr=b'partial error')
        report, failed, calls = self.run_cleanup(shutdown=timeout, delete=OSError('delete unavailable'),
                                               query=OSError('inventory unavailable'))
        self.assertTrue(failed)
        self.assertEqual([args[2] for args in calls], ['shutdown', 'delete', 'list'])
        item = report['devices'][0]
        self.assertTrue(item['operations'][0]['timedOut'])
        self.assertEqual(len(item['operations'][0]['stdout']), 16384)
        self.assertTrue(item['operations'][0]['stdoutTruncated'])
        self.assertEqual(item['operations'][0]['stderr'], 'partial error')
        self.assertIsNone(item['remainingOwnedDevice'])
        self.assertFalse(report['allOwnedDevicesProvenAbsent'])
        self.assertIn('delete unavailable', item['operations'][1]['error'])

    def test_remaining_device_or_bad_inventory_cannot_claim_deletion(self):
        report, failed, _ = self.run_cleanup(delete=4, remaining=True)
        self.assertTrue(failed)
        self.assertFalse(report['allOwnedDevicesProvenAbsent'])
        self.assertEqual(report['devices'][0]['remainingOwnedDevice'][0]['device']['udid'], self.OWNED)
        for query in ('not json', '{}', '{"devices":{"runtime":[{}]}}'):
            report, failed, _ = self.run_cleanup(query=query)
            self.assertTrue(failed)
            self.assertFalse(report['allOwnedDevicesProvenAbsent'])
            self.assertIn('verificationError', report['devices'][0])

    def test_foreign_identity_never_causes_native_mutation(self):
        report, failed, calls = self.run_cleanup(foreign=True)
        self.assertTrue(failed)
        self.assertEqual(calls, [])
        self.assertFalse(report['allOwnedDevicesProvenAbsent'])


class BashBuildSmokeTests(unittest.TestCase):
    SIMULATOR = '22222222-2222-4222-8222-222222222222'
    SCRIPT = Path(__file__).with_name('run_ios_toolchain_qualification.sh')

    @staticmethod
    def invoke_build(script, mode, build_exit=0):
        """Use actual system Bash, but make every Python/Xcode call a shell stub."""
        with tempfile.TemporaryDirectory(prefix='qualification bash smoke ') as temp:
            root = Path(temp)
            stubs = root / 'stubs'
            stubs.mkdir()
            out = root / '.build/toolchain-qualification'
            out.mkdir(parents=True)
            python_stub = stubs / 'python3'
            python_stub.write_text('''#!/bin/bash
set -euo pipefail
printf '%s\\0' "$@" >> "$STUB_PYTHON_LOG"
printf '\\0' >> "$STUB_PYTHON_LOG"
if [[ "$#" -eq 3 && "$1" == scripts/qualify_ios_toolchain.py && "$2" == verify-runtime && "$3" == build ]]; then
    printf '%s\\n' "$STUB_SIMULATOR"
elif [[ "$#" -eq 4 && "$1" == scripts/check_built_app.py && "$3" == --configuration ]]; then
    exit 0
else
    echo 'Unexpected Python stub command; refusing execution' >&2
    exit 97
fi
''')
            xcode_stub = stubs / 'xcodebuild'
            xcode_stub.write_text('''#!/bin/bash
set -euo pipefail
printf '%s\\0' "$@" > "$STUB_XCODE_LOG"
printf 'stub build output\\n'
exit "$STUB_BUILD_EXIT"
''')
            python_stub.chmod(0o755)
            xcode_stub.chmod(0o755)
            # Only tee is real; no Python, xcrun, simctl or Xcode is reachable via PATH.
            (stubs / 'tee').symlink_to('/usr/bin/tee')
            environment = dict(os.environ, PATH=str(stubs), STUB_SIMULATOR=BashBuildSmokeTests.SIMULATOR,
                               STUB_BUILD_EXIT=str(build_exit), STUB_PYTHON_LOG=str(root / 'python.args'),
                               STUB_XCODE_LOG=str(root / 'xcode.args'))
            result = subprocess.run(['/bin/bash', str(Path(script).resolve()), mode], cwd=root,
                                    env=environment, capture_output=True, text=True, timeout=15, check=False)
            python_calls = []
            if (root / 'python.args').exists():
                python_calls = [record.decode().split('\0') for record in
                                (root / 'python.args').read_bytes().split(b'\0\0') if record]
            xcode_args = None
            if (root / 'xcode.args').exists():
                xcode_args = (root / 'xcode.args').read_bytes().decode().rstrip('\0').split('\0')
            configuration = 'Debug' if mode == 'build-debug' else 'Release'
            log = out / (configuration + '-build.log')
            return {'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr,
                    'pythonCalls': python_calls, 'xcodeArguments': xcode_args,
                    'buildLog': log.read_text() if log.exists() else None,
                    'pathEntries': ['stub python3', 'stub xcodebuild', '/usr/bin/tee'],
                    'mode': mode, 'stubBuildExit': build_exit}

    def expected_arguments(self, configuration):
        scheme = 'RoomInTheCart' if configuration == 'Debug' else 'RoomInTheCart-Performance'
        arguments = ['-project', 'ios/RoomInTheCart.xcodeproj', '-scheme', scheme,
                     '-configuration', configuration, '-destination', 'platform=iOS Simulator,id=' + self.SIMULATOR,
                     '-parallel-testing-enabled', 'NO', '-jobs', '2', '-derivedDataPath', '.build/DerivedData']
        if configuration == 'Release':
            arguments += ['-enableCodeCoverage', 'NO', '-enableAddressSanitizer', 'NO',
                          '-enableThreadSanitizer', 'NO', '-enableUndefinedBehaviorSanitizer', 'NO']
        return arguments + ['CODE_SIGN_IDENTITY=-', 'build-for-testing']

    def check_success(self, mode, configuration):
        result = self.invoke_build(self.SCRIPT, mode)
        self.assertEqual(result['exit'], 0, result)
        self.assertEqual(result['xcodeArguments'], self.expected_arguments(configuration))
        self.assertEqual(result['pythonCalls'], [
            ['scripts/qualify_ios_toolchain.py', 'verify-runtime', 'build'],
            ['scripts/check_built_app.py', '.build/DerivedData/Build/Products/' + configuration +
             '-iphonesimulator/RoomInTheCart.app', '--configuration', configuration]])
        self.assertEqual(result['buildLog'], 'stub build output\n')

    def test_debug_exact_argv_on_system_bash(self):
        self.check_success('build-debug', 'Debug')

    def test_release_exact_argv_and_flags_on_system_bash(self):
        self.check_success('build-release', 'Release')

    def test_build_failure_propagates_through_tee_and_skips_app_validation(self):
        for mode, configuration in [('build-debug', 'Debug'), ('build-release', 'Release')]:
            with self.subTest(mode=mode):
                result = self.invoke_build(self.SCRIPT, mode, build_exit=42)
                self.assertEqual(result['exit'], 42, result)
                self.assertEqual(result['xcodeArguments'], self.expected_arguments(configuration))
                self.assertEqual(result['pythonCalls'], [['scripts/qualify_ios_toolchain.py', 'verify-runtime', 'build']])
                self.assertEqual(result['buildLog'], 'stub build output\n')


if __name__ == '__main__':
    unittest.main()
