import copy
import unittest

from plan_ios_fixture_tests import matrix
from select_ios_fixture_work import select_work


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
        self.assertEqual(self.full, before)

    def test_non_manual_runs_cannot_narrow_coverage(self):
        shard = self.full["include"][0]["shard"]
        for event in ("pull_request", "workflow_call", "push", "", "schedule"):
            with self.subTest(event=event), self.assertRaises(ValueError):
                select_work(event, shard, self.full)

    def test_invalid_or_ambiguous_selection_fails_before_building(self):
        for shard in ("missing", "*", "../contributor-balanced-01", "contributor-balanced-01\nmatrix={}", None):
            with self.subTest(shard=shard), self.assertRaises(ValueError):
                select_work("workflow_dispatch", shard, self.full)
        row = self.full["include"][0]
        with self.assertRaises(ValueError):
            select_work("workflow_dispatch", row["shard"], {"include": [row, row]})
        with self.assertRaises(ValueError):
            select_work("workflow_dispatch", "", {"include": []})


if __name__ == "__main__":
    unittest.main()
