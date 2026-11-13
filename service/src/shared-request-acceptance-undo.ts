/** Pure acceptance certificate / compensation. Load all inputs under the same
 * authorized household transaction. This is not a public input/authorization API. */
import {z} from 'zod';
import {digest} from './database.js';
import {checkout} from './checkout.js';
import {ServiceError} from './errors.js';
import {deriveFoodUndoBasket} from './shared-food-undo-basket.js';
import {validateDemandGraph,undoDemandChange,demandLineTotals} from './shared-demand-domain.js';
import {sharedDemandReceiptSchema,type DemandGraph} from './shared-demand-contracts.js';
import {requestAcceptanceCertificateSchema,requestAcceptanceRecordSchema,requestUndoHistoricalSchema,requestUndoCurrentSchema,
 requestUndoLiveSchema,requestUndoCandidateSchema,requestUndoInverseRecordSchema,requestContentSchema,requestLinkSchema,requestStateSchema,requestUndoID,
 type RequestAcceptanceCertificate,type RequestUndoHistorical,type RequestUndoCurrent,type RequestUndoLive} from './shared-request-undo-contracts.js';
const eq=(a:unknown,b:unknown)=>digest(a)===digest(b);
function check(v:unknown,code:string):asserts v {if(!v)throw new ServiceError(409,'request_undo_'+code,'Refresh and review this complete request change.');}
function exact<T>(schema:z.ZodType<T>,value:unknown):T {const parsed=schema.safeParse(value);check(parsed.success,'invalid_evidence');check(eq(parsed.data,value),'normalized_evidence');return parsed.data;}
function unique(ids:string[]){check(new Set(ids).size===ids.length,'duplicate_identity');}
function sorted<T>(rows:T[],id:(r:T)=>string){return [...rows].sort((a,b)=>id(a).localeCompare(id(b)));}
/** Digest shared with compound tracking evidence; excludes only snapshot and
 * food composition hashes, avoiding a cycle while retaining actual transition facts. */
