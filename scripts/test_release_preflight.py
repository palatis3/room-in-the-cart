"""Keep invalid release sources from allocating native slots."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from check_ci_workflows import parse_workflow
from check_release_performance_preflight import validate as validate_performance


ROOT = Path(__file__).resolve().parents[1]


class ReleasePreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.checkout = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.checkout.cleanup)
        subprocess.run(["git", "init", "--quiet", cls.checkout.name], check=True, capture_output=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "Fixture"],
                       cwd=cls.checkout.name, check=True, capture_output=True)
        cls.sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cls.checkout.name, text=True).strip()

    def setUp(self):
        self.workflow = parse_workflow(ROOT / ".github/workflows/release-checks.yml")[0]
        self.jobs = self.workflow["jobs"]

    def candidate_guard(self):
        return next(step for step in self.jobs["source-preflight"]["steps"]
                    if step.get("name") == "Require the reviewed release candidate")

    def run_candidate_guard(self, candidate, event_sha):
        return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", self.candidate_guard()["run"]],
                              cwd=self.checkout.name,
                              env={**os.environ, "REVIEWED_CANDIDATE_SHA": candidate, "GITHUB_SHA": event_sha},
                              capture_output=True, text=True, check=False)

    def test_required_candidate_is_checked_after_checkout_before_expensive_preflight(self):
        self.assertEqual(set(self.workflow["on"]), {"workflow_dispatch"})
        spec = self.workflow["on"]["workflow_dispatch"]["inputs"]["candidate_sha"]
        self.assertEqual(spec["type"], "string")
        self.assertIs(spec["required"], True)
        self.assertNotIn("default", spec)
        steps = self.jobs["source-preflight"]["steps"]
        self.assertTrue(steps[0]["uses"].startswith("actions/checkout@"))
        self.assertEqual(steps[1], self.candidate_guard())
        self.assertEqual(steps[2]["name"], "Check production metadata before allocating native runners")
        self.assertEqual(self.candidate_guard()["env"], {"REVIEWED_CANDIDATE_SHA": "${{ inputs.candidate_sha }}"})
        self.assertNotIn("${{", self.candidate_guard()["run"])

    def test_metadata_step_checks_the_release_file_and_ignores_staging_values(self):
        step = self.jobs["source-preflight"]["steps"][2]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / step["working-directory"]
            scripts.mkdir()
            (scripts / "app_configuration.py").write_bytes((ROOT / "scripts/app_configuration.py").read_bytes())
            config = root / "config"
            config.mkdir()
            store_fields = {"householdSubscriptionProductID": "org.grocery.annual", "supportURL": "https://grocery.org/support",
                            "privacyPolicyURL": "https://grocery.org/privacy", "termsOfUseURL": "https://grocery.org/terms"}
            backend = {"supabaseURL": "https://identity.grocery.org", "publishableKey": "sb_publishable_release",
                       "serviceURL": "https://api.grocery.org"}
            (config / "staging.json").write_text(json.dumps({
                **store_fields, "environment": "staging", "supabaseURL": "https://staging-identity.grocery.org",
                "publishableKey": "sb_publishable_staging", "serviceURL": "https://staging-api.grocery.org",
            }))
            for release, error in ((None, "Release metadata is incomplete"),
                                   ({"supportURL": "http://grocery.org/support"}, "supportURL"),
                                   (store_fields, "HouseholdServiceURL"), ({**store_fields, **backend}, None)):
                with self.subTest(error=error):
                    if release is not None:
                        (config / "release.json").write_text(json.dumps(release))
                    run = subprocess.run(["bash", "-e", "-c", step["run"]], cwd=scripts, capture_output=True, text=True)
                    if error is None:
                        self.assertEqual(run.returncode, 0, run.stderr)
                    else:
                        self.assertNotEqual(run.returncode, 0)
                        self.assertIn(error, run.stderr)

    def test_candidate_guard_accepts_matching_dispatch_and_actual_checkout(self):
        result = self.run_candidate_guard(self.sha, self.sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.sha, result.stdout)

    def test_candidate_guard_rejects_malformed_inputs_without_shell_execution(self):
        for candidate in ("", self.sha[:7], "A" * 40, "g" * 40, self.sha + "\n", "$(touch candidate-injection)"):
            with self.subTest(candidate=candidate):
                result = self.run_candidate_guard(candidate, self.sha)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("full lowercase commit SHA", result.stderr)
        self.assertFalse((Path(self.checkout.name) / "candidate-injection").exists())

    def test_candidate_guard_rejects_dispatch_mismatch_and_checkout_drift(self):
        other = "b" * 40 if self.sha != "b" * 40 else "c" * 40
        for candidate, event_sha in ((self.sha, other), (other, other)):
            with self.subTest(candidate=candidate, event_sha=event_sha):
                result = self.run_candidate_guard(candidate, event_sha)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("differs from the dispatched or checked-out revision", result.stderr)

    def test_native_paths_wait_for_linux_validation_without_holding_a_slot(self):
        preflight = self.jobs["source-preflight"]
        self.assertEqual(preflight["runs-on"], "ubuntu-24.04")
        self.assertNotIn("concurrency", preflight)
        self.assertNotIn("needs", preflight)
        for name in ("core", "diagnostics", "fixtures", "native-wire", "performance", "staging-iphone"):
            with self.subTest(job=name):
                self.assertEqual(self.jobs[name]["needs"], "source-preflight")
                self.assertNotIn("if", self.jobs[name])
        for name in ("security", "dependencies"):
            self.assertNotIn("needs", self.jobs[name])

    def test_release_checks_performance_before_source_tests_and_native_fanout(self):
        steps = self.jobs['source-preflight']['steps']
        guard = next(i for i, step in enumerate(steps)
                     if step.get('run') == 'python3 scripts/check_release_performance_preflight.py')
        setup = next(i for i, step in enumerate(steps)
                     if step.get('name') == 'Validate workflow syntax and expression references')
        tests = next(i for i, step in enumerate(steps)
                     if step.get('name') == 'Validate generated files, localization and CI test selection')
        self.assertLess(setup, guard)
        self.assertLess(guard, tests)
        self.assertNotIn('env', steps[guard])  # No calibration override on full release.
        performance = parse_workflow(ROOT / '.github/workflows/ios-performance.yml')[0]
        self.assertEqual(performance['jobs']['performance-plan']['steps'][-1]['run'],
                         'python3 scripts/check_ios_performance_environment.py configured --architecture arm64')

    def test_release_performance_reads_workflow_pins_and_fails_before_native_queries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.github/workflows').mkdir(parents=True)
            (root / 'scripts').mkdir()
            workflow = root / '.github/workflows/ios-performance.yml'
            workflow.write_bytes((ROOT / '.github/workflows/ios-performance.yml').read_bytes())
            baseline_path = root / 'scripts/ios_performance_baselines.json'
            baseline = json.loads((ROOT / 'scripts/ios_performance_baselines.json').read_text())
            # Synthetic profiles establish both outcomes without approving real calibration.
            baseline['profiles'][0]['environment'].update(
                xcode='Xcode 0.0\nBuild version fixture-build', osVersion='0.0')
            baseline_path.write_text(json.dumps(baseline))
            with patch('check_ios_performance_environment.subprocess.check_output') as native:
                with self.assertRaisesRegex(ValueError, 'No approved baseline'):
                    validate_performance(root)
                pins = parse_workflow(workflow)[0]['env']
                baseline['profiles'][0]['environment'].update(
                    xcode='Xcode ' + pins['DEVELOPER_DIR'].split('Xcode_')[1].split('.app')[0]
                          + '\nBuild version fixture-build',
                    osVersion=pins['CI_IPHONE_RUNTIME'].split('iOS-')[1].replace('-', '.'),
                    modelName=pins['CI_IPHONE_NAME'], architecture='arm64')
                baseline_path.write_text(json.dumps(baseline))
                result = validate_performance(root)
                self.assertEqual(result['compatibleProfiles'], 1)
                self.assertFalse(result['releaseAcceptance'])
                workflow.write_text(workflow.read_text().replace('CI_IPHONE_NAME: iPhone 17',
                                                                  'CI_IPHONE_NAME: Changed device'))
                with self.assertRaisesRegex(ValueError, 'No approved baseline'):
                    validate_performance(root)
                native.assert_not_called()

    def test_preflight_runs_existing_source_validators_without_failure_bypasses(self):
        core = parse_workflow(ROOT / ".github/workflows/ci.yml")[0]["jobs"]["source-checks"]
        names = {
            "Validate workflow syntax and expression references",
            "Validate generated files, localization and CI test selection",
        }
        expected = [step for step in core["steps"] if step.get("name") in names]
        actual = [step for step in self.jobs["source-preflight"]["steps"] if step.get("name") in names]
        self.assertEqual(len(expected), 2)
        self.assertEqual(actual, expected)
        self.assertNotIn("continue-on-error", self.jobs["source-preflight"])
        for step in self.jobs["source-preflight"]["steps"]:
            self.assertNotIn("continue-on-error", step)
            self.assertNotIn("if", step)

    def test_release_gate_rejects_failed_or_skipped_preflight_and_keeps_full_checks(self):
        gate = self.jobs["release-checks"]
        self.assertEqual(set(gate["needs"]), {
            "source-preflight", "core", "security", "diagnostics", "fixtures", "native-wire",
            "performance", "staging-iphone", "dependencies",
        })
        self.assertEqual(gate["if"], "always()")
        self.assertEqual(gate["env"]["JOB_RESULTS"], "${{ toJSON(needs) }}")
        require_all = next(step["run"] for step in gate["steps"]
                           if step.get("name") == "Require every pre-release job to succeed")
        code = require_all.split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        for result in ("success", "failure", "skipped", "cancelled"):
            with self.subTest(preflight_result=result):
                results = {name: {"result": "success"} for name in gate["needs"]}
                results["source-preflight"]["result"] = result
                completed = subprocess.run([sys.executable, "-c", code],
                                           env={**os.environ, "JOB_RESULTS": json.dumps(results)},
                                           capture_output=True, text=True, check=False)
                self.assertEqual(completed.returncode == 0, result == "success")
                if result != "success":
                    self.assertIn("source-preflight", completed.stderr)
        self.assertEqual(self.jobs["core"]["with"], {"require_release_metadata": True})
        self.assertEqual(self.jobs["performance"]["with"], {"enforce_baselines": True})
        self.assertNotIn("with", self.jobs["fixtures"])


if __name__ == "__main__":
    unittest.main()
