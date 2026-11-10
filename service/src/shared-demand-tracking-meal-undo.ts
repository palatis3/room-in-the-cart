import {z} from 'zod';
/** Whole partial-meal inverse: immutable food/meal snapshots plus exact partition
 * changes. Nothing here accepts caller-supplied history or invents old authority. */
import type {Context,HouseholdRepository,Shop} from './repository.js';
import {foodUndoEvidence,actionFacts} from './shared-demand-repository.js';
import {deriveSharedFoodUndoCore,assertSharedFoodUndoReplay,type FoodUndoEvidence} from './shared-food-operation-undo.js';
import {validateState,admitV1,trackingStateSchema,digest,coverage,PartitionError,type TrackingState} from './shared-demand-tracking.js';
import {sharedDemandReceiptSchema} from './shared-demand-contracts.js';
import {validateDetachedDemandChanges} from './shared-demand-domain.js';
import {digest as storedDigest} from './database.js';
import {trackingCatalog} from './shared-demand-tracking-repository.js';
function check(v:unknown,code:string):asserts v{if(!v)throw new PartitionError(code);}
const eq=(a:unknown,b:unknown)=>digest(a)===digest(b);
const lines=(s:TrackingState)=>s.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible}));
const hash=z.string().regex(/^[a-f0-9]{64}$/),uuid=z.string().uuid(),revision=z.number().int().positive().max(2147483647);
const capturedBeforeSchema=z.object({proof:z.object({version:z.literal(1),operationId:uuid,householdId:uuid,shopId:uuid,baseShopRevision:revision,resultShopRevision:revision,beforeSnapshotDigest:hash,beforeStateDigest:hash,afterStateDigest:hash,beforeState:trackingStateSchema}).strict(),proofDigest:hash}).strict();
function stateMatchesSnapshot(state:TrackingState,snapshot:any,ctx:Context,shop:Shop){
 check(snapshot.shopId===shop.shop_id&&snapshot.phase==='draft'&&state.graph.householdId===ctx.householdId&&state.graph.shopId===shop.shop_id&&
  storedDigest(state.graph)===snapshot.demand?.digest&&state.graph.revision===snapshot.demand?.revision&&eq(lines(state),snapshot.lines)&&state.quoteDigest===storedDigest(snapshot.quote),'tracking_meal_partition_history');
}
/** Capture only while applying a NEW meal effect whose real base snapshot predates
 * 046. This never updates a prior snapshot or manufactures evidence during Undo. */
