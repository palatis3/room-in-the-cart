import {requireAssistance} from './shared-fallback-options.js';
import type {BillingService} from './billing/service.js';
import { chooseTonight } from './contracts.js';
import { z } from 'zod';
import { digest } from './database.js';
import { refresh, ServiceError, unavailable } from './errors.js';
import { mealConstraints, mealEligibility, mealEvidence } from './meal-preferences.js';
import { householdPantryEpoch, pantryRevision, tonightStock } from './pantry-lots.js';
import { amount, dimension, inUnit, min, sub, zero, type Rat } from './physical-quantity.js';
import { householdStockCommitments } from './shared-recovery-basis.js';
import { loadRecoveryPublication } from './shared-recovery-publication.js';
import type { Context, HouseholdRepository, Shop } from './repository.js';
import { mealQuantity, sharedMealSchema } from './shared-meal-planning.js';

const id = z.uuid().toLowerCase(),
  rev = z.number().int().positive().max(2147483647);
const label = z
  .string()
  .trim()
  .min(1)
  .max(240)
  .refine((s) => !/[\p{Cc}\uD800-\uDFFF]/u.test(s));
const productReview = mealEvidence
  .pick({ reviewedIngredientDetails: true, brands: true })
  .extend({
    lotId: id,
    observationId: id,
  })
  .strict()
  .refine((review) => review.reviewedIngredientDetails != null || review.brands != null);

const recipe = z
  .object({
    title: label,
    portions: z.number().int().min(1).max(1000),
    minutes: z.number().int().min(0).max(525600).nullable(),
    ingredients: z
      .array(
        z
          .object({
            id,
            name: label,
            quantity: mealQuantity.nullable(),
            reviewedLotIds: z
              .array(id)
              .max(12)
              .default([])
              .refine((ids) => new Set(ids).size === ids.length),
          })
          .strict(),
      )
      .min(1)
      .max(60),
    preferenceEvidence: mealEvidence.nullish(),
    productReviews: z.array(productReview).max(60).optional(),
  })
  .strict()
  .refine((r) => {
    const reviews = r.productReviews ?? [],
      bound = new Set(r.ingredients.flatMap((i) => i.reviewedLotIds));
    return (
      reviews.every((review) => bound.has(review.lotId)) &&
      new Set(reviews.map((review) => review.lotId)).size === reviews.length
    );
  })
  .refine(
    (r) =>
      new Set(r.ingredients.map((i) => i.id)).size === r.ingredients.length &&
      Buffer.byteLength(JSON.stringify(r)) <= 60000,
  );
type Recipe = z.infer<typeof recipe>;
const save = z
  .object({
    v: z.literal(1),
    clientKey: id,
    replayWindow: id,
    grantEpoch: rev.or(z.literal(0)),
    recipeId: id,
    baseRevision: rev.nullable(),
    reviewed: z.literal(true),
    recipe,
  })
  .strict();

function reviewedStock(ctx: Context, ids: string[]) {
  return tonightStock(ctx, ids, (scope, input, requested) =>
    householdStockCommitments(scope, input, requested, loadRecoveryPublication),
  );
}

const linked = (r: Recipe) => r.ingredients.flatMap((i) => i.reviewedLotIds);
function authority(ctx: Context) {
  const epoch = householdPantryEpoch(ctx);
  if (epoch === null) throw unavailable();
  return epoch;
}

