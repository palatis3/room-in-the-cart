import type { Decision } from './contracts.js';
import { digest } from './database.js';
import { refresh, unavailable } from './errors.js';
import type { Context, HouseholdRepository, RequestRow, Shop } from './repository.js';
import { readTracking } from './shared-demand-tracking-repository.js';

type Target = Extract<Decision, {choice:'sameItem'}>['target'];
type Evidence = {item:string; quantity:string|null; sourceLabel:string; exclusions:string[]; reservationPurpose?:string; lineName?:string; packs?:number};
interface Proof {
  evidence:Evidence;
  digest:string;
  occurrence:string|null;
  mealRevision:number|null;
  purchaseOperation:string|null;
}

function requireLiveAuthor(repo:HouseholdRepository, request:RequestRow) {
  // request_origin checks the actual consent that authorized this child's request.
  if (!request.author_active || request.author_kind !== 'adult' &&
      (!repo.options.allowChildNetwork || request.live_notice !== repo.options.noticeVersion)) throw unavailable();
}
const normalized = (value:string) => value.normalize('NFC').trim().replace(/\s+/gu,' ').toLowerCase();

export async function proveSameItem(repo:HouseholdRepository, ctx:Context, shop:Shop, request:RequestRow, target:Target, mode:'review'|'replay'='review'):Promise<Proof> {
  repo.requireShopper(ctx, shop);
  requireLiveAuthor(repo,request);
  if (target.kind === 'meal') {
    if (mode === 'review' && shop.phase !== 'draft') throw refresh();
    const page = await readTracking(repo,ctx,shop);
    const fact = page.state?.catalog.find(row => row.id === target.factId);
    if (!fact || fact.revision !== target.factRevision || normalized(request.original_item) !== normalized(fact.originalText)) throw refresh();
    const occurrence = fact.source.kind === 'meal' ? fact.source.occurrenceId :
      fact.source.kind === 'reservation' ? fact.source.originOccurrenceId : null;
    if (!occurrence) throw unavailable();
    return {evidence:{item:fact.originalText,quantity:fact.originalQuantityText,sourceLabel:fact.sourceLabel,
      ...(fact.source.kind==='reservation'?{reservationPurpose:fact.source.purpose}:{}),
      exclusions:fact.sourceExclusions.map(row=>row.label)},digest:digest(fact),occurrence,mealRevision:fact.revision,purchaseOperation:null};
  }
  if (target.sourceRequestId === request.request_id || shop.confirmed_order_erased || shop.placed_revision !== target.placedRevision ||
      !['placed','closed'].includes(shop.phase)) throw unavailable();
  const source = await repo.request(ctx,target.sourceRequestId,shop.shop_id);
  if (source.status !== 'added' || source.revision !== target.sourceRequestRevision ||
      normalized(request.original_item) !== normalized(source.original_item)) throw refresh();
  requireLiveAuthor(repo,source);
  const {rows} = await ctx.db.query(`SELECT p.operation_id, entry->>'originalItem' AS name, (entry->>'packs')::int AS packs
    FROM ritc.placed_request_link l JOIN ritc.request_purchase_review p USING(household_id,request_id,shop_id,placed_revision)
    JOIN ritc.member confirmer ON (confirmer.household_id,confirmer.member_id)=(p.household_id,p.actor_id) AND confirmer.state='active'
    JOIN ritc.shop_snapshot s ON (s.household_id,s.shop_id,s.revision)=(l.household_id,l.shop_id,l.placed_revision)
    CROSS JOIN LATERAL jsonb_array_elements(s.snapshot->'lines') entry
    WHERE l.household_id=$1 AND l.shop_id=$2 AND l.request_id=$3 AND p.request_revision=$4 AND p.outcome='bought'
      AND l.line_id=$5 AND l.placed_revision=$6 AND lower(entry->>'lineId')=l.line_id::text`,
    [ctx.householdId,shop.shop_id,target.sourceRequestId,target.sourceRequestRevision,target.lineId,target.placedRevision]);
  const row = rows[0];
  if (!row || rows.length !== 1) throw refresh();
  const evidence = {item:source.original_item,quantity:source.own_quantity,sourceLabel:source.author_alias,
    exclusions:[],lineName:row.name as string,packs:row.packs as number};
  return {evidence,digest:digest({evidence,target,sourceAuthor:source.author_id,operationId:row.operation_id}),
    occurrence:null,mealRevision:null,purchaseOperation:row.operation_id};
}

