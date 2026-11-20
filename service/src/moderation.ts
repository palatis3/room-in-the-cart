import {tripSubstitution} from './trip-substitutions.js';
import {pickingWording} from './shared-picking.js';
import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import {digest} from './database.js';
import {HouseholdLifecycle} from './lifecycle.js';
import type {Context,HouseholdRepository} from './repository.js';
import {ServiceError,unavailable} from './errors.js';

const uuid=z.string().uuid().toLowerCase();
const reference={id:uuid,revision:z.number().int().min(1).max(2147483647)};
const source=z.discriminatedUnion('kind',[
  z.object({...reference,kind:z.literal('request'),field:z.enum(['item','amount'])}).strict(),
  z.object({...reference,kind:z.literal('clarification'),field:z.literal('question')}).strict(),
  z.object({...reference,kind:z.literal('instruction'),field:z.enum(['shopLabel','label','amount','unit','action']),index:z.number().int().min(0).max(199).optional()}).strict(),
  z.object({...reference,kind:z.literal('suggestion'),field:z.literal('correction')}).strict(),
  z.object({...reference,kind:z.literal('substitution'),field:z.literal('alternative')}).strict(),
  z.object({...reference,kind:z.literal('pickingRow'),field:z.literal('label')}).strict(),
  z.object({...reference,kind:z.literal('cookCopy'),field:z.literal('text')}).strict(),
]).refine(value=>value.kind!=='instruction'||(value.field==='shopLabel')===(value.index===undefined));
export const moderationAction=z.discriminatedUnion('action',[
  z.object({clientKey:uuid,action:z.literal('report'),source,reason:z.enum(['harassment','unsafe','other']),text:z.string().min(1).max(1000).optional()}).strict(),
  z.object({clientKey:uuid,action:z.literal('block'),source}).strict(),
]);
type Source=z.infer<typeof source>;
interface Wording {author:string|null; revision:number; first:number; text:string|null}

export function moderationConfiguration(env:NodeJS.ProcessEnv) {
  if(env.SHARED_CONTENT_SAFETY_ENABLED!=='true')return {};
  const days=Number(env.MODERATION_RETENTION_DAYS);
  if(!env.MODERATION_OPERATOR_APPROVAL?.trim()||!Number.isInteger(days)||days<1||days>365)
    throw Error('Shared content safety requires an operator approval reference and an approved retention interval.');
  return {sharedContentSafety:true,moderationRetentionDays:days};
}

async function currentWording(repo:HouseholdRepository,ctx:Context,ref:Source):Promise<Wording> {
  const h=ctx.householdId;
  if(ref.kind==='pickingRow')return pickingWording(repo,ctx,ref.id);
  if(ref.kind==='substitution'){
    const record=(await ctx.db.query('SELECT shop_id,author_id FROM ritc.trip_substitution WHERE household_id=$1 AND request_id=$2',[h,ref.id])).rows[0];
    if(!record)throw unavailable();
    const result=await tripSubstitution(repo,ctx,await repo.shop(ctx,record.shop_id),ref.id,'GET',undefined);
    return {author:record.author_id,revision:result.revision,first:result.revision,text:result.alternative};
  }
  if(ref.kind==='request'||ref.kind==='clarification'){
    if(ctx.viewGrantId)throw unavailable();
    const column=(await ctx.db.query('SELECT shop_id,author_id,wording_revision,clarification_author_id,clarification_revision FROM ritc.request WHERE household_id=$1 AND request_id=$2',[h,ref.id])).rows[0];
    if(!column)throw unavailable();
    const shop=await repo.shop(ctx,column.shop_id);
    const own=column.author_id===ctx.member.member_id;
    if(!own)repo.requireShopper(ctx,shop);
    const r=await repo.request(ctx,ref.id,shop.shop_id,own);
    if(ref.kind==='clarification')return {author:column.clarification_author_id,first:column.clarification_revision??1,revision:r.revision,text:r.clarification};
    return {author:r.author_id,first:column.wording_revision,revision:r.revision,text:ref.field==='item'?r.original_item:r.own_quantity};
  }
  if(ctx.member.kind!=='adult'||ctx.ownRequestsOnly)throw unavailable();
  if(ref.kind==='cookCopy'){
    const row=(await ctx.db.query('SELECT shop_id,version,actor_id,reviewed_text FROM ritc.dated_cook_copy WHERE household_id=$1 AND copy_id=$2',[h,ref.id])).rows[0];
    if(!row)throw unavailable();
    const shop=await repo.shop(ctx,row.shop_id);
    repo.requireShopper(ctx,shop);
    if(shop.placed_revision===null || !['placed','closed'].includes(shop.phase))throw unavailable();
    return {author:row.actor_id,first:row.version,revision:row.version,text:row.reviewed_text};
  }
  const grants=new HouseholdLifecycle(repo);
  if(ref.kind==='instruction'){
    const grant=await grants.grant(ctx,ref.id);
    if(ctx.selectedShopId&&ctx.selectedShopId!==grant.shop_id)throw unavailable();
    const text=ref.field==='shopLabel'?grant.projection.shopLabel:grant.projection.items[ref.index!]?.[ref.field];
    return {author:grant.projection_author_id,first:grant.projection_wording_revision,revision:grant.revision,text:text??null};
  }
  const proposal=(await ctx.db.query('SELECT grant_id,actor_id,revision,correction FROM ritc.helper_proposal WHERE household_id=$1 AND proposal_id=$2',[h,ref.id])).rows[0];
  if(!proposal)throw unavailable();
  await grants.grant(ctx,proposal.grant_id,true);
  return {author:proposal.actor_id,first:1,revision:proposal.revision,text:proposal.correction};
}

