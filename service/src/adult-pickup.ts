import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import {digest} from './database.js';
import {ServiceError,unavailable} from './errors.js';
import type {Context,HouseholdRepository,Shop} from './repository.js';
import {checkPublishingMember,reviewSharedWording} from './shared-content-filter.js';

export interface AdultPickupOptions {
  adultLastCall?:boolean;
  adultProductReferenceDays?:number;
  adultProductReferenceMedia?:boolean;
}
export function adultPickupConfiguration(env:NodeJS.ProcessEnv):AdultPickupOptions {
  const approved=(flag:string,approval:string)=>{
    if(env[flag]!=='true')return false;
    if(!env[approval]?.trim())throw Error(flag+' requires an owner approval reference.');
    return true;
  };
  const adultLastCall=approved('ADULT_LAST_CALL_ENABLED','ADULT_LAST_CALL_APPROVAL');
  const references=approved('ADULT_PRODUCT_REFERENCE_ENABLED','ADULT_PRODUCT_REFERENCE_APPROVAL');
  const media=approved('ADULT_PRODUCT_MEDIA_ENABLED','ADULT_PRODUCT_MEDIA_APPROVAL');
  const days=Number(env.ADULT_PRODUCT_REFERENCE_RETENTION_DAYS);
  if(references && (env.SHARED_CONTENT_SAFETY_ENABLED!=='true'||!Number.isInteger(days)||days<1||days>7))
    throw Error('Product references require shared content moderation and a retention interval of 1 to 7 days.');
  if(media && (!references||!env.ADULT_PRODUCT_MEDIA_OPERATOR_APPROVAL?.trim()))
    throw Error('Product media requires enabled product references and a separate media operator approval.');
  return {adultLastCall,...(references?{adultProductReferenceDays:days}:{}),adultProductReferenceMedia:media};
}

const uuid=z.uuid().toLowerCase(),revision=z.int().min(0).max(2147483646);
const stale=()=>new ServiceError(409,'stale_base','Refresh the current pickup and review again.');
const lastCall=z.object({expectedRevision:revision,authorityEpoch:revision,cutoffAt:z.iso.datetime({offset:true})}).strict();
const respond=z.object({revision,action:z.enum(['pass','mute','unmute'])}).strict();
async function adultScope(repo:HouseholdRepository,ctx:Context,shop:Shop) {
  if(ctx.member.kind!=='adult'||ctx.ownRequestsOnly||ctx.viewGrantId||shop.phase==='closed'||
     (shop.shopper_id!==ctx.member.member_id&&!ctx.member.can_contribute)||(await repo.bootstrap(ctx)).grantId)throw unavailable();
}
async function currentLastCall(ctx:Context,shop:Shop) {
  const managed=shop.shopper_id===ctx.member.member_id;
  const row=(await ctx.db.query(`SELECT c.revision,c.cutoff_at,r.response,r.muted FROM ritc.pickup_last_call c
    LEFT JOIN ritc.pickup_last_call_recipient r ON (r.household_id,r.shop_id)=(c.household_id,c.shop_id) AND r.member_id=$3
    WHERE c.household_id=$1 AND c.shop_id=$2 AND c.authority_epoch=$4 AND ($5 OR (r.member_id IS NOT NULL AND ritc.shared_content_visible(c.household_id,$3,c.sender_id,'lastCall',c.shop_id,1,c.revision)))`,
    [ctx.householdId,shop.shop_id,ctx.member.member_id,shop.authority_epoch,managed])).rows[0];
  return {managed,revision:Number(row?.revision??0),...(row?{cutoffAt:row.cutoff_at.toISOString() as string}:{}),
    responded:Boolean(row?.response),muted:Boolean(row?.muted),nextShopOnly:shop.phase!=='draft'||Boolean(row&&row.cutoff_at<=ctx.now)};
}
export async function lastCallRoute(repo:HouseholdRepository,ctx:Context,shop:Shop,tail:string,method:string,body:unknown) {
  if(!repo.options.adultLastCall)throw unavailable();
  await adultScope(repo,ctx,shop);
  const current=await currentLastCall(ctx,shop);
  if(method==='GET'&&tail==='/last-call')return current;
  if(method!=='POST')throw unavailable();
  const h=ctx.householdId,s=shop.shop_id,m=ctx.member.member_id;
  if(tail==='/last-call'){
    repo.requireShopper(ctx,shop);repo.requireDraft(shop);
    const input=lastCall.parse(body),cutoff=new Date(input.cutoffAt);
    if(input.authorityEpoch!==shop.authority_epoch)throw stale();
    if(current.cutoffAt===cutoff.toISOString())return current;
    if(current.revision!==input.expectedRevision)throw stale();
    if(cutoff<=ctx.now||cutoff.getTime()>ctx.now.getTime()+7*86400000)
      throw new ServiceError(422,'invalid_cutoff','Choose a future cutoff within seven days.');
    await checkPublishingMember(ctx);
    await ctx.db.query(`INSERT INTO ritc.pickup_last_call(household_id,shop_id,sender_id,authority_epoch,revision,cutoff_at)
      VALUES($1,$2,$3,$4,1,$5) ON CONFLICT(household_id,shop_id) DO UPDATE SET revision=ritc.pickup_last_call.revision+1,cutoff_at=excluded.cutoff_at`,
      [h,s,m,shop.authority_epoch,cutoff]);
    if(current.revision===0)await ctx.db.query(`INSERT INTO ritc.pickup_last_call_recipient(household_id,shop_id,member_id)
      SELECT household_id,$2,member_id FROM ritc.member WHERE household_id=$1 AND member_id<>$3 AND state='active' AND kind='adult' AND can_contribute`,[h,s,m]);
  }else if(tail==='/last-call/response'){
    const input=respond.parse(body);
    if(current.managed||current.revision===0)throw unavailable();
    if(input.revision!==current.revision)throw stale();
    if(input.action==='pass')await ctx.db.query(`UPDATE ritc.pickup_last_call_recipient SET response=coalesce(response,'pass') WHERE household_id=$1 AND shop_id=$2 AND member_id=$3`,[h,s,m]);
    else await ctx.db.query('UPDATE ritc.pickup_last_call_recipient SET muted=$4 WHERE household_id=$1 AND shop_id=$2 AND member_id=$3',[h,s,m,input.action==='mute']);
  }else throw unavailable();
  return currentLastCall(ctx,shop);
}