export function requestAcceptanceComponentDigest(raw:unknown){
 check(raw!==null&&typeof raw==='object'&&!Array.isArray(raw),'invalid_evidence');
 const {beforeSnapshotDigest,afterSnapshotDigest,food,...component}=raw as Record<string,unknown>;
 return digest(exact(requestAcceptanceCertificateSchema.omit({beforeSnapshotDigest:true,afterSnapshotDigest:true,food:true}),component));
}
export function requestContentDigest(raw:unknown){return digest(exact(requestContentSchema,raw));}
function validateCertificate(c:RequestAcceptanceCertificate){
 check(c.resultShopRevision===c.baseShopRevision+1&&c.after.revision===c.before.revision+1,'invalid_transition');
 check(['pending','clarified','deferred'].includes(c.before.status)&&c.after.status==='added'&&c.after.route==='current','invalid_transition');
 check(c.before.status!=='deferred'||c.before.route==='next','invalid_transition');
 check(c.decision.choice==='add'||c.decision.choice==='link','unsupported_decision');
 check(c.before.route!=='next'||c.decision.promote,'promotion_required');
 check(c.before.status!=='deferred'||c.decision.promote,'promotion_required');
 const lineId=c.decision.choice==='add'?c.decision.line.lineId:c.decision.lineId;
 check(c.afterLink.requestId===c.requestId&&c.afterLink.shopId===c.shopId&&c.afterLink.lineId===lineId&&
  c.afterLink.reviewedRevision===c.before.revision&&c.afterLink.operationId===c.operationId,'invalid_link');
 check(c.authorKind==='child'?c.consentId!==null:c.consentId===null,'invalid_origin');
 unique(c.privacyMemberIds);check(c.privacyMemberIds.includes(c.actorId)&&c.privacyMemberIds.includes(c.authorId),'missing_privacy_origin');
 unique(c.carry.map(r=>r.sourceRequestId));unique(c.carry.map(r=>r.targetRequestId));
 for(let i=0;i<c.carry.length;i++){
  const row=c.carry[i]!;check(row.sourceRequestId!==row.targetRequestId&&row.sourceShopId!==row.targetShopId&&row.targetRequestId===row.operationId,'invalid_origin');
  if(i>0){const prior=c.carry[i-1]!;check(prior.targetRequestId===row.sourceRequestId&&prior.targetShopId===row.sourceShopId,'invalid_origin');}
 }
 if(c.carry.length){const last=c.carry.at(-1)!;check(last.targetRequestId===c.requestId&&last.targetShopId===c.shopId,'invalid_origin');
  check(!c.carry.some(x=>x.sourceRequestId===c.requestId),'invalid_origin');}
}
function checkSnapshots(e:RequestUndoHistorical){
 const c=e.record.certificate,b=e.beforeSnapshot.value,a=e.afterSnapshot.value;
 check(e.afterSnapshot.operationId===c.operationId,'snapshot_unavailable');
 check(e.beforeSnapshot.digest===digest(b)&&e.afterSnapshot.digest===digest(a)&&c.beforeSnapshotDigest===e.beforeSnapshot.digest&&c.afterSnapshotDigest===e.afterSnapshot.digest,'snapshot_unavailable');
 check(b.shopId===c.shopId&&a.shopId===c.shopId&&b.revision===c.baseShopRevision&&a.revision===c.resultShopRevision,'snapshot_unavailable');
 check((!b.tracking||b.tracking.shopRevision===b.revision)&&(!a.tracking||a.tracking.shopRevision===a.revision),'snapshot_unavailable');
 check(eq(b.budget,checkout(b.lines,b.quote))&&eq(a.budget,checkout(a.lines,a.quote)),'snapshot_unavailable');
 unique(b.lines.map(x=>x.lineId));unique(a.lines.map(x=>x.lineId));
 check(eq(b.quote,a.quote)&&eq(b.mealRefs??[],a.mealRefs??[]),'unexpected_acceptance_effect');
 if(c.decision.choice==='add'){
  check(!b.lines.some(x=>x.lineId===c.afterLink.lineId),'unexpected_acceptance_effect');
  check(eq(sorted([...b.lines,c.decision.line],x=>x.lineId),sorted(a.lines,x=>x.lineId)),'unexpected_acceptance_effect');
 }else check(eq(sorted(b.lines,x=>x.lineId),sorted(a.lines,x=>x.lineId))&&a.lines.some(x=>x.lineId===c.afterLink.lineId),'unexpected_acceptance_effect');
}
function diff<T extends {id:string}>(before:T[],after:T[]){return [...new Set([...before,...after].map(x=>x.id))].flatMap(id=>{
 const b=before.find(x=>x.id===id)??null,a=after.find(x=>x.id===id)??null;return eq(b,a)?[]:[{id,before:b,after:a}];});}
/** Exact graph receipt proof only. Partition callers MUST separately validate
 * both authenticated complete partition states; this is not basket admission. */
