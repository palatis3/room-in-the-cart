import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import {digest} from './database.js';
import {storedDeliveryEvidence} from './delivery-evidence.js';
import {invalid,refresh,ServiceError} from './errors.js';
import {amount,cmp} from './physical-quantity.js';
import {usableQuantitySchema} from './recovery-contracts.js';
import type {Context} from './repository.js';

const id=z.string().uuid().toLowerCase();
const text=(max:number)=>z.string().min(1).refine(s=>s.trim().length>0 && Buffer.byteLength(s)<=max && !/[\u0000\uD800-\uDFFF]/u.test(s));
const quantity=usableQuantitySchema.refine(q=>!/[\u0000\uD800-\uDFFF]/u.test(q.originalLiteral));
const lineSchema=z.object({
  ordinal:z.number().int().min(0).max(3999),original:text(2048),foodName:text(240),
  received:quantity,usable:quantity,paidUSDMinor:z.number().int().min(0).max(2_147_483_647).nullish().default(null),
  location:z.enum(['pantry','fridge','freezer']),
  delivery:z.object({lotId:id,observationId:id}).strict().nullish().default(null),
  printed:z.object({page:z.number().int().min(1).max(20),line:z.number().int().min(1).max(200),
    method:z.enum(['textFile','pdfText','pdfOCR','imageOCR']),stage:z.enum(['order','receipt','finalInvoice'])}).strict().nullish().default(null)
}).strict().refine(l=>l.received.amount.numerator>0 && l.received.unit===l.usable.unit && cmp(amount(l.usable),amount(l.received))<=0
  && (l.printed?(l.printed.page-1)*200+l.printed.line-1===l.ordinal:l.ordinal<200));
export const householdReceiptBody=z.object({
  receiptId:id,imageId:id.nullish().default(null),merchant:text(256),purchaseDay:z.iso.date(),zone:text(100),
  reference:text(256).nullish().default(null),lines:z.array(lineSchema).min(1).max(50)
}).strict().refine(b=>new Set(b.lines.map(l=>l.ordinal)).size===b.lines.length &&
  new Set(b.lines.flatMap(l=>l.delivery?[l.delivery.lotId]:[])).size===b.lines.filter(l=>l.delivery).length);
type Body=z.infer<typeof householdReceiptBody>;
type Row=Body['lines'][number];
const conflict=()=>new ServiceError(409,'receipt_conflict','This receipt or delivery already has different evidence.');
function dayAt(now:Date,zone:string) {
  try { return new Intl.DateTimeFormat('en-CA',{year:'numeric',month:'2-digit',day:'2-digit',timeZone:zone}).format(now); }
  catch { throw invalid(); }
}

