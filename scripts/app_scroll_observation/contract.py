"""Frozen source/tool/profile contracts and portable file custody; no import-time I/O."""
import json
import hashlib
import stat
import struct
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import time
import uuid
from .support import require, sha, manifest, modes, atomic_json, launcher_identity, arm64_uuid

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CONDITION = '#if RELEASE && APP_SIGNPOST_CAPTURE_CONTROL && targetEnvironment(simulator)'
FLAG = 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) RELEASE APP_SIGNPOST_CAPTURE_CONTROL'
SOURCE_PATHS = ('ios', 'scripts', 'shared', 'config', '.github/workflows/ios-performance.yml')
PRODUCT_METADATA = {'performance-plan-producer.json', 'app-observation-producer.json'}


def read(path, cap=8*1024**2):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= cap, 'JSON_shape_or_cap:'+str(path))
    return json.loads(path.read_bytes())


def frozen():
    value = read(HERE/'contract.json')
    for name, digest in value['files'].items():
        require(sha(ROOT/name) == digest, 'frozen_source_changed:'+name)
    return value


def snapshot(folder, cap=256*1024**2, files=4096):
    folder = Path(folder)
    entries = list(folder.rglob('*'))
    require(folder.is_dir() and not folder.is_symlink() and len(entries) <= files, 'snapshot_root_or_count')
    require(all(not p.is_symlink() and (p.is_file() or p.is_dir()) for p in entries), 'snapshot_links')
    require(sum(p.stat().st_size for p in entries if p.is_file()) <= cap, 'snapshot_bytes')
    return {'files': manifest(folder), 'modes': modes(folder)}


def selected_snapshot(root, names):
    root = Path(root).resolve(); result = {'files':{}, 'modes':{}}
    require(len(names) <= 8192, 'source_count')
    total = 0
    for name in sorted(names):
        path = root/name
        require(not Path(name).is_absolute() and '..' not in Path(name).parts and path.is_file()
                and path.resolve() == path and path.is_relative_to(root), 'source_path')
        total += path.stat().st_size; require(total <= 128*1024**2, 'source_bytes')
        result['files'][name] = sha(path); result['modes'][name] = path.stat().st_mode & 0o777
    return result


def source_snapshot():
    result = subprocess.run(['git','ls-files','-z','--',*SOURCE_PATHS], cwd=ROOT,
                            capture_output=True, check=True, timeout=15)
    require(len(result.stdout) <= 2*1024**2, 'source_inventory_cap')
    names = result.stdout.decode().rstrip('\0').split('\0')
    require(names and len(names) == len(set(names)), 'source_inventory')
    # Include the reviewed new modules before git add as well as in the committed CI checkout.
    names=sorted(set(names)|set(frozen()['files'])|{'scripts/app_scroll_observation/contract.json'})
    return selected_snapshot(ROOT, names)


def products_snapshot(root):
    value = snapshot(root,512*1024**2,8192)
    return {kind:{k:v for k,v in rows.items() if k not in PRODUCT_METADATA} for kind,rows in value.items()}



