import {z} from 'zod';
import {hasPaidSeat} from './billing/domain.js';
import type {BillingService} from './billing/service.js';
import type {Context,HouseholdRepository,Shop} from './repository.js';
import {invalid,refresh,ServiceError,unavailable} from './errors.js';
import {checkPublishingMember,reviewSharedWording} from './shared-content-filter.js';

const uuid=z.uuid().toLowerCase();
const revision=z.int().nonnegative();
const kind=z.enum(['attendance','cupboard']);
const attendance=z.enum(['home','latePlate','out']);
const cupboard=z.enum(['enough','low','cannotCheck']);
const decimal=z.string().regex(/^(?:0|[1-9]\d{0,5})(?:\.\d{1,3})?$/)
  .refine(value=>Number(value)>0).transform(value=>value.includes('.')?value.replace(/0+$/,'').replace(/\.$/,''):value);
const amount=z.object({value:decimal,unit:z.enum(['count','gram','kilogram','milliliter','liter'])}).strict();
const answer=z.union([attendance,cupboard]);
const command=z.discriminatedUnion('action',[
  z.object({action:z.literal('ask'),id:uuid,kind,sourceId:uuid,recipientId:uuid,shopRevision:revision,
    authorityEpoch:revision,pairRevision:revision,expiresAt:z.iso.datetime({offset:true})}).strict(),
  z.object({action:z.literal('answer'),id:uuid,answer,quantity:amount.nullish()}).strict(),
  z.object({action:z.literal('review'),id:uuid,answer,answeredAt:z.iso.datetime({offset:true})}).strict(),
  z.object({action:z.literal('withdraw'),id:uuid}).strict(),
]);
type Kind=z.infer<typeof kind>;
type Amount=z.infer<typeof amount>;
type Answer=z.infer<typeof answer>;
interface Choice {id:string;label:string;day:string|null;shoppingPacks:number|null}
interface StoredCheck {
  check_id:string;kind:Kind;source_id:string;expires_at:Date;recipient_id:string;
  answer:Answer|null;quantity:Amount|null;answered_at:Date|null;reviewed:boolean;withdrawn:boolean;
}
export interface NamedAdultPair {id:string;label:string}
const duration=7*86400000;

// Entering a general workspace as a Free adult must not contact the billing provider.
// A displayed paid entry and the route itself each require current named-seat eligibility.
export async function adultCheckCapability(ctx:Context,billing:BillingService|undefined) {
  if(!billing)return false;
  const seat=await ctx.db.query('SELECT 1 FROM ritc.billing_seat WHERE household_id=$1 AND member_id=$2',
    [ctx.householdId,ctx.member.member_id]);
  if(!seat.rowCount)return false;
  try{return hasPaidSeat(await billing.snapshot(ctx),ctx.member.member_id,ctx.now);}
  catch(error){if(error instanceof ServiceError)return false;throw error;}
}

async function findPair(ctx:Context,shop:Shop,otherID:string|undefined):Promise<NamedAdultPair|null> {
  if(!otherID || (ctx.member.member_id!==shop.shopper_id && otherID!==shop.shopper_id))return null;
  const row=(await ctx.db.query<NamedAdultPair>(`SELECT member_id AS id,alias AS label FROM ritc.member
    WHERE household_id=$1 AND member_id=$2 AND kind='adult' AND state='active'
    AND (can_contribute OR organizer OR member_id=$3)
    AND ritc.shared_content_visible($1,$4,$2,'adultCheck',$5,1,1)
    AND ritc.shared_content_visible($1,$2,$4,'adultCheck',$5,1,1)`,
    [ctx.householdId,otherID,shop.shopper_id,ctx.member.member_id,shop.shop_id])).rows[0];
  return row??null;
}