// Caller holds the household write lock, after checking actor, device, window, grant epoch and stock revision.
export async function acquireHouseholdReceipt(ctx:Context,body:Body,operationId:string,base:number) {
  if(body.purchaseDay>dayAt(ctx.now,body.zone)) throw invalid();
  const h=ctx.householdId;
  const sources=[...new Set([body.receiptId,...(body.imageId?[body.imageId]:[])])];
  const aliases=await ctx.db.query<{receipt_id:string}>('SELECT DISTINCT receipt_id FROM ritc.receipt_source_key WHERE household_id=$1 AND source_id=ANY($2::uuid[])',[h,sources]);
  if(aliases.rows.length>1) throw conflict();
  const receiptId=aliases.rows[0]?.receipt_id??body.receiptId;
  await ctx.db.query(`INSERT INTO ritc.receipt_source_key(household_id,source_id,receipt_id)
    SELECT $1,source,$3 FROM unnest($2::uuid[]) source ON CONFLICT DO NOTHING`,[h,sources,receiptId]);
  const header=(await ctx.db.query(`SELECT evidence->>'merchant' AS merchant,evidence->>'purchaseDay' AS day,
    evidence->>'reference' AS reference FROM ritc.household_receipt_line WHERE household_id=$1 AND receipt_id=$2 LIMIT 1`,[h,receiptId])).rows[0];
  if(header && (header.merchant!==body.merchant || header.day!==body.purchaseDay ||
                (header.reference && body.reference && header.reference!==body.reference))) throw conflict();
  const ordinals=body.lines.map(l=>l.ordinal);
  if((await ctx.db.query('SELECT 1 FROM ritc.retired_receipt_line WHERE household_id=$1 AND receipt_id=$2 AND ordinal=ANY($3::int[]) LIMIT 1',[h,receiptId,ordinals])).rowCount) throw refresh();
  const prior=await ctx.db.query<{ordinal:number,lot_id:string,evidence:unknown}>('SELECT ordinal,lot_id,evidence FROM ritc.household_receipt_line WHERE household_id=$1 AND receipt_id=$2 AND ordinal=ANY($3::int[])',[h,receiptId,ordinals]);
  const existing=new Map(prior.rows.map(r=>[r.ordinal,r]));
  const links=body.lines.flatMap(row=>!existing.has(row.ordinal)&&row.delivery?[row.delivery.lotId]:[]);
  const deliveries=links.length?await storedDeliveryEvidence(ctx,links,null,true):[];
  const linked=links.length?(await ctx.db.query<{lot_id:string,location:string,used:boolean}>(`SELECT l.lot_id,l.location,
    EXISTS(SELECT 1 FROM ritc.household_receipt_line r WHERE (r.household_id,r.lot_id)=(l.household_id,l.lot_id)) AS used
    FROM ritc.pantry_lot l WHERE household_id=$1 AND lot_id=delivery_source_id AND lot_id=ANY($2::uuid[])`,[h,links])).rows:[];
  const fresh:{lot_id:string,ordinal:number,location:string,food_name:string,usable:Row['usable'],add:boolean,evidence:unknown}[]=[];
  const receiptLines=body.lines.map(row=>{
    const old=existing.get(row.ordinal);
    const evidence={merchant:body.merchant,purchaseDay:body.purchaseDay,reference:body.reference,line:row};
    if(old) {
      if(digest(old.evidence)!==digest(evidence)) throw conflict();
      return {ordinal:row.ordinal,lotId:old.lot_id};
    }
    const link=row.delivery;
    if(link) {
      const delivery=deliveries.find(d=>d.sourceId===link.lotId),lot=linked.find(l=>l.lot_id===link.lotId);
      if(!lot || lot.location!==row.location || !delivery?.confirmed || delivery.usable?.observationId!==link.observationId ||
         delivery.confirmed.quantity?.unit!==row.usable.unit) throw refresh();
      if(lot.used) throw conflict();
    }
    const lotId=link?.lotId??randomUUID();
    fresh.push({lot_id:lotId,ordinal:row.ordinal,location:row.location,food_name:row.foodName,
      usable:row.usable,add:!link,evidence});
    return {ordinal:row.ordinal,lotId};
  });
  if(fresh.length) {
    const next=base+1, actor=ctx.member.member_id, rows=JSON.stringify(fresh);
    await ctx.db.query('INSERT INTO ritc.pantry_batch(household_id,operation_id,pantry_revision) VALUES($1,$2,$3)',[h,operationId,next]);
    await ctx.db.query(`INSERT INTO ritc.pantry_lot(household_id,lot_id,receipt_origin,location,food_name,exclusion_tags,actor_id,operation_id)
      SELECT $1,lot_id,true,location,food_name,'{}',$3,$4 FROM jsonb_to_recordset($2::jsonb)
      AS r(lot_id uuid,location text,food_name text,add boolean) WHERE r.add`,[h,rows,actor,operationId]);
    await ctx.db.query(`INSERT INTO ritc.pantry_event(household_id,lot_id,event_id,operation_id,actor_id,kind,pantry_revision,confirmed_at,quantity)
      SELECT $1,lot_id,lot_id,$3,$4,'observe',$5,$6,usable FROM jsonb_to_recordset($2::jsonb)
      AS r(lot_id uuid,usable jsonb,add boolean) WHERE r.add`,[h,rows,operationId,actor,next,ctx.now]);
    await ctx.db.query(`INSERT INTO ritc.household_receipt_line(household_id,receipt_id,ordinal,lot_id,actor_id,operation_id,evidence)
      SELECT $1,$3,ordinal,lot_id,$4,$5,evidence FROM jsonb_to_recordset($2::jsonb)
      AS r(ordinal int,lot_id uuid,evidence jsonb)`,[h,rows,receiptId,actor,operationId]);
    await ctx.db.query('UPDATE ritc.household SET pantry_revision=$2 WHERE household_id=$1',[h,next]);
  }
  await ctx.db.query(`INSERT INTO ritc.receipt_submission_line(household_id,operation_id,receipt_id,ordinal)
    SELECT $1,$2,$3,ordinal FROM unnest($4::int[]) ordinal`,[h,operationId,receiptId,ordinals]);
  return {receiptId,receiptLines,savedCount:fresh.length,pantryRevision:base+(fresh.length?1:0)};
}
