import {z} from 'zod';
import type {BillingService} from './billing/service.js';
import type {Context} from './repository.js';
import {digest} from './database.js';
import {ServiceError, invalid, unavailable} from './errors.js';

const id = z.string().uuid().transform(value => value.toLowerCase());
// PostgreSQL text excludes NUL and unpaired surrogates. Preserve all other entered text verbatim.
const text = (max:number) => z.string().max(max).refine(value =>
  value.trim().length > 0 && !/[\u0000\uD800-\uDFFF]/u.test(value));
const label = text(120);
const note = text(500);
const versioned = {clientKey:id, baseVersion:z.number().int().positive().max(2147483647)};
const create = z.object({
  clientKey:id, kind:z.enum(['approval','exclusion','preference']),
  product:label.nullable(), dish:label.nullable(), occasion:label.nullable(),
  decision:note, outcome:note.nullable()
}).strict().refine(value => value.product !== null || value.dish !== null || value.occasion !== null);
const observe = z.object({...versioned, outcome:note}).strict();
const promote = z.object(versioned).strict();
const search = z.object({product:label.optional(),dish:label.optional(),occasion:label.optional(),shopId:id.optional(),cursor:id.optional()}).strict();
const changed = () => new ServiceError(409,'decision_changed','Read the current decision before recording this action.');
const reused = () => new ServiceError(409,'key_reused','Retry the original action or use a fresh key.');

interface DecisionRow {
  decision_id:string; shop_id:string; version:number; kind:'approval'|'exclusion'|'preference';
  product:string|null; dish:string|null; occasion:string|null; decision:string; outcome:string|null;
  recorded_at:Date; observed_at:Date|null; promoted_at:Date|null; observer_id:string|null; promoter_id:string|null;
}

function record(row:DecisionRow) {
  return {
    id:row.decision_id, shopId:row.shop_id, version:row.version, kind:row.kind,
    product:row.product, dish:row.dish, occasion:row.occasion, decision:row.decision, outcome:row.outcome,
    scope:row.promoted_at ? 'lasting' : 'one_shop', recordedAt:row.recorded_at.toISOString(),
    observedAt:row.observed_at?.toISOString() ?? null, promotedAt:row.promoted_at?.toISOString() ?? null
  };
}

export class DecisionHistory {
  constructor(private readonly billing?:BillingService) {}

  private async assignedShop(ctx:Context, requested?:string) {
    if (ctx.viewGrantId || ctx.member.kind !== 'adult') throw unavailable();
    const selected = ctx.selectedShopId?.toLowerCase();
    if (selected && requested && selected !== requested) throw unavailable();
    const shopId = requested ?? selected ?? null;
    const allowed = await ctx.db.query(
      'SELECT 1 FROM ritc.shop WHERE household_id=$1 AND shopper_id=$2 AND history_retired_at IS NULL AND ($3::uuid IS NULL OR shop_id=$3) LIMIT 1',
      [ctx.householdId,ctx.member.member_id,shopId]);
    if (!allowed.rowCount) throw unavailable();
    return shopId;
  }

  private async paid(ctx:Context) {
    if (!this.billing) throw new ServiceError(503,'billing_unavailable','Try again when membership can be verified.');
    await this.billing.requirePaidSeat(ctx);
  }

  private async row(ctx:Context, shopId:string, decisionId:string) {
    const {rows} = await ctx.db.query<DecisionRow>(
      'SELECT * FROM ritc.family_decision WHERE household_id=$1 AND shop_id=$2 AND decision_id=$3',
      [ctx.householdId,shopId,decisionId]);
    if (!rows[0]) throw unavailable();
    return rows[0];
  }

  async read(ctx:Context, shopId:string, decisionId:string) {
    await this.assignedShop(ctx,shopId);
    return record(await this.row(ctx,shopId,decisionId));
  }

  // HouseholdRepository serializes these writes, their receipts, and current authority in one transaction.
  private async mutation(ctx:Context, key:string, fingerprint:string, write:()=>Promise<DecisionRow>) {
    const actor = ctx.member.member_id;
    const {rows:[prior]} = await ctx.db.query(
      'SELECT fingerprint,response FROM ritc.decision_receipt WHERE household_id=$1 AND actor_id=$2 AND client_key=$3',
      [ctx.householdId,actor,key]);
    if (prior) {
      if (prior.fingerprint !== fingerprint) throw reused();
      if (!prior.response) throw changed();
      return prior.response;
    }
    const row = await write();
    const response = record(row);
    await ctx.db.query(
      'INSERT INTO ritc.decision_receipt(household_id,actor_id,client_key,decision_id,fingerprint,response,snapshot_observer,snapshot_promoter) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
      [ctx.householdId,actor,key,row.decision_id,fingerprint,response,row.observer_id,row.promoter_id]);
    return response;
  }

