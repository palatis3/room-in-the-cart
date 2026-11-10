/** V2 tracking persistence. Called only in the existing authorized household lock.
 * Feature admission is opt-in; existing persisted partitions are fenced even when
 * the feature is disabled. No client-supplied catalog/history is ever authority. */
import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import type {Context,HouseholdRepository,Shop,Member} from './repository.js';
import type {Envelope} from './contracts.js';
import {bodySchemas} from './contracts.js';
import {ServiceError} from './errors.js';
import {digest as storeDigest} from './database.js';
import {trackingStateSchema,validateState,admitV1,coverage,recordFirstAdoption,inverseFirstAdoption,PartitionError,digest,type TrackingState,type Fact} from './shared-demand-tracking.js';
import {previewTransferredRebind,previewRedactedRecovery,trackingReviewDisclosure,recordTrackingReview,sealReviewedTracking,verifyTrackingPlacement,redactedProjectionSchema} from './shared-demand-tracking-transitions.js';
import {sharedDemandChangeSchema,demandLineSchema} from './shared-demand-contracts.js';
import {validateDemandGraph,applyDemandChange} from './shared-demand-domain.js';
import {mealDemandSources,requestDemandSource} from './shared-demand-sources.js';
import {loadDemand,actionFacts,verifyPacks,rememberSources,liveFoodUndoStoreBasis,recordFoodOperationEffect} from './shared-demand-repository.js';
const id=z.string().uuid().transform(x=>x.toLowerCase()),hash=z.string().regex(/^[a-f0-9]{64}$/),rev=z.number().int().min(0).max(2147483647);
const base=z.object({shopRevision:rev,authorityEpoch:rev,graphRevision:rev,stateDigest:hash}).strict();
const packs=trackingStateSchema.shape.packReviews;
const delta=sharedDemandChangeSchema.omit({schemaVersion:true,operationId:true,householdId:true,shopId:true,baseRevision:true,at:true});
const action=z.object({kind:z.enum(['shop.patch','request.apply']),body:z.record(z.string(),z.unknown())}).strict();
export const trackingIntentSchema=z.discriminatedUnion('mode',[
 z.object({mode:z.literal('adopt'),base,action,change:delta,packs}).strict(),
 z.object({mode:z.literal('change'),base,action,change:delta,packs,unboundFactIds:z.array(id).max(2000)}).strict(),
 z.object({mode:z.literal('review'),base,action,packs}).strict(),
 z.object({mode:z.literal('firstAdoptionUndo'),base,targetOperationId:id,packs}).strict(),
 z.object({mode:z.literal('rebind'),base,bindings:z.array(z.object({factId:id,line:demandLineSchema,basket:trackingStateSchema.shape.basket.element,packReview:packs.element}).strict()).min(1).max(2000)}).strict(),
 z.object({mode:z.literal('recover'),base,packs}).strict()
]);
type Intent=z.infer<typeof trackingIntentSchema>;
const token=z.object({previewId:id,previewDigest:hash,trackingVersion:z.literal(2)}).strict();
const acceptSchema=z.object({candidateId:id,candidateDigest:hash,acknowledgedDisclosure:z.unknown()}).strict();
function check(v:unknown,code='tracking_review_required'):asserts v{if(!v)throw new ServiceError(409,code,'Review the current food sources and pickup scope.');}
function enabled(repo:HouseholdRepository){if(!repo.options.trackingV2)throw new ServiceError(404,'not_available','This operation is not available.');}
const bounded=<T>(v:T):T=>{check(Buffer.byteLength(JSON.stringify(v))<=1_800_000,'tracking_size');return v;};
const blank=(ctx:Context,shop:Shop)=>({schemaVersion:1 as const,conversionTableVersion:'us-customary-metric-v1' as const,householdId:ctx.householdId,shopId:shop.shop_id,revision:0,lines:[],contributions:[],edges:[],usedIds:[]});
export const trackingBasket=(lines:Awaited<ReturnType<HouseholdRepository['lines']>>)=>lines.map(l=>({id:l.lineId,name:l.originalItem,packs:l.packs,priceMinor:l.unitPriceMinor,feeEligible:l.feeEligible})).sort((a,b)=>a.id.localeCompare(b.id));
const basket=trackingBasket;
const lines=(state:TrackingState)=>state.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible}));
const same=(a:unknown,b:unknown)=>digest(a)===digest(b);
const catalogGraph=(s:Pick<TrackingState,'graph'|'unbound'>)=>({...s.graph,contributions:[...s.graph.contributions,...s.unbound.flatMap(u=>u.transferred?[u.transferred]:[])]});
async function privacyRevision(ctx:Context,shop:Shop){return Number((await ctx.db.query('SELECT tracking_privacy_revision FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id])).rows[0]?.tracking_privacy_revision??0);}
export async function trackingRow(ctx:Context,shop:Shop){return (await ctx.db.query('SELECT * FROM ritc.shared_tracking_revision WHERE household_id=$1 AND shop_id=$2 AND shop_revision<=$3 ORDER BY shop_revision DESC LIMIT 1',[ctx.householdId,shop.shop_id,shop.revision])).rows[0]??null;}
/** Same source enumeration as v1, with the persisted source revision attached.
 * Consent is checked for every accepted request even if currently unbound. */
export async function trackingCatalog(repo:HouseholdRepository,ctx:Context,shop:Shop,facts?:Awaited<ReturnType<typeof actionFacts>>,graph?:TrackingState['graph']):Promise<Fact[]>{
 const meals=facts?.meals??await repo.meals(ctx,shop.shop_id);
 const linked=(await ctx.db.query(`SELECT l.request_id,l.line_id,l.reviewed_revision,r.original_item,r.own_quantity,r.author_id
 FROM ritc.request_link l JOIN ritc.request r ON (r.household_id,r.shop_id,r.request_id)=(l.household_id,l.shop_id,l.request_id)
 WHERE l.household_id=$1 AND l.shop_id=$2 ORDER BY l.request_id`,[ctx.householdId,shop.shop_id])).rows;
 if(facts?.request){const r=facts.request,index=linked.findIndex(x=>x.request_id===r.request_id);const value={...r,line_id:r.targetLine,reviewed_revision:r.revision};if(index<0)linked.push(value);else linked[index]=value;}
 linked.sort((a,b)=>a.request_id.localeCompare(b.request_id));
 const authors=(await ctx.db.query<Member>('SELECT * FROM ritc.member WHERE household_id=$1 AND member_id=ANY($2::uuid[])',[ctx.householdId,[...new Set(linked.map(r=>r.author_id))]])).rows;
 const live=new Set<string>();for(const m of authors){check(m.state==='active','tracking_source_unavailable');await repo.consent(ctx.db,ctx.householdId,m);live.add(m.member_id);}check(linked.every(r=>live.has(r.author_id)),'tracking_source_unavailable');
 const whole=new Set((graph?.contributions??[]).flatMap(c=>c.removedAt===null&&c.source.kind==='reservation'&&c.source.originOccurrenceId&&c.source.groupId===null&&c.source.bindingId===null?[c.source.originOccurrenceId+'/'+c.source.ingredientId]:[]));
 const occurrenceIds=meals.map(m=>m.occurrenceId);
 if(occurrenceIds.length){
  const origins=(await ctx.db.query(`SELECT DISTINCT m.* FROM ritc.member m JOIN (
   SELECT actor_id FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=ANY($3::uuid[])
   UNION SELECT actor_id FROM ritc.shared_meal_change WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=ANY($3::uuid[]) AND (state='applied' OR proposal_id=$4)
  ) o ON o.actor_id=m.member_id WHERE m.household_id=$1`,[ctx.householdId,shop.shop_id,occurrenceIds,facts?.body.mealEdit?.changeProposalId??null])).rows as Member[];
  for(const author of origins){check(author.state==='active','tracking_source_unavailable');await repo.consent(ctx.db,ctx.householdId,author);}
 }
 const descriptors=[...mealDemandSources(shop.shop_id,meals,whole),...linked.map(r=>requestDemandSource(shop.shop_id,r))];
 return descriptors.map(({productName:_,...d})=>({ ...d,revision:d.source.kind==='request'?d.source.appliedRequestRevision:meals.find(m=>m.occurrenceId===(d.source.kind==='meal'?d.source.occurrenceId:d.source.kind==='reservation'?d.source.originOccurrenceId:null))!.revision})).sort((a,b)=>a.id.localeCompare(b.id));
}
function partition(graph:TrackingState['graph'],catalog:Fact[],before:TrackingState|null,allowedUnbound:string[]){
 check(new Set(allowedUnbound).size===allowedUnbound.length&&allowedUnbound.every(i=>catalog.some(f=>f.id===i)),'tracking_unbound_identity');
 const bindings:TrackingState['bindings']=[],unbound:TrackingState['unbound']=[];
 for(const f of catalog){const found=graph.contributions.filter(c=>c.removedAt===null&&same(c.source,f.source));check(found.length<=1,'tracking_duplicate_source');
  if(found.length){check(!allowedUnbound.includes(f.id),'tracking_partition_conflict');bindings.push({factId:f.id,contributionId:found[0]!.id});}
  else{check(allowedUnbound.includes(f.id),'tracking_unbound_review_required');const old=before?.unbound.find(x=>x.factId===f.id);check(!before?.bindings.some(x=>x.factId===f.id),'tracking_transfer_requires_inverse');unbound.push(old?structuredClone(old):{factId:f.id,transferred:null});}
 }
 return{bindings,unbound};
}
async function stateNow(repo:HouseholdRepository,ctx:Context,shop:Shop){
 const row=await trackingRow(ctx,shop),loaded=await loadDemand(ctx,shop),graph=loaded?.graph??blank(ctx,shop);
 const retained=row?.state??row?.projection?.state;const catalog=await trackingCatalog(repo,ctx,shop,undefined,retained?catalogGraph({...retained,graph}):graph);
 const currentBasket=basket(await repo.lines(ctx,shop.shop_id)),privacy=await privacyRevision(ctx,shop);
 if(row){
  if(row.projection!==null){const p=redactedProjectionSchema.parse({...row.projection,state:{...row.projection.state,authorityEpoch:shop.authority_epoch}});check(row.state===null&&row.state_digest===null&&p.state.privacyRevision===privacy,'tracking_projection_integrity');return{row,state:null,projection:p,catalog,graph};}
  check(row.state&&row.state_digest===digest(row.state),'tracking_integrity');const state=validateState({...row.state,authorityEpoch:shop.authority_epoch},catalog);
  check(same(state.graph,graph)&&same(state.basket,currentBasket)&&state.quoteDigest===storeDigest(shop.quote)&&state.privacyRevision===privacy&&state.authorityEpoch===shop.authority_epoch,'tracking_stale_state');
  return{row,state,projection:null,catalog,graph};
 }
 if(loaded){const p=(await ctx.db.query('SELECT pack_review FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,graph.revision])).rows[0];check(p?.pack_review&&!shop.demand_review_required,'tracking_history_unavailable');
  const state=validateState({schemaVersion:2,authorityEpoch:shop.authority_epoch,privacyRevision:privacy,quoteDigest:storeDigest(shop.quote),graph,basket:currentBasket,catalog,...partition(graph,catalog,null,[]),legacyLineIds:[],packReviews:p.pack_review},catalog);
  return{row:null,state,projection:null,catalog,graph}; // Current facts only; no initial lineage invented.
 }
 const state=validateState({schemaVersion:2,authorityEpoch:shop.authority_epoch,privacyRevision:privacy,quoteDigest:storeDigest(shop.quote),graph,basket:currentBasket,catalog,bindings:[],unbound:catalog.map(f=>({factId:f.id,transferred:null})),legacyLineIds:currentBasket.map(l=>l.id),packReviews:[]},catalog);
 return{row:null,state,projection:null,catalog,graph};
}
export async function readTracking(repo:HouseholdRepository,ctx:Context,shop:Shop){enabled(repo);repo.requireShopper(ctx,shop);const c=await stateNow(repo,ctx,shop);
 const state=c.state,projection=c.projection;return bounded({schemaVersion:2,shopId:shop.shop_id,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,status:projection?'reviewRequired':shop.demand_revision?'enabled':'legacy',state,projection,basisDigest:digest(projection??state),coverage:state?coverage(state,c.catalog):null,freezeReview:c.row?.review&&state&&same(c.row.review.review.disclosure,trackingReviewDisclosure(state,c.catalog))?{previewId:c.row.review.review.reviewId,previewDigest:c.row.review.reviewDigest,trackingVersion:2}:null});}
/** V1 never receives a partial graph as a complete record, even if activation is off. */
export async function assertTrackingV1(repo:HouseholdRepository,ctx:Context,shop:Shop){const r=await trackingRow(ctx,shop);if(!r)return;check(r.state&&r.state_digest===digest(r.state)&&!r.projection,'tracking_v2_required');try{admitV1(r.state,r.state.catalog);const current=await stateNow(repo,ctx,shop);check(current.state&&!current.projection,'tracking_v2_required');admitV1(current.state,current.catalog);}catch(e){if(e instanceof PartitionError)throw new ServiceError(409,'tracking_v2_required','Review all tracked and unbound food sources.');throw e;}}
const basis=(ctx:Context,shop:Shop,state:TrackingState,basisDigest=digest(state))=>({householdId:ctx.householdId,shopId:shop.shop_id,graphRevision:state.graph.revision,authorityEpoch:shop.authority_epoch,privacyRevision:state.privacyRevision,basisDigest,currentCatalog:state.catalog});
const unchangedAction=(state:TrackingState,shop:Shop)=>({kind:'shop.patch' as const,body:{quote:shop.quote,lines:lines(state)}});
async function storeProof(ctx:Context,shop:Shop,expected?:unknown){
 check(!shop.store_review_required,'tracking_store_review_required');const revision=shop.store_basis_revision??null;
 const proof=revision===null?null:await liveFoodUndoStoreBasis(ctx,shop,revision);check(revision===null||proof,'tracking_store_permission');if(expected!==undefined)check(same(proof,expected),'tracking_store_changed');return proof;
}
async function lineage(ctx:Context,shop:Shop,target:string){const row=(await ctx.db.query('SELECT * FROM ritc.shared_tracking_adoption WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,target])).rows[0];
 check(row?.evidence&&row.evidence_digest===digest(row.evidence)&&row.authority_epoch===shop.authority_epoch,'tracking_history_unavailable');
 check(!(await ctx.db.query('SELECT 1 FROM ritc.shared_tracking_revision WHERE household_id=$1 AND shop_id=$2 AND reverses_operation_id=$3',[ctx.householdId,shop.shop_id,target])).rowCount,'tracking_already_reversed');await storeProof(ctx,shop,row.store_basis);return row;}
async function evaluate(repo:HouseholdRepository,ctx:Context,shop:Shop,input:Intent,operationId:string,at:string){
 repo.requireShopper(ctx,shop);repo.requireDraft(shop);repo.checkBase(shop,input.base);const current=await stateNow(repo,ctx,shop),before=current.state;
 check(input.base.graphRevision===current.graph.revision&&input.base.stateDigest===digest(current.projection??before),'tracking_stale_state');
 let graphReceipt:unknown=null;
 let state:TrackingState,commandAction: z.infer<typeof action>,disclosure:unknown=null,adoption:ReturnType<typeof recordFirstAdoption>|null=null;
 if(input.mode==='recover'){
  check(current.projection,'tracking_recovery_required');const p=current.projection;
  const b={householdId:ctx.householdId,shopId:shop.shop_id,graphRevision:p.state.graph.revision,authorityEpoch:shop.authority_epoch,privacyRevision:p.state.privacyRevision,basisDigest:digest(p),currentCatalog:current.catalog};
  const result=previewRedactedRecovery(p,{operationId,at,packReviews:input.packs},b);state=result.state;disclosure=result.disclosure;commandAction=unchangedAction(state,shop);
 }else{
  check(before&&!shop.demand_review_required,'tracking_recovery_required');check((input.mode==='adopt')===(before.graph.revision===0),'tracking_adoption_required');
  if(input.mode==='firstAdoptionUndo'){
   const old=await lineage(ctx,shop,input.targetOperationId);const result=inverseFirstAdoption(old.evidence,before,{operationId,targetOperationId:input.targetOperationId,evidenceDigest:old.evidence_digest,householdId:ctx.householdId,shopId:shop.shop_id,baseRevision:before.graph.revision,authorityEpoch:shop.authority_epoch,privacyRevision:before.privacyRevision,at,currentCatalog:current.catalog});
   state={...result.state,packReviews:input.packs};validateState(state,current.catalog);
   const restoresPrice=old.evidence.before.basket.some((b:TrackingState['basket'][number])=>old.evidence.after.basket.some((a:TrackingState['basket'][number])=>a.id===b.id&&a.priceMinor!==b.priceMinor));check(!restoresPrice||Date.parse(shop.quote.expiresAt)>ctx.now.getTime(),'expired_quote');disclosure=result.disclosure;commandAction=unchangedAction(state,shop);
  }else if(input.mode==='rebind'){
   const result=previewTransferredRebind(before,{operationId,at,bindings:input.bindings},basis(ctx,shop,before));state=result.state;disclosure=result.disclosure;commandAction=unchangedAction(state,shop);
  }else{
   commandAction={kind:input.action.kind,body:bodySchemas[input.action.kind].parse(input.action.body)};const facts=await actionFacts(repo,ctx,shop,{action:commandAction});
   check(input.mode!=='adopt'||(before.graph.revision===0&&!facts.body.mealEdit&&commandAction.kind==='shop.patch'&&same(facts.quote,shop.quote)),'tracking_first_adoption_scope');
   const result=input.mode==='review'?{graph:validateDemandGraph({...before.graph,revision:before.graph.revision+1})}:applyDemandChange(before.graph,{...input.change,schemaVersion:1,operationId,householdId:ctx.householdId,shopId:shop.shop_id,baseRevision:before.graph.revision,at});
   graphReceipt='receipt' in result?result.receipt:{schemaVersion:1,operationId,householdId:ctx.householdId,shopId:shop.shop_id,baseRevision:before.graph.revision,resultRevision:result.graph.revision,lines:[],contributions:[],edges:[]};
   if(input.mode==='review')check(!facts.body.mealEdit&&commandAction.kind==='shop.patch'&&same(basket(facts.lines).map(l=>({id:l.id,name:before.legacyLineIds.includes(l.id)?null:l.name})),before.basket.map(l=>({id:l.id,name:before.legacyLineIds.includes(l.id)?null:l.name}))),'tracking_review_food_changed');
   const catalog=await trackingCatalog(repo,ctx,shop,facts,result.graph),actualBasket=basket(facts.lines),unboundIds=input.mode==='change'?input.unboundFactIds:input.mode==='review'?before.unbound.map(u=>u.factId):[];
   state=validateState({...before,graph:result.graph,basket:actualBasket,quoteDigest:storeDigest(facts.quote),catalog,...partition(result.graph,catalog,before,unboundIds),legacyLineIds:actualBasket.filter(l=>!result.graph.lines.some(g=>g.id===l.id&&g.trashedAt===null)).map(l=>l.id),packReviews:input.packs},catalog);
   if(input.mode==='adopt')adoption=recordFirstAdoption(operationId,before,state);
  }
 }
 state={...state,basket:[...state.basket].sort((a,b)=>a.id.localeCompare(b.id))};
 const facts=await actionFacts(repo,ctx,shop,{action:commandAction});const catalog=await trackingCatalog(repo,ctx,shop,facts,catalogGraph(state));validateState(state,catalog);
 check(same(basket(facts.lines),state.basket)&&storeDigest(facts.quote)===state.quoteDigest,'tracking_action_changed');
 verifyPacks(state.graph,{...facts,lines:facts.lines.filter(l=>!state.legacyLineIds.includes(l.lineId))},state.packReviews);
 const afterDisclosure=trackingReviewDisclosure(state,catalog),storeBasis=await storeProof(ctx,shop);
 return{before,projection:current.projection,state,graphReceipt,action:commandAction,disclosure:{changes:disclosure,pickup:afterDisclosure},adoption,storeBasis};
}
export async function createTrackingCandidate(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown){enabled(repo);repo.requireShopper(ctx,shop);const intent=trackingIntentSchema.parse(raw),operationId=randomUUID(),created=ctx.now,expires=new Date(created.getTime()+600000);
 const value=await evaluate(repo,ctx,shop,intent,operationId,created.toISOString()),candidateId=randomUUID(),candidateDigest=digest({intent,operationId,createdAt:created.toISOString(),value});bounded(value);
 await ctx.db.query('DELETE FROM ritc.shared_tracking_preview WHERE household_id=$1 AND expires_at<=$2',[ctx.householdId,ctx.now]);
 check((await ctx.db.query('SELECT count(*)::integer AS n FROM ritc.shared_tracking_preview WHERE household_id=$1 AND actor_id=$2',[ctx.householdId,ctx.member.member_id])).rows[0].n<100,'tracking_preview_limit');
 await ctx.db.query(`INSERT INTO ritc.shared_tracking_preview(household_id,shop_id,preview_id,operation_id,actor_id,device_id,authority_epoch,shop_revision,intent,candidate_digest,created_at,expires_at)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,[ctx.householdId,shop.shop_id,candidateId,operationId,ctx.member.member_id,ctx.deviceId,shop.authority_epoch,shop.revision,intent,candidateDigest,created,expires]);
 return{schemaVersion:2,candidateId,candidateDigest,expiresAt:expires.toISOString(),action:value.action,after:value.state,disclosure:value.disclosure};
}
async function previewRow(ctx:Context,shopId:string,previewId:string){const p=(await ctx.db.query('SELECT * FROM ritc.shared_tracking_preview WHERE household_id=$1 AND shop_id=$2 AND preview_id=$3 AND actor_id=$4 AND device_id=$5 AND expires_at>$6',[ctx.householdId,shopId,previewId,ctx.member.member_id,ctx.deviceId,ctx.now])).rows[0];check(p,'tracking_preview_expired');return p;}
async function recompute(repo:HouseholdRepository,ctx:Context,shop:Shop,p:any){check(p.shop_revision===shop.revision&&p.authority_epoch===shop.authority_epoch,'tracking_stale_state');const intent=trackingIntentSchema.parse(p.intent),value=await evaluate(repo,ctx,shop,intent,p.operation_id,p.created_at.toISOString());check(digest({intent,operationId:p.operation_id,createdAt:p.created_at.toISOString(),value})===p.candidate_digest,'tracking_candidate_changed');return{intent,value};}
export async function acceptTrackingCandidate(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown){enabled(repo);repo.requireShopper(ctx,shop);const input=acceptSchema.parse(raw),p=await previewRow(ctx,shop.shop_id,input.candidateId);check(p.candidate_digest===input.candidateDigest&&!p.accepted_digest,'tracking_candidate_changed');const {value}=await recompute(repo,ctx,shop,p);
 check(same(input.acknowledgedDisclosure,value.disclosure),'tracking_disclosure_changed');
 const review=recordTrackingReview(value.state,value.disclosure.pickup,{...basis(ctx,shop,value.state),reviewId:randomUUID(),actorId:ctx.member.member_id,deviceId:ctx.deviceId,shopRevision:shop.revision+1,now:ctx.now.toISOString(),expiresAt:p.expires_at.toISOString()});
 const acceptedDigest=digest({candidateDigest:p.candidate_digest,review});
 await ctx.db.query('UPDATE ritc.shared_tracking_preview SET accepted_digest=$3,review=$4 WHERE household_id=$1 AND preview_id=$2 AND accepted_digest IS NULL',[ctx.householdId,p.preview_id,acceptedDigest,review]);
 return{schemaVersion:2,previewId:p.preview_id,previewDigest:acceptedDigest,trackingVersion:2,expiresAt:p.expires_at.toISOString(),action:value.action,disclosure:value.disclosure};
}
export async function trackingOperation(ctx:Context,shopId:string,raw:unknown){const t=token.parse(raw),p=await previewRow(ctx,shopId,t.previewId);check(p.accepted_digest===t.previewDigest&&p.review,'tracking_preview_not_reviewed');return p.operation_id as string;}
export async function stageV1Tracking(repo:HouseholdRepository,ctx:Context,shop:Shop,input:{mode:string;action:{kind:string;body:Record<string,unknown>};packs:TrackingState['packReviews']},reviewed:{result:{graph:TrackingState['graph']};facts:Awaited<ReturnType<typeof actionFacts>>},operationId:string){
 if(!repo.options.trackingV2||shop.store_review_required||input.action.body.reviewedStoreBasisRevision!==undefined||shop.demand_revision||input.mode!=='adopt'||input.action.kind!=='shop.patch'||input.action.body.mealEdit||!same(reviewed.facts.quote,shop.quote))return;
 const before=(await stateNow(repo,ctx,shop)).state!;const graph=reviewed.result.graph,catalog=await trackingCatalog(repo,ctx,shop,reviewed.facts,graph);
 const state=validateState({...before,graph,basket:basket(reviewed.facts.lines),catalog,...partition(graph,catalog,null,[]),legacyLineIds:[],packReviews:input.packs},catalog);
 const adoption=recordFirstAdoption(operationId,before,state),storeBasis=await storeProof(ctx,shop);
 if(!staged.has(ctx))staged.set(ctx,new Map());staged.get(ctx)!.set(shop.shop_id,{state,adoption,review:null,storeBasis,reverses:null});
}
type Stage={state:TrackingState;adoption:ReturnType<typeof recordFirstAdoption>|null;review:any;storeBasis:unknown;reverses:string|null};
const staged=new WeakMap<Context,Map<string,Stage>>();
export async function applyTracking(repo:HouseholdRepository,ctx:Context,shop:Shop,c:Envelope,operationId:string){enabled(repo);const t=token.parse(c.body.demandReview),p=await previewRow(ctx,shop.shop_id,t.previewId);check(p.operation_id===operationId&&p.accepted_digest===t.previewDigest&&p.review&&p.accepted_digest===digest({candidateDigest:p.candidate_digest,review:p.review}),'tracking_preview_not_reviewed');
 const {intent,value}=await recompute(repo,ctx,shop,p),{demandReview,...body}=c.body;check(c.kind===value.action.kind&&same(body,value.action.body),'tracking_action_changed');
 check(same(p.review.review.disclosure,value.disclosure.pickup),'tracking_disclosure_changed');const graph=value.state.graph;
 const receipt=value.graphReceipt??{schemaVersion:2,operationId,baseRevision:graph.revision-1,resultRevision:graph.revision,tracking:true};
 if(value.graphReceipt&&(intent.mode==='adopt'||intent.mode==='change'||intent.mode==='review'))await recordFoodOperationEffect(ctx,shop,{mode:intent.mode,base:{shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,graphRevision:graph.revision-1},action:value.action,change:intent.mode==='review'?{lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[]}:intent.change,packs:value.state.packReviews},operationId,graph.revision-1,graph.revision);
 await ctx.db.query(`INSERT INTO ritc.shared_demand_revision(household_id,shop_id,revision,predecessor,shop_revision,authority_epoch,operation_id,actor_id,device_id,created_at,graph,graph_digest,receipt,pack_review)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,[ctx.householdId,shop.shop_id,graph.revision,graph.revision===1?null:graph.revision-1,shop.revision+1,shop.authority_epoch,operationId,ctx.member.member_id,ctx.deviceId,ctx.now,graph,storeDigest(graph),receipt,JSON.stringify(value.state.packReviews)]);
 await rememberSources(ctx,shop,value.before?.graph??value.projection!.state.graph,graph,(value.action.body.mealEdit as any)?.changeProposalId??null);
 await ctx.db.query('UPDATE ritc.shop SET demand_revision=$3,demand_review_required=false WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id,graph.revision]);
 if(!staged.has(ctx))staged.set(ctx,new Map());staged.get(ctx)!.set(shop.shop_id,{state:value.state,adoption:value.adoption,review:p.review,storeBasis:value.storeBasis,reverses:intent.mode==='firstAdoptionUndo'?intent.targetOperationId:null});
 await ctx.db.query('DELETE FROM ritc.shared_tracking_preview WHERE household_id=$1 AND preview_id=$2',[ctx.householdId,p.preview_id]);
}
/** A completed v1 write can advance an already-proved complete envelope. It never
 * manufactures first-adoption evidence for an old graph. */
export async function captureTrackingSnapshot(repo:HouseholdRepository,ctx:Context,shop:Shop,operationId:string){
 const pending=staged.get(ctx)?.get(shop.shop_id),previous=await trackingRow(ctx,shop);if(!pending&&!previous)return undefined;
 if(previous?.shop_revision===shop.revision)return{schemaVersion:2,shopRevision:shop.revision,digest:previous.state_digest,status:previous.projection?'reviewRequired':'recorded'};
 if(previous?.projection&&!pending)return{schemaVersion:2,shopRevision:previous.shop_revision,digest:null,status:'reviewRequired'};
 let state=pending?.state;
 if(!state){const graph=(await loadDemand(ctx,shop))!.graph,catalog=await trackingCatalog(repo,ctx,shop,undefined,graph),actualBasket=basket(await repo.lines(ctx,shop.shop_id));const old=validateState(previous.state,previous.state.catalog);
  // Preserve exact transfer evidence; current catalog must still authenticate it.
  const packRow=(await ctx.db.query('SELECT pack_review FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,graph.revision])).rows[0];
  state=validateState({...old,graph,catalog,basket:actualBasket,quoteDigest:storeDigest(shop.quote),authorityEpoch:shop.authority_epoch,privacyRevision:await privacyRevision(ctx,shop),...partition(graph,catalog,old,old.unbound.map(u=>u.factId)),legacyLineIds:actualBasket.filter(l=>!graph.lines.some(g=>g.id===l.id&&g.trashedAt===null)).map(l=>l.id),packReviews:packRow.pack_review},catalog);
 }
 const actualGraph=(await loadDemand(ctx,shop))!.graph,catalog=await trackingCatalog(repo,ctx,shop,undefined,catalogGraph({...state,graph:actualGraph}));validateState(state,catalog);
 check(same(state.graph,actualGraph)&&same(state.basket,basket(await repo.lines(ctx,shop.shop_id)))&&state.quoteDigest===storeDigest(shop.quote),'tracking_commit_mismatch');
 await ctx.db.query(`INSERT INTO ritc.shared_tracking_revision(household_id,shop_id,shop_revision,graph_revision,authority_epoch,privacy_revision,operation_id,actor_id,device_id,state,state_digest,review,reverses_operation_id)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,[ctx.householdId,shop.shop_id,shop.revision,state.graph.revision,shop.authority_epoch,state.privacyRevision,operationId,ctx.member.member_id,ctx.deviceId,state,digest(state),pending?.review??null,pending?.reverses??null]);
 if(pending?.adoption)await ctx.db.query('INSERT INTO ritc.shared_tracking_adoption(household_id,shop_id,operation_id,authority_epoch,evidence,evidence_digest,store_basis) VALUES($1,$2,$3,$4,$5,$6,$7)',[ctx.householdId,shop.shop_id,operationId,shop.authority_epoch,pending.adoption.evidence,pending.adoption.evidenceDigest,pending.storeBasis]);
 await rememberTrackingCatalog(ctx,shop,state);staged.get(ctx)?.delete(shop.shop_id);
 return{schemaVersion:2,shopRevision:shop.revision,digest:digest(state),status:'recorded'};
}
async function rememberTrackingCatalog(ctx:Context,shop:Shop,state:TrackingState){
 // Independent of graph membership: catalog origins survive a representation transfer.
 const requests=state.catalog.flatMap(f=>f.source.kind==='request'?[f.source.requestId]:[]),occurrences=state.catalog.flatMap(f=>f.source.kind==='meal'?[f.source.occurrenceId]:f.source.kind==='reservation'&&f.source.originOccurrenceId?[f.source.originOccurrenceId]:[]);
 const authors=(await ctx.db.query(`SELECT request_id AS id,author_id AS member,'request' AS kind FROM ritc.request WHERE household_id=$1 AND shop_id=$2 AND request_id=ANY($3::uuid[])
 UNION SELECT occurrence_id,actor_id,'meal' FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=ANY($4::uuid[])
 UNION SELECT occurrence_id,actor_id,'meal' FROM ritc.shared_meal_change WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=ANY($4::uuid[]) AND state='applied'`,[ctx.householdId,shop.shop_id,requests,occurrences])).rows;
 const origins=state.catalog.flatMap(f=>{const origin=f.source.kind==='request'?f.source.requestId:f.source.kind==='meal'?f.source.occurrenceId:f.source.kind==='reservation'?f.source.originOccurrenceId:null;return authors.filter(a=>a.id===origin).map(a=>({fact:f.id,member:a.member}));});
 if(origins.length)await ctx.db.query(`INSERT INTO ritc.shared_tracking_source_member(household_id,shop_id,fact_id,member_id) SELECT $1,$2,(e->>'fact')::uuid,(e->>'member')::uuid FROM jsonb_array_elements($3::jsonb) e ON CONFLICT DO NOTHING`,[ctx.householdId,shop.shop_id,JSON.stringify(origins)]);
}
export async function assertTrackingReplay(repo:HouseholdRepository,ctx:Context,shop:Shop,operationId:string){const r=(await ctx.db.query('SELECT * FROM ritc.shared_tracking_revision WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,operationId])).rows[0];if(!r)return;
 check(r.state&&r.state_digest===digest(r.state)&&!r.projection&&r.authority_epoch===shop.authority_epoch&&r.privacy_revision===await privacyRevision(ctx,shop),'tracking_replay_unavailable');
 const memberIDs=(await ctx.db.query(`SELECT DISTINCT member_id FROM ritc.shared_tracking_source_member WHERE household_id=$1 AND shop_id=$2 AND fact_id=ANY($3::uuid[])
 UNION SELECT DISTINCT member_id FROM ritc.shared_demand_source_member WHERE household_id=$1 AND shop_id=$2 AND entity_id=ANY($4::uuid[])`,[ctx.householdId,shop.shop_id,r.state.catalog.map((f:Fact)=>f.id),r.state.graph.contributions.map((c:{id:string})=>c.id)])).rows.map(x=>x.member_id);
 const authors=(await ctx.db.query<Member>('SELECT * FROM ritc.member WHERE household_id=$1 AND member_id=ANY($2::uuid[])',[ctx.householdId,memberIDs])).rows;check(authors.length===memberIDs.length&&authors.every(m=>m.state==='active'),'tracking_source_unavailable');for(const m of authors)await repo.consent(ctx.db,ctx.householdId,m);
 if(r.reverses_operation_id){const old=(await ctx.db.query('SELECT evidence,evidence_digest,store_basis FROM ritc.shared_tracking_adoption WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,r.reverses_operation_id])).rows[0];check(old?.evidence&&old.evidence_digest===digest(old.evidence),'tracking_history_unavailable');
 // Exact retry returns the original receipt after later store changes, but still
 // requires the original store permission. It does not reapply the inverse.
 if(old.store_basis){const live=await liveFoodUndoStoreBasis(ctx,shop,old.store_basis.revision);check(same(live,old.store_basis),'tracking_store_permission');}}
}
const frozenTracking=new WeakMap<Context,Map<string,ReturnType<typeof sealReviewedTracking>>>();
export async function prepareTrackingFreeze(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown){const row=await trackingRow(ctx,shop);if(!row)return;const current=await stateNow(repo,ctx,shop);check(current.state&&!current.projection,'tracking_review_required');
 // Fully tracked legacy callers retain the original freeze policy.
 if(raw===undefined&&current.state.unbound.length===0&&current.state.legacyLineIds.length===0&&row.authority_epoch===shop.authority_epoch&&row.state_digest===digest(current.state))return;
 enabled(repo);check(raw!==undefined,'tracking_review_required');const t=token.parse(raw);check(row.review&&row.review.review.reviewId===t.previewId&&row.review.reviewDigest===t.previewDigest,'tracking_review_required');
 const sealed=sealReviewedTracking(current.state,row.review.review,{...basis(ctx,shop,current.state),actorId:ctx.member.member_id,deviceId:ctx.deviceId,baseShopRevision:shop.revision,frozenRevision:shop.revision+1,reviewDigest:t.previewDigest,now:ctx.now.toISOString()});
 if(!frozenTracking.has(ctx))frozenTracking.set(ctx,new Map());frozenTracking.get(ctx)!.set(shop.shop_id,sealed);
}
export function takeTrackingSeal(ctx:Context,shopId:string){const value=frozenTracking.get(ctx)?.get(shopId);frozenTracking.get(ctx)?.delete(shopId);return value;}
export async function assertTrackingPlacement(repo:HouseholdRepository,ctx:Context,shop:Shop,snapshotRevision:number){const row=await trackingRow(ctx,shop);if(!row)return;const current=await stateNow(repo,ctx,shop);check(current.state&&!current.projection,'tracking_review_required');
 check(row.authority_epoch===shop.authority_epoch&&row.state_digest===digest(current.state),'tracking_snapshot_stale');
 const saved=(await ctx.db.query('SELECT snapshot,digest FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,snapshotRevision])).rows[0];check(saved?.snapshot?.tracking&&saved.digest===storeDigest(saved.snapshot)&&saved.snapshot.tracking.digest===digest(current.state),'tracking_snapshot_stale');
 if(current.state.unbound.length===0&&current.state.legacyLineIds.length===0)return;
 check(saved.snapshot.trackingSeal,'tracking_snapshot_unreviewed');const seal=saved.snapshot.trackingSeal;verifyTrackingPlacement(seal.snapshot,current.state,{...basis(ctx,shop,current.state),frozenRevision:snapshotRevision,storedSnapshotDigest:seal.snapshotDigest});
}
export async function readTrackingRecord(repo:HouseholdRepository,ctx:Context,shop:Shop){enabled(repo);repo.requireShopper(ctx,shop);const page=await readTracking(repo,ctx,shop),record={schemaVersion:2,projection:'assigned-shopper-tracking-record-v2',shopId:shop.shop_id,shopRevision:shop.revision,phase:shop.phase,quote:shop.quote,basket:await repo.lines(ctx,shop.shop_id),meals:await repo.meals(ctx,shop.shop_id),food:page,portableExportAllowed:false};bounded(record);return{record,recordDigest:digest(record),asOf:ctx.now.toISOString()};}

/** Content-free lineage listing; candidate creation rechecks every live fact. */
export async function readTrackingHistory(repo:HouseholdRepository,ctx:Context,shop:Shop){
 enabled(repo);repo.requireShopper(ctx,shop);repo.requireDraft(shop);
 const rows=(await ctx.db.query(`SELECT a.operation_id,o.committed_at,t.shop_revision,a.evidence IS NOT NULL AS retained,
 EXISTS(SELECT 1 FROM ritc.shared_tracking_revision u WHERE u.household_id=a.household_id AND u.reverses_operation_id=a.operation_id) AS reversed
 FROM ritc.shared_tracking_adoption a JOIN ritc.operation o
 ON o.household_id=a.household_id AND o.shop_id=a.shop_id AND o.operation_id=a.operation_id
 JOIN ritc.shared_tracking_revision t
 ON t.household_id=a.household_id AND t.shop_id=a.shop_id AND t.operation_id=a.operation_id
 WHERE a.household_id=$1 AND a.shop_id=$2 ORDER BY t.shop_revision DESC LIMIT 100`,[ctx.householdId,shop.shop_id])).rows;
 return{schemaVersion:2,shopId:shop.shop_id,shopRevision:shop.revision,items:rows.map(r=>({operationId:r.operation_id,shopRevision:r.shop_revision,committedAt:r.committed_at.toISOString(),status:r.retained&&!r.reversed?'current_preview_required':'unavailable'}))};
}
