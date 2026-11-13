from pathlib import Path
import csv, hashlib, io, json, re, sqlite3, subprocess, tempfile, zipfile
from datetime import datetime, timezone
ROOT=Path.cwd(); OUT=ROOT/'.build/AppleScrollFeedback20261106'
def sha(data): return hashlib.sha256(data).hexdigest()
def write(rel,data):
 p=OUT/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data if isinstance(data,bytes) else data.encode())
def jwrite(rel,data):write(rel,json.dumps(data,indent=2)+'\n')
prior=json.loads((ROOT/'.build/ScrollMetricRecurrence20261106/attachment-list.json').read_text())
rows=[]
for priorrow in prior['primaryArtifacts']:
 rows.append({k:priorrow[k] for k in ('role','commit','runID','jobID','attempt','artifactID','archivePath','archiveSHA256')})
rows.append({'role':'additional unwrapped omission on newer toolchain','commit':'5376a01227d9ccf2cba53123b7887c83531088de','runID':42261730525,'jobID':128057841463,'attempt':1,'artifactID':13526949819,'archivePath':str(ROOT/'.build/ReleaseToolchainQualification20261106/hosted-5376a01/qualification-scroll-1.zip'),'archiveSHA256':'06b89fd235aa764d0afcfc2d5d6e3f848c72ce860476d5be0db47d2a738c7db5'})
metric='com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration'
for row,label in zip(rows,['original-8f','comparator-0d33','qualification-5376']):
 p=Path(row['archivePath']);assert sha(p.read_bytes())==row['archiveSHA256'];row['archiveDigestReverified']=True;row['archiveBytes']=p.stat().st_size
 row['packagedFiles']=[]
 with zipfile.ZipFile(p) as z:
  prefix='scroll/' if label.startswith('qualification') else ''
  for name in ['metrics.json','test-summary.json','toolchain.txt']:
   data=z.read(prefix+name);dest=label+'/'+name;write(dest,data);row['packagedFiles'].append({'path':dest,'archiveMember':prefix+name,'sha256':sha(data),'byteIdentical':True})
  summary=json.loads(z.read(prefix+'test-summary.json'));row['deviceAndConfiguration']=summary['devicesAndConfigurations'];row['toolchain']=z.read(prefix+'toolchain.txt').decode().strip();row['summaryEnvironmentDescription']=summary.get('environmentDescription');row['testResult']={k:summary[k] for k in ['passedTests','failedTests','skippedTests','result']};row['startUTC']=datetime.fromtimestamp(summary['startTime'],timezone.utc).isoformat();row['finishUTC']=datetime.fromtimestamp(summary['finishTime'],timezone.utc).isoformat()
  metrics=json.loads(z.read(prefix+'metrics.json'))[0]['testRuns'][0]['metrics'];row['series']=[{'identifier':x['identifier'],'unit':x['unitOfMeasurement'],'samples':x['measurements']} for x in metrics]
  member=prefix+('Tests.xcresult/database.sqlite3' if prefix else 'Performance.xcresult/database.sqlite3');db=z.read(member)
  with tempfile.TemporaryDirectory() as t:
   dbpath=Path(t)/'original.sqlite3';dbpath.write_bytes(db)
   with sqlite3.connect(dbpath.as_uri()+'?mode=ro',uri=True) as con:
    dbrows=con.execute('SELECT identifier, unitOfMeasurement, measurements FROM PerformanceMetrics').fetchall()
   assert sha(dbpath.read_bytes())==sha(db)
  dbout={'originalArchiveMember':member,'originalArchiveMemberSHA256':sha(db),'query':'SELECT identifier, unitOfMeasurement, measurements FROM PerformanceMetrics','readOnly':True,'rows':[{'identifier':x[0],'unit':x[1],'measurementsText':x[2]} for x in dbrows],'requiredScrollSeriesPresent':any(x[0]==metric for x in dbrows)}
  jwrite(label+'/original-xcresult-metrics-readback.json',dbout);row['originalXCTestDatabase']=dbout
  assert {x[0]:[float(v) for v in x[2].split(',')] for x in dbrows}=={x['identifier']:x['measurements'] for x in metrics}
  logname=prefix+('Tests.log' if prefix else 'Performance.log');log=z.read(logname);lines=log.decode().splitlines();selected=[{'line':i,'text':line} for i,line in enumerate(lines,1) if ' measured [' in line or ('Test Case ' in line and 'testScrollingPerformanceOnFiveHundredItemPickup' in line and ' passed (' in line) or i<=2]
  jwrite(label+'/console-excerpt.json',{'archiveMember':logname,'originalLogSHA256':sha(log),'lines':selected});row['originalConsoleLogSHA256']=sha(log)
  row['consoleReportedMetricIdentifiers']=re.findall(r'performanceMetricID:([^,\s]+)',log.decode())
  csvnames=[n for n in z.namelist() if n.startswith(prefix+'metrics-csv/') and n.endswith('.csv')]
  row['csvEvidence']=[]
  for n in csvnames:
   b=z.read(n);dest=label+'/metrics.csv';write(dest,b);row['csvEvidence'].append({'archiveMember':n,'sha256':sha(b),'packagedPath':dest,'containsScrollDuration':b'Scroll_DraggingAndDeceleration' in b})
  if not prefix:
   n='scroll-signpost-diagnostic.json';b=z.read(n);write(label+'/'+n,b);row['diagnosticSummarySHA256']=sha(b)
  row['requiredScrollSeriesPresent']=any(x['identifier']==metric for x in metrics)
  row['allRetainedSeriesHaveFiveSamples']=all(len(x['measurements'])==5 for x in metrics)
 assert row['requiredScrollSeriesPresent']==('comparator' in label)
