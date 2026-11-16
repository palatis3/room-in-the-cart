"""Prepare the pinned GitHub iOS 27 runtime and verify its stability after tests."""
import argparse
import json
import os
import platform
import subprocess
import re
import time
import uuid
import hashlib
import shutil
import stat
from pathlib import Path

evidence = Path('.build/github-ios-runtime')
runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
build = '24A434'
# The successful standalone import and read-only installed-payload hash agree
# on these exact iOS 27.0/24A434 arm64 bytes.
PAYLOAD_BYTES = 8067000161
PAYLOAD_SHA256 = '5136453f500b73dc3518f262d8a51e4be0c136e38a550998febf7759de6ba0fd'

def capture(name, timeout=30):
    raw = subprocess.check_output(['xcrun', 'simctl', 'runtime', 'list', '-j'], text=True, timeout=timeout)
    (evidence / name).write_text(raw)
    value = json.loads(raw)
    assert isinstance(value, dict)
    return value

def targets(rows):
    return [r for r in rows.values() if r.get('runtimeIdentifier') == runtime and r.get('build') == build]

def classify_bulk_result(status, detail, before):
    """Recognize only the two observed aggregate-error forms, bound to this command."""
    if status == 30:
        assert len(before) == 1, 'Ambiguous single-runtime purge error'
        identifier, row = next(iter(before.items()))
        uuid.UUID(identifier)
        assert row.get('identifier') == identifier and row.get('deletable') is True
        assert row.get('state') == 'Ready' and row.get('kind') == 'Patchable Cryptex Disk Image'
        path = row.get('path', '')
        assert re.fullmatch(r'/System/Library/AssetsV2/com_apple_MobileAsset_[A-Za-z0-9_]+SimulatorRuntime/[A-Za-z0-9]+\.asset/AssetData', path)
        assert all(isinstance(row.get(k), str) and row[k] for k in ('runtimeIdentifier', 'build', 'version'))
        expected = [
            'An error was encountered processing the command (domain=com.apple.CoreSimulator.simdiskimaged.SimDiskImageError, code=30):',
            'Removed the runtime, but did not reclaim its MobileAsset: ' + path + '/',
            "Run 'xcrun simctl runtime scan-and-mount' to re-register the runtime, then delete it again.",
        ]
        assert detail.splitlines() == expected, 'Unknown single-runtime purge text or path'
        return [{'identifier': identifier, 'classification': 'mobileasset-not-reclaimed',
                 'form': 'single-runtime-code30', 'runtimeIdentifier': row['runtimeIdentifier'],
                 'build': row['build'], 'version': row['version'], 'path': path, 'lines': expected}]
    if status == 0:
        assert not detail.strip(), 'Unexpected successful bulk-delete output'
        return []
    assert status == 1 and detail.strip(), 'Unknown aggregate-delete exit'
    classified = []
    seen = set()
    for line in detail.splitlines():
        if not line:
            continue
        matches = []
        for identifier, row in before.items():
            assert row['identifier'] == identifier
            # P is the observed Patchable Cryptex prefix, not a generic error parser.
            if row.get('kind') != 'Patchable Cryptex Disk Image':
                continue
            platform_name = row['runtimeIdentifier'].split('.SimRuntime.', 1)[1].split('-', 1)[0]
            prefix = f"Error deleting P: {identifier} {platform_name} ({row['version']} - {row['build']}) "
            deleting = re.fullmatch(
                re.escape(prefix + '(Deleting): Attempting to delete image: ' + identifier +
                          ' (Please retry in ') + r'(0|[1-9][0-9]{0,2})' +
                re.escape('s, if the image is not removed)'), line)
            purging = (prefix + '(Ready): Removed the runtime, but did not reclaim its MobileAsset: ' +
                       row['path'].rstrip('/') + '/')
            if deleting and int(deleting[1]) <= 180:
                matches.append('already-deleting')
            elif (line == purging and row.get('state') == 'Ready' and
                  row['path'].startswith('/System/Library/AssetsV2/com_apple_MobileAsset_') and
                  row['path'].endswith('.asset/AssetData')):
                matches.append('mobileasset-not-reclaimed')
            else:
                continue
            assert identifier not in seen, 'Repeated error for one runtime'
            seen.add(identifier)
            classified.append({'identifier': identifier, 'classification': matches[-1],
                               'runtimeIdentifier': row['runtimeIdentifier'], 'build': row['build'],
                               'version': row['version'], 'path': row['path'], 'line': line})
            if deleting:
                classified[-1]['retrySeconds'] = int(deleting[1])
        assert len(matches) == 1, 'Unknown or ambiguous aggregate-delete line: ' + line
    assert classified
    return classified


