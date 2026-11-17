import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { digest } from './database.js';
import { invalid, refresh, ServiceError, unavailable } from './errors.js';
import { householdPantryEpoch, pantryRevision, physicalPantryPage } from './pantry-lots.js';
import { pantryBodies, usableQuantitySchema } from './recovery-contracts.js';
import type { Context } from './repository.js';

const id=z.string().uuid().toLowerCase();
const revision=z.number().int().min(0).max(2_147_483_647);
const validText=(value:string)=>!/[\u0000\uD800-\uDFFF]/u.test(value);
const addBody=pantryBodies['pantry.create'].omit({pantryRevision:true,supplyRevision:true}).extend({
  location:z.enum(['pantry','fridge','freezer']),confirmedAt:z.iso.datetime({offset:true}),quantity:usableQuantitySchema.nullable(),
}).refine(b=>validText(b.foodName) && b.exclusionTags.every(validText) && (!b.quantity || validText(b.quantity.originalLiteral)));
const addCommand=z.object({v:z.literal(1),kind:z.literal('pantry.addLot'),clientKey:id,replayWindow:id,
  grantEpoch:revision,pantryRevision:revision,body:addBody}).strict();
const correctionBody=z.object({lotId:id,predecessorId:id,confirmedAt:z.iso.datetime({offset:true}),
  quantity:usableQuantitySchema.nullable()}).strict().refine(b=>!b.quantity || validText(b.quantity.originalLiteral));
const correctionCommand=addCommand.extend({kind:z.literal('pantry.correctCount'),body:correctionBody});
const stockCommand=z.discriminatedUnion('kind',[addCommand,correctionCommand]);
const changeGrant=z.object({v:z.literal(1),memberId:id,enabled:z.boolean(),expectedGrantEpoch:revision}).strict();

function currentEpoch(ctx:Context) {
  const epoch=householdPantryEpoch(ctx);
  if(epoch===null) throw unavailable();
  return epoch;
}
function requireOrganizer(ctx:Context) {
  currentEpoch(ctx);
  if(!ctx.member.organizer) throw unavailable();
}

export async function householdPantry(ctx:Context,cursor:string|null) {
  const grantEpoch=currentEpoch(ctx);
  return {v:1,householdId:ctx.householdId,grantEpoch,pantryRevision:await pantryRevision(ctx),asOf:ctx.now.toISOString(),
    ...await physicalPantryPage(ctx,cursor)};
}

export async function pantryGrants(ctx:Context) {
  requireOrganizer(ctx);
  const {rows}=await ctx.db.query(`SELECT member_id AS "memberId",alias AS label,pantry_editor AS enabled,pantry_grant_epoch AS "grantEpoch"
    FROM ritc.member WHERE household_id=$1 AND kind='adult' AND state='active' AND NOT organizer ORDER BY alias,member_id`,[ctx.householdId]);
  return {v:1,adults:rows};
}

export async function changePantryGrant(ctx:Context,input:unknown) {
  requireOrganizer(ctx);
  const {memberId,enabled,expectedGrantEpoch}=changeGrant.parse(input);
  const row=(await ctx.db.query(`SELECT pantry_editor,pantry_grant_epoch FROM ritc.member
    WHERE household_id=$1 AND member_id=$2 AND kind='adult' AND state='active' AND NOT organizer`,[ctx.householdId,memberId])).rows[0];
  if(!row) throw unavailable();
  if(row.pantry_grant_epoch!==expectedGrantEpoch) {
    if(row.pantry_grant_epoch!==expectedGrantEpoch+1 || row.pantry_editor!==enabled) throw refresh();
  } else if(row.pantry_editor!==enabled) {
    await ctx.db.query('UPDATE ritc.member SET pantry_editor=$3 WHERE household_id=$1 AND member_id=$2',[ctx.householdId,memberId,enabled]);
  }
  return pantryGrants(ctx);
}

