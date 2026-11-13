import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest

from check_ci_workflows import FIXTURE_CONSUMER_RUNNER, FIXTURE_MATRIX_GROUP, FIXTURE_RUNNER, FIXTURE_SLOT_PREFIX, parse_workflow


class FixtureDependencyTests(unittest.TestCase):
    def test_profiles_wait_only_for_their_own_build_and_keep_the_same_runner(self):
        workflow, _, _ = parse_workflow(Path(__file__).resolve().parents[1] /
                                       ".github/workflows/ios-fixtures.yml")
        jobs = workflow["jobs"]
        for profile in ("contributor", "dinner"):
            job = jobs[f"{profile}-tests"]
            self.assertEqual(job["runs-on"], FIXTURE_CONSUMER_RUNNER)
            self.assertEqual(jobs[f"build-{profile}"]["runs-on"], FIXTURE_RUNNER)
            self.assertEqual(jobs[f"build-{profile}"]["concurrency"]["group"],
                             FIXTURE_SLOT_PREFIX + str(("contributor", "dinner").index(profile)))
            self.assertEqual(job["needs"], ["fixture-plan", f"build-{profile}"])
            self.assertEqual(job["if"], f"needs.fixture-plan.outputs.build_{profile} == 'true'")
            self.assertEqual(job["strategy"]["matrix"],
                             "${{ fromJSON(needs.fixture-plan.outputs." + profile + "_matrix) }}")
            self.assertEqual(job["env"]["TEST_PRODUCTS_ARTIFACT"],
                             "${{ needs.build-" + profile + ".outputs.artifact }}")
            self.assertEqual(job["concurrency"], {"group": FIXTURE_MATRIX_GROUP,
                                                  "queue": "max", "cancel-in-progress": False})
            self.assertFalse(job["strategy"]["fail-fast"])
            self.assertTrue(any("bash scripts/run_ios_test_shard.sh" in step.get("run", "")
                                for step in job["steps"]))
        self.assertEqual(jobs["contributor-tests"]["env"]["RECORDS_BUILD_WORKSPACE"],
                         "${{ needs.build-contributor.outputs.workspace }}")
        self.assertEqual(jobs["build-contributor"]["outputs"]["workspace"], "${{ github.workspace }}")
        self.assertEqual(jobs["contributor-tests"]["steps"], jobs["dinner-tests"]["steps"])
        self.assertEqual(set(jobs["fixture-gate"]["needs"]),
                         {"fixture-plan", "build-contributor", "build-dinner", "contributor-tests", "dinner-tests"})
        self.assertEqual(jobs["fixture-gate"]["if"], "always()")

    def test_private_records_step_keeps_raw_output_private_and_propagates_both_failures(self):
        workflow, _, _ = parse_workflow(Path(__file__).resolve().parents[1] / ".github/workflows/ios-fixtures.yml")
        steps = workflow["jobs"]["contributor-tests"]["steps"]
        run = next(step["run"] for step in steps if step.get("name") == "Run selected fixture tests and require complete execution")
        with TemporaryDirectory() as folder:
            root = Path(folder)
            (root / ".build").mkdir()
            (root / "scripts").mkdir()
            private = "private fixture canary"
            (root / "scripts/run_ios_test_shard.sh").write_text(
                'echo "$PRIVATE"\necho "$PRIVATE" >&2\n'
                'if [[ -n "$GITHUB_STEP_SUMMARY" ]]; then echo "$PRIVATE" >> "$GITHUB_STEP_SUMMARY"; fi\n'
                'exit "$RUN_STATUS"\n')
            (root / "scripts/report_records_media_test.py").write_text(
                'import os, sys\nprint(os.environ["PRIVATE"], file=sys.stderr)\n'
                'assert sys.argv[1:] == [".build", os.environ["RUN_STATUS"], os.environ["TEST_SHARD"]]\n'
                'print("safe result")\nsys.exit(int(os.environ["REPORT_STATUS"]))\n')
            summary = root / "summary"
            for shard in ("SharedRecordsUITests", "RecordsMediaUITests"):
                for run_status, report_status in ((0, 0), (0, 1), (7, 0)):
                    with self.subTest(shard=shard, run=run_status, report=report_status):
                        summary.write_text("")
                        result = subprocess.run(["bash", "-e", "-c", run], cwd=root, capture_output=True, text=True,
                            env={**os.environ, "RUNNER_TEMP": folder, "GITHUB_STEP_SUMMARY": str(summary),
                                 "TEST_SHARD": shard, "RUN_STATUS": str(run_status),
                                 "REPORT_STATUS": str(report_status), "PRIVATE": private})
                        self.assertEqual(result.returncode, run_status or report_status)
                        self.assertEqual(summary.read_text(), "safe result\n")
                        self.assertEqual((root / ".build/records-test-report.md").read_text(), "safe result\n")
                        self.assertNotIn(private, result.stdout + result.stderr)
                        self.assertEqual((root / "records-fixture.log").read_text().count(private), 3)

    def test_failed_result_upload_retries_only_the_same_non_media_files(self):
        workflow, _, _ = parse_workflow(Path(__file__).resolve().parents[1] /
                                       ".github/workflows/ios-fixtures.yml")
        steps = workflow["jobs"]["contributor-tests"]["steps"]
        upload = next(step for step in steps if step.get("id") == "fixture_results_upload")
        retry = next(step for step in steps if step.get("name") == "Retry fixture result upload")
        exclusion = "matrix.shard != 'RecordsMediaUITests' && matrix.shard != 'SharedRecordsUITests'"
        self.assertIn(exclusion, upload["if"])
        private = next(step for step in steps if step.get("name") == "Retain privacy-safe Records verification")
        self.assertIn("matrix.shard == 'SharedRecordsUITests'", private["if"])
        self.assertEqual(set(private["with"]["path"].splitlines()),
                         {".build/records-test-report.md", ".build/test-simulator-ownership.json", ".build/test-plan/"})
        self.assertEqual(retry["if"], "${{ !cancelled() && " + exclusion + " && "
                                    "steps.fixture_results_upload.outcome == 'failure' }}")
        self.assertTrue(upload["continue-on-error"])
        self.assertFalse(retry.get("continue-on-error", False))
        self.assertEqual(retry["uses"], upload["uses"])
        self.assertEqual(retry["with"]["path"], upload["with"]["path"])
        self.assertEqual(retry["with"]["name"], upload["with"]["name"] + "-retry")
        self.assertEqual(retry["with"]["if-no-files-found"], "error")


if __name__ == "__main__":
    unittest.main()