def original_catalog(rows):
    """Capture allowed disk-image descendants while the original payloads still exist."""
    catalog = {}
    for key, row in rows.items():
        uuid.UUID(key)
        assert row.get('identifier') == key and row.get('deletable') is True
        root = row['path']
        assert root.startswith(('/System/Library/AssetsV2/com_apple_MobileAsset_',
                                '/Library/Developer/CoreSimulator/'))
        assert '..' not in Path(root).parts
        identity = {k: row[k] for k in ('runtimeIdentifier', 'build', 'version')}
        assert all(isinstance(v, str) and v for v in identity.values())
        if root in catalog:
            assert catalog[root]['identity'] == identity, 'Shared path has conflicting identity'
            continue
        path = Path(root)
        payloads = ([root] if path.is_file() else
                    [str(p) for p in path.rglob('*.dmg') if p.is_file()])
        assert all(str(Path(p).resolve()) == p for p in payloads), 'Unexpected payload symlink'
        catalog[root] = {'identity': identity, 'payloads': sorted(payloads)}
    assert catalog
    return catalog


def validate_original_rows(rows, catalog, *, pending=False):
    for key, row in rows.items():
        uuid.UUID(key)
        assert row.get('identifier') == key and row.get('deletable') is True
        path = row.get('path')
        roots = [root for root, entry in catalog.items()
                 if path == root or (path in entry['payloads'] and row.get('parentMountPath') == root)]
        assert len(roots) == 1, 'Foreign or unrecorded original-asset path'
        for field, value in catalog[roots[0]]['identity'].items():
            assert row.get(field) == value or (pending and row.get(field) is None), 'Original identity changed: ' + field
        allowed = ('Copying', 'Verifying', 'Mounting', 'Ready', 'Unusable', 'Deleting')
        assert row.get('state') in allowed, 'Unexpected original runtime state'


def collect_cleanup_failure(catalog):
    """Read-only best effort: each disk command has its own ten-second ceiling."""
    observations = {'observedAt': time.time(), 'roots': {}, 'commands': {}}
    for root, entry in catalog.items():
        paths = {}
        for value in [root, *entry['payloads']]:
            try:
                path = Path(value)
                paths[value] = {'exists': path.exists(), 'isFile': path.is_file(), 'isDirectory': path.is_dir()}
            except Exception as error:
                paths[value] = {'error': str(error)}
        observations['roots'][root] = paths
    for name, args in [('failure-disks.plist', ['hdiutil', 'info', '-plist']),
                       ('failure-mounts.txt', ['/sbin/mount'])]:
        try:
            raw = subprocess.check_output(args, timeout=10)
            (evidence / name).write_bytes(raw)
            observations['commands'][name] = {'outcome': 'success'}
        except Exception as error:
            observations['commands'][name] = {'outcome': 'failure', 'error': str(error)}
    (evidence / 'failure-filesystem.json').write_text(json.dumps(observations, indent=2) + '\n')


def eligible_asset_recovery(first_errors, second_errors, catalog):
    """Authorize one previously unretried asset, never another bulk cleanup pass."""
    assert len(second_errors) == 1, 'Asset recovery requires exactly one second-pass error'
    error = second_errors[0]
    assert error['classification'] == 'mobileasset-not-reclaimed'
    root = error['path']
    prior_purges = {e['path'] for e in first_errors if e['classification'] == 'mobileasset-not-reclaimed'}
    assert root not in prior_purges, 'This asset already received its purge retry'
    assert root in catalog and catalog[root]['payloads'], 'No original payload recorded for this asset'
    assert all(error.get(k) == value for k, value in catalog[root]['identity'].items())
    return root