export async function saveTonightRecipe(ctx: Context, input: unknown) {
  const grantEpoch = authority(ctx);
  if (!ctx.member.organizer) throw unavailable();
  const command = save.parse(input);
  if (command.grantEpoch !== grantEpoch) throw refresh();
  const actorId = ctx.member.member_id;
  const window = await ctx.db.query(
    `SELECT FROM ritc.replay_window
   WHERE household_id=$1 AND window_id=$2 AND member_id=$3 AND device_id=$4
     AND revoked_at IS NULL AND expires_at>$5`,
    [ctx.householdId, command.replayWindow, actorId, ctx.deviceId, ctx.now],
  );
  if (!window.rowCount) throw refresh();

  // HouseholdRepository.authorized holds the household row FOR UPDATE until commit.
  const source = (
    await ctx.db.query<{ actor_id: string; revision: number; active: boolean }>(
      `SELECT actor_id,revision,recipe IS NOT NULL AS active
   FROM ritc.tonight_recipe WHERE household_id=$1 AND recipe_id=$2`,
      [ctx.householdId, command.recipeId],
    )
  ).rows[0];
  const prior = (
    await ctx.db.query<{
      recipe_id: string;
      revision: number;
      device_id: string;
      fingerprint: string | null;
    }>(
      `SELECT recipe_id,revision,device_id,fingerprint
   FROM ritc.tonight_recipe_write WHERE household_id=$1 AND actor_id=$2 AND client_key=$3`,
      [ctx.householdId, actorId, command.clientKey],
    )
  ).rows[0];
  const fingerprint = digest(command);
  if (source && (!source.active || source.actor_id !== actorId)) throw refresh();
  if (prior) {
    if (
      prior.fingerprint !== fingerprint ||
      prior.device_id !== ctx.deviceId ||
      prior.recipe_id !== command.recipeId ||
      prior.revision !== source?.revision
    )
      throw refresh();
    return { recipeId: prior.recipe_id, recipeRevision: prior.revision };
  }
  if ((source?.revision ?? null) !== command.baseRevision) throw refresh();
  if (!source) {
    const count = await ctx.db.query<{ count: number }>(
      'SELECT count(*)::int count FROM ritc.tonight_recipe WHERE household_id=$1 AND recipe IS NOT NULL',
      [ctx.householdId],
    );
    if (count.rows[0]!.count >= 100)
      throw new ServiceError(409, 'recipe_limit', 'Review your existing household recipes.');
  }
  const lotIds = [...new Set(linked(command.recipe))];
  const lots = await reviewedStock(ctx, lotIds);
  const observations = new Map(lots.map((lot) => [lot.id, lot.observed?.observationId]));
  if (
    lots.length !== lotIds.length ||
    command.recipe.productReviews?.some((review) => observations.get(review.lotId) !== review.observationId)
  )
    throw refresh();
  const revision = (source?.revision ?? 0) + 1;
  const saved = await ctx.db.query(
    `INSERT INTO ritc.tonight_recipe(household_id,recipe_id,actor_id,revision,recipe)
   VALUES ($1,$2,$3,$4,$5) ON CONFLICT(household_id,recipe_id) DO UPDATE SET revision=$4,recipe=$5
   WHERE ritc.tonight_recipe.revision=$6 AND ritc.tonight_recipe.actor_id=$3 AND ritc.tonight_recipe.recipe IS NOT NULL`,
    [ctx.householdId, command.recipeId, actorId, revision, command.recipe, command.baseRevision],
  );
  if (!saved.rowCount) throw refresh();
  await ctx.db.query(
    `INSERT INTO ritc.tonight_recipe_write(household_id,actor_id,client_key,device_id,recipe_id,revision,fingerprint)
   VALUES($1,$2,$3,$4,$5,$6,$7)`,
    [ctx.householdId, actorId, command.clientKey, ctx.deviceId, command.recipeId, revision, fingerprint],
  );
  return { recipeId: command.recipeId, recipeRevision: revision };
}
type Stock = Awaited<ReturnType<typeof tonightStock>>;
type Settings = Awaited<ReturnType<typeof mealConstraints>>['settings'];
type RecipeRow = { recipe_id: string; actor_id: string; revision: number; recipe: Recipe };
type ExcludedReview = { recipeId: string; recipeRevision: number; reviewedRecipe: Recipe };

function productsForRecipe(recipe: Recipe, stock: Stock, settings: Settings) {
  // A package review applies only to this recipe, lot and physical observation.
  // Updating the count cannot move a previous ingredient/brand attestation to the new head.
  const byLot = new Map(recipe.productReviews?.map((review) => [review.lotId, review]));
  const productRules = settings && {
    ...settings,
    availableAppliances: null,
    maximumEffort: null,
    strictEffort: false,
    timeLimit: null,
  };
  return stock.map((lot) => {
    const previous = byLot.get(lot.id);
    const evidence =
      previous && lot.observed?.observationId === previous.observationId ? previous : undefined;
    return { ...lot, eligibility: mealEligibility(productRules, [lot.name, ...lot.tags], evidence) };
  });
}

