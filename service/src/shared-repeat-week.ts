import {z} from 'zod';
import {digest} from './database.js';
import {ServiceError, unavailable} from './errors.js';
import type {Context, HouseholdRepository, Shop} from './repository.js';
import type {MealMoves} from './meal-moves.js';
import type {BillingService} from './billing/service.js';
import {reviewedID} from './reviewed-identity.js';
import {sharedMealSchema, type SharedMealValue} from './shared-meal-planning.js';

const id = z.uuid().transform(value => value.toLowerCase());
const selection = z.object({
  sourceId: id,
  sourceRevision: z.number().int().positive(),
  day: z.iso.date()
}).strict();

export const repeatWeekStop = z.object({
  planId: id,
  weekStart: z.iso.date(),
  authorityEpoch: z.number().int().positive(),
  grantRevision: z.number().int().nonnegative()
}).strict();

export const repeatWeekStart = repeatWeekStop.extend({
  shopRevision: z.number().int().positive(),
  selections: z.array(selection).min(1).max(100)
});

type SeriesStep = z.infer<typeof selection> & { targetId: string };
interface SeriesRow {
  actor_id: string;
  plan_id: string;
  week_start: string;
  steps: SeriesStep[];
  receipts: Record<string, string>;
  stopped: boolean;
  request_digest: string;
}
const columns = 'actor_id,plan_id,week_start::text,steps,receipts,stopped,request_digest';

function changedWeek() {
  return new ServiceError(409, 'repeat_week_changed', 'Refresh the shared week and review the remaining dinners.');
}

function shiftedDay(day: string, offset: number) {
  const date = new Date(day + 'T12:00:00Z');
  date.setUTCDate(date.getUTCDate() + offset);
  return date.toISOString().slice(0, 10);
}

async function reviewAccess(moves: MealMoves, billing: BillingService | undefined, ctx: Context,
                            shopId: string, readOnly = false) {
  const grant = await moves.context(ctx, shopId, readOnly);
  if (!billing || (!readOnly && grant.shop.phase !== 'draft')) throw unavailable();

  // The meal planning grant already checks the other adult's seat.
  if (grant.shopper) await billing.requirePaidSeat(ctx);
  return grant;
}

function seriesResponse(row: SeriesRow | undefined) {
  if (!row) return {series: null};
  return {
    series: {
      planId: row.plan_id,
      weekStart: row.week_start,
      steps: row.steps,
      receipts: row.receipts,
      stopped: row.stopped
    }
  };
}

export async function readRepeatWeek(moves: MealMoves, billing: BillingService | undefined,
                                     ctx: Context, shopId: string, week: string) {
  const {shop, grantRevision} = await reviewAccess(moves, billing, ctx, shopId, true);
  const result = await ctx.db.query<SeriesRow>(`
    SELECT ${columns} FROM ritc.shared_repeat_week
    WHERE household_id=$1 AND shop_id=$2 AND authority_epoch=$3 AND grant_revision=$4 AND week_start=$5
    ORDER BY created_at DESC,plan_id LIMIT 1`,
    [ctx.householdId, shopId, shop.authority_epoch, grantRevision, z.iso.date().parse(week)]);
  return seriesResponse(result.rows[0]);
}

async function priorSubmission(ctx: Context, shopId: string, planId: string, fingerprint: string) {
  const result = await ctx.db.query<SeriesRow>(`
    SELECT ${columns} FROM ritc.shared_repeat_week
    WHERE household_id=$1 AND shop_id=$2 AND plan_id=$3`, [ctx.householdId, shopId, planId]);
  const prior = result.rows[0];
  if (prior && prior.request_digest !== fingerprint) throw changedWeek();
  return prior;
}

export async function startRepeatWeek(repository: HouseholdRepository, moves: MealMoves,
                                      billing: BillingService | undefined, ctx: Context, shopId: string,
                                      input: z.infer<typeof repeatWeekStart>) {
  const {shop, grantRevision} = await reviewAccess(moves, billing, ctx, shopId);
  if (shop.authority_epoch !== input.authorityEpoch || grantRevision !== input.grantRevision) {
    throw changedWeek();
  }

  const fingerprint = digest({member: ctx.member.member_id, input});
  const prior = await priorSubmission(ctx, shopId, input.planId, fingerprint);
  if (prior) return seriesResponse(prior);

  const sourceIds = new Set(input.selections.map(row => row.sourceId));
  if (shop.revision !== input.shopRevision || sourceIds.size !== input.selections.length) throw changedWeek();
  const meals = await repository.meals(ctx, shopId);
  if (meals.length + input.selections.length > 100) {
    throw new ServiceError(409, 'meal_limit', 'Review the remaining meal slots before starting this week.');
  }

  const byId = new Map(meals.map(meal => [meal.occurrenceId, meal]));
  const previousWeek = shiftedDay(input.weekStart, -7);
  const followingWeek = shiftedDay(input.weekStart, 7);
  const steps = input.selections.map(row => {
    const original = byId.get(row.sourceId);
    if (!original || original.revision !== row.sourceRevision) throw changedWeek();
    const meal = sharedMealSchema.parse(original.meal);
    if (meal.kind !== 'dinner' || !meal.day || meal.day < previousWeek || meal.day >= input.weekStart) {
      throw changedWeek();
    }
    if (row.day < input.weekStart || row.day >= followingWeek) throw changedWeek();

    const targetId = reviewedID(shopId, 'shared-repeat-week-v1', row.sourceId);
    if (byId.has(targetId)) throw changedWeek();
    return {...row, targetId};
  });

  const inserted = await ctx.db.query<SeriesRow>(`
    INSERT INTO ritc.shared_repeat_week
      (household_id,shop_id,plan_id,actor_id,authority_epoch,grant_revision,week_start,
       request_digest,steps,basket_revision,store_revision)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT DO NOTHING RETURNING ${columns}`,
    [ctx.householdId, shopId, input.planId, ctx.member.member_id, input.authorityEpoch, grantRevision,
     input.weekStart, fingerprint, JSON.stringify(steps), shop.revision, shop.store_basis_revision ?? null]);
  if (inserted.rows[0]) return seriesResponse(inserted.rows[0]);

  // A simultaneous retry can win the insert. Only the same actor and exact selections
  // may receive its receipt. A different series for the same week needs a new review.
  const concurrent = await priorSubmission(ctx, shopId, input.planId, fingerprint);
  if (!concurrent) throw changedWeek();
  return seriesResponse(concurrent);
}

