import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {migrate} from '../scripts/migrate.mjs';
import {randomUUID,randomBytes} from 'node:crypto';
import {PrivacyService,PrivacyMaintenance} from '../dist/privacy.js';
import {openPrivacyJournalFixture} from './privacy-journal-fixture.mjs';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {BillingService} from '../dist/billing/service.js';
import {createHTTPServer} from '../dist/http.js';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),subscriptions=new Map();let verifiedCalls=0;
const gateway={verifyTransaction:async value=>{const current=subscriptions.get(value);if(!current)throw Error('fixture signature');return current;},current:async id=>{verifiedCalls++;const value=subscriptions.get(id);if(!value)throw Error('fixture unavailable');return value;},verifyNotification:async()=>{throw Error('unused');}};
const issuer='https://amendment.fixture.invalid',audience='authenticated';const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='history';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/keys'},createLocalJWKSet({keys:[jwk]})),repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)}),billing=new BillingService(gateway),server=createHTTPServer({repository:repo,verifier,billing,maxRequestsPerMinute:20000});let origin;
before(async()=>{if(!process.env.TEST_DATABASE_URL||!process.env.TEST_ADMIN_DATABASE_URL)throw Error('Explicit isolated local database URLs required');await admin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');await migrate(process.env.TEST_ADMIN_DATABASE_URL);await new Promise(r=>server.listen(0,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;});after(async()=>{await new Promise(r=>server.close(r));await Promise.all([admin.end(),runtime.end()]);});
async function actor(){const subject=randomUUID(),session=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);const token=await new SignJWT({session_id:session,amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)}]}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience(audience).setIssuedAt().setExpirationTime('1h').sign(privateKey);return{subject,session,token};}
async function call(a,path,method='GET',body,headers={}){const r=await fetch(origin+path,{method,headers:{Authorization:'Bearer '+a.token,...(a.device?{'X-Device-Token':a.device}:{}),...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})});return{status:r.status,data:await r.json()};}
function ok(r,status=200){assert.equal(r.status,status,JSON.stringify(r.data));return r.data;}
async function enroll(a,h){a.device=ok(await call(a,`/v1/households/${h}/devices`,'POST',{}),201).deviceToken;a.window=ok(await call(a,`/v1/households/${h}/replay-windows`,'POST',{})).id;}
async function fixture(){const owner=await actor(),created=ok(await call(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'History fixture',alias:'Adult',adultAttestation:true}),201),h=created.householdId,base=`/v1/households/${h}`;owner.id=created.memberId;await enroll(owner,h);
 const shop=async(price=10000)=>{const id=randomUUID(),quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:100000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date(Date.now()-60000).toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()};ok(await call(owner,base+'/commands','POST',{v:1,replayWindow:owner.window,clientKey:randomUUID(),shopId:id,kind:'shop.create',base:{shopRevision:0,authorityEpoch:0},body:{quote,lines:[{lineId:randomUUID(),originalItem:'Private basket source',packs:1,unitPriceMinor:price,feeEligible:true}]}}));return id;};
 const shopId=await shop();async function paid(){const token=ok(await call(owner,base+'/billing/purchase-context','POST',{})).appAccountToken,original=String(Date.now())+String(Math.floor(Math.random()*1e6)),now=Date.now();subscriptions.set(original,{environment:'Sandbox',originalTransactionID:original,transactionID:original,appAccountToken:token,productID:'fixture.household.yearly',purchasedAt:now,signedAt:now,expiresAt:now+3600000,graceExpiresAt:null,status:'active'});ok(await call(owner,'/v1/billing/verify','POST',{householdId:h,signedTransactionInfo:original}));return original;}
 const version=async(id=shopId)=>ok(await call(owner,base+`/shops/${id}/financial-evidence`)).sourceVersion;
 const financial=async(entry,id=shopId)=>{const input={clientKey:randomUUID(),sourceVersion:await version(id),entry};return{input,result:ok(await call(owner,base+`/shops/${id}/financial-evidence`,'POST',input))};};
 return{owner,h,base,shopId,shop,paid,version,financial};}


