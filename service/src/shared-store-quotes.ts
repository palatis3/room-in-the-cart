import { z } from 'zod';
import { digest } from './database.js';
import { ServiceError, unavailable } from './errors.js';
import { parseCommand } from './contracts.js';
import type { Context, HouseholdRepository } from './repository.js';
const id = z.string().uuid().transform(v => v.toLowerCase());
const cents = z.number().int().min(0).max(1000000000).nullable();
const text = z.string().trim().min(1).max(240);
const date = z.string().datetime({ offset: true });
const base = z.object({ operationId: id, shopRevision: z.number().int().positive(), authorityEpoch: z.number().int().positive(), grantRevision: z.number().int().nonnegative() });
const choice = z.enum(['first', 'second']);
const option = z.object({ label: text, store: text, branch: text, mode: z.enum(['pickup', 'delivery', 'inStore']), slot: date, observedAt: date,
    source: text, currency: z.literal('USD'), terms: z.string().trim().max(500), itemsMinor: cents, checkoutMinor: cents, allChargesIncluded: z.boolean(),
    available: z.boolean().nullable(), quantitiesMatched: z.boolean(), singleStore: z.boolean(), tripAlreadyPlanned: z.boolean(), tripMinor: cents,
    extraMinutes: z.number().int().min(0).max(525600).nullable(),
    capMinor: cents.optional().default(null), capScope: z.enum(['wholeCheckout', 'itemsOnly']).optional().default('wholeCheckout'),
    eligibilityConfirmed: z.boolean().optional().default(false) }).strict();
const options = z.object({ first: option, second: option }).strict();
const save = base.extend({ options }).strict();
const propose = base.extend({ pairId: id, choice }).strict();
const adopt = propose.extend({ proposalId: id.nullable() }).strict();
const grant = base.extend({ adultId: id, enabled: z.boolean(), targetRevision: z.number().int().nonnegative() }).strict();
export type StoreQuoteOptions = z.infer<typeof options>;
const stale = () => new ServiceError(409, 'stale_base', 'Review the current shop and its entered store quotes.');
const conflict = () => new ServiceError(409, 'operation_conflict', 'This identifier belongs to a different review.');
const delta = (a: number | null, b: number | null) => a === null || b === null ? null : b - a;
/** Both alternatives use the server-snapshotted commitments. Cash is bounded
 * integer minor units; optional travel time is never converted into money. */
