import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import pg from 'pg';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {PrivacyService,PrivacyMaintenance} from '../dist/privacy.js';
import {deferProfileOnlyDeletion,openPrivacyJournalFixture} from './privacy-journal-fixture.mjs';
import {createHTTPServer} from '../dist/http.js';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
const workerURL=new URL(process.env.TEST_DATABASE_URL);workerURL.username='ritc_test_worker';const worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL??workerURL.toString()});
const issuer='https://privacy.fixture.invalid',audience='authenticated';
const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='privacy';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]})),repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
const journal=await openPrivacyJournalFixture(admin);
let providerFailure=false,providerCalls=0;
const provider={assertAvailable:async()=>{},deleteAccount:async subject=>{providerCalls++;if(providerFailure)throw Error('PRIVATE provider failure');await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);}};
const service=new PrivacyService(repo,{provider,journal:journal.port,policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1}}),maintenance=new PrivacyMaintenance(worker,{provider,journal:journal.port});
const server=createHTTPServer({repository:repo,verifier,privacy:service,maxRequestsPerMinute:10000});let origin;
before(async()=>{
 const role=(await admin.query("SELECT rolcanlogin,rolsuper,rolbypassrls,pg_has_role(oid,'ritc_worker','MEMBER') AS worker,pg_has_role(oid,'ritc_app','MEMBER') AS app FROM pg_roles WHERE rolname='ritc_test_worker'")).rows[0];
 assert.ok(role?.rolcanlogin&&role.worker&&!role.app&&!role.rolsuper&&!role.rolbypassrls,'Configure the distinct existing local worker before running this fixture; no roles or memberships are changed.');
 await new Promise(r=>server.listen(0,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;
});
after(async()=>{await new Promise(r=>server.close(r));await journal.close();await Promise.all([admin.end(),runtime.end(),worker.end()]);});
async function actor(age=0){const subject=randomUUID(),session=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);const token=await new SignJWT({session_id:session,amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)-age}]}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience(audience).setIssuedAt().setExpirationTime('1h').sign(privateKey);return{subject,session,token};}
async function call(actor,path,method='GET',body,headers={}){const r=await fetch(origin+path,{method,headers:{...(actor?{Authorization:'Bearer '+actor.token}:{}),...(actor?.deviceToken?{'X-Device-Token':actor.deviceToken}:{}),...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})});return{status:r.status,data:await r.json()};}
function ok(r,status=200){assert.equal(r.status,status,JSON.stringify(r.data));return r.data;}
async function enroll(a,h){const d=ok(await call(a,`/v1/households/${h}/devices`,'POST',{}),201);a.deviceToken=d.deviceToken;a.window=ok(await call(a,`/v1/households/${h}/replay-windows`,'POST',{})).id;}
async function fresh(){const owner=await actor(),created=ok(await call(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'Fictional fresh household',alias:'Owner secret alias',adultAttestation:true}),201),h=created.householdId;owner.id=created.memberId;await enroll(owner,h);return{owner,h};}
async function invite(f,a,alias='Other adult'){const link=ok(await call(f.owner,`/v1/households/${f.h}/invites`,'POST',{kind:'adult_contributor'}));const joined=ok(await call(a,'/v1/invites/redeem','POST',{token:link.token,intent:'join',adultAttestation:true,alias}));a.id=joined.memberId;await enroll(a,f.h);return a;}
const quote=()=>({currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date(Date.now()-60000).toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()});
function command(a,shop,kind,body,revision=0,epoch=0,requestRevision){return{v:1,replayWindow:a.window,clientKey:randomUUID(),shopId:shop,kind,base:{shopRevision:revision,authorityEpoch:epoch,...(requestRevision?{requestRevision}:{})},body};}
async function send(f,a,envelope){return call(a,`/v1/households/${f.h}/commands`,'POST',envelope);}
async function shop(f){const id=randomUUID();ok(await send(f,f.owner,command(f.owner,id,'shop.create',{quote:quote(),lines:[{lineId:randomUUID(),originalItem:'Owner private grocery',packs:1,unitPriceMinor:300,feeEligible:true}]})));return id;}
const disposition=(h,overrides={})=>({householdId:h,organizer:'none',shops:[],eraseChildProfiles:[],...overrides});
const request=(households)=>({clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households});
async function status(input){return call(null,'/v1/privacy/jobs/'+input.clientKey,'GET',undefined,{'X-Deletion-Token':input.statusToken});}

