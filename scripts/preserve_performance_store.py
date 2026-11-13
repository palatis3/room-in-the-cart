#!/usr/bin/env python3
"""Preserve only an attempted fresh-device pilot's synthetic ledger before cleanup."""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time
from uuid import UUID

from select_ci_iphone import owner_identity, owned_name

RECEIPT = 'test-simulator-ownership.json'
ATTEMPT = 'native-attempt.json'
OUTCOME = 'store-preservation.json'
SNAPSHOT = 'ledger-snapshot.sqlite'
TOTAL_SECONDS = 90
COMMAND_SECONDS = 30
MAX_STORE_BYTES = 32 * 1024 * 1024
MAX_COMMAND_BYTES = 1024 * 1024


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(65536), b''):
            value.update(chunk)
    return value.hexdigest()


def load(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise ValueError('Invalid metadata file')
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError('Invalid metadata object')
    return value


def save(path, value):
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('x') as output:
        json.dump(value, output, indent=2)
        output.write('\n')
    temporary.replace(path)


def owned(folder):
    path = folder / RECEIPT
    if not path.exists() and not path.is_symlink():
        return None
    receipt = load(path)
    if (receipt.get('schema') != 1 or receipt.get('owner') != owner_identity()
            or receipt.get('createdName') != owned_name(receipt['owner'], receipt['nonce'])):
        raise ValueError('Ownership mismatch')
    created = receipt.get('createdUDID')
    if created is not None and (str(UUID(created)).upper() != created
            or created == str(UUID(receipt['sourceUDID'])).upper()
            or os.environ.get('SIMULATOR_ID', created) != created):
        raise ValueError('Owned UUID mismatch')
    return receipt


def binding(folder, receipt):
    return {'owner': owner_identity(), 'createdUDID': receipt.get('createdUDID') if receipt else None,
            'ownershipSHA256': digest(folder / RECEIPT) if receipt else None}


def mark_attempt(folder):
    receipt = owned(folder)
    if not receipt or not receipt.get('createdUDID') or receipt.get('creationStatus') != 'verified':
        raise ValueError('Native attempt requires verified owned creation')
    path = folder / ATTEMPT
    if path.exists() or path.is_symlink():
        raise ValueError('Native attempt already recorded')
    save(path, {'schema': 1, **binding(folder, receipt),
                'startUTC': datetime.now(timezone.utc).isoformat()})


def remaining(deadline):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise TimeoutError('Preservation deadline')
    return seconds


def command(args, deadline):
    result = subprocess.run(['xcrun', 'simctl', *args], check=True, capture_output=True,
                            timeout=min(COMMAND_SECONDS, remaining(deadline)))
    if len(result.stdout) > MAX_COMMAND_BYTES or len(result.stderr) > MAX_COMMAND_BYTES:
        raise ValueError('Command output cap')
    return result.stdout.decode('utf-8').strip()


def current_device(receipt, deadline):
    inventory = json.loads(command(['list', '-j'], deadline))
    runtime = receipt['runtime']
    matches = [r for r in inventory['runtimes'] if r.get('identifier') == runtime['identifier']]
    if (len(matches) != 1 or matches[0].get('isAvailable') is not True
            or {key: matches[0].get(key) for key in ('identifier', 'version', 'buildversion', 'bundlePath')} != runtime):
        raise ValueError('Runtime identity changed')
    devices = [(r, d) for r, rows in inventory['devices'].items() for d in rows
               if d.get('udid') == receipt['createdUDID']]
    if len(devices) != 1:
        raise ValueError('Owned device missing or ambiguous')
    runtime_id, device = devices[0]
    if (runtime_id != runtime['identifier'] or device.get('name') != receipt['createdName']
            or device.get('deviceTypeIdentifier') != receipt['deviceTypeIdentifier']
            or device.get('isAvailable') is not True or device.get('state') not in ('Booted', 'Shutdown')):
        raise ValueError('Owned device identity changed')


def ledger_path(receipt, container):
    # Accept only the exact owned default device-set container, never an arbitrary path.
    root = Path.home() / 'Library/Developer/CoreSimulator/Devices' / receipt['createdUDID'] / 'data/Containers/Data/Application'
    path = Path(container)
    if (not path.is_absolute() or path.parent != root or str(UUID(path.name)).upper() != path.name.upper()
            or path.resolve() != path or not path.is_dir()):
        raise ValueError('Container is outside the owned device')
    store = path / 'Library/Application Support/RoomInTheCart/ledger.sqlite'
    if store.resolve() != store or not store.is_file():
        raise ValueError('Owned ledger unavailable')
    for candidate in (store, Path(str(store) + '-wal'), Path(str(store) + '-shm')):
        if candidate.is_symlink() or (candidate.exists() and candidate.stat().st_size > MAX_STORE_BYTES):
            raise ValueError('Unsafe or oversized ledger')
    return store


def snapshot(store, destination, deadline):
    if destination.exists() or destination.is_symlink():
        raise ValueError('Snapshot already exists')
    temporary = destination.with_name(destination.name + '.partial')
    with temporary.open('xb'):
        pass
    try:
        with closing(sqlite3.connect(store.as_uri() + '?mode=ro', uri=True, timeout=1)) as source:
            source.execute('PRAGMA query_only=ON')
            page_size = source.execute('PRAGMA page_size').fetchone()[0]
            def progress(status, pages_left, pages_total):
                remaining(deadline)
                if pages_total * page_size > MAX_STORE_BYTES:
                    raise ValueError('Snapshot size cap')
            with closing(sqlite3.connect(temporary, timeout=1)) as target:
                source.backup(target, pages=128, progress=progress, sleep=0.05)
                target.set_progress_handler(lambda: int(time.monotonic() >= deadline), 1000)
                if target.execute('PRAGMA quick_check').fetchall() != [('ok',)]:
                    raise ValueError('Snapshot integrity failed')
        remaining(deadline)
        if temporary.stat().st_size > MAX_STORE_BYTES:
            raise ValueError('Snapshot size cap')
        temporary.replace(destination)
        return {'snapshot': SNAPSHOT, 'snapshotSHA256': digest(destination), 'snapshotBytes': destination.stat().st_size}
    finally:
        if temporary.exists():
            temporary.unlink()


def preserve(folder):
    deadline = time.monotonic() + TOTAL_SECONDS
    result = {'schema': 1, 'status': 'running', 'stage': 'ownership', 'cleanupAllowed': False}
    save(folder / OUTCOME, result)
    try:
        receipt = owned(folder)
        result.update(binding(folder, receipt))
        attempt_path = folder / ATTEMPT
        attempted = attempt_path.exists() or attempt_path.is_symlink()
        result['attemptSHA256'] = None
        if attempted:
            attempt = load(attempt_path)
            result['attemptSHA256'] = digest(attempt_path)
            if attempt.get('schema') != 1 or any(attempt.get(key) != result[key] for key in binding(folder, receipt)):
                raise ValueError('Native attempt ownership changed')
            if not receipt or not receipt.get('createdUDID') or receipt.get('creationStatus') != 'verified':
                raise ValueError('Native attempt has no verified owned device')
            result['stage'] = 'device'; save(folder / OUTCOME, result)
            current_device(receipt, deadline)
            result['stage'] = 'container'; save(folder / OUTCOME, result)
            container = command(['get_app_container', receipt['createdUDID'], 'dev.roominthecart.app', 'data'], deadline)
            store = ledger_path(receipt, container)
            result['stage'] = 'snapshot'; save(folder / OUTCOME, result)
            result.update(snapshot(store, folder / SNAPSHOT, deadline))
            result['status'] = 'preserved'
        else:
            result['status'] = 'not-attempted' if receipt and receipt.get('createdUDID') else 'no-owned-device'
        result.update(stage='complete', cleanupAllowed=True)
        save(folder / OUTCOME, result)
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError) as error:
        # Never retain command stderr, container paths or database content in metadata.
        result.update(status='failed', cleanupAllowed=False, errorType=type(error).__name__)
        save(folder / OUTCOME, result)
        raise


