import { carryRequest, deferredRequests, reauthorizeCarry } from './deferred-requests.js';
import type {BillingService} from './billing/service.js';
import {recordCurrentDelivery,recordCurrentPantry} from './shared-recovery-basis.js';
import {loadRecoveryPublication,recordSharedRecovery} from './shared-recovery-publication.js';
import { sharedMealSchema, moveSharedMeal, preserveProtectedMeal } from './shared-meal-planning.js';
import { cookCopyStillExists, recordCookCopy } from './cook-copy.js';
import { isPantryCommand, pantryOperationExists } from './pantry-lots.js';
import { consumeSharedMealChange } from './shared-meal-changes.js';
import { randomBytes, randomUUID } from 'node:crypto';
import type { OwnRequest, ShopperReceipt, RequestPurchaseOutcome, RequestPreview, QuoteBasis, BasketLine } from '../../shared/contracts/service-v1.js';
import type { VerifiedIdentity,SessionStatusVerifier } from './auth.js';
import { type Database,type Transaction,digest,tokenHash } from './database.js';
import { accessEnded,unavailable,invalid,refresh,ServiceError } from './errors.js';
import { type Envelope,type Decision,type PreviewInput,bodySchemas,decisionSchema } from './contracts.js';
import { checkout } from './checkout.js';
export interface AuthContext { identity:VerifiedIdentity; deviceToken?:string; trustedDeviceId?:string;viewGrantId?:string;selectedShopId?:string;historicalReportShopId?:string }
export interface Member { member_id:string; kind:'adult'|'child'; organizer:boolean; can_contribute:boolean; alias:string; state:string }
export interface Context { db:Transaction; householdId:string; member:Member; deviceId:string; now:Date;viewGrantId?:string;selectedShopId?:string }
export interface Shop { household_id:string;shop_id:string;shopper_id:string;authority_epoch:number;revision:number;phase:string;quote:QuoteBasis;frozen_revision:number|null;placed_revision:number|null;supply_revision:number;recovery_revision?:number;store_basis_revision?:number|null;store_review_required?:boolean }
interface RequestRow { carried_forward?:boolean;from_previous_shop?:boolean; purchase_outcome?:RequestPurchaseOutcome|null;request_id:string;author_id:string;shop_id:string;original_item:string;own_quantity:string|null;revision:number;authored_at:Date;received_at:Date;route:'current'|'next';status:OwnRequest['status'];clarification:string|null;followup_to:string|null }
const editable=(r:RequestRow)=>!r.carried_forward && (r.status==='pending'||r.status==='clarified');
export function ownRequest(r:RequestRow):OwnRequest {
  return {requestId:r.request_id,shopId:r.shop_id,revision:r.revision,originalItem:r.original_item,ownQuantity:r.own_quantity,
    ...(r.status==='added' && (r.purchase_outcome==='bought' || r.purchase_outcome==='notBought')?{purchaseOutcome:r.purchase_outcome}:{}),
    authoredAt:r.authored_at.toISOString(),receivedAt:r.received_at.toISOString(),route:r.route,status:r.status,
    ...(r.carried_forward?{carriedForward:true}:{}),...(r.from_previous_shop?{fromPreviousShop:true}:{}),
    ownActionAllowed:editable(r),clarification:r.clarification,followupTo:r.followup_to};
}
export class HouseholdRepository {
  constructor(readonly pool:Database,readonly options:{allowChildNetwork:boolean;noticeVersion:string;sessionStatus?:SessionStatusVerifier}) {}
  async assertIdentityAllowed(db:Transaction,issuer:string,subject:string){
    const lock=(await db.query("SELECT pg_try_advisory_xact_lock_shared(hashtextextended($1,0)) AS acquired",[tokenHash(issuer+'\n'+subject)])).rows[0]?.acquired;
    if(!lock)throw new ServiceError(409,'account_action_pending','Wait for the pending account action to finish.');
    if((await db.query('SELECT ritc.identity_blocked($1,$2) AS blocked',[issuer,subject])).rows[0]?.blocked)throw new ServiceError(401,'session_needed','Account deletion has revoked this identity.');
  }
  async assertSession(db:Transaction,identity:VerifiedIdentity,now:Date) {
    if(!this.options.sessionStatus||identity.expiresAt<=now)throw new ServiceError(401,'session_needed','Authenticate with the configured live session provider.');
    await this.assertIdentityAllowed(db,identity.issuer,identity.subject);
    await this.options.sessionStatus.assertLive(db,identity,now);
  }
  async transaction<T>(householdId:string,fn:(db:Transaction,now:Date)=>Promise<T>):Promise<T> {
    const db=await this.pool.connect();
    try {
      await db.query('BEGIN');
      await db.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='3s'");
      await db.query("SELECT set_config('app.household_id',$1,true)",[householdId]);
      const house=await db.query('SELECT household_id FROM ritc.household WHERE household_id=$1 FOR UPDATE',[householdId]);
      if(!house.rowCount)throw unavailable();
      const now=(await db.query<{now:Date}>('SELECT clock_timestamp() AS now')).rows[0]!.now;
      const result=await fn(db,now);
      await db.query('COMMIT');return result;
    }catch(error) {await db.query('ROLLBACK');throw error;}finally{db.release();}
  }
  async member(db:Transaction,householdId:string,identity:VerifiedIdentity):Promise<Member> {
    const member=(await db.query<Member>('SELECT member_id,kind,organizer,can_contribute,alias,state FROM ritc.member WHERE household_id=$1 AND issuer=$2 AND subject=$3',[householdId,identity.issuer,identity.subject])).rows[0];
    if(!member)throw unavailable();
    if(member.state!=='active')throw accessEnded();
    await this.consent(db,householdId,member);
    return member;
  }
  async consent(db:Transaction,householdId:string,member:Member):Promise<void> {
    if(member.kind==='adult')return;
    if(!this.options.allowChildNetwork)throw accessEnded();
    const result=await db.query(`SELECT 1 FROM ritc.consent c
      JOIN ritc.guardian_relationship r USING(household_id,child_id,guardian_id)
      JOIN ritc.member g ON g.household_id=c.household_id AND g.member_id=c.guardian_id
      WHERE c.household_id=$1 AND c.child_id=$2 AND c.revoked_at IS NULL AND r.revoked_at IS NULL
      AND c.notice_version=$3 AND g.kind='adult' AND g.state='active' LIMIT 1`,[householdId,member.member_id,this.options.noticeVersion]);
    if(!result.rowCount)throw accessEnded();
  }
  async authorized<T>(householdId:string,auth:AuthContext,fn:(ctx:Context)=>Promise<T>):Promise<T> {
    return this.transaction(householdId,async(db,now)=>{
      await this.assertSession(db,auth.identity,now);
      const member=await this.member(db,householdId,auth.identity);
      const device=(await db.query<{device_id:string}>(`SELECT device_id FROM ritc.device WHERE household_id=$1 AND member_id=$2
        AND session_id=$3 AND revoked_at IS NULL AND ${auth.trustedDeviceId?'device_id=$4':'token_hash=$4'}`,
        [householdId,member.member_id,auth.identity.sessionId,auth.trustedDeviceId??tokenHash(auth.deviceToken??'')])).rows[0];
      if(!device)throw accessEnded();
      if(member.kind==='child'){const generation=await db.query(`SELECT 1 FROM ritc.device d JOIN ritc.consent c ON c.household_id=d.household_id AND c.consent_id=d.guardian_consent_id JOIN ritc.guardian_enrollment e ON e.household_id=c.household_id AND e.consent_id=c.consent_id WHERE d.household_id=$1 AND d.device_id=$2 AND c.child_id=$3 AND c.revoked_at IS NULL AND e.state='active'`,[householdId,device.device_id,member.member_id]);if(!generation.rowCount)throw accessEnded();}
      if(auth.viewGrantId){
        const grant=await db.query(`SELECT 1 FROM ritc.view_grant g JOIN ritc.member creator ON creator.household_id=g.household_id AND creator.member_id=g.created_by
          WHERE g.household_id=$1 AND g.grant_id=$2 AND g.recipient_id=$3 AND g.revoked_at IS NULL AND g.expires_at>$4 AND creator.state='active'`,[householdId,auth.viewGrantId,member.member_id,now]);
        if(!grant.rowCount)throw accessEnded();
      }
      if(auth.viewGrantId&&auth.selectedShopId)throw unavailable();
      if(auth.selectedShopId){const selected=await db.query("SELECT 1 FROM ritc.shop s WHERE s.household_id=$1 AND s.shop_id=$2 AND ((s.shopper_id=$3 AND $4='adult') OR (s.phase<>'closed' AND $5::boolean) OR ($4='adult' AND EXISTS(SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=s.household_id AND g.shop_id=s.shop_id AND g.member_id=$3 AND g.enabled AND g.authority_epoch=s.authority_epoch)))",[householdId,auth.selectedShopId,member.member_id,member.kind,member.can_contribute||member.organizer]);if(!selected.rowCount){
        // HTTP supplies this marker only for placement-report routes; each still applies its reporter/current-shopper check.
        const historical=auth.historicalReportShopId===auth.selectedShopId&&member.kind==='adult'&&!auth.viewGrantId
          ? await db.query('SELECT 1 FROM ritc.shop_authority WHERE household_id=$1 AND shop_id=$2 AND member_id=$3 LIMIT 1',[householdId,auth.selectedShopId,member.member_id]) : null;
        if(!historical?.rowCount)throw accessEnded();
      }}
      const scopedMember=auth.viewGrantId?{...member,organizer:false,can_contribute:false}:member;
      return fn({db,householdId,member:scopedMember,deviceId:device.device_id,now,...(auth.viewGrantId?{viewGrantId:auth.viewGrantId}:{}),...(auth.selectedShopId?{selectedShopId:auth.selectedShopId}:{})});
    });
  }
  async workspaces(identity:VerifiedIdentity) {
    const db=await this.pool.connect();try{
      await db.query('BEGIN');await this.assertSession(db,identity,new Date());await db.query("SELECT set_config('app.issuer',$1,true),set_config('app.subject',$2,true)",[identity.issuer,identity.subject]);
      const result=await db.query(`SELECT m.household_id,h.label,m.organizer FROM ritc.member m JOIN ritc.household h USING(household_id)
        WHERE m.issuer=$1 AND m.subject=$2 AND m.kind='adult' AND m.state='active' ORDER BY h.created_at,h.household_id LIMIT 50`,[identity.issuer,identity.subject]);
      await db.query('COMMIT');return {workspaces:result.rows.map(r=>({householdId:r.household_id,label:r.label,role:r.organizer?'organizer':'contributor'}))};
    }catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}
  }
  async enroll(householdId:string,identity:VerifiedIdentity) {
    return this.transaction(householdId,async(db,now)=>{
      await this.assertSession(db,identity,now);
      const member=await this.member(db,householdId,identity);
      if(member.kind==='child')throw new ServiceError(403,'guardian_reenrollment_required','A guardian must approve a fresh child device.');
      const enrollment=(await db.query('SELECT ritc.device_enrollment_permitted($1,$2,$3,$4,$5) AS permitted',[householdId,member.member_id,identity.issuer,identity.subject,identity.sessionId])).rows[0];
      if(!enrollment?.permitted)throw new ServiceError(401,'session_needed','Sign in again with a fresh session before enrolling another device.');
      const count=(await db.query('SELECT count(*)::integer AS count FROM ritc.device WHERE household_id=$1 AND member_id=$2 AND revoked_at IS NULL',[householdId,member.member_id])).rows[0].count;
      if(count>=20)throw new ServiceError(429,'device_limit','Revoke an old device before enrolling again.');
      const deviceId=randomUUID(),deviceToken=randomBytes(32).toString('base64url');
      await db.query('INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id) VALUES($1,$2,$3,$4,$5)',[householdId,deviceId,member.member_id,tokenHash(deviceToken),identity.sessionId]);
      return {deviceId,deviceToken};
    });
  }
  async window(ctx:Context) {
    const prior=(await ctx.db.query<{window_id:string;expires_at:Date}>(`SELECT window_id,expires_at FROM ritc.replay_window
      WHERE household_id=$1 AND device_id=$2 AND revoked_at IS NULL AND expires_at>$3 ORDER BY expires_at DESC LIMIT 1`,[ctx.householdId,ctx.deviceId,new Date(ctx.now.getTime()+60_000)])).rows[0];
    if(prior)return{id:prior.window_id,expiresAt:prior.expires_at.toISOString()};
    const id=randomUUID(),expiresAt=new Date(ctx.now.getTime()+24*60*60_000);
    await ctx.db.query('INSERT INTO ritc.replay_window(household_id,window_id,member_id,device_id,expires_at) VALUES($1,$2,$3,$4,$5)',[ctx.householdId,id,ctx.member.member_id,ctx.deviceId,expiresAt]);
    return{id,expiresAt:expiresAt.toISOString()};
  }
  async setRequestQueuePermission(ctx:Context, enabled:boolean) {
    const current = await this.bootstrap(ctx);
    if (!current.capabilities.includes('request_queue_permission')) throw unavailable();
    const key = [ctx.householdId,ctx.member.member_id,ctx.deviceId];
    if (!enabled) {
      await ctx.db.query('DELETE FROM ritc.request_queue_permission WHERE household_id=$1 AND member_id=$2 AND device_id=$3',key);
    } else if (!current.queueConsent) {
      const until = (await this.window(ctx)).expiresAt;
      await ctx.db.query(`INSERT INTO ritc.request_queue_permission(household_id,member_id,device_id,grant_id,enabled_at,expires_at)
        VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(household_id,member_id,device_id)
        DO UPDATE SET grant_id=excluded.grant_id,enabled_at=excluded.enabled_at,expires_at=excluded.expires_at`,
        [...key,randomUUID(),ctx.now,until]);
    }
    return this.bootstrap(ctx);
  }
  async bootstrap(ctx:Context) {
    const house=(await ctx.db.query('SELECT label FROM ritc.household WHERE household_id=$1',[ctx.householdId])).rows[0];
    const candidates = (await ctx.db.query<{shop_id:string;shopper_id:string;placed_revision:number|null;budget_access:boolean}>(`
      SELECT s.shop_id,s.shopper_id,s.placed_revision,
        ($5::boolean AND EXISTS(SELECT 1 FROM ritc.shop_budget_grant g
          WHERE g.household_id=s.household_id AND g.shop_id=s.shop_id AND g.member_id=$3
          AND g.enabled AND g.authority_epoch=s.authority_epoch)) AS budget_access
      FROM ritc.shop s WHERE s.household_id=$1
      AND ($2::uuid IS NOT NULL AND s.shop_id=$2 OR $2::uuid IS NULL AND s.phase<>'closed')
      AND (s.shopper_id=$3 OR $4::boolean OR ($5::boolean AND EXISTS(
        SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=s.household_id AND g.shop_id=s.shop_id
        AND g.member_id=$3 AND g.enabled AND g.authority_epoch=s.authority_epoch)))
      ORDER BY s.created_at DESC,s.shop_id LIMIT 2`,
      [ctx.householdId,ctx.selectedShopId??null,ctx.member.member_id,
       ctx.member.can_contribute||ctx.member.organizer,ctx.member.kind==='adult'&&!ctx.viewGrantId])).rows;
    const shop=ctx.selectedShopId?candidates[0]:candidates.length===1?candidates[0]:undefined;
    if(ctx.selectedShopId&&!shop)throw accessEnded();
    const helper=(await ctx.db.query(`SELECT g.grant_id,g.shop_id,g.mode FROM ritc.view_grant g JOIN ritc.member creator ON creator.household_id=g.household_id AND creator.member_id=g.created_by
      WHERE g.household_id=$1 AND g.recipient_id=$2 AND g.revoked_at IS NULL AND g.expires_at>$3 AND creator.state='active' AND ($4::uuid IS NULL OR g.grant_id=$4) ORDER BY g.as_of DESC,g.grant_id LIMIT 1`,[ctx.householdId,ctx.member.member_id,ctx.now,ctx.viewGrantId??null])).rows[0];
    if(ctx.viewGrantId&&!helper)throw accessEnded();
    const isShopper=!ctx.viewGrantId&&ctx.member.kind==='adult'&&shop?.shopper_id===ctx.member.member_id;
    const hasBudgetAccess = !ctx.viewGrantId && ctx.member.kind === 'adult' &&
      ((await ctx.db.query(`SELECT 1 FROM ritc.shop_budget_grant g
        JOIN ritc.shop s USING(household_id,shop_id,authority_epoch)
        WHERE g.household_id=$1 AND g.member_id=$2 AND g.enabled AND s.phase<>'closed' LIMIT 1`,
        [ctx.householdId,ctx.member.member_id])).rowCount ?? 0) > 0;
    const helperRole=!ctx.selectedShopId&&!isShopper&&!ctx.member.organizer&&!hasBudgetAccess&&helper;
    const queueEligible = !ctx.viewGrantId && !helperRole && ctx.member.kind === 'adult' && ctx.member.can_contribute;
    const grant = queueEligible ? (await ctx.db.query<{request_queue_grant:string,request_queue_until:Date}>(
      'SELECT grant_id AS request_queue_grant,expires_at AS request_queue_until FROM ritc.request_queue_permission WHERE household_id=$1 AND member_id=$2 AND device_id=$3 AND expires_at>$4',
      [ctx.householdId,ctx.member.member_id,ctx.deviceId,ctx.now])).rows[0] : undefined;
    const planning = !ctx.viewGrantId && !helperRole && !isShopper && shop && ctx.member.kind==='adult' &&
      (await ctx.db.query(`SELECT 1 FROM ritc.meal_planner p JOIN ritc.shop s USING(household_id,shop_id,authority_epoch)
       WHERE p.household_id=$1 AND p.shop_id=$2 AND p.planner_id=$3 AND s.phase<>'closed'`,[ctx.householdId,shop.shop_id,ctx.member.member_id])).rowCount;
    return{household:{id:ctx.householdId,label:house.label as string},memberId:ctx.member.member_id,
      canSelectShop:!helperRole&&!ctx.viewGrantId&&ctx.member.kind==='adult'&&(ctx.member.can_contribute||ctx.member.organizer||isShopper||hasBudgetAccess),
      selectionRequired:!helperRole&&!ctx.viewGrantId&&!ctx.selectedShopId&&candidates.length>1,role:isShopper?'shopper':ctx.member.organizer?'organizer':helperRole?(helper.mode==='edit'?'editor':'helper'):'contributor',shopId:helperRole?helper.shop_id:shop?.shop_id??null,...(helperRole?{grantId:helper.grant_id}:{}),enrolled:true,canSetRequestQueue:Boolean(queueEligible),queueConsent:Boolean(grant),
      ...(grant ? {requestQueueGrant:grant.request_queue_grant,requestQueueUntil:grant.request_queue_until.toISOString()} : {}),
      capabilities:[...(queueEligible?['request_queue_permission']:[]),...(!helperRole&&!ctx.viewGrantId&&(isShopper||shop?.budget_access)?['store_quotes']:[]),...(isShopper && shop?.placed_revision!=null?['delivery_evidence','cook_copies','cook_corrections','pantry_lots','meal_recovery','request_purchase_confirmation']:[]),...(planning?['meal_proposals']:[]),...(ctx.member.can_contribute?['own_requests']:[]),...(isShopper?['shopper_inbox','request_preview','shopper_commands','accepted_fallbacks','deferred_requests']:[]),...(ctx.member.organizer?['household_admin']:[]),...(helperRole?['helper_view',...(helper.mode==='edit'?['helper_propose']:[])]:[])]};
  }
  async shops(ctx:Context,scope:'active'|'owned',after:string|null){
    if(ctx.viewGrantId||ctx.member.kind!=='adult')throw unavailable();
    let cursor:string|undefined;
    if(after){const record=(await ctx.db.query("SELECT created_at::text AS created_at FROM ritc.shop WHERE household_id=$1 AND shop_id=$2 AND ($3='active' AND phase<>'closed' AND (shopper_id=$4 OR $5::boolean OR EXISTS(SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=ritc.shop.household_id AND g.shop_id=ritc.shop.shop_id AND g.member_id=$4 AND g.enabled AND g.authority_epoch=ritc.shop.authority_epoch)) OR $3='owned' AND shopper_id=$4)",[ctx.householdId,after,scope,ctx.member.member_id,ctx.member.can_contribute||ctx.member.organizer])).rows[0];if(!record)throw unavailable();cursor=record.created_at;}
    const rows=(await ctx.db.query("SELECT shop_id,shopper_id,created_at,phase,revision,authority_epoch FROM ritc.shop WHERE household_id=$1 AND ($2='active' AND phase<>'closed' AND (shopper_id=$3 OR $6::boolean OR EXISTS(SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=ritc.shop.household_id AND g.shop_id=ritc.shop.shop_id AND g.member_id=$3 AND g.enabled AND g.authority_epoch=ritc.shop.authority_epoch)) OR $2='owned' AND shopper_id=$3) AND ($4::timestamptz IS NULL OR (created_at,shop_id)<($4,$5::uuid)) ORDER BY created_at DESC,shop_id DESC LIMIT 51",[ctx.householdId,scope,ctx.member.member_id,cursor??null,after,ctx.member.can_contribute||ctx.member.organizer])).rows;
    return{shops:rows.slice(0,50).map(s=>({shopId:s.shop_id,createdAt:s.created_at.toISOString(),phase:s.phase,role:s.shopper_id===ctx.member.member_id?'shopper':'contributor',...(s.shopper_id===ctx.member.member_id?{revision:s.revision,authorityEpoch:s.authority_epoch}:{})})),nextCursor:rows.length>50?rows[49].shop_id:null};
  }
  private get carryNotice() {return this.options.allowChildNetwork?this.options.noticeVersion:null;}
  async deferredRequests(ctx:Context,shopId:string,after:string|null) {
    const shop=await this.shop(ctx,shopId);
    this.requireShopper(ctx,shop);
    this.requireDraft(shop);
    return deferredRequests(ctx,shop,this.carryNotice,after);
  }
  async requests(ctx:Context,after:string|null,shopId?:string) {
    if(shopId)this.requireShopper(ctx,await this.shop(ctx,shopId));
    let cursor:{received_at:string;request_id:string}|undefined;
    if(after) {
      cursor=(await ctx.db.query<{received_at:string;request_id:string}>(`SELECT received_at::text AS received_at,request_id FROM ritc.request_origin WHERE (NOT (carried_forward OR from_previous_shop) OR (author_active AND (author_kind='adult' OR live_notice=$5))) AND household_id=$1 AND request_id=$2 AND ${shopId?'shop_id':'author_id'}=$3 AND ($4::uuid IS NULL OR shop_id=$4)`,[ctx.householdId,after,shopId??ctx.member.member_id,ctx.selectedShopId??null,this.carryNotice])).rows[0];
      if(!cursor)throw unavailable();
    }
    const params:unknown[]=[ctx.householdId,shopId??ctx.member.member_id,ctx.selectedShopId??null,this.carryNotice];
    if(cursor)params.push(cursor.received_at,cursor.request_id);
    const result=await ctx.db.query<RequestRow & {author_alias?:string;linked_line_id?:string}>(`SELECT r.*,p.outcome AS purchase_outcome
      ${shopId?',l.line_id AS linked_line_id':''}
      FROM ritc.request_origin r LEFT JOIN ritc.request_purchase_review p
        ON (p.household_id,p.request_id,p.request_revision)=(r.household_id,r.request_id,r.revision)
      ${shopId?`LEFT JOIN ritc.placed_request_link l ON (l.household_id,l.request_id)=(r.household_id,r.request_id)`:''}
      WHERE r.household_id=$1 AND r.${shopId?'shop_id':'author_id'}=$2 AND ($3::uuid IS NULL OR r.shop_id=$3)
      AND (NOT (r.carried_forward OR r.from_previous_shop) OR (r.author_active AND (r.author_kind='adult' OR r.live_notice=$4)))
      ${cursor?'AND (r.received_at,r.request_id)>($5,$6)':''} ORDER BY r.received_at,r.request_id LIMIT 51`,params);
    const rows=result.rows.slice(0,50);
    return{requests:rows.map(r=>({...ownRequest(r),...(shopId?{authorAlias:r.author_alias}:{}),
      ...(shopId && r.linked_line_id?{linkedLineId:r.linked_line_id}:{})})),nextCursor:result.rows.length>50?rows.at(-1)!.request_id:null};
  }
  async shop(ctx:Context,shopId:string):Promise<Shop> {
    if(ctx.selectedShopId&&ctx.selectedShopId!==shopId)throw unavailable();
    const shop=(await ctx.db.query<Shop>('SELECT * FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shopId])).rows[0];
    if(!shop)throw unavailable();return shop;
  }
  requireShopper(ctx:Context,shop:Shop) {if(ctx.viewGrantId||ctx.member.kind!=='adult'||shop.shopper_id!==ctx.member.member_id)throw unavailable();}
  requireOrganizer(ctx:Context) {if(ctx.viewGrantId||ctx.member.kind!=='adult'||!ctx.member.organizer)throw unavailable();}
  checkBase(shop:Shop,base:Envelope['base']) {
    if(shop.authority_epoch!==base.authorityEpoch)throw new ServiceError(409,'authority_changed','Refresh shopper authority and review again.');
    if(shop.revision!==base.shopRevision)throw new ServiceError(409,'stale_base','Refresh the shop and review again.');
  }
  requireDraft(shop:Shop) {if(shop.phase!=='draft')throw new ServiceError(409,'checkout_locked','Review the frozen order or save this for next shop.');}
  async request(ctx:Context,id:string,shopId:string,own=false):Promise<RequestRow> {
    const r=(await ctx.db.query<RequestRow>("SELECT * FROM ritc.request_origin WHERE household_id=$1 AND request_id=$2 AND shop_id=$3 AND (NOT (carried_forward OR from_previous_shop) OR (author_active AND (author_kind='adult' OR live_notice=$4)))",[ctx.householdId,id,shopId,this.carryNotice])).rows[0];
    if(!r||(own&&r.author_id!==ctx.member.member_id))throw unavailable();return r;
  }
  async lines(ctx:Context,shopId:string):Promise<BasketLine[]> {
    return(await ctx.db.query('SELECT line_id,original_item,packs,unit_price_minor,fee_eligible FROM ritc.basket_line WHERE household_id=$1 AND shop_id=$2 ORDER BY line_id',[ctx.householdId,shopId])).rows.map(r=>({lineId:r.line_id,originalItem:r.original_item,packs:r.packs,feeEligible:r.fee_eligible,unitPriceMinor:r.unit_price_minor===null?null:Number(r.unit_price_minor)}));
  }
  async meals(ctx: Context, shopId: string) {
    const result = await ctx.db.query(`SELECT occurrence_id,revision,meal FROM (
      SELECT DISTINCT ON (occurrence_id) occurrence_id,revision,meal FROM ritc.shared_meal_revision
      WHERE household_id=$1 AND shop_id=$2 ORDER BY occurrence_id,revision DESC
    ) latest WHERE meal IS NOT NULL ORDER BY meal->>'day',occurrence_id`, [ctx.householdId, shopId]);
    return result.rows.map(row => ({occurrenceId: row.occurrence_id as string, revision: row.revision as number, meal: row.meal}));
  }
  async shopperAssignment(ctx: Context,shopId: string) {
    this.requireOrganizer(ctx);
    const shop=await this.shop(ctx,shopId);
    const adults=await ctx.db.query("SELECT member_id,alias FROM ritc.member WHERE household_id=$1 AND kind='adult' AND state='active' ORDER BY alias,member_id",[ctx.householdId]);
    return {shopId,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,shopperId:shop.shopper_id,phase:shop.phase,
      adults:adults.rows.map(row=>({id:row.member_id,label:row.alias}))};
  }
  async adultShop(ctx:Context,shopId:string) {
    const s=await this.shop(ctx,shopId);this.requireShopper(ctx,s);
    return{shopId:s.shop_id,shopRevision:s.revision,authorityEpoch:s.authority_epoch,phase:s.phase,quote:s.quote,meals:await this.meals(ctx,shopId),lines:await this.lines(ctx,shopId),frozenRevision:s.frozen_revision,placedRevision:s.placed_revision,storeBasisRevision:s.store_basis_revision??null,storeReviewRequired:s.store_review_required??false};
  }
  private async snapshot(ctx:Context,shopId:string,operationId:string,purpose:string) {
    const shop=await this.shop(ctx,shopId),lines=await this.lines(ctx,shopId);
    const mealRefs=(await this.meals(ctx,shopId)).map(({occurrenceId,revision})=>({occurrenceId,revision}));
    const snapshot={shopId,...(mealRefs.length ? {mealRefs} : {}),revision:shop.revision,phase:shop.phase,quote:shop.quote,lines,budget:checkout(lines,shop.quote)};
    await ctx.db.query('INSERT INTO ritc.shop_snapshot(household_id,shop_id,revision,purpose,snapshot,digest,operation_id) VALUES($1,$2,$3,$4,$5,$6,$7)',[ctx.householdId,shopId,shop.revision,purpose,snapshot,digest(snapshot),operationId]);
  }
  private validateQuote(quote:QuoteBasis,now:Date) {
    if(Date.parse(quote.observedAt)>now.getTime()+5*60_000)throw invalid();
  }
  private async setLines(ctx:Context,shopId:string,lines:BasketLine[]) {
    if(new Set(lines.map(l=>l.lineId)).size!==lines.length)throw invalid();
    // A linked line cannot disappear: the FK rejects deletion rather than discarding an accepted request.
    await ctx.db.query('DELETE FROM ritc.basket_line WHERE household_id=$1 AND shop_id=$2 AND NOT(line_id=ANY($3::uuid[]))',[ctx.householdId,shopId,lines.map(l=>l.lineId)]);
    for(const line of lines)await ctx.db.query(`INSERT INTO ritc.basket_line(household_id,shop_id,line_id,original_item,packs,unit_price_minor,fee_eligible) VALUES($1,$2,$3,$4,$5,$6,$7)
      ON CONFLICT(household_id,shop_id,line_id) DO UPDATE SET original_item=EXCLUDED.original_item,packs=EXCLUDED.packs,unit_price_minor=EXCLUDED.unit_price_minor,fee_eligible=EXCLUDED.fee_eligible`,[ctx.householdId,shopId,line.lineId,line.originalItem,line.packs,line.unitPriceMinor,line.feeEligible]);
  }
  private applyDecision(lines:BasketLine[],decision:Decision) {
    if(decision.choice==='add') {
      if(lines.some(l=>l.lineId===decision.line.lineId))throw new ServiceError(409,'line_exists','Link the existing line or review a genuinely additional pack.');
      return[...lines,decision.line];
    }
    if(decision.choice==='link'&&!lines.some(l=>l.lineId===decision.lineId))throw unavailable();
    return lines;
  }
  private previewFacts(shop:Shop,r:RequestRow,lines:BasketLine[],decision:Decision) {
    const before=checkout(lines,shop.quote),after=checkout(this.applyDecision(lines,decision),shop.quote);
    return{before,after,changeMinor:before.totalMinor!==null&&after.totalMinor!==null?after.totalMinor-before.totalMinor:null,
      requiresOverageAcceptance:decision.choice==='add'&&after.status==='overCap',requiresUnknownAcceptance:decision.choice==='add'&&(after.status==='unresolved'||after.status==='scopeMismatch'||after.scope!=='wholeCheckout')};
  }
  async preview(ctx:Context,shopId:string,input:PreviewInput):Promise<RequestPreview> {
    const shop=await this.shop(ctx,shopId);this.requireShopper(ctx,shop);this.checkBase(shop,input.base);
    const r=await this.request(ctx,input.requestId,shopId);
    if(r.carried_forward||!editable(r)&&!(r.status==='deferred'&&('promote'in input.decision)&&input.decision.promote))throw new ServiceError(409,'already_handled','Review the current request status.');
    if(r.revision!==input.base.requestRevision)throw new ServiceError(409,'stale_base','Review the changed request.');
    if(input.decision.choice==='add'||input.decision.choice==='link') {
      this.requireDraft(shop);
      if(r.route==='next'&&!input.decision.promote)throw new ServiceError(409,'next_shop','Explicitly review promotion into this shop.');
      if(Date.parse(shop.quote.expiresAt)<=ctx.now.getTime())throw new ServiceError(409,'stale_quote','Record a current quote before reviewing this purchase.');
    }
    if(input.decision.choice==='add'&&input.decision.reviewedPackEvidence) {
      const evidence=input.decision.reviewedPackEvidence;
      if(Date.parse(evidence.reviewedAt)>ctx.now.getTime()+300000||Date.parse(evidence.quoteObservedAt)>ctx.now.getTime()+300000)throw invalid();
    }
    const lines=await this.lines(ctx,shopId),previewId=randomUUID();
    const facts=this.previewFacts(shop,r,lines,input.decision);
    const expiresAt=new Date(ctx.now.getTime()+5*60_000);
    const fingerprint=digest({shop,r:ownRequest(r),lines,decision:input.decision});
    await ctx.db.query(`INSERT INTO ritc.preview(household_id,preview_id,shop_id,actor_id,request_id,shop_revision,request_revision,authority_epoch,decision,fingerprint,expires_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,[ctx.householdId,previewId,shopId,ctx.member.member_id,r.request_id,shop.revision,r.revision,shop.authority_epoch,input.decision,fingerprint,expiresAt]);
    return{previewId,expiresAt:expiresAt.toISOString(),shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,requestRevision:r.revision,choice:input.decision.choice,...facts};
  }
  async execute(ctx:Context,command:Envelope,billing?:BillingService):Promise<unknown> {
    if(ctx.selectedShopId && command.shopId!==ctx.selectedShopId) throw unavailable();
    const window=(await ctx.db.query('SELECT 1 FROM ritc.replay_window WHERE household_id=$1 AND window_id=$2 AND member_id=$3 AND device_id=$4 AND revoked_at IS NULL AND expires_at>$5',[ctx.householdId,command.replayWindow,ctx.member.member_id,ctx.deviceId,ctx.now])).rowCount;
    if(!window)throw refresh();
    const payloadDigest=digest(command);
    const prior=(await ctx.db.query(`SELECT o.*,r.response FROM ritc.operation o LEFT JOIN ritc.operation_response r USING(household_id,operation_id)
      WHERE o.household_id=$1 AND o.actor_id=$2 AND o.client_key=$3`,[ctx.householdId,ctx.member.member_id,command.clientKey])).rows[0];
    if(prior) {
      // Reauthorize the original scope before returning anything about a prior result.
      if(prior.response_scope==='shopper'){
        const shop=await this.shop(ctx,prior.shop_id);this.requireShopper(ctx,shop);
        if(prior.kind==='request.carry')await reauthorizeCarry(ctx,shop,this.carryNotice,prior.operation_id);
        if(prior.kind==='request.confirmPurchase' && (prior.response?.authorityEpoch!==shop.authority_epoch || !(await ctx.db.query(
          'SELECT 1 FROM ritc.request_purchase_review WHERE household_id=$1 AND operation_id=$2',[ctx.householdId,prior.operation_id])).rowCount)) throw refresh();
        if(prior.kind==='mealRecovery.apply') {
          if(prior.response?.authorityEpoch!==shop.authority_epoch || !(await ctx.db.query(
            'SELECT 1 FROM ritc.meal_recovery_revision WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3 AND current_meal IS NOT NULL',
            [ctx.householdId,shop.shop_id,prior.operation_id])).rowCount) throw refresh();
        }
        if(prior.kind==='cookCopy.save' || prior.kind==='cookCopy.markSent') {
          if(prior.response?.authorityEpoch!==shop.authority_epoch ||
             !await cookCopyStillExists(ctx,shop,prior.kind,prior.operation_id)) throw refresh();
        }
        if(isPantryCommand(prior.kind) && (prior.response?.authorityEpoch!==shop.authority_epoch || !await pantryOperationExists(ctx,prior.operation_id))) throw refresh();
        if(prior.kind.startsWith('delivery.')) {
          if(prior.response?.authorityEpoch!==shop.authority_epoch) throw refresh();
          const source=await ctx.db.query('SELECT 1 FROM ritc.delivery_source WHERE household_id=$1 AND shop_id=$2 AND source_id=$3',
            [ctx.householdId,shop.shop_id,prior.response.sourceId]);
          if(!source.rowCount)throw refresh();
          if(prior.kind==='delivery.reserve' && !(await ctx.db.query(
            'SELECT 1 FROM ritc.delivery_reservation WHERE household_id=$1 AND operation_id=$2',
            [ctx.householdId,prior.operation_id])).rowCount)throw refresh();
          if(prior.kind==='delivery.match' && !(await ctx.db.query(
            'SELECT 1 FROM ritc.delivery_ingredient_review WHERE household_id=$1 AND operation_id=$2',
            [ctx.householdId,prior.operation_id])).rowCount)throw refresh();
        }
      }
      if(prior.response_scope==='organizer')this.requireOrganizer(ctx);
      if(prior.response_scope==='own'&&!ctx.member.can_contribute)throw accessEnded();
      if(!prior.response)throw refresh();
      if(prior.payload_digest!==payloadDigest)throw new ServiceError(409,'key_reused','Review and submit the changed intent with a new key.');
      if(prior.device_id!==ctx.deviceId)throw refresh();
      return prior.response;
    }
    const operationId=randomUUID();
    let scope:'own'|'shopper'|'organizer'|'reporter'='shopper';
    let response:unknown;
    if(command.kind==='shop.create') {
      this.requireOrganizer(ctx);scope='organizer';
      if(command.base.shopRevision!==0||command.base.authorityEpoch!==0)throw invalid();
      const body=bodySchemas['shop.create'].parse(command.body);this.validateQuote(body.quote,ctx.now);checkout(body.lines,body.quote);
      const exists=await ctx.db.query('SELECT 1 FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,command.shopId]);
      if(exists.rowCount)throw new ServiceError(409,'shop_exists','Open the existing shop.');
      await ctx.db.query('INSERT INTO ritc.shop(household_id,shop_id,shopper_id,quote) VALUES($1,$2,$3,$4)',[ctx.householdId,command.shopId,ctx.member.member_id,body.quote]);
      await ctx.db.query('INSERT INTO ritc.shop_authority(household_id,shop_id,epoch,member_id) VALUES($1,$2,1,$3)',[ctx.householdId,command.shopId,ctx.member.member_id]);
      await this.setLines(ctx,command.shopId,body.lines);await this.snapshot(ctx,command.shopId,operationId,'create');
      response=await this.receipt(ctx,command,operationId,'created');
    }else {
      const shop=await this.shop(ctx,command.shopId);
      if(['request.send','request.edit','request.withdraw'].includes(command.kind)) {
        scope='own';if(!ctx.member.can_contribute)throw unavailable();
        response=await this.authorCommand(ctx,shop,command,operationId);
      }else if(command.kind==='shop.reportPlaced') {
        scope='reporter';response=await this.report(ctx,shop,command,operationId);
      }else if(command.kind==='shop.transferAuthority') {
        scope='organizer';this.requireOrganizer(ctx);this.checkBase(shop,command.base);
        const body=bodySchemas['shop.transferAuthority'].parse(command.body);
        const eligible=await ctx.db.query("SELECT 1 FROM ritc.member WHERE household_id=$1 AND member_id=$2 AND kind='adult' AND state='active'",[ctx.householdId,body.newShopperId]);
        if(!eligible.rowCount)throw unavailable();
        if(shop.shopper_id===body.newShopperId)throw new ServiceError(409,'already_assigned','This adult is already the assigned shopper.');
        if(shop.phase==='closed')throw new ServiceError(409,'checkout_locked','Open a current shop.');
        await ctx.db.query('UPDATE ritc.shop SET shopper_id=$3,authority_epoch=authority_epoch+1 WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id,body.newShopperId]);
        await ctx.db.query('INSERT INTO ritc.shop_authority(household_id,shop_id,epoch,member_id) VALUES($1,$2,$3,$4)',[ctx.householdId,shop.shop_id,shop.authority_epoch+1,body.newShopperId]);
        response=await this.receipt(ctx,command,operationId,'transferred');
      }else {
        this.requireShopper(ctx,shop);this.checkBase(shop,command.base);
        response=await this.shopperCommand(ctx,shop,command,operationId,billing);
      }
    }
    await ctx.db.query(`INSERT INTO ritc.operation(household_id,operation_id,actor_id,device_id,client_key,window_id,kind,shop_id,payload_digest,response_scope)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,[ctx.householdId,operationId,ctx.member.member_id,ctx.deviceId,command.clientKey,command.replayWindow,command.kind,command.shopId,payloadDigest,scope]);
    await ctx.db.query('INSERT INTO ritc.operation_response(household_id,operation_id,response) VALUES($1,$2,$3)',[ctx.householdId,operationId,response]);
    await ctx.db.query('INSERT INTO ritc.event(household_id,operation_id,shop_id,kind) VALUES($1,$2,$3,$4)',[ctx.householdId,operationId,command.shopId,command.kind]);
    return response;
  }
  private async receipt(ctx:Context,c:Envelope,operationId:string,disposition:string,extra:Partial<ShopperReceipt>={}):Promise<ShopperReceipt> {
    const s=await this.shop(ctx,c.shopId);return{operationId,kind:c.kind,shopId:s.shop_id,shopRevision:s.revision,authorityEpoch:s.authority_epoch,disposition,...extra};
  }
  private async authorCommand(ctx:Context,shop:Shop,c:Envelope,operationId:string) {
    let id:string;
    if(c.kind==='request.send') {
      const b=bodySchemas['request.send'].parse(c.body);id=randomUUID();
      if(b.followupTo)await this.request(ctx,b.followupTo,shop.shop_id,true);
      if(Date.parse(b.authoredAt)>ctx.now.getTime()+24*60*60_000)throw invalid();
      const dup=await ctx.db.query('SELECT 1 FROM ritc.request WHERE household_id=$1 AND author_id=$2 AND client_request_id=$3',[ctx.householdId,ctx.member.member_id,b.clientRequestId]);
      if(dup.rowCount)throw new ServiceError(409,'request_id_reused','Refresh your request list before submitting a new request.');
      await ctx.db.query(`INSERT INTO ritc.request(household_id,request_id,author_id,client_request_id,shop_id,original_item,own_quantity,route,authored_at,followup_to,author_consent_id)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,(SELECT guardian_consent_id FROM ritc.device WHERE household_id=$1 AND device_id=$11 AND member_id=$3))`,[ctx.householdId,id,ctx.member.member_id,b.clientRequestId,shop.shop_id,b.originalItem,b.ownQuantity,shop.phase==='draft'?b.route:'next',b.authoredAt,b.followupTo??null,ctx.deviceId]);
    }else {
      const b=c.kind==='request.edit'?bodySchemas['request.edit'].parse(c.body):bodySchemas['request.withdraw'].parse(c.body);id=b.requestId;
      const r=await this.request(ctx,id,shop.shop_id,true);
      if(!editable(r))throw new ServiceError(409,'followup_required','Send a linked follow-up; the accepted basket stays unchanged.');
      if(r.revision!==c.base.requestRevision)throw new ServiceError(409,'stale_base','Refresh your request before changing it.');
      if('originalItem'in b&&'ownQuantity'in b)await ctx.db.query("UPDATE ritc.request SET original_item=$3,own_quantity=$4,status='pending',clarification=NULL,revision=revision+1 WHERE household_id=$1 AND request_id=$2",[ctx.householdId,id,b.originalItem,b.ownQuantity]);
      else await ctx.db.query("UPDATE ritc.request SET status='withdrawn',revision=revision+1 WHERE household_id=$1 AND request_id=$2",[ctx.householdId,id]);
    }
    return{operationId,kind:c.kind,request:ownRequest(await this.request(ctx,id,shop.shop_id,true))};
  }
  private async shopperCommand(ctx:Context,shop:Shop,c:Envelope,operationId:string,billing?:BillingService) {
    if(c.kind==='mealRecovery.apply') {
      const applied=await recordSharedRecovery(ctx,shop,c.body,operationId,billing);
      return {...await this.receipt(ctx,c,operationId,'recorded'),...applied};
    }
    if(isPantryCommand(c.kind)) {
      const lot=await recordCurrentPantry(ctx,shop,c.kind,c.body,operationId,loadRecoveryPublication);
      return {...await this.receipt(ctx,c,operationId,'recorded'),...lot};
    }
    if(c.kind==='cookCopy.save' || c.kind==='cookCopy.markSent') {
      const copyId=await recordCookCopy(ctx,shop,c.kind,c.body,operationId);
      return {...await this.receipt(ctx,c,operationId,'recorded'),copyId};
    }
    if(c.kind==='delivery.reserve'||c.kind==='delivery.match'||c.kind==='delivery.register'||c.kind==='delivery.arrival'||c.kind==='delivery.usable'){
      const delivery=await recordCurrentDelivery(ctx,shop,c.kind,c.body,operationId,loadRecoveryPublication);
      return {...await this.receipt(ctx,c,operationId,'recorded'),...delivery};
    }
    if(c.kind==='request.carry') {
      this.requireDraft(shop);
      const carried=await carryRequest(ctx,shop,this.carryNotice,c,operationId);
      return this.receipt(ctx,c,operationId,'recorded',carried);
    }
    if(c.kind==='request.clarify') {
      const b=bodySchemas['request.clarify'].parse(c.body),r=await this.request(ctx,b.requestId,shop.shop_id);
      if(!editable(r)||r.revision!==c.base.requestRevision)throw new ServiceError(409,'stale_base','Review the current request.');
      await ctx.db.query("UPDATE ritc.request SET status='clarified',clarification=$3,revision=revision+1 WHERE household_id=$1 AND request_id=$2",[ctx.householdId,r.request_id,b.question]);
      return this.receipt(ctx,c,operationId,'clarified',{requestId:r.request_id,requestRevision:r.revision+1});
    }
    if(c.kind==='request.confirmPurchase')return this.confirmPurchase(ctx,shop,c,operationId);
    if(c.kind==='request.apply')return this.apply(ctx,shop,c,operationId);
    if(c.kind==='shop.patch') {
      this.requireDraft(shop);const b=bodySchemas['shop.patch'].parse(c.body);this.validateQuote(b.quote,ctx.now);checkout(b.lines,b.quote);
      if(b.mealEdit) {
        const {occurrenceId,meal}=b.mealEdit;
        const current=await this.meals(ctx,shop.shop_id);
        const original=current.find(entry=>entry.occurrenceId===occurrenceId);
        const exists=Boolean(original);
        preserveProtectedMeal(original ? sharedMealSchema.parse(original.meal) : undefined, meal);
        if((original?.revision ?? null)!==b.mealEdit.baseMealRevision)
          throw new ServiceError(409,'stale_meal','Review this occurrence again before applying a change.');
        if(b.mealEdit.changeProposalId) await consumeSharedMealChange(ctx,shop,b.mealEdit.changeProposalId,occurrenceId,b.mealEdit.baseMealRevision,meal);
        if(b.mealEdit.proposalId) {
          const proposal=(await ctx.db.query(`SELECT m.proposed_day::text FROM ritc.meal_move m
            JOIN ritc.meal_planner p USING(household_id,shop_id,authority_epoch)
            JOIN ritc.member a ON a.household_id=m.household_id AND a.member_id=m.actor_id AND a.state='active'
            WHERE m.household_id=$1 AND m.shop_id=$2 AND m.proposal_id=$3 AND m.occurrence_id=$4 AND m.shop_revision=$5
            AND m.authority_epoch=$6 AND m.state='pending' AND p.planner_id=m.actor_id AND m.grant_revision=p.revision`,
            [ctx.householdId,shop.shop_id,b.mealEdit.proposalId,occurrenceId,shop.revision,shop.authority_epoch])).rows[0];
          if(!proposal || !original || digest(meal)!==digest(moveSharedMeal(sharedMealSchema.parse(original.meal),proposal.proposed_day)))
            throw new ServiceError(409,'stale_proposal','Read the current proposal and review its exact move.');
          await ctx.db.query("UPDATE ritc.meal_move SET state='applied' WHERE household_id=$1 AND shop_id=$2 AND proposal_id=$3",
            [ctx.householdId,shop.shop_id,b.mealEdit.proposalId]);
        }
        if(!exists && !meal)throw unavailable();
        if(!exists && current.length>=100)throw new ServiceError(409,'meal_limit','Remove a finished occurrence before adding another.');
        await ctx.db.query('INSERT INTO ritc.shared_meal_revision(household_id,shop_id,occurrence_id,revision,actor_id,meal) VALUES($1,$2,$3,$4,$5,$6)',
          [ctx.householdId,shop.shop_id,occurrenceId,shop.revision+1,ctx.member.member_id,meal]);
      }
      const reviewingStore = b.reviewedStoreBasisRevision !== undefined;
      if (reviewingStore && b.reviewedStoreBasisRevision !== shop.store_basis_revision) {
        throw new ServiceError(409,'store_review_required','Review prices and charges for the current selected store.');
      }
      // Partial pricing remains useful draft work. A matching store review token
      // clears the freeze guard only once every cost is known and still current.
      const completedStoreReview = reviewingStore && b.quote.complete &&
        checkout(b.lines,b.quote).totalMinor !== null && Date.parse(b.quote.expiresAt) > ctx.now.getTime();
      await this.setLines(ctx,shop.shop_id,b.lines);
      await ctx.db.query('UPDATE ritc.shop SET quote=$3,revision=revision+1 WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id,b.quote]);
      if (completedStoreReview) {
        await ctx.db.query('UPDATE ritc.shop SET store_review_required=false WHERE household_id=$1 AND shop_id=$2',
          [ctx.householdId,shop.shop_id]);
      }
      await this.snapshot(ctx,shop.shop_id,operationId,'patch');return this.receipt(ctx,c,operationId,'patched');
    }
    if(c.kind==='shop.freeze') {
      this.requireDraft(shop);
      if (shop.store_review_required) {
        throw new ServiceError(409,'store_review_required','Review current item prices and charges after changing stores.');
      }
      await ctx.db.query("UPDATE ritc.shop SET phase='frozen',revision=revision+1,frozen_revision=revision+1 WHERE household_id=$1 AND shop_id=$2",[ctx.householdId,shop.shop_id]);
      await this.snapshot(ctx,shop.shop_id,operationId,'freeze');return this.receipt(ctx,c,operationId,'frozen');
    }
    if(c.kind==='shop.reopen') {
      if(shop.phase!=='frozen')throw new ServiceError(409,'checkout_locked','A placed order cannot be silently reopened.');
      await ctx.db.query("UPDATE ritc.shop SET phase='draft',revision=revision+1,frozen_revision=NULL WHERE household_id=$1 AND shop_id=$2",[ctx.householdId,shop.shop_id]);
      await this.snapshot(ctx,shop.shop_id,operationId,'reopen');return this.receipt(ctx,c,operationId,'reopened');
    }
    if(c.kind==='shop.reconcileReport') {
      const b=bodySchemas['shop.reconcileReport'].parse(c.body);
      const r=(await ctx.db.query('SELECT * FROM ritc.placement_report WHERE household_id=$1 AND report_id=$2 AND shop_id=$3',[ctx.householdId,b.reportId,shop.shop_id])).rows[0];
      if(!r)throw unavailable();if(r.state!=='pending_reconciliation')throw new ServiceError(409,'already_handled','Review the recorded report.');
      if(b.choice==='apply') {
        if(shop.phase!=='frozen'||shop.frozen_revision!==r.reported_revision)throw new ServiceError(409,'reconciliation_required','The report differs from the frozen basket. Preserve both records for review.');
        await this.place(ctx,shop,operationId,r.reported_revision);
      }
      await ctx.db.query('UPDATE ritc.placement_report SET state=$3,resolution_operation_id=$4 WHERE household_id=$1 AND report_id=$2',[ctx.householdId,b.reportId,b.choice==='apply'?'applied':'rejected',operationId]);
      return this.receipt(ctx,c,operationId,b.choice==='apply'?'placed':'report_rejected',{reportId:b.reportId});
    }
    throw invalid();
  }
  private async confirmPurchase(ctx:Context,shop:Shop,c:Envelope,operationId:string) {
    const {requestId,lineId,placedRevision,outcome}=bodySchemas['request.confirmPurchase'].parse(c.body);
    if(!shop.placed_revision || !['placed','closed'].includes(shop.phase))
      throw new ServiceError(409,'placed_order_required','Open the placed order to review this purchase.');
    if(placedRevision!==shop.placed_revision) throw refresh();
    const scope=[ctx.householdId,requestId,shop.shop_id];
    const linked=await ctx.db.query(`SELECT 1 FROM ritc.placed_request_link
      WHERE household_id=$1 AND request_id=$2 AND shop_id=$3 AND line_id=$4 AND placed_revision=$5`,[...scope,lineId,placedRevision]);
    if(!linked.rowCount) throw unavailable();
    const changed=await ctx.db.query<{revision:number}>(`UPDATE ritc.request SET revision=revision+1
      WHERE household_id=$1 AND request_id=$2 AND shop_id=$3 AND status='added' AND revision=$4 RETURNING revision`,
      [...scope,c.base.requestRevision??null]);
    if(!changed.rowCount) throw new ServiceError(409,'stale_base','Review the current request before confirming the purchase.');
    const revision=changed.rows[0]!.revision;
    await ctx.db.query(`INSERT INTO ritc.request_purchase_review(household_id,request_id,shop_id,placed_revision,request_revision,actor_id,operation_id,outcome)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[...scope,placedRevision,revision,ctx.member.member_id,operationId,outcome]);
    return {...await this.receipt(ctx,c,operationId,'recorded',{requestId,requestRevision:revision}),purchaseOutcome:outcome};
  }
  private async apply(ctx:Context,shop:Shop,c:Envelope,operationId:string) {
    const b=bodySchemas['request.apply'].parse(c.body),r=await this.request(ctx,b.requestId,shop.shop_id);
    const p=(await ctx.db.query('SELECT * FROM ritc.preview WHERE household_id=$1 AND preview_id=$2 AND actor_id=$3 AND shop_id=$4 AND request_id=$5',[ctx.householdId,b.previewId,ctx.member.member_id,shop.shop_id,r.request_id])).rows[0];
    if(!p)throw unavailable();
    const decision=decisionSchema.parse(p.decision);
    if(r.carried_forward||!editable(r)&&!(r.status==='deferred'&&('promote'in decision)&&decision.promote))throw new ServiceError(409,'already_handled','Review the current request.');
    if(r.revision!==c.base.requestRevision||p.request_revision!==r.revision||p.shop_revision!==shop.revision||p.authority_epoch!==shop.authority_epoch||p.expires_at<=ctx.now)throw new ServiceError(409,'stale_preview','Review a fresh preview.');
    const lines=await this.lines(ctx,shop.shop_id);
    if(p.fingerprint!==digest({shop,r:ownRequest(r),lines,decision}))throw new ServiceError(409,'stale_preview','Review a fresh preview.');
    const facts=this.previewFacts(shop,r,lines,decision);
    if(facts.requiresOverageAcceptance&&!b.acceptOverage)throw new ServiceError(409,'overage_acceptance_required','Explicitly accept the recomputed whole-checkout overage or defer.');
    if(facts.requiresUnknownAcceptance&&!b.acceptUnknown)throw new ServiceError(409,'unknown_acceptance_required','Review the missing costs or defer.');
    if(decision.choice==='add'||decision.choice==='link') {
      this.requireDraft(shop);
      if(Date.parse(shop.quote.expiresAt)<=ctx.now.getTime())throw new ServiceError(409,'stale_quote','Record a fresh quote.');
      if(r.route==='next'&&!decision.promote)throw new ServiceError(409,'next_shop','Review promotion into this shop.');
      // Recheck the request author's current consent when turning their data into a basket change.
      const author=(await ctx.db.query<Member>('SELECT member_id,kind,state,organizer,can_contribute,alias FROM ritc.member WHERE household_id=$1 AND member_id=$2',[ctx.householdId,r.author_id])).rows[0]!;
      if(author.state!=='active')throw accessEnded();await this.consent(ctx.db,ctx.householdId,author);
      if(decision.choice==='add')await this.setLines(ctx,shop.shop_id,[...lines,decision.line]);
      const lineId=decision.choice==='add'?decision.line.lineId:decision.lineId;
      await ctx.db.query('INSERT INTO ritc.request_link(household_id,request_id,shop_id,line_id,reviewed_revision,operation_id) VALUES($1,$2,$3,$4,$5,$6)',[ctx.householdId,r.request_id,shop.shop_id,lineId,r.revision,operationId]);
      await ctx.db.query('UPDATE ritc.shop SET revision=revision+1 WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id]);
      await this.snapshot(ctx,shop.shop_id,operationId,'decision');
    }
    const status=decision.choice==='add'||decision.choice==='link'?'added':decision.choice==='defer'?'deferred':decision.choice==='dismiss'?'dismissed':'handled';
    await ctx.db.query('UPDATE ritc.request SET status=$3,route=$4,revision=revision+1 WHERE household_id=$1 AND request_id=$2',[ctx.householdId,r.request_id,status,decision.choice==='defer'?'next':status==='added'?'current':r.route]);
    return this.receipt(ctx,c,operationId,status,{requestId:r.request_id,requestRevision:r.revision+1});
  }
  private async place(ctx:Context,shop:Shop,operationId:string,snapshotRevision:number) {
    await ctx.db.query("UPDATE ritc.shop SET phase='placed',placed_revision=$3,revision=revision+1 WHERE household_id=$1 AND shop_id=$2",[ctx.householdId,shop.shop_id,snapshotRevision]);
    await ctx.db.query("UPDATE ritc.request SET route='next',revision=revision+1 WHERE household_id=$1 AND shop_id=$2 AND status IN('pending','clarified') AND route='current'",[ctx.householdId,shop.shop_id]);
    await this.snapshot(ctx,shop.shop_id,operationId,'placed');
  }
  private async report(ctx:Context,shop:Shop,c:Envelope,operationId:string) {
    if(ctx.member.kind!=='adult')throw unavailable();
    const b=bodySchemas['shop.reportPlaced'].parse(c.body);
    const authority=await ctx.db.query('SELECT 1 FROM ritc.shop_authority WHERE household_id=$1 AND shop_id=$2 AND epoch=$3 AND member_id=$4',[ctx.householdId,shop.shop_id,c.base.authorityEpoch,ctx.member.member_id]);
    if(!authority.rowCount)throw unavailable();
    const snapshot=await ctx.db.query('SELECT 1 FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[ctx.householdId,shop.shop_id,c.base.shopRevision]);
    if(!snapshot.rowCount)throw new ServiceError(409,'stale_base','Identify the actual dated snapshot that was sent.');
    if(Date.parse(b.occurredAt)>ctx.now.getTime()+5*60_000)throw invalid();
    const current=shop.shopper_id===ctx.member.member_id&&shop.authority_epoch===c.base.authorityEpoch&&shop.revision===c.base.shopRevision&&(shop.phase==='draft'||shop.phase==='frozen');
    const reportId=randomUUID();
    await ctx.db.query(`INSERT INTO ritc.placement_report(household_id,report_id,shop_id,actor_id,reported_epoch,reported_revision,occurred_at,state,operation_id)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,[ctx.householdId,reportId,shop.shop_id,ctx.member.member_id,c.base.authorityEpoch,c.base.shopRevision,b.occurredAt,current?'applied':'pending_reconciliation',operationId]);
    if(current)await this.place(ctx,shop,operationId,shop.frozen_revision??shop.revision);
    // Reporter receipt contains only their evidence disposition, never the current shopper's revision or budget.
    return{operationId,kind:c.kind,reportId,disposition:current?'placed':'pending_reconciliation'};
  }
  async startWebSession(householdId:string,identity:VerifiedIdentity,viewGrantId?:string,browserBound=false,selectedShopId?:string,pairedDeviceToken?:string) {
    const device=pairedDeviceToken?{deviceToken:pairedDeviceToken}:await this.enroll(householdId,identity);
    return this.authorized(householdId,{identity,deviceToken:device.deviceToken,...(viewGrantId?{viewGrantId}:{}),...(selectedShopId?{selectedShopId}:{})},async ctx=>{
      const bootstrap=await this.bootstrap(ctx);
      const token=randomBytes(32).toString('base64url'),csrf=randomBytes(32).toString('base64url');
      const expiresAt=new Date(Math.min(identity.expiresAt.getTime(),ctx.now.getTime()+15*60_000));
      const previous=pairedDeviceToken?(await ctx.db.query('SELECT token_hash FROM ritc.web_session WHERE household_id=$1 AND device_id=$2 AND revoked_at IS NULL ORDER BY expires_at DESC,token_hash LIMIT 1',[householdId,ctx.deviceId])).rows[0]:undefined;
      if(previous){
        await ctx.db.query('UPDATE ritc.web_session SET revoked_at=COALESCE(revoked_at,$4) WHERE household_id=$1 AND device_id=$2 AND token_hash<>$3',[householdId,ctx.deviceId,previous.token_hash,ctx.now]);
        await ctx.db.query('UPDATE ritc.web_session SET token_hash=$3,csrf=$4,expires_at=$5,grant_id=$6,browser_bound=$7,shop_id=$8 WHERE household_id=$1 AND token_hash=$2',[householdId,previous.token_hash,tokenHash(token),csrf,expiresAt,viewGrantId??null,browserBound,selectedShopId??null]);
      }else await ctx.db.query('INSERT INTO ritc.web_session(household_id,token_hash,member_id,device_id,csrf,expires_at,grant_id,browser_bound,shop_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)',[householdId,tokenHash(token),ctx.member.member_id,ctx.deviceId,csrf,expiresAt,viewGrantId??null,browserBound,selectedShopId??null]);
      return{cookie:householdId+'.'+token,csrf,expiresAt,session:{authenticated:true,...bootstrap,replayWindow:await this.window(ctx),csrf}};
    });
  }
  async webIdentity(cookie:string,freshIdentity?:VerifiedIdentity) {
    const [householdId,token]=cookie.split('.');
    if(!householdId||!token||!/^[0-9a-f-]{36}$/.test(householdId)||!/^[A-Za-z0-9_-]{43}$/.test(token))throw accessEnded();
    return this.transaction(householdId,async(db,now)=>{
      const s=(await db.query(`SELECT s.csrf,s.expires_at,s.device_id,s.grant_id,s.shop_id,s.browser_bound,m.issuer,m.subject,d.session_id FROM ritc.web_session s
        JOIN ritc.member m USING(household_id,member_id) JOIN ritc.device d USING(household_id,member_id,device_id)
        WHERE s.household_id=$1 AND s.token_hash=$2 AND s.revoked_at IS NULL AND (s.expires_at>$3 OR $4::boolean) AND d.revoked_at IS NULL AND m.state='active'`,[householdId,tokenHash(token),now,Boolean(freshIdentity)])).rows[0];
      if(!s)throw accessEnded();
      if(s.browser_bound&&!freshIdentity)throw new ServiceError(401,'session_needed','Sign in again to continue.');
      if(freshIdentity&&(freshIdentity.issuer!==s.issuer||freshIdentity.subject!==s.subject||freshIdentity.sessionId!==s.session_id))throw accessEnded();
      const identity:VerifiedIdentity=freshIdentity??{issuer:s.issuer,subject:s.subject,sessionId:s.session_id,expiresAt:s.expires_at};
      await this.assertSession(db,identity,now);
      if(freshIdentity)await db.query('UPDATE ritc.web_session SET expires_at=$3 WHERE household_id=$1 AND token_hash=$2',[householdId,tokenHash(token),new Date(Math.min(freshIdentity.expiresAt.getTime(),now.getTime()+15*60_000))]);
      return{householdId,csrf:s.csrf as string,auth:{identity,trustedDeviceId:s.device_id as string,...(s.grant_id?{viewGrantId:s.grant_id as string}:{}),...(s.shop_id?{selectedShopId:s.shop_id as string}:{})}};
    });
  }
  async revokeWebCookie(cookie:string){
    const [householdId,token]=cookie.split('.');
    if(!householdId||!token||!/^[0-9a-f-]{36}$/.test(householdId)||!/^[A-Za-z0-9_-]{43}$/.test(token))return;
    return this.transaction(householdId,async(db,now)=>{
      const session=(await db.query('SELECT device_id FROM ritc.web_session WHERE household_id=$1 AND token_hash=$2',[householdId,tokenHash(token)])).rows[0];
      if(!session)return;
      for(const table of ['web_session','replay_window','device'])await db.query(`UPDATE ritc.${table} SET revoked_at=COALESCE(revoked_at,$3) WHERE household_id=$1 AND device_id=$2`,[householdId,session.device_id,now]);
    });
  }
  async logout(ctx:Context) {
    await ctx.db.query('UPDATE ritc.web_session SET revoked_at=$3 WHERE household_id=$1 AND device_id=$2 AND revoked_at IS NULL',[ctx.householdId,ctx.deviceId,ctx.now]);
    await ctx.db.query('UPDATE ritc.replay_window SET revoked_at=$3 WHERE household_id=$1 AND device_id=$2 AND revoked_at IS NULL',[ctx.householdId,ctx.deviceId,ctx.now]);
    await ctx.db.query('UPDATE ritc.device SET revoked_at=$3 WHERE household_id=$1 AND device_id=$2 AND revoked_at IS NULL',[ctx.householdId,ctx.deviceId,ctx.now]);
    return{signedOut:true};
  }
}