test('fresh self-serve household completes create, invite, review, freeze, late routing and promote with exact retries',async()=>{
 const f=await fresh(),s=await shop(f),other=await invite(f,await actor());
 const c=command(other,s,'request.send',{clientRequestId:randomUUID(),originalItem:'Other private request',ownQuantity:'one',authoredAt:new Date().toISOString()});const sent=ok(await send(f,other,c));assert.deepEqual(ok(await send(f,other,c)),sent);
 const decision={choice:'add',line:{lineId:randomUUID(),originalItem:'Reviewed cereal',packs:1,unitPriceMinor:250,feeEligible:true},promote:false};
 const p=ok(await call(f.owner,`/v1/households/${f.h}/shops/${s}/previews`,'POST',{requestId:sent.request.requestId,base:{shopRevision:1,authorityEpoch:1,requestRevision:1},decision}));
 const apply=command(f.owner,s,'request.apply',{requestId:sent.request.requestId,previewId:p.previewId,acceptOverage:false,acceptUnknown:false},1,1,1);const applied=ok(await send(f,f.owner,apply));assert.deepEqual(ok(await send(f,f.owner,apply)),applied);
 ok(await send(f,f.owner,command(f.owner,s,'shop.freeze',{},2,1)));
 const late=ok(await send(f,other,command(other,s,'request.send',{clientRequestId:randomUUID(),originalItem:'Late request',ownQuantity:null,authoredAt:new Date().toISOString()})));assert.equal(late.request.route,'next');
 ok(await send(f,f.owner,command(f.owner,s,'shop.reopen',{},3,1)));
 const promoted=ok(await call(f.owner,`/v1/households/${f.h}/shops/${s}/previews`,'POST',{requestId:late.request.requestId,base:{shopRevision:4,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:decision.line.lineId,promote:true}}));
 const approve=command(f.owner,s,'request.apply',{requestId:late.request.requestId,previewId:promoted.previewId,acceptOverage:false,acceptUnknown:false},4,1,1);const receipt=ok(await send(f,f.owner,approve));assert.deepEqual(ok(await send(f,f.owner,approve)),receipt);assert.equal(ok(await call(other,`/v1/households/${f.h}/requests/mine`)).requests.find(r=>r.requestId===late.request.requestId).status,'added');
});
test('deletion requires recent signed authentication and configured provider before accepting a job',async()=>{
 const old=await actor(3600),input=request([]);const r=await call(old,'/v1/privacy/deletions','POST',input);assert.equal(r.status,401);assert.equal(r.data.error.code,'reauthentication_required');
 const a=await actor(),identity=await verifier.verify(a.token);await assert.rejects(()=>new PrivacyService(repo).request(identity,input),e=>e.code==='deletion_unavailable');assert.equal((await status(input)).status,404);
 await assert.rejects(()=>runtime.query('SELECT * FROM ritc.privacy_job'),e=>e.code==='42501');await assert.rejects(()=>runtime.query('SELECT ritc.privacy_claim($1)',[randomUUID()]),e=>e.code==='42501');
});
test('a profile-only fixture with an expired lease leaves the next accepted deletion claimable',async t=>{
 const first=await actor(),second=await actor(),firstJob=request([]),secondJob=request([]);
 t.after(async()=>{
   await deferProfileOnlyDeletion(admin,firstJob.clientKey);
   await deferProfileOnlyDeletion(admin,secondJob.clientKey);
 });
 ok(await call(first,'/v1/privacy/deletions','POST',firstJob),202);
 const lease=randomUUID(),claim=(await worker.query('SELECT * FROM ritc.privacy_claim($1)',[lease])).rows[0];
 assert.equal(claim.job_id,firstJob.clientKey);
 ok(await call(second,'/v1/privacy/deletions','POST',secondJob),202);
 await deferProfileOnlyDeletion(admin,firstJob.clientKey);
 // Exercise a slow-suite boundary without waiting for the real 30-second lease.
 assert.equal((await admin.query("UPDATE ritc.privacy_job SET lease_until=clock_timestamp()-interval '1 second' WHERE job_id=$1 AND lease_id=$2",
   [firstJob.clientKey,lease])).rowCount,1);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal(ok(await status(secondJob)).status,'complete');
 assert.equal(ok(await status(firstJob)).providerAccountDeleted,false);
 assert.equal((await admin.query('SELECT 1 FROM auth.sessions WHERE id=$1',[first.session])).rowCount,1);
});
test('explicit responsibilities precede deletion; outage keeps pending and exact subject erasure preserves another member',async()=>{
 const f=await fresh(),s=await shop(f),other=await invite(f,await actor());const mine=ok(await send(f,f.owner,command(f.owner,s,'request.send',{clientRequestId:randomUUID(),originalItem:'Owner private request',ownQuantity:'secret quantity',authoredAt:new Date().toISOString()}))),theirs=ok(await send(f,other,command(other,s,'request.send',{clientRequestId:randomUUID(),originalItem:'Other retained private request',ownQuantity:'one',authoredAt:new Date().toISOString()})));
 assert.deepEqual(ok(await call(other,'/v1/privacy/deletion-preview')).households[0].otherAdults,[]);
 const queuePath=`/v1/households/${f.h}/devices/current/request-queue`;
 assert.ok(ok(await call(f.owner,queuePath,'PUT',{enabled:true})).requestQueueGrant);
 const otherGrant=ok(await call(other,queuePath,'PUT',{enabled:true})).requestQueueGrant;
 const preview=ok(await call(f.owner,'/v1/privacy/deletion-preview'));assert.equal(preview.households[0].activeShops[0].shopId,s);assert.equal(preview.subscriptionCancelledByDeletion,false);assert.equal(preview.verifiedBackupRetentionDays,1);
 const invalid=request([disposition(f.h)]);assert.equal((await call(f.owner,'/v1/privacy/deletions','POST',invalid)).data.error.code,'organizer_disposition_required');assert.equal((await status(invalid)).status,404);
 const input=request([disposition(f.h,{organizer:'transfer',organizerMemberId:other.id,shops:[{shopId:s,revision:1,authorityEpoch:1,action:'transfer',memberId:other.id}]})]);const accepted=ok(await call(f.owner,'/v1/privacy/deletions','POST',input),202);assert.equal(accepted.status,'pending');assert.equal(accepted.providerAccountDeleted,false);
 assert.equal((await call(f.owner,'/v1/me/workspaces')).status,401);assert.equal((await call(f.owner,'/v1/households','POST',{clientKey:randomUUID(),label:'Resurrection',alias:'Name',adultAttestation:true})).status,401);
 assert.equal((await call(null,'/v1/privacy/jobs/'+input.clientKey,'GET',undefined,{'X-Deletion-Token':randomBytes(32).toString('base64url')})).status,404);
 providerFailure=true;try{const result=await maintenance.run({batchSize:1});assert.equal(result.retryScheduled,1);}finally{providerFailure=false;}
 let receipt=ok(await status(input));assert.equal(receipt.status,'pending');assert.equal(receipt.appDataErased,true);assert.equal(receipt.providerAccountDeleted,false);
 assert.deepEqual((await admin.query('SELECT grant_id FROM ritc.request_queue_permission WHERE household_id=$1',[f.h])).rows,[{grant_id:otherGrant}]);
 const rows=(await admin.query('SELECT request_id,original_item,own_quantity FROM ritc.request WHERE household_id=$1',[f.h])).rows;assert.equal(rows.find(r=>r.request_id===mine.request.requestId).original_item,'Removed request');assert.equal(rows.find(r=>r.request_id===theirs.request.requestId).original_item,'Other retained private request');
 const erased=(await admin.query('SELECT * FROM ritc.member WHERE household_id=$1 AND member_id=$2',[f.h,f.owner.id])).rows[0];assert.equal(erased.alias,'Removed member');assert.notEqual(erased.subject,f.owner.subject);
 assert.equal((await admin.query("SELECT count(*)::int AS n FROM ritc.shop_snapshot WHERE household_id=$1 AND snapshot::text LIKE '%Owner private grocery%'",[f.h])).rows[0].n,0);
 assert.equal(ok(await call(other,`/v1/households/${f.h}/requests/mine`)).requests[0].originalItem,'Other retained private request');
 await admin.query("UPDATE ritc.privacy_job SET next_at=clock_timestamp()-interval '1 second' WHERE job_id=$1",[input.clientKey]);assert.equal((await maintenance.run({batchSize:1})).completed,1);receipt=ok(await status(input));assert.equal(receipt.status,'complete');assert.equal(receipt.providerAccountDeleted,true);
 const stored=(await admin.query('SELECT issuer,subject FROM ritc.privacy_job WHERE job_id=$1',[input.clientKey])).rows[0];assert.deepEqual(stored,{issuer:null,subject:null});assert.equal((await status(input)).status,200);assert.equal((await maintenance.run({batchSize:1})).completed,0);
});
test('household exit revokes only that membership, preserves service identity and is recoverable by the same key',async()=>{
 const f=await fresh(),second=ok(await call(f.owner,'/v1/households','POST',{clientKey:randomUUID(),label:'Keep this household',alias:'Still me',adultAttestation:true}),201);
 assert.ok(ok(await call(f.owner,`/v1/households/${f.h}/devices/current/request-queue`,'PUT',{enabled:true})).requestQueueGrant);
 const input={clientKey:randomUUID(),confirm:true,disposition:disposition(f.h,{organizer:'archive'})};const first=ok(await call(f.owner,`/v1/households/${f.h}/exit`,'POST',input));assert.equal(first.accountDeleted,false);assert.deepEqual(ok(await call(f.owner,`/v1/households/${f.h}/exit`,'POST',input)),first);
 assert.equal((await admin.query('SELECT 1 FROM ritc.request_queue_permission WHERE household_id=$1',[f.h])).rowCount,0);
 assert.deepEqual(ok(await call(f.owner,'/v1/me/workspaces')).workspaces.map(w=>w.householdId),[second.householdId]);assert.equal((await admin.query('SELECT count(*)::int AS n FROM auth.sessions WHERE id=$1',[f.owner.session])).rows[0].n,1);
});
test('sole guardian cannot abandon a child through exit; deletion explicitly erases only the selected household child profile',async()=>{
 const f=await fresh(),child=randomUUID(),childSubject=randomUUID();await admin.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,can_contribute) VALUES($1,$2,$3,$4,'Child private alias','child','active',true)",[f.h,child,issuer,childSubject]);await admin.query("INSERT INTO ritc.guardian_relationship VALUES($1,$2,$3,'fixture-verified-proof',NULL)",[f.h,child,f.owner.id]);await admin.query("INSERT INTO ritc.consent(household_id,consent_id,child_id,guardian_id,notice_version,verification_ref) VALUES($1,$2,$3,$4,'fixture','fixture-verified-consent')",[f.h,randomUUID(),child,f.owner.id]);
 const choice=disposition(f.h,{organizer:'archive'});assert.equal((await call(f.owner,`/v1/households/${f.h}/exit`,'POST',{clientKey:randomUUID(),confirm:true,disposition:choice})).data.error.code,'guardian_disposition_required');
 assert.equal(ok(await call(f.owner,'/v1/privacy/deletion-preview')).households[0].soleGuardianChildren[0].memberId,child);
 const input=request([{...choice,eraseChildProfiles:[child]}]);ok(await call(f.owner,'/v1/privacy/deletions','POST',input),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 const stored=(await admin.query('SELECT alias,state,erased_at FROM ritc.member WHERE household_id=$1 AND member_id=$2',[f.h,child])).rows[0];assert.equal(stored.alias,'Removed member');assert.equal(stored.state,'revoked');assert.ok(stored.erased_at);assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.consent WHERE household_id=$1',[f.h])).rows[0].n,0);
});
test('deleting a purchaser purges billing payloads and seats while retaining only a non-expiring rebinding marker',async()=>{
 const f=await fresh(),other=await invite(f,await actor()),token=randomUUID(),original=String(Date.now())+String(Math.floor(Math.random()*100000));
 await admin.query('INSERT INTO ritc.billing_account(household_id,purchaser_id,app_account_token) VALUES($1,$2,$3)',[f.h,f.owner.id,token]);
 await admin.query("INSERT INTO ritc.billing_binding(environment,original_transaction_id,household_id,purchaser_id,app_account_token) VALUES('Sandbox',$1,$2,$3,$4)",[original,f.h,f.owner.id,token]);
 await admin.query("INSERT INTO ritc.billing_state(household_id,purchaser_id,subscription,verified_at) VALUES($1,$2,'{\"privateReceipt\":\"fictional\"}',now())",[f.h,f.owner.id]);
 await admin.query("INSERT INTO ritc.billing_seat(household_id,slot,member_id,display_name) VALUES($1,1,$2,'Purchaser'),($1,2,$3,'Other adult')",[f.h,f.owner.id,other.id]);
 const input=request([disposition(f.h,{organizer:'transfer',organizerMemberId:other.id})]);ok(await call(f.owner,'/v1/privacy/deletions','POST',input),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 for(const table of ['billing_account','billing_binding','billing_state','billing_seat'])assert.equal((await admin.query(`SELECT count(*)::int AS n FROM ritc.${table} WHERE household_id=$1`,[f.h])).rows[0].n,0);
 assert.equal((await runtime.query("SELECT ritc.purchase_retired('Sandbox',$1) AS retired",[original])).rows[0].retired,true);assert.equal((await runtime.query("SELECT ritc.purchase_retired('Production',$1) AS retired",[original])).rows[0].retired,false);
 assert.equal((await call(other,'/v1/me/workspaces')).status,200);
 await admin.query("UPDATE ritc.privacy_job SET receipt_until=now()-interval '1 day',marker_until=now()-interval '1 day' WHERE job_id=$1",[input.clientKey]);
 const cleaned=await maintenance.run({batchSize:1});assert.equal(cleaned.jobsPurged,1);assert.equal((await status(input)).status,404);assert.equal((await runtime.query("SELECT ritc.purchase_retired('Sandbox',$1) AS retired",[original])).rows[0].retired,true);
});
test('foreign household and child identifiers cannot broaden deletion scope',async()=>{
 const a=await fresh(),b=await fresh();let input=request([disposition(a.h,{organizer:'archive'}),disposition(b.h,{organizer:'archive'})]);assert.equal((await call(a.owner,'/v1/privacy/deletions','POST',input)).status,404);
 input=request([disposition(a.h,{organizer:'archive',eraseChildProfiles:[randomUUID()]})]);assert.equal((await call(a.owner,'/v1/privacy/deletions','POST',input)).data.error.code,'guardian_disposition_required');assert.equal((await call(b.owner,'/v1/me/workspaces')).status,200);assert.equal((await call(a.owner,'/v1/me/workspaces')).status,200);
});
test('worker abort during the provider call leaves the original lease and receipt recoverable',async()=>{
 const account=await actor(),input=request([]);
 ok(await call(account,'/v1/privacy/deletions','POST',input),202);
 const cancellation=new AbortController(),attempts=[];
 const interrupted=new PrivacyMaintenance(worker,{journal:journal.port,provider:{
  assertAvailable:async()=>{},
  deleteAccount:async(subject,context)=>{
   attempts.push({subject,context});
   cancellation.abort();
   context.signal.throwIfAborted();
  },
 }});
 await assert.rejects(interrupted.run({batchSize:1,signal:cancellation.signal}),error=>error.code==='deletion_unavailable');
 assert.equal(attempts.length,1);
 assert.equal(attempts[0].subject,account.subject);
 assert.equal(attempts[0].context.signal.aborted,true);
 const job=(await admin.query('SELECT state,lease_id,provider_erased_at FROM ritc.privacy_job WHERE job_id=$1',[input.clientKey])).rows[0];
 assert.equal(job.state,'processing');
 assert.ok(job.lease_id);
 assert.equal(job.provider_erased_at,null);
 assert.equal((await admin.query("SELECT 1 FROM ritc.privacy_journal_outbox WHERE job_id=$1 AND kind IN ('source_pending','source_completed')",[input.clientKey])).rowCount,0);
 assert.equal(ok(await status(input)).status,'pending');
 await admin.query("UPDATE ritc.privacy_job SET lease_until=clock_timestamp()-interval '1 second' WHERE job_id=$1",[input.clientKey]);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal(ok(await status(input)).status,'complete');
});
test('worker recovers an accepted request whose committed event was never acknowledged',async()=>{
 const account=await actor(),input=request([]),identity=await verifier.verify(account.token);
 const interrupted=new PrivacyService(repo,{provider,policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1},journal:{
  ...journal.port,afterCommit:async()=>{throw Error('Synthetic loss after acceptance commit');},
 }});
 await assert.rejects(interrupted.request(identity,input),/Synthetic loss/);
 const claim='SELECT ritc.privacy_claim_reconciliation($1) AS job_id';
 await assert.rejects(runtime.query(claim,[randomUUID()]),{code:'42501'});
 const lease=randomUUID();
 const claims=await Promise.all([worker.query(claim,[lease]),worker.query(claim,[lease])]);
 assert.deepEqual(claims.map(value=>value.rows[0].job_id).filter(Boolean),[input.clientKey]);
 assert.equal((await worker.query('SELECT ritc.privacy_erase_target($1,$2) AS erased',[input.clientKey,lease])).rows[0].erased,false);
 await assert.rejects(worker.query('SELECT ritc.privacy_finish($1,$2,true,NULL)',[input.clientKey,lease]),/journal_pending/);
 assert.equal((await worker.query("SELECT ritc.privacy_finish($1,$2,false,'storage_unavailable') AS committed",[input.clientKey,lease])).rows[0].committed,false);
 const providerBefore=providerCalls;
 assert.equal((await maintenance.run({batchSize:1})).completed,0);
 assert.equal(providerCalls,providerBefore);
 await admin.query("UPDATE ritc.privacy_job SET lease_until=clock_timestamp()-interval '1 second' WHERE job_id=$1",[input.clientKey]);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal(providerCalls,providerBefore+1);
 assert.equal(ok(await status(input)).status,'complete');
});
test('worker recovers a lost completion acknowledgement without deleting the account again',async()=>{
 const account=await actor(),input=request([]);
 ok(await call(account,'/v1/privacy/deletions','POST',input),202);
 const interrupted=new PrivacyMaintenance(worker,{provider,journal:{...journal.port,
  acknowledgeJob:async(jobId,context)=>{
   const completed=(await admin.query("SELECT 1 FROM ritc.privacy_job WHERE job_id=$1 AND state='complete'",[jobId])).rowCount;
   if(completed)throw Error('Synthetic loss after completion commit');
   await journal.port.acknowledgeJob(jobId,context);
  },
 }});
 const providerBefore=providerCalls;
 await assert.rejects(interrupted.run({batchSize:1}),/Synthetic loss/);
 assert.equal(providerCalls,providerBefore+1);
 const pending=(await admin.query("SELECT count(*)::int AS n FROM ritc.privacy_journal_outbox e WHERE e.job_id=$1 AND e.kind='source_completed' AND NOT EXISTS(SELECT 1 FROM ritc.privacy_journal_ack a WHERE a.event_id=e.event_id)",[input.clientKey])).rows[0].n;
 assert.equal(pending,1);
 assert.equal((await maintenance.run({batchSize:1})).completed,0);
 assert.equal(providerCalls,providerBefore+1);
 assert.equal(ok(await status(input)).status,'complete');
});
test('deletion waits for an authorized identity transaction then closes enrollment and requires an actual worker lease',async()=>{
 const f=await fresh(),identity=await verifier.verify(f.owner.token),db=await runtime.connect(),input=request([disposition(f.h,{organizer:'archive'})]);
 await db.query('BEGIN');await repo.assertIdentityAllowed(db,identity.issuer,identity.subject);let finished=false;const deletion=call(f.owner,'/v1/privacy/deletions','POST',input).then(r=>{finished=true;return r;});
 await new Promise(resolve=>setTimeout(resolve,30));assert.equal(finished,false);await db.query('COMMIT');db.release();ok(await deletion,202);
 assert.equal((await runtime.query('SELECT ritc.identity_blocked($1,$2) AS blocked',[issuer,f.owner.subject])).rows[0].blocked,true);
 assert.equal((await worker.query('SELECT ritc.privacy_erase_target($1,$2) AS erased',[input.clientKey,randomUUID()])).rows[0].erased,false);
 const attempts=(await admin.query('SELECT attempts FROM ritc.privacy_job WHERE job_id=$1',[input.clientKey])).rows[0].attempts;assert.equal(attempts,0);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);assert.equal((await call(f.owner,`/v1/households/${f.h}/devices`,'POST',{})).status,401);
});
test('new helper/history data joins the bounded erasure path without deleting another current shopper accounting facts',async()=>{
 const f=await fresh(),s=await shop(f),other=await invite(f,await actor());
 const grant=ok(await call(f.owner,`/v1/households/${f.h}/views`,'POST',{shopId:s,mode:'read',shopLabel:'Owner private view',language:'en',items:[]}));
 ok(await call(f.owner,`/v1/households/${f.h}/views/${grant.grantId}/replacements`,'POST',{clientKey:randomUUID(),baseRevision:1,projection:{shopLabel:'Owner private replacement',language:'en',items:[]}}));
 const entryId=randomUUID(),evidenceKey=randomUUID(),periodId=randomUUID();
 await admin.query("INSERT INTO ritc.financial_entry(household_id,shop_id,entry_id,evidence_key,actor_id,kind,amount_minor,occurred_at,source_text) VALUES($1,$2,$3,$4,$5,'postedCharge',1234,now(),'Owner private financial source')",[f.h,s,entryId,evidenceKey,f.owner.id]);
 await admin.query('INSERT INTO ritc.financial_head(household_id,shop_id,revision) VALUES($1,$2,1)',[f.h,s]);
 await admin.query("INSERT INTO ritc.price_observation(household_id,observation_id,shop_id,actor_id,record,observed_at) VALUES($1,$2,$3,$4,'{\"private\":\"Owner price evidence\"}',now())",[f.h,randomUUID(),s,f.owner.id]);
 await admin.query("INSERT INTO ritc.budget_period(household_id,period_id,owner_id,revision,record,updated_at) VALUES($1,$2,$3,1,'{\"title\":\"Owner private funding\"}',now())",[f.h,periodId,f.owner.id]);
 await admin.query('INSERT INTO ritc.budget_period_shop VALUES($1,$2,$3)',[f.h,periodId,s]);
 const input=request([disposition(f.h,{organizer:'transfer',organizerMemberId:other.id,shops:[{shopId:s,revision:1,authorityEpoch:1,action:'transfer',memberId:other.id}]})]);ok(await call(f.owner,'/v1/privacy/deletions','POST',input),202);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 for(const table of ['helper_mutation','price_observation','budget_period','budget_period_shop'])assert.equal((await admin.query(`SELECT count(*)::int AS n FROM ritc.${table} WHERE household_id=$1`,[f.h])).rows[0].n,0);
 const retained=(await admin.query('SELECT amount_minor,source_text,evidence_key FROM ritc.financial_entry WHERE household_id=$1 AND entry_id=$2',[f.h,entryId])).rows[0];assert.equal(Number(retained.amount_minor),1234);assert.equal(retained.source_text,'Removed financial evidence');assert.equal(retained.evidence_key,evidenceKey);
 assert.equal((await admin.query('SELECT revision FROM ritc.financial_head WHERE household_id=$1 AND shop_id=$2',[f.h,s])).rows[0].revision,2);
 const current=ok(await call(other,`/v1/households/${f.h}/shops/${s}/financial-evidence`));assert.equal(current.entries[0].amountMinor,1234);assert.equal(JSON.stringify(current).includes('Owner private'),false);
 await assert.rejects(()=>runtime.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,other.id]),e=>e.code==='42501');
});

