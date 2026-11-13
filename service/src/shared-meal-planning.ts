import { z } from 'zod';
import { ServiceError } from './errors.js';

const id = z.string().uuid().transform(value => value.toLowerCase());
const label = z.string().trim().min(1).max(240);
const integer = z.number().int().min(1).max(1_000_000_000);
export const mealAmount = z.object({ numerator: integer, denominator: integer }).strict();
export const mealQuantity = z.object({
  amount: mealAmount,
  unit: z.enum(['count','gram','kilogram','ounce','pound','milliliter','liter','fluidOunce','cup']),
  originalLiteral: z.string().trim().min(1).max(240),
}).strict();
// A deadline records one instant and the civil zone in which the shopper
// scheduled it. A numeric UTC offset cannot describe that zone across a move.
const mealDeadline = z.object({
  at: z.iso.datetime({offset:true}),
  zone: z.string().max(100).regex(/^(?:UTC|GMT|[A-Za-z][A-Za-z0-9_+.-]*(?:\/[A-Za-z0-9_+.-]+)+)$/)
    .refine(zone => { try { new Intl.DateTimeFormat('en', {timeZone:zone}); return true; } catch { return false; } }),
}).strict();
export const mealPlanning = z.object({
  sourceOccurrenceId: id.optional(),
  deadline: mealDeadline.optional(),
  exclusions: z.array(label).max(20).optional(),
  leadTimeMinutes: z.number().int().min(0).max(1_000_000).optional(),
  completedSteps: z.array(label).max(100).optional(),
  bindings: z.array(z.object({ id, groupId: id, ingredientId: id, quantity: mealQuantity }).strict()).max(200).optional(),
  groups: z.array(z.object({ id, name: label, servings: mealAmount, protected: z.boolean() }).strict()).max(30),
  ingredients: z.array(z.object({
    id, name: label, quantity: mealQuantity.nullable(),
    groupIds: z.array(id).max(30), exclusions: z.array(label).max(20),
  }).strict()).max(60),
}).strict().superRefine((value, ctx) => {
  const bindings = value.bindings ?? [];
  const invalidBinding = new Set(bindings.map(b => b.id)).size !== bindings.length ||
    new Set(bindings.map(b => `${b.groupId}/${b.ingredientId}`)).size !== bindings.length ||
    bindings.some(b => !value.groups.some(g => g.id === b.groupId) || !value.ingredients.some(i => i.id === b.ingredientId && i.groupIds.includes(b.groupId)));
  let invalidTotal = false;
  for (const ingredient of value.ingredients) {
    const entries = bindings.filter(b => b.ingredientId === ingredient.id);
    if (!entries.length) continue;
    if (!ingredient.quantity || entries.some(b => b.quantity.unit !== ingredient.quantity!.unit)) { invalidTotal = true; continue; }
    let numerator = 0n, denominator = 1n;
    for (const entry of entries) {
      numerator = numerator * BigInt(entry.quantity.amount.denominator) + BigInt(entry.quantity.amount.numerator) * denominator;
      denominator *= BigInt(entry.quantity.amount.denominator);
    }
    if (numerator * BigInt(ingredient.quantity.amount.denominator) !== BigInt(ingredient.quantity.amount.numerator) * denominator) invalidTotal = true;
  }
  if (invalidBinding || invalidTotal) ctx.addIssue({code: 'custom', message: 'Explicit group quantities must refer to exact ingredients and sum to the entered total in the same unit.'});
  if (new Set(value.groups.map(g => g.id)).size !== value.groups.length ||
      new Set(value.ingredients.map(i => i.id)).size !== value.ingredients.length ||
      value.ingredients.some(i => new Set(i.groupIds).size !== i.groupIds.length || i.groupIds.some(id => !value.groups.some(g => g.id === id)))) {
    ctx.addIssue({ code: 'custom', message: 'Groups and ingredients need unique stable IDs and exact group references.' });
  }
});
export const sharedMealSchema = z.object({
  // A selected shop occurrence may be unscheduled; omission is not an explicit choice.
  title: label, day: z.iso.date().nullable(), kind: z.enum(['dinner','lunch','side']),
  portions: z.number().int().min(1).max(1000), protected: z.boolean(), planning: mealPlanning.optional(),
}).strict().superRefine((meal,ctx) => {
  const deadline = meal.planning?.deadline;
  if (!deadline) return;
  try {
    const day = new Intl.DateTimeFormat('en', {calendar:'gregory',numberingSystem:'latn',timeZone:deadline.zone,
      year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(deadline.at));
    const parts = Object.fromEntries(day.map(part => [part.type,part.value]));
    if ([parts.year?.padStart(4,'0'),parts.month,parts.day].join('-') === meal.day) return;
  } catch { /* The deadline field also reports an invalid instant or zone. */ }
  ctx.addIssue({code:'custom',path:['planning','deadline'],message:'Use a deadline on the scheduled day in the selected time zone.'});
});
export type SharedMealValue = z.infer<typeof sharedMealSchema>;
/** A date-only move cannot establish the deadline for a different civil day. */
export function moveSharedMeal(original:SharedMealValue, day:string):SharedMealValue {
  if (!original.planning?.deadline || original.day === day) return {...original,day};
  const {deadline,...planning} = original.planning;
  return {...original,day,planning};
}
function atLeast(next: z.infer<typeof mealAmount>, original: z.infer<typeof mealAmount>) {
  return BigInt(next.numerator) * BigInt(original.denominator) >= BigInt(original.numerator) * BigInt(next.denominator);
}
/** Existing protected reservations cannot be reassigned, reduced, or silently erased by any meal edit. */
export function preserveProtectedMeal(original: SharedMealValue | undefined, next: SharedMealValue | null) {
  const fail = () => { throw new ServiceError(409, 'protected_meal', 'Keep existing protected portions and ingredient reservations.'); };
  if (!original) return;
  if (original.protected && (!next || !next.protected || next.portions < original.portions || next.kind !== original.kind)) fail();
  // A whole-meal reservation covers each named group even when its own flag is off.
  const protectedGroups = original.planning?.groups.filter(g => original.protected || g.protected) ?? [];
  if ((original.protected || protectedGroups.length > 0) &&
      original.planning?.exclusions?.some(restriction => !next?.planning?.exclusions?.includes(restriction))) fail();
  for (const group of protectedGroups) {
    const replacement = next?.planning?.groups.find(g => g.id === group.id);
    if (!replacement || (group.protected && !replacement.protected) || replacement.name !== group.name || !atLeast(replacement.servings, group.servings)) fail();
  }
  for (const binding of original.planning?.bindings ?? []) {
    if (!protectedGroups.some(g => g.id === binding.groupId)) continue;
    const nextBinding = next?.planning?.bindings?.find(b => b.id === binding.id);
    if (!nextBinding || nextBinding.groupId !== binding.groupId || nextBinding.ingredientId !== binding.ingredientId ||
        nextBinding.quantity.unit !== binding.quantity.unit || !atLeast(nextBinding.quantity.amount, binding.quantity.amount)) fail();
  }
  for (const ingredient of original.planning?.ingredients ?? []) {
    const protectedIds = ingredient.groupIds.filter(id => protectedGroups.some(g => g.id === id));
    if (!original.protected && protectedIds.length === 0) continue;
    const replacement = next?.planning?.ingredients.find(i => i.id === ingredient.id);
    if (!replacement || replacement.name !== ingredient.name ||
        protectedIds.some(id => !replacement.groupIds.includes(id)) ||
        ingredient.exclusions.some(value => !replacement.exclusions.includes(value))) { fail(); continue; }
    const hasProtectedAmounts = protectedIds.every(groupId => original.planning?.bindings?.some(
      b => b.ingredientId === ingredient.id && b.groupId === groupId));
    if ((original.protected || !hasProtectedAmounts) && ingredient.quantity && (!replacement.quantity || ingredient.quantity.unit !== replacement.quantity.unit ||
        !atLeast(replacement.quantity.amount, ingredient.quantity.amount))) fail();
  }
}
