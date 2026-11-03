#!/usr/bin/env python3
"""Read-only local AVD inventory; never launches Android tools or opens sockets."""
import datetime
import hashlib
import json
import pathlib
import re
import subprocess

OUT = pathlib.Path(__file__).resolve().parent
SCRATCH = OUT.parent.parent
ROOT = pathlib.Path('/tmp/ritc-android')
AVD = ROOT / 'avd/RITC_Chrome_API34.avd'
IMAGE = ROOT / 'sdk/system-images/android-34/google_apis_playstore/arm64-v8a'

def command(args):
    result = subprocess.run(args, capture_output=True, text=True)
    return {'command': args, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}

def properties(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line and not line.lstrip().startswith('#'))

def clean(data):
    return {key.strip(): value.strip() for key, value in data.items()}

def identity(path, hash_body=True):
    stat = path.stat()
    data = {'path': str(path), 'bytes': stat.st_size, 'allocated_bytes': stat.st_blocks * 512, 'modified_utc': datetime.datetime.fromtimestamp(stat.st_mtime, datetime.timezone.utc).isoformat()}
    if hash_body:
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        data['sha256'] = digest.hexdigest()
    return data

read_files = [ROOT / 'avd/RITC_Chrome_API34.ini', AVD / 'config.ini', AVD / 'hardware-qemu.ini', AVD / 'emu-launch-params.txt', IMAGE / 'source.properties', IMAGE / 'build.prop', ROOT / 'sdk/emulator/source.properties', ROOT / 'sdk/platform-tools/source.properties', ROOT / 'env.sh', ROOT / 'launch-authorized.sh', ROOT / 'sdk/emulator/emulator', ROOT / 'sdk/platform-tools/adb', SCRATCH / 'android-browser-acceptance/resume-preflight/149-continuation-transport.json', SCRATCH / 'android-browser-acceptance/resume-preflight/cleanup-verification.json', SCRATCH / 'android-chrome-prep-evidence/apks/product__app__Chrome__Chrome.apk', SCRATCH / 'android-chrome-prep-evidence/apks/product__app__TrichromeLibrary__TrichromeLibrary.apk', pathlib.Path('/tmp/ritc-android-fixture/setup-evidence/20-play-chrome-update.png'), pathlib.Path('/tmp/ritc-android-fixture/setup-evidence/20-play-chrome-update.xml')]
file_identities = [identity(path) for path in read_files]
large_image_files = [identity(path, False) for path in sorted(IMAGE.iterdir()) if path.is_file() and path.suffix in ('.img', '')]
avd_files = [identity(path, False) for path in sorted(AVD.iterdir()) if path.is_file()]

process_result = command(['/bin/ps', '-axo', 'pid=,ppid=,etime=,rss=,comm='])
owned = []
native = []
if process_result['exit'] == 0:
    for line in process_result['stdout'].splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) != 5:
            continue
        pid, ppid, elapsed, rss, executable = parts
        row = {'pid': int(pid), 'parent_pid': int(ppid), 'elapsed': elapsed, 'rss_kib': int(rss), 'executable': executable}
        name = pathlib.Path(executable).name.lower()
        if name in ('adb', 'emulator', 'qemu-system-aarch64') or '/tmp/ritc-android/' in executable or '/private/tmp/ritc-android/' in executable:
            owned.append(row)
        if name in ('xcodebuild', 'xctest', 'simulator', 'simulatord'):
            native.append(row)
    process_result.pop('stdout')

listeners = command(['/usr/sbin/lsof', '-nP', '-iTCP:5037', '-iTCP:5554', '-iTCP:5555', '-iTCP:9227', '-iTCP:65502', '-sTCP:LISTEN'])
resource = {
    'memory_pressure_query': command(['/usr/bin/memory_pressure', '-Q']),
    'vm_stat': command(['/usr/bin/vm_stat']),
    'disk_free': command(['/bin/df', '-k', '/tmp']),
    'allocated_directory_sizes_kib': command(['/usr/bin/du', '-sk', str(ROOT / 'sdk'), str(ROOT / 'avd'), '/tmp/ritc-android-fixture']),
}
key_metadata = []
for path in (ROOT / 'user/adbkey', pathlib.Path('/Users/palatis/.android/adbkey'), pathlib.Path('/Users/palatis/.android/adbkey.pub')):
    row = {'path': str(path), 'exists': path.exists(), 'key_contents_read': False}
    if path.exists():
        row['bytes'] = path.stat().st_size
    key_metadata.append(row)

result = {
    'checked_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'scope': 'LOCAL READ ONLY; no emulator/ADB/network/account action',
    'avd_name': 'RITC_Chrome_API34',
    'avd_path': str(AVD),
    'image_path': str(IMAGE),
    'config': clean(properties(AVD / 'config.ini')),
    'last_generated_hardware': clean(properties(AVD / 'hardware-qemu.ini')),
    'image_source_properties': clean(properties(IMAGE / 'source.properties')),
    'emulator_source_properties': clean(properties(ROOT / 'sdk/emulator/source.properties')),
    'platform_tools_source_properties': clean(properties(ROOT / 'sdk/platform-tools/source.properties')),
    'last_launch_parameters': (AVD / 'emu-launch-params.txt').read_text().splitlines(),
    'current_android_processes': owned,
    'native_activity_metadata_only': native,
    'process_query_result': process_result,
    'listener_query': listeners,
    'resource_queries': resource,
    'host_adb_key_metadata_only': key_metadata,
    'file_identities': file_identities,
    'image_files_metadata_only': large_image_files,
    'avd_files_metadata_only': avd_files,
    'installed_browser_last_observed': json.loads((SCRATCH / 'android-browser-acceptance/resume-preflight/149-continuation-transport.json').read_text()),
    'fresh_runtime_version_checked': False,
    'play_store_app_version': 'Not retained in inspected local evidence; requires later authorized running-device query',
    'google_play_services_version': 'Not retained in inspected local evidence; requires later authorized running-device query',
    'network_probes': False,
    'emulator_or_adb_executed': False,
    'account_or_terms_action': False,
    'avd_or_sdk_written': False,
}
(OUT / 'local-inventory.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'checked_at_utc': result['checked_at_utc'], 'android_processes': owned, 'process_query_exit': process_result['exit'], 'listener_query': listeners, 'native_process_count': len(native), 'memory': resource['memory_pressure_query'], 'host_adb_key_metadata_only': key_metadata, 'identity_count': len(file_identities)}, indent=2))