test('account erasure removes household stock and observed corrections without reviving earlier counts or joint cook text',async()=>{
 const f=await fresh(),editor=await invite(f,await actor()),s=await shop(f),base='/v1/households/'+f.h+'/shops/'+s;
 const initial=ok(await call(f.owner,base)),occurrenceId=randomUUID(),now=new Date(Date.now()-1000).toISOString();
 let epoch=1;
 const write=(actor,kind,body,revision=3)=>send(f,actor,command(actor,s,kind,body,revision,epoch));
 ok(await write(f.owner,'shop.patch',{quote:initial.quote,lines:initial.lines,mealEdit:{occurrenceId,baseMealRevision:null,
   meal:{title:'Household soup',day:'2026-11-07',kind:'dinner',portions:4,protected:false}}},1));
 ok(await write(f.owner,'shop.reportPlaced',{occurredAt:now},2));
 const page=async actor=>ok(await call(actor,base+'/pantry-lots'));
 const review=async actor=>{const {pantryRevision,supplyRevision}=await page(actor);return {pantryRevision,supplyRevision};};
 const make=async(actor,name)=>ok(await write(actor,'pantry.create',{...await review(actor),location:'pantry',storedAt:null,useFirstAt:null,foodName:name,exclusionTags:[]}));
 const lot=await make(f.owner,'Retained shared stock');
 ok(await write(f.owner,'pantry.select',{...await review(f.owner),lotId:lot.lotId,selected:true}));
 const observe=async(actor,qty)=>{
   const p=await page(actor),current=p.lots.find(l=>l.lotId===lot.lotId);
   const row={lotId:lot.lotId,predecessorId:current.observation?.observationId??null,confirmedAt:now,
     quantity:{amount:{numerator:qty,denominator:1},unit:'count',originalLiteral:String(qty)},pantryRevision:p.pantryRevision,supplyRevision:p.supplyRevision};
   const preview=ok(await call(actor,base+'/pantry-lots/observation-preview','POST',row));
   ok(await write(actor,'pantry.observe',{...row,previewDigest:preview.previewDigest}));
 };
 await observe(f.owner,5);
 ok(await write(f.owner,'shop.transferAuthority',{newShopperId:editor.id}));epoch++;
 await observe(editor,2);
 await make(editor,'Removed private batch');
 ok(await write(f.owner,'shop.transferAuthority',{newShopperId:f.owner.id}));epoch++;
 const original=command(f.owner,s,'cookCopy.save',{placedRevision:2,...await review(f.owner),occurrenceId,mealRevision:2,language:'en',text:'Use the revised shared stock.'},3,epoch);
 const saved=ok(await send(f,f.owner,original));
 ok(await write(f.owner,'cookCopy.markSent',{copyId:saved.copyId,recipient:'Cook',previousSendId:null}));
 assert.equal(ok(await call(f.owner,base+'/cook-copies/baseline','POST',{occurrenceId,recipient:'Cook'})).baseline.copy.copyId,saved.copyId);
 const deletion=request([disposition(f.h)]);
 ok(await call(editor,'/v1/privacy/deletions','POST',deletion),202);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 const retained=await page(f.owner);assert.equal(retained.lots.length,1);assert.equal(retained.lots[0].lotId,lot.lotId);
 assert.equal(retained.lots[0].observation,null);assert.equal(retained.lots[0].selected,true);
 assert.deepEqual(ok(await call(f.owner,base+'/cook-copies?occurrenceId='+occurrenceId)),{copies:[],nextCursor:null});
 assert.equal(ok(await call(f.owner,base+'/cook-copies/baseline','POST',{occurrenceId,recipient:'Cook'})).baseline,null);
 assert.equal((await send(f,f.owner,original)).status,409);
});

