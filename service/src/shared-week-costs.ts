import type { BillingService } from './billing/service.js';
import { unavailable } from './errors.js';
import { requireSupportedCurrency } from './grocery-currency.js';
import type { MealMoves } from './meal-moves.js';
import type { Context } from './repository.js';
import type { StoreQuoteOptions } from './shared-store-quotes.js';

interface SnapshotLine {
  lineId: string;
  originalItem: string;
  packs: number;
  unitPriceMinor: number | null;
}

interface SnapshotRow {
  revision: number;
  original: boolean;
  lines: SnapshotLine[];
  currency: 'USD' | 'MXN';
  observed_at: string;
  expires_at: string;
  captured_at: Date;
  commitments: { id: string; label: string; packs: number }[] | null;
  selected: StoreQuoteOptions['first'] | null;
  pair_id: string | null;
}

function safeMinorUnits(amount: bigint): number | null {
  if (amount < BigInt(Number.MIN_SAFE_INTEGER) || amount > BigInt(Number.MAX_SAFE_INTEGER)) {
    return null;
  }
  return Number(amount);
}

/** Display an adopted quote only for the exact basket and quantities the author reviewed. */
function matchingAdoptedQuote(row: SnapshotRow) {
  const option = row.selected;
  if (!option || !row.pair_id || option.currency !== row.currency ||
      !option.quantitiesMatched || !option.singleStore || !(Date.parse(option.observedAt) <= row.captured_at.getTime())) {
    return null;
  }
  const commitments = new Map(row.commitments?.map(commitment => [commitment.id, commitment]));
  const coversBasket = commitments.size === row.lines.length && row.lines.every(line => {
    const commitment = commitments.get(line.lineId);
    return commitment?.label === line.originalItem && commitment.packs === line.packs;
  });
  if (!coversBasket) return null;

  return {
    id: row.pair_id,
    store: option.store,
    branch: option.branch,
    observedAt: option.observedAt,
    itemsMinor: option.itemsMinor,
    checkoutMinor: option.allChargesIncluded ? option.checkoutMinor : null,
  };
}

export function sharedWeekCostVersion(row: SnapshotRow, shopper: boolean) {
  const adoptedQuote = matchingAdoptedQuote(row);
  if (!shopper && !adoptedQuote) return null;

  const capturedAt = row.captured_at.getTime();
  const pricesWereCurrent = Date.parse(row.observed_at) <= capturedAt && capturedAt < Date.parse(row.expires_at);
  let subtotal = 0n;
  let pricedLines = 0;
  const lines = [];
  for (const line of row.lines) {
    const unitPriceMinor = shopper && pricesWereCurrent ? line.unitPriceMinor : null;
    if (unitPriceMinor !== null) {
      subtotal += BigInt(line.packs) * BigInt(unitPriceMinor);
      pricedLines += 1;
    }
    lines.push({ id: line.lineId, name: line.originalItem, packs: line.packs, unitPriceMinor });
  }

  return {
    revision: row.revision,
    original: row.original,
    capturedAt: row.captured_at.toISOString(),
    currency: row.currency,
    lines,
    knownItemSubtotalMinor: pricedLines ? safeMinorUnits(subtotal) : null,
    pricedLines,
    adoptedQuote,
  };
}