export function validateRequestAcceptanceGraphReceipt(raw:unknown){
 const e=validateRequestAcceptanceCoreHistory(raw),c=e.record.certificate;
 check(e.food.kind==='tracked'&&c.food.kind==='tracked','food_history_unavailable');
 const b=validateDemandGraph(e.food.before),a=validateDemandGraph(e.food.after),r=sharedDemandReceiptSchema.parse(e.food.receipt);
 check(c.food.beforeDigest===digest(b)&&c.food.afterDigest===digest(a)&&c.food.receiptDigest===digest(r),'food_history_unavailable');
 check(b.householdId===c.householdId&&a.householdId===c.householdId&&b.shopId===c.shopId&&a.shopId===c.shopId&&
  b.revision===c.food.beforeRevision&&a.revision===c.food.afterRevision&&a.revision===b.revision+1,'food_history_unavailable');
 check(eq(e.beforeSnapshot.value.demand,{schemaVersion:1,revision:b.revision,digest:digest(b)})&&eq(e.afterSnapshot.value.demand,{schemaVersion:1,revision:a.revision,digest:digest(a)}),'food_history_unavailable');
 check(r.operationId===c.operationId&&r.householdId===c.householdId&&r.shopId===c.shopId&&r.baseRevision===b.revision&&r.resultRevision===a.revision,'food_history_unavailable');
 for(const key of ['lines','contributions','edges'] as const)check(eq(sorted(r[key] as {id:string}[],x=>x.id),sorted(diff(b[key] as {id:string}[],a[key] as {id:string}[]),x=>x.id)),'receipt_mismatch');
 return e;
}
function validateGraphHistory(e:RequestUndoHistorical){
 const c=e.record.certificate;check(e.food.kind===c.food.kind,'food_history_unavailable');
 if(c.food.kind==='compoundAdoption')throw new ServiceError(409,'request_undo_composition_required','Review the complete adoption and request transition together.');
 if(e.food.kind==='legacy'){check(!e.beforeSnapshot.value.demand&&!e.afterSnapshot.value.demand,'food_history_unavailable');return;}
 check(e.food.kind==='tracked'&&c.food.kind==='tracked','food_history_unavailable');
 if(e.food.partition)throw new ServiceError(409,'request_undo_composition_required','Review the complete accepted partition evidence.');
 validateRequestAcceptanceGraphReceipt(e);
 const b=e.food.before,a=e.food.after;
 const own=(g:DemandGraph)=>g.contributions.filter(x=>x.removedAt===null&&x.source.kind==='request'&&x.source.requestId===c.requestId);
 check(own(b).length===0&&own(a).length===1,'invalid_link');
 graphBasket(b,e.beforeSnapshot.value.lines);graphBasket(a,e.afterSnapshot.value.lines);
 const source=own(a)[0]!;check(source.lineId===c.afterLink.lineId&&source.source.kind==='request'&&source.source.appliedRequestRevision===c.before.revision,'invalid_link');
}
/** Validate historical lineage without requiring its mutable result to remain
 * current. Replay after later author edits/reacceptance uses this exact path. */
export function validateRequestAcceptanceCoreHistory(raw:unknown){
 const e=exact(requestUndoHistoricalSchema,raw),c=e.record.certificate;
 check(e.record.digest===digest(c),'history_unavailable');validateCertificate(c);
 check(e.operation.householdId===c.householdId&&e.operation.shopId===c.shopId&&e.operation.operationId===c.operationId&&e.operation.actorId===c.actorId&&e.operation.deviceId===c.deviceId&&e.operation.payloadDigest===c.payloadDigest,'history_unavailable');
 checkSnapshots(e);return e;
}
export function validateRequestAcceptanceHistory(raw:unknown){
 const e=validateRequestAcceptanceCoreHistory(raw);validateGraphHistory(e);return e;
}
/** Repository acceptance hook supplies facts read before and after its actual
 * transition. Returned certificate is to be inserted immutably, never accepted
 * from an HTTP body. No preview lookup is used as historical authority. */