// Recipients read source labels for their current addressed questions only.
async function choices(ctx:Context,shop:Shop,shopper:boolean,rows:StoredCheck[]) {
  const base=[ctx.householdId,shop.shop_id];
  const dinners=(await ctx.db.query<Choice>(`SELECT id,meal->>'title' AS label,meal->>'day' AS day,NULL::int AS "shoppingPacks"
    FROM (SELECT DISTINCT ON (occurrence_id) occurrence_id AS id,meal FROM ritc.shared_meal_revision
      WHERE household_id=$1 AND shop_id=$2 AND ($3::boolean OR occurrence_id=ANY($4::uuid[]))
      ORDER BY occurrence_id,revision DESC) latest
    WHERE meal->>'kind'='dinner' AND meal->>'day' IS NOT NULL ORDER BY day,id`,
    [...base,shopper,rows.filter(r=>r.kind==='attendance').map(r=>r.source_id)])).rows;
  const items=(await ctx.db.query<Choice>(`SELECT line_id AS id,original_item AS label,NULL::text AS day,packs AS "shoppingPacks"
    FROM ritc.basket_line WHERE household_id=$1 AND shop_id=$2 AND ($3::boolean OR line_id=ANY($4::uuid[])) ORDER BY line_id`,
    [...base,shopper,rows.filter(r=>r.kind==='cupboard').map(r=>r.source_id)])).rows;
  return {dinners,items};
}

export async function namedAdultScope(repo:HouseholdRepository,billing:BillingService|undefined,ctx:Context,shopId:string,phases:readonly string[]) {
  if(!billing||ctx.ownRequestsOnly||ctx.viewGrantId||ctx.member.kind!=='adult'||ctx.member.state!=='active')throw unavailable();
  const boot=await repo.bootstrap(ctx);
  if(boot.shopId!==shopId||boot.grantId)throw unavailable();
  const shop=await repo.shop(ctx,shopId);
  const shopper=shop.shopper_id===ctx.member.member_id;
  if(!shopper&&!ctx.member.can_contribute&&!ctx.member.organizer)throw unavailable();
  if(!phases.includes(shop.phase))throw unavailable();
  const snapshot=await billing.snapshot(ctx);
  if(!hasPaidSeat(snapshot,ctx.member.member_id,ctx.now))throw new ServiceError(403,'membership_inactive','Use Free or manage named adult seats.');
  const other=snapshot.seats.find(s=>s.userID!==ctx.member.member_id && hasPaidSeat(snapshot,s.userID,ctx.now));
  const pair=await findPair(ctx,shop,other?.userID);
  const pairRevision=(await ctx.db.query<{revision:number}>(`SELECT coalesce(max(revision),0) AS revision FROM ritc.billing_event
    WHERE household_id=$1 AND kind='seats_changed'`,[ctx.householdId])).rows[0]!.revision;
  const recipientId=shopper?pair?.id:ctx.member.member_id;
  return {shop,shopper,snapshot,pair,pairRevision,recipientId};
}

