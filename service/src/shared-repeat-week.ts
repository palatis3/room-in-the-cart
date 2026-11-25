import {z} from 'zod';
import {digest} from './database.js';
import {ServiceError, unavailable} from './errors.js';
import type {Context, HouseholdRepository, Shop} from './repository.js';
import type {MealMoves} from './meal-moves.js';
import type {BillingService} from './billing/service.js';
import {reviewedID} from './reviewed-identity.js';
import {sharedMealSchema, type SharedMealValue} from './shared-meal-planning.js';

const id=z.uuid().transform(value=>value.toLowerCase());
const source=z.object({sourceId:id,sourceRevision:z.number().int().positive(),day:z.iso.date()}).strict();
const base=z.object({planId:id,weekStart:z.iso.date(),authorityEpoch:z.number().int().positive(),grantRevision:z.number().int().nonnegative()}).strict();
export const repeatWeekStart=base.extend({shopRevision:z.number().int().positive(),selections:z.array(source).min(1).max(100)});
export const repeatWeekStop=base;
const step=source.extend({targetId:id});
type Step=z.infer<typeof step>;
interface Row {actor_id:string; plan_id:string; week_start:string; steps:Step[]; receipts:Record<string,string>; stopped:boolean; request_digest:string}
const conflict=()=>new ServiceError(409,'repeat_week_changed','Refresh the shared week and review the remaining dinners.');
const localDay=(day:string,offset:number)=>{
  const date=new Date(day+'T12:00:00Z');
  date.setUTCDate(date.getUTCDate()+offset);
  return date.toISOString().slice(0,10);
};

async function authorized(moves:MealMoves,billing:BillingService|undefined,ctx:Context,shopId:string, reading=false) {
  const grant=await moves.context(ctx,shopId,reading);
  if (!billing || (!reading && grant.shop.phase!=='draft')) throw unavailable();
  if (grant.shopper) await billing.requirePaidSeat(ctx);
  return grant;
}
function visible(row:Row|undefined) {
  return {series:row ? {planId:row.plan_id,weekStart:row.week_start,steps:row.steps,receipts:row.receipts,stopped:row.stopped}:null};
}
const columns='actor_id,plan_id,week_start::text,steps,receipts,stopped,request_digest';
export async function readRepeatWeek(moves:MealMoves,billing:BillingService|undefined,ctx:Context,shopId:string,week:string) {
  const {shop,grantRevision}=await authorized(moves,billing,ctx,shopId,true);
  const result=await ctx.db.query<Row>(`SELECT ${columns} FROM ritc.shared_repeat_week WHERE household_id=$1 AND shop_id=$2
    AND authority_epoch=$3 AND grant_revision=$4 AND week_start=$5 ORDER BY created_at DESC,plan_id LIMIT 1`,
    [ctx.householdId,shopId,shop.authority_epoch,grantRevision,z.iso.date().parse(week)]);
  return visible(result.rows[0]);
}
export async function startRepeatWeek(repository:HouseholdRepository,moves:MealMoves,billing:BillingService|undefined,ctx:Context,shopId:string,input:z.infer<typeof repeatWeekStart>) {
  const {shop,grantRevision}=await authorized(moves,billing,ctx,shopId);
  if (shop.authority_epoch!==input.authorityEpoch || grantRevision!==input.grantRevision) throw conflict();
  const scope=[ctx.householdId,shopId,input.planId];
  const existing=(await ctx.db.query<Row>(`SELECT ${columns} FROM ritc.shared_repeat_week WHERE household_id=$1 AND shop_id=$2 AND plan_id=$3`,scope)).rows[0];
  const fingerprint=digest({member:ctx.member.member_id,input});
  if(existing) {if(existing.request_digest!==fingerprint) throw conflict();return visible(existing);}
  if(shop.revision!==input.shopRevision || new Set(input.selections.map(s=>s.sourceId)).size!==input.selections.length)throw conflict();
  const meals=await repository.meals(ctx,shopId);
  if (meals.length + input.selections.length > 100) {
    throw new ServiceError(409,'meal_limit','Review the remaining meal slots before starting this week.');
  }
  const start=localDay(input.weekStart,-7),end=localDay(input.weekStart,7);
  const steps=input.selections.map(selection=>{
    const record=meals.find(m=>m.occurrenceId===selection.sourceId);
    if(!record || record.revision!==selection.sourceRevision) throw conflict();
    const meal=sharedMealSchema.parse(record.meal);
    if(meal.kind!=='dinner' || !meal.day || meal.day<start || meal.day>=input.weekStart ||
       selection.day<input.weekStart || selection.day>=end) throw conflict();
    const targetId=reviewedID(shopId,'shared-repeat-week-v1',selection.sourceId);
    if(meals.some(m=>m.occurrenceId===targetId))throw conflict();
    return {...selection,targetId};
  });
  const result=await ctx.db.query<Row>(`INSERT INTO ritc.shared_repeat_week
    (household_id,shop_id,plan_id,actor_id,authority_epoch,grant_revision,week_start,request_digest,steps,basket_revision,store_revision)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT DO NOTHING RETURNING ${columns}`,
    [...scope,ctx.member.member_id,input.authorityEpoch,input.grantRevision,input.weekStart,fingerprint,JSON.stringify(steps),shop.revision,shop.store_basis_revision??null]);
  if(!result.rowCount)throw conflict();
  return visible(result.rows[0]);
}
export async function stopRepeatWeek(moves:MealMoves,billing:BillingService|undefined,ctx:Context,shopId:string,input:z.infer<typeof repeatWeekStop>) {
  const {shop,grantRevision}=await authorized(moves,billing,ctx,shopId);
  if(shop.authority_epoch!==input.authorityEpoch || grantRevision!==input.grantRevision)throw conflict();
  const result=await ctx.db.query<Row>(`UPDATE ritc.shared_repeat_week SET stopped=true WHERE household_id=$1 AND shop_id=$2
   AND authority_epoch=$3 AND grant_revision=$4 AND week_start=$5 AND plan_id=$6 RETURNING ${columns}`,
    [ctx.householdId,shopId,input.authorityEpoch,input.grantRevision,input.weekStart,input.planId]);
  if(!result.rowCount)throw conflict();
  return visible(result.rows[0]);
}

