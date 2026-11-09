import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from plan_ios_fixture_tests import (
    BALANCED_SUITES, DELIVERY_SHARDS, ISOLATED_SUITES, LIBRARY_PRIVACY_HELPER, MICROPHONE_PROBE,
    UI_SOURCES, UI_TARGET, make_plan, matrix, source_inventory, suites_for, write_plan,
)


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

    def test_every_source_fixture_method_maps_to_exactly_one_job(self):
        actual = [entry["shard"] for entry in matrix()["include"]]
        grouped_suites = {suite for owners in BALANCED_SUITES.values() for suite in owners}
        grouped = (set(self.inventory) - ISOLATED_SUITES - grouped_suites - {"SharedDeliveryUITests"}) | set(BALANCED_SUITES)
        isolated = {f"{suite}-{method.rsplit('/', 1)[1]}"
                    for suite in ISOLATED_SUITES for method in self.inventory[suite]}
        self.assertCountEqual(actual, grouped | isolated | set(DELIVERY_SHARDS))
        self.assertEqual(len(actual), 17)
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
                matrix_shards = {row["shard"] for row in matrix(self.inventory)["include"] if row["profile"] == profile}
                self.assertEqual(set(plan["shards"]), matrix_shards)
                for name, shard in plan["shards"].items():
                    owners = shard["suites"] if "suites" in shard else [shard["suite"]]
                    lines = (output / shard["selector_file"]).read_text().splitlines()
                    if name in DELIVERY_SHARDS:
                        self.assertEqual(owners, ["SharedDeliveryUITests"])
                        self.assertEqual(shard["selector_file"], f"{name}.txt")
                        self.assertEqual(lines, sorted(f"{UI_TARGET}/{owners[0]}/{method}"
                                                       for method in DELIVERY_SHARDS[name]))
                    elif len(owners) == 1 and owners[0] in ISOLATED_SUITES:
                        suite = owners[0]
                        self.assertEqual(len(lines), 1)
                        self.assertIn(lines[0], self.inventory[suite])
                        self.assertEqual(name, f"{suite}-{lines[0].rsplit('/', 1)[1]}")
                    else:
                        self.assertEqual(lines, sorted(method for suite in owners for method in self.inventory[suite]))
                        if name in BALANCED_SUITES:
                            self.assertEqual(owners, list(BALANCED_SUITES[name]))
                    selectors.extend(lines)
                self.assertCountEqual(selectors, enabled)

    def test_records_and_dinner_keep_exact_standalone_names_profiles_and_selectors(self):
        plans = {profile: make_plan(enumeration(self.enabled_for(profile)), profile, self.inventory)
                 for profile in ("contributor", "dinner")}
        records = plans["contributor"]["shards"]["RecordsMediaUITests"]
        self.assertEqual(records["suite"], "RecordsMediaUITests")
        self.assertEqual(records["selector_file"], "RecordsMediaUITests.txt")
        self.assertEqual([identifier.removesuffix("()") for identifier in records["test_identifiers"]],
                         sorted(self.inventory["RecordsMediaUITests"]))
        self.assertNotIn("suites", records)
        self.assertEqual(set(plans["dinner"]["shards"]), {"DinnerDecisionSheetUITests"})
        self.assertEqual(plans["dinner"]["shards"]["DinnerDecisionSheetUITests"]["suite"], "DinnerDecisionSheetUITests")
        self.assertEqual(sum(len(shard["test_identifiers"]) for plan in plans.values()
                             for shard in plan["shards"].values()), 73)
        later_page = f"{UI_TARGET}/RequestDuplicateComparisonUITests/testConfirmedLaterPageDecisionReturnsToSameLeeOutcomeWithoutScrolling"
        return_shard = plans["contributor"]["shards"]["contributor-balanced-01"]["test_identifiers"]
        self.assertEqual([value.removesuffix("()") for value in return_shard].count(later_page), 1)
        large_lunches = f"{UI_TARGET}/HouseholdRequestPackUITests/testLargestTextShowsCompleteProtectedLunchNamesAndDates"
        decision_shard = plans["contributor"]["shards"]["contributor-balanced-03"]["test_identifiers"]
        self.assertIn(large_lunches, [identifier.removesuffix("()") for identifier in decision_shard])
        other_meals = f"{UI_TARGET}/HouseholdRequestPackUITests/testOtherMealsDisclosureHasNamed44PointControlAndLabelTapsPreserveReviewedFacts"
        self.assertEqual([identifier.removesuffix("()") for identifier in decision_shard].count(other_meals), 1)
        cancel_preview = f"{UI_TARGET}/HouseholdRequestPackUITests/testCancelPreviewClearsOverageConsentRetainsEditableDraftAndRequiresFreshReview"
        self.assertEqual([identifier.removesuffix("()") for identifier in decision_shard].count(cancel_preview), 1)
        clarification = f"{UI_TARGET}/HouseholdRequestPackUITests/testClarificationGuidanceAndEmptyQuestionStayReadableAndCancelDoesNotWrite"
        self.assertEqual([identifier.removesuffix("()") for identifier in decision_shard].count(clarification), 1)
        carry = f"{UI_TARGET}/HouseholdRequestPackUITests/testShopperCarriesEarlierRequestOnceAndReviewsCurrentPackPrice"
        carry_shards = [shard for shard in plans["contributor"]["shards"].values()
                       if carry in [value.removesuffix("()") for value in shard["test_identifiers"]]]
        self.assertEqual(len(carry_shards), 1)
        deadline = f"{UI_TARGET}/SharedMealChangeUITests/testShopperReviewsRepeatedClockTimeThenMovesDayWithoutExtendingDeadline"
        shared_edits = plans["contributor"]["shards"]["contributor-balanced-05"]["test_identifiers"]
        self.assertIn(deadline, [value.removesuffix("()") for value in shared_edits])
        first_sign_in = f"{UI_TARGET}/GuardianEnrollmentUITests/testPrivateSettingsFirstSignInContinuesToHouseholdAndBackgroundReturnsToLock"
        self.assertIn(first_sign_in, [value.removesuffix("()") for value in shared_edits])
        fallbacks = plans["contributor"]["shards"]["SharedFallbackUITests"]
        self.assertEqual(fallbacks["suite"], "SharedFallbackUITests")
        self.assertEqual(len(fallbacks["test_identifiers"]), 2)
        paid_case = f"{UI_TARGET}/PaidPickupRecoveryUITests/testNamedSeatCanApplyAcceptedRecipeAndExpiredSeatCanReadSavedCookCopy"
        group = plans["contributor"]["shards"]["contributor-balanced-04"]
        self.assertIn(paid_case, [identifier.removesuffix("()") for identifier in group["test_identifiers"]])
        for name, shard in plans["contributor"]["shards"].items():
            if name != "RecordsMediaUITests":
                self.assertFalse(any("/RecordsMediaUITests/" in identifier for identifier in shard["test_identifiers"]))

    def test_delivery_shards_keep_their_own_named_proofs(self):
        shards = make_plan(enumeration(self.enabled_for("contributor")), "contributor", self.inventory)["shards"]
        counts = {name: len(shard["test_identifiers"]) for name, shard in shards.items()
                  if shard.get("suite") == "SharedDeliveryUITests"}
        self.assertEqual(counts, {"SharedDeliveryUITests-stock-and-purchase": 6,
                                  "SharedDeliveryUITests-recovery-cook-and-closeout": 5})

    def test_delivery_partition_rejects_unassigned_or_stale_methods(self):
        suite = "SharedDeliveryUITests"
        for methods in (self.inventory[suite] | {f"{UI_TARGET}/{suite}/testNewJourney"},
                        self.inventory[suite] - {min(self.inventory[suite])}):
            with self.subTest(methods=methods), self.assertRaisesRegex(ValueError, "Shared delivery groups differ"):
                matrix({**self.inventory, suite: methods})

    def test_delivery_partition_rejects_duplicate_and_empty_assignments(self):
        first = next(iter(DELIVERY_SHARDS.values()))[0]
        for methods in ((), (first,), ("testOther", "testOther")):
            with self.subTest(methods=methods), patch.dict(DELIVERY_SHARDS, {"additional-delivery": methods}):
                with self.assertRaisesRegex(ValueError, "Empty or duplicate shared delivery assignment"):
                    matrix(self.inventory)

    def test_import_recovery_actions_are_required_in_the_existing_balanced_group(self):
        expected = {f"{UI_TARGET}/ImportRecoveryUITests/{method}" for method in (
            "testDiscardKeepsPendingImportUncommittedAndReviewPresented",
            "testRetryPersistsOneImportAndDismissesThroughItsCallback",
        )}
        self.assertEqual(self.inventory["ImportRecoveryUITests"], expected)
        enabled = self.enabled_for("contributor")
        plan = make_plan(enumeration(enabled), "contributor", self.inventory)
        actual = [identifier.removesuffix("()")
                  for identifier in plan["shards"]["contributor-balanced-02"]["test_identifiers"]]
        for identifier in expected:
            self.assertEqual(actual.count(identifier), 1)
            remaining = [case for case in enabled if case != identifier]
            with self.subTest(case=identifier, state="missing"):
                with self.assertRaisesRegex(ValueError, "Compiled fixture tests differ for ImportRecoveryUITests"):
                    make_plan(enumeration(remaining), "contributor", self.inventory)
            with self.subTest(case=identifier, state="disabled"):
                with self.assertRaisesRegex(ValueError, "Fixture tests must not be disabled"):
                    make_plan(enumeration(remaining, [STOREKIT_TEST, identifier]), "contributor", self.inventory)

    def test_new_method_in_balanced_suite_keeps_its_whole_suite_and_all_other_methods(self):
        inventory = {suite: set(methods) for suite, methods in self.inventory.items()}
        suite = "ContributorRequestUITests"
        added = f"{UI_TARGET}/{suite}/testNewJourney"
        inventory[suite].add(added)
        enabled = sorted(method for owner in suites_for("contributor") for method in inventory[owner])
        plan = make_plan(enumeration(enabled), "contributor", inventory)
        owner = next(name for name, owners in BALANCED_SUITES.items() if suite in owners)
        self.assertTrue(inventory[suite].issubset({identifier.removesuffix("()")
                                                for identifier in plan["shards"][owner]["test_identifiers"]}))
        actual = [identifier.removesuffix("()") for shard in plan["shards"].values()
                  for identifier in shard["test_identifiers"]]
        self.assertCountEqual(actual, enabled)
        self.assertEqual(len(actual), len(set(actual)))

    def test_balanced_groups_reject_duplicate_foreign_privacy_or_isolated_owners(self):
        invalid = (
            ({"balanced": ("ContributorRequestUITests", "ContributorRequestUITests")}, "multiple balanced groups"),
            ({"balanced": ("DinnerDecisionSheetUITests",)}, "outside contributor"),
            ({"balanced": ("RecordsMediaUITests",)}, "must remain isolated"),
            ({"balanced": ("SharedDeliveryUITests",)}, "must remain isolated"),
            ({"SharedDeliveryUITests-stock-and-purchase": ("ContributorRequestUITests",)}, "Invalid balanced fixture group"),
            ({"balanced": ("SharedMealIdeaUITests",)}, "must remain isolated"),
            ({"balanced": ("SharedStoreQuoteUITests",)}, "must remain isolated"),
            ({"RecordsMediaUITests": ("ContributorRequestUITests",)}, "Invalid balanced fixture group"),
            ({"balanced": ()}, "Invalid balanced fixture group"),
        )
        for groups, reason in invalid:
            with self.subTest(groups=groups), patch("plan_ios_fixture_tests.BALANCED_SUITES", groups):
                with self.assertRaisesRegex(ValueError, reason):
                    matrix(self.inventory)
                with self.assertRaisesRegex(ValueError, reason):
                    make_plan(enumeration(self.enabled_for("contributor")), "contributor", self.inventory)

    def test_new_isolated_method_is_included_without_dropping_existing_methods(self):
        inventory = {suite: set(methods) for suite, methods in self.inventory.items()}
        suite = "SharedMealIdeaUITests"
        added = f"{UI_TARGET}/{suite}/testNewJourney"
        inventory[suite].add(added)
        enabled = sorted(method for owner in suites_for("contributor") for method in inventory[owner])
        plan = make_plan(enumeration(enabled), "contributor", inventory)
        self.assertEqual(plan["shards"][f"{suite}-testNewJourney"]["test_identifiers"], [added + "()"])
        actual = [identifier.removesuffix("()") for shard in plan["shards"].values()
                  for identifier in shard["test_identifiers"]]
        self.assertCountEqual(actual, enabled)
        self.assertEqual(len(actual), len(set(actual)))
        self.assertIn(f"{suite}-testNewJourney", {row["shard"] for row in matrix(inventory)["include"]})

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

    def test_accepts_only_the_known_methodless_contributor_helper_suite(self):
        enabled = self.enabled_for("contributor")
        helper = {"identifier": LIBRARY_PRIVACY_HELPER}
        source = enumeration(enabled)
        source["values"][0]["enabledTests"].append(helper)
        self.assertEqual(make_plan(source, "contributor", self.inventory),
                         make_plan(enumeration(enabled), "contributor", self.inventory))

        source["values"][0]["enabledTests"].append(helper)
        with self.assertRaisesRegex(ValueError, "Duplicate Xcode test selector"):
            make_plan(source, "contributor", self.inventory)

        for profile, key, identifier in (("dinner", "enabledTests", LIBRARY_PRIVACY_HELPER),
                                         ("contributor", "disabledTests", LIBRARY_PRIVACY_HELPER),
                                         ("contributor", "enabledTests", f"{UI_TARGET}/UnknownUITestCase")):
            with self.subTest(profile=profile, key=key, identifier=identifier):
                source = enumeration(self.enabled_for(profile))
                source["values"][0][key].append({"identifier": identifier})
                with self.assertRaisesRegex(ValueError, f"Invalid Xcode test identifier in {key}"):
                    make_plan(source, profile, self.inventory)

    def test_rejects_a_compiled_method_on_the_helper_even_if_disabled(self):
        enabled = self.enabled_for("contributor")
        method = f"{LIBRARY_PRIVACY_HELPER}/testUnexpected"
        for source in (enumeration([*enabled, method]), enumeration(enabled, [STOREKIT_TEST, method])):
            with self.assertRaisesRegex(ValueError, "fixture helper must not contain test methods"):
                make_plan(source, "contributor", self.inventory)

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
