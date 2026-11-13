/** Request compensation across a recorded tracking partition. All history and
 * mapping inputs are loaded by the repository, never accepted from an API body.
 * Uses the existing food reducer; this module owns no quantity arithmetic. */
import {z} from 'zod';
import {digest as storedDigest} from './database.js';
import {checkout} from './checkout.js';
import {ServiceError} from './errors.js';
import {trackingStateSchema,validateState,coverage,digest,type TrackingState} from './shared-demand-tracking.js';
import {validateDemandGraph,applyDemandChange,undoDemandChange,demandLineTotals} from './shared-demand-domain.js';
import {sharedDemandReceiptSchema,type DemandGraph} from './shared-demand-contracts.js';
import {prepareRequestAcceptanceUndo,validateRequestAcceptanceHistory,validateRequestAcceptanceCoreHistory,validateRequestAcceptanceGraphReceipt,requestAcceptanceComponentDigest} from './shared-request-acceptance-undo.js';
import {requestUndoCandidateSchema,requestUndoID,requestUndoSnapshotSchema} from './shared-request-undo-contracts.js';
import {validateCompoundAdoptionEvidence,inverseCompoundAdoptionPartition} from './shared-demand-compound-adoption.js';
const hash=z.string().regex(/^[0-9a-f]{64}$/),revision=z.number().int().min(1).max(2147483647);
export const requestTrackingMappingSchema=z.object({operationId:requestUndoID,shopRevision:revision,authorityEpoch:revision,
 state:trackingStateSchema,stateDigest:hash,snapshotOperationId:requestUndoID,snapshot:requestUndoSnapshotSchema,snapshotDigest:hash}).strict();
export type RequestTrackingMapping=z.infer<typeof requestTrackingMappingSchema>;
const same=(a:unknown,b:unknown)=>digest(a)===digest(b);
function check(v:unknown,code:string):asserts v{if(!v)throw new ServiceError(409,'request_undo_'+code,'Review the complete request and food change.');}
const basket=(lines:{lineId:string;originalItem:string;packs:number;unitPriceMinor:number|null;feeEligible:boolean}[])=>
 lines.map(l=>({id:l.lineId,name:l.originalItem,packs:l.packs,priceMinor:l.unitPriceMinor,feeEligible:l.feeEligible})).sort((a,b)=>a.id.localeCompare(b.id));
const active=(g:DemandGraph)=>g.contributions.filter(c=>c.removedAt===null);
function receipt(before:DemandGraph,after:DemandGraph,operationId:string){
 const diff=<T extends {id:string}>(a:T[],b:T[])=>[...new Set([...a,...b].map(x=>x.id))].flatMap(id=>{
  const before=a.find(x=>x.id===id)??null,after=b.find(x=>x.id===id)??null;return same(before,after)?[]:[{id,before,after}];});
 return sharedDemandReceiptSchema.parse({schemaVersion:1,operationId,householdId:before.householdId,shopId:before.shopId,
  baseRevision:before.revision,resultRevision:after.revision,lines:diff(before.lines,after.lines),
  contributions:diff(before.contributions,after.contributions),edges:diff(before.edges,after.edges)});
}
/** Partial original acceptance is authenticated by actual stored partition rows,
 * not by the mere presence of a tracking marker. The null-before case is only
 * the first V2 write from an already complete V1 graph. */