function ingredientNeeds(recipe: Recipe, stock: ReturnType<typeof productsForRecipe>, now: Date, balances?: Map<string, Rat>) {
  const available = stock.map((lot) => ({
    id: lot.id,
    quantity: lot.observed?.quantity,
    free: balances?.get(lot.id) ?? (lot.free ? { n: BigInt(lot.free.numerator), d: BigInt(lot.free.denominator) } : null),
    useSoon: lot.useFirstAt !== null && Date.parse(lot.useFirstAt) <= now.getTime() + 3 * 86400000,
    evidenceAt: lot.observed?.confirmedAt ?? null,
    eligible: lot.eligibility.eligible,
  }));
  const remainingByLot = new Map<string, Rat>();
  let usedConfirmedStock = false;
  const ingredients = recipe.ingredients.map((ingredient) => {
    const required = ingredient.quantity;
    const matches = available.filter((lot) => ingredient.reviewedLotIds.includes(lot.id));
    const base = {
      id: ingredient.id,
      name: ingredient.name,
      evidenceAt: matches.flatMap((lot) => (lot.evidenceAt ? [lot.evidenceAt] : [])).sort()[0] ?? null,
    };
    const unknown = { ...base, status: 'unknown' as const, missing: null, useSoon: false };
    if (
      !required ||
      matches.length !== ingredient.reviewedLotIds.length ||
      matches.some(
        (lot) =>
          !lot.eligible || !lot.quantity || !lot.free || dimension(required) !== dimension(lot.quantity),
      )
    )
      return unknown;
    let remaining = amount(required),
      useSoon = false;
    for (const lot of matches) {
      const allocation = min(remaining, lot.free!);
      if (allocation.n > 0n) {
        usedConfirmedStock = true;
        useSoon ||= lot.useSoon;
        lot.free = sub(lot.free!, allocation);
        remainingByLot.set(lot.id, lot.free);
        remaining = sub(remaining, allocation);
      }
      if (remaining.n === 0n) break;
    }
    if (remaining.n === 0n) return { ...base, status: 'covered' as const, missing: null, useSoon };
    const shortfall = inUnit(remaining, required.unit);
    const numerator = Number(shortfall.numerator),
      denominator = Number(shortfall.denominator);
    if (numerator > 1e9 || denominator > 1e9) return unknown;
    return {
      ...base,
      status: 'missing' as const,
      useSoon,
      missing: {
        amount: { numerator, denominator },
        unit: required.unit,
        originalLiteral: denominator === 1 ? String(numerator) : numerator + '/' + denominator,
      },
    };
  });
  return { ingredients, usedConfirmedStock, remainingByLot };
}

async function shopperPriceBasis(ctx: Context) {
  // A new destination's initial quote is reviewed by shop.create. Subsequent quotes,
  // store reviews and financial changes invalidate even an otherwise unchanged meal.
  return (
    await ctx.db.query(
      `SELECT s.shop_id,s.revision,s.authority_epoch,s.store_basis_revision,
      coalesce(f.revision,0) financial_revision, p.observations, p.identity FROM ritc.shop s
    LEFT JOIN ritc.financial_head f USING(household_id,shop_id)
    CROSS JOIN LATERAL (SELECT count(*) observations,bit_xor(hashtextextended(po.observation_id::text,0)) identity
      FROM ritc.price_observation po WHERE po.household_id=s.household_id AND po.shop_id=s.shop_id
      AND po.actor_id=$2 AND po.retired_at IS NULL) p
    WHERE s.household_id=$1 AND s.shopper_id=$2 AND s.history_retired_at IS NULL AND s.phase='draft'
      AND (s.revision>1 OR s.store_basis_revision IS NOT NULL OR f.revision>0 OR p.observations>0)
    ORDER BY s.shop_id`,
      [ctx.householdId, ctx.member.member_id],
    )
  ).rows;
}

