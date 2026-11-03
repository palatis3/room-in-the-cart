import { z } from 'zod';
import type { Context, HouseholdRepository } from './repository.js';
import type { BillingService } from './billing/service.js';
import { ServiceError, unavailable } from './errors.js';
import { uuid } from './contracts.js';

const positive = z.number().int().positive();
export const grantChange = z.object({ plannerId: uuid.nullable(), grantRevision: positive.or(z.literal(0)), authorityEpoch: positive }).strict();
export const moveRequest = z.object({ proposalId: uuid, occurrenceId: uuid, day: z.iso.date(),
  shopRevision: positive, authorityEpoch: positive, grantRevision: positive }).strict();
export const dismissMove = z.object({proposalId: uuid, shopRevision: positive, authorityEpoch: positive, grantRevision: positive}).strict();
const stale = () => new ServiceError(409,'stale_base','Read the current shared plan before reviewing this change.');

export class MealMoves {
  constructor(private readonly repo: HouseholdRepository, private readonly billing?: BillingService) {}

  async context(ctx: Context, id: string, allowLocked = false) {
    if(ctx.viewGrantId || ctx.member.kind !== 'adult') throw unavailable();
    const shop = await this.repo.shop(ctx,id);
    const row = (await ctx.db.query('SELECT planner_id,revision,authority_epoch FROM ritc.meal_planner WHERE household_id=$1 AND shop_id=$2',
      [ctx.householdId,id])).rows[0];
    const shopper = shop.shopper_id === ctx.member.member_id;
    const plannerId = row?.authority_epoch === shop.authority_epoch ? row.planner_id as string|null : null;
    if(!shopper) {
      if(plannerId !== ctx.member.member_id || (!allowLocked && shop.phase !== 'draft') || shop.phase === 'closed') throw unavailable();
      if(!this.billing) throw unavailable();
      await this.billing.requirePaidSeat(ctx);
    }
    return {shop,shopper,plannerId,grantRevision: Number(row?.revision ?? 0)};
  }

  async read(ctx: Context,id: string) {
    const {shop,shopper,plannerId,grantRevision} = await this.context(ctx,id);
    const proposals = (await ctx.db.query(`SELECT m.proposal_id,m.occurrence_id,m.proposed_day::text FROM ritc.meal_move m
      JOIN ritc.member a ON a.household_id=m.household_id AND a.member_id=m.actor_id AND a.state='active'
      WHERE m.household_id=$1 AND m.shop_id=$2 AND m.shop_revision=$3 AND m.authority_epoch=$4
      AND m.grant_revision=$5 AND m.actor_id=$6 AND m.state='pending' ORDER BY m.proposal_id`,
      [ctx.householdId,id,shop.revision,shop.authority_epoch,grantRevision,plannerId])).rows;
    const adults = shopper ? (await ctx.db.query("SELECT member_id,alias FROM ritc.member WHERE household_id=$1 AND member_id<>$2 AND kind='adult' AND state='active' ORDER BY alias,member_id",
      [ctx.householdId,ctx.member.member_id])).rows.map(row=>({id:row.member_id,label:row.alias})) : [];
    return {shopId:id,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,grantRevision,shopper,plannerId,adults,
      meals:await this.repo.meals(ctx,id), proposals:proposals.map(row=>({proposalId:row.proposal_id,occurrenceId:row.occurrence_id,day:row.proposed_day}))};
  }

  async grant(ctx: Context,id: string,input: z.infer<typeof grantChange>) {
    const shop = await this.repo.shop(ctx,id);
    this.repo.requireShopper(ctx,shop); this.repo.requireDraft(shop);
    const {grantRevision,plannerId} = await this.context(ctx,id);
    if(input.authorityEpoch !== shop.authority_epoch) throw stale();
    if(input.plannerId === plannerId && (input.grantRevision === grantRevision || input.grantRevision+1 === grantRevision)) return {saved:true};
    if(input.grantRevision !== grantRevision) throw stale();
    if(input.plannerId) {
      const target=await ctx.db.query("SELECT 1 FROM ritc.member WHERE household_id=$1 AND member_id=$2 AND member_id<>$3 AND kind='adult' AND state='active'",
        [ctx.householdId,input.plannerId,ctx.member.member_id]);
      if(!target.rowCount) throw unavailable();
    }
    await ctx.db.query(`INSERT INTO ritc.meal_planner(household_id,shop_id,authority_epoch,revision,planner_id) VALUES($1,$2,$3,$4,$5)
      ON CONFLICT(household_id,shop_id) DO UPDATE SET authority_epoch=$3,revision=$4,planner_id=$5`,
      [ctx.householdId,id,shop.authority_epoch,grantRevision+1,input.plannerId]);
    return {saved:true};
  }