# Immutable source provenance: only selected performance-related files.
sourcepaths=['ios/UITests/ReleasePerformanceUITests.swift','ios/UITests/Fixtures/ReleaseLedger500.txt','.github/workflows/ios-performance.yml','scripts/check_ios_performance.py','ios/RoomInTheCart.xcodeproj/xcshareddata/xcschemes/RoomInTheCart-Performance.xcscheme']
source={}
for path in sourcepaths:
 source[path]={}
 for row in rows:
  commit=row['commit'];data=subprocess.check_output(['git','show',commit+':'+path]);blob=subprocess.check_output(['git','rev-parse',commit+':'+path],text=True).strip();source[path][commit]={'gitBlob':blob,'sha256':sha(data)}
sourcefile=subprocess.check_output(['git','show',rows[0]['commit']+':'+sourcepaths[0]]).decode();lines=sourcefile.splitlines()
def method(start,end):return sourcefile[sourcefile.index(start):sourcefile.index(end)]
excerpt=method('    func testScrollingPerformance','    private func importFixture')+method('    private func measurementOptions','    private func milliseconds')
write('UnwrappedScrollExcerpt.swift','// Verbatim method excerpts from '+sourcepaths[0]+'\n// Same file bytes at all three commits in evidence-map.json.\n// Context required: enclosing XCTestCase, XCUIApplication app, native 500-item importFixture(), screenshot().\n// This is not a standalone reproduction project; no new test was created or run.\n\n'+excerpt)
write('ReleaseLedger500.txt',subprocess.check_output(['git','show',rows[0]['commit']+':ios/UITests/Fixtures/ReleaseLedger500.txt']))
source['excerpt']={'path':'UnwrappedScrollExcerpt.swift','originalFileLineRanges':[[153,184],[247,252]],'verbatimExcerptSHA256':sha(excerpt.encode()),'fullTestFileIdenticalAcrossAllThreeCommits':len({v['sha256'] for v in source[sourcepaths[0]].values()})==1}
# Retained build archives: identity and only the Release build invocation, never unrelated logs.
builds=[]
for row,label,reportfile in zip(rows[:2],['original-8f','comparator-0d33'],['core-deep-performance-audit.json','core-final-audit.json']):
 short=row['commit'][:7];auditpath=ROOT/f'docs/evidence/native/ci-{short}-20261106/{reportfile}';meta=json.loads(auditpath.read_text())['digestVerifiedArchives']['iphone-performance-build-log-1'];archive=Path(row['archivePath']).parent/'iphone-performance-build-log-1.zip';assert sha(archive.read_bytes())==meta['sha256']
 with zipfile.ZipFile(archive) as z:
  b=z.read('PerformanceBuild.log');first=b.decode().splitlines()[:2]
 build={'commit':row['commit'],'runID':row['runID'],'artifactID':meta['artifactID'],'archivePath':str(archive),'sha256':meta['sha256'],'archiveDigestReverified':True,'logSHA256':sha(b),'invocationFirstTwoLines':first,'evidenceSource':str(auditpath),'scope':'Build log provenance; compiled product bytes were not downloaded or reverified for this preparation.'};builds.append(build);jwrite(label+'/build-provenance.json',build)
