import json
from pathlib import Path
import tempfile
import unittest

from plan_ios_tests import MODEL_TARGET, UI_TARGET, make_plan, selector, write_plan


MODEL = f"{MODEL_TARGET}/ModelTests/testModel()"
DISABLED = f"{MODEL_TARGET}/StoreKitScenarioTests/testLocalOffer()"
UI_TESTS = [f"{UI_TARGET}/JourneyTests/test{letter}()" for letter in "ABCDE"]
DURATIONS = {
    "hosted_seconds": {selector(UI_TESTS[0]): 100},
    "local_seconds": {selector(UI_TESTS[0]): 1, selector(UI_TESTS[1]): 20},
    "local_multiplier": 4,
    "default_seconds": 30,
}


def enumeration(enabled, disabled=(DISABLED,)):
    return {
        "errors": [],
        "values": [{
            "testPlan": "RoomInTheCart",
            "enabledTests": [{"identifier": identifier} for identifier in enabled],
            "disabledTests": [{"identifier": identifier} for identifier in disabled],
        }],
    }


class PlanIOSTests(unittest.TestCase):
    def test_every_enabled_case_appears_once_in_manifest_and_selector_files(self):
        new_ui = f"{UI_TARGET}/NewSuite/testNewCase()"
        new_model = f"{MODEL_TARGET}/NewModels/testNewCase()"
        enabled = [MODEL, new_model, *UI_TESTS, new_ui]
        plan = make_plan(enumeration(enabled), DURATIONS, 3)

        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "plan"
            write_plan(plan, output)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["include"][0], {"shard": "models", "expected_count": 2})
            self.assertEqual(manifest["disabled_tests"], [DISABLED])
            original_identifiers = []
            selectors = []
            for job in manifest["include"]:
                shard = manifest["shards"][job["shard"]]
                identifiers = shard["test_identifiers"]
                lines = (output / shard["selector_file"]).read_text().splitlines()
                self.assertEqual(job["expected_count"], len(lines))
                self.assertEqual(lines, [identifier[:-2] for identifier in identifiers])
                self.assertTrue(lines)
                target = MODEL_TARGET if job["shard"] == "models" else UI_TARGET
                self.assertTrue(all(line.startswith(f"{target}/") for line in lines))
                original_identifiers.extend(identifiers)
                selectors.extend(lines)

        self.assertCountEqual(original_identifiers, enabled)
        self.assertEqual(len(selectors), len(set(selectors)))

    def test_greedy_duration_balancing_is_stable_and_prefers_hosted_measurements(self):
        enabled = [MODEL, *UI_TESTS]
        plan = make_plan(enumeration(enabled), DURATIONS, 2)
        reversed_plan = make_plan(enumeration(reversed(enabled)), DURATIONS, 2)
        self.assertEqual(plan, reversed_plan)
        self.assertEqual(plan["shards"]["ui-01"]["test_identifiers"], [UI_TESTS[0], UI_TESTS[3]])
        self.assertEqual(plan["shards"]["ui-01"]["estimated_seconds"], 130)
        self.assertEqual(
            plan["shards"]["ui-02"]["test_identifiers"], [UI_TESTS[1], UI_TESTS[2], UI_TESTS[4]]
        )
        self.assertEqual(plan["shards"]["ui-02"]["estimated_seconds"], 140)

    def test_rejects_duplicate_selectors_including_after_normalization(self):
        for source in (
            enumeration([MODEL, UI_TESTS[0], UI_TESTS[0]]),
            enumeration([MODEL, UI_TESTS[0], selector(UI_TESTS[0])]),
            enumeration([MODEL, UI_TESTS[0]], [UI_TESTS[0]]),
        ):
            with self.subTest(source=source):
                with self.assertRaisesRegex(ValueError, "Duplicate Xcode test selector"):
                    make_plan(source, DURATIONS, 1)

    def test_rejects_invalid_or_incomplete_enumeration(self):
        source = enumeration([MODEL, UI_TESTS[0]])
        invalid = (
            ({**source, "errors": ["enumeration failed"]}, "reported errors"),
            ({**source, "values": source["values"] * 2}, "exactly one test configuration"),
            (enumeration([]), "enabled model and UI tests"),
            (enumeration([MODEL]), "enabled model and UI tests"),
            (enumeration([UI_TESTS[0]]), "enabled model and UI tests"),
            (enumeration([MODEL, "OtherTarget/Suite/testCase()"]), "Unknown Xcode test target"),
            (enumeration([MODEL, f"{UI_TARGET}/Suite"]), "Invalid Xcode test identifier"),
        )
        for data, message in invalid:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValueError, message):
                    make_plan(data, DURATIONS, 1)
        with self.assertRaisesRegex(ValueError, "2 nonempty shards"):
            make_plan(source, DURATIONS, 2)

    def test_rejects_invalid_duration_data(self):
        with self.assertRaisesRegex(ValueError, "positive integers"):
            make_plan(enumeration([MODEL, UI_TESTS[0]]), {**DURATIONS, "default_seconds": 0}, 1)


if __name__ == "__main__":
    unittest.main()
