import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import type {Context,HouseholdRepository,Shop,Member} from './repository.js';
import {bodySchemas,decisionSchema,type Envelope} from './contracts.js';
import {digest} from './database.js';
import {ServiceError,refresh,unavailable} from './errors.js';
import {checkout} from './checkout.js';
import {sharedDemandChangeSchema,demandQuantitySchema,demandReviewSchema,type DemandGraph,type DemandContribution} from './shared-demand-contracts.js';
import {applyDemandChange,undoDemandChange,validateDemandGraph,demandLineTotals,convertDemandQuantity} from './shared-demand-domain.js';
import {sharedMealSchema,preserveProtectedMeal} from './shared-meal-planning.js';
const id=z.string().uuid().transform(s=>s.toLowerCase());
const delta=sharedDemandChangeSchema.omit({schemaVersion:true,operationId:true,householdId:true,shopId:true,baseRevision:true,at:true});
const pack=z.object({lineId:id,usablePerPack:demandQuantitySchema.nullable(),acceptUnresolved:z.boolean()}).strict();
const inputSchema=z.object({mode:z.enum(['adopt','change','undo','review']),base:z.object({shopRevision:z.number().int().positive(),authorityEpoch:z.number().int().positive(),graphRevision:z.number().int().min(0)}).strict(),
 change:delta,undoOperationId:id.optional(),action:z.object({kind:z.enum(['shop.patch','request.apply']),body:z.record(z.string(),z.unknown())}).strict(),packs:z.array(pack).max(200)}).strict();
