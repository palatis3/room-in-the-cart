import {validatePartitionedRequestAcceptanceHistory,validateCompoundRequestAcceptanceHistory} from './shared-demand-request-composition.js';
/** Acceptance-time facts; always called inside the existing household lock.
 * Never reconstruct a pre-acceptance request outcome from a shop snapshot. */
import type {Context,HouseholdRepository,Shop,Member} from './repository.js';
import type {Envelope,Decision} from './contracts.js';
import {digest} from './database.js';
import {digest as trackingDigest,trackingStateSchema} from './shared-demand-tracking.js';
import {ServiceError} from './errors.js';
import {captureRequestAcceptance,requestContentDigest,requestAcceptanceComponentDigest,validateRequestAcceptanceCoreHistory,validateRequestAcceptanceHistory} from './shared-request-acceptance-undo.js';
import {requestAcceptanceCertificateSchema,requestUndoHistoricalSchema,requestUndoLiveSchema,type RequestAcceptanceCertificate,type RequestUndoHistorical} from './shared-request-undo-contracts.js';
import {liveFoodUndoStoreBasis} from './shared-demand-repository.js';
const fail=(code='history_unavailable')=>new ServiceError(409,'request_undo_'+code,'Refresh and review this complete request change.');
function check(v:unknown,code?:string):asserts v {if(!v)throw fail(code);}
export async function acceptanceLinks(ctx:Context,shopId:string){return(await ctx.db.query('SELECT request_id,shop_id,line_id,reviewed_revision,operation_id FROM ritc.request_link WHERE household_id=$1 AND shop_id=$2 ORDER BY request_id',[ctx.householdId,shopId])).rows.map(r=>({requestId:r.request_id,shopId:r.shop_id,lineId:r.line_id,reviewedRevision:r.reviewed_revision,operationId:r.operation_id}));}
export async function acceptanceRequest(ctx:Context,shopId:string,requestId:string){const r=(await ctx.db.query('SELECT * FROM ritc.request_origin WHERE household_id=$1 AND shop_id=$2 AND request_id=$3',[ctx.householdId,shopId,requestId])).rows[0];check(r,'request_unavailable');return r;}
export function acceptanceContent(r:any){return{requestId:r.request_id,shopId:r.shop_id,authorId:r.author_id,authorKind:r.author_kind,consentId:r.author_consent_id??null,
 originalItem:r.original_item,ownQuantity:r.own_quantity,clarification:r.clarification,authoredAt:r.authored_at.toISOString(),receivedAt:r.received_at.toISOString(),followupTo:r.followup_to};}
