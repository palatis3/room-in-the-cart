import json
from pathlib import Path
import tempfile
import unittest

from plan_ios_fixture_tests import (MICROPHONE_PROBE, UI_SOURCES, UI_TARGET, make_plan, matrix,
                                    source_inventory, suites_for, write_plan)


ORDINARY_TEST = f"{UI_TARGET}/FreeJourneyUITests/testCancellingSystemShareKeepsTheFrozenPickupUnplaced"
STOREKIT_TEST = "RoomInTheCartTests/StoreKitScenarioTests/testLocalAnnualOfferUsesStoreKitPriceAndLocale"


def enumeration(enabled, disabled=(STOREKIT_TEST,)):
    return {
        "errors": [],
        "values": [{
            "testPlan": "RoomInTheCart",
            "enabledTests": [{"identifier": f"{identifier}()"} for identifier in enabled],
            "disabledTests": [{"identifier": f"{identifier}()"} for identifier in disabled],
        }],
    }


class PlanIOSFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inventory = source_inventory(UI_SOURCES)

    def enabled_for(self, profile):
        return sorted(test for suite in suites_for(profile) for test in self.inventory[suite])

    def test_every_source_fixture_method_maps_to_one_serial_class_job(self):
        actual = [entry["shard"] for entry in matrix()["include"]]
        self.assertCountEqual(actual, self.inventory.keys())
        self.assertIn("RecipeLibraryAcceptanceUITests", suites_for("contributor"))
        self.assertIn("CorrectionPrivacyAcceptanceUITests", suites_for("contributor"))
        self.assertNotIn("LibraryPrivacyUITestCase", actual)
        self.assertEqual(suites_for("dinner"), ["DinnerDecisionSheetUITests"])

        for profile in ("contributor", "dinner"):
            enabled = self.enabled_for(profile)
            plan = make_plan(enumeration([ORDINARY_TEST, *reversed(enabled)]), profile, self.inventory)
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                write_plan(plan, output)
                self.assertEqual(json.loads((output / "manifest.json").read_text()), plan)
                self.assertEqual(plan["profile"], profile)
                selectors = []
                for suite, shard in plan["shards"].items():
                    lines = (output / shard["selector_file"]).read_text().splitlines()
                    self.assertEqual(lines, sorted(self.inventory[suite]))
                    selectors.extend(lines)
                self.assertCountEqual(selectors, enabled)

    def test_rejects_missing_class_and_missing_or_extra_method(self):
        enabled = self.enabled_for("contributor")
        suite = "ContributorRequestUITests"
        prefix = f"{UI_TARGET}/{suite}/"
        missing_class = [test for test in enabled if not test.startswith(prefix)]
        missing_method = [test for test in enabled if test != min(self.inventory[suite])]
        for tests in (missing_class, missing_method, [*enabled, f"{prefix}testUnknown"]):
            with self.subTest(tests=len(tests)):
                with self.assertRaisesRegex(ValueError, f"Compiled fixture tests differ for {suite}"):
                    make_plan(enumeration(tests), "contributor", self.inventory)

    def test_rejects_disabled_fixture_even_when_other_methods_in_same_class_run(self):
        enabled = self.enabled_for("contributor")
        disabled = min(self.inventory["ContributorRequestUITests"])
        remaining = [test for test in enabled if test != disabled]
        with self.assertRaisesRegex(ValueError, "Fixture tests must not be disabled"):
            make_plan(enumeration(remaining, [STOREKIT_TEST, disabled]), "contributor", self.inventory)

    def test_rejects_other_profile_or_microphone_permission_probe(self):
        enabled = self.enabled_for("contributor")
        dinner = min(self.inventory["DinnerDecisionSheetUITests"])
        for extra in (dinner, MICROPHONE_PROBE):
            for source in (enumeration([*enabled, extra]), enumeration(enabled, [STOREKIT_TEST, extra])):
                with self.subTest(extra=extra):
                    with self.assertRaisesRegex(ValueError, "Incompatible test compiled"):
                        make_plan(source, "contributor", self.inventory)

    def test_rejects_unknown_gated_suite_and_unrecognized_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "NewFixtureUITests.swift"
            for gate, error in (("CONTRIBUTOR_CAPTURE_UI_FIXTURE", "Undeclared fixture suite"),
                                ("NEW_UI_FIXTURE", "Unrecognized or mixed fixture gates")):
                with self.subTest(gate=gate):
                    source.write_text(f"#if DEBUG && {gate}\n"
                                      "@MainActor final class NewFixtureUITests: XCTestCase {\n"
                                      "    func testNewFixture() {}\n}\n#endif\n")
                    with self.assertRaisesRegex(ValueError, error):
                        source_inventory(Path(directory))

    def test_rejects_duplicate_and_errored_enumerations(self):
        enabled = self.enabled_for("dinner")
        source = enumeration(enabled)
        for data, error in ((enumeration([*enabled, enabled[0]]), "Duplicate Xcode test selector"),
                            ({**source, "errors": ["test discovery failed"]}, "reported errors"),
                            ({**source, "values": source["values"] * 2}, "exactly one test configuration")):
            with self.subTest(error=error):
                with self.assertRaisesRegex(ValueError, error):
                    make_plan(data, "dinner", self.inventory)


if __name__ == "__main__":
    unittest.main()