async function recentFeedback(ctx: Context) {
  // Only this adult's opted-in reaction to this same recipe revision, cooked on
  // their own shop, can break a tie. Erasure, withdrawal or Undo removes the signal.
  const windowMs = 90 * 86_400_000;
  const { rows } = await ctx.db.query<{ recipe_id: string; direction: number; updated_at: Date }>(
    `
    SELECT DISTINCT ON (c.recipe_id) c.recipe_id, f.updated_at,
      (f.reactions && ARRAY['makeAgain','childrenLikedIt'])::int - ('tooMuchEffort'=ANY(f.reactions))::int AS direction
    FROM ritc.tonight_choice c
    JOIN ritc.tonight_recipe r ON (r.household_id,r.recipe_id,r.revision)=(c.household_id,c.recipe_id,c.recipe_revision)
    JOIN ritc.shop s ON (s.household_id,s.shop_id)=(c.household_id,c.shop_id)
    JOIN ritc.shared_cook k ON (k.household_id,k.shop_id,k.occurrence_id)=(c.household_id,c.shop_id,c.occurrence_id)
    JOIN ritc.operation_response o ON (o.household_id,o.operation_id)=(c.household_id,c.operation_id)
    JOIN ritc.household_meal_feedback f ON (f.household_id,f.cook_id)=(k.household_id,k.operation_id)
    WHERE c.household_id=$1 AND s.shopper_id=$2 AND f.member_id=$2 AND k.undone_by IS NULL
      AND k.meal_revision=(o.response->>'shopRevision')::integer AND cardinality(f.reactions)>0
      AND f.updated_at>$3 AND f.updated_at<=$4
    ORDER BY c.recipe_id, f.updated_at DESC, f.revision DESC`,
    [ctx.householdId, ctx.member.member_id, new Date(ctx.now.getTime() - windowMs), ctx.now],
  );
  // Match private meal feedback: the latest impression replaces older ones and fades linearly to zero.
  return new Map(rows.map((row) => {
    const ageMs = ctx.now.getTime() - row.updated_at.getTime();
    return [row.recipe_id, row.direction * (1 - ageMs / windowMs)];
  }));
}

async function candidates(ctx: Context) {
  const epoch = authority(ctx);
  const revision = await pantryRevision(ctx);
  const profile = await mealConstraints(ctx);
  const { rows } = await ctx.db.query<RecipeRow>(
    'SELECT recipe_id,actor_id,revision,recipe FROM ritc.tonight_recipe WHERE household_id=$1 AND recipe IS NOT NULL ORDER BY recipe_id LIMIT 100',
    [ctx.householdId],
  );
  const stock = await reviewedStock(ctx, [...new Set(rows.flatMap((row) => linked(row.recipe)))]);
  const scope = digest({
    member: ctx.member.member_id,
    household: ctx.householdId,
    epoch,
    pantry: revision,
    profile: profile.revision,
    stock,
    price: await shopperPriceBasis(ctx),
  });
  const stockById = new Map(stock.map((lot, index) => [lot.id, { lot, index }]));
  const feedback = await recentFeedback(ctx);
  let excludedCount = 0;
  const excludedReviewedRecipes: ExcludedReview[] = [];
  const list = rows.flatMap((row) => {
    const source = row.recipe;
    const canEdit = ctx.member.organizer && row.actor_id === ctx.member.member_id;
    const lotIds = new Set(linked(source));
    const sourceStock = [...lotIds]
      .flatMap((id) => {
        const entry = stockById.get(id);
        return entry ? [entry] : [];
      })
      .sort((a, b) => a.index - b.index)
      .map((entry) => entry.lot);
    const labels = sourceStock.flatMap((lot) => [lot.name, ...lot.tags]);
    const eligibility = mealEligibility(
      profile.settings,
      [...source.ingredients.map((i) => i.name), ...labels],
      source.preferenceEvidence ?? undefined,
      source.minutes,
    );
    const products = productsForRecipe(source, sourceStock, profile.settings);
    if (eligibility.blocked.length || products.some((lot) => lot.eligibility.blocked.length)) {
      excludedCount++;
      if (canEdit)
        excludedReviewedRecipes.push({
          recipeId: row.recipe_id,
          recipeRevision: row.revision,
          reviewedRecipe: source,
        });
      return [];
    }
    const { ingredients, usedConfirmedStock } = ingredientNeeds(source, products, ctx.now);
    const selectable =
      eligibility.eligible && usedConfirmedStock && ingredients.every((i) => i.status !== 'unknown');
    const covered = ingredients.filter((i) => i.status === 'covered').length;
    const item = {
      recipeId: row.recipe_id,
      recipeRevision: row.revision,
      title: source.title,
      portions: source.portions,
      minutes: source.minutes,
      status: selectable ? 'eligible' : 'unresolved',
      ...(canEdit ? { reviewedRecipe: source } : {}),
      ingredients,
      checkoutEstimate: selectable && covered === ingredients.length ? 'noPurchaseNeeded' : 'incomplete',
      reviewToken: selectable
        ? digest({ scope, id: row.recipe_id, revision: row.revision, ingredients })
        : null,
    };
    const effort = ['low', 'medium', 'high'].indexOf(source.preferenceEvidence?.effort ?? '');
    return [
      {
        item,
        products,
        recipe: source,
        covered,
        soon: ingredients.filter((i) => i.useSoon).length,
        soft: new Set([...eligibility.soft, ...products.flatMap((lot) => lot.eligibility.soft)]).size,
        effort: effort < 0 ? 3 : effort,
        feedback: feedback.get(row.recipe_id) ?? 0,
      },
    ];
  });
  list.sort(
    (a, b) =>
      Number(b.item.status === 'eligible') - Number(a.item.status === 'eligible') ||
      b.soon - a.soon ||
      b.covered * a.recipe.ingredients.length - a.covered * b.recipe.ingredients.length ||
      a.soft - b.soft ||
      a.effort - b.effort ||
      b.feedback - a.feedback ||
      (a.recipe.minutes ?? Infinity) - (b.recipe.minutes ?? Infinity) ||
      a.item.recipeId.localeCompare(b.item.recipeId),
  );
  return { epoch, revision, list, stock, excludedCount, excludedReviewedRecipes };
}
// Each candidate gets a scratch balance. An incomplete dinner never consumes another candidate's stock.
export async function twoNightUseSoon(ctx: Context, selected: string[]) {
  return twoNightSuggestions(ctx, await candidates(ctx), selected);
}

