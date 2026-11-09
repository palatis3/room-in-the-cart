#!/usr/bin/env python3
"""Read a preserved, checkpointed fictional ledger snapshot; never query a device."""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import sqlite3
import time
from uuid import UUID


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def identifier(value):
    require(isinstance(value, str) and str(UUID(value)).upper() == value, 'UUID identity')
    return value


def unique(rows):
    result = {identifier(row['id']): row for row in rows}
    require(len(result) == len(rows), 'duplicate identities')
    return result


def quantity(row, amount):
    q = row['quantity']
    require(q['unit'] == 'count' and q['amount'] == {'numerator': amount, 'denominator': 1}, 'quantity')


def verify_documents(before, after, binding, workspace_id):
    require(set(binding) == {'schema', 'sequenceFinished', 'removedOccurrenceID', 'survivingOccurrenceID', 'manualLineID'}
            and binding['schema'] == 1 and binding['sequenceFinished'] is True, 'UI binding')
    target_id = identifier(binding['removedOccurrenceID']); other_id = identifier(binding['survivingOccurrenceID'])
    line_id = identifier(binding['manualLineID']); identifier(workspace_id)
    require(before['formatVersion'] == after['formatVersion'] == 1, 'document version')
    b = before['workspace']; a = after['workspace']
    require(len(b['shops']) == len(a['shops']) == 1, 'one isolated shop')
    shop = b['shops'][0]; changed = a['shops'][0]
    require(shop['id'] == changed['id'] == b['selectedShopID'] == a['selectedShopID']
            and shop['title'] == 'Family pickup', 'shop identity')
    meals = unique(shop['mealOccurrences']); require(set(meals) == {target_id, other_id}, 'two original dinners')
    require(meals[target_id]['title'] == 'Tuesday tacos' and meals[other_id]['title'] == 'Wednesday quesadillas', 'fixture meal identity')
    require(all(m.get('removedAt') is None for m in meals.values()), 'original active meals')
    require(len(meals[target_id]['ingredientContributionIDs']) == len(meals[other_id]['ingredientContributionIDs']) == 1, 'one need each')
    target_need = meals[target_id]['ingredientContributionIDs'][0]; other_need = meals[other_id]['ingredientContributionIDs'][0]
    sources = unique(shop['contributions']); require(len(sources) == 4, 'four original sources')
    manuals = [s for s in sources.values() if s['source'] == {'manual': {}}]
    lunches = [s for s in sources.values() if s['source'] == {'protectedNeed': {'purpose': 'Lunch'}}]
    require(len(manuals) == len(lunches) == 1, 'manual and protected source')
    manual = manuals[0]; lunch = lunches[0]
    require(set(sources) == {manual['id'], lunch['id'], target_need, other_need}, 'source identities')
    for source, amount in [(manual, 12), (sources[target_need], 6), (sources[other_need], 4), (lunch, 2)]:
        quantity(source, amount)
        require(source['lineID'] == line_id and source.get('removedAt') is None, 'shared live line')
    require(sources[target_need]['source'] == {'meal': {'occurrenceID': target_id}}
            and sources[other_need]['source'] == {'meal': {'occurrenceID': other_id}}, 'meal provenance')
    lines = unique(shop['lines']); require(len(lines) == 4 and line_id in lines and lines[line_id].get('trashedAt') is None, 'manual line identity')
    require(all(row.get('trashedAt') is not None for key, row in lines.items() if key != line_id), 'three prior linked-away tombstones')
    edges = unique(shop['allocations']); require(len(edges) == 3, 'three original reservations')
    for need, amount in [(target_need, 6), (other_need, 4), (lunch['id'], 2)]:
        matches = [e for e in edges.values() if e['demandContributionID'] == need]
        require(len(matches) == 1 and matches[0]['supplyContributionID'] == manual['id'] and matches[0]['kind'] == 'withinExisting', 'reservation identity')
        quantity(matches[0], amount)
    state = b['dinnerPlanning']; next_state = a['dinnerPlanning']
    require(state['applyReceipts'] == [] and len(next_state['applyReceipts']) == 1, 'one applied decision')
    receipt = next_state['applyReceipts'][0]; proposal = receipt['proposal']; operation = identifier(proposal['id'])
    when = receipt['appliedAt']; require(type(when) in (int, float) and math.isfinite(when), 'tombstone time')
    require(proposal['shopID'] == shop['id'] and proposal['baseRevisionID'] == shop['revisionID']
            and proposal['basisRevision'] == shop['basisRevision'] and proposal['planningRevisionID'] == state['revisionID']
            and proposal['changes'] == [{'remove': {'occurrenceID': target_id}}]
            and proposal['tool'] == 'manual' and proposal['isIsolatedPreview'] is False
            and proposal['namespace'] == 'local:' + workspace_id
            and receipt['appliedBy'] == proposal['authorID'] and bool(receipt['appliedBy'])
            and receipt['revisionID'] == proposal['proposedRevisionID'] == changed['revisionID'], 'reviewed removal receipt')
    identifier(changed['revisionID']); identifier(next_state['revisionID'])
    require(changed['revisionID'] != shop['revisionID'] and next_state['revisionID'] != state['revisionID'], 'fresh revisions')
    expected = copy.deepcopy(before); es = expected['workspace']['shops'][0]
    es['revision'] += 1; es['revisionID'] = changed['revisionID']
    es['revisions'].append({'id': changed['revisionID'], 'parentID': shop['revisionID'], 'number': es['revision'],
        'basisRevision': shop['basisRevision'], 'createdAt': when, 'operation': 'dinner:' + operation})
    for meal in es['mealOccurrences']:
        if meal['id'] == target_id: meal['removedAt'] = when
    for source in es['contributions']:
        if source['id'] == target_need: source['removedAt'] = when
    es['allocations'] = [edge for edge in es['allocations'] if edge['demandContributionID'] != target_need]
    expected['workspace']['dinnerPlanning']['revisionID'] = next_state['revisionID']
    expected['workspace']['dinnerPlanning']['applyReceipts'] = [receipt]
    # Whole-document equality deliberately catches unrelated old tombstone changes,
    # renumbered allocations, hidden quantity changes and other workspace edits.
    require(after == expected, 'unexpected persisted change outside target removal and its receipt/revisions')
    return {'removedOccurrenceID': target_id, 'survivingOccurrenceID': other_id, 'manualLineID': line_id,
            'survivingContributionIDs': sorted([manual['id'], other_need, lunch['id']]),
            'survivingAllocationIDs': sorted(e['id'] for e in edges.values() if e['demandContributionID'] != target_need),
            'manualUnits': 12, 'protectedLunchUnits': 2, 'otherMealUnits': 4, 'priorTombstonesUnchanged': True}


