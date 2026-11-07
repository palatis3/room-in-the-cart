import type {Context,Shop} from './repository.js';
import {cookCopyBaselineBody,cookCopySaveBody,cookCopySendBody} from './contracts.js';
import {ServiceError,unavailable} from './errors.js';

type Kind='cookCopy.save'|'cookCopy.markSent';
function placedRevision(shop:Shop):number {
  if(shop.placed_revision===null || !['placed','closed'].includes(shop.phase)) {
    throw new ServiceError(409,'placed_order_required','Open the placed order for these cook instructions.');
  }
  return shop.placed_revision;
}

const copyFields=`c.copy_id AS "copyId",c.shop_id AS "shopId",c.shop_revision AS "shopRevision",
  c.placed_revision AS "placedRevision",c.authority_epoch AS "authorityEpoch",c.supply_revision AS "supplyRevision",
  c.occurrence_id AS "occurrenceId",c.meal_revision AS "mealRevision",c.version,c.language,c.reviewed_text AS text,c.created_at AS "createdAt"`;

export async function cookCopyHistory(ctx:Context,shop:Shop,occurrenceId:string,cursor:string|null) {
  placedRevision(shop);
  const scope=[ctx.householdId,shop.shop_id,occurrenceId];
  let before:number|null=null;
  if(cursor!==null) {
    const row=(await ctx.db.query('SELECT version FROM ritc.dated_cook_copy WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 AND copy_id=$4',
      [...scope,cursor])).rows[0];
    if(!row) throw unavailable();
    before=row.version;
  }
  const result=await ctx.db.query(`SELECT ${copyFields} FROM ritc.dated_cook_copy c
    WHERE c.household_id=$1 AND c.shop_id=$2 AND c.occurrence_id=$3 AND ($4::int IS NULL OR c.version<$4)
    ORDER BY c.version DESC LIMIT 21`,[...scope,before]);
  const copies=result.rows.slice(0,20);
  return {copies,nextCursor:result.rows.length>20?copies.at(-1)!.copyId:null};
}

export async function cookCopyBaseline(ctx:Context,shop:Shop,input:unknown) {
  placedRevision(shop);
  const {occurrenceId,recipient}=cookCopyBaselineBody.parse(input);
  const row=(await ctx.db.query(`SELECT ${copyFields},s.send_id AS "sendId",s.recipient,s.sent_at AS "sentAt"
    FROM ritc.cook_copy_baseline b JOIN ritc.cook_copy_send s USING(household_id,send_id)
    JOIN ritc.dated_cook_copy c ON (c.household_id,c.copy_id)=(s.household_id,s.copy_id)
    WHERE b.household_id=$1 AND b.shop_id=$2 AND b.occurrence_id=$3 AND b.recipient=$4`,
    [ctx.householdId,shop.shop_id,occurrenceId,recipient])).rows[0];
  if(!row) return {baseline:null};
  const {sendId,sentAt,recipient:name,...copy}=row;
  return {baseline:{copy,send:{sendId,sentAt,recipient:name,copyId:copy.copyId}}};
}

export async function cookCopyStillExists(ctx:Context,shop:Shop,kind:Kind,operationId:string) {
  const result=kind==='cookCopy.save'
    ? await ctx.db.query('SELECT 1 FROM ritc.dated_cook_copy WHERE household_id=$1 AND shop_id=$2 AND copy_id=$3',[ctx.householdId,shop.shop_id,operationId])
    : await ctx.db.query(`SELECT 1 FROM ritc.cook_copy_send s JOIN ritc.dated_cook_copy c USING(household_id,copy_id)
        WHERE c.household_id=$1 AND c.shop_id=$2 AND s.send_id=$3`,[ctx.householdId,shop.shop_id,operationId]);
  return result.rowCount===1;
}

// Household command execution serializes the comparison, insert, baseline update,
// operation and receipt. Merely saving a version never writes a send.
export async function recordCookCopy(ctx:Context,shop:Shop,kind:Kind,input:unknown,operationId:string) {
  const placed=placedRevision(shop), scope=[ctx.householdId,shop.shop_id];
  if(kind==='cookCopy.save') {
    const row=cookCopySaveBody.parse(input);
    if(placed!==row.placedRevision || shop.supply_revision!==row.supplyRevision) {
      throw new ServiceError(409,'stale_supply','Review the currently placed meal and delivery facts.');
    }
    const sealed=await ctx.db.query(`SELECT 1 FROM ritc.shared_meal_revision m,ritc.shop_snapshot ss WHERE (ss.household_id,ss.shop_id,ss.revision)=($1,$2,$3)
      AND (m.household_id,m.shop_id,m.occurrence_id,m.revision)=($1,$2,$4,$5) AND m.meal IS NOT NULL
      AND EXISTS(SELECT 1 FROM jsonb_array_elements(ss.snapshot->'mealRefs') ref
        WHERE (ref->>'occurrenceId')::uuid=m.occurrence_id AND (ref->>'revision')::int=m.revision)`,[...scope,placed,row.occurrenceId,row.mealRevision]);
    if(!sealed.rowCount) throw unavailable();
    const series=await ctx.db.query(`INSERT INTO ritc.cook_copy_series AS series(household_id,shop_id,occurrence_id,last_version)
      VALUES($1,$2,$3,1) ON CONFLICT(household_id,shop_id,occurrence_id)
      DO UPDATE SET last_version=series.last_version+1 RETURNING last_version`,[...scope,row.occurrenceId]);
    await ctx.db.query(`INSERT INTO ritc.dated_cook_copy(household_id,shop_id,copy_id,occurrence_id,meal_revision,version,
      shop_revision,placed_revision,authority_epoch,supply_revision,language,reviewed_text,actor_id,created_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
      [...scope,operationId,row.occurrenceId,row.mealRevision,series.rows[0]!.last_version,shop.revision,placed,shop.authority_epoch,
        row.supplyRevision,row.language,row.text,ctx.member.member_id,ctx.now]);
    return operationId;
  }
  const mark=cookCopySendBody.parse(input);
  const copy=(await ctx.db.query('SELECT occurrence_id FROM ritc.dated_cook_copy WHERE household_id=$1 AND shop_id=$2 AND copy_id=$3',
    [...scope,mark.copyId])).rows[0];
  if(!copy) throw unavailable();
  const recipientScope=[...scope,copy.occurrence_id,mark.recipient];
  const previous=(await ctx.db.query('SELECT send_id FROM ritc.cook_copy_baseline WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 AND recipient=$4',recipientScope)).rows[0];
  if((previous?.send_id??null)!==mark.previousSendId) {
    throw new ServiceError(409,'stale_base','Review the last version marked sent to this recipient.');
  }
  await ctx.db.query('INSERT INTO ritc.cook_copy_send(household_id,send_id,copy_id,recipient,actor_id,sent_at) VALUES($1,$2,$3,$4,$5,$6)',
    [ctx.householdId,operationId,mark.copyId,mark.recipient,ctx.member.member_id,ctx.now]);
  await ctx.db.query(`INSERT INTO ritc.cook_copy_baseline(household_id,shop_id,occurrence_id,recipient,send_id)
    VALUES($1,$2,$3,$4,$5) ON CONFLICT(household_id,shop_id,occurrence_id,recipient) DO UPDATE SET send_id=EXCLUDED.send_id`,[...recipientScope,operationId]);
  return mark.copyId;
}
