import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes,randomUUID,createCipheriv} from 'node:crypto';
import {request as httpRequest} from 'node:http';
import {spawn} from 'node:child_process';
import pg from 'pg';
import {createOperationsHTTPServer} from '../dist/operations-http.js';
import {createOperationsRuntime} from '../dist/operations-runtime.js';
import {AuthMaintenance} from '../dist/maintenance.js';

const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL});
const app=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
const workerURL=new URL(process.env.TEST_DATABASE_URL);workerURL.username='ritc_test_worker';
const secret=randomBytes(32).toString('base64url'),key=randomBytes(32),hashes=[],sessions=[],jobs=[],servers=[];
const environment={WORKER_DATABASE_URL:process.env.TEST_WORKER_DATABASE_URL??workerURL.toString(),DATABASE_URL:process.env.TEST_DATABASE_URL,CRON_SECRET:secret,
 SUPABASE_URL:'https://operations.fixture.invalid',SUPABASE_PUBLISHABLE_KEY:'sb_publishable_fictional_operations_fixture',BFF_TOKEN_ENCRYPTION_KEY:key.toString('base64')};
let outage=false,providerCalls=0;const originalFetch=globalThis.fetch;
globalThis.fetch=async(input,init)=>{
 if(String(input).startsWith(environment.SUPABASE_URL)){
  assert.equal(String(input),environment.SUPABASE_URL+'/auth/v1/logout?scope=local');
  assert.equal(init.method,'POST');assert.ok(init.headers.Authorization.startsWith('Bearer fictional-access-'));
  assert.equal(init.body,undefined);providerCalls++;
  return outage?new Response('PRIVATE provider detail',{status:503}):new Response(null,{status:204});
 }
 return originalFetch(input,init);
};
async function start(env=environment){
 const value=createOperationsHTTPServer(env);await new Promise(resolve=>value.server.listen(0,'127.0.0.1',resolve));servers.push(value);
 return{...value,origin:'http://127.0.0.1:'+value.server.address().port};
}
async function call(server,path='/internal/maintenance',options={}){
 const response=await fetch(server.origin+path,{headers:{Authorization:'Bearer '+secret},...options});
 assert.equal(response.headers.get('cache-control'),'no-store');return{status:response.status,value:await response.json()};
}
function raw(server,options){return new Promise((resolve,reject)=>{
 if(Array.isArray(options.headers))options={...options,headers:['Host',new URL(server.origin).host,...options.headers]};
 const request=httpRequest(server.origin+'/internal/maintenance',options,response=>{const parts=[];response.on('data',part=>parts.push(part));response.on('end',()=>{const body=Buffer.concat(parts).toString();resolve({status:response.statusCode,value:body?JSON.parse(body):null});});});
 request.on('error',reject);request.end(options.body);
});}
async function fixture({expired=false,accessExpired=false,missing=false}={}){
 const hash=randomBytes(32).toString('hex'),subject=randomUUID(),session=randomUUID();hashes.push(hash);sessions.push(session);
 if(!missing)await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);
 const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,iv);cipher.setAAD(Buffer.from(hash));
 const data=Buffer.concat([cipher.update(JSON.stringify({accessToken:'fictional-access-'+hash,refreshToken:'never-refresh-'+hash})),cipher.final()]);
 const sealed=['v1',iv.toString('base64url'),cipher.getAuthTag().toString('base64url'),data.toString('base64url')].join('.');
 await admin.query(`INSERT INTO ritc.browser_auth(token_hash,csrf,phase,issuer,subject,session_id,access_expires_at,secret_cipher,expires_at,revoked_at)
 VALUES($1,'fictional-csrf','authenticated','https://operations.fixture.invalid',$2,$3,$4,$5,$6,$7)`,[hash,subject,session,new Date(Date.now()+(accessExpired?-3600000:3600000)),sealed,new Date(Date.now()+(expired?-3600000:3600000)),expired?null:new Date()]);return{hash,session};
}
async function row(hash){return(await admin.query('SELECT * FROM ritc.browser_auth WHERE token_hash=$1',[hash])).rows[0];}
before(async()=>{
 await admin.query("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ritc_test_worker') THEN CREATE ROLE ritc_test_worker LOGIN NOSUPERUSER NOBYPASSRLS; END IF; IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ritc_test_combined_worker') THEN CREATE ROLE ritc_test_combined_worker LOGIN NOSUPERUSER NOBYPASSRLS; END IF; END $$;GRANT ritc_worker TO ritc_test_worker,ritc_test_combined_worker;GRANT ritc_app TO ritc_test_combined_worker");
});
after(async()=>{
 globalThis.fetch=originalFetch;
 await Promise.all(servers.map(async value=>{await new Promise(resolve=>value.server.close(resolve));await value.close();}));
 await admin.query('DELETE FROM ritc.browser_auth WHERE token_hash=ANY($1::text[])',[hashes]);
 await admin.query('DELETE FROM auth.sessions WHERE id=ANY($1::uuid[])',[sessions]);
 await admin.query('DELETE FROM ritc.privacy_job WHERE job_id=ANY($1::uuid[])',[jobs]);
 await Promise.all([admin.end(),app.end()]);
});