export async function adultChecksRoute(repo:HouseholdRepository,billing:BillingService|undefined,ctx:Context,shopId:string,method:string,body:unknown) {
  const {shop,shopper,snapshot,pair,pairRevision,recipientId}=await namedAdultScope(repo,billing,ctx,shopId,['draft']);
  const basis=[ctx.householdId,shopId,shop.shopper_id,recipientId??null,shop.revision,shop.authority_epoch,pairRevision,ctx.now];
  const input=method==='POST'?command.parse(body):null;
  const readRows=async()=>pair?(await ctx.db.query<StoredCheck>(`SELECT check_id,kind,source_id,expires_at,recipient_id,answer,quantity,answered_at,reviewed,withdrawn
    FROM ritc.adult_check WHERE household_id=$1 AND shop_id=$2 AND shopper_id=$3 AND recipient_id=$4
    AND kind IN ('attendance','cupboard') AND shop_revision=$5 AND authority_epoch=$6 AND pair_revision=$7 AND expires_at>$8
    AND (NOT withdrawn OR check_id=$9::uuid) ORDER BY created_at,check_id`,[...basis,input?.id??null])).rows:[];
  let rows=await readRows();
  const {dinners,items}=pair?await choices(ctx,shop,shopper,rows.filter(r=>!r.withdrawn)):{dinners:[],items:[]};
  const source=(type:Kind,id:string)=>(type==='attendance'?dinners:items).find(c=>c.id===id);
  if(input){
    if(!pair)throw unavailable();
    const key=[ctx.householdId,shopId,input.id];
    const row=rows.find(r=>r.check_id===input.id);
    if(input.action==='ask'){
      if(!shopper||input.recipientId!==pair.id)throw unavailable();
      if(input.shopRevision!==shop.revision||input.authorityEpoch!==shop.authority_epoch||input.pairRevision!==pairRevision)throw refresh();
      const choice=source(input.kind,input.sourceId);
      if(!choice)throw unavailable();
      reviewSharedWording(choice.label);
      const end=new Date(input.expiresAt);
      if(end<=ctx.now||end.getTime()-ctx.now.getTime()>duration)throw invalid();
      if(row){
        if(row.withdrawn||row.kind!==input.kind||row.source_id!==input.sourceId||row.expires_at.getTime()!==end.getTime())throw refresh();
      }else{
        if(rows.some(r=>!r.withdrawn && r.kind===input.kind && r.source_id===input.sourceId) || rows.filter(r=>!r.withdrawn).length>=24)throw refresh();
        await checkPublishingMember(ctx);
        const inserted=await ctx.db.query(`INSERT INTO ritc.adult_check
          (household_id,shop_id,check_id,shopper_id,recipient_id,shop_revision,authority_epoch,pair_revision,kind,source_id,created_at,expires_at)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) ON CONFLICT DO NOTHING`,
          [...key,shop.shopper_id,pair.id,shop.revision,shop.authority_epoch,pairRevision,input.kind,input.sourceId,ctx.now,end]);
        if(!inserted.rowCount)throw refresh();
      }
    }else{
      if(!row)throw unavailable();
      if(input.action==='withdraw'){
        await ctx.db.query('UPDATE ritc.adult_check SET withdrawn=true,answer=NULL,quantity=NULL,answered_at=NULL,reviewed=false WHERE household_id=$1 AND shop_id=$2 AND check_id=$3',key);
      }else{
        if(row.withdrawn||!source(row.kind,row.source_id))throw unavailable();
        if(input.action==='answer'){
          if(shopper)throw unavailable();
          if(!(row.kind==='attendance'?attendance:cupboard).safeParse(input.answer).success ||
            (input.quantity && input.answer!=='enough' && input.answer!=='low'))throw invalid();
          const quantity=input.quantity??null;
          if(row.answer){
            if(row.answer!==input.answer||row.quantity?.value!==quantity?.value||row.quantity?.unit!==quantity?.unit)throw refresh();
          }else{
            await checkPublishingMember(ctx);
            await ctx.db.query('UPDATE ritc.adult_check SET answer=$4,quantity=$5,answered_at=$6 WHERE household_id=$1 AND shop_id=$2 AND check_id=$3',
              [...key,input.answer,quantity,ctx.now]);
          }
        }else{
          if(!shopper)throw unavailable();
          if(!row.answered_at||row.answer!==input.answer||row.answered_at.getTime()!==Date.parse(input.answeredAt))throw refresh();
          await ctx.db.query('UPDATE ritc.adult_check SET reviewed=true WHERE household_id=$1 AND shop_id=$2 AND check_id=$3',key);
        }
      }
    }
    rows=await readRows();
  }
  const checks=rows.flatMap(row=>{
    const choice=source(row.kind,row.source_id);
    return row.withdrawn||!choice?[]:[{id:row.check_id,kind:row.kind,sourceId:row.source_id,label:choice.label,day:choice.day,
      shoppingPacks:choice.shoppingPacks,expiresAt:row.expires_at.toISOString(),answer:row.answer,quantity:row.quantity,
      answeredAt:row.answered_at?.toISOString()??null,reviewed:row.reviewed,canAnswer:!shopper&&row.answer===null}];
  });
  return {shopId,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,pairRevision,shopper,
    recipient:shopper?pair:null,dinners:shopper?dinners.map(({id,label,day})=>({id,label,day})):[],
    items:shopper?items.map(({id,label,shoppingPacks})=>({id,label,shoppingPacks})):[],checks,
    validUntil:new Date(Math.min(Date.parse(snapshot.validUntil),ctx.now.getTime()+60000,...checks.map(c=>Date.parse(c.expiresAt)))).toISOString()};
}
