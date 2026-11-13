#!/usr/bin/env python3
"""Reject known performance incompatibility before the full release native fan-out."""
import argparse
import json
from pathlib import Path

from check_ci_workflows import parse_workflow
from check_ios_performance_environment import configured_environment, require_compatible_baseline

ROOT = Path(__file__).resolve().parents[1]


def validate(root=ROOT):
    # Read the existing workflow pins rather than maintaining a second toolchain.
    workflow = parse_workflow(root / '.github/workflows/ios-performance.yml')[0]
    environment = configured_environment(workflow['env'], 'arm64')
    baseline = json.loads((root / 'scripts/ios_performance_baselines.json').read_text())
    count = require_compatible_baseline(baseline, environment)
    return {'environment': environment, 'compatibleProfiles': count,
            'releaseAcceptance': False,
            'note': 'Configured compatibility only. Actual runner identity, complete metrics and approved limits remain required.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    try:
        print(json.dumps(validate()))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f'Release performance preflight failed: {error}\n')


if __name__ == '__main__':
    main()
