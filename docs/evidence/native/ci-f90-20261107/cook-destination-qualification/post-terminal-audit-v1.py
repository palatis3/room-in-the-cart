#!/usr/bin/env python3
"""Read-only, bounded audit of this exact completed run. Never starts native work."""
from pathlib import Path, PurePosixPath
import argparse,base64,collections,hashlib,importlib.util,json,os,re,resource,shutil,sqlite3,stat,subprocess,sys
ROOT=Path('/Users/palatis/Room in the Cart')
RUN=ROOT/'.build/CookDestinationTraceNov08'
BUNDLE=RUN/'native.xcresult'
ORIGINAL=ROOT/'.build/CIF90Nov07/speech/pristine-members/test-plan/SharedDeliveryUITests-recovery-cook-and-closeout.txt'
SCOPE='SharedDeliveryUITests/testShopperSavesDatedCookCopyAndReopensRecipientSendRecord'
MARKER='S24_COOK_DESTINATION_TRACE'
MAX_COPY=256_000_000
MAX_STDOUT=256_000_000
MAX_METADATA=256_000
MAX_JSON=10_000_000
MAX_MARKERS=1000
OUT=RUN/'post-terminal-audit'
AUDIT_STARTED=False
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def require(v,msg):
 if not v:raise RuntimeError(msg)
def inventory(root,limit):
 rows=[];total=0
 for p in sorted(root.rglob('*')):
  require(not p.is_symlink(),'Symlink refused')
  if p.is_dir():continue
  st=p.stat();require(stat.S_ISREG(st.st_mode),'Special member refused')
  total+=st.st_size;require(len(rows)<50000 and total<=limit,'Inspection-copy budget refused')
  rows.append({'file':str(p.relative_to(root)),'bytes':st.st_size,'sha256':digest(p)})
 return rows
def command(cmd,name,cap=MAX_JSON,timeout=120):
 def bounded():resource.setrlimit(resource.RLIMIT_FSIZE,(cap,cap))
 with (OUT/(name+'.stdout')).open('xb') as o,(OUT/(name+'.stderr')).open('xb') as e:
  p=subprocess.run(cmd,cwd=ROOT,stdout=o,stderr=e,timeout=timeout,preexec_fn=bounded)
 receipt={'command':cmd,'exit':p.returncode,'fileSizeLimit':cap,'stdoutSHA256':digest(OUT/(name+'.stdout')),'stderrSHA256':digest(OUT/(name+'.stderr'))}
 save(OUT/(name+'.receipt.json'),receipt);return p.returncode
REF=re.compile(r'0~[A-Za-z0-9_-]+={0,2}')
def refs(bundle,ref):
 require(REF.fullmatch(ref),'Malformed object reference')
 p=bundle/'Data'/('refs.'+ref);require(p.stat().st_size<=MAX_METADATA,'Reference metadata budget refused');raw=p.read_bytes();pos=0
 def varint():
  nonlocal pos
  result=0;shift=0
  while True:
   require(pos<len(raw) and shift<63,'Malformed reference varint');v=raw[pos];pos+=1;result|=(v&127)<<shift
   if v<128:return result
   shift+=7
 n=varint();require(n<=10000,'Reference count refused');values=[]
 for _ in range(n):
  size=varint();v=raw[pos:pos+size];pos+=size;require(len(v)==65 and v[0]==0,'Malformed reference');values.append('0~'+base64.urlsafe_b64encode(v[1:]).decode())
 require(pos==len(raw),'Trailing reference bytes');return values
def export(bundle,ref,dest,name,cap):
 require(REF.fullmatch(ref),'Malformed export reference')
 rc=command(['xcrun','xcresulttool','export','object','--legacy','--path',str(bundle),'--id',ref,'--type','file','--output-path',str(dest)],name,cap)
 require(rc==0,'Exact object export failed or hit file-size cap; capture unavailable, not missing markers')
 require(dest.is_file() and dest.stat().st_size<=cap,'Export budget refused')