export async function captureTrackingMealBefore(ctx:Context,shop:Shop,operationId:string,before:TrackingState,after:TrackingState){
 const saved=(await ctx.db.query('SELECT snapshot,digest,operation_id FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,shop.revision])).rows[0];
 check(saved&&saved.digest===storedDigest(saved.snapshot)&&saved.snapshot.revision===shop.revision,'tracking_meal_partition_history');
 if(saved.snapshot.tracking!==undefined)return null;
 admitV1(before,before.catalog);validateState(after,after.catalog);stateMatchesSnapshot(before,saved.snapshot,ctx,shop);
 check(before.graph.revision>0&&after.graph.revision===before.graph.revision+1&&before.authorityEpoch===shop.authority_epoch&&after.authorityEpoch===shop.authority_epoch&&before.privacyRevision===after.privacyRevision,'tracking_meal_partition_history');
 const proof={version:1 as const,operationId,householdId:ctx.householdId,shopId:shop.shop_id,baseShopRevision:shop.revision,resultShopRevision:shop.revision+1,beforeSnapshotDigest:saved.digest,beforeStateDigest:digest(before),afterStateDigest:digest(after),beforeState:structuredClone(before)};
 return capturedBeforeSchema.parse({proof,proofDigest:digest(proof)});
}
export async function loadTrackingMealHistory(ctx:Context,shop:Shop,target:string){
 const evidence=await foodUndoEvidence(ctx,shop,target);check(evidence.effect?.classification==='meal_action'&&evidence.meal,'tracking_meal_history_required');assertSharedFoodUndoReplay(evidence);
 const beforeSnapshot=(evidence.before!.snapshot as any),afterSnapshot=(evidence.after!.snapshot as any);
 const read=async(snapshot:any)=>{const ref=snapshot.tracking;check(ref&&ref.status==='recorded'&&ref.shopRevision===snapshot.revision,'tracking_meal_partition_history');
  const row=(await ctx.db.query('SELECT state,state_digest,projection,operation_id,review FROM ritc.shared_tracking_revision WHERE household_id=$1 AND shop_id=$2 AND shop_revision=$3',[ctx.householdId,shop.shop_id,ref.shopRevision])).rows[0];
  check(row?.state&&!row.projection&&row.state_digest===digest(row.state)&&row.state_digest===ref.digest,'tracking_meal_partition_history');
  const state=validateState(row.state,row.state.catalog);stateMatchesSnapshot(state,snapshot,ctx,shop);return{row,state};};
 const after=await read(afterSnapshot);check(after.row.operation_id===target,'tracking_meal_partition_history');let before:TrackingState;
 if(beforeSnapshot.tracking!==undefined)before=(await read(beforeSnapshot)).state;
 else{const capture=capturedBeforeSchema.parse(after.row.review?.trackingMealBefore),p=capture.proof;
  check(capture.proofDigest===digest(p)&&p.operationId===target&&p.householdId===ctx.householdId&&p.shopId===shop.shop_id&&p.baseShopRevision===beforeSnapshot.revision&&p.resultShopRevision===afterSnapshot.revision&&p.resultShopRevision===p.baseShopRevision+1&&p.beforeSnapshotDigest===evidence.before!.digest&&p.beforeStateDigest===digest(p.beforeState)&&p.afterStateDigest===after.row.state_digest,'tracking_meal_partition_history');
  before=validateState(p.beforeState,p.beforeState.catalog);admitV1(before,before.catalog);check(before.authorityEpoch===after.state.authorityEpoch&&before.privacyRevision===after.state.privacyRevision,'tracking_meal_partition_history');stateMatchesSnapshot(before,beforeSnapshot,ctx,shop);
 }
 const states=[before,after.state];
 check(evidence.operation.operation_id===target&&evidence.operation.household_id===ctx.householdId&&evidence.operation.shop_id===shop.shop_id&&
  evidence.effect!.operation_id===target&&evidence.effect!.household_id===ctx.householdId&&evidence.effect!.shop_id===shop.shop_id&&
  evidence.effect!.base_graph_revision===states[0]!.graph.revision&&evidence.effect!.result_graph_revision===states[1]!.graph.revision,'tracking_meal_partition_history');
 const receipt=sharedDemandReceiptSchema.parse(evidence.afterGraph!.receipt);check(receipt.operationId===target&&receipt.householdId===ctx.householdId&&receipt.shopId===shop.shop_id&&receipt.baseRevision===states[0]!.graph.revision&&receipt.resultRevision===states[1]!.graph.revision,'tracking_meal_partition_history');
 for(const key of ['lines','contributions','edges'] as const){const before=states[0]!.graph[key] as {id:string}[],after=states[1]!.graph[key] as {id:string}[];
  const changes=[...new Set([...before,...after].map(x=>x.id))].flatMap(id=>{const b=before.find(x=>x.id===id)??null,a=after.find(x=>x.id===id)??null;return eq(b,a)?[]:[{id,before:b,after:a}];});
  check(eq([...receipt[key]].sort((a,b)=>a.id.localeCompare(b.id)),changes.sort((a,b)=>a.id.localeCompare(b.id))),'tracking_meal_partition_history');}
 return{evidence,before,after:after.state};
}
/** Pure touched-partition compensation. A later independent fact stays intact;
 * changed/rebound target rows conflict instead of being silently overwritten. */
export function inverseMealPartition(before:TrackingState,after:TrackingState,current:TrackingState,graph:TrackingState['graph']){
 const next=structuredClone(current),transferredChanges:unknown[]=[];
 for(const key of ['bindings','unbound'] as const){
  const identity=(x:{factId:string})=>x.factId;
  for(const factId of new Set([...before[key],...after[key]].map(identity))){
   const b=before[key].find(x=>x.factId===factId)??null,a=after[key].find(x=>x.factId===factId)??null;if(eq(b,a))continue;
   const c=current[key].find(x=>x.factId===factId)??null;check(eq(c,a),'tracking_meal_partition_conflict');
   if(key==='unbound'){
    const old=(a as TrackingState['unbound'][number]|null)?.transferred,newRow=(b as TrackingState['unbound'][number]|null)?.transferred;
    if(old&&newRow)validateDetachedDemandChanges([old],[newRow]);
    if(old&&!newRow)check(old.source.kind!=='reservation','tracking_meal_protected');
    if(newRow)check(!graph.contributions.some(x=>x.id===newRow.id)&&!graph.edges.some(x=>x.demandId===newRow.id||x.supplyId===newRow.id)&&graph.usedIds.includes(newRow.id),'tracking_meal_partition_conflict');
    transferredChanges.push({factId,before:c,after:b});
   }
   const rows=next[key] as {factId:string}[];const index=rows.findIndex(x=>x.factId===factId);
   if(index>=0){if(b)rows[index]=structuredClone(b);else rows.splice(index,1);}
   else if(b){const oldIndex=before[key].findIndex(x=>x.factId===factId),nextOld=before[key].slice(oldIndex+1).find(x=>rows.some(r=>r.factId===x.factId));
    const insert=nextOld?rows.findIndex(r=>r.factId===nextOld.factId):rows.length;rows.splice(insert,0,structuredClone(b));}
  }
 }
 // A touched pack review cannot be restored through a later, independently
 // changed review. New packs will still require the inverse preview's explicit review.
 for(const lineId of new Set([...before.packReviews,...after.packReviews].map(x=>x.lineId))){const b=before.packReviews.find(x=>x.lineId===lineId)??null,a=after.packReviews.find(x=>x.lineId===lineId)??null;if(!eq(b,a))check(eq(current.packReviews.find(x=>x.lineId===lineId)??null,a),'pack_review_conflict');}
 return{bindings:next.bindings,unbound:next.unbound,transferredChanges};
}
export async function deriveTrackingMealUndo(repo:HouseholdRepository,ctx:Context,shop:Shop,current:TrackingState,target:string,operationId:string,at:string,packs:TrackingState['packReviews']){
 const history=await loadTrackingMealHistory(ctx,shop,target),{before,after,evidence}=history;
 check(before.privacyRevision===current.privacyRevision&&after.privacyRevision===current.privacyRevision,'tracking_meal_privacy_changed');
 const reversed=(await ctx.db.query('SELECT 1 FROM ritc.shared_tracking_revision WHERE household_id=$1 AND shop_id=$2 AND reverses_operation_id=$3',[ctx.householdId,shop.shop_id,target])).rowCount!==0;check(!reversed,'tracking_already_reversed');
 const result=deriveSharedFoodUndoCore(evidence,{graph:current.graph,lines:lines(current),quote:shop.quote,shopRevision:shop.revision,storeBasis:{revision:shop.store_basis_revision??null,reviewRequired:shop.store_review_required??false}},
  {operationId,householdId:ctx.householdId,shopId:shop.shop_id,baseRevision:current.graph.revision,at},ctx.now);
 const partition=inverseMealPartition(before,after,current,result.result.graph),facts=await actionFacts(repo,ctx,shop,{action:result.action});
 const candidate={...current,graph:result.result.graph,bindings:partition.bindings,unbound:partition.unbound};
 const identities=[...current.catalog,...before.catalog.filter(f=>!current.catalog.some(c=>c.id===f.id))];
 const catalog=await trackingCatalog(repo,ctx,shop,facts,{...candidate.graph,contributions:[...candidate.graph.contributions,...candidate.unbound.flatMap(u=>u.transferred?[u.transferred]:[])]},identities);
 const basket=facts.lines.map(l=>({id:l.lineId,name:l.originalItem,packs:l.packs,priceMinor:l.unitPriceMinor,feeEligible:l.feeEligible})).sort((a,b)=>a.id.localeCompare(b.id));
 const state=validateState({...candidate,catalog,basket,quoteDigest:storedDigest(facts.quote),legacyLineIds:basket.filter(l=>!candidate.graph.lines.some(g=>g.id===l.id&&g.trashedAt===null)).map(l=>l.id),packReviews:packs},catalog);
 return{state,action:result.action,receipt:result.result.receipt,disclosure:{kind:'mealOperationUndo' as const,targetOperationId:target,mealUndo:result.mealUndo!,transferredChanges:partition.transferredChanges,
  touchedBasket:result.scope.touchedLines,quote:{before:shop.quote,after:facts.quote},graphRows:result.scope.graphRows,beforeCoverage:coverage(current,current.catalog),afterCoverage:coverage(state,catalog)}};
}