function twoNightSuggestions(ctx: Context, snapshot: Awaited<ReturnType<typeof candidates>>, selected: string[]) {
  const requested = z.array(id).max(12).parse(selected);
  const { epoch, revision, list, stock } = snapshot;
  const lots = stock.flatMap(lot => {
    if (!lot.useFirstAt || Date.parse(lot.useFirstAt) > ctx.now.getTime() + 3 * 86400000 ||
        !lot.free || BigInt(lot.free.numerator) <= 0n || !lot.observed?.quantity) return [];
    return [{ lotId: lot.id, name: lot.name, useFirstAt: lot.useFirstAt }];
  });
  if (requested.some(key => !lots.some(lot => lot.lotId === key))) throw refresh();
  const focus = new Set(requested.length ? requested : lots.map(lot => lot.lotId));
  const result = { householdId: ctx.householdId, grantEpoch: epoch, pantryRevision: revision, lots };
  const eligible = list.filter(row => row.item.checkoutEstimate === 'noPurchaseNeeded');
  for (let i = 0; i < eligible.length; i++) {
    const first = eligible[i]!;
    const initial = ingredientNeeds(first.recipe, first.products, ctx.now).remainingByLot;
    if (![...initial.keys()].some(key => focus.has(key))) continue;
    for (const second of eligible) {
      if (second.item.recipeId === first.item.recipeId) continue;
      const next = ingredientNeeds(second.recipe, second.products, ctx.now, initial);
      if (!next.ingredients.every(ingredient => ingredient.status === 'covered')) continue;
      const balances = new Map([...initial, ...next.remainingByLot]);
      if (!requested.every(key => balances.has(key))) continue;
      const remainders = stock.flatMap(lot => {
        const balance = balances.get(lot.id), unit = lot.observed?.quantity?.unit;
        if (!balance || !unit) return [];
        const left = inUnit(balance, unit);
        // Keep exact arithmetic through display. Never round a small balance up to a serving.
        return [{ lotId: lot.id, name: lot.name, unit, amount: left.denominator === '1' ? left.numerator : left.numerator + '/' + left.denominator }];
      });
      return { ...result, recipeIds: [first.item.recipeId, second.item.recipeId], reviewTokens: [first.item.reviewToken, second.item.reviewToken], remainders };
    }
  }
  return { ...result, recipeIds: [], reviewTokens: [], remainders: [] };
}

