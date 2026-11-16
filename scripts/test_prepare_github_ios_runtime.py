"""Exercise runtime replacement and workflow ordering without native tools."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import prepare_github_ios_runtime as subject
from check_ci_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]
OLD = "11111111-1111-4111-8111-111111111111"
TWIN = "22222222-2222-4222-8222-222222222222"
NEW = "33333333-3333-4333-8333-333333333333"
OTHER = "44444444-4444-4444-8444-444444444444"
ASSET = "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/test.asset/AssetData"
IMAGE = "/Library/Developer/CoreSimulator/Cryptex/Images/test.dmg"
BUNDLE = "/private/var/run/com.apple.security.cryptexd/mnt/test/iOS.simruntime"


def registration(identifier, **changes):
    return {
        "identifier": identifier, "runtimeIdentifier": subject.runtime,
        "build": subject.build, "state": "Ready", "deletable": True,
        "path": ASSET, "runtimeBundlePath": BUNDLE, "mountPath": "/test-mount",
        "supportedArchitectures": ["arm64"], **changes,
    }


class RuntimeReplacementTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        previous = Path.cwd()
        os.chdir(temporary.name)
        self.addCleanup(os.chdir, previous)
        subject.evidence.mkdir(parents=True)
        self.other = registration(OTHER, runtimeIdentifier="watchOS", build="24R362",
                                  path="/System/Library/AssetsV2/watchOS/other.asset/AssetData")
        self.rows = {OLD: registration(OLD), OTHER: self.other}
        self.imported = registration(NEW, path=IMAGE)
        self.commands = []
        self.export_status = 0
        self.export_present = True
        self.import_status = 0
        self.device_state = "Shutdown"
        self.shared_delete = False
        self.missing_bundle = False
        self.change_before_delete = False
        self.runtime_reads = 0
        self.delete_callback = None
        self.scan_callback = None
        self.read_callback = None
        self.elapsed = 0

        def sleep(seconds):
            self.elapsed += seconds

        original_dir, original_exists = Path.is_dir, Path.exists

        def is_dir(path):
            return not self.missing_bundle if str(path) == BUNDLE else original_dir(path)

        def exists(path):
            return True if str(path) == IMAGE else original_exists(path)

        for patcher in [
            patch.object(subject.time, "monotonic", side_effect=lambda: self.elapsed),
            patch.object(subject.time, "sleep", side_effect=sleep),
            patch.object(subject.subprocess, "run", side_effect=self.run_command),
            patch.object(subject.subprocess, "check_output", side_effect=self.read_command),
            patch.object(Path, "is_dir", is_dir),
            patch.object(Path, "exists", exists),
        ]:
            patcher.start()
            self.addCleanup(patcher.stop)

    def read_command(self, command, **kwargs):
        self.commands.append(command)
        if command == ["xcrun", "simctl", "list", "devices", "-j"]:
            return json.dumps({"devices": {subject.runtime: [{"state": self.device_state}]}})
        self.assertEqual(command, ["xcrun", "simctl", "runtime", "list", "-j"])
        self.runtime_reads += 1
        if self.read_callback:
            self.read_callback()
        if self.change_before_delete and self.runtime_reads == 3:
            self.rows[OLD]["build"] = "wrong"
        return json.dumps(self.rows)

    def run_command(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == "xcodebuild":
            self.assertEqual(command[:5], ["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", "24A434"])
            self.assertEqual(command[-2:], ["-architectureVariant", "arm64"])
            if self.export_present:
                bundle = Path(command[6]) / "iOS.exportedBundle"
                bundle.mkdir()
                (bundle / "runtime.dmg").write_bytes(b"synthetic runtime payload")
            return subprocess.CompletedProcess(command, self.export_status)
        if command == ["xcrun", "simctl", "runtime", "scan-and-mount"]:
            if self.scan_callback:
                self.scan_callback()
            return subprocess.CompletedProcess(command, 0)
        if command[:4] == ["xcrun", "simctl", "runtime", "delete"]:
            if self.delete_callback:
                return self.delete_callback(command, kwargs)
            del self.rows[command[4]]
            if self.shared_delete:
                self.rows.pop(TWIN, None)
        else:
            self.assertEqual(command[:6], [
                "sudo", "-n", "/usr/bin/env",
                "DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer",
                "/usr/bin/xcodebuild", "-importPlatform"])
            if self.import_status:
                raise subprocess.CalledProcessError(self.import_status, command)
            self.rows[NEW] = copy.deepcopy(self.imported)
        return subprocess.CompletedProcess(command, 0)

    def deletions(self):
        return [c for c in self.commands if c[:4] == ["xcrun", "simctl", "runtime", "delete"]]

    def test_success_preserves_other_platform_and_round_trips_target_for_verification(self):
        subject.prepare()
        subject.verify()
        self.assertEqual(self.deletions(), [["xcrun", "simctl", "runtime", "delete", OLD]])
        self.assertEqual(self.rows[OTHER], self.other)
        self.assertEqual(json.loads((subject.evidence / "target.json").read_text()), self.imported)

    def test_export_status_70_requires_real_bundle(self):
        self.export_status = 70
        subject.prepare()
        subject.verify()

    def test_export_failure_prevents_all_deletions(self):
        self.export_status = 1
        with self.assertRaises(AssertionError):
            subject.prepare()
        self.assertEqual(self.deletions(), [])

    def test_missing_export_prevents_all_deletions_even_with_status_70(self):
        self.export_status = 70
        self.export_present = False
        with self.assertRaises(AssertionError):
            subject.prepare()
        self.assertEqual(self.deletions(), [])

    def test_entire_removal_set_is_validated_before_mutation(self):
        self.rows[TWIN] = registration(TWIN, path="/unexpected/image")
        with self.assertRaises(AssertionError):
            subject.prepare()
        self.assertEqual(self.deletions(), [])

    def test_wrong_target_is_rejected_before_export(self):
        self.rows[OLD]["build"] = "23C54"
        with self.assertRaises(AssertionError):
            subject.prepare()
        self.assertFalse(any(c[0] == "xcodebuild" for c in self.commands))

    def test_booted_target_prevents_deletion(self):
        self.device_state = "Booted"
        with self.assertRaises(AssertionError):
            subject.prepare()
        self.assertEqual(self.deletions(), [])

    def test_shared_asset_retirement_does_not_delete_stale_uuid(self):
        self.rows[TWIN] = registration(TWIN, state="Unusable")
        self.shared_delete = True
        subject.prepare()
        self.assertEqual(len(self.deletions()), 1)

    def test_registration_drift_prevents_deletion(self):
        self.change_before_delete = True
        with self.assertRaises(AssertionError):
            subject.prepare()
        self.assertEqual(self.deletions(), [])

    def test_import_error_propagates_without_publishing_baseline(self):
        self.import_status = 70
        with self.assertRaises(subprocess.CalledProcessError):
            subject.prepare()
        self.assertFalse((subject.evidence / "target.json").exists())
        self.assertTrue((subject.evidence / "after-removal.json").exists())

    def test_mobileasset_import_result_is_rejected(self):
        self.imported["path"] = ASSET
        with self.assertRaises(AssertionError):
            subject.prepare()
        self.assertFalse((subject.evidence / "target.json").exists())

    def test_missing_imported_bundle_is_rejected(self):
        self.missing_bundle = True
        with self.assertRaises(AssertionError):
            subject.prepare()

    def test_postcheck_rejects_identity_mount_or_bundle_loss_and_records_state(self):
        subject.prepare()
        for changes in [{"identifier": TWIN}, {"mountPath": "/moved"}, {"state": "Unusable"}]:
            with self.subTest(changes=changes):
                self.rows[NEW] = {**self.imported, **changes}
                with self.assertRaises(AssertionError):
                    subject.verify()
        self.rows[NEW] = self.imported
        self.missing_bundle = True
        with self.assertRaises(AssertionError):
            subject.verify()
        self.assertTrue((subject.evidence / "after-tests.json").is_file())

    def test_cli_guard_rejects_local_bitrise_and_other_runtime_before_native_calls(self):
        env = {"RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_ACTIONS": "true",
               "CI_IPHONE_RUNTIME": subject.runtime,
               "DEVELOPER_DIR": "/Applications/Xcode_27.1.app/Contents/Developer"}
        for changes in [{"RUNNER_ENVIRONMENT": "self-hosted"}, {"GITHUB_ACTIONS": ""},
                        {"CI_IPHONE_RUNTIME": "com.apple.CoreSimulator.SimRuntime.iOS-17-0"},
                        {"CI_IPHONE_RUNTIME": "com.apple.CoreSimulator.SimRuntime.iOS-26-2"}]:
            with self.subTest(changes=changes), patch.dict(os.environ, {**env, **changes}, clear=True), \
                 patch.object(sys, "argv", ["prepare_github_ios_runtime.py", "prepare"]), \
                 patch.object(subject.platform, "system", return_value="Darwin"), \
                 patch.object(subject.platform, "machine", return_value="arm64"), \
                 self.assertRaises(AssertionError):
                subject.main()
        self.assertEqual(self.commands, [])

    def test_already_deleting_shared_twin_is_observed_without_second_delete(self):
        self.rows[TWIN] = registration(TWIN, state="Unusable")

        def delete(command, kwargs):
            self.assertEqual(command[-1], OLD)
            self.rows.pop(OLD)
            self.rows[TWIN]["state"] = "Deleting"
            return subprocess.CompletedProcess(command, 0)

        def read():
            if self.elapsed >= 180:
                self.rows.pop(TWIN, None)

        self.delete_callback, self.read_callback = delete, read
        subject.prepare()
        self.assertEqual(len(self.deletions()), 1)
        self.assertEqual(self.elapsed, 180)
        subject.verify()

    def test_stuck_deleting_twin_fails_at_210_seconds_without_import_or_repeat_delete(self):
        self.rows[OLD]["state"] = "Deleting"
        # The initial readiness guard still requires a Ready sibling.
        self.rows[TWIN] = registration(TWIN)
        with self.assertRaisesRegex(AssertionError, "210 seconds"):
            subject.prepare()
        self.assertEqual(self.elapsed, 210)
        self.assertEqual(self.deletions(), [])
        self.assertFalse((subject.evidence / "target.json").exists())

    def test_exact_code24_race_waits_for_disappearance(self):
        def delete(command, kwargs):
            self.rows[OLD]["state"] = "Deleting"
            kwargs["stdout"].write(
                "An error was encountered processing the command "
                "(domain=com.apple.CoreSimulator.simdiskimaged.SimDiskImageError, code=24):\n"
                "Attempting to delete image: " + OLD +
                " (Please retry in 178s, if the image is not removed)\n")
            return subprocess.CompletedProcess(command, 24)

        def read():
            if self.elapsed >= 180:
                self.rows.pop(OLD, None)

        self.delete_callback, self.read_callback = delete, read
        subject.prepare()
        self.assertEqual(len(self.deletions()), 1)
        self.assertEqual(self.elapsed, 180)

    def test_unqualified_delete_error_is_fatal(self):
        def delete(command, kwargs):
            kwargs["stdout"].write("Unrelated deletion failure, code=24")
            return subprocess.CompletedProcess(command, 24)
        self.delete_callback = delete
        with self.assertRaises(subprocess.CalledProcessError):
            subject.prepare()
        self.assertEqual(self.elapsed, 0)
        self.assertFalse(any(c[-1] == "scan-and-mount" for c in self.commands))

    def configure_purge_recovery(self, *, wrong_identity=False, pending_forever=False,
                                 retry_error=False, late_pending=False):
        count = [0]

        def delete(command, kwargs):
            identifier = command[-1]
            self.rows.pop(identifier)
            if identifier == OLD or retry_error:
                kwargs["stdout"].write(
                    "An error was encountered processing the command "
                    "(domain=com.apple.CoreSimulator.simdiskimaged.SimDiskImageError, code=30):\n"
                    "Removed the runtime, but did not reclaim its MobileAsset: " + ASSET + "/\n"
                    "Run 'xcrun simctl runtime scan-and-mount' to re-register the runtime, then delete it again.\n")
                return subprocess.CompletedProcess(command, 30)
            return subprocess.CompletedProcess(command, 0)

        def scan():
            count[0] += 1
            if count[0] == 1:
                self.rows[TWIN] = registration(
                    TWIN, state="Copying", runtimeIdentifier=None, build=None,
                    path=ASSET + "/runtime.dmg", parentMountPath=ASSET)

        def read():
            if count[0] == 1 and TWIN in self.rows and self.elapsed >= 5 and not pending_forever:
                self.rows[TWIN].update(runtimeIdentifier=subject.runtime,
                                       build="wrong" if wrong_identity else subject.build, state="Ready")
            if count[0] == 2 and late_pending and self.elapsed >= 10:
                self.rows[TWIN] = registration(TWIN, state="Copying", runtimeIdentifier=None,
                                               build=None, path=ASSET + "/runtime.dmg", parentMountPath=ASSET)

        self.delete_callback, self.scan_callback, self.read_callback = delete, scan, read
        return count

    def test_code30_scans_then_removes_only_identified_original_payload_once(self):
        count = self.configure_purge_recovery()
        subject.prepare()
        subject.verify()
        self.assertEqual(count[0], 2)  # One recovery scan and its removal confirmation.
        self.assertEqual([c[-1] for c in self.deletions()], [OLD, TWIN])
        self.assertEqual(self.rows[OTHER], self.other)
        self.assertGreaterEqual(self.elapsed, 50)

    def test_code30_scan_wrong_build_prevents_retry_deletion(self):
        self.configure_purge_recovery(wrong_identity=True)
        with self.assertRaises(AssertionError):
            subject.prepare()
        self.assertEqual([c[-1] for c in self.deletions()], [OLD])
        self.assertFalse((subject.evidence / "target.json").exists())

    def test_code30_pending_original_payload_cannot_be_ignored(self):
        self.configure_purge_recovery(pending_forever=True)
        with self.assertRaisesRegex(AssertionError, "did not settle"):
            subject.prepare()
        self.assertEqual(self.elapsed, 120)
        self.assertEqual([c[-1] for c in self.deletions()], [OLD])

    def test_code30_second_delete_error_is_fatal_without_another_recovery(self):
        count = self.configure_purge_recovery(retry_error=True)
        with self.assertRaises(subprocess.CalledProcessError):
            subject.prepare()
        self.assertEqual(count[0], 1)
        self.assertEqual([c[-1] for c in self.deletions()], [OLD, TWIN])

    def test_code30_late_pending_child_blocks_import(self):
        self.configure_purge_recovery(late_pending=True)
        with self.assertRaisesRegex(AssertionError, "reappeared"):
            subject.prepare()
        self.assertFalse((subject.evidence / "target.json").exists())

    def test_code30_wrong_asset_message_cannot_authorize_scan(self):
        def delete(command, kwargs):
            self.rows.pop(command[-1])
            kwargs["stdout"].write(
                "(domain=com.apple.CoreSimulator.simdiskimaged.SimDiskImageError, code=30):\n"
                "Removed the runtime, but did not reclaim its MobileAsset: /another/asset/\n"
                "Run 'xcrun simctl runtime scan-and-mount' to re-register the runtime, then delete it again.\n")
            return subprocess.CompletedProcess(command, 30)
        self.delete_callback = delete
        with self.assertRaises(subprocess.CalledProcessError):
            subject.prepare()
        self.assertFalse(any(c[-1] == "scan-and-mount" for c in self.commands))

    def test_code30_unexpected_child_path_prevents_retry_deletion(self):
        self.configure_purge_recovery()
        original_scan = self.scan_callback

        def scan():
            original_scan()
            self.rows[TWIN]["path"] = ASSET + "/unexpected.dmg"

        self.scan_callback = scan
        with self.assertRaises(AssertionError):
            subject.prepare()
        self.assertEqual([c[-1] for c in self.deletions()], [OLD])

    def test_code30_successful_retry_with_surviving_payload_blocks_import(self):
        self.configure_purge_recovery()
        original_exists = Path.exists

        def exists(path):
            return True if str(path) == ASSET + "/runtime.dmg" else original_exists(path)

        with patch.object(Path, "exists", exists), self.assertRaisesRegex(AssertionError, "payload remains"):
            subject.prepare()
        self.assertFalse((subject.evidence / "target.json").exists())

    def test_successful_delete_waits_for_its_own_deleting_registration(self):
        def delete(command, kwargs):
            self.rows[OLD]["state"] = "Deleting"
            return subprocess.CompletedProcess(command, 0)

        def read():
            if self.elapsed >= 5:
                self.rows.pop(OLD, None)

        self.delete_callback, self.read_callback = delete, read
        subject.prepare()
        self.assertEqual(len(self.deletions()), 1)
        self.assertEqual(self.elapsed, 5)


class RuntimeWorkflowTests(unittest.TestCase):
    def test_only_github_ui_consumers_prepare_before_selection_and_always_check_after_tests(self):
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
                native = next(s for s in steps if "bash scripts/run_ios_test_shard.sh" in s.get("run", ""))
                selection = next(s for s in steps if "scripts/select_ci_iphone.py" in s.get("run", ""))
                cleanup = next(s for s in steps if "--cleanup-owned" in s.get("run", ""))
                self.assertEqual(prepare["if"], "runner.environment == 'github-hosted'")
                self.assertEqual(prepare["timeout-minutes"], 20)
                self.assertEqual(verify["if"], "always() && steps.imported-runtime.outcome == 'success'")
                self.assertNotIn("continue-on-error", verify)
                self.assertLess(steps.index(prepare), steps.index(selection))
                self.assertLess(steps.index(native), steps.index(verify))
                self.assertLess(steps.index(verify), steps.index(cleanup))
                self.assertEqual(native["timeout-minutes"], 40)
                self.assertEqual(job["timeout-minutes"], 75)
                upload = next(s for s in steps if s.get("name") == "Upload GitHub runtime evidence")
                self.assertEqual(upload["with"]["path"].splitlines(),
                                 [".build/github-ios-runtime", ".build/test-simulator-ownership.json"])
                self.assertLess(steps.index(cleanup), steps.index(upload))
                self.assertIn("always() && steps.imported-runtime.outcome != 'skipped'", upload["if"])
                self.assertIs(upload["continue-on-error"], True)
        self.assertEqual(seen, {("ci.yml", "ios-tests"), ("ios-fixtures.yml", "contributor-tests"),
                                ("ios-fixtures.yml", "dinner-tests")})

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
            self.assertNotIn("CoreSimulatorService", diagnostic["run"])


if __name__ == "__main__":
    unittest.main()
