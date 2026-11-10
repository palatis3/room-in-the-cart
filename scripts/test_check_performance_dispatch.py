import copy
import os
from pathlib import Path
import unittest
from unittest.mock import patch
import yaml
from check_performance_dispatch import FLAGS, WORKFLOW, profile


class DispatchProfileTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text())
        self.off = {name: False for name in FLAGS}

    def test_actual_observer_profile_expands_every_guard_and_environment(self):
        options = dict(self.off, fresh_performance_simulator=True, observe_app_scroll_signposts=True)
        script, env, inputs = profile(self.workflow, 'workflow_dispatch', 'scroll', options)
        self.assertNotIn('${{', script)
        self.assertEqual(env['OBSERVE_APP_SCROLL_SIGNPOSTS'], 'true')
        self.assertEqual(env['FRESH_PERFORMANCE_SIMULATOR'], 'true')
        self.assertEqual(env['ENFORCE_BASELINES'], 'false')
        self.assertEqual(env['REQUESTED_PERFORMANCE_CASE'], 'scroll')
        self.assertIn('python3 scripts/test_plan_ios_performance_tests.py', script)
        self.assertIn('python3 scripts/test_app_scroll_observation.py', script)
        self.assertIn('python3 scripts/plan_ios_performance_tests.py --validate-request', script)
        self.assertTrue(inputs['observe_app_scroll_signposts'])

    def test_ordinary_profile_cannot_inherit_ambient_observer(self):
        with patch.dict(os.environ, {'OBSERVE_APP_SCROLL_SIGNPOSTS': 'true', 'FRESH_PERFORMANCE_SIMULATOR': 'true'}):
            _, env, _ = profile(self.workflow, 'workflow_dispatch', 'all', self.off)
        self.assertEqual(env['OBSERVE_APP_SCROLL_SIGNPOSTS'], 'false')
        self.assertEqual(env['FRESH_PERFORMANCE_SIMULATOR'], 'false')
        self.assertEqual(env['REQUESTED_PERFORMANCE_CASE'], '')

    def test_pull_request_keeps_baseline_enforcement(self):
        _, env, _ = profile(self.workflow, 'pull_request', 'all', self.off)
        self.assertEqual(env['ENFORCE_BASELINES'], 'true')

    def test_helper_profile_expands_exact_manual_all_case_without_other_modes(self):
        script, env, inputs = profile(self.workflow, 'workflow_dispatch', 'all',
                                      dict(self.off, simulator_signpost_control=True))
        self.assertEqual(env['SIMULATOR_SIGNPOST_CONTROL'], 'true')
        self.assertEqual(env['GITHUB_EVENT_NAME'], 'workflow_dispatch')
        self.assertEqual(env['REQUESTED_PERFORMANCE_CASE'], '')
        for name in FLAGS:
            if name != 'simulator_signpost_control':
                self.assertFalse(inputs[name])
        self.assertIn('python3 scripts/run_simulator_signpost_control.py validate-request', script)

    def test_new_boolean_cannot_silently_use_its_workflow_default(self):
        trigger = self.workflow.get('on', self.workflow.get(True))
        trigger['workflow_dispatch']['inputs']['unreviewed_mode'] = {'type': 'boolean', 'default': True}
        with self.assertRaisesRegex(ValueError, 'boolean roster changed'):
            profile(self.workflow, 'workflow_dispatch', 'all', self.off)

    def test_unknown_expression_is_review_required(self):
        self.workflow['env']['NEW_SETTING'] = '${{ secrets.UNREVIEWED }}'
        with self.assertRaisesRegex(ValueError, 'Unreviewed'):
            profile(self.workflow, 'workflow_dispatch', 'scroll', self.off)

    def test_no_macos_job_or_hidden_environment_override(self):
        for change in ('runner', 'environment', 'step'):
            with self.subTest(change=change):
                document = copy.deepcopy(self.workflow)
                job = document['jobs']['performance-plan']
                if change == 'runner': job['runs-on'] = 'macos-latest'
                elif change == 'environment': job['env'] = {'EXTRA': 'true'}
                else: job['steps'].append(copy.deepcopy(job['steps'][1]))
                with self.assertRaises(ValueError): profile(document, 'workflow_dispatch', 'scroll', self.off)

    def test_inputs_are_typed_and_choices_are_bounded(self):
        for event, case, options in [('push', 'scroll', self.off), ('workflow_call', 'all', self.off),
                                     ('workflow_dispatch', '$(command)', self.off),
                                     ('workflow_dispatch', 'scroll', dict(self.off, observe_app_scroll_signposts='true'))]:
            with self.subTest(event=event, case=case), self.assertRaises(ValueError):
                profile(self.workflow, event, case, options)


if __name__ == '__main__':
    unittest.main()
