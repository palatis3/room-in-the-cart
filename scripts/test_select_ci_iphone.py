#!/usr/bin/env python3
"""Owned simulator provisioning checks; all simctl calls are mocked."""
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from select_ci_iphone import cleanup, main, provision, select_iphone

RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-2'
TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
SOURCE = '11111111-1111-4111-8111-111111111111'
CREATED = '22222222-2222-4222-8222-222222222222'


class OwnedSimulatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.receipt = self.root / 'test-simulator-ownership.json'
        self.env_file = self.root / 'environment'
        self.env = {'GITHUB_REPOSITORY': 'example/project', 'GITHUB_RUN_ID': '42', 'GITHUB_RUN_ATTEMPT': '2',
                    'GITHUB_JOB': 'ios-tests', 'TEST_SHARD': 'ui-01', 'DEVELOPER_DIR': '/Applications/Xcode_26.3.app/Contents/Developer',
                    'GITHUB_ENV': str(self.env_file)}
        self.environment = patch.dict(os.environ, self.env)
        self.environment.start(); self.addCleanup(self.environment.stop)
        os.environ.pop('SIMULATOR_ID', None)
        self.inventory = {RUNTIME: [{'name': 'iPhone 17', 'udid': SOURCE, 'isAvailable': True,
                                     'deviceTypeIdentifier': TYPE, 'state': 'Shutdown'}]}
        self.original = copy.deepcopy(self.inventory)
        self.runtimes = [{'identifier': RUNTIME, 'version': '26.2', 'buildversion': '23C54',
                          'bundlePath': '/Runtime/iOS26.2.simruntime', 'isAvailable': True}]
        self.calls = []
        self.created_id = CREATED
        self.create_error = None
        self.after_create = lambda device: None
        self.mock = patch('select_ci_iphone.subprocess.run', side_effect=self.run_simctl)
        self.mock.start(); self.addCleanup(self.mock.stop)

    def run_simctl(self, command, **kwargs):
        self.assertEqual(command[:2], ['xcrun', 'simctl'])
        self.assertEqual(kwargs, {'check': True, 'capture_output': True, 'text': True})
        args = command[2:]; self.calls.append(args)
        if args == ['list', 'runtimes', '-j']:
            result = json.dumps({'runtimes': self.runtimes})
        elif args == ['list', 'devices', '-j']:
            result = json.dumps({'devices': self.inventory})
        elif args[0] == 'create':
            if self.create_error: raise self.create_error
            self.assertEqual(args[2:], [TYPE, RUNTIME])
            if self.created_id != SOURCE:
                device = {'name': args[1], 'udid': self.created_id, 'isAvailable': True,
                          'deviceTypeIdentifier': TYPE, 'state': 'Shutdown'}
                self.inventory[RUNTIME].append(device); self.after_create(device)
            result = self.created_id + '\n'
        elif args[0] in ('shutdown', 'delete'):
            self.assertEqual(args[1:], [CREATED], 'Only the created UUID may be mutated')
            if args[0] == 'shutdown': self.inventory[RUNTIME][1]['state'] = 'Shutdown'
            else: self.inventory[RUNTIME] = [d for d in self.inventory[RUNTIME] if d['udid'] != CREATED]
            result = ''
        else:
            self.fail(f'Unexpected simulator command: {args}')
        return subprocess.CompletedProcess(command, 0, stdout=result)

    def create(self):
        return provision(copy.deepcopy(self.original), self.receipt)

    def test_legacy_selection_and_environment_output_make_no_simctl_calls(self):
        older = 'com.apple.CoreSimulator.SimRuntime.iOS-18-5'
        data = copy.deepcopy(self.original)
        data[older] = [{'name': 'iPhone 17', 'isAvailable': True, 'udid': 'older'}]
        data[RUNTIME].insert(0, {'name': 'iPhone 16', 'isAvailable': True, 'udid': 'other'})
        with patch('sys.argv', ['select_ci_iphone.py']), patch('sys.stdin', io.StringIO(json.dumps({'devices': data}))):
            main()
        self.assertEqual(self.env_file.read_text(), f'SIMULATOR_ID={SOURCE}\n')
        self.assertEqual(select_iphone(data)[0], RUNTIME)
        self.assertEqual(self.calls, [])

    def test_create_binds_exact_runtime_type_and_owner_then_deletes_only_owned_uuid(self):
        receipt = self.create()
        self.assertEqual(receipt['runtime'], {k: self.runtimes[0][k] for k in ('identifier', 'version', 'buildversion', 'bundlePath')})
        self.assertEqual(receipt['owner'], {k: v for k, v in self.env.items() if k != 'GITHUB_ENV'})
        self.assertEqual(receipt['sourceUDID'], SOURCE)
        self.assertEqual(receipt['createdUDID'], CREATED)
        self.assertEqual(receipt['creationStatus'], 'verified')
        self.assertEqual(self.env_file.read_text(), f'SIMULATOR_ID={CREATED}\n')
        self.inventory[RUNTIME][1]['state'] = 'Booted'
        os.environ['SIMULATOR_ID'] = CREATED
        cleanup(self.receipt)
        self.assertEqual(self.inventory, self.original)
        self.assertEqual(json.loads(self.receipt.read_text())['cleanup']['status'], 'deleted')
        self.assertEqual([c for c in self.calls if c[0] in ('shutdown', 'delete')],
                         [['shutdown', CREATED], ['delete', CREATED]])
        cleanup(self.receipt)
        self.assertEqual(json.loads(self.receipt.read_text())['cleanup']['status'], 'already-absent')

    def test_ambiguous_runtime_build_or_missing_identity_refuses_before_creation(self):
        for runtimes in ([self.runtimes[0], {**self.runtimes[0], 'buildversion': '23C52'}],
                         [{**self.runtimes[0], 'isAvailable': False}],
                         [{k: v for k, v in self.runtimes[0].items() if k != 'buildversion'}]):
            with self.subTest(runtimes=runtimes):
                self.runtimes = runtimes
                self.calls.clear()
                with self.assertRaises(ValueError): self.create()
                self.assertFalse(self.env_file.exists())
                self.assertFalse(any(c[0] == 'create' for c in self.calls))

    def test_creation_failure_or_returned_image_uuid_never_falls_back(self):
        self.create_error = subprocess.CalledProcessError(1, ['xcrun', 'simctl', 'create'])
        with self.assertRaises(subprocess.CalledProcessError): self.create()
        self.assertFalse(self.env_file.exists())
        self.assertIsNone(json.loads(self.receipt.read_text())['createdUDID'])
        cleanup(self.receipt)
        self.assertFalse(any(c[0] in ('shutdown', 'delete') for c in self.calls))
        self.receipt.unlink(); self.create_error = None; self.created_id = SOURCE
        with self.assertRaisesRegex(ValueError, 'already present'): self.create()
        cleanup(self.receipt)
        self.assertFalse(self.env_file.exists())
        self.assertFalse(any(c[0] in ('shutdown', 'delete') for c in self.calls))

    def test_post_creation_identity_mismatch_is_not_published_or_deleted(self):
        self.after_create = lambda device: device.update(deviceTypeIdentifier='com.apple.CoreSimulator.SimDeviceType.iPhone-16')
        with self.assertRaisesRegex(ValueError, 'does not match'): self.create()
        self.assertFalse(self.env_file.exists())
        self.assertEqual(json.loads(self.receipt.read_text())['createdUDID'], CREATED)
        with self.assertRaisesRegex(ValueError, 'does not match'): cleanup(self.receipt)
        self.assertEqual(json.loads(self.receipt.read_text())['cleanup']['status'], 'failed')
        self.assertFalse(any(c[0] in ('shutdown', 'delete') for c in self.calls))

    def test_missing_type_refuses_creation_and_environment_write_failure_keeps_cleanup_identity(self):
        del self.original[RUNTIME][0]['deviceTypeIdentifier']
        with self.assertRaisesRegex(ValueError, 'exact device type'): self.create()
        self.assertEqual(self.calls, [])
        self.original[RUNTIME][0]['deviceTypeIdentifier'] = TYPE
        self.env_file.mkdir()  # Creation succeeds, but publishing its UUID cannot.
        with self.assertRaises(OSError): self.create()
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['creationStatus'], 'failed')
        self.assertEqual(receipt['createdUDID'], CREATED)
        cleanup(self.receipt)
        self.assertEqual(self.inventory, self.original)

    def test_cleanup_refuses_foreign_owner_source_uuid_name_or_environment(self):
        self.create(); original = self.receipt.read_text()
        mutations = [lambda r: r['owner'].update(GITHUB_RUN_ATTEMPT='3'),
                     lambda r: r.update(createdUDID=SOURCE), lambda r: r.update(createdName='iPhone 17')]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                row = json.loads(original); mutate(row); self.receipt.write_text(json.dumps(row)); self.calls.clear()
                with self.assertRaises(ValueError): cleanup(self.receipt)
                self.assertEqual(self.calls, [])
        self.receipt.write_text(original); os.environ['SIMULATOR_ID'] = SOURCE
        with self.assertRaisesRegex(ValueError, 'environment'): cleanup(self.receipt)
        self.assertEqual(self.calls, [])

    def test_cleanup_refuses_runtime_change_and_device_change_without_mutation(self):
        self.create()
        self.runtimes[0]['buildversion'] = '23C52'; self.calls.clear()
        with self.assertRaisesRegex(ValueError, 'runtime identity changed'): cleanup(self.receipt)
        self.assertFalse(any(c[0] in ('shutdown', 'delete') for c in self.calls))
        self.runtimes[0]['buildversion'] = '23C54'; self.inventory[RUNTIME][1]['name'] = 'unrelated'; self.calls.clear()
        with self.assertRaisesRegex(ValueError, 'does not match'): cleanup(self.receipt)
        self.assertFalse(any(c[0] in ('shutdown', 'delete') for c in self.calls))

    def test_no_receipt_or_symlink_or_existing_receipt_never_mutates_devices(self):
        cleanup(self.receipt)
        target = self.root / 'retained-original'; target.write_text('original')
        self.receipt.symlink_to(target)
        with self.assertRaises(ValueError): cleanup(self.receipt)
        with self.assertRaises(ValueError): self.create()
        self.assertEqual(target.read_text(), 'original')
        self.assertEqual(self.calls, [])

    def test_shutdown_failure_is_retained_and_never_followed_by_delete(self):
        self.create(); self.inventory[RUNTIME][1]['state'] = 'Booted'
        original = self.run_simctl
        def fail_shutdown(command, **kwargs):
            if command[2] == 'shutdown': raise subprocess.CalledProcessError(1, command)
            return original(command, **kwargs)
        with patch('select_ci_iphone.subprocess.run', side_effect=fail_shutdown):
            with self.assertRaises(subprocess.CalledProcessError): cleanup(self.receipt)
        self.assertEqual(json.loads(self.receipt.read_text())['cleanup']['status'], 'failed')
        self.assertFalse(any(c[0] == 'delete' for c in self.calls))
        self.assertEqual(len(self.inventory[RUNTIME]), 2)