export function captureRequestAcceptance(raw:unknown,observed:{beforeContent:unknown;afterContent:unknown;beforeState:unknown;afterState:unknown;beforeLinks:unknown;afterLinks:unknown}){
 const c=exact(requestAcceptanceCertificateSchema,raw);validateCertificate(c);
 check(eq(exact(requestStateSchema,observed.beforeState),c.before)&&eq(exact(requestStateSchema,observed.afterState),c.after),'invalid_transition');
 const before=exact(requestContentSchema,observed.beforeContent),after=exact(requestContentSchema,observed.afterContent);
 check(eq(before,after)&&digest(before)===c.contentDigest&&before.requestId===c.requestId&&before.shopId===c.shopId&&
  before.authorId===c.authorId&&before.authorKind===c.authorKind&&before.consentId===c.consentId,'invalid_origin');
 const links=z.array(requestLinkSchema).max(2000),b=exact(links,observed.beforeLinks),a=exact(links,observed.afterLinks);
 unique(b.map(x=>x.requestId));unique(a.map(x=>x.requestId));
 check(!b.some(x=>x.requestId===c.requestId)&&eq(sorted(a,x=>x.requestId),sorted([...b,c.afterLink],x=>x.requestId)),'invalid_link');
 check(c.beforeLinksDigest===digest(sorted(b,x=>x.requestId))&&c.afterLinksDigest===digest(sorted(a,x=>x.requestId)),'invalid_link');
 return requestAcceptanceRecordSchema.parse({certificate:structuredClone(c),digest:digest(c)});
}
function authorize(c:RequestAcceptanceCertificate,raw:unknown){
 const live=exact(requestUndoLiveSchema,raw);
 check(live.householdId===c.householdId&&live.shopId===c.shopId&&live.actorActive&&live.deviceActive&&live.shopperScope&&live.actorId===live.assignedShopperId,'access_ended');
 unique(live.privacyMembers.map(x=>x.memberId));
 check(c.privacyMemberIds.every(id=>live.privacyMembers.some(x=>x.memberId===id&&x.available)),'history_erased');
 check(live.author.memberId===c.authorId&&live.author.kind===c.authorKind&&live.author.consentId===c.consentId&&live.author.disclosureLive,'author_access_ended');
 check(live.carry.length===c.carry.length,'origin_access_ended');
 for(let i=0;i<c.carry.length;i++){
  const {sourceShopperId,sourceCurrentAuthorityEpoch,targetCurrentAuthorityEpoch,disclosureLive,...receipt}=live.carry[i]!;
  check(eq(receipt,c.carry[i])&&sourceShopperId===live.actorId&&sourceCurrentAuthorityEpoch===receipt.sourceAuthorityEpoch&&
   targetCurrentAuthorityEpoch===receipt.targetAuthorityEpoch&&disclosureLive,'origin_access_ended');
 }
 return live;
}
function sameStore(e:RequestUndoHistorical,live:RequestUndoLive,current?:RequestUndoCurrent){
 const none={revision:null,reviewRequired:false},old=e.beforeSnapshot.value.storeBasis??none,next=e.afterSnapshot.value.storeBasis??none;
 check(!old.reviewRequired&&!next.reviewRequired&&eq(old,next),'store_conflict');
 if(current)check(!current.storeBasis.reviewRequired&&current.storeBasis.revision===old.revision,'store_conflict');
 if(old.revision===null)check(live.storeBasis===null,'store_conflict');
 else check(live.storeBasis&&live.storeBasis.revision===old.revision&&old.revision<=e.record.certificate.baseShopRevision,'store_access_ended');
}
/** Live authorization for a recorded receipt, without checking mutable head facts. */
export function authorizeRequestAcceptanceReplayCore(history:unknown,liveRaw:unknown){
 const e=validateRequestAcceptanceCoreHistory(history),live=authorize(e.record.certificate,liveRaw);sameStore(e,live);return e;
}
export function authorizeRequestAcceptanceReplayHistory(history:unknown,liveRaw:unknown){
 validateRequestAcceptanceHistory(history);return authorizeRequestAcceptanceReplayCore(history,liveRaw);
}
function verifyLinks(graph:DemandGraph,links:RequestUndoCurrent['links']){
 const sources=graph.contributions.filter(c=>c.removedAt===null&&c.source.kind==='request');
 for(const link of links){const rows=sources.filter(c=>c.source.kind==='request'&&c.source.requestId===link.requestId);
  check(rows.length===1&&rows[0]!.lineId===link.lineId&&rows[0]!.source.kind==='request'&&rows[0]!.source.appliedRequestRevision===link.reviewedRevision,'request_source_mismatch');}
 check(sources.every(c=>{const source=c.source;return source.kind==='request'&&links.some(l=>l.requestId===source.requestId);}),'request_source_mismatch');
}
function graphBasket(g:DemandGraph,lines:RequestUndoCurrent['lines']){
 const totals=demandLineTotals(g);check(totals.length===lines.length&&lines.every(l=>totals.some(t=>t.lineId===l.lineId)&&g.lines.some(x=>x.id===l.lineId&&x.name===l.originalItem)),'graph_conflict');
}
export function prepareRequestAcceptanceUndo(history:unknown,currentRaw:unknown,liveRaw:unknown,command:{operationId:string;at:string},now:Date,alreadyReversed=false){
 exact(z.object({operationId:requestUndoID,at:z.string().datetime({offset:true})}).strict(),command);
 const e=validateRequestAcceptanceCoreHistory(history),c=e.record.certificate,live=authorize(c,liveRaw),current=exact(requestUndoCurrentSchema,currentRaw);
 check(!alreadyReversed,'already_reversed');sameStore(e,live,current);
 check(current.authorityEpoch===live.authorityEpoch&&current.shopRevision>=c.resultShopRevision,'stale_base');
 const content=current.request.content;
 check(content.requestId===c.requestId&&content.shopId===c.shopId&&content.authorId===c.authorId&&content.authorKind===c.authorKind&&content.consentId===c.consentId&&
  requestContentDigest(content)===c.contentDigest&&eq(current.request.state,c.after),'request_conflict');
 unique(current.mealRefs.map(x=>x.occurrenceId));unique(current.lines.map(x=>x.lineId));
 unique(current.links.map(x=>x.requestId));check(current.links.every(x=>x.shopId===c.shopId),'invalid_link');
 check(eq(current.links.find(x=>x.requestId===c.requestId)??null,c.afterLink),'request_conflict');
 const basket=deriveFoodUndoBasket(e.beforeSnapshot.value,e.afterSnapshot.value,current,now);
 check(!basket.quoteChanged,'unexpected_acceptance_effect');
 const links=current.links.filter(x=>x.requestId!==c.requestId),restored={...c.before,revision:current.request.state.revision+1};
 return {e,c,live,current,content,basket,links,restored};
}
export function deriveRequestAcceptanceUndo(history:unknown,currentRaw:unknown,liveRaw:unknown,command:{operationId:string;at:string},now:Date,alreadyReversed=false){
 validateRequestAcceptanceHistory(history);
 const {e,c,live,current,content,basket,links,restored}=prepareRequestAcceptanceUndo(history,currentRaw,liveRaw,command,now,alreadyReversed);
 if(current.food.kind==='partition'||current.food.kind!==c.food.kind)throw new ServiceError(409,'request_undo_composition_required','Review the request origin and later tracking partition together.');
 let foodAfter:RequestUndoCurrent['food'],receipt:z.infer<typeof sharedDemandReceiptSchema>|null=null,rows=0;
 if(current.food.kind==='tracked'){
  check(e.food.kind==='tracked','food_history_unavailable');const graph=validateDemandGraph(current.food.graph);
  check(graph.householdId===c.householdId&&graph.shopId===c.shopId&&graph.revision>=e.food.after.revision,'stale_base');
  verifyLinks(graph,current.links);graphBasket(graph,current.lines);
  check(graph.contributions.some(x=>x.removedAt===null&&x.source.kind==='request'&&x.source.requestId===c.requestId&&x.originalText===content.originalItem),'request_source_mismatch');
  const result=undoDemandChange(graph,e.food.receipt,{schemaVersion:1,operationId:command.operationId,householdId:c.householdId,shopId:c.shopId,
   baseRevision:graph.revision,at:command.at,lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[]});
  verifyLinks(result.graph,links);graphBasket(result.graph,basket.lines);
  foodAfter={kind:'tracked',graph:result.graph};receipt=result.receipt;
  rows=e.food.receipt.lines.length+e.food.receipt.contributions.length+e.food.receipt.edges.length;
 }else{
  unique(current.food.catalog.map(x=>x.id));
  const requestFacts=current.food.catalog.filter(x=>x.source.kind==='request');
  for(const link of current.links){const matched=requestFacts.filter(x=>x.source.kind==='request'&&x.source.requestId===link.requestId);
   check(matched.length===1&&matched[0]!.source.kind==='request'&&matched[0]!.source.appliedRequestRevision===link.reviewedRevision&&matched[0]!.requiredLineId===link.lineId,'request_source_mismatch');}
  check(requestFacts.every(x=>{const source=x.source;return source.kind==='request'&&current.links.some(l=>l.requestId===source.requestId);}),'request_source_mismatch');
  const own=requestFacts.find(x=>x.source.kind==='request'&&x.source.requestId===c.requestId)!;
  check(own.revision===c.afterLink.reviewedRevision&&own.originalText===content.originalItem&&own.originalQuantityText===content.ownQuantity,'request_source_mismatch');
  const catalog=current.food.catalog.filter(x=>x.id!==own.id);
  check(catalog.every(x=>x.requiredLineId===null||basket.lines.some(l=>l.lineId===x.requiredLineId)),'dependent_source');
  foodAfter={kind:'legacy',catalog};
 }
 const action={kind:'request.undoAcceptance' as const,body:{targetOperationId:c.operationId,requestId:c.requestId,baseRequestRevision:current.request.state.revision,lines:basket.lines,quote:basket.quote}};
 const base={shopRevision:current.shopRevision,authorityEpoch:current.authorityEpoch,requestRevision:current.request.state.revision,
  food:current.food.kind==='tracked'?{kind:'tracked' as const,graphRevision:current.food.graph.revision,graphDigest:digest(current.food.graph)}:{kind:'legacy' as const,catalogDigest:digest(current.food.catalog)}};
 const requestUndo={requestId:c.requestId,choice:c.decision.choice,originalItem:content.originalItem,originalQuantityText:content.ownQuantity,targetBefore:c.before,targetAfter:c.after,current:current.request.state,restored,
  beforeLink:c.afterLink,afterLink:null,carry:c.carry};
 const scope={requestsChanged:true as const,mealsChanged:false as const,quoteChanged:false as const,touchedLines:basket.touched,graphRows:rows};
 // Exclude newly generated tombstone timestamps/reserved operation IDs, so a
 // later preview of the same current facts has the same candidate digest.
 const effectDigest=digest({acceptance:e.record.digest,base,current,action,requestUndo,scope,storeBasis:live.storeBasis});
 const candidate=requestUndoCandidateSchema.parse({schemaVersion:1,kind:'requestAcceptanceUndo',shopId:c.shopId,targetOperationId:c.operationId,effectDigest,base,action,requestUndo,scope,
  foodBefore:current.food,foodAfter,beforeCheckout:checkout(current.lines,current.quote),afterCheckout:checkout(basket.lines,basket.quote),packReviewLineIds:basket.lines.map(x=>x.lineId),storeBasis:live.storeBasis});
 return {candidate,transition:{requestId:c.requestId,expected:current.request.state,restored,retireLink:c.afterLink,remainingLinks:links,mealRefs:structuredClone(current.mealRefs)},receipt};
}
/** This does not read/rederive current mutable request/graph state. The repository
 * must load the actual recorded inverse and existing dedup bytes/key under the
 * same live authority/privacy lock; the old receipt is never an instruction. */
