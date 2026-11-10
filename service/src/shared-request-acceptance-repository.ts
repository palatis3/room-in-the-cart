/** Dedicated request-family review/commit. Existing Undo payloads stay unchanged. */
import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import type {Context,HouseholdRepository,Shop} from './repository.js';
import type {Envelope} from './contracts.js';
import {digest} from './database.js';
import {ServiceError,refresh} from './errors.js';
import {deriveRequestAcceptanceUndo,replayRequestAcceptanceUndoCore,authorizeRequestAcceptanceReplayCore} from './shared-request-acceptance-undo.js';
import {requestUndoID,requestUndoPreviewInputSchema,requestUndoApplyBodySchema,requestUndoPreviewResponseSchema,requestUndoInverseRecordSchema} from './shared-request-undo-contracts.js';
import {acceptanceLinks,acceptanceRequest,acceptanceContent,acceptanceState,loadAcceptanceHistory,loadAcceptanceLive,loadAcceptanceComposition,validateLoadedAcceptanceHistory} from './shared-request-acceptance-lineage.js';
import {loadDemand,actionFacts,verifySources,verifyPacks,rememberSources} from './shared-demand-repository.js';
import {assertTrackingV1,trackingCatalog,readRequestUndoTracking,loadRequestUndoTrackingMapping,stageRequestUndoTracking} from './shared-demand-tracking-repository.js';
import {derivePartitionedRequestUndo,deriveCompoundRequestUndo} from './shared-demand-request-composition.js';
import {SharedDemandError} from './shared-demand-domain.js';
import {PartitionError} from './shared-demand-tracking.js';
function check(value:unknown,code='stale_preview'):asserts value {if(!value)throw new ServiceError(409,'request_undo_'+code,'Refresh and review this complete request change.');}
const same=(a:unknown,b:unknown)=>digest(a)===digest(b);
const candidateInput=z.object({targetOperationId:requestUndoID,base:z.object({shopRevision:z.number().int().positive(),authorityEpoch:z.number().int().positive()}).strict()}).strict();
async function derive(repo:HouseholdRepository,ctx:Context,shop:Shop,target:string,operationId:string,at:string){
 repo.requireShopper(ctx,shop);repo.requireDraft(shop);const partition=await readRequestUndoTracking(repo,ctx,shop);if(!partition)await assertTrackingV1(repo,ctx,shop);
 check(!shop.demand_review_required&&!shop.store_review_required,'review_required');
 const history=await loadAcceptanceHistory(ctx,shop,target),live=await loadAcceptanceLive(repo,ctx,shop,history),request=await acceptanceRequest(ctx,shop.shop_id,history.record.certificate.requestId);
 const demand=await loadDemand(ctx,shop),catalog=partition?.catalog??await trackingCatalog(repo,ctx,shop,undefined,demand?.graph),lines=await repo.lines(ctx,shop.shop_id),meals=await repo.meals(ctx,shop.shop_id);
 const already=(await ctx.db.query('SELECT 1 FROM ritc.request_acceptance_inverse WHERE household_id=$1 AND target_operation_id=$2 UNION ALL SELECT 1 FROM ritc.shared_tracking_revision WHERE household_id=$1 AND reverses_operation_id=$2',[ctx.householdId,target])).rowCount!==0;
 const current={shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,phase:shop.phase,storeBasis:{revision:shop.store_basis_revision??null,reviewRequired:shop.store_review_required??false},lines,quote:shop.quote,mealRefs:meals.map(({occurrenceId,revision})=>({occurrenceId,revision})),request:{content:acceptanceContent(request),state:acceptanceState(request)},links:await acceptanceLinks(ctx,shop.shop_id),food:partition?{kind:'partition',state:partition}:demand?{kind:'tracked',graph:demand.graph}:{kind:'legacy',catalog}};
 const value=history.food.kind==='compoundAdoption'?deriveCompoundRequestUndo(history,current,live,{operationId,at},ctx.now,await loadAcceptanceComposition(ctx,shop,target),already):partition?derivePartitionedRequestUndo(history,current,live,{operationId,at},ctx.now,await loadRequestUndoTrackingMapping(ctx,shop,history.record.certificate.resultShopRevision),already):deriveRequestAcceptanceUndo(history,current,live,{operationId,at},ctx.now,already);
 if(value.candidate.foodAfter.kind==='tracked'){
  const facts=await actionFacts(repo,ctx,shop,{action:{kind:'shop.patch',body:{lines:value.candidate.action.body.lines,quote:value.candidate.action.body.quote}}});
  await verifySources(repo,ctx,shop,value.candidate.foodAfter.graph,facts,value.transition.retireLink);
 }
 return{...value,history,live,trackingState:value.candidate.foodAfter.kind==='partition'?value.candidate.foodAfter.state:undefined,targetAdoptionOperationId:value.candidate.scope.firstAdoptionReversed?target:null};
}
export async function readRequestUndoCandidate(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown){
 const input=candidateInput.parse(raw);repo.requireShopper(ctx,shop);repo.checkBase(shop,input.base);
 return(await derive(repo,ctx,shop,input.targetOperationId,randomUUID(),ctx.now.toISOString())).candidate;
}
async function evaluated(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown,operationId:string,at:string){
 const input=requestUndoPreviewInputSchema.parse(raw);repo.checkBase(shop,input.base);
 let result=await derive(repo,ctx,shop,input.targetOperationId,operationId,at);const c=result.candidate;
 check(same(input.base,c.base)&&input.effectDigest===c.effectDigest,'changed');
 check(input.packs.length===c.packReviewLineIds.length&&new Set(input.packs.map(x=>x.lineId)).size===input.packs.length&&input.packs.every(x=>c.packReviewLineIds.includes(x.lineId)),'pack_review_required');
 if(c.foodAfter.kind==='tracked'){
  const facts=await actionFacts(repo,ctx,shop,{action:{kind:'shop.patch',body:{lines:c.action.body.lines,quote:c.action.body.quote}}});verifyPacks(c.foodAfter.graph,facts,input.packs);
 }else if(c.foodAfter.kind==='partition'){
  const state=c.foodAfter.state,legacy=new Set(state.legacyLineIds);
  check(input.packs.filter(x=>legacy.has(x.lineId)).every(x=>x.acceptUnresolved),'unknown_acceptance_required');
  const facts=await actionFacts(repo,ctx,shop,{action:{kind:'shop.patch',body:{lines:c.action.body.lines,quote:c.action.body.quote}}});
  const packs=input.packs.filter(x=>!legacy.has(x.lineId));verifyPacks(state.graph,{...facts,lines:facts.lines.filter(l=>!legacy.has(l.lineId))},packs);
  const trackingState={...state,packReviews:packs};result={...result,candidate:{...c,foodAfter:{kind:'partition',state:trackingState}},trackingState};
 }else check(input.packs.every(x=>x.acceptUnresolved),'unknown_acceptance_required');
 check(c.afterCheckout.status!=='overCap'||input.acceptOverage,'overage_acceptance_required');
 check((c.afterCheckout.status!=='unresolved'&&c.afterCheckout.status!=='scopeMismatch'&&c.afterCheckout.scope==='wholeCheckout')||input.acceptUnknown,'unknown_acceptance_required');
 return{input,...result};
}
export async function previewRequestUndo(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown){
 repo.requireShopper(ctx,shop);const operationId=randomUUID(),previewId=randomUUID(),createdAt=ctx.now.toISOString(),expiresAt=new Date(ctx.now.getTime()+5*60000).toISOString();
 const value=await evaluated(repo,ctx,shop,raw,operationId,createdAt);
 const facts={schemaVersion:1 as const,kind:'requestAcceptanceUndoPreview' as const,candidate:value.candidate,previewId,expiresAt,operationId,packs:value.input.packs,foodReceipt:value.receipt?{kind:'tracked' as const,receipt:value.receipt}:{kind:'legacy' as const,receipt:null}};
 const previewDigest=digest({facts,intent:value.input,actorId:ctx.member.member_id,deviceId:ctx.deviceId,createdAt});
 const result=requestUndoPreviewResponseSchema.parse({...facts,previewDigest});
 check(Buffer.byteLength(JSON.stringify(result))<=1800000,'review_too_large');
 await ctx.db.query('DELETE FROM ritc.request_acceptance_preview WHERE household_id=$1 AND expires_at<=$2',[ctx.householdId,ctx.now]);
 check((await ctx.db.query('SELECT count(*)::integer n FROM ritc.request_acceptance_preview WHERE household_id=$1 AND actor_id=$2',[ctx.householdId,ctx.member.member_id])).rows[0].n<100,'preview_limit');
 await ctx.db.query(`INSERT INTO ritc.request_acceptance_preview(household_id,shop_id,preview_id,operation_id,actor_id,device_id,authority_epoch,shop_revision,target_operation_id,request_id,request_revision,intent,result,accepted_digest,created_at,expires_at)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)`,[ctx.householdId,shop.shop_id,previewId,operationId,ctx.member.member_id,ctx.deviceId,shop.authority_epoch,shop.revision,value.input.targetOperationId,value.candidate.requestUndo.requestId,value.candidate.base.requestRevision,value.input,result,previewDigest,createdAt,expiresAt]);
 return result;
}
async function bound(ctx:Context,shopId:string,body:unknown){const b=requestUndoApplyBodySchema.parse(body);const p=(await ctx.db.query(`SELECT * FROM ritc.request_acceptance_preview WHERE household_id=$1 AND shop_id=$2 AND preview_id=$3 AND actor_id=$4 AND device_id=$5 AND accepted_digest=$6 AND expires_at>$7`,[ctx.householdId,shopId,b.operationUndoReview.previewId,ctx.member.member_id,ctx.deviceId,b.operationUndoReview.previewDigest,ctx.now])).rows[0];if(!p)throw refresh();return{p,b};}
export async function requestUndoOperation(ctx:Context,c:Envelope){return(await bound(ctx,c.shopId,c.body)).p.operation_id as string;}
/** Called by the repository before setLines/request update/snapshot. Its return
 * values are exact prepared state; callers cannot replace part of the inverse. */
