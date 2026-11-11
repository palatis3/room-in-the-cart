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


if __name__ == "__main__":
    unittest.main()
