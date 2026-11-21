import contextlib
import csv
import io
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from compare_shopper_journeys import criterion_report, report, score


class ShopperRegressionTests(unittest.TestCase):
    def test_missing_domain_cannot_be_turned_into_a_passing_grade(self):
        ratings = {i: 100 for i in range(25)}
        domains = {i: "O" for i in ratings}
        self.assertIsNone(score(ratings, ratings.keys(), domains, None))

    def test_completed_cells_still_respect_consequence_ceiling(self):
        ratings = {i: 100 for i in range(25)}
        domains = {i: "OECAR"[i % 5] for i in ratings}
        self.assertEqual(score(ratings, ratings.keys(), domains, 49), 49)

    def test_a_better_average_cannot_hide_one_worse_trip_or_new_ceiling(self):
        higher = [(f"{i:02}", 30, 60, 95, None, None) for i in range(1, 12)]
        for last in [("12", 30, 80, 78, None, None), ("12", 30, 80, 79.9975, None, None),
                     ("12", 30, 48, 49, None, 49)]:
            with self.subTest(last=last), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report(higher + [last], True), 1)

    def test_incomplete_trip_withholds_the_headline(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(report([("01", 23, None, None, None, None),
                                     ("02", 30, 70, 75, None, None)], True), 2)
        self.assertIn("Eligible subset (1/2 journeys)", output.getvalue())
        self.assertNotIn("Equal-weight cohort", output.getvalue())

    def test_incomplete_trip_still_reports_a_new_consequence_ceiling(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(report([("12", 22, None, None, None, 49)], True), 2)
        self.assertIn("new consequence ceilings for 12", output.getvalue())

    def test_criterion_breakdown_exposes_mixed_results_and_keeps_missing_evidence_blank(self):
        rubric = {1: {"criterion": "Clear feedback", "domain": "C"},
                  2: {"criterion": "Return", "domain": "R"}}
        observations = {1: [("01", 50, 75), ("02", 75, 50), ("03", 75, 75)], 2: []}
        with TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            output = Path(folder) / "criteria.csv"
            self.assertEqual(criterion_report(rubric, observations, output), 1)
            with output.open(newline="") as file:
                mixed, missing = csv.DictReader(file)
        self.assertEqual(mixed["before_mean"], mixed["after_mean"])
        self.assertEqual((mixed["improved_trips"], mixed["lower_trips"], mixed["unchanged_trips"]),
                         ("01", "02", "03"))
        self.assertEqual((missing["shared_observations"], missing["after_mean"]), ("0", ""))