export async function acceptRepeatStep(repository:HouseholdRepository,billing:BillingService|undefined,ctx:Context,shop:Shop,
 planId:string,targetId:string,meal:SharedMealValue|null,operationId:string) {
  if(!billing || !meal)throw unavailable();
  await billing.requirePaidSeat(ctx);
  const result=await ctx.db.query<Row>(`SELECT ${columns} FROM ritc.shared_repeat_week w WHERE w.household_id=$1 AND w.shop_id=$2 AND w.plan_id=$3
    AND NOT w.stopped AND w.authority_epoch=$4 AND w.grant_revision=coalesce((SELECT revision FROM ritc.meal_planner p WHERE
    p.household_id=w.household_id AND p.shop_id=w.shop_id),0) FOR UPDATE`,[ctx.householdId,shop.shop_id,planId,shop.authority_epoch]);
  const plan=result.rows[0],row=plan?.steps.find(step=>step.targetId===targetId);
  if(!plan || !row || plan.receipts[targetId])throw conflict();
  if(plan.actor_id!==ctx.member.member_id) {
    const author=await ctx.db.query<{member_id:string;kind:string}>(`SELECT m.member_id,m.kind FROM ritc.member m
      JOIN ritc.meal_planner p ON p.household_id=m.household_id AND p.planner_id=m.member_id
      WHERE m.household_id=$1 AND m.member_id=$2 AND m.state='active' AND m.kind='adult'
      AND p.shop_id=$3 AND p.authority_epoch=$4`,[ctx.householdId,plan.actor_id,shop.shop_id,shop.authority_epoch]);
    if(!author.rows[0])throw conflict();
    await billing.requirePaidSeat({...ctx,member:author.rows[0]});
  }
  const original=(await repository.meals(ctx,shop.shop_id)).find(old=>old.occurrenceId===row.sourceId);
  if(!original || original.revision!==row.sourceRevision)throw conflict();
  const expected=sharedMealSchema.parse(original.meal);
  expected.day=row.day;
  if(expected.planning){delete expected.planning.deadline;delete expected.planning.completedSteps;}
  if(digest(expected)!==digest(meal))throw conflict();
  await ctx.db.query(`UPDATE ritc.shared_repeat_week SET receipts=receipts || jsonb_build_object($4::text,$5::text)
    WHERE household_id=$1 AND shop_id=$2 AND plan_id=$3`,[ctx.householdId,shop.shop_id,planId,targetId,operationId]);
}