// request.send already serializes all commands against the household and replays the committed receipt.
export async function respondWithRequest(ctx:Context,shop:Shop) {
  if(ctx.member.kind!=='adult'||shop.shopper_id===ctx.member.member_id)return false;
  const row=(await ctx.db.query(`UPDATE ritc.pickup_last_call_recipient r SET response='sent'
    FROM ritc.pickup_last_call c WHERE (c.household_id,c.shop_id)=(r.household_id,r.shop_id)
    AND r.household_id=$1 AND r.shop_id=$2 AND r.member_id=$3 AND c.authority_epoch=$4 AND ritc.shared_content_visible(c.household_id,$3,c.sender_id,'lastCall',c.shop_id,1,c.revision) RETURNING c.cutoff_at<=$5 AS late`,
    [ctx.householdId,shop.shop_id,ctx.member.member_id,shop.authority_epoch,ctx.now])).rows[0];
  return row?.late===true;
}

const short=z.string().trim().min(1).max(80);
const crop=z.object({width:z.int().min(8).max(192),height:z.int().min(8).max(192),pixels:z.string().max(147456)}).strict()
  .refine(({width,height,pixels})=>{
    const raw=Buffer.from(pixels,'base64');
    return raw.length===width*height*3&&raw.toString('base64')===pixels;
  });
const reference=z.object({brand:short.optional(),size:short.optional(),barcode:z.string().regex(/^[0-9]{8,14}$/).optional(),
  description:z.string().trim().min(1).max(240),crop:crop.optional()}).strict();
const publish=z.object({expectedRevision:revision,requestRevision:revision,authorityEpoch:revision,recipientId:uuid,clientKey:uuid,
  consent:z.literal(true),reference}).strict();
const remove=z.object({expectedRevision:revision,clientKey:uuid}).strict();
const moderate=z.discriminatedUnion('action',[
  z.object({expectedRevision:revision,clientKey:uuid,action:z.literal('block')}).strict(),
  z.object({expectedRevision:revision,clientKey:uuid,action:z.literal('report'),reason:z.enum(['harassment','unsafe','other'])}).strict(),
]);

