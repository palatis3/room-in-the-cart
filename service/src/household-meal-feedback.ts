import {randomUUID} from 'node:crypto';
import {digest} from './database.js';
import {z} from 'zod';
import {refresh, unavailable} from './errors.js';
import {householdPantryEpoch} from './pantry-lots.js';
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
  const grantEpoch = householdPantryEpoch(ctx);
  if (grantEpoch === null || shop.shopper_id !== ctx.member.member_id) throw unavailable();
  const row = (await ctx.db.query<{operation_id:string}>(`SELECT operation_id FROM ritc.shared_cook
    WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 AND undone_by IS NULL`,
    [ctx.householdId,shop.shop_id,occurrenceId])).rows[0];
  if (!row) throw unavailable();
  return {cookId: row.operation_id, grantEpoch, authorityEpoch: shop.authority_epoch};
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
  const revision = reactions.length ? randomUUID() : null;
  if (revision) {
    await ctx.db.query(`INSERT INTO ritc.household_meal_feedback(household_id,cook_id,member_id,revision,reactions,updated_at)
      VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(household_id,cook_id,member_id) DO UPDATE SET
      revision=EXCLUDED.revision,reactions=EXCLUDED.reactions,updated_at=EXCLUDED.updated_at`,
      [...args,revision,reactions,ctx.now]);
  } else if (old) {
    await ctx.db.query('DELETE FROM ritc.household_meal_feedback WHERE household_id=$1 AND cook_id=$2 AND member_id=$3',args);
  }
  await ctx.db.query(`INSERT INTO ritc.meal_feedback_receipt(household_id,cook_id,member_id,device_id,client_key,window_id,request_digest,accepted_revision)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[...args,ctx.deviceId,body.clientKey,body.replayWindow,fingerprint,revision]);
  return {v:1,revision};
}