  async dismiss(ctx: Context,id: string,input: z.infer<typeof dismissMove>) {
    const {shop,shopper,grantRevision,plannerId} = await this.context(ctx,id);
    if(!shopper) throw unavailable();
    if(shop.revision!==input.shopRevision || shop.authority_epoch!==input.authorityEpoch || grantRevision!==input.grantRevision) throw stale();
    const result=await ctx.db.query(`UPDATE ritc.meal_move SET state='dismissed' WHERE household_id=$1 AND shop_id=$2
      AND proposal_id=$3 AND shop_revision=$4 AND authority_epoch=$5 AND grant_revision=$6 AND actor_id=$7 AND state IN ('pending','dismissed')`,
      [ctx.householdId,id,input.proposalId,shop.revision,shop.authority_epoch,grantRevision,plannerId]);
    if(!result.rowCount) throw stale();
    return {saved:true};
  }

  async propose(ctx: Context,id: string,input: z.infer<typeof moveRequest>) {
    const {shop,shopper,grantRevision} = await this.context(ctx,id);
    if(shopper) throw unavailable();
    if(grantRevision !== input.grantRevision || shop.authority_epoch !== input.authorityEpoch) throw stale();
    const prior=(await ctx.db.query('SELECT actor_id,occurrence_id,proposed_day::text,shop_revision,grant_revision,authority_epoch FROM ritc.meal_move WHERE household_id=$1 AND shop_id=$2 AND proposal_id=$3',
      [ctx.householdId,id,input.proposalId])).rows[0];
    if(prior) {
      if(prior.actor_id!==ctx.member.member_id || prior.occurrence_id!==input.occurrenceId || prior.proposed_day!==input.day ||
         prior.shop_revision!==input.shopRevision || prior.grant_revision!==grantRevision || prior.authority_epoch!==input.authorityEpoch) throw stale();
      return {saved:true};
    }
    if(shop.revision!==input.shopRevision) throw stale();
    const meals=await this.repo.meals(ctx,id);
    const occurrence=meals.find(meal=>meal.occurrenceId===input.occurrenceId);
    if(!occurrence || occurrence.meal.day===input.day) throw stale();
    const same=await ctx.db.query(`SELECT 1 FROM ritc.meal_move WHERE household_id=$1 AND shop_id=$2 AND actor_id=$3
      AND shop_revision=$4 AND grant_revision=$5 AND occurrence_id=$6 AND proposed_day=$7 AND state='pending'`,
      [ctx.householdId,id,ctx.member.member_id,shop.revision,grantRevision,input.occurrenceId,input.day]);
    if(same.rowCount) return {saved:true};
    const count=await ctx.db.query("SELECT count(*)::int AS n FROM ritc.meal_move WHERE household_id=$1 AND shop_id=$2 AND shop_revision=$3 AND grant_revision=$4 AND state='pending'",
      [ctx.householdId,id,shop.revision,grantRevision]);
    if(count.rows[0].n>=100) throw new ServiceError(409,'proposal_limit','Review the outstanding meal changes first.');
    await ctx.db.query(`INSERT INTO ritc.meal_move(household_id,shop_id,proposal_id,actor_id,authority_epoch,grant_revision,shop_revision,occurrence_id,proposed_day)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
      [ctx.householdId,id,input.proposalId,ctx.member.member_id,shop.authority_epoch,grantRevision,shop.revision,input.occurrenceId,input.day]);
    return {saved:true};
  }
}