test('actual account erasure clears a purchase correction without reviving an old answer and removes request-linked receipts',async()=>{
 const f=await fresh(),s=await shop(f),author=await invite(f,await actor()),reviewer=await invite(f,await actor());
 const root='/v1/households/'+f.h,shopPath=root+'/shops/'+s,submit=(a,kind,body,revision,epoch,req)=>
   send(f,a,command(a,s,kind,body,revision,epoch,req));
 const requestId=ok(await submit(author,'request.send',{clientRequestId:randomUUID(),originalItem:'A private purchase',ownQuantity:null,
   authoredAt:new Date().toISOString()})).request.requestId;
 const line={lineId:randomUUID(),originalItem:'A reviewed purchase',packs:1,unitPriceMinor:250,feeEligible:true};
 const preview=ok(await call(f.owner,shopPath+'/previews','POST',{requestId,base:{shopRevision:1,authorityEpoch:1,requestRevision:1},
   decision:{choice:'add',line,promote:false}}));
 ok(await submit(f.owner,'request.apply',{requestId,previewId:preview.previewId,acceptOverage:false,acceptUnknown:false},1,1,1));
 ok(await submit(f.owner,'shop.freeze',{},2,1));
 ok(await submit(f.owner,'shop.reportPlaced',{occurredAt:new Date().toISOString()},3,1));
 const {shopRevision,placedRevision}=ok(await call(f.owner,shopPath));
 const observed={requestId,lineId:line.lineId,placedRevision};
 const prior=ok(await submit(f.owner,'request.confirmPurchase',{...observed,outcome:'notBought'},shopRevision,1,2));
 ok(await submit(f.owner,'shop.transferAuthority',{newShopperId:reviewer.id},shopRevision,1));
 const latest=ok(await submit(reviewer,'request.confirmPurchase',{...observed,outcome:'bought'},shopRevision,2,3));
 ok(await submit(f.owner,'shop.transferAuthority',{newShopperId:f.owner.id},shopRevision,2));
 const own=async()=>ok(await call(author,root+'/requests/mine')).requests.find(r=>r.requestId===requestId);
 assert.equal((await own()).purchaseOutcome,'bought');
 async function erase(person){
   const input=request([disposition(f.h)]);
   ok(await call(person,'/v1/privacy/deletions','POST',input),202);
   assert.equal((await maintenance.run({batchSize:1})).completed,1);
   assert.equal(ok(await status(input)).status,'complete');
 }
 const hasReceipt=async id=>(await admin.query('SELECT 1 FROM ritc.operation_response WHERE household_id=$1 AND operation_id=$2',[f.h,id])).rowCount;
 await erase(reviewer);
 const after=await own();assert.equal(after.status,'added');assert.equal(after.revision,5);assert.equal(after.purchaseOutcome,undefined);
 assert.equal(await hasReceipt(latest.operationId),0);assert.equal(await hasReceipt(prior.operationId),1);
 await erase(author);
 assert.equal(await hasReceipt(prior.operationId),0);
 assert.equal((await admin.query('SELECT 1 FROM ritc.request_purchase_review WHERE household_id=$1',[f.h])).rowCount,0);
 const erased=ok(await call(f.owner,shopPath+'/inbox')).requests.find(r=>r.requestId===requestId);
 assert.equal(erased.status,'withdrawn');assert.equal(erased.linkedLineId,undefined);assert.equal(erased.purchaseOutcome,undefined);
});

