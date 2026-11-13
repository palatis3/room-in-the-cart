import copy
import unittest

from plan_ios_fixture_tests import matrix
from select_ios_fixture_work import check_job_results, select_work


class FixtureWorkSelectionTests(unittest.TestCase):
    def setUp(self):
        self.full = matrix()

    def test_default_keeps_every_group_and_both_build_profiles(self):
        for event in ("pull_request", "workflow_call", "workflow_dispatch", "push"):
            with self.subTest(event=event):
                result = select_work(event, "", self.full)
                self.assertEqual(result["matrix"], self.full)
                self.assertTrue(result["build_contributor"])
                self.assertTrue(result["build_dinner"])
                self.assertEqual(result["scope"], "full fixture suite")

    def test_every_manual_group_keeps_identity_slot_and_only_its_profile(self):
        before = copy.deepcopy(self.full)
        for row in self.full["include"]:
            with self.subTest(shard=row["shard"]):
                result = select_work("workflow_dispatch", row["shard"], self.full)
                self.assertEqual(result["matrix"], {"include": [row]})
                self.assertEqual(result["build_contributor"], row["profile"] == "contributor")
                self.assertEqual(result["build_dinner"], row["profile"] == "dinner")
                self.assertEqual(result["scope"], "targeted diagnostic")
                for profile in ("contributor", "dinner"):
                    self.assertEqual(result[f"{profile}_matrix"]["include"],
                                     [row] if row["profile"] == profile else [])
        self.assertEqual(self.full, before)

    def test_multiple_manual_groups_share_builds_and_preserve_planner_order(self):
        rows = self.full["include"]
        selected = [row for row in rows if row["profile"] == "contributor"][:2]
        for group in (selected, selected + [next(row for row in rows if row["profile"] == "dinner")]):
            request = ", ".join(row["shard"] for row in reversed(group))
            work = select_work("workflow_dispatch", request, self.full)
            self.assertEqual(work["matrix"]["include"], [row for row in rows if row in group])
            self.assertTrue(work["build_contributor"])
            self.assertEqual(work["build_dinner"], any(row["profile"] == "dinner" for row in group))

    def test_partition_preserves_every_original_row_and_slot_exactly_once(self):
        work = select_work("pull_request", "", self.full)
        parts = [row for profile in ("contributor", "dinner")
                 for row in work[f"{profile}_matrix"]["include"]]
        self.assertCountEqual(parts, self.full["include"])
        for profile in ("contributor", "dinner"):
            self.assertEqual(work[f"{profile}_matrix"]["include"],
                             [row for row in self.full["include"] if row["profile"] == profile])

    def test_non_manual_runs_cannot_narrow_coverage(self):
        shard = self.full["include"][0]["shard"]
        for event in ("pull_request", "workflow_call", "push", "", "schedule"):
            with self.subTest(event=event), self.assertRaises(ValueError):
                select_work(event, shard, self.full)

    def test_invalid_or_ambiguous_selection_fails_before_building(self):
        invalid = ("contributor-balanced-01,missing", "contributor-balanced-01,",
                   "contributor-balanced-01,contributor-balanced-01", "missing", "*",
                   "../contributor-balanced-01", "contributor-balanced-01\nmatrix={}", None)
        for shard in invalid:
            with self.subTest(shard=shard), self.assertRaises(ValueError):
                select_work("workflow_dispatch", shard, self.full)
        row = self.full["include"][0]
        with self.assertRaises(ValueError):
            select_work("workflow_dispatch", row["shard"], {"include": [row, row]})
        with self.assertRaises(ValueError):
            select_work("workflow_dispatch", "", {"include": []})


class FixtureJobGateTests(unittest.TestCase):
    @staticmethod
    def results(contributor=True, dinner=True):
        jobs = {"fixture-plan": {"result": "success", "outputs": {}}}
        for profile, selected in (("contributor", contributor), ("dinner", dinner)):
            jobs["fixture-plan"]["outputs"][f"build_{profile}"] = str(selected).lower()
            for name in (f"build-{profile}", f"{profile}-tests"):
                jobs[name] = {"result": "success" if selected else "skipped"}
        return jobs

    def test_full_and_each_focused_profile_can_pass(self):
        for selected in ((True, True), (True, False), (False, True)):
            check_job_results(self.results(*selected))

    def test_failed_cancelled_or_unexpectedly_skipped_required_job_fails(self):
        for selected in ((True, True), (True, False), (False, True)):
            original = self.results(*selected)
            for name, job in original.items():
                for outcome in ("failure", "cancelled", "skipped", "success"):
                    if outcome == job["result"]:
                        continue
                    jobs = copy.deepcopy(original)
                    jobs[name]["result"] = outcome
                    with self.subTest(selected=selected, name=name, outcome=outcome), self.assertRaises(ValueError):
                        check_job_results(jobs)

    def test_missing_or_empty_selection_cannot_pass(self):
        with self.assertRaises(ValueError):
            check_job_results(self.results(False, False))
        for value in (None, True, "", "unknown"):
            jobs = self.results()
            jobs["fixture-plan"]["outputs"]["build_dinner"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                check_job_results(jobs)


if __name__ == "__main__":
    unittest.main()