def preferred_cryptex_twin(identifier, before, rows, catalog):
    """Bind the observed Ready-to-preferred-Unusable transition to one new asset twin."""
    original, row = before[identifier], rows[identifier]
    root = original['path']
    assert re.fullmatch(r'/System/Library/AssetsV2/com_apple_MobileAsset_[A-Za-z0-9_]+SimulatorRuntime/[A-Za-z0-9]+\.asset/AssetData', root)
    assert catalog[root]['payloads'], 'Preferred twin lacks a recorded original payload'
    assert original.get('state') == 'Ready' and original.get('kind') == 'Patchable Cryptex Disk Image'
    fields = ('identifier', 'path', 'runtimeIdentifier', 'build', 'version', 'kind', 'parentMountPath', 'mountPath')
    assert all(row.get(k) == original.get(k) for k in fields), 'Preferred original identity changed'
    assert row.get('parentMountPath') == root
    assert row.get('state') == 'Unusable'
    assert row.get('unusableSubstate') == row.get('unusableErrorMessage') == 'Cryptex Mount Preferred'
    twins = {key: other for key, other in rows.items() if other.get('path') == root and key != identifier}
    assert len(twins) == 1, 'Preferred original requires exactly one same-asset twin'
    key, twin = next(iter(twins.items()))
    assert key not in before and twin.get('state') == 'Ready', 'Preferred twin is not a new Ready registration'
    validate_original_rows({identifier: row, key: twin}, catalog)
    assert all(twin.get(k) == original.get(k) for k in ('path', 'runtimeIdentifier', 'build', 'version', 'kind', 'parentMountPath'))
    assert twin.get('mountPath', '').startswith('/private/var/run/com.apple.security.cryptexd/mnt/')
    assert twin['mountPath'] != row.get('mountPath'), 'Preferred twin lacks a distinct Cryptex mount'
    return key

