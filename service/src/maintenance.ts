import {createDecipheriv,randomUUID} from 'node:crypto';
import {z} from 'zod';
import type {Database} from './database.js';
import type {EmailOTPProvider} from './browser-auth.js';
export interface MaintenanceResult {
 expiredQueued:number; emailsCleared:number; authPurged:number; rateBucketsPurged:number;
 logoutCompleted:number; logoutRetryScheduled:number; logoutExpiredUnconfirmed:number; leaseLost:number;
}
export async function assertWorkerRole(pool:Database){
 const row=(await pool.query(`SELECT r.rolsuper,r.rolbypassrls,pg_has_role(current_user,'ritc_worker','USAGE') AS worker,
 pg_has_role(session_user,'ritc_app','MEMBER') AS application, current_user<>session_user AS switched_role,
 (EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='ritc' AND pg_has_role(session_user,c.relowner,'MEMBER'))
 OR EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='ritc' AND pg_has_role(session_user,nspowner,'MEMBER'))
 OR EXISTS(SELECT 1 FROM pg_database WHERE datname=current_database() AND pg_has_role(session_user,datdba,'MEMBER'))) AS owns_tables FROM pg_roles r WHERE rolname=current_user`)).rows[0];
 if(!row?.worker||row.rolsuper||row.rolbypassrls||row.owns_tables||row.application||row.switched_role)throw new Error('Maintenance requires the separate non-owner, non-bypass worker role');
}

export async function workerQuery(pool:Database,text:string,values:unknown[]=[]){
 const db=await pool.connect();try{await db.query('BEGIN');await db.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='2s'");const result=await db.query(text,values);await db.query('COMMIT');return result;}catch(error){await db.query('ROLLBACK');throw error;}finally{db.release();}
}
export class AuthMaintenance {
 private readonly key:Buffer|null;
 constructor(private readonly pool:Database,private readonly options:{encryptionKey?:string;provider?:Pick<EmailOTPProvider,'logout'>}){
  this.key=options.encryptionKey?Buffer.from(options.encryptionKey,'base64'):null;
  if(this.key&&(this.key.length!==32||this.key.toString('base64')!==options.encryptionKey))throw new Error('Invalid auth-maintenance encryption key');
 }
 private accessToken(ciphertext:string,binding:string){
  if(!this.key)throw new Error('configuration_unavailable');
  const[v,iv,tag,data]=ciphertext.split('.');if(v!=='v1'||!iv||!tag||!data)throw new Error('cipher_unavailable');
  const cipher=createDecipheriv('aes-256-gcm',this.key,Buffer.from(iv,'base64url'));cipher.setAAD(Buffer.from(binding));cipher.setAuthTag(Buffer.from(tag,'base64url'));
  const value=JSON.parse(Buffer.concat([cipher.update(Buffer.from(data,'base64url')),cipher.final()]).toString('utf8'));
  // Only the access token is used. A revoked session's refresh token is never used.
  return z.object({accessToken:z.string().min(1).max(16_384)}).parse(value).accessToken;
 }
 async run(input:{batchSize?:number;timeBudgetMs?:number;signal?:AbortSignal}={}):Promise<MaintenanceResult>{
  const checkpoint=()=>input.signal?.throwIfAborted();checkpoint();
  await assertWorkerRole(this.pool);
  const batchSize=z.number().int().min(1).max(100).parse(input.batchSize??25),budget=z.number().int().min(1000).max(25_000).parse(input.timeBudgetMs??20_000);
  checkpoint();const started=Date.now(),prepared=(await this.pool.query('SELECT * FROM ritc.maintenance_prepare_auth($1)',[batchSize])).rows[0];
  const result:MaintenanceResult={expiredQueued:prepared.expired_queued,emailsCleared:prepared.emails_cleared,authPurged:prepared.auth_purged,rateBucketsPurged:prepared.rates_purged,logoutCompleted:0,logoutRetryScheduled:0,logoutExpiredUnconfirmed:0,leaseLost:0};
  for(let index=0;index<batchSize&&Date.now()-started<budget;index++){
   checkpoint();
   const lease=randomUUID(),row=(await this.pool.query('SELECT * FROM ritc.maintenance_claim_logout($1)',[lease])).rows[0];if(!row)break;
   let outcome:'complete'|'retry'|'expired_unconfirmed'='retry',error:string|null=null;
   checkpoint();const present=(await this.pool.query('SELECT ritc.maintenance_provider_session_present($1::uuid,$2::uuid) AS present',[row.session_id,row.subject])).rows[0].present;
   if(!present)outcome='complete';
   else if(!row.access_expires_at||row.access_expires_at<=new Date()){outcome='expired_unconfirmed';error='token_expired';}
   else if(!this.options.provider||!this.key)error='configuration_unavailable';
   else{
    let access:string|undefined;
    try{access=this.accessToken(row.secret_cipher,row.token_hash);}catch{error='cipher_unavailable';}
    checkpoint();if(access){try{await this.options.provider.logout(access);outcome='complete';}catch{
     checkpoint();
     const stillPresent=(await this.pool.query('SELECT ritc.maintenance_provider_session_present($1::uuid,$2::uuid) AS present',[row.session_id,row.subject])).rows[0].present;
     if(!stillPresent)outcome='complete';else error='provider_unavailable';
    }}
   }
   checkpoint();const committed=(await this.pool.query('SELECT ritc.maintenance_finish_logout($1,$2,$3,$4) AS committed',[row.token_hash,lease,outcome,error])).rows[0].committed;
   if(!committed)result.leaseLost++;
   else if(outcome==='complete')result.logoutCompleted++;
   else if(outcome==='expired_unconfirmed')result.logoutExpiredUnconfirmed++;
   else result.logoutRetryScheduled++;
  }
  checkpoint();return result;
 }
}
