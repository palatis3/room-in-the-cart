import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from check_ci_workflows import (A1_LABEL, A2_LABEL, A2_RUNNER, CORE_BUILD_JOB, RELEASE_BUILD_JOB,
                                STOREKIT_JOB, PRODUCER_JOBS, FIXTURE_CONSUMER_RUNNER, FIXTURE_RUNNER, ROUTED_NATIVE_JOBS,
                                POLICY, QUEUE_ERROR, bitrise_group, lint_workflows, parse_workflow, validate_workflows)

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
QUEUE_BLOCK = """    concurrency:
      group: ritc-macos-slot-0
      queue: max
      cancel-in-progress: false
"""
GITHUB_TEXT = TEXT.replace(QUEUE_BLOCK, '')
GITHUB_POLICY = {('probe.yml', 'native'): None}
FIXTURE_JOB = ('ios-fixtures.yml', 'build-contributor')
FIXTURE_GROUP = bitrise_group(FIXTURE_JOB, 'provider')
FIXTURE_TEXT = TEXT.replace('  native:', '  build-contributor:').replace(
    'runs-on: macos-15', 'runs-on: ' + FIXTURE_RUNNER).replace('ritc-macos-slot-0', FIXTURE_GROUP)
FIXTURE_POLICY = {FIXTURE_JOB: 'provider'}


class WorkflowGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'probe.yml'
        self.path.write_text(GITHUB_TEXT)

    def validate(self, text, policy=GITHUB_POLICY):
        self.path.write_text(text)
        return validate_workflows([self.path], policy)

    def test_current_inventory_and_existing_workflow_supersession(self):
        positions = validate_workflows(sorted((ROOT / '.github/workflows').glob('*.yml')))
        self.assertEqual({(value['workflow'], value['job']) for value in positions.values()}, ROUTED_NATIVE_JOBS)
        self.assertEqual(len(positions), 9)
        self.assertEqual(len(POLICY), 18)
        data, _, _ = parse_workflow(self.path)
        self.assertIn('on', data)
        self.assertEqual(data['concurrency'], {'group': 'original-pr-${{ github.ref }}', 'cancel-in-progress': True})

    def test_provider_routes_keep_fallback_jobs_independent(self):
        def evaluate(expression, context):
            for token, replacement in context.items():
                expression = expression.replace(token, repr(replacement))
            expression = expression.removeprefix('${{ ').removesuffix(' }}').replace('&&', 'and').replace('||', 'or')
            return eval(expression, {'__builtins__': {}}, {'format': str.format})

        canonical = 'palatis3/room-in-the-cart'
        fixture = ('ios-fixtures.yml', 'contributor-tests')
        core = ('ci.yml', 'ios-tests')
        fixed_groups = {identity: f'ritc-bitrise-producer-{identity[0][:-4]}-{identity[1]}-1635-2'
                        for identity in PRODUCER_JOBS}
        fixed_groups[STOREKIT_JOB] = 'ritc-bitrise-a2-slot-2'
        # Exercise canonical PRs, forks, outage mode, and every allowed/denied event.
        cases = [(canonical, event, canonical, '') for event in
                 ('push', 'schedule', 'workflow_dispatch', 'workflow_call', 'pull_request')]
        cases += [(canonical, 'pull_request', 'outside/fork', ''),
                  ('outside/fork', 'push', canonical, ''),
                  (canonical, 'pull_request', canonical, 'true')]
        cases += [(canonical, event, canonical, '') for event in ('pull_request_target', 'repository_dispatch', '')]
        for i, (repository, event, head, github_only) in enumerate(cases):
            for provider in ('github', 'bitrise-A1', 'bitrise-A2', 'bitrise', 'bitrise-m4', 'unknown', 'bitrise-runner-more ci'):
                with self.subTest(repository=repository, event=event, head=head, github_only=github_only, provider=provider):
                    context = {'github.event.pull_request.head.repo.full_name': head, 'github.event_name': event,
                               'vars.RITC_GITHUB_MAC_ONLY': github_only, 'github.repository': repository,
                               'github.run_id': 1635, 'github.run_attempt': 2, 'matrix.locale': 'es',
                               'matrix.provider': provider, 'matrix.macos_slot': 2, 'matrix.pool_slot': 0,
                               'matrix.profile': 'contributor', 'matrix.shard': 'ui-03'}
                    trusted = i < 5
                    self.assertEqual(evaluate(FIXTURE_RUNNER, context), A1_LABEL if trusted else 'xcode-27')
                    self.assertEqual(evaluate(A2_RUNNER, context), A2_LABEL if trusted else 'xcode-27')
                    runner = {'bitrise-A1': A1_LABEL, 'bitrise-A2': A2_LABEL}.get(provider, 'xcode-27')
                    self.assertEqual(evaluate(FIXTURE_CONSUMER_RUNNER, context), runner if trusted else 'xcode-27')
                    groups = {}
                    for identity in ROUTED_NATIVE_JOBS:
                        expression = bitrise_group(identity, POLICY[identity])
                        group = evaluate(expression, context)
                        groups[identity] = group
                        native = fixed_groups.get(identity)
                        if not native and identity != core:
                            native = {'bitrise-A1': 'ritc-bitrise-a1-slot-0', 'bitrise-A2': 'ritc-bitrise-a2-slot-0'}.get(provider)
                        if trusted and native:
                            self.assertEqual(group, native)
                            continue
                        workflow, job = identity
                        suffix = '-es' if identity == STOREKIT_JOB else (
                            '-ui-03' if identity == core else '-contributor-ui-03' if identity not in fixed_groups else '')
                        self.assertEqual(group, f'ritc-github-job-{workflow[:-4]}-{job}-1635-2{suffix}')
                        changes = {'github.run_id': 1636, 'github.run_attempt': 3}
                        if identity == STOREKIT_JOB:
                            changes['matrix.locale'] = 'en'
                        if identity in (core, fixture, ('ios-fixtures.yml', 'dinner-tests')):
                            changes['matrix.shard'] = 'ui-04'
                        for key, value in changes.items():
                            self.assertNotEqual(evaluate(expression, {**context, key: value}), group)
                    fallbacks = [value.casefold() for value in groups.values() if value.startswith('ritc-github-job-')]
                    self.assertEqual(len(fallbacks), len(set(fallbacks)))

    def test_swift_packages_keeps_the_source_gate_and_coverage_artifacts(self):
        workflow, _, _ = parse_workflow(ROOT / '.github/workflows/ci.yml')
        job = workflow['jobs']['swift-packages']
        self.assertEqual(job['needs'], 'source-checks')
        self.assertEqual(job['if'], "needs.source-checks.outputs.ios_provider == 'github'")
        self.assertEqual(job['runs-on'], FIXTURE_RUNNER)
        test = next(step for step in job['steps'] if '--enable-code-coverage' in step.get('run', ''))
        self.assertIn('ios/Packages/*/Package.swift', test['run'])
        self.assertIn('list --skip-build', test['run'])
        self.assertIn('scripts/check_swift_package_results.py', test['run'])
        upload = next(step for step in job['steps'] if step.get('uses', '').startswith('actions/upload-artifact@'))
        self.assertEqual(upload['if'], 'always()')
        self.assertIs(upload['with']['include-hidden-files'], True)
        self.assertEqual(upload['with']['path'].splitlines(), [
            '.build/package-results', 'ios/Packages/**/.build/**/codecov/*.json'])

    def test_product_jobs_seek_pool_capacity_without_cross_run_slot_blocking(self):
        groups = set()
        for run in (100, 101):
            for attempt in (1, 2):
                for identity in PRODUCER_JOBS:
                    self.assertEqual(POLICY[identity], 'provider')
                    expression = bitrise_group(identity, POLICY[identity])
                    context = {'github.event.pull_request.head.repo.full_name': 'palatis3/room-in-the-cart',
                               'github.event_name': 'push', 'vars.RITC_GITHUB_MAC_ONLY': '',
                               'github.repository': 'palatis3/room-in-the-cart',
                               'github.run_id': run, 'github.run_attempt': attempt}
                    for token, value in context.items(): expression = expression.replace(token, repr(value))
                    expression = expression.removeprefix('${{ ').removesuffix(' }}').replace('&&', 'and').replace('||', 'or')
                    group = eval(expression, {'__builtins__': {}}, {'format': str.format})
                    self.assertEqual(group, f'ritc-bitrise-producer-{identity[0][:-4]}-{identity[1]}-{run}-{attempt}')
                    self.assertNotIn('-slot-', group)
                    groups.add(group)
        self.assertEqual(len(groups), 20)
        # The StoreKit fixture still shares its assigned lane.
        self.assertEqual(POLICY[STOREKIT_JOB], 2)

    def test_twelve_fixture_lanes_are_shared_and_disjoint_between_pools(self):
        context = {'github.event.pull_request.head.repo.full_name': 'palatis3/room-in-the-cart',
                   'github.event_name': 'push', 'vars.RITC_GITHUB_MAC_ONLY': '',
                   'github.repository': 'palatis3/room-in-the-cart', 'github.run_id': 1,
                   'github.run_attempt': 1, 'matrix.profile': 'contributor', 'matrix.shard': 'ui-01'}
        lanes = set()
        for pool in ('A1', 'A2'):
            for slot in range(6):
                evaluated = set()
                for identity in (('ios-fixtures.yml', 'contributor-tests'),
                                 ('ios-fixtures.yml', 'dinner-tests')):
                    expression = bitrise_group(identity, POLICY[identity])
                    for token, value in {**context, 'matrix.provider': 'bitrise-' + pool,
                                         'matrix.pool_slot': slot}.items():
                        expression = expression.replace(token, repr(value))
                    expression = expression.removeprefix('${{ ').removesuffix(' }}').replace('&&', 'and').replace('||', 'or')
                    evaluated.add(eval(expression, {'__builtins__': {}}, {'format': str.format}))
                self.assertEqual(evaluated, {f'ritc-bitrise-{pool.lower()}-slot-{slot}'})
                lanes.update(evaluated)
        self.assertEqual(len(lanes), 12)
        self.assertEqual({p: sum(f'bitrise-{p}-' in lane for lane in lanes) for p in ('a1', 'a2')},
                         {'a1': 6, 'a2': 6})

    def test_provider_and_admission_route_cannot_escape_inventory(self):
        self.path = Path(self.temp.name) / FIXTURE_JOB[0]
        self.assertEqual(len(self.validate(FIXTURE_TEXT, FIXTURE_POLICY)), 1)
        for changed in (FIXTURE_TEXT.replace(FIXTURE_RUNNER, "'" + A1_LABEL + "'"),
                        FIXTURE_TEXT.replace(FIXTURE_GROUP, 'ritc-macos-slot-0'),
                        FIXTURE_TEXT.replace(FIXTURE_GROUP, "${{ 'ritc-bitrise-a1-slot-0' }}"),
                        FIXTURE_TEXT.replace("github.repository == 'palatis3/room-in-the-cart'", 'true'),
                        FIXTURE_TEXT.replace('bitrise-runner-A1', 'bitrise-runner-other'),
                        FIXTURE_TEXT.replace('bitrise-runner-A1', 'bitrise-runner-room in cart'),
                        FIXTURE_TEXT.replace('bitrise-runner-A1', 'bitrise-runner-ci 2'),
                        FIXTURE_TEXT.replace('ritc-bitrise-producer-', 'ritc-bitrise-slot-')):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                self.validate(changed, FIXTURE_POLICY)
        core = ('ci.yml', 'ios-tests')
        core_group = bitrise_group(core, POLICY[core])
        self.path = Path(self.temp.name) / core[0]
        consumer = TEXT.replace('  native:', '  ios-tests:').replace(
            'runs-on: macos-15', 'runs-on: ' + FIXTURE_CONSUMER_RUNNER).replace(
            'ritc-macos-slot-0', core_group).replace(
            '    steps:', '    strategy:\n      matrix: ${{ fromJSON(needs.ios-build.outputs.test_matrix) }}\n    steps:')
        core_policy = {core: POLICY[core]}
        self.assertEqual(len(self.validate(consumer, core_policy)), 1)
        for changed in (consumer.replace(FIXTURE_CONSUMER_RUNNER, FIXTURE_RUNNER),
                        consumer.replace("matrix.provider == 'bitrise-A1'", 'true'),
                        consumer.replace(core_group, 'ritc-macos-slot-${{ matrix.macos_slot }}'),
                        consumer.replace(core_group, 'ritc-bitrise-a2-slot-2'),
                        consumer.replace("matrix.provider == 'bitrise-A2'", 'true'),
                        consumer.replace(core_group, bitrise_group(FIXTURE_JOB, POLICY[FIXTURE_JOB])),
                        consumer.replace('github.run_attempt', 'github.run_id'),
                        consumer.replace('matrix.shard', 'matrix.macos_slot'),
                        consumer.replace('bitrise-runner-A2', 'bitrise-runner-more ci'),
                        consumer.replace('bitrise-runner-A2', 'bitrise-runner-tessss'),
                        consumer.replace('needs.ios-build.outputs.test_matrix', 'needs.other.outputs.test_matrix'),
                        consumer.replace('  ios-tests:', '  ios-build:')):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                self.validate(changed, core_policy)
        for identity, runner, slot, wrong_slot in [
            (CORE_BUILD_JOB, A2_RUNNER, 'ritc-bitrise-a2-slot-0', 'ritc-bitrise-a2-slot-6'),
            (RELEASE_BUILD_JOB, A2_RUNNER, 'ritc-bitrise-a2-slot-1', 'ritc-bitrise-a2-slot-6'),
        ]:
            name = identity[1]
            group = bitrise_group(identity, POLICY[identity])
            producer = TEXT.replace('  native:', '  ' + name + ':').replace(
                'runs-on: macos-15', 'runs-on: ' + runner).replace('ritc-macos-slot-0', group)
            producer_policy = {identity: POLICY[identity]}
            self.assertEqual(len(self.validate(producer, producer_policy)), 1)
            for changed in (producer.replace(group, slot),
                            producer.replace('github.run_attempt', '0'),
                            producer.replace('github.run_id', 'github.ref'),
                            producer.replace(runner, FIXTURE_CONSUMER_RUNNER),
                            producer.replace(runner, FIXTURE_RUNNER),
                            producer.replace(runner, A2_LABEL),
                            producer.replace(runner, "'bitrise-runner-tessss'"),
                            producer.replace(runner, "'bitrise-runner-more ci'"),
                            producer.replace("github.repository == 'palatis3/room-in-the-cart'", 'true'),
                            producer.replace('  ' + name + ':', '  ios-tests:')):
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    self.validate(changed, producer_policy)
        self.path = Path(self.temp.name) / 'probe.yml'
        for label in (FIXTURE_RUNNER, A1_LABEL, 'xcode-27-xlarge', 'macos-15-xlarge'):
            with self.assertRaisesRegex(ValueError, 'Expected standard GitHub runner'):
                self.validate(GITHUB_TEXT.replace('runs-on: macos-15', 'runs-on: ' + label))

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
        self.path = Path(self.temp.name) / FIXTURE_JOB[0]
        for queue in ('single', 'false', 'null', '[max]', '${{ github.ref }}'):
            with self.subTest(queue=queue), self.assertRaises(ValueError):
                self.validate(FIXTURE_TEXT.replace('queue: max', 'queue: ' + queue), FIXTURE_POLICY)
        for cancel in ('true', '"false"', 'no', '0', '${{ false }}', 'False'):
            with self.subTest(cancel=cancel), self.assertRaises(ValueError):
                self.validate(FIXTURE_TEXT.replace('      cancel-in-progress: false', '      cancel-in-progress: ' + cancel), FIXTURE_POLICY)
        for missing in ('      queue: max\n', QUEUE_BLOCK.replace('ritc-macos-slot-0', FIXTURE_GROUP)):
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                self.validate(FIXTURE_TEXT.replace(missing, ''), FIXTURE_POLICY)

    def test_github_jobs_cannot_reintroduce_a_job_group(self):
        for group in ('ritc-macos-slot-0', 'ritc-macos-slot-5', 'ritc-macos-slot-${{ github.workflow }}-0',
                      'ritc-macos-slot-${{ github.ref }}-0', 'preview-private-slot'):
            with self.subTest(group=group), self.assertRaisesRegex(ValueError, 'must use provider admission'):
                self.validate(TEXT.replace('ritc-macos-slot-0', group))

    def test_xcode_runner_cannot_bypass_native_inventory(self):
        text = GITHUB_TEXT.replace('runs-on: macos-15', 'runs-on: xcode-27')
        self.assertEqual(len(self.validate(text)), 0)
        with self.assertRaisesRegex(ValueError, 'Unreviewed native job'):
            self.validate(text, {})

    def test_slots_cannot_be_owned_by_workflow_caller_or_linux_job(self):
        for text in (GITHUB_TEXT.replace('original-pr-${{ github.ref }}', 'ritc-bitrise-a1-slot-0'),
                     GITHUB_TEXT.replace('  cancel-in-progress: true\n', '  cancel-in-progress: true\n  queue: max\n'),
                     TEXT.replace('runs-on: macos-15', 'runs-on: ubuntu-24.04'),
                     TEXT.replace('runs-on: macos-15', 'uses: ./.github/workflows/ci.yml')):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.validate(text)

    def test_nonleaf_namespace_is_case_insensitive_and_computed_prefixes_are_proven_disjoint(self):
        groups = ('RITC-MACOS-SLOT-0', 'RiTc-MaCoS-sLoT-4', 'RITC-BITRISE-SLOT-0', 'RITC-BITRISE-M4-SLOT-0', 'RITC-BITRISE-M4-SLOT-5',
                  'RITC-GITHUB-JOB-CI-IOS-TESTS-10-2-UI-01', "ritc-github-${{ 'job-ci-ios-tests-10-2-ui-01' }}",
                  'ritc-bitrise-a2-slot-${{ matrix.pool_slot }}', "ritc-bitrise-m${{ '4-slot-0' }}",
                  'ritc-bitrise-a1-slot-${{ matrix.macos_slot }}', "ritc-bitri${{ 'se-slot-0' }}",
                  "${{ 'ritc-macos-' }}slot-0", "${{ format('ritc-macos-slot-{0}', 0) }}",
                  "ritc-${{ 'macos-slot-0' }}", "RITC-MACOS-SLO${{ 't-0' }}")
        for group in groups:
            for scope in ('root-mapping', 'root-string', 'linux', 'caller'):
                with self.subTest(group=group, scope=scope), self.assertRaises(ValueError):
                    if scope == 'root-mapping':
                        text = GITHUB_TEXT.replace('original-pr-${{ github.ref }}', group)
                    elif scope == 'root-string':
                        text = GITHUB_TEXT.replace('concurrency:\n  group: original-pr-${{ github.ref }}\n  cancel-in-progress: true',
                                            'concurrency: ' + group)
                    else:
                        runner = 'runs-on: ubuntu-24.04' if scope == 'linux' else 'uses: ./.github/workflows/ci.yml'
                        text = GITHUB_TEXT + '  other:\n    ' + runner + '\n    concurrency:\n      group: ' + group + '\n'
                    self.validate(text)
        for group in ('CORE-CI-${{ github.ref }}', 'ritc-linux-${{ github.ref }}', 'independent-group'):
            with self.subTest(safe_group=group):
                self.assertEqual(len(self.validate(GITHUB_TEXT.replace('original-pr-${{ github.ref }}', group))), 0)
                self.assertEqual(len(self.validate(GITHUB_TEXT + '  other:\n    runs-on: ubuntu-24.04\n    concurrency: ' +
                                                   group + '\n    steps: [{run: echo fixture}]\n')), 0)

    def test_native_inventory_cannot_add_drop_or_hide_an_unguarded_job(self):
        for text in (GITHUB_TEXT + '  new-native:\n    runs-on: macos-15\n    steps: [{run: echo new}]\n',
                     GITHUB_TEXT.replace('runs-on: macos-15', 'runs-on: ${{ matrix.runner }}'),
                     GITHUB_TEXT[:GITHUB_TEXT.index('jobs:')] + 'jobs: {}\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.validate(text)

    def test_aliases_cannot_relocate_queue_source_validation(self):
        self.path = Path(self.temp.name) / FIXTURE_JOB[0]
        queue = QUEUE_BLOCK.replace('ritc-macos-slot-0', FIXTURE_GROUP)
        for text in ('value: &queue max\n' + FIXTURE_TEXT.replace('queue: max', 'queue: *queue'),
                     f'value: &config\n  group: {FIXTURE_GROUP}\n  queue: max\n  cancel-in-progress: false\n' +
                     FIXTURE_TEXT.replace(queue, '    concurrency: *config\n')):
            with self.assertRaises(ValueError):
                self.validate(text, FIXTURE_POLICY)

    def test_static_matrix_validates_identity_order_and_integer_slot(self):
        text = GITHUB_TEXT.replace('    steps:',
            '    strategy:\n      matrix:\n        include:\n          - locale: en\n            macos_slot: 2\n          - locale: es\n            macos_slot: 3\n    steps:')
        policy = {('probe.yml', 'native'): ([('en', 2), ('es', 3)], 'locale')}
        self.assertEqual(len(self.validate(text, policy)), 0)
        for changed in (text.replace('macos_slot: 2', 'macos_slot: true'), text.replace('macos_slot: 2', 'macos_slot: 5'),
                        text.replace('locale: es', 'locale: en'), text.replace('locale: en', 'locale: es')):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                self.validate(changed, policy)

    def test_dynamic_matrix_requires_exact_reviewed_producer(self):
        expression = '${{ fromJSON(needs.build.outputs.matrix) }}'
        text = GITHUB_TEXT.replace('    steps:',
            '    strategy:\n      matrix: ' + expression + '\n    steps:')
        policy = {('probe.yml', 'native'): (expression, ('shard',))}
        self.assertEqual(len(self.validate(text, policy)), 0)
        with self.assertRaises(ValueError):
            self.validate(text.replace('needs.build.outputs', 'needs.other.outputs'), policy)


class ActionlintBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / FIXTURE_JOB[0]
        self.path.write_text(FIXTURE_TEXT)
        self.allowed = validate_workflows([self.path], FIXTURE_POLICY)
        pos, = self.allowed
        self.diagnostic = {'filepath': str(self.path), 'line': pos[1], 'column': pos[2],
                           'end_column': pos[2] + 5, 'kind': 'syntax-check', 'message': QUEUE_ERROR}

    def invoke(self, diagnostics, exit_code=1, stderr=''):
        outputs = [subprocess.CompletedProcess([], 0, '1.7.12\n', ''),
                   subprocess.CompletedProcess([], exit_code, json.dumps(diagnostics), stderr)]
        with patch('check_ci_workflows.subprocess.run', side_effect=outputs) as run:
            report = lint_workflows([self.path], Path('/pinned/actionlint'), FIXTURE_POLICY)
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
        self.path.write_text(FIXTURE_TEXT.replace('queue: max', 'queue: single'))
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
