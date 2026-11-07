from datetime import date
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from check_node_runtime import INDEX_URL, NETWORK_TIMEOUT_SECONDS, check_release, fetch_json, read_pin


TODAY = date(2026, 11, 4)
PIN = (22, 23, 4)
SCHEDULE = {"v22": {"start": "2024-04-24", "end": "2027-04-30"}}
INDEX = [
    {"version": "v22.24.0", "security": False},
    {"version": "v22.14.0", "security": True},
    {"version": "v22.25.0-rc.1", "security": True},
    {"version": "v24.40.0", "security": True},
    {"version": "v22.23.4", "security": True},
]


class NodeRuntimeReleaseTests(unittest.TestCase):
    def test_security_floor_allows_a_later_published_non_security_release(self):
        for version in (PIN, (22, 24, 0)):
            with self.subTest(version=version):
                self.assertEqual(check_release(version, INDEX, SCHEDULE, TODAY),
                                 ("22.23.4", date(2027, 4, 30)))

    def test_rejects_a_stale_security_release(self):
        with self.assertRaisesRegex(ValueError, "below the security floor 22.23.4"):
            check_release((22, 14, 0), INDEX, SCHEDULE, TODAY)

    def test_rejects_end_of_life_and_unreleased_schedule(self):
        with self.assertRaisesRegex(ValueError, "end of life"):
            check_release(PIN, INDEX, SCHEDULE, date(2027, 4, 30))
        with self.assertRaisesRegex(ValueError, "not yet supported"):
            check_release(PIN, INDEX, SCHEDULE, date(2024, 4, 23))

    def test_rejects_missing_or_invalid_schedule(self):
        with self.assertRaisesRegex(ValueError, "missing v22"):
            check_release(PIN, INDEX, {}, TODAY)
        for entry in ({"start": "2024-04-24"}, {"start": "2024-04-24", "end": "TBD"}):
            with self.subTest(entry=entry), self.assertRaisesRegex(ValueError, "invalid dates"):
                check_release(PIN, INDEX, {"v22": entry}, TODAY)

    def test_rejects_unpublished_pin_even_above_the_floor(self):
        with self.assertRaisesRegex(ValueError, "not a published stable release"):
            check_release((22, 24, 1), INDEX, SCHEDULE, TODAY)

    def test_rejects_missing_or_malformed_security_metadata(self):
        for index, message in (
            ([], "index is missing"),
            ([{"version": "v22.23.4", "security": False}], "does not establish a security floor"),
            (INDEX + [{"version": "v22.25.0"}], "invalid version or security data"),
            (INDEX + [{"version": "v22.25.0", "security": "true"}], "invalid version or security data"),
            (INDEX + [{"version": "22.25.0", "security": True}], "invalid version or security data"),
        ):
            with self.subTest(index=index), self.assertRaisesRegex(ValueError, message):
                check_release(PIN, index, SCHEDULE, TODAY)

    @patch("check_node_runtime.urlopen", side_effect=TimeoutError("timed out"))
    def test_unavailable_metadata_fails_with_an_explicit_timeout(self, request):
        with self.assertRaisesRegex(ValueError, "Cannot read official Node metadata"):
            fetch_json(INDEX_URL)
        request.assert_called_once_with(INDEX_URL, timeout=NETWORK_TIMEOUT_SECONDS)


class NodeEngineTests(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / ".node-version").write_text("22.23.4\n")
        for project in ("service", "web"):
            (self.root / project).mkdir()
            self.write_engine(project, "package.json", ">=22.23.4 <23")
            self.write_engine(project, "package-lock.json", ">=22.23.4 <23")

    def write_engine(self, project, filename, engine):
        package = {"engines": {"node": engine}}
        document = package if filename == "package.json" else {"packages": {"": package}}
        (self.root / project / filename).write_text(json.dumps(document))

    def test_pin_and_both_root_engine_constraints_match(self):
        self.assertEqual(read_pin(self.root), PIN)

    def test_rejects_unpinned_or_prerelease_versions(self):
        for pin in ("22", "22.x", "v22.23.4", "22.23.4-rc.1", "22.023.4"):
            with self.subTest(pin=pin), self.assertRaisesRegex(ValueError, "exact stable version"):
                (self.root / ".node-version").write_text(pin)
                read_pin(self.root)

    def test_rejects_each_project_root_engine_minimum_and_cap_mismatch(self):
        for project in ("service", "web"):
            for filename in ("package.json", "package-lock.json"):
                for engine in (">=22.14.0 <23", ">=22.23.4 <24"):
                    with self.subTest(project=project, filename=filename, engine=engine):
                        self.write_engine(project, filename, engine)
                        with self.assertRaisesRegex(ValueError, "root Node engine must be"):
                            read_pin(self.root)
                        self.write_engine(project, filename, ">=22.23.4 <23")


if __name__ == "__main__":
    unittest.main()
