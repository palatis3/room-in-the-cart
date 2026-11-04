import {randomUUID,createHash} from 'node:crypto';
import {decodeJwt} from 'jose';
import {z} from 'zod';
import type {VerifiedIdentity} from './auth.js';
import {HouseholdRepository} from './repository.js';
import {type Database,digest,tokenHash} from './database.js';
import {ServiceError} from './errors.js';
import {assertWorkerRole} from './maintenance.js';
import type {PrivacyJournalPort} from './privacy-journal.js';
import type {DurablePrivacyJournalPort,JournalCall,WorkerJournalKind} from './privacy-journal-durable-contract.js';
import {JournalWriterBusy} from './privacy-journal-durable-contract.js';
import {PrivacyCall,privacyPhase,withPrivacyClient} from './privacy-call.js';
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
export interface AccountDeletionProvider { assertAvailable(subject:string,call?:JournalCall):Promise<void>; deleteAccount(subject:string,call?:JournalCall):Promise<void> }
const unavailable=()=>new ServiceError(503,'deletion_unavailable','Account deletion is unavailable until the configured provider can remove the account.');
export class SupabaseAccountDeletionProvider implements AccountDeletionProvider {
 private readonly base:string;private readonly key:string;
 constructor(config:{url:string;secretKey:string;revokeApple?:(subject:string,call?:JournalCall)=>Promise<void>},private readonly fetcher:typeof fetch=(input,init)=>globalThis.fetch(input,init)){
  const url=new URL(config.url);if(url.protocol!=='https:'||url.username||url.password||url.search||url.hash||!['','/'].includes(url.pathname))throw Error('Fixed HTTPS provider origin required');
  if(!config.secretKey.startsWith('sb_secret_')){try{if(decodeJwt(config.secretKey).role!=='service_role')throw Error();}catch{throw Error('Privileged server-only provider key required');}}
  if(config.secretKey.length<20||config.secretKey.length>4096)throw Error('Invalid privileged provider key');this.base=url.origin+'/auth/v1/admin/users/';this.key=config.secretKey;this.apple=config.revokeApple;
 }
 private readonly apple:((subject:string,call?:JournalCall)=>Promise<void>)|undefined;
 private async request(subject:string,method:'GET'|'DELETE',parent:JournalCall){
  return privacyPhase(parent,async call=>{
  id.parse(subject);let response:Response;
  try{response=await this.fetcher(this.base+subject,{method,headers:{apikey:this.key,...(this.key.startsWith('sb_secret_')?{}:{Authorization:'Bearer '+this.key}),'Content-Type':'application/json'},redirect:'error',signal:call.signal,...(method==='DELETE'?{body:JSON.stringify({should_soft_delete:false})}:{})});}catch{throw unavailable();}
  if(response.status===404)return null;if(!response.ok)throw unavailable();if(method==='DELETE'){await response.body?.cancel();return null;}
  if(!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type')??''))throw unavailable();
  const reader=response.body?.getReader();if(!reader)throw unavailable();let size=0;const parts:Uint8Array[]=[];
  for(;;){const part=await reader.read();if(part.done)break;size+=part.value.length;if(size>65536){await reader.cancel();throw unavailable();}parts.push(part.value);}
  try{const user=z.object({id,identities:z.array(z.object({provider:z.string()}))}).parse(JSON.parse(Buffer.concat(parts).toString('utf8')));if(user.id!==subject)throw Error();return user;}catch{throw unavailable();}
  });
 }
 private async account(subject:string,call:JournalCall){const value=await this.request(subject,'GET',call);if(value&&value.identities.some(i=>i.provider==='apple')&&!this.apple)throw unavailable();return value;}
 async assertAvailable(subject:string,parent?:JournalCall){const scope=new PrivacyCall(parent);try{await scope.run(async call=>{if(!await this.account(subject,call))throw unavailable();});}finally{scope.dispose();}}
 async deleteAccount(subject:string,parent?:JournalCall){const scope=new PrivacyCall(parent);try{await scope.run(async call=>{const user=await this.account(subject,call);if(!user)return;if(user.identities.some(i=>i.provider==='apple'))await privacyPhase(call,child=>this.apple!(subject,child));scope.check();await this.request(subject,'DELETE',call);scope.check();if(await this.request(subject,'GET',call))throw unavailable();});}finally{scope.dispose();}}
}
export interface DeletionPolicy {receiptRetentionDays:number;erasureMarkerRetentionDays:number;verifiedBackupRetentionDays:number}
export function validateDeletionPolicy(value:unknown):DeletionPolicy{const checked=z.object({receiptRetentionDays:z.number().int().min(1).max(365),erasureMarkerRetentionDays:z.number().int().min(1).max(3650),verifiedBackupRetentionDays:z.number().int().min(0).max(3650)}).strict().parse(value);if(checked.erasureMarkerRetentionDays<Math.max(checked.receiptRetentionDays,checked.verifiedBackupRetentionDays))throw Error('Erasure markers must cover receipts and the verified backup horizon');return Object.freeze(checked);}
async function privacyQuery(pool:Database,call:JournalCall,text:string,values:unknown[]=[]){
 return withPrivacyClient(pool,call,async db=>{
  try{
   await db.query('BEGIN');
   await db.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='2s'");
   const result=await db.query(text,values);
   await db.query('COMMIT');
   return result;
  }catch(error){await db.query('ROLLBACK').catch(()=>{});throw error;}
 });
}
function digestSession(identity:VerifiedIdentity){return createHash('sha256').update(identity.issuer+'\n'+identity.subject+'\n'+identity.sessionId).digest('hex');}
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
 constructor(private readonly repo:HouseholdRepository,private readonly options:{provider?:AccountDeletionProvider;policy?:DeletionPolicy;journal?:PrivacyJournalPort|DurablePrivacyJournalPort;
  available?:(call:JournalCall)=>Promise<boolean>;assertSource?:(call:JournalCall)=>Promise<void>}={}){this.policy=options.policy?validateDeletionPolicy(options.policy):undefined;}
 private async authenticated(identity:VerifiedIdentity,call:JournalCall){return withPrivacyClient(this.repo.pool,call,async db=>{try{await db.query('BEGIN');await this.repo.assertSession(db,identity,new Date());await db.query('COMMIT');}catch(e){await db.query('ROLLBACK').catch(()=>{});throw e;}});}
 private query(call:JournalCall,text:string,values:unknown[]=[]){return privacyQuery(this.repo.pool,call,text,values);}
 async preview(identity:VerifiedIdentity,parent?:JournalCall){
  const scope=new PrivacyCall(parent);try{return await scope.run(async call=>{
  await this.authenticated(identity,call);
  try{const result=(await this.query(call,'SELECT ritc.privacy_preview($1,$2,$3::uuid) AS value',[identity.issuer,identity.subject,identity.sessionId])).rows[0].value;
   const deletionAvailable=Boolean(this.options.provider&&this.policy&&this.options.journal)&&(!this.options.available||await this.options.available(call));
   return{...result,verifiedBackupRetentionDays:this.policy?.verifiedBackupRetentionDays??null,deletionAvailable,reauthenticationRequired:!identity.authenticatedAt||Date.now()-identity.authenticatedAt.getTime()>300000,subscriptionManagementURL:'https://apps.apple.com/account/subscriptions/',subscriptionCancelledByDeletion:false};
  }catch(e){return mapped(e);}
  });}finally{scope.dispose();}
 }
 async request(identity:VerifiedIdentity,input:z.infer<typeof deletionSchema>,parent?:JournalCall){
  input=deletionSchema.parse(input);
  const scope=new PrivacyCall(parent);try{return await scope.run(async call=>{
  recent(identity);await this.authenticated(identity,call);if(!this.options.provider||!this.policy||!this.options.journal||!identity.authenticatedMethod)throw unavailable();
  if(this.options.available&&!await this.options.available(call))throw unavailable();
  const {provider,journal}=this.options,retention=this.policy;
  await privacyPhase(call,child=>provider.assertAvailable(identity.subject,child));
  let eventId:string;
  await withPrivacyClient(this.repo.pool,call,async db=>{try{
   await db.query('BEGIN');await db.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='2s'; SET LOCAL idle_in_transaction_session_timeout='7s'");
   const event=(await db.query('SELECT ritc.privacy_journal_request($1,$2,$3::uuid,$4::uuid,$5,$6,$7::jsonb,$8,$9,$10::jsonb) AS event',[identity.issuer,identity.subject,identity.sessionId,input.clientKey,tokenHash(input.statusToken),digest({...input,statusToken:undefined}),JSON.stringify(input.households),retention.receiptRetentionDays,retention.erasureMarkerRetentionDays,JSON.stringify({configurationId:journal.configurationId,authenticatedAt:identity.authenticatedAt!.toISOString(),authenticatedMethod:identity.authenticatedMethod,providerAvailability:'configured_adapter_passed',appleGate:'availability_contract_passed',policy:retention,sessionBindingHash:digestSession(identity),checkedAt:new Date().toISOString()})])).rows[0].event;
   eventId=event.eventId;await privacyPhase(call,child=>journal.beforeCommit(event,child));scope.check();await db.query('COMMIT');
  }catch(e){await db.query('ROLLBACK').catch(()=>{});mapped(e);}});
  await privacyPhase(call,child=>journal.afterCommit(eventId!,child));
  return this.status(input.clientKey,input.statusToken,call);
  });}finally{scope.dispose();}
 }
 async status(jobId:string,statusToken:string,parent?:JournalCall){const scope=new PrivacyCall(parent);try{return await scope.run(async call=>{
  id.parse(jobId);secret.parse(statusToken);
  const read=async()=>{
   const value=(await this.query(call,'SELECT ritc.privacy_status($1,$2) AS value',[jobId,tokenHash(statusToken)])).rows[0].value;
   if(!value)throw new ServiceError(404,'unavailable','Use the deletion receipt from this device.');
   return value;
  };
  const value=await read();
  if(!this.options.journal)return value;
  await this.options.assertSource?.(call);
  await privacyPhase(call,child=>this.options.journal!.acknowledgeJob(jobId,child));
  return read();
 });}finally{scope.dispose();}}
 async leave(identity:VerifiedIdentity,householdId:string,input:z.infer<typeof exitSchema>,parent?:JournalCall){const scope=new PrivacyCall(parent);try{return await scope.run(async call=>{recent(identity);await this.authenticated(identity,call);if(input.disposition.householdId!==householdId||input.disposition.eraseChildProfiles.length)throw new ServiceError(422,'invalid_candidate','Leaving a household does not erase child profiles. Resolve guardian responsibility first.');
  try{await this.query(call,'SELECT ritc.leave_household($1,$2,$3::uuid,$4::uuid,$5::uuid,$6,$7::jsonb)',[identity.issuer,identity.subject,identity.sessionId,householdId,input.clientKey,digest(input),JSON.stringify(input.disposition)]);return{householdId,left:true as const,accountDeleted:false as const};}catch(e){return mapped(e);}
  });}finally{scope.dispose();}
 }
}
export class PrivacyMaintenance {
 constructor(private readonly pool:Database,private readonly options:{provider?:AccountDeletionProvider;journal?:PrivacyJournalPort|DurablePrivacyJournalPort;issuer?:string}={}){}
 private async bounded<T>(signal:AbortSignal|undefined,budgetMs:number,work:(scope:PrivacyCall)=>Promise<T>){
  const parent=signal?{signal,deadlineUnixMs:Date.now()+budgetMs,attemptId:randomUUID()}:undefined;
  const scope=new PrivacyCall(parent,budgetMs);
  try{return await scope.run(async call=>{
   await withPrivacyClient(this.pool,call,assertWorkerRole);
   return work(scope);
  });}finally{scope.dispose();}
 }
 private async retireReceipts(call:JournalCall,batch:number){
  const row=(await privacyQuery(this.pool,call,'SELECT * FROM ritc.privacy_cleanup($1)',[batch])).rows[0];
  return {receiptsCleared:row.receipts_cleared as number,jobsPurged:row.jobs_purged as number};
 }
 // Production may retire already-completed receipts using their persisted dates
 // without granting permission to claim, erase, or delete any pending account.
 async cleanup(input:{batchSize?:number;signal?:AbortSignal}={}){
  const batch=z.number().int().min(1).max(100).parse(input.batchSize??25);
  return this.bounded(input.signal,15_000,scope=>this.retireReceipts(scope.call,batch));
 }
 async run(input:{batchSize?:number;timeBudgetMs?:number;signal?:AbortSignal}={}){
  const {journal,provider}=this.options;
  if(!journal)throw unavailable();
  const batch=z.number().int().min(1).max(100).parse(input.batchSize??25);
  const budget=z.number().int().min(1000).max(25000).parse(input.timeBudgetMs??20000);
  return this.bounded(input.signal,budget,async scope=>{
   const {call}=scope;
   const result={completed:0,retryScheduled:0,leaseLost:0,capacityDeferred:0,issuerMismatch:0,journalDeferred:0,receiptsCleared:0,jobsPurged:0};
   const acknowledge=async(jobId:string)=>{
    try{await privacyPhase(call,phase=>journal.acknowledgeJob(jobId,phase));return true;}
    catch(error){
     if(!(error instanceof JournalWriterBusy))throw error;
     result.journalDeferred++;
     return false;
    }
   };
   // Resume exact journal observations left behind by an interrupted request or
   // worker. A reconciliation lease cannot erase targets or finish a job.
   for(let i=0;i<batch;i++){
    const lease=randomUUID();
    const {job_id:jobId}=(await privacyQuery(this.pool,call,'SELECT ritc.privacy_claim_reconciliation($1) AS job_id',[lease])).rows[0];
    if(!jobId)break;
    const acknowledged=await acknowledge(jobId);
    await privacyQuery(this.pool,call,'SELECT ritc.privacy_release_reconciliation($1,$2)',[jobId,lease]);
    if(!acknowledged)break;
   }
   Object.assign(result,await this.retireReceipts(call,batch));
   const reserve='reserveWorkerCapacity' in journal?journal.reserveWorkerCapacity.bind(journal):undefined;
   const needs=async(jobId:string,lease:string)=> (await privacyQuery(this.pool,call,'SELECT * FROM ritc.privacy_worker_journal_needs($1,$2)',[jobId,lease])).rows[0];
   const capacity=async(jobId:string,kinds:readonly WorkerJournalKind[])=>{
    try{if(!reserve||await privacyPhase(call,phase=>reserve(jobId,kinds,phase)))return true;}
    catch(error){
     if(!(error instanceof JournalWriterBusy))throw error;
     result.journalDeferred++;
     return false;
    }
    result.capacityDeferred++;
    return false;
   };
   // End the batch on contention. Capacity refusals still let later jobs use
   // their already reserved space.
   jobs:for(let i=0;i<batch&&result.journalDeferred===0;i++){
    const lease=randomUUID(),job=(await privacyQuery(this.pool,call,'SELECT * FROM ritc.privacy_claim($1)',[lease])).rows[0];
    if(!job)break;
    if(this.options.issuer&&job.issuer!==this.options.issuer){result.issuerMismatch++;continue;}
    let deleted=false,failure:string|null=null;
    try{
     let erased=job.app_erased;
     // At most 100 target profiles per leased run. Record each committed step
     // before taking another step or contacting the account provider.
     for(let n=0;n<100&&!erased;n++){
      if(reserve){
       const required=await needs(job.job_id,lease);
       if(!required){result.leaseLost++;continue jobs;}
       if(required.target_remaining&&!await capacity(job.job_id,['target_erased']))continue jobs;
      }
      erased=(await privacyQuery(this.pool,call,'SELECT ritc.privacy_erase_target($1,$2) AS erased',[job.job_id,lease])).rows[0].erased;
      if(!await acknowledge(job.job_id))return result;
     }
     if(erased){
      if(!await acknowledge(job.job_id))return result;
      if(!provider)failure='provider_configuration';
      else{
       if(reserve){
        const required=await needs(job.job_id,lease);
        if(!required){result.leaseLost++;continue jobs;}
        if(!await capacity(job.job_id,required.pending_needed?['source_pending','source_completed']:['source_completed']))continue jobs;
       }
       try{await privacyPhase(call,phase=>provider.deleteAccount(job.subject,phase),15_000);deleted=true;}
       catch{failure='provider_unavailable';}
      }
     }
    }catch{failure='storage_unavailable';}
    // A cancelled worker must leave the lease for recovery, including if a
    // provider request or database COMMIT is already in flight.
    scope.check();
    if(reserve&&!deleted){
     const required=await needs(job.job_id,lease);
     if(!required){result.leaseLost++;continue jobs;}
     if(required.pending_needed&&!await capacity(job.job_id,['source_pending']))continue jobs;
    }
    const committed=(await privacyQuery(this.pool,call,'SELECT ritc.privacy_finish($1,$2,$3,$4) AS committed',[job.job_id,lease,deleted,failure])).rows[0].committed;
    if(committed&&!await acknowledge(job.job_id))return result;
    if(!committed)result.leaseLost++;
    else if(deleted)result.completed++;
    else result.retryScheduled++;
   }
   return result;
  });
 }
}
