"""Protect PR coverage for native source/build inputs.

These workflows deliberately use only literal paths and trailing /** prefixes.
This check does not emulate GitHub's diff generation or its changed-file limit;
the unfiltered pre-release workflow remains required for every release candidate.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
APP_WORKFLOWS = ("ios-deep.yml", "ios-fixtures.yml", "ios-performance.yml")


def pr_patterns(name):
    text = (WORKFLOWS / name).read_text()
    match = re.search(r"^  pull_request:\n    paths:\n((?:      .*\n)+)", text, re.M)
    if not match:
        raise ValueError(f"Review the changed PR trigger format in {name}")
    patterns = []
    for line in match[1].splitlines():
        if line.lstrip().startswith("#"):
            continue
        item = re.fullmatch(r"      - '([^']+)'", line)
        if not item:
            raise ValueError(f"Review the changed path syntax in {name}")
        pattern = item[1]
        literal = pattern[:-3] if pattern.endswith("/**") else pattern
        if any(char in literal for char in "!*?[]+\\"):
            raise ValueError(f"Review the changed glob policy in {name}")
        patterns.append(pattern)
    return patterns


def selects(name, changed_paths):
    return any(path.startswith(pattern[:-2]) if pattern.endswith("/**") else path == pattern
               for path in changed_paths for pattern in pr_patterns(name))


class CITriggerCoverageTests(unittest.TestCase):
    def test_app_source_and_package_changes_select_all_native_regressions(self):
        for workflow in APP_WORKFLOWS:
            for path in ("ios/App/FutureComposition.swift", "ios/Features/Dinners/FutureEditor.swift",
                         "ios/Packages/LocalStore/Sources/LocalStore/FutureStore.swift",
                         "ios/Tests/FutureModelTests.swift", "ios/UITests/FutureJourneyUITests.swift",
                         "ios/Resources/Localizable.xcstrings", "ios/RoomInTheCart.xcodeproj/project.pbxproj"):
                with self.subTest(workflow=workflow, path=path):
                    self.assertTrue(selects(workflow, [path]))

    def test_shared_generation_and_configuration_inputs_select_native_regressions(self):
        for workflow in APP_WORKFLOWS:
            for path in ("shared/contracts/theme.json", "shared/fixtures/checkout.json",
                         "config/public-contact.json", "scripts/generate_xcode_project.py",
                         "scripts/app_configuration.py", "scripts/select_ci_iphone.py",
                         "scripts/check_built_app.py", "scripts/check_ios_test_results.py"):
                with self.subTest(workflow=workflow, path=path):
                    self.assertTrue((ROOT / path).is_file(), path)
                    self.assertTrue(selects(workflow, [path]))

    def test_wire_contract_changes_select_native_integration(self):
        for path in ("shared/contracts/service-v1.d.ts", "service/src/repository.ts",
                     "ios/Packages/HouseholdClient/Package.swift", ".node-version",
                     "scripts/run_ios_native_wire.sh"):
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file(), path)
                self.assertTrue(selects("ios-native-wire.yml", [path]))

    def test_check_changes_select_their_own_workflow(self):
        for workflow in (*APP_WORKFLOWS, "ios-native-wire.yml"):
            with self.subTest(workflow=workflow):
                self.assertTrue(selects(workflow, [f".github/workflows/{workflow}"]))

    def test_docs_only_and_mixed_changes_remain_distinct(self):
        docs = ["README.md", "docs/CURRENT-HANDOFF.md", "docs/evidence/native/new-result.json"]
        for workflow in APP_WORKFLOWS:
            with self.subTest(workflow=workflow):
                self.assertFalse(selects(workflow, docs))
                self.assertTrue(selects(workflow, docs + ["ios/App/FutureComposition.swift"]))

    def test_required_core_security_and_release_entry_points_stay_unfiltered(self):
        for workflow in ("ci.yml", "security.yml"):
            text = (WORKFLOWS / workflow).read_text()
            self.assertIn("\n  pull_request:\n  workflow_dispatch:\n", text)
        for workflow in (*APP_WORKFLOWS, "ios-native-wire.yml"):
            text = (WORKFLOWS / workflow).read_text()
            self.assertIn("\n  workflow_dispatch:\n", text)
            self.assertIn("\n  workflow_call:\n", text)
        release = (WORKFLOWS / "release-checks.yml").read_text()
        for workflow in (*APP_WORKFLOWS, "ios-native-wire.yml"):
            self.assertIn(f"    uses: ./.github/workflows/{workflow}\n", release)


if __name__ == "__main__":
    unittest.main()
