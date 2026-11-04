#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('check_ios_test_results.py')


class ExecutionInventoryTests(unittest.TestCase):
    def check_case(self, identifiers, *, selected=None, skipped=0, result='Passed'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'selection.txt').write_text('\n'.join(selected or ['Target/Suite/testOne']) + '\n')
            (root / 'summary.json').write_text(json.dumps({
                'totalTestCount': len(identifiers), 'passedTests': len(identifiers) - skipped,
                'skippedTests': skipped, 'failedTests': 0, 'result': result,
            }))
            (root / 'tests.json').write_text(json.dumps({'testNodes': [
                {'nodeType': 'Test Case', 'nodeIdentifierURL': 'test://com.apple.xcode/Project/' + identifier,
                 'result': 'Passed', 'durationInSeconds': 1} for identifier in identifiers
            ]}))
            env = dict(os.environ)
            env.pop('GITHUB_STEP_SUMMARY', None)
            return subprocess.run([sys.executable, str(SCRIPT), '--selectors', str(root / 'selection.txt'),
                '--expected-count', str(len(selected or ['Target/Suite/testOne'])), '--summary', str(root / 'summary.json'), '--tests', str(root / 'tests.json')],
                env=env, capture_output=True, text=True).returncode

    def test_exact_execution_passes(self):
        self.assertEqual(self.check_case(['Target/Suite/testOne']), 0)

    def test_wrong_test_with_same_count_fails(self):
        self.assertNotEqual(self.check_case(['Target/Suite/testOther']), 0)

    def test_missing_or_duplicate_execution_fails(self):
        self.assertNotEqual(self.check_case([]), 0)
        self.assertNotEqual(self.check_case(['Target/Suite/testOne'] * 2), 0)

    def test_skip_or_failed_summary_fails(self):
        self.assertNotEqual(self.check_case(['Target/Suite/testOne'], skipped=1), 0)
        self.assertNotEqual(self.check_case(['Target/Suite/testOne'], result='Failed'), 0)


if __name__ == '__main__':
    unittest.main()
