import {z} from 'zod';
import {digest} from './database.js';
import {ServiceError, unavailable} from './errors.js';
import {reviewedID} from './reviewed-identity.js';
import {loadDemand, previewDemand} from './shared-demand-repository.js';
import {assertTrackingV1} from './shared-demand-tracking-repository.js';
import {basketDifference, needsReview, removeNight, selectedNights, type WeekFood} from './saved-week-reconciliation.js';
import type {BillingService} from './billing/service.js';
import type {MealMoves} from './meal-moves.js';
import type {HouseholdRepository, Context, Shop} from './repository.js';

const id = z.uuid().toLowerCase();
const revision = z.number().int().positive();
const choice = z.object({week:z.iso.date(), ids:z.array(id).min(1).max(7), shopRevision:revision,
  authorityEpoch:revision, grantRevision:z.number().int().nonnegative()}).strict();
const confirmation = choice.extend({planId:id, digest:z.string().regex(/^[a-f0-9]{64}$/)});
const action = z.object({planId:id, id}).strict();
type Choice = z.infer<typeof choice>;
type Step = {id:string; revision:number; day:string};
type Saved = {plan_id:string; initial_revision:number; review_digest:string; steps:Step[]; receipts:string[]; stopped:boolean};
const columns = 'plan_id,initial_revision,review_digest,steps,receipts,stopped';
const stale = () => new ServiceError(409,'saved_week_changed','Reload the saved week and review the remaining dinners.');
function status(row:Saved, shop:Shop) {
  return {planId:row.plan_id, steps:row.steps, completed:row.receipts.length, stopped:row.stopped,
    conflicted:row.receipts.length < row.steps.length && shop.revision !== row.initial_revision + row.receipts.length};
}
async function foodAt(repo:HouseholdRepository, ctx:Context, shop:Shop):Promise<WeekFood|null> {
  if (shop.store_review_required || shop.demand_review_required) needsReview();
  const current = await loadDemand(ctx,shop);
  if (!current) return null;
  await assertTrackingV1(repo,ctx,shop);
  const row = (await ctx.db.query('SELECT pack_review FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=$3',
    [ctx.householdId,shop.shop_id,current.graph.revision])).rows[0];
  if (!Array.isArray(row?.pack_review)) needsReview();
  return {graph:current.graph,packs:row.pack_review};
}
export async function savedWeekRoute(repo:HouseholdRepository, moves:MealMoves, billing:BillingService|undefined,
                                    ctx:Context, shopId:string, tail:string, method:string, raw:unknown, query:URLSearchParams) {
  const {shop,shopper,grantRevision} = await moves.context(ctx,shopId,true);
  if (shop.phase !== 'draft' || !billing) throw unavailable();
  if (shopper) await billing.requirePaidSeat(ctx);
  const scope = [ctx.householdId,shop.shop_id,shop.authority_epoch,grantRevision];
  async function latest(week:string) {
    return (await ctx.db.query<Saved>(`SELECT ${columns} FROM ritc.saved_week_change WHERE household_id=$1 AND shop_id=$2 AND authority_epoch=$3 AND grant_revision=$4 AND week_start=$5 ORDER BY created_at DESC,plan_id DESC LIMIT 1`,[...scope,week])).rows[0];
  }
  if (method === 'GET' && tail === '') {
    const row = await latest(z.iso.date().parse(query.get('week')));
    return {series:row ? status(row,shop) : null};
  }
  if (method !== 'POST') throw unavailable();
  async function review(input:Choice) {
    if (input.shopRevision !== shop.revision || input.authorityEpoch !== shop.authority_epoch || input.grantRevision !== grantRevision) throw stale();
    const meals = await repo.meals(ctx,shopId);
    const steps = selectedNights(meals,input.week,input.ids);
    const initial = shopper ? await repo.lines(ctx,shopId) : [];
    const original = shopper ? await foodAt(repo,ctx,shop) : null;
    let food = original, lines = initial;
    if (shopper) {
      for (const step of steps) {
        const change = removeNight(lines,food,step.id,reviewedID(step.id,'week-preview',shop.revision),ctx.now.toISOString());
        lines = change.lines;
        food = change.food;
      }
    }
    const basket = basketDifference(initial,lines,original,food);
    const proof = digest({scope,week:input.week,shopRevision:shop.revision,steps,meals,basket,
      graph:original?.graph??null, packs:original?.packs??null, lines:initial, quote:shopper ? shop.quote : null});
    return {steps,basket,digest:proof,shopper};
  }
  if (tail === '/preview') return review(choice.parse(raw));
  if (!shopper) throw unavailable();
  if (tail === '/confirm') {
    const input = confirmation.parse(raw);
    const prior = await latest(input.week);
    if (prior?.plan_id === input.planId) {
      if (prior.review_digest !== input.digest || digest(prior.steps.map(s=>s.id).sort()) !== digest([...input.ids].sort())) throw stale();
      return {series:status(prior,shop)};
    }
    if (prior && !prior.stopped && prior.receipts.length < prior.steps.length) throw stale();
    const fresh = await review(input);
    if (fresh.digest !== input.digest) throw stale();
    const inserted = await ctx.db.query<Saved>(`INSERT INTO ritc.saved_week_change
      (household_id,shop_id,authority_epoch,grant_revision,week_start,actor_id,plan_id,initial_revision,review_digest,steps)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING ${columns}`,
      [...scope,input.week,ctx.member.member_id,input.planId,shop.revision,input.digest,JSON.stringify(fresh.steps)]);
    return {series:status(inserted.rows[0]!,shop)};
  }
  if (tail !== '/step' && tail !== '/stop') throw unavailable();
  const input = action.parse(raw);
  const row = (await ctx.db.query<Saved>(`SELECT ${columns} FROM ritc.saved_week_change WHERE household_id=$1 AND shop_id=$2
    AND authority_epoch=$3 AND grant_revision=$4 AND plan_id=$5 AND actor_id=$6 FOR UPDATE`,[...scope,input.planId,ctx.member.member_id])).rows[0];
  if (!row) throw unavailable();
  const index = row.steps.findIndex(step => step.id === input.id);
  if (index < 0) throw stale();
  if (index < row.receipts.length) return {series:status(row,shop)};
  if (index !== row.receipts.length) throw stale();
  if (tail === '/stop') {
    await ctx.db.query('UPDATE ritc.saved_week_change SET stopped=true WHERE household_id=$1 AND shop_id=$2 AND plan_id=$3',
      [ctx.householdId,shopId,input.planId]);
    return {series:status({...row,stopped:true},shop)};
  }
  if (row.stopped || shop.revision !== row.initial_revision + index) throw stale();
  const step = row.steps[index]!;
  const occurrence = (await repo.meals(ctx,shopId)).find(m => m.occurrenceId === step.id);
  if (!occurrence || occurrence.revision !== step.revision) throw stale();
  const original = await foodAt(repo,ctx,shop);
  const clientKey = reviewedID(row.plan_id,'remove-saved-night',step.id);
  const next = removeNight(await repo.lines(ctx,shopId),original,step.id,clientKey,ctx.now.toISOString());
  const base = {shopRevision:shop.revision,authorityEpoch:shop.authority_epoch};
  const body = {lines:next.lines, quote:shop.quote, mealEdit:{occurrenceId:step.id,baseMealRevision:step.revision,meal:null}};
  let demandReview;
  if (original && next.food && next.change) {
    const p = await previewDemand(repo,ctx,shop,{mode:'change',base:{...base,graphRevision:original.graph.revision},
      change:next.change,packs:next.food.packs,action:{kind:'shop.patch',body}});
    demandReview = {previewId:p.previewId,previewDigest:p.previewDigest};
  }
  // The normal patch and per-occurrence receipt commit in the same authorized transaction.
  const window = await repo.window(ctx);
  const result = z.object({operationId:id, shopRevision:revision}).parse(await repo.execute(ctx,{
    v:1,replayWindow:window.id,clientKey,shopId, kind:'shop.patch',base,body:{...body,...(demandReview?{demandReview}:{})}
  },billing));
  if (result.shopRevision !== shop.revision + 1) throw stale();
  const receipts = [...row.receipts,result.operationId];
  await ctx.db.query('UPDATE ritc.saved_week_change SET receipts=$4 WHERE household_id=$1 AND shop_id=$2 AND plan_id=$3',
    [ctx.householdId,shopId,row.plan_id,JSON.stringify(receipts)]);
  return {series:status({...row,receipts},{...shop,revision:result.shopRevision})};
}
