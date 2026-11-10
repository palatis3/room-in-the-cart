/** Pure tracking-state contract. Callers must load authority/evidence from trusted
 * storage. Nothing here authorizes a client, writes a row, or accepts a preview. */
import {createHash} from 'node:crypto';
import {z} from 'zod';
import {sharedDemandGraphSchema,demandContributionSchema,demandQuantitySchema,sourceExclusionSchema} from './shared-demand-contracts.js';
import {validateDemandGraph,demandLineTotals,convertDemandQuantity} from './shared-demand-domain.js';
const id=z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
const hash=z.string().regex(/^[a-f0-9]{64}$/), text=z.string().min(1).max(2048);
const rev=z.number().int().min(0).max(2147483647);
const source=demandContributionSchema.shape.source;
export const factSchema=z.object({id,revision:rev,source,sourceLabel:text,originalText:text,originalQuantityText:text.nullable(),quantity:demandQuantitySchema.nullable(),
 sourceExclusions:z.array(sourceExclusionSchema).max(40),requiredLineId:id.nullable()}).strict().refine(f=>f.source.kind!=='manual'&&f.source.kind!=='import','authoritative meal/request only');
const basketSchema=z.object({id,name:text,packs:z.number().int().min(1).max(10000),priceMinor:z.number().int().min(0).nullable(),feeEligible:z.boolean()}).strict();
export const trackingStateSchema=z.object({schemaVersion:z.literal(2),authorityEpoch:rev,privacyRevision:rev,
 quoteDigest:hash,graph:sharedDemandGraphSchema,basket:z.array(basketSchema).max(200),catalog:z.array(factSchema).max(2000),
 bindings:z.array(z.object({factId:id,contributionId:id}).strict()).max(2000),
 unbound:z.array(z.object({factId:id,transferred:demandContributionSchema.nullable()}).strict()).max(2000),
 legacyLineIds:z.array(id).max(200),packReviews:z.array(z.object({lineId:id,usablePerPack:demandQuantitySchema.nullable(),acceptUnresolved:z.boolean()}).strict()).max(200)}).strict();
