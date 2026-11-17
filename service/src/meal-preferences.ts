import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { digest } from './database.js';
import type { SharedMealValue } from './shared-meal-planning.js';
import type { DecisionHistory } from './decision-history.js';
import { refresh, unavailable } from './errors.js';
import type { Context } from './repository.js';

const id = z.uuid().toLowerCase();
const epoch = z.number().int().min(0).max(2_147_483_647);
const normalized = (value: string) => value.normalize('NFKD').toLowerCase().replace(/\p{M}/gu, '').replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
const term = z.string().trim().min(1).refine(value => Buffer.byteLength(value) <= 160 &&
  !/[\u0000\uD800-\uDFFF]/u.test(value) && normalized(value).length > 0);
const terms = z.array(term).max(64).refine(values => new Set(values.map(normalized)).size === values.length);
const settings = z.object({
  exclusions: terms, availableAppliances: terms.nullish(), dislikes: terms, preferredBrands: terms,
  maximumEffort: z.enum(['low', 'medium', 'high']).nullish(),
  strictDislikes: z.boolean(), strictBrands: z.boolean(), strictEffort: z.boolean()
}).strict().refine(value => (!value.strictDislikes || value.dislikes.length > 0) &&
  (!value.strictBrands || value.preferredBrands.length > 0) && (!value.strictEffort || value.maximumEffort != null));
const sourceDecision = z.object({shopId:id,decisionId:id,version:z.number().int().positive(),
  field:z.enum(['exclusions','dislikes','preferredBrands']),term}).strict();
type DecisionReference = z.infer<typeof sourceDecision>;
const update = z.object({v: z.literal(1), clientKey: id, replayWindow: id, grantEpoch: epoch,
  expectedRevision: id.nullable(), settings: settings.nullable(), sourceDecision:sourceDecision.optional()}).strict();
const grant = z.object({v: z.literal(1), memberId: id, enabled: z.boolean(), expectedGrantEpoch: epoch}).strict();

async function authority(ctx: Context, writing = false): Promise<number> {
  if (ctx.viewGrantId || ctx.ownRequestsOnly || ctx.member.kind !== 'adult' || ctx.member.state !== 'active') throw unavailable();
  const {rows} = await ctx.db.query('SELECT organizer,preference_reader,preference_grant_epoch FROM ritc.member WHERE household_id=$1 AND member_id=$2',
    [ctx.householdId, ctx.member.member_id]);
  const member = rows[0];
  if (!member || (!member.organizer && (writing || !member.preference_reader))) throw unavailable();
  return member.preference_grant_epoch;
}

export async function readMealPreferences(ctx: Context) {
  const grantEpoch = await authority(ctx);
  const row = (await ctx.db.query('SELECT revision,settings FROM ritc.meal_preference_profile WHERE household_id=$1',[ctx.householdId])).rows[0];
  return {v: 1, householdId: ctx.householdId, grantEpoch, canWrite: ctx.member.organizer,
    revision: row?.revision ?? null, settings: row?.settings ?? null};
}

const termFields = ['exclusions','availableAppliances','dislikes','preferredBrands'] as const;
const scalarFields = ['maximumEffort','strictDislikes','strictBrands','strictEffort'] as const;
type Settings = z.infer<typeof settings>;
type Provenance = Record<string, Record<string, string[]>>;

// Retain the author of an unchanged rule across later organizer edits. Explicit
// deletion removes the attribution together with the rule. The map stays private.
function origins(value: Settings | null, previous: Provenance, author: string, source?: {rule:DecisionReference; member:string}): Provenance {
  if (!value) return {};
  const result: Provenance = {};
  for (const key of termFields) {
    const previousTerms = new Map(Object.entries(previous[key] ?? {}).map(([term, members]) => [normalized(term), members]));
    result[key] = Object.fromEntries((value[key] ?? []).map(term => {
      const earlier = previousTerms.get(normalized(term));
      const members = source?.rule.field === key && source.rule.term === term ? [author,source.member] : [author];
      return [term, Array.isArray(earlier) ? earlier : [...new Set(members)]];
    }));
  }
  if (value.availableAppliances != null) {
    result.appliancesReviewed = {yes: previous.appliancesReviewed?.yes ?? [author]};
  }
  for (const key of scalarFields) {
    const v = value[key];
    if (v) result[key] = {[String(v)]: previous[key]?.[String(v)] ?? [author]};
  }
  return result;
}

