"""Prepared runners only. Importing this module never launches native tools."""
from pathlib import Path
import contextlib,datetime,hashlib,json,os,shutil,subprocess
ROOT=Path('/Users/palatis/Room in the Cart')
BASE=ROOT/'.build/KnownTripVisibleResultNov08/execution-r1'
SOURCE=BASE/'fixed-source-manifest.json'
SOURCE_SHA='2acb55ff836b13edc94921827d4872d924a97d0641831bad9eff9f77f6fb59ae'
DEVELOPER=Path('/Applications/Xcode.app/Contents/Developer')
XCODE=DEVELOPER/'usr/bin/xcodebuild'
XCODE_SHA='d37fbcb4198c2474d847e5d7d4bf8394a1a9443890ad0153a76bc3e1d5576ec1'
UID='D420C2CA-0E73-4213-9B96-1EB62EB061F6'
FIXTURE_DD=ROOT/'.build/CookVoicePreparationNov08/fixture-r1/dd'
RELEASE_DD=ROOT/'.build/CookVoicePreparationNov08/release-style-r2/dd'
RESERVE=8*1024**3
ENV=dict(os.environ,DEVELOPER_DIR=str(DEVELOPER),PYTHONDONTWRITEBYTECODE='1')
ENV.pop('GITHUB_STEP_SUMMARY',None)
now=lambda:datetime.datetime.now(datetime.timezone.utc).isoformat()
def sha(file):return hashlib.sha256(Path(file).read_bytes()).hexdigest()
def write(file,value):Path(file).write_text(json.dumps(value,indent=2)+'\n')
def sources():
 assert sha(SOURCE)==SOURCE_SHA,'frozen manifest changed'
 pins=json.loads(SOURCE.read_text())
 assert len(pins)==556
 for name,want in pins.items():assert sha(ROOT/name)==want,'source changed: '+name
 for name,want in json.loads((BASE/'auxiliary-source-pins.json').read_text()).items():assert sha(ROOT/name)==want,'auxiliary source changed: '+name
 assert sha(XCODE)==XCODE_SHA,'Xcode executable changed'
 return pins

def free_space():
 free=shutil.disk_usage(ROOT).free
 assert free>=RESERVE,f'insufficient free disk: {free}; require {RESERVE}; remove nothing automatically'
 return free

def tree(folder):
 folder=Path(folder);assert folder.is_dir(),folder
 result={}
 for item in sorted(folder.rglob('*')):
  name=str(item.relative_to(folder))
  if item.is_symlink():result[name]={'kind':'symlink','target':os.readlink(item)}
  elif item.is_file():result[name]={'kind':'file','sha256':sha(item),'bytes':item.stat().st_size}
  elif item.is_dir():result[name]={'kind':'directory'}
  else:raise AssertionError('unsupported file type: '+str(item))
 return result

def clone_preserve(original,destination,receipt):
 original=Path(original);destination=Path(destination);assert not destination.exists()
 before=tree(original);assert before;free_space()
 # APFS clone only. Failure stops before native build; no full-copy fallback or deletion.
 result=subprocess.run(['/bin/cp','-cR',str(original),str(destination)],cwd=ROOT,env=ENV,capture_output=True,text=True)
 record={'original':str(original),'copy':str(destination),'command':['/bin/cp','-cR',str(original),str(destination)],'exitCode':result.returncode,'stdout':result.stdout,'stderr':result.stderr,'manifest':before,'recordedAtUTC':now()}
 if result.returncode==0:record.update(originalUnchanged=tree(original)==before,copyVerified=tree(destination)==before)
 write(receipt,record)
 assert result.returncode==0,'APFS clone failed; preserved failure; no build launched'
 assert record['originalUnchanged'] and record['copyVerified']
 free_space();return record

def no_native_job():
 output=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True,timeout=10)
 active=[]
 for line in output.splitlines():
  parts=line.strip().split(None,1)
  if len(parts)>1 and Path(parts[1]).name in ['xcodebuild','xctest','xctrace']:active.append(line)
 assert not active,'another native job remains active: '+repr(active)

@contextlib.contextmanager
def lane():
 no_native_job();lock=BASE/'qualification-native.lock'
 fd=os.open(lock,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 try:
  with os.fdopen(fd,'w')as f:json.dump({'pid':os.getpid(),'createdAtUTC':now()},f)
  no_native_job();yield
 finally:
  # Only remove this invocation's own coordination lock, never evidence/products.
  if lock.exists() and json.loads(lock.read_text()).get('pid')==os.getpid():lock.unlink()

def capture(args):return subprocess.check_output(args,cwd=ROOT,env=ENV,text=True,timeout=30).strip()
def toolchain():
 swift=capture(['/usr/bin/xcrun','--find','swift'])
 return {'developerDirectory':str(DEVELOPER),'xcodebuild':str(XCODE),'xcodebuildSHA256':sha(XCODE),'xcodeVersion':capture([str(XCODE),'-version']),'swiftExecutable':swift,'swiftVersion':capture([swift,'--version'])}
def device_identity(uid,expected_version,expected_build,appearance="light",content_size="large"):
 inventory=json.loads(capture(['/usr/bin/xcrun','simctl','list','devices','-j']))
 found=[{'runtimeIdentifier':runtime,**d}for runtime,devices in inventory['devices'].items()for d in devices if d['udid']==uid]
 assert len(found)==1 and found[0]['isAvailable'] and found[0]['state']=='Booted','owned selected device must already be booted; no auto-boot/reset'
 runtime=capture(['/usr/bin/xcrun','simctl','getenv',uid,'SIMULATOR_ROOT'])
 import plistlib
 version=plistlib.loads((Path(runtime)/'System/Library/CoreServices/SystemVersion.plist').read_bytes())
 assert version['ProductVersion']==expected_version and version['ProductBuildVersion']==expected_build,'unexpected owned runtime'
 settings={}
 for setting,value in [('appearance',appearance),('content_size',content_size),('increase_contrast','disabled')]:
  subprocess.run(['/usr/bin/xcrun','simctl','ui',uid,setting,value],cwd=ROOT,env=ENV,check=True,capture_output=True,timeout=30)
  settings[setting]=capture(['/usr/bin/xcrun','simctl','ui',uid,setting])
  assert settings[setting]==value,'simulator setting readback mismatch: '+setting
 return {'device':found[0],'bootedRuntimeRoot':runtime,'systemVersion':version,'settings':settings}
def require_pass(run):
 record=json.loads((run/'run.json').read_text());inspection=json.loads((run/'inspection/verification.json').read_text())
 assert record['status']=='completed' and record['nativeExit']==0 and record['sourceUnchanged'] and record['preservedProductsUnchanged']
 assert record['sourceManifestSHA256']==SOURCE_SHA
 assert inspection['nativeExit']==0 and inspection['strictExit']==0 and inspection['sourceUnchanged'] and inspection['originalUnchanged']
