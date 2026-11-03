import { randomUUID, createHash } from 'node:crypto';
import { z } from 'zod';
import { digest, type Database, type Transaction } from '../database.js';
import { ServiceError, accessEnded, invalid, refresh } from '../errors.js';
import type { AppleBillingGateway, VerifiedAppleTransaction } from './apple.js';
import {
  billingUnavailable, bindingConflict, effectiveStatus, hasPaidSeat, supersedes, validityEnd,
  type EntitlementSnapshot, type VerifiedSubscription,
} from './domain.js';

export interface BillingContext {
  db: Transaction; householdId: string;
  member: { member_id: string; kind: string }; now: Date;
}
type StateRow = { purchaser_id: string; revision: number; subscription: VerifiedSubscription; verified_at: Date };
export const billingVerifySchema = z.object({ householdId: z.string().uuid(), signedTransactionInfo: z.string().min(16).max(128_000) }).strict();
export const billingSeatsSchema = z.object({ revision: z.number().int().positive(), userIDs: z.array(z.string().uuid()).max(2) }).strict()
  .refine(value => new Set(value.userIDs.map(id => id.toLowerCase())).size === value.userIDs.length, 'Seat holders must be distinct');
export const billingNotificationSchema = z.object({ signedPayload: z.string().min(16).max(128_000) }).strict();

/** Methods except notification run inside HouseholdRepository.authorized's locked transaction.
 * The HTTP adapter must await that transaction's COMMIT before emitting durable:true.
 * This module never changes any shopper authority or household planning/data grant.
 */
