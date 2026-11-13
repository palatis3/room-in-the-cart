#!/usr/bin/env python3
"""Observe selected-runtime checker bytes; never infer effective process loading."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import tempfile
import time
from uuid import UUID

import performance_plan_provenance as provenance
from check_ios_performance_environment import configured_environment

LIBRARY = 'libMainThreadChecker.dylib'
MAX_LIBRARY = 8 * 1024 * 1024
MAX_INVENTORY = 2 * 1024 * 1024
RUNTIME_BUNDLE = re.compile(
    r'/(?:private/)?var/run/com\.apple\.security\.cryptexd/mnt/[A-Za-z0-9][A-Za-z0-9_.-]*/'
    r'Library/Developer/CoreSimulator/Profiles/Runtimes/iOS ([0-9.]+)\.simruntime')
require = provenance.require


def inventory():
    # Fixed read-only query. Bound duration and retained/read bytes; never emit
    # arbitrary simulator inventory or subprocess stderr into the receipt.
    with tempfile.TemporaryFile() as output:
        subprocess.run(['xcrun', 'simctl', 'list', '-j'], stdout=output,
                       stderr=subprocess.DEVNULL, check=True, timeout=30)
        require(output.tell() <= MAX_INVENTORY, 'inventory_size')
        output.seek(0)
        return json.loads(output.read(MAX_INVENTORY + 1), object_pairs_hook=provenance.unique_pairs)


def selected_runtime(data, env):
    configured = configured_environment(env, 'arm64')
    device_id = str(UUID(env['SIMULATOR_ID'])).upper()
    matches = [(runtime, row) for runtime, rows in data['devices'].items() for row in rows
               if row.get('udid') == device_id]
    require(len(matches) == 1 and matches[0][0] == env['CI_IPHONE_RUNTIME']
            and matches[0][1].get('isAvailable') is True, 'selected_device')
    device = matches[0][1]
    types = [row for row in data['devicetypes'] if row.get('identifier') == device.get('deviceTypeIdentifier')]
    require(len(types) == 1 and types[0].get('name') == configured['modelName'], 'selected_device_type')
    rows = [row for row in data['runtimes'] if row.get('identifier') == matches[0][0]]
    require(len(rows) == 1 and rows[0].get('isAvailable') is True, 'selected_runtime')
    runtime = rows[0]
    require(runtime.get('version') == configured['osVersion']
            and isinstance(runtime.get('buildversion'), str)
            and re.fullmatch(r'[A-Za-z0-9.]{1,64}', runtime['buildversion']), 'runtime_version_build')
    bundle = runtime.get('bundlePath')
    match = RUNTIME_BUNDLE.fullmatch(bundle) if isinstance(bundle, str) else None
    require(match is not None and match[1] == runtime['version'], 'runtime_bundle_root')
    return {'deviceID': device_id, 'deviceType': device['deviceTypeIdentifier'],
            'identifier': runtime['identifier'], 'version': runtime['version'],
            'build': runtime['buildversion'], 'bundlePathSHA256': hashlib.sha256(bundle.encode()).hexdigest()}, Path(bundle)


def arm64_uuid(data):
    """Read only Mach-O headers/load commands, including a universal arm64 slice."""
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide = data[:4] == b'\xca\xfe\xba\xbf'
        count = struct.unpack_from('>I', data, 4)[0]
        require(0 < count <= 16, 'macho_arch_count')
        matches = []
        for index in range(count):
            offset = 8 + index * (32 if wide else 20)
            cpu = struct.unpack_from('>I', data, offset)[0]
            start, size = struct.unpack_from('>QQ' if wide else '>II', data, offset + 8)
            require(start >= 8 + count * (32 if wide else 20) and size > 0
                    and start + size <= len(data), 'macho_slice_bounds')
            if cpu == 0x0100000C:
                matches.append(data[start:start + size])
        require(len(matches) == 1, 'macho_arm64_slice')
        data = matches[0]
    require(len(data) >= 32 and data[:4] == b'\xcf\xfa\xed\xfe'
            and struct.unpack_from('<I', data, 4)[0] == 0x0100000C, 'macho_arm64_header')
    count, size = struct.unpack_from('<II', data, 16)
    require(0 < count <= 4096 and 32 + size <= len(data), 'macho_commands')
    offset, uuids = 32, []
    for _ in range(count):
        require(offset + 8 <= 32 + size, 'macho_command_bounds')
        command, length = struct.unpack_from('<II', data, offset)
        require(length >= 8 and length % 8 == 0 and offset + length <= 32 + size, 'macho_command_bounds')
        if command == 0x1B:
            require(length == 24, 'macho_uuid_size')
            uuids.append(str(UUID(bytes=data[offset + 8:offset + 24])).upper())
        offset += length
    require(offset == 32 + size and len(uuids) == 1, 'macho_uuid_count')
    return uuids[0]


def checker_identity(bundle, deadline):
    path = bundle / 'Contents/Resources/RuntimeRoot/usr/lib' / LIBRARY
    row = {'library': LIBRARY, 'location': 'selected-runtime', 'status': 'missing'}
    if not path.exists() and not path.is_symlink():
        return row
    # Only normal runtime files: no leaf or intermediate redirection to another
    # library. /var -> /private/var is allowed by the exact runtime-root policy.
    require(not path.is_symlink() and path.resolve() == bundle.resolve() / path.relative_to(bundle), 'checker_redirected')
    require(RUNTIME_BUNDLE.fullmatch(str(bundle.resolve())) is not None, 'resolved_runtime_root')
    before = path.stat()
    require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= MAX_LIBRARY, 'checker_size_type')
    with path.open('rb') as source:
        data = source.read(MAX_LIBRARY + 1)
    after = path.stat()
    require((before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode) ==
            (after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode)
            and len(data) == before.st_size, 'checker_changed')
    provenance.check_time(deadline)
    return {**row, 'status': 'readable', 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
            'architecture': 'arm64', 'uuid': arm64_uuid(data)}


def bind_plan(receipt_path, products, context, checker):
    require(not receipt_path.is_symlink(), 'provenance_symlink')
    raw = provenance.metadata_bytes(receipt_path)
    receipt = json.loads(raw, object_pairs_hook=provenance.unique_pairs)
    require(receipt['schema'] == 1 and receipt['role'] == 'consumer' and receipt['status'] == 'passed'
            and receipt['context'] == context and receipt['comparison']['immutableMatch'] is True,
            'consumer_provenance_identity')
    name = receipt['immutable']['planName']
    require(isinstance(name, str) and re.fullmatch(r'RoomInTheCart-Performance_iphonesimulator[0-9.]+-[A-Za-z0-9_-]+\.xctestrun', name), 'plan_name')
    plan = provenance.regular(products / name, products)
    plan_sha = hashlib.sha256(provenance.metadata_bytes(plan)).hexdigest()
    require(plan_sha == receipt['immutable']['planSHA256'], 'plan_changed')
    observations = receipt['comparison']['producerObservations']
    provenance.validate_observations(observations)
    expected = [row for row in observations['generated']['TestingEnvironmentVariables']['libraries']['entries']
                if row['library'] == LIBRARY]
    require(len(expected) <= 1, 'ambiguous_producer_checker')
    match = None
    if expected and expected[0]['status'] == checker['status'] == 'readable':
        match = all(expected[0][key] == checker[key] for key in ('sha256', 'bytes'))
    return {'planSHA256': plan_sha, 'consumerProvenanceSHA256': hashlib.sha256(raw).hexdigest(),
            'producerReceiptSHA256': receipt['comparison']['producerReceiptSHA256'],
            'producerDeclaredChecker': expected, 'selectedRuntimeBytesMatchProducer': match}


def run(output, products=None, receipt=None):
    deadline = time.monotonic() + 60
    result = {'schema': 1, 'status': 'running', 'diagnosticOnly': True, 'releaseAcceptance': False,
              'loadedState': 'unknown', 'scope': 'Selected-runtime filesystem identity only; no test-process environment, loaded-library or metric-causation observation.'}
    provenance.write(output, result)
    try:
        require((products is None) == (receipt is None), 'paired_plan_inputs')
        role = 'consumer' if products is not None else 'producer'
        result['context'] = provenance.context(role, Path(__file__).resolve().parents[1])
        runtime, bundle = selected_runtime(inventory(), os.environ)
        result['runtime'] = runtime
        result['checker'] = checker_identity(bundle, deadline)
        if products is not None:
            result['plan'] = bind_plan(receipt, products.resolve(), result['context'], result['checker'])
        provenance.check_time(deadline)
        result['status'] = 'observed'
    except (provenance.ProofError, OSError, ValueError, TypeError, KeyError, AttributeError, struct.error,
            subprocess.SubprocessError) as error:
        result.update(status='failed', error=error.args[0] if isinstance(error, provenance.ProofError) else type(error).__name__)
        raise
    finally:
        provenance.write(output, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--products', type=Path)
    parser.add_argument('--plan-provenance', type=Path)
    args = parser.parse_args()
    try:
        run(args.output, args.products, args.plan_provenance)
    except (ValueError, OSError, TypeError, KeyError, AttributeError, struct.error, subprocess.SubprocessError):
        parser.exit(1, 'Selected-runtime checker observation failed; inspect the bounded receipt.\n')


if __name__ == '__main__':
    main()
