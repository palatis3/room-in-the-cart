import {pantryRevision,trackCookStockProvenance} from './pantry-lots.js';
import type {Context,Shop} from './repository.js';
import {cookCorrectionBody,cookCopyBaselineBody,cookCopySaveBody,cookCopySendBody} from './contracts.js';
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
  c.pantry_revision AS "pantryRevision",c.recovery_revision AS "recoveryRevision",c.recovery_meal_id AS "revisionId",c.occurrence_id AS "occurrenceId",c.meal_revision AS "mealRevision",c.version,c.language,c.reviewed_text AS text,c.created_at AS "createdAt"`;

function omitAbsentSeals(row:Record<string,unknown>) {
  for(const field of ['pantryRevision','recoveryRevision','revisionId']) if(row[field]===null) delete row[field];
}

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
  for(const copy of copies) omitAbsentSeals(copy);
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
  omitAbsentSeals(copy);
  return {baseline:{copy,send:{sendId,sentAt,recipient:name,copyId:copy.copyId}}};
}

// Called only after verifying the live shopper and their named paid seat. The
// baseline pointer, both immutable versions and the current series head are read
// together. A later copy or a source revision invalidates differences-only sharing.
export async function cookCorrectionFacts(ctx:Context,shop:Shop,input:unknown) {
  const placed=placedRevision(shop), review=cookCorrectionBody.parse(input);
  const row=(await ctx.db.query(`SELECT cur.fact_index AS current_facts,prev.fact_index AS previous_facts,
      cur.pantry_revision,cur.recovery_revision,
      (cur.language=prev.language AND cur.version>=prev.version) AS compatible
    FROM ritc.dated_cook_copy cur JOIN ritc.cook_copy_series series USING(household_id,shop_id,occurrence_id)
    JOIN ritc.cook_copy_baseline b USING(household_id,shop_id,occurrence_id)
    JOIN ritc.cook_copy_send send ON (send.household_id,send.send_id)=(b.household_id,b.send_id)
    JOIN ritc.dated_cook_copy prev ON (prev.household_id,prev.shop_id,prev.occurrence_id,prev.copy_id)=
      (b.household_id,b.shop_id,b.occurrence_id,send.copy_id)
    WHERE (cur.household_id,cur.shop_id,cur.occurrence_id,cur.copy_id)=($1,$2,$3,$4)
      AND prev.copy_id=$5 AND b.send_id=$6 AND b.recipient=$7 AND send.recipient=b.recipient
      AND cur.version=series.last_version AND cur.shop_revision=$8 AND cur.placed_revision=$9
      AND cur.authority_epoch=$10 AND cur.supply_revision=$11`,
    [ctx.householdId,shop.shop_id,review.occurrenceId,review.copyId,review.previousCopyId,review.previousSendId,
      review.recipient,shop.revision,placed,shop.authority_epoch,shop.supply_revision])).rows[0];
  if(!row || (row.recovery_revision!==null && row.recovery_revision!==shop.recovery_revision) ||
    (row.pantry_revision!==null && row.pantry_revision!==await pantryRevision(ctx))) {
    throw new ServiceError(409,'stale_base','Review the current cook instruction and recipient again.');
  }
  return {copyId:review.copyId,previousCopyId:review.previousCopyId,previousSendId:review.previousSendId,
    recipient:review.recipient,currentFacts:row.compatible?row.current_facts:null,previousFacts:row.compatible?row.previous_facts:null};
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
    if(placed!==row.placedRevision || shop.supply_revision!==row.supplyRevision ||
      row.pantryRevision!==undefined && row.pantryRevision!==await pantryRevision(ctx)) {
      throw new ServiceError(409,'stale_supply','Review the currently placed meal and delivery facts.');
    }
    const sealed=await ctx.db.query(`SELECT 1 FROM ritc.shared_meal_revision m,ritc.shop_snapshot ss WHERE (ss.household_id,ss.shop_id,ss.revision)=($1,$2,$3)
      AND (m.household_id,m.shop_id,m.occurrence_id,m.revision)=($1,$2,$4,$5) AND m.meal IS NOT NULL
      AND EXISTS(SELECT 1 FROM jsonb_array_elements(ss.snapshot->'mealRefs') ref
        WHERE (ref->>'occurrenceId')::uuid=m.occurrence_id AND (ref->>'revision')::int=m.revision)`,[...scope,placed,row.occurrenceId,row.mealRevision]);
    if(!sealed.rowCount) throw unavailable();
    const recovery=(await ctx.db.query(`SELECT new_revision_id,current_meal IS NOT NULL AS available FROM ritc.meal_recovery_revision
      WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 ORDER BY recovery_revision DESC LIMIT 1`,
      [...scope,row.occurrenceId])).rows[0];
    if(recovery ? !recovery.available || row.revisionId!==recovery.new_revision_id || row.recoveryRevision!==shop.recovery_revision
                : row.revisionId!==undefined) throw new ServiceError(409,'stale_meal','Review the current dinner before saving its cook instructions.');
    const series=await ctx.db.query(`INSERT INTO ritc.cook_copy_series AS series(household_id,shop_id,occurrence_id,last_version)
      VALUES($1,$2,$3,1) ON CONFLICT(household_id,shop_id,occurrence_id)
      DO UPDATE SET last_version=series.last_version+1 RETURNING last_version`,[...scope,row.occurrenceId]);
    await ctx.db.query(`INSERT INTO ritc.dated_cook_copy(household_id,shop_id,copy_id,occurrence_id,meal_revision,version,
      shop_revision,placed_revision,authority_epoch,supply_revision,language,reviewed_text,actor_id,created_at,pantry_revision,recovery_revision,recovery_meal_id,fact_index)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18::jsonb)`,
      [...scope,operationId,row.occurrenceId,row.mealRevision,series.rows[0]!.last_version,shop.revision,placed,shop.authority_epoch,
        row.supplyRevision,row.language,row.text,ctx.member.member_id,ctx.now,row.pantryRevision??null,row.recoveryRevision??null,row.revisionId??null,row.factIndex?JSON.stringify(row.factIndex):null]);
    if(row.pantryRevision!==undefined) await trackCookStockProvenance(ctx,shop,operationId);
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
