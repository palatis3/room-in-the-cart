import {z} from 'zod';
import {namedAdultScope} from './adult-checks.js';
import type {BillingService} from './billing/service.js';
import type {Context,HouseholdRepository} from './repository.js';
import {invalid,refresh,unavailable} from './errors.js';
import {checkPublishingMember,reviewSharedWording} from './shared-content-filter.js';

const uuid=z.uuid().toLowerCase(),revision=z.int().nonnegative();
const command=z.discriminatedUnion('action',[
  z.object({action:z.literal('offer'),id:uuid,recipientId:uuid,shopRevision:revision,authorityEpoch:revision,pairRevision:revision,
    instruction:z.string().trim().min(1).max(240).refine(s=>!/[\p{Cc}\p{Cf}]/u.test(s)),expiresAt:z.iso.datetime({offset:true}),reviewed:z.literal(true)}).strict(),
  z.object({action:z.literal('reply'),id:uuid,answer:z.enum(['accepted','declined'])}).strict(),
  z.object({action:z.literal('withdraw'),id:uuid}).strict(),
]);
interface Row {check_id:string;step_sender:string;step_text:string;answer:'accepted'|'declined'|null;expires_at:Date;withdrawn:boolean}
const phases=['draft','frozen','placed'];
export async function cookingStepRoute(repo:HouseholdRepository,billing:BillingService|undefined,ctx:Context,shopId:string,method:string,body:unknown){
  const {shop,pair,pairRevision,recipientId,snapshot}=await namedAdultScope(repo,billing,ctx,shopId,phases);
  const input=method==='POST'?command.parse(body):null,member=ctx.member.member_id;
  const read=async()=>pair?(await ctx.db.query<Row>(`SELECT check_id,step_sender,step_text,answer,expires_at,withdrawn FROM ritc.adult_check
    WHERE household_id=$1 AND shop_id=$2 AND kind='cookStep' AND shopper_id=$3 AND recipient_id=$4 AND authority_epoch=$5
    AND pair_revision=$6 AND expires_at>$7 AND (NOT withdrawn OR check_id=$8::uuid)
    AND ritc.shared_content_visible(household_id,CASE WHEN step_sender=shopper_id THEN recipient_id ELSE shopper_id END,
      step_sender,'cookStep',check_id,1,1) ORDER BY created_at,check_id`,
    [ctx.householdId,shopId,shop.shopper_id,recipientId,shop.authority_epoch,pairRevision,ctx.now,input?.id??null])).rows:[];
  let rows=await read();
  if(input){
    if(!pair)throw unavailable();
    const key=[ctx.householdId,shopId,input.id],row=rows.find(r=>r.check_id===input.id);
    if(input.action==='offer'){
      if(input.recipientId!==pair.id)throw unavailable();
      if(shop.revision!==input.shopRevision||shop.authority_epoch!==input.authorityEpoch||pairRevision!==input.pairRevision)throw refresh();
      const expiry=new Date(input.expiresAt);
      if(expiry<=ctx.now||expiry.getTime()-ctx.now.getTime()>24*3600000)throw invalid();
      reviewSharedWording(input.instruction);
      if(row){
        if(row.withdrawn||row.step_sender!==member||row.step_text!==input.instruction||row.expires_at.getTime()!==expiry.getTime())throw refresh();
      }else{
        if(rows.some(r=>!r.withdrawn && r.step_sender===member))throw refresh();
        await checkPublishingMember(ctx);
        const inserted=await ctx.db.query(`INSERT INTO ritc.adult_check(household_id,shop_id,check_id,source_id,kind,shopper_id,recipient_id,
          shop_revision,authority_epoch,pair_revision,created_at,expires_at,step_sender,step_text)
          VALUES($1,$2,$3,$3,'cookStep',$4,$5,$6,$7,$8,$9,$10,$11,$12) ON CONFLICT DO NOTHING`,
          [...key,shop.shopper_id,recipientId,shop.revision,shop.authority_epoch,pairRevision,ctx.now,expiry,member,input.instruction]);
        if(!inserted.rowCount)throw refresh();
      }
    }else{
      if(!row)throw unavailable();
      if(input.action==='withdraw'){
        await ctx.db.query("UPDATE ritc.adult_check SET withdrawn=true,answer=NULL,answered_at=NULL WHERE household_id=$1 AND shop_id=$2 AND check_id=$3",key);
      }else{
        if(row.withdrawn||row.step_sender===member)throw unavailable();
        if(row.answer && row.answer!==input.answer)throw refresh();
        if(!row.answer){
          await checkPublishingMember(ctx);
          await ctx.db.query('UPDATE ritc.adult_check SET answer=$4,answered_at=$5 WHERE household_id=$1 AND shop_id=$2 AND check_id=$3',[...key,input.answer,ctx.now]);
        }
      }
    }
    rows=await read();
  }
  const offers=rows.filter(r=>!r.withdrawn).map(r=>({id:r.check_id,instruction:r.step_text,mine:r.step_sender===member,answer:r.answer,expiresAt:r.expires_at.toISOString()}));
  return {shopId,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,pairRevision,otherAdult:pair,offers,
    validUntil:new Date(Math.min(ctx.now.getTime()+60000,Date.parse(snapshot.validUntil),...offers.map(o=>Date.parse(o.expiresAt)))).toISOString()};
}
export async function cookingStepWording(repo:HouseholdRepository,billing:BillingService|undefined,ctx:Context,id:string){
  const row=(await ctx.db.query("SELECT shop_id,step_sender FROM ritc.adult_check WHERE household_id=$1 AND kind='cookStep' AND check_id=$2 AND NOT withdrawn",
    [ctx.householdId,id])).rows[0];
  if(!row||row.step_sender===ctx.member.member_id)throw unavailable();
  const page=await cookingStepRoute(repo,billing,ctx,row.shop_id,'GET',null);
  const offer=page.offers.find(o=>o.id===id);
  if(!offer)throw unavailable();
  return {author:row.step_sender,revision:1,first:1,text:offer.instruction};
}
