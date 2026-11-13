import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_qualification_receipt import ROOT, MERGE_GATES, digest, template, validate

SHA = 'a' * 40


class QualificationReceiptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.receipt = {'schema_version': 1, 'candidate_sha': SHA, 'scope': 'focused',
            'purpose': 'Qualify the exact reviewed change', 'source_changes': ['ios/Example.swift'],
            'release_execution_plan': self.save('release-plan.md', 'Separate live and physical requirements'),
            'runs': [], 'originals': []}

    def save(self, name, value):
        path = self.root / name
        path.write_text(value if isinstance(value, str) else json.dumps(value))
        return {'path': name, 'sha256': digest(path)}

    def add_run(self, names=('Dinner diagnostic gate',), coverage='focused', run_id=1, event='workflow_dispatch', workflow='Build and test'):
        run = {'id': run_id, 'attempt': 2, 'sha': SHA, 'event': event, 'workflow': workflow,
               'status': 'completed', 'conclusion': 'success', 'job_count': len(names),
               'jobs': [{'id': index + 100 * run_id, 'name': name, 'status': 'completed', 'conclusion': 'success'} for index, name in enumerate(names)]}
        entry = {'run_id': run_id, 'attempt': 2, 'coverage': coverage, 'question': 'Did the reviewed change pass?',
                 'change_since_prior_attempt': 'First qualification of this revision',
                 'feedback': self.save(f'feedback-{run_id}.json', {'runs': [run]}),
                 'checkout_proof': self.save(f'checkout-{run_id}.json', {'run_id': run_id, 'attempt': 2, 'head_sha': SHA, 'tested_sha': SHA,
                     'provenance': self.save(f'provenance-{run_id}.txt', f'Fixture build provenance for {SHA}, run {run_id}, attempt 2')})}
        self.receipt['runs'].append(entry)
        original = self.save(f'original-{run_id}.txt', f'Retained original bytes for run {run_id}')
        self.receipt['originals'].append({'run_id': run_id, 'attempt': 2, 'retrieved_copy': original,
            'immutable_uri': f'https://archive.example.test/sha256/{original["sha256"]}',
            'retention': 'project-lifetime', 'custodian': 'Project owner', 'retrieval_verified_at': '2026-11-09T10:00:00Z'})
        return run, entry

    def update_run(self, run, entry):
        entry['feedback'] = self.save(f'feedback-{run["id"]}.json', {'runs': [run]})

    def test_focused_pass_never_satisfies_merge_or_release(self):
        self.add_run()
        self.assertTrue(validate(self.receipt, self.root)['checklist_complete'])
        for scope in ('merge', 'automated_release'):
            self.receipt['scope'] = scope
            report = validate(self.receipt, self.root)
            self.assertFalse(report['checklist_complete'])
            self.assertTrue(any('Missing successful' in item for item in report['pending']))

    def test_merge_preserves_pr_head_and_tested_merge_sha_as_distinct_identities(self):
        self.receipt['scope'] = 'merge'
        run, entry = self.add_run(sorted(MERGE_GATES), 'merge', event='pull_request')
        run['sha'] = 'b' * 40; self.update_run(run, entry)
        entry['checkout_proof'] = self.save('checkout-1.json', {'run_id': 1, 'attempt': 2, 'head_sha': run['sha'], 'tested_sha': SHA,
            'provenance': self.save('provenance-1.txt', f'Fixture merge checkout {SHA} from head {run["sha"]}')})
        result = validate(self.receipt, self.root)
        self.assertTrue(result['checklist_complete'])
        self.assertIn('Not live branch-protection approval', ' '.join(result['limits']))
        run['event'] = 'workflow_dispatch'; self.update_run(run, entry)
        with self.assertRaisesRegex(ValueError, 'Non-PR run head'):
            validate(self.receipt, self.root)

    def test_release_requires_existing_full_gate_and_workflow(self):
        self.receipt['scope'] = 'automated_release'
        run, entry = self.add_run(['Automated release gate'], 'automated_release', workflow='Pre-release regression checks')
        self.assertTrue(validate(self.receipt, self.root)['checklist_complete'])
        run['workflow'] = 'Focused replacement'; self.update_run(run, entry)
        with self.assertRaisesRegex(ValueError, 'existing full release workflow'):
            validate(self.receipt, self.root)

    def test_missing_duplicate_and_mismatched_evidence_fail_closed(self):
        run, entry = self.add_run()
        mutations = [lambda r: r.update(candidate_sha='b' * 40),
                     lambda r: r['runs'].append(copy.deepcopy(r['runs'][0])),
                     lambda r: r['runs'][0].update(attempt=3),
                     lambda r: r['runs'][0]['feedback'].update(sha256='0' * 64),
                     lambda r: r['runs'][0]['checkout_proof'].update(path='missing'),
                     lambda r: r['runs'][0].update(change_since_prior_attempt=''),
                     lambda r: r['originals'][0].update(run_id=999),
                     lambda r: r['originals'].append(copy.deepcopy(r['originals'][0]))]
        for mutate in mutations:
            receipt = copy.deepcopy(self.receipt); mutate(receipt)
            with self.subTest(receipt=receipt), self.assertRaises(ValueError):
                validate(receipt, self.root)
        for altered in [dict(run, job_count=2), dict(run, jobs=run['jobs'] * 2, job_count=2)]:
            self.update_run(altered, entry)
            with self.assertRaises(ValueError):
                validate(self.receipt, self.root)

    def test_failed_active_or_inconsistent_success_is_incomplete(self):
        run, entry = self.add_run()
        for status, conclusion, job_status in [('completed', 'failure', 'completed'), ('in_progress', None, 'in_progress'), ('completed', 'success', 'in_progress')]:
            run.update(status=status, conclusion=conclusion)
            run['jobs'][0]['status'] = job_status; self.update_run(run, entry)
            self.assertFalse(validate(self.receipt, self.root)['checklist_complete'])

    def test_expiring_or_unverified_original_cannot_be_only_durable_record(self):
        self.add_run()
        for change in [{'immutable_uri': 'https://github.com/o/r/actions/runs/1/artifacts/2'},
                       {'retention': '7-days'}, {'custodian': ''}, {'retrieval_verified_at': '2026-11-09'},
                       {'retrieved_copy': {'path': 'original-1.txt', 'sha256': '0' * 64}}]:
            receipt = copy.deepcopy(self.receipt); receipt['originals'][0].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate(receipt, self.root)
        self.receipt['originals'] = []
        self.assertFalse(validate(self.receipt, self.root)['checklist_complete'])

    def test_prior_failure_reference_must_still_match_original_bytes(self):
        _, entry = self.add_run()
        entry['prior_attempts'] = [self.save('first-failure.txt', 'original failure')]
        self.assertTrue(validate(self.receipt, self.root)['checklist_complete'])
        (self.root / 'first-failure.txt').write_text('overwritten pass')
        with self.assertRaisesRegex(ValueError, 'Missing or changed evidence'):
            validate(self.receipt, self.root)

    def test_private_local_original_needs_no_upload_but_is_not_independent_archival(self):
        self.add_run()
        archive = self.root / 'original-1.txt'
        for location in (str(archive), archive.as_uri()):
            self.receipt['originals'][0]['immutable_uri'] = location
            result = validate(self.receipt, self.root)
            self.assertTrue(result['checklist_complete'])
            self.assertIn('local-only', result['original_storage'][0]['storage'])
        self.receipt['originals'][0]['immutable_uri'] = str(self.root / 'absent')
        with self.assertRaisesRegex(ValueError, 'Local original is missing'):
            validate(self.receipt, self.root)

    def test_source_provenance_and_unfilled_placeholders_cannot_be_overlooked(self):
        self.add_run()
        self.receipt['purpose'] = 'REPLACE: qualification question'
        self.assertFalse(validate(self.receipt, self.root)['checklist_complete'])
        self.receipt['purpose'] = 'Reviewed question'
        (self.root / 'provenance-1.txt').write_text('Changed source provenance')
        with self.assertRaisesRegex(ValueError, 'Missing or changed evidence'):
            validate(self.receipt, self.root)

    def test_optional_timings_preserve_combined_and_unmapped_work(self):
        _, entry = self.add_run()
        steps = [{'name': name, 'status': 'completed', 'conclusion': 'success',
                  'started_at': '2026-11-09T10:00:00Z', 'completed_at': '2026-11-09T10:00:10Z'}
                 for name in ('Build products', 'Run and verify tests', 'Unknown overhead')]
        jobs = {'total_count': 1, 'jobs': [{'id': 100, 'run_id': 1, 'run_attempt': 2, 'steps': steps}]}
        entry['timing'] = {'jobs': self.save('jobs.json', jobs),
                           'phase_steps': {'build': ['Build products'], 'test_and_validation': ['Run and verify tests']}}
        timing = validate(self.receipt, self.root)['runs'][0]['timing']
        self.assertEqual(timing['measured_whole_step_seconds']['test_and_validation'], 10)
        self.assertEqual(timing['measured_whole_step_seconds']['unmapped'], 10)
        self.assertEqual(timing['unmapped_steps'], ['Unknown overhead'])
        entry['timing']['phase_steps']['setup'] = ['Build products']
        with self.assertRaisesRegex(ValueError, 'Duplicate or invalid phase'):
            validate(self.receipt, self.root)
        entry['timing']['phase_steps'].pop('setup')
        jobs['jobs'][0]['run_attempt'] = 3; entry['timing']['jobs'] = self.save('jobs.json', jobs)
        with self.assertRaisesRegex(ValueError, 'another run/attempt'):
            validate(self.receipt, self.root)

    def test_real_cli_template_fails_incomplete_without_network_or_native_work(self):
        path = self.root / 'incomplete.json'; path.write_text(json.dumps(template(SHA)))
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/check_qualification_receipt.py'), '--receipt', str(path)],
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report['checklist_complete'])
        for name in MERGE_GATES:
            self.assertIn('Missing successful ' + name, report['pending'])


if __name__ == '__main__':
    unittest.main()
