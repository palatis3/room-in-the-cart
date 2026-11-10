/** Versioned first-adoption composition. Internal persistence/derivation only;
 * related request/meal authority must be validated by its existing family before
 * supplying the derived catalog/action. Never accept this history over HTTP. */
import {z} from 'zod';
import {quoteSchema} from './contracts.js';
import {digest as storedDigest} from './database.js';
import {trackingStateSchema,validateState,coverage,digest,PartitionError,type TrackingState,type Fact} from './shared-demand-tracking.js';
import {deriveFoodUndoBasket} from './shared-food-undo-basket.js';
import {validateDemandGraph} from './shared-demand-domain.js';
import {sharedDemandReceiptSchema} from './shared-demand-contracts.js';
const id=z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/),hash=z.string().regex(/^[a-f0-9]{64}$/);
export const adoptionComponentSchema=z.discriminatedUnion('kind',[
 z.object({kind:z.literal('none')}).strict(),
 z.object({kind:z.literal('requestAcceptance'),requestId:id,componentDigest:hash}).strict(),
 z.object({kind:z.literal('meal'),occurrenceId:id,componentDigest:hash}).strict()
]);
export const compoundAdoptionEvidenceSchema=z.object({version:z.literal(2),operationId:id,
 before:trackingStateSchema,after:trackingStateSchema,beforeQuote:quoteSchema,afterQuote:quoteSchema,
 component:adoptionComponentSchema}).strict();
export type CompoundAdoptionEvidence=z.infer<typeof compoundAdoptionEvidenceSchema>;
const eq=(a:unknown,b:unknown)=>digest(a)===digest(b);
function check(v:unknown,code:string):asserts v{if(!v)throw new PartitionError(code);}
function freeze<T>(v:T):T{if(v&&typeof v==='object'){Object.freeze(v);for(const x of Object.values(v))freeze(x);}return v;}
const lines=(s:TrackingState)=>s.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible}));
const basket=(ls:ReturnType<typeof lines>)=>ls.map(l=>({id:l.lineId,name:l.originalItem,packs:l.packs,priceMinor:l.unitPriceMinor,feeEligible:l.feeEligible})).sort((a,b)=>a.id.localeCompare(b.id));
function belongs(f:Fact,c:CompoundAdoptionEvidence['component']){
 if(c.kind==='requestAcceptance')return f.source.kind==='request'&&f.source.requestId===c.requestId;
 if(c.kind==='meal')return f.source.kind==='meal'?f.source.occurrenceId===c.occurrenceId:f.source.kind==='reservation'&&f.source.originOccurrenceId===c.occurrenceId;
 return false;
}
export function validateCompoundAdoptionEvidence(raw:unknown){
 const e=compoundAdoptionEvidenceSchema.parse(raw),b=validateState(e.before,e.before.catalog),a=validateState(e.after,e.after.catalog);
 check(b.graph.revision===0&&a.graph.revision===1&&b.graph.lines.length===0&&b.graph.contributions.length===0&&
  b.graph.edges.length===0&&b.graph.usedIds.length===0&&b.bindings.length===0&&b.unbound.every(u=>u.transferred===null),'not_first_adoption');
 check(a.unbound.length===0&&a.legacyLineIds.length===0,'incomplete_first_adoption');
 check(b.graph.householdId===a.graph.householdId&&b.graph.shopId===a.graph.shopId&&b.authorityEpoch===a.authorityEpoch&&b.privacyRevision===a.privacyRevision,'source_revision_or_privacy');
 check(storedDigest(e.beforeQuote)===b.quoteDigest&&storedDigest(e.afterQuote)===a.quoteDigest,'quote_history_unavailable');
 // Source changes must belong to the exact separately authenticated component.
 const sorted=(fs:Fact[])=>[...fs].sort((x,y)=>x.id.localeCompare(y.id));
 check(eq(sorted(b.catalog.filter(f=>!belongs(f,e.component))),sorted(a.catalog.filter(f=>!belongs(f,e.component)))),'unrelated_source_effect');
 if(e.component.kind==='requestAcceptance'){
  check(!b.catalog.some(f=>belongs(f,e.component))&&a.catalog.filter(f=>belongs(f,e.component)).length===1,'request_transition');
  check(eq(e.beforeQuote,e.afterQuote),'request_quote_effect');
 }
 return e;
}
export function recordCompoundAdoption(operationId:string,before:unknown,after:unknown,beforeQuote:unknown,afterQuote:unknown,component:unknown){
 const evidence=validateCompoundAdoptionEvidence({version:2,operationId,before,after,beforeQuote,afterQuote,component});
 return freeze({evidence,evidenceDigest:digest(evidence)});
}
const contextSchema=z.object({operationId:id,targetOperationId:id,evidenceDigest:hash,householdId:id,shopId:id,
 baseRevision:z.number().int().min(1).max(2147483646),authorityEpoch:z.number().int().nonnegative(),privacyRevision:z.number().int().nonnegative(),
 at:z.string().datetime({offset:true})}).strict();
