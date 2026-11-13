import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import preserve_performance_store as proof
from select_ci_iphone import owned_name

CREATED = '22222222-2222-4222-8222-222222222222'
SOURCE = '11111111-1111-4111-8111-111111111111'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'


class PreservePerformanceStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.folder = self.root / 'evidence'; self.folder.mkdir()
        self.env = {'GITHUB_REPOSITORY': 'test/repo', 'GITHUB_RUN_ID': '42', 'GITHUB_RUN_ATTEMPT': '1',
                    'GITHUB_JOB': 'performance-tests', 'TEST_SHARD': 'performance-scroll',
                    'DEVELOPER_DIR': '/Applications/Xcode_27.1.app/Contents/Developer', 'SIMULATOR_ID': CREATED}
        self.environment = patch.dict(os.environ, self.env); self.environment.start(); self.addCleanup(self.environment.stop)
        self.home = patch.object(Path, 'home', return_value=self.root); self.home.start(); self.addCleanup(self.home.stop)
        owner = proof.owner_identity(); nonce = '33333333-3333-4333-8333-333333333333'
        self.runtime = {'identifier': RUNTIME, 'version': '27.0', 'buildversion': '24A434', 'bundlePath': '/runtimes/iOS27.simruntime'}
        self.receipt = {'schema': 1, 'owner': owner, 'sourceUDID': SOURCE, 'createdUDID': CREATED,
                        'nonce': nonce, 'createdName': owned_name(owner, nonce), 'creationStatus': 'verified',
                        'runtime': self.runtime, 'deviceTypeIdentifier': TYPE, 'cleanup': {'status': 'not-run'}}
        self.write_receipt()
        self.container = self.root / 'Library/Developer/CoreSimulator/Devices' / CREATED / 'data/Containers/Data/Application' / '44444444-4444-4444-8444-444444444444'
        self.store = self.container / 'Library/Application Support/RoomInTheCart/ledger.sqlite'
        self.store.parent.mkdir(parents=True)
        self.writer = sqlite3.connect(self.store)
        self.addCleanup(self.writer.close)
        self.writer.execute('PRAGMA journal_mode=WAL')
        self.writer.execute('CREATE TABLE synthetic_fixture(value INTEGER)')
        self.writer.commit(); self.writer.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        self.writer.execute('INSERT INTO synthetic_fixture VALUES (500)'); self.writer.commit()
        self.device = {'udid': CREATED, 'name': self.receipt['createdName'], 'deviceTypeIdentifier': TYPE,
                       'isAvailable': True, 'state': 'Booted'}
        self.inventory = {'runtimes': [{**self.runtime, 'isAvailable': True}], 'devices': {RUNTIME: [self.device]}}
        self.commands = []
        self.cli = patch.object(proof, 'command', side_effect=self.fake_command)
        self.cli.start(); self.addCleanup(self.cli.stop)

    def write_receipt(self):
        (self.folder / proof.RECEIPT).write_text(json.dumps(self.receipt))

    def fake_command(self, args, deadline):
        self.commands.append(args)
        if args == ['list', '-j']:
            return json.dumps(self.inventory)
        if args == ['get_app_container', CREATED, 'dev.roominthecart.app', 'data']:
            return str(self.container)
        raise AssertionError(args)

    def attempted(self):
        proof.mark_attempt(self.folder)

    def outcome(self):
        return json.loads((self.folder / proof.OUTCOME).read_text())

    def assert_cleanup_blocked(self):
        with self.assertRaises((ValueError, OSError)):
            proof.require_preserved(self.folder)

    def test_failed_native_and_strict_runs_preserve_committed_wal_before_cleanup(self):
        # The latest row is WAL-only, so copying just ledger.sqlite would lose it.
        with sqlite3.connect(self.store.as_uri() + '?immutable=1', uri=True) as disk_only:
            self.assertEqual(disk_only.execute('SELECT count(*) FROM synthetic_fixture').fetchone()[0], 0)
        original = {p: proof.digest(p) for p in (self.store, Path(str(self.store) + '-wal'))}
        self.attempted()
        (self.folder / 'Performance.log').write_text('TEST FAILED; native exit65; strict check failed\n')
        proof.preserve(self.folder)
        proof.require_preserved(self.folder)
        with sqlite3.connect(self.folder / proof.SNAPSHOT) as saved:
            self.assertEqual(saved.execute('SELECT value FROM synthetic_fixture').fetchall(), [(500,)])
        self.assertEqual({p: proof.digest(p) for p in original}, original)
        self.assertEqual(self.outcome()['status'], 'preserved')
        self.assertEqual(self.outcome()['snapshotSHA256'], proof.digest(self.folder / proof.SNAPSHOT))
        self.assertEqual(self.commands, [['list', '-j'], ['get_app_container', CREATED, 'dev.roominthecart.app', 'data']])

    def test_no_attempt_never_reads_app_or_device_and_allows_owned_cleanup(self):
        proof.preserve(self.folder); proof.require_preserved(self.folder)
        self.assertEqual(self.outcome()['status'], 'not-attempted')
        self.assertFalse(self.commands)
        self.assertFalse((self.folder / proof.SNAPSHOT).exists())

    def test_missing_receipt_or_no_created_uuid_is_explicit_without_native_reads(self):
        for absent in (False, True):
            self.receipt['createdUDID'] = None; self.receipt['creationStatus'] = 'pending'; self.write_receipt()
            if absent: (self.folder / proof.RECEIPT).unlink()
            proof.preserve(self.folder); proof.require_preserved(self.folder)
            self.assertEqual(self.outcome()['status'], 'no-owned-device')
        self.assertFalse(self.commands)

    def test_missing_store_after_attempt_is_fatal_and_blocks_cleanup(self):
        self.attempted(); self.writer.close(); self.store.unlink()
        with self.assertRaises(ValueError): proof.preserve(self.folder)
        self.assertEqual(self.outcome()['stage'], 'container')
        self.assertEqual(self.outcome()['status'], 'failed')
        self.assert_cleanup_blocked()

    def test_command_timeout_retains_safe_failure_and_blocks_cleanup(self):
        self.attempted()
        with patch.object(proof, 'command', side_effect=subprocess.TimeoutExpired('private-command', 30, stderr=b'private-path')):
            with self.assertRaises(subprocess.TimeoutExpired): proof.preserve(self.folder)
        text = (self.folder / proof.OUTCOME).read_text()
        self.assertNotIn('private', text)
        self.assertEqual(self.outcome()['errorType'], 'TimeoutExpired')
        self.assert_cleanup_blocked()

    def test_changed_owner_and_source_uuid_never_read_device_data(self):
        for field, value in [('owner', {**self.receipt['owner'], 'GITHUB_RUN_ATTEMPT': '2'}), ('createdUDID', SOURCE)]:
            original = self.receipt[field]; self.receipt[field] = value; self.write_receipt()
            with self.assertRaises(ValueError): proof.preserve(self.folder)
            self.assertFalse(self.commands); self.assert_cleanup_blocked()
            self.receipt[field] = original

    def test_changed_runtime_or_device_identity_stops_before_container_read(self):
        self.attempted()
        mutations = [(self.inventory['runtimes'][0], 'buildversion', 'different'),
                     (self.device, 'name', 'unowned'), (self.device, 'deviceTypeIdentifier', 'wrong'),
                     (self.device, 'isAvailable', False)]
        for row, key, value in mutations:
            old = row[key]; row[key] = value; self.commands.clear()
            with self.assertRaises(ValueError): proof.preserve(self.folder)
            self.assertEqual(self.commands, [['list', '-j']]); self.assert_cleanup_blocked()
            row[key] = old

    def test_foreign_container_and_symlink_store_are_rejected(self):
        self.attempted()
        original = self.container
        self.container = self.root
        with self.assertRaises(ValueError): proof.preserve(self.folder)
        self.assert_cleanup_blocked(); self.container = original
        self.writer.close()
        target = self.store.with_name('other.sqlite'); self.store.rename(target); self.store.symlink_to(target)
        with self.assertRaises(ValueError): proof.preserve(self.folder)
        self.assert_cleanup_blocked()

    def test_marker_requires_verified_ownership_and_cannot_be_reused(self):
        self.receipt['creationStatus'] = 'failed'; self.write_receipt()
        with self.assertRaises(ValueError): proof.mark_attempt(self.folder)
        self.receipt['creationStatus'] = 'verified'; self.write_receipt(); self.attempted()
        with self.assertRaises(ValueError): proof.mark_attempt(self.folder)
        self.receipt['runtime']['buildversion'] = 'changed'; self.write_receipt()
        with self.assertRaises(ValueError): proof.preserve(self.folder)
        self.assertFalse(self.commands); self.assert_cleanup_blocked()

    def test_cleanup_rejects_missing_modified_snapshot_or_attempt_and_running_receipt(self):
        self.attempted(); proof.preserve(self.folder)
        snapshot = self.folder / proof.SNAPSHOT; original = snapshot.read_bytes()
        snapshot.unlink(); self.assert_cleanup_blocked()
        snapshot.write_bytes(original + b'x'); self.assert_cleanup_blocked(); snapshot.write_bytes(original)
        attempt = self.folder / proof.ATTEMPT; marker = attempt.read_bytes()
        attempt.unlink(); self.assert_cleanup_blocked(); attempt.write_bytes(marker)
        outcome = self.outcome(); outcome['status'] = 'running'; outcome['cleanupAllowed'] = False
        (self.folder / proof.OUTCOME).write_text(json.dumps(outcome)); self.assert_cleanup_blocked()

    def test_snapshot_deadline_and_size_cap_leave_no_partial_success(self):
        destination = self.folder / proof.SNAPSHOT
        with self.assertRaises(TimeoutError): proof.snapshot(self.store, destination, time.monotonic() - 1)
        self.assertFalse(destination.exists()); self.assertFalse(destination.with_name(destination.name + '.partial').exists())
        with patch.object(proof, 'MAX_STORE_BYTES', 1):
            with self.assertRaises(ValueError): proof.snapshot(self.store, destination, time.monotonic() + 10)
        self.assertFalse(destination.exists())

    def test_real_command_wrapper_has_bounded_timeout_and_does_not_return_oversized_output(self):
        # Restore the function under test; subprocess remains inert.
        self.cli.stop()
        with patch.object(proof.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, b'{}', b'')) as run:
            proof.command(['list', '-j'], time.monotonic() + 60)
            self.assertEqual(run.call_args.kwargs['timeout'], proof.COMMAND_SECONDS)
            proof.command(['list', '-j'], time.monotonic() + 1)
            self.assertGreater(run.call_args.kwargs['timeout'], 0)
            self.assertLessEqual(run.call_args.kwargs['timeout'], 1)
        with patch.object(proof.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, b'x' * (proof.MAX_COMMAND_BYTES + 1), b'')):
            with self.assertRaises(ValueError): proof.command(['list', '-j'], time.monotonic() + 1)


if __name__ == '__main__':
    unittest.main()
