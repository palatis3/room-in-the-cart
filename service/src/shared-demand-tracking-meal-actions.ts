/** Partition-aware meal review. These functions receive server-derived catalogs;
 * public callers never provide authoritative facts or replay evidence. */
import {z} from 'zod';
import {demandContributionSchema,type DemandContribution,type DemandGraph} from './shared-demand-contracts.js';
import {validateDetachedDemandChanges,validateDemandGraph} from './shared-demand-domain.js';
import {actionDemandSources} from './shared-demand-action-sources.js';
import {mealSourceKey,type LegacyDemandSource} from './shared-demand-sources.js';
import {validateState,coverage,digest,PartitionError,factSchema,type Fact,type TrackingState} from './shared-demand-tracking.js';
const id=factSchema.shape.id;
export const transferredChangesSchema=z.array(z.object({factId:id,after:demandContributionSchema.nullable()}).strict()).max(2000);
export type TransferredChange=z.infer<typeof transferredChangesSchema>[number];
function check(v:unknown,code:string):asserts v{if(!v)throw new PartitionError(code);}
const eq=(a:unknown,b:unknown)=>digest(a)===digest(b);
const mealSource=(s:DemandContribution['source'])=>s.kind==='meal'||s.kind==='reservation';
const occurrence=(s:DemandContribution['source'])=>s.kind==='meal'?s.occurrenceId:s.kind==='reservation'?s.originOccurrenceId:null;
/** Informational partitions retain detached rows as detached; their old line is
 * never presented as proof of a current allocation. */
export function partitionMealActionSources(state:TrackingState,meals:{occurrenceId:string;meal:unknown}[],descriptors:(LegacyDemandSource&{revision:number})[]){
 validateState(state,state.catalog);const detached=state.unbound.flatMap(u=>u.transferred?[u.transferred]:[]);
 const combined={...state.graph,contributions:[...state.graph.contributions,...detached]};
 const result=actionDemandSources(state.graph.shopId,meals,combined);
 const sources=result.sources.map(row=>{
  const fact=descriptors.find(f=>mealSource(f.source)&&mealSourceKey(f.source)===mealSourceKey(row.proposed.source));check(fact,'tracking_source_catalog_mismatch');
  const transfer=row.before&&state.unbound.find(u=>u.transferred?.id===row.before!.id),binding=row.before&&state.bindings.find(b=>b.contributionId===row.before!.id);
  const existing=state.catalog.find(f=>f.id===fact.id);
  const proposed=row.before?row.proposed:{...row.proposed,id:fact.id,source:fact.source,originalText:fact.originalText,originalQuantityText:fact.originalQuantityText,quantity:fact.quantity,sourceExclusions:fact.sourceExclusions,requiredLineId:fact.requiredLineId};
  check(row.before||!state.graph.usedIds.includes(proposed.id),'tracking_source_identity_reused');
  return{...row,proposed,factId:fact.id,revision:fact.revision,location:transfer?'transferred' as const:binding?'tracked' as const:existing?'unbound' as const:'new' as const};
 });
 const activeFacts=new Set(descriptors.filter(f=>mealSource(f.source)).map(f=>f.id));
 return{sources,retirementCandidates:result.retirementCandidates.filter(id=>state.graph.contributions.some(c=>c.id===id)),
  transferredRetirementCandidates:state.unbound.filter(u=>u.transferred&&result.retirementCandidates.includes(u.transferred.id)).map(u=>({factId:u.factId,contributionId:u.transferred!.id})),
  retiredUnboundFactIds:state.unbound.filter(u=>!u.transferred&&mealSource(state.catalog.find(f=>f.id===u.factId)!.source)&&!activeFacts.has(u.factId)).map(u=>u.factId),
  retainedContributionIds:result.retainedContributionIds.filter(id=>state.graph.contributions.some(c=>c.id===id)),
  proposedCatalog:descriptors.map(({productName:_,...fact})=>fact),beforeCoverage:coverage(state,state.catalog)};
}
/** Explicit same-ID changes only. An explicit retirement is retained by immutable before/after tracking
 * snapshots and usedIds; unchanged transfers remain byte-identical and unallocatable. */