interface ProductReferenceRow {
  revision:number; publication_id:string; client_key:string; fingerprint:string; expires_at:Date; reported:boolean;
  brand:string|null; package_size:string|null; barcode:string|null; description:string|null;
  crop_width:number|null; crop_height:number|null; pixels:Buffer|null; media_status:'pending'|'approved'|'rejected'|null;
}
export async function productReferenceRoute(repo:HouseholdRepository,ctx:Context,shop:Shop,id:string,tail:string|undefined,method:string,body:unknown){
  const days=repo.options.adultProductReferenceDays;
  if(!days||!repo.options.sharedContentSafety||!repo.options.moderationRetentionDays)throw unavailable();
  await adultScope(repo,ctx,shop);
  const h=ctx.householdId,viewer=ctx.member.member_id;
  // A block can hide the very request that produced the receipt. Recover only its status,
  // after rechecking the submitting shopper, household, shop and authority generation.
  const moderation=method==='POST'&&tail==='moderation'?moderate.parse(body):undefined;
  const moderationDigest=moderation?digest({shop:shop.shop_id,id,input:moderation,epoch:shop.authority_epoch}):undefined;
  if(moderation){
    repo.requireShopper(ctx,shop);
    const prior=(await ctx.db.query('SELECT fingerprint,status,expires_at FROM ritc.moderation_receipt WHERE household_id=$1 AND reporter_id=$2 AND client_key=$3',[h,viewer,moderation.clientKey])).rows[0];
    if(prior){if(prior.fingerprint!==moderationDigest||prior.expires_at<=ctx.now)throw stale();return {status:prior.status};}
  }
  const request=await repo.request(ctx,id,shop.shop_id);
  const own=request.author_id===viewer;
  if(request.author_kind!=='adult'||!request.author_active||request.author_id===shop.shopper_id||
    (!own&&viewer!==shop.shopper_id)||request.carried_forward||request.from_previous_shop||
    !['pending','clarified','added'].includes(request.status))throw unavailable();
  const people=(await ctx.db.query(`SELECT recipient.alias FROM ritc.member author JOIN ritc.member recipient USING(household_id)
    WHERE author.household_id=$1 AND author.member_id=$2 AND author.state='active' AND author.can_contribute AND author.kind='adult'
    AND recipient.member_id=$3 AND recipient.state='active' AND recipient.kind='adult'`,[h,request.author_id,shop.shopper_id])).rows[0];
  if(!people)throw unavailable();
  const read=async()=> (await ctx.db.query<ProductReferenceRow>(`SELECT revision,publication_id,client_key,fingerprint,expires_at,reported,
    brand,package_size,barcode,description,crop_width,crop_height,media_status,
    CASE WHEN $6 AND ($7 OR (media_status='approved' AND NOT reported)) AND expires_at>$8 THEN pixels END AS pixels
    FROM ritc.adult_product_reference WHERE household_id=$1 AND request_id=$2
    AND recipient_id=$3 AND author_id=$4 AND authority_epoch=$5`,[h,id,shop.shopper_id,request.author_id,shop.authority_epoch,
    Boolean(repo.options.adultProductReferenceMedia),own,ctx.now])).rows[0];
  const visible=async(row:ProductReferenceRow|undefined)=> row?.description && row.expires_at>ctx.now &&
    (own||(!row.reported&&(await ctx.db.query('SELECT ritc.shared_content_visible($1,$2,$3,$4,$5,$6,$6) AS allowed',
      [h,viewer,request.author_id,'productReference',row.publication_id,row.revision])).rows[0]?.allowed));
  const result=async()=>{
    const row=await read(),show=await visible(row);
    const media=show&&repo.options.adultProductReferenceMedia&&(own||row!.media_status==='approved');
    return {own,requestRevision:request.revision,authorityEpoch:shop.authority_epoch,recipientId:shop.shopper_id,recipientLabel:String(people.alias),
      revision:own||show?Number(row?.revision??0):0,...(show?{expiresAt:row!.expires_at.toISOString(),reference:{
        description:String(row!.description),...(row!.brand?{brand:row!.brand}:{}),...(row!.package_size?{size:row!.package_size}:{}),
        ...(row!.barcode?{barcode:row!.barcode}:{}),...(media&&row!.media_status?{mediaStatus:row!.media_status}:{}),
        ...(media&&row!.pixels?{crop:{width:row!.crop_width,height:row!.crop_height,pixels:row!.pixels.toString('base64')}}:{})}}:{})};
  };
  if(method==='GET'&&!tail)return result();
  if(method!=='POST')throw unavailable();
  const row=await read(),version=Number(row?.revision??0);
  if(tail==='moderation'){
    if(own)throw unavailable();
    const input=moderation!;
    if(!await visible(row))throw unavailable();
    if(version!==input.expectedRevision)throw stale();
    const receipt=randomUUID(),expires=new Date(ctx.now.getTime()+repo.options.moderationRetentionDays*86400000);
    if(input.action==='block')await ctx.db.query('INSERT INTO ritc.moderation_block(household_id,viewer_id,author_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING',[h,viewer,request.author_id]);
    else {
      await ctx.db.query(`INSERT INTO ritc.moderation_case(case_id,household_id,reporter_id,author_id,source_kind,source_id,source_revision,source_field,reason,created_at,expires_at)
        VALUES($1,$2,$3,$4,'productReference',$5,$6,'reference',$7,$8,$9)`,[receipt,h,viewer,request.author_id,row!.publication_id,version,input.reason,ctx.now,expires]);
      await ctx.db.query(`UPDATE ritc.adult_product_reference SET reported=true,
        media_status=CASE WHEN media_status='approved' THEN 'pending' ELSE media_status END WHERE household_id=$1 AND request_id=$2`,[h,id]);
    }
    const status=input.action==='block'?'blocked':'received';
    await ctx.db.query('INSERT INTO ritc.moderation_receipt(household_id,reporter_id,client_key,fingerprint,receipt_id,status,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)',[h,viewer,input.clientKey,moderationDigest,receipt,status,expires]);
    return {status};
  }
  if(!own|| (tail && tail!=='remove'))throw unavailable();
  const publication=tail==='remove'?undefined:publish.parse(body);
  const input=publication??remove.parse(body),fingerprint=digest({tail:tail??'publish',input});
  if(row?.client_key===input.clientKey){if(row.fingerprint!==fingerprint)throw stale();return result();}
  if(version!==input.expectedRevision)throw stale();
  if(!publication){
    if(!row)throw unavailable();
    await ctx.db.query(`UPDATE ritc.adult_product_reference SET revision=revision+1,description=NULL,brand=NULL,package_size=NULL,
      barcode=NULL,pixels=NULL,crop_width=NULL,crop_height=NULL,media_status=NULL,media_reviewed_at=NULL,media_reviewed_by=NULL,fingerprint=$3,client_key=$4 WHERE household_id=$1 AND request_id=$2`,[h,id,fingerprint,input.clientKey]);
    return result();
  }
  if(publication.authorityEpoch!==shop.authority_epoch||publication.recipientId!==shop.shopper_id||publication.requestRevision!==request.revision)throw stale();
  const r=publication.reference;
  if(r.crop&&!repo.options.adultProductReferenceMedia)throw unavailable();
  await checkPublishingMember(ctx);
  reviewSharedWording(r.description,r.brand??null,r.size??null);
  if(r.crop){
    const uploads=(await ctx.db.query('SELECT count(*)::int AS n FROM ritc.adult_product_reference WHERE household_id=$1 AND author_id=$2 AND request_id<>$3 AND pixels IS NOT NULL AND expires_at>$4',[h,viewer,id,ctx.now])).rows[0];
    if(uploads.n>=8)throw new ServiceError(429,'media_limit','Remove an earlier image or share text alone.');
  }
  const expiry=new Date(ctx.now.getTime()+days*86400000);
  await ctx.db.query(`INSERT INTO ritc.adult_product_reference(household_id,request_id,shop_id,author_id,recipient_id,authority_epoch,revision,
      publication_id,client_key,fingerprint,brand,package_size,barcode,description,crop_width,crop_height,pixels,media_status,expires_at,created_at)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20)
    ON CONFLICT(household_id,request_id) DO UPDATE SET revision=excluded.revision,publication_id=excluded.publication_id,
      client_key=excluded.client_key,fingerprint=excluded.fingerprint,brand=excluded.brand,package_size=excluded.package_size,
      barcode=excluded.barcode,description=excluded.description,crop_width=excluded.crop_width,crop_height=excluded.crop_height,
      pixels=excluded.pixels,media_status=excluded.media_status,expires_at=excluded.expires_at,created_at=excluded.created_at,reported=false,media_reviewed_at=NULL,media_reviewed_by=NULL`,
    [h,id,shop.shop_id,viewer,shop.shopper_id,shop.authority_epoch,version+1,randomUUID(),input.clientKey,fingerprint,
     r.brand??null,r.size??null,r.barcode??null,r.description,r.crop?.width??null,r.crop?.height??null,r.crop?Buffer.from(r.crop.pixels,'base64'):null,
     r.crop?'pending':null,expiry,ctx.now]);
  return result();
}
