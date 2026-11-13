"""Run the workflow build commands against a stub compiler."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_ci_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = Path(".build/ios-build-evidence")
DEVELOPER_DIR = "/Applications/Xcode_27.1.app/Contents/Developer"
SOURCE_SHA = "0123456789abcdef0123456789abcdef01234567"
SIMULATOR_ID = "8C9F4118-331E-4250-B1FC-194972BA6726"
CASES = (
    ("ci.yml", "ios-build", "REQUESTED_IOS_SCOPE", "full", None),
    ("ci.yml", "ios-build", "REQUESTED_IOS_SCOPE", "dinner", None),
    ("ios-fixtures.yml", "build-contributor", "FIXTURE_PROFILE", "contributor",
     "DEBUG CONTRIBUTOR_CAPTURE_UI_FIXTURE STOCK_REVIEW_UI_FIXTURE AWAY_CARRYOVER_UI_FIXTURE"),
    ("ios-fixtures.yml", "build-dinner", "FIXTURE_PROFILE", "dinner", "DEBUG DINNER_DECISION_UI_FIXTURE"),
)


class IOSBuildEvidenceTests(unittest.TestCase):
    def steps(self, workflow, job):
        return parse_workflow(ROOT / ".github/workflows" / workflow)[0]["jobs"][job]["steps"]

    def run_build(self, steps, profile_variable, profile, exit_code, version_exit_code=0, boot_exit_code=0):
        build = next(step for step in steps if step.get("id") == "build")
        self.assertEqual(build["shell"], "bash")
        self.assertFalse(build.get("continue-on-error"))
        with tempfile.TemporaryDirectory() as folder:
            checkout = Path(folder)
            (checkout / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
            # Use the current interpreter, bypassing the macOS Xcode-dependent /usr/bin shim.
            (checkout / "python3").symlink_to(sys.executable)
            # Gate each stub on the other's start. A serialized build fails promptly.
            rendezvous = """#!/bin/bash
touch "$1"
for (( attempt = 0; attempt < 50; attempt++ )); do
    [ -f "$2" ] && exit 0
    sleep 0.1
done
exit 72
"""
            tools = {"rendezvous": rendezvous, "xcrun": """#!/bin/sh
[ "$*" = "simctl bootstatus $SIMULATOR_ID -b" ] || exit 2
rendezvous boot-started compiler-started || exit $?
exit "$FAKE_BOOT_EXIT"
""", "git": """#!/bin/sh
test "$*" = 'rev-parse --verify HEAD' || exit 2
printf '%s\n' "$CHECKOUT_SHA"
""", "xcodebuild": """#!/bin/sh
if [ "$1" = -version ]; then
    printf 'Xcode 27.1\nBuild version 27A9275\n'
    exit "$FAKE_VERSION_EXIT"
