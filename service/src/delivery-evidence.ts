import {deliveryCoverage,type SealedMeal} from './delivery-coverage.js';
import { z } from 'zod';
import type { Context, Shop } from './repository.js';
import { deliveryMatchBody, deliverySourceBody, deliveryArrivalBody, deliveryUsableBody } from './recovery-contracts.js';
import { fitsReceived, confirmedLot } from './recovery-domain.js';
import { ServiceError, invalid, unavailable } from './errors.js';

type Kind = 'delivery.match'|'delivery.register'|'delivery.arrival'|'delivery.usable';
type Arrival = z.infer<typeof deliveryArrivalBody>;
type Usable = z.infer<typeof deliveryUsableBody>;
interface SourceRow {
  source_id:string; line_id:string; segment_key:string; food_name:string; exclusion_tags:string[];
  matches: {occurrenceId:string;mealRevision:number;ingredientId:string}[];
  arrival: Arrival|null; usable: Usable|null; arrival_recorded: Date|null; usable_recorded: Date|null;
}

const stale = () => new ServiceError(409, 'stale_supply', 'Reopen the delivery and review the latest observation.');
function requirePlaced(shop: Shop, allowClosed = false) {
  if (shop.placed_revision === null || (shop.phase !== 'placed' && !(allowClosed && shop.phase === 'closed'))) {
    throw new ServiceError(409,'placed_order_required','Open the placed order for this delivery.');
  }
}

// Read the meal versions reviewed at checkout. Erasure removes the joined facts.
const sealedMeals = `SELECT m.occurrence_id AS "occurrenceId",m.revision,m.meal
  FROM ritc.shop_snapshot ss
  CROSS JOIN LATERAL jsonb_array_elements(ss.snapshot->'mealRefs') ref
  JOIN ritc.shared_meal_revision m ON m.household_id=ss.household_id AND m.shop_id=ss.shop_id
    AND m.occurrence_id=(ref->>'occurrenceId')::uuid AND m.revision=(ref->>'revision')::integer
  WHERE ss.household_id=$1 AND ss.shop_id=$2 AND ss.revision=$3 AND m.meal IS NOT NULL`;

// Physical observations and reviewed ingredient identity have independent heads.
const heads = `SELECT s.*,matches.current AS matches,a.body AS arrival,a.recorded_at AS arrival_recorded,u.body AS usable,u.recorded_at AS usable_recorded
  FROM ritc.delivery_source s
  LEFT JOIN LATERAL (SELECT COALESCE(jsonb_agg(jsonb_build_object('occurrenceId',r.occurrence_id,
    'mealRevision',r.meal_revision,'ingredientId',r.ingredient_id) ORDER BY r.occurrence_id,r.ingredient_id)
    FILTER (WHERE r.matched),'[]'::jsonb) AS current FROM
    (SELECT DISTINCT ON (occurrence_id,meal_revision,ingredient_id) * FROM ritc.delivery_ingredient_review
      WHERE household_id=s.household_id AND shop_id=s.shop_id AND source_id=s.source_id
      ORDER BY occurrence_id,meal_revision,ingredient_id,supply_revision DESC) r) matches ON true
  LEFT JOIN LATERAL (SELECT body,recorded_at FROM ritc.delivery_observation WHERE household_id=s.household_id
    AND shop_id=s.shop_id AND source_id=s.source_id AND kind='arrival' ORDER BY supply_revision DESC LIMIT 1) a ON true
  LEFT JOIN LATERAL (SELECT body,recorded_at FROM ritc.delivery_observation WHERE household_id=s.household_id
    AND shop_id=s.shop_id AND source_id=s.source_id AND kind='usable' ORDER BY supply_revision DESC LIMIT 1) u ON true
  WHERE s.household_id=$1 AND s.shop_id=$2`;