def cleanup_original_images(current):
    """Two bulk deletions and at most one documented, asset-specific UUID recovery."""
    import plistlib
    catalog = original_catalog(current)
    (evidence / 'original-payload-catalog.json').write_text(json.dumps(catalog, indent=2) + '\n')
    old_mounts = {r['mountPath'] for r in current.values() if r.get('mountPath')}
    receipt = {'mutationLimit': 3, 'bulkMutationLimit': 2, 'mutations': 0, 'totalDeadlineSeconds': 600, 'stage': 'preflight'}
    deadline = time.monotonic() + 600

    def save():
        (evidence / 'aggregate-cleanup.json').write_text(json.dumps(receipt, indent=2) + '\n')

    def remaining(limit):
        value = min(limit, deadline - time.monotonic())
        assert value > 0, 'Aggregate cleanup exceeded 600 seconds'
        return value

    def observe(name):
        rows = capture(name + '.json', timeout=remaining(30))
        validate_original_rows(rows, catalog, pending=True)
        old_mounts.update(r['mountPath'] for r in rows.values() if r.get('mountPath'))
        return rows

    def disk_state(name):
        raw = subprocess.check_output(['hdiutil', 'info', '-plist'], timeout=remaining(30))
        (evidence / (name + '.plist')).write_bytes(raw)
        mounts = subprocess.check_output(['/sbin/mount'], text=True, timeout=remaining(30))
        (evidence / (name + '.mounts.txt')).write_text(mounts)
        return plistlib.loads(raw), mounts

    def missing_payloads():
        return [p for entry in catalog.values() for p in entry['payloads'] if Path(p).exists()]

    def physical_absence(name, *, allow_pending=False):
        assert not missing_payloads(), 'Original payload remains'
        for root in catalog:
            path = Path(root)
            assert not path.is_file(), 'Original runtime image remains'
            assert not any(p.is_file() for p in path.rglob('*.dmg')), 'Unrecorded original payload remains'
        disks, mounts = disk_state(name)
        pending = []
        for image in disks.get('images', []):
            attached_path = image.get('image-path', '')
            roots = [root for root in catalog if attached_path == root or attached_path.startswith(root.rstrip('/') + '/')]
            image_mounts = {e['mount-point'] for e in image.get('system-entities', []) if e.get('mount-point')}
            if roots:
                assert len(roots) == 1
                root = roots[0]
                assert attached_path == root or attached_path in catalog[root]['payloads'], 'Unrecorded original image remains attached'
                assert all(m.startswith(('/Library/Developer/CoreSimulator/Volumes/',
                                         '/private/var/run/com.apple.security.cryptexd/mnt/')) for m in image_mounts), 'Unexpected original image mount path'
                old_mounts.update(image_mounts)
                pending.append('Old runtime image remains attached: ' + attached_path)
            else:
                assert not old_mounts.intersection(image_mounts), 'Foreign image occupies an old runtime mount'
        if any(os.path.ismount(m) for m in old_mounts):
            pending.append('Old runtime volume is still mounted')
        if any(' on ' + m + ' (' in mounts for m in old_mounts):
            pending.append('Old runtime mount remains')
        (evidence / (name + '-pending.json')).write_text(json.dumps(pending, indent=2) + '\n')
        if not allow_pending:
            assert not pending, '; '.join(pending)
        return not pending

    def command(name, args, *, before=None):
        receipt['stage'] = name
        if before is not None:
            if args == ['xcrun', 'simctl', 'runtime', 'delete', 'all']:
                assert receipt['mutations'] < 2, 'No third bulk deletion permitted'
            else:
                assert name == 'delete-recovered-asset' and receipt['mutations'] == 2
                assert len(before) == 1 and args == ['xcrun', 'simctl', 'runtime', 'delete', next(iter(before))]
                assert receipt.get('assetRecoveryRoot'), 'Exact deletion lacks recovery authorization'
            receipt['mutations'] += 1
            (evidence / (name + '-before.json')).write_text(json.dumps(before, indent=2) + '\n')
        save()
        with (evidence / (name + '.log')).open('w') as output:
            result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT, timeout=remaining(300 if before is not None else 60))
        (evidence / (name + '-exit.json')).write_text(json.dumps({'exit': result.returncode}) + '\n')
        if before is None:
            result.check_returncode()
        else:
            if name == 'delete-recovered-asset':
                result.check_returncode()  # No fourth mutation or further recovery on any error.
            classified = classify_bulk_result(result.returncode, (evidence / (name + '.log')).read_text(), before)
            (evidence / (name + '-classification.json')).write_text(json.dumps({
                'exit': result.returncode, 'requiresVerification': True, 'recognizedErrors': classified}, indent=2) + '\n')
            return classified

    retained_preferred = {}

    def validate_retained(rows, before):
        for key in set(before).intersection(rows):
            assert key in retained_preferred, 'Original UUID returned after retirement'
            assert preferred_cryptex_twin(key, before, rows, catalog) == retained_preferred[key], 'Preferred twin changed'

    def wait_retired(before, name, *, allow_recreated, recreated_catalog=None, allow_preferred=False, deleting_errors=()):
        until = time.monotonic() + remaining(210)
        attempt = 0
        while True:
            rows = observe(name + '-' + str(attempt))
            for key, row in rows.items():
                if key in before:
                    assert all(row.get(k) == before[key].get(k) for k in ('identifier', 'path', 'runtimeIdentifier', 'build', 'version'))
                    if key in deleting_errors and row.get('state') == 'Unusable':
                        original = before[key]
                        assert original.get('state') == 'Deleting' and original.get('kind') == 'Patchable Cryptex Disk Image'
                        assert re.fullmatch(r'/System/Library/AssetsV2/com_apple_MobileAsset_[A-Za-z0-9_]+SimulatorRuntime/[A-Za-z0-9]+\.asset/AssetData', original['path'])
                        assert original.get('parentMountPath') == original['path']
                        assert all(row.get(k) == original.get(k) for k in ('kind', 'parentMountPath', 'mountPath'))
                        assert row.get('unusableSubstate') == row.get('unusableErrorMessage') == 'Cryptex Mount Preferred'
                        # Still outstanding: this observation never authorizes another deletion.
                        receipt.setdefault('pendingPreferredRetirements', {})[key] = attempt
                        save()
                    elif row.get('state') != 'Deleting':
                        assert allow_preferred, 'Old registration did not enter Deleting'
                        twin = preferred_cryptex_twin(key, before, rows, catalog)
                        assert retained_preferred.get(key, twin) == twin, 'Preferred twin changed'
                        assert key in retained_preferred or not retained_preferred, 'More than one preferred original/twin pair'
                        retained_preferred[key] = twin
                        receipt['retainedPreferredTwins'] = dict(retained_preferred)
                        save()
                else:
                    if not allow_recreated:
                        assert recreated_catalog is not None, 'Runtime recreated after final deletion; no further mutation permitted'
                        validate_original_rows({key: row}, recreated_catalog, pending=True)
            if recreated_catalog is not None:
                assert len(set(rows) - set(before)) <= 1, 'Asset recovery exposed more than one registration'
            remaining_originals = set(before).intersection(rows)
            if allow_preferred:
                remaining_originals -= {key for key in retained_preferred if rows.get(key, {}).get('state') == 'Unusable'}
            if not remaining_originals:
                return rows
            assert time.monotonic() < until, 'Original deletion did not retire within 210 seconds'
            time.sleep(max(0, min(5, until - time.monotonic(), remaining(5))))
            attempt += 1

    def all_ready(rows):
        validate_original_rows(rows, catalog)
        return all(r.get('state') in ('Ready', 'Unusable') for r in rows.values())

    def payloads_registered(rows):
        for root, entry in catalog.items():
            surviving = [p for p in entry['payloads'] if Path(p).exists()]
            if surviving and not any(r.get('path') == root for r in rows.values()):
                if not all(any(r.get('path') == p for r in rows.values()) for p in surviving):
                    return False
        return True

    try:
        save()
        disk_state('disks-before-removal')
        command('delete-all-dry-run', ['xcrun', 'simctl', 'runtime', 'delete', 'all', '--dry-run'])
        first = observe('delete-all-current')
        validate_original_rows(first, catalog)
        assert first, 'Runtime inventory disappeared before command'
        first_errors = command('delete-all', ['xcrun', 'simctl', 'runtime', 'delete', 'all'], before=first)
        wait_retired(first, 'all-removal-wait', allow_recreated=True, allow_preferred=not first_errors,
                     deleting_errors={e['identifier'] for e in first_errors if e['classification'] == 'already-deleting'})
        command('purge-recovery-scan', ['xcrun', 'simctl', 'runtime', 'scan-and-mount'])
        until = time.monotonic() + remaining(120)
        count = 0
        while True:
            rows = observe('recovery-settle-' + str(count))
            validate_retained(rows, first)
            # Pending identities are observable but can never authorize deletion.
            known = all(all(r.get(k) for k in ('runtimeIdentifier', 'build', 'version')) for r in rows.values())
            if known and all_ready(rows) and payloads_registered(rows):
                break
            assert time.monotonic() < until, 'Recovery scan did not settle within 120 seconds'
            time.sleep(max(0, min(5, until - time.monotonic(), remaining(5))))
            count += 1
        second_errors = []
        asset_recovery_root = None
        if rows:
            second = observe('delete-recreated-current')
            assert second, 'Recreated inventory disappeared before second deletion'
            validate_retained(second, first)
            assert all_ready(second) and payloads_registered(second), 'Recovery changed before second deletion'
            second_errors = command('delete-recreated-originals', ['xcrun', 'simctl', 'runtime', 'delete', 'all'], before=second)
            if any(e['classification'] == 'mobileasset-not-reclaimed' for e in second_errors):
                asset_recovery_root = eligible_asset_recovery(first_errors, second_errors, catalog)
                receipt['assetRecoveryRoot'] = asset_recovery_root
                save()
            wait_retired(second, 'recreated-removal-wait', allow_recreated=False,
                         recreated_catalog={asset_recovery_root: catalog[asset_recovery_root]} if asset_recovery_root else None)
        if asset_recovery_root is not None:
            root = asset_recovery_root
            scoped_catalog = {root: catalog[root]}
            command('asset-recovery-scan', ['xcrun', 'simctl', 'runtime', 'scan-and-mount'])
            until = time.monotonic() + remaining(120)
            count = 0
            while True:
                recovered = observe('asset-recovery-settle-' + str(count))
                assert len(recovered) <= 1, 'Asset recovery exposed more than one registration'
                validate_original_rows(recovered, scoped_catalog, pending=True)
                known = all(all(r.get(k) for k in ('runtimeIdentifier', 'build', 'version')) for r in recovered.values())
                if recovered and known and all_ready(recovered):
                    break
                assert time.monotonic() < until, 'Asset recovery did not settle within 120 seconds'
                time.sleep(max(0, min(5, until - time.monotonic(), remaining(5))))
                count += 1
            exact = observe('delete-recovered-asset-current')
            assert len(exact) == 1 and set(exact) == set(recovered), 'Recovered UUID changed before deletion'
            validate_original_rows(exact, scoped_catalog)
            assert all_ready(exact)
            for key, row in exact.items():
                assert all(row.get(k) == recovered[key].get(k) for k in ('identifier', 'path', 'runtimeIdentifier', 'build', 'version'))
            command('delete-recovered-asset', ['xcrun', 'simctl', 'runtime', 'delete', next(iter(exact))], before=exact)
            wait_retired(exact, 'asset-recovery-removal-wait', allow_recreated=False)
        assert not observe('all-before-confirmation'), 'Runtime remains before confirmation'
        command('confirm-removal-scan', ['xcrun', 'simctl', 'runtime', 'scan-and-mount'])
        receipt['stage'] = 'physical-settle'; save()
        until = time.monotonic() + remaining(210)
        count = 0
        while True:
            assert not observe('physical-settle-' + str(count)), 'Runtime registration reappeared during physical settle'
            if physical_absence('disks-settle-' + str(count), allow_pending=True):
                break
            assert time.monotonic() < until, 'Original physical cleanup did not settle within 210 seconds'
            time.sleep(max(0, min(5, until - time.monotonic(), remaining(5))))
            count += 1
        receipt['stage'] = 'sustained-absence'; save()
        until = time.monotonic() + 60
        count = 0
        while True:
            assert not observe('all-absence-' + str(count)), 'Runtime registration reappeared'
            physical_absence('disks-absence-' + str(count))
            if time.monotonic() >= until:
                break
            time.sleep(max(0, min(5, until - time.monotonic(), remaining(5))))
            count += 1
        receipt.update(outcome='success', absenceObservations=count + 1, oldMounts=sorted(old_mounts))
        save()
        return old_mounts, count + 1
    except BaseException as error:
        receipt.update(outcome='failure', error=str(error))
        # A diagnostic failure must never replace the cleanup exception.
        try:
            save()
        except BaseException:
            pass
        try:
            collect_cleanup_failure(catalog)
        except BaseException:
            pass
        raise


