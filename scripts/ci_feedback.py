#!/usr/bin/env python3
"""Read-only, exact-revision CI triage. Never dispatches or retries a workflow."""
import argparse
from collections import Counter
from datetime import datetime
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def seconds(start, end):
    if not start or not end:
        return None
    return max(0, (datetime.fromisoformat(end.replace('Z', '+00:00')) -
                   datetime.fromisoformat(start.replace('Z', '+00:00'))).total_seconds())


def summarize(run, jobs):
    rows = []
    for job in jobs:
        steps = job.get('steps', [])
        timed = [{'name': step['name'], 'seconds': seconds(step.get('started_at'), step.get('completed_at'))}
                 for step in steps if step.get('status') == 'completed' and step.get('conclusion') != 'skipped']
        timed = [step for step in timed if step['seconds'] is not None]
        rows.append({
            'id': job['id'], 'name': job['name'], 'status': job['status'],
            'conclusion': job.get('conclusion'), 'url': job.get('html_url'),
            'execution_seconds': seconds(job.get('started_at'), job.get('completed_at'))
                if job.get('conclusion') != 'skipped' else None,
            # This includes dependency/slot/runner waits, not pure runner queue time.
            'pre_start_seconds': seconds(job.get('created_at'), job.get('started_at')),
            'failed_steps': [step['name'] for step in steps if step.get('conclusion') == 'failure'],
            'slowest_steps': sorted(timed, key=lambda step: step['seconds'], reverse=True)[:3],
        })
    failures = Counter(step for job in rows for step in job['failed_steps'])
    return {
        'id': run['id'], 'attempt': run['run_attempt'], 'sha': run['head_sha'],
        'workflow': run.get('name'), 'branch': run.get('head_branch'), 'event': run.get('event'),
        'status': run['status'], 'conclusion': run.get('conclusion'), 'url': run['html_url'],
        'job_count': len(rows),
        'repeated_failed_steps': dict(sorted(failures.items(), key=lambda pair: (-pair[1], pair[0]))),
        'jobs': sorted(rows, key=lambda row: row['execution_seconds'] or 0, reverse=True),
    }


class GitHub:
    def __init__(self, gh, repo, cache):
        self.gh, self.repo, self.cache = gh, repo, cache

    def api(self, path, *, pages=False):
        command = [self.gh, 'api', f'repos/{self.repo}/{path}']
        if pages:
            command += ['--paginate', '--slurp']
        result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=60)
        return json.loads(result.stdout)

    def runs(self, sha):
        pages = self.api(f'actions/runs?head_sha={sha}&per_page=100', pages=True)
        return [run for page in pages for run in page['workflow_runs'] if run['head_sha'] == sha]

    def report(self, run):
        attempt = run['run_attempt']
        path = self.cache / self.repo / f"{run['id']}-attempt-{attempt}.json"
        if path.exists():
            try:
                saved = json.loads(path.read_text())
            except (OSError, ValueError):
                saved = {}
            if not isinstance(saved, dict):
                saved = {}
            if (saved.get('repo') == self.repo and saved.get('id') == run['id'] and
                    saved.get('attempt') == attempt and saved.get('sha') == run['head_sha'] and
                    saved.get('status') == 'completed' and run['status'] == 'completed' and
                    saved.get('conclusion') == run.get('conclusion')):
                return saved
        pages = self.api(f"actions/runs/{run['id']}/attempts/{attempt}/jobs?per_page=100", pages=True)
        jobs = [job for page in pages for job in page['jobs']]
        report = dict(summarize(run, jobs), repo=self.repo)
        # A live snapshot is never reused as terminal evidence.
        if run['status'] == 'completed' and jobs and all(job['status'] == 'completed' for job in jobs):
            path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, suffix='.tmp', delete=False) as output:
                temporary = Path(output.name)
                output.write(json.dumps(report, indent=2) + '\n')
            try:
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
        return report