export async function sameItemUndo(repo:HouseholdRepository,ctx:Context,shop:Shop,request:RequestRow,operationId:string) {
  repo.requireShopper(ctx,shop);
  requireLiveAuthor(repo,request);
  const {rows} = await ctx.db.query(`SELECT prior_status,request_revision FROM ritc.request_same_item
    WHERE household_id=$1 AND shop_id=$2 AND request_id=$3 AND operation_id=$4 AND undo_operation_id IS NULL AND NOT invalidated`,
    [ctx.householdId,shop.shop_id,request.request_id,operationId]);
  if (request.status !== 'handled' || !rows[0] || rows[0].request_revision+1 !== request.revision) throw refresh();
  return rows[0].prior_status as 'pending'|'clarified';
}

export async function rememberSameItem(ctx:Context,shop:Shop,request:RequestRow,previewId:string,proof:Proof) {
  await ctx.db.query(`INSERT INTO ritc.request_same_item(household_id,shop_id,preview_id,request_id,request_revision,prior_status,
    meal_occurrence,meal_revision,purchase_operation) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
    [ctx.householdId,shop.shop_id,previewId,request.request_id,request.revision,request.status,proof.occurrence,proof.mealRevision,proof.purchaseOperation]);
}

export async function applySameItem(repo:HouseholdRepository,ctx:Context,shop:Shop,request:RequestRow,
    previewId:string,decision:Extract<Decision,{choice:'sameItem'|'undoSameItem'}>,operationId:string) {
  const key = [ctx.householdId,shop.shop_id,request.request_id];
  let status:'pending'|'clarified'|'handled'='handled';
  if (decision.choice === 'undoSameItem') {
    status = await sameItemUndo(repo,ctx,shop,request,decision.operationId);
    await ctx.db.query('UPDATE ritc.request_same_item SET undo_operation_id=$5 WHERE household_id=$1 AND shop_id=$2 AND request_id=$3 AND operation_id=$4',
      [...key,decision.operationId,operationId]);
  } else {
    const changed=await ctx.db.query('UPDATE ritc.request_same_item SET operation_id=$5 WHERE household_id=$1 AND shop_id=$2 AND request_id=$3 AND preview_id=$4 AND operation_id IS NULL AND NOT invalidated',
      [...key,previewId,operationId]);
    if (changed.rowCount !== 1) throw refresh();
  }
  await ctx.db.query(`UPDATE ritc.request SET status=$4,route=CASE WHEN $5 AND $4<>'handled' THEN 'next' ELSE route END,revision=revision+1 WHERE household_id=$1 AND shop_id=$2 AND request_id=$3`, [...key,status,['placed','closed'].includes(shop.phase)]);
  return status;
}

export async function checkSameItemReplay(repo:HouseholdRepository,ctx:Context,shop:Shop,operationId:string,epoch:number) {
  const {rows}=await ctx.db.query(`SELECT r.request_id, r.request_revision, r.undo_operation_id, r.invalidated, p.decision
    FROM ritc.request_same_item r JOIN ritc.preview p USING(household_id,preview_id)
    WHERE r.household_id=$1 AND r.shop_id=$2 AND (r.operation_id=$3 OR r.undo_operation_id=$3)`,[ctx.householdId,shop.shop_id,operationId]);
  if (!rows.length) return;
  if (epoch!==shop.authority_epoch) throw refresh();
  const effect=rows[0],request=await repo.request(ctx,effect.request_id,shop.shop_id);
  if (effect.undo_operation_id===operationId) { requireLiveAuthor(repo,request); return; }
  if (effect.invalidated || effect.undo_operation_id || request.status !== 'handled' || request.revision !== effect.request_revision+1) throw refresh();
  await proveSameItem(repo,ctx,shop,request,effect.decision.target,'replay');
}
