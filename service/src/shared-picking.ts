import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import {digest} from './database.js';
import {invalid, unavailable} from './errors.js';
import type {Context, HouseholdRepository, Shop} from './repository.js';
import {checkPublishingMember,reviewSharedWording} from './shared-content-filter.js';
import {adultTrip,reusedTrip,staleTrip,tripRevision,tripUUID} from './trip-substitutions.js';

const permission=z.object({clientKey:tripUUID,expectedPermissionId:tripUUID.nullable(),authorityEpoch:tripRevision,
  shopRevision:tripRevision,recipientId:tripUUID.nullable(),lineIds:z.array(tripUUID).max(200),
  expiresAt:z.iso.datetime({offset:true}).nullable()}).strict().refine(x=>
  (x.recipientId!==null)===(x.expiresAt!==null)&&(x.recipientId!==null)===(x.lineIds.length>0)&&new Set(x.lineIds).size===x.lineIds.length);
const opShape={operationId:tripUUID,permissionId:tripUUID,actorId:tripUUID,deviceId:tripUUID,rowId:tripUUID,expectedRevision:tripRevision};
const operation=z.discriminatedUnion('action',[
  z.object({...opShape,action:z.literal('claim')}).strict(),
  z.object({...opShape,action:z.literal('pick'),packs:z.int().min(1).max(10000)}).strict(),
  z.object({...opShape,action:z.literal('undo'),undoOperationId:tripUUID}).strict(),
]);
type Grant={permission_id:string;recipient_id:string;expires_at:Date;line_ids:string[]};

async function currentGrant(ctx:Context,shop:Shop):Promise<Grant|undefined> {
  return (await ctx.db.query<Grant>(`SELECT p.permission_id,p.recipient_id,p.expires_at,p.line_ids
    FROM ritc.trip_picking_permission p JOIN ritc.member m ON (m.household_id,m.member_id)=(p.household_id,p.recipient_id)
    JOIN ritc.member s ON (s.household_id,s.member_id)=(p.household_id,p.shopper_id)
    WHERE p.household_id=$1 AND p.shop_id=$2 AND p.shopper_id=$3 AND p.authority_epoch=$4 AND p.expires_at>$5 AND $6 IN (p.shopper_id,p.recipient_id)
    AND m.state='active' AND m.kind='adult' AND m.can_contribute AND s.state='active' AND s.kind='adult'
    AND ritc.shared_content_visible(p.household_id,m.member_id,s.member_id,'trip',p.permission_id,1,1)
    AND ritc.shared_content_visible(p.household_id,s.member_id,m.member_id,'trip',p.permission_id,1,1)`,
    [ctx.householdId,shop.shop_id,shop.shopper_id,shop.authority_epoch,ctx.now,ctx.member.member_id])).rows[0];
}
async function members(ctx:Context,shop:Shop) {
  return (await ctx.db.query<{id:string;label:string}>(`SELECT member_id AS id,alias AS label FROM ritc.member WHERE household_id=$1
    AND state='active' AND kind='adult' AND can_contribute AND member_id<>$2
    AND ritc.shared_content_visible(household_id,$2,member_id,'trip',$3,1,1)
    AND ritc.shared_content_visible(household_id,member_id,$2,'trip',$3,1,1)
    ORDER BY alias,member_id`,[ctx.householdId,shop.shopper_id,shop.shop_id])).rows;
}
async function availableRows(ctx:Context,shop:Shop) {
  // An accepted request can contain another person's wording. It stays within its original audience.
  return (await ctx.db.query<{id:string;label:string;packs:number}>(`SELECT b.line_id AS id,b.original_item AS label,b.packs
    FROM ritc.basket_line b LEFT JOIN ritc.trip_picking_row r USING(household_id,shop_id,line_id)
    WHERE b.household_id=$1 AND b.shop_id=$2 AND b.packs>=coalesce(r.picked,0)
    AND NOT EXISTS(SELECT FROM ritc.request_link l WHERE (l.household_id,l.shop_id,l.line_id)=(b.household_id,b.shop_id,b.line_id))
    ORDER BY b.line_id`,[ctx.householdId,shop.shop_id])).rows;
}