def signature_regions(raw, slice_start=0, slice_size=None):
    """Static byte-region diagnostics, not signature verification or tool admission."""
    view=memoryview(raw);size=len(raw)-slice_start if slice_size is None else slice_size
    require(0<=slice_start and 32<=size and slice_start+size<=len(raw),'signature_slice_bounds')
    macho=view[slice_start:slice_start+size]
    magic,cpu,_,_,count,commands_size,_,_=struct.unpack_from('<8I',macho)
    require(magic==0xfeedfacf and cpu==0x0100000c,'signature_arm64_header')
    require(count<=4096 and commands_size<=16*1024**2 and 32+commands_size<=size,'signature_commands_bounds')
    cursor=32;declared=[]
    for _ in range(count):
        require(cursor+8<=32+commands_size,'signature_command_header')
        command,length=struct.unpack_from('<II',macho,cursor)
        require(length>=8 and length%8==0 and cursor+length<=32+commands_size,'signature_command_bounds')
        if command==0x1d:
            require(length==16,'signature_command_size')
            declared.append(struct.unpack_from('<II',macho,cursor+8))
        cursor+=length
    require(cursor==32+commands_size,'signature_commands_coverage')
    require(len(declared)==1,'signature_absent_or_duplicate')
    offset,length=declared[0]
    require(offset>=cursor and length>=12 and offset+length<=size,'signature_blob_bounds')
    start=slice_start+offset;end=start+length;blob=view[start:end]
    magic,total,count=struct.unpack_from('>III',blob)
    require(magic==0xfade0cc0 and 12<=total<=length and count<=16 and 12+8*count<=total,'signature_superblob_bounds')
    entries=[];ranges=[];slots=set()
    for i in range(count):
        slot,at=struct.unpack_from('>II',blob,12+8*i)
        require(slot not in slots and at>=12+8*count and at+8<=total,'signature_index_bounds')
        slots.add(slot);kind,blob_size=struct.unpack_from('>II',blob,at)
        require(blob_size>=8 and at+blob_size<=total,'signature_child_bounds')
        require(all(at+blob_size<=a or at>=b for a,b in ranges),'signature_child_overlap')
        ranges.append((at,at+blob_size))
        entries.append({'slot':slot,'magic':hex(kind),'offset':start+at,'bytes':blob_size,
                        'sha256':hashlib.sha256(blob[at:at+blob_size]).hexdigest(),
                        'codeDirectory':kind==0xfade0c02})
    prefix=view[:start];suffix=view[end:];digest=hashlib.sha256();digest.update(prefix);digest.update(suffix)
    return {'sliceOffset':slice_start,'sliceBytes':size,'signatureOffset':start,'signatureBytes':length,
            'prefix':{'offset':0,'bytes':start,'sha256':hashlib.sha256(prefix).hexdigest()},
            'signatureSHA256':hashlib.sha256(blob).hexdigest(),
            'suffix':{'offset':end,'bytes':len(raw)-end,'sha256':hashlib.sha256(suffix).hexdigest()},
            'nonSignatureSHA256':digest.hexdigest(),'coveredBytes':len(prefix)+len(blob)+len(suffix),
            'superBlobBytes':total,'superBlobTrailingBytes':length-total,'blobs':entries,
            'codeDirectories':[entry for entry in entries if entry['codeDirectory']]}