export function validatePartitionedRequestAcceptanceHistory(raw:unknown){
 const e=validateRequestAcceptanceCoreHistory(raw),c=e.record.certificate;
 if(e.food.kind!=='tracked'||!e.food.partition)return validateRequestAcceptanceHistory(raw);
 validateRequestAcceptanceGraphReceipt(raw);
 const {before,after}=e.food.partition;
 const verify=(state:TrackingState,graph:DemandGraph,snapshot:typeof e.beforeSnapshot.value)=>{
  validateState(state,state.catalog);
  check(state.graph.householdId===c.householdId&&state.graph.shopId===c.shopId&&state.authorityEpoch===c.authorityEpoch&&
   same(state.graph,graph)&&same(state.basket,basket(snapshot.lines))&&state.quoteDigest===storedDigest(snapshot.quote)&&
   same(snapshot.tracking,{schemaVersion:2,shopRevision:snapshot.revision,digest:digest(state),status:'recorded'}),'partition_history_unavailable');
 };
 verify(after,e.food.after,e.afterSnapshot.value);
 if(before){verify(before,e.food.before,e.beforeSnapshot.value);check(before.privacyRevision===after.privacyRevision,'partition_history_unavailable');}
 else{
  check(e.beforeSnapshot.value.tracking===undefined,'partition_history_unavailable');
  const totals=demandLineTotals(e.food.before),ls=e.beforeSnapshot.value.lines;
  check(totals.length===ls.length&&ls.every(l=>totals.some(t=>t.lineId===l.lineId)&&
   e.food.kind==='tracked'&&e.food.before.lines.some(g=>g.id===l.lineId&&g.name===l.originalItem)),'partition_history_unavailable');
 }
 const own=after.catalog.filter(f=>f.source.kind==='request'&&f.source.requestId===c.requestId);
 check(own.length===1,'request_source_mismatch');const fact=own[0]!;
 check(fact.source.kind==='request'&&fact.source.appliedRequestRevision===c.afterLink.reviewedRevision&&fact.revision===c.afterLink.reviewedRevision&&
  fact.requiredLineId===c.afterLink.lineId,'request_source_mismatch');
 const sorted=(xs:typeof after.catalog)=>[...xs].sort((a,b)=>a.id.localeCompare(b.id));
 if(before){check(!before.catalog.some(f=>f.source.kind==='request'&&f.source.requestId===c.requestId)&&
  same(sorted(before.catalog),sorted(after.catalog.filter(f=>f.id!==fact.id))),'unrelated_source_effect');}
 else{
  // Complete V1 before-state: every nonmanual source must correspond exactly to
  // an unchanged after fact. This projection validates coverage; it is not saved
  // or represented as an invented historical tracking row.
  const priorFacts=after.catalog.filter(f=>f.id!==fact.id),g=e.food.before;
  validateState({...after,graph:g,basket:basket(e.beforeSnapshot.value.lines),quoteDigest:storedDigest(e.beforeSnapshot.value.quote),catalog:priorFacts,
   bindings:priorFacts.map(f=>{const matches=g.contributions.filter(r=>r.removedAt===null&&same(r.source,f.source));
    check(matches.length===1,'partition_history_unavailable');return{factId:f.id,contributionId:matches[0]!.id};}),
   unbound:[],legacyLineIds:[],packReviews:g.lines.filter(l=>l.trashedAt===null).map(l=>({lineId:l.id,usablePerPack:null,acceptUnresolved:true}))},priorFacts);
 }
 return e;
}
/** Complete compound request history binds the separate actual request
 * transition to the immutable first-adoption envelope without a digest cycle. */