export type TrackingState=z.infer<typeof trackingStateSchema>;
export type Fact=z.infer<typeof factSchema>;
export class PartitionError extends Error {constructor(readonly code:string){super(code);}}
function check(v:unknown,code:string):asserts v {if(!v)throw new PartitionError(code);}
function canonical(v:unknown):string {if(v===null||typeof v!=='object')return JSON.stringify(v);if(Array.isArray(v))return '['+v.map(canonical).join(',')+']';return '{'+Object.entries(v).sort(([a],[b])=>a<b?-1:a>b?1:0).map(([k,x])=>JSON.stringify(k)+':'+canonical(x)).join(',')+'}';}
export const digest=(v:unknown)=>createHash('sha256').update(canonical(v)).digest('hex');
const eq=(a:unknown,b:unknown)=>digest(a)===digest(b);
function unique(values:string[],code:string){check(new Set(values).size===values.length,code);}
const active=(r:z.infer<typeof demandContributionSchema>)=>r.removedAt===null;
function labels(rows:z.infer<typeof sourceExclusionSchema>[]){return rows.map(({occurrenceId,ingredientId,label})=>({occurrenceId,ingredientId,label}));}
function matchesFact(row:z.infer<typeof demandContributionSchema>,fact:Fact){
 check(eq(row.source,fact.source)&&row.originalText===fact.originalText,'source_identity');
 if(fact.source.kind==='meal'||fact.source.kind==='reservation'){
  const core=(q:typeof fact.quantity)=>q===null?null:{amount:q.amount,unit:q.unit,originalLiteral:q.originalLiteral};
  check(eq(core(row.quantity),core(fact.quantity)),'authoritative_quantity');
  if(fact.quantity?.confirmedConversion)check(eq(row.quantity?.confirmedConversion,fact.quantity.confirmedConversion),'authoritative_conversion');
 }
 check(eq(labels(row.sourceExclusions??[]),labels(fact.sourceExclusions)),'source_restrictions');
 check(fact.requiredLineId===null||row.lineId===fact.requiredLineId,'required_line');
}
/** The trusted caller supplies CURRENT authorized facts; omission is not permission. */
export function validateState(input:unknown,currentCatalog:readonly Fact[]):TrackingState {
 const s=trackingStateSchema.parse(input);validateDemandGraph(s.graph);
 check(eq(s.catalog,currentCatalog),'source_revision_or_privacy');
 unique(s.catalog.map(f=>f.id),'duplicate_fact');unique(s.catalog.map(f=>{const x=f.source;return x.kind==='request'?'request/'+x.requestId:x.kind==='meal'?'meal/'+x.occurrenceId+'/'+x.ingredientId+'/'+x.groupId:x.kind==='reservation'?'reservation/'+x.reservationId:digest(x);}), 'duplicate_authoritative_source');
 for(const f of s.catalog){
  if(f.quantity)convertDemandQuantity(f.quantity,f.quantity.unit);
  if(f.requiredLineId!==null)check(s.basket.some(l=>l.id===f.requiredLineId),'required_line_missing');
  for(const x of f.sourceExclusions){
   const occurrence=f.source.kind==='meal'?f.source.occurrenceId:f.source.kind==='reservation'?f.source.originOccurrenceId:null;
   const ingredient=f.source.kind==='meal'||f.source.kind==='reservation'?f.source.ingredientId:null;
   check(occurrence!==null&&x.occurrenceId===occurrence&&(x.ingredientId===null||x.ingredientId===ingredient),'restriction_origin');
  }
 }unique(s.basket.map(l=>l.id),'duplicate_basket');
 unique(s.bindings.map(b=>b.contributionId),'duplicate_binding');
 unique([...s.bindings.map(b=>b.factId),...s.unbound.map(b=>b.factId)],'duplicate_partition');
 check(eq([...s.catalog.map(f=>f.id)].sort(),[...s.bindings.map(b=>b.factId),...s.unbound.map(b=>b.factId)].sort()),'partition_missing');
 unique(s.legacyLineIds,'duplicate_legacy_line');
 const live=s.graph.contributions.filter(active), bound=new Set(s.bindings.map(b=>b.contributionId));
 for(const b of s.bindings){const row=live.find(r=>r.id===b.contributionId),fact=s.catalog.find(f=>f.id===b.factId);check(row&&fact,'binding_missing');matchesFact(row,fact);}
 for(const r of live)if(r.source.kind!=='manual'&&r.source.kind!=='import')check(bound.has(r.id),'unproven_source');
 const detached=s.unbound.flatMap(u=>u.transferred?[u.transferred]:[]);unique(detached.map(r=>r.id),'duplicate_transfer');
 for(const u of s.unbound)if(u.transferred){const fact=s.catalog.find(f=>f.id===u.factId)!;
  check(active(u.transferred)&&!s.graph.contributions.some(r=>r.id===u.transferred!.id),'transfer_not_retirement');
  check(s.graph.usedIds.includes(u.transferred.id),'transfer_identity_lost');matchesFact(u.transferred,fact);
  check(!s.graph.edges.some(e=>e.demandId===u.transferred!.id||e.supplyId===u.transferred!.id),'transfer_allocation');
 }
 const tracked=s.graph.lines.filter(l=>l.trashedAt===null);
 check(tracked.every(l=>live.some(c=>c.lineId===l.id)),'empty_tracked_line');
 unique([...tracked.map(l=>l.id),...s.legacyLineIds],'duplicate_line_partition');
 check(eq([...s.basket.map(l=>l.id)].sort(),[...tracked.map(l=>l.id),...s.legacyLineIds].sort()),'basket_partition');
 unique(s.packReviews.map(p=>p.lineId),'duplicate_pack_review');
 check(eq(s.packReviews.map(p=>p.lineId).sort(),tracked.map(l=>l.id).sort()),'pack_review_partition');
 for(const p of s.packReviews)if(p.usablePerPack)convertDemandQuantity(p.usablePerPack,p.usablePerPack.unit);
 for(const l of tracked)check(s.basket.some(b=>b.id===l.id&&b.name===l.name),'basket_identity');
 return s;
}
/** No complete total/free-supply claim is produced for a partial state, even when
 * each displayed tracked subtotal is numeric. No acceptUnknown bypass exists. */
