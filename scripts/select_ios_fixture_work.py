#!/usr/bin/env python3
"""Select an explicit manual fixture group without narrowing PR/release coverage."""
import argparse
import json
import os
from pathlib import Path

from plan_ios_fixture_tests import matrix


def select_work(event, requested_shard, full_matrix):
    rows = full_matrix["include"]
    if not isinstance(requested_shard, str):
        raise ValueError("Fixture shard must be a string")
    if requested_shard:
        if event != "workflow_dispatch":
            raise ValueError("Only an explicit manual dispatch may select a fixture group")
        names = [name.strip(" ") for name in requested_shard.split(",")]
        requested = set(names)
        if "" in requested or len(requested) != len(names):
            raise ValueError("Specify each requested fixture group exactly once")
        selected = [row for row in rows if row["shard"] in requested]
        if len(selected) != len(requested) or {row["shard"] for row in selected} != requested:
            raise ValueError("Unknown or ambiguous fixture group; use exact planner shard names")
    else:
        selected = rows
    if not selected:
        raise ValueError("Fixture selection must not be empty")
    profiles = {row["profile"] for row in selected}
    if not profiles <= {"contributor", "dinner"}:
        raise ValueError("Unknown fixture build profile")
    return {
        "matrix": {"include": selected},
        # Partition existing rows: preserve their original identities and slots.
        "contributor_matrix": {"include": [row for row in selected if row["profile"] == "contributor"]},
        "dinner_matrix": {"include": [row for row in selected if row["profile"] == "dinner"]},
        "build_contributor": "contributor" in profiles,
        "build_dinner": "dinner" in profiles,
        "scope": "targeted diagnostic" if requested_shard else "full fixture suite",
    }


def check_job_results(jobs):
    """An independent profile failure or unexpected skip must fail the suite."""
    plan = jobs["fixture-plan"]
    if plan["result"] != "success":
        raise ValueError("Fixture planning did not succeed")
    for profile in ("contributor", "dinner"):
        selected = plan["outputs"].get(f"build_{profile}")
        if selected not in ("true", "false"):
            raise ValueError(f"Missing selection for {profile}")
        expected = "success" if selected == "true" else "skipped"
        for name in (f"build-{profile}", f"{profile}-tests"):
            if jobs[name]["result"] != expected:
                raise ValueError(f"{name} must be {expected}, got {jobs[name]['result']}")
    if not any(plan["outputs"][f"build_{profile}"] == "true" for profile in ("contributor", "dinner")):
        raise ValueError("No fixture profile was selected")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--check-results", action="store_true")
    args = parser.parse_args()
    try:
        if args.check_results:
            check_job_results(json.loads(os.environ["JOB_RESULTS"]))
            print("Every selected fixture build and test job passed.")
            return
        # matrix() validates the entire source inventory before any filtering.
        full_matrix = matrix(github_mac_only=os.environ.get("RITC_GITHUB_MAC_ONLY") == "true")
        work = select_work(os.environ.get("GITHUB_EVENT_NAME", ""),
                           os.environ.get("REQUESTED_FIXTURE_SHARD", ""), full_matrix)
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f"Cannot select fixture work: {error}\n")
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            for key in ("matrix", "contributor_matrix", "dinner_matrix"):
                output.write(key + "=" + json.dumps(work[key], separators=(",", ":")) + "\n")
            for key in ("build_contributor", "build_dinner"):
                output.write(f"{key}={str(work[key]).lower()}\n")
    print(json.dumps(work, indent=2))


if __name__ == "__main__":
    main()
