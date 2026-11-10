import {assertTrackingV1,applyTracking,trackingOperation,assertTrackingReplay,stageV1Tracking} from './shared-demand-tracking-repository.js';
import {deriveSharedFoodUndo,assertSharedFoodUndoReplay,foodUndoFailure,type FoodUndoEvidence,type FoodUndoStoreBasis} from './shared-food-operation-undo.js';
import {recordMealUndoEffect,loadMealUndoEvidence} from './shared-food-meal-undo.js';
import {randomUUID} from 'node:crypto';
import {actionDemandSources} from './shared-demand-action-sources.js';
import {requireSharedMealChange} from './shared-meal-changes.js';
import {requireMealMove} from './meal-moves.js';
import {z} from 'zod';
import type {Context,HouseholdRepository,Shop,Member} from './repository.js';
import {bodySchemas,decisionSchema,type Envelope} from './contracts.js';
import {digest} from './database.js';
import {ServiceError,refresh,unavailable} from './errors.js';
import {checkout} from './checkout.js';
import {sharedDemandChangeSchema,demandQuantitySchema,demandReviewSchema,type DemandGraph,type DemandContribution} from './shared-demand-contracts.js';
import {SharedDemandError,applyDemandChange,undoDemandChange,validateDemandGraph,demandLineTotals,convertDemandQuantity} from './shared-demand-domain.js';
import {sharedMealSchema,preserveProtectedMeal} from './shared-meal-planning.js';
import {mealDemandSources,mealSourceKey,exactSourceExclusions,requestDemandSource} from './shared-demand-sources.js';
const id=z.string().uuid().transform(s=>s.toLowerCase());
const delta=sharedDemandChangeSchema.omit({schemaVersion:true,operationId:true,householdId:true,shopId:true,baseRevision:true,at:true});
const pack=z.object({lineId:id,usablePerPack:demandQuantitySchema.nullable(),acceptUnresolved:z.boolean()}).strict();
const baseSchema=z.object({shopRevision:z.number().int().positive(),authorityEpoch:z.number().int().positive(),graphRevision:z.number().int().min(0)}).strict();
export const demandActionSourcesInputSchema=z.object({base:baseSchema.extend({graphRevision:z.number().int().positive(),graphDigest:z.string().regex(/^[0-9a-f]{64}$/)}),action:z.object({kind:z.literal('shop.patch'),body:bodySchemas['shop.patch']}).strict()}).strict()
 .refine(v=>v.action.body.mealEdit!==undefined&&v.action.body.demandReview===undefined,'Review one meal edit without a nested demand review.');
const inputSchema=z.object({mode:z.enum(['adopt','change','undo','review','operationUndo']),base:baseSchema,
 change:delta,undoOperationId:id.optional(),operationUndoDigest:z.string().regex(/^[0-9a-f]{64}$/).optional(),action:z.object({kind:z.enum(['shop.patch','request.apply']),body:z.record(z.string(),z.unknown())}).strict(),packs:z.array(pack).max(200)}).strict();