export async function stopRepeatWeek(moves: MealMoves, billing: BillingService | undefined,
                                     ctx: Context, shopId: string, input: z.infer<typeof repeatWeekStop>) {
  const {shop, grantRevision} = await reviewAccess(moves, billing, ctx, shopId);
  if (shop.authority_epoch !== input.authorityEpoch || grantRevision !== input.grantRevision) {
    throw changedWeek();
  }
  const result = await ctx.db.query<SeriesRow>(`
    UPDATE ritc.shared_repeat_week SET stopped=true
    WHERE household_id=$1 AND shop_id=$2 AND authority_epoch=$3 AND grant_revision=$4 AND week_start=$5 AND plan_id=$6
    RETURNING ${columns}`,
    [ctx.householdId, shopId, input.authorityEpoch, grantRevision, input.weekStart, input.planId]);
  if (!result.rows[0]) throw changedWeek();
  return seriesResponse(result.rows[0]);
}

async function recheckPlanningAdult(ctx: Context, shop: Shop, actorId: string, billing: BillingService) {
  if (actorId === ctx.member.member_id) return;
  const result = await ctx.db.query<{member_id: string; kind: string}>(`
    SELECT m.member_id,m.kind FROM ritc.member m
    JOIN ritc.meal_planner p ON p.household_id=m.household_id AND p.planner_id=m.member_id
    WHERE m.household_id=$1 AND m.member_id=$2 AND m.state='active' AND m.kind='adult'
      AND p.shop_id=$3 AND p.authority_epoch=$4`, [ctx.householdId, actorId, shop.shop_id, shop.authority_epoch]);
  const author = result.rows[0];
  if (!author) throw changedWeek();
  await billing.requirePaidSeat({...ctx, member: author});
}

/** The household transaction serializes reads with seat, grant and shopper changes. */
async function authorizedSeries(ctx: Context, billing: BillingService | undefined, shop: Shop, planId: string) {
  if (!billing) throw unavailable();
  await billing.requirePaidSeat(ctx);
  const result = await ctx.db.query<SeriesRow>(`
    SELECT ${columns} FROM ritc.shared_repeat_week w
    WHERE w.household_id=$1 AND w.shop_id=$2 AND w.plan_id=$3 AND w.authority_epoch=$4
      AND w.grant_revision=coalesce((SELECT revision FROM ritc.meal_planner p
                                     WHERE p.household_id=w.household_id AND p.shop_id=w.shop_id),0)
    FOR UPDATE`, [ctx.householdId, shop.shop_id, planId, shop.authority_epoch]);
  const series = result.rows[0];
  if (!series) throw changedWeek();
  await recheckPlanningAdult(ctx, shop, series.actor_id, billing);
  return series;
}

export async function assertRepeatStepReplay(ctx: Context, billing: BillingService | undefined, shop: Shop,
                                             planId: string, targetId: string, operationId: string) {
  const series = await authorizedSeries(ctx, billing, shop, planId);
  if (series.receipts[targetId] !== operationId) throw changedWeek();
}

/** Runs inside the existing shopper-authorized shop.patch transaction. */
export async function acceptRepeatStep(repository: HouseholdRepository, billing: BillingService | undefined,
                                       ctx: Context, shop: Shop, planId: string, targetId: string,
                                       meal: SharedMealValue | null, operationId: string) {
  if (!meal) throw unavailable();
  const series = await authorizedSeries(ctx, billing, shop, planId);
  const step = series.steps.find(row => row.targetId === targetId);
  if (series.stopped || !step || series.receipts[targetId]) throw changedWeek();

  const meals = await repository.meals(ctx, shop.shop_id);
  const original = meals.find(row => row.occurrenceId === step.sourceId);
  if (!original || original.revision !== step.sourceRevision) throw changedWeek();
  const expected = sharedMealSchema.parse(original.meal);
  expected.day = step.day;
  if (expected.planning) {
    delete expected.planning.deadline;
    delete expected.planning.completedSteps;
  }
  if (digest(expected) !== digest(meal)) throw changedWeek();

  await ctx.db.query(`
    UPDATE ritc.shared_repeat_week SET receipts=receipts || jsonb_build_object($4::text,$5::text)
    WHERE household_id=$1 AND shop_id=$2 AND plan_id=$3`,
    [ctx.householdId, shop.shop_id, planId, targetId, operationId]);
}