export const acceptanceState=(r:any)=>({revision:r.revision,status:r.status,route:r.route});
async function snapshot(ctx:Context,shop:Shop,revision:number){const r=(await ctx.db.query('SELECT snapshot,digest,operation_id FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,revision])).rows[0];return r?{operationId:r.operation_id,value:r.snapshot,digest:r.digest}:null;}
async function graph(ctx:Context,shop:Shop,revision:number){return(await ctx.db.query('SELECT graph,graph_digest,receipt,operation_id FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,revision])).rows[0]??null;}
/** Exact stored partition reference. Absence of a before reference is explicit
 * null; the composed validator must separately prove that before graph complete. */
async function snapshotPartition(ctx:Context,shop:Shop,snapshot:{operationId:string;value:any}){
 const ref=snapshot.value.tracking;if(!ref)return null;
 check(ref.schemaVersion===2&&ref.status==='recorded'&&ref.shopRevision===snapshot.value.revision&&ref.digest,'food_history_unavailable');
 const row=(await ctx.db.query('SELECT operation_id,state,state_digest FROM ritc.shared_tracking_revision WHERE household_id=$1 AND shop_id=$2 AND shop_revision=$3',[ctx.householdId,shop.shop_id,ref.shopRevision])).rows[0];
 check(row?.state&&row.state_digest===trackingDigest(row.state)&&row.state_digest===ref.digest&&row.operation_id===snapshot.operationId,'food_history_unavailable');return trackingStateSchema.parse(row.state);
}
export async function acceptanceCarry(ctx:Context,requestId:string){
 const chain:any[]=[];let target=requestId;const seen=new Set<string>();
 for(let depth=0;depth<50;depth++){
  check(!seen.has(target),'origin_access_ended');seen.add(target);
  const r=(await ctx.db.query(`SELECT c.*,src.shop_id AS source_shop_id,dst.shop_id AS target_shop_id,ss.shopper_id AS source_shopper_id,
   ss.authority_epoch AS source_current_epoch,ds.authority_epoch AS target_current_epoch,src.author_active,src.author_kind,src.live_notice
   FROM ritc.request_carry c JOIN ritc.request_origin src ON (src.household_id,src.request_id)=(c.household_id,c.source_request_id)
   JOIN ritc.request dst ON (dst.household_id,dst.request_id)=(c.household_id,c.target_request_id)
   JOIN ritc.shop ss ON (ss.household_id,ss.shop_id)=(src.household_id,src.shop_id) JOIN ritc.shop ds ON (ds.household_id,ds.shop_id)=(dst.household_id,dst.shop_id)
   WHERE c.household_id=$1 AND c.target_request_id=$2`,[ctx.householdId,target])).rows[0];
  if(!r)return chain.reverse();chain.push(r);target=r.source_request_id;
 }
 throw fail('origin_access_ended');
}
const carryFact=(r:any)=>({sourceRequestId:r.source_request_id,targetRequestId:r.target_request_id,sourceShopId:r.source_shop_id,targetShopId:r.target_shop_id,sourceAuthorityEpoch:r.source_authority_epoch,targetAuthorityEpoch:r.target_authority_epoch,operationId:r.target_request_id});
const stagedAcceptance=new WeakMap<Context,Map<string,{operationId:string;requestId:string;componentDigest:string}>>();
export function acceptanceComponentForTracking(ctx:Context,shopId:string,operationId:string){
 const item=stagedAcceptance.get(ctx)?.get(shopId);return item?.operationId===operationId?{kind:'requestAcceptance' as const,requestId:item.requestId,componentDigest:item.componentDigest}:null;
}
export type AcceptanceBefore=NonNullable<Awaited<ReturnType<typeof captureAcceptanceBefore>>>;
export async function captureAcceptanceBefore(repo:HouseholdRepository,ctx:Context,shop:Shop,c:Envelope,operationId:string,decision:Decision){
 if(decision.choice!=='add'&&decision.choice!=='link')return null;
 const r=await acceptanceRequest(ctx,shop.shop_id,String(c.body.requestId)),before=await snapshot(ctx,shop,shop.revision);
 // Existing acceptance remains usable if its old base was already redacted or
 // lacks original child provenance. It does not gain fabricated Undo authority.
 if(!before||before.digest!==digest(before.value)||before.digest==='0'.repeat(64)||(r.author_kind==='child'&&!r.author_consent_id))return null;
 const content=acceptanceContent(r),state=acceptanceState(r),links=await acceptanceLinks(ctx,shop.shop_id),carry=(await acceptanceCarry(ctx,r.request_id)).map(carryFact);
 // UUID spelling is canonicalized by PostgreSQL; labels/literals are untouched.
 const normalized=decision.choice==='add'?{...decision,line:{...decision.line,lineId:decision.line.lineId.toLowerCase()}}:{...decision,lineId:decision.lineId.toLowerCase()};
 const afterLink={requestId:r.request_id,shopId:shop.shop_id,lineId:normalized.choice==='add'?normalized.line.lineId:normalized.lineId,reviewedRevision:r.revision,operationId};
 const component={schemaVersion:1,householdId:ctx.householdId,shopId:shop.shop_id,operationId,actorId:ctx.member.member_id,deviceId:ctx.deviceId,authorityEpoch:shop.authority_epoch,payloadDigest:digest(c),baseShopRevision:shop.revision,resultShopRevision:shop.revision+1,requestId:r.request_id,authorId:r.author_id,authorKind:r.author_kind,consentId:r.author_consent_id??null,contentDigest:requestContentDigest(content),before:state,after:{revision:r.revision+1,status:'added',route:'current'},decision:normalized,beforeLink:null,afterLink,beforeLinksDigest:digest(links),afterLinksDigest:digest([...links,afterLink].sort((a,b)=>a.requestId.localeCompare(b.requestId))),carry,privacyMemberIds:[...new Set([ctx.member.member_id,r.author_id])].sort()};
 const componentDigest=requestAcceptanceComponentDigest(component);
 if(!stagedAcceptance.has(ctx))stagedAcceptance.set(ctx,new Map());stagedAcceptance.get(ctx)!.set(shop.shop_id,{operationId,requestId:r.request_id,componentDigest});
 return{r,content,state,links,carry,before,graph:shop.demand_revision?await graph(ctx,shop,shop.demand_revision):null,
  command:structuredClone(c),operationId,decision:normalized,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,componentDigest};
}
export async function finishAcceptanceCapture(repo:HouseholdRepository,ctx:Context,shop:Shop,before:AcceptanceBefore|null){
 if(!before)return;
 const current=await repo.shop(ctx,shop.shop_id),r=await acceptanceRequest(ctx,shop.shop_id,before.r.request_id),after=await snapshot(ctx,current,current.revision),links=await acceptanceLinks(ctx,shop.shop_id);
 check(after&&after.operationId===before.operationId,'snapshot_unavailable');const linked=links.find(x=>x.requestId===r.request_id);check(linked,'invalid_link');
 const afterGraph=current.demand_revision?await graph(ctx,current,current.demand_revision):null;
 let food:RequestAcceptanceCertificate['food'];let historyFood:RequestUndoHistorical['food'];let composition:unknown=null;
 if(!before.graph&&!afterGraph){food={kind:'legacy'};historyFood={kind:'legacy'};}
 else if(before.graph&&afterGraph){food={kind:'tracked',beforeRevision:before.graph.graph.revision,afterRevision:afterGraph.graph.revision,beforeDigest:before.graph.graph_digest,afterDigest:afterGraph.graph_digest,receiptDigest:digest(afterGraph.receipt)};historyFood={kind:'tracked',before:before.graph.graph,after:afterGraph.graph,receipt:afterGraph.receipt};}
 else {
  check(afterGraph&&!before.graph,'food_history_unavailable');
  const adoption=(await ctx.db.query('SELECT evidence,evidence_digest FROM ritc.shared_tracking_adoption WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,before.operationId])).rows[0];
  // Pre-composition API operations cannot be promoted from a graph-only receipt.
  if(!adoption?.evidence||adoption.evidence_digest!==trackingDigest(adoption.evidence))return;
  composition=adoption.evidence;
  food={kind:'compoundAdoption',afterRevision:1,afterDigest:afterGraph.graph_digest,receiptDigest:digest(afterGraph.receipt),compositionDigest:adoption.evidence_digest};historyFood={kind:'compoundAdoption',after:afterGraph.graph,receipt:afterGraph.receipt,compositionDigest:adoption.evidence_digest};
 }
 if(historyFood.kind==='tracked'&&after.value.tracking){const a=await snapshotPartition(ctx,shop,after);check(a,'food_history_unavailable');historyFood.partition={before:await snapshotPartition(ctx,shop,before.before),after:a};}
 const privacyMemberIds=[...new Set([ctx.member.member_id,r.author_id])].sort();
 const certificate=requestAcceptanceCertificateSchema.parse({schemaVersion:1,householdId:ctx.householdId,shopId:shop.shop_id,operationId:before.operationId,actorId:ctx.member.member_id,deviceId:ctx.deviceId,authorityEpoch:before.authorityEpoch,payloadDigest:digest(before.command),baseShopRevision:before.shopRevision,resultShopRevision:current.revision,requestId:r.request_id,authorId:r.author_id,authorKind:r.author_kind,consentId:r.author_consent_id??null,contentDigest:requestContentDigest(before.content),before:before.state,after:acceptanceState(r),decision:before.decision,beforeLink:null,afterLink:linked,beforeLinksDigest:digest(before.links),afterLinksDigest:digest(links),beforeSnapshotDigest:before.before.digest,afterSnapshotDigest:after.digest,food,carry:before.carry,privacyMemberIds});
 check(requestAcceptanceComponentDigest(certificate)===before.componentDigest,'invalid_transition');
 const record=captureRequestAcceptance(certificate,{beforeContent:before.content,afterContent:acceptanceContent(r),beforeState:before.state,afterState:acceptanceState(r),beforeLinks:before.links,afterLinks:links});
 const history={record,operation:{householdId:ctx.householdId,shopId:shop.shop_id,operationId:before.operationId,kind:'request.apply',actorId:ctx.member.member_id,deviceId:ctx.deviceId,payloadDigest:certificate.payloadDigest},beforeSnapshot:before.before,afterSnapshot:after,food:historyFood};
 if(food.kind==='compoundAdoption')validateCompoundRequestAcceptanceHistory(history,composition);else validatePartitionedRequestAcceptanceHistory(history);
 await ctx.db.query(`INSERT INTO ritc.request_acceptance_effect(household_id,shop_id,operation_id,request_id,author_id,actor_id,device_id,authority_epoch,author_consent_id,base_shop_revision,result_shop_revision,base_request_revision,result_request_revision,certificate,certificate_digest)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)`,[ctx.householdId,shop.shop_id,before.operationId,r.request_id,r.author_id,ctx.member.member_id,ctx.deviceId,before.authorityEpoch,r.author_consent_id??null,before.shopRevision,current.revision,before.state.revision,r.revision,record.certificate,record.digest]);
 stagedAcceptance.get(ctx)?.delete(shop.shop_id);
 await ctx.db.query('INSERT INTO ritc.request_acceptance_source_member(household_id,operation_id,member_id) SELECT $1,$2,unnest($3::uuid[])',[ctx.householdId,before.operationId,privacyMemberIds]);
}
export async function loadAcceptanceComposition(ctx:Context,shop:Shop,target:string){
 const row=(await ctx.db.query('SELECT evidence,evidence_digest FROM ritc.shared_tracking_adoption WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,target])).rows[0];
 check(row?.evidence&&row.evidence_digest===trackingDigest(row.evidence),'food_history_unavailable');return row.evidence as unknown;
}
export async function validateLoadedAcceptanceHistory(ctx:Context,shop:Shop,history:RequestUndoHistorical){
 return history.food.kind==='compoundAdoption'?validateCompoundRequestAcceptanceHistory(history,await loadAcceptanceComposition(ctx,shop,history.record.certificate.operationId)):validatePartitionedRequestAcceptanceHistory(history);
}
export async function loadAcceptanceHistory(ctx:Context,shop:Shop,target:string){
 const row=(await ctx.db.query('SELECT * FROM ritc.request_acceptance_effect WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,target])).rows[0];check(row?.certificate&&row.certificate_digest,'history_unavailable');
 const c=requestAcceptanceCertificateSchema.parse(row.certificate);check(row.certificate_digest===digest(c),'history_unavailable');
 const o=(await ctx.db.query('SELECT * FROM ritc.operation WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,target])).rows[0];check(o,'history_unavailable');
 const before=await snapshot(ctx,shop,c.baseShopRevision),after=await snapshot(ctx,shop,c.resultShopRevision);check(before&&after,'snapshot_unavailable');let food:RequestUndoHistorical['food'];
 if(c.food.kind==='legacy')food={kind:'legacy'};
 else {const a=await graph(ctx,shop,c.food.kind==='tracked'?c.food.afterRevision:1);check(a&&a.graph_digest===c.food.afterDigest&&a.operation_id===target,'food_history_unavailable');
  if(c.food.kind==='tracked'){const b=await graph(ctx,shop,c.food.beforeRevision);check(b&&b.graph_digest===c.food.beforeDigest,'food_history_unavailable');food={kind:'tracked',before:b.graph,after:a.graph,receipt:a.receipt};}
  else{const lineage=(await ctx.db.query('SELECT evidence,evidence_digest FROM ritc.shared_tracking_adoption WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,target])).rows[0];check(lineage?.evidence&&lineage.evidence_digest===trackingDigest(lineage.evidence)&&lineage.evidence_digest===c.food.compositionDigest,'food_history_unavailable');food={kind:'compoundAdoption',after:a.graph,receipt:a.receipt,compositionDigest:lineage.evidence_digest};}}
 if(food.kind==='tracked'&&after.value.tracking){const a=await snapshotPartition(ctx,shop,after);check(a,'food_history_unavailable');food.partition={before:await snapshotPartition(ctx,shop,before),after:a};}
 return requestUndoHistoricalSchema.parse({record:{certificate:c,digest:row.certificate_digest},operation:{householdId:o.household_id,shopId:o.shop_id,operationId:o.operation_id,kind:o.kind,actorId:o.actor_id,deviceId:o.device_id,payloadDigest:o.payload_digest},beforeSnapshot:before,afterSnapshot:after,food});
}
export async function loadAcceptanceLive(repo:HouseholdRepository,ctx:Context,shop:Shop,history:RequestUndoHistorical){
 repo.requireShopper(ctx,shop);const c=history.record.certificate;
 const origin=await acceptanceRequest(ctx,shop.shop_id,c.requestId),members=(await ctx.db.query<Member>('SELECT * FROM ritc.member WHERE household_id=$1 AND member_id=ANY($2::uuid[])',[ctx.householdId,c.privacyMemberIds])).rows;
 check(members.length===c.privacyMemberIds.length&&members.every(x=>x.state==='active'),'history_erased');for(const m of members)await repo.consent(ctx.db,ctx.householdId,m);
 const childLive=c.authorKind==='adult'||(repo.options.allowChildNetwork&&origin.live_notice===repo.options.noticeVersion&&origin.author_consent_id===c.consentId);
 // Ordinary historical request disclosure does not require future submission
 // permission; carried-origin disclosure retains its existing author_active rule.
 const carried=!!(origin.carried_forward||origin.from_previous_shop);check(childLive&&(!carried||origin.author_active),'author_access_ended');
 const carry=(await acceptanceCarry(ctx,c.requestId)).map(r=>({...carryFact(r),sourceShopperId:r.source_shopper_id,sourceCurrentAuthorityEpoch:r.source_current_epoch,targetCurrentAuthorityEpoch:r.target_current_epoch,disclosureLive:!!r.author_active&&(r.author_kind==='adult'||repo.options.allowChildNetwork&&r.live_notice===repo.options.noticeVersion)}));
 return requestUndoLiveSchema.parse({householdId:ctx.householdId,shopId:shop.shop_id,actorId:ctx.member.member_id,deviceId:ctx.deviceId,authorityEpoch:shop.authority_epoch,assignedShopperId:shop.shopper_id,actorActive:true,deviceActive:true,shopperScope:!ctx.viewGrantId,privacyMembers:members.map(m=>({memberId:m.member_id,available:true})),author:{memberId:origin.author_id,kind:origin.author_kind,consentId:origin.author_consent_id??null,disclosureLive:true},carry,storeBasis:await liveFoodUndoStoreBasis(ctx,shop,history.beforeSnapshot.value.storeBasis?.revision)});
}
