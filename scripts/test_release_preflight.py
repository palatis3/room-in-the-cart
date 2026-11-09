"""Keep invalid release sources from allocating native slots."""
from pathlib import Path
import json
import os
import subprocess
import sys
import unittest

from check_ci_workflows import parse_workflow


ROOT = Path(__file__).resolve().parents[1]


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.jobs = parse_workflow(ROOT / ".github/workflows/release-checks.yml")[0]["jobs"]

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

    def test_preflight_runs_existing_source_validators_without_failure_bypasses(self):
        core = parse_workflow(ROOT / ".github/workflows/ci.yml")[0]["jobs"]["source-checks"]
        names = {
            "Validate workflow syntax and expression references",
            "Validate generated files, localization and CI test selection",
        }
        expected = [step for step in core["steps"] if step.get("name") in names]
        actual = [step for step in self.jobs["source-preflight"]["steps"] if "run" in step]
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
