import copy
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import unittest
from unittest.mock import patch
from uuid import UUID

import observe_runtime_checker as observer
import test_performance_plan_provenance as provenance_tests


DEVICE = '00000000-0000-4000-8000-000000000001'
IMAGE_UUID = '00000000-0000-4000-8000-000000000002'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
HOSTED_RUNTIME_BUNDLE = observer.RUNTIME_BUNDLE
ENV = {'DEVELOPER_DIR': '/Applications/Xcode_27.1.app/Contents/Developer',
       'CI_IPHONE_RUNTIME': RUNTIME, 'CI_IPHONE_NAME': 'iPhone 17', 'SIMULATOR_ID': DEVICE}


def macho():
    return struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 6, 1, 24, 0, 0) + struct.pack('<II', 0x1B, 24) + UUID(IMAGE_UUID).bytes


class RuntimeCheckerTests(unittest.TestCase):
    def setUp(self):
        # Reuse the existing producer/archive fixture, not a second receipt schema.
        self.proof = provenance_tests.PerformancePlanProvenanceTests()
        self.proof.setUp(); self.addCleanup(self.proof.doCleanups)
        self.root = self.proof.root
        self.bundle = self.root / 'iOS 27.0.simruntime'
        self.library = self.bundle / 'Contents/Resources/RuntimeRoot/usr/lib' / observer.LIBRARY
        self.library.parent.mkdir(parents=True); self.library.write_bytes(macho())
        self.env = patch.dict(os.environ, ENV); self.env.start(); self.addCleanup(self.env.stop)
        roots = patch.object(observer, 'RUNTIME_BUNDLE', re.compile(re.escape(str(self.root)) + r'/iOS ([0-9.]+)\.simruntime'))
        roots.start(); self.addCleanup(roots.stop)
        self.data = {'devices': {RUNTIME: [{'udid': DEVICE, 'isAvailable': True,
            'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}]},
            'runtimes': [{'identifier': RUNTIME, 'isAvailable': True, 'version': '27.0',
                          'buildversion': 'fixtureBuild', 'bundlePath': str(self.bundle)}],
            'devicetypes': [{'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17', 'name': 'iPhone 17'}]}
        self.output = self.root / 'observer.json'

    def observe(self, consumer=False):
        with patch.object(observer, 'inventory', return_value=self.data):
            return observer.run(self.output, self.proof.products if consumer else None,
                                self.root / 'consumer.json' if consumer else None)

    def consumer(self, expected=None):
        self.proof.produce()
        path = self.proof.products / 'performance-plan-producer.json'
        producer = json.loads(path.read_text())
        producer['observations']['generated']['TestingEnvironmentVariables']['libraries'] = {
            'state': 'present', 'entries': [expected or {
                'library': observer.LIBRARY, 'root': 'declared-runtime-library', 'status': 'readable',
                'bytes': len(macho()), 'sha256': hashlib.sha256(macho()).hexdigest()}]}
        path.write_text(json.dumps(producer))
        self.proof.consume()

    def test_capability_without_products_observes_bytes_uuid_not_loaded_state(self):
        before = self.library.read_bytes()
        result = self.observe()
        self.assertEqual(result['status'], 'observed')
        self.assertEqual(result['checker']['uuid'], IMAGE_UUID)
        self.assertEqual(result['checker']['sha256'], hashlib.sha256(before).hexdigest())
        self.assertEqual(result['loadedState'], 'unknown')
        self.assertFalse(result['releaseAcceptance'])
        self.assertNotIn('plan', result)
        self.assertNotIn(str(self.root), json.dumps(result))
        self.assertEqual(self.library.read_bytes(), before)
        self.assertTrue(all(call.args[0] == ['git', 'rev-parse', 'HEAD'] for call in self.proof.git.call_args_list))

    def test_consumer_compares_corresponding_bytes_and_preserves_plan(self):
        self.consumer(); before = self.proof.plan.read_bytes()
        result = self.observe(consumer=True)
        self.assertTrue(result['plan']['selectedRuntimeBytesMatchProducer'])
        self.assertEqual(result['plan']['planSHA256'], hashlib.sha256(before).hexdigest())
        self.assertEqual(self.proof.plan.read_bytes(), before)
        self.assertEqual(result['loadedState'], 'unknown')
        # Changed valid UUID means changed bytes, not an approved substitute.
        changed = bytearray(macho()); changed[-1] ^= 1; self.library.write_bytes(changed)
        result = self.observe(consumer=True)
        self.assertFalse(result['plan']['selectedRuntimeBytesMatchProducer'])
        self.assertEqual(result['status'], 'observed')
        self.assertFalse(result['releaseAcceptance'])

    def test_missing_selected_library_is_explicit_not_load_failure(self):
        self.consumer(); self.library.unlink()
        result = self.observe(consumer=True)
        self.assertEqual(result['checker']['status'], 'missing')
        self.assertIsNone(result['plan']['selectedRuntimeBytesMatchProducer'])
        self.assertEqual(result['loadedState'], 'unknown')

    def test_changed_plan_or_wrong_run_provenance_rejected(self):
        self.consumer(); before = self.proof.plan.read_bytes()
        self.proof.plan.write_bytes(before + b'changed')
        with self.assertRaisesRegex(ValueError, 'plan_changed'): self.observe(consumer=True)
        self.proof.plan.write_bytes(before)
        path = self.root / 'consumer.json'; data = json.loads(path.read_text())
        data['context']['runID'] = '99'; path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'consumer_provenance_identity'): self.observe(consumer=True)
        data['context']['runID'] = '42'; data['comparison']['immutableMatch'] = False
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'consumer_provenance_identity'): self.observe(consumer=True)
        self.assertEqual(json.loads(self.output.read_text())['status'], 'failed')

    def test_wrong_duplicate_unavailable_or_drifted_selected_runtime_rejected(self):
        original = copy.deepcopy(self.data)
        mutations = [lambda d: d['devices'][RUNTIME][0].update(udid=IMAGE_UUID),
                     lambda d: d['devices'].update({'com.apple.CoreSimulator.SimRuntime.iOS-27-1': d['devices'].pop(RUNTIME)}),
                     lambda d: d['devices'][RUNTIME].append(copy.deepcopy(d['devices'][RUNTIME][0])),
                     lambda d: d['devices'][RUNTIME][0].update(isAvailable=False),
                     lambda d: d['runtimes'].append(copy.deepcopy(d['runtimes'][0])),
                     lambda d: d['runtimes'][0].update(version='27.1'),
                     lambda d: d['runtimes'][0].update(isAvailable=False),
                     lambda d: d['devicetypes'][0].update(name='Different device'),
                     lambda d: d['runtimes'][0].update(bundlePath='/private/secret-runtime')]
        for mutation in mutations:
            self.data = copy.deepcopy(original); mutation(self.data)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): self.observe()
            self.assertNotIn('secret-runtime', self.output.read_text())

    def test_symlink_and_oversize_checker_are_not_followed(self):
        self.library.unlink(); self.library.symlink_to(self.root / 'not-a-checker')
        with self.assertRaisesRegex(ValueError, 'checker_redirected'): self.observe()
        self.library.unlink(); self.library.write_bytes(macho())
        with patch.object(observer, 'MAX_LIBRARY', 10), self.assertRaisesRegex(ValueError, 'checker_size_type'):
            self.observe()

    def test_universal_arm64_and_truncated_or_ambiguous_macho(self):
        raw = macho()
        fat = struct.pack('>II5I', 0xCAFEBABE, 1, 0x0100000C, 0, 28, len(raw), 0) + raw
        self.assertEqual(observer.arm64_uuid(fat), IMAGE_UUID)
        fat64 = struct.pack('>IIIIQQII', 0xCAFEBABF, 1, 0x0100000C, 0, 40, len(raw), 0, 0) + raw
        self.assertEqual(observer.arm64_uuid(fat64), IMAGE_UUID)
        duplicate = struct.pack('>II', 0xCAFEBABE, 2) + struct.pack('>5I', 0x0100000C, 0, 48, len(raw), 0) * 2 + raw
        for bad in (b'', raw[:40], fat[:20], duplicate, raw[:16] + struct.pack('<I', 0) + raw[20:]):
            with self.subTest(size=len(bad)), self.assertRaises((ValueError, struct.error)):
                observer.arm64_uuid(bad)

    def test_bounded_inventory_uses_only_readonly_simctl_and_discards_stderr(self):
        def fake(args, **kwargs):
            self.assertEqual(args, ['xcrun', 'simctl', 'list', '-j'])
            self.assertEqual(kwargs['timeout'], 30)
            self.assertEqual(kwargs['stderr'], subprocess.DEVNULL)
            kwargs['stdout'].write(json.dumps(self.data).encode())
        with patch.object(observer.subprocess, 'run', side_effect=fake):
            self.assertEqual(observer.inventory(), self.data)
            with patch.object(observer, 'MAX_INVENTORY', 10), self.assertRaisesRegex(ValueError, 'inventory_size'):
                observer.inventory()
        with patch.object(observer, 'inventory', side_effect=subprocess.TimeoutExpired(['fixed'], 30)):
            with self.assertRaises(subprocess.TimeoutExpired): observer.run(self.output)
        self.assertEqual(json.loads(self.output.read_text())['error'], 'TimeoutExpired')


