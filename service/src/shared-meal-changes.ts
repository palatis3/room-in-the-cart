import { z } from 'zod';
import type { Context, HouseholdRepository } from './repository.js';
import type { MealMoves } from './meal-moves.js';
import { digest } from './database.js';
import { ServiceError, unavailable } from './errors.js';
import { requireApprovedSharedIdea } from './shared-meal-ideas.js';
import { sharedMealSchema, preserveProtectedMeal } from './shared-meal-planning.js';

const positive = z.number().int().positive();
export const sharedMealChangeSchema = z.object({
  proposalId: z.string().uuid().transform(value => value.toLowerCase()), occurrenceId: z.string().uuid().transform(value => value.toLowerCase()), baseMealRevision: positive.nullable(),
  shopRevision: positive, authorityEpoch: positive, grantRevision: z.number().int().nonnegative(),
  approvedIdeaId: z.string().uuid().transform(value => value.toLowerCase()).optional(), approvedIdeaRevision: positive.optional(),
  meal: sharedMealSchema, reason: z.string().trim().min(1).max(500),
}).strict().superRefine((v,ctx)=>{if(v.baseMealRevision===null ? (!v.approvedIdeaId||!v.approvedIdeaRevision) : (v.grantRevision<1||v.approvedIdeaId!==undefined||v.approvedIdeaRevision!==undefined))ctx.addIssue({code:'custom',message:'New meals require an exact approved idea; existing edits retain their original revision.'});});
export const sharedMealDismissSchema = z.object({
  proposalId: z.string().uuid().transform(value => value.toLowerCase()), shopRevision: positive, authorityEpoch: positive, grantRevision: z.number().int().nonnegative(),
}).strict();
const stale = () => new ServiceError(409, 'stale_proposal', 'Read the current shared occurrence and review this proposal again.');
export class SharedMealChanges {
  constructor(private readonly repo: HouseholdRepository, private readonly moves: MealMoves) {}
  async read(ctx: Context, id: string) {
    const { shop, shopper, plannerId, grantRevision } = await this.moves.context(ctx, id, true);
    const rows = (await ctx.db.query(`SELECT c.proposal_id,c.body,c.original_meal,c.state FROM ritc.shared_meal_change c
      JOIN ritc.member a ON a.household_id=c.household_id AND a.member_id=c.actor_id AND a.state='active'
      WHERE c.household_id=$1 AND c.shop_id=$2 AND c.authority_epoch=$3 AND c.grant_revision=$4 AND (c.actor_id=$5 OR (c.base_meal_revision IS NULL AND c.actor_id=$6))
      ORDER BY (c.state='pending') DESC,c.created_at DESC,c.proposal_id LIMIT 100`, [ctx.householdId,id,shop.authority_epoch,grantRevision,plannerId,shopper?ctx.member.member_id:plannerId])).rows;
    return { shopId:id, shopRevision:shop.revision, authorityEpoch:shop.authority_epoch, grantRevision,
      phase:shop.phase, shopper, meals:await this.repo.meals(ctx,id),
      proposals:rows.map(row => ({ proposalId:row.proposal_id, request:row.body, original:row.original_meal, state:row.state })) };
  }
  async propose(ctx: Context, id: string, input: z.infer<typeof sharedMealChangeSchema>) {
    const { shop, shopper, grantRevision } = await this.moves.context(ctx,id,true);
    if (shopper && input.baseMealRevision !== null) throw unavailable();
    if (shop.authority_epoch !== input.authorityEpoch || grantRevision !== input.grantRevision) throw stale();
    if(input.baseMealRevision===null) await requireApprovedSharedIdea(ctx,id,shop.authority_epoch,grantRevision,ctx.member.member_id,input.approvedIdeaId!,input.approvedIdeaRevision!,input.meal);
    const prior = (await ctx.db.query('SELECT actor_id,fingerprint,state FROM ritc.shared_meal_change WHERE household_id=$1 AND shop_id=$2 AND proposal_id=$3',
      [ctx.householdId,id,input.proposalId])).rows[0];
    if (prior) {
      if (prior.actor_id !== ctx.member.member_id || prior.fingerprint !== digest(input)) throw new ServiceError(409,'key_reused','Retry the original proposal without changes.');
      return { saved:true, proposalId:input.proposalId };
    }
    if (shop.revision !== input.shopRevision) throw stale();
    const original = (await this.repo.meals(ctx,id)).find(m => m.occurrenceId === input.occurrenceId);
    if(input.baseMealRevision===null) { if(original)throw stale(); }
    else {
      if (!original || original.revision !== input.baseMealRevision || original.meal.day !== input.meal.day || digest(original.meal) === digest(input.meal)) throw stale();
      preserveProtectedMeal(sharedMealSchema.parse(original.meal),input.meal);
    }
    const count = await ctx.db.query("SELECT count(*)::int AS n FROM ritc.shared_meal_change WHERE household_id=$1 AND shop_id=$2 AND grant_revision=$3 AND authority_epoch=$4 AND state='pending'",[ctx.householdId,id,grantRevision,shop.authority_epoch]);
    if (count.rows[0].n >= 100) throw new ServiceError(409,'proposal_limit','Review this planning grant before sending more changes.');
    await ctx.db.query(`INSERT INTO ritc.shared_meal_change(household_id,shop_id,proposal_id,actor_id,authority_epoch,grant_revision,shop_revision,occurrence_id,base_meal_revision,body,original_meal,fingerprint)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
      [ctx.householdId,id,input.proposalId,ctx.member.member_id,shop.authority_epoch,grantRevision,shop.revision,input.occurrenceId,input.baseMealRevision,input,original?.meal??null,digest(input)]);
    return { saved:true, proposalId:input.proposalId };
  }
  async dismiss(ctx: Context,id: string,input: z.infer<typeof sharedMealDismissSchema>) {
    const {shop,shopper,plannerId,grantRevision} = await this.moves.context(ctx,id,true);
    if (!shopper) throw unavailable();
    if (shop.revision !== input.shopRevision || shop.authority_epoch !== input.authorityEpoch || grantRevision !== input.grantRevision) throw stale();
    const result = await ctx.db.query(`UPDATE ritc.shared_meal_change SET state='dismissed' WHERE household_id=$1 AND shop_id=$2 AND proposal_id=$3
      AND authority_epoch=$4 AND grant_revision=$5 AND (actor_id=$6 OR (base_meal_revision IS NULL AND actor_id=$7)) AND state IN ('pending','dismissed')`,
      [ctx.householdId,id,input.proposalId,shop.authority_epoch,grantRevision,plannerId,ctx.member.member_id]);
    if (!result.rowCount) throw stale();
    return {saved:true,proposalId:input.proposalId};
  }
}
/** Runs inside the existing authenticated, household-serialized shop.patch transaction. */
export async function consumeSharedMealChange(ctx: Context, shop: {shop_id:string;revision:number;authority_epoch:number},
  proposalId:string, occurrenceId:string, baseMealRevision:number|null, meal:unknown) {
  const proposal = (await ctx.db.query(`SELECT c.body,c.actor_id,c.grant_revision FROM ritc.shared_meal_change c
    LEFT JOIN ritc.meal_planner p USING(household_id,shop_id,authority_epoch)
    JOIN ritc.member a ON a.household_id=c.household_id AND a.member_id=c.actor_id AND a.state='active' AND a.kind='adult'
    WHERE c.household_id=$1 AND c.shop_id=$2 AND c.proposal_id=$3 AND c.occurrence_id=$4 AND c.shop_revision=$5
    AND c.authority_epoch=$6 AND c.base_meal_revision IS NOT DISTINCT FROM $7 AND c.state='pending'
    AND ((p.planner_id=c.actor_id AND p.revision=c.grant_revision)
      OR (c.base_meal_revision IS NULL AND c.actor_id=$8 AND c.grant_revision=COALESCE(p.revision,0)))`,
    [ctx.householdId,shop.shop_id,proposalId,occurrenceId,shop.revision,shop.authority_epoch,baseMealRevision,ctx.member.member_id])).rows[0];
  if (!proposal || digest(proposal.body.meal) !== digest(meal)) throw stale();
  if(baseMealRevision===null) await requireApprovedSharedIdea(ctx,shop.shop_id,shop.authority_epoch,proposal.grant_revision,
    proposal.actor_id,proposal.body.approvedIdeaId,proposal.body.approvedIdeaRevision,meal);
  await ctx.db.query("UPDATE ritc.shared_meal_change SET state='applied' WHERE household_id=$1 AND shop_id=$2 AND proposal_id=$3",[ctx.householdId,shop.shop_id,proposalId]);
}
