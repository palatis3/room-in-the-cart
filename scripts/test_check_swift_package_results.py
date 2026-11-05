#!/usr/bin/env python3
import contextlib
import io
from pathlib import Path
import tempfile
import unittest

from check_swift_package_results import EXPECTED_SKIPS, PACKAGES, verify_package, verify_results


TEST = "CoreDomainTests.ExampleTests/testOne"
OTHER = "CoreDomainTests.ExampleTests/testTwo"


def event(selector, status):
    suite, test = selector.split("/")
    suffix = "started." if status == "started" else f"{status} (0.003 seconds)."
    return f"Test Case '-[{suite} {test}]' {suffix}\n"


def completed(selector, status="passed"):
    return event(selector, "started") + event(selector, status)


class SwiftPackageResultTests(unittest.TestCase):
    def test_exact_pass_and_reviewed_wire_skips(self):
        self.assertEqual(verify_package("CoreDomain", [TEST], [TEST], completed(TEST)), (1, 0))
        wire = sorted(EXPECTED_SKIPS["HouseholdClient"])
        regular = "HouseholdClientTests.ExampleTests/testOne"
        reviewed = [regular, *wire]
        log = completed(regular) + "".join(completed(name, "skipped") for name in wire)
        self.assertEqual(verify_package("HouseholdClient", reviewed, list(reversed(reviewed)), log), (1, 3))

    def test_removed_or_added_compiled_case_requires_inventory_review(self):
        for reviewed, compiled in (([TEST, OTHER], [TEST]), ([TEST], [TEST, OTHER])):
            with self.subTest(compiled=compiled), self.assertRaisesRegex(ValueError, "Compiled tests differ"):
                verify_package("CoreDomain", reviewed, compiled, completed(TEST))

    def test_discovered_case_missing_from_run_or_without_terminal_fails(self):
        for log, error in ((completed(TEST), "execution differs"),
                           (completed(TEST) + event(OTHER, "started"), "terminal outcomes differ")):
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                verify_package("CoreDomain", [TEST, OTHER], [TEST, OTHER], log)

    def test_duplicate_unmatched_or_unrecognized_events_fail(self):
        for log, error in (
            (completed(TEST) * 2, "Duplicate XCTest start"),
            (completed(TEST) + event(TEST, "passed"), "unmatched XCTest outcome"),
            (event(TEST, "passed"), "unmatched XCTest outcome"),
            (completed(TEST).replace("passed", "unknown"), "Unrecognized XCTest event"),
        ):
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                verify_package("CoreDomain", [TEST], [TEST], log)

    def test_unapproved_skip_and_missing_approved_skip_fail(self):
        with self.assertRaisesRegex(ValueError, "skips differ"):
            verify_package("CoreDomain", [TEST], [TEST], completed(TEST, "skipped"))
        wire = sorted(EXPECTED_SKIPS["HouseholdClient"])
        log = completed(wire[0]) + "".join(completed(name, "skipped") for name in wire[1:])
        with self.assertRaisesRegex(ValueError, "skips differ"):
            verify_package("HouseholdClient", wire, wire, log)

    def test_failure_or_same_count_wrong_selector_fails(self):
        with self.assertRaisesRegex(ValueError, "Failed XCTest cases"):
            verify_package("CoreDomain", [TEST], [TEST], completed(TEST, "failed"))
        with self.assertRaisesRegex(ValueError, "execution differs"):
            verify_package("CoreDomain", [TEST], [TEST], completed(OTHER))

    def test_empty_duplicate_or_unsupported_compiled_inventory_fails(self):
        for compiled in ([], [TEST, TEST], ["CoreDomainTests.ExampleSuite/testOne()"]):
            with self.subTest(compiled=compiled), self.assertRaisesRegex(ValueError, "Compiled inventory"):
                verify_package("CoreDomain", [TEST], compiled, completed(TEST))

    def test_missing_package_manifest_inventory_or_log_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            packages, results = root / "Packages", root / "results"
            results.mkdir()
            reviewed = {}
            for package in PACKAGES:
                package_path = packages / package
                package_path.mkdir(parents=True)
                (package_path / "Package.swift").touch()
                skips = sorted(EXPECTED_SKIPS.get(package, set()))
                ordinary = f"{package}Tests.ExampleTests/testOne"
                reviewed[package] = [ordinary, *skips]
                (results / f"{package}.inventory.txt").write_text("\n".join(reviewed[package]) + "\n")
                (results / f"{package}.log").write_text(
                    completed(ordinary) + "".join(completed(name, "skipped") for name in skips)
                )
            with contextlib.redirect_stdout(io.StringIO()):
                verify_results(results, packages, reviewed)
            for path, error in (
                (packages / "CoreDomain" / "Package.swift", "Swift packages differ"),
                (results / "CoreDomain.inventory.txt", "Compiled inventories differ"),
                (results / "CoreDomain.log", "Swift package logs differ"),
            ):
                original = path.read_bytes()
                path.unlink()
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, error):
                    verify_results(results, packages, reviewed)
                path.write_bytes(original)


if __name__ == "__main__":
    unittest.main()