q=ROOT/'.build/ReleaseToolchainQualification20261106/hosted-5376a01/qualification-build-evidence-1.zip';meta=json.loads((ROOT/'docs/evidence/native/toolchain-qualification-20261106/build-evidence-summary.json').read_text());assert sha(q.read_bytes())==meta['sha256'];builds.append({'commit':rows[2]['commit'],'runID':rows[2]['runID'],'artifactID':meta['artifactID'],'archivePath':str(q),'sha256':meta['sha256'],'archiveDigestReverified':True,'environment':meta['environment'],'scope':'Retained source/product manifest qualification; product binaries not downloaded for independent preparation.'})
excluded=[{'role':'not a missing-series reproduction: test never ran','source':'docs/evidence/native/ci-804030e-20261106/scroll-pretest-setup-failure.json'},{'role':'not the original issue: rejected forwarding wrapper on Xcode 27.1','source':'docs/evidence/native/scroll-report-probe-20261106/REVIEW.md'}]
for item in excluded:item['sourceSHA256']=sha((ROOT/item['source']).read_bytes())
current=json.loads((ROOT/'docs/evidence/native/ci-804030e-20261106/scroll-pretest-setup-failure.json').read_text())
excluded[0]['identity']={k:current[k] for k in ['candidate','runID','attempt','jobID','artifactID','archiveSHA256','executedNativeTests','classification']}
excluded[1]['identity']={'xcode':'27.1','xcodeBuild':'27A9275','iOS':'26.2','iOSBuild':'23C54','frozenWrapperSourceSHA256':'cae07fc0191c062fcc92a25b675e0ee2fdb716f6995372bc52864ce5a9769bfe','localLogSHA256':'a276ce8a3487cbe5065bf60094289f6eac2206828fd96a1bb791dd73943c9309','result':'null archive-search dates, MXMOSSignpostMetric _constructProbe assertion, then manualStop exception; metrics []'}
manifest={'status':'Prepared locally; not submitted','requiredMetric':metric,'primaryEvidence':rows,'sourceProvenance':source,'buildProvenance':builds,'excludedFromReproductionCount':excluded,'privacyScope':'Only scroll test metadata, metric tables, console/build invocation excerpts, fictional fixture and minimal code are packaged. No raw Records, credentials, app-ledger databases, images, opaque xcresult objects, or unrelated test artifacts copied. Original ZIPs are referenced, not duplicated or uploaded.','limitations':['No new native execution, hosted action, download or Git mutation.','Source identity and artifact provenance are evidence, not proof of deterministic reproduction or collector root cause.','Original archived XCTest metric database was read with SQLite mode=ro; temporary copy deleted. No native xcresulttool invoked.','No fresh sysdiagnose or standalone minimized app is provided.','UIKit diagnostic summaries do not prove collector receipt or true measurement boundaries.']}
manifest['limitations'].append('Qualification build metadata labels macOS 26.6.2/25G83; its XCTest environmentDescription says Built with macOS 26.7.2. These differently sourced descriptions are retained without assuming they describe the same layer.')
jwrite('evidence-map.json',manifest)
print('Prepared',len(rows),'original archive readbacks and source/build provenance in',OUT)
