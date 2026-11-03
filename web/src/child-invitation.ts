import type { ChildInvitationClaim, ChildInvitationClaimReceipt, ChildInvitationClaimStatus, ChildInvitationFinish, ChildBrowserEnrollmentReceipt, ChildInvitationAuthStart, ChildInvitationSession, GuardianAvailability } from '../../shared/contracts/guardian-enrollment-v1.js';
import { API, ApiError, type BrowserAuthState, type Session } from './api.js';
export type { ChildInvitationSession };

/** A host may supply this only after the server authorizes the approved child
 * identity setup. The existing adult email-code flow is not such a capability.
 * Admission comes from /v1/child-invitations/session, never generic login. */
export type ChildClaimAccess = Readonly<{ kind:'approved_child_session'; scope:string; csrf:string }>;
export interface ChildClaimIdentity { current():Promise<ChildClaimAccess|null> }
export interface ChildClaimPort {
  claim(access:ChildClaimAccess, input:Readonly<ChildInvitationClaim>):Promise<ChildInvitationClaimReceipt>;
  status(access:ChildClaimAccess, householdId:string, claimId:string):Promise<ChildInvitationClaimStatus>;
  finish(access:ChildClaimAccess, input:Readonly<ChildInvitationFinish>):Promise<ChildBrowserEnrollmentReceipt>;
}
export interface ChildInvitationBrowserPort extends ChildClaimPort {
  availability(language:'en'|'es'):Promise<GuardianAvailability>;
  childSession():Promise<ChildInvitationSession>;
  authState():Promise<BrowserAuthState>;
  startSignin(input:Readonly<ChildInvitationAuthStart>,csrf:string):Promise<void>;
  verifySignin(code:string,csrf:string):Promise<BrowserAuthState>;
  logoutIdentity(csrf:string):Promise<{providerRevoked:boolean}>;
  scopedSession():Promise<Session|null>;
}
const bad = ():never => { throw new ApiError('invalid_response',502); };
const uuid = (value:unknown):string => typeof value==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)?value:bad();
const date = (value:unknown):string => typeof value==='string'&&value.length<=64&&Number.isFinite(Date.parse(value))?value:bad();
const record = (value:unknown):Record<string,unknown> => value!==null&&typeof value==='object'&&!Array.isArray(value)?value as Record<string,unknown>:bad();
const secret = (value:unknown):string => typeof value==='string'&&/^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/.test(value)?value:bad();
const pairing = (value:unknown):string => typeof value==='string'&&/^[A-Z2-7]{8}$/.test(value)?value:bad();
const invitation = (value:unknown):string => typeof value==='string'&&value.length>0&&value.length<=4096&&!/[\s\p{Cc}]/u.test(value)?value:bad();
const bool=(value:unknown):boolean=>typeof value==='boolean'?value:bad();
function accessValue(access:ChildClaimAccess):void {
  if(access.kind!=='approved_child_session'||!access.scope||access.scope.length>1024||!access.csrf||access.csrf.length>1024)throw new ApiError('child_setup_unavailable',503);
}

/** App-owned v1 routes only. Covered OTP starts through the invitation route;
 * finish installs the exact device cookie. No generic enrollment is invoked. */
