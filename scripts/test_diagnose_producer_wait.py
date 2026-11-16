"""Offline checks for the isolated producer diagnostic; no native tools run."""
import copy
import json
import contextlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, call, patch

import diagnose_producer_wait as subject
from check_ci_workflows import parse_workflow

ROOT = Path(__file__).resolve().parents[1]


class ObserverTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        previous = Path.cwd()
        os.chdir(temporary.name)
        self.addCleanup(os.chdir, previous)
        subject.DIRECTORY.mkdir(parents=True)
        Path('.build/ios-build-evidence').mkdir()
        Path('.build/ios-build-evidence/build.log').write_text('Resolve Package Graph\n')
        self.build = Mock(pid=123)
        self.build.poll.return_value = None
        (subject.DIRECTORY / 'build-identity.txt').write_text(
            f'123 {os.getpid()} {os.getuid()} {subject.DEVELOPER}/usr/bin/xcodebuild\n')
        for name in ('dump_traceback_later', 'cancel_dump_traceback_later'):
            patcher = patch.object(subject.faulthandler, name)
            setattr(self, name, patcher.start())
            self.addCleanup(patcher.stop)

    def test_checkpoint_has_utc_timestamp_and_flushes(self):
        with patch('builtins.print') as output:
            subject.checkpoint('observation-entered')
        output.assert_called_once()
        self.assertRegex(output.call_args.args[0], r'^Producer observer \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ: observation-entered$')
        self.assertEqual(output.call_args.kwargs, {'flush': True})

    def test_sample_excerpt_is_bounded_and_marks_truncation_without_changing_file(self):
        path = subject.DIRECTORY / 'build.sample.txt'
        original = ''.join(f'frame {i}\n' for i in range(200))
        path.write_text(original)
        output = io.StringIO()
        with contextlib.redirect_stdout(output): subject.print_sample_excerpt(path)
        self.assertIn('frame 119\n', output.getvalue())
        self.assertNotIn('frame 120\n', output.getvalue())
        self.assertIn('TRUNCATED; full file retained.', output.getvalue())
        self.assertEqual(path.read_text(), original)
        path.write_text('x' * 20000)
        output = io.StringIO()
        with contextlib.redirect_stdout(output): subject.print_sample_excerpt(path)
        self.assertLess(len(output.getvalue()), 16300)
        self.assertIn('TRUNCATED', output.getvalue())

    def test_exact_live_child_gets_one_three_second_sample(self):
        with patch.object(subject, 'collect', return_value={'status':'completed','exitCode':0}) as capture:
            subject.observe(self.build)
        self.assertEqual(capture.call_count, 3)
        sample = capture.call_args_list[-1].args
        self.assertEqual(sample[0][:4], ['/usr/bin/sample', '123', '3', '1'])
        self.assertEqual(sample[2], 15)
        self.build.kill.assert_not_called()
        self.build.terminate.assert_not_called()
        self.assertEqual(json.loads((subject.DIRECTORY / 'capture.json').read_text())['outcome'], 'sample-attempted')

    def test_wrong_owner_parent_pid_or_executable_is_never_sampled(self):
        good = f'123 {os.getpid()} {os.getuid()} {subject.DEVELOPER}/usr/bin/xcodebuild'
        for bad in [good.replace('123 ', '456 ', 1), f'123 1 {os.getuid()} {subject.DEVELOPER}/usr/bin/xcodebuild',
                    f'123 {os.getpid()} -1 {subject.DEVELOPER}/usr/bin/xcodebuild', good + '-other', good + '\n' + good]:
            with self.subTest(bad=bad):
                (subject.DIRECTORY / 'build-identity.txt').write_text(bad)
                with patch.object(subject, 'collect', return_value={'status':'completed','exitCode':0}) as capture:
                    subject.observe(self.build)
                self.assertEqual(capture.call_count, 2)
                self.build.kill.assert_not_called()

    def test_log_phase_labels_do_not_gate_the_single_owned_sample(self):
        log = Path('.build/ios-build-evidence/build.log')
        for text, phase in [('', 'no-graph-marker'),
                            ('Resolve Package Graph\n', 'graph-started'),
                            ('Resolve Package Graph\nResolved source packages:\n', 'graph-completed'),
                            (None, 'unknown')]:
            with self.subTest(phase=phase):
                if text is None:
                    log.unlink()
                else:
                    log.write_text(text)
                with patch.object(subject, 'collect', return_value={'status':'completed','exitCode':0}) as capture:
                    subject.observe(self.build)
                self.assertEqual(capture.call_count, 3)
                self.assertEqual(capture.call_args.args[0][0], '/usr/bin/sample')
                receipt = json.loads((subject.DIRECTORY / 'capture.json').read_text())
                self.assertEqual(receipt['packageGraphPhase'], phase)
                self.assertEqual(receipt['outcome'], 'sample-attempted')
                self.build.kill.assert_not_called()

    def test_exited_child_is_not_sampled(self):
        self.build.poll.return_value = 0
        with patch.object(subject, 'collect') as capture:
            subject.observe(self.build)
        capture.assert_not_called()

    def test_failed_identity_capture_never_samples(self):
        with patch.object(subject, 'collect', return_value={'status':'timed-out'}) as capture:
            subject.observe(self.build)
        self.assertEqual(capture.call_count, 2)

    def test_evidence_child_unreapable_is_bounded_and_not_build(self):
        collector = Mock()
        collector.wait.side_effect = subprocess.TimeoutExpired('collector', 10)
        with patch.object(subject.subprocess, 'Popen', return_value=collector):
            result = subject.collect(['/bin/ps'], subject.DIRECTORY / 'ps.txt', 10)
        self.assertEqual(collector.wait.call_args_list, [call(timeout=10), call(timeout=5)])
        collector.kill.assert_called_once_with()
        self.assertEqual(result['termination'], 'unreaped')
        self.build.kill.assert_not_called()

    def test_run_preserves_arguments_status_and_only_observes_once_at_five_minutes(self):
        command = ['xcodebuild', '-project', 'same.xcodeproj', 'build-for-testing']
        def wait(timeout=None):
            self.dump_traceback_later.assert_called_once_with(360, repeat=False)
            if timeout == 300:
                self.cancel_dump_traceback_later.assert_not_called()
                raise subprocess.TimeoutExpired('build', 300)
            self.cancel_dump_traceback_later.assert_called_once_with()
            return 7
        self.build.wait.side_effect = wait
        env = {'RUNNER_ENVIRONMENT':'github-hosted','GITHUB_REPOSITORY':'palatis3/room-in-the-cart','DEVELOPER_DIR':subject.DEVELOPER}
        with patch.dict(os.environ, env), patch.object(subject.os, 'getuid', return_value=501), \
                patch.object(subject.subprocess, 'Popen', return_value=self.build) as start, \
                patch.object(subject, 'observe', side_effect=OSError('evidence unavailable')) as observe:
            self.assertEqual(subject.run(command), 7)
        start.assert_called_once_with([subject.DEVELOPER + '/usr/bin/xcodebuild', *command[1:]])
        self.assertEqual(self.build.wait.call_args_list, [call(timeout=300), call()])
        observe.assert_called_once_with(self.build)
        self.build.kill.assert_not_called()

    def test_build_finished_before_delay_has_no_observation(self):
        self.build.wait.return_value = 0
        env = {'RUNNER_ENVIRONMENT':'github-hosted','GITHUB_REPOSITORY':'palatis3/room-in-the-cart','DEVELOPER_DIR':subject.DEVELOPER}
        with patch.dict(os.environ, env), patch.object(subject.os, 'getuid', return_value=501), \
                patch.object(subject.subprocess, 'Popen', return_value=self.build), patch.object(subject, 'observe') as observe:
            self.assertEqual(subject.run(['xcodebuild','build-for-testing']), 0)
        observe.assert_not_called()
        self.build.kill.assert_not_called()
        self.dump_traceback_later.assert_called_once_with(360, repeat=False)
        self.cancel_dump_traceback_later.assert_called_once_with()

    def test_interrupted_initial_wait_cancels_watchdog_without_signaling_build(self):
        self.build.wait.side_effect = KeyboardInterrupt()
        env = {'RUNNER_ENVIRONMENT':'github-hosted','GITHUB_REPOSITORY':'palatis3/room-in-the-cart','DEVELOPER_DIR':subject.DEVELOPER}
        with patch.dict(os.environ, env), patch.object(subject.os, 'getuid', return_value=501), \
                patch.object(subject.subprocess, 'Popen', return_value=self.build), self.assertRaises(KeyboardInterrupt):
            subject.run(['xcodebuild','build-for-testing'])
        self.dump_traceback_later.assert_called_once_with(360, repeat=False)
        self.cancel_dump_traceback_later.assert_called_once_with()
        self.build.kill.assert_not_called()


