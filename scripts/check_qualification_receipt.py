#!/usr/bin/env python3
"""Validate an offline exact-revision evidence checklist; never authorize merge or release."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
MERGE_GATES = {'CI gate', 'CodeQL (javascript-typescript)', 'CodeQL (actions)', 'Dependency review'}
PHASES = {'setup', 'build', 'test_and_validation', 'collection'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def evidence(ref, root):
    require(isinstance(ref, dict) and isinstance(ref.get('path'), str) and ref['path'], 'Missing evidence path')
    require(isinstance(ref.get('sha256'), str) and re.fullmatch('[0-9a-f]{64}', ref['sha256']), 'Missing exact evidence SHA256')
    path = root / ref['path']
    require(path.is_file() and digest(path) == ref['sha256'], f'Missing or changed evidence: {ref["path"]}')
    return path


def timing_summary(spec, root, run):
    raw = json.loads(evidence(spec['jobs'], root).read_text())
    jobs = raw['jobs']
    require(raw['total_count'] == len(jobs) and len({j['id'] for j in jobs}) == len(jobs), 'Incomplete or duplicate timing jobs')
    mapping = spec['phase_steps']
    require(set(mapping) <= PHASES and all(isinstance(names, list) for names in mapping.values()), 'Invalid timing phases')
    labels = [name for names in mapping.values() for name in names]
    require(all(isinstance(name, str) and name for name in labels) and len(labels) == len(set(labels)), 'Duplicate or invalid phase step assignment')
    phase_for = {name: phase for phase, names in mapping.items() for name in names}
    totals = {phase: 0 for phase in [*sorted(PHASES), 'unmapped']}
    seen, untimed, unmapped = set(), [], set()
    for job in jobs:
        require(job['run_id'] == run['id'] and job['run_attempt'] == run['attempt'], 'Timing jobs belong to another run/attempt')
        for step in job.get('steps', []):
            if step.get('conclusion') == 'skipped':
                continue
            name = step['name']; seen.add(name)
            if step.get('status') != 'completed' or not step.get('started_at') or not step.get('completed_at'):
                untimed.append(name)
                continue
            elapsed = (datetime.fromisoformat(step['completed_at'].replace('Z', '+00:00')) -
                       datetime.fromisoformat(step['started_at'].replace('Z', '+00:00'))).total_seconds()
            require(elapsed >= 0, 'Negative step duration')
            phase = phase_for.get(name, 'unmapped'); totals[phase] += elapsed
            if phase == 'unmapped':
                unmapped.add(name)
    require(set(labels) <= seen, 'A mapped timing step is absent from the retained jobs')
    return {'measured_whole_step_seconds': totals, 'unmapped_steps': sorted(unmapped), 'untimed_steps': untimed,
            'limits': 'Step sums may overlap across jobs; not wall time, runner-minutes or pure XCTest time. Combined steps remain combined.'}


def validate(receipt, root=ROOT):
    require(receipt['schema_version'] == 1 and type(receipt['schema_version']) is int, 'Unsupported receipt schema')
    sha, scope = receipt['candidate_sha'], receipt['scope']
    require(isinstance(sha, str) and re.fullmatch('[0-9a-f]{40}', sha), 'Candidate must be a full immutable SHA')
    require(scope in ('focused', 'merge', 'automated_release'), 'Unknown qualification scope')
    require(isinstance(receipt['purpose'], str) and receipt['purpose'].strip(), 'State the qualification question')
    require(isinstance(receipt['source_changes'], list) and receipt['source_changes'] and
            all(isinstance(path, str) and path.strip() for path in receipt['source_changes']), 'List source changes separately from evidence')
    evidence(receipt['release_execution_plan'], root)
    rows, gates, identities, pending = [], set(), set(), []
    if receipt['purpose'].startswith('REPLACE:') or any(path.startswith('REPLACE:') for path in receipt['source_changes']):
        pending.append('Replace template purpose/source-change placeholders')
    require(isinstance(receipt['runs'], list), 'Runs must be a list')
    for entry in receipt['runs']:
        require(entry['coverage'] in ('focused', 'merge', 'automated_release'), 'Unknown run coverage')
        require(all(isinstance(entry.get(key), str) and entry[key].strip()
                    for key in ('question', 'change_since_prior_attempt')), 'Record the question and change or first-attempt rationale')
        feedback = json.loads(evidence(entry['feedback'], root).read_text())
        matches = [run for run in feedback['runs'] if run['id'] == entry['run_id'] and run['attempt'] == entry['attempt']]
        require(len(matches) == 1, 'Run/attempt missing or duplicated in feedback')
        run = matches[0]; identity = (run['id'], run['attempt'])
        require(identity not in identities, 'Duplicate run/attempt in checklist'); identities.add(identity)
        proof = json.loads(evidence(entry['checkout_proof'], root).read_text())
        require(set(proof) == {'run_id', 'attempt', 'head_sha', 'tested_sha', 'provenance'} and
                {key: value for key, value in proof.items() if key != 'provenance'} ==
                {'run_id': run['id'], 'attempt': run['attempt'], 'head_sha': run['sha'], 'tested_sha': sha},
                'Checkout proof does not bind this run/attempt/head to the candidate')
        evidence(proof['provenance'], root)
        require(run['event'] == 'pull_request' or run['sha'] == sha, 'Non-PR run head differs from candidate')
        jobs = run['jobs']
        require(run['job_count'] == len(jobs) and len({job['id'] for job in jobs}) == len(jobs), 'Incomplete or duplicated feedback jobs')
        success = {job['name'] for job in jobs if job['status'] == 'completed' and job.get('conclusion') == 'success'}
        named_gates = [j['name'] for j in jobs if j['name'] in MERGE_GATES | {'Automated release gate', 'Dinner diagnostic gate'}]
        require(len(named_gates) == len(set(named_gates)), 'Ambiguous duplicate gate name')
        complete = (run['status'] == 'completed' and run.get('conclusion') == 'success' and bool(jobs)
                    and bool(success) and all(j['status'] == 'completed' and j.get('conclusion') in ('success', 'skipped') for j in jobs))
        if not complete:
            pending.append(f'Run {run["id"]} attempt {run["attempt"]} is not successful and terminal')
        if entry['coverage'] == 'merge':
            require(run['event'] == 'pull_request', 'Merge evidence must be a PR run, including dependency review')
            require('Dinner diagnostic gate' not in {j['name'] for j in jobs}, 'Focused Dinner run cannot be merge evidence')
            if complete:
                gates.update(success & MERGE_GATES)
        elif entry['coverage'] == 'automated_release':
            require(run['workflow'] == 'Pre-release regression checks', 'Release evidence must use the existing full release workflow')
            if complete and 'Automated release gate' in success:
                gates.add('Automated release gate')
        for prior in entry.get('prior_attempts', []):
            evidence(prior, root)  # Retain first-failure evidence; never overwrite it with a later pass.
        row = {'id': run['id'], 'attempt': run['attempt'], 'coverage': entry['coverage'], 'successful': complete}
        if 'timing' in entry:
            row['timing'] = timing_summary(entry['timing'], root, run)
        rows.append(row)
    if not rows:
        pending.append('No run evidence recorded')
    required = MERGE_GATES if scope == 'merge' else {'Automated release gate'} if scope == 'automated_release' else set()
    pending.extend(f'Missing successful {gate}' for gate in sorted(required - gates))
    originals = receipt['originals']
    require(isinstance(originals, list), 'Original references must be a list')
    seen_originals, archived_runs, storage = set(), set(), []
    for original in originals:
        evidence(original['retrieved_copy'], root)
        identity = (original['run_id'], original['attempt'])
        require(identity in identities, 'Original is not linked to a contributing run/attempt')
        archived_runs.add(identity)
        checksum = original['retrieved_copy']['sha256']
        require(checksum not in seen_originals, 'Duplicate original digest'); seen_originals.add(checksum)
        location = original['immutable_uri']; uri = urlparse(location)
        if Path(location).is_absolute() or uri.scheme == 'file':
            require(Path(location).is_absolute() or (uri.netloc in ('', 'localhost') and not uri.query and not uri.fragment),
                    'Local archive must use an absolute local path or file URI')
            archive = Path(location) if Path(location).is_absolute() else Path(unquote(uri.path))
            require(archive.is_absolute() and archive.is_file() and digest(archive) == checksum, 'Local original is missing or changed')
            storage_kind = 'local-only; archive bytes checked, independent archival not established'
        else:
            require(uri.scheme == 'https' and uri.netloc and not uri.query and not uri.fragment, 'Use an absolute local archive or immutable HTTPS location')
            require('/actions/' not in uri.path and (checksum in uri.path or
                    re.search(r'/blob/[0-9a-f]{40}/', uri.path)), 'Remote original must be digest-addressed or a committed blob, not an expiring Actions artifact')
            storage_kind = 'remote reference attested; only retrieved local bytes checked, no independent fetch'
        storage.append({'run_id': identity[0], 'attempt': identity[1], 'storage': storage_kind})
        require(original['retention'] == 'project-lifetime' and original['custodian'].strip(), 'Record project-lifetime retention and its custodian')
        checked = datetime.fromisoformat(original['retrieval_verified_at'].replace('Z', '+00:00'))
        require(checked.tzinfo is not None, 'Retrieval verification requires a timezone')
    if not originals:
        pending.append('No durable hash-bound original recorded')
    pending.extend(f'No durable original for run {run_id} attempt {attempt}' for run_id, attempt in sorted(identities - archived_runs))
    return {'candidate_sha': sha, 'scope': scope, 'checklist_complete': not pending, 'pending': pending, 'runs': rows, 'original_storage': storage,
            'limits': ['Offline receipt consistency only; checkout/retention attestations are not independently fetched.',
                       'Not live branch-protection approval, merge authorization or distribution acceptance.',
                       'Focused runs cannot satisfy merge or automated release scope. Follow the linked release execution plan.']}


def template(sha):
    plan = ROOT / 'docs/RELEASE-EXECUTION.md'
    return {'schema_version': 1, 'candidate_sha': sha, 'scope': 'merge', 'purpose': 'REPLACE: qualification question',
            'source_changes': ['REPLACE: source paths or immutable change-map reference'],
            'release_execution_plan': {'path': 'docs/RELEASE-EXECUTION.md', 'sha256': digest(plan)},
            'runs': [], 'originals': []}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--init', metavar='FULL_SHA', help='print an incomplete receipt template')
    action.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    try:
        if args.init:
            require(re.fullmatch('[0-9a-f]{40}', args.init), 'Use a full immutable SHA')
            print(json.dumps(template(args.init), indent=2)); return 0
        report = validate(json.loads(args.receipt.read_text()))
        print(json.dumps(report, indent=2)); return 0 if report['checklist_complete'] else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f'Invalid qualification receipt: {error}\n')


if __name__ == '__main__':
    raise SystemExit(main())
