"""Offline state/error tests for the qualified StoreKit runtime import sequence."""
import ast
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

import prepare_github_storekit_runtime as preparation


class Clock:
    def __init__(self):
        self.now = 0

    def monotonic(self):
        return self.now

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class RuntimeImportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.evidence = Path(self.temporary.name)
        self.root = '/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/' + 'a' * 40 + '.asset/AssetData'
        self.payload = self.root + '/Restore/043-87504-067.dmg'
        self.pending = {
            'identifier': '187B8B6A-F26F-4641-BF7C-4EE359B837BA', 'deletable': True,
            'path': self.payload, 'parentMountPath': self.root, 'state': 'Verifying',
        }
        self.known = dict(self.pending, runtimeIdentifier='com.apple.CoreSimulator.SimRuntime.iOS-26-2',
                          build='23C54', state='Ready')
        # Load the actual nested functions without executing the native entry point.
        # Their closure is supplied by recorded-shape fixtures, not a second algorithm.
        tree = ast.parse(Path(preparation.__file__).read_text())
        entry = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'prepare')
        functions = [node for node in entry.body if isinstance(node, ast.FunctionDef)]
        self.context = {
            'json': json, 'uuid': uuid, 'Path': Path, 'subprocess': subprocess, 'time': Clock(),
            'runtime': self.known['runtimeIdentifier'], 'build': '23C54', 'evidence': self.evidence,
            'asset_prefix': '/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/',
            'asset_paths': {self.root}, 'payload_paths': {self.payload},
            'allowed_paths': {self.root, self.payload}, 'payload_name': Path('Restore/043-87504-067.dmg'),
        }
        exec(compile(ast.Module(body=functions, type_ignores=[]), str(preparation.__file__), 'exec'), self.context)
        # Any test accidentally reaching a native subprocess must fail immediately.
        self.native = patch.object(subprocess, 'run', side_effect=AssertionError('Unexpected native operation'))
        self.native.start()
        self.addCleanup(self.native.stop)

    def rows(self, *rows):
        return {row['identifier']: row for row in rows}

    def sequence(self, *snapshots):
        remaining = iter(snapshots)
        latest = {}
        self.snapshots = []

        def images(name, timeout=None):
            nonlocal latest
            latest = next(remaining, latest)
            self.snapshots.append(name)
            return latest

        self.context['images'] = images

    def test_empty_then_pending_then_known_waits_without_deleting(self):
        self.sequence({}, self.rows(self.pending), self.rows(self.known))
        result = self.context['wait_for_scan_identity'](20)
        self.assertEqual(result, [self.known])
        self.assertEqual(len(self.snapshots), 3)
        observations = json.loads((self.evidence / 'recovery-wait.json').read_text())
        self.assertEqual([row['time'] for row in observations], [0, 5, 10])

    def test_pending_or_missing_identity_times_out(self):
        for snapshot in ({}, self.rows(self.pending)):
            with self.subTest(snapshot=snapshot):
                self.context['time'] = Clock()
                self.sequence(snapshot)
                with self.assertRaisesRegex(AssertionError, 'did not settle'):
                    self.context['wait_for_scan_identity'](10)
                self.assertEqual(self.context['time'].now, 10)

    def test_scan_rejects_wrong_build_unrelated_exact_build_and_unexpected_descendant(self):
        for row in (dict(self.known, build='23C52'), dict(self.known, path='/unrelated/image.dmg', parentMountPath=''),
                    dict(self.pending, path=self.root + '/Restore/other.dmg')):
            with self.subTest(row=row):
                self.sequence(self.rows(row))
                with self.assertRaises(AssertionError):
                    self.context['wait_for_scan_identity'](10)

    def test_unknown_identity_cannot_reach_delete(self):
        with self.assertRaisesRegex(AssertionError, 'identity still unknown'):
            self.context['delete_exact']([self.pending], 'delete')

    def test_descendant_requires_exact_exported_name_parent_and_deletable_identity(self):
        self.context['validate_original'](self.known)
        for change in ({'parentMountPath': '/different'}, {'deletable': False},
                       {'runtimeIdentifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'}):
            with self.subTest(change=change), self.assertRaises(AssertionError):
                self.context['validate_original'](dict(self.known, **change))

    def deletion(self, *, code=30, detail=None, retained=False, allow=True):
        row = dict(self.known, path=self.root)
        message = (
            'domain=com.apple.CoreSimulator.simdiskimaged.SimDiskImageError, code=30\n'
            'Removed the runtime, but did not reclaim its MobileAsset: ' + self.root + '/\n'
            "Run 'xcrun simctl runtime scan-and-mount' to re-register the runtime, then delete it again.\n")
        (self.evidence / ('delete-' + row['identifier'] + '.log')).write_text(message if detail is None else detail)
        self.sequence(self.rows(row), self.rows(row) if retained else {})
        self.context['operation'] = lambda name, command: subprocess.CompletedProcess(command, code)
        return self.context['delete_exact']([row], 'delete', allow_known_purge_failure=allow)

    def test_only_exact_reclaimed_registration_error_allows_one_recovery(self):
        self.assertFalse(self.deletion())
        self.assertEqual(json.loads((self.evidence / 'known-purge-recovery.json').read_text())['exit'], 30)
        self.assertTrue(self.deletion(code=0))
        for parameters in ({'code': 1}, {'detail': 'unknown error 30'}, {'retained': True}, {'allow': False}):
            with self.subTest(parameters=parameters), self.assertRaises(subprocess.CalledProcessError):
                self.deletion(**parameters)

    def test_absence_checks_include_pending_rows_without_build_identity(self):
        for row in (self.pending, self.known):
            with self.subTest(row=row), self.assertRaises(AssertionError):
                self.context['require_no_original'](self.rows(row))
        self.context['require_no_original']({})

    def test_confirmation_rejects_delayed_pending_row(self):
        self.sequence({}, self.rows(self.pending))
        with patch.object(Path, 'exists', return_value=False), self.assertRaisesRegex(AssertionError, 'pending'):
            self.context['confirm_absence'](15)

    def test_confirmation_allows_empty_catalog_but_not_payload(self):
        self.sequence({})
        with patch.object(Path, 'exists', return_value=False):
            self.context['confirm_absence'](10)
        self.assertEqual(self.context['time'].now, 10)
        self.sequence({})
        with patch.object(Path, 'exists', return_value=True), self.assertRaisesRegex(AssertionError, 'payload'):
            self.context['confirm_absence'](10)

    def test_entry_refuses_non_github_host_without_any_native_operation(self):
        with patch.dict(preparation.os.environ, {'RUNNER_ENVIRONMENT': 'self-hosted', 'GITHUB_ACTIONS': 'true'}):
            with self.assertRaises(AssertionError):
                preparation.prepare()


if __name__ == '__main__':
    unittest.main()