export class BillingService {
  constructor(private readonly apple: AppleBillingGateway | null) {}
  private gateway(): AppleBillingGateway { if (!this.apple) throw billingUnavailable(); return this.apple; }
  private adult(ctx: BillingContext): void { if (ctx.member.kind !== 'adult') throw accessEnded(); }
  private async row(ctx: BillingContext): Promise<StateRow | undefined> {
    return (await ctx.db.query<StateRow>('SELECT purchaser_id,revision,subscription,verified_at FROM ritc.billing_state WHERE household_id=$1 FOR UPDATE', [ctx.householdId])).rows[0];
  }
  async prepare(ctx: BillingContext): Promise<{ appAccountToken: string }> {
    this.adult(ctx); this.gateway();
    const current = await this.row(ctx);
    if (current && current.purchaser_id !== ctx.member.member_id)
      throw new ServiceError(409, 'purchase_context_not_purchaser', 'Read your named seat entitlement; only the purchasing adult can prepare another purchase.');
    await ctx.db.query(`INSERT INTO ritc.billing_account(household_id,purchaser_id,app_account_token) VALUES($1,$2,$3)
      ON CONFLICT(household_id,purchaser_id) DO NOTHING`, [ctx.householdId, ctx.member.member_id, randomUUID()]);
    const result = await ctx.db.query('SELECT app_account_token FROM ritc.billing_account WHERE household_id=$1 AND purchaser_id=$2', [ctx.householdId, ctx.member.member_id]);
    return { appAccountToken: result.rows[0].app_account_token as string };
  }
  private async assertToken(ctx: BillingContext, transaction: VerifiedAppleTransaction): Promise<void> {
    const account = await ctx.db.query('SELECT app_account_token FROM ritc.billing_account WHERE household_id=$1 AND purchaser_id=$2', [ctx.householdId, ctx.member.member_id]);
    if (account.rows[0]?.app_account_token !== transaction.appAccountToken) throw bindingConflict();
  }
  private async bind(ctx: BillingContext, state: VerifiedSubscription): Promise<void> {
    // Global unique key arbitrates cross-household races even though RLS hides foreign rows.
    await ctx.db.query(`INSERT INTO ritc.billing_binding(environment,original_transaction_id,household_id,purchaser_id,app_account_token)
      VALUES($1,$2,$3,$4,$5) ON CONFLICT(environment,original_transaction_id) DO NOTHING`,
    [state.environment,state.originalTransactionID,ctx.householdId,ctx.member.member_id,state.appAccountToken]);
    const binding = await ctx.db.query(`SELECT purchaser_id,app_account_token FROM ritc.billing_binding
      WHERE environment=$1 AND original_transaction_id=$2 AND household_id=$3`, [state.environment,state.originalTransactionID,ctx.householdId]);
    if (binding.rows[0]?.purchaser_id !== ctx.member.member_id || binding.rows[0]?.app_account_token !== state.appAccountToken) throw bindingConflict();
  }
  private async apply(ctx: BillingContext, next: VerifiedSubscription): Promise<StateRow> {
    next = { ...next, status: effectiveStatus(next, ctx.now.getTime()) };
    await this.assertToken(ctx, next);
    const existing = await this.row(ctx);
    if (existing && (existing.purchaser_id !== ctx.member.member_id || existing.subscription.environment !== next.environment)) throw bindingConflict();
    await this.bind(ctx, next);
    const same = existing && digest(existing.subscription) === digest(next);
    if (!existing) {
      await ctx.db.query('INSERT INTO ritc.billing_state(household_id,purchaser_id,subscription,verified_at) VALUES($1,$2,$3,$4)', [ctx.householdId,ctx.member.member_id,next,ctx.now]);
      await ctx.db.query('INSERT INTO ritc.billing_seat(household_id,slot,member_id,display_name) SELECT $1,1,member_id,alias FROM ritc.member WHERE household_id=$1 AND member_id=$2', [ctx.householdId,ctx.member.member_id]);
    } else if (supersedes(next, existing.subscription)) {
      await ctx.db.query('UPDATE ritc.billing_state SET subscription=$2,verified_at=$3,revision=revision+1 WHERE household_id=$1', [ctx.householdId,next,ctx.now]);
    } else if (same) {
      await ctx.db.query('UPDATE ritc.billing_state SET verified_at=$2 WHERE household_id=$1', [ctx.householdId,ctx.now]);
    }
    const result = (await this.row(ctx))!;
    const key = createHash('sha256').update(JSON.stringify(next)).digest('hex');
    await this.audit(ctx, 'verified', key, result.revision);
    return result;
  }
  private async audit(ctx: BillingContext, kind: 'verified' | 'notification' | 'seats_changed', key: string, revision: number): Promise<void> {
    await ctx.db.query(`INSERT INTO ritc.billing_event(household_id,event_id,kind,event_key,actor_id,revision,occurred_at)
      VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(household_id,kind,event_key) DO NOTHING`, [ctx.householdId,randomUUID(),kind,key,ctx.member.member_id,revision,ctx.now]);
  }
  private async project(ctx: BillingContext, state?: StateRow): Promise<EntitlementSnapshot> {
    if (!state) return { householdID: ctx.householdId, purchaserID: ctx.member.member_id, revision: 0, status: 'free',
      expiresAt: null, graceExpiresAt: null, verifiedAt: ctx.now.toISOString(), validUntil: ctx.now.toISOString(), seats: [] };
    const removed = await ctx.db.query(`DELETE FROM ritc.billing_seat s USING ritc.member m
      WHERE s.household_id=$1 AND m.household_id=s.household_id AND m.member_id=s.member_id AND (m.state<>'active' OR m.kind<>'adult') RETURNING s.slot`, [ctx.householdId]);
    if (removed.rowCount) {
      await ctx.db.query('UPDATE ritc.billing_state SET revision=revision+1 WHERE household_id=$1',[ctx.householdId]);
      state = (await this.row(ctx))!;
      await this.audit(ctx,'seats_changed',String(state.revision),state.revision);
    }
    const result = await ctx.db.query(`SELECT s.member_id,s.display_name FROM ritc.billing_seat s JOIN ritc.member m USING(household_id,member_id)
      WHERE s.household_id=$1 AND m.kind='adult' AND m.state='active' ORDER BY s.slot`, [ctx.householdId]);
    return { householdID: ctx.householdId, purchaserID: state.purchaser_id, revision: state.revision,
      status: effectiveStatus(state.subscription, ctx.now.getTime()), expiresAt: new Date(state.subscription.expiresAt).toISOString(),
      graceExpiresAt: state.subscription.graceExpiresAt === null ? null : new Date(state.subscription.graceExpiresAt).toISOString(),
      verifiedAt: state.verified_at.toISOString(), validUntil: new Date(validityEnd(state.subscription,state.verified_at.getTime(),ctx.now.getTime())).toISOString(),
      seats: result.rows.map(row => ({ userID: row.member_id as string, displayName: row.display_name as string, isAdult: true })) };
  }
  async verify(ctx: BillingContext, signedTransactionInfo: string): Promise<{ acceptedTransactionID: string; durable: true; snapshot: EntitlementSnapshot }> {
    this.adult(ctx);
    const gateway = this.gateway();
    const submitted = await gateway.verifyTransaction(signedTransactionInfo);
    await this.assertToken(ctx, submitted);
    // Even a valid old receipt must not resurrect a subscription already refunded by Apple.
    const current = await gateway.current(submitted.originalTransactionID);
    if (current.originalTransactionID !== submitted.originalTransactionID || current.appAccountToken !== submitted.appAccountToken) throw bindingConflict();
    const state = await this.apply(ctx, current);
    await ctx.db.query(`INSERT INTO ritc.billing_delivery(environment,transaction_id,household_id,purchaser_id,original_transaction_id,accepted_at)
      VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(environment,transaction_id) DO NOTHING`,
    [current.environment,submitted.transactionID,ctx.householdId,ctx.member.member_id,submitted.originalTransactionID,ctx.now]);
    const receipt = await ctx.db.query('SELECT purchaser_id FROM ritc.billing_delivery WHERE environment=$1 AND transaction_id=$2 AND household_id=$3', [current.environment,submitted.transactionID,ctx.householdId]);
    if (receipt.rows[0]?.purchaser_id !== ctx.member.member_id) throw bindingConflict();
    return { acceptedTransactionID: submitted.transactionID, durable: true, snapshot: await this.project(ctx,state) };
  }
  /** Read refresh doubles as a missing-notification reconciliation path. */
  async snapshot(ctx: BillingContext): Promise<EntitlementSnapshot> {
    this.adult(ctx);
    let state = await this.row(ctx);
    if (state && state.purchaser_id !== ctx.member.member_id) {
      const ownSeat = await ctx.db.query(`SELECT 1 FROM ritc.billing_seat s
        JOIN ritc.member m USING(household_id,member_id)
        WHERE s.household_id=$1 AND s.member_id=$2 AND m.kind='adult' AND m.state='active'`,
        [ctx.householdId,ctx.member.member_id]);
      // A contributor without a seat receives the same own Free projection whether
      // another adult has a subscription or not; never reveal the paid roster.
      if (!ownSeat.rowCount) return this.project(ctx);
    }
    if (state) {
      const current = await this.gateway().current(state.subscription.originalTransactionID);
      const purchaserContext = { ...ctx, member: { member_id: state.purchaser_id, kind: 'adult' } };
      state = await this.apply(purchaserContext,current);
    }
    return this.project(ctx,state);
  }
  async replaceSeats(ctx: BillingContext, input: unknown): Promise<EntitlementSnapshot> {
    this.adult(ctx);
    const parsed = billingSeatsSchema.safeParse(input); if (!parsed.success) throw invalid();
    const before = await this.row(ctx);
    if (!before || before.purchaser_id !== ctx.member.member_id) throw accessEnded();
    if (before.revision !== parsed.data.revision) throw refresh();
    // Reconcile before seat assignment; expired/revoked/retry/unknown cannot add paid access.
    const next = await this.gateway().current(before.subscription.originalTransactionID);
    const state = await this.apply(ctx,next);
    const snapshot = await this.project(ctx,state);
    if (!['active','grace'].includes(snapshot.status) || Date.parse(snapshot.validUntil) <= ctx.now.getTime()) throw new ServiceError(403,'membership_inactive','Keep using Free or restore the membership.');
    for (const id of parsed.data.userIDs) {
      const member = await ctx.db.query("SELECT member_id FROM ritc.member WHERE household_id=$1 AND member_id=$2 AND kind='adult' AND state='active'", [ctx.householdId,id]);
      if (!member.rowCount) throw invalid();
    }
    await ctx.db.query('DELETE FROM ritc.billing_seat WHERE household_id=$1', [ctx.householdId]);
    for (const [slot,id] of parsed.data.userIDs.entries()) await ctx.db.query('INSERT INTO ritc.billing_seat(household_id,slot,member_id,display_name) SELECT $1,$2,member_id,alias FROM ritc.member WHERE household_id=$1 AND member_id=$3', [ctx.householdId,slot+1,id]);
    await ctx.db.query('UPDATE ritc.billing_state SET revision=revision+1 WHERE household_id=$1', [ctx.householdId]);
    const result = (await this.row(ctx))!;
    await this.audit(ctx,'seats_changed',String(result.revision),result.revision);
    return this.project(ctx,result);
  }
  async seatCandidates(ctx: BillingContext): Promise<{ adults: EntitlementSnapshot['seats'] }> {
    this.adult(ctx);
    const state = await this.row(ctx);
    if (!state || state.purchaser_id !== ctx.member.member_id) throw accessEnded();
    const result = await ctx.db.query("SELECT member_id,alias FROM ritc.member WHERE household_id=$1 AND kind='adult' AND state='active' ORDER BY alias,member_id",[ctx.householdId]);
    return { adults: result.rows.map(row => ({ userID: row.member_id as string, displayName: row.alias as string, isAdult: true })) };
  }
  /** Call in addition to the operation's independent data-grant / shopper checks. */
  async requirePaidSeat(ctx: BillingContext): Promise<void> {
    const snapshot = await this.snapshot(ctx);
    if (!hasPaidSeat(snapshot,ctx.member.member_id,ctx.now)) throw new ServiceError(403,'membership_inactive','Use the Free manual path or manage named adult seats.');
  }
  async notification(pool: Database, signedPayload: string): Promise<{ accepted: true }> {
    const notification = await this.gateway().verifyNotification(signedPayload);
    if (!notification.transaction) return { accepted: true }; // Apple's signed TEST notification.
    const transaction = notification.transaction;
    const current = await this.gateway().current(transaction.originalTransactionID);
    if (current.appAccountToken !== transaction.appAccountToken) throw bindingConflict();
    const db = await pool.connect();
    try {
      await db.query('BEGIN');
      await db.query("SELECT set_config('app.billing_token',$1,true)", [transaction.appAccountToken]);
      const account = (await db.query('SELECT household_id,purchaser_id FROM ritc.billing_account WHERE app_account_token=$1', [transaction.appAccountToken])).rows[0];
      // Do not acknowledge delivery before the purchaser has established their binding context.
      if (!account) throw new ServiceError(503,'billing_context_pending','Retry notification delivery.');
      await db.query("SELECT set_config('app.household_id',$1,true)", [account.household_id]);
      await db.query('SELECT household_id FROM ritc.household WHERE household_id=$1 FOR UPDATE', [account.household_id]);
      const member = (await db.query('SELECT member_id,kind,state FROM ritc.member WHERE household_id=$1 AND member_id=$2', [account.household_id,account.purchaser_id])).rows[0];
      if (!member || member.kind !== 'adult') throw accessEnded();
      const ctx: BillingContext = { db, householdId: account.household_id as string, member: { member_id: account.purchaser_id as string, kind: 'adult' }, now: new Date() };
      const existing = await this.row(ctx);
      // Revoked household membership cannot receive newly minted seats; existing billing state still reconciles refunds/expiry.
      if (!existing && member.state !== 'active') throw accessEnded();
      const state = await this.apply(ctx,current);
      await this.audit(ctx,'notification',notification.notificationID,state.revision);
      await db.query('COMMIT');
      return { accepted: true };
    } catch (error) { await db.query('ROLLBACK'); throw error; }
    finally { db.release(); }
  }
}
