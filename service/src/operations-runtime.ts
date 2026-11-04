import type {PoolConfig} from 'pg';
import {randomUUID} from 'node:crypto';
import {Pool} from './database.js';
import {AuthMaintenance,assertWorkerRole} from './maintenance.js';
import {PrivacyMaintenance} from './privacy.js';
import {createPrivacyRuntime} from './privacy-runtime.js';
import {guardianRetentionPolicy} from './guardian-policy.js';
import {SupabaseEmailOTPProvider} from './browser-auth.js';

export const OPERATIONS_DEADLINE_MS=25_000;
export const OPERATIONS_BATCH_SIZE=25;
export type OperationsMode='run'|'status';

/** This pool never falls back to DATABASE_URL or ambient PG credentials. */
export function workerDatabaseConfiguration(environment:NodeJS.ProcessEnv):PoolConfig{
 if(!environment.WORKER_DATABASE_URL)throw Error('WORKER_DATABASE_URL is required');
 const url=new URL(environment.WORKER_DATABASE_URL);
 if(!['postgres:','postgresql:'].includes(url.protocol)||url.hash||!url.username||url.pathname.length<2)throw Error('Explicit PostgreSQL worker connection required');
 const user=decodeURIComponent(url.username);
 if(environment.DATABASE_URL&&decodeURIComponent(new URL(environment.DATABASE_URL).username)===user)throw Error('Worker and application credentials must be separate');
 const local=['localhost','127.0.0.1','[::1]'].includes(url.hostname);
 const socket=url.searchParams.get('host');
 if(socket&&(!local||!socket.startsWith('/')||environment.VERCEL==='1'))throw Error('Only local Unix fixture sockets are permitted');
 // Build explicit fields instead of giving pg a URL: connection-string query
 // options otherwise override TLS, timeouts, host, credentials, and startup role.
 return{
  // A password callback also prevents an empty fixture password from falling
  // back to an unrelated ambient PGPASSWORD in node-postgres.
  user,password:()=>decodeURIComponent(url.password),database:decodeURIComponent(url.pathname.slice(1)),
  host:socket??url.hostname.replace(/^\[|\]$/g,''),port:url.port?Number(url.port):5432,
  max:2,connectionTimeoutMillis:3000,idleTimeoutMillis:5000,allowExitOnIdle:true,
  statement_timeout:2000,lock_timeout:500,query_timeout:3000,
  application_name:'ritc-operations',options:'-c statement_timeout=2000 -c lock_timeout=500',
  ssl:local?false:{rejectUnauthorized:true,...(environment.WORKER_DATABASE_CA_PEM?{ca:environment.WORKER_DATABASE_CA_PEM}:{})},
 };
}

export function createOperationsRuntime(environment:NodeJS.ProcessEnv=process.env){
 const configuration=workerDatabaseConfiguration(environment);
 const guardianPolicy=guardianRetentionPolicy(environment);
 let provider:SupabaseEmailOTPProvider|undefined;
 if(environment.BFF_TOKEN_ENCRYPTION_KEY){
  if(!environment.SUPABASE_URL||!environment.SUPABASE_PUBLISHABLE_KEY)throw Error('Complete logout provider and encryption configuration required');
  const key=Buffer.from(environment.BFF_TOKEN_ENCRYPTION_KEY,'base64');
  if(key.length!==32||key.toString('base64')!==environment.BFF_TOKEN_ENCRYPTION_KEY)throw Error('Invalid auth-maintenance encryption key');
  provider=new SupabaseEmailOTPProvider({url:environment.SUPABASE_URL!,publicKey:environment.SUPABASE_PUBLISHABLE_KEY!});
 }
 const pool=new Pool(configuration);
 pool.on('error',()=>console.error(JSON.stringify({event:'operations_database_idle_error'})));
 const auth=new AuthMaintenance(pool,{
  ...(environment.BFF_TOKEN_ENCRYPTION_KEY?{encryptionKey:environment.BFF_TOKEN_ENCRYPTION_KEY}:{}),...(provider?{provider}:{}),
 });
 const privacyRuntime=createPrivacyRuntime(pool,environment,'operations');
 const privacy=new PrivacyMaintenance(pool,privacyRuntime.options);
 let running=false;
 return{pool,async close(){await Promise.all([privacyRuntime.close(),pool.end()]);},
 async run(mode:OperationsMode='run',signal:AbortSignal=AbortSignal.timeout(OPERATIONS_DEADLINE_MS)){
  if(running)throw Error('Operations already running');running=true;
  const started=Date.now();
  try{
   signal.throwIfAborted();await assertWorkerRole(pool);signal.throwIfAborted();
   const authResult=mode==='run'?await auth.run({batchSize:OPERATIONS_BATCH_SIZE,timeBudgetMs:10_000,signal}):null;
   signal.throwIfAborted();
   const privacyJournal=await privacyRuntime.health({attemptId:randomUUID(),deadlineUnixMs:started+OPERATIONS_DEADLINE_MS,signal});
   const privacyJobProcessingEnabled=privacyJournal.state==='ready';
   signal.throwIfAborted();
   const options={batchSize:OPERATIONS_BATCH_SIZE,signal};
   const deletionResult=mode==='run'&&privacyJobProcessingEnabled?await privacy.run({...options,timeBudgetMs:8000}):null;
   const privacyResult=mode==='run'?(deletionResult??await privacy.cleanup(options)):null;
   const privacyAttention=deletionResult&&(deletionResult.capacityDeferred||deletionResult.issuerMismatch||deletionResult.leaseLost);
   signal.throwIfAborted();
   const guardianResult=mode==='run'?(await pool.query('SELECT * FROM ritc.guardian_housekeeping($1,$2,$3)',[OPERATIONS_BATCH_SIZE,guardianPolicy?.pendingHours??null,guardianPolicy?.evidenceDays??null])).rows[0]:null;
   signal.throwIfAborted();
   const row=(await pool.query('SELECT * FROM ritc.operations_health()')).rows[0];signal.throwIfAborted();
   const health={authDue:Number(row.auth_due),authRetryPending:Number(row.auth_retry_pending),authExpiredUnconfirmed:Number(row.auth_expired_unconfirmed),privacyPending:Number(row.privacy_pending),privacyDue:Number(row.privacy_due)};
   return{event:'operations_result' as const,mode,durationMs:Date.now()-started,batchSize:OPERATIONS_BATCH_SIZE,
    logoutProviderConfigured:Boolean(provider),privacyJobProcessingEnabled,privacyJournal,auth:authResult,privacy:privacyResult,guardian:guardianResult?{expired:Number(guardianResult.expired),purged:Number(guardianResult.purged),retentionConfigured:Boolean(guardianPolicy)}:null,health,
    attentionRequired:Boolean(health.authDue||health.authRetryPending||health.authExpiredUnconfirmed||health.privacyPending||
     authResult?.logoutExpiredUnconfirmed||authResult?.leaseLost||privacyAttention||privacyJournal.capacity?.nearLimit||
     !['disabled','ready'].includes(privacyJournal.state)),
   };
  }finally{running=false;}
 }};
}