  async create(ctx:Context, shopId:string, payload:unknown) {
    await this.assignedShop(ctx,shopId);
    const input = create.parse(payload);
    return this.mutation(ctx,input.clientKey,digest({action:'create',shopId,input}),async () => {
      const {rows} = await ctx.db.query<DecisionRow>(
        `INSERT INTO ritc.family_decision(household_id,decision_id,shop_id,author_id,kind,product,dish,occasion,decision,outcome,recorded_at,observed_at,observer_id)
         VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) ON CONFLICT DO NOTHING RETURNING *`,
        [ctx.householdId,input.clientKey,shopId,ctx.member.member_id,input.kind,input.product,input.dish,input.occasion,input.decision,
          input.outcome,ctx.now,input.outcome ? ctx.now : null,input.outcome ? ctx.member.member_id : null]);
      if (!rows[0]) throw reused();
      return rows[0];
    });
  }

  async update(ctx:Context, shopId:string, decisionId:string, action:'outcome'|'promote', payload:unknown) {
    await this.assignedShop(ctx,shopId);
    const current = await this.row(ctx,shopId,decisionId);
    if (action === 'promote') await this.paid(ctx);
    const input = action === 'outcome'
      ? observe.parse(payload)
      : {...promote.parse(payload),outcome:null};
    return this.mutation(ctx,input.clientKey,digest({action,shopId,decisionId,input}),async () => {
      if (current.version !== input.baseVersion) throw changed();
      const values = [ctx.householdId,decisionId,ctx.now,ctx.member.member_id];
      let assignment:string;
      if (input.outcome !== null) {
        if (current.outcome === input.outcome) throw changed();
        assignment = 'outcome=$5, observed_at=$3, observer_id=$4';
        values.push(input.outcome);
      } else {
        if (current.kind !== 'preference' || current.promoted_at) throw changed();
        assignment = 'promoted_at=$3, promoter_id=$4';
      }
      const {rows} = await ctx.db.query<DecisionRow>(
        `UPDATE ritc.family_decision SET ${assignment},version=version+1 WHERE household_id=$1 AND decision_id=$2 RETURNING *`,values);
      return rows[0]!;
    });
  }

  async list(ctx:Context, params:URLSearchParams) {
    if (params.size !== new Set(params.keys()).size) throw invalid();
    const filters = search.parse(Object.fromEntries(params));
    const shopId = await this.assignedShop(ctx,filters.shopId);
    await this.paid(ctx);
    const from = `FROM ritc.family_decision d JOIN ritc.shop s USING(household_id,shop_id)
      WHERE d.household_id=$1 AND s.shopper_id=$2 AND s.history_retired_at IS NULL AND ($3::uuid IS NULL OR d.shop_id=$3)
      AND ($4::text IS NULL OR strpos(lower(d.product),lower($4))>0)
      AND ($5::text IS NULL OR strpos(lower(d.dish),lower($5))>0)
      AND ($6::text IS NULL OR strpos(lower(d.occasion),lower($6))>0)`;
    const values = [ctx.householdId,ctx.member.member_id,shopId,filters.product ?? null,filters.dish ?? null,filters.occasion ?? null];
    if (filters.cursor) {
      // Keep PostgreSQL timestamp precision and require the cursor to belong to this authorized search.
      const {rows:[cursor]} = await ctx.db.query('SELECT d.recorded_at::text AS time '+from+' AND d.decision_id=$7',[...values,filters.cursor]);
      if (!cursor) throw unavailable();
      values.push(cursor.time,filters.cursor);
    }
    const after = filters.cursor ? ' AND (d.recorded_at,d.decision_id)<($7::timestamptz,$8::uuid)' : '';
    const {rows} = await ctx.db.query<DecisionRow>('SELECT d.* '+from+after+' ORDER BY d.recorded_at DESC,d.decision_id DESC LIMIT 51',values);
    return {decisions:rows.slice(0,50).map(record),nextCursor:rows.length>50 ? rows[49]!.decision_id : null};
  }
}