/** Internal composition primitive. restoredCatalog is produced by authenticated
 * request/meal compensation, not supplied by the client. Every changed source
 * is restricted to the certificate's one related component. */
export function inverseCompoundAdoptionPartition(raw:unknown,currentRaw:unknown,contextRaw:unknown,
 currentQuote:unknown,restoredCatalog:readonly Fact[],now:Date){
 const e=validateCompoundAdoptionEvidence(raw),c=contextSchema.parse(contextRaw),current=trackingStateSchema.parse(currentRaw);
 validateState(current,current.catalog);
 check(c.operationId!==e.operationId&&c.targetOperationId===e.operationId&&c.evidenceDigest===digest(e),'history_unavailable');
 check(current.graph.householdId===c.householdId&&current.graph.shopId===c.shopId&&e.after.graph.householdId===c.householdId&&e.after.graph.shopId===c.shopId,'wrong_scope');
 check(current.graph.revision===c.baseRevision&&current.graph.revision>=e.after.graph.revision,'stale_revision');
 check(current.authorityEpoch===c.authorityEpoch&&current.privacyRevision===c.privacyRevision&&e.after.authorityEpoch===c.authorityEpoch&&e.after.privacyRevision===c.privacyRevision,'source_revision_or_privacy');
 check(storedDigest(currentQuote)===current.quoteDigest,'quote_conflict');
 const coreFact=(f:Fact)=>{const {revision,sourceLabel,...core}=f;return core;};
 for(const f of e.after.catalog){const live=current.catalog.find(x=>x.id===f.id);
  check(live&&(e.component.kind==='meal'&&belongs(f,e.component)?eq(coreFact(live),coreFact(f)):eq(live,f)),'source_revision_or_privacy');}
 // Recording a valid forward protected edit is allowed; its compensation may
 // still be forbidden by the unchanged protection contract.
 for(const f of e.before.catalog.filter(f=>f.source.kind==='reservation')){const a=e.after.catalog.find(x=>x.id===f.id);
  check(a&&eq(a.source,f.source)&&eq(a.quantity,f.quantity)&&eq(a.sourceExclusions,f.sourceExclusions),'protected_source_effect');}
 const originalFacts=new Set(e.after.catalog.map(f=>f.id)),beforeFacts=new Map(e.before.catalog.map(f=>[f.id,f]));
 const expectedIds=[...e.before.catalog.map(f=>f.id),...current.catalog.filter(f=>!originalFacts.has(f.id)).map(f=>f.id)].sort();
 check(eq(restoredCatalog.map(f=>f.id).sort(),expectedIds),'source_restore_identity');
 for(const f of current.catalog.filter(f=>!originalFacts.has(f.id)))check(eq(restoredCatalog.find(x=>x.id===f.id)??null,f),'unrelated_source_effect');
 for(const f of restoredCatalog){
  if(belongs(f,e.component))continue;
  check(eq(current.catalog.find(x=>x.id===f.id)??null,f),'unrelated_source_effect');
 }
 for(const f of e.before.catalog){const restored=restoredCatalog.find(x=>x.id===f.id);check(restored,'source_restore_missing');
  // Related meal revision changes after compensation are legitimate; actual
  // quantities/source/protection come from the separately derived current meal.
  if(!belongs(f,e.component))check(eq(restored,f),'source_revision_or_privacy');
 }
 check(!restoredCatalog.some(f=>originalFacts.has(f.id)&&!beforeFacts.has(f.id)&&belongs(f,e.component)),'source_not_reversed');
 const b=e.before,a=e.after,sources=new Set(a.graph.contributions.map(x=>x.id)),lineIds=new Set(a.graph.lines.map(x=>x.id)),edges=new Set(a.graph.edges.map(x=>x.id));
 for(const key of ['lines','contributions','edges'] as const)for(const row of a.graph[key])check(eq(current.graph[key].find(x=>x.id===row.id)??null,row),'touched_conflict');
 check(current.graph.edges.every(x=>edges.has(x.id)||(!sources.has(x.demandId)&&!sources.has(x.supplyId))),'dependency_conflict');
 check(current.graph.contributions.every(x=>sources.has(x.id)||x.removedAt!==null||!lineIds.has(x.lineId)),'line_dependency_conflict');
 for(const p of a.packReviews)check(eq(current.packReviews.find(x=>x.lineId===p.lineId)??null,p),'pack_review_conflict');
 for(const binding of a.bindings)check(eq(current.bindings.find(x=>x.factId===binding.factId)??null,binding),'partition_conflict');
 const money=deriveFoodUndoBasket({lines:lines(b),quote:e.beforeQuote},{lines:lines(a),quote:e.afterQuote},
  {lines:lines(current),quote:quoteSchema.parse(currentQuote)},now);
 const next=structuredClone(current),transferBySource=new Map(a.bindings.map(x=>[x.contributionId,x.factId]));
 next.catalog=structuredClone([...restoredCatalog]);next.basket=basket(money.lines);next.quoteDigest=storedDigest(money.quote);
 next.bindings=next.bindings.filter(x=>!sources.has(x.contributionId));next.graph.edges=next.graph.edges.filter(x=>!edges.has(x.id));
 const newlyUnbound=new Map<string,TrackingState['unbound'][number]>();
 next.graph.contributions=next.graph.contributions.flatMap(row=>{
  if(!sources.has(row.id))return[row];
  const factId=transferBySource.get(row.id),f=factId?next.catalog.find(f=>f.id===factId):undefined;
  if(f&&beforeFacts.has(f.id)){
   // An exact unchanged authoritative source transfers rather than retires.
   const old=a.catalog.find(x=>x.id===f.id)!;
   const exact=eq(coreFact(f),coreFact(old));
   if(row.source.kind==='reservation')check(exact,'protected_source_effect');
   newlyUnbound.set(f.id,{factId:f.id,transferred:exact?structuredClone(row):null});
   if(exact)return[];
  }
  check(row.source.kind!=='reservation','protected_source_effect');return[{...row,removedAt:c.at}];
 });
 for(const f of e.before.catalog)if(!newlyUnbound.has(f.id))newlyUnbound.set(f.id,{factId:f.id,transferred:null});
 next.unbound.push(...newlyUnbound.values());
 next.graph.lines=next.graph.lines.map(l=>lineIds.has(l.id)?{...l,trashedAt:c.at}:l);
 next.packReviews=next.packReviews.filter(p=>!lineIds.has(p.lineId));
 next.legacyLineIds=next.basket.filter(l=>!next.graph.lines.some(g=>g.id===l.id&&g.trashedAt===null)).map(l=>l.id);
 next.graph.revision++;validateDemandGraph(next.graph);validateState(next,next.catalog);
 const delta=<T extends {id:string}>(before:T[],after:T[])=>[...new Set([...before,...after].map(x=>x.id))].flatMap(id=>{
  const b=before.find(x=>x.id===id)??null,a=after.find(x=>x.id===id)??null;return eq(b,a)?[]:[{id,before:b,after:a}];});
 const receipt=sharedDemandReceiptSchema.parse({schemaVersion:1,operationId:c.operationId,householdId:c.householdId,shopId:c.shopId,
  baseRevision:current.graph.revision,resultRevision:next.graph.revision,lines:delta(current.graph.lines,next.graph.lines),
  contributions:delta(current.graph.contributions,next.graph.contributions),edges:delta(current.graph.edges,next.graph.edges)});
 const disclosure={component:e.component,reversedAssertions:{lines:a.graph.lines,contributions:a.graph.contributions,edges:a.graph.edges,packReviews:a.packReviews},
  touchedBasket:money.touched,quote:{before:currentQuote,after:money.quote},beforeCoverage:coverage(current,current.catalog),afterCoverage:coverage(next,next.catalog)};
 return freeze({state:next,quote:money.quote,receipt,disclosure,evidenceDigest:digest(e)});
}
