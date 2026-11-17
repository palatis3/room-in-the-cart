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

    def run_build(self, steps, profile_variable, profile, exit_code, version_exit_code=0, boot_exit_code=0,
                  provider="self-hosted", cache_enabled="", cas_outcome=""):
        build = next(step for step in steps if step.get("id") == "build")
        self.assertEqual(build["shell"], "bash")
        self.assertFalse(build.get("continue-on-error"))
        with tempfile.TemporaryDirectory() as folder:
            checkout = Path(folder)
            (checkout / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
            # Use the current interpreter, bypassing the macOS Xcode-dependent /usr/bin shim.
            (checkout / "python3").symlink_to(sys.executable)
            # Self-hosted must overlap; GitHub must not boot until compilation ends.
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
if [ "$RUNNER_ENVIRONMENT" = github-hosted ]; then
    [ -f compiler-finished ] && [ ! -f boot-started ] || exit 73
    touch boot-started
else
    rendezvous boot-started compiler-started || exit $?
fi
exit "$FAKE_BOOT_EXIT"
""", "git": """#!/bin/sh
test "$*" = 'rev-parse --verify HEAD' || exit 2
printf '%s\n' "$CHECKOUT_SHA"
""", "xcodebuild": """#!/bin/sh
if [ "$1" = -version ]; then
    printf 'Xcode 27.1\nBuild version 27A9275\n'
    exit "$FAKE_VERSION_EXIT"
fi
if [ "$RUNNER_ENVIRONMENT" = github-hosted ]; then
    [ ! -f boot-started ] || exit 74
    touch compiler-started
else
    rendezvous compiler-started boot-started || exit $?
fi
printf '%s\n' "$@" > build-args.txt
printf '%s\n' "$0" > compiler-command.txt
printf 'build stdout\n'
printf 'build stderr\n' >&2
touch compiler-finished
exit "$FAKE_BUILD_EXIT"
"""}
            for name, script in tools.items():
                path = checkout / name
                path.write_text(script)
                path.chmod(0o755)
            developer = checkout / "reviewed-xcode/Contents/Developer"
            direct = developer / "usr/bin/xcodebuild"
            direct.parent.mkdir(parents=True)
            direct.write_text(tools["xcodebuild"])
            direct.chmod(0o755)
            env = {
                "PATH": str(checkout) + os.pathsep + os.environ["PATH"],
                "CHECKOUT_SHA": SOURCE_SHA,
                "GITHUB_SHA": "event-sha",
                "GITHUB_RUN_ID": "12345",
                "GITHUB_RUN_ATTEMPT": "2",
                "DEVELOPER_DIR": str(developer),
                "SIMULATOR_ID": SIMULATOR_ID,
                "FAKE_BOOT_EXIT": str(boot_exit_code),
                "RUNNER_ENVIRONMENT": provider,
                "RITC_BITRISE_CACHE_ENABLED": cache_enabled,
                "RITC_CAS_OUTCOME": cas_outcome,
                "RITC_CAS_HIT": "true",
                profile_variable: profile,
                "FAKE_BUILD_EXIT": str(exit_code),
                "FAKE_VERSION_EXIT": str(version_exit_code),
            }
            # Use errexit but no implicit pipefail: the build step must enable pipefail itself.
            result = subprocess.run(["/bin/bash", "-e", "-c", build["run"]],
                                    cwd=checkout, env=env, capture_output=True, text=True, timeout=15)
            files = {"developer-dir": str(developer)}
            for path in (EVIDENCE / "receipt.txt", EVIDENCE / "build.log", Path("build-args.txt"),
                         Path("boot-started"), Path("compiler-finished"), Path("compiler-command.txt")):
                if (checkout / path).is_file():
                    files[path.name] = (checkout / path).read_text().splitlines()
            if "compiler-command.txt" in files:
                expected = direct if provider == "self-hosted" and cache_enabled != "true" else checkout / "xcodebuild"
                self.assertEqual(files["compiler-command.txt"], [str(expected)])
            return result, files

    def test_builds_keep_their_arguments_and_retain_output_on_success_and_failure(self):
        for workflow, job, profile_variable, profile, conditions in CASES:
            for provider, exit_code in ((p, s) for p in ("github-hosted", "self-hosted") for s in (0, 65)):
                with self.subTest(job=job, profile=profile, provider=provider, exit_code=exit_code):
                    result, files = self.run_build(
                        self.steps(workflow, job), profile_variable, profile, exit_code, provider=provider)
                    self.assertEqual(result.returncode, exit_code, result)
                    self.assertIn("compiler-finished", files)
                    self.assertEqual("boot-started" in files, provider == "self-hosted" or exit_code == 0)
                    self.assertEqual(files["build.log"], ["build stdout", "build stderr"])
                    self.assertIn("build stderr", result.stdout)
                    self.assertEqual(files["receipt.txt"], [
                        f"source_sha={SOURCE_SHA}", "run_id=12345", "run_attempt=2", "configuration=Debug",
                        f"profile={profile}", f"developer_dir={files['developer-dir']}", "Xcode 27.1", "Build version 27A9275",
                    ])
                    args = ["-project", "ios/RoomInTheCart.xcodeproj", "-scheme", "RoomInTheCart",
                            "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={SIMULATOR_ID}"]
                    if conditions:
                        args += ["-parallel-testing-enabled", "NO"]
                    args += ["-jobs", "2", "-derivedDataPath", ".build/DerivedData"]
                    if provider == "self-hosted":
                        args += ["COMPILATION_CACHE_ENABLE_CACHING=NO"]
                    args += ["CODE_SIGN_IDENTITY=-"]
                    if conditions:
                        args += [f"SWIFT_ACTIVE_COMPILATION_CONDITIONS={conditions}"]
                    self.assertEqual(files["build-args.txt"], args + ["build-for-testing"])

    def test_boot_failure_blocks_publication_and_does_not_mask_compiler_errors(self):
        for workflow, job, variable, profile, _ in CASES:
            for provider, build_status in ((p, s) for p in ("github-hosted", "self-hosted") for s in (0, 65)):
                with self.subTest(job=job, profile=profile, provider=provider, build_status=build_status):
                    result, _ = self.run_build(self.steps(workflow, job), variable, profile,
                                               build_status, boot_exit_code=70, provider=provider)
                    self.assertEqual(result.returncode, build_status or 70, result)

    def test_receipt_failure_prevents_build(self):
        for workflow, job, profile_variable, profile, _ in CASES:
            with self.subTest(job=job, profile=profile):
                result, files = self.run_build(self.steps(workflow, job), profile_variable, profile,
                                               exit_code=0, version_exit_code=70)
                self.assertEqual(result.returncode, 70, result)
                self.assertNotIn("build-args.txt", files)
                self.assertNotIn("build.log", files)

    def test_cache_opt_in_and_github_cas_preserve_command_selection(self):
        for provider, enabled, cas, expected in (
                ("self-hosted", "true", "", []),
                ("self-hosted", "false", "success", ["COMPILATION_CACHE_ENABLE_CACHING=NO"]),
                ("github-hosted", "", "success", ["COMPILATION_CACHE_ENABLE_CACHING=YES",
                                                    "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES"])):
            with self.subTest(provider=provider, enabled=enabled):
                result, files = self.run_build(self.steps("ci.yml", "ios-build"), "REQUESTED_IOS_SCOPE",
                                               "full", 0, provider=provider, cache_enabled=enabled, cas_outcome=cas)
                self.assertEqual(result.returncode, 0, result)
                settings = [arg for arg in files["build-args.txt"] if arg.startswith("COMPILATION_CACHE_")]
                if provider == "github-hosted":
                    self.assertTrue(settings[-1].endswith("/.build/github-xcode-cas"))
                    self.assertTrue(settings.pop().startswith("COMPILATION_CACHE_CAS_PATH="))
                self.assertEqual(settings, expected)

    def test_all_bitrise_activation_steps_require_explicit_repository_opt_in(self):
        for workflow, job in (("ci.yml", "ios-release"), ("ci.yml", "ios-build"),
                              ("ios-fixtures.yml", "build-contributor"), ("ios-fixtures.yml", "build-dinner")):
            with self.subTest(job=job):
                steps = self.steps(workflow, job)
                activation = next(s for s in steps if s.get("id") == "compilation-cache")
                self.assertEqual(activation["if"], "runner.environment == 'self-hosted' && vars.RITC_BITRISE_CACHE_ENABLED == 'true'")
                build = next(s for s in steps if s.get("id") == "build" or s.get("name") == "Compile unsigned Release for iPhone")
                self.assertEqual(build["env"]["RITC_BITRISE_CACHE_ENABLED"], "${{ vars.RITC_BITRISE_CACHE_ENABLED }}")

    def test_release_cache_off_uses_direct_xcode_and_preserves_archive_failure(self):
        step = next(s for s in self.steps("ci.yml", "ios-release") if s.get("name") == "Compile unsigned Release for iPhone")
        for provider, enabled in (("self-hosted", ""), ("self-hosted", "true"), ("github-hosted", "")):
            for status in (0, 65):
                with self.subTest(provider=provider, enabled=enabled, status=status), tempfile.TemporaryDirectory() as folder:
                    checkout = Path(folder)
                    developer = checkout / "reviewed-xcode/Contents/Developer"
                    direct = developer / "usr/bin/xcodebuild"
                    direct.parent.mkdir(parents=True)
                    for path in (direct, checkout / "xcodebuild"):
                        path.write_text('#!/bin/sh\nprintf "%s\\n" "$0" > command.txt\nprintf "%s\\n" "$@" > args.txt\nexit "$FAKE_BUILD_EXIT"\n')
                        path.chmod(0o755)
                    env = dict(os.environ, PATH=str(checkout) + os.pathsep + os.environ["PATH"],
                               DEVELOPER_DIR=str(developer), RUNNER_ENVIRONMENT=provider,
                               RITC_BITRISE_CACHE_ENABLED=enabled, FAKE_BUILD_EXIT=str(status))
                    result = subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c", step["run"]],
                                            cwd=checkout, env=env, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, status, result)
                    disabled = provider == "self-hosted" and enabled != "true"
                    self.assertEqual((checkout / "command.txt").read_text().strip(), str(direct if disabled else checkout / "xcodebuild"))
                    args = (checkout / "args.txt").read_text().splitlines()
                    expected = ["-project", "ios/RoomInTheCart.xcodeproj", "-scheme", "RoomInTheCart-Release",
                                "-configuration", "Release", "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
                                "-jobs", "2", "-derivedDataPath", ".build/ReleaseDerivedData", "ARCHS=arm64",
                                "-archivePath", ".build/RoomInTheCart.xcarchive"]
                    if disabled: expected += ["COMPILATION_CACHE_ENABLE_CACHING=NO"]
                    expected += ["CODE_SIGNING_REQUIRED=NO", "CODE_SIGNING_ALLOWED=NO", "archive"]
                    self.assertEqual(args, expected)

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