export async function recordModerationAction(repo:HouseholdRepository,ctx:Context,input:z.infer<typeof moderationAction>) {
  const days=repo.options.moderationRetentionDays;
  if(!repo.options.sharedContentSafety||!days)throw new ServiceError(503,'moderation_unavailable','Contact support.');
  const h=ctx.householdId,viewer=ctx.member.member_id;
  const fingerprint=digest({input,grant:ctx.viewGrantId??null,shop:ctx.selectedShopId??null,own:ctx.ownRequestsOnly??false});
  const old=(await ctx.db.query('SELECT fingerprint,status,receipt_id,expires_at FROM ritc.moderation_receipt WHERE household_id=$1 AND reporter_id=$2 AND client_key=$3',[h,viewer,input.clientKey])).rows[0];
  if(old){
    if(old.expires_at<=ctx.now)throw new ServiceError(409,'stale_base','Review a new action.');
    if(old.fingerprint!==fingerprint)throw new ServiceError(409,'key_reused','Review a new action.');
    return {receiptId:old.receipt_id as string,status:old.status as string};
  }
  const ref=input.source;
  const wording=await currentWording(repo,ctx,ref);
  if(!wording.text||wording.author===viewer)throw unavailable();
  const visible=await ctx.db.query('SELECT ritc.shared_content_visible($1,$2,$3,$4,$5,$6,$7) AS allowed',
    [h,viewer,wording.author,ref.kind,ref.id,wording.first,wording.revision]);
  if(!visible.rows[0]?.allowed)throw unavailable();
  if(wording.revision!==ref.revision)throw new ServiceError(409,'stale_base','Review the current wording.');
  const receiptId=randomUUID(),status=input.action==='block'?'blocked':'received';
  const expires=new Date(ctx.now.getTime()+days*86400000);
  if(input.action==='block'){
    if(!wording.author)throw new ServiceError(409,'sender_unavailable','The original sender is unknown. You can report the wording.');
    await ctx.db.query('INSERT INTO ritc.moderation_block(household_id,viewer_id,author_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING',[h,viewer,wording.author]);
  }else{
    if(input.text!==undefined && !(ref.kind==='cookCopy'?wording.text.includes(input.text):wording.text===input.text))
      throw new ServiceError(409,'stale_base','Review the exact wording you want to include.');
    await ctx.db.query(`INSERT INTO ritc.moderation_case(case_id,household_id,reporter_id,author_id,source_kind,source_id,
      source_revision,source_field,field_index,reason,excerpt,created_at,expires_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
      [receiptId,h,viewer,wording.author,ref.kind,ref.id,ref.revision,ref.field,ref.kind==='instruction'?ref.index??null:null,input.reason,input.text??null,ctx.now,expires]);
  }
  await ctx.db.query(`INSERT INTO ritc.moderation_receipt(household_id,reporter_id,client_key,fingerprint,receipt_id,status,expires_at)
    VALUES($1,$2,$3,$4,$5,$6,$7)`,[h,viewer,input.clientKey,fingerprint,receiptId,status,expires]);
  return {receiptId,status};
}
