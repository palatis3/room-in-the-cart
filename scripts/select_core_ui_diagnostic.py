#!/usr/bin/env python3
"""Select one existing dinner journey only after validating the complete core inventory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re

from plan_ios_tests import DURATIONS_PATH, make_plan, selector

CASES = {
    'en': 'RoomInTheCartUITests/FreeJourneyUITests/testFirstPickupCanStartFromDinnersAndReviewAnEditablePattern',
    'es': 'RoomInTheCartUITests/FreeJourneyUITests/testSpanishDinnerIdeaReviewsPacksAndLeavesListEmptyAfterApproval',
}
SHARD = 'core-dinner-diagnostic'


def require_identity(event, candidate, event_sha, checkout_sha):
    if event != 'workflow_dispatch':
        raise ValueError('Core UI diagnostic is manual-only')
    if not isinstance(candidate, str) or re.fullmatch('[0-9a-f]{40}', candidate) is None:
        raise ValueError('An exact lowercase 40-character candidate SHA is required')
    if not candidate == event_sha == checkout_sha:
        raise ValueError('Candidate, selected workflow ref, and checkout SHA must match')


def selected_case(requested, enumeration, manifest, durations):
    if not isinstance(requested, str) or requested not in CASES:
        raise ValueError('Explicitly choose en or es; no default or all selection is accepted')
    full = make_plan(enumeration, durations, ui_shards=10)
    if manifest != full:
        raise ValueError('Retained full plan differs from the validated compiled inventory')
    enabled = [selector(case) for shard in full['shards'].values() for case in shard['test_identifiers']]
    if any(enabled.count(case) != 1 for case in CASES.values()):
        raise ValueError('Both existing dinner journeys must be enabled exactly once in the full core inventory')
    return CASES[requested], len(enabled)


def write_selection(plan_dir, receipt_path, requested, candidate_sha, durations):
    enum_path = plan_dir / 'test-enumeration.json'
    manifest_path = plan_dir / 'manifest.json'
    enum_bytes, manifest_bytes = enum_path.read_bytes(), manifest_path.read_bytes()
    chosen, full_count = selected_case(requested, json.loads(enum_bytes), json.loads(manifest_bytes), durations)
    output = plan_dir / (SHARD + '.txt')
    # Neither full plan nor existing selector files are overwritten.
    if output.exists() or output.is_symlink() or receipt_path.exists() or receipt_path.is_symlink():
        raise ValueError('Diagnostic outputs must be new, not stale or overwritten')
    content = chosen + '\n'
    receipt = {'schema': 1, 'diagnosticOnly': True, 'candidateSHA': candidate_sha, 'case': requested,
               'shard': SHARD, 'expectedCount': 1, 'selector': chosen, 'fullEnabledCount': full_count,
               'enumerationSHA256': hashlib.sha256(enum_bytes).hexdigest(),
               'fullPlanSHA256': hashlib.sha256(manifest_bytes).hexdigest(),
               'selectionSHA256': hashlib.sha256(content.encode()).hexdigest()}
    with output.open('x', encoding='utf-8') as stream:
        stream.write(content)
    with receipt_path.open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(receipt, indent=2) + '\n')
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkout-sha', required=True)
    args = parser.parse_args()
    try:
        require_identity(os.environ.get('GITHUB_EVENT_NAME'), os.environ.get('CANDIDATE_SHA'),
                         os.environ.get('GITHUB_SHA'), args.checkout_sha)
        write_selection(Path('.build/test-plan'), Path('.build/core-ui-diagnostic-selection.json'),
                        os.environ.get('DINNER_CASE'), os.environ['CANDIDATE_SHA'],
                        json.loads(DURATIONS_PATH.read_bytes()))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Core UI diagnostic selection rejected: {error}\n')


if __name__ == '__main__':
    main()
