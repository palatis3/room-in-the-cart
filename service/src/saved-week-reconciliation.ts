import {ServiceError} from './errors.js';
import {applyDemandChange, convertDemandQuantity, demandLineTotals} from './shared-demand-domain.js';
import type {DemandGraph, DemandQuantity} from './shared-demand-contracts.js';
import {preserveProtectedMeal, sharedMealSchema} from './shared-meal-planning.js';
import type {HouseholdRepository} from './repository.js';

export type WeekMeal = Awaited<ReturnType<HouseholdRepository['meals']>>[number];
export type WeekLine = Awaited<ReturnType<HouseholdRepository['lines']>>[number];
type Pack = {lineId:string; usablePerPack:DemandQuantity|null; acceptUnresolved:boolean};
export type WeekFood = {graph:DemandGraph; packs:Pack[]};
export function needsReview():never {
  throw new ServiceError(409, 'review_week_sources', 'Review the current dinner, grocery sources and pack sizes before saving.');
}

export function selectedNights(meals:WeekMeal[], week:string, ids:string[]) {
  const end = new Date(week + 'T12:00:00Z');
  end.setUTCDate(end.getUTCDate() + 7);
  const until = end.toISOString().slice(0,10);
  if (new Set(ids).size !== ids.length) needsReview();
  return ids.map(id => {
    const row = meals.find(m => m.occurrenceId === id);
    if (!row) needsReview();
    const meal = sharedMealSchema.parse(row.meal);
    if (meal.kind !== 'dinner' || !meal.day || meal.day < week || meal.day >= until) needsReview();
    preserveProtectedMeal(meal, null);
    return {id, revision:row.revision, day:meal.day};
  }).sort((a,b) => a.day.localeCompare(b.day) || a.id.localeCompare(b.id));
}

function wholePacks(need:NonNullable<ReturnType<typeof demandLineTotals>[number]['quantity']>, usable:{n:bigint;d:bigint}) {
  const n = BigInt(need.numerator) * usable.d, d = BigInt(need.denominator) * usable.n;
  if (d <= 0n) needsReview();
  return Number((n + d - 1n) / d);
}

// Never use a grocery name to attribute a pack to a meal. Legacy rows have no
// binding; their entered packs remain intact. An unexplained surplus needs review.
export function removeNight(lines:WeekLine[], food:WeekFood|null, id:string, operationId:string, at:string) {
  if (!food) return {lines,food,change:null};
  const {graph} = food;
  const retired = graph.contributions.filter(c => c.removedAt === null && c.source.kind === 'meal' && c.source.occurrenceId === id);
  if (!retired.length) needsReview();
  const change = {lines:[], contributions:[], edges:[], removeEdgeIds:[], removeSourceIds:retired.map(c => c.id)};
  const result = applyDemandChange(graph,{...change, schemaVersion:1, operationId, householdId:graph.householdId,
    shopId:graph.shopId, baseRevision:graph.revision, at}).graph;
  const tracked = new Set(retired.map(c => c.lineId));
  const before = new Map(demandLineTotals(graph).map(line => [line.lineId,line]));
  const after = new Map(demandLineTotals(result).map(line => [line.lineId,line]));
  const next = lines.flatMap(line => {
    if (!tracked.has(line.lineId)) return [line];
    const original = before.get(line.lineId);
    const pack = food.packs.find(p => p.lineId === line.lineId);
    const usable = original && pack?.usablePerPack && convertDemandQuantity(pack.usablePerPack, original.unit);
    if (!usable || !original?.quantity || wholePacks(original.quantity, usable) !== line.packs ||
        graph.contributions.some(c => c.lineId === line.lineId && !c.removedAt && c.sourceExclusions?.some(e => e.resolution.kind === 'unresolved'))) needsReview();
    const remaining = after.get(line.lineId);
    if (!remaining) return [];
    if (!remaining.quantity) needsReview();
    const count = wholePacks(remaining.quantity, usable);
    if (count < 1 || count > line.packs) needsReview();
    return [{...line,packs:count}];
  });
  return {lines:next, food:{graph:result,packs:food.packs.filter(p => after.has(p.lineId))}, change};
}

export function basketDifference(before:WeekLine[], after:WeekLine[], food:WeekFood|null, remaining:WeekFood|null) {
  const totals = (state:WeekFood|null) => new Map((state ? demandLineTotals(state.graph) : []).map(t => [t.lineId,t]));
  const prior = totals(food), next = totals(remaining);
  const measured = (total:ReturnType<typeof demandLineTotals>[number]|undefined) => total?.quantity
    ? {numerator:total.quantity.numerator,denominator:total.quantity.denominator,unit:total.unit} : null;
  return before.map(line => {
    const sources = food?.graph.contributions.filter(c => c.lineId === line.lineId && c.removedAt === null) ?? [];
    return {id:line.lineId, name:line.originalItem, beforeNeed:measured(prior.get(line.lineId)), afterNeed:measured(next.get(line.lineId)), before:line.packs, after:after.find(row => row.lineId === line.lineId)?.packs ?? 0,
      unlinked:sources.length === 0, manual:sources.some(c => c.source.kind === 'manual' || c.source.kind === 'import'),
      held:sources.some(c => c.source.kind === 'reservation'), mealIds:[...new Set(sources.flatMap(c => c.source.kind === 'meal' ? [c.source.occurrenceId] : []))]};
  });
}
