import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { digest } from './database.js';
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
const update = z.object({v: z.literal(1), clientKey: id, replayWindow: id, grantEpoch: epoch,
  expectedRevision: id.nullable(), settings: settings.nullable()}).strict();
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

export async function writeMealPreferences(ctx: Context, input: unknown) {
  const current = await authority(ctx, true);
  const command = update.parse(input);
  if (current !== command.grantEpoch) throw refresh();
  const window = await ctx.db.query('SELECT 1 FROM ritc.replay_window WHERE household_id=$1 AND window_id=$2 AND member_id=$3 AND device_id=$4 AND revoked_at IS NULL AND expires_at>$5',
    [ctx.householdId, command.replayWindow, ctx.member.member_id, ctx.deviceId, ctx.now]);
  if (!window.rowCount) throw refresh();
  const previous = (await ctx.db.query('SELECT revision,author_id,device_id,client_key,request_digest FROM ritc.meal_preference_profile WHERE household_id=$1',[ctx.householdId])).rows[0];
  const fingerprint = digest(command);
  if (previous?.client_key === command.clientKey) {
    if (previous.author_id !== ctx.member.member_id || previous.device_id !== ctx.deviceId || previous.request_digest !== fingerprint) throw refresh();
    return readMealPreferences(ctx);
  }
  if ((previous?.revision ?? null) !== command.expectedRevision) throw refresh();
  // HouseholdRepository.authorized already holds the tenant lock for this transaction.
  await ctx.db.query(`INSERT INTO ritc.meal_preference_profile(household_id,revision,settings,author_id,device_id,client_key,request_digest)
    VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(household_id) DO UPDATE SET
    revision=excluded.revision,settings=excluded.settings,author_id=excluded.author_id,device_id=excluded.device_id,
    client_key=excluded.client_key,request_digest=excluded.request_digest`,
    [ctx.householdId, randomUUID(), command.settings, ctx.member.member_id, ctx.deviceId, command.clientKey, fingerprint]);
  return readMealPreferences(ctx);
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
