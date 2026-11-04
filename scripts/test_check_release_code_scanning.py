import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from check_release_code_scanning import REQUIRED_CATEGORIES, main, validate


CANDIDATE_REF = "refs/heads/release-candidate"


def analyses():
    return [{"tool": {"name": "CodeQL"}, "category": category, "commit_sha": "candidate",
             "ref": CANDIDATE_REF, "error": "", "id": index, "created_at": "2026-11-04T00:00:00Z"}
            for index, category in enumerate(sorted(REQUIRED_CATEGORIES))]


def alert(*, state="open", candidate_state="open", security="high", severity="error"):
    return {
        "number": 7,
        "state": state,
        "most_recent_instance": {"ref": CANDIDATE_REF, "state": candidate_state},
        "rule": {"security_severity_level": security, "severity": severity},
    }


class ReleaseScanningTests(unittest.TestCase):
    def check(self, scans, alerts=()):
        validate(scans, alerts, "candidate", CANDIDATE_REF)

    def test_requires_every_language_on_exact_candidate_and_ref(self):
        self.check(analyses())
        for key, value in (("commit_sha", "older"), ("ref", "refs/heads/other"), ("tool", {"name": "Other"})):
            scans = analyses()
            scans[0][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "Missing CodeQL"):
                self.check(scans)

    def test_new_failed_analysis_cannot_fall_back_to_an_older_success(self):
        scans = analyses()
        scans.append({**scans[0], "id": 100, "error": "Extraction failed"})
        with self.assertRaisesRegex(ValueError, "analysis errors"):
            self.check(scans)

    def test_open_high_critical_and_nonsecurity_error_findings_block(self):
        for security in ("high", "critical", None):
            with self.subTest(security=security), self.assertRaisesRegex(ValueError, "Serious open"):
                self.check(analyses(), [alert(security=security)])

    def test_default_branch_fix_does_not_hide_open_candidate_finding(self):
        with self.assertRaisesRegex(ValueError, "Serious open"):
            self.check(analyses(), [alert(state="fixed")])

    def test_candidate_branch_fix_passes_even_if_default_branch_is_open(self):
        self.check(analyses(), [alert(candidate_state="fixed")])

    def test_requires_matching_candidate_instance_even_for_dismissed_alert(self):
        for instance in (None, {}, {"ref": "refs/heads/main", "state": "open"}):
            row = alert(state="dismissed")
            row["most_recent_instance"] = instance
            with self.subTest(instance=instance), self.assertRaisesRegex(ValueError, "Missing or mismatched"):
                self.check(analyses(), [row])

    def test_rejects_missing_or_unknown_instance_state(self):
        for state in (None, "unexpected"):
            row = alert(state="fixed", candidate_state=state)
            with self.subTest(state=state), self.assertRaisesRegex(ValueError, "Invalid code-scanning instance state"):
                self.check(analyses(), [row])

    def test_explicit_dismissal_passes(self):
        self.check(analyses(), [alert(state="dismissed"), alert(candidate_state="dismissed")])

    def test_resolved_findings_and_below_policy_security_levels_do_not_block(self):
        self.check(analyses(), [
            alert(candidate_state="fixed"),
            alert(security="medium"),
            alert(security=None, severity="warning"),
        ])

    def test_alert_api_query_uses_candidate_ref_without_top_level_state_filter(self):
        ref = {"object": {"sha": "candidate"}}
        environment = {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_SHA": "candidate", "GITHUB_REF": CANDIDATE_REF}
        with patch.dict("os.environ", environment), patch(
            "check_release_code_scanning.github_json", side_effect=[ref, analyses(), [], ref]
        ) as github_json, patch("builtins.print"):
            main()

        alert_call = github_json.call_args_list[2]
        endpoint = urlsplit(alert_call.args[0])
        self.assertEqual(endpoint.path, "repos/owner/repo/code-scanning/alerts")
        self.assertEqual(parse_qs(endpoint.query), {"ref": [CANDIDATE_REF], "per_page": ["100"]})
        self.assertEqual(alert_call.kwargs, {"pages": True})


if __name__ == "__main__":
    unittest.main()