function sourceEvidence(row:SourceRow, asOf:string) {
  // Each newly reviewed physical identity is distinct until deliberately mapped.
  const source = {id:row.source_id, foodId:row.source_id, identityRevision:1};
  const a=row.arrival, u=row.usable;
  const lot=confirmedLot(source,
    a && row.arrival_recorded ? {...a,id:a.observationId,identityRevision:1,recordedAt:row.arrival_recorded.toISOString()} : undefined,
    u && row.usable_recorded ? {...u,id:u.observationId,identityRevision:1,recordedAt:row.usable_recorded.toISOString()} : undefined, asOf);
  return {sourceId:source.id, foodId:source.foodId, lineId:row.line_id, segmentKey:row.segment_key, foodName:row.food_name,
    exclusionTags:row.exclusion_tags, matches:row.matches, arrival:a, usable:u, confirmed:lot??null};
}

export async function readDeliveryCoverage(ctx:Context,shop:Shop) {
  requirePlaced(shop,true);
  const scope=[ctx.householdId,shop.shop_id];
  const meals=await ctx.db.query<SealedMeal>(sealedMeals+" ORDER BY m.meal->>'day',m.occurrence_id",[...scope,shop.placed_revision]);
  const sources=await ctx.db.query<SourceRow>(heads+" AND jsonb_array_length(matches.current)>0 ORDER BY s.source_id",scope);
  const asOf=ctx.now.toISOString();
  return {shopId:shop.shop_id,shopRevision:shop.revision,placedRevision:shop.placed_revision,authorityEpoch:shop.authority_epoch,
    supplyRevision:shop.supply_revision,asOf,...deliveryCoverage(meals.rows,sources.rows.map(row=>sourceEvidence(row,asOf)))};
}

export async function readDelivery(ctx: Context, shop: Shop, cursor: string|null) {
  requirePlaced(shop, true);
  const lines = cursor === null ? (await ctx.db.query(`SELECT lower(line->>'lineId') AS "lineId", line->>'originalItem' AS name
    FROM ritc.shop_snapshot ss CROSS JOIN LATERAL jsonb_array_elements(ss.snapshot->'lines') WITH ORDINALITY AS item(line,position)
    WHERE ss.household_id=$1 AND ss.shop_id=$2 AND ss.revision=$3
      AND NOT (ss.digest=repeat('0',64) AND line->>'originalItem'='Removed item') ORDER BY position`,
    [ctx.householdId,shop.shop_id,shop.placed_revision])).rows : [];
  const meals = cursor === null ? (await ctx.db.query(sealedMeals+" ORDER BY m.meal->>'day',m.occurrence_id",
    [ctx.householdId,shop.shop_id,shop.placed_revision])).rows : [];
  const result = await ctx.db.query<SourceRow>(heads+' AND ($3::uuid IS NULL OR s.source_id>$3) ORDER BY s.source_id LIMIT 51',
    [ctx.householdId,shop.shop_id,cursor]);
  const asOf = ctx.now.toISOString();
  const sources = result.rows.slice(0,50).map(row=>sourceEvidence(row,asOf));
  return {shopId:shop.shop_id, placedRevision:shop.placed_revision, shopRevision:shop.revision, authorityEpoch:shop.authority_epoch,
    supplyRevision:shop.supply_revision, asOf, coverageAvailable:true, lines, meals, sources, nextCursor:result.rows.length>50?sources.at(-1)!.sourceId:null};
}

