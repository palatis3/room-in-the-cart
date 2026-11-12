#!/usr/bin/env python3
"""Validate five GitHub, three M2 and six M4 Bitrise native-job slots and bridge only actionlint 1.7.12's queue-key gap."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

import yaml
from yaml.nodes import MappingNode, ScalarNode, SequenceNode

SLOT_PREFIX = 'ritc-macos-slot-'
MATRIX_GROUP = SLOT_PREFIX + '${{ matrix.macos_slot }}'
BITRISE_SLOT_PREFIX = 'ritc-bitrise-slot-'
BITRISE_LABEL = 'bitrise-runner-room in cart'
M4_SLOT_PREFIX = 'ritc-bitrise-m4-slot-'
M4_LABEL = 'bitrise-runner-ci 2'
FIXTURE_JOBS = {('ios-fixtures.yml', name) for name in
                ('build-contributor', 'build-dinner', 'contributor-tests', 'dinner-tests')}
CORE_BUILD_JOB = ('ci.yml', 'ios-build')
RELEASE_BUILD_JOB = ('ci.yml', 'ios-release')
M4_BUILD_JOBS = {RELEASE_BUILD_JOB}
ROUTED_NATIVE_JOBS = FIXTURE_JOBS | {CORE_BUILD_JOB} | M4_BUILD_JOBS | {('ci.yml', 'ios-tests')}
# One reviewed routing expression, not arbitrary runner selection. Reusable
# workflows inherit their caller's event; unknown events fail back to GitHub.
FIXTURE_TRUSTED = ("github.repository == 'palatis3/room-in-the-cart' && "
                   "(github.event_name == 'push' || github.event_name == 'workflow_dispatch' || "
                   "github.event_name == 'workflow_call' || github.event_name == 'schedule' || "
                   "(github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository))")
FIXTURE_RUNNER = "${{ " + FIXTURE_TRUSTED + " && '" + BITRISE_LABEL + "' || 'xcode-27' }}"
FIXTURE_SLOT_PREFIX = "${{ " + FIXTURE_TRUSTED + " && '" + BITRISE_SLOT_PREFIX + "' || '" + SLOT_PREFIX + "' }}"
# Full queue names preserve the original GitHub fallback, including M4 slot zero.
M4_RUNNER = "${{ " + FIXTURE_TRUSTED + " && '" + M4_LABEL + "' || 'xcode-27' }}"
CORE_BUILD_GROUP = "${{ " + FIXTURE_TRUSTED + " && 'ritc-bitrise-slot-2' || 'ritc-macos-slot-3' }}"
RELEASE_BUILD_GROUP = "${{ " + FIXTURE_TRUSTED + " && 'ritc-bitrise-m4-slot-1' || 'ritc-macos-slot-1' }}"
FIXTURE_CONSUMER_RUNNER = ("${{ " + FIXTURE_TRUSTED +
    " && (matrix.provider == 'bitrise-m4' && '" + M4_LABEL +
    "' || matrix.provider == 'bitrise' && '" + BITRISE_LABEL + "') || 'xcode-27' }}")
FIXTURE_MATRIX_GROUP = ("${{ " + FIXTURE_TRUSTED +
    " && (matrix.provider == 'bitrise-m4' && format('ritc-bitrise-m4-slot-{0}', matrix.m4_slot)" +
    " || matrix.provider == 'bitrise' && format('ritc-bitrise-slot-{0}', matrix.macos_slot))" +
    " || format('ritc-macos-slot-{0}', matrix.macos_slot) }}")
# Isolated qualification branch only; never merge these pilot exceptions.
PILOT_JOBS = {('ios-fixtures.yml', 'build-contributor'): 0,
              ('ios-fixtures.yml', 'contributor-tests'): 1}
PILOT_SHARD = 'SharedStoreQuoteUITests-testLostReplyRelaunchRestoresExactRetryWithoutDuplicatingPrivateSave'
PILOT_GUARD_STEP = {
    'name': 'Require the isolated M4 qualification invocation',
    'shell': 'bash',
    'env': {'REQUESTED_FIXTURE_SHARD': '${{ inputs.shard }}'},
    'run': 'test "$GITHUB_REPOSITORY" = palatis3/room-in-the-cart\n'
           'test "$GITHUB_EVENT_NAME" = workflow_dispatch\n'
           'test "$GITHUB_REF" = refs/heads/codex/m4-fixture-pilot\n'
           'test "$REQUESTED_FIXTURE_SHARD" = ' + PILOT_SHARD + '\n',
}
QUEUE_ERROR = 'unexpected key "queue" for "concurrency" section. expected one of "cancel-in-progress", "group"'
# Every native leaf job must remain represented; new native job definitions require review.
POLICY = {
    ('ci.yml', 'swift-packages'): 0,
    ('ci.yml', 'ios-release'): 1,
    ('release-checks.yml', 'staging-iphone'): 2,
    ('ci.yml', 'ios-swift-codeql'): 4,
    ('ci.yml', 'ios-build'): 3,
    ('ci.yml', 'ios-tests'): ('${{ fromJSON(needs.ios-build.outputs.test_matrix) }}', ('shard',)),
    ('ios-fixtures.yml', 'build-contributor'): 0,
    ('ios-fixtures.yml', 'build-dinner'): 1,
    ('ios-fixtures.yml', 'contributor-tests'): ('${{ fromJSON(needs.fixture-plan.outputs.contributor_matrix) }}', ('profile', 'shard')),
    ('ios-fixtures.yml', 'dinner-tests'): ('${{ fromJSON(needs.fixture-plan.outputs.dinner_matrix) }}', ('profile', 'shard')),
    ('ios-performance.yml', 'performance-build'): 2,
    ('ios-performance.yml', 'simulator-signpost-control'): 2,
    ('ios-performance.yml', 'performance-tests'): ('${{ fromJSON(needs.performance-build.outputs.test_matrix) }}', ('case',)),
    ('ios-deep.yml', 'sanitizers'): ([('thread', 0), ('address', 1)], 'sanitizer'),
    ('ios-deep.yml', 'storekit-build'): 2,
    ('ios-deep.yml', 'storekit'): 2,
    ('ios-native-wire.yml', 'native-wire'): 4,
    ('ios-toggle-diagnostic.yml', 'control'): 4,
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


class WorkflowLoader(yaml.SafeLoader):
    """Safe constructors with GitHub-compatible true/false resolution, not on/off."""
    yaml_implicit_resolvers = copy.deepcopy(yaml.SafeLoader.yaml_implicit_resolvers)

    def construct_mapping(self, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            require(isinstance(key_node, ScalarNode) and key_node.tag == 'tag:yaml.org,2002:str',
                    'Workflow mapping keys must be strings; merge keys are not permitted')
            key = key_node.value
            require(key not in result, f'Duplicate YAML key {key!r} at line {key_node.start_mark.line + 1}')
            result[key] = self.construct_object(value_node, deep=deep)
        return result


for first, resolvers in WorkflowLoader.yaml_implicit_resolvers.items():
    WorkflowLoader.yaml_implicit_resolvers[first] = [item for item in resolvers if item[0] != 'tag:yaml.org,2002:bool']
WorkflowLoader.add_implicit_resolver('tag:yaml.org,2002:bool', re.compile(r'^(?:true|false)$'), list('tf'))


def parse_workflow(path):
    require(yaml.__version__ == '6.0.3', 'Use the hash-pinned PyYAML 6.0.3 requirements')
    text = path.read_text(encoding='utf-8')
    loader = WorkflowLoader(text)
    nodes = {}
    keys = {}
    count = 0

    def walk(node, location, active):
        nonlocal count
        count += 1
        require(count <= 100000, 'Workflow YAML exceeds the bounded node traversal')
        require(id(node) not in active, 'Recursive YAML aliases are not permitted')
        active = active | {id(node)}
        nodes[location] = node
        if isinstance(node, MappingNode):
            seen = set()
            for key, value in node.value:
                require(isinstance(key, ScalarNode) and key.tag == 'tag:yaml.org,2002:str',
                        'Workflow mapping keys must be strings; merge keys are not permitted')
                require(key.value not in seen, f'Duplicate YAML key {key.value!r} at line {key.start_mark.line + 1}')
                seen.add(key.value)
                child = location + (key.value,)
                keys[child] = key
                walk(value, child, active)
        elif isinstance(node, SequenceNode):
            for index, child in enumerate(node.value):
                walk(child, location + (index,), active)

    try:
        node = loader.get_single_node()
        require(isinstance(node, MappingNode), f'Workflow must be a YAML mapping: {path}')
        walk(node, (), set())
        data = loader.construct_document(node)
    except yaml.YAMLError as error:
        raise ValueError(f'Invalid safe workflow YAML in {path}: {error}') from error
    finally:
        loader.dispose()
    return data, nodes, keys


def native_job(job):
    labels = job.get('runs-on', [])
    if labels in (FIXTURE_RUNNER, M4_RUNNER, FIXTURE_CONSUMER_RUNNER):
        return True
    if isinstance(labels, str):
        labels = [labels]
    require(isinstance(labels, list) and all(isinstance(label, str) and '${{' not in label for label in labels),
            'Review dynamic or grouped runs-on before changing the native-job inventory')
    return any(re.match(r'^(?:(?:macos|xcode)(?:-|$)|bitrise-runner-)', label, re.I) for label in labels)


def nonleaf_group_is_disjoint(group):
    """Prove exclusion using literal prefixes, without evaluating GitHub expressions.

    Groups are case-insensitive. A computed suffix is allowed only after a
    nonempty literal prefix that cannot prefix (or equal) any reserved name.
    Entirely computed groups and ambiguous prefixes need explicit review.
    """
    if not isinstance(group, str) or not group:
        return False
    folded = group.casefold()
    if any(prefix in folded for prefix in (SLOT_PREFIX, BITRISE_SLOT_PREFIX, M4_SLOT_PREFIX)):
        return False
    prefix = folded.split('${{', 1)[0]
    reserved = [pool + str(slot) for pool, count in ((SLOT_PREFIX, 5), (BITRISE_SLOT_PREFIX, 3), (M4_SLOT_PREFIX, 6))
                for slot in range(count)]
    return bool(prefix) and all(not name.startswith(prefix) for name in reserved)


def validate_workflows(paths, policy=POLICY):
    allowed = {}
    actual = set()
    seen_files = set()
    for path in paths:
        require(path.name not in seen_files, 'Duplicate workflow filename')
        seen_files.add(path.name)
        data, nodes, keys = parse_workflow(path)
        root_concurrency = data.get('concurrency')
        if isinstance(root_concurrency, dict):
            require('queue' not in root_concurrency and nonleaf_group_is_disjoint(root_concurrency.get('group')),
                    'Native slots and queue compatibility are leaf-job-only, never workflow-owned')
        elif root_concurrency is not None:
            require(nonleaf_group_is_disjoint(root_concurrency), 'Workflow cannot own or compute an ambiguous native slot')
        require(isinstance(data.get('jobs'), dict), f'Missing workflow jobs: {path}')
        for name, job in data['jobs'].items():
            require(isinstance(job, dict), f'Invalid job: {name}')
            identity = (path.name, name)
            concurrency = job.get('concurrency')
            is_native = native_job(job)
            if not is_native:
                if concurrency is not None:
                    group = concurrency.get('group') if isinstance(concurrency, dict) else concurrency
                    require(not (isinstance(concurrency, dict) and 'queue' in concurrency) and
                            nonleaf_group_is_disjoint(group),
                            f'Only leaf macOS jobs may own native slots/queue compatibility: {identity}')
                continue
            actual.add(identity)
            require('uses' not in job and identity in policy, f'Unreviewed native job inventory: {identity}')
            require(isinstance(concurrency, dict) and set(concurrency) == {'group', 'queue', 'cancel-in-progress'},
                    f'Native job needs exactly group, queue and cancel-in-progress: {identity}')
            base = ('jobs', name, 'concurrency')
            node = nodes[base]
            require(node.start_mark.index >= keys[base].end_mark.index,
                    f'Native concurrency must be defined at its own leaf, not aliased: {identity}')
            queue_node = nodes[base + ('queue',)]
            cancel_node = nodes[base + ('cancel-in-progress',)]
            queue_key = keys[base + ('queue',)]
            require(queue_key.style is None and queue_key.value == 'queue', 'Use a direct plain queue key')
            require(isinstance(queue_node, ScalarNode) and queue_node.tag == 'tag:yaml.org,2002:str' and
                    queue_node.value == 'max' and queue_node.start_mark.index >= queue_key.end_mark.index,
                    f'Native queue must be literal max: {identity}')
            require(isinstance(cancel_node, ScalarNode) and cancel_node.tag == 'tag:yaml.org,2002:bool' and
                    cancel_node.style is None and cancel_node.value == 'false' and
                    cancel_node.start_mark.index >= keys[base + ('cancel-in-progress',)].end_mark.index,
                    f'Native cancel-in-progress must be literal false: {identity}')
            expected = policy[identity]
            routed = identity in ROUTED_NATIVE_JOBS
            pilot = identity in PILOT_JOBS and job.get('runs-on') == M4_LABEL
            if pilot:
                plan = data['jobs'].get('fixture-plan', {})
                require(plan.get('steps') and plan['steps'][0] == PILOT_GUARD_STEP and
                        'continue-on-error' not in plan,
                        'Literal M4 pilot routes require the exact first-step invocation guard')
                expected_needs = 'fixture-plan' if name == 'build-contributor' else ['fixture-plan', 'build-contributor']
                require(job.get('needs') == expected_needs and
                        job.get('if') == "needs.fixture-plan.outputs.build_contributor == 'true'",
                        'M4 pilot native jobs must depend on the successful guarded plan')
            elif routed:
                runner = M4_RUNNER if identity in M4_BUILD_JOBS else FIXTURE_RUNNER if type(expected) is int else FIXTURE_CONSUMER_RUNNER
                require(job.get('runs-on') == runner, f'Unreviewed native provider routing: {identity}')
            else:
                labels = job.get('runs-on', [])
                labels = [labels] if isinstance(labels, str) else labels
                require(job.get('runs-on') not in (FIXTURE_RUNNER, M4_RUNNER, FIXTURE_CONSUMER_RUNNER) and
                        not any(label.lower().startswith('bitrise-runner-') for label in labels),
                        f'Bitrise routing is restricted to reviewed native jobs: {identity}')
            slot_prefix = FIXTURE_SLOT_PREFIX if routed else SLOT_PREFIX
            matrix_group = M4_SLOT_PREFIX + str(PILOT_JOBS[identity]) if pilot else FIXTURE_MATRIX_GROUP if routed else MATRIX_GROUP
            slot_count = 3 if routed else 5
            if type(expected) is int:
                if pilot:
                    require(concurrency['group'] == M4_SLOT_PREFIX + str(PILOT_JOBS[identity]),
                            f'Wrong isolated pilot slot: {identity}')
                elif identity == CORE_BUILD_JOB:
                    require(expected == 3 and concurrency['group'] == CORE_BUILD_GROUP,
                            f'Wrong main producer dual-provider slots: {identity}')
                elif identity == RELEASE_BUILD_JOB:
                    require(expected == 1 and concurrency['group'] == RELEASE_BUILD_GROUP,
                            f'Wrong Release producer dual-provider slots: {identity}')
                else:
                    require(0 <= expected < slot_count and concurrency['group'] == slot_prefix + str(expected), f'Wrong fixed native slot: {identity}')
                require('strategy' not in job or 'matrix' not in job['strategy'],
                        f'Static slot policy cannot silently accept a new matrix: {identity}')
            else:
                require(concurrency['group'] == matrix_group, f'Wrong global native matrix group: {identity}')
                matrix = job.get('strategy', {}).get('matrix')
                if isinstance(expected[0], str):
                    require(matrix == expected[0], f'Unreviewed native matrix producer: {identity}')
                else:
                    require(isinstance(matrix, dict) and set(matrix) == {'include'} and
                            isinstance(matrix['include'], list), f'Expected explicit native matrix rows: {identity}')
                    rows = matrix['include']
                    require(all(isinstance(row, dict) and type(row.get('macos_slot')) is int and
                                0 <= row['macos_slot'] < slot_count for row in rows), f'Invalid native matrix slot: {identity}')
                    require([(row.get(expected[1]), row['macos_slot']) for row in rows] == expected[0],
                            f'Native matrix identity/order/slot changed: {identity}')
            position = (str(path.resolve()), queue_key.start_mark.line + 1, queue_key.start_mark.column + 1)
            require(position not in allowed, 'Queue keys must have distinct physical source positions')
            allowed[position] = {'workflow': path.name, 'job': name, 'line': position[1], 'column': position[2]}
    require(actual == set(policy), f'Native job inventory mismatch: missing={sorted(set(policy) - actual)}, extra={sorted(actual - set(policy))}')
    return allowed


def classify_diagnostics(diagnostics, allowed):
    require(isinstance(diagnostics, list), 'Expected a JSON array of actionlint diagnostics')
    exempted, unexpected, seen = [], [], set()
    for diagnostic in diagnostics:
        require(isinstance(diagnostic, dict), 'Malformed actionlint diagnostic')
        filename = diagnostic.get('filepath')
        position = (str(Path(filename).resolve()), diagnostic.get('line'), diagnostic.get('column')) if isinstance(filename, str) else None
        exact = (position in allowed and diagnostic.get('message') == QUEUE_ERROR and
                 diagnostic.get('kind') == 'syntax-check' and type(diagnostic.get('line')) is int and
                 type(diagnostic.get('column')) is int and diagnostic.get('end_column') == position[2] + 5)
        if exact and position not in seen:
            exempted.append(diagnostic)
            seen.add(position)
        else:
            unexpected.append(diagnostic)
    require(seen == set(allowed), 'Pinned actionlint did not report exactly the validated queue-key positions')
    return exempted, unexpected


def lint_workflows(paths, actionlint, policy=POLICY):
    before = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    report = {'passed': False, 'actionlintVersion': None, 'validationErrors': [], 'exemptedQueueDiagnostics': [],
              'unexpectedDiagnostics': [], 'sourceSHA256': before}
    allowed = {}
    try:
        allowed = validate_workflows(paths, policy)
    except (OSError, ValueError, TypeError, KeyError) as error:
        report['validationErrors'].append(str(error))
    # Run the entire pinned linter on every original workflow, even if strict YAML/slot validation failed.
    version = subprocess.run([str(actionlint), '-version'], capture_output=True, text=True, timeout=15, check=False)
    report['actionlintVersion'] = version.stdout.strip()
    require(version.returncode == 0 and version.stdout.splitlines() and
            version.stdout.splitlines()[0] == '1.7.12', 'Expected pinned actionlint 1.7.12')
    args = [str(actionlint), '-no-color', '-shellcheck=', '-pyflakes=', '-format', '{{json .}}', *map(str, paths)]
    result = subprocess.run(args, capture_output=True, text=True, timeout=90, check=False)
    report.update(actionlintArguments=args, actionlintExit=result.returncode, actionlintStderr=result.stderr,
                  actionlintStdout=result.stdout)
    try:
        require(not result.stderr, 'actionlint produced unexpected stderr')
        diagnostics = json.loads(result.stdout)
        if diagnostics is None:
            diagnostics = []
        report['actionlintDiagnostics'] = diagnostics
        require(result.returncode == (1 if diagnostics else 0), 'Unexpected actionlint process exit')
        if report['validationErrors']:
            report['unexpectedDiagnostics'] = diagnostics
        else:
            exempted, unexpected = classify_diagnostics(diagnostics, allowed)
            report.update(exemptedQueueDiagnostics=exempted, unexpectedDiagnostics=unexpected)
        require(before == {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths},
                'Workflow source changed during validation')
    except (ValueError, TypeError, KeyError) as error:
        report['validationErrors'].append(str(error))
    report['passed'] = not report['validationErrors'] and not report['unexpectedDiagnostics']
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--actionlint', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    paths = sorted(path for path in Path('.github/workflows').iterdir() if path.suffix in ('.yml', '.yaml'))
    try:
        report = lint_workflows(paths, args.actionlint)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
        if not report['passed']:
            print(json.dumps(report, indent=2), file=sys.stderr)
            return 1
        print(f'All workflow checks passed; {len(report["exemptedQueueDiagnostics"])} queue nodes independently validated.')
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Workflow validation failed: {error}\n')


if __name__ == '__main__':
    sys.exit(main())