export function applyTransferredMealChanges(before:TrackingState,graph:DemandGraph,catalog:Fact[],raw:unknown,
 edit:{occurrenceId:string},quantifyIds:string[],clarifyIds:string[],at:string){
 const changes=transferredChangesSchema.parse(raw??[]);check(new Set(changes.map(x=>x.factId)).size===changes.length,'tracking_duplicate_transfer_change');
 const next=structuredClone(before),updated=new Map<string,DemandContribution|null>();const oldRows:DemandContribution[]=[],newRows:DemandContribution[]=[];
 for(const change of changes){const u=before.unbound.find(u=>u.factId===change.factId),old=u?.transferred;check(old&&mealSource(old.source)&&occurrence(old.source)===edit.occurrenceId,'tracking_transfer_change_scope');
  check(!graph.contributions.some(c=>c.id===old.id)&&!graph.edges.some(e=>e.demandId===old.id||e.supplyId===old.id)&&graph.usedIds.includes(old.id),'tracking_transfer_identity');
  const fact=catalog.find(f=>f.id===change.factId);
  let after=change.after;
  if(after===null){check(!fact&&old.source.kind!=='reservation','tracking_transfer_retirement');after={...structuredClone(old),removedAt:at};}
  else check(fact&&after.id===old.id&&after.lineId===old.lineId&&after.removedAt===null,'tracking_transfer_identity');
  check(!eq(old,after),'tracking_transfer_no_change');oldRows.push(old);newRows.push(after);updated.set(change.factId,change.after===null?null:after);
 }
 validateDetachedDemandChanges(oldRows,newRows,quantifyIds,clarifyIds);
 next.graph=structuredClone(graph);
 next.graph=validateDemandGraph(next.graph);
 next.unbound=next.unbound.flatMap(u=>updated.has(u.factId)?updated.get(u.factId)===null?[]:[{factId:u.factId,transferred:updated.get(u.factId)!}]:[u]);
 // Source disappearance or modified authoritative quantity cannot silently
 // discard/update a transferred row merely by omitting an intent entry.
 for(const u of next.unbound.filter(u=>u.transferred))check(catalog.some(f=>f.id===u.factId),'tracking_transfer_change_required');
 return{graph:next.graph,unbound:next.unbound,changes:changes.map(c=>({factId:c.factId,before:before.unbound.find(u=>u.factId===c.factId)!.transferred,after:updated.get(c.factId)??null}))};
}
/** Retained fact identity is authoritative within its original meal lineage.
 * Binding resolution is the one existing protected unknown→known transition;
 * no arbitrary new source identity is adopted by matching a display label. */
export function retainMealFactIdentity(descriptors:(LegacyDemandSource&{revision:number})[],prior:readonly Fact[]){
 const lineage=(s:DemandContribution['source'])=>s.kind==='meal'?['meal',s.occurrenceId,s.ingredientId,s.groupId]:s.kind==='reservation'?['reservation',s.originOccurrenceId,s.ingredientId,s.groupId]:null;
 return descriptors.map(d=>{
  if(!mealSource(d.source))return d;
  const matches=prior.filter(f=>eq(lineage(f.source),lineage(d.source)));check(matches.length<=1,'tracking_source_ambiguous');const old=matches[0];if(!old)return d;
  if(old.source.kind==='meal'&&d.source.kind==='meal'){check(eq(old.source,d.source),'tracking_source_rebinding_required');return{...d,id:old.id,originalText:old.originalText};}
  check(old.source.kind==='reservation'&&d.source.kind==='reservation','tracking_source_identity');
  const sameBinding=old.source.bindingId===d.source.bindingId;
  check(sameBinding||(old.source.bindingId===null&&old.quantity===null&&d.source.bindingId!==null&&d.quantity!==null),'tracking_source_rebinding_required');
  return{...d,id:old.id,originalText:old.originalText,source:{...old.source,bindingId:d.source.bindingId}};
 });
}