const line=(name='Added retailer item')=>({lineId:randomUUID(),originalItem:name,packs:2,unitPriceMinor:275,feeEligible:true});
async function placedFixture(){const f=await fixture(),path=f.base+'/shops/'+f.shopId;
 const initial=ok(await call(f.owner,path));
 const command=(kind,revision,body)=>({v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind,base:{shopRevision:revision,authorityEpoch:1},body});
 ok(await call(f.owner,f.base+'/commands','POST',command('shop.freeze',1,{})));
 ok(await call(f.owner,f.base+'/commands','POST',command('shop.reportPlaced',2,{occurredAt:new Date().toISOString()})));
 const read=()=>call(f.owner,path+'/confirmed-order');
 const send=c=>call(f.owner,f.base+'/commands','POST',c);
 const amend=(lines,base=3,predecessorId=null)=>command('amendment.recordResponse',base,{placedRevision:2,predecessorId,retailerReference:'Retailer confirmation #42',confirmedAt:new Date().toISOString(),lines});
 return{...f,path,initial,command,read,send,amend};}

test('retailer amendments preserve original placement, physical evidence and finances; exact lost-reply retry appends once',async()=>{
 const f=await placedFixture(),original=ok(await f.read());assert.deepEqual(original.current.lines,f.initial.lines);assert.equal(original.current.amendmentId,null);
 const sealed=(await admin.query('SELECT revision,snapshot,digest FROM ritc.shop_snapshot WHERE household_id=$1 ORDER BY revision',[f.h])).rows;
 const financial=ok(await call(f.owner,f.path+'/financial-evidence'));
 const added=line(),lines=[{...original.current.lines[0],packs:3},added],command=f.amend(lines);
 const [first,retry]=await Promise.all([f.send(command),f.send(command)]),receipt=ok(first);assert.deepEqual(ok(retry),receipt);
 assert.equal(receipt.amendmentId,receipt.operationId);assert.equal(receipt.shopRevision,4);assert.equal(receipt.placedRevision,2);
 const page=ok(await f.read());assert.deepEqual(page.original,original.original);assert.deepEqual(page.current,{lines,amendmentId:receipt.amendmentId});assert.equal(page.amendments.length,1);
 assert.equal(page.amendments[0].actorId,f.owner.id);assert.equal(page.amendments[0].predecessorId,null);
 assert.deepEqual((await admin.query('SELECT revision,snapshot,digest FROM ritc.shop_snapshot WHERE household_id=$1 ORDER BY revision',[f.h])).rows,sealed);
 const shop=ok(await call(f.owner,f.path));assert.deepEqual(shop.lines,f.initial.lines);assert.deepEqual(shop.quote,f.initial.quote);
 const laterFinancial=ok(await call(f.owner,f.path+'/financial-evidence'));assert.deepEqual(laterFinancial.entries,financial.entries);assert.equal(laterFinancial.sourceVersion.financialRevision,financial.sourceVersion.financialRevision);
 const delivery=ok(await call(f.owner,f.path+'/delivery-evidence'));assert.equal(delivery.sources.length,0);assert.equal(delivery.supplyRevision,0);
 assert.equal(delivery.lines.find(l=>l.lineId===added.lineId).currentOrderedPacks,2);
 const registered=ok(await f.send(f.command('delivery.register',4,{placedRevision:2,supplyRevision:0,lineId:added.lineId,segmentKey:randomUUID(),foodName:added.originalItem,exclusionTags:[]})));
 assert.ok(registered.sourceId);assert.equal(ok(await call(f.owner,f.path+'/delivery-evidence')).sources[0].arrival,null);
 const cancel=f.amend([],4,receipt.amendmentId);ok(await f.send(cancel));
 const after=ok(await call(f.owner,f.path+'/delivery-evidence'));assert.equal(after.sources.length,1);assert.equal(after.lines.length,2);assert.ok(after.lines.every(l=>l.currentOrderedPacks===0));assert.deepEqual(ok(await f.read()).current.lines,[]);
 assert.equal((await f.send({...command,clientKey:randomUUID()})).data.error.code,'stale_base');
 assert.equal((await f.send({...command,body:{...command.body,retailerReference:'changed'}})).data.error.code,'key_reused');
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.order_amendment WHERE household_id=$1',[f.h])).rows[0].n,2);
});

