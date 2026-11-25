import {type TripOptions,checkLinkedPackChanges,decisionPermission} from './trip-substitutions.js';
import {type AdultPickupOptions,respondWithRequest} from './adult-pickup.js';
import {checkPublishingMember,reviewSharedWording} from './shared-content-filter.js';
import {applyPair,checkPairReplay,inboxPairs,rememberPair,reviewPair} from './request-pair.js';
import {proveSameItem,rememberSameItem,sameItemUndo,applySameItem,checkSameItemReplay} from './request-same-item.js';
import {recordTonight,checkTonightReplay} from './household-tonight.js';
import {acceptRepeatStep,assertRepeatStepReplay} from './shared-repeat-week.js';
import {checkDraftDinnerSwap} from './shared-dinner-swap.js';
import {checkIngredientChange} from './meal-preferences.js';
import {isCookCommand} from './cook-completion-contracts.js';
import {cookReceiptExists,recordCook} from './shared-cook-completion.js';
import {captureAcceptanceBefore,finishAcceptanceCapture} from './shared-request-acceptance-lineage.js';
import {requestUndoOperation,applyRequestUndo,assertRequestAcceptanceReplay} from './shared-request-acceptance-repository.js';
import {captureTrackingSnapshot,prepareTrackingFreeze,takeTrackingSeal,assertTrackingPlacement} from './shared-demand-tracking-repository.js';
import {applyDemand,demandOperation,demandSnapshotRef,assertDemandReplay,assertPriceOnly,assertDemandPlacement} from './shared-demand-repository.js';
import { recordOrderAmendment } from './order-amendments.js';
import { carryRequest, deferredRequests, reauthorizeCarry } from './deferred-requests.js';
import type {BillingService} from './billing/service.js';
import {recordCurrentDelivery,recordCurrentPantry} from './shared-recovery-basis.js';
import {loadRecoveryPublication,recordSharedRecovery} from './shared-recovery-publication.js';
import { sharedMealSchema, moveSharedMeal, preserveProtectedMeal } from './shared-meal-planning.js';
import { cookCopyStillExists, recordCookCopy } from './cook-copy.js';
import { isPantryCommand, pantryOperationExists, householdPantryEpoch } from './pantry-lots.js';
import { consumeSharedMealChange } from './shared-meal-changes.js';
import {requireMealMove} from './meal-moves.js';
import { randomBytes, randomUUID } from 'node:crypto';
import type { OwnRequest, ShopperReceipt, RequestPurchaseOutcome, RequestPreview, QuoteBasis, BasketLine, GroceryCurrency } from '../../shared/contracts/service-v1.js';
import type { VerifiedIdentity,SessionStatusVerifier } from './auth.js';
import { type Database,type Transaction,digest,tokenHash } from './database.js';
import { accessEnded,unavailable,invalid,refresh,ServiceError } from './errors.js';
import { type Envelope,type Decision,type PreviewInput,bodySchemas,decisionSchema } from './contracts.js';
import { checkout } from './checkout.js';
import {requireMatchingCurrency,requireSupportedCurrency} from './grocery-currency.js';
export interface AuthContext { supportsMXN?:boolean; sharedContentSafety?:boolean;identity:VerifiedIdentity; deviceToken?:string; trustedDeviceId?:string;ownRequestsOnly?:boolean;viewGrantId?:string;selectedShopId?:string;historicalReportShopId?:string }
export interface Member { member_id:string; kind:'adult'|'child'; organizer:boolean; can_contribute:boolean; preference_reader?:boolean; pantry_editor?:boolean; pantry_grant_epoch?:number; alias:string; state:string }
export interface Context { supportsMXN?:boolean; sharedContentSafety?:boolean;db:Transaction; householdId:string; member:Member; deviceId:string; now:Date;ownRequestsOnly?:boolean;viewGrantId?:string;selectedShopId?:string }
export interface Shop { household_id:string;shop_id:string;shopper_id:string;authority_epoch:number;revision:number;phase:string;currency:GroceryCurrency;quote:QuoteBasis;frozen_revision:number|null;placed_revision:number|null;supply_revision:number;recovery_revision?:number;store_basis_revision?:number|null;store_review_required?:boolean;confirmed_order_erased?:boolean;demand_revision?:number|null;demand_review_required?:boolean }
export interface RequestRow { author_active:boolean;author_kind:string;author_alias:string;live_notice:string|null; carried_forward?:boolean;from_previous_shop?:boolean; purchase_outcome?:RequestPurchaseOutcome|null;request_id:string;author_id:string;shop_id:string;original_item:string;own_quantity:string|null;revision:number;authored_at:Date;received_at:Date;route:'current'|'next';status:OwnRequest['status'];clarification:string|null;clarification_author_id?:string|null;followup_to:string|null }
// Earlier servers accept exactly 43 base64url characters. Include the scope
// prefix in the hashed credential so removing it cannot bypass that boundary.
const contributorCookiePrefix='own_';
function scopedCookieParts(cookie:string) {
  const match=/^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.((?:own_)?[A-Za-z0-9_-]{43})$/.exec(cookie);
  return match ? {householdId:match[1]!,token:match[2]!} : null;
}
const editable=(r:RequestRow)=>!r.carried_forward && (r.status==='pending'||r.status==='clarified');
export function ownRequest(r:RequestRow):OwnRequest {
  return {requestId:r.request_id,shopId:r.shop_id,revision:r.revision,originalItem:r.original_item,ownQuantity:r.own_quantity,
    ...(r.status==='added' && (r.purchase_outcome==='bought' || r.purchase_outcome==='notBought')?{purchaseOutcome:r.purchase_outcome}:{}),
    authoredAt:r.authored_at.toISOString(),receivedAt:r.received_at.toISOString(),route:r.route,status:r.status,
    ...(r.carried_forward?{carriedForward:true}:{}),...(r.from_previous_shop?{fromPreviousShop:true}:{}),
    ownActionAllowed:editable(r),clarification:r.clarification,followupTo:r.followup_to};
}
export class HouseholdRepository {
  constructor(readonly pool:Database,readonly options:TripOptions & AdultPickupOptions & {allowChildNetwork:boolean;noticeVersion:string;sessionStatus?:SessionStatusVerifier;trackingV2?:boolean;sharedContentSafety?:boolean;moderationRetentionDays?:number}) {}
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
  async transaction<T>(householdId:string,fn:(db:Transaction,now:Date)=>Promise<T>,readOnly=false):Promise<T> {
    const db=await this.pool.connect();
    try {
      await db.query('BEGIN');
      await db.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='3s'");
      await db.query("SELECT set_config('app.household_id',$1,true)",[householdId]);
      const house=await db.query('SELECT household_id FROM ritc.household WHERE household_id=$1 FOR UPDATE',[householdId]);
      if(!house.rowCount)throw unavailable();
      const now=(await db.query<{now:Date}>('SELECT clock_timestamp() AS now')).rows[0]!.now;
      const result=await fn(db,now);
      // The live provider check locks its row FOR SHARE. End preview reads by rollback.
      await db.query(readOnly?'ROLLBACK':'COMMIT');return result;
    }catch(error) {await db.query('ROLLBACK');throw error;}finally{db.release();}
  }
  async member(db:Transaction,householdId:string,identity:VerifiedIdentity):Promise<Member> {
    const member=(await db.query<Member>('SELECT member_id,kind,organizer,can_contribute,preference_reader,pantry_editor,pantry_grant_epoch,alias,state FROM ritc.member WHERE household_id=$1 AND issuer=$2 AND subject=$3',[householdId,identity.issuer,identity.subject])).rows[0];
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
  async authorized<T>(householdId:string,auth:AuthContext,fn:(ctx:Context)=>Promise<T>,readOnly=false):Promise<T> {
    return this.transaction(householdId,(db,now)=>this.authorizedInTransaction(db,now,householdId,auth,fn),readOnly);
  }
  private async authorizedInTransaction<T>(db:Transaction,now:Date,householdId:string,auth:AuthContext,fn:(ctx:Context)=>Promise<T>):Promise<T> {
    await this.assertSession(db,auth.identity,now);
    const member=await this.member(db,householdId,auth.identity);
    const device=(await db.query<{device_id:string}>(`SELECT device_id FROM ritc.device WHERE household_id=$1 AND member_id=$2
      AND session_id=$3 AND revoked_at IS NULL AND ${auth.trustedDeviceId?'device_id=$4':'token_hash=$4'}`,
      [householdId,member.member_id,auth.identity.sessionId,auth.trustedDeviceId??tokenHash(auth.deviceToken??'')])).rows[0];
    if(!device)throw accessEnded();
    if(member.kind==='child'){const generation=await db.query(`SELECT 1 FROM ritc.device d JOIN ritc.consent c ON c.household_id=d.household_id AND c.consent_id=d.guardian_consent_id JOIN ritc.guardian_enrollment e ON e.household_id=c.household_id AND e.consent_id=c.consent_id WHERE d.household_id=$1 AND d.device_id=$2 AND c.child_id=$3 AND c.revoked_at IS NULL AND e.state='active'`,[householdId,device.device_id,member.member_id]);if(!generation.rowCount)throw accessEnded();}
    await db.query("SELECT set_config('app.content_viewer',$1,true)",[member.member_id]);
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
    if(auth.ownRequestsOnly && (!member.can_contribute || auth.viewGrantId)) throw accessEnded();
    const scopedMember=auth.viewGrantId||auth.ownRequestsOnly
      ? {...member,organizer:false,can_contribute:!auth.viewGrantId && member.can_contribute}
      : member;
    return fn({supportsMXN:auth.supportsMXN===true,sharedContentSafety:auth.sharedContentSafety===true&&this.options.sharedContentSafety===true,db,householdId,member:scopedMember,deviceId:device.device_id,now,...(auth.ownRequestsOnly?{ownRequestsOnly:true}:{}),...(auth.viewGrantId?{viewGrantId:auth.viewGrantId}:{}),...(auth.selectedShopId?{selectedShopId:auth.selectedShopId}:{})});
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
    return this.transaction(householdId,(db,now)=>this.enrollInTransaction(db,now,householdId,identity));
  }
  private async enrollInTransaction(db:Transaction,now:Date,householdId:string,identity:VerifiedIdentity) {
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
    } else if (!current.requestQueueGrant) {
      const until = (await this.window(ctx)).expiresAt;
      await ctx.db.query(`INSERT INTO ritc.request_queue_permission(household_id,member_id,device_id,grant_id,enabled_at,expires_at)
        VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(household_id,member_id,device_id)
        DO UPDATE SET grant_id=excluded.grant_id,enabled_at=excluded.enabled_at,expires_at=excluded.expires_at`,
        [...key,randomUUID(),ctx.now,until]);
    }
    return this.bootstrap(ctx);
  }
  async bootstrap(ctx:Context,includeSharedContentSafety=ctx.sharedContentSafety) {
    const house=(await ctx.db.query('SELECT label FROM ritc.household WHERE household_id=$1',[ctx.householdId])).rows[0];
    const candidates = (await ctx.db.query<{shop_id:string;shopper_id:string;phase:string;placed_revision:number|null;budget_access:boolean}>(`
      SELECT s.shop_id,s.shopper_id,s.phase,s.placed_revision,
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
       ctx.member.can_contribute||ctx.member.organizer,ctx.member.kind==='adult'&&!ctx.viewGrantId&&!ctx.ownRequestsOnly])).rows;
    const shop=ctx.selectedShopId?candidates[0]:candidates.length===1?candidates[0]:undefined;
    if(ctx.selectedShopId&&!shop)throw accessEnded();
    const helper=ctx.ownRequestsOnly?undefined:(await ctx.db.query(`SELECT g.grant_id,g.shop_id,g.mode FROM ritc.view_grant g JOIN ritc.member creator ON creator.household_id=g.household_id AND creator.member_id=g.created_by
      WHERE g.household_id=$1 AND g.recipient_id=$2 AND g.revoked_at IS NULL AND g.expires_at>$3 AND creator.state='active' AND ($4::uuid IS NULL OR g.grant_id=$4) ORDER BY g.as_of DESC,g.grant_id LIMIT 1`,[ctx.householdId,ctx.member.member_id,ctx.now,ctx.viewGrantId??null])).rows[0];
    if(ctx.viewGrantId&&!helper)throw accessEnded();
    const isShopper=!ctx.ownRequestsOnly&&!ctx.viewGrantId&&ctx.member.kind==='adult'&&shop?.shopper_id===ctx.member.member_id;
    const hasBudgetAccess = !ctx.ownRequestsOnly && !ctx.viewGrantId && ctx.member.kind === 'adult' &&
      ((await ctx.db.query(`SELECT 1 FROM ritc.shop_budget_grant g
        JOIN ritc.shop s USING(household_id,shop_id,authority_epoch)
        WHERE g.household_id=$1 AND g.member_id=$2 AND g.enabled AND s.phase<>'closed' LIMIT 1`,
        [ctx.householdId,ctx.member.member_id])).rowCount ?? 0) > 0;
    const pantryAccess=householdPantryEpoch(ctx)!==null;
    const preferenceAccess=!ctx.viewGrantId&&!ctx.ownRequestsOnly&&ctx.member.kind==='adult'&&ctx.member.state==='active'&&
      (ctx.member.organizer||ctx.member.preference_reader);

    const helperRole=!pantryAccess&&!preferenceAccess&&!ctx.selectedShopId&&!isShopper&&!ctx.member.organizer&&!hasBudgetAccess&&helper;
    const queueEligible = !ctx.viewGrantId && !helperRole && ctx.member.kind === 'adult' && ctx.member.can_contribute;
    const grant = queueEligible ? (await ctx.db.query<{request_queue_grant:string,request_queue_until:Date}>(
      'SELECT grant_id AS request_queue_grant,expires_at AS request_queue_until FROM ritc.request_queue_permission WHERE household_id=$1 AND member_id=$2 AND device_id=$3 AND enabled_at<=$4 AND expires_at>$4',
      [ctx.householdId,ctx.member.member_id,ctx.deviceId,ctx.now])).rows[0] : undefined;
    const planning = !ctx.ownRequestsOnly && !ctx.viewGrantId && !helperRole && !isShopper && shop && ctx.member.kind==='adult' &&
      (await ctx.db.query(`SELECT 1 FROM ritc.meal_planner p JOIN ritc.shop s USING(household_id,shop_id,authority_epoch)
       WHERE p.household_id=$1 AND p.shop_id=$2 AND p.planner_id=$3 AND s.phase<>'closed'`,[ctx.householdId,shop.shop_id,ctx.member.member_id])).rowCount;
    const lateCutoff=shop?.phase==='draft'&&this.options.adultLastCall&&ctx.member.kind==='adult'&&ctx.member.can_contribute&&
      !helperRole&&!ctx.viewGrantId&&shop.shopper_id!==ctx.member.member_id&&
      (await ctx.db.query('SELECT ritc.pickup_cutoff_passed($1,$2,$3,$4) AS late',[ctx.householdId,shop.shop_id,ctx.member.member_id,ctx.now])).rows[0]?.late;
    const adultPickup=!helperRole&&!ctx.viewGrantId&&!ctx.ownRequestsOnly&&ctx.member.kind==='adult'&&(ctx.member.can_contribute||isShopper);
    return{household:{id:ctx.householdId,label:house.label as string},memberId:ctx.member.member_id,
      canSelectShop:!ctx.ownRequestsOnly&&!helperRole&&!ctx.viewGrantId&&ctx.member.kind==='adult'&&(ctx.member.can_contribute||ctx.member.organizer||isShopper||hasBudgetAccess),
      selectionRequired:!helperRole&&!ctx.viewGrantId&&!ctx.selectedShopId&&candidates.length>1,role:isShopper?'shopper':ctx.member.organizer?'organizer':helperRole?(helper.mode==='edit'?'editor':'helper'):'contributor',shopId:helperRole?helper.shop_id:shop?.shop_id??null,...(helperRole?{grantId:helper.grant_id}:{}),enrolled:true,canSetRequestQueue:Boolean(queueEligible),queueConsent:false,
      ...(shop && !helperRole && ctx.member.can_contribute ? {nextShopOnly:shop.phase!=='draft'||Boolean(lateCutoff)} : {}),
      ...(grant ? {requestQueueGrant:grant.request_queue_grant,requestQueueUntil:grant.request_queue_until.toISOString()} : {}),
      capabilities:[...(adultPickup&&shop&&['draft','frozen'].includes(shop.phase)&&this.options.sharedContentSafety&&this.options.moderationRetentionDays
        ?[...(this.options.tripSubstitutions?['trip_substitutions']:[]),...(this.options.sharedPicking?['shared_picking']:[])]:[]),
        ...(adultPickup&&this.options.adultLastCall?['adult_last_call']:[]),
        ...(adultPickup&&this.options.sharedContentSafety&&this.options.adultProductReferenceDays?['adult_product_reference',...(this.options.adultProductReferenceMedia?['adult_product_reference_media']:[])]:[]),
        ...(includeSharedContentSafety&&this.options.sharedContentSafety?['shared_content_safety']:[]),...(preferenceAccess?['meal_preferences_read']:[]),
        ...(preferenceAccess&&ctx.member.organizer?['meal_preferences_admin']:[]),...(pantryAccess?['household_pantry','household_tonight','my_feedback_withdrawal']:[]),...(pantryAccess && isShopper && shop?.placed_revision!=null?['cook_completion','meal_feedback']:[]),...(pantryAccess&&ctx.member.organizer?['household_pantry_grants']:[]),...(queueEligible?['request_queue_permission']:[]),...(!helperRole&&!ctx.viewGrantId&&(isShopper||shop?.budget_access)?['store_quotes']:[]),...(isShopper && shop?.placed_revision!=null?['confirmed_order','delivery_evidence','cook_copies','cook_corrections','pantry_lots','meal_recovery','request_purchase_confirmation','request_purchase_attribution']:[]),...(planning?['meal_proposals']:[]),...(ctx.member.can_contribute?['own_requests']:[]),...(isShopper?['shopper_inbox','request_preview','shopper_commands','request_same_item','request_pair_review','accepted_fallbacks','deferred_requests']:[]),...(ctx.member.organizer?['household_admin']:[]),...(helperRole?['helper_view',...(helper.mode==='edit'?['helper_propose']:[])]:[])]};
  }
  async shops(ctx:Context,scope:'active'|'owned'|'history-owned'|'requests',after:string|null){
    if(ctx.viewGrantId)throw unavailable();
    if(scope==='requests'){
      if(!ctx.member.can_contribute || (await this.bootstrap(ctx)).grantId)throw unavailable();
    }else if(ctx.ownRequestsOnly||ctx.member.kind!=='adult')throw unavailable();
    const values:unknown[]=[ctx.householdId,scope==='requests'?ctx.selectedShopId??null:ctx.member.member_id];
    let visible='s.shopper_id=$2';
    if(scope==='requests'){
      visible="s.phase<>'closed' AND ($2::uuid IS NULL OR s.shop_id=$2)";
    }else if(scope==='active'){
      visible=`s.phase<>'closed' AND (s.shopper_id=$2 OR $3::boolean OR EXISTS(
        SELECT 1 FROM ritc.shop_budget_grant g WHERE g.household_id=s.household_id AND g.shop_id=s.shop_id
        AND g.member_id=$2 AND g.enabled AND g.authority_epoch=s.authority_epoch))`;
      values.push(ctx.member.can_contribute||ctx.member.organizer);
    }else if(scope==='history-owned'){
      visible+=' AND s.history_retired_at IS NULL AND ($3::uuid IS NULL OR s.shop_id=$3)';
      values.push(ctx.selectedShopId??null);
      if(!ctx.supportsMXN)visible+=" AND s.currency='USD'";
    }
    const source=`FROM ritc.shop s WHERE s.household_id=$1 AND ${visible}`;
    let boundary='';
    if(after){
      const cursorValues=[...values,after];
      const record=(await ctx.db.query(`SELECT s.created_at::text AS created_at ${source} AND s.shop_id=$${cursorValues.length}`,cursorValues)).rows[0];
      if(!record)throw unavailable();
      values.push(record.created_at,after);
      boundary=` AND (s.created_at,s.shop_id)<($${values.length-1}::timestamptz,$${values.length}::uuid)`;
    }
    let cutoff='false';
    if(scope==='requests'&&this.options.adultLastCall&&ctx.member.kind==='adult'){
      values.push(ctx.member.member_id,ctx.now);
      cutoff=`ritc.pickup_cutoff_passed(s.household_id,s.shop_id,$${values.length-1},$${values.length})`;
    }
    const rows=(await ctx.db.query(`SELECT s.shop_id,s.shopper_id,s.created_at,s.phase,s.revision,s.authority_epoch,s.currency,${cutoff} AS late
      ${source}${boundary} ORDER BY s.created_at DESC,s.shop_id DESC LIMIT 51`,values)).rows;
    if(scope==='requests')return{shops:rows.slice(0,50).map(s=>({
      shopId:s.shop_id,createdAt:s.created_at.toISOString(),nextShopOnly:s.phase!=='draft'||s.late
    })),nextCursor:rows.length>50?rows[49].shop_id:null};
    return{shops:rows.slice(0,50).map(s=>({shopId:s.shop_id,createdAt:s.created_at.toISOString(),phase:s.phase,...(ctx.supportsMXN?{currency:s.currency}:{}),role:s.shopper_id===ctx.member.member_id?'shopper':'contributor',...(s.shopper_id===ctx.member.member_id?{revision:s.revision,authorityEpoch:s.authority_epoch}:{})})),nextCursor:rows.length>50?rows[49].shop_id:null};
  }
  private get carryNotice() {return this.options.allowChildNetwork?this.options.noticeVersion:null;}
  async deferredRequests(ctx:Context,shopId:string,after:string|null) {
    const shop=await this.shop(ctx,shopId);
    this.requireShopper(ctx,shop);
    this.requireDraft(shop);
    return deferredRequests(ctx,shop,this.carryNotice,after);
  }
  async requests(ctx:Context,after:string|null,shopId?:string) {
    const shop=shopId ? await this.shop(ctx,shopId) : undefined;
    if(shop)this.requireShopper(ctx,shop);
    let cursor:{received_at:string;request_id:string}|undefined;
    if(after) {
      cursor=(await ctx.db.query<{received_at:string;request_id:string}>(`SELECT received_at::text AS received_at,request_id FROM ritc.visible_request_origin WHERE (NOT (carried_forward OR from_previous_shop) OR (author_active AND (author_kind='adult' OR live_notice=$5))) AND household_id=$1 AND request_id=$2 AND ${shopId?'shop_id':'author_id'}=$3 AND ($4::uuid IS NULL OR shop_id=$4)`,[ctx.householdId,after,shopId??ctx.member.member_id,ctx.selectedShopId??null,this.carryNotice])).rows[0];
      if(!cursor)throw unavailable();
    }
    const params:unknown[]=[ctx.householdId,shopId??ctx.member.member_id,ctx.selectedShopId??null,this.carryNotice];
    if(cursor)params.push(cursor.received_at,cursor.request_id);
    // The placed link attests to a line in the sealed order. The draft link
    // identifies an earlier shopper decision about an item still in this basket.
    let linkJoin='';
    if(shop?.phase==='draft'){
      linkJoin=`LEFT JOIN (ritc.request_link l INNER JOIN ritc.basket_line b USING(household_id,shop_id,line_id))
        ON (l.household_id,l.shop_id,l.request_id)=(r.household_id,r.shop_id,r.request_id) AND r.status='added'`;
    }else if(shop){
      linkJoin='LEFT JOIN ritc.placed_request_link l ON (l.household_id,l.shop_id,l.request_id)=(r.household_id,r.shop_id,r.request_id)';
    }
    const result=await ctx.db.query<RequestRow & {author_alias?:string;linked_line_id?:string;same_item_operation?:string;buyer_alias?:string;recorder_alias?:string}>(`SELECT r.*,p.outcome AS purchase_outcome
      ${shopId?`,l.line_id AS linked_line_id,buyer.alias AS buyer_alias,recorder.alias AS recorder_alias,(SELECT e.operation_id FROM ritc.request_same_item e
        WHERE e.household_id=r.household_id AND e.request_id=r.request_id AND e.request_revision+1=r.revision
          AND r.status='handled' AND NOT e.invalidated AND e.undo_operation_id IS NULL AND e.operation_id IS NOT NULL) AS same_item_operation`:''}
      FROM ritc.visible_request_origin r LEFT JOIN ritc.request_purchase_review p
        ON (p.household_id,p.request_id,p.request_revision)=(r.household_id,r.request_id,r.revision)
      ${linkJoin}
      ${shopId?`LEFT JOIN ritc.request_purchase_buyer attributed ON (attributed.household_id,attributed.operation_id)=(p.household_id,p.operation_id)
        LEFT JOIN ritc.member buyer ON (buyer.household_id,buyer.member_id)= (attributed.household_id,attributed.buyer_id) AND buyer.state='active'
        LEFT JOIN ritc.member recorder ON (recorder.household_id,recorder.member_id)=(p.household_id,p.actor_id) AND recorder.state='active'` : ''}
      WHERE r.household_id=$1 AND r.${shopId?'shop_id':'author_id'}=$2 AND ($3::uuid IS NULL OR r.shop_id=$3)
      AND (NOT (r.carried_forward OR r.from_previous_shop) OR (r.author_active AND (r.author_kind='adult' OR r.live_notice=$4)))
      ${cursor?'AND (r.received_at,r.request_id)>($5,$6)':''} ORDER BY r.received_at,r.request_id LIMIT 51`,params);
    const rows=result.rows.slice(0,50);
    const pairs=shop?await inboxPairs(ctx,shop,rows.map(r=>r.request_id),this.carryNotice):undefined;
    const requests=rows.map(r=>({
      ...ownRequest(r),
      ...(ctx.sharedContentSafety&&r.author_id!==ctx.member.member_id?{canReportContent:true}:{}),
      ...(ctx.sharedContentSafety&&r.clarification&&r.clarification_author_id!==ctx.member.member_id?{canReportClarification:true}:{}),
      ...(shop ? {authorAlias:r.author_alias} : {}),
      ...(pairs?.has(r.request_id)?{requestPairs:pairs.get(r.request_id)}:{}),
      ...(shop?.placed_revision && r.author_active && r.author_kind==='adult' && r.author_id!==ctx.member.member_id
        ? {canReportAuthorAsPurchaser:true} : {}),
      ...(shop && r.linked_line_id && r.purchase_outcome==='bought' && r.buyer_alias ? {reportedPurchaser:r.buyer_alias} : {}),
      ...(shop && r.linked_line_id && (r.purchase_outcome==='bought'||r.purchase_outcome==='notBought') && r.recorder_alias
        ? {purchaseRecordedBy:r.recorder_alias} : {}),
      ...(shop && r.same_item_operation ? {sameItemOperationId:r.same_item_operation} : {}),
      ...(shop && r.linked_line_id
        ? (shop.phase==='draft' ? {draftBasketLineId:r.linked_line_id} : {linkedLineId:r.linked_line_id})
        : {})
    }));
    return {asOf:ctx.now.toISOString(),requests,nextCursor:result.rows.length>50?rows.at(-1)!.request_id:null};
  }
  async shop(ctx:Context,shopId:string):Promise<Shop> {
    if(ctx.selectedShopId&&ctx.selectedShopId!==shopId)throw unavailable();
    const shop=(await ctx.db.query<Shop>('SELECT * FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shopId])).rows[0];
    if(!shop)throw unavailable();return shop;
  }
  requireShopper(ctx:Context,shop:Shop) {if(ctx.ownRequestsOnly||ctx.viewGrantId||ctx.member.kind!=='adult'||shop.shopper_id!==ctx.member.member_id)throw unavailable();requireSupportedCurrency(ctx,shop.currency);}
  requireOrganizer(ctx:Context) {if(ctx.ownRequestsOnly||ctx.viewGrantId||ctx.member.kind!=='adult'||!ctx.member.organizer)throw unavailable();}
  checkBase(shop:Shop,base:Envelope['base']) {
    if(shop.authority_epoch!==base.authorityEpoch)throw new ServiceError(409,'authority_changed','Refresh shopper authority and review again.');
    if(shop.revision!==base.shopRevision)throw new ServiceError(409,'stale_base','Refresh the shop and review again.');
  }
  requireDraft(shop:Shop) {if(shop.phase!=='draft')throw new ServiceError(409,'checkout_locked','Review the frozen order or save this for next shop.');}
  async request(ctx:Context,id:string,shopId:string,own=false):Promise<RequestRow> {
    const r=(await ctx.db.query<RequestRow>("SELECT * FROM ritc.visible_request_origin WHERE household_id=$1 AND request_id=$2 AND shop_id=$3 AND (NOT (carried_forward OR from_previous_shop) OR (author_active AND (author_kind='adult' OR live_notice=$4)))",[ctx.householdId,id,shopId,this.carryNotice])).rows[0];
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
  private async snapshot(ctx:Context,shopId:string,operationId:string,purpose:string,storeBasisKnown=true) {
    const shop=await this.shop(ctx,shopId),lines=await this.lines(ctx,shopId);
    const mealRefs=(await this.meals(ctx,shopId)).map(({occurrenceId,revision})=>({occurrenceId,revision}));
    const tracking=await captureTrackingSnapshot(this,ctx,shop,operationId),trackingSeal=takeTrackingSeal(ctx,shopId);
    const demand=await demandSnapshotRef(ctx,shop,purpose==='reopen');
    // The internal store-adoption write precedes its basis update. Omit unknown
    // basis there rather than attest the previous selection as its final state.
    const snapshot={shopId,...(tracking?{tracking}:{}),...(trackingSeal?{trackingSeal}:{}),...(storeBasisKnown?{storeBasis:{revision:shop.store_basis_revision??null,reviewRequired:shop.store_review_required??false}}:{}),...(demand?{demand}:{}),...(mealRefs.length ? {mealRefs} : {}),revision:shop.revision,phase:shop.phase,quote:shop.quote,lines,budget:checkout(lines,shop.quote)};
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
    if(r.carried_forward||input.decision.choice!=='undoSameItem'&&!editable(r)&&!(r.status==='deferred'&&('promote'in input.decision)&&input.decision.promote))throw new ServiceError(409,'already_handled','Review the current request status.');
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
    const pair=input.decision.choice==='reviewRequestPair'||input.decision.choice==='undoRequestPair'?await reviewPair(this,ctx,shop,r,input.decision):null;
    const proof=input.decision.choice==='sameItem'?await proveSameItem(this,ctx,shop,r,input.decision.target):null;
    if(input.decision.choice==='undoSameItem')await sameItemUndo(this,ctx,shop,r,input.decision.operationId);
    const permission=await decisionPermission(this,ctx,shop,r,input.decision,lines);
    const fingerprint=digest({shop,r:ownRequest(r),lines,decision:input.decision,...permission,...(proof?{targetProof:proof.digest}:{}),...(pair?{pairProof:pair.fingerprint}:{})});
    await ctx.db.query(`INSERT INTO ritc.preview(household_id,preview_id,shop_id,actor_id,request_id,shop_revision,request_revision,authority_epoch,decision,fingerprint,expires_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,[ctx.householdId,previewId,shopId,ctx.member.member_id,r.request_id,shop.revision,r.revision,shop.authority_epoch,input.decision,fingerprint,expiresAt]);
    if(pair && input.decision.choice==='reviewRequestPair')await rememberPair(ctx,shop,r,previewId,pair.evidence);
    if(proof)await rememberSameItem(ctx,shop,r,previewId,proof);
    return{...(pair?{requestPairEvidence:pair.evidence}:{}),...(proof?{sameItemEvidence:proof.evidence}:{}),previewId,expiresAt:expiresAt.toISOString(),shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,requestRevision:r.revision,choice:input.decision.choice,...facts};
  }
  async execute(ctx:Context,command:Envelope,billing?:BillingService,queueGrant?:string,internalPriceOnly=false):Promise<unknown> {
    if(ctx.selectedShopId && command.shopId!==ctx.selectedShopId) throw unavailable();
    const window=(await ctx.db.query('SELECT 1 FROM ritc.replay_window WHERE household_id=$1 AND window_id=$2 AND member_id=$3 AND device_id=$4 AND revoked_at IS NULL AND expires_at>$5',[ctx.householdId,command.replayWindow,ctx.member.member_id,ctx.deviceId,ctx.now])).rowCount;
    const queueEnded=()=>new ServiceError(409,'queue_permission_ended','Review current received requests before sending a new request.');
    const queueAuthority=queueGrant ? await this.bootstrap(ctx) : undefined;
    if(queueGrant && !queueAuthority?.canSetRequestQueue)throw queueEnded();
    if(!window)throw queueGrant ? queueEnded() : refresh();
    const payloadDigest=queueGrant ? digest({command,queueGrant}) : digest(command);
    const prior=(await ctx.db.query(`SELECT o.*,r.response FROM ritc.operation o LEFT JOIN ritc.operation_response r USING(household_id,operation_id)
      WHERE o.household_id=$1 AND o.actor_id=$2 AND o.client_key=$3`,[ctx.householdId,ctx.member.member_id,command.clientKey])).rows[0];
    if(prior) {
      // Reauthorize the original scope before returning anything about a prior result.
      if(prior.pantry_grant_epoch!=null && householdPantryEpoch(ctx)!==prior.pantry_grant_epoch) throw refresh();
      if(prior.response_scope==='shopper'){
        const shop=await this.shop(ctx,prior.shop_id);this.requireShopper(ctx,shop);
        await assertDemandReplay(this,ctx,shop,prior.operation_id);
        await assertRequestAcceptanceReplay(this,ctx,shop,prior,command);
        if (prior.kind === 'shop.patch' && command.kind === 'shop.patch' && command.body.mealEdit &&
            prior.payload_digest === payloadDigest && prior.device_id === ctx.deviceId) {
          const edit = bodySchemas['shop.patch'].parse(command.body).mealEdit;
          if (edit?.repeatPlanId) {
            await assertRepeatStepReplay(ctx, billing, shop, edit.repeatPlanId, edit.occurrenceId, prior.operation_id);
          }
        }
        if(prior.kind==='request.apply'){
          await checkSameItemReplay(this,ctx,shop,prior.operation_id,prior.response?.authorityEpoch);
          await checkPairReplay(this,ctx,shop,prior.operation_id,prior.response?.authorityEpoch);
        }
        if(prior.kind==='amendment.recordResponse' && (prior.response?.authorityEpoch!==shop.authority_epoch || shop.confirmed_order_erased || !(await ctx.db.query(
          'SELECT 1 FROM ritc.order_amendment WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,prior.operation_id])).rowCount)) throw refresh();
        if(prior.kind==='request.carry')await reauthorizeCarry(ctx,shop,this.carryNotice,prior.operation_id);
        if(prior.kind==='request.confirmPurchase' && (prior.response?.authorityEpoch!==shop.authority_epoch || !(await ctx.db.query(
          'SELECT 1 FROM ritc.request_purchase_review WHERE household_id=$1 AND operation_id=$2',[ctx.householdId,prior.operation_id])).rowCount)) throw refresh();
        if(prior.kind==='meal.chooseTonight'){if(prior.response?.authorityEpoch!==shop.authority_epoch)throw refresh();await checkTonightReplay(ctx,shop,prior.operation_id,prior.response?.secondOccurrenceId?2:1);}
        if(prior.kind==='mealRecovery.apply') {
          if(prior.response?.authorityEpoch!==shop.authority_epoch || !(await ctx.db.query(
            'SELECT 1 FROM ritc.meal_recovery_revision WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3 AND current_meal IS NOT NULL',
            [ctx.householdId,shop.shop_id,prior.operation_id])).rowCount) throw refresh();
        }
        if(prior.kind==='cookCopy.save' || prior.kind==='cookCopy.markSent') {
          if(prior.response?.authorityEpoch!==shop.authority_epoch ||
             !await cookCopyStillExists(ctx,shop,prior.kind,prior.operation_id)) throw refresh();
        }
        if(isCookCommand(prior.kind) && !await cookReceiptExists(ctx,shop,prior.response)) throw refresh();
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
      if(prior.response_scope==='own' && prior.response.request) {
        const receipt=prior.response.request;
        const current=await this.request(ctx,receipt.requestId,command.shopId,true);
        if(receipt.originalItem!==current.original_item || receipt.ownQuantity!==current.own_quantity) {
          const historical=await ctx.db.query("SELECT ritc.shared_content_visible($1,$2,$2,'request',$3,1,$4) AS visible",
            [ctx.householdId,ctx.member.member_id,receipt.requestId,receipt.revision]);
          if(!historical.rows[0]?.visible) throw refresh();
        }
        // An immutable retry receipt cannot disclose a superseded or hidden question.
        if(receipt.clarification!==current.clarification) return {...prior.response,request:{...receipt,clarification:null}};
      }
      return prior.response;
    }
    if(queueGrant && queueAuthority?.requestQueueGrant!==queueGrant) {
      throw queueEnded();
    }
    const operationId=command.kind==='request.undoAcceptance'?await requestUndoOperation(ctx,command):await demandOperation(ctx,command);
    let scope:'own'|'shopper'|'organizer'|'reporter'='shopper';
    let response:unknown;
    if(command.kind==='shop.create') {
      this.requireOrganizer(ctx);scope='organizer';
      if(command.base.shopRevision!==0||command.base.authorityEpoch!==0)throw invalid();
      const body=bodySchemas['shop.create'].parse(command.body);requireSupportedCurrency(ctx,body.quote.currency);this.validateQuote(body.quote,ctx.now);checkout(body.lines,body.quote);
      const exists=await ctx.db.query('SELECT 1 FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,command.shopId]);
      if(exists.rowCount)throw new ServiceError(409,'shop_exists','Open the existing shop.');
      await ctx.db.query('INSERT INTO ritc.shop(household_id,shop_id,shopper_id,quote,currency) VALUES($1,$2,$3,$4,$5)',[ctx.householdId,command.shopId,ctx.member.member_id,body.quote,body.quote.currency]);
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
        this.requireShopper(ctx,shop);
        // An exact successful replay already returned above. This uncommitted freeze can never apply to its superseded revision.
        if(this.options.trackingV2&&command.kind==='shop.freeze'&&command.body.trackingReview&&
          command.base.authorityEpoch===shop.authority_epoch&&command.base.shopRevision<shop.revision)
          throw new ServiceError(409,'tracking_freeze_superseded','Review the current pickup before freezing.');
        this.checkBase(shop,command.base);
        response=await this.shopperCommand(ctx,shop,command,operationId,billing,internalPriceOnly);
      }
    }
    await ctx.db.query(`INSERT INTO ritc.operation(household_id,operation_id,actor_id,device_id,client_key,window_id,kind,shop_id,payload_digest,response_scope,pantry_grant_epoch)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,CASE WHEN $13::boolean THEN $11::integer ELSE (SELECT $11::integer FROM ritc.pantry_lot
        WHERE household_id=$1 AND lot_id=$12 AND origin_shop_id IS NULL) END)`,[ctx.householdId,operationId,ctx.member.member_id,ctx.deviceId,command.clientKey,command.replayWindow,command.kind,command.shopId,payloadDigest,scope,householdPantryEpoch(ctx),isPantryCommand(command.kind)?command.body.lotId??null:null,isCookCommand(command.kind)]);
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
      await checkPublishingMember(ctx);
      reviewSharedWording(b.originalItem,b.ownQuantity);
      if(b.followupTo)await this.request(ctx,b.followupTo,shop.shop_id,true);
      else if(shop.phase==='closed')throw new ServiceError(409,'pickup_closed','Choose an open pickup for this request.');
      if(Date.parse(b.authoredAt)>ctx.now.getTime()+24*60*60_000)throw invalid();
      const dup=await ctx.db.query('SELECT 1 FROM ritc.request WHERE household_id=$1 AND author_id=$2 AND client_request_id=$3',[ctx.householdId,ctx.member.member_id,b.clientRequestId]);
      if(dup.rowCount)throw new ServiceError(409,'request_id_reused','Refresh your request list before submitting a new request.');
      const cutoffPassed=this.options.adultLastCall&&await respondWithRequest(ctx,shop);
      await ctx.db.query(`INSERT INTO ritc.request(household_id,request_id,author_id,client_request_id,shop_id,original_item,own_quantity,route,authored_at,followup_to,author_consent_id)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,(SELECT guardian_consent_id FROM ritc.device WHERE household_id=$1 AND device_id=$11 AND member_id=$3))`,[ctx.householdId,id,ctx.member.member_id,b.clientRequestId,shop.shop_id,b.originalItem,b.ownQuantity,shop.phase==='draft'&&!cutoffPassed?b.route:'next',b.authoredAt,b.followupTo??null,ctx.deviceId]);
    }else {
      const edited=c.kind==='request.edit'?bodySchemas['request.edit'].parse(c.body):undefined;
      id=(edited??bodySchemas['request.withdraw'].parse(c.body)).requestId;
      const r=await this.request(ctx,id,shop.shop_id,true);
      if(!editable(r))throw new ServiceError(409,'followup_required','Send a linked follow-up; the accepted basket stays unchanged.');
      if(r.revision!==c.base.requestRevision)throw new ServiceError(409,'stale_base','Refresh your request before changing it.');
      if(edited) {
        await checkPublishingMember(ctx);
        reviewSharedWording(edited.originalItem,edited.ownQuantity);
        await ctx.db.query(`UPDATE ritc.request SET original_item=$3,own_quantity=$4,status='pending',clarification=NULL,
          clarification_author_id=NULL,clarification_revision=NULL,
          wording_revision=CASE WHEN (original_item,own_quantity) IS DISTINCT FROM ($3,$4) THEN revision+1 ELSE wording_revision END,
          revision=revision+1 WHERE household_id=$1 AND request_id=$2`,[ctx.householdId,id,edited.originalItem,edited.ownQuantity]);
      }
      else await ctx.db.query("UPDATE ritc.request SET status='withdrawn',revision=revision+1 WHERE household_id=$1 AND request_id=$2",[ctx.householdId,id]);
    }
    return{operationId,kind:c.kind,request:ownRequest(await this.request(ctx,id,shop.shop_id,true))};
  }
  private async shopperCommand(ctx:Context,shop:Shop,c:Envelope,operationId:string,billing?:BillingService,internalPriceOnly=false) {
    if(c.kind==='meal.chooseTonight'){
      const choices=await recordTonight(ctx,shop,c.body,operationId,this,billing);
      await this.snapshot(ctx,shop.shop_id,operationId,'patch');
      return {...await this.receipt(ctx,c,operationId,'meal_chosen'),...choices};
    }
    if(isCookCommand(c.kind)){
      const result=await recordCook(ctx,shop,c.kind,c.body,operationId,billing);
      return {...await this.receipt(ctx,c,operationId,'recorded'),...result};
    }
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
    if(c.kind==='amendment.recordResponse') {
      const amendment=await recordOrderAmendment(ctx,shop,c.body,operationId);
      return {...await this.receipt(ctx,c,operationId,'recorded'),...amendment};
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
      await checkPublishingMember(ctx);
      reviewSharedWording(b.question);
      await ctx.db.query("UPDATE ritc.request SET status='clarified',clarification=$3,clarification_author_id=$4,clarification_revision=revision+1,revision=revision+1 WHERE household_id=$1 AND request_id=$2",[ctx.householdId,r.request_id,b.question,ctx.member.member_id]);
      return this.receipt(ctx,c,operationId,'clarified',{requestId:r.request_id,requestRevision:r.revision+1});
    }
    if(c.kind==='request.confirmPurchase')return this.confirmPurchase(ctx,shop,c,operationId);
    if(c.kind==='request.undoAcceptance'){
      const inverse=await applyRequestUndo(this,ctx,shop,c,operationId);
      await this.setLines(ctx,shop.shop_id,inverse.body.lines);
      await ctx.db.query('UPDATE ritc.shop SET quote=$3,revision=revision+1 WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id,inverse.body.quote]);
      const t=inverse.transition;
      const updated=await ctx.db.query('UPDATE ritc.request SET status=$3,route=$4,revision=revision+1 WHERE household_id=$1 AND request_id=$2 AND revision=$5 AND status=$6 AND route=$7',[ctx.householdId,t.requestId,t.restored.status,t.restored.route,t.expected.revision,t.expected.status,t.expected.route]);
      if(updated.rowCount!==1)throw refresh();
      await this.snapshot(ctx,shop.shop_id,operationId,'decision');return inverse.receipt;
    }
    if(c.kind==='request.apply')return this.apply(ctx,shop,c,operationId);
    if(c.kind==='shop.patch') {
      this.requireDraft(shop);const b=bodySchemas['shop.patch'].parse(c.body);requireMatchingCurrency(b.quote.currency,shop.currency);this.validateQuote(b.quote,ctx.now);checkout(b.lines,b.quote);
      let demandAcceptance:Awaited<ReturnType<typeof applyDemand>>=undefined;
      if(b.demandReview)demandAcceptance=await applyDemand(this,ctx,shop,c,operationId);
      else if(shop.demand_revision){if(!internalPriceOnly)throw new ServiceError(409,'demand_review_required','Review shared source quantities before changing this shop.');await assertPriceOnly(this,ctx,shop,c);}
      if(b.mealEdit) {
        const {occurrenceId,meal}=b.mealEdit;
        const current=await this.meals(ctx,shop.shop_id);
        const original=current.find(entry=>entry.occurrenceId===occurrenceId);
        const exists=Boolean(original);
        if(demandAcceptance?.protectMeal)demandAcceptance.protectMeal(original ? sharedMealSchema.parse(original.meal) : undefined,meal,occurrenceId);
        else preserveProtectedMeal(original ? sharedMealSchema.parse(original.meal) : undefined, meal);
        if((original?.revision ?? null)!==b.mealEdit.baseMealRevision)
          throw new ServiceError(409,'stale_meal','Review this occurrence again before applying a change.');
        if(b.mealEdit.repeatPlanId) await acceptRepeatStep(this,billing,ctx,shop,b.mealEdit.repeatPlanId,occurrenceId,meal,operationId);
        if(b.mealEdit.dinnerSwap) await checkDraftDinnerSwap(ctx,original?sharedMealSchema.parse(original.meal):undefined,meal,b.mealEdit.preferenceReview);
        if(b.mealEdit.changeProposalId) await consumeSharedMealChange(ctx,shop,b.mealEdit.changeProposalId,occurrenceId,b.mealEdit.baseMealRevision,meal);
        else if(!b.demandReview)await checkIngredientChange(ctx,original?sharedMealSchema.parse(original.meal):undefined,meal,b.mealEdit.preferenceReview);
        if(b.mealEdit.proposalId) {
          await requireMealMove(ctx,shop,b.mealEdit.proposalId,occurrenceId,original?sharedMealSchema.parse(original.meal):undefined,meal);
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
      await checkLinkedPackChanges(this,ctx,shop,b.lines);
      await this.setLines(ctx,shop.shop_id,b.lines);
      await ctx.db.query('UPDATE ritc.shop SET quote=$3,revision=revision+1 WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id,b.quote]);
      if (completedStoreReview) {
        await ctx.db.query('UPDATE ritc.shop SET store_review_required=false WHERE household_id=$1 AND shop_id=$2',
          [ctx.householdId,shop.shop_id]);
      }
      await this.snapshot(ctx,shop.shop_id,operationId,'patch',!internalPriceOnly);return this.receipt(ctx,c,operationId,'patched');
    }
    if(c.kind==='shop.freeze') {
      this.requireDraft(shop);await prepareTrackingFreeze(this,ctx,shop,bodySchemas['shop.freeze'].parse(c.body).trackingReview);
      if(shop.demand_review_required)throw new ServiceError(409,'demand_review_required','Review shared source quantities before freezing this shop.');
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
        await assertTrackingPlacement(this,ctx,shop,r.reported_revision);await assertDemandPlacement(ctx,shop,r.reported_revision);
        if(shop.phase!=='frozen'||shop.frozen_revision!==r.reported_revision)throw new ServiceError(409,'reconciliation_required','The report differs from the frozen basket. Preserve both records for review.');
        await this.place(ctx,shop,operationId,r.reported_revision);
      }
      await ctx.db.query('UPDATE ritc.placement_report SET state=$3,resolution_operation_id=$4 WHERE household_id=$1 AND report_id=$2',[ctx.householdId,b.reportId,b.choice==='apply'?'applied':'rejected',operationId]);
      return this.receipt(ctx,c,operationId,b.choice==='apply'?'placed':'report_rejected',{reportId:b.reportId});
    }
    throw invalid();
  }
  private async confirmPurchase(ctx:Context,shop:Shop,c:Envelope,operationId:string) {
    const {requestId,lineId,placedRevision,outcome,reportedPurchaser}=bodySchemas['request.confirmPurchase'].parse(c.body);
    if(!shop.placed_revision || !['placed','closed'].includes(shop.phase))
      throw new ServiceError(409,'placed_order_required','Open the placed order to review this purchase.');
    if(placedRevision!==shop.placed_revision) throw refresh();
    const scope=[ctx.householdId,requestId,shop.shop_id];
    const linked=await ctx.db.query(`SELECT 1 FROM ritc.placed_request_link
      WHERE household_id=$1 AND request_id=$2 AND shop_id=$3 AND line_id=$4 AND placed_revision=$5`,[...scope,lineId,placedRevision]);
    if(!linked.rowCount) throw unavailable();
    let buyerID = reportedPurchaser?.kind === 'self' ? ctx.member.member_id : null;
    if (reportedPurchaser?.kind === 'requestAuthor') {
      const source = await this.request(ctx,reportedPurchaser.requestId,shop.shop_id);
      if (!source.author_active || source.author_kind !== 'adult' || source.author_id === ctx.member.member_id) throw unavailable();
      if (source.revision !== reportedPurchaser.requestRevision || source.author_alias !== reportedPurchaser.expectedAlias) throw refresh();
      buyerID = source.author_id;
    }
    const changed=await ctx.db.query<{revision:number}>(`UPDATE ritc.request SET revision=revision+1
      WHERE household_id=$1 AND request_id=$2 AND shop_id=$3 AND status='added' AND revision=$4 RETURNING revision`,
      [...scope,c.base.requestRevision??null]);
    if(!changed.rowCount) throw new ServiceError(409,'stale_base','Review the current request before confirming the purchase.');
    const revision=changed.rows[0]!.revision;
    await ctx.db.query(`INSERT INTO ritc.request_purchase_review(household_id,request_id,shop_id,placed_revision,request_revision,actor_id,operation_id,outcome)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[...scope,placedRevision,revision,ctx.member.member_id,operationId,outcome]);
    if (buyerID) await ctx.db.query('INSERT INTO ritc.request_purchase_buyer(household_id,operation_id,buyer_id) VALUES($1,$2,$3)',
      [ctx.householdId,operationId,buyerID]);
    return {...await this.receipt(ctx,c,operationId,'recorded',{requestId,requestRevision:revision}),purchaseOutcome:outcome};
  }
  private async apply(ctx:Context,shop:Shop,c:Envelope,operationId:string) {
    const b=bodySchemas['request.apply'].parse(c.body),r=await this.request(ctx,b.requestId,shop.shop_id);
    const p=(await ctx.db.query('SELECT * FROM ritc.preview WHERE household_id=$1 AND preview_id=$2 AND actor_id=$3 AND shop_id=$4 AND request_id=$5',[ctx.householdId,b.previewId,ctx.member.member_id,shop.shop_id,r.request_id])).rows[0];
    if(!p)throw unavailable();
    const decision=decisionSchema.parse(p.decision);
    if(b.demandReview&&decision.choice!=='add'&&decision.choice!=='link')throw new ServiceError(409,'demand_action_changed','Use the exact reviewed source action.');
    if(r.carried_forward||decision.choice!=='undoSameItem'&&!editable(r)&&!(r.status==='deferred'&&('promote'in decision)&&decision.promote))throw new ServiceError(409,'already_handled','Review the current request.');
    if(r.revision!==c.base.requestRevision||p.request_revision!==r.revision||p.shop_revision!==shop.revision||p.authority_epoch!==shop.authority_epoch||p.expires_at<=ctx.now)throw new ServiceError(409,'stale_preview','Review a fresh preview.');
    const lines=await this.lines(ctx,shop.shop_id);
    const pair=decision.choice==='reviewRequestPair'||decision.choice==='undoRequestPair'?await reviewPair(this,ctx,shop,r,decision):null;
    const proof=decision.choice==='sameItem'?await proveSameItem(this,ctx,shop,r,decision.target):null;
    const permission=await decisionPermission(this,ctx,shop,r,decision,lines);
    if(p.fingerprint!==digest({shop,r:ownRequest(r),lines,decision,...permission,...(proof?{targetProof:proof.digest}:{}),...(pair?{pairProof:pair.fingerprint}:{})}))throw new ServiceError(409,'stale_preview','Review a fresh preview.');
    const facts=this.previewFacts(shop,r,lines,decision);
    if(facts.requiresOverageAcceptance&&!b.acceptOverage)throw new ServiceError(409,'overage_acceptance_required','Explicitly accept the recomputed whole-checkout overage or defer.');
    if(facts.requiresUnknownAcceptance&&!b.acceptUnknown)throw new ServiceError(409,'unknown_acceptance_required','Review the missing costs or defer.');
    if(decision.choice==='reviewRequestPair'||decision.choice==='undoRequestPair'){
      await applyPair(ctx,shop,b.previewId,decision,operationId);
      return this.receipt(ctx,c,operationId,r.status,{requestId:r.request_id,requestRevision:r.revision});
    }
    if(decision.choice==='sameItem'||decision.choice==='undoSameItem'){
      const status=await applySameItem(this,ctx,shop,r,b.previewId,decision,operationId);
      return this.receipt(ctx,c,operationId,status,{requestId:r.request_id,requestRevision:r.revision+1});
    }
    const acceptanceBefore=await captureAcceptanceBefore(this,ctx,shop,c,operationId,decision);
    if(decision.choice==='add'||decision.choice==='link') {
      this.requireDraft(shop);
      if(b.demandReview)await applyDemand(this,ctx,shop,c,operationId);
      else if(shop.demand_revision)throw new ServiceError(409,'demand_review_required','Review the request quantity against current shared sources.');
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
    await finishAcceptanceCapture(this,ctx,shop,acceptanceBefore);
    return this.receipt(ctx,c,operationId,status,{requestId:r.request_id,requestRevision:r.revision+1});
  }
  private async place(ctx:Context,shop:Shop,operationId:string,snapshotRevision:number) {
    await assertTrackingPlacement(this,ctx,shop,snapshotRevision);await assertDemandPlacement(ctx,shop,snapshotRevision);
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
    if(shop.demand_review_required)throw new ServiceError(409,'demand_review_required','Review shared source quantities before recording placement.');
    if(Date.parse(b.occurredAt)>ctx.now.getTime()+5*60_000)throw invalid();
    const current=shop.shopper_id===ctx.member.member_id&&shop.authority_epoch===c.base.authorityEpoch&&shop.revision===c.base.shopRevision&&(shop.phase==='draft'||shop.phase==='frozen');
    const reportId=randomUUID();
    await ctx.db.query(`INSERT INTO ritc.placement_report(household_id,report_id,shop_id,actor_id,reported_epoch,reported_revision,occurred_at,state,operation_id)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,[ctx.householdId,reportId,shop.shop_id,ctx.member.member_id,c.base.authorityEpoch,c.base.shopRevision,b.occurredAt,current?'applied':'pending_reconciliation',operationId]);
    if(current)await this.place(ctx,shop,operationId,shop.frozen_revision??shop.revision);
    // Reporter receipt contains only their evidence disposition, never the current shopper's revision or budget.
    return{operationId,kind:c.kind,reportId,disposition:current?'placed':'pending_reconciliation'};
  }
  async startWebSession(householdId:string,identity:VerifiedIdentity,options:{
    viewGrantId?:string;browserBound?:boolean;selectedShopId?:string;pairedDeviceToken?:string;sharedContentSafety?:boolean;
    ownRequestsOnly?:boolean;previousSession?:{deviceId:string;csrf:string}
  }={}) {
    const {viewGrantId,browserBound=false,selectedShopId,pairedDeviceToken,ownRequestsOnly=false,previousSession}=options;
    return this.transaction(householdId,async(db,now)=>{
      let deviceToken=pairedDeviceToken;
      if(previousSession){
        const current=await db.query('SELECT 1 FROM ritc.web_session WHERE household_id=$1 AND device_id=$2 AND csrf=$3 AND revoked_at IS NULL AND expires_at>$4',[householdId,previousSession.deviceId,previousSession.csrf,now]);
        if(!current.rowCount)throw accessEnded();
      }else if(!deviceToken){
        deviceToken=(await this.enrollInTransaction(db,now,householdId,identity)).deviceToken;
      }
      return this.authorizedInTransaction(db,now,householdId,{
        identity,ownRequestsOnly,sharedContentSafety:options.sharedContentSafety===true,...(deviceToken?{deviceToken}:{}),...(previousSession?{trustedDeviceId:previousSession.deviceId}:{}),
        ...(viewGrantId?{viewGrantId}:{}),...(selectedShopId?{selectedShopId}:{})
      },async ctx=>{
        const bootstrap=await this.bootstrap(ctx);
        const token=(ownRequestsOnly?contributorCookiePrefix:'')+randomBytes(32).toString('base64url'),csrf=randomBytes(32).toString('base64url');
        const expiresAt=new Date(Math.min(identity.expiresAt.getTime(),ctx.now.getTime()+15*60_000));
        const previous=pairedDeviceToken||previousSession?(await ctx.db.query('SELECT token_hash FROM ritc.web_session WHERE household_id=$1 AND device_id=$2 AND revoked_at IS NULL ORDER BY expires_at DESC,token_hash LIMIT 1',[householdId,ctx.deviceId])).rows[0]:undefined;
        if(previous){
          await ctx.db.query('UPDATE ritc.web_session SET revoked_at=COALESCE(revoked_at,$4) WHERE household_id=$1 AND device_id=$2 AND token_hash<>$3',[householdId,ctx.deviceId,previous.token_hash,ctx.now]);
          await ctx.db.query('UPDATE ritc.web_session SET token_hash=$3,csrf=$4,expires_at=$5,grant_id=$6,browser_bound=$7,shop_id=$8,own_requests_only=$9 WHERE household_id=$1 AND token_hash=$2',[householdId,previous.token_hash,tokenHash(token),csrf,expiresAt,viewGrantId??null,browserBound,selectedShopId??null,ownRequestsOnly]);
        }else await ctx.db.query('INSERT INTO ritc.web_session(household_id,token_hash,member_id,device_id,csrf,expires_at,grant_id,browser_bound,shop_id,own_requests_only) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)',[householdId,tokenHash(token),ctx.member.member_id,ctx.deviceId,csrf,expiresAt,viewGrantId??null,browserBound,selectedShopId??null,ownRequestsOnly]);
        return{cookie:householdId+'.'+token,csrf,expiresAt,session:{authenticated:true,...bootstrap,replayWindow:await this.window(ctx),csrf}};
      });
    });
  }
  async webIdentity(cookie:string,freshIdentity?:VerifiedIdentity,readOnly=false) {
    const parts=scopedCookieParts(cookie);
    if(!parts)throw accessEnded();
    const {householdId,token}=parts;
    return this.transaction(householdId,async(db,now)=>{
      const s=(await db.query(`SELECT s.csrf,s.expires_at,s.device_id,s.grant_id,s.shop_id,s.browser_bound,s.own_requests_only,m.issuer,m.subject,m.kind,d.session_id FROM ritc.web_session s
        JOIN ritc.member m USING(household_id,member_id) JOIN ritc.device d USING(household_id,member_id,device_id)
        WHERE s.household_id=$1 AND s.token_hash=$2 AND s.revoked_at IS NULL AND (s.expires_at>$3 OR $4::boolean) AND d.revoked_at IS NULL AND m.state='active'`,[householdId,tokenHash(token),now,Boolean(freshIdentity)&&!readOnly])).rows[0];
      if(!s)throw accessEnded();
      if(s.browser_bound&&!freshIdentity)throw new ServiceError(401,'session_needed','Sign in again to continue.');
      if(freshIdentity&&(freshIdentity.issuer!==s.issuer||freshIdentity.subject!==s.subject||freshIdentity.sessionId!==s.session_id))throw accessEnded();
      const identity:VerifiedIdentity=freshIdentity??{issuer:s.issuer,subject:s.subject,sessionId:s.session_id,expiresAt:s.expires_at};
      await this.assertSession(db,identity,now);
      if(freshIdentity&&!readOnly)await db.query('UPDATE ritc.web_session SET expires_at=$3 WHERE household_id=$1 AND token_hash=$2',[householdId,tokenHash(token),new Date(Math.min(freshIdentity.expiresAt.getTime(),now.getTime()+15*60_000))]);
      const session={householdId,csrf:s.csrf as string,auth:{identity,trustedDeviceId:s.device_id as string,...(s.own_requests_only?{ownRequestsOnly:true}:{}),...(s.grant_id?{viewGrantId:s.grant_id as string}:{}),...(s.shop_id?{selectedShopId:s.shop_id as string}:{})}};
      if(readOnly&&s.kind==='child')throw unavailable();
      if(readOnly)await this.authorizedInTransaction(db,now,householdId,session.auth,async()=>undefined);
      return session;
    },readOnly);
  }
  async revokeWebCookie(cookie:string){
    const parts=scopedCookieParts(cookie);
    if(!parts)return;
    const {householdId,token}=parts;
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
