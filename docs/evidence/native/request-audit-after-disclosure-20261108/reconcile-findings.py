"""Reconcile actual unfiltered audit findings; never infer closure from count changes."""
from pathlib import Path
import json,re,collections,hashlib
BASE=Path(__file__).resolve().parent;ROOT=Path('/Users/palatis/Room in the Cart');run=BASE/'run';inspection=run/'inspection';out=run/'reconciliation'
assert not out.exists();verified=json.loads((inspection/'verification.json').read_text());assert verified['originalUnchanged'] and verified['sourceUnchanged']
def attachments(folder,prefix):
 result=[]
 for test in json.loads((folder/'manifest.json').read_text()):
  for entry in test.get('attachments',[]):
   if entry['suggestedHumanReadableName'].startswith(prefix):result.append({**entry,'path':folder/entry['exportedFileName']})
 return result
family=sorted(attachments(inspection/'custom-issues','Family request review accessibility'),key=lambda x:x['timestamp'])
automatic=attachments(inspection/'automatic-issues','Complete Issue Description')
errors=[];callbacks=[];pending=False
for number,line in enumerate((run/'native.log').read_text(errors='replace').splitlines(),1):
 if "Added attachment named 'Family request review accessibility'" in line:
  assert not pending,'two callbacks without an error';pending=True
  callbacks.append({'line':number,'elapsed':float(re.search(r't =\s*([0-9.]+)s',line).group(1))})
 if '<unknown>:0: error:' in line:
  assert pending,'unmatched native error';pending=False;errors.append({'line':number,'category':line.split('] : ',1)[-1]})
assert not pending and len(family)==len(automatic)==len(errors)==len(callbacks)
assert len(family)>0 or verified['nativeExit']==0,'audit did not establish zero findings'
assert len({a['timestamp'] for a in family})==len(family)
offsets=[a['timestamp']-e['elapsed'] for a,e in zip(family,callbacks)];spread=max(offsets)-min(offsets) if offsets else 0;assert spread<.025
assert collections.Counter(a['path'].read_text().splitlines()[0].strip() for a in family)==collections.Counter(a['path'].read_text().strip() for a in automatic)
def identity(text):
 attrs=next((line for line in text.splitlines() if line.startswith('Attributes: ')),None)
 result={'attributes':attrs,'label':None,'type':None,'context':None,'identifier':None,'disabled':None,'key':None}
 if attrs is None:return result
 def match(pattern):
  m=re.search(pattern,attrs);return m.group(1) if m else None
 label=match(r"label: '([^']*)'");typ=match(r'Attributes: ([^,]+),');ident=match(r"identifier: '([^']*)'");context=None
 if label in ['Protected portions','1']:
  ids=[('88888888-8888-4888-8888-888888888888','Sam protected meal8888'),('99999999-9999-4999-8999-999999999999','Mia protected meal9999')]
  found=[name for uid,name in ids if 'household.decision.meal.'+uid in text]
  context=found[0] if len(found)==1 else None
 if label=='Whole checkout':
  names=[name for name in ['Cap scope','Scope'] if "label: '"+name+", Whole checkout'" in text];context=names[0] if len(names)==1 else None
 ambiguous=label in ['Protected portions','1','Whole checkout'] and context is None
 result.update(label=label,type=typ,context=context,identifier=ident,disabled=', Disabled' in attrs,key=None if ambiguous else [typ,label,context])
 return result
oldPath=ROOT/'docs/evidence/native/request-decision-measurements-20261108/current-audit/findings.json';old=json.loads(oldPath.read_text())['newIssues'];assert len(old)==41
new=[]
for number,(entry,error) in enumerate(zip(family,errors),1):
 text=entry['path'].read_text();target=identity(text)
 sameTarget=[r for r in old if target['key'] is not None and r['target']['key']==target['key'] and not(target['identifier'] and r['target']['identifier'] and target['identifier']!=r['target']['identifier'])]
 same=[r['finding'] for r in sameTarget if r['category']==error['category']]
 new.append({'finding':number,'category':error['category'],'description':text.splitlines()[0],'target':target,'consoleLine':error['line'],'timestamp':entry['timestamp'],'attachmentPath':str(entry['path']),'attachmentSHA256':hashlib.sha256(entry['path'].read_bytes()).hexdigest(),'old41SameTargetSameCategory':same,'old41SameTargetOtherCategory':[{'finding':r['finding'],'category':r['category']} for r in sameTarget if r['category']!=error['category']],'disposition':'unattributed' if target['key'] is None else 'observed-again' if same else 'named-target/category-not-matched-to-old41','provenRegression':False})
oldRows=[]
for r in old:
 matches=[n['finding'] for n in new if r['finding'] in n['old41SameTargetSameCategory']]
 other=[{'finding':n['finding'],'category':n['category']} for n in new if any(x['finding']==r['finding'] for x in n['old41SameTargetOtherCategory'])]
 oldRows.append({'finding':r['finding'],'category':r['category'],'target':r['target']['label'],'context':r['target']['context'],'freshSameCategory':matches,'freshOtherCategory':other,'status':'unattributed-unmatchable' if r['target']['key'] is None else 'observed-again' if matches else 'different-category-observed' if other else 'not-observed-in-this-run','closed':False})
result={'oldIssueCount':41,'newIssueCount':len(new),'categories':dict(collections.Counter(n['category'] for n in new)),'callbackCorrelation':{'count':len(new),'timestampSpreadSeconds':spread,'automaticDescriptionMultisetMatches':True},'oldSourceSHA256':hashlib.sha256(oldPath.read_bytes()).hexdigest(),'newIssues':new,'old41Reconciliation':oldRows,'scope':'Exact unfiltered audit. Not-observed is not closed; unattributed findings are unmatched. Compare targets/categories/context and later rendered behavior, never subtract counts as bug fixes.'}
out.mkdir();(out/'findings.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n');print(json.dumps({k:v for k,v in result.items() if k not in ['newIssues','old41Reconciliation']},indent=2))
for n in new:print(n['finding'],n['category'],n['target']['label'],n['target']['context'],n['disposition'])