def tool_inventory(developer, expected):
    """Bounded read-only diagnostics. Observed identity never changes admission pins."""
    started=time.monotonic();deadline=started+30;remaining=1024**3
    developer=Path(developer).resolve()
    result={'schema':1,'diagnosticOnly':True,'releaseAcceptance':False,'admission':'not-evaluated',
            'developer':str(developer),'complete':True,'entries':{},
            'limits':{'seconds':30,'fileBytes':512*1024**2,'totalHashBytes':1024**3,
                      'additionalMachOReadBytes':1024**3,'metadataBytes':64*1024}}
    def sample(label,path,expected_sha=None,expected_fields=None,metadata=False,metadata_fields=None):
        nonlocal remaining
        path=Path(path);row={'path':str(path),'expectedSHA256':expected_sha,
                            'expectedFields':expected_fields or {},'observed':{}}
        result['entries'][label]=row;raw=None
        try:
            require(time.monotonic()<deadline,'inventory_deadline')
            info=path.stat();observed=row['observed']
            def unchanged():
                now=path.stat()
                return (now.st_dev,now.st_ino,now.st_size,now.st_mtime_ns,now.st_ctime_ns)==(info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns)
            observed.update(resolvedPath=str(path.resolve()),symlink=path.is_symlink(),bytes=info.st_size)
            require(stat.S_ISREG(info.st_mode),'inventory_not_regular')
            require(info.st_size <= (1024**2 if metadata else 512*1024**2) and info.st_size<=remaining,'inventory_byte_cap')
            chunks=[];count=0
            with path.open('rb') as stream:
                while True:
                    require(time.monotonic()<deadline,'inventory_deadline')
                    chunk=stream.read(min(1024**2,info.st_size-count+1))
                    if not chunk:break
                    count+=len(chunk);remaining-=len(chunk)
                    require(count<=info.st_size and remaining>=0,'inventory_file_grew');chunks.append(chunk)
            raw=b''.join(chunks)
            require(unchanged() and count==info.st_size,'inventory_file_changed')
            observed.update(sha256=hashlib.sha256(raw).hexdigest(),magic=raw[:4].hex())
            row['matchesExpectedSHA256']=None if expected_sha is None else observed['sha256']==expected_sha
            if metadata:
                value=plistlib.loads(raw);observed['fields']={}
                for key in metadata_fields or expected_fields:
                    field=value.get(key)
                    require(isinstance(field,str) and len(field)<=256,'inventory_metadata_field')
                    observed['fields'][key]=field
                if expected_fields is not None:row['matchesExpectedFields']=observed['fields']==expected_fields
            elif raw[:4] in (b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):
                try:
                    # Reuse the already qualified UUID parser; its extra read is bounded by
                    # the checked regular-file size and stable stat identity above/below.
                    observed['arm64UUID']=arm64_uuid(path)
                except Exception as exc:
                    row['machODiagnosticError']=type(exc).__name__+': '+str(exc)[:256]
                require(unchanged() and time.monotonic()<deadline,'inventory_macho_changed_or_deadline')
                try:
                    require('machODiagnosticError' not in row,'inventory_uuid_unavailable')
                    magic=struct.unpack_from('>I',raw)[0];slices=[];slice_start=0
                    if magic in (0xcafebabe,0xcafebabf):
                        count=struct.unpack_from('>I',raw,4)[0];require(0<count<=16,'inventory_fat_count')
                        stride=20 if magic==0xcafebabe else 32
                        for i in range(count):
                            offset=8+i*stride;cpu=struct.unpack_from('>I',raw,offset)[0]
                            start,size=struct.unpack_from('>II' if stride==20 else '>QQ',raw,offset+8)
                            require(start+size<=len(raw),'inventory_fat_bounds')
                            if cpu==0x0100000c:
                                slices.append(memoryview(raw)[start:start+size]);slice_start=start
                        observed['container']='universal'
                    else:slices=[raw];observed['container']='thin'
                    require(len(slices)==1,'inventory_unique_arm64_slice')
                    observed['arm64SliceSHA256']=hashlib.sha256(slices[0]).hexdigest()
                    observed['arm64SliceBytes']=len(slices[0])
                    try:
                        observed['codeSignature']=signature_regions(raw,slice_start,len(slices[0]))
                    except Exception as exc:
                        row['codeSignatureDiagnosticError']=type(exc).__name__+': '+str(exc)[:256]
                except Exception as exc:
                    row.setdefault('machODiagnosticError',type(exc).__name__+': '+str(exc)[:256])
                    # A parse failure is diagnostic only; unchanged tools() still decides admission.
                require(unchanged() and time.monotonic()<deadline,'inventory_macho_changed_or_deadline')
            require(unchanged() and time.monotonic()<deadline,'inventory_final_changed_or_deadline')
        except Exception as exc:
            row['error']=type(exc).__name__+': '+str(exc)[:256];result['complete']=False
        return raw
    sample('xcode-version',developer.parent/'version.plist',expected_fields={
        'CFBundleShortVersionString':'27.1','ProductBuildVersion':'27A9275'},metadata=True)
    sdk=(developer/'Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk').resolve()
    result['SDKROOT']=str(sdk)
    sample('sdk-settings',sdk/'SDKSettings.plist',expected['qualifiedSDKSettingsSHA256'],
           {'Version':'27.1','CanonicalName':'iphonesimulator27.1'},True)
    launcher=None
    for name,relative in {'xcodebuild':'usr/bin/xcodebuild','xctrace':'usr/bin/xctrace','simctl':'usr/bin/simctl',
                         'xcresulttool':'usr/bin/xcresulttool','swift-frontend':'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend'}.items():
        raw=sample(name,developer/relative,expected['qualifiedToolHashes'].get(name))
        if name=='simctl':launcher=raw
    try:
        require(launcher is not None and len(launcher)<=65536,'inventory_launcher_size')
        lines=launcher.decode('utf-8').splitlines()
        match=re.fullmatch(r'exec "([^"\n]+)" "\$\{@\}"',lines[-1])
        require(lines[0]=='#!/bin/bash' and match is not None,'inventory_launcher_shape')
        actual=Path(match[1]);require(actual.is_absolute(),'inventory_launcher_absolute')
        sample('simctl-executable',actual)
        known=Path('/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl')
        if actual==known and actual.resolve()==known:
            sample('coresimulator-version',known.parents[1]/'Info.plist',metadata=True,
                   metadata_fields=('CFBundleIdentifier','CFBundleVersion','CFBundleShortVersionString'))
        else:
            result['entries']['coresimulator-version']={'observed':{},'diagnostic':'launcher_target_not_known_framework_path'}
    except Exception as exc:
        result['entries']['simctl-executable']={'expectedSHA256':None,'observed':{},'error':type(exc).__name__+': '+str(exc)[:256]}
        result['complete']=False
    result['hashedBytes']=1024**3-remaining;result['elapsedSeconds']=time.monotonic()-started
    require(len(json.dumps(result).encode())<=64*1024,'inventory_metadata_cap')
    return result


