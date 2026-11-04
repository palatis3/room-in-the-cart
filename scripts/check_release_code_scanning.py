#!/usr/bin/env python3
"""Require current CodeQL coverage and reject serious open release findings."""
import json
import os
import subprocess
from urllib.parse import urlencode

REQUIRED_CATEGORIES = {"/language:swift", "/language:javascript-typescript", "/language:actions"}


def validate(analyses, alerts, commit, ref):
    latest = {}
    for analysis in sorted(analyses, key=lambda item: (item.get("created_at", ""), item.get("id", 0)), reverse=True):
        if (analysis.get("tool", {}).get("name") == "CodeQL"
                and analysis.get("commit_sha") == commit and analysis.get("ref") == ref):
            latest.setdefault(analysis.get("category"), analysis)
    missing = REQUIRED_CATEGORIES - latest.keys()
    if missing:
        raise ValueError(f"Missing CodeQL analysis for this exact candidate: {sorted(missing)}")
    errors = {category: latest[category]["error"] for category in REQUIRED_CATEGORIES if latest[category].get("error")}
    if errors:
        raise ValueError(f"CodeQL analysis errors: {errors}")
    serious = []
    for alert in alerts:
        identifier = alert.get("html_url") or str(alert["number"])
        instance = alert.get("most_recent_instance")
        if not isinstance(instance, dict) or instance.get("ref") != ref:
            raise ValueError(f"Missing or mismatched code-scanning instance for alert {identifier} on {ref}")
        state = instance.get("state")
        if state not in ("open", "fixed", "dismissed"):
            raise ValueError(f"Invalid code-scanning instance state for alert {identifier}: {state!r}")
        # A dismissal applies across branches. The instance supplies the branch's fix state.
        if alert.get("state") == "dismissed" or state != "open":
            continue
        rule = alert["rule"]
        security = rule.get("security_severity_level")
        # GitHub uses security severity in preference to ordinary rule severity.
        if security in {"high", "critical"} or (not security and rule.get("severity") == "error"):
            serious.append(identifier)
    if serious:
        raise ValueError("Serious open code-scanning findings: " + ", ".join(serious))


def github_json(endpoint, pages=False):
    command = ["gh", "api", endpoint]
    if pages:
        command.extend(["--paginate", "--slurp"])
    result = subprocess.run(command, check=True, text=True, capture_output=True)
    data = json.loads(result.stdout)
    return [item for page in data for item in page] if pages else data


def main():
    repository = os.environ["GITHUB_REPOSITORY"]
    commit = os.environ["GITHUB_SHA"]
    ref = os.environ["GITHUB_REF"]
    if not ref.startswith("refs/heads/"):
        raise SystemExit("Select the release candidate branch for pre-release regression checks.")
    prefix = f"repos/{repository}"
    current = github_json(f"{prefix}/git/ref/{ref.removeprefix('refs/')}")
    if current["object"]["sha"] != commit:
        raise SystemExit("The candidate branch moved during testing. Run the checks on its current commit.")
    analyses = github_json(f"{prefix}/code-scanning/analyses?" + urlencode({"ref": ref, "per_page": 100}), pages=True)
    alerts = github_json(f"{prefix}/code-scanning/alerts?" + urlencode({"ref": ref, "per_page": 100}), pages=True)
    validate(analyses, alerts, commit, ref)
    current = github_json(f"{prefix}/git/ref/{ref.removeprefix('refs/')}")
    if current["object"]["sha"] != commit:
        raise SystemExit("The candidate branch moved while security results were checked.")
    print(f"All three CodeQL languages cover {commit}; no serious open findings.")


if __name__ == "__main__":
    main()
