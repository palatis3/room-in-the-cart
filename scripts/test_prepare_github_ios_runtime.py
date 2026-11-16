"""Offline aggregate-delete classifier and bounded state-machine checks."""
import copy
import os
import sys
import prepare_github_ios_runtime as subject
from check_ci_workflows import parse_workflow
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = json.loads((Path(__file__).parent / 'fixtures/github-runtime-cleanup.json').read_text())
ORIGINAL = FIXTURE['original']
DETAIL = FIXTURE['originalError']
SINGLE_BEFORE = FIXTURE['singleBefore']
SINGLE_DETAIL = FIXTURE['singleError']
RECOVERY_CATALOG = FIXTURE['recoveryCatalog']
RECOVERY_PENDING = FIXTURE['recoveryPending']
RECOVERY_ERRORS = FIXTURE['recoveryErrors']
RECOVERY_ID = next(iter(RECOVERY_PENDING))
WATCH = '4E2A8325-62E2-427F-A198-FFEE1E5EF15A'
IOS_OLD = 'CCB02CE5-F3D8-4937-AEA4-C56E0C73443F'
IOS = 'D6FBE28E-42A8-4F9E-B67A-58140EBB3670'
TV = '54D35026-7325-4069-BF3A-FDFEA26D5885'
NEW_TV = '2F11B40E-98FB-47CC-8A06-A0F4806A5347'
NEW_IOS = '11111111-1111-4111-8111-111111111111'


def preferred_pair():
    # Sanitized original 133201539104 transition: same UUID/asset, new Cryptex twin.
    original = copy.deepcopy(ORIGINAL[TV])
    unusable = {**original, 'state': 'Unusable',
                'unusableSubstate': 'Cryptex Mount Preferred',
                'unusableErrorMessage': 'Cryptex Mount Preferred'}
    twin = {**original, 'identifier': NEW_TV,
            'mountPath': '/private/var/run/com.apple.security.cryptexd/mnt/tvOS_24J360'}
    catalog = {original['path']: {'identity': {k: original[k] for k in ('runtimeIdentifier', 'build', 'version')},
                                 'payloads': [original['path'] + '/Restore/043-16887-522.dmg']}}
    return {TV: original}, {TV: unusable, NEW_TV: twin}, catalog


class PreferredTwinTests(unittest.TestCase):
    def test_observed_preferred_transition_is_bound_to_the_original_asset(self):
        before, rows, catalog = preferred_pair()
        self.assertEqual(subject.preferred_cryptex_twin(TV, before, rows, catalog), NEW_TV)

    def test_missing_ambiguous_preexisting_or_pending_twin_is_rejected(self):
        for variant in ('missing', 'multiple', 'preexisting', 'pending', 'wrong-mount'):
            with self.subTest(variant=variant):
                before, rows, catalog = preferred_pair()
                if variant == 'missing': rows.pop(NEW_TV)
                if variant == 'multiple': rows[NEW_IOS] = {**rows[NEW_TV], 'identifier': NEW_IOS}
                if variant == 'preexisting': before[NEW_TV] = rows[NEW_TV]
                if variant == 'pending': rows[NEW_TV].update(state='Verifying', build=None)
                if variant == 'wrong-mount': rows[NEW_TV]['mountPath'] = rows[TV]['mountPath']
                with self.assertRaises(AssertionError):
                    subject.preferred_cryptex_twin(TV, before, rows, catalog)

    def test_changed_identity_state_error_kind_path_or_payload_cannot_authorize_retention(self):
        for key in (TV, NEW_TV):
            for field, value in [('build', 'wrong'), ('version', None), ('runtimeIdentifier', 'wrong'),
                                 ('path', '/foreign'), ('parentMountPath', '/foreign'),
                                 ('kind', 'Disk Image'), ('deletable', False), ('identifier', NEW_IOS)]:
                with self.subTest(key=key, field=field):
                    before, rows, catalog = preferred_pair(); rows[key][field] = value
                    with self.assertRaises(AssertionError):
                        subject.preferred_cryptex_twin(TV, before, rows, catalog)
        for change in ({'state': 'Ready'}, {'unusableSubstate': 'Mount Failed'}, {'unusableErrorMessage': ''}):
            before, rows, catalog = preferred_pair(); rows[TV].update(change)
            with self.assertRaises(AssertionError): subject.preferred_cryptex_twin(TV, before, rows, catalog)
        before, rows, catalog = preferred_pair(); catalog[before[TV]['path']]['payloads'] = []
        with self.assertRaises(AssertionError): subject.preferred_cryptex_twin(TV, before, rows, catalog)