export async function writeMealPreferences(ctx: Context, input: unknown, decisions: DecisionHistory) {
  const current = await authority(ctx, true);
  const command = update.parse(input);
  if (current !== command.grantEpoch) throw refresh();
  const window = await ctx.db.query('SELECT 1 FROM ritc.replay_window WHERE household_id=$1 AND window_id=$2 AND member_id=$3 AND device_id=$4 AND revoked_at IS NULL AND expires_at>$5',
    [ctx.householdId, command.replayWindow, ctx.member.member_id, ctx.deviceId, ctx.now]);
  if (!window.rowCount) throw refresh();
  const previous = (await ctx.db.query('SELECT revision,rule_authors FROM ritc.meal_preference_profile WHERE household_id=$1',[ctx.householdId])).rows[0];
  let source: {rule:DecisionReference; member:string} | undefined;
  if (command.sourceDecision) {
    const rule = command.sourceDecision;
    const note = await decisions.preferenceSource(ctx,rule.shopId,rule.decisionId);
    if (note.kind !== 'preference' || note.version !== rule.version || !command.settings?.[rule.field].includes(rule.term)) throw refresh();
    source={rule,member:note.author_id};
  }
  const fingerprint = digest(command);
  // Once a window expires no credential can replay its commands. While a
  // window is live, a spent client key can never authorize a different change.
  await ctx.db.query(`DELETE FROM ritc.meal_preference_write_key k WHERE household_id=$1 AND NOT EXISTS (
    SELECT FROM ritc.replay_window w WHERE w.household_id=k.household_id AND w.window_id=k.window_id
    AND w.revoked_at IS NULL AND w.expires_at>$2)`,[ctx.householdId,ctx.now]);
  const spent=(await ctx.db.query('SELECT actor_id,device_id,window_id,request_digest,accepted_revision FROM ritc.meal_preference_write_key WHERE household_id=$1 AND client_key=$2',
    [ctx.householdId,command.clientKey])).rows[0];
  if (spent) {
    if (spent.actor_id !== ctx.member.member_id || spent.device_id !== ctx.deviceId || spent.window_id !== command.replayWindow ||
        spent.request_digest !== fingerprint || spent.accepted_revision !== previous?.revision) throw refresh();
    return readMealPreferences(ctx);
  }
  if ((previous?.revision ?? null) !== command.expectedRevision) throw refresh();
  if (source && Object.keys(previous?.rule_authors?.[source.rule.field] ?? {}).some(t => normalized(t) === normalized(source.rule.term))) throw refresh();
  // HouseholdRepository.authorized already holds the tenant lock for this transaction.
  const revision = randomUUID();
  await ctx.db.query(`INSERT INTO ritc.meal_preference_profile(household_id,revision,settings,rule_authors)
    VALUES($1,$2,$3,$4) ON CONFLICT(household_id) DO UPDATE SET
    revision=excluded.revision,settings=excluded.settings,rule_authors=excluded.rule_authors`,
    [ctx.householdId, revision, command.settings, origins(command.settings, previous?.rule_authors ?? {}, ctx.member.member_id, source)]);
  await ctx.db.query(`INSERT INTO ritc.meal_preference_write_key(household_id,client_key,actor_id,device_id,window_id,accepted_revision,request_digest)
    VALUES($1,$2,$3,$4,$5,$6,$7)`,[ctx.householdId,command.clientKey,ctx.member.member_id,ctx.deviceId,command.replayWindow,revision,fingerprint]);
  return readMealPreferences(ctx);
}

export const mealEvidence = z.object({
  reviewedIngredientDetails: terms.nullish(), requiredAppliances: terms.nullish(),
  brands: terms.nullish(), effort: z.enum(['low','medium','high']).nullish()
}).strict();

export async function mealConstraints(ctx: Context): Promise<{revision: string | null, settings: Settings | null}> {
  const row = (await ctx.db.query('SELECT revision,settings FROM ritc.meal_preference_profile WHERE household_id=$1',[ctx.householdId])).rows[0];
  return {revision: row?.revision ?? null, settings: row?.settings ? settings.parse(row.settings) : null};
}