fi
rendezvous compiler-started boot-started || exit $?
printf '%s\n' "$@" > build-args.txt
printf 'build stdout\n'
printf 'build stderr\n' >&2
exit "$FAKE_BUILD_EXIT"
"""}
            for name, script in tools.items():
                path = checkout / name
                path.write_text(script)
                path.chmod(0o755)
            env = {
                "PATH": str(checkout) + os.pathsep + os.environ["PATH"],
                "CHECKOUT_SHA": SOURCE_SHA,
                "GITHUB_SHA": "event-sha",
                "GITHUB_RUN_ID": "12345",
                "GITHUB_RUN_ATTEMPT": "2",
                "DEVELOPER_DIR": DEVELOPER_DIR,
                "SIMULATOR_ID": SIMULATOR_ID,
                "FAKE_BOOT_EXIT": str(boot_exit_code),
                profile_variable: profile,
                "FAKE_BUILD_EXIT": str(exit_code),
                "FAKE_VERSION_EXIT": str(version_exit_code),
            }
            # Use errexit but no implicit pipefail: the build step must enable pipefail itself.
            result = subprocess.run(["/bin/bash", "-e", "-c", build["run"]],
                                    cwd=checkout, env=env, capture_output=True, text=True, timeout=15)
            files = {}
            for path in (EVIDENCE / "receipt.txt", EVIDENCE / "build.log", Path("build-args.txt")):
                if (checkout / path).is_file():
                    files[path.name] = (checkout / path).read_text().splitlines()
            return result, files

    def test_builds_keep_their_arguments_and_retain_output_on_success_and_failure(self):
        for workflow, job, profile_variable, profile, conditions in CASES:
            for exit_code in (0, 65):
                with self.subTest(job=job, profile=profile, exit_code=exit_code):
                    result, files = self.run_build(
                        self.steps(workflow, job), profile_variable, profile, exit_code)
                    self.assertEqual(result.returncode, exit_code, result)
                    self.assertEqual(files["build.log"], ["build stdout", "build stderr"])
                    self.assertIn("build stderr", result.stdout)
                    self.assertEqual(files["receipt.txt"], [
                        f"source_sha={SOURCE_SHA}", "run_id=12345", "run_attempt=2", "configuration=Debug",
                        f"profile={profile}", f"developer_dir={DEVELOPER_DIR}", "Xcode 27.1", "Build version 27A9275",
                    ])
                    args = ["-project", "ios/RoomInTheCart.xcodeproj", "-scheme", "RoomInTheCart",
                            "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={SIMULATOR_ID}"]
                    if conditions:
                        args += ["-parallel-testing-enabled", "NO"]
                    args += ["-jobs", "2", "-derivedDataPath", ".build/DerivedData", "CODE_SIGN_IDENTITY=-"]
                    if conditions:
                        args += [f"SWIFT_ACTIVE_COMPILATION_CONDITIONS={conditions}"]
                    self.assertEqual(files["build-args.txt"], args + ["build-for-testing"])

    def test_boot_failure_blocks_publication_and_does_not_mask_compiler_errors(self):
        for workflow, job, variable, profile, _ in CASES:
            for build_status in (0, 65):
                with self.subTest(job=job, profile=profile, build_status=build_status):
                    result, _ = self.run_build(self.steps(workflow, job), variable, profile,
                                               build_status, boot_exit_code=70)
                    self.assertEqual(result.returncode, build_status or 70, result)

    def test_receipt_failure_prevents_build(self):
        for workflow, job, profile_variable, profile, _ in CASES:
            with self.subTest(job=job, profile=profile):
                result, files = self.run_build(self.steps(workflow, job), profile_variable, profile,
                                               exit_code=0, version_exit_code=70)
                self.assertEqual(result.returncode, 70, result)
                self.assertNotIn("build-args.txt", files)
                self.assertNotIn("build.log", files)

    def test_workflows_upload_only_small_build_evidence_on_any_build_outcome(self):
        names = set()
        for workflow, job, _, _, _ in CASES:
            with self.subTest(job=job):
                steps = self.steps(workflow, job)
                upload, = (step for step in steps if str(EVIDENCE) in step.get("with", {}).get("path", ""))
                self.assertTrue(upload["uses"].startswith("actions/upload-artifact@"))
                self.assertEqual(upload["if"], "always() && steps.build.outcome != 'skipped'")
                self.assertTrue(upload["continue-on-error"])
                options = upload["with"]
                self.assertEqual(set(options["path"].splitlines()), {
                    str(EVIDENCE / "build.log"), str(EVIDENCE / "receipt.txt"),
                })
                self.assertTrue(options["include-hidden-files"])
                self.assertEqual(options["retention-days"], 7)
                self.assertEqual(options["if-no-files-found"], "warn")
                names.add(options["name"])
        self.assertEqual(names, {
            "iphone-test-build-log-${{ github.run_attempt }}",
            "iphone-fixture-build-log-${{ env.FIXTURE_PROFILE }}-${{ github.run_attempt }}",
        })
        core = self.steps("ci.yml", "ios-build")
        requested_scope = "REQUESTED_IOS_SCOPE"
        self.assertEqual(next(step for step in core if step.get("id") == "build")["env"][requested_scope],
                         next(step for step in core if step.get("id") == "plan")["env"][requested_scope])


if __name__ == "__main__":
    unittest.main()
