import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from check_ci_workflows import MATRIX_GROUP, POLICY, QUEUE_ERROR, lint_workflows, parse_workflow, validate_workflows

ROOT = Path(__file__).resolve().parents[1]
TEXT = '''name: Safe fixture
on: workflow_dispatch
concurrency:
  group: original-pr-${{ github.ref }}
  cancel-in-progress: true
jobs:
  native:
    runs-on: macos-15
    concurrency:
      group: ritc-macos-slot-0
      queue: max
      cancel-in-progress: false
    steps:
      - run: echo fixture
'''
POLICY_FIXTURE = {('probe.yml', 'native'): 0}


class WorkflowGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'probe.yml'
        self.path.write_text(TEXT)

    def validate(self, text, policy=POLICY_FIXTURE):
        self.path.write_text(text)
        return validate_workflows([self.path], policy)

    def test_current_inventory_and_existing_workflow_supersession(self):
        positions = validate_workflows(sorted((ROOT / '.github/workflows').glob('*.yml')))
        self.assertEqual(len(positions), len(POLICY))
        self.assertEqual(len(positions), 14)
        data, _, _ = parse_workflow(self.path)
        self.assertIn('on', data)
        self.assertEqual(data['concurrency'], {'group': 'original-pr-${{ github.ref }}', 'cancel-in-progress': True})

    def test_duplicate_yaml_at_any_depth(self):
        for text in (TEXT.replace('name: Safe fixture', 'name: Safe fixture\nname: shadow'),
                     TEXT.replace('      queue: max', '      queue: max\n      queue: single'),
                     TEXT.replace('      - run: echo fixture', '      - run: echo fixture\n        run: hidden')):
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, 'Duplicate YAML key'):
                self.validate(text)

    def test_safe_yaml_rejects_tags_cycles_and_merges(self):
        for addition in ('bad: !!python/object/apply:os.system [echo unsafe]\n', 'bad: &cycle [*cycle]\n',
                         'bad: {<<: {hidden: value}}\n'):
            with self.subTest(addition=addition), self.assertRaises(ValueError):
                self.validate(addition + TEXT)

    def test_queue_and_cancellation_must_be_safe_literals(self):
        for queue in ('single', 'false', 'null', '[max]', '${{ github.ref }}'):
            with self.subTest(queue=queue), self.assertRaises(ValueError):
                self.validate(TEXT.replace('queue: max', 'queue: ' + queue))
        for cancel in ('true', '"false"', 'no', '0', '${{ false }}', 'False'):
            with self.subTest(cancel=cancel), self.assertRaises(ValueError):
                self.validate(TEXT.replace('      cancel-in-progress: false', '      cancel-in-progress: ' + cancel))
        with self.assertRaises(ValueError):
            self.validate(TEXT.replace('      queue: max\n', ''))

    def test_global_groups_cannot_be_partitioned(self):
        for group in ('ritc-macos-slot-5', 'ritc-macos-slot--1', 'ritc-macos-slot-${{ github.workflow }}-0',
                      'ritc-macos-slot-${{ github.ref }}-0', 'ritc-macos-slot-${{ github.run_attempt }}-0',
                      'ritc-macos-26-slot-0'):
            with self.subTest(group=group), self.assertRaises(ValueError):
                self.validate(TEXT.replace('ritc-macos-slot-0', group))

    def test_slots_cannot_be_owned_by_workflow_caller_or_linux_job(self):
        for text in (TEXT.replace('original-pr-${{ github.ref }}', 'ritc-macos-slot-0'),
                     TEXT.replace('  cancel-in-progress: true\n', '  cancel-in-progress: true\n  queue: max\n'),
                     TEXT.replace('runs-on: macos-15', 'runs-on: ubuntu-24.04'),
                     TEXT.replace('runs-on: macos-15', 'uses: ./.github/workflows/ci.yml')):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.validate(text)

    def test_nonleaf_namespace_is_case_insensitive_and_computed_prefixes_are_proven_disjoint(self):
        groups = ('RITC-MACOS-SLOT-0', 'RiTc-MaCoS-sLoT-4',
                  "${{ 'ritc-macos-' }}slot-0", "${{ format('ritc-macos-slot-{0}', 0) }}",
                  "ritc-${{ 'macos-slot-0' }}", "RITC-MACOS-SLO${{ 't-0' }}")
        for group in groups:
            for scope in ('root-mapping', 'root-string', 'linux', 'caller'):
                with self.subTest(group=group, scope=scope), self.assertRaises(ValueError):
                    if scope == 'root-mapping':
                        text = TEXT.replace('original-pr-${{ github.ref }}', group)
                    elif scope == 'root-string':
                        text = TEXT.replace('concurrency:\n  group: original-pr-${{ github.ref }}\n  cancel-in-progress: true',
                                            'concurrency: ' + group)
                    else:
                        runner = 'runs-on: ubuntu-24.04' if scope == 'linux' else 'uses: ./.github/workflows/ci.yml'
                        text = TEXT + '  other:\n    ' + runner + '\n    concurrency:\n      group: ' + group + '\n'
                    self.validate(text)
        for group in ('CORE-CI-${{ github.ref }}', 'ritc-linux-${{ github.ref }}', 'independent-group'):
            with self.subTest(safe_group=group):
                self.assertEqual(len(self.validate(TEXT.replace('original-pr-${{ github.ref }}', group))), 1)
                self.assertEqual(len(self.validate(TEXT + '  other:\n    runs-on: ubuntu-24.04\n    concurrency: ' +
                                                   group + '\n    steps: [{run: echo fixture}]\n')), 1)

    def test_native_inventory_cannot_add_drop_or_hide_an_unguarded_job(self):
        for text in (TEXT + '  new-native:\n    runs-on: macos-15\n    steps: [{run: echo new}]\n',
                     TEXT.replace('runs-on: macos-15', 'runs-on: ${{ matrix.runner }}'),
                     TEXT[:TEXT.index('jobs:')] + 'jobs: {}\n',
                     TEXT.replace('    concurrency:\n      group: ritc-macos-slot-0\n      queue: max\n      cancel-in-progress: false\n', '')):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.validate(text)

    def test_aliases_cannot_relocate_queue_source_validation(self):
        for text in ('value: &queue max\n' + TEXT.replace('queue: max', 'queue: *queue'),
                     'value: &config {group: ritc-macos-slot-0, queue: max, cancel-in-progress: false}\n' +
                     TEXT.replace('    concurrency:\n      group: ritc-macos-slot-0\n      queue: max\n      cancel-in-progress: false',
                                  '    concurrency: *config')):
            with self.assertRaises(ValueError):
                self.validate(text)

    def test_static_matrix_validates_identity_order_and_integer_slot(self):
        text = TEXT.replace('ritc-macos-slot-0', MATRIX_GROUP).replace('    steps:',
            '    strategy:\n      matrix:\n        include:\n          - locale: en\n            macos_slot: 2\n          - locale: es\n            macos_slot: 3\n    steps:')
        policy = {('probe.yml', 'native'): ([('en', 2), ('es', 3)], 'locale')}
        self.assertEqual(len(self.validate(text, policy)), 1)
        for changed in (text.replace('macos_slot: 2', 'macos_slot: true'), text.replace('macos_slot: 2', 'macos_slot: 5'),
                        text.replace('locale: es', 'locale: en'), text.replace('locale: en', 'locale: es')):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                self.validate(changed, policy)

    def test_dynamic_matrix_requires_exact_reviewed_producer(self):
        expression = '${{ fromJSON(needs.build.outputs.matrix) }}'
        text = TEXT.replace('ritc-macos-slot-0', MATRIX_GROUP).replace('    steps:',
            '    strategy:\n      matrix: ' + expression + '\n    steps:')
        policy = {('probe.yml', 'native'): (expression, ('shard',))}
        self.assertEqual(len(self.validate(text, policy)), 1)
        with self.assertRaises(ValueError):
            self.validate(text.replace('needs.build.outputs', 'needs.other.outputs'), policy)


class ActionlintBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'probe.yml'
        self.path.write_text(TEXT)
        self.allowed = validate_workflows([self.path], POLICY_FIXTURE)
        pos, = self.allowed
        self.diagnostic = {'filepath': str(self.path), 'line': pos[1], 'column': pos[2],
                           'end_column': pos[2] + 5, 'kind': 'syntax-check', 'message': QUEUE_ERROR}

    def invoke(self, diagnostics, exit_code=1, stderr=''):
        outputs = [subprocess.CompletedProcess([], 0, '1.7.12\n', ''),
                   subprocess.CompletedProcess([], exit_code, json.dumps(diagnostics), stderr)]
        with patch('check_ci_workflows.subprocess.run', side_effect=outputs) as run:
            report = lint_workflows([self.path], Path('/pinned/actionlint'), POLICY_FIXTURE)
            self.assertEqual(run.call_count, 2)
            self.assertEqual(run.call_args.args[0], ['/pinned/actionlint', '-no-color', '-shellcheck=', '-pyflakes=',
                                                   '-format', '{{json .}}', str(self.path)])
            return report

    def test_only_exact_validated_queue_diagnostic_is_exempted(self):
        report = self.invoke([self.diagnostic])
        self.assertTrue(report['passed'], report)
        self.assertEqual(report['exemptedQueueDiagnostics'], [self.diagnostic])

    def test_unrelated_actionlint_error_remains_fatal(self):
        unrelated = {**self.diagnostic, 'kind': 'expression', 'message': 'undefined variable needs.missing'}
        report = self.invoke([self.diagnostic, unrelated])
        self.assertFalse(report['passed'])
        self.assertEqual(report['unexpectedDiagnostics'], [unrelated])
        self.assertEqual(len(report['actionlintDiagnostics']), 2)

    def test_message_kind_position_extent_or_file_mismatch_cannot_be_exempted(self):
        for key, value in [('message', QUEUE_ERROR + ' changed'), ('kind', 'expression'),
                           ('line', self.diagnostic['line'] + 1), ('column', self.diagnostic['column'] + 1),
                           ('end_column', self.diagnostic['end_column'] + 1), ('filepath', '/different/probe.yml')]:
            with self.subTest(key=key):
                report = self.invoke([{**self.diagnostic, key: value}])
                self.assertFalse(report['passed'])
                self.assertTrue(report['validationErrors'])

    def test_duplicate_or_missing_expected_queue_diagnostic_fails(self):
        self.assertFalse(self.invoke([self.diagnostic, self.diagnostic])['passed'])
        self.assertFalse(self.invoke([], exit_code=0)['passed'])

    def test_invalid_yaml_policy_still_runs_full_actionlint(self):
        self.path.write_text(TEXT.replace('queue: max', 'queue: single'))
        report = self.invoke([self.diagnostic])
        self.assertFalse(report['passed'])
        self.assertTrue(report['validationErrors'])
        self.assertEqual(report['exemptedQueueDiagnostics'], [])
        self.assertEqual(report['unexpectedDiagnostics'], [self.diagnostic])

    def test_bad_process_exit_or_stderr_cannot_be_hidden(self):
        self.assertFalse(self.invoke([self.diagnostic], exit_code=2)['passed'])
        self.assertFalse(self.invoke([self.diagnostic], exit_code=0)['passed'])
        self.assertFalse(self.invoke([self.diagnostic], stderr='fatal: tool failed')['passed'])


if __name__ == '__main__':
    unittest.main()