class DiagnosticWorkflowTests(unittest.TestCase):
    def test_manual_isolated_slot_and_unchanged_contributor_build(self):
        workflow = parse_workflow(ROOT / '.github/workflows/ci.yml')[0]
        source = parse_workflow(ROOT / '.github/workflows/ios-fixtures.yml')[0]
        self.assertEqual(set(workflow['on']), {'workflow_dispatch'})
        self.assertEqual(len(workflow['jobs']), 1)
        job = workflow['jobs']['producer-wait']
        self.assertEqual(job['runs-on'], 'xcode-27')
        self.assertEqual(job['timeout-minutes'], 35)
        self.assertEqual(job['concurrency'], {'group':'ritc-macos-slot-0','queue':'max','cancel-in-progress':False})
        self.assertIn("github.ref == 'refs/heads/codex/producer-wait-diagnostic-nov16'", job['if'])
        original = source['jobs']['build-contributor']
        self.assertEqual(job['env'], original['env'])
        self.assertEqual(workflow['env'], source['env'])
        build = next(s for s in job['steps'] if s.get('id') == 'build')
        expected = copy.deepcopy(next(s for s in original['steps'] if s.get('id') == 'build'))
        expected['run'] = expected['run'].replace('\nxcodebuild -project', '\npython3 scripts/diagnose_producer_wait.py -- xcodebuild -project')
        self.assertEqual(build, expected)
        upload = job['steps'][job['steps'].index(build) + 1]
        self.assertEqual(upload['name'], 'Upload observer and build evidence before runtime verification')
        self.assertEqual(upload['if'], 'always()')
        self.assertTrue(upload['continue-on-error'])
        self.assertEqual(upload['timeout-minutes'], 2)
        self.assertEqual(set(upload['with']['path'].splitlines()), {'.build/producer-wait', '.build/ios-build-evidence'})
        self.assertEqual(job['steps'][job['steps'].index(build) + 2]['name'], 'Verify the imported runtime after producer execution')
        final = next(s for s in job['steps'] if s.get('name') == 'Upload final runtime evidence')
        self.assertEqual(set(final['with']['path'].splitlines()), {'.build/github-ios-runtime', '.build/test-simulator-ownership.json'})
        before = job['steps'][:job['steps'].index(build)]
        self.assertTrue(any(s.get('name') == 'Upload setup evidence before native build' and s['timeout-minutes'] == 2 for s in before))
        setup = next(s for s in before if s.get('name') == 'Print setup evidence outcome')
        for field in ('mode', 'bytes', 'sha256'):
            self.assertIn("data.get('" + field + "')", setup['run'])
        self.assertEqual(setup['env']['RITC_CAS_HIT'], '${{ steps.github-cas.outputs.cache-hit }}')
        for old in original['steps']:
            if old.get('id') in ('imported-runtime', 'github-cache-key', 'github-cas') or old.get('name') in (
                    'Select an iPhone simulator','Verify the imported runtime after producer execution',
                    'Retain GitHub runtime diagnostics','Clean up only the owned simulator after result export'):
                self.assertIn(old, job['steps'])
        self.assertFalse(any(s.get('id') in ('models','upload') for s in job['steps']))


if __name__ == '__main__':
    unittest.main()