export function coverage(input:unknown,currentCatalog:readonly Fact[]){const s=validateState(input,currentCatalog);
 const partial=s.unbound.length>0||s.legacyLineIds.length>0;
 const totals=demandLineTotals(s.graph);
 return {status:partial?'partial' as const:totals.some(t=>t.quantity===null)?'unknown' as const:'tracked' as const,
  trackedSubtotals:totals,completeFoodCoverage:false as const,
  unboundFactIds:s.unbound.map(u=>u.factId),untrackedBasketIds:s.legacyLineIds,
  protectedUnboundFactIds:s.unbound.filter(u=>s.catalog.find(f=>f.id===u.factId)!.source.kind==='reservation').map(u=>u.factId),
  allocatableUnboundFactIds:[] as string[]};
}
export function admitV1(input:unknown,currentCatalog:readonly Fact[]){const s=validateState(input,currentCatalog);
 check(s.unbound.length===0&&s.legacyLineIds.length===0,'client_requires_partition_support');return s.graph;}
const evidenceSchema=z.object({version:z.literal(1),operationId:id,before:trackingStateSchema,after:trackingStateSchema}).strict();
export type AdoptionEvidence=z.infer<typeof evidenceSchema>;
function frozen<T>(v:T):T {if(v&&typeof v==='object'){Object.freeze(v);for(const x of Object.values(v))frozen(x);}return v;}
/** Fixture/repository-side constructor, NOT an API accepting client history. */
export function recordFirstAdoption(operationId:string,before:unknown,after:unknown){
 const e=evidenceSchema.parse({version:1,operationId,before,after});validateEvidence(e);
 return frozen({evidence:e,evidenceDigest:digest(e)});
}
function validateEvidence(e:AdoptionEvidence){
 const b=validateState(e.before,e.before.catalog),a=validateState(e.after,e.after.catalog);
 check(b.graph.revision===0&&a.graph.revision===1&&b.graph.lines.length===0&&b.graph.contributions.length===0&&b.graph.edges.length===0&&b.graph.usedIds.length===0,'not_first_adoption');
 check(b.bindings.length===0&&b.unbound.every(u=>u.transferred===null),'invalid_legacy_baseline');
 check(a.unbound.length===0&&a.legacyLineIds.length===0,'incomplete_first_adoption');
 check(b.graph.householdId===a.graph.householdId&&b.graph.shopId===a.graph.shopId,'wrong_scope');
 check(eq(b.catalog,a.catalog)&&b.authorityEpoch===a.authorityEpoch&&b.privacyRevision===a.privacyRevision,'source_revision_or_privacy');
 check(b.quoteDigest===a.quoteDigest,'quote_change_outside_boundary');
 // Existing legacy basket facts cannot be dropped during tracking. The current
 // first-tracking route allows quantities/packs and new rows, not old-row deletion.
 check(b.basket.every(l=>a.basket.some(r=>r.id===l.id)),'legacy_basket_removed');
}
export const inverseContextSchema=z.object({operationId:id,targetOperationId:id,evidenceDigest:hash,
 householdId:id,shopId:id,baseRevision:rev,authorityEpoch:rev,privacyRevision:rev,
 at:z.iso.datetime({offset:true}),currentCatalog:z.array(factSchema).max(2000)}).strict();
/** Complete first-tracking+manual inverse. Restores tracking representation,
 * not authority, and never treats supplied context as an authorization token. */
