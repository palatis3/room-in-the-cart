import {randomUUID} from 'node:crypto';
import {decodeJwt} from 'jose';
import {z} from 'zod';
import type {VerifiedIdentity} from './auth.js';
import {HouseholdRepository} from './repository.js';
import {type Database,digest,tokenHash} from './database.js';
import {ServiceError} from './errors.js';
import {assertWorkerRole,workerQuery} from './maintenance.js';
const id=z.string().uuid(),secret=z.string().regex(/^[A-Za-z0-9_-]{43}$/);
const shopChoice=z.discriminatedUnion('action',[
 z.object({shopId:id,revision:z.number().int().positive(),authorityEpoch:z.number().int().positive(),action:z.literal('close')}).strict(),
 z.object({shopId:id,revision:z.number().int().positive(),authorityEpoch:z.number().int().positive(),action:z.literal('transfer'),memberId:id}).strict()
]);
export const exitChoiceSchema=z.object({householdId:id,organizer:z.enum(['none','transfer','archive']),organizerMemberId:id.optional(),shops:z.array(shopChoice).max(100),eraseChildProfiles:z.array(id).max(100)}).strict().superRefine((value,ctx)=>{
 if(new Set(value.shops.map(shop=>shop.shopId)).size!==value.shops.length||new Set(value.eraseChildProfiles).size!==value.eraseChildProfiles.length)ctx.addIssue({code:'custom',message:'Duplicate target'});
});
export const deletionSchema=z.object({clientKey:id,statusToken:secret,confirm:z.literal(true),households:z.array(exitChoiceSchema).max(100)}).strict().superRefine((v,c)=>{if(new Set(v.households.map(h=>h.householdId)).size!==v.households.length)c.addIssue({code:'custom',message:'Duplicate household'});});
export const exitSchema=z.object({clientKey:id,confirm:z.literal(true),disposition:exitChoiceSchema}).strict();
export interface AccountDeletionProvider { assertAvailable(subject:string):Promise<void>; deleteAccount(subject:string):Promise<void> }
const unavailable=()=>new ServiceError(503,'deletion_unavailable','Account deletion is unavailable until the configured provider can remove the account.');
export class SupabaseAccountDeletionProvider implements AccountDeletionProvider {
 private readonly base:string;private readonly key:string;
 constructor(config:{url:string;secretKey:string;revokeApple?:(subject:string)=>Promise<void>},private readonly fetcher:typeof fetch=(input,init)=>globalThis.fetch(input,init)){
  const url=new URL(config.url);if(url.protocol!=='https:'||url.username||url.password||url.search||url.hash||!['','/'].includes(url.pathname))throw Error('Fixed HTTPS provider origin required');
  if(!config.secretKey.startsWith('sb_secret_')){try{if(decodeJwt(config.secretKey).role!=='service_role')throw Error();}catch{throw Error('Privileged server-only provider key required');}}
  if(config.secretKey.length<20||config.secretKey.length>4096)throw Error('Invalid privileged provider key');this.base=url.origin+'/auth/v1/admin/users/';this.key=config.secretKey;this.apple=config.revokeApple;
 }
 private readonly apple:((subject:string)=>Promise<void>)|undefined;
 private async request(subject:string,method:'GET'|'DELETE'){
  id.parse(subject);let response:Response;
  try{response=await this.fetcher(this.base+subject,{method,headers:{apikey:this.key,Authorization:'Bearer '+this.key,'Content-Type':'application/json'},redirect:'error',signal:AbortSignal.timeout(5000),...(method==='DELETE'?{body:JSON.stringify({should_soft_delete:false})}:{})});}catch{throw unavailable();}
  if(response.status===404)return null;if(!response.ok)throw unavailable();if(method==='DELETE'){await response.body?.cancel();return null;}
  if(!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type')??''))throw unavailable();
  const reader=response.body?.getReader();if(!reader)throw unavailable();let size=0;const parts:Uint8Array[]=[];
  for(;;){const part=await reader.read();if(part.done)break;size+=part.value.length;if(size>65536){await reader.cancel();throw unavailable();}parts.push(part.value);}
  try{const user=z.object({id,identities:z.array(z.object({provider:z.string()}))}).parse(JSON.parse(Buffer.concat(parts).toString('utf8')));if(user.id!==subject)throw Error();return user;}catch{throw unavailable();}
 }
 private async account(subject:string){const value=await this.request(subject,'GET');if(value&&value.identities.some(i=>i.provider==='apple')&&!this.apple)throw unavailable();return value;}
 async assertAvailable(subject:string){if(!await this.account(subject))throw unavailable();}
 async deleteAccount(subject:string){const user=await this.account(subject);if(!user)return;if(user.identities.some(i=>i.provider==='apple'))await this.apple!(subject);await this.request(subject,'DELETE');if(await this.request(subject,'GET'))throw unavailable();}
}
export interface DeletionPolicy {receiptRetentionDays:number;erasureMarkerRetentionDays:number;verifiedBackupRetentionDays:number}
function policy(value:DeletionPolicy){z.object({receiptRetentionDays:z.number().int().min(1).max(365),erasureMarkerRetentionDays:z.number().int().min(1).max(3650),verifiedBackupRetentionDays:z.number().int().min(0).max(3650)}).strict().parse(value);if(value.erasureMarkerRetentionDays<Math.max(value.receiptRetentionDays,value.verifiedBackupRetentionDays))throw Error('Erasure markers must cover receipts and the verified backup horizon');return value;}
function recent(identity:VerifiedIdentity){const time=identity.authenticatedAt?.getTime();if(!time||time>Date.now()+5000||Date.now()-time>5*60_000)throw new ServiceError(401,'reauthentication_required','Sign in again, then confirm this account action within five minutes.');}
function mapped(error:unknown):never{
 const message=error instanceof Error?error.message:'';
 if(message==='session_needed')throw new ServiceError(401,'session_needed','Sign in again.');
 if(message==='unavailable'||message==='adult_scope_required')throw new ServiceError(404,'unavailable','Use your own adult account.');
 if(message==='key_reused')throw new ServiceError(409,'key_reused','Use the original action and receipt, or review a new action.');
 if(['organizer_disposition_required','invalid_successor','shop_disposition_stale','shop_disposition_required','guardian_disposition_required','household_disposition_required'].includes(message))throw new ServiceError(409,message,'Refresh account responsibilities and explicitly review each household, shop, and child profile.');
 throw error;
}
export class PrivacyService {
 private readonly policy:DeletionPolicy|undefined;
 constructor(private readonly repo:HouseholdRepository,private readonly options:{provider?:AccountDeletionProvider;policy?:DeletionPolicy}={}){this.policy=options.policy?policy(options.policy):undefined;}
 private async authenticated(identity:VerifiedIdentity){const db=await this.repo.pool.connect();try{await db.query('BEGIN');await this.repo.assertSession(db,identity,new Date());await db.query('COMMIT');}catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}}
 async preview(identity:VerifiedIdentity){
  await this.authenticated(identity);
  try{const result=(await workerQuery(this.repo.pool,'SELECT ritc.privacy_preview($1,$2,$3::uuid) AS value',[identity.issuer,identity.subject,identity.sessionId])).rows[0].value;
   return{...result,verifiedBackupRetentionDays:this.policy?.verifiedBackupRetentionDays??null,deletionAvailable:Boolean(this.options.provider&&this.policy),reauthenticationRequired:!identity.authenticatedAt||Date.now()-identity.authenticatedAt.getTime()>300000,subscriptionManagementURL:'https://apps.apple.com/account/subscriptions/',subscriptionCancelledByDeletion:false};
  }catch(e){return mapped(e);}
 }
 async request(identity:VerifiedIdentity,input:z.infer<typeof deletionSchema>){
  recent(identity);await this.authenticated(identity);if(!this.options.provider||!this.policy)throw unavailable();
  await this.options.provider.assertAvailable(identity.subject);
  try{await workerQuery(this.repo.pool,'SELECT ritc.privacy_request($1,$2,$3::uuid,$4::uuid,$5,$6,$7::jsonb,$8,$9)',[identity.issuer,identity.subject,identity.sessionId,input.clientKey,tokenHash(input.statusToken),digest({...input,statusToken:undefined}),JSON.stringify(input.households),this.policy.receiptRetentionDays,this.policy.erasureMarkerRetentionDays]);}catch(e){mapped(e);}
  return this.status(input.clientKey,input.statusToken);
 }
 async status(jobId:string,statusToken:string){id.parse(jobId);secret.parse(statusToken);const value=(await workerQuery(this.repo.pool,'SELECT ritc.privacy_status($1,$2) AS value',[jobId,tokenHash(statusToken)])).rows[0].value;if(!value)throw new ServiceError(404,'unavailable','Use the deletion receipt from this device.');return value;}
 async leave(identity:VerifiedIdentity,householdId:string,input:z.infer<typeof exitSchema>){recent(identity);await this.authenticated(identity);if(input.disposition.householdId!==householdId||input.disposition.eraseChildProfiles.length)throw new ServiceError(422,'invalid_candidate','Leaving a household does not erase child profiles. Resolve guardian responsibility first.');
  try{await workerQuery(this.repo.pool,'SELECT ritc.leave_household($1,$2,$3::uuid,$4::uuid,$5::uuid,$6,$7::jsonb)',[identity.issuer,identity.subject,identity.sessionId,householdId,input.clientKey,digest(input),JSON.stringify(input.disposition)]);return{householdId,left:true as const,accountDeleted:false as const};}catch(e){return mapped(e);}
 }
}
export class PrivacyMaintenance {
 constructor(private readonly pool:Database,private readonly options:{provider?:AccountDeletionProvider}={}){}
 // Production may retire already-completed receipts using their persisted dates
 // without granting permission to claim, erase, or delete any pending account.
 async cleanup(input:{batchSize?:number;signal?:AbortSignal}={}){
  input.signal?.throwIfAborted();await assertWorkerRole(this.pool);
  const batch=z.number().int().min(1).max(100).parse(input.batchSize??25);
  input.signal?.throwIfAborted();const row=(await this.pool.query('SELECT * FROM ritc.privacy_cleanup($1)',[batch])).rows[0];
  input.signal?.throwIfAborted();return{receiptsCleared:row.receipts_cleared as number,jobsPurged:row.jobs_purged as number};
 }
 async run(input:{batchSize?:number;timeBudgetMs?:number}={}){
  await assertWorkerRole(this.pool);const batch=z.number().int().min(1).max(100).parse(input.batchSize??25),budget=z.number().int().min(1000).max(25000).parse(input.timeBudgetMs??20000),start=Date.now();
  const cleanup=(await workerQuery(this.pool,'SELECT * FROM ritc.privacy_cleanup($1)',[batch])).rows[0];
  const result={completed:0,retryScheduled:0,leaseLost:0,receiptsCleared:cleanup.receipts_cleared as number,jobsPurged:cleanup.jobs_purged as number};
  for(let i=0;i<batch&&Date.now()-start<budget;i++){
   const lease=randomUUID(),job=(await this.pool.query('SELECT * FROM ritc.privacy_claim($1)',[lease])).rows[0];if(!job)break;let deleted=false,failure:string|null=null;
   try{
    let erased=job.app_erased;
    // At most 100 target profiles per leased run; remaining work is durably retried.
    for(let n=0;n<100&&!erased&&Date.now()-start<budget;n++)erased=(await workerQuery(this.pool,'SELECT ritc.privacy_erase_target($1,$2) AS erased',[job.job_id,lease])).rows[0].erased;
    if(erased){if(!this.options.provider)failure='provider_configuration';else{try{await this.options.provider.deleteAccount(job.subject);deleted=true;}catch{failure='provider_unavailable';}}}
   }catch{failure='storage_unavailable';}
   const committed=(await this.pool.query('SELECT ritc.privacy_finish($1,$2,$3,$4) AS committed',[job.job_id,lease,deleted,failure])).rows[0].committed;
   if(!committed)result.leaseLost++;else if(deleted)result.completed++;else result.retryScheduled++;
  }return result;
 }
}
