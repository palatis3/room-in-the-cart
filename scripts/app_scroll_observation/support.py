"""File-only support at import. Native ownership primitives live in copied owned.py."""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import uuid

SELECTOR = 'RoomInTheCartUITests/ReleasePerformanceUITests/testScrollingPerformanceOnFiveHundredItemPickup'


def require(value, reason):
    if not value: raise ValueError(reason)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()


def manifest(folder):
    folder = Path(folder)
    require(folder.is_dir() and not folder.is_symlink(), 'manifest_root')
    output = {}
    for path in sorted(folder.rglob('*')):
        require(not path.is_symlink(), 'manifest_symlink')
        if path.is_dir(): continue
        require(path.is_file(), 'manifest_nonregular')
        output[str(path.relative_to(folder))] = sha(path)
    return output


def modes(folder):
    return {str(p.relative_to(folder)): p.stat().st_mode & 0o777 for p in sorted(Path(folder).rglob('*')) if p.is_file()}


def atomic_json(path, value):
    path = Path(path); temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n'); temporary.replace(path)


def derive_plan(original, products, nonce, device):
    require(str(uuid.UUID(device)).upper() == device, "device_uuid")
    value = plistlib.loads(original)
    require(set(value) == {'RoomInTheCartUITests', '__xctestrun_metadata__'}, 'reviewed_v1_plan_shape')
    require(value['__xctestrun_metadata__']['FormatVersion'] == 1, 'plan_version')
    target = value['RoomInTheCartUITests']
    require(target['IsUITestBundle'] is True and target['BlueprintName'] == 'RoomInTheCartUITests', 'plan_target')
    require('Release-iphonesimulator' in target['UITargetAppPath'], 'release_plan')
    require(len(nonce) == 32 and all(c in '0123456789abcdef' for c in nonce), 'nonce')
    env = target.setdefault('EnvironmentVariables', {})
    require(not any(k.startswith('RITC_CAPTURE_') for k in env), 'stale_capture_plan')
    env.update(RITC_CAPTURE_NONCE=nonce, RITC_CAPTURE_DEVICE=device)
    def relocate(item):
        if isinstance(item, str): return item.replace('__TESTROOT__', str(Path(products).resolve()))
        if isinstance(item, list): return [relocate(x) for x in item]
        if isinstance(item, dict): return {k: relocate(v) for k, v in item.items()}
        return item
    return plistlib.dumps(relocate(value), sort_keys=False)


def arm64_uuid(path):
    raw = Path(path).read_bytes()
    require(len(raw) >= 32, 'macho_short')
    slices = []
    magic = struct.unpack_from('>I', raw)[0]
    if magic in (0xcafebabe, 0xcafebabf):
        count = struct.unpack_from('>I', raw, 4)[0]
        require(0 < count <= 16, 'fat_count')
        stride = 20 if magic == 0xcafebabe else 32
        for i in range(count):
            entry = 8 + i * stride
            cpu = struct.unpack_from('>I', raw, entry)[0]
            if magic == 0xcafebabe: offset, size = struct.unpack_from('>II', raw, entry + 8)
            else: offset, size = struct.unpack_from('>QQ', raw, entry + 8)
            require(offset + size <= len(raw), 'fat_bounds')
            if cpu == 0x0100000c: slices.append(raw[offset:offset + size])
    else: slices = [raw]
    matches = []
    for data in slices:
        require(len(data) >= 32 and struct.unpack_from('<I', data)[0] == 0xfeedfacf, 'macho_64le')
        require(struct.unpack_from('<I', data, 4)[0] == 0x0100000c, 'macho_arm64')
        ncmds, sizecmds = struct.unpack_from('<II', data, 16)
        require(ncmds <= 4096 and 32 + sizecmds <= len(data), 'load_commands_bounds')
        offset = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', data, offset)
            require(size >= 8 and offset + size <= 32 + sizecmds, 'load_command_size')
            if cmd == 0x1b:
                require(size == 24, 'uuid_command_size'); matches.append(str(uuid.UUID(bytes=data[offset+8:offset+24])).upper())
            offset += size
    require(len(matches) == 1, 'unique_arm64_uuid')
    return matches[0]


def launcher_identity(launcher, launcher_sha, executable, executable_sha):
    launcher, executable = Path(launcher), Path(executable)
    for path, expected in ((launcher, launcher_sha), (executable, executable_sha)):
        require(not path.is_symlink() and path.is_file() and sha(path) == expected, 'tool_file_identity')
    lines = launcher.read_text().splitlines()
    final = 'exec "' + str(executable.resolve()) + '" "${@}"'
    require(lines[0] == '#!/bin/bash' and lines[-1] == final, 'simctl_launcher_contract')
    return {'launcher': str(launcher.resolve()), 'launcherSHA256': launcher_sha,
            'executable': str(executable.resolve()), 'executableSHA256': executable_sha, 'finalExec': final}