interface Row {
  id:string;label:string;packs:number;picked:number;revision:number;safetyId:string;
  claimedBy:string|null;claimedByLabel:string|null;lastActorLabel:string|null;undoOperationId:string|null;
}
async function rows(ctx:Context,shop:Shop,g:Grant):Promise<Row[]> {
  return (await ctx.db.query<Row>(`SELECT b.line_id AS id,b.original_item AS label,b.packs,r.picked,r.revision,r.safety_id AS "safetyId",
      c.member_id AS "claimedBy",c.alias AS "claimedByLabel",a.alias AS "lastActorLabel",
      CASE WHEN r.last_permission=$4 AND r.last_actor=$6 THEN r.last_operation END AS "undoOperationId"
    FROM ritc.trip_picking_row r JOIN ritc.basket_line b USING(household_id,shop_id,line_id)
    LEFT JOIN ritc.member c ON (c.household_id,c.member_id)=(r.household_id,r.claimed_by) AND r.last_permission=$4
    LEFT JOIN ritc.member a ON (a.household_id,a.member_id)=(r.household_id,r.last_actor) AND r.last_permission=$4
    WHERE r.household_id=$1 AND r.shop_id=$2 AND r.line_id=ANY($3::uuid[]) AND r.published_permission=$4
    AND ritc.shared_content_visible(r.household_id,$7,$5,'pickingRow',r.safety_id,1,1)
    AND NOT EXISTS(SELECT FROM ritc.request_link l WHERE (l.household_id,l.shop_id,l.line_id)=(r.household_id,r.shop_id,r.line_id))
    ORDER BY r.line_id`,[ctx.householdId,shop.shop_id,g.line_ids,g.permission_id,shop.shopper_id,ctx.member.member_id,g.recipient_id])).rows;
}
async function snapshot(ctx:Context,shop:Shop,g:Grant|undefined) {
  const managed=ctx.member.member_id===shop.shopper_id;
  if(!managed&&g?.recipient_id!==ctx.member.member_id)throw unavailable();
  return {managed,authorityEpoch:shop.authority_epoch,shopRevision:shop.revision,permissionId:g?.permission_id??null,
    recipientId:g?.recipient_id??null,expiresAt:g?.expires_at.toISOString()??null,
    members:managed?await members(ctx,shop):[],availableRows:managed?await availableRows(ctx,shop):[],rows:g?await rows(ctx,shop,g):[]};
}