def main():
 global AUDIT_STARTED
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--native-exit',type=int,required=True,help='Actual terminal xcodebuild exit, supplied by owning root');a=ap.parse_args()
 require(a.native_exit in (0,65),'Only completed native test success/failure supported')
 ps=subprocess.check_output(['ps','-axo','pid=,command='],text=True)
 require(not any('xcodebuild' in x and 'CookDestinationTraceNov08/native.xcresult' in x for x in ps.splitlines()),'Native run still active; audit refused')
 run=json.loads((RUN/'run.json').read_text());expected=ORIGINAL.read_text().splitlines();require(len(expected)==5 and len(set(expected))==5,'Original five selectors invalid')
 selected=[x.removeprefix('-only-testing:') for x in run['command'] if x.startswith('-only-testing:')];require(selected==expected,'Run selection/order differs from exact original')
 require((RUN/'native.log').stat().st_size<=50_000_000,'Native log budget refused')
 rawlog=(RUN/'native.log').read_text();banners=re.findall(r'^\*\* TEST (?:EXECUTE )?(SUCCEEDED|FAILED) \*\*$',rawlog,re.M);require(len(banners)==1,'No unique terminal XCTest banner')
 require((a.native_exit==0)==(banners[0]=='SUCCEEDED'),'Supplied exit/banner mismatch')
 original_db=sqlite3.connect('file:'+str(BUNDLE/'database.sqlite3')+'?mode=ro&immutable=1',uri=True)
 actions=original_db.execute('select finished,diagnosticsRef from Actions').fetchall();original_db.close();require(actions and all(f is not None for f,_ in actions),'Result action still unfinished')
 OUT.mkdir(exist_ok=False)
 AUDIT_STARTED=True
 save(OUT/'terminal-input.json',{'nativeExit':a.native_exit,'banner':banners[0],'runJSONSHA256':digest(RUN/'run.json'),'nativeLogSHA256':digest(RUN/'native.log'),'originalSelectorsSHA256':digest(ORIGINAL),'expectedSelectors':expected,'runStatusAtAudit':run.get('status'),'noNativeOrSimulatorActions':True})
 originals=inventory(BUNDLE,MAX_COPY);save(OUT/'original-result-manifest.json',originals)
 copy=OUT/'inspection.xcresult';shutil.copytree(BUNDLE,copy);require(inventory(copy,MAX_COPY)==originals,'Inspection copy mismatch')
 (OUT/'selectors.txt').write_bytes(ORIGINAL.read_bytes())
 spec=importlib.util.spec_from_file_location('checker',ROOT/'scripts/check_ios_test_results.py');checker=importlib.util.module_from_spec(spec);spec.loader.exec_module(checker)
 lines=rawlog.splitlines();starts=[]
 for i,line in enumerate(lines):
  line=checker.recover_interleaved_case(line,lines[i+1] if i+1<len(lines) else '')
  m=checker.XCTEST_CASE_LINE.fullmatch(line)
  if m and m['event']=='started.':starts.append({'line':i+1,'selector':'/'.join(m.group('target','suite','method'))})
 save(OUT/'order-audit.json',{'expected':expected,'observedStarts':starts,'exactOriginalOrder':[x['selector'] for x in starts]==expected,'consoleFailures':checker.execution_log_failures(iter(rawlog.splitlines(True)),expected)})
 for kind in ['summary','tests']:
  rc=command(['xcrun','xcresulttool','get','test-results',kind,'--path',str(copy)],kind);require(rc==0,'Structured result export unavailable');(OUT/(kind+'.json')).write_bytes((OUT/(kind+'.stdout')).read_bytes())
 rc=command(['python3','scripts/check_ios_test_results.py','--selectors',str(OUT/'selectors.txt'),'--summary',str(OUT/'summary.json'),'--tests',str(OUT/'tests.json'),'--result-bundle',str(copy),'--test-log',str(RUN/'native.log'),'--expected-count','5'],'strict')
 save(OUT/'strict-status.json',{'exit':rc,'status':'passed' if rc==0 else 'failed','warningEvidenceNeverAssumedZero':True})
 c=sqlite3.connect('file:'+str(copy/'database.sqlite3')+'?mode=ro&immutable=1',uri=True);c.row_factory=sqlite3.Row
 issues=[dict(x) for x in c.execute('select i.rowid as issueRowID,i.uuid,i.issueType,i.compactDescription,i.timestamp,i.sourceCodeContext_fk,r.identifierURL from TestIssues i left join TestCaseRuns r on r.rowid=i.testCaseRun_fk where i.issueType = ?',('Runtime Warning',))]
 require(len(issues)<=100,'Runtime issue inventory budget refused')
 for issue in issues:
  frames=[dict(x) for x in c.execute('select f.*,s.imageName,s.symbolName from SourceCodeFrames f left join SourceCodeSymbolInfos s on s.rowid=f.symbolInfo_fk where f.context_fk=? order by f.orderInContainer',(issue['sourceCodeContext_fk'],))]
  require(len(frames)<=1000,'Runtime frame budget refused');issue['sourceFrames']=frames
 save(OUT/'runtime-issues-separate.json',{'scope':'Original structured runtime issues, independently of destination state; strict checker remains authoritative for complete warning evidence.','speechReadback':[x for x in issues if 'testShopperReviewsExactEditedCookWordingBeforeReadback' in (x['identifierURL'] or '')],'otherCases':[x for x in issues if 'testShopperReviewsExactEditedCookWordingBeforeReadback' not in (x['identifierURL'] or '')]})
 drefs=[x[0] for x in c.execute('select distinct diagnosticsRef from Actions where diagnosticsRef is not null')];c.close();require(len(drefs)==1,'Ambiguous diagnostic roots; capture unavailable')
 ref=drefs[0];traversal=[]
 for level in range(3):
  dest=OUT/f'directory-{level}.json';export(copy,ref,dest,f'directory-{level}',MAX_METADATA)
  entries=json.loads(dest.read_text());ids=refs(copy,ref);require(len(entries)==len(ids) and len(entries)<10000,'Directory/reference mismatch')
  for x in entries:
   p=PurePosixPath(x['name']);require(not p.is_absolute() and '..' not in p.parts and '/' not in x['name'] and '\\' not in x['name'] and x['type'] in (1,2),'Unsafe diagnostic directory entry')
  traversal.append({'directoryRef':ref,'entries':[{**x,'id':i} for x,i in zip(entries,ids)]});save(OUT/'directory-traversal.json',traversal)
  if level<2:
   choices=[i for x,i in zip(entries,ids) if x['type']==2 and x['name'].startswith('RoomInTheCartUITests-')];require(len(choices)==1,'Ambiguous test diagnostic directory');ref=choices[0]
  else:
   choices=[(x,i) for x,i in zip(entries,ids) if x['type']==1 and x['name']=='StandardOutputAndStandardError-dev.roominthecart.app.debug.txt'];require(len(choices)==1,'Exact app stdout object unavailable');entry,ref=choices[0]
 objectfile=copy/'Data'/('data.'+ref)
 save(OUT/'stdout-preflight.json',{'directoryEntry':entry,'objectReference':ref,'storedObjectBytes':objectfile.stat().st_size,'storedObjectSHA256':digest(objectfile),'expandedSizeAdvertised':entry.get('size'),'expandedSizeNote':'Retain supplied entry verbatim; absent size means unknown, not inferred from compressed object.','exportCapBytes':MAX_STDOUT})
 appout=OUT/'app-stdout-private.txt';export(copy,ref,appout,'app-stdout-export',MAX_STDOUT)
 events={'setter-enter','setter-return','appear','recipient-changed','allowed-changed','scene-changed','paid-changed','seat-deadline-fired','disappear','state-change','copy-identity-changed','page-changed','model-identity-changed','clear-correction','invalidate-enter','invalidate-return','review-enter','review-exit','review-result','check-recipient-enter','check-recipient-exit','baseline-accepted','mark-sent-enter','mark-sent-exit'}
 pattern=re.compile(re.escape(MARKER)+r' uptime=(?P<uptime>[0-9]+\.[0-9]+) pid=(?P<pid>[0-9]+) scope='+re.escape(SCOPE)+r' event=(?P<event>[a-z-]+) state=(?P<state>[0-9A-F-]{36}) from=(?P<from>true|false|-) to=(?P<to>true|false|-) confirmed=(?P<confirmed>true|false) review=(?P<review>true|false) request=(?P<request>true|false) correction=(?P<correction>true|false) allowed=(?P<allowed>true|false) paid=(?P<paid>true|false) active=(?P<active>true|false)')
 markers=[];bad=[];warningLines=[]
 with appout.open('r',encoding='utf-8',errors='replace') as f:
  for n,line in enumerate(f,1):
   if MARKER in line:
    m=pattern.fullmatch(line.strip())
    if m and m['event'] in events:
     row={'line':n,**m.groupdict()};row['uptime']=float(row['uptime']);row['pid']=int(row['pid']);markers.append(row);require(len(markers)<=MAX_MARKERS,'Marker count budget refused')
    else:bad.append(n)
   if any(s in line for s in ['Hang Risk','Thread running at User-interactive quality-of-service','BUG IN CLIENT OF libsqlite3.dylib:']):warningLines.append(n)
 save(OUT/'markers.json',markers)
 groups=collections.defaultdict(list)
 for x in markers:groups[(x['pid'],x['state'])].append(x)
 continuity=[]
 for (pid,state),rows in groups.items():
  continuity.append({'pid':pid,'state':state,'events':dict(collections.Counter(x['event'] for x in rows)),'monotonicUptime':all(a['uptime']<=b['uptime'] for a,b in zip(rows,rows[1:])),'first':rows[0],'last':rows[-1],'setterEvents':[x for x in rows if x['event'].startswith('setter-')],'invalidations':[{'previousEvent':rows[i-1]['event'] if i else None,'marker':x} for i,x in enumerate(rows) if x['event'].startswith('invalidate-')],'stateChanges':[x for x in rows if x['event']=='state-change'],'lifecycle':[x for x in rows if x['event'] in ('appear','disappear')]})
 save(OUT/'continuity.json',{'storageLifetimes':continuity,'scope':'Observed @State diagnostic tokens and immediate markers; onChange can coalesce; new tokens do not identify the parent cause; a pass is nonreproduction, not repair.'})
 save(OUT/'capture-receipt.json',{'status':'captured' if markers and not bad else 'unavailable-or-malformed','markers':len(markers),'malformedMarkerLines':bad,'appStdoutPath':str(appout),'appStdoutBytes':appout.stat().st_size,'appStdoutSHA256':digest(appout),'runtimeSignatureLineNumbers':warningLines,'runtimeSignatureScope':'Locations only, separately from validated destination markers; see structured issues/strict status. Not a complete runtime diagnosis.','privacy':'Only exact fixed-scope validated marker fields retained in markers.json; full stdout stays scratch/private.','limits':'Captured events qualify this execution only. Capped/missing export never means setter not called. No retries or native actions.'})
 require(inventory(BUNDLE,MAX_COPY)==originals,'Original result changed during audit')
 save(OUT/'audit-status.json',{'completed':True,'strictExit':rc,'originalBundleUnchanged':True,'sourcePins':run['sourcePins'],'sourceHashesAtAudit':[{'path':x['path'],'sha256':digest(ROOT/x['path']),'matchesRunPin':digest(ROOT/x['path'])==x['candidateSHA256']} for x in run['sourcePins']['files']]})
 print(json.dumps({'auditComplete':True,'strictExit':rc,'markers':len(markers),'scope':'No native actions; inspect retained failure/warning/capture statuses independently'}))
if __name__=='__main__':
 try:main()
 except Exception as e:
  if AUDIT_STARTED:save(OUT/'audit-unavailable.json',{'status':'unavailable','reason':str(e),'notEvidenceOfAbsentSetter':True,'noNativeActions':True})
  print('Audit refused/unavailable: '+str(e),file=sys.stderr);sys.exit(1)