type Input=z.infer<typeof inputSchema>;
const fail=(code='demand_review_required')=>new ServiceError(409,code,'Review the current shared quantities and exact source changes.');
function assert(value:unknown,code?:string):asserts value{if(!value)throw fail(code);}
function noChanges(c:Input['change']){return c.lines.length+c.contributions.length+c.edges.length+c.removeEdgeIds.length+c.removeSourceIds.length+(c.quantifyReservationIds?.length??0)===0;}
export async function loadDemand(ctx:Context,shop:Shop):Promise<{graph:DemandGraph;fingerprint:string;receipt:unknown}|null>{
 if(!shop.demand_revision)return null;
 const row=(await ctx.db.query('SELECT graph,graph_digest,receipt FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,shop.demand_revision])).rows[0];
 if(!row)throw refresh();const graph=validateDemandGraph(row.graph);
 assert(graph.householdId===ctx.householdId&&graph.shopId===shop.shop_id&&graph.revision===shop.demand_revision,'demand_identity');
 if(row.graph_digest!==null)assert(row.graph_digest===digest(graph),'demand_integrity');
 return {graph,fingerprint:digest(graph),receipt:row.receipt};
}
export async function readDemand(repo:HouseholdRepository,ctx:Context,shop:Shop){
 repo.requireShopper(ctx,shop);const current=await loadDemand(ctx,shop);
 return {schemaVersion:1,shopId:shop.shop_id,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,status:current?(shop.demand_review_required?'reviewRequired':'enabled'):'legacy',graph:current?.graph??null,totals:current?demandLineTotals(current.graph):[]};
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
async function actionFacts(repo:HouseholdRepository,ctx:Context,shop:Shop,input:Input){
 const meals=await repo.meals(ctx,shop.shop_id);let request:any=null;let body:any,lines:any[],quote=shop.quote;
 if(input.action.kind==='shop.patch'){
  assert(!('demandReview' in input.action.body),'nested_demand_review');body=bodySchemas['shop.patch'].parse(input.action.body);lines=body.lines;quote=body.quote;
  if(body.mealEdit){const e=body.mealEdit,old=meals.find(m=>m.occurrenceId===e.occurrenceId);assert((old?.revision??null)===e.baseMealRevision,'stale_meal');preserveProtectedMeal(old?sharedMealSchema.parse(old.meal):undefined,e.meal);
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
function verifySourceExclusions(c:DemandContribution,occurrenceId:string,meal:any,ingredient:any){
 const expected=[...(meal.planning?.exclusions??[]).map((label:string)=>({occurrenceId,ingredientId:null,label})),...ingredient.exclusions.map((label:string)=>({occurrenceId,ingredientId:ingredient.id,label}))];
 const key=(e:any)=>JSON.stringify([e.occurrenceId,e.ingredientId,e.label]);const required=new Set(expected.map(key));
 const supplied=c.sourceExclusions??[];assert(supplied.length===required.size&&supplied.every(e=>required.has(key(e))),'demand_exclusion_mapping_required');
}
async function verifySources(repo:HouseholdRepository,ctx:Context,shop:Shop,graph:DemandGraph,facts:Awaited<ReturnType<typeof actionFacts>>){
 const active=graph.contributions.filter(c=>c.removedAt===null),expected=new Set<string>();
 // Selected meal ingredients and explicit group bindings are authoritative; the
 // graph cannot omit a need or counterfeit a reservation from another meal.
 for(const m of facts.meals){const meal=sharedMealSchema.parse(m.meal);for(const ingredient of meal.planning?.ingredients??[]){
  const bindings=meal.planning?.bindings?.filter(b=>b.ingredientId===ingredient.id)??[];
  const wholeRow=active.some(c=>c.source.kind==='reservation'&&c.source.originOccurrenceId===m.occurrenceId&&c.source.ingredientId===ingredient.id&&c.source.groupId===null&&c.source.bindingId===null);
  if(!bindings.length||(meal.protected&&wholeRow)){
   const wholeProtected=meal.protected;
   const rows=active.filter(c=>wholeProtected?c.source.kind==='reservation'&&c.source.originOccurrenceId===m.occurrenceId&&c.source.ingredientId===ingredient.id&&c.source.groupId===null&&c.source.bindingId===null:
    c.source.kind==='meal'&&c.source.occurrenceId===m.occurrenceId&&c.source.ingredientId===ingredient.id&&c.source.bindingId===null);
   assert(rows.length===1&&quantityMatches(rows[0]!.quantity,ingredient.quantity),'demand_meal_mismatch');verifySourceExclusions(rows[0]!,m.occurrenceId,meal,ingredient);expected.add(rows[0]!.id);
  }else for(const b of bindings){const protectedGroup=meal.protected||meal.planning!.groups.find(g=>g.id===b.groupId)!.protected;
   const rows=active.filter(c=>protectedGroup?c.source.kind==='reservation'&&c.source.originOccurrenceId===m.occurrenceId&&c.source.bindingId===b.id&&c.source.groupId===b.groupId&&c.source.ingredientId===ingredient.id:
    c.source.kind==='meal'&&c.source.occurrenceId===m.occurrenceId&&c.source.bindingId===b.id&&c.source.groupId===b.groupId&&c.source.ingredientId===ingredient.id);
   assert(rows.length===1&&quantityMatches(rows[0]!.quantity,b.quantity),'demand_meal_mismatch');verifySourceExclusions(rows[0]!,m.occurrenceId,meal,ingredient);expected.add(rows[0]!.id);
  }
  // Missing group quantities are protected unknowns, not inferred proportions.
  // A whole protected ingredient with no bindings is already represented once.
  if(!(meal.protected&&(!bindings.length||wholeRow)))for(const group of meal.planning!.groups.filter(g=>(meal.protected||g.protected)&&ingredient.groupIds.includes(g.id)&&!bindings.some(b=>b.groupId===g.id))){
   const rows=active.filter(c=>c.source.kind==='reservation'&&c.source.originOccurrenceId===m.occurrenceId&&c.source.ingredientId===ingredient.id&&c.source.groupId===group.id&&c.source.bindingId===null);
   assert(rows.length===1&&rows[0]!.quantity===null,'demand_protected_unknown_required');verifySourceExclusions(rows[0]!,m.occurrenceId,meal,ingredient);expected.add(rows[0]!.id);
  }
 }}
 const requestIds=active.flatMap(c=>c.source.kind==='request'?[c.source.requestId]:[]);
 const requests=new Map((await ctx.db.query('SELECT * FROM ritc.request WHERE household_id=$1 AND shop_id=$2 AND request_id=ANY($3::uuid[])',[ctx.householdId,shop.shop_id,requestIds])).rows.map(r=>[r.request_id,r]));
 const links=(await ctx.db.query('SELECT request_id,line_id,reviewed_revision FROM ritc.request_link WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id])).rows;
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
function verifyPacks(graph:DemandGraph,facts:Awaited<ReturnType<typeof actionFacts>>,packs:Input['packs']){
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
 repo.requireShopper(ctx,shop);repo.requireDraft(shop);repo.checkBase(shop,input.base);const current=await loadDemand(ctx,shop);
 assert((current?.graph.revision??0)===input.base.graphRevision,'stale_demand');assert((input.mode==='adopt')===!current,'demand_adoption_required');
 const before=current?.graph??{schemaVersion:1 as const,conversionTableVersion:'us-customary-metric-v1' as const,householdId:ctx.householdId,shopId:shop.shop_id,revision:0,lines:[],contributions:[],edges:[],usedIds:[]};
 const command={...input.change,schemaVersion:1,operationId,householdId:ctx.householdId,shopId:shop.shop_id,baseRevision:before.revision,at};
 let result;
 if(input.mode==='undo'){
  assert(input.undoOperationId&&noChanges(input.change),'invalid_demand_undo');const old=(await ctx.db.query('SELECT receipt FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,input.undoOperationId])).rows[0];assert(old?.receipt,'demand_undo_unavailable');result=undoDemandChange(before,old.receipt,command);
 }else if(input.mode==='review'){
  assert(noChanges(input.change)&&!input.undoOperationId,'invalid_demand_review');result={graph:validateDemandGraph({...before,revision:before.revision+1}),receipt:{schemaVersion:1,operationId,householdId:ctx.householdId,shopId:shop.shop_id,baseRevision:before.revision,resultRevision:before.revision+1,lines:[],contributions:[],edges:[]}};
 }else {assert(!input.undoOperationId,'invalid_demand_change');result=applyDemandChange(before,command);}
 const facts=await actionFacts(repo,ctx,shop,input);await verifySources(repo,ctx,shop,result.graph,facts);verifyPacks(result.graph,facts,input.packs);
 return {before,result,facts,baseDigest:current?.fingerprint??digest(before),acceptedDigest:digest({input,operationId,at,graph:result.graph,receipt:result.receipt,lines:facts.lines,quote:facts.quote,meals:facts.meals,requestRevision:facts.request?.revision??null})};
}
export async function previewDemand(repo:HouseholdRepository,ctx:Context,shop:Shop,raw:unknown){
 const input=inputSchema.parse(raw);input.action.body=bodySchemas[input.action.kind].parse(input.action.body);
 const operationId=randomUUID(),at=ctx.now.toISOString(),reviewed=await evaluate(repo,ctx,shop,input,operationId,at),previewId=randomUUID(),expiresAt=new Date(ctx.now.getTime()+600000);
 await ctx.db.query('DELETE FROM ritc.shared_demand_preview WHERE household_id=$1 AND expires_at<=$2',[ctx.householdId,ctx.now]);
 const count=(await ctx.db.query('SELECT count(*)::integer AS n FROM ritc.shared_demand_preview WHERE household_id=$1 AND actor_id=$2',[ctx.householdId,ctx.member.member_id])).rows[0].n;assert(count<100,'demand_preview_limit');
 await ctx.db.query(`INSERT INTO ritc.shared_demand_preview(household_id,shop_id,preview_id,operation_id,actor_id,device_id,authority_epoch,shop_revision,graph_revision,graph_digest,intent,accepted_digest,created_at,expires_at)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,[ctx.householdId,shop.shop_id,previewId,operationId,ctx.member.member_id,ctx.deviceId,shop.authority_epoch,shop.revision,reviewed.before.revision,reviewed.baseDigest,input,reviewed.acceptedDigest,ctx.now,expiresAt]);
 return {previewId,previewDigest:reviewed.acceptedDigest,expiresAt:expiresAt.toISOString(),before:reviewed.before,after:reviewed.result.graph,beforeTotals:demandLineTotals(reviewed.before),afterTotals:demandLineTotals(reviewed.result.graph),receipt:reviewed.result.receipt,packs:input.packs,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch};
}
async function boundPreview(ctx:Context,shopId:string,review:unknown){
 const b=demandReviewSchema.parse(review),p=(await ctx.db.query('SELECT * FROM ritc.shared_demand_preview WHERE household_id=$1 AND shop_id=$2 AND preview_id=$3 AND actor_id=$4 AND device_id=$5 AND accepted_digest=$6 AND expires_at>$7',[ctx.householdId,shopId,b.previewId,ctx.member.member_id,ctx.deviceId,b.previewDigest,ctx.now])).rows[0];if(!p)throw refresh();return p;
}
export async function demandOperation(ctx:Context,c:Envelope){return c.body.demandReview?(await boundPreview(ctx,c.shopId,c.body.demandReview)).operation_id as string:randomUUID();}
export async function assertDemandReplay(ctx:Context,shop:Shop,operationId:string){
 const row=(await ctx.db.query('SELECT authority_epoch,receipt FROM ritc.shared_demand_revision WHERE household_id=$1 AND operation_id=$2',[ctx.householdId,operationId])).rows[0];if(row&&(!row.receipt||row.authority_epoch!==shop.authority_epoch))throw refresh();
}
async function rememberSources(ctx:Context,shop:Shop,before:DemandGraph,after:DemandGraph,acceptedProposalId:string|null){
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
 const p=await boundPreview(ctx,shop.shop_id,c.body.demandReview),input=inputSchema.parse(p.intent);assert(p.operation_id===operationId&&p.authority_epoch===shop.authority_epoch&&p.shop_revision===shop.revision,'stale_demand');
 const {demandReview,...body}=c.body;assert(input.action.kind===c.kind&&digest(input.action.body)===digest(body),'demand_action_changed');
 const reviewed=await evaluate(repo,ctx,shop,input,operationId,p.created_at.toISOString());assert(reviewed.baseDigest===p.graph_digest&&reviewed.acceptedDigest===p.accepted_digest,'stale_demand');
 const {graph,receipt}=reviewed.result;await ctx.db.query(`INSERT INTO ritc.shared_demand_revision(household_id,shop_id,revision,predecessor,shop_revision,authority_epoch,operation_id,actor_id,device_id,created_at,graph,graph_digest,receipt,pack_review)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,[ctx.householdId,shop.shop_id,graph.revision,graph.revision===1?null:graph.revision-1,shop.revision+1,shop.authority_epoch,operationId,ctx.member.member_id,ctx.deviceId,ctx.now,graph,digest(graph),receipt,JSON.stringify(input.packs)]);
 await rememberSources(ctx,shop,reviewed.before,graph,reviewed.facts.body.mealEdit?.changeProposalId??null);
 await ctx.db.query('UPDATE ritc.shop SET demand_revision=$3,demand_review_required=false WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id,graph.revision]);
 await ctx.db.query('DELETE FROM ritc.shared_demand_preview WHERE household_id=$1 AND preview_id=$2',[ctx.householdId,p.preview_id]);
}
export async function assertPriceOnly(repo:HouseholdRepository,ctx:Context,shop:Shop,c:Envelope){
 const body=bodySchemas['shop.patch'].parse(c.body);assert(!body.mealEdit&&!body.demandReview&&!shop.demand_review_required,'demand_review_required');
 const identity=(lines:any[])=>lines.map(({lineId,originalItem,packs})=>({lineId,originalItem,packs}));assert(digest(identity(body.lines))===digest(identity(await repo.lines(ctx,shop.shop_id))),'demand_price_only_changed');
}
