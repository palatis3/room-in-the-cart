"""One bounded file-only tar, outside its inputs, preserving file modes for artifact recovery."""
import hashlib
import os
from pathlib import Path
import shutil
import tarfile
import time
from .support import require, sha, atomic_json
from .contract import read

ARCHIVE_BYTES=2*1024**3
RAW_BYTES=3*1024**3
FILES=32768
SECONDS=180


def inventory(root, cap, deadline, exclude_copies=False):
    root=Path(root);require(root.is_dir() and root.resolve()==root and not root.is_symlink(),'archive_root')
    result={};total=0
    for path in sorted(root.rglob('*')):
        require(time.monotonic()<deadline,'archive_deadline')
        require(not path.is_symlink() and (path.is_file() or path.is_dir()),'archive_link_or_nonregular')
        name=str(path.relative_to(root));require(not Path(name).is_absolute() and '..' not in Path(name).parts,'archive_traversal')
        if exclude_copies and any(p in ('inspection.trace','Inspection.xcresult') for p in Path(name).parts):continue
        if path.is_dir():continue
        total+=path.stat().st_size;require(total<=cap and len(result)<FILES,'archive_size_or_count')
        result[name]={'sha256':sha(path),'bytes':path.stat().st_size,'mode':path.stat().st_mode&0o777}
    return result


def verify_tar(path, expected, deadline):
    seen={}
    with tarfile.open(path,'r:') as archive:
        for item in archive:
            require(time.monotonic()<deadline,'archive_verify_deadline')
            require(item.isfile() and item.name in expected and item.name not in seen
                    and not Path(item.name).is_absolute() and '..' not in Path(item.name).parts,'archive_member')
            value=expected[item.name];require(item.size==value['bytes'] and item.mode==value['mode'],'archive_mode_or_size')
            digest=hashlib.sha256();stream=archive.extractfile(item)
            with stream:
                for chunk in iter(lambda:stream.read(1024**2),b''):
                    digest.update(chunk);require(time.monotonic()<deadline,'archive_verify_deadline')
            require(digest.hexdigest()==value['sha256'],'archive_member_hash');seen[item.name]=True
    require(set(seen)==set(expected),'archive_inventory')


def run(evidence, output):
    evidence=Path(evidence).absolute();output=Path(output).absolute()
    require(evidence==evidence.resolve() and output==output.resolve(),'archive_redirected_root')
    require(not output.is_relative_to(evidence) and not evidence.is_relative_to(output),'archive_outside_input_tree')
    output.mkdir(parents=True,exist_ok=False);(output/'report').mkdir();(output/'complete').mkdir()
    started=time.monotonic();deadline=started+SECONDS
    receipt={'diagnosticOnly':True,'releaseAcceptance':False,'archivePreserved':False,'rawFallbackQualified':False,
             'limits':{'archiveBytes':ARCHIVE_BYTES,'rawFallbackBytes':RAW_BYTES,'files':FILES,'wallSeconds':SECONDS},
             'excludedDisposableCopies':['inspection.trace','Inspection.xcresult']}
    artifact=output/'report';partial=output/'evidence.tar.partial'
    try:
        require(shutil.disk_usage(output).free>=8*1024**3,'archive_disk_reserve')
        original=inventory(evidence,RAW_BYTES,deadline)
        selected={n:v for n,v in original.items() if not any(p in ('inspection.trace','Inspection.xcresult') for p in Path(n).parts)}
        selected_bytes=sum(v['bytes'] for v in selected.values())
        require(selected_bytes<=ARCHIVE_BYTES,'selected_archive_bytes')
        # Reserve payload plus conservative PAX/header/padding overhead once before writing,
        # not on each 16 KiB tar read. Recheck the free reserve after verification.
        overhead=(len(selected)+1)*16*1024
        receipt.update(selectedPayloadBytes=selected_bytes,tarOverheadAllowanceBytes=overhead)
        require(shutil.disk_usage(output).free>=8*1024**3+selected_bytes+overhead,'archive_headroom')
        class BoundReader:
            def __init__(self,stream):self.stream=stream
            def read(self,size):
                require(time.monotonic()<deadline and partial.stat().st_size<=ARCHIVE_BYTES,'archive_write_cap')
                return self.stream.read(size)
        with tarfile.open(partial,'x:',format=tarfile.PAX_FORMAT) as archive:
            for name,value in selected.items():
                info=tarfile.TarInfo(name);info.size=value['bytes'];info.mode=value['mode'];info.mtime=0
                with (evidence/name).open('rb') as source:archive.addfile(info,BoundReader(source))
        require(partial.stat().st_size<=ARCHIVE_BYTES,'archive_bytes')
        verify_tar(partial,selected,deadline)
        require(inventory(evidence,RAW_BYTES,deadline)==original,'archive_input_changed')
        require(shutil.disk_usage(output).free>=8*1024**3,'archive_post_write_reserve')
        final=output/'complete/evidence.tar';partial.rename(final)
        receipt.update(archivePreserved=True,archiveSHA256=sha(final),archiveBytes=final.stat().st_size,
                       members=selected,scope='File bytes and modes preserved; this archive does not qualify failed collection or checks.')
        artifact=output/'complete'
    except BaseException as exc:
        receipt['error']=type(exc).__name__+': '+str(exc)
        # No unbounded directory upload after a failed archive. If safe inventory cannot be
        # established within a separate short file-only bound, retain the compact report only.
        try:
            raw=inventory(evidence,RAW_BYTES-1024**2,time.monotonic()+30)
            receipt.update(rawFallback={'files':len(raw),'bytes':sum(v['bytes'] for v in raw.values()),'qualified':False})
            artifact=evidence
        except BaseException as fallback:receipt['rawFallbackError']=str(fallback)
    receipt.update(artifactPath=str(artifact),elapsedSeconds=time.monotonic()-started)
    atomic_json(output/'report/receipt.json',receipt)
    if receipt['archivePreserved']:shutil.copy2(output/'report/receipt.json',output/'complete/receipt.json')
    elif artifact==evidence:shutil.copy2(output/'report/receipt.json',evidence/'observation-archive-failure.json')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'],'a') as stream:stream.write('artifact_path='+str(artifact)+'\n')
    return 0 if receipt['archivePreserved'] else 1


def require_preserved(output):
    receipt=read(Path(output)/'report/receipt.json')
    require(receipt['archivePreserved'] is True,'portable_archive_required_before_cleanup')
    require(sha(Path(output)/'complete/evidence.tar')==receipt['archiveSHA256'],'portable_archive_changed')
