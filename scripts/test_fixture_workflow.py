from pathlib import Path
import unittest
import os
import subprocess

from check_ci_workflows import M4_LABEL, PILOT_SHARD, PILOT_GUARD_STEP, FIXTURE_CONSUMER_RUNNER, FIXTURE_MATRIX_GROUP, FIXTURE_RUNNER, FIXTURE_SLOT_PREFIX, parse_workflow


class FixtureDependencyTests(unittest.TestCase):
    def test_profiles_wait_only_for_their_own_build_and_keep_the_same_runner(self):
        workflow, _, _ = parse_workflow(Path(__file__).resolve().parents[1] /
                                       ".github/workflows/ios-fixtures.yml")
        jobs = workflow["jobs"]
        for profile in ("contributor", "dinner"):
            job = jobs[f"{profile}-tests"]
            self.assertEqual(job["runs-on"], M4_LABEL if profile == 'contributor' else FIXTURE_CONSUMER_RUNNER)
            self.assertEqual(jobs[f"build-{profile}"]["runs-on"], M4_LABEL if profile == "contributor" else FIXTURE_RUNNER)
            self.assertEqual(jobs[f"build-{profile}"]["concurrency"]["group"],
                             "ritc-bitrise-m4-slot-0" if profile == "contributor" else FIXTURE_SLOT_PREFIX + "1")
            self.assertEqual(job["needs"], ["fixture-plan", f"build-{profile}"])
            self.assertEqual(job["if"], f"needs.fixture-plan.outputs.build_{profile} == 'true'")
            self.assertEqual(job["strategy"]["matrix"],
                             "${{ fromJSON(needs.fixture-plan.outputs." + profile + "_matrix) }}")
            self.assertEqual(job["env"]["TEST_PRODUCTS_ARTIFACT"],
                             "${{ needs.build-" + profile + ".outputs.artifact }}")
            self.assertEqual(job["concurrency"], {"group": "ritc-bitrise-m4-slot-1" if profile == "contributor" else FIXTURE_MATRIX_GROUP,
                                                  "queue": "max", "cancel-in-progress": False})
            self.assertFalse(job["strategy"]["fail-fast"])
            self.assertTrue(any("bash scripts/run_ios_test_shard.sh" in step.get("run", "")
                                for step in job["steps"]))
        self.assertEqual(jobs["contributor-tests"]["steps"], jobs["dinner-tests"]["steps"])
        self.assertEqual(set(jobs["fixture-gate"]["needs"]),
                         {"fixture-plan", "build-contributor", "build-dinner", "contributor-tests", "dinner-tests"})
        self.assertEqual(jobs["fixture-gate"]["if"], "always()")


    def test_pilot_guard_runs_first_and_rejects_every_other_invocation(self):
        from select_ios_fixture_work import select_work
        from plan_ios_fixture_tests import matrix
        workflow = parse_workflow(Path(__file__).resolve().parents[1] / '.github/workflows/ios-fixtures.yml')[0]
        guard = workflow['jobs']['fixture-plan']['steps'][0]
        self.assertEqual(guard, PILOT_GUARD_STEP)
        allowed = {'GITHUB_REPOSITORY': 'palatis3/room-in-the-cart', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                   'GITHUB_REF': 'refs/heads/codex/m4-fixture-pilot', 'REQUESTED_FIXTURE_SHARD': PILOT_SHARD}
        def execute(env):
            return subprocess.run(['/bin/bash', '-eo', 'pipefail', '-c', guard['run']],
                                  env={**os.environ, **env}, capture_output=True, text=True)
        self.assertEqual(execute(allowed).returncode, 0)
        for key, values in {
            'GITHUB_REPOSITORY': ['', 'outside/fork'],
            'GITHUB_EVENT_NAME': ['push', 'pull_request', 'pull_request_target', 'workflow_call', 'schedule', ''],
            'GITHUB_REF': ['refs/heads/main', 'refs/heads/codex/m4-fixture-pilot-other', 'refs/tags/codex/m4-fixture-pilot', ''],
            'REQUESTED_FIXTURE_SHARD': ['', '*', 'contributor-balanced-03', PILOT_SHARD + '\nmatrix={}'],
        }.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    self.assertNotEqual(execute({**allowed, key: value}).returncode, 0)
        selected = select_work('workflow_dispatch', PILOT_SHARD, matrix())
        self.assertEqual(selected['build_contributor'], True)
        self.assertEqual(selected['build_dinner'], False)
        self.assertEqual(len(selected['contributor_matrix']['include']), 1)
        self.assertEqual(selected['contributor_matrix']['include'][0]['shard'], PILOT_SHARD)
        self.assertEqual(selected['dinner_matrix']['include'], [])


if __name__ == "__main__":
    unittest.main()