test('invalid evidence, stale chains, recycled identities and proposal-shaped writes cannot become confirmed orders',async()=>{
 const f=await placedFixture(),original=ok(await f.read()),added=line();
 const invalids=[{retailerReference:''},{retailerReference:'x'.repeat(241)},{confirmedAt:new Date(Date.now()+60000).toISOString()},
 {confirmedAt:'2000-01-01T00:00:00Z'},{lines:[added,added]},{lines:[{...added,packs:0}]},{lines:[{...original.current.lines[0],originalItem:'Silent replacement'}]},
 {lines:original.current.lines},{placedRevision:1},{predecessorId:randomUUID()},{state:'proposed'}];
 for(const patch of invalids){const c=f.amend([added]);c.body={...c.body,...patch};assert.ok([409,422].includes((await f.send(c)).status),JSON.stringify(patch));}
 assert.equal(ok(await f.read()).amendments.length,0);
 const r=ok(await f.send(f.amend([added])));
 assert.equal((await f.send(f.amend(original.current.lines,4,r.amendmentId))).data.error.code,'order_line_identity');
 assert.equal((await f.send(f.amend([{...added,packs:3}],4,null))).data.error.code,'stale_order');
 // SQL itself prevents ordinary runtime mutation of retained evidence.
 await assert.rejects(()=>runtime.query('UPDATE ritc.order_amendment SET retailer_reference=$1 WHERE household_id=$2',['rewrite',f.h]),e=>e.code==='42501');
 await assert.rejects(()=>runtime.query('DELETE FROM ritc.order_amendment WHERE household_id=$1',[f.h]),e=>e.code==='42501');
});

test('current authority alone reads and records; reassignment fences successful retry and closed orders retain manual recording',async()=>{
 const f=await placedFixture(),other=await actor(),invite=ok(await call(f.owner,f.base+'/invites','POST',{kind:'adult_contributor'}));
 other.id=ok(await call(other,'/v1/invites/redeem','POST',{token:invite.token,intent:'join',adultAttestation:true,alias:'Other adult'})).memberId;await enroll(other,f.h);
 const c=f.amend([line()]);assert.equal((await call(other,f.path+'/confirmed-order')).status,404);
 assert.equal((await call(other,f.base+'/commands','POST',{...c,replayWindow:other.window})).status,404);
 assert.ok(ok(await call(f.owner,f.base+'/bootstrap')).capabilities.includes('confirmed_order'));
 assert.ok(!ok(await call(other,f.base+'/bootstrap')).capabilities.includes('confirmed_order'));
 const r=ok(await f.send(c));
 ok(await f.send(f.command('shop.transferAuthority',4,{newShopperId:other.id})));
 assert.equal((await f.read()).status,404);assert.equal((await f.send(c)).status,404);
 const current=ok(await call(other,f.path+'/confirmed-order'));assert.equal(current.authorityEpoch,2);
 await admin.query("UPDATE ritc.shop SET phase='closed' WHERE household_id=$1 AND shop_id=$2",[f.h,f.shopId]);
 const next={...f.amend([],4,r.amendmentId),replayWindow:other.window,base:{shopRevision:4,authorityEpoch:2}};
 assert.equal(ok(await call(other,f.base+'/commands','POST',next)).shopRevision,5);
 const own=ok(await call(other,f.base+'/requests/mine'));assert.equal(JSON.stringify(own).includes('retailerReference'),false);
});


test('real erasure removes dependent amendment copies without reverting to the original order or reviving erased retries',async()=>{
 const f=await placedFixture(),other=await actor(),invite=ok(await call(f.owner,f.base+'/invites','POST',{kind:'adult_contributor'}));
 other.id=ok(await call(other,'/v1/invites/redeem','POST',{token:invite.token,intent:'join',adultAttestation:true,alias:'Amendment author'})).memberId;await enroll(other,f.h);
 ok(await f.send(f.command('shop.transferAuthority',3,{newShopperId:other.id})));
 const added=line('Erased added food'),first={...f.amend([added]),replayWindow:other.window,base:{shopRevision:3,authorityEpoch:2}};
 const receipt=ok(await call(other,f.base+'/commands','POST',first));
 ok(await f.send({...f.command('shop.transferAuthority',4,{newShopperId:f.owner.id}),base:{shopRevision:4,authorityEpoch:2}}));
 const successor={...f.amend([{...added,packs:3}],4,receipt.amendmentId),base:{shopRevision:4,authorityEpoch:3}};
 ok(await f.send(successor));
 ok(await f.send({...f.command('delivery.register',5,{placedRevision:2,supplyRevision:0,lineId:added.lineId,segmentKey:randomUUID(),foodName:added.originalItem,exclusionTags:[]}),base:{shopRevision:5,authorityEpoch:3}}));
 const original=ok(await f.read()).original;
 const journal=await openPrivacyJournalFixture(admin),workerURL=new URL(process.env.TEST_DATABASE_URL);workerURL.username='ritc_test_worker';const worker=new pg.Pool({connectionString:workerURL.toString()});
 const provider={assertAvailable:async()=>{},deleteAccount:async subject=>{await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);}};
 try{
   const privacy=new PrivacyService(repo,{provider,journal:journal.port,policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1}});
   await privacy.request(await verifier.verify(other.token),{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,
     households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]});
   const maintenance=new PrivacyMaintenance(worker,{provider,journal:journal.port});assert.equal((await maintenance.run({batchSize:1})).completed,1);
   assert.equal((await f.read()).data.error.code,'order_evidence_removed');assert.equal((await f.send(successor)).status,409);
   assert.equal((await admin.query('SELECT 1 FROM ritc.order_amendment WHERE household_id=$1',[f.h])).rowCount,0);
   assert.equal((await admin.query('SELECT 1 FROM ritc.delivery_source WHERE household_id=$1',[f.h])).rowCount,0);
   assert.equal((await admin.query("SELECT 1 FROM ritc.operation_response r JOIN ritc.operation o USING(household_id,operation_id) WHERE o.household_id=$1 AND o.kind='amendment.recordResponse'",[f.h])).rowCount,0);
   assert.deepEqual(ok(await call(f.owner,f.path)).lines,original.lines);
   assert.equal((await admin.query('SELECT confirmed_order_erased FROM ritc.shop WHERE household_id=$1',[f.h])).rows[0].confirmed_order_erased,true);
 }finally{await journal.close();await worker.end();}
});

