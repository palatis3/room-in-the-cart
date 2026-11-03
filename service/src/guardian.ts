import {randomBytes,randomUUID,createHmac} from 'node:crypto';
import {z} from 'zod';
import type {GuardianRetentionPolicy} from './guardian-policy.js';
import type {VerifiedIdentity} from './auth.js';
import type {Database,Transaction} from './database.js';
import {canonical,digest,tokenHash} from './database.js';
import {HouseholdRepository,type AuthContext,type Context} from './repository.js';
import {ServiceError,unavailable,accessEnded} from './errors.js';
import {KWSWebhookVerifier,type GuardianVerificationGateway} from './guardian-provider.js';
import type {BrowserAuthService,ChildSigninBinding,EmailOTPProvider} from './browser-auth.js';
import type {GuardianNotice,GuardianEnrollment} from '../../shared/contracts/guardian-enrollment-v1.js';

const uuid=z.uuid();const hash=z.string().regex(/^[0-9a-f]{64}$/);
const secret=z.string().regex(/^[A-Za-z0-9_-]{43}$/).refine(v=>Buffer.from(v,'base64url').toString('base64url')===v);
const pairing=z.string().regex(/^[A-Z2-7]{8}$/);
export const guardianCreateSchema=z.object({clientKey:uuid,noticeVersion:z.string().min(1).max(100),noticeDigest:hash,
  language:z.enum(['en','es']),childLocation:z.string().regex(/^US(-[A-Z]{2})?$/),guardianDeclaration:z.literal('parent_or_legal_guardian'),childId:uuid.optional()}).strict();
