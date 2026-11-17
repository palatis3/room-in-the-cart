#!/usr/bin/env python3
"""Wait for the full CircleCI package, build and test jobs on the dispatched SHA."""
import json
import os
import re
import subprocess
import time


CONTEXTS = tuple(f"ci/circleci: ios-core-{job}" for job in ("packages", "build", "tests"))
# GitHub's numeric identity for the installed circleci-app[bot].
CIRCLECI_BOT_ID = 127350680
UUID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
JOB_URL = re.compile(rf"https://app\.circleci\.com/workflow/({UUID})/job/({UUID})")


def completed_workflow(statuses):
    """GitHub lists statuses newest first. Never accept an older green result."""
    latest = {}
    for status in statuses:
        context = status["context"]
        if context in CONTEXTS:
            latest.setdefault(context, status)
    workflows = set()
    for context, status in latest.items():
        if status["creator"]["id"] != CIRCLECI_BOT_ID:
            raise ValueError(f"Unexpected publisher for {context}")
        target = JOB_URL.fullmatch(status.get("target_url") or "")
        if not target:
            raise ValueError(f"Missing CircleCI job identity for {context}")
        if status["state"] not in ("pending", "success"):
            raise ValueError(f'{context}: {status["state"]} {status["target_url"]}')
        if status["state"] == "success":
            workflows.add(target.group(1))
    if len(latest) == len(CONTEXTS) and all(s["state"] == "success" for s in latest.values()):
        if len(workflows) != 1:
            raise ValueError("The latest CircleCI successes belong to different workflows. Rerun the complete workflow.")
        return workflows.pop()
    waiting = [name for name in CONTEXTS if latest.get(name, {}).get("state") != "success"]
    print("Waiting for " + ", ".join(waiting), flush=True)
    return None


def main():
    sha = os.environ["GITHUB_SHA"]
    if re.fullmatch("[0-9a-f]{40}", sha) is None:
        raise ValueError("Expected the immutable dispatch SHA")
    endpoint = f"repos/palatis3/room-in-the-cart/commits/{sha}/statuses?per_page=100"
    # The Actions step sets the overall deadline and fails if the jobs never report.
    while True:
        response = subprocess.check_output(["gh", "api", "--paginate", "--slurp", endpoint], text=True)
        workflow = completed_workflow(status for page in json.loads(response) for status in page)
        if workflow:
            print(f"Verified {sha}: https://app.circleci.com/workflow/{workflow}")
            return
        time.sleep(30)


if __name__ == "__main__":
    main()
