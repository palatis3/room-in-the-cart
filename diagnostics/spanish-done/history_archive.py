"""Pinned singleton products, restored without rebuilding or editing xctestrun."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import zipfile
from run import command, hashes, write

SOURCE = '4bff9599a3619bfc5efa79a7a533fd12e08250fc'
ZIP_SHA = '390a0662b9907ed319c390675964c091f2130cb5d5d174865f0f77abc95f6117'
TAR_SHA = '96ffe997f5d8798efaca7da7079970a9aa438bfff9cceb5508f0365b8c69aeb3'
PRODUCTS = Path('.build/spanish-done-products/Build/Products')
METADATA = {'._Products', 'Products/._Debug-iphonesimulator', 'Products/Debug-iphonesimulator/._PackageFrameworks'}
METADATA_SHA = '4798dcd53450d1b8bd450cf6e57b913e12a90a3baf6a63c051c5153c68cc3c1e'


def digest(path):
    with Path(path).open('rb') as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def restore(archive, evidence):
    if archive.stat().st_size != 85078230 or digest(archive) != ZIP_SHA:
        raise ValueError('Not the pinned run42206008187 artifact13497202263')
    if PRODUCTS.exists() or evidence.exists():
        raise ValueError('Fresh product/evidence paths required; no reuse/retry')
    evidence.mkdir(parents=True)
    needed = ['source-sha256.json', 'product-sha256.json', 'enumeration.json', 'products.tar.gz']
    with zipfile.ZipFile(archive) as source:
        names = source.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate ZIP members')
        for name in needed:
            if names.count(name) != 1:
                raise ValueError('Missing pinned archive member: ' + name)
            with source.open(name) as stream, (evidence / name).open('xb') as target:
                shutil.copyfileobj(stream, target)
    source_hashes = json.loads((evidence / 'source-sha256.json').read_text())
    paths = command(['git', 'ls-tree', '-r', '--name-only', SOURCE, 'ios', 'shared', 'config', 'scripts',
                     'diagnostics', '.github/workflows/ios-fixtures.yml']).splitlines()
    if len(source_hashes) != 528 or set(paths) != set(source_hashes):
        raise ValueError('Original source inventory mismatch')
    # cat-file is binary-safe; the current runner is frozen separately by prepare.
    import subprocess
    blobs = subprocess.check_output(['git', 'cat-file', '--batch'],
        input=''.join(SOURCE + ':' + p + '\n' for p in paths).encode(), timeout=90)
    offset = 0
    for path in paths:
        end = blobs.index(b'\n', offset)
        header = blobs[offset:end].split()
        if len(header) != 3 or header[1] != b'blob':
            raise ValueError('Missing original source blob')
        size = int(header[2]); offset = end + 1
        data = blobs[offset:offset + size]; offset += size + 1
        if hashlib.sha256(data).hexdigest() != source_hashes[path]:
            raise ValueError('Original source hash mismatch: ' + path)
    archive_tar = evidence / 'products.tar.gz'
    if digest(archive_tar) != TAR_SHA:
        raise ValueError('Product archive hash mismatch')
    expected = json.loads((evidence / 'product-sha256.json').read_text())
    if len(expected) != 238:
        raise ValueError('Product inventory count mismatch')
    seen, metadata, expanded = set(), set(), 0
    with tarfile.open(archive_tar) as source:
        for member in source:
            path = PurePosixPath(member.name)
            if member.name in seen or path.is_absolute() or '..' in path.parts or '\\' in member.name:
                raise ValueError('Unsafe/duplicate tar member')
            seen.add(member.name)
            if len(seen) > 1000 or not (member.isfile() or member.isdir()):
                raise ValueError('Unexpected linked/nonregular product member')
            if member.name in METADATA:
                data = source.extractfile(member).read(1025)
                if member.size != 172 or hashlib.sha256(data).hexdigest() != METADATA_SHA:
                    raise ValueError('Unexpected AppleDouble metadata')
                metadata.add(member.name)
                continue
            if not path.parts or path.parts[0] != 'Products':
                raise ValueError('Unexpected product path')
            target = PRODUCTS.parent.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            expanded += member.size
            if member.size > 512 * 1024 * 1024 or expanded > 256 * 1024 * 1024 or str(target) not in expected:
                raise ValueError('Unexpected/oversized product file')
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as stream, target.open('xb') as output:
                shutil.copyfileobj(stream, output)
            target.chmod(member.mode & 0o777)
    if metadata != METADATA or hashes([p for p in PRODUCTS.rglob('*') if p.is_file()]) != expected:
        raise ValueError('Restored inventory/hash mismatch')
    proof = {'productSourceCommit': SOURCE, 'artifactRun': 42206008187, 'artifactID': 13497202263,
             'artifactSHA256': ZIP_SHA, 'productArchiveSHA256': TAR_SHA,
             'originalSourceCount': 528, 'productCount': 238, 'expandedProductBytes': expanded,
             'xctestrunRewritten': False, 'rebuilt': False, 'metadataExcluded': sorted(metadata)}
    write(evidence / 'provenance.json', proof)
    return proof