def require_preserved(folder):
    result = load(folder / OUTCOME)
    receipt = owned(folder)
    if (result.get('schema') != 1 or result.get('cleanupAllowed') is not True
            or result.get('stage') != 'complete'
            or any(result.get(key) != value for key, value in binding(folder, receipt).items())):
        raise ValueError('Cleanup lacks matching preservation evidence')
    attempt = folder / ATTEMPT
    if attempt.exists() or attempt.is_symlink():
        load(attempt)
        store = folder / SNAPSHOT
        if (result.get('status') != 'preserved' or result.get('attemptSHA256') != digest(attempt)
                or result.get('snapshot') != SNAPSHOT or store.is_symlink() or not store.is_file()
                or store.stat().st_size > MAX_STORE_BYTES or result.get('snapshotBytes') != store.stat().st_size
                or result.get('snapshotSHA256') != digest(store)):
            raise ValueError('Attempted run snapshot missing or changed')
    elif result.get('attemptSHA256') is not None or result.get('status') != (
            'not-attempted' if receipt and receipt.get('createdUDID') else 'no-owned-device'):
        raise ValueError('Attempt state changed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('mark-attempt', 'preserve', 'require-preserved'))
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == 'preserve':
            args.evidence.mkdir(parents=True, exist_ok=True)
        if args.evidence.is_symlink() or not args.evidence.is_dir():
            raise ValueError('Evidence directory unavailable')
        {'mark-attempt': mark_attempt, 'preserve': preserve, 'require-preserved': require_preserved}[args.action](args.evidence)
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError) as error:
        parser.exit(1, f'Performance store preservation failed ({type(error).__name__}).\n')


if __name__ == '__main__':
    main()