export class ChildInvitationAPI implements ChildInvitationBrowserPort {
  private readonly auth:API;
  constructor(private readonly fetcher:typeof fetch=(input,init)=>globalThis.fetch(input,init)) {this.auth=new API(fetcher);}
  private async request(path:string,input?:object,csrf?:string):Promise<Record<string,unknown>> {
    let response:Response;
    try { response=await this.fetcher(path,{method:input?'POST':'GET',credentials:'same-origin',cache:'no-store',redirect:'error',referrerPolicy:'no-referrer',headers:{Accept:'application/json',...(input?{'Content-Type':'application/json',...(csrf?{'X-CSRF-Token':csrf}:{})}:{})},...(input?{body:JSON.stringify(input)}:{})}); }
    catch { throw new ApiError('network',0); }
    const data:unknown=await response.json().catch(()=>null);
    if(!response.ok){const error=data&&typeof data==='object'&&'error' in data?data.error:null;throw new ApiError(error&&typeof error==='object'&&'code' in error&&typeof error.code==='string'?error.code:'unavailable',response.status);}
    return record(data);
  }
  private call(access:ChildClaimAccess,path:string,input?:Readonly<ChildInvitationClaim|ChildInvitationFinish>):Promise<Record<string,unknown>> {accessValue(access);return this.request(path,input,access.csrf);}
  async availability(language:'en'|'es'):Promise<GuardianAvailability> {
    const d=await this.request(`/v1/guardian/availability?language=${language}`),available=bool(d.available);
    if(available?d.reason!==null:!['provider_configuration_required','notice_approval_required'].includes(String(d.reason)))return bad();
    return {available,reason:d.reason as GuardianAvailability['reason']};
  }
  async childSession():Promise<ChildInvitationSession> {
    const d=await this.request('/v1/child-invitations/session');
    const result:ChildInvitationSession={available:bool(d.available),authenticated:bool(d.authenticated),admitted:bool(d.admitted),scope:d.scope==='own_requests'?'own_requests':d.scope===null?null:bad(),householdId:d.householdId===null?null:uuid(d.householdId),inviteId:d.inviteId===null?null:uuid(d.inviteId),claimId:d.claimId===null?null:uuid(d.claimId),status:['none','admitted','awaiting_guardian','approved','active','ended'].includes(String(d.status))?d.status as ChildInvitationSession['status']:bad(),expiresAt:d.expiresAt===null?null:date(d.expiresAt)};
    if(result.admitted){
      if(!result.available||!result.authenticated||result.scope!=='own_requests'||!result.householdId||!result.inviteId||!result.expiresAt||['none','ended'].includes(result.status)||(result.status==='admitted'?result.claimId!==null:result.claimId===null))return bad();
    }else if(result.scope!==null||!['none','ended'].includes(result.status)||result.status==='none'&&(result.householdId!==null||result.inviteId!==null||result.claimId!==null||result.expiresAt!==null)||result.status==='ended'&&(!result.authenticated||!result.householdId||!result.inviteId||!result.expiresAt))return bad();
    return result;
  }
  authState():Promise<BrowserAuthState>{return this.auth.authState();}
  async startSignin(input:Readonly<ChildInvitationAuthStart>,csrf:string):Promise<void> {
    if(typeof input.email!=='string'||input.email.length>254||!/^\S+@\S+\.\S+$/.test(input.email)||!csrf||csrf.length>1024)throw new ApiError('invalid_entry',422);
    const d=await this.request('/v1/child-invitations/auth/start',{token:invitation(input.token),email:input.email},csrf);
    if(d.status!=='check_email')return bad();
  }
  verifySignin(code:string,csrf:string):Promise<BrowserAuthState>{return this.auth.verifyEmailCode(code,csrf);}
  logoutIdentity(csrf:string):Promise<{providerRevoked:boolean}>{return this.auth.logoutIdentity(csrf);}
  scopedSession():Promise<Session|null>{return this.auth.session();}
  async claim(access:ChildClaimAccess,input:Readonly<ChildInvitationClaim>):Promise<ChildInvitationClaimReceipt> {
    const body={clientKey:uuid(input.clientKey),token:invitation(input.token),pairingCode:pairing(input.pairingCode)};
    const value=await this.call(access,'/v1/child-invitations/claim',body);
    if(value.status!=='awaiting_guardian')return bad();
    return {householdId:uuid(value.householdId),claimId:uuid(value.claimId),status:'awaiting_guardian',expiresAt:date(value.expiresAt)};
  }
  async status(access:ChildClaimAccess,householdId:string,claimId:string):Promise<ChildInvitationClaimStatus> {
    const value=await this.call(access,`/v1/child-invitations/claims/${encodeURIComponent(uuid(claimId))}?householdId=${encodeURIComponent(uuid(householdId))}`);
    if(value.claimId!==claimId||!['awaiting_guardian','approved','active','ended'].includes(String(value.status)))return bad();
    return {claimId,status:value.status as ChildInvitationClaimStatus['status'],expiresAt:date(value.expiresAt)};
  }
  async finish(access:ChildClaimAccess,input:Readonly<ChildInvitationFinish>):Promise<ChildBrowserEnrollmentReceipt> {
    const body={clientKey:uuid(input.clientKey),householdId:uuid(input.householdId),claimId:uuid(input.claimId),pairingCode:pairing(input.pairingCode),deviceSecret:secret(input.deviceSecret)};
    const value=await this.call(access,'/v1/child-invitations/finish',body);
    if(value.householdId!==input.householdId||value.role!=='contributor')return bad();
    return {householdId:input.householdId,memberId:uuid(value.memberId),role:'contributor',deviceId:uuid(value.deviceId)};
  }
}

export type ChildClaimState = Readonly<{
  stage:'ready'|'awaiting_guardian'|'approved'|'finish_retry'|'restart_required'|'finished'|'ended';
  pairingCode:string|null; expiresAt:string|null;
}>;
/** In-memory caller, scoped to server admission and the exact BFF cookie's csrf.
 * Reloading loses local retry intent. No browser persistence is used. */
