import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from check_swift_syntax import check, source_files
from check_ci_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]


class SwiftSyntaxTests(unittest.TestCase):
    def test_selection_covers_staged_unstaged_untracked_and_excludes_deleted_ignored_manifests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.DEVNULL)
            git('init')
            (root / 'ios').mkdir()
            for name in ['Staged.swift', 'Unstaged.swift', 'Deleted.swift', 'Same.swift', 'Package.swift']:
                (root / 'ios' / name).write_text('// initial\n')
            (root / '.gitignore').write_text('ios/Ignored.swift\n')
            git('add', '.')
            git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'Fixture')
            (root / 'ios/Staged.swift').write_text('// staged\n')
            git('add', '.')
            (root / 'ios/Unstaged.swift').write_text('// unstaged\n')
            (root / 'ios/Deleted.swift').unlink()
            (root / 'ios/Untracked space.swift').write_text('// new\n')
            (root / 'ios/Ignored.swift').write_text('// ignored\n')
            (root / 'ios/Package.swift').write_text('// manifest\n')
            changed = {p.name for p in source_files(root, changed=True)}
            self.assertEqual(changed, {'Staged.swift', 'Unstaged.swift', 'Untracked space.swift'})
            self.assertEqual({p.name for p in source_files(root)}, changed | {'Same.swift'})

    def test_parser_failure_and_timeout_cannot_pass(self):
        with patch('check_swift_syntax.subprocess.run') as run:
            run.return_value.returncode = 1
            self.assertEqual(check([Path('bad.swift')]), 1)
            self.assertEqual(run.call_count, 1)
            run.side_effect = subprocess.TimeoutExpired('swiftc', 60)
            self.assertEqual(check([Path('bad.swift')]), 2)

    def test_gate_precedes_every_main_app_test_producer(self):
        for file in ['ci.yml', 'ios-fixtures.yml', 'ios-deep.yml', 'ios-performance.yml']:
            workflow = parse_workflow(ROOT / '.github/workflows' / file)[0]
            for name, job in workflow['jobs'].items():
                steps = job.get('steps', [])
                builds = [i for i, step in enumerate(steps) if 'build-for-testing' in step.get('run', '')]
                if not builds:
                    continue
                guards = [i for i, step in enumerate(steps) if step.get('run') == 'python3 scripts/check_swift_syntax.py']
                self.assertEqual(len(guards), 1, (file, name))
                self.assertLess(guards[0], min(builds), (file, name))
                self.assertNotIn('continue-on-error', steps[guards[0]])


if __name__ == '__main__':
    unittest.main()