// Called in HouseholdRepository's household-locked command transaction, after device,
// replay, shopper and checkout-revision validation. The receipt and evidence commit together.
export async function recordDelivery(ctx: Context, shop: Shop, kind: Kind, input: unknown, operationId: string) {
  requirePlaced(shop);
  const scope=[ctx.householdId,shop.shop_id], revision=shop.supply_revision+1;
  let sourceId:string;
  if(kind==='delivery.register') {
    const row=deliverySourceBody.parse(input);
    if(row.supplyRevision!==shop.supply_revision || row.placedRevision!==shop.placed_revision) throw stale();
    const line=await ctx.db.query(`SELECT 1 FROM ritc.shop_snapshot ss, jsonb_array_elements(ss.snapshot->'lines') line
      WHERE ss.household_id=$1 AND ss.shop_id=$2 AND ss.revision=$3 AND lower(line->>'lineId')=$4
      AND NOT (ss.digest=repeat('0',64) AND line->>'originalItem'='Removed item')`,
      [...scope,row.placedRevision,row.lineId]);
    if(!line.rowCount) throw unavailable();
    sourceId=operationId;
    await ctx.db.query(`INSERT INTO ritc.delivery_source(household_id,shop_id,source_id,placed_revision,line_id,segment_key,
      food_name,exclusion_tags,actor_id,operation_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$3)`,
      [...scope,sourceId,row.placedRevision,row.lineId,row.segmentKey,row.foodName,row.exclusionTags,ctx.member.member_id]);
  } else if(kind==='delivery.match') {
    const row=deliveryMatchBody.parse(input);
    if(row.supplyRevision!==shop.supply_revision) throw stale();
    sourceId=row.sourceId;
    const source=(await ctx.db.query<SourceRow>(heads+' AND s.source_id=$3',[...scope,sourceId])).rows[0];
    if(!source) throw unavailable();
    const meal=await ctx.db.query(sealedMeals+` AND m.occurrence_id=$4 AND m.revision=$5
      AND EXISTS(SELECT 1 FROM jsonb_array_elements(m.meal->'planning'->'ingredients') i WHERE (i->>'id')::uuid=$6)`,
      [...scope,shop.placed_revision,row.occurrenceId,row.mealRevision,row.ingredientId]);
    if(!meal.rowCount) throw unavailable();
    if(source.matches.some(m=>m.occurrenceId===row.occurrenceId && m.mealRevision===row.mealRevision &&
      m.ingredientId===row.ingredientId)===row.matched) throw stale();
    await ctx.db.query(`INSERT INTO ritc.delivery_ingredient_review(household_id,shop_id,source_id,occurrence_id,
      meal_revision,ingredient_id,supply_revision,matched,actor_id,operation_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
      [...scope,sourceId,row.occurrenceId,row.mealRevision,row.ingredientId,revision,row.matched,ctx.member.member_id,operationId]);
  } else {
    const row=kind==='delivery.arrival'?deliveryArrivalBody.parse(input):deliveryUsableBody.parse(input);
    if(row.supplyRevision!==shop.supply_revision) throw stale();
    sourceId=row.sourceId;
    const source=(await ctx.db.query<SourceRow>(heads+' AND s.source_id=$3',[...scope,sourceId])).rows[0];
    if(!source) throw unavailable();
    const head=kind==='delivery.arrival'?source.arrival:source.usable;
    if(row.predecessorId!==(head?.observationId??null)) throw stale();
    if('usable' in row) {
      const arrival=source.arrival;
      if(!arrival || row.arrivalObservationId!==arrival.observationId) throw stale();
      const confirmedAt = Date.parse(row.confirmedAt);
      if (confirmedAt > ctx.now.getTime()) throw invalid();
      if (row.usable && (!arrival.received || !arrival.arrivedAt || confirmedAt < Date.parse(arrival.arrivedAt) ||
          !fitsReceived(row.usable,arrival.received))) throw invalid();
    }
    await ctx.db.query(`INSERT INTO ritc.delivery_observation(household_id,shop_id,source_id,observation_id,kind,
      supply_revision,body,actor_id,operation_id,recorded_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
      [...scope,sourceId,row.observationId,kind==='delivery.arrival'?'arrival':'usable',revision,row,ctx.member.member_id,operationId,ctx.now]);
  }
  await ctx.db.query('UPDATE ritc.shop SET supply_revision=$3 WHERE household_id=$1 AND shop_id=$2',[...scope,revision]);
  return {sourceId,supplyRevision:revision};
}
