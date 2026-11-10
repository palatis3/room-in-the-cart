/** Independent, bounded historical record. Invoke only inside authorized's
 * household-locked transaction. This document grants no live authority. */
import {z} from 'zod';
import type {Context,HouseholdRepository,Member,Shop} from './repository.js';
import {digest} from './database.js';
import {ServiceError,unavailable} from './errors.js';
import {lineSchema,quoteSchema} from './contracts.js';
import {mealQuantity,sharedMealSchema} from './shared-meal-planning.js';
import {deliveryArrivalBody,deliveryUsableBody,usableQuantitySchema} from './recovery-contracts.js';
import {financialEntrySchema,observationSchema} from './history-contracts.js';
import {sharedDemandGraphSchema} from './shared-demand-contracts.js';
import {validateDemandGraph} from './shared-demand-domain.js';
import {trackingStateSchema,validateState,digest as trackingDigest} from './shared-demand-tracking.js';

const id=z.string().uuid(),revision=z.number().int().positive().max(2147483647);
const date=z.string().datetime({offset:true}),phase=z.enum(['draft','frozen','placed','closed']);
const list=<T extends z.ZodTypeAny>(schema:T)=>z.array(schema).max(2000);
const target={sourceId:id,occurrenceId:id,mealRevision:revision,ingredientId:id};
const portableFoodSchema=trackingStateSchema.pick({graph:true,basket:true,catalog:true,bindings:true,unbound:true,legacyLineIds:true,packReviews:true});
const stockEvent={lotId:id,pantryRevision:revision,recordedAt:date};
const stockTarget={occurrenceId:id,mealRevision:revision,ingredientId:id};
const foodHistorySchema=z.object({
 demandRevisions:list(z.object({shopRevision:revision,predecessorRevision:revision.nullable(),recordedAt:date,
  graph:sharedDemandGraphSchema,packReviews:trackingStateSchema.shape.packReviews}).strict()),
 trackingRevisions:list(z.object({shopRevision:revision,recordedAt:date,food:portableFoodSchema}).strict())
}).strict();
const stockHistorySchema=z.object({
 lots:list(z.object({lotId:id,deliverySourceId:id.nullable(),location:z.enum(['pantry','freezer']),storedAt:date.nullable(),
  useFirstAt:date.nullable(),foodName:z.string().min(1).max(240),exclusionTags:z.array(z.string().min(1).max(240)).max(20)}).strict()),
 events:list(z.discriminatedUnion('kind',[
  z.object({...stockEvent,kind:z.literal('observe'),confirmedAt:date,quantity:usableQuantitySchema.nullable()}).strict(),
  z.object({...stockEvent,kind:z.literal('select'),selected:z.boolean()}).strict(),
  z.object({...stockEvent,kind:z.literal('match'),...stockTarget,matched:z.boolean()}).strict(),
  z.object({...stockEvent,kind:z.literal('reserve'),...stockTarget,groupId:id,quantity:mealQuantity.nullable()}).strict()
 ]))
}).strict();
export const sharedHistoryRecordSchema=z.object({
 schemaVersion:z.literal(1),projection:z.literal('assigned-shopper-history-v1'),
 origin:z.object({householdId:id,shopId:id}).strict(),shopRevision:revision,phase,
 basketRevisions:list(z.object({revision,purpose:z.enum(['create','patch','decision','freeze','reopen','placed']),
  recordedAt:date,phase,quote:quoteSchema,basketLines:z.array(lineSchema).max(200)}).strict()),
 mealRevisions:list(z.object({occurrenceId:id,revision,meal:sharedMealSchema.nullable()}).strict()),
 cookCopies:list(z.object({copyId:id,occurrenceId:id,mealRevision:revision,shopRevision:revision,placedRevision:revision,
  version:revision,language:z.enum(['en','es']),text:z.string().min(1).max(16000),createdAt:date}).strict()),
 cookSends:list(z.object({copyId:id,recipient:z.string().min(1).max(80),sentAt:date}).strict()),
 deliveries:z.object({
  sources:list(z.object({sourceId:id,placedRevision:revision,lineId:id,segmentKey:id,foodName:z.string().min(1).max(240),exclusionTags:z.array(z.string()).max(20)}).strict()),
  observations:list(z.discriminatedUnion('kind',[
   z.object({kind:z.literal('arrival'),recordedAt:date,body:deliveryArrivalBody}).strict(),
   z.object({kind:z.literal('usable'),recordedAt:date,body:deliveryUsableBody}).strict()])),
  matches:list(z.object({supplyRevision:revision,...target,matched:z.boolean()}).strict()),
  reservations:list(z.object({supplyRevision:revision,...target,groupId:id,quantity:mealQuantity.nullable()}).strict())
 }).strict(),
 decisions:list(z.object({id,shopId:id,version:revision,kind:z.enum(['approval','exclusion','preference']),
  product:z.string().max(120).nullable(),dish:z.string().max(120).nullable(),occasion:z.string().max(120).nullable(),
  decision:z.string().min(1).max(500),outcome:z.string().max(500).nullable(),scope:z.enum(['lasting','one_shop']),
  recordedAt:date,observedAt:date.nullable(),promotedAt:date.nullable()}).strict()),
 financialEntries:list(financialEntrySchema),priceObservations:list(observationSchema),
 // Absence means an older archive did not capture this history, never that it
 // was empty. Newly read records include both complete bounded sections.
 foodHistory:foodHistorySchema.optional(),stockHistory:stockHistorySchema.optional()
}).strict();
export type SharedHistoryRecord=z.infer<typeof sharedHistoryRecordSchema>;
const fail=()=>new ServiceError(409,'shared_history_unavailable','This history cannot be exported completely. Current records remain available.');
function check(value:unknown):asserts value{if(!value)throw fail();}
function time(value:Date|string){const result=new Date(value);check(Number.isFinite(result.getTime()));return result.toISOString();}
const optionalTime=(value:Date|string|null)=>value===null?null:time(value);

