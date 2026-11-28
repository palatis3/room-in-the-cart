import {guardianRetentionPolicy} from './guardian-policy.js';
import {z} from 'zod';
import type {PoolConfig} from 'pg';
import {Pool,assertRuntimeRole,type Database} from './database.js';
import {HouseholdRepository} from './repository.js';
import {GuardianEnrollmentService,type GuardianApprovedNotice,type GuardianEnrollmentOptions} from './guardian.js';
import {KWSParentVerificationGateway,KWSWebhookVerifier} from './guardian-provider.js';

const childCountriesSchema=z.array(z.enum(['US','MX'])).min(1).max(2)
  .refine(values=>values.includes('US')&&new Set(values).size===values.length);
const noticeSchema=z.object({version:z.string().min(1).max(100),digest:z.string().regex(/^[0-9a-f]{64}$/),locale:z.enum(['en','es']),text:z.string().min(1).max(30_000),scope:z.literal('own_requests'),methodVersion:z.string().min(1).max(100),approvalReference:z.string().min(1).max(200),childCountries:childCountriesSchema.optional()}).strict();
/** Configuration preparation alone never turns on child access. A complete actual
 * provider, distinct verifier role, reviewed notices and matching method are all
 * needed. No Boolean/environment-only child-network override is accepted. */
export async function guardianRuntime(repo:HouseholdRepository,environment:NodeJS.ProcessEnv,configuration:(env:NodeJS.ProcessEnv)=>PoolConfig):Promise<{service:GuardianEnrollmentService;pool?:Database}>{
  const retentionPolicy=guardianRetentionPolicy(environment);
  const manualReviewOptions:Pick<GuardianEnrollmentOptions,'manualReviewRetentionDays'|'unmatchedReviewRetentionDays'>={};
  if(environment.PRIVACY_CHILD_MANUAL_REVIEW_ENABLED==='true'){
    z.string().trim().min(1).max(200).parse(environment.PRIVACY_CHILD_MANUAL_REVIEW_APPROVAL_REFERENCE);
    z.string().min(1).parse(environment.GUARDIAN_EMAIL_DIGEST_KEY);
    manualReviewOptions.unmatchedReviewRetentionDays=z.coerce.number().int().min(1).max(365).parse(environment.PRIVACY_CHILD_UNMATCHED_REVIEW_RETENTION_DAYS);
    manualReviewOptions.manualReviewRetentionDays=z.coerce.number().int().min(1).max(365).parse(environment.PRIVACY_CHILD_MANUAL_REVIEW_RETENTION_DAYS);
  }
  let notices:GuardianApprovedNotice[]|undefined;
  if(environment.GUARDIAN_APPROVED_NOTICES_JSON){try{notices=z.array(noticeSchema).min(1).max(2).parse(JSON.parse(environment.GUARDIAN_APPROVED_NOTICES_JSON));}catch{throw new Error('Approved guardian notice configuration is invalid');}}
  const receiverSettings=['KWS_ORGANIZATION_ID','KWS_SCOPE','KWS_ENVIRONMENT','KWS_WEBHOOK_SECRETS_JSON','GUARDIAN_EMAIL_DIGEST_KEY','GUARDIAN_VERIFIER_DATABASE_URL'] as const;
  if(receiverSettings.some(name=>!environment[name]))return{service:new GuardianEnrollmentService(repo,{...manualReviewOptions,...(environment.GUARDIAN_EMAIL_DIGEST_KEY?{emailDigestKey:environment.GUARDIAN_EMAIL_DIGEST_KEY}:{}),...(notices?{notices}:{}),...(retentionPolicy?{retentionPolicy}:{})})};
  const environmentName=z.enum(['test','production']).parse(environment.KWS_ENVIRONMENT);
  const scope=z.enum(['organization','product']).parse(environment.KWS_SCOPE);
  const provider={organizationId:z.uuid().parse(environment.KWS_ORGANIZATION_ID),environment:environmentName,...(scope==='organization'?{scope,productId:null}:{scope,productId:z.uuid().parse(environment.KWS_PRODUCT_ID)})};
  if(scope==='organization'&&environment.KWS_PRODUCT_ID)throw new Error('Organization-scoped KWS must not supply a product ID');
  const secrets=z.array(z.string().min(16).max(1024)).min(1).max(3).parse(JSON.parse(environment.KWS_WEBHOOK_SECRETS_JSON!));
  const {KWS_CLIENT_ID:clientId,KWS_API_KEY:apiKey,KWS_USER_AGENT:userAgent,KWS_SERVICE_ORIGIN:serviceOrigin}=environment;
  const gateway=clientId&&apiKey&&userAgent&&serviceOrigin
    ?new KWSParentVerificationGateway(provider,{clientId,apiKey,userAgent,serviceOrigin})
    :undefined;
  const webhookVerifier=new KWSWebhookVerifier(provider,secrets);
  const pool=new Pool(configuration({...environment,DATABASE_URL:environment.GUARDIAN_VERIFIER_DATABASE_URL!}));
  pool.on('error',()=>console.error(JSON.stringify({event:'guardian_verifier_idle_connection_error'})));
  try{
    await assertRuntimeRole(pool);
    const authority=(await pool.query("SELECT pg_has_role(current_user,'ritc_guardian_verifier','member') AS verifier,pg_has_role(current_user,'ritc_app','member') AS app,pg_has_role(current_user,'ritc_worker','member') AS worker,current_user<>session_user AS switched_role,(EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='ritc' AND pg_has_role(session_user,c.relowner,'MEMBER')) OR EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='ritc' AND pg_has_role(session_user,nspowner,'MEMBER')) OR EXISTS(SELECT 1 FROM pg_database WHERE datname=current_database() AND pg_has_role(session_user,datdba,'MEMBER'))) AS owner")).rows[0];
    const writer=(await repo.pool.query("SELECT has_function_privilege(current_user,'ritc.guardian_record_verification(uuid,uuid,text,text,text,uuid,text,text,text)','EXECUTE') OR has_function_privilege(current_user,'ritc.guardian_admit_child_verified(uuid,uuid,text,text,text,text,text)','EXECUTE') OR has_function_privilege(current_user,'ritc.guardian_finish_verified(uuid,uuid,text,text,text,text,text,uuid,text,uuid,text,text,text)','EXECUTE') AS proof")).rows[0];
    if(!authority?.verifier||authority.app||authority.worker||authority.switched_role||authority.owner||writer?.proof)throw new Error('Guardian proof requires a distinct verifier-only database login');
    const service=new GuardianEnrollmentService(repo,{...manualReviewOptions,...(gateway?{gateway}:{}),webhookVerifier,verifierPool:pool,emailDigestKey:environment.GUARDIAN_EMAIL_DIGEST_KEY!,...(retentionPolicy?{retentionPolicy}:{}),...(notices?{notices}:{})});
    return{service,pool};
  }catch(error){await pool.end();throw error;}
}