export function validateCompoundRequestAcceptanceHistory(raw:unknown,compoundRaw:unknown){
 const e=validateRequestAcceptanceCoreHistory(raw),c=e.record.certificate,t=validateCompoundAdoptionEvidence(compoundRaw);
 check(e.food.kind==='compoundAdoption'&&c.food.kind==='compoundAdoption','complete_adoption_required');
 check(t.operationId===c.operationId&&t.component.kind==='requestAcceptance'&&t.component.requestId===c.requestId&&
  t.component.componentDigest===requestAcceptanceComponentDigest(c)&&c.food.compositionDigest===digest(t)&&
  e.food.compositionDigest===digest(t),'compound_history_unavailable');
 check(t.before.graph.householdId===c.householdId&&t.before.graph.shopId===c.shopId&&t.before.authorityEpoch===c.authorityEpoch&&
  same(t.after.graph,e.food.after)&&c.food.afterDigest===storedDigest(e.food.after)&&c.food.receiptDigest===storedDigest(e.food.receipt)&&
  same(e.food.receipt,receipt(t.before.graph,t.after.graph,c.operationId)),'compound_history_unavailable');
 check(e.beforeSnapshot.value.demand===undefined&&e.beforeSnapshot.value.tracking===undefined&&
  same(basket(e.beforeSnapshot.value.lines),t.before.basket)&&same(e.beforeSnapshot.value.quote,t.beforeQuote)&&
  same(basket(e.afterSnapshot.value.lines),t.after.basket)&&same(e.afterSnapshot.value.quote,t.afterQuote)&&
  same(e.afterSnapshot.value.demand,{schemaVersion:1,revision:1,digest:storedDigest(t.after.graph)})&&
  same(e.afterSnapshot.value.tracking,{schemaVersion:2,shopRevision:c.resultShopRevision,digest:digest(t.after),status:'recorded'}),'compound_history_unavailable');
 const facts=t.after.catalog.filter(f=>f.source.kind==='request'&&f.source.requestId===c.requestId);check(facts.length===1,'request_source_mismatch');
 const f=facts[0]!;check(f.source.kind==='request'&&f.source.appliedRequestRevision===c.afterLink.reviewedRevision&&
  f.revision===c.afterLink.reviewedRevision&&f.requiredLineId===c.afterLink.lineId,'request_source_mismatch');
 return e;
}
export function deriveCompoundRequestUndo(history:unknown,currentRaw:unknown,live:unknown,command:{operationId:string;at:string},now:Date,
 compoundRaw:unknown,alreadyReversed=false){
 const e=validateCompoundRequestAcceptanceHistory(history,compoundRaw),t=validateCompoundAdoptionEvidence(compoundRaw);
 const p=prepareRequestAcceptanceUndo(history,currentRaw,live,command,now,alreadyReversed),{c,current,content,links,restored}=p;
 check(current.food.kind==='partition','partition_required');const before=validateState(current.food.state,current.food.state.catalog);
 check(same(before.basket,basket(current.lines))&&before.quoteDigest===storedDigest(current.quote),'partition_conflict');
 const own=before.catalog.filter(f=>f.source.kind==='request'&&f.source.requestId===c.requestId);check(own.length===1,'request_source_mismatch');
 check(own[0]!.originalText===content.originalItem&&own[0]!.originalQuantityText===content.ownQuantity,'request_source_mismatch');
 const catalog=before.catalog.filter(f=>f.id!==own[0]!.id);
 const result=inverseCompoundAdoptionPartition(t,before,{...command,targetOperationId:c.operationId,evidenceDigest:digest(t),householdId:c.householdId,shopId:c.shopId,
  baseRevision:before.graph.revision,authorityEpoch:current.authorityEpoch,privacyRevision:before.privacyRevision},current.quote,catalog,now);
 check(same(result.state.basket,basket(p.basket.lines))&&same(result.quote,p.basket.quote),'compound_action_changed');
 const action={kind:'request.undoAcceptance' as const,body:{targetOperationId:c.operationId,requestId:c.requestId,baseRequestRevision:current.request.state.revision,
  lines:p.basket.lines,quote:p.basket.quote}};
 const base={shopRevision:current.shopRevision,authorityEpoch:current.authorityEpoch,requestRevision:current.request.state.revision,
  food:{kind:'partition' as const,graphRevision:before.graph.revision,graphDigest:storedDigest(before.graph),stateDigest:digest(before),privacyRevision:before.privacyRevision}};
 const requestUndo={requestId:c.requestId,choice:c.decision.choice,originalItem:content.originalItem,originalQuantityText:content.ownQuantity,targetBefore:c.before,targetAfter:c.after,current:current.request.state,
  restored,beforeLink:c.afterLink,afterLink:null,carry:c.carry};
 const scope={requestsChanged:true as const,mealsChanged:false as const,quoteChanged:false as const,firstAdoptionReversed:true as const,
  touchedLines:p.basket.touched,graphRows:result.receipt.lines.length+result.receipt.contributions.length+result.receipt.edges.length};
 const effectDigest=storedDigest({acceptance:e.record.digest,compositionDigest:digest(t),base,current,action,requestUndo,scope,storeBasis:p.live.storeBasis});
 const candidate=requestUndoCandidateSchema.parse({schemaVersion:1,kind:'requestAcceptanceUndo',shopId:c.shopId,targetOperationId:c.operationId,effectDigest,base,action,requestUndo,scope,
  foodBefore:{kind:'partition',state:before},foodAfter:{kind:'partition',state:result.state},beforeCheckout:checkout(current.lines,current.quote),
  afterCheckout:checkout(p.basket.lines,p.basket.quote),packReviewLineIds:p.basket.lines.map(x=>x.lineId),storeBasis:p.live.storeBasis});
 return{candidate,transition:{requestId:c.requestId,expected:current.request.state,restored,retireLink:c.afterLink,remainingLinks:links,mealRefs:structuredClone(current.mealRefs)},
  receipt:result.receipt,trackingState:result.state,targetAdoptionOperationId:c.operationId,trackingDisclosure:result.disclosure};
}
/** The mapping row and its snapshot authenticate the original accepted fact,
 * including its reviewed source revision. Current mutable status revision is
 * checked separately by prepareRequestAcceptanceUndo. */
