#!/usr/bin/env python3
"""Choose manual Dinner diagnostics only after validating the complete compiled inventory."""
import argparse
import json
import os
from pathlib import Path
import shutil

from ci_mac_slots import with_macos_slots, with_bitrise_slots
from plan_ios_tests import ACCESSIBILITY_AUDIT, DURATIONS_PATH, make_plan, selector, write_plan

DINNER = (
    'RoomInTheCartUITests/FreeJourneyUITests/testFirstPickupCanStartFromDinnersAndReviewAnEditablePattern',
    'RoomInTheCartUITests/FreeJourneyUITests/testSpanishDinnerIdeaReviewsPacksAndLeavesListEmptyAfterApproval',
)


def select_work(inventory, durations, event, scope):
    # This validates every enabled/disabled test, including cases outside Dinner.
    full = make_plan(inventory, durations, ui_shards=10)
    if 'ui-11' not in full['shards']:
        raise ValueError(f'The compiled inventory must include the ordinary accessibility audit: {ACCESSIBILITY_AUDIT}')
    if scope == 'full':
        return full, full
    if scope != 'dinner' or event != 'workflow_dispatch':
        raise ValueError('Only an explicit manual dispatch may select the dinner scope')
    identifiers = [identifier for shard in full['shards'].values()
                   for identifier in shard['test_identifiers'] if selector(identifier) in DINNER]
    if {selector(identifier) for identifier in identifiers} != set(DINNER):
        raise ValueError('Both original Dinner journeys must exist in the compiled inventory')
    shards = {'models': full['shards']['models'],
              'ui-01': {'selector_file': 'ui-01.txt', 'test_identifiers': sorted(identifiers)}}
    selected = {**full, 'scope': 'manual dinner diagnostic', 'shards': shards,
                'include': with_macos_slots([
                    {'shard': name, 'expected_count': len(shard['test_identifiers'])}
                    for name, shard in shards.items()], ('shard',))}
    return full, selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan-dir', type=Path, default=Path('.build/test-plan'))
    parser.add_argument('--github-output', type=Path, required=True)
    args = parser.parse_args()
    try:
        scope = os.environ.get('REQUESTED_IOS_SCOPE', 'full')
        full, selected = select_work(
            json.loads((args.plan_dir / 'test-enumeration.json').read_text()),
            json.loads(DURATIONS_PATH.read_text()), os.environ.get('GITHUB_EVENT_NAME', ''),
            scope)
        if json.loads((args.plan_dir / 'manifest.json').read_text()) != full:
            raise ValueError('The discovered full plan changed before scope selection')
        if selected != full:
            retained = args.plan_dir / 'full-plan'
            retained.mkdir()  # Refuse stale evidence or a second selection.
            for path in [args.plan_dir / 'manifest.json', *args.plan_dir.glob('*.txt')]:
                shutil.copyfile(path, retained / path.name)
            for path in args.plan_dir.glob('*.txt'):
                path.unlink()
            write_plan(selected, args.plan_dir)
        # The producer keeps its model work. Preserve all UI rows and balance
        # their existing estimates across A1/A2; GitHub routing remains in YAML.
        consumers = [dict(row) for row in selected['include'] if row['shard'] != 'models']
        seconds = [selected['shards'][row['shard']].get('estimated_seconds',
                   len(selected['shards'][row['shard']]['test_identifiers']) * 300) for row in consumers]
        consumers = with_bitrise_slots(consumers, ('shard',), seconds, first_pool='A2')
        provider = os.environ.get('IOS_PROVIDER', 'github')
        if provider == 'circleci':
            delegated = {'ui-01', 'ui-02', 'ui-03'}
            expected = {f'ui-{i:02}' for i in range(1, 12)}
            if scope != 'full' or {row['shard'] for row in consumers} != expected:
                raise ValueError('CircleCI requires the ten general UI shards and the dedicated accessibility shard')
            consumers = [row for row in consumers if row['shard'] not in delegated]
            print('CircleCI runs ' + ', '.join(sorted(delegated)) + ' from the same full plan.')
        elif provider != 'github':
            raise ValueError(f'Unknown iOS test provider: {provider}')
        model_count = len(selected['shards']['models']['test_identifiers'])
        with args.github_output.open('a', encoding='utf-8') as output:
            print('matrix=' + json.dumps({'include': consumers}), file=output)
            print('model_count=' + str(model_count), file=output)
        print(json.dumps({'scope': selected.get('scope', 'full'),
                          'producer_model_count': model_count, 'include': consumers}))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f'Cannot select core iOS work: {error}\n')


if __name__ == '__main__':
    main()