type Input=z.infer<typeof inputSchema>;
const fail=(code='demand_review_required')=>new ServiceError(409,code,'Review the current shared quantities and exact source changes.');
function assert(value:unknown,code?:string):asserts value{if(!value)throw fail(code);}
function noChanges(c:Input['change']){return c.lines.length+c.contributions.length+c.edges.length+c.removeEdgeIds.length+c.removeSourceIds.length+(c.quantifyReservationIds?.length??0)+(c.clarifyReservationProductIds?.length??0)===0;}
export async function loadDemand(ctx:Context,shop:Shop):Promise<{graph:DemandGraph;fingerprint:string;receipt:unknown}|null>{
 if(!shop.demand_revision)return null;
 const row=(await ctx.db.query('SELECT graph,graph_digest,receipt FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,shop.demand_revision])).rows[0];
 if(!row)throw refresh();const graph=validateDemandGraph(row.graph);
 assert(graph.householdId===ctx.householdId&&graph.shopId===shop.shop_id&&graph.revision===shop.demand_revision,'demand_identity');
 if(row.graph_digest!==null)assert(row.graph_digest===digest(graph),'demand_integrity');
 return {graph,fingerprint:digest(graph),receipt:row.receipt};
}
export async function readDemand(repo:HouseholdRepository,ctx:Context,shop:Shop){
 repo.requireShopper(ctx,shop);await assertTrackingV1(repo,ctx,shop);const current=await loadDemand(ctx,shop);
 let legacySources=null;
 if(!current){
  const links=(await ctx.db.query(`SELECT l.request_id,l.line_id,l.reviewed_revision,r.original_item,r.own_quantity,r.author_id
   FROM ritc.request_link l JOIN ritc.request r ON (r.household_id,r.shop_id,r.request_id)=(l.household_id,l.shop_id,l.request_id)
   WHERE l.household_id=$1 AND l.shop_id=$2 ORDER BY l.request_id`,[ctx.householdId,shop.shop_id])).rows;
  const authors=(await ctx.db.query<Member>('SELECT * FROM ritc.member WHERE household_id=$1 AND member_id=ANY($2::uuid[])',[ctx.householdId,[...new Set(links.map(r=>r.author_id))]])).rows;
  const liveAuthors=new Set<string>();for(const author of authors){assert(author.state==='active','demand_source_unavailable');await repo.consent(ctx.db,ctx.householdId,author);liveAuthors.add(author.member_id);}
  assert(links.every(r=>liveAuthors.has(r.author_id)),'demand_source_unavailable');
  legacySources={sources:[...mealDemandSources(shop.shop_id,await repo.meals(ctx,shop.shop_id)),...links.map(r=>requestDemandSource(shop.shop_id,r))]};
 }
 return {schemaVersion:1,shopId:shop.shop_id,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,status:current?(shop.demand_review_required?'reviewRequired':'enabled'):'legacy',graph:current?.graph??null,graphDigest:current&&!shop.demand_review_required?current.fingerprint:null,totals:current?demandLineTotals(current.graph):[],legacySources};
}
export async function demandSnapshotRef(ctx:Context,shop:Shop,allowReviewRequired=false){
 if(!shop.demand_revision)return undefined;const row=(await ctx.db.query('SELECT graph_digest FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,shop.demand_revision])).rows[0];
 assert(row,'demand_identity');
 if(shop.demand_review_required&&allowReviewRequired)return {schemaVersion:1,revision:shop.demand_revision,digest:null,status:'reviewRequired' as const};
 assert(row.graph_digest&&!shop.demand_review_required);return {schemaVersion:1,revision:shop.demand_revision,digest:row.graph_digest};
}
/** A dated snapshot cannot regain placement authority after its source is erased. */
export async function assertDemandPlacement(ctx:Context,shop:Shop,snapshotRevision:number){
 if(!shop.demand_revision)return;
 assert(!shop.demand_review_required,'demand_review_required');
 const row=(await ctx.db.query('SELECT snapshot,digest FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,snapshotRevision])).rows[0];
 const ref=row?.snapshot?.demand;assert(row&&row.digest===digest(row.snapshot)&&ref?.schemaVersion===1&&typeof ref.digest==='string'&&ref.status!=='reviewRequired','demand_review_required');
 const accepted=(await ctx.db.query('SELECT graph_digest FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,ref.revision])).rows[0];
 assert(accepted?.graph_digest&&accepted.graph_digest===ref.digest,'demand_review_required');
}
function quantityMatches(actual:DemandContribution['quantity'],expected:any){
 if(expected===null)return actual===null;if(!actual)return false;
 return actual.unit===expected.unit&&BigInt(actual.amount.numerator)*BigInt(expected.amount.denominator)===BigInt(expected.amount.numerator)*BigInt(actual.amount.denominator);
}
export async function actionFacts(repo:HouseholdRepository,ctx:Context,shop:Shop,input:Pick<Input,'action'>){
 const meals=await repo.meals(ctx,shop.shop_id);let request:any=null;let body:any,lines:any[],quote=shop.quote;
 if(input.action.kind==='shop.patch'){
  assert(!('demandReview' in input.action.body),'nested_demand_review');body=bodySchemas['shop.patch'].parse(input.action.body);lines=body.lines;quote=body.quote;
  if(body.mealEdit){const e=body.mealEdit,old=meals.find(m=>m.occurrenceId===e.occurrenceId);assert((old?.revision??null)===e.baseMealRevision,'stale_meal');preserveProtectedMeal(old?sharedMealSchema.parse(old.meal):undefined,e.meal);
   assert(old||e.meal,'stale_meal');assert(old||meals.length<100,'meal_limit');
   if(e.changeProposalId)await requireSharedMealChange(ctx,shop,e.changeProposalId,e.occurrenceId,e.baseMealRevision,e.meal);
   if(e.proposalId)await requireMealMove(ctx,shop,e.proposalId,e.occurrenceId,old?sharedMealSchema.parse(old.meal):undefined,e.meal);
   const index=meals.findIndex(m=>m.occurrenceId===e.occurrenceId);if(index>=0)meals.splice(index,1);if(e.meal)meals.push({occurrenceId:e.occurrenceId,revision:shop.revision+1,meal:e.meal});}
 }else{
  assert(!('demandReview' in input.action.body),'nested_demand_review');body=bodySchemas['request.apply'].parse(input.action.body);
  const preview=(await ctx.db.query('SELECT * FROM ritc.preview WHERE household_id=$1 AND shop_id=$2 AND preview_id=$3 AND actor_id=$4 AND request_id=$5',[ctx.householdId,shop.shop_id,body.previewId,ctx.member.member_id,body.requestId])).rows[0];
  assert(preview&&preview.expires_at>ctx.now&&preview.shop_revision===shop.revision&&preview.authority_epoch===shop.authority_epoch,'stale_preview');
  request=(await ctx.db.query('SELECT * FROM ritc.request WHERE household_id=$1 AND shop_id=$2 AND request_id=$3',[ctx.householdId,shop.shop_id,body.requestId])).rows[0];assert(request&&request.revision===preview.request_revision,'stale_preview');
  const decision=decisionSchema.parse(preview.decision);assert(decision.choice==='add'||decision.choice==='link','demand_request_choice');
  lines=await repo.lines(ctx,shop.shop_id);if(decision.choice==='add')lines.push(decision.line);
  request={...request,targetLine:decision.choice==='add'?decision.line.lineId:decision.lineId};
 }
 checkout(lines,quote);return {body,lines,quote,meals,request};
}
export async function verifySources(repo:HouseholdRepository,ctx:Context,shop:Shop,graph:DemandGraph,facts:Awaited<ReturnType<typeof actionFacts>>,retiring?:{requestId:string;operationId:string;lineId:string;reviewedRevision:number}){
 const active=graph.contributions.filter(c=>c.removedAt===null),expected=new Set<string>();
 const wholeProtected=new Set(active.flatMap(c=>c.source.kind==='reservation'&&c.source.originOccurrenceId&&c.source.groupId===null&&c.source.bindingId===null?[c.source.originOccurrenceId+'/'+c.source.ingredientId]:[]));
 // The same authoritative enumeration supplies adoption and validates committed sources.
 for(const source of mealDemandSources(shop.shop_id,facts.meals,wholeProtected)){
  const rows=active.filter(c=>mealSourceKey(c.source)===mealSourceKey(source.source));
  const unknownProtected=source.source.kind==='reservation'&&source.source.groupId!==null&&source.source.bindingId===null&&source.quantity===null;
  assert(rows.length===1&&quantityMatches(rows[0]!.quantity,source.quantity),unknownProtected?'demand_protected_unknown_required':'demand_meal_mismatch');
  assert(exactSourceExclusions(rows[0]!.sourceExclusions??[],source.sourceExclusions),'demand_exclusion_mapping_required');
  expected.add(rows[0]!.id);
 }
 const requestIds=active.flatMap(c=>c.source.kind==='request'?[c.source.requestId]:[]);
 const requests=new Map((await ctx.db.query('SELECT * FROM ritc.request WHERE household_id=$1 AND shop_id=$2 AND request_id=ANY($3::uuid[])',[ctx.householdId,shop.shop_id,requestIds])).rows.map(r=>[r.request_id,r]));
 let links=(await ctx.db.query('SELECT request_id,line_id,reviewed_revision,operation_id FROM ritc.request_link WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id])).rows;
 if(retiring){const exact=links.find(x=>x.request_id===retiring.requestId);assert(exact&&exact.operation_id===retiring.operationId&&exact.line_id===retiring.lineId&&exact.reviewed_revision===retiring.reviewedRevision,'demand_request_mismatch');links=links.filter(x=>x.request_id!==retiring.requestId);}
 const acceptedRequests=new Map(links.map(r=>[r.request_id,r]));
 const authors=(await ctx.db.query<Member>('SELECT * FROM ritc.member WHERE household_id=$1 AND member_id=ANY($2::uuid[])',[ctx.householdId,[...new Set([...requests.values()].map(r=>r.author_id))]])).rows;
 const liveAuthors=new Set<string>();for(const author of authors){assert(author.state==='active','demand_source_unavailable');await repo.consent(ctx.db,ctx.householdId,author);liveAuthors.add(author.member_id);}
 for(const c of active){
  if(c.source.kind==='meal'||c.source.kind==='reservation')assert(expected.has(c.id),'demand_meal_mismatch');
  if(c.source.kind==='request'){
   const r=requests.get(c.source.requestId),accepted=acceptedRequests.get(c.source.requestId);assert(r&&c.originalText===r.original_item&&liveAuthors.has(r.author_id),'demand_request_mismatch');
   assert(facts.request?.request_id===c.source.requestId?c.lineId===facts.request.targetLine&&c.source.appliedRequestRevision===r.revision:accepted&&accepted.line_id===c.lineId&&accepted.reviewed_revision===c.source.appliedRequestRevision,'demand_request_mismatch');
  }
 }
 if(facts.request)assert(active.filter(c=>c.source.kind==='request'&&c.source.requestId===facts.request.request_id).length===1,'demand_request_mismatch');
 for(const r of links)assert(requestIds.includes(r.request_id),'demand_request_mismatch');
}
export function verifyPacks(graph:DemandGraph,facts:Awaited<ReturnType<typeof actionFacts>>,packs:Input['packs']){
 const totals=new Map(demandLineTotals(graph).map(total=>[total.lineId,total]));
 assert(new Set(packs.map(p=>p.lineId)).size===packs.length&&packs.length===facts.lines.length&&totals.size===facts.lines.length,'demand_basket_mismatch');
 for(const basket of facts.lines){const line=graph.lines.find(l=>l.id===basket.lineId),total=totals.get(basket.lineId),review=packs.find(p=>p.lineId===basket.lineId);assert(line&&total&&review,'demand_basket_mismatch');
  assert(line.name===basket.originalItem,'demand_basket_mismatch');const unresolvedExclusions=graph.contributions.some(c=>c.lineId===line.id&&c.removedAt===null&&c.sourceExclusions?.some(e=>e.resolution.kind==='unresolved'));
  const need=total.quantity,usable=review.usablePerPack&&convertDemandQuantity(review.usablePerPack,line.unit);
  if(unresolvedExclusions)assert(review.acceptUnresolved,'demand_unknown_acceptance');
  if(!need||!usable){assert(review.acceptUnresolved,'demand_unknown_acceptance');continue;}
  assert(usable.n*BigInt(basket.packs)*BigInt(need.denominator)>=BigInt(need.numerator)*usable.d,'demand_insufficient_packs');
 }
}
async function evaluate(repo:HouseholdRepository,ctx:Context,shop:Shop,input:Input,operationId:string,at:string){
 repo.requireShopper(ctx,shop);repo.requireDraft(shop);await assertTrackingV1(repo,ctx,shop);repo.checkBase(shop,input.base);const current=await loadDemand(ctx,shop);
 assert((current?.graph.revision??0)===input.base.graphRevision,'stale_demand');assert((input.mode==='adopt')===!current,'demand_adoption_required');
 const before=current?.graph??{schemaVersion:1 as const,conversionTableVersion:'us-customary-metric-v1' as const,householdId:ctx.householdId,shopId:shop.shop_id,revision:0,lines:[],contributions:[],edges:[],usedIds:[]};
 const command={...input.change,schemaVersion:1,operationId,householdId:ctx.householdId,shopId:shop.shop_id,baseRevision:before.revision,at};
 let result;
 if(input.mode==='operationUndo'){
  assert(input.undoOperationId&&noChanges(input.change),'invalid_operation_undo');
  const inverse=await operationInverse(repo,ctx,shop,input.undoOperationId,before,operationId,at);
  assert(input.action.kind==='shop.patch'&&digest(input.action)===digest(inverse.action)&&input.operationUndoDigest===inverse.effectDigest,'demand_action_changed');
  result=inverse.result;
 }else if(input.mode==='undo'){
  assert(input.undoOperationId&&noChanges(input.change),'invalid_demand_undo');const old=(await ctx.db.query('SELECT receipt FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,input.undoOperationId])).rows[0];assert(old?.receipt?.schemaVersion===1,'demand_undo_unavailable');result=undoDemandChange(before,old.receipt,command);
 }else if(input.mode==='review'){
  assert(noChanges(input.change)&&!input.undoOperationId,'invalid_demand_review');result={graph:validateDemandGraph({...before,revision:before.revision+1}),receipt:{schemaVersion:1,operationId,householdId:ctx.householdId,shopId:shop.shop_id,baseRevision:before.revision,resultRevision:before.revision+1,lines:[],contributions:[],edges:[]}};
 }else {assert(!input.undoOperationId,'invalid_demand_change');result=applyDemandChange(before,command);}
 const facts=await actionFacts(repo,ctx,shop,input);await verifySources(repo,ctx,shop,result.graph,facts);verifyPacks(result.graph,facts,input.packs);
 return {before,result,facts,baseDigest:current?.fingerprint??digest(before),acceptedDigest:digest({input,operationId,at,graph:result.graph,receipt:result.receipt,lines:facts.lines,quote:facts.quote,meals:facts.meals,requestRevision:facts.request?.revision??null})};
}
/** Informational, read-only facts. Existing preview/apply revalidate all authority and source rules. */
export async function readActionDemandSources(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown){
 repo.requireShopper(ctx,shop);repo.requireDraft(shop);await assertTrackingV1(repo,ctx,shop);
 const input=demandActionSourcesInputSchema.parse(raw);repo.checkBase(shop,input.base);
 const current=await loadDemand(ctx,shop);assert(current&&!shop.demand_review_required,'demand_enabled_required');
 assert(current.graph.revision===input.base.graphRevision&&current.fingerprint===input.base.graphDigest,'stale_demand');
 const facts=await actionFacts(repo,ctx,shop,input);
 const catalog=actionDemandSources(shop.shop_id,facts.meals,current.graph);
 const normalizedAction={kind:'shop.patch' as const,body:bodySchemas['shop.patch'].parse(facts.body)};
 const response={schemaVersion:1 as const,shopId:shop.shop_id,base:input.base,graphDigest:current?.fingerprint??null,
  normalizedAction,actionDigest:digest(normalizedAction),...catalog};
 assert(Buffer.byteLength(JSON.stringify(response),'utf8')<=1_800_000,'demand_source_limit');
 return response;
}
export type DemandActionSourcesResponse=Awaited<ReturnType<typeof readActionDemandSources>>;
export async function previewDemand(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown){
 const input=inputSchema.parse(raw);assert(input.mode!=='operationUndo'&&input.operationUndoDigest===undefined,'operation_undo_endpoint_required');
 return previewDemandInput(repo,ctx,shop,input);
}
async function previewDemandInput(repo:HouseholdRepository,ctx:Context,shop:Shop,input:Input){input.action.body=bodySchemas[input.action.kind].parse(input.action.body);
 const operationId=randomUUID(),at=ctx.now.toISOString(),reviewed=await evaluate(repo,ctx,shop,input,operationId,at),previewId=randomUUID(),expiresAt=new Date(ctx.now.getTime()+600000);
 await ctx.db.query('DELETE FROM ritc.shared_demand_preview WHERE household_id=$1 AND expires_at<=$2',[ctx.householdId,ctx.now]);
 const count=(await ctx.db.query('SELECT count(*)::integer AS n FROM ritc.shared_demand_preview WHERE household_id=$1 AND actor_id=$2',[ctx.householdId,ctx.member.member_id])).rows[0].n;assert(count<100,'demand_preview_limit');
 await ctx.db.query(`INSERT INTO ritc.shared_demand_preview(household_id,shop_id,preview_id,operation_id,actor_id,device_id,authority_epoch,shop_revision,graph_revision,graph_digest,intent,accepted_digest,created_at,expires_at)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,[ctx.householdId,shop.shop_id,previewId,operationId,ctx.member.member_id,ctx.deviceId,shop.authority_epoch,shop.revision,reviewed.before.revision,reviewed.baseDigest,input,reviewed.acceptedDigest,ctx.now,expiresAt]);
 return {previewId,previewDigest:reviewed.acceptedDigest,expiresAt:expiresAt.toISOString(),before:reviewed.before,after:reviewed.result.graph,beforeTotals:demandLineTotals(reviewed.before),afterTotals:demandLineTotals(reviewed.result.graph),receipt:reviewed.result.receipt,packs:input.packs,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch};
}
async function boundPreview(ctx:Context,shopId:string,review:unknown){
 const b=demandReviewSchema.parse(review);assert(b.trackingVersion===undefined,'tracking_version_mismatch');const p=(await ctx.db.query('SELECT * FROM ritc.shared_demand_preview WHERE household_id=$1 AND shop_id=$2 AND preview_id=$3 AND actor_id=$4 AND device_id=$5 AND accepted_digest=$6 AND expires_at>$7',[ctx.householdId,shopId,b.previewId,ctx.member.member_id,ctx.deviceId,b.previewDigest,ctx.now])).rows[0];if(!p)throw refresh();return p;
}
export async function demandOperation(ctx:Context,c:Envelope){if((c.body.demandReview as any)?.trackingVersion===2)return trackingOperation(ctx,c.shopId,c.body.demandReview);return c.body.demandReview?(await boundPreview(ctx,c.shopId,c.body.demandReview)).operation_id as string:randomUUID();}
export async function assertDemandReplay(repo:HouseholdRepository,ctx:Context,shop:Shop,operationId:string){
 await assertTrackingReplay(repo,ctx,shop,operationId);
 const row=(await ctx.db.query('SELECT authority_epoch,receipt FROM ritc.shared_demand_revision WHERE household_id=$1 AND operation_id=$2',[ctx.householdId,operationId])).rows[0];if(row&&(!row.receipt||row.authority_epoch!==shop.authority_epoch))throw refresh();
 const inverse=(await ctx.db.query('SELECT reverses_operation_id FROM ritc.shared_food_operation_effect WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,operationId])).rows[0];
 if(inverse?.reverses_operation_id)assertSharedFoodUndoReplay(await foodUndoEvidence(ctx,shop,inverse.reverses_operation_id));
}
export async function rememberSources(ctx:Context,shop:Shop,before:DemandGraph,after:DemandGraph,acceptedProposalId:string|null){
 const changed:{kind:string;row:{id:string}}[]=[];
 for(const [kind,old,rows] of [['line',before.lines,after.lines],['contribution',before.contributions,after.contributions],['edge',before.edges,after.edges]] as const){
  const prior=new Map(old.map(x=>[x.id,digest(x)]));for(const row of rows)if(prior.get(row.id)!==digest(row))changed.push({kind,row});
 }
 const contributions=changed.filter(c=>c.kind==='contribution').map(c=>c.row as DemandContribution);
 const requestIds=contributions.flatMap(c=>c.source.kind==='request'?[c.source.requestId]:[]);
 const requests=new Map((await ctx.db.query('SELECT request_id,author_id FROM ritc.request WHERE household_id=$1 AND shop_id=$2 AND request_id=ANY($3::uuid[])',[ctx.householdId,shop.shop_id,requestIds])).rows.map(r=>[r.request_id,r.author_id as string]));
 const occurrenceIds=contributions.flatMap(c=>c.source.kind==='meal'?[c.source.occurrenceId]:c.source.kind==='reservation'&&c.source.originOccurrenceId?[c.source.originOccurrenceId]:[]);
 const origins=(await ctx.db.query(`SELECT occurrence_id,actor_id FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=ANY($3::uuid[])
 UNION SELECT occurrence_id,actor_id FROM ritc.shared_meal_change WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=ANY($3::uuid[]) AND (state='applied' OR proposal_id=$4)`,[ctx.householdId,shop.shop_id,occurrenceIds,acceptedProposalId])).rows;
 const mealAuthors=new Map<string,Set<string>>();for(const origin of origins){if(!mealAuthors.has(origin.occurrence_id))mealAuthors.set(origin.occurrence_id,new Set());mealAuthors.get(origin.occurrence_id)!.add(origin.actor_id);}
 const entries:{id:string;kind:string;member:string}[]=[];
 for(const {kind,row} of changed){const members=new Set([ctx.member.member_id]);if(kind==='contribution'){
  const c=row as DemandContribution;if(c.source.kind==='request'){const author=requests.get(c.source.requestId);assert(author);members.add(author);}
  const occurrence=c.source.kind==='meal'?c.source.occurrenceId:c.source.kind==='reservation'?c.source.originOccurrenceId:null;
  if(occurrence)for(const author of mealAuthors.get(occurrence)??[])members.add(author);
 }for(const member of members)entries.push({id:row.id,kind,member});}
 if(entries.length)await ctx.db.query(`INSERT INTO ritc.shared_demand_source_member(household_id,shop_id,entity_id,entity_kind,member_id)
 SELECT $1,$2,(e->>'id')::uuid,e->>'kind',(e->>'member')::uuid FROM jsonb_array_elements($3::jsonb) e ON CONFLICT DO NOTHING`,[ctx.householdId,shop.shop_id,JSON.stringify(entries)]);
 // One scoped set operation also covers existing lines that acquire a sourced label.
 await ctx.db.query(`INSERT INTO ritc.shared_demand_source_member(household_id,shop_id,entity_id,entity_kind,member_id)
 SELECT p.household_id,p.shop_id,(c->>'lineId')::uuid,'line',p.member_id FROM jsonb_array_elements($3::jsonb) c
 JOIN ritc.shared_demand_source_member p ON p.household_id=$1 AND p.shop_id=$2 AND p.entity_id=(c->>'id')::uuid AND p.entity_kind='contribution' ON CONFLICT DO NOTHING`,[ctx.householdId,shop.shop_id,JSON.stringify(after.contributions.map(c=>({id:c.id,lineId:c.lineId})))]);
}
export async function applyDemand(repo:HouseholdRepository,ctx:Context,shop:Shop,c:Envelope,operationId:string){
 if((c.body.demandReview as any)?.trackingVersion===2)return applyTracking(repo,ctx,shop,c,operationId);await assertTrackingV1(repo,ctx,shop);
 const p=await boundPreview(ctx,shop.shop_id,c.body.demandReview),input=inputSchema.parse(p.intent);assert(p.operation_id===operationId&&p.authority_epoch===shop.authority_epoch&&p.shop_revision===shop.revision,'stale_demand');
 const {demandReview,...body}=c.body;assert(input.action.kind===c.kind&&digest(input.action.body)===digest(body),'demand_action_changed');
 const reviewed=await evaluate(repo,ctx,shop,input,operationId,p.created_at.toISOString());assert(reviewed.baseDigest===p.graph_digest&&reviewed.acceptedDigest===p.accepted_digest,'stale_demand');
 const {graph,receipt}=reviewed.result;
 await recordFoodOperationEffect(ctx,shop,input,operationId,reviewed.before.revision,graph.revision);
 await stageV1Tracking(repo,ctx,shop,input,reviewed,operationId);
 await ctx.db.query(`INSERT INTO ritc.shared_demand_revision(household_id,shop_id,revision,predecessor,shop_revision,authority_epoch,operation_id,actor_id,device_id,created_at,graph,graph_digest,receipt,pack_review)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,[ctx.householdId,shop.shop_id,graph.revision,graph.revision===1?null:graph.revision-1,shop.revision+1,shop.authority_epoch,operationId,ctx.member.member_id,ctx.deviceId,ctx.now,graph,digest(graph),receipt,JSON.stringify(input.packs)]);
 await rememberSources(ctx,shop,reviewed.before,graph,reviewed.facts.body.mealEdit?.changeProposalId??null);
 await ctx.db.query('UPDATE ritc.shop SET demand_revision=$3,demand_review_required=false WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id,graph.revision]);
 await ctx.db.query('DELETE FROM ritc.shared_demand_preview WHERE household_id=$1 AND preview_id=$2',[ctx.householdId,p.preview_id]);
}
export async function assertPriceOnly(repo:HouseholdRepository,ctx:Context,shop:Shop,c:Envelope){
 await assertTrackingV1(repo,ctx,shop);const body=bodySchemas['shop.patch'].parse(c.body);assert(!body.mealEdit&&!body.demandReview&&!shop.demand_review_required,'demand_review_required');
 const identity=(lines:any[])=>lines.map(({lineId,originalItem,packs})=>({lineId,originalItem,packs}));assert(digest(identity(body.lines))===digest(identity(await repo.lines(ctx,shop.shop_id))),'demand_price_only_changed');
}

/** New effect references authenticate a bounded whole-operation scope; old receipts
 * are deliberately not backfilled or promoted to complete Undo authority. */
export async function recordFoodOperationEffect(ctx:Context,shop:Shop,input:Input,operationId:string,beforeGraph:number,afterGraph:number){
 const body=input.action.body;
 let classification=input.action.kind==='request.apply'?'request_acceptance':beforeGraph===0?'first_adoption':
  body.reviewedStoreBasisRevision!==undefined||shop.store_review_required?'store_action':body.mealEdit?'meal_action':'eligible';
 const previous=(await ctx.db.query('SELECT snapshot,digest FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,shop.revision])).rows[0];
 if(classification==='eligible'&&(!previous||previous.digest!==digest(previous.snapshot)))classification='missing_snapshot';
 await ctx.db.query(`INSERT INTO ritc.shared_food_operation_effect(household_id,shop_id,operation_id,base_shop_revision,result_shop_revision,
 base_graph_revision,result_graph_revision,classification,reverses_operation_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
 [ctx.householdId,shop.shop_id,operationId,shop.revision,shop.revision+1,beforeGraph,afterGraph,classification,input.mode==='operationUndo'?input.undoOperationId:null]);
 if((classification==='meal_action'||classification==='first_adoption'&&body.mealEdit)&&input.mode!=='operationUndo')
  await recordMealUndoEffect(ctx,shop,operationId,bodySchemas['shop.patch'].parse(body).mealEdit);
}
/** Selection identity is immutable, but access to its author/permission is live.
 * No copied source wording is returned; erasure removes the joined basis. */
export async function liveFoodUndoStoreBasis(ctx:Context,shop:Shop,revision:unknown):Promise<FoodUndoStoreBasis|null>{
 if(!Number.isInteger(revision)||Number(revision)<=0)return null;
 const row=(await ctx.db.query(`SELECT a.revision,a.pair_id,a.choice,p.options->a.choice AS selected
 FROM ritc.store_quote_adoption a
 JOIN ritc.store_quote_pair p ON p.household_id=a.household_id AND p.shop_id=a.shop_id AND p.pair_id=a.pair_id
 JOIN ritc.member author ON author.household_id=p.household_id AND author.member_id=p.actor_id AND author.state='active'
 JOIN ritc.member adopter ON adopter.household_id=a.household_id AND adopter.member_id=a.actor_id AND adopter.state='active'
 WHERE a.household_id=$1 AND a.shop_id=$2 AND a.revision=$3 AND p.authority_epoch=$4
 AND (p.grant_revision=0 OR EXISTS(SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=p.household_id AND g.shop_id=p.shop_id
 AND g.member_id=p.actor_id AND g.enabled AND g.authority_epoch=p.authority_epoch AND g.revision=p.grant_revision))`,
 [ctx.householdId,shop.shop_id,revision,shop.authority_epoch])).rows[0];
 return row?.selected?{revision:row.revision,pairId:row.pair_id,choice:row.choice,selectionDigest:digest(row.selected)}:null;
}
async function foodUndoEvidence(ctx:Context,shop:Shop,operationId:string):Promise<FoodUndoEvidence>{
 const o=(await ctx.db.query('SELECT operation_id,household_id,shop_id,kind,payload_digest FROM ritc.operation WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,operationId])).rows[0];
 if(!o)throw foodUndoFailure('history_unavailable');
 const effect=(await ctx.db.query('SELECT * FROM ritc.shared_food_operation_effect WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,operationId])).rows[0]??null;
 let before=null,after=null,beforeGraph=null,afterGraph=null;
 if(effect){
  const snapshots=(await ctx.db.query('SELECT revision,snapshot,digest,operation_id FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=ANY($3::integer[])',[ctx.householdId,shop.shop_id,[effect.base_shop_revision,effect.result_shop_revision]])).rows;
  before=snapshots.find(r=>r.revision===effect.base_shop_revision)??null;
  after=snapshots.find(r=>r.revision===effect.result_shop_revision&&r.operation_id===operationId)??null;
  const graphs=(await ctx.db.query('SELECT revision,graph,graph_digest,receipt,operation_id FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=ANY($3::integer[])',[ctx.householdId,shop.shop_id,[effect.base_graph_revision,effect.result_graph_revision]])).rows;
  beforeGraph=graphs.find(r=>r.revision===effect.base_graph_revision)??null;
  afterGraph=graphs.find(r=>r.revision===effect.result_graph_revision&&r.operation_id===operationId)??null;
 }
 const alreadyReversed=(await ctx.db.query('SELECT 1 FROM ritc.shared_food_operation_effect WHERE household_id=$1 AND shop_id=$2 AND reverses_operation_id=$3',[ctx.householdId,shop.shop_id,operationId])).rowCount!==0;
 const meal=effect?.classification==='meal_action'?await loadMealUndoEvidence(ctx,shop,operationId):null;
 const storeBasis=await liveFoodUndoStoreBasis(ctx,shop,before?.snapshot?.storeBasis?.revision);
 return {operation:o,effect,before,after,beforeGraph,afterGraph,alreadyReversed,meal,storeBasis};
}
async function operationInverse(repo:HouseholdRepository,ctx:Context,shop:Shop,target:string,graph:DemandGraph,operationId:string,at:string,lines?:Awaited<ReturnType<HouseholdRepository['lines']>>){
 assert(!shop.demand_review_required,'demand_review_required');
 return deriveSharedFoodUndo(await foodUndoEvidence(ctx,shop,target),{graph,lines:lines??await repo.lines(ctx,shop.shop_id),quote:shop.quote,shopRevision:shop.revision,storeBasis:{revision:shop.store_basis_revision??null,reviewRequired:shop.store_review_required??false}},
  {operationId,householdId:ctx.householdId,shopId:shop.shop_id,baseRevision:graph.revision,at},ctx.now);
}
export const foodUndoCandidateSchema=z.object({targetOperationId:id,base:baseSchema.extend({graphRevision:z.number().int().positive(),graphDigest:z.string().regex(/^[0-9a-f]{64}$/)})}).strict();
export const foodUndoInputSchema=foodUndoCandidateSchema.extend({effectDigest:z.string().regex(/^[0-9a-f]{64}$/),packs:z.array(pack).max(200)}).strict();
export async function readFoodOperationUndoCandidate(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown){
 repo.requireShopper(ctx,shop);await assertTrackingV1(repo,ctx,shop);repo.requireDraft(shop);const input=foodUndoCandidateSchema.parse(raw);repo.checkBase(shop,input.base);
 const current=await loadDemand(ctx,shop);assert(current&&!shop.demand_review_required,'demand_enabled_required');
 assert(current.graph.revision===input.base.graphRevision&&current.fingerprint===input.base.graphDigest,'stale_demand');
 const inverse=await operationInverse(repo,ctx,shop,input.targetOperationId,current.graph,randomUUID(),ctx.now.toISOString());
 const facts=await actionFacts(repo,ctx,shop,{action:inverse.action});await verifySources(repo,ctx,shop,inverse.result.graph,facts);
 return {schemaVersion:1,shopId:shop.shop_id,base:input.base,targetOperationId:input.targetOperationId,effectDigest:inverse.effectDigest,
  scope:inverse.scope,action:inverse.action,before:current.graph,after:inverse.result.graph,
  beforeTotals:demandLineTotals(current.graph),afterTotals:demandLineTotals(inverse.result.graph),
  beforeCheckout:inverse.beforeCheckout,afterCheckout:inverse.afterCheckout,packReviewLineIds:inverse.action.body.lines.map(l=>l.lineId),
  ...(inverse.mealUndo?{mealUndo:inverse.mealUndo}:{}),...(inverse.storeBasis?{storeBasis:inverse.storeBasis}:{})};
}
export async function previewFoodOperationUndo(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown){
 repo.requireShopper(ctx,shop);await assertTrackingV1(repo,ctx,shop);repo.requireDraft(shop);const input=foodUndoInputSchema.parse(raw);repo.checkBase(shop,input.base);
 const current=await loadDemand(ctx,shop);assert(current&&!shop.demand_review_required,'demand_enabled_required');
 assert(current.graph.revision===input.base.graphRevision&&current.fingerprint===input.base.graphDigest,'stale_demand');
 const inverse=await operationInverse(repo,ctx,shop,input.targetOperationId,current.graph,randomUUID(),ctx.now.toISOString());
 assert(input.effectDigest===inverse.effectDigest,'demand_action_changed');
 const intent:Input={mode:'operationUndo',base:{shopRevision:input.base.shopRevision,authorityEpoch:input.base.authorityEpoch,graphRevision:input.base.graphRevision},undoOperationId:input.targetOperationId,operationUndoDigest:inverse.effectDigest,
  change:{lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[]},action:inverse.action,packs:input.packs};
 const preview=await previewDemandInput(repo,ctx,shop,intent);
 return {...preview,operationUndo:{targetOperationId:input.targetOperationId,scope:inverse.scope,effectDigest:inverse.effectDigest},
  action:inverse.action,beforeCheckout:inverse.beforeCheckout,afterCheckout:inverse.afterCheckout,
  ...(inverse.mealUndo?{mealUndo:inverse.mealUndo}:{}),...(inverse.storeBasis?{storeBasis:inverse.storeBasis}:{})};
}
/** Informational only: reviewable never means accepted or guaranteed applicable.
 * No source wording, request IDs or copied meal content is exposed by history. */
export async function readFoodOperationHistory(repo:HouseholdRepository,ctx:Context,shop:Shop,beforeRevision:string|null){
 repo.requireShopper(ctx,shop);await assertTrackingV1(repo,ctx,shop);repo.requireDraft(shop);
 const cursor=beforeRevision===null?2147483647:z.coerce.number().int().positive().max(2147483647).parse(beforeRevision);
 const rows=(await ctx.db.query(`SELECT s.revision,o.operation_id,o.kind,o.committed_at FROM ritc.shop_snapshot s
 JOIN ritc.operation o ON (o.household_id,o.operation_id)=(s.household_id,s.operation_id)
 WHERE s.household_id=$1 AND s.shop_id=$2 AND s.revision<$3 AND o.kind IN ('shop.patch','request.apply')
 ORDER BY s.revision DESC LIMIT 21`,[ctx.householdId,shop.shop_id,cursor])).rows;
 const current=await loadDemand(ctx,shop),currentLines=await repo.lines(ctx,shop.shop_id);const items=[];
 for(const row of rows.slice(0,20)){
  let eligibility:{status:'reviewable'|'unavailable';reason:string};
  try{
   if(!current||shop.demand_review_required)throw foodUndoFailure('history_unavailable');
   await operationInverse(repo,ctx,shop,row.operation_id,current.graph,randomUUID(),ctx.now.toISOString(),currentLines);
   eligibility={status:'reviewable',reason:'explicit_current_preview_required'};
  }catch(error){
   if(error instanceof ServiceError)eligibility={status:'unavailable',reason:error.code};
   else if(error instanceof z.ZodError)eligibility={status:'unavailable',reason:'food_undo_history_unavailable'};
   else if(error instanceof SharedDemandError)eligibility={status:'unavailable',reason:'food_undo_graph_conflict'};
   else throw error;
  }
  items.push({operationId:row.operation_id,kind:row.kind,shopRevision:row.revision,committedAt:row.committed_at.toISOString(),eligibility});
 }
 return {schemaVersion:1,shopId:shop.shop_id,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,
  items,nextBeforeRevision:rows.length>20?String(rows[19]!.revision):null};
}