/** Strict decoding rejects authority fields even when nested. Stable content
 * digest is the archive revision; the fresh observation time is outside it. */
export function projectSharedHistory(raw:unknown,asOf:Date){
 const result=sharedHistoryRecordSchema.safeParse(raw);check(result.success);
 const record=result.data;check(digest(record)===digest(raw));
 const unique=(values:unknown[])=>check(new Set(values).size===values.length);
 unique(record.basketRevisions.map(r=>r.revision));unique(record.mealRevisions.map(r=>r.occurrenceId+'/'+r.revision));
 unique(record.cookCopies.map(r=>r.copyId));unique(record.deliveries.sources.map(r=>r.sourceId));
 unique(record.deliveries.observations.map(r=>r.body.observationId));unique(record.decisions.map(r=>r.id));
 unique(record.financialEntries.map(r=>r.id));unique(record.priceObservations.map(r=>r.id));
 const meals=new Set(record.mealRevisions.filter(r=>r.meal!==null).map(r=>r.occurrenceId+'/'+r.revision));
 const baskets=new Map(record.basketRevisions.map(r=>[r.revision,r]));
 const sources=new Set(record.deliveries.sources.map(r=>r.sourceId));
 const copies=new Set(record.cookCopies.map(r=>r.copyId));
 check(record.basketRevisions.every(r=>r.revision<=record.shopRevision&&new Set(r.basketLines.map(l=>l.lineId)).size===r.basketLines.length));
 check(record.mealRevisions.every(r=>r.revision<=record.shopRevision));
 check(record.cookCopies.every(r=>r.shopRevision<=record.shopRevision&&baskets.has(r.placedRevision)&&meals.has(r.occurrenceId+'/'+r.mealRevision)));
 check(record.cookSends.every(r=>copies.has(r.copyId)));
 check(record.deliveries.sources.every(r=>baskets.get(r.placedRevision)?.basketLines.some(l=>l.lineId===r.lineId)));
 check(record.deliveries.observations.every(r=>sources.has(r.body.sourceId)));
 check([...record.deliveries.matches,...record.deliveries.reservations].every(r=>sources.has(r.sourceId)&&meals.has(r.occurrenceId+'/'+r.mealRevision)));
 check(record.decisions.every(r=>r.shopId===record.origin.shopId));check(record.priceObservations.every(r=>r.shopId===record.origin.shopId));
 if(record.foodHistory){
  const history=record.foodHistory,graphs=new Map(history.demandRevisions.map(r=>[r.graph.revision,r]));
  unique(history.demandRevisions.map(r=>r.graph.revision));unique(history.demandRevisions.map(r=>r.shopRevision));unique(history.trackingRevisions.map(r=>r.shopRevision));
  const occurrences=new Set(record.mealRevisions.filter(r=>r.meal!==null).map(r=>r.occurrenceId));
  const sourceExists=(source:{kind:string;occurrenceId?:string;originOccurrenceId?:string|null})=>source.kind==='meal'?occurrences.has(source.occurrenceId!):source.kind==='reservation'&&source.originOccurrenceId!==null?occurrences.has(source.originOccurrenceId!):true;
  for(const row of history.demandRevisions){
   check(baskets.has(row.shopRevision)&&row.graph.householdId===record.origin.householdId&&row.graph.shopId===record.origin.shopId);
   check(row.predecessorRevision===(row.graph.revision===1?null:row.graph.revision-1));
   check(row.predecessorRevision===null||graphs.has(row.predecessorRevision));
   try{validateDemandGraph(row.graph);}catch{throw fail();}
   check(row.graph.contributions.every(c=>sourceExists(c.source)));
   unique(row.packReviews.map(p=>p.lineId));
   check(digest(row.packReviews.map(p=>p.lineId).sort())===digest(row.graph.lines.filter(l=>l.trashedAt===null).map(l=>l.id).sort()));
  }
  for(const row of history.trackingRevisions){
   const basket=baskets.get(row.shopRevision),graph=graphs.get(row.food.graph.revision);
   check(basket&&graph&&graph.shopRevision<=row.shopRevision&&digest(graph.graph)===digest(row.food.graph));
   const lines=basket.basketLines.map(l=>({id:l.lineId,name:l.originalItem,packs:l.packs,priceMinor:l.unitPriceMinor,feeEligible:l.feeEligible})).sort((a,b)=>a.id.localeCompare(b.id));
   check(digest(lines)===digest([...row.food.basket].sort((a,b)=>a.id.localeCompare(b.id))));
   try{validateState({schemaVersion:2,authorityEpoch:0,privacyRevision:0,quoteDigest:digest(basket.quote),...row.food},row.food.catalog);}catch{throw fail();}
   check(row.food.unbound.every(u=>!u.transferred||sourceExists(u.transferred.source)));
   for(const fact of row.food.catalog){
    const occurrence=fact.source.kind==='meal'?fact.source.occurrenceId:fact.source.kind==='reservation'?fact.source.originOccurrenceId:null;
    check(occurrence===null||meals.has(occurrence+'/'+fact.revision));
   }
  }
 }
 if(record.stockHistory){
  const stock=record.stockHistory,lots=new Map(stock.lots.map(l=>[l.lotId,l]));
  unique(stock.lots.map(l=>l.lotId));unique(stock.events.map(e=>e.pantryRevision));
  check(stock.lots.every(l=>l.deliverySourceId===null||l.deliverySourceId===l.lotId&&sources.has(l.deliverySourceId)));
  for(const event of stock.events){
   const lot=lots.get(event.lotId);check(lot);
   if(event.kind==='observe')check(lot.deliverySourceId===null);
   if(event.kind==='match'||event.kind==='reserve'){
    const meal=record.mealRevisions.find(m=>m.occurrenceId===event.occurrenceId&&m.revision===event.mealRevision)?.meal;
    const ingredient=meal?.planning?.ingredients.find(i=>i.id===event.ingredientId);check(ingredient);
    if(event.kind==='reserve')check(ingredient.groupIds.includes(event.groupId)&&meal?.planning?.groups.some(g=>g.id===event.groupId));
   }
  }
 }
 const envelope={schemaVersion:1 as const,asOf:time(asOf),recordDigest:digest(record),record};
 check(Buffer.byteLength(JSON.stringify(envelope),'utf8')<=1_800_000);
 return envelope;
}

