from pathlib import Path
import json,hashlib,re,shutil
p=Path(__file__).resolve().parent;c=p.parent/'core-collection';head='0d5bb1b22e9e84cd4b8c2b07317f91cfc703b60c';merge='525d68ae2dbb46f21be8d71a495c10f7c1246f7f';rid=42316648580
read=lambda p:json.loads(p.read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
run=read(c/f'{rid}-run.json');jobs=read(c/f'{rid}-jobs.json');assert run['status']=='completed' and run['conclusion']=='success' and run['run_attempt']==1 and run['head_sha']==head
for name in [f'{rid}-run.json',f'{rid}-jobs.json','hosted-merge-commit.json']:
 shutil.copyfile(c/name,p/name)
shutil.copyfile(c/'candidate-verifiers/.github/workflows/security.yml',p/'security.yml')
proof={'candidate':head,'merge':merge,'mergeTreeExactlyMatchesCandidate':read(c/'evidence/merge-source-proof.json')['treesIdentical'],'runID':rid,'attempt':1,'conclusion':run['conclusion'],'analyses':[],'jobs':[],'releaseAcceptance':False,'limits':['Successful rules and zero findings do not establish absence of vulnerabilities.','API-returned SARIF omits artifact/input coverage and invocation diagnostics; logged extracted paths are observations, not a complete input or semantic-coverage guarantee. Swift security analysis is separately pending in core run.']}
tracked={x['path'] for x in read(c/'immutable-source-manifest.json')['files']}
for j in jobs['jobs']:
 assert j['conclusion']=='success';f=c/f'{rid}-job-{j["id"]}.log';shutil.copyfile(f,p/f.name);s=f.read_text();rows={'jobID':j['id'],'name':j['name'],'status':'success','logSHA256':sha(f)}
 if j['name'].startswith('CodeQL'):
  commits=[];lines=s.splitlines()
  for i,line in enumerate(lines[:-1]):
   if 'git log -1 --format=%H' in line:
    m=re.search(r'\b([a-f0-9]{40})$',lines[i+1]);assert m;commits.append(m[1])
  assert commits==[merge];rows['checkoutVerified']=True
  prefix='/home/runner/work/room-in-the-cart/room-in-the-cart/'
  observed=sorted(set(re.findall(r'Done extracting '+re.escape(prefix)+r'(.+?) \(\d+ ms\)',s)))
  rows['loggedExtractedRepositoryPaths']=[x for x in observed if x in tracked];rows['loggedExtractedOtherPaths']=[x for x in observed if x not in tracked]
  rows['fileCoverageDisabledForPullRequestMessage']='file coverage information is only enabled when analyzing the default branch and protected branches' in s
 proof['jobs'].append(rows)
for record in read(p/'sarif-metadata.json'):
 a=record['analysis'];assert a['commit_sha']==merge and a['analysis_key']=='.github/workflows/security.yml:codeql' and not a['error'] and not a['warning']
 f=p/record['sarifPath'];assert sha(f)==record['sha256'];sarif=read(f);sr,=sarif['runs'];assert sr['automationDetails']['id']==a['category']+'/' and sr['versionControlProvenance'][0]['revisionId']==merge
 assert len(sr['results'])==a['results_count'];rules=sum(len(x.get('rules',[])) for x in sr['tool'].get('extensions',[]));assert rules==a['rules_count']
 proof['analyses'].append({'analysisID':a['id'],'category':a['category'],'rules':rules,'findings':len(sr['results']),'error':a['error'],'warning':a['warning'],'sarifSHA256':sha(f),'sourceCommitVerified':True,'createdAt':a['created_at']})
assert {a['category'] for a in proof['analyses']}=={'/language:actions','/language:javascript-typescript'}
(p/'verification.json').write_text(json.dumps(proof,indent=2)+'\n')
files={str(f.relative_to(p)):sha(f) for f in sorted(p.rglob('*')) if f.is_file() and f.name!='freeze.json'};(p/'freeze.json').write_text(json.dumps({'candidate':head,'runID':rid,'files':files,'releaseAcceptance':False},indent=2)+'\n')
print(json.dumps({'analyses':proof['analyses'],'loggedTrackedPathCounts':{x['name']:len(x.get('loggedExtractedRepositoryPaths',[])) for x in proof['jobs']},'freezeSHA256':sha(p/'freeze.json')}))