// The shared meal preview discloses only decision categories for a meal already
// in its actor's shop projection. Whole preference values never enter cook copies.
export function mealEligibility(value: Settings | null, ingredients: string[], evidence?: z.infer<typeof mealEvidence>) {
  const blocked: string[] = [], unresolved: string[] = [], soft: string[] = [];
  if (value) {
    const names = [...ingredients,...(evidence?.reviewedIngredientDetails ?? [])].map(v => ' '+normalized(v)+' ');
    const matches = (rule: string) => names.some(n => n.includes(' '+normalized(rule)+' '));
    if (value.exclusions.some(matches)) blocked.push('ingredient');
    if (value.dislikes.some(matches)) (value.strictDislikes ? blocked : soft).push('dislike');
    if ((value.exclusions.length || value.strictDislikes) && (!ingredients.length || evidence?.reviewedIngredientDetails == null)) unresolved.push('ingredient');
    if (value.availableAppliances != null) {
      const available = new Set(value.availableAppliances.map(normalized));
      if (evidence?.requiredAppliances == null) unresolved.push('appliance');
      else if (evidence.requiredAppliances.some(v => !available.has(normalized(v)))) blocked.push('appliance');
    }
    if (value.preferredBrands.length) {
      const preferred = new Set(value.preferredBrands.map(normalized));
      if (evidence?.brands == null) (value.strictBrands ? unresolved : soft).push('brand');
      else if (!evidence.brands.length || evidence.brands.some(v => !preferred.has(normalized(v)))) (value.strictBrands ? blocked : soft).push('brand');
    }
    if (value.maximumEffort) {
      const order = ['low','medium','high'];
      if (evidence?.effort == null) (value.strictEffort ? unresolved : soft).push('effort');
      else if (order.indexOf(evidence.effort) > order.indexOf(value.maximumEffort)) (value.strictEffort ? blocked : soft).push('effort');
    }
  }
  return {eligible: !blocked.length && !unresolved.length, blocked, unresolved, soft};
}

export const recipeReview = z.object({revision:id, evidence:mealEvidence.optional()}).strict();

export async function checkIngredientChange(ctx: Context, original: SharedMealValue | undefined,
    next: SharedMealValue | null, review?: z.infer<typeof recipeReview>) {
  if (!original || !next) return;
  const identities = (meal: SharedMealValue) => (meal.planning?.ingredients ?? []).map(i => ({id:i.id,name:i.name})).sort((a,b)=>a.id.localeCompare(b.id));
  if (digest(identities(original)) === digest(identities(next))) return;
  const current = await mealConstraints(ctx);
  if (!review && !current.settings) return;
  if (review?.revision !== current.revision) throw refresh();
  const result = mealEligibility(current.settings,(next.planning?.ingredients ?? []).map(i=>i.name),review?.evidence);
  if (!result.eligible) throw refresh();
}

export async function preferenceGrants(ctx: Context) {
  await authority(ctx, true);
  const {rows} = await ctx.db.query(`SELECT member_id AS "memberId", alias AS label, preference_reader AS enabled,
    preference_grant_epoch AS "grantEpoch" FROM ritc.member WHERE household_id=$1 AND kind='adult'
    AND state='active' AND NOT organizer ORDER BY alias,member_id`,[ctx.householdId]);
  return {v: 1, adults: rows};
}

export async function changePreferenceGrant(ctx: Context, input: unknown) {
  await authority(ctx, true);
  const command = grant.parse(input);
  const member = (await ctx.db.query(`SELECT preference_reader,preference_grant_epoch FROM ritc.member
    WHERE household_id=$1 AND member_id=$2 AND kind='adult' AND state='active' AND NOT organizer`,[ctx.householdId, command.memberId])).rows[0];
  if (!member) throw unavailable();
  if (member.preference_grant_epoch !== command.expectedGrantEpoch) {
    if (member.preference_grant_epoch !== command.expectedGrantEpoch + 1 || member.preference_reader !== command.enabled) throw refresh();
  } else if (member.preference_reader !== command.enabled) {
    await ctx.db.query('UPDATE ritc.member SET preference_reader=$3 WHERE household_id=$1 AND member_id=$2',
      [ctx.householdId, command.memberId, command.enabled]);
  }
  return preferenceGrants(ctx);
}