function mappingFact(raw:unknown,p:ReturnType<typeof prepareRequestAcceptanceUndo>,current:TrackingState){
 const m=requestTrackingMappingSchema.parse(raw),s=validateState(m.state,m.state.catalog),c=p.c;
 check(m.stateDigest===digest(s)&&m.snapshotDigest===storedDigest(m.snapshot)&&m.snapshotOperationId===m.operationId&&
  same(m.snapshot.budget,checkout(m.snapshot.lines,m.snapshot.quote)),'mapping_unavailable');
 check(m.shopRevision>=c.resultShopRevision&&m.shopRevision<=p.current.shopRevision&&m.snapshot.shopId===c.shopId&&
  m.snapshot.revision===m.shopRevision&&same(m.snapshot.tracking,{schemaVersion:2,shopRevision:m.shopRevision,digest:m.stateDigest,status:'recorded'})&&
  same(m.snapshot.demand,{schemaVersion:1,revision:s.graph.revision,digest:storedDigest(s.graph)})&&
  same(basket(m.snapshot.lines),s.basket)&&storedDigest(m.snapshot.quote)===s.quoteDigest,'mapping_unavailable');
 check(s.graph.householdId===c.householdId&&s.graph.shopId===c.shopId&&s.authorityEpoch===m.authorityEpoch&&
  s.privacyRevision===current.privacyRevision&&s.graph.revision<=current.graph.revision,'mapping_unavailable');
 const facts=s.catalog.filter(f=>f.source.kind==='request'&&f.source.requestId===c.requestId);check(facts.length===1,'mapping_unavailable');
 const fact=facts[0]!;check(fact.source.kind==='request'&&fact.source.appliedRequestRevision===c.afterLink.reviewedRevision&&
  fact.revision===c.afterLink.reviewedRevision&&fact.requiredLineId===c.afterLink.lineId&&
  fact.originalText===p.content.originalItem&&fact.originalQuantityText===p.content.ownQuantity,'mapping_unavailable');
 check(same(current.catalog.find(f=>f.id===fact.id)??null,fact),'source_conflict');
 return {mapping:m,fact};
}
/** Original legacy acceptance has no food receipt to undo. Its recorded request
 * fact is removed from the current partition, preserving later independently
 * entered manual food and unrelated mappings. Original tracked acceptance uses
 * its COMPLETE receipt instead, including any coupled manual/relationship edits. */
