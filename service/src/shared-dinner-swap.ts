import {refresh} from './errors.js';
import type {SharedMealValue} from './shared-meal-planning.js';
import type {recipeReview} from './meal-preferences.js';
import type {z} from 'zod';
import {mealConstraints,mealEligibility} from './meal-preferences.js';
import {recoveryMealSchema,type RecoveryBasis,type RecoveryIntent,type RecoveryMeal} from './recovery-contracts.js';
import {recoveryDigest} from './recovery-domain.js';
import type {Context,Shop} from './repository.js';

export async function checkDraftDinnerSwap(ctx:Context,old:SharedMealValue|undefined,next:SharedMealValue|null,review?:z.infer<typeof recipeReview>) {
  if(!old || !next || old.protected || old.kind!=='dinner' || next.kind!==old.kind || next.portions!==old.portions ||
    old.day!==next.day || old.protected!==next.protected ||
    recoveryDigest(old.planning?.groups??[])!==recoveryDigest(next.planning?.groups??[]) ||
    recoveryDigest(old.planning?.deadline??null)!==recoveryDigest(next.planning?.deadline??null)) throw refresh();
  const profile=await mealConstraints(ctx);
  if((review?.revision??null)!==profile.revision ||
    !mealEligibility(profile.settings,next.planning?.ingredients.map(i=>i.name)??[],review?.evidence,next.planning?.leadTimeMinutes).eligible) throw refresh();
}

export function swapStockDigest(basis:RecoveryBasis,before:RecoveryMeal,after:RecoveryMeal) {
  const needs=[...before.needs,...after.needs];
  const ids=new Set(needs.flatMap(n=>n.matchedSourceIds ?? (n.foodId?[n.foodId]:[])));
  const needIds=new Set(needs.map(n=>n.id));
  const digests=(items:unknown[])=>items.map(recoveryDigest).sort();
  const sources=(items:{sourceId:string}[])=>items.filter(row=>ids.has(row.sourceId));
  return recoveryDigest({
    sources:digests(basis.sources.filter(s=>ids.has(s.id))), foods:digests(basis.foods.filter(f=>ids.has(f.id))),
    arrivals:digests(sources(basis.arrivals)), usable:digests(sources(basis.usable)),
    pantry:digests(sources(basis.pantryObservations??[])), foreign:digests(sources(basis.foreignHolds??[])),
    reservations:digests(basis.reservations.filter(r=>ids.has(r.sourceId)||needIds.has(r.needId)))
  });
}

export async function cooked(ctx:Context,shop:Shop,occurrenceId:string) {
  // Households may use this service before the optional cook ledger ships.
  const table=await ctx.db.query("SELECT to_regclass('ritc.shared_cook') IS NOT NULL AS available");
  if(!table.rows[0].available) return false;
  return !!(await ctx.db.query(`SELECT 1 FROM ritc.shared_cook WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 AND undone_by IS NULL LIMIT 1`,
    [ctx.householdId,shop.shop_id,occurrenceId])).rowCount;
}

export async function swapReview(ctx:Context,shop:Shop,basis:RecoveryBasis,intent:RecoveryIntent) {
  const target=basis.meals.find(m=>m.occurrenceId===intent.occurrenceId);
  if(!target || intent.fallback || !!intent.dinnerSwap===!!intent.undoesSwap ||
    await cooked(ctx,shop,target.occurrenceId)) throw refresh();
  const dinner=await ctx.db.query(`SELECT 1 FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2
    AND occurrence_id=$3 AND revision=$4 AND meal->>'kind'='dinner' AND meal->>'protected'='false'`,[ctx.householdId,shop.shop_id,target.occurrenceId,target.sourceMealRevision]);
  if(!dinner.rowCount) throw refresh();
  const profile=await mealConstraints(ctx);
  const next=intent.replacement;
  if(!mealEligibility(profile.settings,next.needs.map(n=>n.name),intent.preferenceEvidence,next.remainingElapsedMinutes).eligible) throw refresh();
  const dependencyDigest=swapStockDigest(basis,target,next);
  if(!intent.undoesSwap) return {dependencyDigest,profileRevision:profile.revision};
  const proof=(await swapOffers(ctx,shop,[target])).find(o=>o.operationId===intent.undoesSwap);
  if(!proof || proof.digest!==dependencyDigest || intent.repeatOfOccurrenceId!==null || intent.proposesExtraTrip ||
    recoveryDigest({...next,revisionId:proof.previous.revisionId})!==recoveryDigest(proof.previous)) throw refresh();
  return {dependencyDigest,profileRevision:profile.revision,previous:proof.previous};
}

export async function swapOffers(ctx:Context,shop:Shop,meals:RecoveryMeal[]) {
  const {rows}=await ctx.db.query(`SELECT r.operation_id,r.occurrence_id,r.swap_before,r.swap_dependencies FROM ritc.meal_recovery_revision r
    WHERE r.household_id=$1 AND r.shop_id=$2 AND r.authority_epoch=$3 AND r.new_revision_id=ANY($4::uuid[])
      AND r.swap_before IS NOT NULL AND r.current_meal IS NOT NULL
      AND NOT EXISTS(SELECT FROM ritc.dated_cook_copy c WHERE c.household_id=r.household_id AND c.shop_id=r.shop_id AND c.recovery_meal_id=r.new_revision_id)
      AND NOT EXISTS(SELECT FROM ritc.accepted_fallback_revision f WHERE f.household_id=r.household_id AND f.shop_id=r.shop_id
        AND f.source->>'kind'='meal' AND f.source->>'revisionId'=r.new_revision_id::text)
      AND NOT EXISTS(SELECT FROM ritc.meal_recovery_revision child WHERE child.household_id=r.household_id AND child.shop_id=r.shop_id
        AND child.recovery_revision>r.recovery_revision AND (child.occurrence_id=r.occurrence_id OR
        child.intent->>'repeatOfOccurrenceId'=r.occurrence_id::text OR child.current_meal IS NULL))`,
    [ctx.householdId,shop.shop_id,shop.authority_epoch,meals.map(m=>m.revisionId)]);
  return rows.map(r=>({operationId:r.operation_id as string,occurrenceId:r.occurrence_id as string,
    previous:recoveryMealSchema.parse(r.swap_before),digest:r.swap_dependencies as string}));
}