/** A safe read of retained history, not a reconstruction of erased payloads.
 * Any unavailable retained provenance or bound fails the whole export. */
export async function readSharedRecordHistory(repo:HouseholdRepository,ctx:Context,shop:Shop){
 repo.requireShopper(ctx,shop);
 const scope=[ctx.householdId,shop.shop_id];
 const permitted=await ctx.db.query(`SELECT 1 FROM ritc.shop WHERE household_id=$1 AND shop_id=$2 AND history_retired_at IS NULL`,scope);
 if(!permitted.rowCount)throw unavailable();
 // Dated copies may contain other shops' stock. This v1 exports one shop only;
 // do not silently bring foreign stock context into the document.
 const joint=await ctx.db.query(`SELECT 1 FROM ritc.cook_copy_pantry_scope p JOIN ritc.dated_cook_copy c USING(household_id,copy_id)
  WHERE c.household_id=$1 AND c.shop_id=$2 AND p.shop_id<>$2 LIMIT 1`,scope);check(!joint.rowCount);
 // Stock scope is selected-shop origin or an explicit historical use in this
 // shop. No household-wide dump or other shops' meal commitments are exported.
 const lotScope=`l.household_id=$1 AND (l.origin_shop_id=$2 OR EXISTS(SELECT 1 FROM ritc.pantry_event e WHERE e.household_id=l.household_id AND e.lot_id=l.lot_id AND e.shop_id=$2))`;
 const stockMetadata=await ctx.db.query(`SELECT l.lot_id,l.origin_shop_id,l.delivery_source_id,l.actor_id,s.history_retired_at FROM ritc.pantry_lot l JOIN ritc.shop s ON (s.household_id,s.shop_id)=(l.household_id,l.origin_shop_id) WHERE ${lotScope} ORDER BY l.lot_id LIMIT 2001`,scope);
 check(stockMetadata.rows.length<=2000&&stockMetadata.rows.every(l=>!l.history_retired_at&&(l.delivery_source_id===null||l.origin_shop_id===shop.shop_id)));
 const stockIds=stockMetadata.rows.map(l=>l.lot_id);
 const stockAuthors=await ctx.db.query(`SELECT DISTINCT e.actor_id,s.history_retired_at FROM ritc.pantry_event e JOIN ritc.shop s ON (s.household_id,s.shop_id)=(e.household_id,e.shop_id) WHERE e.household_id=$1 AND e.lot_id=ANY($3::uuid[]) AND (e.shop_id=$2 OR e.kind='observe') LIMIT 2001`,[...scope,stockIds]);
 check(stockAuthors.rows.length<=2000&&stockAuthors.rows.every(r=>!r.history_retired_at));
 // Recheck retained contributors before reading payloads. This deliberately
 // fails closed for an ended source instead of trusting historical authority.
 const provenance=await ctx.db.query<{member_id:string}>(`SELECT DISTINCT member_id FROM (
  SELECT actor_id AS member_id FROM ritc.operation WHERE household_id=$1 AND shop_id=$2
  UNION SELECT author_id FROM ritc.request WHERE household_id=$1 AND shop_id=$2
  UNION SELECT actor_id FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2
  UNION SELECT actor_id FROM ritc.shared_meal_change WHERE household_id=$1 AND shop_id=$2 AND state='applied'
  UNION SELECT actor_id FROM ritc.meal_move WHERE household_id=$1 AND shop_id=$2 AND state='applied'
  UNION SELECT member_id FROM ritc.shared_demand_source_member WHERE household_id=$1 AND shop_id=$2
  UNION SELECT member_id FROM ritc.shared_tracking_source_member WHERE household_id=$1 AND shop_id=$2
  UNION SELECT member_id FROM ritc.shared_tracking_basket_origin WHERE household_id=$1 AND shop_id=$2
  UNION SELECT author_id FROM ritc.family_decision WHERE household_id=$1 AND shop_id=$2
  UNION SELECT observer_id FROM ritc.family_decision WHERE household_id=$1 AND shop_id=$2
  UNION SELECT promoter_id FROM ritc.family_decision WHERE household_id=$1 AND shop_id=$2
  UNION SELECT actor_id FROM ritc.financial_entry WHERE household_id=$1 AND shop_id=$2
  UNION SELECT actor_id FROM ritc.price_observation WHERE household_id=$1 AND shop_id=$2 AND retired_at IS NULL
  UNION SELECT p.member_id FROM ritc.cook_copy_pantry_actor p JOIN ritc.dated_cook_copy c USING(household_id,copy_id) WHERE c.household_id=$1 AND c.shop_id=$2
 ) authors WHERE member_id IS NOT NULL LIMIT 2001`,scope);check(provenance.rows.length<=2000);
 const authorIds=[...new Set([...provenance.rows.map(r=>r.member_id),...stockMetadata.rows.map(r=>r.actor_id),...stockAuthors.rows.map(r=>r.actor_id)])];check(authorIds.length<=2000);
 const authors=await ctx.db.query<Member>('SELECT * FROM ritc.member WHERE household_id=$1 AND member_id=ANY($2::uuid[])',[ctx.householdId,authorIds]);
 check(authors.rows.length===authorIds.length);
 for(const author of authors.rows){check(author.state==='active');await repo.consent(ctx.db,ctx.householdId,author);}
 const rows=async(sql:string)=>{const result=await ctx.db.query(sql,scope);check(result.rows.length<=2000);return result.rows;};
 const snapshots=await rows(`SELECT revision,purpose,created_at,snapshot,digest FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 ORDER BY revision LIMIT 2001`);
 const basketRevisions=snapshots.map(r=>{
  check(r.digest!=='0'.repeat(64)&&r.digest===digest(r.snapshot));
  check(r.snapshot.shopId===shop.shop_id&&r.snapshot.revision===r.revision);
  return{revision:r.revision,purpose:r.purpose,recordedAt:time(r.created_at),phase:r.snapshot.phase,quote:r.snapshot.quote,basketLines:r.snapshot.lines};
 });
 const mealRevisions=await rows(`SELECT occurrence_id AS "occurrenceId",revision,meal FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 ORDER BY occurrence_id,revision LIMIT 2001`);
 // Normal removal records a null meal revision. Privacy erasure deletes the
 // occurrence's history; never fill a missing/removed meal from another row.
 const retainedMeals=new Set(mealRevisions.filter(r=>r.meal!==null).map(r=>r.occurrenceId+'/'+r.revision));
 const mealRefs=z.array(z.object({occurrenceId:id,revision}).strict()).max(100);
 for(const snapshot of snapshots){
  const refs=mealRefs.safeParse(snapshot.snapshot.mealRefs??[]);check(refs.success);
  check(refs.data.every(ref=>retainedMeals.has(ref.occurrenceId+'/'+ref.revision)));
 }
 const cookCopies=(await rows(`SELECT copy_id AS "copyId",occurrence_id AS "occurrenceId",meal_revision AS "mealRevision",shop_revision AS "shopRevision",placed_revision AS "placedRevision",version,language,reviewed_text AS text,created_at AS "createdAt" FROM ritc.dated_cook_copy WHERE household_id=$1 AND shop_id=$2 ORDER BY occurrence_id,version LIMIT 2001`)).map(r=>({...r,createdAt:time(r.createdAt)}));
 const cookSends=(await rows(`SELECT s.copy_id AS "copyId",s.recipient,s.sent_at AS "sentAt" FROM ritc.cook_copy_send s JOIN ritc.dated_cook_copy c USING(household_id,copy_id) WHERE c.household_id=$1 AND c.shop_id=$2 ORDER BY s.sent_at,s.send_id LIMIT 2001`)).map(r=>({...r,sentAt:time(r.sentAt)}));
 const sources=await rows(`SELECT source_id AS "sourceId",placed_revision AS "placedRevision",line_id AS "lineId",segment_key AS "segmentKey",food_name AS "foodName",exclusion_tags AS "exclusionTags" FROM ritc.delivery_source WHERE household_id=$1 AND shop_id=$2 ORDER BY source_id LIMIT 2001`);
 const observations=(await rows(`SELECT kind,recorded_at AS "recordedAt",body FROM ritc.delivery_observation WHERE household_id=$1 AND shop_id=$2 ORDER BY supply_revision LIMIT 2001`)).map(r=>({...r,recordedAt:time(r.recordedAt)}));
 const targets=`supply_revision AS "supplyRevision",source_id AS "sourceId",occurrence_id AS "occurrenceId",meal_revision AS "mealRevision",ingredient_id AS "ingredientId"`;
 const matches=await rows(`SELECT ${targets},matched FROM ritc.delivery_ingredient_review WHERE household_id=$1 AND shop_id=$2 ORDER BY supply_revision LIMIT 2001`);
 const reservations=await rows(`SELECT ${targets},group_id AS "groupId",quantity FROM ritc.delivery_reservation WHERE household_id=$1 AND shop_id=$2 ORDER BY supply_revision LIMIT 2001`);
 const decisions=(await rows(`SELECT decision_id AS id,shop_id AS "shopId",version,kind,product,dish,occasion,decision,outcome,CASE WHEN promoted_at IS NULL THEN 'one_shop' ELSE 'lasting' END AS scope,recorded_at AS "recordedAt",observed_at AS "observedAt",promoted_at AS "promotedAt" FROM ritc.family_decision WHERE household_id=$1 AND shop_id=$2 ORDER BY recorded_at,decision_id LIMIT 2001`)).map(r=>({...r,recordedAt:time(r.recordedAt),observedAt:optionalTime(r.observedAt),promotedAt:optionalTime(r.promotedAt)}));
 const financialEntries=(await rows(`SELECT entry_id AS id,evidence_key AS "evidenceKey",kind,amount_minor AS "amountMinor",'USD' AS currency,occurred_at AS "occurredAt",credit_id AS "creditId",charge_evidence_key AS "chargeEvidenceKey",hold_evidence_key AS "holdEvidenceKey",source_text AS "sourceText" FROM ritc.financial_entry WHERE household_id=$1 AND shop_id=$2 ORDER BY created_at,entry_id LIMIT 2001`)).map(r=>({...r,amountMinor:Number(r.amountMinor),occurredAt:time(r.occurredAt)}));
 const priceObservations=(await rows(`SELECT record FROM ritc.price_observation WHERE household_id=$1 AND shop_id=$2 AND retired_at IS NULL ORDER BY observed_at,observation_id LIMIT 2001`)).map(r=>r.record);
 const demandRevisions=(await rows(`SELECT shop_revision,predecessor,created_at,graph,graph_digest,pack_review FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 ORDER BY revision LIMIT 2001`)).map(r=>{
  check(r.graph_digest!==null&&r.graph_digest===digest(r.graph)&&r.pack_review!==null);
  return{shopRevision:r.shop_revision,predecessorRevision:r.predecessor,recordedAt:time(r.created_at),graph:r.graph,packReviews:r.pack_review};
 });
 const trackingRevisions=(await rows(`SELECT t.shop_revision,t.state,t.state_digest,t.projection,o.committed_at FROM ritc.shared_tracking_revision t JOIN ritc.operation o USING(household_id,operation_id) WHERE t.household_id=$1 AND t.shop_id=$2 ORDER BY t.shop_revision LIMIT 2001`)).map(r=>{
  check(r.state!==null&&r.projection===null&&r.state_digest===trackingDigest(r.state));
  const basket=snapshots.find(s=>s.revision===r.shop_revision);check(basket&&r.state.quoteDigest===digest(basket.snapshot.quote));
  let state;try{state=validateState(r.state,r.state.catalog);}catch{throw fail();}
  const {graph,basket:lines,catalog,bindings,unbound,legacyLineIds,packReviews}=state;
  return{shopRevision:r.shop_revision,recordedAt:time(r.committed_at),food:{graph,basket:lines,catalog,bindings,unbound,legacyLineIds,packReviews}};
 });
 const lots=(await rows(`SELECT l.lot_id AS "lotId",l.delivery_source_id AS "deliverySourceId",l.location,l.stored_at AS "storedAt",l.use_first_at AS "useFirstAt",COALESCE(d.food_name,l.food_name) AS "foodName",COALESCE(d.exclusion_tags,l.exclusion_tags) AS "exclusionTags" FROM ritc.pantry_lot l LEFT JOIN ritc.delivery_source d ON (d.household_id,d.shop_id,d.source_id)=(l.household_id,l.origin_shop_id,l.delivery_source_id) WHERE ${lotScope} ORDER BY l.lot_id LIMIT 2001`)).map(r=>({...r,storedAt:optionalTime(r.storedAt),useFirstAt:optionalTime(r.useFirstAt)}));
 const stockRows=await ctx.db.query(`SELECT e.lot_id,e.pantry_revision,e.kind,e.occurrence_id,e.meal_revision,e.ingredient_id,e.group_id,e.enabled,e.confirmed_at,e.quantity,o.committed_at FROM ritc.pantry_event e JOIN ritc.operation o USING(household_id,operation_id) WHERE e.household_id=$1 AND e.lot_id=ANY($3::uuid[]) AND (e.shop_id=$2 OR e.kind='observe') ORDER BY e.pantry_revision LIMIT 2001`,[...scope,stockIds]);check(stockRows.rows.length<=2000);
 const events=stockRows.rows.map(r=>{
  const common={lotId:r.lot_id,pantryRevision:r.pantry_revision,recordedAt:time(r.committed_at)};
  if(r.kind==='observe')return{...common,kind:'observe',confirmedAt:time(r.confirmed_at),quantity:r.quantity};
  if(r.kind==='select')return{...common,kind:'select',selected:r.enabled};
  const target={occurrenceId:r.occurrence_id,mealRevision:r.meal_revision,ingredientId:r.ingredient_id};
  if(r.kind==='match')return{...common,kind:'match',...target,matched:r.enabled};
  check(r.kind==='reserve');return{...common,kind:'reserve',...target,groupId:r.group_id,quantity:r.quantity};
 });
 return projectSharedHistory({schemaVersion:1,projection:'assigned-shopper-history-v1',origin:{householdId:ctx.householdId,shopId:shop.shop_id},shopRevision:shop.revision,phase:shop.phase,
  basketRevisions,mealRevisions,cookCopies,cookSends,deliveries:{sources,observations,matches,reservations},decisions,financialEntries,priceObservations,
  foodHistory:{demandRevisions,trackingRevisions},stockHistory:{lots,events}},ctx.now);
}