export class ChildClaimController {
  private generation=0;
  private busy=false;
  private access:ChildClaimAccess|null=null;
  private claimIntent:Readonly<ChildInvitationClaim>|null=null;
  private receipt:ChildInvitationClaimReceipt|null=null;
  private finishIntent:Readonly<ChildInvitationFinish>|null=null;
  private stage:ChildClaimState['stage']='ready';
  constructor(private readonly identity:ChildClaimIdentity,private readonly api:ChildClaimPort=new ChildInvitationAPI(),private readonly random:Crypto=globalThis.crypto,private readonly now:()=>number=Date.now) {}
  get state():ChildClaimState { return Object.freeze({stage:this.stage,pairingCode:this.claimIntent?.pairingCode??null,expiresAt:this.receipt?.expiresAt??null}); }
  checkExpiry():boolean {if(this.receipt&&Date.parse(this.receipt.expiresAt)<=this.now()){this.clear(true);return true;}return false;}
  clear(ended=false):void { this.generation++;this.access=null;this.claimIntent=null;this.receipt=null;this.finishIntent=null;this.stage=ended?'ended':'ready'; }
  private async current(generation:number):Promise<ChildClaimAccess> {
    const current=await this.identity.current();
    if(generation!==this.generation)throw new ApiError('access_ended',403);
    if(!current||current.kind!=='approved_child_session'){this.clear(true);throw new ApiError('child_setup_unavailable',503);}
    accessValue(current);
    if(this.access&&(current.scope!==this.access.scope||current.csrf!==this.access.csrf)){this.clear(true);throw new ApiError('access_ended',403);}
    this.access??=Object.freeze({...current});return this.access;
  }
  private live():void {
    if(this.receipt&&Date.parse(this.receipt.expiresAt)<=this.now()){this.clear(true);throw new ApiError('access_ended',403);}
  }
  private async operation<T>(action:(generation:number)=>Promise<T>):Promise<T> {
    if(this.busy)throw new ApiError('action_pending',409);
    if(this.stage==='ended'||this.stage==='finished'||this.stage==='restart_required')throw new ApiError('access_ended',403);
    this.busy=true;
    try {this.live();return await action(this.generation);}
    catch(error){if(error instanceof ApiError&&[401,403,404,410].includes(error.status))this.clear(true);throw error;}
    finally {this.busy=false;}
  }
  private randomSecret():string {return btoa(String.fromCharCode(...this.random.getRandomValues(new Uint8Array(32)))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');}
  async claim(token:string):Promise<void> {
    return this.operation(async generation=>{
      const access=await this.current(generation);
      if(this.receipt)return;
      if(this.claimIntent&&this.claimIntent.token!==token)throw new ApiError('review_original_invitation',409);
      this.claimIntent??=Object.freeze({clientKey:this.random.randomUUID(),token:invitation(token),pairingCode:Array.from(this.random.getRandomValues(new Uint8Array(8)),byte=>'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'[byte&31]).join('')});
      const receipt=await this.api.claim(access,this.claimIntent);
      await this.current(generation);
      this.receipt=Object.freeze({...receipt});this.live();this.stage='awaiting_guardian';
    });
  }
  private async readStatus(access:ChildClaimAccess,generation:number):Promise<ChildInvitationClaimStatus> {
    if(!this.receipt)throw new ApiError('claim_needed',409);
    const status=await this.api.status(access,this.receipt.householdId,this.receipt.claimId);
    await this.current(generation);
    this.live();
    if(status.claimId!==this.receipt.claimId||Date.parse(status.expiresAt)!==Date.parse(this.receipt.expiresAt))throw new ApiError('invalid_response',502);
    if(status.status==='ended'){this.clear(true);throw new ApiError('access_ended',403);}
    return status;
  }
  async refresh():Promise<void> {
    return this.operation(async generation=>{
      const access=await this.current(generation),status=await this.readStatus(access,generation);
      if(status.status==='active'){
        if(!this.finishIntent){this.clear();this.stage='restart_required';throw new ApiError('original_finish_needed',409);}
        this.stage='finish_retry';return;
      }
      this.stage=status.status==='approved'?(this.finishIntent?'finish_retry':'approved'):'awaiting_guardian';
    });
  }
  /** The BFF installs the exact finished device in an HttpOnly scoped cookie.
   * This browser receipt carries no device credential. */
  async finish():Promise<ChildBrowserEnrollmentReceipt> {
    return this.operation(async generation=>{
      const access=await this.current(generation),status=await this.readStatus(access,generation);
      if(status.status==='active'&&!this.finishIntent){this.clear();this.stage='restart_required';throw new ApiError('original_finish_needed',409);}
      if(status.status!=='approved'&&!(status.status==='active'&&this.finishIntent))throw new ApiError('guardian_confirmation_needed',409);
      this.finishIntent??=Object.freeze({clientKey:this.random.randomUUID(),householdId:this.receipt!.householdId,claimId:this.receipt!.claimId,pairingCode:this.claimIntent!.pairingCode,deviceSecret:this.randomSecret()});
      this.stage='finish_retry';
      const receipt=await this.api.finish(access,this.finishIntent);
      await this.current(generation);this.live();
      if(receipt.householdId!==this.receipt!.householdId||receipt.role!=='contributor')throw new ApiError('invalid_response',502);
      const browserReceipt={householdId:uuid(receipt.householdId),memberId:uuid(receipt.memberId),role:'contributor' as const,deviceId:uuid(receipt.deviceId)};
      this.clear();this.stage='finished';return browserReceipt;
    });
  }
}
