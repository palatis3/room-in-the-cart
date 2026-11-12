"""Recognize the single simulator launch failure eligible for a StoreKit retry."""
import json
from pathlib import Path
import sys


LAUNCH_FAILURE = (
    'Failed to install or launch the test runner. (Underlying Error: '
    'The operation couldn’t be completed. (Mach error -308 - (ipc/mig) server died))'
)
RUNNER_ERROR = 'RoomInTheCart encountered an error'


def is_launch_failure(log, tests):
    if any(marker in log for marker in (
        'Test Suite ', 'Test Case ', ': error: -[', 'Restarting after unexpected exit, crash, or test timeout;',
    )):
        return False
    diagnostic = f'{RUNNER_ERROR} ({LAUNCH_FAILURE})'
    if not any(line.strip() == diagnostic for line in log.splitlines()):
        return False

    # XCResult counts this synthetic System Failures child as a failed test.
    # Require exactly this branch, including the framework's own failure text.
    nodes = tests.get('testNodes') if isinstance(tests, dict) else None
    for kind, name in (
        ('Test Plan', 'LocalStoreKit'), ('Unit test bundle', 'RoomInTheCartTests'),
        ('Test Suite', 'System Failures'), ('Test Case', RUNNER_ERROR),
        ('Failure Message', LAUNCH_FAILURE),
    ):
        if not isinstance(nodes, list) or len(nodes) != 1 or not isinstance(nodes[0], dict):
            return False
        node = nodes[0]
        if node.get('nodeType') != kind or node.get('name') != name:
            return False
        if kind == 'Test Case' and ('nodeIdentifierURL' in node or node.get('result') != 'Failed'):
            return False
        nodes = node.get('children', [])
    return nodes == []


if __name__ == '__main__':
    log_file, tests_file = map(Path, sys.argv[1:])
    sys.exit(0 if is_launch_failure(log_file.read_text(), json.loads(tests_file.read_text())) else 1)
