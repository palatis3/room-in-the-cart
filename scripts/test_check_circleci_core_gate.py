import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from check_ci_workflows import parse_workflow
from check_circleci_core_gate import CIRCLECI_BOT_ID, CONTEXTS, completed_workflow, main

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = '5c182c81-7749-4e37-87ff-130ed7bbb144'
JOB = 'b3fe4b21-713f-4773-8825-0a5df824cb3c'
TARGET = f'https://app.circleci.com/workflow/{WORKFLOW}/job/{JOB}'


class CircleGateTests(unittest.TestCase):
    def setUp(self):
        self.statuses = [dict(context=name, creator={'id': CIRCLECI_BOT_ID}, state='success',
                              target_url=TARGET) for name in CONTEXTS]
        self.workflow = parse_workflow(ROOT / '.github/workflows/ci.yml')[0]

    def test_accepts_one_complete_workflow_and_requires_latest_status(self):
        self.assertEqual(completed_workflow(self.statuses), WORKFLOW)
        self.assertIsNone(completed_workflow(self.statuses[1:]))
        for state in ('pending', 'failure', 'error', 'cancelled'):
            statuses = [dict(self.statuses[0], state=state), *self.statuses]
            if state == 'pending':
                self.assertIsNone(completed_workflow(statuses))
            else:
                with self.assertRaises(ValueError):
                    completed_workflow(statuses)
        for changed in ({'creator': {'id': 123}}, {'target_url': 'https://example.com/'},
                        {'target_url': TARGET.replace(WORKFLOW, JOB)}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                completed_workflow([dict(self.statuses[0], **changed), *self.statuses])

    def test_reads_all_pages_for_the_immutable_dispatch_sha(self):
        sha = '1' * 40
        with patch.dict(os.environ, GITHUB_SHA=sha), patch('subprocess.check_output',
                return_value=json.dumps([self.statuses[:1], self.statuses[1:]])) as gh:
            main()
        gh.assert_called_once_with(['gh', 'api', '--paginate', '--slurp',
                                    f'repos/palatis3/room-in-the-cart/commits/{sha}/statuses?per_page=100'], text=True)
        with patch.dict(os.environ, GITHUB_SHA='main'), patch('subprocess.check_output') as gh:
            with self.assertRaises(ValueError):
                main()
            gh.assert_not_called()

    def test_provider_selection_requires_a_trusted_exact_candidate(self):
        inputs = self.workflow['on']['workflow_dispatch']['inputs']['ios_provider']
        self.assertEqual(inputs['options'], ['github', 'circleci'])
        self.assertEqual(inputs['default'], 'github')
        self.assertNotIn('ios_provider', self.workflow['on']['workflow_call']['inputs'])
        jobs = self.workflow['jobs']
        route = next(s for s in jobs['source-checks']['steps'] if s.get('id') == 'route')
        self.assertEqual(route['env']['IOS_PROVIDER'], "${{ inputs.ios_provider || 'github' }}")
        canonical = dict(IOS_PROVIDER='circleci', GITHUB_EVENT_NAME='workflow_dispatch',
                         GITHUB_REPOSITORY='palatis3/room-in-the-cart',
                         GITHUB_REF='refs/heads/codex/circleci-performance', IOS_SCOPE='full',
                         RELEASE_METADATA='', RITC_GITHUB_MAC_ONLY='true', GITHUB_SHA='1' * 40,
                         CIRCLECI_PR_HEAD_SHA='', PR_HEAD_SHA='', PR_REPO='')
        pr = dict(IOS_PROVIDER='github', GITHUB_EVENT_NAME='pull_request',
                  PR_REPO=canonical['GITHUB_REPOSITORY'], PR_HEAD_SHA='3' * 40, CIRCLECI_PR_HEAD_SHA='3' * 40)
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'out'
            for changes, expected in [
                ({}, 'circleci'), ({'IOS_PROVIDER': 'github'}, 'github'), ({'IOS_PROVIDER': 'bogus'}, None),
                ({'GITHUB_EVENT_NAME': 'pull_request'}, None), ({'GITHUB_EVENT_NAME': 'workflow_call'}, None),
                ({'GITHUB_EVENT_NAME': 'push'}, None), ({'GITHUB_REPOSITORY': 'someone/fork'}, None),
                ({'GITHUB_REF': 'refs/heads/main'}, None), ({'GITHUB_REF': 'refs/tags/codex/circleci-performance'}, None),
                ({'IOS_SCOPE': 'dinner'}, None), ({'RELEASE_METADATA': 'true'}, None),
                (pr, 'circleci'), ({**pr, 'CIRCLECI_PR_HEAD_SHA': '2' * 40}, 'github'),
                ({**pr, 'CIRCLECI_PR_HEAD_SHA': ''}, 'github'),
                ({**pr, 'CIRCLECI_PR_HEAD_SHA': canonical['GITHUB_SHA']}, 'github'), ({**pr, 'PR_REPO': 'someone/fork'}, 'github'),
                ({**pr, 'GITHUB_EVENT_NAME': 'push'}, 'github'), ({**pr, 'RELEASE_METADATA': 'true'}, 'github'),
                ({**pr, 'GITHUB_EVENT_NAME': 'workflow_dispatch'}, 'github'),
            ]:
                with self.subTest(changes=changes):
                    output.write_text('')
                    result = subprocess.run(['bash', '-e', '-c', route['run']], capture_output=True,
                        env={**os.environ, **canonical, **changes, 'GITHUB_OUTPUT': str(output)})
                    self.assertEqual(result.returncode == 0, expected is not None)
                    self.assertEqual(output.read_text(), f'provider={expected}\n' if expected else '')
        self.assertEqual(jobs['swift-packages']['if'], "needs.source-checks.outputs.ios_provider == 'github'")
        self.assertNotIn('if', jobs['ios-build'])
        self.assertEqual(jobs['ios-tests']['needs'], 'ios-build')
        step = next(s for s in jobs['ios-build']['steps'] if s.get('id') == 'plan')
        self.assertEqual(step['env']['IOS_PROVIDER'], '${{ needs.source-checks.outputs.ios_provider }}')

    def test_split_gate_requires_provider_statuses_and_all_remaining_github_jobs(self):
        gate = self.workflow['jobs']['ci-gate']
        self.assertIn("'CircleCI-assisted CI gate'", gate['name'])
        self.assertEqual(gate['permissions'], {'contents': 'read', 'statuses': 'read'})
        self.assertEqual(gate['steps'][-1]['if'], "needs.source-checks.outputs.ios_provider == 'circleci'")
        self.assertEqual(gate['steps'][-1]['run'], 'python3 scripts/check_circleci_core_gate.py')
        results = {name: {'result': 'success'} for name in gate['needs']}
        results['source-checks']['outputs'] = {'ios_provider': 'circleci'}
        results['ios-build']['outputs'] = {'model_result': 'success'}
        results['swift-packages']['result'] = 'skipped'
        code = gate['steps'][0]['run']
        def gate_status(value):
            return subprocess.run(['bash', '-e', '-c', code], capture_output=True, text=True,
                                  env={**os.environ, 'JOB_RESULTS': json.dumps(value)}).returncode
        self.assertEqual(gate_status(results), 0)
        changed = copy.deepcopy(results)
        changed['ios-build']['outputs']['model_result'] = 'failure'
        self.assertNotEqual(gate_status(changed), 0)
        for name, job in results.items():
            for value in ('failure', 'cancelled', 'skipped' if job['result'] == 'success' else 'success'):
                with self.subTest(name=name, value=value):
                    changed = copy.deepcopy(results)
                    changed[name]['result'] = value
                    self.assertNotEqual(gate_status(changed), 0)


if __name__ == '__main__':
    unittest.main()