def tools(developer):
    developer = Path(developer).resolve(); contract = frozen()
    version = plistlib.loads((developer.parent/'version.plist').read_bytes())
    require(version['CFBundleShortVersionString']=='27.1' and version['ProductBuildVersion']=='27A9275','exact_Xcode')
    sdk = (developer/'Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk').resolve()
    settings = plistlib.loads((sdk/'SDKSettings.plist').read_bytes())
    require(settings['Version']=='27.1' and settings['CanonicalName']=='iphonesimulator27.1','exact_SDK')
    require(sha(sdk/'SDKSettings.plist')==contract['qualifiedSDKSettingsSHA256'],'qualified_SDK_metadata_changed')
    result = {}
    for name,relative in {'xcodebuild':'usr/bin/xcodebuild','xctrace':'usr/bin/xctrace','simctl':'usr/bin/simctl',
                         'xcresulttool':'usr/bin/xcresulttool','swift-frontend':'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend'}.items():
        path=developer/relative; require(path.is_file() and not path.is_symlink(),'literal_tool:'+name)
        result[name]={'path':str(path),'sha256':sha(path)}
    for name,digest in contract['qualifiedToolHashes'].items(): require(result[name]['sha256']==digest,'qualified_tool_changed:'+name)
    # The public simctl entrypoint is a launcher; bind its actual executable too.
    lines=Path(result['simctl']['path']).read_text().splitlines()
    match=re.fullmatch(r'exec "([^"]+)" "\$\{@\}"',lines[-1]); require(match is not None,'simctl_launcher')
    actual=Path(match[1]);result['simctl'].update(executable=str(actual),executableSHA256=sha(actual))
    launcher_identity(result['simctl']['path'],result['simctl']['sha256'],str(actual),sha(actual))
    result.update(developer=str(developer),SDKROOT=str(sdk),SDKSettingsSHA256=sha(sdk/'SDKSettings.plist'),
                  versionPlistSHA256=sha(developer.parent/'version.plist'),xcode='Xcode 27.1\nBuild version 27A9275')
    return result


def verify_tools(value):
    require(tools(value['developer'])==value,'tool_or_SDK_changed')


def environment(runner):
    import platform
    from check_ios_performance_environment import runner_environment
    toolchain=runner.tools['xcodebuild']; device=os.environ['SIMULATOR_ID']
    raw=runner.command('runtime','simctl',['list','-j'],30,terminal_query=True).read_bytes()
    observed=runner_environment(os.environ,json.loads(raw),runner.tools['xcode'],platform.machine())
    require(observed==dict(osVersion='27.0',osBuildNumber='24A434',modelName='iPhone 17',architecture='arm64',xcode=runner.tools['xcode']), 'exact_runtime_environment')
    require(str(uuid.UUID(device)).upper()==device,'device_uuid')
    return {'device':device,'observed':observed,'hostOS':platform.mac_ver()[0]}


def verify_config(c):
    frozen(); verify_tools(c['tools'])
    require(c['diagnosticOnly'] is True and c['releaseAcceptance'] is False,'config_scope')
    require(selected_snapshot(c['sourceRoot'],c['sourceSnapshot']['files'])==c['sourceSnapshot'],'source_changed')
    require(snapshot(c['productsRoot'],512*1024**2,8192)==c['productsSnapshot'],'products_changed')
    require(sha(c['plan'])==c['planSHA256'],'plan_changed')
    require(sha(c['setupReceipt'])==c['setupReceiptSHA256'],'setup_changed')
    setup=read(c['setupReceipt'])
    require(setup['status']=='passed' and setup['case']=='scroll'
            and [s['stage'] for s in setup['stages']]==['boot','list-installed-apps','verify-app-absent','seed-pasteboard']
            and all(s['status']=='passed' for s in setup['stages']),'setup_not_passed')
    for name,digest in c['inputReceipts'].items():require(sha(Path(c['evidenceRoot'])/name)==digest,'input_receipt_changed:'+name)
    from preserve_performance_store import owned, binding, load
    evidence=Path(c['evidenceRoot']); owner=owned(evidence)
    require(owner and owner['createdUDID']==c['simulatorUDID'] and owner['creationStatus']=='verified','owned_device')
    attempt=load(evidence/'native-attempt.json')
    require(all(attempt[k]==v for k,v in binding(evidence,owner).items()),'attempt_binding')


def copy_snapshot(source, destination, value, budget):
    source=Path(source);destination=Path(destination);destination.mkdir(parents=True,exist_ok=False)
    for name in value['files']:
        src=source/name;dst=destination/name;dst.parent.mkdir(parents=True,exist_ok=True)
        with src.open('rb') as incoming,dst.open('xb') as outgoing:
            while True:
                chunk=incoming.read(1024**2)
                if not chunk:break
                outgoing.write(chunk);budget()
        shutil.copystat(src,dst)
    require(selected_snapshot(source,value['files'])==value==selected_snapshot(destination,value['files']),'copy_custody')