export async function householdTonight(ctx: Context) {
  const { epoch, revision, list, excludedCount, excludedReviewedRecipes } = await candidates(ctx);
  return {
    v: 1,
    householdId: ctx.householdId,
    grantEpoch: epoch,
    pantryRevision: revision,
    asOf: ctx.now.toISOString(),
    canReviewRecipes: ctx.member.organizer,
    recipes: list.map((v) => v.item),
    excludedCount,
    ...(ctx.member.organizer ? { excludedReviewedRecipes } : {}),
  };
}
export async function recordTonight(
  ctx: Context,
  shop: Shop,
  body: unknown,
  operationId: string,
  repo: HouseholdRepository,
  billing?: BillingService,
) {
  repo.requireDraft(shop);
  if (shop.demand_revision)
    throw new ServiceError(409, 'demand_review_required', 'Review shared demand in the destination plan.');
  const b = chooseTonight.parse(body);
  if (b.second) await requireAssistance(ctx, billing);
  const snapshot = await candidates(ctx);
  const {epoch, list} = snapshot;
  const choices = b.second ? [b, b.second] : [b];
  if (b.grantEpoch !== epoch || (b.selectedLotIds && !b.second)) throw refresh();
  if (b.second) {
    const plan = twoNightSuggestions(ctx, snapshot, b.selectedLotIds ?? []);
    if (!b.day || !b.second.day || b.second.day <= b.day || b.occurrenceId === b.second.occurrenceId ||
        plan.recipeIds[0] !== b.recipeId || plan.recipeIds[1] !== b.second.recipeId) throw refresh();
  }
  const ids = choices.map(choice => choice.occurrenceId);
  const existing = await repo.meals(ctx, shop.shop_id);
  if (existing.length + ids.length > 100 || (await ctx.db.query(
    'SELECT FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=ANY($3::uuid[]) LIMIT 1',
    [ctx.householdId, shop.shop_id, ids])).rowCount) throw refresh();
  for (const choice of choices) {
    const selection = list.find(row => row.item.recipeId === choice.recipeId);
    if (!selection || selection.item.recipeRevision !== choice.recipeRevision || selection.item.reviewToken !== choice.reviewToken) throw refresh();
    const r = selection.recipe,
      meal = sharedMealSchema.parse({
        title: r.title,
        day: choice.day,
        kind: 'dinner',
        portions: r.portions,
        protected: false,
        planning: {
          groups: [],
          ingredients: r.ingredients.map(({ id, name, quantity }) => ({
            id,
            name,
            quantity,
            groupIds: [],
            exclusions: [],
          })),
          ...(r.minutes === null ? {} : { leadTimeMinutes: r.minutes }),
        },
      });
    await ctx.db.query(
      'INSERT INTO ritc.shared_meal_revision(household_id,shop_id,occurrence_id,revision,actor_id,meal) VALUES($1,$2,$3,$4,$5,$6)',
      [ctx.householdId, shop.shop_id, choice.occurrenceId, shop.revision + 1, ctx.member.member_id, meal],
    );
    await ctx.db.query(
      'INSERT INTO ritc.tonight_choice(household_id,shop_id,occurrence_id,operation_id,recipe_id,recipe_revision,grant_epoch) VALUES($1,$2,$3,$4,$5,$6,$7)',
      [ctx.householdId, shop.shop_id, choice.occurrenceId, operationId, choice.recipeId, choice.recipeRevision, epoch],
    );
  }
  await ctx.db.query('UPDATE ritc.shop SET revision=revision+1 WHERE household_id=$1 AND shop_id=$2', [
    ctx.householdId,
    shop.shop_id,
  ]);
  return {occurrenceId:b.occurrenceId, ...(b.second ? {secondOccurrenceId:b.second.occurrenceId} : {})};
}
export async function checkTonightReplay(ctx: Context, shop: Shop, id: string, expected: number) {
  const epoch = authority(ctx);
  if (
    (
      await ctx.db.query(
        `SELECT FROM ritc.tonight_choice c JOIN ritc.tonight_recipe r USING(household_id,recipe_id)
   WHERE c.household_id=$1 AND c.shop_id=$2 AND c.operation_id=$3 AND c.grant_epoch=$4 AND r.recipe IS NOT NULL
   AND (SELECT meal IS NOT NULL FROM ritc.shared_meal_revision WHERE household_id=c.household_id AND shop_id=c.shop_id AND occurrence_id=c.occurrence_id ORDER BY revision DESC LIMIT 1)`,
        [ctx.householdId, shop.shop_id, id, epoch],
      )
    ).rowCount !== expected
  )
    throw refresh();
}
