import contextlib
import io
import unittest

from compare_shopper_journeys import report, score


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
        for last in [("12", 30, 80, 78, None, None), ("12", 30, 48, 49, None, 49)]:
            with self.subTest(last=last), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report(higher + [last], True), 1)

    def test_incomplete_trip_withholds_the_headline(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(report([("01", 23, None, None, None, None),
                                     ("02", 30, 70, 75, None, None)], True), 2)
        self.assertIn("Eligible subset (1/2 journeys)", output.getvalue())
        self.assertNotIn("Equal-weight cohort", output.getvalue())
