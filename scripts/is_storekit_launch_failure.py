"""Recognize documented simulator failures before any StoreKit scenario starts."""
import json
from pathlib import Path
import sys


LAUNCH_FAILURE = (
    'Failed to install or launch the test runner. (Underlying Error: '
    'The operation couldn’t be completed. (Mach error -308 - (ipc/mig) server died))'
)
RUNNER_ERROR = 'RoomInTheCart encountered an error'


def is_launch_failure(log, tests, status=65, simulator=""):
    if any(marker in log for marker in (
        'Test Suite ', 'Test Case ', ': error: -[', 'Restarting after unexpected exit, crash, or test timeout;',
    )):
        return False
    if not isinstance(tests, dict):
        return False
    if status == 70:
        # simctl booted this exact device, but Xcode listed only its generic
        # simulator placeholder. A wrong UDID or an executed test is ineligible.
        heading = 'Destinations compatible with the "RoomInTheCart-LocalStoreKit" scheme:'
        before, found, destinations = log.partition(heading)
        lines = [line.strip() for line in before.splitlines() if line.strip()]
        diagnostic = [
            'xcodebuild: error: Unable to find a device matching the provided destination specifier:',
            f'{{ platform:iOS Simulator, id:{simulator} }}',
            'The requested device could not be found because no available devices matched the request.',
        ]
        listed = [line.strip() for line in destinations.splitlines() if line.strip().startswith('{ platform:iOS Simulator,')]
        placeholder = ('{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, '
                       'name:Any iOS Simulator Device }')
        errors = [line.strip() for line in log.splitlines() if line.strip().startswith('xcodebuild: error:')]
        return bool(simulator and found and lines[-3:] == diagnostic and errors == diagnostic[:1] and listed == [placeholder]
                    and tests.get('testNodes') == [] and tests.get('testPlanConfigurations') == []
                    and tests.get('devices') == [{'architecture': '', 'deviceId': '', 'deviceName': '',
                                                  'modelName': '', 'osVersion': '', 'platform': ''}])
    if status != 65:
        return False
    diagnostic = f'{RUNNER_ERROR} ({LAUNCH_FAILURE})'
    if not any(line.strip() == diagnostic for line in log.splitlines()):
        return False

    # XCResult counts this synthetic System Failures child as a failed test.
    # Require exactly this branch, including the framework's own failure text.
    nodes = tests.get('testNodes')
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
    log_file, tests_file = map(Path, sys.argv[1:3])
    retryable = is_launch_failure(log_file.read_text(), json.loads(tests_file.read_text()), int(sys.argv[3]), sys.argv[4])
    sys.exit(0 if retryable else 1)