def render_text(payload):
    """Compact triage view; JSON remains the complete machine-readable evidence."""
    lines = [f"Runs: {len(payload['runs'])}; active: {payload['active_run_count']}"]
    if not payload['runs']:
        lines.append('No runs found; this is not a passing result.')
    for run in payload['runs']:
        lines += ['', f"{run.get('workflow') or 'Workflow'} | run {run['id']} attempt {run['attempt']}",
                  f"{run['sha']} | {run['status']} / {run.get('conclusion') or 'pending'}",
                  run['url']]
        counts = Counter(job.get('conclusion') or job['status'] for job in run['jobs'])
        lines.append('Jobs: ' + ', '.join(f'{name}={count}' for name, count in sorted(counts.items())))
        # Include every unsuccessful/unfinished job, even if it has no failed step.
        for job in run['jobs']:
            if job['status'] != 'completed' or job.get('conclusion') != 'success':
                lines.append(f"  {job['name']}: {job.get('conclusion') or job['status']}")
                lines.extend(f'    failed step: {step}' for step in job['failed_steps'])
                if job.get('url'):
                    lines.append(f"    {job['url']}")
        timed = sorted((job for job in run['jobs'] if job['execution_seconds'] is not None),
                       key=lambda job: job['execution_seconds'], reverse=True)[:5]
        if timed:
            lines.append('Longest job execution windows (not a critical-path calculation):')
            for job in timed:
                lines.append(f"  {job['execution_seconds'] / 60:.1f}m | {job['name']}")
                if job['slowest_steps']:
                    step = job['slowest_steps'][0]
                    lines.append(f"    longest step: {step['seconds'] / 60:.1f}m | {step['name']}")
    for group in payload['possible_duplicate_runs']:
        lines.append('Possible active duplicates; compare scopes: ' + ', '.join(map(str, group)))
    lines += ['', 'Counts cover this query only. Focused passes do not establish release acceptance.',
              'Read-only: no dispatch, retry, cancellation or log download.']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument('--sha', help='Full 40-character commit SHA; includes every workflow at that revision')
    target.add_argument('--run', type=int, help='Exact run ID; reads its current attempt')
    parser.add_argument('--repo', default='palatis3/room-in-the-cart')
    parser.add_argument('--gh', default=shutil.which('gh') or str(ROOT / '.tools/github-cli/bin/gh'))
    parser.add_argument('--cache', type=Path, default=ROOT / '.build/ci-feedback')
    parser.add_argument('--format', choices=('json', 'text'), default='json',
                        help='Use text for a compact failure-first triage view; JSON retains all job details')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo) or '..' in args.repo:
        parser.error('--repo must be owner/repository')
    if args.sha and not re.fullmatch(r'[0-9a-fA-F]{40}', args.sha):
        parser.error('--sha must be a full commit SHA')
    if args.run is not None and args.run <= 0:
        parser.error('--run must be positive')
    github = GitHub(args.gh, args.repo, args.cache)
    runs = github.runs(args.sha.lower()) if args.sha else [github.api(f'actions/runs/{args.run}')]
    groups = {}
    for run in runs:
        if run['status'] != 'completed':
            key = (run.get('workflow_id'), run.get('head_branch'), run['head_sha'])
            groups.setdefault(key, []).append(run['id'])
    reports = [github.report(run) for run in runs]
    payload = {
        'runs': reports,
        'active_run_count': sum(run['status'] != 'completed' for run in runs),
        'possible_duplicate_runs': [ids for ids in groups.values() if len(ids) > 1],
        'notes': [
            'Read-only snapshot; no dispatch, retry, cancellation or log download.',
            'Possible duplicates share workflow, branch and SHA; compare manual scopes before cancelling.',
            'Repeated failed step names help triage; they are not a count of distinct bugs.',
            'pre_start_seconds includes dependencies and scheduling, not just runner queue time.',
            'A focused green run does not establish full PR or release acceptance.',
        ],
    }
    print(render_text(payload) if args.format == 'text' else json.dumps(payload, indent=2))
    return 0 if runs else 1


if __name__ == '__main__':
    raise SystemExit(main())
