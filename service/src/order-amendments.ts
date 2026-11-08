import type { Context, Shop } from './repository.js';
import type { BasketLine, ConfirmedOrderPage, ConfirmedOrderAmendment } from '../../shared/contracts/service-v1.js';
import { amendmentResponseBody } from './contracts.js';
import { digest } from './database.js';
import { ServiceError, unavailable } from './errors.js';

const removed = () => new ServiceError(409,'order_evidence_removed','Order evidence was removed. Keep the original placement and physical receipts separate.');
function placed(shop:Shop) {
  if(!shop.placed_revision || !['placed','closed'].includes(shop.phase)) throw new ServiceError(409,'placed_order_required','Open the placed order before recording retailer confirmation.');
  if(shop.confirmed_order_erased) throw removed();
}
export async function readConfirmedOrder(ctx:Context,shop:Shop):Promise<ConfirmedOrderPage> {
  placed(shop);
  const original=(await ctx.db.query(`SELECT snapshot,created_at,digest FROM ritc.shop_snapshot
    WHERE household_id=$1 AND shop_id=$2 AND revision=$3`,[ctx.householdId,shop.shop_id,shop.placed_revision])).rows[0];
  if(!original)throw unavailable();
  // An erased snapshot must never become a fresh basis through copied amendment facts.
  if(original.digest==='0'.repeat(64))throw removed();
  const rows=(await ctx.db.query(`SELECT a.amendment_id,a.predecessor_id,a.retailer_reference,a.confirmed_at,a.recorded_at,a.actor_id,a.lines,m.alias AS actor_label
    FROM ritc.order_amendment a JOIN ritc.member m ON (m.household_id,m.member_id)=(a.household_id,a.actor_id)
    WHERE a.household_id=$1 AND a.shop_id=$2 ORDER BY a.shop_revision`,[ctx.householdId,shop.shop_id])).rows;
  const amendments:ConfirmedOrderAmendment[]=rows.map(r=>({amendmentId:r.amendment_id,predecessorId:r.predecessor_id,
    retailerReference:r.retailer_reference,confirmedAt:r.confirmed_at.toISOString(),recordedAt:r.recorded_at.toISOString(),actorId:r.actor_id,actorLabel:r.actor_label,lines:r.lines}));
  return {shopId:shop.shop_id,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,placedRevision:shop.placed_revision!,asOf:ctx.now.toISOString(),
    original:{lines:original.snapshot.lines,quote:original.snapshot.quote,snapshotCreatedAt:original.created_at.toISOString()},
    current:{lines:amendments.at(-1)?.lines??original.snapshot.lines,amendmentId:amendments.at(-1)?.amendmentId??null},amendments};
}

export async function recordOrderAmendment(ctx:Context,shop:Shop,input:unknown,operationId:string) {
  const body=amendmentResponseBody.parse(input),page=await readConfirmedOrder(ctx,shop);
  if(body.placedRevision!==page.placedRevision || body.predecessorId!==page.current.amendmentId)
    throw new ServiceError(409,'stale_order','Review the current confirmed order before recording another amendment.');
  const time=Date.parse(body.confirmedAt),previous=page.amendments.at(-1);
  if(time>ctx.now.getTime() || time<Date.parse(page.original.snapshotCreatedAt) || (previous && time<Date.parse(previous.confirmedAt)))
    throw new ServiceError(422,'invalid_confirmation_time','Enter when the retailer confirmed this change after the order snapshot.');
  const current=new Map(page.current.lines.map(line=>[line.lineId.toLowerCase(),line]));
  const history=new Set([...page.original.lines,...page.amendments.flatMap(a=>a.lines)].map(line=>line.lineId.toLowerCase()));
  const lines=body.lines.map(line=>({...line,lineId:line.lineId.toLowerCase()}));
  for(const line of lines) {
    const prior=current.get(line.lineId);
    if((prior && prior.originalItem!==line.originalItem) || (!prior && history.has(line.lineId)))
      throw new ServiceError(409,'order_line_identity','Use a new line identity for a replacement; retain earlier physical receipts.');
  }
  // Reordering is presentation, not independently confirmed order evidence.
  const canonical=(values:BasketLine[])=>[...values].sort((a,b)=>a.lineId.localeCompare(b.lineId));
  if(digest(canonical(lines))===digest(canonical(page.current.lines)))throw new ServiceError(409,'order_unchanged','Record a changed line confirmed by the retailer.');
  await ctx.db.query(`INSERT INTO ritc.order_amendment(household_id,shop_id,amendment_id,placed_revision,predecessor_id,
    shop_revision,authority_epoch,retailer_reference,confirmed_at,recorded_at,actor_id,operation_id,lines)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$3,$12)`,
    [ctx.householdId,shop.shop_id,operationId,body.placedRevision,body.predecessorId,shop.revision+1,shop.authority_epoch,
      body.retailerReference,body.confirmedAt,ctx.now,ctx.member.member_id,JSON.stringify(lines)]);
  await ctx.db.query('UPDATE ritc.shop SET revision=revision+1 WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id]);
  return {amendmentId:operationId,placedRevision:body.placedRevision};
}

/** Historical identity is deliberately independent of currently ordered quantity. */
export async function confirmedDeliveryLines(ctx:Context,shop:Shop) {
  const originals=(await ctx.db.query(`SELECT lower(line->>'lineId') AS "lineId",line->>'originalItem' AS name,line->'packs' AS packs
    FROM ritc.shop_snapshot ss CROSS JOIN LATERAL jsonb_array_elements(ss.snapshot->'lines') WITH ORDINALITY AS item(line,position)
    WHERE ss.household_id=$1 AND ss.shop_id=$2 AND ss.revision=$3
      AND NOT (ss.digest=repeat('0',64) AND line->>'originalItem'='Removed item') ORDER BY position`,
    [ctx.householdId,shop.shop_id,shop.placed_revision])).rows;
  const history=(await ctx.db.query<{lines:BasketLine[]}>(`SELECT lines FROM ritc.order_amendment WHERE household_id=$1 AND shop_id=$2 ORDER BY shop_revision`,
    [ctx.householdId,shop.shop_id])).rows;
  const values=new Map<string,{lineId:string;name:string;packs?:number;currentOrderedPacks?:number}>();
  for(const line of originals) values.set(line.lineId,{lineId:line.lineId,name:line.name,
    ...(Number.isInteger(line.packs)&&line.packs>=1&&line.packs<=10000?{packs:line.packs}:{})});
  for(const {lines} of history) for(const line of lines) if(!values.has(line.lineId))values.set(line.lineId,{lineId:line.lineId,name:line.originalItem,packs:line.packs});
  if(history.length) {
    const active=new Map(history.at(-1)!.lines.map(l=>[l.lineId,l.packs]));
    for(const line of values.values())line.currentOrderedPacks=active.get(line.lineId)??0;
  }
  return [...values.values()];
}
