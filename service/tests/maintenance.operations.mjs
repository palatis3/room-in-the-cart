import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes,randomUUID,createCipheriv} from 'node:crypto';
import pg from 'pg';
import {AuthMaintenance,assertWorkerRole} from '../dist/maintenance.js';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL});
const url=new URL(process.env.TEST_DATABASE_URL);url.username='ritc_test_worker';
const worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL??url.toString(),max:4});
const app=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
const key=randomBytes(32),ids=[];
function seal(hash,value){const iv=randomBytes(12),c=createCipheriv('aes-256-gcm',key,iv);c.setAAD(Buffer.from(hash));const data=Buffer.concat([c.update(JSON.stringify(value)),c.final()]);return['v1',iv.toString('base64url'),c.getAuthTag().toString('base64url'),data.toString('base64url')].join('.');}
async function fixture({expired=false,revoked=true,accessExpired=false,missing=false}={}){
 const hash=randomBytes(32).toString('hex'),subject=randomUUID(),session=randomUUID();ids.push(hash);
 if(!missing)await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);
 await admin.query(`INSERT INTO ritc.browser_auth(token_hash,csrf,phase,issuer,subject,session_id,access_expires_at,secret_cipher,expires_at,revoked_at)
 VALUES($1,'fixture-csrf','authenticated','https://fixture.invalid',$2,$3,$4,$5,$6,$7)`,[hash,subject,session,new Date(Date.now()+(accessExpired?-3600000:3600000)),seal(hash,{accessToken:'fictional-access-'+hash,refreshToken:'never-refresh-'+hash}),new Date(Date.now()+(expired?-3600000:3600000)),revoked?new Date():null]);return{hash,subject,session};
}
async function row(hash){return(await admin.query('SELECT * FROM ritc.browser_auth WHERE token_hash=$1',[hash])).rows[0];}
before(async()=>{await admin.query("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ritc_test_worker') THEN CREATE ROLE ritc_test_worker LOGIN NOSUPERUSER NOBYPASSRLS; END IF; END $$; GRANT ritc_worker TO ritc_test_worker");});
after(async()=>{await admin.query('DELETE FROM ritc.browser_auth WHERE token_hash=ANY($1::text[])',[ids]);await Promise.all([admin.end(),worker.end(),app.end()]);});
test('maintenance requires the separate worker role and does not grant raw access',async()=>{
 await assertWorkerRole(worker);await assert.rejects(()=>assertWorkerRole(app),/separate/);await assert.rejects(()=>assertWorkerRole(admin),/separate/);
 await assert.rejects(()=>app.query('SELECT ritc.maintenance_prepare_auth(1)'),e=>e.code==='42501');
 await assert.rejects(()=>worker.query('SELECT * FROM ritc.browser_auth'),e=>e.code==='42501');
 await assert.rejects(()=>worker.query('SELECT * FROM auth.sessions'),e=>e.code==='42501');
 await assert.rejects(()=>new AuthMaintenance(worker,{}).run({batchSize:101}));
});
test('logout outage is durably retried without refreshing revoked credentials',async()=>{
 const f=await fixture();let calls=0;
 const maintenance=new AuthMaintenance(worker,{encryptionKey:key.toString('base64'),provider:{logout:async token=>{assert.equal(token,'fictional-access-'+f.hash);calls++;throw Error('PRIVATE upstream detail');}}});
 let result=await maintenance.run({batchSize:1});assert.equal(result.logoutRetryScheduled,1);assert.equal(calls,1);
 let record=await row(f.hash);assert.equal(record.logout_state,'pending');assert.equal(record.logout_attempts,1);assert.ok(record.logout_next_at>Date.now());assert.equal(record.logout_last_error,'provider_unavailable');assert.ok(record.secret_cipher);
 result=await maintenance.run({batchSize:1});assert.equal(result.logoutRetryScheduled,0);assert.equal(calls,1);
 await admin.query("UPDATE ritc.browser_auth SET logout_next_at=clock_timestamp()-interval '1 second' WHERE token_hash=$1",[f.hash]);
 result=await new AuthMaintenance(worker,{encryptionKey:key.toString('base64'),provider:{logout:async token=>{assert.equal(token,'fictional-access-'+f.hash);await admin.query('DELETE FROM auth.sessions WHERE id=$1',[f.session]);}}}).run({batchSize:1});
 assert.equal(result.logoutCompleted,1);record=await row(f.hash);assert.equal(record.secret_cipher,null);assert.equal(record.subject,null);assert.ok(record.revoked_at);assert.equal(JSON.stringify(result).includes('fictional'),false);
});
test('lease claim is exclusive, rejects wrong completion and recovers an abandoned lease',async()=>{
 const f=await fixture(),a=randomUUID(),b=randomUUID();const claims=await Promise.all([worker.query('SELECT * FROM ritc.maintenance_claim_logout($1)',[a]),worker.query('SELECT * FROM ritc.maintenance_claim_logout($1)',[b])]);
 const won=claims.findIndex(r=>r.rows.some(v=>v.token_hash===f.hash));assert.ok(won>=0);assert.equal(claims.flatMap(r=>r.rows).filter(v=>v.token_hash===f.hash).length,1);
 const wrong=(await worker.query("SELECT ritc.maintenance_finish_logout($1,$2,'complete') AS done",[f.hash,randomUUID()])).rows[0];assert.equal(wrong.done,false);
 await admin.query("UPDATE ritc.browser_auth SET logout_lease_until=clock_timestamp()-interval '1 second' WHERE token_hash=$1",[f.hash]);
 const next=randomUUID(),claimed=(await worker.query('SELECT * FROM ritc.maintenance_claim_logout($1)',[next])).rows[0];assert.equal(claimed.token_hash,f.hash);assert.equal(claimed.attempt,2);
 assert.equal((await worker.query("SELECT ritc.maintenance_finish_logout($1,$2,'complete') AS done",[f.hash,[a,b][won]])).rows[0].done,false);
 assert.equal((await worker.query("SELECT ritc.maintenance_finish_logout($1,$2,'complete') AS done",[f.hash,next])).rows[0].done,true);
});
test('expired access is honestly unconfirmed while an absent exact provider session is complete',async()=>{
 const expired=await fixture({accessExpired:true}),absent=await fixture({missing:true});let called=false;
 const result=await new AuthMaintenance(worker,{encryptionKey:key.toString('base64'),provider:{logout:async()=>{called=true;}}}).run({batchSize:10});
 assert.equal(result.logoutExpiredUnconfirmed,1);assert.equal(result.logoutCompleted,1);assert.equal(called,false);
 assert.equal((await row(expired.hash)).logout_state,'expired_unconfirmed');assert.equal((await row(expired.hash)).secret_cipher,null);assert.equal((await row(absent.hash)).logout_state,'complete');
});
test('expired authentication and temporary email cleanup are bounded and missing provider remains pending',async()=>{
 const a=await fixture({expired:true,revoked:false}),b=await fixture({expired:true,revoked:false});
 const hash=randomBytes(32).toString('hex');ids.push(hash);await admin.query("INSERT INTO ritc.browser_auth(token_hash,csrf,email_cipher,code_expires_at,expires_at) VALUES($1,'csrf','temporary-encrypted-email',clock_timestamp()-interval '1 minute',clock_timestamp()+interval '1 hour')",[hash]);
 const result=await new AuthMaintenance(worker,{}).run({batchSize:1});assert.equal(result.expiredQueued,1);assert.equal(result.emailsCleared,1);assert.equal(result.logoutRetryScheduled,1);assert.equal((await row(hash)).email_cipher,null);
 const rows=await Promise.all([row(a.hash),row(b.hash)]);assert.equal(rows.filter(r=>r.logout_last_error==='configuration_unavailable').length,1);
 await admin.query("UPDATE ritc.browser_auth SET secret_cipher=NULL,phase='challenge',revoked_at=clock_timestamp() WHERE token_hash=ANY($1::text[])",[[a.hash,b.hash]]);
});
