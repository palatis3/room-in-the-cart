import {randomUUID} from 'node:crypto';
import {digest} from './database.js';
import {z} from 'zod';
import {refresh, unavailable} from './errors.js';
import {householdPantryEpoch} from './pantry-lots.js';
import {cookReview} from './shared-cook-completion.js';
import type {Context, Shop} from './repository.js';

const options = ['makeAgain','tooMuchEffort','childrenLikedIt','tooManyLeftovers'] as const;
type Reaction = typeof options[number];
const uuid = z.string().uuid().toLowerCase();
const edit = z.object({
  v: z.literal(1), cookId: uuid, authorityEpoch: z.number().int().nonnegative(),
  grantEpoch: z.number().int().nonnegative(), expectedRevision: uuid.nullable(), clientKey: uuid, replayWindow: uuid,
  reactions: z.array(z.enum(options)).max(4).refine(values => new Set(values).size === values.length)
}).strict();
interface Stored {
  member_id: string; revision: string;
  reactions: Reaction[]; updated_at: Date;
}
async function source(ctx: Context, shop: Shop, occurrenceId: string) {
  const review = await cookReview(ctx,shop,occurrenceId);
  if (!review.completion) throw unavailable();
  const exact = await ctx.db.query(`SELECT 1 FROM ritc.shared_cook WHERE household_id=$1 AND shop_id=$2
    AND operation_id=$3 AND occurrence_id=$4 AND meal_revision=$5 AND recipe_revision_id=$6 AND undone_by IS NULL`,
    [ctx.householdId,shop.shop_id,review.completion.cookId,occurrenceId,review.base.mealRevision,review.base.recipeRevisionId]);
  if (!exact.rowCount) throw unavailable();
  return {cookId:review.completion.cookId, grantEpoch:review.base.grantEpoch, authorityEpoch:shop.authority_epoch};
}
export async function readMealFeedback(ctx: Context, shop: Shop, occurrenceId: string) {
  const basis = await source(ctx,shop,occurrenceId);
  const rows = (await ctx.db.query<Stored>(`SELECT member_id,revision,reactions,updated_at FROM ritc.household_meal_feedback
    WHERE household_id=$1 AND cook_id=$2`, [ctx.householdId,basis.cookId])).rows;
  const own = rows.find(row => row.member_id === ctx.member.member_id);
  const cutoff = ctx.now.getTime() - 90 * 86_400_000;
  const shared = new Set(rows.filter(row => row.updated_at.getTime() > cutoff).flatMap(row => row.reactions));
  return {v:1, ...basis, occurrenceId, revision:own?.revision ?? null, own:own?.reactions ?? [],
    shared:options.filter(reaction => shared.has(reaction))};
}
export async function updateMealFeedback(ctx: Context, shop: Shop, occurrenceId: string, input: unknown) {
  const basis = await source(ctx,shop,occurrenceId);
  const body = edit.parse(input);
  if (body.cookId !== basis.cookId || body.grantEpoch !== basis.grantEpoch ||
      body.authorityEpoch !== basis.authorityEpoch) throw refresh();
  const window = await ctx.db.query(`SELECT 1 FROM ritc.replay_window WHERE household_id=$1 AND window_id=$2
      AND member_id=$3 AND device_id=$4 AND revoked_at IS NULL AND expires_at>$5`,
      [ctx.householdId,body.replayWindow,ctx.member.member_id,ctx.deviceId,ctx.now]);
  if (!window.rowCount) throw refresh();

  await ctx.db.query(`DELETE FROM ritc.meal_feedback_receipt k WHERE k.household_id=$1 AND NOT EXISTS
    (SELECT 1 FROM ritc.replay_window w WHERE (w.household_id,w.window_id)=(k.household_id,k.window_id)
      AND w.revoked_at IS NULL AND w.expires_at>$2)`,[ctx.householdId,ctx.now]);
  const receipt = (await ctx.db.query(`SELECT * FROM ritc.meal_feedback_receipt WHERE household_id=$1 AND client_key=$2`,
    [ctx.householdId,body.clientKey])).rows[0];
  const fingerprint = digest(body);
  if (receipt) {
    if (receipt.cook_id!==basis.cookId || receipt.member_id!==ctx.member.member_id || receipt.device_id!==ctx.deviceId ||
        receipt.window_id!==body.replayWindow || receipt.request_digest!==fingerprint) throw refresh();
    return {v:1,revision:receipt.accepted_revision};
  }
  const args = [ctx.householdId,basis.cookId,ctx.member.member_id];
  const old = (await ctx.db.query<Stored>(`SELECT revision FROM ritc.household_meal_feedback
    WHERE household_id=$1 AND cook_id=$2 AND member_id=$3`,args)).rows[0];
  if ((old?.revision ?? null)!==body.expectedRevision) throw refresh();
  const reactions = options.filter(reaction=>body.reactions.includes(reaction));
  // Keep a payload-free revision after removal so a previously reviewed empty form cannot resurrect it.
  const revision = reactions.length || old ? randomUUID() : null;
  if (revision) {
    await ctx.db.query(`INSERT INTO ritc.household_meal_feedback(household_id,cook_id,member_id,revision,reactions,updated_at)
      VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(household_id,cook_id,member_id) DO UPDATE SET
      revision=EXCLUDED.revision,reactions=EXCLUDED.reactions,updated_at=EXCLUDED.updated_at`,
      [...args,revision,reactions,ctx.now]);
  }
  await ctx.db.query(`INSERT INTO ritc.meal_feedback_receipt(household_id,cook_id,member_id,device_id,client_key,window_id,request_digest,accepted_revision)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[...args,ctx.deviceId,body.clientKey,body.replayWindow,fingerprint,revision]);
  return {v:1,revision};
}

// Withdrawal remains available to the author after a shopper handoff. This projection cannot enumerate any cook.
export async function reviewMyFeedbackWithdrawal(ctx: Context) {
  const grantEpoch = householdPantryEpoch(ctx);
  if (grantEpoch === null) throw unavailable();
  const rows = (await ctx.db.query<{revision:string}>(`SELECT revision FROM ritc.household_meal_feedback
    WHERE household_id=$1 AND member_id=$2 AND cardinality(reactions)>0 ORDER BY revision`,
    [ctx.householdId,ctx.member.member_id])).rows;
  return {v:1, grantEpoch, count:rows.length, basis:digest([ctx.householdId,ctx.member.member_id,grantEpoch,rows])};
}

export async function withdrawMyFeedback(ctx: Context, input: unknown) {
  const review = await reviewMyFeedbackWithdrawal(ctx);
  const command = z.object({v:z.literal(1), grantEpoch:z.number().int().nonnegative(), basis:z.string().regex(/^[a-f0-9]{64}$/)}).strict().parse(input);
  if (command.grantEpoch !== review.grantEpoch || (review.count > 0 && command.basis !== review.basis)) throw refresh();
  // A repeat after a lost reply can only acknowledge an empty set. New consent produces a different basis.
  if (review.count) await ctx.db.query(`UPDATE ritc.household_meal_feedback SET reactions='{}',revision=gen_random_uuid(),updated_at=$3
    WHERE household_id=$1 AND member_id=$2 AND cardinality(reactions)>0`,[ctx.householdId,ctx.member.member_id,ctx.now]);
  return reviewMyFeedbackWithdrawal(ctx);
}
