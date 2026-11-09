#!/usr/bin/env python3
"""Compare the existing performance archive's plan/products without changing tests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import time
from xml.parsers.expat import ExpatError

TARGET = 'RoomInTheCartUITests'
SCOPES = ('EnvironmentVariables', 'TestingEnvironmentVariables', 'UITargetAppEnvironmentVariables')
ANTIPATTERN_FLAGS = ('PERFC_ENABLE_ANTI_PATTERN_CHECKER', 'PERFC_ENABLE_ANTIPATTERN_CHECKER',
                    'PERFC_ANTI_PATTERN_CHECKER_ENABLED', 'EnablePerformanceAntipatternChecker',
                    'PerformanceAntipatternCheckerEnabled', 'IsPerformanceAntipatternCheckerEnabled',
                    'IDE_ENABLE_PERFORMANCE_ANTI_PATTERN_CHECKER', 'XCTestEnablePerformanceAntipatternChecker')
SETTINGS = ('OS_ACTIVITY_MODE', 'OS_ACTIVITY_DT_MODE', 'OS_LOG_DT_HOOK_MODE', 'IDE_CHOSEN_LOGGING_METHOD',
            'PERFC_ENABLE_EXTENDED_DIAGNOSTIC_FORMAT', 'PERFC_ENABLE_PROFILE_MODE',
            'PERFC_RESET_INSERT_LIBRARIES', 'PERFC_SUPPRESS_SYSTEM_REPORTS', 'SQLITE_ENABLE_THREAD_ASSERTIONS') + ANTIPATTERN_FLAGS
VALUES = {'0', '1', 'YES', 'NO', 'enable', 'disable', 'default'}
OPTIONS = ('IsMemoryTaggingAddressSanitizerEnabled', 'UITargetAppPerformanceAntipatternCheckerEnabled',
           'EnableCodeCoverage', 'EnableAddressSanitizer', 'EnableThreadSanitizer', 'EnableUndefinedBehaviorSanitizer') + ANTIPATTERN_FLAGS
BUNDLES = {
    'app': ('RoomInTheCart.app', 'RoomInTheCart'),
    'runner': ('RoomInTheCartUITests-Runner.app', 'RoomInTheCartUITests-Runner'),
    'tests': ('RoomInTheCartUITests-Runner.app/PlugIns/RoomInTheCartUITests.xctest', 'RoomInTheCartUITests'),
    'share': ('RoomInTheCartShare.appex', 'RoomInTheCartShare'),
    'widget': ('RoomInTheCartWidget.appex', 'RoomInTheCartWidget'),
}
SOURCES = ('ios/UITests/ReleasePerformanceUITests.swift', 'ios/UITests/Fixtures/ReleaseLedger500.txt',
           'ios/RoomInTheCart.xcodeproj/xcshareddata/xcschemes/RoomInTheCart-Performance.xcscheme')
LIBRARIES = {'libMainThreadChecker.dylib', 'libRPAC.dylib', 'libXCTestBundleInject.dylib',
             'libclang_rt.asan_iossim_dynamic.dylib', 'libclang_rt.tsan_iossim_dynamic.dylib',
             'libclang_rt.ubsan_iossim_dynamic.dylib'}
MAX_EXECUTABLE = 512 * 1024 * 1024
MAX_LIBRARY = 128 * 1024 * 1024
MAX_METADATA = 65536
SECONDS = 60


class ProofError(ValueError):
    pass


def require(condition, code):
    if not condition:
        raise ProofError(code)


class UniqueDictionary(dict):
    def __setitem__(self, key, value):
        require(key not in self, 'duplicate_metadata_key')
        super().__setitem__(key, value)


def parse_plist(value):
    try:
        return plistlib.loads(value, dict_type=UniqueDictionary)
    except (plistlib.InvalidFileException, ExpatError) as error:
        raise ProofError('malformed_plist') from error


def unique_pairs(pairs):
    result = UniqueDictionary()
    for key, value in pairs:
        result[key] = value
    return result


def check_time(deadline):
    require(time.monotonic() < deadline, 'receipt_deadline')


def sha(path, limit, deadline):
    check_time(deadline)
    before = path.stat()
    require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= limit, 'file_size_or_type')
    result = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(65536):
            check_time(deadline)
            result.update(chunk)
    after = path.stat()
    require((before.st_size, before.st_mtime_ns, before.st_mode, before.st_ino) ==
            (after.st_size, after.st_mtime_ns, after.st_mode, after.st_ino), 'file_changed_during_hash')
    return result.hexdigest()


def metadata_bytes(path):
    with path.open('rb') as source:
        value = source.read(MAX_METADATA + 1)
    require(0 < len(value) <= MAX_METADATA, 'metadata_size')
    return value


def regular(path, root):
    require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root.resolve()), 'missing_or_unsafe_product')
    # Do not accept product paths redirected through a symlinked parent.
    require(path.absolute() == path.resolve(), 'redirected_product')
    return path


def context(role, root):
    source = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True,
                            check=True, text=True, timeout=5).stdout.strip()
    require(re.fullmatch(r'[0-9a-f]{40}', source) and source == os.environ.get('GITHUB_SHA'), 'source_identity')
    result = {'sourceSHA': source, 'repository': os.environ.get('GITHUB_REPOSITORY', ''),
              'runID': os.environ.get('GITHUB_RUN_ID', ''), 'attempt': os.environ.get('GITHUB_RUN_ATTEMPT', ''),
              'job': os.environ.get('GITHUB_JOB', '')}
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', result['repository'])
            and all(re.fullmatch(r'[1-9][0-9]*', result[k]) for k in ('runID', 'attempt'))
            and result['job'] == ('performance-build' if role == 'producer' else 'performance-tests'), 'job_identity')
    return result


def boolean_marker(mapping, key):
    if key not in mapping:
        return 'absent'
    value = mapping[key]
    if type(value) is bool or (type(value) is int and value in (0, 1)):
        return 'true' if value else 'false'
    if isinstance(value, str) and value in {'YES', 'NO', 'true', 'false', '1', '0'}:
        return 'true' if value in {'YES', 'true', '1'} else 'false'
    return 'unrecognized-present'


def settings(environment):
    result = {}
    for key in SETTINGS:
        if key in ANTIPATTERN_FLAGS:
            result[key] = boolean_marker(environment, key)
        else:
            result[key] = ('absent' if key not in environment else
                           'value:' + environment[key] if isinstance(environment[key], str) and environment[key] in VALUES
                           else 'unrecognized-present')
    return result


def library_reference(value, products):
    """Only known library names/roots may be opened; never return a raw path."""
    if not isinstance(value, str) or len(value) > 2048 or '..' in value.split('/'):
        return None, 'unrecognized', None
    name = value.rsplit('/', 1)[-1]
    if name not in LIBRARIES:
        return None, 'unrecognized', None
    if value == '__TESTHOST__/Frameworks/' + name:
        return name, 'product-runner-framework', products / 'Release-iphonesimulator' / BUNDLES['runner'][0] / 'Frameworks' / name
    if value == '/usr/lib/' + name:
        return name, 'host-system-library', Path(value)
    runtime = (r'/(?:private/)?var/run/com\.apple\.security\.cryptexd/mnt/[A-Za-z0-9_.-]+/'
               r'Library/Developer/CoreSimulator/Profiles/Runtimes/iOS [0-9.]+\.simruntime/'
               r'Contents/Resources/RuntimeRoot/usr/lib/')
    if re.fullmatch(runtime + re.escape(name), value):
        return name, 'declared-runtime-library', Path(value)
    return name, 'unrecognized', None


def libraries(environment, products, deadline):
    if 'DYLD_INSERT_LIBRARIES' not in environment:
        return {'state': 'absent', 'entries': []}
    value = environment['DYLD_INSERT_LIBRARIES']
    if not isinstance(value, str) or len(value) > 8192 or len(value.split(':')) > 8:
        return {'state': 'unrecognized-present', 'entries': []}
    rows = []
    for entry in value.split(':'):
        name, root_kind, path = library_reference(entry, products)
        row = {'library': name, 'root': root_kind, 'status': 'unrecognized'}
        if path is not None:
            try:
                if not path.exists():
                    row['status'] = 'missing'
                elif not path.is_file() or path.is_symlink():
                    row['status'] = 'not-regular'
                else:
                    # A recognized path must not resolve elsewhere through parent symlinks.
                    resolved_name, resolved_root, _ = library_reference(str(path.resolve()), products)
                    safe = (path.resolve().is_relative_to(products.resolve()) if root_kind == 'product-runner-framework'
                            else resolved_name == name and resolved_root == root_kind)
                    if not safe:
                        row['status'] = 'redirected'
                    elif path.stat().st_size == 0:
                        row['status'] = 'empty'
                    elif path.stat().st_size > MAX_LIBRARY:
                        row['status'] = 'oversize'
                    else:
                        row.update(status='readable', sha256=sha(path, MAX_LIBRARY, deadline), bytes=path.stat().st_size)
            except OSError:
                row['status'] = 'unreadable'
        rows.append(row)
    return {'state': 'present', 'entries': rows}


def observations(target, products, deadline):
    generated = {}
    for scope in SCOPES:
        env = target.get(scope, {})
        require(isinstance(env, dict), 'plan_environment_shape')
        generated[scope] = {'settings': settings(env), 'libraries': libraries(env, products, deadline)}
    return {'generated': generated,
            'invoking': {'settings': settings(os.environ), 'libraries': libraries(os.environ, products, deadline)},
            'options': {key: boolean_marker(target, key) for key in OPTIONS}}


def inspect_products(products, root, deadline):
    plans = list(products.glob('RoomInTheCart-Performance_iphonesimulator*.xctestrun'))
    require(len(plans) == 1, 'plan_count')
    plan = regular(plans[0], products)
    require(re.fullmatch(r'RoomInTheCart-Performance_iphonesimulator[0-9.]+-[A-Za-z0-9_-]+\.xctestrun', plan.name), 'plan_name')
    plan_sha = sha(plan, MAX_METADATA, deadline)
    plan_bytes = metadata_bytes(plan)
    require(hashlib.sha256(plan_bytes).hexdigest() == plan_sha, 'plan_changed')
    data = parse_plist(plan_bytes)
    require(isinstance(data, dict) and set(data) == {TARGET, '__xctestrun_metadata__'}, 'plan_targets')
    metadata = data['__xctestrun_metadata__']
    require(type(metadata.get('FormatVersion')) is int and metadata['FormatVersion'] == 1
            and metadata['ContainerInfo']['SchemeName'] == 'RoomInTheCart-Performance', 'plan_format_or_scheme')
    target = data[TARGET]
    require(target['TestHostPath'] == '__TESTROOT__/Release-iphonesimulator/' + BUNDLES['runner'][0]
            and target['UITargetAppPath'] == '__TESTROOT__/Release-iphonesimulator/' + BUNDLES['app'][0]
            and target['TestBundlePath'] == '__TESTHOST__/PlugIns/RoomInTheCartUITests.xctest'
            and target['IsUITestBundle'] is True and target['IsXCTRunnerHostedTestBundle'] is True
            and target['OnlyTestIdentifiers'] == ['ReleasePerformanceUITests'], 'plan_layout_or_selection')
    dependencies = target['DependentProductPaths']
    require(isinstance(dependencies, list) and len(dependencies) == len(BUNDLES)
            and set(dependencies) == {'__TESTROOT__/Release-iphonesimulator/' + pair[0] for pair in BUNDLES.values()}, 'dependent_products')
    records = {}
    for role, (bundle, executable) in BUNDLES.items():
        directory = products / 'Release-iphonesimulator' / bundle
        info = regular(directory / 'Info.plist', products)
        info_sha = sha(info, MAX_METADATA, deadline)
        info_bytes = metadata_bytes(info)
        require(hashlib.sha256(info_bytes).hexdigest() == info_sha, 'bundle_metadata_changed')
        require(parse_plist(info_bytes).get('CFBundleExecutable') == executable, 'executable_identity')
        binary = regular(directory / executable, products)
        require(binary.stat().st_mode & 0o111, 'executable_mode')
        records[role] = {'sha256': sha(binary, MAX_EXECUTABLE, deadline), 'infoSHA256': info_sha,
                         'mode': stat.S_IMODE(binary.stat().st_mode), 'bytes': binary.stat().st_size}
    immutable = {'planName': plan.name, 'planSHA256': plan_sha, 'products': records,
                 'sourceFiles': {path: sha(regular(root / path, root), MAX_METADATA, deadline) for path in SOURCES}}
    observed = observations(target, products, deadline)
    embedded = {}
    for scope in SCOPES:
        for index, entry in enumerate(observed['generated'][scope]['libraries']['entries']):
            if entry['root'] == 'product-runner-framework':
                require(entry['status'] == 'readable', 'referenced_product_library')
                embedded[scope + ':' + str(index)] = entry
    immutable['productLibraries'] = embedded
    return immutable, observed


def validate_observations(value):
    require(isinstance(value, dict) and set(value) == {'generated', 'invoking', 'options'}, 'producer_observations')
    require(set(value['generated']) == set(SCOPES) and set(value['options']) == set(OPTIONS)
            and all(v in {'absent', 'true', 'false', 'unrecognized-present'} for v in value['options'].values()), 'producer_observations')
    for env in [value['invoking'], *value['generated'].values()]:
        require(set(env) == {'settings', 'libraries'} and set(env['settings']) == set(SETTINGS)
                and all(v in ({'absent', 'unrecognized-present', 'true', 'false'} if k in ANTIPATTERN_FLAGS
                              else {'absent', 'unrecognized-present', *('value:' + x for x in VALUES)})
                        for k, v in env['settings'].items()), 'producer_settings')
        libs = env['libraries']
        require(set(libs) == {'state', 'entries'} and libs['state'] in {'absent', 'present', 'unrecognized-present'}
                and isinstance(libs['entries'], list) and len(libs['entries']) <= 8
                and (libs['state'] == 'present' or not libs['entries']), 'producer_libraries')
        for row in libs['entries']:
            require(set(row) == ({'library', 'root', 'status', 'sha256', 'bytes'} if row['status'] == 'readable'
                                else {'library', 'root', 'status'})
                    and row['library'] in LIBRARIES | {None}
                    and row['root'] in {'unrecognized', 'product-runner-framework', 'host-system-library', 'declared-runtime-library'}
                    and row['status'] in {'unrecognized', 'missing', 'not-regular', 'redirected', 'oversize', 'empty', 'readable', 'unreadable'}, 'producer_libraries')
            if row['status'] == 'readable':
                require(re.fullmatch(r'[0-9a-f]{64}', row['sha256']) and type(row['bytes']) is int
                        and 0 < row['bytes'] <= MAX_LIBRARY, 'producer_library_hash')


def compare(producer, current):
    require(set(producer) == {'schema', 'role', 'status', 'context', 'immutable', 'observations', 'scope'}
            and type(producer['schema']) is int and producer['schema'] == 1
            and producer['role'] == 'producer' and producer['status'] == 'passed', 'producer_receipt')
    old, new = producer['context'], current['context']
    require(set(old) == set(new) and old['job'] == 'performance-build'
            and all(old[k] == new[k] for k in ('sourceSHA', 'repository', 'runID'))
            and isinstance(old['attempt'], str) and re.fullmatch(r'[1-9][0-9]*', old['attempt'])
            and int(old['attempt']) <= int(new['attempt']), 'producer_lineage')
    require(producer['immutable'] == current['immutable'], 'archive_plan_or_product_mismatch')
    require(producer['scope'] == current['scope'], 'producer_scope')
    validate_observations(producer['observations'])
    old_obs, new_obs = producer['observations'], current['observations']
    require(old_obs['options'] == new_obs['options'] and all(
        old_obs['generated'][s]['settings'] == new_obs['generated'][s]['settings'] for s in SCOPES), 'generated_metadata_mismatch')
    return {'immutableMatch': True, 'producerAttempt': old['attempt'], 'consumerAttempt': new['attempt'],
            'generatedSettingsMatch': all(old_obs['generated'][s]['settings'] == new_obs['generated'][s]['settings'] for s in SCOPES),
            'invokingSettingsMatch': old_obs['invoking']['settings'] == new_obs['invoking']['settings'],
            'libraryObservationsMatch': all(old_obs['generated'][s]['libraries'] == new_obs['generated'][s]['libraries'] for s in SCOPES)
                and old_obs['invoking']['libraries'] == new_obs['invoking']['libraries'],
            'producerObservations': old_obs}


def write(path, value):
    encoded = json.dumps(value, indent=2) + '\n'
    require(len(encoded.encode()) <= MAX_METADATA, 'receipt_size')
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('x') as output:
        output.write(encoded)
    temporary.replace(path)


def run(role, products, output, producer_path=None):
    deadline = time.monotonic() + SECONDS
    result = {'schema': 1, 'role': role, 'status': 'running'}
    write(output, result)
    try:
        root = Path(__file__).resolve().parents[1]
        result['context'] = context(role, root)
        result['scope'] = 'Selected plan/executables, not entire archive identity. Allowlisted plan and receipt-process settings; host-filesystem availability only. Effective test-process environment and loaded libraries unknown.'
        result['immutable'], result['observations'] = inspect_products(products.resolve(), root, deadline)
        if role == 'consumer':
            require(producer_path is not None, 'producer_required')
            regular(producer_path, products)
            producer_sha = sha(producer_path, MAX_METADATA, deadline)
            producer_bytes = metadata_bytes(producer_path)
            require(hashlib.sha256(producer_bytes).hexdigest() == producer_sha, 'producer_changed')
            producer = json.loads(producer_bytes, object_pairs_hook=unique_pairs)
            result['comparison'] = compare(producer, result)
            result['comparison']['producerReceiptSHA256'] = producer_sha
        result['status'] = 'passed'
        check_time(deadline)
        write(output, result)
    except (ProofError, OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError) as error:
        # Never include exception text from paths, plists, environment or subprocesses.
        result.update(status='failed', error=error.args[0] if isinstance(error, ProofError) else type(error).__name__)
        write(output, result)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('role', choices=('producer', 'consumer'))
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--producer', type=Path)
    args = parser.parse_args()
    try:
        require((args.role == 'consumer') == (args.producer is not None), 'producer_argument')
        run(args.role, args.products, args.output, args.producer)
    except (ValueError, OSError, TypeError, KeyError, AttributeError, subprocess.SubprocessError):
        parser.exit(1, 'Performance plan provenance failed; inspect the bounded receipt.\n')


if __name__ == '__main__':
    main()
