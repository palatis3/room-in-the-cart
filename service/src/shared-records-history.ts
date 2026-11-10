/** Independent, bounded historical record. Invoke only inside authorized's
 * household-locked transaction. This document grants no live authority. */
import {z} from 'zod';
import type {Context,HouseholdRepository,Member,Shop} from './repository.js';
import {digest} from './database.js';
import {ServiceError,unavailable} from './errors.js';
import {lineSchema,quoteSchema} from './contracts.js';
import {mealQuantity,sharedMealSchema} from './shared-meal-planning.js';
import {deliveryArrivalBody,deliveryUsableBody} from './recovery-contracts.js';
import {financialEntrySchema,observationSchema} from './history-contracts.js';

const id=z.string().uuid(),revision=z.number().int().positive().max(2147483647);
const date=z.string().datetime({offset:true}),phase=z.enum(['draft','frozen','placed','closed']);
const list=<T extends z.ZodTypeAny>(schema:T)=>z.array(schema).max(2000);
const target={sourceId:id,occurrenceId:id,mealRevision:revision,ingredientId:id};
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
 financialEntries:list(financialEntrySchema),priceObservations:list(observationSchema)
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
 const authors=await ctx.db.query<Member>('SELECT * FROM ritc.member WHERE household_id=$1 AND member_id=ANY($2::uuid[])',[ctx.householdId,provenance.rows.map(r=>r.member_id)]);
 check(authors.rows.length===provenance.rows.length);
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
 return projectSharedHistory({schemaVersion:1,projection:'assigned-shopper-history-v1',origin:{householdId:ctx.householdId,shopId:shop.shop_id},shopRevision:shop.revision,phase:shop.phase,
  basketRevisions,mealRevisions,cookCopies,cookSends,deliveries:{sources,observations,matches,reservations},decisions,financialEntries,priceObservations},ctx.now);
}