export function compareStoreQuotes(pair: StoreQuoteOptions) {
    const { first, second } = pair;
    const comparable = first.quantitiesMatched && second.quantitiesMatched && first.singleStore && second.singleStore;
    const checkout = (entered: StoreQuoteOptions['first']) => entered.allChargesIncluded ? entered.checkoutMinor : null;
    const tripTotal = (entered: StoreQuoteOptions['first']) => {
        const total = checkout(entered);
        return total === null || entered.tripMinor === null ? null : total + entered.tripMinor;
    };
    const firstCheckout = checkout(first), secondCheckout = checkout(second);
    const firstTrip = tripTotal(first), secondTrip = tripTotal(second);
    const cashDelta = comparable ? delta(firstTrip, secondTrip) : null;
    const coverageConfirmed = first.available === true && second.available === true
        && first.eligibilityConfirmed === true && second.eligibilityConfirmed === true;
    const capResult = (entered: StoreQuoteOptions['first']) => {
        const amountMinor = entered.capMinor ?? null;
        const scope = entered.capScope ?? 'wholeCheckout';
        const total = scope === 'itemsOnly' ? entered.itemsMinor : checkout(entered);
        const known = amountMinor !== null && total !== null;
        return {
            amountMinor, scope,
            status: !known ? 'unresolved' : total > amountMinor ? 'overCap' : 'withinCap',
            overMinor: known ? Math.max(0, total - amountMinor) : null,
            headroomMinor: known ? amountMinor - total : null,
        };
    };
    const secondBreakEven = comparable && coverageConfirmed && second.tripMinor === null
        && firstTrip !== null && secondCheckout !== null && firstTrip >= secondCheckout
        ? firstTrip - secondCheckout : null;
    return {
        comparable, firstCheckout, secondCheckout, firstTrip, secondTrip,
        itemDelta: comparable ? delta(first.itemsMinor, second.itemsMinor) : null,
        checkoutDelta: comparable ? delta(firstCheckout, secondCheckout) : null,
        cashDelta,
        minutesDelta: comparable ? delta(first.extraMinutes, second.extraMinutes) : null,
        preferred: coverageConfirmed && cashDelta !== null && cashDelta !== 0 ? (cashDelta < 0 ? 'second' : 'first') : null,
        secondBreakEven, firstCap: capResult(first), secondCap: capResult(second),
    };
}
export class SharedStoreQuotes {
    constructor(private readonly repo: HouseholdRepository) { }
    private async access(ctx: Context, shopId: string) {
        if (ctx.viewGrantId || ctx.member.kind !== 'adult' || ctx.member.state !== 'active')
            throw unavailable();
        const shop = await this.repo.shop(ctx, shopId), shopper = shop.shopper_id === ctx.member.member_id;
        const permission = shopper ? null : (await ctx.db.query('SELECT revision FROM ritc.shop_budget_grant WHERE household_id=$1 AND shop_id=$2 AND member_id=$3 AND enabled AND authority_epoch=$4', [ctx.householdId, shopId, ctx.member.member_id, shop.authority_epoch])).rows[0];
        if (!shopper && !permission)
            throw unavailable();
        return { shop, shopper, grantRevision: Number(permission?.revision ?? 0) };
    }
    private async commitments(ctx: Context, shopId: string) {
        return (await this.repo.lines(ctx, shopId)).map(({ lineId, originalItem, packs }) => ({ id: lineId, label: originalItem, packs }));
    }
    private async activePair(ctx: Context, shopId: string, pairId: string, shopper: boolean, epoch: number) {
        const p = (await ctx.db.query(`SELECT p.* FROM ritc.store_quote_pair p JOIN ritc.member m ON m.household_id=p.household_id AND m.member_id=p.actor_id AND m.state='active'
      WHERE p.household_id=$1 AND p.shop_id=$2 AND p.pair_id=$3 AND p.authority_epoch=$4 AND
        (p.actor_id=$5 OR ($6 AND EXISTS(SELECT 1 FROM ritc.store_quote_proposal q WHERE q.household_id=p.household_id AND q.shop_id=p.shop_id AND q.pair_id=p.pair_id))) AND
        (p.grant_revision=0 OR EXISTS(SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=p.household_id AND g.shop_id=p.shop_id AND g.member_id=p.actor_id
          AND g.enabled AND g.authority_epoch=p.authority_epoch AND g.revision=p.grant_revision))`, [ctx.householdId, shopId, pairId, epoch, ctx.member.member_id, shopper])).rows[0];
        if (!p)
            throw unavailable();
        return p;
    }
    async read(ctx: Context, shopId: string, after: string | null) {
        const { shop, shopper, grantRevision } = await this.access(ctx, shopId);
        let cursor = null;
        if (after) {
            const p = (await ctx.db.query(`SELECT p.created_at FROM ritc.store_quote_pair p
        JOIN ritc.member m ON m.household_id=p.household_id AND m.member_id=p.actor_id AND m.state='active'
        WHERE p.household_id=$1 AND p.shop_id=$2 AND p.pair_id=$3
        AND (actor_id=$4 OR ($5 AND authority_epoch=$6 AND EXISTS(SELECT 1 FROM ritc.store_quote_proposal q
        WHERE q.household_id=p.household_id AND q.shop_id=p.shop_id AND q.pair_id=p.pair_id)
        AND (grant_revision=0 OR EXISTS(SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=p.household_id AND g.shop_id=p.shop_id
        AND g.member_id=p.actor_id AND g.enabled AND g.authority_epoch=p.authority_epoch AND g.revision=p.grant_revision))))`, [ctx.householdId, shopId, id.parse(after), ctx.member.member_id, shopper, shop.authority_epoch])).rows[0];
            if (!p)
                throw unavailable();
            cursor = p.created_at;
        }
        const rows = (await ctx.db.query(`SELECT p.pair_id,p.shop_revision,p.authority_epoch,p.grant_revision,p.created_at,p.commitments,p.options,p.actor_id=$3 AS own,
      (SELECT jsonb_agg(jsonb_build_object('proposalId',q.proposal_id,'choice',q.choice) ORDER BY q.proposal_id) FROM ritc.store_quote_proposal q
        WHERE q.household_id=p.household_id AND q.shop_id=p.shop_id AND q.pair_id=p.pair_id) proposals
      FROM ritc.store_quote_pair p JOIN ritc.member m ON m.household_id=p.household_id AND m.member_id=p.actor_id AND m.state='active'
      WHERE p.household_id=$1 AND p.shop_id=$2 AND (p.actor_id=$3 OR ($5 AND p.authority_epoch=$4 AND EXISTS(SELECT 1 FROM ritc.store_quote_proposal q
        WHERE q.household_id=p.household_id AND q.shop_id=p.shop_id AND q.pair_id=p.pair_id)))
      AND (p.actor_id=$3 OR p.grant_revision=0 OR EXISTS(SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=p.household_id AND g.shop_id=p.shop_id AND g.member_id=p.actor_id AND g.enabled
        AND g.authority_epoch=p.authority_epoch AND g.revision=p.grant_revision)) AND ($6::timestamptz IS NULL OR (p.created_at,p.pair_id)<($6,$7::uuid))
      ORDER BY p.created_at DESC,p.pair_id DESC LIMIT 31`, [ctx.householdId, shopId, ctx.member.member_id, shop.authority_epoch, shopper, cursor, after])).rows;
        const adults = shopper ? (await ctx.db.query(`SELECT m.member_id AS id,m.alias AS label,COALESCE(g.revision,0) AS revision,COALESCE(g.enabled AND g.authority_epoch=$4,false) AS enabled
      FROM ritc.member m LEFT JOIN ritc.shop_budget_grant g ON g.household_id=m.household_id AND g.member_id=m.member_id AND g.shop_id=$2
      WHERE m.household_id=$1 AND m.kind='adult' AND m.state='active' AND m.member_id<>$3 ORDER BY m.alias,m.member_id`, [ctx.householdId, shopId, ctx.member.member_id, shop.authority_epoch])).rows : [];
        const current = (await ctx.db.query(`SELECT p.options->a.choice AS chosen,a.revision FROM ritc.shop s
      JOIN ritc.store_quote_adoption a ON a.household_id=s.household_id AND a.shop_id=s.shop_id AND a.revision=s.store_basis_revision
      JOIN ritc.store_quote_pair p ON p.household_id=a.household_id AND p.shop_id=a.shop_id AND p.pair_id=a.pair_id
      WHERE s.household_id=$1 AND s.shop_id=$2`, [ctx.householdId, shopId])).rows[0];
        const selected = current?.chosen;
        return { shopId, shopRevision: shop.revision, authorityEpoch: shop.authority_epoch, grantRevision, shopper, phase: shop.phase, adults,
            commitments: await this.commitments(ctx, shopId), currentBasis: selected ? { store: selected.store, branch: selected.branch, mode: selected.mode, slot: selected.slot, revision: current.revision } : null,
            pairs: rows.slice(0, 30).map(p => ({ pairId: p.pair_id, baseRevision: p.shop_revision, savedAt: p.created_at, own: p.own, commitments: p.commitments, options: p.options,
                authorityEpoch: p.authority_epoch, grantRevision: p.grant_revision,
                stale: p.shop_revision !== shop.revision || p.authority_epoch !== shop.authority_epoch || (p.own && !shopper && p.grant_revision !== grantRevision),
                comparison: compareStoreQuotes(p.options), proposals: p.proposals ?? [] })), nextCursor: rows.length > 30 ? rows[29].pair_id : null };
    }
    async change(ctx: Context, shopId: string, action: 'grant' | 'pairs' | 'proposals' | 'adoptions', raw: unknown) {
        const scheme = { grant, pairs: save, proposals: propose, adoptions: adopt }[action];
        const input = scheme.parse(raw), { shop, shopper, grantRevision } = await this.access(ctx, shopId);
        if ((action === 'grant' || action === 'adoptions') && !shopper)
            throw unavailable();
        if (input.authorityEpoch !== shop.authority_epoch || input.grantRevision !== grantRevision)
            throw stale();
        const args = [ctx.householdId, shopId, ctx.member.member_id, input.operationId];
        const fingerprint = digest({ action, input });
        // HTTP calls this inside HouseholdRepository.authorized, which locks the
        // household row. Reauthorize before reading a receipt; exact authorized
        // retries then survive later draft revisions or checkout freezing.
        const prior = (await ctx.db.query('SELECT fingerprint,receipt FROM ritc.store_quote_mutation WHERE household_id=$1 AND shop_id=$2 AND actor_id=$3 AND operation_id=$4', args)).rows[0];
        if (prior) {
            if (prior.fingerprint !== fingerprint)
                throw conflict();
            return prior.receipt;
        }
        this.repo.checkBase(shop, input);
        if (action !== 'grant')
            this.repo.requireDraft(shop);
        let revision = shop.revision;
        if (action === 'grant') {
            const change = grant.parse(input);
            const target = (await ctx.db.query("SELECT 1 FROM ritc.member WHERE household_id=$1 AND member_id=$2 AND state='active' AND kind='adult' AND member_id<>$3", [ctx.householdId, change.adultId, shop.shopper_id])).rowCount;
            if (!target)
                throw unavailable();
            const old = (await ctx.db.query('SELECT revision FROM ritc.shop_budget_grant WHERE household_id=$1 AND shop_id=$2 AND member_id=$3', [ctx.householdId, shopId, change.adultId])).rows[0];
            if ((old?.revision ?? 0) !== change.targetRevision)
                throw stale();
            await ctx.db.query(`INSERT INTO ritc.shop_budget_grant(household_id,shop_id,member_id,authority_epoch,revision,enabled) VALUES($1,$2,$3,$4,$5,$6)
        ON CONFLICT(household_id,shop_id,member_id) DO UPDATE SET authority_epoch=excluded.authority_epoch,revision=excluded.revision,enabled=excluded.enabled`, [ctx.householdId, shopId, change.adultId, shop.authority_epoch, change.targetRevision + 1, change.enabled]);
        }
        else if (action === 'pairs') {
            const { options: entered } = save.parse(input);
            if ([entered.first, entered.second].some(o => Date.parse(o.observedAt) > ctx.now.getTime() + 300000))
                throw new ServiceError(422, 'future_evidence', 'Use the time the quote was observed.');
            const commitments = await this.commitments(ctx, shopId);
            if (!commitments.length)
                throw new ServiceError(409, 'empty_basket', 'Review a shared basket before comparing stores.');
            const count = (await ctx.db.query('SELECT count(*)::int AS n FROM ritc.store_quote_pair WHERE household_id=$1 AND shop_id=$2 AND actor_id=$3', [ctx.householdId, shopId, ctx.member.member_id])).rows[0].n;
            if (count >= 500)
                throw new ServiceError(409, 'comparison_limit', 'Keep the saved comparisons and start a fresh shop before adding another.');
            const inserted = await ctx.db.query(`INSERT INTO ritc.store_quote_pair(household_id,shop_id,pair_id,actor_id,shop_revision,authority_epoch,grant_revision,commitments,options,created_at)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) ON CONFLICT DO NOTHING`, [ctx.householdId, shopId, input.operationId, ctx.member.member_id, revision, shop.authority_epoch, grantRevision, JSON.stringify(commitments), entered, ctx.now]);
            if (!inserted.rowCount)
                throw conflict();
        }
        else {
            const selection = propose.parse({ operationId: input.operationId, shopRevision: input.shopRevision, authorityEpoch: input.authorityEpoch, grantRevision: input.grantRevision,
                pairId: (input as z.infer<typeof propose>).pairId, choice: (input as z.infer<typeof propose>).choice });
            const p = await this.activePair(ctx, shopId, selection.pairId, shopper, shop.authority_epoch);
            if (p.shop_revision !== shop.revision)
                throw stale();
            const entered = p.options as StoreQuoteOptions, selected = entered[selection.choice];
            if (!compareStoreQuotes(entered).comparable || selected.available !== true || !selected.eligibilityConfirmed)
                throw new ServiceError(409, 'unreviewed_coverage', 'Review package quantities, eligibility and availability.');
            if (action === 'proposals') {
                if (p.actor_id !== ctx.member.member_id || shopper)
                    throw unavailable();
                const inserted = await ctx.db.query('INSERT INTO ritc.store_quote_proposal(household_id,shop_id,proposal_id,pair_id,choice) VALUES($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING', [ctx.householdId, shopId, input.operationId, p.pair_id, selection.choice]);
                if (!inserted.rowCount)
                    throw conflict();
            }
            else {
                const { proposalId } = adopt.parse(input);
                if (p.actor_id !== ctx.member.member_id || proposalId !== null) {
                    const proposed = proposalId && (await ctx.db.query('SELECT 1 FROM ritc.store_quote_proposal WHERE household_id=$1 AND shop_id=$2 AND proposal_id=$3 AND pair_id=$4 AND choice=$5', [ctx.householdId, shopId, proposalId, p.pair_id, selection.choice])).rowCount;
                    if (!proposed)
                        throw unavailable();
                }
                const lines = (await this.repo.lines(ctx, shopId)).map(l => ({ ...l, unitPriceMinor: null }));
                const quote = { ...shop.quote, complete: false, fee: { kind: 'fixed', amountMinor: null }, discountsMinor: null, taxesMinor: null, depositsMinor: null,
                    observedAt: new Date(ctx.now.getTime() - 1000).toISOString(), expiresAt: ctx.now.toISOString() };
                await this.repo.execute(ctx, parseCommand({ v: 1, clientKey: input.operationId, replayWindow: (await this.repo.window(ctx)).id,
                    kind: 'shop.patch', shopId, base: { shopRevision: revision, authorityEpoch: shop.authority_epoch }, body: { lines, quote } }));
                revision += 1;
                await ctx.db.query('INSERT INTO ritc.store_quote_adoption(household_id,shop_id,revision,pair_id,choice,actor_id) VALUES($1,$2,$3,$4,$5,$6)', [ctx.householdId, shopId, revision, p.pair_id, selection.choice, ctx.member.member_id]);
                await ctx.db.query('UPDATE ritc.shop SET store_basis_revision=$3,store_review_required=true WHERE household_id=$1 AND shop_id=$2', [ctx.householdId, shopId, revision]);
            }
        }
        const receipt = { operationId: input.operationId, shopRevision: revision };
        await ctx.db.query('INSERT INTO ritc.store_quote_mutation(household_id,shop_id,actor_id,operation_id,fingerprint,receipt) VALUES($1,$2,$3,$4,$5,$6)', [...args, fingerprint, receipt]);
        return receipt;
    }
}