def refresh_user_service(expected):
    """Refresh the current user service once, before any simulator creation or boot."""
    assert os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
    assert os.environ.get('GITHUB_ACTIONS') == 'true'
    assert platform.system() == 'Darwin' and platform.machine() == 'arm64'
    assert os.environ.get('DEVELOPER_DIR') == '/Applications/Xcode_27.1.app/Contents/Developer'
    uid = os.getuid()
    assert uid != 0
    p = evidence
    pattern = r'com\.apple\.CoreSimulator\.CoreSimulatorService'
    receipt = {'uid': uid, 'signal': 'TERM', 'scope': 'one pre-create refresh, no sudo or escalation'}
    def save():
        (p / 'service-refresh.json').write_text(json.dumps(receipt, indent=2) + '\n')
    def pids():
        r = subprocess.run(['/usr/bin/pgrep', '-u', str(uid), '-x', pattern], capture_output=True, text=True, timeout=10)
        assert r.returncode in (0, 1), r.stderr
        return [int(s) for s in r.stdout.split()]
    def inventory(name):
        raw = subprocess.check_output(['xcrun', 'simctl', 'list', '-j'], text=True, timeout=60)
        (p / name).write_text(raw)
        d = json.loads(raw)
        assert all(v['state'] == 'Shutdown' for rows in d['devices'].values() for v in rows), 'A simulator is active; do not refresh its service'
        targets = [r for r in d['runtimes'] if r['identifier'] == expected['runtimeIdentifier']]
        assert len(targets) == 1 and targets[0].get('isAvailable') is True
        r = targets[0]
        assert r['buildversion'] == expected['build'] and r['bundlePath'] == expected['runtimeBundlePath']
        assert Path(r['runtimeRoot']).is_dir(), 'RuntimeRoot is unavailable'
        raw = subprocess.check_output(['xcrun', 'simctl', 'runtime', 'list', '-j'], text=True, timeout=30)
        (p / (name + '.images.json')).write_text(raw)
        rows = json.loads(raw)
        targets = [r for r in rows.values() if r.get('runtimeIdentifier') == expected['runtimeIdentifier'] and r.get('build') == expected['build']]
        assert len(targets) == 1
        r = targets[0]
        for key in ('identifier', 'build', 'runtimeIdentifier', 'path', 'mountPath', 'runtimeBundlePath', 'state', 'kind'):
            assert r.get(key) == expected.get(key), key
        assert r['kind'] == 'Disk Image' and r['state'] == 'Ready'
        assert not r.get('parentMountPath') and not r.get('parentIdentifier')
        assert Path(r['path']).is_file() and Path(r['mountPath']).is_dir() and Path(r['runtimeBundlePath']).is_dir()
    try:
        inventory('service-before.json')
        old = pids(); assert len(old) == 1, old
        detail = subprocess.check_output(['/bin/ps', '-p', str(old[0]), '-o', 'uid=', '-o', 'comm='], text=True, timeout=10).strip()
        owner, command = detail.split(None, 1)
        assert int(owner) == uid and Path(command).name == 'com.apple.CoreSimulator.CoreSimulatorService', detail
        receipt.update(oldPids=old, oldProcess=detail, beforeVerified=True, signalSent=False); save()
        result = subprocess.run(['/usr/bin/pkill', '-TERM', '-u', str(uid), '-x', pattern], capture_output=True, text=True, timeout=10)
        receipt.update(signalSent=True, signalExit=result.returncode, signalStderr=result.stderr); save()
        result.check_returncode()
        deadline = time.monotonic() + 60
        while set(old).intersection(pids()):
            assert time.monotonic() < deadline, 'Original service did not exit; no escalation permitted'
            time.sleep(1)
        receipt['oldExited'] = True; save()
        inventory('service-after.json')
        new = pids(); assert len(new) == 1 and not set(old).intersection(new), new
        receipt.update(newPids=new, afterVerified=True, outcome='success'); save()
    except BaseException as error:
        receipt.update(outcome='failure', error=str(error)); save(); raise


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def payload_identity(info):
    assert stat.S_ISREG(info.st_mode), 'Payload must be a regular file'
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def preserve_original_payload(before):
    selected = targets(before)
    assert any(r.get('state') == 'Ready' for r in selected)
    assert len({r['path'] for r in selected}) == 1, 'Ambiguous original target asset'
    assert all(r.get('version') == '27.0' and
               r.get('platformIdentifier') == 'com.apple.platform.iphonesimulator' and
               r.get('kind') in ('Patchable Cryptex Disk Image', 'Disk Image') and
               r.get('supportedArchitectures') == ['arm64'] for r in selected)
    root = selected[0]['path']
    catalog = original_catalog(before)
    payloads = catalog[root]['payloads']
    assert len(payloads) == 1, 'Expected one original disk-image payload'
    source = Path(payloads[0])
    assert source.resolve() == source
    relative_payload = str(source.relative_to(root))
    identity = payload_identity(source.lstat())
    assert identity[2] == PAYLOAD_BYTES, 'Original payload size differs from qualified image'
    export = Path('.build/runtime-export')
    export.mkdir()
    saved_image = export.resolve() / source.name
    assert not str(saved_image).startswith(('/System/Library/AssetsV2/', '/Library/Developer/CoreSimulator/'))
    with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as original, saved_image.open('xb') as saved:
        assert payload_identity(os.fstat(original.fileno())) == identity, 'Original payload was replaced'
        shutil.copyfileobj(original, saved, 1024 * 1024)
        assert payload_identity(os.fstat(original.fileno())) == identity, 'Original payload changed during copy'
    assert payload_identity(source.lstat()) == identity, 'Original payload was replaced during copy'
    assert saved_image.stat().st_size == PAYLOAD_BYTES and sha256(saved_image) == PAYLOAD_SHA256, 'Saved payload differs from qualified image'
    (evidence / 'saved-payload.json').write_text(json.dumps({
        'mode': 'copy-original', 'source': str(source), 'sourceRoot': root,
        'relativePayload': relative_payload, 'sourceIdentity': identity,
        'path': str(saved_image), 'bytes': PAYLOAD_BYTES, 'sha256': PAYLOAD_SHA256}) + '\n')
    return saved_image, source, identity, catalog


