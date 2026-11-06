#!/usr/bin/env python3
"""Pinned artifact restore. --local-cache validates/extracts without network/native tools."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

BASE = '169613bfabeb00355649f96d6bc88ad91064f708'
REPO = 'palatis3/room-in-the-cart'
RUN = 42176801822
REPO_ID = 1445928007
SCOPE = ['ios', 'shared', 'config', 'scripts', 'diagnostics', '.github/workflows/ios-fixtures.yml']
ARTIFACTS = {
    'keyboard-events-1': (13484227125, '8db6da6d34f0558a93b71e8e37bc5eaa4cc583fa4c899c81ba3b6101520a170d', 1020752, 74, 2573004),
    'keyboard-products-1': (13484396727, '9dc1a1a53b645f00a666c9f08f1286eced4ede0a45c19f91456ac9fe6845e545', 51830824, 1, 51830640),
}
TAR_SHA = 'a5c87f66347417d3ebafdec2b87d45c7c6b5eda3d9f5819298ad94147241e87f'
SELECTOR_SHA = 'beb687223139990138c7431da849b74459d1764fbc06c5977e17b29e17e2d3c4'
APPLE_SHA = '4798dcd53450d1b8bd450cf6e57b913e12a90a3baf6a63c051c5153c68cc3c1e'
APPLE = {'._Products', 'Products/._Debug-iphonesimulator', 'Products/Debug-iphonesimulator/._PackageFrameworks'}
OVERLAY = {'.github/workflows/ios-fixtures.yml'} | {
    'diagnostics/keyboard-history/' + x for x in ['restore.py', 'prepare.sh', 'run.sh', 'analyze.py', 'cleanup.py', 'REVIEW.md']
}
EVENT_FILES = {'identity.json', 'toolchain.txt', 'source-sha256.json', 'product-sha256.json',
               'frozen-inputs-unchanged.json', 'product-archive.sha256', 'compiled-plan/manifest.json',
               'compiled-plan/contributor-balanced-02.txt'}
PREFIX = '.build/DerivedData/Build/'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''):
            h.update(b)
    return h.hexdigest()


def dump(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def git(*args, data=None):
    return subprocess.check_output(['git', *args], input=data)


def safe_path(name):
    p = PurePosixPath(name)
    require(bool(name) and not p.is_absolute() and '..' not in p.parts and '\\' not in name and '\0' not in name,
            'Unsafe archive path')
    require(str(p) == name.rstrip('/') and p.parts[0] != '.', 'Noncanonical archive path')
    return p


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api(path, archive=None, expected_size=None):
    """Never forward GH_TOKEN to an artifact redirect or include it in command arguments."""
    url = f'https://api.github.com/repos/{REPO}/actions/{path}'
    headers = {'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json',
               'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'ritc-keyboard-history-diagnostic'}
    opener = urllib.request.build_opener(NoRedirect())
    try:
        response = opener.open(urllib.request.Request(url, headers=headers), timeout=30)
    except urllib.error.HTTPError as e:
        require(archive is not None and e.code in (301, 302, 303, 307, 308), 'GitHub API request failed')
        location = e.headers.get('Location', '')
        target = urllib.parse.urlsplit(location)
        require(target.scheme == 'https' and target.hostname and not target.username and not target.password,
                'Invalid artifact redirect')
        # Separate unauthenticated request; signed storage URL is never logged.
        response = opener.open(urllib.request.Request(location), timeout=30)
    with response:
        if archive is None:
            data = response.read(2_000_001)
            require(len(data) <= 2_000_000, 'Oversize API metadata')
            return json.loads(data)
        total = 0
        start = time.monotonic()
        with Path(archive).open('xb') as f:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                require(total <= expected_size and time.monotonic() - start < 180, 'Artifact download bound exceeded')
                f.write(chunk)
        require(total == expected_size, 'Artifact download length mismatch')


def provenance(run, artifacts):
    require(run['id'] == RUN and run['head_sha'] == BASE and run['run_attempt'] == 1, 'Source run identity mismatch')
    require(run['repository']['full_name'] == REPO and run['repository']['id'] == REPO_ID and
            run['head_repository']['id'] == REPO_ID, 'Source repository mismatch')
    require(run['workflow_id'] == 407500252 and run['path'] == '.github/workflows/ios-fixtures.yml' and
            run['event'] == 'workflow_dispatch' and run['head_branch'] == 'codex/diagnostic-keyboard-d0b0b12',
            'Source workflow mismatch')
    require(run['status'] == 'completed' and run['conclusion'] == 'success', 'Source run not successful/completed')
    require(artifacts['total_count'] == 2 and len(artifacts['artifacts']) == 2, 'Unexpected source artifact set')
    for name, (identifier, sha, size, _, _) in ARTIFACTS.items():
        matches = [a for a in artifacts['artifacts'] if a['id'] == identifier]
        require(len(matches) == 1, 'Pinned artifact missing/duplicated')
        a = matches[0]
        require(a['name'] == name and a['digest'] == 'sha256:' + sha and a['size_in_bytes'] == size and
                a['expired'] is False, 'Artifact metadata mismatch/expired')
        w = a['workflow_run']
        require(w['id'] == RUN and w['head_sha'] == BASE and w['repository_id'] == REPO_ID and
                w['head_repository_id'] == REPO_ID and w['head_branch'] == run['head_branch'], 'Artifact provenance mismatch')
        require(a['archive_download_url'] == f'https://api.github.com/repos/{REPO}/actions/artifacts/{identifier}/zip',
                'Artifact API URL mismatch')


def read_zip(archive, name, destination):
    _, sha, size, count, expanded = ARTIFACTS[name]
    require(archive.stat().st_size == size and digest(archive) == sha, 'Pinned ZIP digest/size mismatch')
    wanted = EVENT_FILES if name == 'keyboard-events-1' else {'keyboard-diagnostic-products.tar.gz'}
    found = set()
    with zipfile.ZipFile(archive) as z:
        entries = z.infolist()
        require(len(entries) == count and sum(i.file_size for i in entries) == expanded, 'ZIP member/expanded size mismatch')
        names = set()
        for i in entries:
            safe_path(i.filename)
            require(i.filename not in names, 'Duplicate ZIP path')
            names.add(i.filename)
            mode = i.external_attr >> 16
            require(not stat.S_ISLNK(mode) and stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), 'Special ZIP member')
            require(not i.flag_bits & 1 and 0 <= i.file_size <= 60_000_000, 'Unsupported or oversized ZIP member')
            # Read every member to validate decompression/CRC, but extract only required
            # metadata/plan. No previous xcresult/media or Records plan is uploaded.
            h = hashlib.sha256()
            got = 0
            target = destination / i.filename if i.filename in wanted else None
            if target:
                target.parent.mkdir(parents=True, exist_ok=True)
            f = target.open('xb') if target else None
            try:
                with z.open(i) as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b''):
                        got += len(chunk)
                        require(got <= i.file_size, 'ZIP member expanded past bound')
                        h.update(chunk)
                        if f:
                            f.write(chunk)
            finally:
                if f:
                    f.close()
            require(got == i.file_size, 'ZIP member size mismatch')
            if target:
                found.add(i.filename)
        require(found == wanted, 'Required artifact metadata missing')
        if name == 'keyboard-products-1':
            require(names == wanted, 'Unexpected products ZIP member')


def verify_sources(source, current):
    paths = git('ls-tree', '-r', '--name-only', BASE, *SCOPE).decode().splitlines()
    require(len(source) == 525 and set(paths) == set(source), 'Archived source inventory differs from exact base')
    blobs = git('cat-file', '--batch', data=''.join(BASE + ':' + p + '\n' for p in paths).encode())
    offset = 0
    for p in paths:
        end = blobs.index(b'\n', offset)
        header = blobs[offset:end].split()
        require(header[1] == b'blob', 'Source is not a Git blob')
        size = int(header[2]); offset = end + 1
        data = blobs[offset:offset + size]; offset += size + 1
        require(hashlib.sha256(data).hexdigest() == source[p], 'Archived source differs from169613bf: ' + p)
        if current and p != '.github/workflows/ios-fixtures.yml':
            require(Path(p).is_file() and not Path(p).is_symlink() and digest(p) == source[p], 'Runtime source differs: ' + p)
    if current:
        expected = os.environ['EXPECTED_SHA']
        require(re.fullmatch('[0-9a-f]{40}', expected) is not None and git('rev-parse', 'HEAD').decode().strip() == expected,
                'Checkout differs from reviewed diagnostic commit')
        changed = set(git('diff', '--name-only', BASE, 'HEAD').decode().splitlines())
        require(changed <= OVERLAY, 'Diagnostic commit changes non-overlay files')
        require(not git('status', '--porcelain', '--untracked-files=no').strip(), 'Tracked checkout is dirty')
        tracked = git('ls-files', '-z').decode().split('\0')
        require(all(not Path(p).is_symlink() for p in tracked if p), 'Tracked symlinks not allowed')
        return {p: digest(p) for p in tracked if p}
    return None


def restore_tar(archive, expected, destination):
    require(digest(archive) == TAR_SHA, 'Pinned product TAR digest mismatch')
    require(len(expected) == 238 and all(p.startswith(PREFIX + 'Products/') for p in expected), 'Invalid product manifest')
    allowed_dirs = {'Products'}
    for path in expected:
        member = PurePosixPath(path.removeprefix(PREFIX))
        safe_path(str(member))
        allowed_dirs.update(str(p) for p in member.parents if str(p) != '.')
    actual = {}; seen = set(); apple = {}; expanded = 0
    with tarfile.open(archive, 'r:gz') as t:
        for m in t:
            safe_path(m.name)
            require(m.name not in seen and len(seen) < 1000, 'Duplicate/too many TAR members')
            seen.add(m.name)
            require(m.isdir() or m.isfile(), 'Special TAR member rejected')
            if m.name in APPLE:
                require(m.isfile() and m.size == 172, 'Unbounded AppleDouble metadata')
                data = t.extractfile(m).read(173)
                require(data[:8] == bytes.fromhex('0005160700020000') and hashlib.sha256(data).hexdigest() == APPLE_SHA,
                        'Unexpected AppleDouble metadata')
                apple[m.name] = APPLE_SHA
                continue
            if m.isdir():
                require(m.name in allowed_dirs, 'Unexpected product directory')
                continue
            key = PREFIX + m.name
            require(key in expected and m.size <= 250_000_000, 'Unexpected/oversize product file')
            expanded += m.size
            require(expanded <= 200_000_000, 'Product expansion bound exceeded')
            path = destination / m.name
            path.parent.mkdir(parents=True, exist_ok=True)
            h = hashlib.sha256(); got = 0
            with t.extractfile(m) as source, path.open('xb') as target:
                for b in iter(lambda: source.read(1024 * 1024), b''):
                    got += len(b); require(got <= m.size, 'TAR member exceeds declared size')
                    h.update(b); target.write(b)
            require(got == m.size and h.hexdigest() == expected[key], 'Product bytes differ from frozen manifest: ' + m.name)
            path.chmod(m.mode & 0o777)  # Preserve executable bits, never ownership/setuid/xattrs.
            actual[key] = h.hexdigest()
    require(actual == expected and set(apple) == APPLE and expanded == 194257759, 'Product set/size mismatch')
    verify_products(expected, destination)
    return {'count': len(actual), 'expandedBytes': expanded, 'appleDoubleOmitted': apple}


def verify_products(expected, destination):
    actual = {}
    for p in (destination / 'Products').rglob('*'):
        require(not p.is_symlink(), 'Unexpected product symlink')
        if p.is_file():
            actual[PREFIX + p.relative_to(destination).as_posix()] = digest(p)
    require(actual == expected, 'Restored/frozen product tree differs')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--local-cache', type=Path, help='Offline validation using cached API JSON and both ZIPs; never native tools')
    p.add_argument('--out', type=Path, default=Path('.build/keyboard-history'))
    p.add_argument('--work', type=Path, default=Path('.build/keyboard-history-inputs'))
    p.add_argument('--products', type=Path, default=Path('.build/DerivedData/Build'))
    args = p.parse_args()
    require(not args.out.exists() and not args.work.exists() and not (args.products / 'Products').exists(),
            'Output/input/product directories must be fresh')
    args.out.mkdir(parents=True); args.work.mkdir(parents=True)
    if args.local_cache:
        run = json.loads((args.local_cache / 'run.json').read_text())
        artifacts = json.loads((args.local_cache / 'artifacts.json').read_text())
    else:
        require(os.environ.get('GITHUB_REPOSITORY') == REPO and os.environ.get('GITHUB_RUN_ATTEMPT') == '1',
                'Only first-attempt workflow dispatch in the expected repository is allowed')
        run = api(f'runs/{RUN}')
        artifacts = api(f'runs/{RUN}/artifacts?per_page=100')
    provenance(run, artifacts)
    dump(args.out / 'source-run.json', run); dump(args.out / 'source-artifacts.json', artifacts)
    for name, (identifier, _, size, _, _) in ARTIFACTS.items():
        archive = (args.local_cache or args.work) / (name + '.zip')
        if not args.local_cache:
            api(f'artifacts/{identifier}/zip', archive=archive, expected_size=size)
        read_zip(archive, name, args.work / name)
    prior = args.work / 'keyboard-events-1'
    identity = json.loads((prior / 'identity.json').read_text())
    require(identity['EXPECTED_SHA'] == BASE and identity['GITHUB_RUN_ID'] == str(RUN) and identity['GITHUB_RUN_ATTEMPT'] == '1' and
            identity['runtimeBuild'] == '23C54' and identity['runtime'] == 'com.apple.CoreSimulator.SimRuntime.iOS-26-2', 'Archived identity mismatch')
    require((prior / 'toolchain.txt').read_text().strip() == 'Xcode 26.3\nBuild version 17C529', 'Archived toolchain mismatch')
    frozen = json.loads((prior / 'frozen-inputs-unchanged.json').read_text())
    require(frozen['source'] is True and frozen['products'] is True, 'Original inputs were not frozen')
    source = json.loads((prior / 'source-sha256.json').read_text())
    current = verify_sources(source, current=not bool(args.local_cache))
    expected = json.loads((prior / 'product-sha256.json').read_text())
    require((prior / 'product-archive.sha256').read_text().split()[0] == TAR_SHA, 'Archived TAR hash mismatch')
    product_proof = restore_tar(args.work / 'keyboard-products-1/keyboard-diagnostic-products.tar.gz', expected, args.products)
    selectors = (prior / 'compiled-plan/contributor-balanced-02.txt').read_bytes()
    require(hashlib.sha256(selectors).hexdigest() == SELECTOR_SHA, 'Six-selector bytes differ from original compiled plan')
    rows = selectors.decode().splitlines()
    plan = json.loads((prior / 'compiled-plan/manifest.json').read_text())
    require(plan['profile'] == 'contributor' and len(rows) == 6 and len(set(rows)) == 6 and
            rows == [x.removesuffix('()') for x in plan['shards']['contributor-balanced-02']['test_identifiers']],
            'Compiled selector plan mismatch')
    require(all('/RecordsMedia' not in r for r in rows), 'Records media selection prohibited')
    (args.out / 'selectors.txt').write_bytes(selectors)
    dump(args.out / 'original-source-sha256.json', source)
    dump(args.out / 'product-sha256.json', expected)
    dump(args.out / 'selector-plan.json', plan['shards']['contributor-balanced-02'])
    if current:
        dump(args.out / 'source-sha256.json', current)
    proof = {'diagnosticOnly': True, 'releaseAcceptance': False, 'archiveOnly': bool(args.local_cache),
             'sourceCommit': BASE, 'sourceRunID': RUN, 'sourceManifestMatchesGit': True,
             'sourceFileCount': len(source), 'runtimeSourceUnchanged': bool(current),
             'productArchiveSHA256': TAR_SHA, 'products': product_proof,
             'selectorSHA256': SELECTOR_SHA, 'selected': len(rows), 'artifactDigestsVerified': True,
             'metadataMode': 'cached-offline' if args.local_cache else 'live-GitHub-API'}
    dump(args.out / 'restore-verification.json', proof)
    print(json.dumps(proof, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Network exceptions can contain signed URLs. Deliberately omit their strings.
        if isinstance(exc, (urllib.error.HTTPError, urllib.error.URLError)):
            raise SystemExit('Artifact retrieval failed; no simulator/test was started.') from None
        raise