export const guardianActionSchema=z.object({clientKey:uuid,baseRevision:z.number().int().positive()}).strict();
export const guardianConsentSchema=guardianActionSchema.extend({noticeVersion:z.string().min(1).max(100),noticeDigest:hash,childAlias:z.string().trim().min(1).max(80),decision:z.literal('grant'),childSignInEmail:z.email().max(254)}).strict();
export const guardianInvitationSchema=guardianActionSchema.extend({secret}).strict();
export const guardianConfirmSchema=guardianActionSchema.extend({claimId:uuid,pairingCode:pairing}).strict();
export const childClaimSchema=z.object({clientKey:uuid,token:z.string().max(150).regex(/^[0-9a-f-]{36}\.[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/i),pairingCode:pairing}).strict();
export const childAuthStartSchema=z.object({token:childClaimSchema.shape.token,email:z.email().max(254)}).strict();
export const childNativeStartSchema=childAuthStartSchema.extend({clientKey:uuid,challengeSecret:secret}).strict();
export const childNativeAdmitSchema=z.object({clientKey:uuid,householdId:uuid,challengeId:uuid,challengeSecret:secret}).strict();
export const childFinishSchema=z.object({clientKey:uuid,householdId:uuid,claimId:uuid,pairingCode:pairing,deviceSecret:secret}).strict();
export interface GuardianApprovedNotice extends GuardianNotice {
  /** Operator approval of the actual direct notice and the combined adulthood
   * proof + guardian declaration + explicit permission method, never inferred. */
  approvalReference:string;
}
export interface GuardianEnrollmentOptions {
  gateway?:GuardianVerificationGateway; webhookVerifier?:KWSWebhookVerifier; verifierPool?:Database;
  retentionPolicy?:GuardianRetentionPolicy;emailDigestKey?:string; notices?:readonly GuardianApprovedNotice[];
}
type Setup=Record<string,any>;
const terminal=new Set(['cancelled','expired','withdrawn']);
const disabled=()=>new ServiceError(503,'consent_unavailable','Guardian setup needs configured verification and an approved notice.');
const stale=()=>new ServiceError(409,'guardian_refresh_required','Refresh this guardian setup and review its current step.');
const ended=()=>new ServiceError(410,'guardian_setup_ended','This setup ended. Begin a new reviewed guardian setup.');
export class GuardianEnrollmentService {
  private browserAuth:BrowserAuthService|undefined;
  private otpProvider:EmailOTPProvider|undefined;
  attachChildSignin(service:BrowserAuthService,provider:EmailOTPProvider){this.browserAuth=service;this.otpProvider=provider;}
  constructor(readonly repo:HouseholdRepository,readonly options:GuardianEnrollmentOptions={}){
    if(options.emailDigestKey&&Buffer.from(options.emailDigestKey,'base64url').length!==32)throw new Error('Guardian email digest key must contain 32 random bytes');
    if(options.gateway&&options.webhookVerifier&&digest(options.gateway.configuration)!==digest(options.webhookVerifier.configuration))throw new Error('Guardian provider and webhook environments must match');
    for(const notice of options.notices??[]){
      if(!notice.approvalReference.trim()||!notice.methodVersion.trim()||!notice.version.trim()||notice.scope!=='own_requests'||notice.digest!==tokenHash(notice.text)||notice.text.length>30_000)throw new Error('Approved guardian notice must match its exact text digest and method');
    }
  }
  get providerConfigured(){return Boolean(this.browserAuth&&this.otpProvider&&this.options.gateway&&this.options.webhookVerifier&&this.options.verifierPool&&this.options.emailDigestKey);}
  private get noticesApproved(){const notices=this.options.notices??[];return Boolean(this.options.retentionPolicy?.approvalReference)&&notices.length===2&&new Set(notices.map(n=>n.locale)).size===2&&new Set(notices.map(n=>n.version)).size===1&&new Set(notices.map(n=>n.methodVersion)).size===1;}
  notice(language:'en'|'es'){
    const found=this.options.notices?.find(n=>n.locale===language);
    const {approvalReference:_,...notice}=found??{approvalReference:'',version:'',digest:'',locale:language,text:'',scope:'own_requests' as const,methodVersion:''};
    return{available:this.providerConfigured&&this.noticesApproved&&Boolean(found),reason:!this.providerConfigured?'provider_configuration_required' as const:!this.noticesApproved||!found?'notice_approval_required' as const:null,notice:found?notice:null};
  }
  private enabled(language:'en'|'es'){
    const value=this.notice(language);if(!value.available||!value.notice)throw disabled();return value.notice;
  }
  private currentNotice(setup:Setup){
    const notice=this.enabled(setup.language);if(notice.version!==setup.notice_version||notice.digest!==setup.notice_digest||notice.methodVersion!==setup.method_version)throw new ServiceError(409,'guardian_notice_changed','Read the current notice in a new guardian setup.');return notice;
  }
  private keyed(kind:string,value:string){if(!this.options.emailDigestKey)throw disabled();return createHmac('sha256',Buffer.from(this.options.emailDigestKey,'base64url')).update(kind+'\n'+value).digest('hex');}
  private guardian(ctx:Context){if(ctx.member.kind!=='adult'||ctx.viewGrantId)throw unavailable();}
  private async setup(ctx:Context,identity:VerifiedIdentity,id:string,allowEnded=false):Promise<Setup>{
    this.guardian(ctx);
    const setup=(await ctx.db.query(`SELECT * FROM ritc.guardian_enrollment WHERE household_id=$1 AND enrollment_id=$2 AND guardian_id=$3
      AND guardian_device_id=$4 AND guardian_issuer=$5 AND guardian_subject=$6 AND guardian_session=$7`,
      [ctx.householdId,id,ctx.member.member_id,ctx.deviceId,identity.issuer,identity.subject,identity.sessionId])).rows[0];
    if(!setup)throw unavailable();
    if(setup.expires_at<=ctx.now&&setup.state!=='active'&&!terminal.has(setup.state)){
      await ctx.db.query("UPDATE ritc.guardian_enrollment SET state='expired',revision=revision+1 WHERE household_id=$1 AND enrollment_id=$2",[ctx.householdId,id]);setup.state='expired';setup.revision++;
    }
    if(!allowEnded&&terminal.has(setup.state))throw ended();return setup;
  }
  private dto(s:Setup):GuardianEnrollment{return{enrollmentId:s.enrollment_id,revision:s.revision,childId:s.child_id,state:s.state,childAlias:s.child_alias,
    noticeVersion:s.notice_version,noticeDigest:s.notice_digest,scope:'own_requests',expiresAt:s.expires_at.toISOString(),verifiedAt:s.verified_at?.toISOString()??null,consentedAt:s.consented_at?.toISOString()??null,claimId:s.claim_id};}
  private async email(ctx:Context,identity:VerifiedIdentity){
    const result=(await ctx.db.query('SELECT ritc.guardian_confirmed_email($1,$2,$3,$4,$5,$6) AS email',[ctx.householdId,ctx.member.member_id,ctx.deviceId,identity.issuer,identity.subject,identity.sessionId])).rows[0]?.email;
    if(typeof result!=='string'||!z.email().max(320).safeParse(result).success)throw new ServiceError(409,'guardian_email_unconfirmed','Confirm the current guardian account email before verification.');return result;
  }
  private async proof(ctx:Context,setup:Setup,identity:VerifiedIdentity){
    const email=await this.email(ctx,identity);const proof=(await ctx.db.query(`SELECT a.email_digest FROM ritc.guardian_attempt a JOIN ritc.guardian_provider_event p USING(household_id,attempt_id)
      WHERE a.household_id=$1 AND a.enrollment_id=$2`,[ctx.householdId,setup.enrollment_id])).rows[0];
    if(!proof)throw new ServiceError(409,'guardian_verification_required','Complete provider verification before granting permission.');
    if(proof.email_digest!==this.keyed('email',email))throw new ServiceError(409,'guardian_email_changed','The guardian email changed. Begin a new reviewed setup.');return proof;
  }
  private async prior(ctx:Context,identity:VerifiedIdentity,key:string,kind:string,input:unknown){
    const row=(await ctx.db.query('SELECT * FROM ritc.guardian_intent WHERE household_id=$1 AND issuer=$2 AND subject=$3 AND client_key=$4',[ctx.householdId,identity.issuer,identity.subject,key])).rows[0];
    if(!row)return null;
    if(row.session_id!==identity.sessionId)throw accessEnded();
    if(row.kind!==kind||row.payload_digest!==this.keyed('intent',canonical(input)))throw new ServiceError(409,'key_reused','Use a fresh key for a changed guardian action.');return row;
  }
  private async save(ctx:Context,identity:VerifiedIdentity,key:string,id:string,kind:string,input:unknown,response:unknown){
    await ctx.db.query('INSERT INTO ritc.guardian_intent(household_id,issuer,subject,session_id,client_key,enrollment_id,kind,payload_digest,response) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)',[ctx.householdId,identity.issuer,identity.subject,identity.sessionId,key,id,kind,this.keyed('intent',canonical(input)),response]);
  }
  private async advance(ctx:Context,setup:Setup,revision:number,state:string,alias?:string,childEmail?:string){
    if(setup.revision!==revision)throw stale();
    await ctx.db.query(`UPDATE ritc.guardian_enrollment SET state=$3,revision=revision+1,child_alias=COALESCE($4,child_alias),consented_at=CASE WHEN $3='consented' THEN $5 ELSE consented_at END,child_email_digest=COALESCE($6,child_email_digest) WHERE household_id=$1 AND enrollment_id=$2`,[ctx.householdId,setup.enrollment_id,state,alias??null,ctx.now,childEmail?this.keyed('child-email',childEmail.trim().toLowerCase()):null]);
    return this.dto({...setup,state,revision:revision+1,child_alias:alias??setup.child_alias,consented_at:state==='consented'?ctx.now:setup.consented_at});
  }
  async list(ctx:Context,identity:VerifiedIdentity){this.guardian(ctx);const rows=(await ctx.db.query('SELECT enrollment_id FROM ritc.guardian_enrollment WHERE household_id=$1 AND guardian_id=$2 AND guardian_device_id=$3 AND guardian_session=$4 ORDER BY created_at DESC LIMIT 100',[ctx.householdId,ctx.member.member_id,ctx.deviceId,identity.sessionId])).rows;const enrollments=[];for(const row of rows)enrollments.push(this.dto(await this.setup(ctx,identity,row.enrollment_id,true)));return{enrollments};}
  async read(ctx:Context,identity:VerifiedIdentity,id:string){return this.dto(await this.setup(ctx,identity,id,true));}
  async create(ctx:Context,identity:VerifiedIdentity,input:z.infer<typeof guardianCreateSchema>){
    this.guardian(ctx);const notice=this.enabled(input.language);
    if(input.noticeVersion!==notice.version||input.noticeDigest!==notice.digest)throw new ServiceError(409,'guardian_notice_changed','Read the current guardian notice before continuing.');
    const prior=await this.prior(ctx,identity,input.clientKey,'create',input);if(prior){await this.setup(ctx,identity,prior.enrollment_id);return prior.response;}
    if(!input.childId&&!ctx.member.organizer)throw new ServiceError(403,'organizer_required','A household organizer must authorize a new child membership.');
    if(input.childId){const own=await ctx.db.query(`SELECT m.state FROM ritc.member m JOIN ritc.guardian_relationship r ON r.household_id=m.household_id AND r.child_id=m.member_id WHERE m.household_id=$1 AND m.member_id=$2 AND m.kind='child' AND m.erased_at IS NULL AND r.guardian_id=$3 AND r.revoked_at IS NULL`,[ctx.householdId,input.childId,ctx.member.member_id]);if(!own.rowCount)throw unavailable();if(own.rows[0].state!=='active'&&!ctx.member.organizer)throw new ServiceError(403,'organizer_required','A household organizer must authorize restoring this membership.');}
    const count=(await ctx.db.query('SELECT count(*)::int AS n FROM ritc.guardian_enrollment WHERE household_id=$1 AND guardian_id=$2',[ctx.householdId,ctx.member.member_id])).rows[0].n;
    if(count>=100)throw new ServiceError(429,'guardian_setup_limit','Finish or remove older guardian setups before starting another.');
    const id=randomUUID(),childId=input.childId??randomUUID(),expires=new Date(ctx.now.getTime()+60*60_000);
    const row=(await ctx.db.query(`INSERT INTO ritc.guardian_enrollment(household_id,enrollment_id,guardian_id,guardian_device_id,guardian_issuer,guardian_subject,guardian_session,child_id,notice_version,notice_digest,method_version,language,child_location,declaration,expires_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) RETURNING *`,[ctx.householdId,id,ctx.member.member_id,ctx.deviceId,identity.issuer,identity.subject,identity.sessionId,childId,notice.version,notice.digest,notice.methodVersion,input.language,input.childLocation,input.guardianDeclaration,expires])).rows[0];
    const response=this.dto(row);await this.save(ctx,identity,input.clientKey,id,'create',input,response);return response;
  }
  /** The household transaction commits the attempt before any network request. */
  async verification(householdId:string,auth:AuthContext,id:string,input:z.infer<typeof guardianActionSchema>){
    const prepared=await this.repo.authorized(householdId,auth,async ctx=>{
      const setup=await this.setup(ctx,auth.identity,id);this.currentNotice(setup);
      const prior=await this.prior(ctx,auth.identity,input.clientKey,'verification',{id,...input});if(prior)return{response:prior.response};
      if(setup.state!=='awaiting_verification')throw stale();
      const email=await this.email(ctx,auth.identity),attempt=randomUUID(),nonce=randomBytes(32).toString('base64url');
      const rateKey=this.keyed('verification-email',email);await ctx.db.query("SELECT set_config('app.auth_rate_key',$1,true)",[rateKey]);const rate=(await ctx.db.query("INSERT INTO ritc.auth_rate_bucket(bucket_key,window_started,attempts) VALUES($1,$2,1) ON CONFLICT(bucket_key) DO UPDATE SET attempts=CASE WHEN ritc.auth_rate_bucket.window_started<$2::timestamptz-interval '1 hour' THEN 1 ELSE ritc.auth_rate_bucket.attempts+1 END,window_started=CASE WHEN ritc.auth_rate_bucket.window_started<$2::timestamptz-interval '1 hour' THEN $2 ELSE ritc.auth_rate_bucket.window_started END RETURNING attempts",[rateKey,ctx.now])).rows[0];if(rate.attempts>10)throw new ServiceError(429,'verification_rate_limited','Wait before requesting guardian verification again.');
      const provider=this.options.gateway!.configuration;
      await ctx.db.query('INSERT INTO ritc.guardian_attempt(household_id,enrollment_id,attempt_id,organization_id,product_id,environment,nonce_hash,email_digest,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)',[householdId,id,attempt,provider.organizationId,provider.productId,provider.environment,tokenHash(nonce),this.keyed('email',email),setup.expires_at]);
      const response=await this.advance(ctx,setup,input.baseRevision,'verification_pending');
      await this.save(ctx,auth.identity,input.clientKey,id,'verification',{id,...input},response);
      return{response,request:{email,location:setup.child_location,language:setup.language as 'en'|'es',userContext:'parent' as const,externalPayload:JSON.stringify({v:1,h:householdId,a:attempt,n:nonce})}};
    });
    if(prepared.request){try{await this.options.gateway!.start(prepared.request);}catch{
      await this.repo.authorized(householdId,auth,async ctx=>{const setup=await this.setup(ctx,auth.identity,id,true);if(setup.state==='verification_pending')await this.advance(ctx,setup,setup.revision,'verification_uncertain');}).catch(()=>{});
      throw new ServiceError(503,'verification_uncertain','Verification delivery is uncertain. Refresh this setup; do not send another email automatically.');
    }}return prepared.response;
  }
  async consent(ctx:Context,identity:VerifiedIdentity,id:string,input:z.infer<typeof guardianConsentSchema>){
    const setup=await this.setup(ctx,identity,id);this.currentNotice(setup);await this.proof(ctx,setup,identity);
    if(input.noticeVersion!==setup.notice_version||input.noticeDigest!==setup.notice_digest)throw new ServiceError(409,'guardian_notice_changed','Review the exact current notice before granting permission.');
    const prior=await this.prior(ctx,identity,input.clientKey,'consent',{id,...input});if(prior)return prior.response;
    if(setup.state!=='verified')throw stale();const response=await this.advance(ctx,setup,input.baseRevision,'consented',input.childAlias,input.childSignInEmail);
    await this.save(ctx,identity,input.clientKey,id,'consent',{id,...input},response);return response;
  }
  async invite(ctx:Context,identity:VerifiedIdentity,id:string,input:z.infer<typeof guardianInvitationSchema>){
    const setup=await this.setup(ctx,identity,id);this.currentNotice(setup);await this.proof(ctx,setup,identity);
    const prior=await this.prior(ctx,identity,input.clientKey,'invite',{id,...input});if(prior)return{...prior.response,token:ctx.householdId+'.'+prior.response.inviteId+'.'+input.secret};
    if(setup.state!=='consented'||setup.revision!==input.baseRevision)throw stale();
    const inviteId=randomUUID(),expires=new Date(Math.min(setup.expires_at.getTime(),ctx.now.getTime()+30*60_000));
    await ctx.db.query('INSERT INTO ritc.guardian_child_invitation(household_id,invite_id,enrollment_id,secret_hash,expires_at) VALUES($1,$2,$3,$4,$5)',[ctx.householdId,inviteId,id,tokenHash(input.secret),expires]);
    const receipt={inviteId,expiresAt:expires.toISOString()};await this.save(ctx,identity,input.clientKey,id,'invite',{id,...input},receipt);return{...receipt,token:ctx.householdId+'.'+inviteId+'.'+input.secret};
  }
  async confirm(ctx:Context,identity:VerifiedIdentity,id:string,input:z.infer<typeof guardianConfirmSchema>){
    const setup=await this.setup(ctx,identity,id);this.currentNotice(setup);await this.proof(ctx,setup,identity);
    const prior=await this.prior(ctx,identity,input.clientKey,'confirm',{id,...input});if(prior)return prior.response;
    if(setup.state!=='child_claimed'||setup.claim_id!==input.claimId||setup.revision!==input.baseRevision)throw stale();
    const claim=(await ctx.db.query(`SELECT c.* FROM ritc.guardian_child_claim c JOIN ritc.guardian_child_invitation i USING(household_id,invite_id) WHERE c.household_id=$1 AND c.claim_id=$2 AND i.enrollment_id=$3 AND c.revoked_at IS NULL AND i.revoked_at IS NULL AND c.expires_at>$4`,[ctx.householdId,input.claimId,id,ctx.now])).rows[0];
    if(!claim||claim.pairing_hash!==this.keyed('pairing',input.claimId+'\n'+input.pairingCode))throw unavailable();
    await this.repo.assertSession(ctx.db,{issuer:claim.issuer,subject:claim.subject,sessionId:claim.session_id,expiresAt:claim.expires_at},ctx.now);
    await ctx.db.query('UPDATE ritc.guardian_child_claim SET approved_at=$3 WHERE household_id=$1 AND claim_id=$2',[ctx.householdId,input.claimId,ctx.now]);
    const response=await this.advance(ctx,setup,input.baseRevision,'child_approved');await this.save(ctx,identity,input.clientKey,id,'confirm',{id,...input},response);return response;
  }
  async cancel(ctx:Context,identity:VerifiedIdentity,id:string,input:z.infer<typeof guardianActionSchema>){
    const setup=await this.setup(ctx,identity,id,true);const prior=await this.prior(ctx,identity,input.clientKey,'cancel',{id,...input});if(prior)return prior.response;
    if(setup.state==='active')throw new ServiceError(409,'guardian_withdraw_required','Withdraw current child permission through consent settings.');
    if(terminal.has(setup.state))throw ended();const response=await this.advance(ctx,setup,input.baseRevision,'cancelled');
    await ctx.db.query('UPDATE ritc.guardian_child_invitation SET revoked_at=COALESCE(revoked_at,$3) WHERE household_id=$1 AND enrollment_id=$2',[ctx.householdId,id,ctx.now]);
    await this.save(ctx,identity,input.clientKey,id,'cancel',{id,...input},response);return response;
  }
  async childSession(identity?:VerifiedIdentity,binding?:ChildSigninBinding){
    const available=this.notice('en').available&&this.notice('es').available;
    const empty={available,authenticated:Boolean(identity),admitted:false,scope:null,householdId:null,inviteId:null,claimId:null,status:'none' as const,expiresAt:null};
    if(!identity||!binding)return empty;
    return this.childTransaction(binding.householdId,identity,async ctx=>{
      const row=(await ctx.db.query(`SELECT a.expires_at,e.state,e.child_id,e.enrollment_id,e.consent_id,c.claim_id,c.approved_at,c.revoked_at FROM ritc.guardian_child_signin a JOIN ritc.guardian_child_invitation v USING(household_id,invite_id) JOIN ritc.guardian_enrollment e USING(household_id,enrollment_id) LEFT JOIN ritc.guardian_child_claim c ON c.household_id=a.household_id AND c.invite_id=a.invite_id AND c.issuer=a.issuer AND c.subject=a.subject AND c.session_id=a.session_id
       WHERE a.household_id=$1 AND a.invite_id=$2 AND a.issuer=$3 AND a.subject=$4 AND a.session_id=$5`,[binding.householdId,binding.inviteId,identity.issuer,identity.subject,identity.sessionId])).rows[0];
      if(!row)return empty;
      let ended=!available||terminal.has(row.state)||row.revoked_at||(row.state!=='active'&&row.expires_at<=ctx.now);
      if(row.state==='active'){try{await this.repo.member(ctx.db,ctx.householdId,identity);}catch{ended=true;}}
      return{available,authenticated:true,admitted:!ended,scope:ended?null:'own_requests',householdId:binding.householdId,inviteId:binding.inviteId,claimId:row.claim_id??null,status:ended?'ended':row.state==='active'?'active':row.approved_at?'approved':row.claim_id?'awaiting_guardian':'admitted',expiresAt:row.expires_at.toISOString()};
    });
  }
  async startChildSignin(cookie:string,csrf:string,input:z.infer<typeof childAuthStartSchema>,address:string){
    if(!this.browserAuth)throw disabled();const [householdId,inviteId,value]=input.token.split('.');uuid.parse(householdId);uuid.parse(inviteId);secret.parse(value);
    await this.repo.transaction(householdId!,async(db,now)=>{const row=(await db.query('SELECT secret_hash FROM ritc.guardian_child_invitation WHERE household_id=$1 AND invite_id=$2 AND revoked_at IS NULL AND consumed_at IS NULL AND expires_at>$3',[householdId,inviteId,now])).rows[0];if(row?.secret_hash!==tokenHash(value!))throw unavailable();});
    return this.browserAuth.start(cookie,csrf,{email:input.email},address,{householdId:householdId!,inviteId:inviteId!});
  }
  async beforeChildSignin(binding:ChildSigninBinding,email:string){
    return this.repo.transaction(binding.householdId,async(db,now)=>{
      const row=(await db.query('SELECT e.*,v.revoked_at AS invite_revoked,v.consumed_at,v.expires_at AS invite_expires FROM ritc.guardian_enrollment e JOIN ritc.guardian_child_invitation v USING(household_id,enrollment_id) WHERE v.household_id=$1 AND v.invite_id=$2',[binding.householdId,binding.inviteId])).rows[0];
      if(!row)throw unavailable();this.currentNotice(row);
      if(row.state!=='consented'||row.expires_at<=now||row.invite_expires<=now||row.invite_revoked||row.consumed_at)throw ended();
      if(row.child_email_digest!==this.keyed('child-email',email.trim().toLowerCase()))throw unavailable();
      const current=(await db.query('SELECT ritc.guardian_confirmed_email($1,$2,$3,$4,$5,$6) AS email',[binding.householdId,row.guardian_id,row.guardian_device_id,row.guardian_issuer,row.guardian_subject,row.guardian_session])).rows[0]?.email;
      const attempt=(await db.query('SELECT a.email_digest FROM ritc.guardian_attempt a JOIN ritc.guardian_provider_event p USING(household_id,attempt_id) WHERE a.household_id=$1 AND a.enrollment_id=$2',[binding.householdId,row.enrollment_id])).rows[0];
      if(typeof current!=='string'||attempt?.email_digest!==this.keyed('email',current))throw ended();
    });
  }
  private async trusted<T>(householdId:string,action:(db:Transaction)=>Promise<T>){
    if(!this.options.verifierPool)throw disabled();const db=await this.options.verifierPool.connect();try{await db.query('BEGIN');await db.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='3s'");await db.query("SELECT set_config('app.household_id',$1,true)",[householdId]);const result=await action(db);await db.query('COMMIT');return result;}catch(error){await db.query('ROLLBACK');throw error;}finally{db.release();}
  }
  async afterChildSignin(binding:ChildSigninBinding,identity:VerifiedIdentity,email:string,notBefore:Date){
    if(!identity.emailOTPAuthenticatedAt||identity.emailOTPAuthenticatedAt.getTime()+1000<notBefore.getTime())throw new ServiceError(401,'child_reauthentication_required','Verify the guardian-approved email code before continuing.');
    await this.beforeChildSignin(binding,email);
    const current=await this.childTransaction(binding.householdId,identity,async ctx=>(await ctx.db.query('SELECT ritc.guardian_child_confirmed_email($1,$2,$3,$4,$5) AS email',[ctx.householdId,binding.inviteId,identity.issuer,identity.subject,identity.sessionId])).rows[0]?.email);
    if(typeof current!=='string'||current.trim().toLowerCase()!==email.trim().toLowerCase())throw unavailable();
    const admitted=await this.trusted(binding.householdId,async db=>(await db.query('SELECT ritc.guardian_admit_child_verified($1,$2,$3,$4,$5,$6,$7) AS admitted',[binding.householdId,binding.inviteId,identity.issuer,identity.subject,identity.sessionId,current,this.keyed('child-email',current.trim().toLowerCase())])).rows[0]?.admitted);
    if(!admitted)throw unavailable();
  }
  async nativeSigninStart(input:z.infer<typeof childNativeStartSchema>,address:string){
    if(!this.otpProvider)throw disabled();const [householdId,inviteId,value]=input.token.split('.');uuid.parse(householdId);uuid.parse(inviteId);secret.parse(value);
    await this.beforeChildSignin({householdId:householdId!,inviteId:inviteId!},input.email);
    const prepared=await this.repo.transaction(householdId!,async(db,now)=>{
      const invitation=(await db.query('SELECT * FROM ritc.guardian_child_invitation WHERE household_id=$1 AND invite_id=$2 AND secret_hash=$3 AND revoked_at IS NULL AND consumed_at IS NULL AND expires_at>$4',[householdId,inviteId,tokenHash(value!),now])).rows[0];if(!invitation)throw unavailable();
      const prior=(await db.query('SELECT * FROM ritc.guardian_native_challenge WHERE household_id=$1 AND invite_id=$2',[householdId,inviteId])).rows[0];
      if(prior){if(prior.client_key!==input.clientKey||prior.payload_digest!==this.keyed('native-intent',canonical(input)))throw new ServiceError(409,'child_signin_pending','Use the retained child sign-in challenge.');return{send:false,receipt:{householdId:householdId!,challengeId:prior.challenge_id,status:'check_email' as const,expiresAt:prior.expires_at.toISOString()}};}
      for(const [kind,value,limit]of [['native-email',input.email.trim().toLowerCase(),5],['native-ip',address,20]] as const){const key=this.keyed(kind,value);await db.query("SELECT set_config('app.auth_rate_key',$1,true)",[key]);const row=(await db.query("INSERT INTO ritc.auth_rate_bucket(bucket_key,window_started,attempts) VALUES($1,$2,1) ON CONFLICT(bucket_key) DO UPDATE SET attempts=CASE WHEN ritc.auth_rate_bucket.window_started<$2::timestamptz-interval '1 hour' THEN 1 ELSE ritc.auth_rate_bucket.attempts+1 END,window_started=CASE WHEN ritc.auth_rate_bucket.window_started<$2::timestamptz-interval '1 hour' THEN $2 ELSE ritc.auth_rate_bucket.window_started END RETURNING attempts",[key,now])).rows[0];if(row.attempts>limit)throw new ServiceError(429,'login_rate_limited','Wait before requesting another code.');}
      const id=randomUUID(),expires=new Date(Math.min(invitation.expires_at.getTime(),now.getTime()+10*60_000));
      await db.query('INSERT INTO ritc.guardian_native_challenge(household_id,challenge_id,invite_id,client_key,secret_hash,payload_digest,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)',[householdId,id,inviteId,input.clientKey,tokenHash(input.challengeSecret),this.keyed('native-intent',canonical(input)),expires]);
      return{send:true,receipt:{householdId:householdId!,challengeId:id,status:'check_email' as const,expiresAt:expires.toISOString()}};
    });
    if(prepared.send){try{await this.otpProvider.start(input.email.trim().toLowerCase());}catch{throw new ServiceError(503,'child_signin_uncertain','Sign-in delivery is uncertain. Retain this challenge and check for the code.');}}return prepared.receipt;
  }
  async nativeSigninAdmit(identity:VerifiedIdentity,input:z.infer<typeof childNativeAdmitSchema>){
    const challenge=await this.repo.transaction(input.householdId,async(db,now)=>{
      await this.repo.assertSession(db,identity,now);const row=(await db.query('SELECT * FROM ritc.guardian_native_challenge WHERE household_id=$1 AND challenge_id=$2 AND secret_hash=$3 AND expires_at>$4',[input.householdId,input.challengeId,tokenHash(input.challengeSecret),now])).rows[0];if(!row)throw unavailable();
      if(row.subject){if(row.issuer!==identity.issuer||row.subject!==identity.subject||row.session_id!==identity.sessionId||row.admit_key!==input.clientKey)throw unavailable();}
      if(!identity.emailOTPAuthenticatedAt||identity.emailOTPAuthenticatedAt.getTime()+1000<row.created_at.getTime())throw new ServiceError(401,'child_reauthentication_required','Verify the guardian-approved sign-in code before continuing.');
      return row;
    });
    const email=await this.repo.transaction(input.householdId,async db=>(await db.query('SELECT ritc.guardian_child_confirmed_email($1,$2,$3,$4,$5) AS email',[input.householdId,challenge.invite_id,identity.issuer,identity.subject,identity.sessionId])).rows[0]?.email);
    if(typeof email!=='string')throw unavailable();await this.beforeChildSignin({householdId:input.householdId,inviteId:challenge.invite_id},email);
    const admitted=await this.trusted(input.householdId,async db=>(await db.query('SELECT ritc.guardian_admit_native_verified($1,$2,$3,$4,$5,$6,$7,$8,$9) AS admitted',[input.householdId,input.challengeId,identity.issuer,identity.subject,identity.sessionId,email,this.keyed('child-email',email.trim().toLowerCase()),tokenHash(input.challengeSecret),input.clientKey])).rows[0]?.admitted);if(!admitted)throw unavailable();
    return{admitted:true as const};
  }
  private async childTransaction<T>(householdId:string,identity:VerifiedIdentity,fn:(ctx:Context)=>Promise<T>){
    return this.repo.transaction(householdId,async(db,now)=>{await this.repo.assertSession(db,identity,now);
      await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[identity.issuer+'|'+identity.subject]);
      if((await db.query('SELECT ritc.identity_has_adult_profile($1,$2) AS adult',[identity.issuer,identity.subject])).rows[0]?.adult)throw unavailable();
      return fn({db,now,householdId,member:{member_id:'',kind:'child',organizer:false,can_contribute:false,alias:'',state:'pending'},deviceId:''});});
  }
  async claim(identity:VerifiedIdentity,input:z.infer<typeof childClaimSchema>){
    const [householdId,inviteId,provided]=input.token.split('.');uuid.parse(householdId);uuid.parse(inviteId);secret.parse(provided);
    return this.childTransaction(householdId!,identity,async ctx=>{
      const invitation=(await ctx.db.query('SELECT * FROM ritc.guardian_child_invitation WHERE household_id=$1 AND invite_id=$2 AND secret_hash=$3',[householdId,inviteId,tokenHash(provided!)])).rows[0];
      if(!invitation)throw unavailable();const setup=(await ctx.db.query('SELECT * FROM ritc.guardian_enrollment WHERE household_id=$1 AND enrollment_id=$2',[householdId,invitation.enrollment_id])).rows[0];this.currentNotice(setup);
      if(terminal.has(setup.state)||setup.expires_at<=ctx.now||invitation.revoked_at||invitation.expires_at<=ctx.now)throw ended();
      const prior=await this.prior(ctx,identity,input.clientKey,'claim',input);if(prior){const own=(await ctx.db.query('SELECT pairing_hash FROM ritc.guardian_child_claim WHERE household_id=$1 AND claim_id=$2 AND issuer=$3 AND subject=$4 AND session_id=$5 AND revoked_at IS NULL',[householdId,prior.response.claimId,identity.issuer,identity.subject,identity.sessionId])).rows[0];if(!own)throw unavailable();return prior.response;}
      if(setup.state!=='consented'||invitation.consumed_at)throw unavailable();
      const admission=await ctx.db.query('SELECT 1 FROM ritc.guardian_child_signin WHERE household_id=$1 AND invite_id=$2 AND issuer=$3 AND subject=$4 AND session_id=$5 AND expires_at>$6',[householdId,inviteId,identity.issuer,identity.subject,identity.sessionId,ctx.now]);if(!admission.rowCount)throw new ServiceError(403,'child_signin_required','Use the guardian-approved child sign-in before claiming this invitation.');
      const current=(await ctx.db.query('SELECT issuer,subject,kind,erased_at FROM ritc.member WHERE household_id=$1 AND member_id=$2',[householdId,setup.child_id])).rows[0];
      if(current&&(current.kind!=='child'||current.issuer!==identity.issuer||current.subject!==identity.subject||current.erased_at))throw unavailable();
      if((await ctx.db.query('SELECT 1 FROM ritc.member WHERE household_id=$1 AND issuer=$2 AND subject=$3 AND member_id<>$4',[householdId,identity.issuer,identity.subject,setup.child_id])).rowCount)throw unavailable();
      const childEmail=(await ctx.db.query('SELECT ritc.guardian_child_confirmed_email($1,$2,$3,$4,$5) AS email',[householdId,inviteId,identity.issuer,identity.subject,identity.sessionId])).rows[0]?.email;if(typeof childEmail!=='string'||setup.child_email_digest!==this.keyed('child-email',childEmail.trim().toLowerCase()))throw unavailable();
      const claimId=randomUUID(),expires=new Date(Math.min(invitation.expires_at.getTime(),identity.expiresAt.getTime()));
      await ctx.db.query('INSERT INTO ritc.guardian_child_claim(household_id,claim_id,invite_id,issuer,subject,session_id,pairing_hash,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',[householdId,claimId,inviteId,identity.issuer,identity.subject,identity.sessionId,this.keyed('pairing',claimId+'\n'+input.pairingCode),expires]);
      await ctx.db.query("UPDATE ritc.guardian_enrollment SET claim_id=$3,state='child_claimed',revision=revision+1 WHERE household_id=$1 AND enrollment_id=$2",[householdId,setup.enrollment_id,claimId]);
      const receipt={householdId,claimId,status:'awaiting_guardian' as const,expiresAt:expires.toISOString()};await this.save(ctx,identity,input.clientKey,setup.enrollment_id,'claim',input,receipt);return receipt;
    });
  }
  private async ownClaim(ctx:Context,identity:VerifiedIdentity,claimId:string){
    const claim=(await ctx.db.query(`SELECT c.*,i.enrollment_id,i.revoked_at AS invite_revoked FROM ritc.guardian_child_claim c JOIN ritc.guardian_child_invitation i USING(household_id,invite_id)
      WHERE c.household_id=$1 AND c.claim_id=$2 AND c.issuer=$3 AND c.subject=$4 AND c.session_id=$5`,[ctx.householdId,claimId,identity.issuer,identity.subject,identity.sessionId])).rows[0];
    if(!claim)throw unavailable();const setup=(await ctx.db.query('SELECT * FROM ritc.guardian_enrollment WHERE household_id=$1 AND enrollment_id=$2',[ctx.householdId,claim.enrollment_id])).rows[0];return{claim,setup};
  }
  async claimStatus(identity:VerifiedIdentity,householdId:string,claimId:string){return this.childTransaction(householdId,identity,async ctx=>{const {claim,setup}=await this.ownClaim(ctx,identity,claimId);return{claimId,status:terminal.has(setup.state)||claim.revoked_at||claim.invite_revoked||(setup.state!=='active'&&claim.expires_at<=ctx.now)?'ended':setup.state==='active'?'active':claim.approved_at?'approved':'awaiting_guardian',expiresAt:claim.expires_at.toISOString()};});}
  async finish(identity:VerifiedIdentity,input:z.infer<typeof childFinishSchema>){
    const prepared=await this.childTransaction(input.householdId,identity,async ctx=>{
      const {claim,setup}=await this.ownClaim(ctx,identity,input.claimId);this.currentNotice(setup);
      if(terminal.has(setup.state)||claim.revoked_at||claim.invite_revoked)throw ended();
      if(claim.pairing_hash!==this.keyed('pairing',input.claimId+'\n'+input.pairingCode))throw unavailable();
      const prior=await this.prior(ctx,identity,input.clientKey,'finish',input);if(prior){
        const device=(await ctx.db.query(`SELECT 1 FROM ritc.device d JOIN ritc.consent c ON c.household_id=d.household_id AND c.consent_id=d.guardian_consent_id WHERE d.household_id=$1 AND d.device_id=$2 AND d.member_id=$3 AND d.token_hash=$4 AND d.session_id=$5 AND d.revoked_at IS NULL AND c.revoked_at IS NULL`,[ctx.householdId,prior.response.deviceId,setup.child_id,tokenHash(input.deviceSecret),identity.sessionId])).rows[0];if(!device||setup.state!=='active')throw accessEnded();return{receipt:prior.response};
      }
      if(setup.state!=='child_approved'||claim.expires_at<=ctx.now||setup.expires_at<=ctx.now)throw ended();
      const childEmail=(await ctx.db.query('SELECT ritc.guardian_child_confirmed_email($1,$2,$3,$4,$5) AS email',[ctx.householdId,claim.invite_id,identity.issuer,identity.subject,identity.sessionId])).rows[0]?.email;if(typeof childEmail!=='string'||setup.child_email_digest!==this.keyed('child-email',childEmail.trim().toLowerCase()))throw ended();
      const guardianEmail=(await ctx.db.query('SELECT ritc.guardian_confirmed_email($1,$2,$3,$4,$5,$6) AS email',[ctx.householdId,setup.guardian_id,setup.guardian_device_id,setup.guardian_issuer,setup.guardian_subject,setup.guardian_session])).rows[0]?.email;
      if(typeof guardianEmail!=='string')throw ended();const emailDigest=this.keyed('email',guardianEmail);
      const expected=(await ctx.db.query('SELECT email_digest FROM ritc.guardian_attempt WHERE household_id=$1 AND enrollment_id=$2',[ctx.householdId,setup.enrollment_id])).rows[0];if(expected?.email_digest!==emailDigest)throw ended();
      await this.repo.assertSession(ctx.db,{issuer:setup.guardian_issuer,subject:setup.guardian_subject,sessionId:setup.guardian_session,expiresAt:setup.expires_at},ctx.now);
      return{claim,guardianEmail,childEmail,emailDigest};
    });
    if(prepared.receipt)return{...prepared.receipt,deviceToken:input.deviceSecret};
    const receipt=await this.trusted(input.householdId,async db=>(await db.query('SELECT ritc.guardian_finish_verified($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) AS receipt',[input.householdId,input.claimId,identity.issuer,identity.subject,identity.sessionId,prepared.claim.pairing_hash,prepared.emailDigest,randomUUID(),tokenHash(input.deviceSecret),input.clientKey,this.keyed('intent',canonical(input)),prepared.guardianEmail,prepared.childEmail])).rows[0]?.receipt);
    if(!receipt)throw ended();return{...receipt,deviceToken:input.deviceSecret};
  }
  async webhook(raw:Buffer,signature:string|undefined){
    if(!this.providerConfigured)throw disabled();const event=this.options.webhookVerifier!.verify(raw,signature);const db=await this.options.verifierPool!.connect();
    try{await db.query('BEGIN');await db.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='3s'");await db.query("SELECT set_config('app.household_id',$1,true)",[event.householdId]);
      const attempt=(await db.query(`SELECT a.*,e.guardian_id,e.guardian_device_id,e.guardian_issuer,e.guardian_subject,e.guardian_session FROM ritc.guardian_attempt a JOIN ritc.guardian_enrollment e USING(household_id,enrollment_id) WHERE a.household_id=$1 AND a.attempt_id=$2`,[event.householdId,event.attemptId])).rows[0];
      if(!attempt||attempt.nonce_hash!==tokenHash(event.nonce)||attempt.organization_id!==event.organizationId||attempt.product_id!==event.productId||attempt.environment!==event.environment)throw unavailable();
      if(event.eventTime.getTime()<attempt.created_at.getTime()-300_000||event.eventTime>attempt.expires_at||event.signatureTime.getTime()<attempt.created_at.getTime()-300_000)throw unavailable();
      const current=(await db.query('SELECT ritc.guardian_confirmed_email($1,$2,$3,$4,$5,$6) AS email',[event.householdId,attempt.guardian_id,attempt.guardian_device_id,attempt.guardian_issuer,attempt.guardian_subject,attempt.guardian_session])).rows[0]?.email;
      if(typeof current!=='string'||event.parentEmail!==current||attempt.email_digest!==this.keyed('email',current)){await db.query('COMMIT');return{received:true};}
      const outcome=(await db.query('SELECT ritc.guardian_record_verification($1,$2,$3,$4,$5,$6,$7,$8,$9) AS outcome',[event.householdId,event.attemptId,tokenHash(event.nonce),this.keyed('email',current),event.organizationId,event.productId,event.environment,event.transactionId,event.eventDigest])).rows[0]?.outcome;
      if(outcome==='changed_event')throw new ServiceError(409,'provider_event_changed','The provider transaction was already recorded with different evidence.');
      if(outcome==='unavailable')throw unavailable();await db.query('COMMIT');return{received:true};
    }catch(error){await db.query('ROLLBACK');throw error;}finally{db.release();}
  }
}