export function inverseFirstAdoption(input:unknown,currentInput:unknown,contextInput:unknown){
 const c=inverseContextSchema.parse(contextInput),e=evidenceSchema.parse(input);
 check(c.targetOperationId===e.operationId&&c.operationId!==e.operationId&&c.evidenceDigest===digest(e),'history_unavailable');validateEvidence(e);
 const current=validateState(currentInput,c.currentCatalog),b=e.before,a=e.after;
 check(current.graph.householdId===c.householdId&&current.graph.shopId===c.shopId&&a.graph.householdId===c.householdId&&a.graph.shopId===c.shopId,'wrong_scope');
 check(c.baseRevision===current.graph.revision&&c.baseRevision>=a.graph.revision&&c.baseRevision<2147483647,'stale_revision');
 check(c.authorityEpoch===current.authorityEpoch&&c.authorityEpoch===a.authorityEpoch&&c.privacyRevision===current.privacyRevision&&c.privacyRevision===a.privacyRevision,'source_revision_or_privacy');
 for(const f of a.catalog)check(eq(c.currentCatalog.find(x=>x.id===f.id)??null,f),'source_revision_or_privacy');
 check(current.quoteDigest===a.quoteDigest,'quote_conflict');
 const targetSource=new Set(a.graph.contributions.map(r=>r.id)),targetLines=new Set(a.graph.lines.map(r=>r.id)),targetEdges=new Set(a.graph.edges.map(r=>r.id));
 for(const key of ['lines','contributions','edges'] as const)for(const r of a.graph[key])check(eq(current.graph[key].find(x=>x.id===r.id)??null,r),'touched_conflict');
 check(current.graph.edges.every(r=>targetEdges.has(r.id)||(!targetSource.has(r.demandId)&&!targetSource.has(r.supplyId))),'dependency_conflict');
 check(current.graph.contributions.every(r=>targetSource.has(r.id)||!active(r)||!targetLines.has(r.lineId)),'line_dependency_conflict');
 for(const p of a.packReviews)check(eq(current.packReviews.find(x=>x.lineId===p.lineId)??null,p),'pack_review_conflict');
 for(const binding of a.bindings)check(eq(current.bindings.find(x=>x.factId===binding.factId)??null,binding),'partition_conflict');
 const next=structuredClone(current);
 const beforeBasket=new Map(b.basket.map(l=>[l.id,l]));
 for(const row of a.basket){const old=beforeBasket.get(row.id)??null;if(eq(old,row))continue;
  const index=next.basket.findIndex(l=>l.id===row.id),found=next.basket[index];
  if(!old){
   // Removing a target-added row changes membership, so all its facts must match.
   check(eq(found??null,row),'basket_conflict');next.basket.splice(index,1);continue;
  }
  check(found,'basket_conflict');
  // Restore only fields changed by this operation. Later untouched fields keep
  // their current value, as in the existing complete-operation Undo reducer.
  for(const key of ['name','packs','priceMinor','feeEligible'] as const){
   if(eq(old[key],row[key]))continue;
   check(eq(found[key],row[key]),'basket_conflict');Object.assign(found,{[key]:old[key]});
  }
 }
 // Every initial graph assignment is disclosed/reversed. Authoritative sources
 // move intact into an unbound slot; they are NOT retired or made free supply.
 const transfers=new Map(a.bindings.map(x=>[x.contributionId,x.factId]));
 next.graph.contributions=next.graph.contributions.flatMap(row=>{
  if(!targetSource.has(row.id))return [row];
  const factId=transfers.get(row.id);
  if(factId){next.unbound.push({factId,transferred:structuredClone(row)});return [];}
  return [{...row,removedAt:c.at}];
 });
 next.packReviews=next.packReviews.filter(p=>!targetLines.has(p.lineId));
 next.bindings=next.bindings.filter(x=>!transfers.has(x.contributionId));
 next.graph.edges=next.graph.edges.filter(r=>!targetEdges.has(r.id));
 next.graph.lines=next.graph.lines.map(l=>targetLines.has(l.id)?{...l,trashedAt:c.at}:l);
 next.legacyLineIds=[...next.legacyLineIds,...b.legacyLineIds];
 next.graph.revision=current.graph.revision+1; // usedIds stays an exact superset, never reset/reused.
 validateState(next,c.currentCatalog);
 const disclosure={targetOperationId:e.operationId,
  reversedAssertions:{lines:structuredClone(a.graph.lines),contributions:structuredClone(a.graph.contributions),edges:structuredClone(a.graph.edges),packReviews:structuredClone(a.packReviews)},
  basketChanges:a.basket.filter(l=>!eq(beforeBasket.get(l.id)??null,l)).map(l=>({id:l.id,before:beforeBasket.get(l.id)??null,after:l})),
  transferredFactIds:[...transfers.values()],retainedLaterContributionIds:next.graph.contributions.filter(r=>active(r)&&!targetSource.has(r.id)).map(r=>r.id),
  beforeCoverage:coverage(current,c.currentCatalog),afterCoverage:coverage(next,c.currentCatalog)};
 return frozen({state:next,disclosure,receipt:{operationId:c.operationId,reversesOperationId:e.operationId,baseRevision:current.graph.revision,resultRevision:next.graph.revision,
  beforeDigest:digest(current),afterDigest:digest(next),evidenceDigest:c.evidenceDigest,disclosureDigest:digest(disclosure)}});
}