export async function readSharedWeekCosts(
  moves: MealMoves, billing: BillingService | undefined, ctx: Context, shopId: string, planId: string,
) {
  const { shop, shopper, grantRevision } = await moves.context(ctx, shopId, true);
  if (!billing || (ctx.selectedShopId && ctx.selectedShopId !== shopId)) throw unavailable();
  // MealMoves already verifies the planner's seat.
  if (shopper) await billing.requirePaidSeat(ctx);
  requireSupportedCurrency(ctx, shop.currency);

  // A meal editing grant alone never conveys budget access.
  const seriesResult = await ctx.db.query(
    `SELECT w.basket_revision,w.store_revision,w.receipts,w.created_at
    FROM ritc.shared_repeat_week w JOIN ritc.shop s USING(household_id,shop_id)
    WHERE w.household_id=$1 AND w.shop_id=$2 AND w.plan_id=$3 AND w.authority_epoch=s.authority_epoch
      AND w.grant_revision=$4 AND s.history_retired_at IS NULL AND (s.shopper_id=$5 OR EXISTS(
        SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=w.household_id AND g.shop_id=w.shop_id
        AND g.member_id=$5 AND g.enabled AND g.authority_epoch=w.authority_epoch))`,
    [ctx.householdId, shopId, planId, grantRevision, ctx.member.member_id],
  );
  const series = seriesResult.rows[0];
  if (!series) throw unavailable();
  if (series.basket_revision === null) {
    return { original: null, revisions: [], reportedNetMinor: null, currency: shop.currency };
  }

  const snapshots = await ctx.db.query<SnapshotRow>(
    `SELECT s.revision,s.revision=$3 AS original,
    CASE WHEN s.revision=$3 THEN $5::timestamptz ELSE s.created_at END AS captured_at,
    s.snapshot->'lines' AS lines,coalesce(s.snapshot->'quote'->>'currency','USD') AS currency,
    s.snapshot->'quote'->>'observedAt' AS observed_at,s.snapshot->'quote'->>'expiresAt' AS expires_at,
    proof.commitments,proof.selected,proof.pair_id
    FROM ritc.shop_snapshot s
    LEFT JOIN LATERAL (SELECT p.pair_id,p.commitments,p.options->a.choice AS selected
      FROM ritc.store_quote_adoption a JOIN ritc.store_quote_pair p USING(household_id,shop_id,pair_id)
      JOIN ritc.member author ON author.household_id=p.household_id AND author.member_id=p.actor_id AND author.state='active'
      JOIN ritc.member adopter ON adopter.household_id=a.household_id AND adopter.member_id=a.actor_id AND adopter.state='active'
      WHERE a.household_id=s.household_id AND a.shop_id=s.shop_id AND p.authority_epoch=$7
        AND a.revision=CASE WHEN s.revision=$3 THEN $4::integer ELSE (s.snapshot->'storeBasis'->>'revision')::integer END
        AND ($9::boolean OR p.actor_id=$8)
        AND EXISTS(SELECT 1 FROM ritc.store_quote_proposal q WHERE q.household_id=p.household_id AND q.shop_id=p.shop_id
          AND q.pair_id=p.pair_id AND q.choice=a.choice)
        AND EXISTS(SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=p.household_id AND g.shop_id=p.shop_id
          AND g.member_id=p.actor_id AND g.enabled AND g.authority_epoch=p.authority_epoch AND g.revision=p.grant_revision)
    ) proof ON true
    WHERE s.household_id=$1 AND s.shop_id=$2 AND (s.revision=$3 OR s.operation_id=ANY($6::uuid[]))
      AND s.digest<>repeat('0',64) AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s.snapshot->'lines') x
        WHERE x->>'originalItem'='Removed item') ORDER BY s.revision`,
    [
      ctx.householdId, shopId, series.basket_revision, series.store_revision, series.created_at,
      Object.values(series.receipts), shop.authority_epoch, ctx.member.member_id, shopper,
    ],
  );
  const versions = snapshots.rows.map(row => sharedWeekCostVersion(row, shopper)).filter(version => version !== null);

  // Included credits already affect the charge. Holds and pending credits are future events.
  const postings = await ctx.db.query<{ net: string | null }>(
    `SELECT sum(CASE WHEN kind='postedCredit' THEN -amount_minor ELSE amount_minor END) AS net
     FROM ritc.financial_entry
     WHERE household_id=$1 AND shop_id=$2 AND currency=$3
       AND kind IN ('postedCharge','postedTopUp','postedCredit')`,
    [ctx.householdId, shopId, shop.currency],
  );
  const postedNet = postings.rows[0]?.net;
  return {
    original: versions.find(version => version.original) ?? null,
    revisions: versions.filter(version => !version.original),
    reportedNetMinor: postedNet == null ? null : safeMinorUnits(BigInt(postedNet)),
    currency: shop.currency,
  };
}