export function replayRequestAcceptanceUndoCore(history:unknown,liveRaw:unknown,inverseRaw:unknown,retry:{clientKey:string;payloadDigest:string}){
 const e=validateRequestAcceptanceCoreHistory(history),c=e.record.certificate,live=authorize(c,liveRaw);sameStore(e,live);
 const inverse=exact(requestUndoInverseRecordSchema,inverseRaw),r=inverse.receipt;
 check(inverse.targetOperationId===c.operationId&&inverse.acceptanceDigest===e.record.digest&&inverse.operationId!==c.operationId,'history_unavailable');
 check(inverse.actorId===live.actorId&&inverse.deviceId===live.deviceId&&inverse.authorityEpoch===live.authorityEpoch,'access_ended');
 check(inverse.clientKey===retry.clientKey&&inverse.payloadDigest===retry.payloadDigest,'retry_changed');
 check(r.operationId===inverse.operationId&&r.shopId===c.shopId&&r.authorityEpoch===inverse.authorityEpoch&&r.requestId===c.requestId&&
  r.requestRevision===c.after.revision+1&&r.shopRevision>c.resultShopRevision,'history_unavailable');
 return structuredClone(r);
}

/** V1 complete graph/legacy wrapper. Composed repository callers must invoke
 * their complete mode validator before using the explicit Core variant. */
export function replayRequestAcceptanceUndo(history:unknown,liveRaw:unknown,inverseRaw:unknown,retry:{clientKey:string;payloadDigest:string}){
 validateRequestAcceptanceHistory(history);return replayRequestAcceptanceUndoCore(history,liveRaw,inverseRaw,retry);
}