class OwnedSimulatorWorkflowTests(unittest.TestCase):
    def test_shell_pilot_branches_select_only_two_exact_shards_without_fallback(self):
        from check_ci_workflows import parse_workflow
        root = Path(__file__).resolve().parents[1]
        pilots = [('ci.yml', 'ios-tests', 'ui-01'),
                  ('ios-fixtures.yml', 'fixture-tests', 'contributor-balanced-01')]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            # Run the actual workflow shell with inert CLI replacements only.
            for name, source in {
                'xcrun': '#!/bin/sh\nprintf \'{"devices":{}}\\n\'\n',
                'python3': '#!/bin/sh\ncat >/dev/null\nprintf "%s\\n" "$@" >> "$CAPTURE"\nexit "${SELECTOR_EXIT:-0}"\n',
            }.items():
                executable = folder / name
                executable.write_text(source); executable.chmod(0o755)
            for workflow_name, job, pilot in pilots:
                workflow, _, _ = parse_workflow(root / '.github/workflows' / workflow_name)
                shell = next(s['run'] for s in workflow['jobs'][job]['steps'] if '--create-owned' in s.get('run', ''))
                for shard in ['models', *[f'ui-{i:02d}' for i in range(1, 11)],
                              *[f'contributor-balanced-{i:02d}' for i in range(1, 11)],
                              'RecordsMediaUITests', 'SharedDeliveryUITests-recovery-cook-and-closeout',
                              pilot + '-extra', '']:
                    with self.subTest(workflow=workflow_name, shard=shard):
                        capture = folder / 'arguments'; capture.write_text('')
                        env = dict(os.environ, PATH=str(folder) + ':/usr/bin:/bin', CAPTURE=str(capture),
                                   TEST_SHARD=shard, SELECTOR_EXIT='0')
                        result = subprocess.run(['/bin/bash', '-eo', 'pipefail', '-c', shell], env=env,
                                                capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        expected = ['scripts/select_ci_iphone.py']
                        if shard == pilot: expected += ['--create-owned', '.build/test-simulator-ownership.json']
                        self.assertEqual(capture.read_text().splitlines(), expected)
                capture.write_text(''); env.update(TEST_SHARD=pilot, SELECTOR_EXIT='17')
                result = subprocess.run(['/bin/bash', '-eo', 'pipefail', '-c', shell], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 17)
                self.assertEqual(capture.read_text().splitlines(),
                                 ['scripts/select_ci_iphone.py', '--create-owned', '.build/test-simulator-ownership.json'])

    def test_only_execution_shards_opt_in_and_cleanup_precedes_receipt_upload(self):
        from check_ci_workflows import parse_workflow
        root = Path(__file__).resolve().parents[1]
        expected = {('ci.yml', 'ios-tests'), ('ios-fixtures.yml', 'fixture-tests')}
        observed = set()
        default_callers = set()
        for path in sorted((root / '.github/workflows').glob('*.yml')):
            workflow, _, _ = parse_workflow(path)
            for job_name, job in workflow['jobs'].items():
                key = (path.name, job_name)
                steps = job.get('steps', [])
                create = [i for i, s in enumerate(steps) if '--create-owned' in s.get('run', '')]
                clean = [i for i, s in enumerate(steps) if '--cleanup-owned' in s.get('run', '')]
                if key not in expected:
                    self.assertEqual(create, [], key); self.assertEqual(clean, [], key)
                    for step in steps:
                        for line in step.get('run', '').splitlines():
                            if 'python3 scripts/select_ci_iphone.py' in line:
                                self.assertTrue(line.rstrip().endswith('python3 scripts/select_ci_iphone.py'), key)
                                default_callers.add(key)
                    continue
                observed.add(key)
                self.assertEqual(len(create), 1); self.assertEqual(len(clean), 1)
                self.assertEqual(steps[create[0]]['timeout-minutes'], 8)
                boot = next(i for i, s in enumerate(steps) if 'scripts/boot_ios_simulator.py' in s.get('run', ''))
                run = next(i for i, s in enumerate(steps) if 'bash scripts/run_ios_test_shard.sh' in s.get('run', ''))
                self.assertLess(create[0], boot); self.assertLess(boot, run); self.assertLess(run, clean[0])
                self.assertEqual(steps[boot]['timeout-minutes'], 8)
                self.assertEqual(steps[run]['timeout-minutes'], 40)
                self.assertEqual(steps[clean[0]]['if'], 'always()')
                self.assertEqual(steps[clean[0]]['timeout-minutes'], 2)
                for i, step in enumerate(steps):
                    if step.get('name') == 'Retain speech runtime diagnostics': self.assertLess(i, clean[0])
                    if 'actions/upload-artifact@' not in step.get('uses', ''): continue
                    self.assertLess(clean[0], i)
                    paths = step['with']['path'].splitlines()
                    if step.get('name') == 'Retain Records media result counts and timing':
                        self.assertEqual(set(paths), {'.build/records-test-report.md', '.build/test-plan/',
                                                    '.build/test-simulator-ownership.json'})
                    else:
                        self.assertIn('.build/test-*.json', paths)
        self.assertEqual(observed, expected)
        self.assertTrue({('ci.yml', 'ios-build'), ('ios-fixtures.yml', 'build-contributor'),
                         ('ios-fixtures.yml', 'build-dinner'), ('ios-performance.yml', 'performance-build'),
                         ('ios-performance.yml', 'performance-tests')}.issubset(default_callers))


if __name__ == '__main__':
    unittest.main()