class RuntimeCheckerWorkflowTests(unittest.TestCase):
    def test_hosted_root_policy_rejects_arbitrary_or_traversing_paths(self):
        path = '/private/var/run/com.apple.security.cryptexd/mnt/runtime-fixture/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime'
        self.assertEqual(HOSTED_RUNTIME_BUNDLE.fullmatch(path)[1], '27.0')
        self.assertIsNotNone(HOSTED_RUNTIME_BUNDLE.fullmatch(path.removeprefix('/private')))
        for bad in (path + '/../../secret', path.replace('/mnt/runtime-fixture/', '/mnt/../'), '/private/secret/iOS 27.0.simruntime'):
            self.assertIsNone(HOSTED_RUNTIME_BUNDLE.fullmatch(bad))

    def test_existing_capability_and_consumer_scopes_retain_observations(self):
        text = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-performance.yml').read_text()
        plan, rest = text.split('  performance-build:', 1)
        build, consumer = rest.split('  performance-tests:', 1)
        self.assertIn('python3 scripts/test_observe_runtime_checker.py', plan)
        capability = build.split('      - name: Observe selected-runtime checker without building', 1)[1].split('      - name:', 1)[0]
        self.assertIn('if: inputs.capture_preflight_only', capability)
        self.assertNotIn('--products', capability)
        self.assertIn('--output .build/capture-preflight/runtime-checker.json', capability)
        self.assertLess(build.index('scripts/boot_ios_simulator.py'), build.index('observe_runtime_checker.py'))
        self.assertLess(build.index('observe_runtime_checker.py'), build.index('Check capture capabilities before compilation'))
        self.assertNotIn('always()', capability)
        self.assertLess(build.index('observe_runtime_checker.py'), build.index('Retain capture capability stages'))
        before, rest = consumer.split('      - name: Observe selected-runtime checker identity', 1)
        step, after = rest.split('      - name:', 1)
        self.assertIn('plan-provenance-after-setup.json', before)
        self.assertIn('--plan-provenance .build/performance/plan-provenance-after-setup.json', step)
        self.assertIn('--products .build/DerivedData/Build/Products', step)
        self.assertIn('--output .build/performance/runtime-checker.json', step)
        self.assertTrue(after.startswith(' Run one Release performance case'))
        self.assertNotIn('continue-on-error', step)
        self.assertIn("path: ${{ inputs.observe_app_scroll_signposts && "
                      "(steps.observation_archive.outputs.artifact_path || '.build/app-observation-portable/report/') "
                      "|| '.build/performance/' }}", after)


if __name__ == '__main__':
    unittest.main()
