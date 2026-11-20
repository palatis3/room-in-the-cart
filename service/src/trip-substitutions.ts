import {z} from 'zod';
import {digest} from './database.js';
import type {Context, HouseholdRepository, RequestRow, Shop} from './repository.js';
import type {Decision} from './contracts.js';
import type {BasketLine} from '../../shared/contracts/service-v1.js';
import {ServiceError, unavailable} from './errors.js';
import {checkPublishingMember, reviewSharedWording} from './shared-content-filter.js';

export interface TripOptions {tripSubstitutions?:boolean; sharedPicking?:boolean}
export function tripConfiguration(env:NodeJS.ProcessEnv):TripOptions {
  const tripSubstitutions=env.TRIP_SUBSTITUTIONS_ENABLED==='true', sharedPicking=env.SHARED_PICKING_ENABLED==='true';
  if((tripSubstitutions||sharedPicking)&&env.SHARED_CONTENT_SAFETY_ENABLED!=='true')
    throw Error('Trip coordination requires shared content safety.');
  return {tripSubstitutions,sharedPicking};
}

export const tripUUID=z.uuid().toLowerCase();
export const tripRevision=z.int().min(0).max(2147483646);
export const staleTrip=()=>new ServiceError(409,'stale_base','Refresh the shared trip and review the current result.');
export const reusedTrip=()=>new ServiceError(409,'key_reused','Review a new action with a new operation ID.');
export async function adultTrip(repo:HouseholdRepository,ctx:Context,shop:Shop) {
  if(!repo.options.sharedContentSafety||!repo.options.moderationRetentionDays||ctx.ownRequestsOnly||ctx.viewGrantId||
    ctx.member.kind!=='adult'||!['draft','frozen'].includes(shop.phase)||
    (ctx.member.member_id!==shop.shopper_id&&!ctx.member.can_contribute)||(await repo.bootstrap(ctx)).grantId)throw unavailable();
}

const write=z.object({clientKey:tripUUID,expectedRevision:tripRevision,requestRevision:tripRevision,
  authorityEpoch:tripRevision,choice:z.enum(['exact','alternative','skip']),alternative:z.string().trim().min(1).max(240).refine(text=>!text.includes('\0')).optional()})
  .strict().refine(x=>(x.choice==='alternative')===(x.alternative!==undefined));

function originalAdultRequest(shop:Shop,r:RequestRow) {
  return r.author_id!==shop.shopper_id&&r.author_kind==='adult'&&r.route==='current'&&
    !r.carried_forward&&!r.from_previous_shop&&['pending','clarified','added'].includes(r.status);
}

async function eligible(ctx:Context,shop:Shop,r:RequestRow) {
  if(!originalAdultRequest(shop,r)||!r.author_active)return false;
  return Boolean((await ctx.db.query(`SELECT 1 FROM ritc.member a JOIN ritc.member s USING(household_id)
    WHERE a.household_id=$1 AND a.member_id=$2 AND a.state='active' AND a.kind='adult' AND a.can_contribute
     AND s.member_id=$3 AND s.state='active' AND s.kind='adult'
     AND ritc.shared_content_visible($1,$3,$2,'request',$4,(SELECT wording_revision FROM ritc.request WHERE household_id=$1 AND request_id=$4),$5)
     AND ritc.shared_content_visible($1,$2,$3,'trip',$4,1,1)`,
    [ctx.householdId,r.author_id,shop.shopper_id,r.request_id,r.revision])).rowCount);
}

async function savedChoice(ctx:Context,shop:Shop,r:RequestRow) {
  return (await ctx.db.query(`SELECT revision,choice,alternative,client_key,fingerprint,
    ritc.shared_content_visible(household_id,shopper_id,author_id,'substitution',request_id,revision,revision) AS visible
    FROM ritc.trip_substitution WHERE household_id=$1 AND shop_id=$2 AND request_id=$3 AND author_id=$4 AND shopper_id=$5 AND authority_epoch=$6`,
    [ctx.householdId,shop.shop_id,r.request_id,r.author_id,shop.shopper_id,shop.authority_epoch])).rows[0];
}