export function derivePartitionedRequestUndo(history:unknown,currentRaw:unknown,live:unknown,command:{operationId:string;at:string},now:Date,
 mappingRaw:unknown,alreadyReversed=false){
 validatePartitionedRequestAcceptanceHistory(history); // Compound first-adoption has its own complete inverse.
 const p=prepareRequestAcceptanceUndo(history,currentRaw,live,command,now,alreadyReversed),{e,c,current,content,basket:money,links,restored}=p;
 check(current.food.kind==='partition','partition_required');
 const before=validateState(current.food.state,current.food.state.catalog);
 check(before.graph.householdId===c.householdId&&before.graph.shopId===c.shopId&&before.authorityEpoch===current.authorityEpoch&&
  same(before.basket,basket(current.lines))&&before.quoteDigest===storedDigest(current.quote),'partition_conflict');
 const {mapping,fact}=mappingFact(mappingRaw,p,before);
 // Every accepted request must remain a fact, whether bound or explicitly unbound.
 const requestFacts=before.catalog.filter(f=>f.source.kind==='request');
 check(requestFacts.length===current.links.length&&current.links.every(link=>requestFacts.some(f=>f.source.kind==='request'&&
  f.source.requestId===link.requestId&&f.source.appliedRequestRevision===link.reviewedRevision&&f.requiredLineId===link.lineId)), 'request_source_mismatch');
 const cmd={schemaVersion:1,operationId:command.operationId,householdId:c.householdId,shopId:c.shopId,baseRevision:before.graph.revision,
  at:command.at,lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[]};
 let graph:DemandGraph;
 if(e.food.kind==='tracked'){
  // Never reduce this to request-only removal: the accepted operation may also
  // have changed manual quantities, products, overlap or line fields.
  graph=undoDemandChange(before.graph,e.food.receipt,cmd).graph;
 }else{
  check(e.food.kind==='legacy','complete_adoption_required');
  const bound=before.bindings.find(x=>x.factId===fact.id),unbound=before.unbound.find(x=>x.factId===fact.id);
  if(bound){
   // A request is demand, not a substitute supply for other commitments. Any
   // unexpected dependent edge must be reviewed as a complete separate change.
   check(!before.graph.edges.some(x=>x.supplyId===bound.contributionId),'dependent_source');
   graph=applyDemandChange(before.graph,{...cmd,removeSourceIds:[bound.contributionId]}).graph;
  }else{
   check(unbound,'partition_conflict');graph=structuredClone(before.graph);check(graph.revision<2147483647,'stale_base');graph.revision++;
   if(unbound.transferred){
    check(unbound.transferred.source.kind==='request'&&!graph.contributions.some(x=>x.id===unbound.transferred!.id)&&
     graph.usedIds.includes(unbound.transferred.id),'partition_conflict');
    // Retire the exact former contribution; its ID is never freed/recreated.
    graph.contributions.push({...structuredClone(unbound.transferred),removedAt:command.at});
   }
   validateDemandGraph(graph);
  }
 }
 const catalog=before.catalog.filter(f=>f.id!==fact.id),liveRows=active(graph),tracked=graph.lines.filter(l=>l.trashedAt===null);
 check(!liveRows.some(r=>r.source.kind==='request'&&r.source.requestId===c.requestId),'request_source_mismatch');
 const resultBasket=basket(money.lines);
 check(tracked.every(l=>resultBasket.some(b=>b.id===l.id&&b.name===l.name))&&
  catalog.every(f=>f.requiredLineId===null||resultBasket.some(b=>b.id===f.requiredLineId)),'dependent_source');
 const next=validateState({...before,graph,catalog,basket:resultBasket,quoteDigest:storedDigest(money.quote),
  bindings:before.bindings.filter(b=>b.factId!==fact.id),unbound:before.unbound.filter(b=>b.factId!==fact.id),
  legacyLineIds:resultBasket.filter(b=>!tracked.some(l=>l.id===b.id)).map(b=>b.id),
  packReviews:before.packReviews.filter(p=>tracked.some(l=>l.id===p.lineId))},catalog);
 const foodReceipt=receipt(before.graph,next.graph,command.operationId);
 const action={kind:'request.undoAcceptance' as const,body:{targetOperationId:c.operationId,requestId:c.requestId,
  baseRequestRevision:current.request.state.revision,lines:money.lines,quote:money.quote}};
 const base={shopRevision:current.shopRevision,authorityEpoch:current.authorityEpoch,requestRevision:current.request.state.revision,
  food:{kind:'partition' as const,graphRevision:before.graph.revision,graphDigest:storedDigest(before.graph),stateDigest:digest(before),privacyRevision:before.privacyRevision}};
 const requestUndo={requestId:c.requestId,choice:c.decision.choice,originalItem:content.originalItem,originalQuantityText:content.ownQuantity,targetBefore:c.before,targetAfter:c.after,
  current:current.request.state,restored,beforeLink:c.afterLink,afterLink:null,carry:c.carry};
 const scope={requestsChanged:true as const,mealsChanged:false as const,quoteChanged:false as const,touchedLines:money.touched,
  graphRows:foodReceipt.lines.length+foodReceipt.contributions.length+foodReceipt.edges.length};
 const effectDigest=storedDigest({acceptance:e.record.digest,mapping:{operationId:mapping.operationId,shopRevision:mapping.shopRevision,
  stateDigest:mapping.stateDigest,snapshotDigest:mapping.snapshotDigest},base,current,action,requestUndo,scope,storeBasis:p.live.storeBasis});
 const candidate=requestUndoCandidateSchema.parse({schemaVersion:1,kind:'requestAcceptanceUndo',shopId:c.shopId,targetOperationId:c.operationId,effectDigest,
  base,action,requestUndo,scope,foodBefore:{kind:'partition',state:before},foodAfter:{kind:'partition',state:next},
  beforeCheckout:checkout(current.lines,current.quote),afterCheckout:checkout(money.lines,money.quote),packReviewLineIds:money.lines.map(l=>l.lineId),storeBasis:p.live.storeBasis});
 return{candidate,transition:{requestId:c.requestId,expected:current.request.state,restored,retireLink:c.afterLink,remainingLinks:links,mealRefs:structuredClone(current.mealRefs)},
  receipt:foodReceipt,trackingState:next,trackingCoverage:{before:coverage(before,before.catalog),after:coverage(next,catalog)}};
}