test('competing confirmations serialize, and complete historical delivery identity can exceed a current 200-line order',async()=>{
 const f=await placedFixture(),first=Array.from({length:200},(_,i)=>line('First pack '+i));
 const a=f.amend(first),b=f.amend([line('Other confirmation')]);
 const results=await Promise.all([f.send(a),f.send(b)]);assert.deepEqual(results.map(r=>r.status).sort(),[200,409]);
 const head=ok(await f.read());const next=Array.from({length:200},(_,i)=>line('Later pack '+i));
 ok(await f.send(f.amend(next,4,head.current.amendmentId)));
 const page=ok(await f.read());assert.equal(page.amendments.length,2);assert.equal(page.current.lines.length,200);
 const delivery=ok(await call(f.owner,f.path+'/delivery-evidence'));assert.equal(delivery.lines.length,1+head.current.lines.length+200);
 assert.equal(delivery.lines.filter(l=>l.currentOrderedPacks>0).length,200);assert.equal(delivery.sources.length,0);
});

test('erasing an original snapshot author also removes a different shopper’s copied amendment chain',async()=>{
 const f=await placedFixture(),other=await actor(),invite=ok(await call(f.owner,f.base+'/invites','POST',{kind:'adult_contributor'}));
 other.id=ok(await call(other,'/v1/invites/redeem','POST',{token:invite.token,intent:'join',adultAttestation:true,alias:'Surviving shopper'})).memberId;await enroll(other,f.h);
 ok(await f.send(f.command('shop.transferAuthority',3,{newShopperId:other.id})));
 const current=ok(await call(other,f.path+'/confirmed-order'));
 const amendment={...f.amend([{...current.original.lines[0],packs:3},line()]),replayWindow:other.window,base:{shopRevision:3,authorityEpoch:2}};
 ok(await call(other,f.base+'/commands','POST',amendment));
 const journal=await openPrivacyJournalFixture(admin),workerURL=new URL(process.env.TEST_DATABASE_URL);workerURL.username='ritc_test_worker';const worker=new pg.Pool({connectionString:workerURL.toString()});
 const provider={assertAvailable:async()=>{},deleteAccount:async subject=>{await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);}};
 try{
  const privacy=new PrivacyService(repo,{provider,journal:journal.port,policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1}});
  await privacy.request(await verifier.verify(f.owner.token),{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,
   households:[{householdId:f.h,organizer:'transfer',organizerMemberId:other.id,shops:[],eraseChildProfiles:[]}]});
  assert.equal((await new PrivacyMaintenance(worker,{provider,journal:journal.port}).run({batchSize:1})).completed,1);
  assert.equal((await call(other,f.path+'/confirmed-order')).data.error.code,'order_evidence_removed');
  assert.equal((await call(other,f.base+'/commands','POST',amendment)).status,409);
  assert.equal((await admin.query('SELECT 1 FROM ritc.order_amendment WHERE household_id=$1',[f.h])).rowCount,0);
  assert.equal((await admin.query("SELECT count(*)::int n FROM ritc.shop_snapshot WHERE household_id=$1 AND snapshot::text LIKE '%Private basket source%'",[f.h])).rows[0].n,0);
 }finally{await journal.close();await worker.end();}
});