export async function tripSubstitution(repo:HouseholdRepository,ctx:Context,shop:Shop,requestId:string,method:string,body:unknown) {
  if(!repo.options.tripSubstitutions)throw unavailable();
  await adultTrip(repo,ctx,shop);
  const r=await repo.request(ctx,requestId,shop.shop_id),own=r.author_id===ctx.member.member_id;
  if((!own&&shop.shopper_id!==ctx.member.member_id)||!await eligible(ctx,shop,r))throw unavailable();
  const read=async()=>{
    const row=await savedChoice(ctx,shop,r),show=own||row?.visible;
    return {requestId:r.request_id,originalItem:r.original_item,own,requestRevision:r.revision,authorityEpoch:shop.authority_epoch,
      revision:show?Number(row?.revision??0):0,choice:show?(row?.choice??'undecided'):'undecided',alternative:show?(row?.alternative??null):null};
  };
  if(method==='GET')return read();
  if(method!=='POST'||!own)throw unavailable();
  const input=write.parse(body);
  if(input.authorityEpoch!==shop.authority_epoch||input.requestRevision!==r.revision)throw staleTrip();
  await checkPublishingMember(ctx);
  if(input.alternative)reviewSharedWording(input.alternative);
  const row=await savedChoice(ctx,shop,r),fingerprint=digest({input,device:ctx.deviceId});
  if(row?.client_key===input.clientKey){if(row.fingerprint!==fingerprint)throw reusedTrip();return read();}
  if((row?.revision??0)!==input.expectedRevision)throw staleTrip();
  if(row?.choice===input.choice&&row.alternative===(input.alternative??null))return read();
  await ctx.db.query(`INSERT INTO ritc.trip_substitution(household_id,request_id,shop_id,author_id,shopper_id,authority_epoch,revision,choice,alternative,client_key,fingerprint)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
    ON CONFLICT(household_id,request_id) DO UPDATE SET revision=excluded.revision,choice=excluded.choice,
     alternative=excluded.alternative,client_key=excluded.client_key,fingerprint=excluded.fingerprint`,
    [ctx.householdId,r.request_id,shop.shop_id,r.author_id,shop.shopper_id,shop.authority_epoch,input.expectedRevision+1,input.choice,
      input.alternative??null,input.clientKey,fingerprint]);
  return read();
}

export async function checkLinkedPackChanges(repo:HouseholdRepository,ctx:Context,shop:Shop,lines:BasketLine[]) {
  if(!repo.options.tripSubstitutions||!repo.options.sharedContentSafety||!repo.options.moderationRetentionDays)return;
  const labels=new Map(lines.map(line=>[line.lineId,line.originalItem]));
  const linked=await ctx.db.query(`SELECT l.request_id,l.line_id,b.original_item FROM ritc.request_link l
    JOIN ritc.basket_line b USING(household_id,shop_id,line_id)
    JOIN ritc.request r ON (r.household_id,r.request_id)=(l.household_id,l.request_id)
    JOIN ritc.member a ON (a.household_id,a.member_id)=(r.household_id,r.author_id)
    WHERE l.household_id=$1 AND l.shop_id=$2 AND a.kind='adult' AND r.author_id<>$3`,
    [ctx.householdId,shop.shop_id,shop.shopper_id]);
  for(const row of linked.rows){
    const label=labels.get(row.line_id);
    if(label!==undefined&&label!==row.original_item)
      await decisionPermission(repo,ctx,shop,await repo.request(ctx,row.request_id,shop.shop_id),{choice:'link',lineId:row.line_id,promote:false},lines);
  }
}

// The fingerprint already contains the exact line and offer. Include a revision only for a live decision
// so established previews of unanswered requests remain compatible.
export async function decisionPermission(repo:HouseholdRepository,ctx:Context,shop:Shop,r:RequestRow,decision:Decision,lines:BasketLine[]) {
  if(!repo.options.tripSubstitutions||!repo.options.sharedContentSafety||!repo.options.moderationRetentionDays||
    (decision.choice!=='add'&&decision.choice!=='link'))return {};
  if(!originalAdultRequest(shop,r))return {};
  if(!await eligible(ctx,shop,r))throw unavailable();
  const row=await savedChoice(ctx,shop,r);
  if(row?.choice&&!row.visible)throw unavailable();
  const label=decision.choice==='add'?decision.line.originalItem:lines.find(line=>line.lineId===decision.lineId)?.originalItem;
  if(label!==r.original_item&&!(row?.choice==='alternative'&&row.alternative===label))
    throw new ServiceError(409,'substitution_changed','Review the original pack and the requester’s current choice.');
  return row?.choice?{substitutionRevision:Number(row.revision)}:{};
}
