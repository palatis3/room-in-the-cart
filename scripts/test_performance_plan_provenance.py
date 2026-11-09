import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

import performance_plan_provenance as proof

SHA = 'a' * 40


class PerformancePlanProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.products = self.root / 'producer/Products'; self.products.mkdir(parents=True)
        self.env = {'GITHUB_SHA': SHA, 'GITHUB_REPOSITORY': 'test/repository', 'GITHUB_RUN_ID': '42',
                    'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_JOB': 'performance-build'}
        env = patch.dict(os.environ, self.env, clear=True); env.start(); self.addCleanup(env.stop)
        location = patch.object(proof, '__file__', str(self.root / 'scripts/performance_plan_provenance.py'))
        location.start(); self.addCleanup(location.stop)
        git = patch.object(proof.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, SHA + '\n', ''))
        self.git = git.start(); self.addCleanup(git.stop)
        for name in proof.SOURCES:
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'fixed-source\n')
        for bundle, executable in proof.BUNDLES.values():
            folder = self.products / 'Release-iphonesimulator' / bundle; folder.mkdir(parents=True, exist_ok=True)
            (folder / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': executable}))
            path = folder / executable; path.write_bytes(b'fixture-executable-' + executable.encode()); path.chmod(0o755)
        self.target = {'TestHostPath': '__TESTROOT__/Release-iphonesimulator/' + proof.BUNDLES['runner'][0],
                       'UITargetAppPath': '__TESTROOT__/Release-iphonesimulator/' + proof.BUNDLES['app'][0],
                       'TestBundlePath': '__TESTHOST__/PlugIns/RoomInTheCartUITests.xctest',
                       'IsUITestBundle': True, 'IsXCTRunnerHostedTestBundle': True,
                       'OnlyTestIdentifiers': ['ReleasePerformanceUITests'],
                       'DependentProductPaths': ['__TESTROOT__/Release-iphonesimulator/' + b for b, _ in proof.BUNDLES.values()],
                       'EnvironmentVariables': {'OS_ACTIVITY_DT_MODE': 'YES'},
                       'TestingEnvironmentVariables': {}, 'UITargetAppEnvironmentVariables': {}}
        self.plan = self.products / 'RoomInTheCart-Performance_iphonesimulator27.1-arm64-x86_64.xctestrun'
        self.write_plan()
        self.output = self.root / 'producer.json'

    def write_plan(self):
        self.plan.write_bytes(plistlib.dumps({proof.TARGET: self.target,
            '__xctestrun_metadata__': {'FormatVersion': 1, 'ContainerInfo': {'SchemeName': 'RoomInTheCart-Performance'}}}))

    def produce(self):
        proof.run('producer', self.products, self.output)
        result = json.loads(self.output.read_text())
        self.assertEqual(result['status'], 'passed')
        shutil.copyfile(self.output, self.products / 'performance-plan-producer.json')
        return result

    def restore(self):
        # Exercise the workflow's actual Products archive layout and executable modes.
        archive = self.root / 'products.tar.gz'
        with tarfile.open(archive, 'w:gz') as output:
            output.add(self.products, arcname='Products')
        consumer = self.root / 'consumer'; consumer.mkdir()
        with tarfile.open(archive) as source:
            # This archive was generated from our own fixed temporary fixture.
            self.assertTrue(all((m.isfile() or m.isdir()) and m.name.startswith('Products')
                                and '..' not in Path(m.name).parts for m in source.getmembers()))
            source.extractall(consumer)
        return consumer / 'Products'

    def consume(self, products=None):
        os.environ['GITHUB_JOB'] = 'performance-tests'
        products = products or self.products
        path = self.root / 'consumer.json'
        proof.run('consumer', products, path, products / 'performance-plan-producer.json')
        return json.loads(path.read_text())

    def test_archive_restore_verifies_plan_source_and_all_five_executables(self):
        original = self.produce(); restored = self.restore()
        result = self.consume(restored)
        self.assertEqual(result['immutable'], original['immutable'])
        self.assertEqual(set(result['immutable']['products']), {'app', 'runner', 'tests', 'share', 'widget'})
        self.assertTrue(result['comparison']['immutableMatch'])
        self.assertEqual(result['comparison']['producerReceiptSHA256'], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertNotIn(str(self.root), json.dumps(result))
        self.assertLess(len(json.dumps(result)), proof.MAX_METADATA)
        self.assertTrue(all(c.args[0] == ['git', 'rev-parse', 'HEAD'] for c in self.git.call_args_list))

    def test_changed_executable_and_missing_extension_fail_before_test_admission(self):
        self.produce()
        for role in ('app', 'runner', 'tests', 'share', 'widget'):
            bundle, executable = proof.BUNDLES[role]
            path = self.products / 'Release-iphonesimulator' / bundle / executable
            original = path.read_bytes(); path.write_bytes(original + b'changed')
            with self.assertRaisesRegex(proof.ProofError, 'mismatch'): self.consume()
            path.write_bytes(original)
        bundle, executable = proof.BUNDLES['share']
        (self.products / 'Release-iphonesimulator' / bundle / executable).unlink()
        with self.assertRaises(proof.ProofError): self.consume()
        self.assertEqual(json.loads((self.root / 'consumer.json').read_text())['status'], 'failed')

    def test_plan_corruption_selection_or_source_change_fails(self):
        self.produce(); old = self.plan.read_bytes()
        self.target['OnlyTestIdentifiers'] = ['OtherTests']; self.write_plan()
        with self.assertRaises(proof.ProofError): self.consume()
        self.plan.write_bytes(old + b'not-a-plist')
        with self.assertRaises(ValueError): self.consume()
        self.plan.write_bytes(old)
        (self.root / proof.SOURCES[0]).write_bytes(b'different-source')
        with self.assertRaisesRegex(proof.ProofError, 'mismatch'): self.consume()

    def test_plan_ambiguity_debug_or_escaping_layout_and_symlink_product_fail(self):
        extra = self.plan.with_name('RoomInTheCart-Performance_iphonesimulator27.1-arm64.xctestrun')
        extra.write_bytes(self.plan.read_bytes())
        with self.assertRaisesRegex(proof.ProofError, 'plan_count'): self.produce()
        extra.unlink()
        for path in ('__TESTROOT__/Debug-iphonesimulator/RoomInTheCart.app', '/private/secret/RoomInTheCart.app', '__TESTROOT__/../RoomInTheCart.app'):
            self.target['UITargetAppPath'] = path; self.write_plan()
            with self.assertRaisesRegex(proof.ProofError, 'layout'): self.produce()
        self.target['UITargetAppPath'] = '__TESTROOT__/Release-iphonesimulator/RoomInTheCart.app'; self.write_plan()
        binary = self.products / 'Release-iphonesimulator/RoomInTheCart.app/RoomInTheCart'
        binary.unlink(); binary.symlink_to(self.root / proof.SOURCES[0])
        with self.assertRaises(proof.ProofError): self.produce()

    def test_unknown_environment_values_names_and_paths_never_leak(self):
        secret = 'private-token-should-never-be-written'
        self.target['EnvironmentVariables'].update({'PRIVATE_PASSWORD': secret, 'OS_ACTIVITY_MODE': secret,
            'DYLD_INSERT_LIBRARIES': '/private/' + secret + '/libUnknown.dylib'})
        self.write_plan(); os.environ['PRIVATE_TOKEN'] = secret; os.environ['OS_ACTIVITY_MODE'] = secret
        producer = self.produce(); result = self.consume()
        for value in (producer, result):
            rendered = json.dumps(value)
            self.assertNotIn(secret, rendered); self.assertNotIn('PRIVATE_PASSWORD', rendered)
            self.assertNotIn('/private/', rendered)
        self.assertEqual(producer['observations']['invoking']['settings']['OS_ACTIVITY_MODE'], 'unrecognized-present')

    def test_invoking_environment_changes_are_observations_not_corruption(self):
        self.produce(); os.environ['OS_ACTIVITY_DT_MODE'] = 'NO'
        result = self.consume()
        self.assertEqual(result['status'], 'passed')
        self.assertFalse(result['comparison']['invokingSettingsMatch'])
        self.assertEqual(result['observations']['invoking']['settings']['OS_ACTIVITY_DT_MODE'], 'value:NO')

    def test_runtime_library_availability_difference_is_not_a_loaded_library_claim(self):
        self.produce()
        producer_path = self.products / 'performance-plan-producer.json'
        producer = json.loads(producer_path.read_text())
        # Availability is time/host-dependent, whereas plan bytes remain identical.
        producer['observations']['invoking']['libraries'] = {'state': 'present', 'entries': [
            {'library': 'libMainThreadChecker.dylib', 'root': 'declared-runtime-library', 'status': 'missing'}]}
        producer_path.write_text(json.dumps(producer))
        result = self.consume()
        self.assertFalse(result['comparison']['libraryObservationsMatch'])
        self.assertEqual(result['status'], 'passed')
        self.assertIn('loaded libraries unknown', result['scope'])

    def test_referenced_product_library_is_mandatory_and_hashed(self):
        self.target['TestingEnvironmentVariables']['DYLD_INSERT_LIBRARIES'] = '__TESTHOST__/Frameworks/libXCTestBundleInject.dylib'
        self.write_plan()
        library = self.products / 'Release-iphonesimulator/RoomInTheCartUITests-Runner.app/Frameworks/libXCTestBundleInject.dylib'
        library.parent.mkdir(); library.write_bytes(b'fixed-library')
        producer = self.produce()
        self.assertEqual(len(producer['immutable']['productLibraries']), 1)
        library.write_bytes(b'changed-library')
        with self.assertRaisesRegex(proof.ProofError, 'mismatch'): self.consume()
        library.unlink()
        with self.assertRaisesRegex(proof.ProofError, 'referenced_product_library'): self.consume()

    def test_lineage_accepts_earlier_attempt_only_same_run_source_repository(self):
        original = self.produce(); path = self.products / 'performance-plan-producer.json'
        os.environ['GITHUB_RUN_ATTEMPT'] = '2'
        self.assertEqual(self.consume()['comparison']['producerAttempt'], '1')
        for key, value in (('attempt', '3'), ('runID', '43'), ('sourceSHA', 'b' * 40),
                           ('repository', 'other/repo'), ('job', 'performance-tests')):
            bad = copy.deepcopy(original); bad['context'][key] = value; path.write_text(json.dumps(bad))
            with self.assertRaisesRegex(proof.ProofError, 'lineage'): self.consume()

    def test_malformed_failed_or_missing_producer_receipt_fails_closed(self):
        original = self.produce(); path = self.products / 'performance-plan-producer.json'
        for content in ('[]', '{broken', json.dumps({**original, 'status': 'failed'}),
                        json.dumps({**original, 'unexpected': 'private-data'})):
            path.write_text(content)
            with self.assertRaises((proof.ProofError, ValueError, TypeError)): self.consume()
            self.assertNotIn('private-data', (self.root / 'consumer.json').read_text())
        path.unlink()
        with self.assertRaises(proof.ProofError): self.consume()

    def test_logging_hook_and_eight_antipattern_flags_are_explicit_in_all_scopes(self):
        self.target['EnvironmentVariables']['OS_LOG_DT_HOOK_MODE'] = 'YES'
        values = [True, False, 1, 0, 'YES', 'NO', 'private-value', []]
        for key, value in zip(proof.ANTIPATTERN_FLAGS, values):
            self.target[key] = value
            for scope in proof.SCOPES:
                self.target[scope][key] = value
        self.write_plan(); result = self.produce()
        expected = dict(zip(proof.ANTIPATTERN_FLAGS, ['true', 'false', 'true', 'false', 'true', 'false',
                                                     'unrecognized-present', 'unrecognized-present']))
        for scope in proof.SCOPES:
            observed = result['observations']['generated'][scope]['settings']
            self.assertEqual({k: observed[k] for k in expected}, expected)
        self.assertEqual({k: result['observations']['options'][k] for k in expected}, expected)
        self.assertEqual(result['observations']['generated']['EnvironmentVariables']['settings']['OS_LOG_DT_HOOK_MODE'], 'value:YES')
        self.assertTrue(all(result['observations']['invoking']['settings'][k] == 'absent' for k in expected))
        self.assertNotIn('private-value', json.dumps(result))

    def test_duplicate_plist_and_json_members_are_not_silently_normalized(self):
        original = self.produce(); path = self.products / 'performance-plan-producer.json'
        # A duplicate equal-valued field is malformed too, not a valid receipt.
        path.write_text(json.dumps(original).replace('"schema": 1', '"schema": 1, "schema": 1', 1))
        with self.assertRaisesRegex(proof.ProofError, 'duplicate_metadata_key'): self.consume()
        self.plan.write_bytes(self.plan.read_bytes().replace(b'<key>FormatVersion</key>',
            b'<key>FormatVersion</key><integer>1</integer><key>FormatVersion</key>', 1))
        with self.assertRaisesRegex(proof.ProofError, 'duplicate_metadata_key'): self.consume()

    def test_context_requires_actual_checkout_sha_and_expected_job(self):
        os.environ['GITHUB_SHA'] = 'b' * 40
        with self.assertRaisesRegex(proof.ProofError, 'source_identity'): self.produce()
        os.environ['GITHUB_SHA'] = SHA; os.environ['GITHUB_JOB'] = 'other'
        with self.assertRaisesRegex(proof.ProofError, 'job_identity'): self.produce()

    def test_size_and_deadline_limits_do_not_produce_pass_receipts(self):
        with patch.object(proof, 'MAX_EXECUTABLE', 1):
            with self.assertRaises(proof.ProofError): self.produce()
        with patch.object(proof, 'SECONDS', -1):
            with self.assertRaisesRegex(proof.ProofError, 'deadline'): self.produce()
        self.assertEqual(json.loads(self.output.read_text())['status'], 'failed')


class PerformanceProvenanceWorkflowTests(unittest.TestCase):
    def test_linux_validation_producer_packaging_and_consumer_admission_order(self):
        text = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-performance.yml').read_text()
        plan = text[text.index('  performance-plan:'):text.index('  performance-build:')]
        build = text[text.index('  performance-build:'):text.index('  performance-tests:')]
        consumer = text[text.index('  performance-tests:'):]
        self.assertIn('python3 scripts/test_performance_plan_provenance.py', plan)
        packaging = build[build.index('      - name: Verify and package Release test products'):build.index('      - uses: actions/upload-artifact', build.index('      - name: Verify and package'))]
        self.assertIn('if: ${{ !inputs.capture_preflight_only }}', packaging)
        self.assertLess(packaging.index('check_built_app.py'), packaging.index('performance_plan_provenance.py producer'))
        self.assertLess(packaging.index('performance_plan_provenance.py producer'), packaging.index('cp .build/performance-plan-producer.json'))
        self.assertLess(packaging.index('cp .build/performance-plan-producer.json'), packaging.index('tar -czf'))
        retained = build[build.index('      - name: Retain Release build log'):]
        self.assertIn('if: always()', retained); self.assertIn('.build/performance-plan-producer.json', retained)
        self.assertLess(consumer.index('tar -xzf'), consumer.index('performance_plan_provenance.py consumer'))
        self.assertLess(consumer.index('performance_plan_provenance.py consumer'), consumer.index('      - name: Select an iPhone simulator'))
        gate = consumer[consumer.index('      - name: Verify restored performance plan'):consumer.index('      - name: Select an iPhone simulator')]
        self.assertIn('timeout-minutes: 2', gate); self.assertNotIn('continue-on-error', gate); self.assertNotIn('||', gate)
        self.assertIn('--output .build/performance/plan-provenance.json', gate)
        self.assertIn('--producer .build/DerivedData/Build/Products/performance-plan-producer.json', gate)
        upload = consumer[consumer.index('      - name: Retain Release performance evidence'):]
        self.assertIn('if: always()', upload); self.assertIn('path: .build/performance/', upload)


if __name__ == '__main__':
    unittest.main()