async function cli(args,env){
 return new Promise((resolve,reject)=>{
  const child=spawn(process.execPath,['dist/operations-cli.js',...args],{
   cwd:new URL('../',import.meta.url),env:{...process.env,...env}
  });
  let output='';
  child.stdout.on('data',part=>{output+=part;});
  child.stderr.on('data',part=>{output+=part;});
  child.on('error',reject);
  child.on('close',code=>resolve({code,output}));
 });
}

test('monitoring check reads healthy worker state without running a maintenance batch',async()=>{
 const result=await cli(['status','--check'],environment);
 assert.equal(result.code,0);
 const report=JSON.parse(result.output);
 assert.equal(report.mode,'status');
 assert.equal(report.attentionRequired,false);
 assert.equal(report.auth,null);
 assert.equal(report.privacy,null);
 assert.equal(report.guardian,null);
});

test('actual HTTP adapter denies unauthorized requests before parsing or connecting worker credentials',async()=>{
 const server=await start({CRON_SECRET:secret,WORKER_DATABASE_URL:'invalid PRIVATE connection'});
 assert.equal((await call(server,'/internal/maintenance',{headers:{}})).status,401);
 assert.equal((await call(server,'/internal/maintenance',{headers:{Authorization:'Bearer wrong'}})).status,401);
 assert.equal((await raw(server,{headers:['Authorization','Bearer '+secret,'Authorization','Bearer '+secret]})).status,401);
 const absent=await start({});assert.equal((await call(absent)).status,503);
});
test('adapter rejects queries, unexpected paths, methods and bodies without running maintenance',async()=>{
 const server=await start();
 assert.equal((await call(server,'/internal/maintenance?batchSize=100')).status,404);
 assert.equal((await call(server,'/v1/maintenance')).status,404);
 assert.equal((await call(server,'/internal/maintenance',{method:'POST'})).status,405);
 assert.equal((await raw(server,{method:'GET',headers:{Authorization:'Bearer '+secret,'Content-Length':'2'},body:'{}'})).status,400);
});
test('deployed runtime role gate rejects application, administrator and combined worker credentials',async()=>{
 for(const connection of [process.env.TEST_DATABASE_URL,process.env.TEST_ADMIN_DATABASE_URL,(()=>{const url=new URL(process.env.TEST_DATABASE_URL);url.username='ritc_test_combined_worker';return url.toString();})()]){
  const server=await start({CRON_SECRET:secret,WORKER_DATABASE_URL:connection});
  const result=await call(server);assert.equal(result.status,503);assert.deepEqual(result.value,{error:'operations_unavailable'});
 }
 await assert.rejects(()=>app.query('SELECT * FROM ritc.operations_health()'),error=>error.code==='42501');
});
test('disabled email deployment with public provider metadata still runs housekeeping without an encryption key',async(t)=>{
 const info=t.mock.method(console,'info',()=>{});
 const {BFF_TOKEN_ENCRYPTION_KEY,...publicEnvironment}=environment;
 const result=await call(await start({...publicEnvironment,EMAIL_OTP_ENABLED:'false'}));
 assert.deepEqual(info.mock.calls.map(call=>JSON.parse(call.arguments[0])),[result.value]);
 assert.equal(result.status,200);assert.equal(result.value.logoutProviderConfigured,false);assert.equal(result.value.privacyJobProcessingEnabled,false);
});
test('worker startup applies actual PostgreSQL statement and lock limits without table access',async()=>{
 const runtime=createOperationsRuntime(environment);
 try{
  assert.equal((await runtime.pool.query('SHOW statement_timeout')).rows[0].statement_timeout,'2s');
  assert.equal((await runtime.pool.query('SHOW lock_timeout')).rows[0].lock_timeout,'500ms');
  await assert.rejects(()=>runtime.pool.query('SELECT * FROM ritc.browser_auth'),error=>error.code==='42501');
  await assert.rejects(()=>runtime.pool.query('SELECT * FROM auth.sessions'),error=>error.code==='42501');
 }finally{await runtime.pool.end();}
});
test('real HTTP/Postgres expiry and provider outage retry keep credentials until confirmed logout',async(t)=>{
 const warning=t.mock.method(console,'warn',()=>{});
 const server=await start(),f=await fixture({expired:true});outage=true;
 const first=await call(server);assert.equal(first.status,200);assert.equal(first.value.auth.expiredQueued,1);assert.equal(first.value.auth.logoutRetryScheduled,1);
 assert.equal(first.value.health.authRetryPending,1);assert.equal(first.value.attentionRequired,true);
 assert.deepEqual(warning.mock.calls.map(call=>JSON.parse(call.arguments[0])),[first.value]);
 let record=await row(f.hash);assert.equal(record.logout_last_error,'provider_unavailable');assert.equal(record.logout_attempts,1);assert.ok(record.secret_cipher);
 assert.equal((await call(server)).value.auth.logoutRetryScheduled,0);
 await admin.query("UPDATE ritc.browser_auth SET logout_next_at=clock_timestamp()-interval '1 second' WHERE token_hash=$1",[f.hash]);outage=false;
 const second=await call(server);assert.equal(second.value.auth.logoutCompleted,1);record=await row(f.hash);assert.equal(record.secret_cipher,null);assert.equal(record.subject,null);assert.equal(providerCalls,2);
 assert.equal(JSON.stringify([first,second]).includes(f.hash),false);assert.equal(JSON.stringify([first,second]).includes('PRIVATE'),false);
});
test('runtime reports expired provider sessions as unconfirmed and absent sessions as confirmed',async()=>{
 const server=await start(),expired=await fixture({accessExpired:true}),absent=await fixture({missing:true}),previous=providerCalls;
 const result=await call(server);assert.equal(result.value.auth.logoutExpiredUnconfirmed,1);assert.equal(result.value.auth.logoutCompleted,1);assert.equal(providerCalls,previous);
 assert.equal((await row(expired.hash)).logout_state,'expired_unconfirmed');assert.equal((await row(absent.hash)).logout_state,'complete');
 assert.equal(result.value.attentionRequired,true);
});
test('production cleanup honors completed retention dates and leaves every pending privacy job unclaimed',async()=>{
 const pending=randomUUID(),receipt=randomUUID(),purge=randomUUID();jobs.push(pending,receipt,purge);
 for(const [id,state,receiptAge,markerAge]of[[pending,'pending',1,2],[receipt,'complete',-1,2],[purge,'complete',-1,-1]]){
  await admin.query(`INSERT INTO ritc.privacy_job(job_id,identity_hash,issuer,subject,receipt_hash,payload_digest,state,receipt_retention_days,marker_retention_days,receipt_until,marker_until)
   VALUES($1,$2,'https://operations.fixture.invalid',$3,$4,$5,$6,1,2,clock_timestamp()+make_interval(days=>$7),clock_timestamp()+make_interval(days=>$8))`,[id,randomBytes(32).toString('hex'),randomUUID(),randomBytes(32).toString('hex'),randomBytes(32).toString('hex'),state,receiptAge,markerAge]);
 }
 const previous=providerCalls,result=await call(await start());assert.equal(result.status,200);
 assert.deepEqual(result.value.privacy,{receiptsCleared:2,jobsPurged:1});assert.equal(result.value.privacyJobProcessingEnabled,false);
 assert.equal(result.value.health.privacyPending,1);assert.equal(result.value.health.privacyDue,1);assert.equal(result.value.attentionRequired,true);assert.equal(providerCalls,previous);
 const record=(await admin.query('SELECT state,attempts,app_erased_at,provider_erased_at FROM ritc.privacy_job WHERE job_id=$1',[pending])).rows[0];
 assert.deepEqual(record,{state:'pending',attempts:0,app_erased_at:null,provider_erased_at:null});
 assert.equal((await admin.query('SELECT receipt_hash FROM ritc.privacy_job WHERE job_id=$1',[receipt])).rows[0].receipt_hash,'0'.repeat(64));
});
test('aggregate deadline leaves an interrupted provider outcome leased rather than falsely completed',async()=>{
 const f=await fixture(),runtime=createOperationsRuntime(environment),controller=new AbortController();
 try{
  await assert.rejects(()=>new AuthMaintenance(runtime.pool,{encryptionKey:key.toString('base64'),provider:{logout:async()=>{controller.abort();}}}).run({batchSize:1,signal:controller.signal}),error=>error.name==='AbortError');
  const record=await row(f.hash);assert.equal(record.logout_state,'leased');assert.ok(record.secret_cipher);assert.equal(record.logout_finished_at,null);
  await admin.query("UPDATE ritc.browser_auth SET logout_lease_until=clock_timestamp()-interval '1 second' WHERE token_hash=$1",[f.hash]);
  const result=await runtime.run();assert.equal(result.auth.logoutCompleted,1);
 }finally{await runtime.pool.end();}
});
test('runnable operator CLI status emits aggregate evidence, and bad credentials fail without connection text',async()=>{
 const status=await cli(['status'],environment);assert.equal(status.code,0);const value=JSON.parse(status.output.trim());assert.equal(value.mode,'status');assert.equal(value.auth,null);assert.equal(value.privacyJobProcessingEnabled,false);assert.equal(value.health.privacyPending,1);
 const check=await cli(['status','--check'],environment);
 assert.equal(check.code,3);
 const report=JSON.parse(check.output);
 assert.equal(report.attentionRequired,true);
 assert.deepEqual(report.health,value.health);
 assert.equal(report.auth,null);
 assert.equal(report.privacy,null);
 assert.equal(report.guardian,null);
 assert.equal((await cli(['run','--check'],environment)).code,2);
 assert.equal((await cli(['status','--check','extra'],environment)).code,2);
 const run=await cli(['run'],environment);assert.equal(run.code,0);assert.equal(JSON.parse(run.output.trim()).mode,'run');
 const failure=await cli(['run'],{WORKER_DATABASE_URL:'PRIVATE invalid connection'});assert.equal(failure.code,1);assert.equal(failure.output.includes('PRIVATE'),false);
 assert.equal((await cli([],environment)).code,2);
});