class ClassifierTests(unittest.TestCase):
    def test_actual_second_pass_purge_authorizes_only_its_original_recorded_asset(self):
        first = FIXTURE['recoveryFirstErrors']
        self.assertEqual(first, [])
        root = subject.eligible_asset_recovery(first, RECOVERY_ERRORS, RECOVERY_CATALOG)
        self.assertEqual(root, RECOVERY_ERRORS[0]['path'])
        subject.validate_original_rows(RECOVERY_PENDING, {root: RECOVERY_CATALOG[root]}, pending=True)
        with self.assertRaises(AssertionError):
            subject.validate_original_rows(RECOVERY_PENDING, {root: RECOVERY_CATALOG[root]})

    def test_repeated_asset_ambiguous_errors_or_wrong_catalog_binding_cannot_authorize_retry(self):
        for first, second in [(RECOVERY_ERRORS, RECOVERY_ERRORS),
                              ([], RECOVERY_ERRORS * 2),
                              ([], [{**RECOVERY_ERRORS[0], 'build': 'wrong'}]),
                              ([], [{**RECOVERY_ERRORS[0], 'classification': 'already-deleting'}])]:
            with self.subTest(first=first, second=second), self.assertRaises(AssertionError):
                subject.eligible_asset_recovery(first, second, RECOVERY_CATALOG)
        root = RECOVERY_ERRORS[0]['path']
        with self.assertRaises(AssertionError):
            subject.eligible_asset_recovery([], RECOVERY_ERRORS, {root: {**RECOVERY_CATALOG[root], 'payloads': []}})

    def test_distinct_prior_ios_purge_does_not_authorize_repeated_tv_purge(self):
        prior = subject.classify_bulk_result(1, DETAIL, ORIGINAL)
        root = subject.eligible_asset_recovery(prior, RECOVERY_ERRORS, RECOVERY_CATALOG)
        self.assertEqual(root, RECOVERY_ERRORS[0]['path'])

    def test_actual_complete_single_runtime_code30_is_bound_to_its_captured_inventory(self):
        status = 30
        result, = subject.classify_bulk_result(status, SINGLE_DETAIL, SINGLE_BEFORE)
        identifier, row = next(iter(SINGLE_BEFORE.items()))
        self.assertEqual(result['identifier'], identifier)
        self.assertEqual(result['path'], row['path'])
        self.assertEqual(result['build'], '24J360')
        self.assertEqual(result['form'], 'single-runtime-code30')
        self.assertEqual(result['lines'], SINGLE_DETAIL.splitlines())

    def test_single_code30_rejects_empty_multiple_mismatched_or_wrong_kind_inventory(self):
        identifier, original = next(iter(SINGLE_BEFORE.items()))
        candidates = [{}, {**SINGLE_BEFORE, WATCH: ORIGINAL[WATCH]}]
        for changes in ({'identifier': WATCH}, {'state': 'Deleting'}, {'kind': 'Disk Image'},
                        {'path': original['path'] + '-wrong'}, {'deletable': False}, {'build': None}):
            candidates.append({identifier: {**original, **changes}})
        for before in candidates:
            with self.subTest(before=before), self.assertRaises(AssertionError):
                subject.classify_bulk_result(30, SINGLE_DETAIL, before)

    def test_single_code30_rejects_wrong_status_path_domain_extra_or_missing_lines(self):
        path = next(iter(SINGLE_BEFORE.values()))['path']
        cases = [(1, SINGLE_DETAIL), (24, SINGLE_DETAIL),
                 (30, SINGLE_DETAIL.replace(path, '/other/asset')),
                 (30, SINGLE_DETAIL.replace('SimDiskImageError', 'OtherError')),
                 (30, SINGLE_DETAIL.replace('code=30', 'code=24')),
                 (30, SINGLE_DETAIL + 'unexpected warning\n'),
                 (30, '\n'.join(SINGLE_DETAIL.splitlines()[:2])),
                 (30, '\n' + SINGLE_DETAIL)]
        for status, detail in cases:
            with self.subTest(status=status, detail=detail), self.assertRaises(AssertionError):
                subject.classify_bulk_result(status, detail, SINGLE_BEFORE)

    def test_actual_three_lines_are_inventory_bound_and_retained(self):
        result = subject.classify_bulk_result(1, DETAIL, ORIGINAL)
        self.assertEqual([r['classification'] for r in result],
                         ['already-deleting', 'already-deleting', 'mobileasset-not-reclaimed'])
        self.assertEqual([r['line'] for r in result], DETAIL.splitlines())
        self.assertEqual([r['identifier'] for r in result], [WATCH, IOS_OLD, IOS])

    def test_wrong_uuid_path_build_version_or_platform_is_not_recognized(self):
        changes = [(WATCH, NEW_IOS), (ORIGINAL[IOS]['path'], '/another/asset'),
                   ('24A434', '23C54'), ('27.0', '26.2'), ('watchOS', 'tvOS'),
                   ('retry in 180s', 'retry in 900s')]
        for old, new in changes:
            with self.subTest(new=new), self.assertRaises(AssertionError):
                subject.classify_bulk_result(1, DETAIL.replace(old, new), ORIGINAL)

    def test_unknown_text_status_or_duplicate_is_fatal(self):
        for status, text in [(2, DETAIL), (1, ''), (1, DETAIL + 'Unknown failure\n'),
                             (1, DETAIL + DETAIL.splitlines()[0] + '\n'), (0, DETAIL)]:
            with self.subTest(status=status, text=text), self.assertRaises(AssertionError):
                subject.classify_bulk_result(status, text, ORIGINAL)

    def test_stale_command_inventory_cannot_authorize_error(self):
        before = copy.deepcopy(ORIGINAL)
        before[IOS]['path'] += '-different'
        with self.assertRaises(AssertionError):
            subject.classify_bulk_result(1, DETAIL, before)

    def test_clean_success_needs_no_error_classification(self):
        self.assertEqual(subject.classify_bulk_result(0, '', ORIGINAL), [])

    def test_countdown_boundaries_are_recorded_without_changing_error_identity(self):
        original_line = DETAIL.splitlines()[0]
        for seconds in (0, 1, 175, 179, 180):
            line = original_line.replace('retry in 180s', f'retry in {seconds}s')
            with self.subTest(seconds=seconds):
                result, = subject.classify_bulk_result(1, line, ORIGINAL)
                self.assertEqual(result['retrySeconds'], seconds)
                self.assertEqual(result['line'], line)
                self.assertEqual(result['identifier'], WATCH)

    def test_out_of_range_and_malformed_countdown_remain_fatal(self):
        for text in ('181', '999', '1000', '-1', '+1', '1.0', '175 ', ' 175', '0175', '', 'one', '١٧٥'):
            line = DETAIL.splitlines()[0].replace('retry in 180s', f'retry in {text}s')
            with self.subTest(text=text), self.assertRaises(AssertionError):
                subject.classify_bulk_result(1, line, ORIGINAL)

    def test_actual_175_second_failure_line_from_captured_log(self):
        lines = [FIXTURE['countdownError'].splitlines()[0]]
        self.assertEqual(len(lines), 1)
        result, = subject.classify_bulk_result(1, lines[0], ORIGINAL)
        self.assertEqual(result['retrySeconds'], 175)
        self.assertEqual(result['identifier'], WATCH)

    def test_complete_captured_log_binds_to_its_command_before_inventory(self):
        before = FIXTURE['countdownBefore']
        detail = FIXTURE['countdownError']
        status = 1
        result = subject.classify_bulk_result(status, detail, before)
        self.assertEqual(len(result), 3)
        self.assertEqual([row['line'] for row in result], detail.splitlines())
        self.assertEqual([row.get('retrySeconds') for row in result], [175, 175, None])
        self.assertEqual(result[-1]['identifier'], '4E95D1D5-20C1-4238-85AF-22D6253E41A7')
        with self.assertRaises(AssertionError):
            subject.classify_bulk_result(status, detail, ORIGINAL)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.evidence = Path(temporary.name)
        self.initial = {k: copy.deepcopy(ORIGINAL[k]) for k in (WATCH, IOS_OLD, IOS, TV)}
        self.rows = copy.deepcopy(self.initial)
        self.payload_for = {r['path']: r['path'] + '/Restore/runtime.dmg' for r in self.initial.values()}
        self.payloads = set(self.payload_for.values())
        self.elapsed = 0
        self.deletes = 0
        self.scans = 0
        self.commands = []
        self.stuck_deleting = False
        self.pending_forever = False
        self.wrong_recreation = None
        self.first_unknown = False
        self.second_unknown = False
        self.second_error = None
        self.second_recreates = False
        self.late_pending = False
        self.attached = False
        self.total_timeout = False
        self.clean_first = False
        self.residual_payload = False
        self.mounted = False
        self.changed_old = False
        self.scan_time = 0
        self.failure_disk_capture = False
        self.single_purge = False
        self.asset_recovery = False
        self.asset_pending_forever = False
        self.asset_change = None
        self.asset_multiple = False
        self.third_recreation = False
        self.third_failure = False
        self.third_residual = False
        self.early_asset_pending = False
        self.preferred_first = False
        self.preferred_first_error = False
        self.preferred_pending_watch = False
        self.preferred_twin_drift = False
        self.preferred_second_survivor = False
        self.preferred_multiple = False
        self.third_preferred_survivor = False
        self.retiring_preferred = False
        self.retiring_change = None
        self.attachment_until = None
        self.attachment_path = None
        self.attachment_mount = '/Library/Developer/CoreSimulator/Volumes/watchOS_24R362'
        self.mount_until = 0
        self.late_attachment = False
        self.physical_registry_return = False
        self.physical_start_elapsed = 0
        original_is_file = Path.is_file
        original_rglob = Path.rglob
        original_exists = Path.exists

        def is_file(path):
            if str(path).startswith('/System/Library/AssetsV2/'):
                return str(path) in self.payloads
            return original_is_file(path)

        def exists(path):
            if str(path).startswith('/System/Library/AssetsV2/'):
                return str(path) in self.payloads or str(path) in self.payload_for
            return original_exists(path)

        def rglob(path, pattern):
            if str(path).startswith('/System/Library/AssetsV2/'):
                return iter(Path(p) for p in sorted(self.payloads) if p.startswith(str(path) + '/'))
            return original_rglob(path, pattern)

        for patcher in [patch.object(subject, 'evidence', self.evidence),
                        patch.object(subject, 'capture', side_effect=self.capture),
                        patch.object(subject.time, 'monotonic', side_effect=lambda: self.elapsed),
                        patch.object(subject.time, 'sleep', side_effect=self.sleep),
                        patch.object(subject.os.path, 'ismount', side_effect=lambda _: self.mounted),
                        patch.object(subject.subprocess, 'run', side_effect=self.run_command),
                        patch.object(subject.subprocess, 'check_output', side_effect=self.read_command),
                        patch.object(Path, 'is_file', is_file), patch.object(Path, 'exists', exists),
                        patch.object(Path, 'rglob', rglob)]:
            patcher.start()
            self.addCleanup(patcher.stop)

    def sleep(self, seconds):
        self.assertGreater(seconds, 0)
        self.elapsed += seconds

    def capture(self, name, timeout=30):
        if self.deletes == 1 and not self.clean_first:
            if self.retiring_preferred and WATCH in self.rows:
                self.rows[WATCH].update(state='Unusable', unusableSubstate='Cryptex Mount Preferred',
                                        unusableErrorMessage='Cryptex Mount Preferred')
                if self.retiring_change: self.rows[WATCH].update(self.retiring_change)
            if self.changed_old and IOS_OLD in self.rows:
                self.rows[IOS_OLD]['version'] = '26.2'
            if self.elapsed >= 5 and not self.stuck_deleting:
                for identifier in self.initial:
                    if not (self.preferred_first and identifier == TV):
                        self.rows.pop(identifier, None)
            if self.preferred_twin_drift and self.scans == 1:
                self.rows[NEW_TV]['state'] = 'Unusable'
            if self.scans == 1 and NEW_IOS in self.rows and self.elapsed >= self.scan_time + 5 and not self.pending_forever:
                self.rows[NEW_IOS].update({k: ORIGINAL[IOS][k] for k in ('runtimeIdentifier', 'build', 'version')})
                self.rows[NEW_IOS]['state'] = 'Ready'
        if self.scans == 2 and self.late_pending and self.elapsed >= self.scan_time + 10:
            self.rows[NEW_IOS] = self.recreated_ios(pending=True)
        if self.deletes == 2 and self.scans == 2 and self.asset_recovery:
            if self.elapsed >= self.scan_time + 5 and not self.asset_pending_forever and RECOVERY_ID in self.rows:
                # Only this readiness transition is simulated; the pending row is original evidence.
                self.rows[RECOVERY_ID].update(RECOVERY_CATALOG[RECOVERY_ERRORS[0]['path']]['identity'])
                self.rows[RECOVERY_ID]['state'] = 'Ready'
            if self.asset_change and RECOVERY_ID in self.rows:
                self.rows[RECOVERY_ID].update(self.asset_change)
        if self.physical_registry_return and name.startswith('physical-settle-'):
            self.rows[NEW_TV] = {**ORIGINAL[TV], 'identifier': NEW_TV}
        result = copy.deepcopy(self.rows)
        (self.evidence / name).write_text(json.dumps(result))
        return result

    def recreated_ios(self, pending=False):
        return {**ORIGINAL[IOS], 'identifier': NEW_IOS,
                'path': self.payload_for[ORIGINAL[IOS]['path']], 'parentMountPath': ORIGINAL[IOS]['path'],
                'runtimeIdentifier': None if pending else ORIGINAL[IOS]['runtimeIdentifier'],
                'build': None if pending else ORIGINAL[IOS]['build'],
                'version': None if pending else ORIGINAL[IOS]['version'],
                'state': 'Verifying' if pending else 'Ready'}

    def run_command(self, command, **kwargs):
        self.commands.append(command)
        if command == ['xcrun', 'simctl', 'runtime', 'delete', 'all', '--dry-run']:
            return subprocess.CompletedProcess(command, 0)
        if command == ['xcrun', 'simctl', 'runtime', 'scan-and-mount']:
            self.scans += 1
            self.scan_time = self.elapsed
            self.assertLessEqual(self.scans, 3 if self.asset_recovery else 2)
            if self.scans == 1 and not self.clean_first and not self.single_purge:
                self.rows[NEW_IOS] = self.recreated_ios(pending=True)
            if self.scans == 2 and self.asset_recovery:
                self.rows = copy.deepcopy(RECOVERY_PENDING)
                if self.asset_multiple:
                    self.rows[NEW_TV] = {**self.rows[RECOVERY_ID], 'identifier': NEW_TV}
            return subprocess.CompletedProcess(command, 0)
        if command == ['xcrun', 'simctl', 'runtime', 'delete', RECOVERY_ID]:
            self.assertTrue(self.asset_recovery)
            self.assertEqual(self.deletes, 2)
            self.assertEqual(self.rows[RECOVERY_ID]['state'], 'Ready')
            self.assertEqual(self.rows[RECOVERY_ID]['build'], '24J360')
            self.deletes += 1
            if self.third_failure:
                kwargs['stdout'].write('Unqualified exact-delete failure')
                return subprocess.CompletedProcess(command, 30)
            if self.third_preferred_survivor:
                original = self.rows[RECOVERY_ID]
                self.rows = {RECOVERY_ID: {**original, 'state': 'Unusable',
                    'unusableSubstate': 'Cryptex Mount Preferred', 'unusableErrorMessage': 'Cryptex Mount Preferred'},
                    NEW_TV: {**original, 'identifier': NEW_TV,
                             'mountPath': '/private/var/run/com.apple.security.cryptexd/mnt/tvOS_24J360'}}
                return subprocess.CompletedProcess(command, 0)
            self.rows.clear()
            if not self.third_residual:
                self.payloads.clear()
            if self.third_recreation:
                self.rows[NEW_TV] = {**ORIGINAL[TV], 'identifier': NEW_TV}
            return subprocess.CompletedProcess(command, 0)
        self.assertEqual(command, ['xcrun', 'simctl', 'runtime', 'delete', 'all'])
        self.deletes += 1
        self.assertLessEqual(self.deletes, 2)
        if self.deletes == 1:
            if self.clean_first:
                self.rows.clear(); self.payloads.clear()
                self.elapsed += self.physical_start_elapsed
                return subprocess.CompletedProcess(command, 0)
            for identifier in (WATCH, IOS_OLD):
                self.rows[identifier]['state'] = 'Deleting'
            for identifier in (IOS, TV):
                self.rows.pop(identifier)
            self.rows[NEW_TV] = {**ORIGINAL[TV], 'identifier': NEW_TV}
            if self.wrong_recreation:
                self.rows[NEW_TV].update(self.wrong_recreation)
            self.payloads.discard(self.payload_for[ORIGINAL[WATCH]['path']])
            if self.single_purge:
                self.payloads.discard(self.payload_for[ORIGINAL[IOS]['path']])
            if self.preferred_first:
                _, pair, _ = preferred_pair()
                self.rows.update(pair)
                if self.preferred_multiple:
                    self.rows.pop(IOS_OLD, None)
                    original = ORIGINAL[IOS]
                    self.rows[IOS] = {**original, 'state': 'Unusable',
                        'unusableSubstate': 'Cryptex Mount Preferred', 'unusableErrorMessage': 'Cryptex Mount Preferred'}
                    self.rows[NEW_IOS] = {**original, 'identifier': NEW_IOS,
                        'mountPath': '/private/var/run/com.apple.security.cryptexd/mnt/iOS_24A434'}
                if self.preferred_pending_watch:
                    self.rows[RECOVERY_ID] = {**ORIGINAL[WATCH], 'identifier': RECOVERY_ID,
                        'state': 'Unusable', 'unusableSubstate': 'Mount Failed',
                        'runtimeIdentifier': None, 'build': None, 'version': None}
                if not self.preferred_first_error:
                    return subprocess.CompletedProcess(command, 0)
            kwargs['stdout'].write(DETAIL + ('Unknown error\n' if self.first_unknown else ''))
            if self.total_timeout:
                self.elapsed += 600
            return subprocess.CompletedProcess(command, 1)
        if self.second_unknown:
            kwargs['stdout'].write('Unknown second delete failure\n')
            return subprocess.CompletedProcess(command, 1)
        if self.preferred_second_survivor:
            self.rows = preferred_pair()[1]
            return subprocess.CompletedProcess(command, 0)
        self.rows.clear()
        if not self.residual_payload:
            self.payloads.clear()
        if self.second_recreates:
            self.rows[NEW_TV] = {**ORIGINAL[TV], 'identifier': NEW_TV}
        if self.single_purge:
            if self.early_asset_pending:
                self.rows = copy.deepcopy(RECOVERY_PENDING)
            kwargs['stdout'].write(SINGLE_DETAIL)
            return subprocess.CompletedProcess(command, 30)
        if self.second_error:
            identifier, row = self.second_error
            prefix = f"Error deleting P: {identifier} iOS ({row['version']} - {row['build']}) "
            kwargs['stdout'].write(prefix + '(Ready): Removed the runtime, but did not reclaim its MobileAsset: ' + row['path'] + '/\n')
            return subprocess.CompletedProcess(command, 1)
        return subprocess.CompletedProcess(command, 0)

    def read_command(self, command, **kwargs):
        self.commands.append(command)
        if command == ['hdiutil', 'info', '-plist']:
            if self.failure_disk_capture and self.deletes:
                raise OSError('disk capture unavailable')
            images = [{'image-path': self.payload_for[ORIGINAL[TV]['path']],
                       'system-entities': [{'dev-entry': '/dev/disk23'}]}] if self.attached else []
            if ((self.scans >= 2 and self.attachment_until is not None and self.elapsed < self.attachment_until)
                    or (self.late_attachment and self.scans == 2 and self.elapsed >= self.scan_time + 10)):
                images.append({'image-path': self.attachment_path or self.payload_for[ORIGINAL[WATCH]['path']],
                               'system-entities': [{'dev-entry': '/dev/disk22s1', 'mount-point': self.attachment_mount}]})
            return plistlib.dumps({'images': images})
        self.assertEqual(command, ['/sbin/mount'])
        mounts = ('/dev/disk22s1 on ' + self.attachment_mount + ' (apfs, sealed, read-only)\n'
                  if self.scans >= 2 and self.elapsed < self.mount_until else '')
        return mounts if kwargs.get('text') else mounts.encode()

    def receipt(self):
        return json.loads((self.evidence / 'aggregate-cleanup.json').read_text())

    def configure_asset_recovery(self):
        self.asset_recovery = True
        self.single_purge = True
        self.residual_payload = True
        root = RECOVERY_ERRORS[0]['path']
        self.payloads.remove(self.payload_for[root])
        self.payload_for[root] = RECOVERY_CATALOG[root]['payloads'][0]
        self.payloads.add(self.payload_for[root])

    def test_observed_errors_pending_identity_and_recreation_finish_with_two_deletions(self):
        mounts, observations = subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (2, 2))
        self.assertEqual(self.elapsed, 70)
        self.assertGreaterEqual(observations, 13)
        self.assertIn(ORIGINAL[TV]['mountPath'], mounts)
        self.assertEqual(self.receipt()['outcome'], 'success')
        result = json.loads((self.evidence / 'delete-all-classification.json').read_text())
        self.assertEqual(len(result['recognizedErrors']), 3)

    def test_preferred_original_and_twin_use_existing_second_delete_then_full_absence(self):
        self.preferred_first = True
        _, observations = subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (2, 2))
        self.assertGreaterEqual(observations, 13)
        self.assertEqual(self.receipt()['retainedPreferredTwins'], {TV: NEW_TV})
        second = json.loads((self.evidence / 'delete-recreated-originals-before.json').read_text())
        self.assertEqual(second[TV]['state'], 'Unusable')
        self.assertEqual(second[NEW_TV]['state'], 'Ready')
        self.assertEqual(self.receipt()['outcome'], 'success')
        self.assertEqual(self.receipt()['mutations'], 2)
        self.assertEqual(self.elapsed, 70)  # Five seconds each for retirement/settling, then 60 absent.

    def test_multiple_otherwise_valid_preferred_pairs_fail_before_scan_or_second_delete(self):
        self.preferred_first = self.preferred_multiple = True
        with self.assertRaisesRegex(AssertionError, 'More than one'):
            subject.cleanup_original_images(self.initial)
        catalog = json.loads((self.evidence / 'original-payload-catalog.json').read_text())
        self.assertEqual(subject.preferred_cryptex_twin(TV, self.initial, self.rows, catalog), NEW_TV)
        self.assertEqual(subject.preferred_cryptex_twin(IOS, self.initial, self.rows, catalog), NEW_IOS)
        self.assertEqual((self.deletes, self.scans), (1, 0))

    def test_preferred_transition_after_nonzero_first_delete_is_not_authorized(self):
        self.preferred_first = self.preferred_first_error = True
        with self.assertRaisesRegex(AssertionError, 'Deleting'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (1, 0))

    def test_identityless_mount_failed_watch_row_still_times_out_without_second_delete(self):
        self.preferred_first = self.preferred_pending_watch = True
        with self.assertRaisesRegex(AssertionError, '120 seconds'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (1, 1))
        self.assertEqual(self.elapsed, 125)

    def test_preferred_twin_is_revalidated_after_scan(self):
        self.preferred_first = self.preferred_twin_drift = True
        with self.assertRaisesRegex(AssertionError, 'new Ready'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (1, 1))

    def test_preferred_survivor_after_final_exact_deletion_never_authorizes_a_fourth(self):
        self.configure_asset_recovery()
        self.third_preferred_survivor = True
        with self.assertRaisesRegex(AssertionError, 'Deleting'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (3, 2))
        self.assertEqual(self.receipt()['outcome'], 'failure')

    def test_preferred_pair_cannot_survive_second_delete_or_authorize_a_third(self):
        self.preferred_first = self.preferred_second_survivor = True
        with self.assertRaisesRegex(AssertionError, 'Deleting'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (2, 1))

    def configure_pending_preferred_retirement(self):
        self.retiring_preferred = True
        self.initial[WATCH]['state'] = 'Deleting'
        self.rows[WATCH]['state'] = 'Deleting'

    def test_observed_deleting_to_preferred_waits_for_real_uuid_retirement(self):
        self.configure_pending_preferred_retirement()
        subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (2, 2))
        self.assertEqual(self.elapsed, 70)
        self.assertIn(WATCH, self.receipt()['pendingPreferredRetirements'])
        second = json.loads((self.evidence / 'delete-recreated-originals-before.json').read_text())
        self.assertNotIn(WATCH, second)
        self.assertNotIn('retainedPreferredTwins', self.receipt())

    def test_persistent_preferred_retirement_expires_without_scan_or_second_mutation(self):
        self.configure_pending_preferred_retirement(); self.stuck_deleting = True
        with self.assertRaisesRegex(AssertionError, '210 seconds'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.elapsed, self.deletes, self.scans), (210, 1, 0))

    def test_pending_retirement_does_not_accept_identity_kind_or_other_unusable_state(self):
        for change in ({'build': 'wrong'}, {'path': '/foreign'}, {'parentMountPath': '/foreign'},
                       {'kind': 'Disk Image'}, {'unusableSubstate': 'Mount Failed'},
                       {'unusableErrorMessage': 'other'}, {'runtimeIdentifier': None}):
            with self.subTest(change=change):
                self.configure_pending_preferred_retirement(); self.retiring_change = change
                with self.assertRaises(AssertionError): subject.cleanup_original_images(self.initial)
                self.assertEqual((self.deletes, self.scans), (1, 0))
                self.deletes = 0; self.rows = copy.deepcopy(self.initial)

    def test_confirmation_scan_exposes_old_attachment_and_new_mount_before_absence_clock(self):
        self.clean_first = True; self.attachment_until = 10; self.mount_until = 15
        self.initial[WATCH].pop('mountPath'); self.rows[WATCH].pop('mountPath')
        mounts, observations = subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (1, 2))
        self.assertEqual(self.elapsed, 75)
        self.assertEqual(observations, 13)
        self.assertIn(self.attachment_mount, mounts)
        pending = json.loads((self.evidence / 'disks-settle-0-pending.json').read_text())
        self.assertTrue(any('remains attached:' in item for item in pending))
        self.assertIn('Old runtime mount remains', pending)
        self.assertFalse(json.loads((self.evidence / 'disks-settle-3-pending.json').read_text()))

    def test_unknown_attached_descendant_or_foreign_image_on_old_mount_fails_immediately(self):
        for value in (ORIGINAL[WATCH]['path'] + '/Restore/unrecorded.dmg', '/foreign/runtime.dmg'):
            with self.subTest(value=value):
                self.clean_first = True; self.attachment_until = 10; self.attachment_path = value
                with self.assertRaises(AssertionError): subject.cleanup_original_images(self.initial)
                self.assertEqual((self.elapsed, self.deletes, self.scans), (0, 1, 2))
                self.deletes = self.scans = 0; self.rows = copy.deepcopy(self.initial)
                self.payloads = set(self.payload_for.values())

    def test_registry_recreation_during_physical_settle_is_not_waited_away(self):
        self.clean_first = self.physical_registry_return = True
        with self.assertRaisesRegex(AssertionError, 'reappeared during physical settle'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (1, 2))

    def test_new_attachment_after_confirmation_fails_without_resetting_absence_clock(self):
        self.clean_first = self.late_attachment = True
        with self.assertRaisesRegex(AssertionError, 'remains attached:'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.elapsed, self.deletes, self.scans), (10, 1, 2))

    def test_physical_settle_cannot_extend_total_six_hundred_second_budget(self):
        self.clean_first = True; self.physical_start_elapsed = 500; self.attachment_until = 1000
        with self.assertRaisesRegex(AssertionError, '600 seconds'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.elapsed, self.deletes, self.scans), (600, 1, 2))

    def test_clean_first_deletion_does_not_make_second_mutation(self):
        self.clean_first = True
        subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (1, 2))
        self.assertEqual(self.elapsed, 60)

    def test_unknown_first_error_prevents_scan_or_retry(self):
        self.first_unknown = True
        with self.assertRaisesRegex(AssertionError, 'Unknown'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (1, 0))
        self.assertEqual(self.receipt()['outcome'], 'failure')

    def test_old_deleting_identity_times_out_without_second_delete(self):
        self.stuck_deleting = True
        with self.assertRaisesRegex(AssertionError, '210 seconds'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual(self.elapsed, 210)
        self.assertEqual((self.deletes, self.scans), (1, 0))

    def test_pending_recovery_identity_times_out_without_deletion(self):
        self.pending_forever = True
        with self.assertRaisesRegex(AssertionError, '120 seconds'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual(self.elapsed, 125)
        self.assertEqual((self.deletes, self.scans), (1, 1))

    def test_old_uuid_identity_drift_prevents_scan_or_second_deletion(self):
        self.changed_old = True
        with self.assertRaisesRegex(AssertionError, 'Original identity changed: version'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (1, 0))

    def test_mounted_old_volume_blocks_success(self):
        self.mounted = True
        with self.assertRaisesRegex(AssertionError, 'physical cleanup did not settle within 210 seconds'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual(self.deletes, 2)
        self.assertEqual(self.elapsed, 220)  # Existing cleanup10 + physical ceiling210; no retries.

    def test_foreign_build_or_payload_path_never_authorizes_second_deletion(self):
        for change in ({'build': 'wrong'}, {'path': ORIGINAL[TV]['path'] + '/unknown.dmg'}):
            with self.subTest(change=change):
                self.wrong_recreation = change
                with self.assertRaises(AssertionError):
                    subject.cleanup_original_images(self.initial)
                self.assertEqual((self.deletes, self.scans), (1, 0))
                self.deletes = 0; self.rows = copy.deepcopy(self.initial)

    def test_second_unknown_error_is_fatal_without_third_mutation(self):
        self.second_unknown = True
        with self.assertRaisesRegex(AssertionError, 'Unknown'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (2, 1))

    def test_second_surviving_ready_registration_is_fatal(self):
        self.second_recreates = True
        with self.assertRaisesRegex(AssertionError, 'Deleting'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual(self.deletes, 2)

    def test_late_pending_registration_fails_sustained_absence(self):
        self.late_pending = True
        with self.assertRaisesRegex(AssertionError, 'reappeared'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (2, 2))

    def test_detached_filesystem_but_attached_old_image_is_rejected(self):
        self.attached = True
        with self.assertRaisesRegex(AssertionError, 'physical cleanup did not settle within 210 seconds'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual(self.deletes, 2)
        self.assertEqual(self.elapsed, 220)

    def test_surviving_payload_blocks_success(self):
        self.residual_payload = True
        with self.assertRaisesRegex(AssertionError, 'payload remains'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual(self.deletes, 2)

    def test_total_deadline_fails_before_additional_calls(self):
        self.total_timeout = True
        with self.assertRaisesRegex(AssertionError, '600 seconds'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (1, 0))

    def test_failure_retains_primary_exception_and_filesystem_when_disk_capture_fails(self):
        self.first_unknown = True
        self.failure_disk_capture = True
        with self.assertRaisesRegex(AssertionError, 'Unknown or ambiguous'):
            subject.cleanup_original_images(self.initial)
        self.assertIn('Unknown or ambiguous', self.receipt()['error'])
        state = json.loads((self.evidence / 'failure-filesystem.json').read_text())
        self.assertEqual(state['commands']['failure-disks.plist']['outcome'], 'failure')
        self.assertEqual(state['commands']['failure-mounts.txt']['outcome'], 'success')
        root = ORIGINAL[IOS]['path']
        self.assertTrue(state['roots'][root][self.payload_for[root]]['exists'])
        self.assertEqual((self.deletes, self.scans), (1, 0))

    def test_failure_evidence_writer_cannot_override_primary_failure(self):
        self.first_unknown = True
        with patch.object(subject, 'collect_cleanup_failure', side_effect=OSError('evidence unavailable')):
            with self.assertRaisesRegex(AssertionError, 'Unknown or ambiguous'):
                subject.cleanup_original_images(self.initial)
        self.assertIn('Unknown or ambiguous', self.receipt()['error'])
        self.assertEqual(self.deletes, 1)

    def test_failure_evidence_commands_are_read_only_and_bounded(self):
        self.first_unknown = True
        calls = []
        def read(command, **kwargs):
            calls.append((command, kwargs))
            return self.read_command(command, **kwargs)
        with patch.object(subject.subprocess, 'check_output', side_effect=read):
            with self.assertRaises(AssertionError):
                subject.cleanup_original_images(self.initial)
        self.assertEqual([command for command, kwargs in calls[-2:]],
                         [['hdiutil', 'info', '-plist'], ['/sbin/mount']])
        self.assertEqual([kwargs['timeout'] for command, kwargs in calls[-2:]], [10, 10])

    def test_exact_asset_retry_cannot_bypass_final_payload_absence(self):
        self.configure_asset_recovery()
        self.third_residual = True
        with self.assertRaisesRegex(AssertionError, 'Original payload remains'):
            subject.cleanup_original_images(self.initial)
        classified = json.loads((self.evidence / 'delete-recreated-originals-classification.json').read_text())
        self.assertEqual(classified['exit'], 30)
        self.assertEqual(classified['recognizedErrors'][0]['form'], 'single-runtime-code30')
        self.assertEqual((self.deletes, self.scans), (3, 3))
        self.assertEqual(self.receipt()['outcome'], 'failure')
        self.assertTrue((self.evidence / 'failure-filesystem.json').is_file())

    def test_actual_pending_asset_requires_simulated_identity_settlement_before_exact_retry(self):
        self.configure_asset_recovery()
        subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (3, 3))
        self.assertEqual(self.elapsed, 70)
        self.assertEqual(self.commands.count(['xcrun', 'simctl', 'runtime', 'delete', 'all']), 2)
        self.assertEqual(self.commands.count(['xcrun', 'simctl', 'runtime', 'delete', RECOVERY_ID]), 1)
        self.assertEqual(self.receipt()['assetRecoveryRoot'], RECOVERY_ERRORS[0]['path'])
        self.assertEqual(self.receipt()['outcome'], 'success')

    def test_only_eligible_pending_asset_can_appear_before_explicit_recovery_scan(self):
        self.configure_asset_recovery()
        self.early_asset_pending = True
        subject.cleanup_original_images(self.initial)
        before_scan = json.loads((self.evidence / 'recreated-removal-wait-0.json').read_text())
        self.assertEqual(before_scan, RECOVERY_PENDING)
        self.assertEqual((self.deletes, self.scans), (3, 3))

    def test_asset_identity_pending_forever_times_out_without_exact_delete(self):
        self.configure_asset_recovery()
        self.asset_pending_forever = True
        with self.assertRaisesRegex(AssertionError, 'Asset recovery did not settle within 120 seconds'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual(self.elapsed, 125)
        self.assertEqual((self.deletes, self.scans), (2, 2))

    def test_foreign_asset_path_or_build_prevents_exact_retry(self):
        for change in ({'path': ORIGINAL[IOS]['path']}, {'build': 'wrong'}):
            with self.subTest(change=change):
                self.configure_asset_recovery()
                self.asset_change = change
                with self.assertRaises(AssertionError):
                    subject.cleanup_original_images(self.initial)
                self.assertEqual(self.deletes, 2)
                self.deletes = 0; self.scans = 0; self.elapsed = 0
                self.rows = copy.deepcopy(self.initial)
                self.payloads = set(self.payload_for.values())

    def test_multiple_pending_rows_prevent_exact_retry(self):
        self.configure_asset_recovery()
        self.asset_multiple = True
        with self.assertRaisesRegex(AssertionError, 'more than one'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual(self.deletes, 2)

    def test_recreation_after_exact_retry_has_no_fourth_mutation(self):
        self.configure_asset_recovery()
        self.third_recreation = True
        with self.assertRaisesRegex(AssertionError, 'no further mutation'):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (3, 2))

    def test_exact_retry_error_is_fatal_without_another_scan_or_mutation(self):
        self.configure_asset_recovery()
        self.third_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            subject.cleanup_original_images(self.initial)
        self.assertEqual((self.deletes, self.scans), (3, 2))



NEW = "33333333-3333-4333-8333-333333333333"
OTHER = "44444444-4444-4444-8444-444444444444"

def registration(identifier, **changes):
    return {"identifier": identifier, "runtimeIdentifier": subject.runtime,
            "build": subject.build, "version": "27.0", "state": "Ready", "kind": "Disk Image",
            "deletable": True, "path": "/Library/Developer/CoreSimulator/Images/test.dmg",
            "mountPath": "/Library/Developer/CoreSimulator/Volumes/iOS_24A434",
            "runtimeBundlePath": "/Library/Developer/CoreSimulator/Volumes/iOS_24A434/iOS.simruntime",
            "supportedArchitectures": ["arm64"], **changes}

class ServiceRefreshTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        evidence = root / "evidence"
        evidence.mkdir()
        image, mount, bundle = root / "runtime.dmg", root / "mount", root / "runtime.simruntime"
        image.write_bytes(b"runtime")
        mount.mkdir()
        runtime_root = bundle / "Contents/Resources/RuntimeRoot"
        runtime_root.mkdir(parents=True)
        self.expected = registration(NEW, path=str(image), mountPath=str(mount), runtimeBundlePath=str(bundle))
        self.inventory = {"devices": {subject.runtime: [{"state": "Shutdown"}]}, "runtimes": [{
            "identifier": subject.runtime, "buildversion": subject.build, "isAvailable": True,
            "bundlePath": str(bundle), "runtimeRoot": str(runtime_root)}]}
        self.commands = []
        self.signaled = False
        self.signal_status = 0
        self.stuck = False
        self.owner = 501
        self.process_name = "com.apple.CoreSimulator.CoreSimulatorService"
        self.initial_pids = [123]
        self.final_pids = [456]
        self.after_changes = {}
        self.elapsed = 0
        env = {"RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_ACTIONS": "true",
               "DEVELOPER_DIR": "/Applications/Xcode_27.1.app/Contents/Developer"}
        for patcher in [patch.object(subject, "evidence", evidence), patch.dict(os.environ, env, clear=True),
                        patch.object(subject.os, "getuid", return_value=501),
                        patch.object(subject.platform, "system", return_value="Darwin"),
                        patch.object(subject.platform, "machine", return_value="arm64"),
                        patch.object(subject.time, "monotonic", side_effect=lambda: self.elapsed),
                        patch.object(subject.time, "sleep", side_effect=self.sleep),
                        patch.object(subject.subprocess, "run", side_effect=self.run_command),
                        patch.object(subject.subprocess, "check_output", side_effect=self.read_command)]:
            patcher.start()
            self.addCleanup(patcher.stop)

    def sleep(self, seconds):
        self.elapsed += seconds

    def read_command(self, command, **kwargs):
        self.commands.append(command)
        if command == ["xcrun", "simctl", "list", "-j"]:
            return json.dumps(self.inventory)
        if command == ["xcrun", "simctl", "runtime", "list", "-j"]:
            row = {**self.expected, **(self.after_changes if self.signaled else {})}
            return json.dumps({NEW: row})
        self.assertEqual(command, ["/bin/ps", "-p", "123", "-o", "uid=", "-o", "comm="])
        return f"{self.owner} /framework/{self.process_name}\n"

    def run_command(self, command, **kwargs):
        self.commands.append(command)
        pattern = r"com\.apple\.CoreSimulator\.CoreSimulatorService"
        if command[0] == "/usr/bin/pgrep":
            self.assertEqual(command, ["/usr/bin/pgrep", "-u", "501", "-x", pattern])
            pids = self.initial_pids if not self.signaled or self.stuck else self.final_pids
            return subprocess.CompletedProcess(command, 0 if pids else 1,
                                               stdout="\n".join(map(str, pids)), stderr="")
        self.assertEqual(command, ["/usr/bin/pkill", "-TERM", "-u", "501", "-x", pattern])
        self.assertFalse(self.signaled, "No second signal or escalation permitted")
        self.signaled = True
        return subprocess.CompletedProcess(command, self.signal_status, stdout="", stderr="signal failure" if self.signal_status else "")

    def receipt(self):
        return json.loads((subject.evidence / "service-refresh.json").read_text())

    def test_success_requires_new_pid_and_preserves_runtime(self):
        subject.refresh_user_service(self.expected)
        self.assertEqual(self.receipt()["outcome"], "success")
        self.assertEqual(self.receipt()["oldPids"], [123])
        self.assertEqual(self.receipt()["newPids"], [456])
        self.assertEqual(sum(c[0] == "/usr/bin/pkill" for c in self.commands), 1)
        self.assertTrue((subject.evidence / "service-before.json").is_file())
        self.assertTrue((subject.evidence / "service-after.json.images.json").is_file())

    def test_wrong_owner_or_executable_never_signals(self):
        for owner, name in [(0, self.process_name), (501, "other-service")]:
            with self.subTest(owner=owner, name=name):
                self.owner, self.process_name = owner, name
                with self.assertRaises(AssertionError):
                    subject.refresh_user_service(self.expected)
                self.assertFalse(self.signaled)
                self.assertEqual(self.receipt()["outcome"], "failure")

    def test_booted_unrelated_device_never_signals(self):
        self.inventory["devices"]["watchOS"] = [{"state": "Booted"}]
        with self.assertRaisesRegex(AssertionError, "simulator is active"):
            subject.refresh_user_service(self.expected)
        self.assertFalse(self.signaled)

    def test_multiple_or_absent_user_services_never_signals(self):
        for pids in ([], [123, 124]):
            with self.subTest(pids=pids):
                self.initial_pids = pids
                with self.assertRaises(AssertionError):
                    subject.refresh_user_service(self.expected)
                self.assertFalse(self.signaled)

    def test_missing_physical_root_never_signals(self):
        Path(self.inventory["runtimes"][0]["runtimeRoot"]).rmdir()
        with self.assertRaisesRegex(AssertionError, "RuntimeRoot"):
            subject.refresh_user_service(self.expected)
        self.assertFalse(self.signaled)

    def test_changed_runtime_after_refresh_is_rejected(self):
        self.after_changes = {"identifier": OTHER}
        with self.assertRaisesRegex(AssertionError, "identifier"):
            subject.refresh_user_service(self.expected)
        self.assertEqual(self.receipt()["outcome"], "failure")
        self.assertTrue(self.receipt()["oldExited"])

    def test_signal_failure_is_fatal_without_retry(self):
        self.signal_status = 1
        with self.assertRaises(subprocess.CalledProcessError):
            subject.refresh_user_service(self.expected)
        self.assertEqual(self.receipt()["signalExit"], 1)
        self.assertNotIn("oldExited", self.receipt())
        self.assertEqual(sum(c[0] == "/usr/bin/pkill" for c in self.commands), 1)

    def test_stuck_service_fails_at_60_seconds_without_escalation(self):
        self.stuck = True
        with self.assertRaisesRegex(AssertionError, "no escalation"):
            subject.refresh_user_service(self.expected)
        self.assertEqual(self.elapsed, 60)
        self.assertEqual(sum(c[0] == "/usr/bin/pkill" for c in self.commands), 1)
        self.assertEqual(self.receipt()["outcome"], "failure")

    def test_no_reconnected_service_is_fatal(self):
        self.final_pids = []
        with self.assertRaises(AssertionError):
            subject.refresh_user_service(self.expected)
        self.assertEqual(self.receipt()["outcome"], "failure")

    def test_nonhosted_or_root_process_never_calls_native_tools(self):
        with patch.dict(os.environ, {"RUNNER_ENVIRONMENT": "self-hosted"}), self.assertRaises(AssertionError):
            subject.refresh_user_service(self.expected)
        with patch.object(subject.os, "getuid", return_value=0), self.assertRaises(AssertionError):
            subject.refresh_user_service(self.expected)
        self.assertEqual(self.commands, [])



class PreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        previous = Path.cwd()
        os.chdir(temporary.name)
        self.addCleanup(os.chdir, previous)
        subject.evidence.mkdir(parents=True)
        self.before = {IOS: copy.deepcopy(ORIGINAL[IOS])}
        self.imported = registration(NEW)
        self.commands = []
        self.export_status = 0
        self.payload_count = 1
        self.import_status = 0
        self.device_state = 'Shutdown'
        self.missing_path = None
        self.env = {'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_ACTIONS': 'true',
                    'GITHUB_REPOSITORY': 'palatis3/room-in-the-cart', 'CI_IPHONE_RUNTIME': subject.runtime,
                    'DEVELOPER_DIR': '/Applications/Xcode_27.1.app/Contents/Developer'}
        original_exists, original_dir = Path.exists, Path.is_dir

        def exists(path):
            if str(path) == self.imported['path']:
                return str(path) != self.missing_path
            return original_exists(path)

        def is_dir(path):
            if str(path) in (self.imported['mountPath'], self.imported['runtimeBundlePath']):
                return str(path) != self.missing_path
            return original_dir(path)

        for patcher in [patch.dict(os.environ, self.env, clear=True),
                        patch.object(subject.os, 'getuid', return_value=501),
                        patch.object(subject.subprocess, 'run', side_effect=self.run_command),
                        patch.object(subject.subprocess, 'check_output', side_effect=self.read_command),
                        patch.object(subject, 'capture', side_effect=self.capture),
                        patch.object(Path, 'exists', exists), patch.object(Path, 'is_dir', is_dir)]:
            patcher.start(); self.addCleanup(patcher.stop)
        for name, value in [('cleanup_original_images', (set(), 13)), ('refresh_user_service', None)]:
            patcher = patch.object(subject, name, return_value=value)
            setattr(self, name, patcher.start()); self.addCleanup(patcher.stop)

    def capture(self, name, timeout=30):
        rows = {NEW: copy.deepcopy(self.imported)} if name in ('after-import.json', 'after-tests.json') else self.before
        (subject.evidence / name).write_text(json.dumps(rows))
        return rows

    def read_command(self, command, **kwargs):
        self.commands.append(command)
        self.assertEqual(command, ['xcrun', 'simctl', 'list', 'devices', '-j'])
        return json.dumps({'devices': {'watchOS': [{'state': self.device_state}]}})

    def run_command(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == 'xcodebuild':
            self.assertEqual(command[:5], ['xcodebuild', '-downloadPlatform', 'iOS', '-buildVersion', '24A434'])
            bundle = Path(command[6]) / 'iOS.exportedBundle'
            bundle.mkdir()
            (bundle / 'metadata.plist').write_text('metadata')
            for n in range(self.payload_count):
                (bundle / f'payload-{n}.dmg').write_bytes(b'payload')
            return subprocess.CompletedProcess(command, self.export_status)
        self.assertEqual(command[:6], ['sudo', '-n', '/usr/bin/env',
                         'DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer',
                         '/usr/bin/xcodebuild', '-importPlatform'])
        self.assertEqual(Path(command[-1]).name, 'payload-0.dmg')
        self.assertTrue(Path(command[-1]).is_file())
        if self.import_status:
            raise subprocess.CalledProcessError(self.import_status, command)
        return subprocess.CompletedProcess(command, 0)

    def test_prepare_imports_exact_payload_and_refreshes_once_then_verifies(self):
        subject.prepare(); subject.verify()
        self.cleanup_original_images.assert_called_once_with(self.before)
        self.refresh_user_service.assert_called_once_with(self.imported)
        self.assertEqual(json.loads((subject.evidence / 'target.json').read_text()), self.imported)
        self.assertEqual(json.loads((subject.evidence / 'import-input.json').read_text())['mode'], 'direct-dmg')

    def test_export70_requires_real_payload_and_successful_import(self):
        self.export_status = 70
        subject.prepare()
        self.refresh_user_service.assert_called_once()

    def test_export_failure_never_cleans_or_imports(self):
        self.export_status = 1
        with self.assertRaises(AssertionError): subject.prepare()
        self.cleanup_original_images.assert_not_called()
        self.refresh_user_service.assert_not_called()

    def test_missing_or_ambiguous_payload_never_deletes(self):
        import shutil
        for count in (0, 2):
            with self.subTest(count=count):
                self.payload_count = count
                with self.assertRaises(AssertionError): subject.prepare()
                self.cleanup_original_images.assert_not_called()
                shutil.rmtree('.build/runtime-export')

    def test_wrong_initial_build_prevents_export(self):
        self.before[IOS]['build'] = 'wrong'
        with self.assertRaises(AssertionError): subject.prepare()
        self.assertEqual(self.commands, [])

    def test_active_unrelated_device_blocks_all_cleanup(self):
        self.device_state = 'Booted'
        with self.assertRaises(AssertionError): subject.prepare()
        self.cleanup_original_images.assert_not_called()

    def test_import_failure_cannot_publish_baseline_or_refresh(self):
        self.import_status = 70
        with self.assertRaises(subprocess.CalledProcessError): subject.prepare()
        self.assertFalse((subject.evidence / 'target.json').exists())
        self.refresh_user_service.assert_not_called()

    def test_refresh_failure_prevents_successful_preparation(self):
        self.refresh_user_service.side_effect = RuntimeError('refresh failed')
        with self.assertRaisesRegex(RuntimeError, 'refresh failed'):
            subject.prepare()
        self.assertTrue((subject.evidence / 'target.json').is_file())

    def test_repository_or_root_guard_blocks_cleanup(self):
        import shutil
        for repository, uid in [('other/repository', 501), ('palatis3/room-in-the-cart', 0)]:
            with self.subTest(repository=repository, uid=uid), \
                 patch.dict(os.environ, {'GITHUB_REPOSITORY': repository}), \
                 patch.object(subject.os, 'getuid', return_value=uid), self.assertRaises(AssertionError):
                subject.prepare()
            self.cleanup_original_images.assert_not_called()
            shutil.rmtree('.build/runtime-export')

    def test_changed_export_hash_blocks_import(self):
        def cleanup(rows):
            Path('.build/runtime-export/iOS.exportedBundle/payload-0.dmg').write_bytes(b'changed')
            return set(), 13
        self.cleanup_original_images.side_effect = cleanup
        with self.assertRaises(AssertionError): subject.prepare()
        self.assertFalse(any(c[0] == 'sudo' for c in self.commands))

    def test_import_registration_and_postcheck_reject_cryptex_parent_or_physical_loss(self):
        import shutil
        original = copy.deepcopy(self.imported)
        for change in ({'kind': 'Cryptex'}, {'parentMountPath': '/tmp/export'},
                       {'parentIdentifier': IOS}, {'state': 'Unusable'}, {'path': ORIGINAL[IOS]['path']}):
            with self.subTest(change=change):
                self.imported = {**original, **change}
                with self.assertRaises(AssertionError): subject.prepare()
                self.refresh_user_service.assert_not_called()
                shutil.rmtree('.build/runtime-export')
        self.imported = original
        subject.prepare()
        for change in ({'identifier': OTHER}, {'build': 'wrong'}, {'kind': 'Cryptex'},
                       {'parentIdentifier': IOS}, {'mountPath': '/other/mount'}, {'mountPath': None}):
            with self.subTest(change=change):
                self.imported = {**original, **change}
                with self.assertRaises(AssertionError): subject.verify()
        self.imported = original
        for key in ('path', 'mountPath', 'runtimeBundlePath'):
            with self.subTest(key=key):
                self.missing_path = self.imported[key]
                with self.assertRaises(AssertionError): subject.verify()
        self.assertTrue((subject.evidence / 'verification-filesystem.json').is_file())

    def test_cli_provider_platform_runtime_and_toolchain_guards_prevent_native_calls(self):
        cases = [({'RUNNER_ENVIRONMENT': 'self-hosted'}, 'Darwin', 'arm64'),
                 ({'GITHUB_ACTIONS': ''}, 'Darwin', 'arm64'),
                 ({'CI_IPHONE_RUNTIME': 'com.apple.CoreSimulator.SimRuntime.iOS-26-2'}, 'Darwin', 'arm64'),
                 ({'DEVELOPER_DIR': '/other/Xcode'}, 'Darwin', 'arm64'),
                 ({}, 'Linux', 'arm64'), ({}, 'Darwin', 'x86_64')]
        for changes, system, machine in cases:
            with self.subTest(changes=changes, system=system, machine=machine), \
                 patch.dict(os.environ, {**self.env, **changes}, clear=True), \
                 patch.object(subject.platform, 'system', return_value=system), \
                 patch.object(subject.platform, 'machine', return_value=machine), \
                 patch.object(sys, 'argv', ['prepare_github_ios_runtime.py', 'prepare']), \
                 self.assertRaises(AssertionError):
                subject.main()
        self.assertEqual(self.commands, [])


class RuntimeWorkflowTests(unittest.TestCase):
    def test_github_consumers_all_create_owned_but_bitrise_keeps_existing_pilots(self):
        cases = [('ci.yml', 'ios-tests', ['ui-01', 'ui-05'], 'ui-09'),
                 ('ios-fixtures.yml', 'contributor-tests', ['contributor-balanced-01', 'SharedFallbackUITests'], 'RecordsMediaUITests'),
                 ('ios-fixtures.yml', 'dinner-tests', ['contributor-balanced-01', 'SharedFallbackUITests'], 'dinner-other')]
        for workflow, job, pilots, other in cases:
            steps = parse_workflow(ROOT / '.github/workflows' / workflow)[0]['jobs'][job]['steps']
            selection = next(s['run'] for s in steps if 'scripts/select_ci_iphone.py' in s.get('run', ''))
            # Shell functions record arguments; these tests never invoke native simctl or Python.
            stub = "xcrun() { printf '{}\\n'; }; python3() { printf '%s\\n' \"$*\"; };\n"
            for provider in ('github-hosted', 'self-hosted'):
                for shard in [*pilots, other]:
                    with self.subTest(workflow=workflow, job=job, provider=provider, shard=shard):
                        output = subprocess.check_output(['bash', '-c', stub + selection], text=True,
                            env={**os.environ, 'RUNNER_ENVIRONMENT': provider, 'TEST_SHARD': shard})
                        self.assertEqual('--create-owned' in output, provider == 'github-hosted' or shard in pilots)

    def test_github_simulator_jobs_prepare_before_selection_and_always_check_after_execution(self):
        seen = set()
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            for name, job in parse_workflow(path)[0]["jobs"].items():
                steps = job.get("steps", [])
                prepares = [s for s in steps if s.get("id") == "imported-runtime"]
                if not prepares:
                    continue
                seen.add((path.name, name))
                prepare, = prepares
                verify, = [s for s in steps if s.get("run") == "python3 scripts/prepare_github_ios_runtime.py verify"]
                fixture_build = path.name == "ios-fixtures.yml" and name.startswith("build-")
                producer = fixture_build or (path.name, name) == ("ci.yml", "ios-build")
                native = next(s for s in steps if (
                    "-enumerate-tests" if fixture_build else "bash scripts/run_ios_test_shard.sh") in s.get("run", ""))
                selection = next(s for s in steps if "scripts/select_ci_iphone.py" in s.get("run", ""))
                cleanup = next(s for s in steps if "--cleanup-owned" in s.get("run", ""))
                self.assertEqual(prepare["if"], "runner.environment == 'github-hosted'")
                self.assertEqual(prepare["timeout-minutes"], 20)
                self.assertEqual(verify["if"], "always() && steps.imported-runtime.outcome == 'success'")
                self.assertNotIn("continue-on-error", verify)
                self.assertLess(steps.index(prepare), steps.index(selection))
                self.assertLess(steps.index(native), steps.index(verify))
                self.assertLess(steps.index(verify), steps.index(cleanup))
                if not fixture_build:
                    self.assertEqual(native["timeout-minutes"], 40)
                self.assertEqual(job["timeout-minutes"], 35 if fixture_build else 75)
                if producer:
                    product_upload = next(s for s in steps if s.get("id") == "upload")
                    self.assertLess(steps.index(cleanup), steps.index(product_upload))
                    # Default success() gates artifact acceptance on strict verification/cleanup.
                    self.assertNotIn("if", product_upload)
                    self.assertNotIn("continue-on-error", product_upload)
                    self.assertNotIn("continue-on-error", cleanup)
                    self.assertEqual(cleanup["if"], "always() && runner.environment == 'github-hosted'")
                    self.assertEqual(job["env"]["TEST_SHARD"], "fixture-build" if fixture_build else "models")
                    for step in steps:
                        self.assertEqual(step.get("env", {}).get("TEST_SHARD", job["env"]["TEST_SHARD"]),
                                         job["env"]["TEST_SHARD"])
                upload = next(s for s in steps if s.get("name") == "Upload GitHub runtime evidence")
                self.assertEqual(upload["with"]["path"].splitlines(),
                                 [".build/github-ios-runtime", ".build/test-simulator-ownership.json"])
                self.assertLess(steps.index(cleanup), steps.index(upload))
                self.assertIn("always() && steps.imported-runtime.outcome != 'skipped'", upload["if"])
                self.assertIs(upload["continue-on-error"], True)
                diagnostic = next(s for s in steps if s.get("name") == "Retain GitHub runtime diagnostics")
                self.assertIn("always() && steps.imported-runtime.outcome != 'skipped'", diagnostic["if"])
        self.assertEqual(seen, {("ci.yml", "ios-build"), ("ci.yml", "ios-tests"),
                                ("ios-fixtures.yml", "build-contributor"), ("ios-fixtures.yml", "build-dinner"),
                                ("ios-fixtures.yml", "contributor-tests"), ("ios-fixtures.yml", "dinner-tests")})

    def test_private_records_never_collect_or_upload_raw_runtime_logs(self):
        workflow = parse_workflow(ROOT / ".github/workflows/ios-fixtures.yml")[0]
        for name in ("contributor-tests", "dinner-tests"):
            steps = workflow["jobs"][name]["steps"]
            for step_name in ("Retain GitHub runtime diagnostics", "Upload GitHub runtime evidence"):
                step = next(s for s in steps if s.get("name") == step_name)
                for private in ("RecordsMediaUITests", "SharedRecordsUITests"):
                    self.assertIn("matrix.shard != '" + private + "'", step["if"])
            verify = next(s for s in steps if s.get("name") == "Verify the imported runtime after tests")
            self.assertNotIn("matrix.shard", verify["if"])
            diagnostic = next(s for s in steps if s.get("name") == "Retain GitHub runtime diagnostics")
            self.assertIn('process == "simdiskimaged"', diagnostic["run"])
            self.assertIn('process CONTAINS "CoreSimulatorService"', diagnostic["run"])



if __name__ == '__main__':
    unittest.main()