def decode(raw):
    def pairs(values):
        d = {}
        for key, value in values:
            require(key not in d, 'duplicate JSON key'); d[key] = value
        return d
    def bad_number(_):
        raise ValueError('nonfinite JSON')
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=bad_number)


def inspect(store, binding_path):
    require(store.is_file() and not store.is_symlink() and 0 < store.stat().st_size <= 32 * 1024 * 1024, 'snapshot size/type')
    require(not any(Path(str(store) + s).exists() for s in ['-wal', '-shm', '-journal']), 'checkpointed standalone copy required')
    require(binding_path.is_file() and not binding_path.is_symlink() and binding_path.stat().st_size <= 4096, 'binding size/type')
    before_hash = hashlib.sha256(store.read_bytes()).hexdigest(); raw_binding = binding_path.read_bytes()
    binding = decode(raw_binding); deadline = time.monotonic() + 30
    with sqlite3.connect(store.resolve().as_uri() + '?mode=ro&immutable=1', uri=True, timeout=1) as db:
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
        require(db.execute('PRAGMA quick_check').fetchall() == [('ok',)], 'SQLite integrity')
        workspace = db.execute('SELECT id, head_revision FROM ledger_workspace WHERE singleton=1').fetchall()
        require(len(workspace) == 1 and workspace[0][1] == 2, 'exact head revision two')
        identity = workspace[0][0]
        shapes = db.execute('SELECT workspace_id,revision,base_revision,length(payload) FROM ledger_revisions ORDER BY revision').fetchall()
        require(len(shapes) == 2 and all(w == identity and r == i + 1 and base == i and 0 < size <= 4*1024*1024
                for i, (w,r,base,size) in enumerate(shapes)), 'only seed and explicit removal saved')
        rows = db.execute('SELECT payload,payload_sha256,operation_id FROM ledger_revisions ORDER BY revision').fetchall()
        require(rows[0][2] != rows[1][2], 'distinct operation receipts')
        for payload, digest, operation in rows:
            identifier(operation); require(hashlib.sha256(payload).digest() == digest, 'payload checksum')
    result = verify_documents(decode(rows[0][0]), decode(rows[1][0]), binding, identity)
    require(hashlib.sha256(store.read_bytes()).hexdigest() == before_hash, 'snapshot changed')
    return {'status': 'passed', 'schema': 1, 'storeSHA256': before_hash,
        'uiBindingSHA256': hashlib.sha256(raw_binding).hexdigest(), 'savedRevisions': [1,2],
        'payloadSHA256': [hashlib.sha256(r[0]).hexdigest() for r in rows], **result,
        'scope': 'Preserved fictional SQLite plus native final binding; combine with exact-source strict native result. No device query.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store', type=Path, required=True); parser.add_argument('--ui-binding', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.store,args.ui_binding), indent=2))
    except (OSError, ValueError, TypeError, KeyError, IndexError, sqlite3.Error):
        parser.exit(1, 'Source-removal persisted readback failed; preserve inputs for scoped review.\n')