test('erasing the sealed line source removes another shopper purchase confirmation while its independent request author remains',async()=>{
 const f=await fresh(),s=await shop(f),author=await invite(f,await actor()),later=await invite(f,await actor());
 const root='/v1/households/'+f.h,path=root+'/shops/'+s;
 const observed=ok(await call(f.owner,path)),lineId=observed.lines[0].lineId;
 const requestId=ok(await send(f,author,command(author,s,'request.send',{clientRequestId:randomUUID(),
   originalItem:'Independent request text',ownQuantity:null,authoredAt:new Date().toISOString()}))).request.requestId;
 const preview=ok(await call(f.owner,path+'/previews','POST',{requestId,base:{shopRevision:1,authorityEpoch:1,requestRevision:1},
   decision:{choice:'link',lineId,promote:false}}));
 ok(await send(f,f.owner,command(f.owner,s,'request.apply',{requestId,previewId:preview.previewId,acceptOverage:false,acceptUnknown:false},1,1,1)));
 ok(await send(f,f.owner,command(f.owner,s,'shop.freeze',{},2,1)));
 ok(await send(f,f.owner,command(f.owner,s,'shop.reportPlaced',{occurredAt:new Date().toISOString()},3,1)));
 const {shopRevision,placedRevision}=ok(await call(f.owner,path));
 ok(await send(f,f.owner,command(f.owner,s,'shop.transferAuthority',{newShopperId:later.id},shopRevision,1)));
 const recorded=command(later,s,'request.confirmPurchase',{requestId,lineId,placedRevision,outcome:'bought'},shopRevision,2,2);
 const receipt=ok(await send(f,later,recorded));
 const deletion=request([disposition(f.h,{organizer:'transfer',organizerMemberId:later.id})]);
 ok(await call(f.owner,'/v1/privacy/deletions','POST',deletion),202);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal(ok(await status(deletion)).status,'complete');
 const current=ok(await call(author,root+'/requests/mine')).requests[0];assert.equal(current.status,'added');
 assert.equal(current.originalItem,'Independent request text');assert.equal(current.purchaseOutcome,undefined);
 const inbox=ok(await call(later,path+'/inbox')).requests[0];assert.equal(inbox.linkedLineId,undefined);
 assert.equal((await send(f,later,recorded)).data.error.code,'refresh_required');
 const retry={...recorded,clientKey:randomUUID(),base:{...recorded.base,requestRevision:current.revision}};
 assert.equal((await send(f,later,retry)).status,404);
 assert.equal((await admin.query('SELECT 1 FROM ritc.operation_response WHERE household_id=$1 AND operation_id=$2',[f.h,receipt.operationId])).rowCount,0);
});

