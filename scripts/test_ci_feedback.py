from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from ci_feedback import GitHub, seconds, summarize, render_text

RUN = {'id': 42, 'run_attempt': 1, 'head_sha': 'a' * 40, 'status': 'completed',
       'conclusion': 'failure', 'html_url': 'https://github.com/example/app/actions/runs/42'}
JOB = {'id': 1, 'name': 'Original journey', 'status': 'completed', 'conclusion': 'failure',
       'created_at': '2026-11-08T00:00:00Z', 'started_at': '2026-11-08T00:01:00Z',
       'completed_at': '2026-11-08T00:04:00Z', 'steps': [
           {'name': 'Build', 'status': 'completed', 'conclusion': 'success',
            'started_at': '2026-11-08T00:01:00Z', 'completed_at': '2026-11-08T00:02:00Z'},
           {'name': 'Strict verification', 'status': 'completed', 'conclusion': 'failure',
            'started_at': '2026-11-08T00:02:00Z', 'completed_at': '2026-11-08T00:04:00Z'}]}


class FeedbackTests(unittest.TestCase):
    def test_compact_view_keeps_cancelled_skipped_and_active_jobs_without_failed_steps(self):
        jobs = [JOB] + [dict(JOB, id=index, name=f'Job {state}', conclusion=conclusion,
                            status=state, steps=[]) for index, (state, conclusion) in enumerate([
                                ('completed', 'cancelled'), ('completed', 'skipped'),
                                ('queued', None), ('in_progress', None)], start=2)]
        report = summarize(RUN, jobs)
        text = render_text({'runs': [report], 'active_run_count': 0, 'possible_duplicate_runs': [[42, 43]]})
        for value in ('run 42 attempt 1', 'a' * 40, RUN['html_url'], 'Strict verification',
                      'cancelled', 'skipped', 'queued', 'in_progress', '42, 43', '3.0m',
                      'not a critical-path', 'do not establish release acceptance'):
            self.assertIn(value, text)

    def test_compact_view_bounds_timing_rows_but_never_hides_failures(self):
        jobs = [dict(JOB, id=index, name=f'Failure {index}') for index in range(12)]
        text = render_text({'runs': [summarize(RUN, jobs)], 'active_run_count': 0,
                            'possible_duplicate_runs': []})
        self.assertEqual(text.count('failed step: Strict verification'), 12)
        self.assertEqual(text.count('longest step:'), 5)
        empty = render_text({'runs': [], 'active_run_count': 0, 'possible_duplicate_runs': []})
        self.assertIn('No runs found; this is not a passing result.', empty)

    def test_timing_failed_step_and_missing_timestamps(self):
        report = summarize(RUN, [JOB])
        self.assertEqual(report['jobs'][0]['pre_start_seconds'], 60)
        self.assertEqual(report['jobs'][0]['execution_seconds'], 180)
        self.assertEqual(report['jobs'][0]['slowest_steps'][0]['name'], 'Strict verification')
        self.assertEqual(report['repeated_failed_steps'], {'Strict verification': 1})
        self.assertIsNone(seconds(None, '2026-11-08T00:04:00Z'))
        skipped = dict(JOB, conclusion='skipped')
        self.assertIsNone(summarize(RUN, [skipped])['jobs'][0]['execution_seconds'])

    def test_paginated_jobs_and_terminal_cache_are_bound_to_attempt_and_source(self):
        with tempfile.TemporaryDirectory() as directory:
            api = GitHub('gh', 'example/app', Path(directory))
            with patch.object(api, 'api', return_value=[{'jobs': [JOB]}, {'jobs': [dict(JOB, id=2)]}]) as request:
                report = api.report(RUN)
                self.assertEqual(report['job_count'], 2)
                request.assert_called_once_with('actions/runs/42/attempts/1/jobs?per_page=100', pages=True)
                self.assertEqual(api.report(RUN), report)
                self.assertEqual(request.call_count, 1)
                api.report(dict(RUN, run_attempt=2))
                self.assertEqual(request.call_count, 2)
                api.report(dict(RUN, head_sha='b' * 40))
                self.assertEqual(request.call_count, 3)

    def test_live_results_are_not_cached_and_incomplete_jobs_are_not_terminal_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            api = GitHub('gh', 'example/app', Path(directory))
            with patch.object(api, 'api', return_value=[{'jobs': [dict(JOB, status='in_progress')]}]) as request:
                for run in (dict(RUN, status='in_progress'), RUN):
                    api.report(run)
                    api.report(run)
                self.assertEqual(request.call_count, 4)
                self.assertEqual(list(Path(directory).rglob('*.json')), [])

    def test_corrupt_cache_is_replaced_with_fresh_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            api = GitHub('gh', 'example/app', Path(directory))
            path = Path(directory) / 'example/app/42-attempt-1.json'
            path.parent.mkdir(parents=True)
            for corrupt in ('{broken', '[]'):
                path.write_text(corrupt)
                with patch.object(api, 'api', return_value=[{'jobs': [JOB]}]) as request:
                    self.assertEqual(api.report(RUN)['job_count'], 1)
                    request.assert_called_once()
                    self.assertEqual(json.loads(path.read_text())['id'], 42)

    def test_concurrent_monitors_write_complete_cache_without_shared_temp_race(self):
        with tempfile.TemporaryDirectory() as directory:
            api = GitHub('gh', 'example/app', Path(directory))
            barrier = threading.Barrier(8)
            def response(*args, **kwargs):
                barrier.wait(timeout=5)
                return [{'jobs': [JOB]}]
            with patch.object(api, 'api', side_effect=response), ThreadPoolExecutor(max_workers=8) as pool:
                reports = list(pool.map(api.report, [RUN] * 8))
            self.assertTrue(all(report == reports[0] for report in reports))
            path = Path(directory) / 'example/app/42-attempt-1.json'
            self.assertEqual(json.loads(path.read_text()), reports[0])
            self.assertEqual(list(Path(directory).rglob('*.tmp')), [])

    def test_run_inventory_filters_exact_sha_across_pages(self):
        api = GitHub('gh', 'example/app', Path('/unused'))
        with patch.object(api, 'api', return_value=[{'workflow_runs': [RUN]},
                {'workflow_runs': [dict(RUN, id=43), dict(RUN, head_sha='b' * 40)]}]):
            self.assertEqual([run['id'] for run in api.runs('a' * 40)], [42, 43])

    def test_api_is_read_only_and_uses_pagination_without_shell(self):
        api = GitHub('gh', 'example/app', Path('/unused'))
        with patch('ci_feedback.subprocess.run') as run:
            run.return_value.stdout = json.dumps([])
            api.api('actions/runs?per_page=100', pages=True)
            self.assertEqual(run.call_args.args[0],
                             ['gh', 'api', 'repos/example/app/actions/runs?per_page=100', '--paginate', '--slurp'])
            self.assertNotIn('shell', run.call_args.kwargs)


if __name__ == '__main__':
    unittest.main()