// HouseholdRepository.authorized holds the existing household row lock and
// revalidates the live session, member and device for reads, writes and retries.
export async function recordHouseholdPantryCommand(ctx:Context,input:unknown) {
  const epoch=currentEpoch(ctx), command=stockCommand.parse(input);
  if(command.grantEpoch!==epoch) throw refresh();
  const window=await ctx.db.query(`SELECT 1 FROM ritc.replay_window WHERE household_id=$1 AND window_id=$2
    AND member_id=$3 AND device_id=$4 AND revoked_at IS NULL AND expires_at>$5`,
    [ctx.householdId,command.replayWindow,ctx.member.member_id,ctx.deviceId,ctx.now]);
  if(!window.rowCount) throw refresh();
  const payloadDigest=digest({scope:'household_pantry',householdId:ctx.householdId,command});
  const prior=(await ctx.db.query(`SELECT o.authority_scope,o.pantry_grant_epoch,o.device_id,o.payload_digest,r.response,
    EXISTS(SELECT 1 FROM ritc.pantry_event e WHERE (e.household_id,e.operation_id)=(o.household_id,o.operation_id)) AS retained
    FROM ritc.operation o LEFT JOIN ritc.operation_response r USING(household_id,operation_id)
    WHERE o.household_id=$1 AND o.actor_id=$2 AND o.client_key=$3`,[ctx.householdId,ctx.member.member_id,command.clientKey])).rows[0];
  if(prior) {
    if(prior.device_id!==ctx.deviceId || (prior.authority_scope==='household_pantry' && prior.pantry_grant_epoch!==epoch)) throw refresh();
    if(prior.payload_digest!==payloadDigest || prior.authority_scope!=='household_pantry')
      throw new ServiceError(409,'key_reused','Review and submit the changed intent with a new key.');
    if(!prior.retained || !prior.response) throw refresh();
    return prior.response;
  }
  if(command.pantryRevision!==await pantryRevision(ctx)) throw new ServiceError(409,'stale_supply','Review the latest household stock.');
  const operationId=randomUUID(),next=command.pantryRevision+1;
  const correction=command.kind==='pantry.correctCount'?command.body:null;
  const lotId=correction?.lotId??operationId;
  if(Date.parse(command.body.confirmedAt)>ctx.now.getTime()) throw invalid();
  if(correction) {
    // The household row lock covers legacy shop observations and reservations as well.
    const lot=(await ctx.db.query(`SELECT delivery_source_id,(SELECT operation_id FROM ritc.pantry_event e
      WHERE (e.household_id,e.lot_id)=(l.household_id,l.lot_id) AND kind='observe'
      ORDER BY pantry_revision DESC LIMIT 1) AS observation_id
      FROM ritc.pantry_lot l WHERE household_id=$1 AND lot_id=$2`,[ctx.householdId,lotId])).rows[0];
    if(!lot || lot.delivery_source_id) throw unavailable();
    if(lot.observation_id!==correction.predecessorId) throw new ServiceError(409,'stale_supply','Review the latest household count.');
  }
  const receipt={v:1,kind:command.kind,householdId:ctx.householdId,operationId,lotId,grantEpoch:epoch,pantryRevision:next};
  await ctx.db.query(`INSERT INTO ritc.operation(household_id,operation_id,actor_id,device_id,client_key,window_id,kind,
    shop_id,payload_digest,response_scope,authority_scope,pantry_grant_epoch)
    VALUES($1,$2,$3,$4,$5,$6,$7,NULL,$8,'pantry','household_pantry',$9)`,
    [ctx.householdId,operationId,ctx.member.member_id,ctx.deviceId,command.clientKey,command.replayWindow,command.kind,payloadDigest,epoch]);
  if(command.kind==='pantry.addLot') {
    const b=command.body;
    if(b.storedAt && Date.parse(b.storedAt)>ctx.now.getTime()) throw invalid();
    await ctx.db.query(`INSERT INTO ritc.pantry_lot(household_id,lot_id,origin_shop_id,location,stored_at,use_first_at,food_name,
      exclusion_tags,actor_id,operation_id) VALUES($1,$2,NULL,$3,$4,$5,$6,$7,$8,$2)`,
      [ctx.householdId,operationId,b.location,b.storedAt,b.useFirstAt,b.foodName,b.exclusionTags,ctx.member.member_id]);
  }
  await ctx.db.query(`INSERT INTO ritc.pantry_event(household_id,lot_id,shop_id,operation_id,actor_id,kind,pantry_revision,confirmed_at,quantity,predecessor_observation_id)
    VALUES($1,$2,NULL,$3,$4,'observe',$5,$6,$7,$8)`,
    [ctx.householdId,lotId,operationId,ctx.member.member_id,next,command.body.confirmedAt,command.body.quantity,correction?.predecessorId??null]);
  await ctx.db.query('UPDATE ritc.household SET pantry_revision=$2 WHERE household_id=$1',[ctx.householdId,next]);
  await ctx.db.query('INSERT INTO ritc.operation_response(household_id,operation_id,response) VALUES($1,$2,$3)',[ctx.householdId,operationId,receipt]);
  return receipt;
}