test('staged author deletion hides all carried requests and exact retries, then erases source, successors and linked text',async()=>{
 const f=await fresh(),author=await invite(f,await actor()),source=await shop(f);
 const text='Private carried grocery';
 const original=ok(await send(f,author,command(author,source,'request.send',{clientRequestId:randomUUID(),
   originalItem:text,ownQuantity:'one bag',authoredAt:new Date().toISOString()}))).request;
 const place=id=>send(f,f.owner,command(f.owner,id,'shop.reportPlaced',{occurredAt:new Date().toISOString()},1,1));
 ok(await place(source));
 const second=await shop(f),ops=[],ids=[original.requestId];
 async function carry(from,to){
   const op=command(f.owner,to,'request.carry',{sourceShopId:from,sourceAuthorityEpoch:1,requestId:ids.at(-1)},1,1,2);
   ids.push(ok(await send(f,f.owner,op)).requestId);ops.push(op);
 }
 await carry(source,second);ok(await place(second));const third=await shop(f);await carry(second,third);
 const decision={choice:'add',line:{lineId:randomUUID(),originalItem:text,packs:1,unitPriceMinor:200,feeEligible:true}};
 const preview=ok(await call(f.owner,`/v1/households/${f.h}/shops/${third}/previews`,'POST',
   {requestId:ids[2],base:{shopRevision:1,authorityEpoch:1,requestRevision:1},decision}));
 ok(await send(f,f.owner,command(f.owner,third,'request.apply',{requestId:ids[2],previewId:preview.previewId,acceptOverage:false,acceptUnknown:false},1,1,1)));
 const input=request([disposition(f.h)]);ok(await call(author,'/v1/privacy/deletions','POST',input),202);
 for(const shopId of [source,second,third]){
   const page=ok(await call(f.owner,`/v1/households/${f.h}/shops/${shopId}/inbox`));assert.deepEqual(page.requests,[]);
 }
 for(const op of ops)assert.equal((await send(f,f.owner,op)).data.error.code,'refresh_required');
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 const rows=await admin.query('SELECT original_item,own_quantity,author_id FROM ritc.request WHERE household_id=$1',[f.h]);
 assert.deepEqual(rows.rows,Array(3).fill({original_item:'Removed request',own_quantity:null,author_id:author.id}));
 const evidence=(await admin.query(`SELECT o.payload_digest,r.response FROM ritc.operation o LEFT JOIN ritc.operation_response r
   USING(household_id,operation_id) WHERE o.household_id=$1 AND o.kind='request.carry'`,[f.h])).rows;
 assert.deepEqual(evidence,Array(2).fill({payload_digest:'0'.repeat(64),response:null}));
 assert.equal((await admin.query("SELECT 1 FROM ritc.shop_snapshot WHERE household_id=$1 AND snapshot::text LIKE $2",[f.h,'%'+text+'%'])).rowCount,0);
 assert.equal((await admin.query("SELECT original_item FROM ritc.basket_line WHERE household_id=$1 AND line_id=$2",[f.h,decision.line.lineId])).rows[0].original_item,'Removed item');
 for(const op of ops)assert.equal((await send(f,f.owner,op)).data.error.code,'refresh_required');
});
