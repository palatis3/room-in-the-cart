import { randomUUID } from 'node:crypto';
import { bodySchemas, type Envelope } from './contracts.js';
import { invalid, refresh, ServiceError, unavailable } from './errors.js';
import type { Context, Shop } from './repository.js';

// The caller has already checked the destination's selected-shop authority.
// Both the list and the write resolve source authority independently.
const eligible = `FROM ritc.request_origin r
 JOIN ritc.shop s ON (s.household_id,s.shop_id)=(r.household_id,r.shop_id)
 JOIN ritc.shop dest ON dest.household_id=r.household_id AND dest.shop_id=$2
 WHERE r.household_id=$1 AND s.shopper_id=$3 AND s.created_at<dest.created_at
 AND s.phase IN ('placed','closed') AND s.placed_revision IS NOT NULL
 AND r.route='next' AND r.status IN ('pending','clarified','deferred') AND NOT r.carried_forward
 AND r.author_active AND (r.author_kind='adult' OR r.live_notice=$4)`;

export async function deferredRequests(ctx:Context,dest:Shop,notice:string|null,after:string|null) {
  const params=[ctx.householdId,dest.shop_id,ctx.member.member_id,notice,after];
  if(after && !(await ctx.db.query(`SELECT 1 ${eligible} AND r.request_id=$5`,params)).rowCount)throw unavailable();
  const rows=(await ctx.db.query(`SELECT s.shop_id,s.authority_epoch,r.request_id,r.revision,r.original_item,r.own_quantity,
    r.author_alias,r.authored_at,r.received_at ${eligible}
    AND ($5::uuid IS NULL OR r.request_id>$5) ORDER BY r.request_id LIMIT 51`,params)).rows;
  return {shopId:dest.shop_id,shopRevision:dest.revision,authorityEpoch:dest.authority_epoch,
    requests:rows.slice(0,50).map(r=>({sourceShopId:r.shop_id,sourceAuthorityEpoch:r.authority_epoch,
      requestId:r.request_id,requestRevision:r.revision,originalItem:r.original_item,ownQuantity:r.own_quantity,
      authorAlias:r.author_alias,authoredAt:r.authored_at.toISOString(),receivedAt:r.received_at.toISOString()})),
    nextCursor:rows.length>50?rows[49].request_id:null};
}

export async function carryRequest(ctx:Context,dest:Shop,notice:string|null,c:Envelope,operationId:string) {
  const b=bodySchemas['request.carry'].parse(c.body);
  if(c.base.requestRevision===undefined)throw invalid();
  const r=(await ctx.db.query(`SELECT r.request_id,r.shop_id,r.author_id,r.author_consent_id,r.revision,r.original_item,
    r.own_quantity,r.authored_at::text,s.authority_epoch ${eligible} AND s.shop_id=$5 AND r.request_id=$6`,
    [ctx.householdId,dest.shop_id,ctx.member.member_id,notice,b.sourceShopId,b.requestId])).rows[0];
  if(!r)throw unavailable();
  if(r.authority_epoch!==b.sourceAuthorityEpoch)throw new ServiceError(409,'authority_changed','Review the current shopper assignment.');
  if(r.revision!==c.base.requestRevision)throw new ServiceError(409,'stale_base','Review the changed request.');
  await ctx.db.query(`INSERT INTO ritc.request(household_id,request_id,shop_id,author_id,author_consent_id,client_request_id,
    original_item,own_quantity,authored_at,route) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'current')`,
    [ctx.householdId,operationId,dest.shop_id,r.author_id,r.author_consent_id,randomUUID(),r.original_item,r.own_quantity,r.authored_at]);
  await ctx.db.query(`INSERT INTO ritc.request_carry(household_id,source_request_id,target_request_id,source_authority_epoch,target_authority_epoch)
    VALUES($1,$2,$3,$4,$5)`,[ctx.householdId,r.request_id,operationId,r.authority_epoch,dest.authority_epoch]);
  return {requestId:operationId,requestRevision:1,sourceRequestId:r.request_id};
}

export async function reauthorizeCarry(ctx:Context,dest:Shop,notice:string|null,operationId:string) {
  const row=await ctx.db.query(`SELECT 1 FROM ritc.request_carry c
    JOIN ritc.request_origin r ON (r.household_id,r.request_id)=(c.household_id,c.source_request_id)
    JOIN ritc.shop s ON (s.household_id,s.shop_id)=(r.household_id,r.shop_id)
    WHERE c.household_id=$1 AND c.target_request_id=$2 AND s.shopper_id=$3
    AND c.source_authority_epoch=s.authority_epoch AND c.target_authority_epoch=$4
    AND r.author_active AND (r.author_kind='adult' OR r.live_notice=$5)`,
    [ctx.householdId,operationId,ctx.member.member_id,dest.authority_epoch,notice]);
  if(!row.rowCount)throw refresh();
}
