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
        selected = [row for row in rows if row["shard"] == requested_shard]
        if len(selected) != 1:
            raise ValueError("Unknown or ambiguous fixture group; use the exact planner shard name")
    else:
        selected = rows
    if not selected:
        raise ValueError("Fixture selection must not be empty")
    profiles = {row["profile"] for row in selected}
    if not profiles <= {"contributor", "dinner"}:
        raise ValueError("Unknown fixture build profile")
    return {
        "matrix": {"include": selected},
        "build_contributor": "contributor" in profiles,
        "build_dinner": "dinner" in profiles,
        "scope": "targeted diagnostic" if requested_shard else "full fixture suite",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        # matrix() validates the entire source inventory before any filtering.
        work = select_work(os.environ.get("GITHUB_EVENT_NAME", ""),
                           os.environ.get("REQUESTED_FIXTURE_SHARD", ""), matrix())
    except (ValueError, OSError) as error:
        parser.exit(1, f"Cannot select fixture work: {error}\n")
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write("matrix=" + json.dumps(work["matrix"], separators=(",", ":")) + "\n")
            for key in ("build_contributor", "build_dinner"):
                output.write(f"{key}={str(work[key]).lower()}\n")
    print(json.dumps(work, indent=2))


if __name__ == "__main__":
    main()