export async function applyRequestUndo(repo:HouseholdRepository,ctx:Context,shop:Shop,c:Envelope,operationId:string){
 repo.requireShopper(ctx,shop);repo.requireDraft(shop);const {p,b}=await bound(ctx,shop.shop_id,c.body);
 check(p.operation_id===operationId&&p.shop_revision===shop.revision&&p.authority_epoch===shop.authority_epoch&&c.base.requestRevision===p.request_revision,'stale_preview');
 const value=await evaluated(repo,ctx,shop,p.intent,operationId,p.created_at.toISOString());
 const stored=requestUndoPreviewResponseSchema.parse(p.result),{operationUndoReview,...body}=b;
 check(same(body,value.candidate.action.body)&&same(stored.candidate,value.candidate)&&same(stored.packs,value.input.packs),'changed');
 const {previewDigest,...facts}=stored;
 check(previewDigest===p.accepted_digest&&previewDigest===digest({facts,intent:value.input,actorId:ctx.member.member_id,deviceId:ctx.deviceId,createdAt:p.created_at.toISOString()})&&same(stored.foodReceipt,value.receipt?{kind:'tracked',receipt:value.receipt}:{kind:'legacy',receipt:null}),'stale_preview');
 await ctx.db.query('SELECT ritc.retire_request_acceptance($1,$2,$3,$4)',[ctx.householdId,shop.shop_id,p.preview_id,operationId]);
 if(value.candidate.foodAfter.kind==='tracked'||value.candidate.foodAfter.kind==='partition'){
  const g=value.candidate.foodAfter.kind==='tracked'?value.candidate.foodAfter.graph:value.candidate.foodAfter.state.graph,before=value.candidate.foodBefore;check(before.kind==='tracked'||before.kind==='partition','food_history_unavailable');
  await ctx.db.query(`INSERT INTO ritc.shared_demand_revision(household_id,shop_id,revision,predecessor,shop_revision,authority_epoch,operation_id,actor_id,device_id,created_at,graph,graph_digest,receipt,pack_review)
   VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,[ctx.householdId,shop.shop_id,g.revision,g.revision-1,shop.revision+1,shop.authority_epoch,operationId,ctx.member.member_id,ctx.deviceId,ctx.now,g,digest(g),value.receipt,JSON.stringify(value.trackingState?.packReviews??value.input.packs)]);
  await rememberSources(ctx,shop,before.kind==='tracked'?before.graph:before.state.graph,g,null);
  await ctx.db.query('UPDATE ritc.shop SET demand_revision=$3,demand_review_required=false WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id,g.revision]);
 }
 if(value.trackingState)await stageRequestUndoTracking(repo,ctx,shop,value.trackingState,value.input.packs,value.targetAdoptionOperationId);
 const receipt={operationId,kind:'request.undoAcceptance' as const,shopId:shop.shop_id,shopRevision:shop.revision+1,authorityEpoch:shop.authority_epoch,disposition:'acceptanceUndone' as const,requestId:value.transition.requestId,requestRevision:value.transition.restored.revision};
 await ctx.db.query(`INSERT INTO ritc.request_acceptance_inverse(household_id,shop_id,operation_id,target_operation_id,request_id,actor_id,device_id,authority_epoch,client_key,payload_digest,acceptance_digest,receipt)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,[ctx.householdId,shop.shop_id,operationId,p.target_operation_id,receipt.requestId,ctx.member.member_id,ctx.deviceId,shop.authority_epoch,c.clientKey,digest(c),value.history.record.digest,receipt]);
 await ctx.db.query('DELETE FROM ritc.request_acceptance_preview WHERE household_id=$1 AND preview_id=$2',[ctx.householdId,p.preview_id]);
 return{body:value.candidate.action.body,transition:value.transition,receipt};
}
export async function assertRequestAcceptanceReplay(repo:HouseholdRepository,ctx:Context,shop:Shop,operation:any,c:Envelope){
 if(operation.kind==='request.undoAcceptance'){
  const row=(await ctx.db.query('SELECT * FROM ritc.request_acceptance_inverse WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,operation.operation_id])).rows[0];check(row?.receipt&&row.acceptance_digest,'history_unavailable');
  const history=await loadAcceptanceHistory(ctx,shop,row.target_operation_id),live=await loadAcceptanceLive(repo,ctx,shop,history);
  const inverse=requestUndoInverseRecordSchema.parse({operationId:row.operation_id,targetOperationId:row.target_operation_id,actorId:row.actor_id,deviceId:row.device_id,authorityEpoch:row.authority_epoch,clientKey:row.client_key,payloadDigest:row.payload_digest,acceptanceDigest:row.acceptance_digest,receipt:row.receipt});
  await validateLoadedAcceptanceHistory(ctx,shop,history);const result=replayRequestAcceptanceUndoCore(history,live,inverse,{clientKey:c.clientKey,payloadDigest:digest(c)});check(same(result,operation.response),'history_unavailable');
 }else if(operation.kind==='request.apply'){
  // New recorded acceptance replay remains historical even after its link was
  // retired/reaccepted, but still rechecks the original author/carry/store scope.
  const exists=(await ctx.db.query('SELECT 1 FROM ritc.request_acceptance_effect WHERE household_id=$1 AND operation_id=$2',[ctx.householdId,operation.operation_id])).rowCount;
  if(exists){const history=await loadAcceptanceHistory(ctx,shop,operation.operation_id);const live=await loadAcceptanceLive(repo,ctx,shop,history);await validateLoadedAcceptanceHistory(ctx,shop,history);authorizeRequestAcceptanceReplayCore(history,live);check(operation.response?.authorityEpoch===shop.authority_epoch,'access_ended');}
 }
}
export async function readRequestAcceptanceHistory(repo:HouseholdRepository,ctx:Context,shop:Shop,cursor:string|null){
 repo.requireShopper(ctx,shop);repo.requireDraft(shop);const before=cursor===null?2147483647:z.coerce.number().int().positive().max(2147483647).parse(cursor);
 const rows=(await ctx.db.query(`SELECT s.revision,o.operation_id,o.kind,o.committed_at FROM ritc.shop_snapshot s JOIN ritc.operation o USING(household_id,operation_id)
 WHERE s.household_id=$1 AND s.shop_id=$2 AND s.revision<$3 AND o.kind='request.apply' ORDER BY s.revision DESC LIMIT 21`,[ctx.householdId,shop.shop_id,before])).rows;const items=[];
 for(const row of rows.slice(0,20)){let eligibility;try{await derive(repo,ctx,shop,row.operation_id,randomUUID(),ctx.now.toISOString());eligibility={status:'reviewable',reason:'explicit_current_preview_required'};}
 catch(e){if(e instanceof ServiceError)eligibility={status:'unavailable',reason:e.code};else if(e instanceof z.ZodError||e instanceof SharedDemandError||e instanceof PartitionError)eligibility={status:'unavailable',reason:'request_undo_history_unavailable'};else throw e;}
 items.push({operationId:row.operation_id,kind:row.kind,shopRevision:row.revision,committedAt:row.committed_at.toISOString(),eligibility});}
 return{schemaVersion:1,shopId:shop.shop_id,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,items,nextBeforeRevision:rows.length>20?String(rows[19]!.revision):null};
}