def prepare():
    assert os.environ.get('GITHUB_REPOSITORY') == 'palatis3/room-in-the-cart'
    assert os.getuid() != 0
    before = capture('before.json')
    saved_image, source, identity, catalog = preserve_original_payload(before)
    saved_identity = payload_identity(saved_image.lstat())
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j'], text=True, timeout=30))
    assert all(d['state'] == 'Shutdown' for rows in devices['devices'].values() for d in rows)
    current = capture('all-before-removal.json')
    assert current, 'No preloaded runtimes to isolate'
    validate_original_rows(current, catalog)
    assert payload_identity(source.lstat()) == identity, 'Original payload changed before cleanup'
    assert payload_identity(saved_image.lstat()) == saved_identity, 'Saved payload changed before cleanup'
    old_mounts, absence_observations = cleanup_original_images(current)
    assert saved_image.is_file() and sha256(saved_image) == PAYLOAD_SHA256
    (evidence / 'all-removal-verified.json').write_text(json.dumps({'registrations': 0, 'oldMounts': sorted(old_mounts),
        'absenceObservations': absence_observations, 'savedPayloadSha256': PAYLOAD_SHA256}) + '\n')
    def original_rows(rows):
        # No other preloaded runtime is allowed to return during this experiment.
        return [r for r in rows.values() if r.get('runtimeIdentifier') != runtime or r.get('build') != build]
    disk_image = saved_image
    (evidence / 'import-input.json').write_text(json.dumps({
        'mode': 'direct-dmg', 'path': str(disk_image.resolve()),
        'relativePayload': str(source.relative_to(targets(before)[0]['path']))}) + '\n')
    with (evidence / 'import.log').open('w') as log:
        subprocess.run(['sudo', '-n', '/usr/bin/env',
                        'DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer',
                        '/usr/bin/xcodebuild', '-importPlatform', str(disk_image.resolve())],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    after = capture('after-import.json')
    assert not original_rows(after), 'Original asset reappeared during import'
    installed = targets(after)
    assert len(installed) == 1 and installed[0].get('state') == 'Ready'
    target = installed[0]
    assert target.get('kind') == 'Disk Image', target
    assert not target.get('parentMountPath') and not target.get('parentIdentifier'), target
    assert target.get('mountPath') and Path(target['mountPath']).is_dir()
    path = target.get('path', '')
    assert path.startswith('/Library/Developer/CoreSimulator/') and '/Images/' in path, path
    assert Path(path).exists() and Path(target['runtimeBundlePath']).is_dir()
    assert 'arm64' in target.get('supportedArchitectures', [])
    (evidence / 'target.json').write_text(json.dumps(target, indent=2) + '\n')
    refresh_user_service(target)
    print('Imported iOS 27.0/24A434 runtime and refreshed user service verified.')


def verify():
    current = capture('after-tests.json')
    before = json.loads((evidence / 'target.json').read_text())
    # Preserve physical availability even when registry mount metadata vanishes.
    # This is diagnostic evidence only: the identity/mount assertions below stay strict.
    filesystem = {'observedAt': time.time(), 'paths': {}}
    for key in ('path', 'mountPath', 'runtimeBundlePath'):
        value = before.get(key)
        filesystem['paths'][key] = {
            'path': value,
            'exists': Path(value).exists() if value else None,
            'isDirectory': Path(value).is_dir() if value else None,
        }
        if key == 'mountPath':
            filesystem['paths'][key]['isMount'] = os.path.ismount(value) if value else None
    (evidence / 'verification-filesystem.json').write_text(json.dumps(filesystem, indent=2) + '\n')
    installed = targets(current)
    assert len(current) == 1, 'An unused runtime reappeared'
    assert len(installed) == 1, 'Expected exactly one target registration'
    after = installed[0]
    assert after['state'] == 'Ready'
    assert after.get('kind') == 'Disk Image', after
    assert not after.get('parentMountPath') and not after.get('parentIdentifier'), after
    assert after.get('mountPath') and Path(after['mountPath']).is_dir()
    for key in ('identifier', 'build', 'runtimeIdentifier', 'path', 'mountPath', 'runtimeBundlePath'):
        assert before.get(key) == after.get(key), 'Runtime changed during tests: ' + key
    assert Path(after['path']).exists() and Path(after['runtimeBundlePath']).is_dir()
    print('Imported runtime identity, mount and bundle retained.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('prepare', 'verify'))
    args = parser.parse_args()
    assert os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
    assert os.environ.get('GITHUB_ACTIONS') == 'true'
    assert platform.system() == 'Darwin' and platform.machine() == 'arm64'
    assert os.environ.get('CI_IPHONE_RUNTIME') == runtime
    assert os.environ.get('DEVELOPER_DIR') == '/Applications/Xcode_27.1.app/Contents/Developer'
    evidence.mkdir(parents=True, exist_ok=True)
    if args.operation == 'prepare':
        prepare()
    else:
        verify()


if __name__ == '__main__':
    main()
