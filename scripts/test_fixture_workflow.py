from pathlib import Path
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
        self.assertEqual(jobs["contributor-tests"]["steps"], jobs["dinner-tests"]["steps"])
        self.assertEqual(set(jobs["fixture-gate"]["needs"]),
                         {"fixture-plan", "build-contributor", "build-dinner", "contributor-tests", "dinner-tests"})
        self.assertEqual(jobs["fixture-gate"]["if"], "always()")

    def test_failed_result_upload_retries_only_the_same_non_media_files(self):
        workflow, _, _ = parse_workflow(Path(__file__).resolve().parents[1] /
                                       ".github/workflows/ios-fixtures.yml")
        steps = workflow["jobs"]["contributor-tests"]["steps"]
        upload = next(step for step in steps if step.get("id") == "fixture_results_upload")
        retry = next(step for step in steps if step.get("name") == "Retry fixture result upload")
        self.assertIn("matrix.shard != 'RecordsMediaUITests'", upload["if"])
        self.assertEqual(retry["if"], "${{ !cancelled() && matrix.shard != 'RecordsMediaUITests' && "
                                    "steps.fixture_results_upload.outcome == 'failure' }}")
        self.assertTrue(upload["continue-on-error"])
        self.assertFalse(retry.get("continue-on-error", False))
        self.assertEqual(retry["uses"], upload["uses"])
        self.assertEqual(retry["with"]["path"], upload["with"]["path"])
        self.assertEqual(retry["with"]["name"], upload["with"]["name"] + "-retry")
        self.assertEqual(retry["with"]["if-no-files-found"], "error")


if __name__ == "__main__":
    unittest.main()