async function pastOperation(ctx:Context,shop:Shop,key:string,fingerprint:string) {
  const saved=(await ctx.db.query(`SELECT * FROM ritc.trip_picking_operation
    WHERE household_id=$1 AND actor_id=$2 AND operation_id=$3`,[ctx.householdId,ctx.member.member_id,key])).rows[0];
  if(saved&&(saved.device_id!==ctx.deviceId||saved.shop_id!==shop.shop_id||saved.fingerprint!==fingerprint))throw reusedTrip();
  return saved;
}
async function saveOperation(ctx:Context,shop:Shop,key:string,g:string|null,row:string|null,fingerprint:string,
  receipt:object,priorPicked:number|null=null,priorClaim:string|null=null) {
  await ctx.db.query(`INSERT INTO ritc.trip_picking_operation(household_id,actor_id,device_id,operation_id,shop_id,permission_id,row_id,fingerprint,receipt,prior_picked,prior_claim)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,[ctx.householdId,ctx.member.member_id,ctx.deviceId,key,shop.shop_id,g,row,fingerprint,receipt,priorPicked,priorClaim]);
}

async function manage(ctx:Context,shop:Shop,g:Grant|undefined,body:unknown) {
  const input=permission.parse(body),fingerprint=digest({input,scope:'permission'}),activeId=g?.permission_id??null;
  if(input.authorityEpoch!==shop.authority_epoch)throw staleTrip();
  const prior=await pastOperation(ctx,shop,input.clientKey,fingerprint);
  if(prior){if(prior.permission_id!==activeId)throw staleTrip();return snapshot(ctx,shop,g);}
  if(input.expectedPermissionId!==activeId||input.shopRevision!==shop.revision)throw staleTrip();
  let grantId:string|null=null;
  if(input.recipientId===null){
    if(!g)throw staleTrip();
    await ctx.db.query('DELETE FROM ritc.trip_picking_permission WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id]);
  }else{
    const until=new Date(input.expiresAt!);
    if(until<=ctx.now||until.getTime()>ctx.now.getTime()+86400000)throw invalid();
    if(!(await members(ctx,shop)).some(m=>m.id===input.recipientId))throw unavailable();
    const selected=(await availableRows(ctx,shop)).filter(r=>input.lineIds.includes(r.id));
    if(selected.length!==input.lineIds.length)throw unavailable();
    await checkPublishingMember(ctx);
    for(const r of selected)reviewSharedWording(r.label);
    grantId=randomUUID();
    await ctx.db.query(`INSERT INTO ritc.trip_picking_permission(household_id,shop_id,permission_id,shopper_id,recipient_id,authority_epoch,expires_at,line_ids)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(household_id,shop_id) DO UPDATE SET permission_id=excluded.permission_id,
      recipient_id=excluded.recipient_id,expires_at=excluded.expires_at,line_ids=excluded.line_ids`,
      [ctx.householdId,shop.shop_id,grantId,shop.shopper_id,input.recipientId,shop.authority_epoch,until,input.lineIds]);
    await ctx.db.query(`INSERT INTO ritc.trip_picking_row(household_id,shop_id,line_id,published_permission)
      SELECT $1,$2,unnest($3::uuid[]),$4 ON CONFLICT(household_id,shop_id,line_id)
      DO UPDATE SET published_permission=excluded.published_permission`,[ctx.householdId,shop.shop_id,input.lineIds,grantId]);
  }
  await saveOperation(ctx,shop,input.clientKey,grantId,null,fingerprint,{permissionId:grantId});
  return snapshot(ctx,shop,await currentGrant(ctx,shop));
}

// HouseholdRepository.authorized serializes commands at the household row within this transaction.
async function apply(ctx:Context,shop:Shop,g:Grant,body:unknown) {
  const input=operation.parse(body);
  if(input.actorId!==ctx.member.member_id||input.deviceId!==ctx.deviceId||input.permissionId!==g.permission_id)throw unavailable();
  const row=(await rows(ctx,shop,g)).find(r=>r.id===input.rowId);
  if(!row)throw unavailable();
  const fingerprint=digest({input,scope:'row'}),past=await pastOperation(ctx,shop,input.operationId,fingerprint);
  // Also bind a receipt to the label's original publication in case the basket UUID was repurposed.
  if(past){if(past.receipt.safetyId!==row.safetyId)throw staleTrip();return past.receipt;}
  if(row.revision!==input.expectedRevision)throw staleTrip();
  let picked=row.picked,claim=row.claimedBy;
  if(input.action==='undo'){
    if(row.undoOperationId!==input.undoOperationId)throw staleTrip();
    const prior=(await ctx.db.query(`SELECT prior_picked,prior_claim FROM ritc.trip_picking_operation
      WHERE household_id=$1 AND actor_id=$2 AND operation_id=$3 AND row_id=$4 AND permission_id=$5`,
      [ctx.householdId,input.actorId,input.undoOperationId,row.id,g.permission_id])).rows[0];
    if(!prior||prior.prior_picked===null)throw staleTrip();
    picked=prior.prior_picked;claim=prior.prior_claim;
  }else{
    if(row.picked>=row.packs||(claim!==null&&claim!==input.actorId))throw staleTrip();
    if(input.action==='claim'){
      if(claim!==null)throw staleTrip();
      claim=input.actorId;
    }else{
      if(input.packs>row.packs-row.picked)throw staleTrip();
      picked+=input.packs;
      if(picked===row.packs)claim=null;
    }
  }
  const receipt={operationId:input.operationId,rowId:row.id,revision:row.revision+1,picked,safetyId:row.safetyId};
  const changed=await ctx.db.query(`UPDATE ritc.trip_picking_row SET revision=revision+1,picked=$4,claimed_by=$5,last_actor=$6,last_operation=$7,last_permission=$8
    WHERE household_id=$1 AND shop_id=$2 AND line_id=$3 AND revision=$9 AND published_permission=$8`,
    [ctx.householdId,shop.shop_id,row.id,picked,claim,input.actorId,input.action==='undo'?null:input.operationId,g.permission_id,input.expectedRevision]);
  if(changed.rowCount!==1)throw staleTrip();
  await saveOperation(ctx,shop,input.operationId,g.permission_id,row.id,fingerprint,receipt,row.picked,row.claimedBy);
  return receipt;
}

export async function sharedPickingRoute(repo:HouseholdRepository,ctx:Context,shop:Shop,tail:string,method:string,body:unknown) {
  if(!repo.options.sharedPicking)throw unavailable();
  await adultTrip(repo,ctx,shop);
  const g=await currentGrant(ctx,shop);
  if(method==='GET'&&tail==='/shared-picking')return snapshot(ctx,shop,g);
  if(method==='POST'&&tail==='/shared-picking/permission'){repo.requireShopper(ctx,shop);return manage(ctx,shop,g,body);}
  if(method==='POST'&&tail==='/shared-picking/operations'&&g)return apply(ctx,shop,g,body);
  throw unavailable();
}
export async function pickingWording(repo:HouseholdRepository,ctx:Context,id:string) {
  if(!repo.options.sharedPicking)throw unavailable();
  const record=(await ctx.db.query('SELECT shop_id FROM ritc.trip_picking_row WHERE household_id=$1 AND safety_id=$2',[ctx.householdId,id])).rows[0];
  if(!record)throw unavailable();
  const shop=await repo.shop(ctx,record.shop_id);
  await adultTrip(repo,ctx,shop);
  const g=await currentGrant(ctx,shop);
  if(!g||g.recipient_id!==ctx.member.member_id)throw unavailable();
  const row=(await rows(ctx,shop,g)).find(r=>r.safetyId===id);
  if(!row)throw unavailable();
  return {author:shop.shopper_id,revision:1,first:1,text:row.label};
}
