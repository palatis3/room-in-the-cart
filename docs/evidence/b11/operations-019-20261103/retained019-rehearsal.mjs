import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import pg from '../service/node_modules/pg/lib/index.js';
import {writeFile} from 'node:fs/promises';
import {BillingService} from '../service/dist/billing/service.js';
import {randomUUID,randomBytes} from 'node:crypto';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from '../service/node_modules/jose/dist/webapi/index.js';
import {migrate} from '../service/scripts/migrate.mjs';
import {HouseholdRepository} from '../service/dist/repository.js';
import {assertRuntimeRole} from '../service/dist/database.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../service/dist/auth.js';
import {createHTTPServer} from '../service/dist/http.js';
import {PrivacyService,PrivacyMaintenance} from '../service/dist/privacy.js';

const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL});
const runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
const workerURL=new URL(process.env.TEST_DATABASE_URL??'postgresql://localhost/ritc_unconfigured');workerURL.username='ritc_test_worker';
const worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL});
const issuer='https://operations019.fixture.invalid',audience='authenticated';
const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='store-quotes';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/keys'},createLocalJWKSet({keys:[jwk]}));
const repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
const provider={assertAvailable:async()=>{},deleteAccount:async subject=>{await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);}};
const privacy=new PrivacyService(repo,{provider,policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1}});
const maintenance=new PrivacyMaintenance(worker,{provider});
const subscriptions=new Map();let gatewayCalls=0;
const gateway={verifyTransaction:async value=>{gatewayCalls++;const row=subscriptions.get(value);if(!row)throw Error('synthetic verification unavailable');return row;},current:async value=>{gatewayCalls++;const row=subscriptions.get(value);if(!row)throw Error('synthetic current unavailable');return row;},verifyNotification:async()=>{throw Error('unused synthetic notification');}};
const billing=new BillingService(gateway);
const server=createHTTPServer({repository:repo,verifier,privacy,billing,maxRequestsPerMinute:20000});let origin;
before(async()=>{
 for(const value of [process.env.TEST_ADMIN_DATABASE_URL,process.env.TEST_DATABASE_URL]){
  if(!value)throw Error('Explicit isolated local PostgreSQL URLs required');
  const url=new URL(value);if(!['localhost','127.0.0.1','[::1]'].includes(url.hostname)||!url.pathname.startsWith('/ritc_'))throw Error('Local isolated ritc_ database required');
 }
 await admin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
 await migrate(process.env.TEST_ADMIN_DATABASE_URL);await assertRuntimeRole(runtime);

 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;
});
after(async()=>{await new Promise(resolve=>server.close(resolve));await Promise.all([admin.end(),runtime.end(),worker.end()]);});
async function actor(){
 const subject=randomUUID(),session=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);
 const token=await new SignJWT({session_id:session,amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)}]}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience(audience).setIssuedAt().setExpirationTime('1h').sign(privateKey);
 return{subject,session,token};
}
async function call(a,path,method='GET',body,headers={}){
 const response=await fetch(origin+path,{method,headers:{Authorization:'Bearer '+a.token,...(a.device?{'X-Device-Token':a.device}:{}),...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})});
 return{status:response.status,data:await response.json()};
}
function ok(response,status=200){assert.equal(response.status,status,JSON.stringify(response.data));return response.data;}
async function enroll(a,h){a.device=ok(await call(a,`/v1/households/${h}/devices`,'POST',{}),201).deviceToken;a.window=ok(await call(a,`/v1/households/${h}/replay-windows`,'POST',{})).id;}
function entered(){
 const first={label:'First store',store:'Store A',branch:'A1',mode:'pickup',slot:new Date(Date.now()+3600000).toISOString(),observedAt:new Date(Date.now()-60000).toISOString(),
  source:'Manually reviewed complete quote',currency:'USD',terms:'No membership needed. Fees, taxes, deposits and discounts included.',itemsMinor:3600,checkoutMinor:3800,allChargesIncluded:true,
  available:true,quantitiesMatched:true,singleStore:true,tripAlreadyPlanned:true,tripMinor:0,extraMinutes:0,capMinor:3800,capScope:'wholeCheckout',eligibilityConfirmed:true};
 return{first,second:{...first,label:'Second store',store:'Store B',branch:'B1',itemsMinor:3200,checkoutMinor:3500,tripAlreadyPlanned:false,tripMinor:400,extraMinutes:18}};
}
async function fixture(){
 const owner=await actor(),created=ok(await call(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'Private quote fixture',alias:'Shopper',adultAttestation:true}),201);
 const h=created.householdId,base=`/v1/households/${h}`;owner.id=created.memberId;await enroll(owner,h);
 const shopId=randomUUID(),path=base+'/shops/'+shopId,quotes=path+'/store-quotes';
 const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:3800,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:100},taxesMinor:100,depositsMinor:0,discountsMinor:0,
  observedAt:new Date(Date.now()-60000).toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()};
 const lines=[{lineId:randomUUID(),originalItem:'Six wraps and protected lunch',packs:2,unitPriceMinor:1800,feeEligible:true}];
 const command=(kind,body,revision=1,epoch=1)=>({v:1,clientKey:randomUUID(),replayWindow:owner.window,shopId,kind,base:{shopRevision:revision,authorityEpoch:epoch},body});
 ok(await call(owner,base+'/commands','POST',command('shop.create',{quote,lines},0,0)));
 async function join(alias='Budget adult'){
  const adult=await actor(),invitation=ok(await call(owner,base+'/invites','POST',{kind:'adult_contributor'}));
  adult.id=ok(await call(adult,'/v1/invites/redeem','POST',{token:invitation.token,intent:'join',adultAttestation:true,alias})).memberId;await enroll(adult,h);return adult;
 }
 const input=(extra={},revision=1,epoch=1,grantRevision=0)=>({operationId:randomUUID(),shopRevision:revision,authorityEpoch:epoch,grantRevision,...extra});
 async function grant(adult,enabled=true,targetRevision=0,revision=1,epoch=1){return ok(await call(owner,quotes+'/grants','POST',input({adultId:adult.id,enabled,targetRevision},revision,epoch)));}
 async function save(a=owner,options=entered(),revision=1,epoch=1,grantRevision=0){const body=input({options},revision,epoch,grantRevision);return{body,receipt:ok(await call(a,quotes+'/pairs','POST',body)),pairId:body.operationId};}
 return{owner,h,base,shopId,path,quotes,quote,lines,command,join,input,grant,save};
}

const publicActor=a=>({memberId:a.id,subject:a.subject,session:a.session});
const scoped=async(f,fn)=>repo.transaction(f.h,db=>fn(db));
const willing=async f=>(await scoped(f,db=>db.query('SELECT count(*)::int n FROM ritc.measurement_willing_household'))).rows[0].n;
async function extraShop(f,newShopper=f.owner){
 const shopId=randomUUID();
 ok(await call(f.owner,f.base+'/commands','POST',{...f.command('shop.create',{quote:f.quote,lines:[{...f.lines[0],lineId:randomUUID()}]},0,0),shopId}));
 if(newShopper.id!==f.owner.id)ok(await call(f.owner,f.base+'/commands','POST',{...f.command('shop.transferAuthority',{newShopperId:newShopper.id}),shopId}));
 return shopId;
}
async function closePlaced(f,shopId,a=f.owner){
 const path=f.base+'/shops/'+shopId;
 const command=async(kind,body)=>{
  const current=ok(await call(a,path));
  return ok(await call(a,f.base+'/commands','POST',{v:1,clientKey:randomUUID(),replayWindow:a.window,shopId,kind,base:{shopRevision:current.shopRevision,authorityEpoch:current.authorityEpoch},body}));
 };
 await command('shop.freeze',{});await command('shop.reportPlaced',{occurredAt:new Date().toISOString()});
 const current=ok(await call(a,path));assert.equal(current.phase,'placed');
 const sourceVersion=ok(await call(a,path+'/financial-evidence')).sourceVersion;
 const result=ok(await call(a,path+'/financial-reviews','POST',{clientKey:randomUUID(),sourceVersion,allEvidenceEntered:false,closeShop:true}));
 assert.equal(result.appShopClosed,true);return path;
}
async function consent(f,a=f.owner){return ok(await call(a,f.base+'/measurement/consent','POST',{noticeVersion:'pickup-feedback-2026-11-03.v1'})).consent;}
const answer=c=>({consentId:c.consentId,noticeVersion:c.noticeVersion,outcome:'already_knew',baseline:'list',comparison:'different'});
async function syntheticBilling(f,a=f.owner,{environment='Production',status='active',expiresAt=Date.now()+365*86400000,graceExpiresAt=null}={}){
 const appAccountToken=ok(await call(a,f.base+'/billing/purchase-context','POST',{})).appAccountToken;
 const original=BigInt('0x'+randomUUID().replaceAll('-','')).toString(),now=Date.now();
 const row={environment,originalTransactionID:original,transactionID:original+'1',appAccountToken,productID:'synthetic.operations019.yearly',purchasedAt:now-1000,signedAt:now,expiresAt,graceExpiresAt,status};
 subscriptions.set(original,row);
 const verify=async()=>ok(await call(a,'/v1/billing/verify','POST',{householdId:f.h,signedTransactionInfo:original}));
 await verify();await verify();return{row,original,verify};
}
async function adoptedPair(f,a){
 await f.grant(a);const saved=await f.save(a,entered(),1,1,1),proposal=f.input({pairId:saved.pairId,choice:'second'},1,1,1);
 ok(await call(a,f.quotes+'/proposals','POST',proposal));
 const adopted=ok(await call(f.owner,f.quotes+'/adoptions','POST',f.input({pairId:saved.pairId,choice:'second',proposalId:proposal.operationId})));
 assert.equal(adopted.shopRevision,2);return{pairId:saved.pairId,proposalId:proposal.operationId};
}

test('controlled retained 018/019 dataset, real service HTTP boundaries and real erasure worker',async t=>{
 const ids={issuer,simulation:'Synthetic JWT signing/session rows and in-process provider/Apple gateway only; no real provider or Apple verification',sourceDatabase:'ritc_b11_ops019_20261103'},checks={};
 const retained=await fixture(),reader=await retained.join('Retained explicit budget reader'),denied=await retained.join('Ungrantable by membership alone');
 ids.retained={householdId:retained.h,quoteShopId:retained.shopId,owner:publicActor(retained.owner),reader:publicActor(reader),denied:publicActor(denied)};
 await t.test('retains explicit budget grant, exact pair/proposal/adoption and denies ungranted mutation/read',async()=>{
  assert.equal((await call(reader,retained.quotes)).status,404);
  Object.assign(ids.retained,await adoptedPair(retained,reader));
  assert.equal(ok(await call(retained.owner,retained.quotes)).currentBasis.branch,'B1');
  assert.equal((await call(denied,retained.quotes)).status,404);
  assert.equal((await call(reader,retained.quotes+'/grants','POST',retained.input({adultId:denied.id,enabled:true,targetRevision:0},2,1,1))).status,404);
  const sourceVersion=ok(await call(reader,retained.path+'/financial-evidence')).sourceVersion;
  assert.equal((await call(reader,retained.path+'/financial-reviews','POST',{clientKey:randomUUID(),sourceVersion,allEvidenceEntered:false,closeShop:true})).status,404);
  checks.explicitBudgetReadOnlyPermission=true;
 });
 await t.test('retains code-only consent and canonical response pinned to actual placed pickup closure',async()=>{
  assert.equal(ok(await call(retained.owner,retained.base+'/measurement/status')).consent,null);
  const shopId=await extraShop(retained);ids.retained.measurementShopId=shopId;
  const c=await consent(retained);ids.retained.consentId=c.consentId;
  const path=retained.base+'/shops/'+shopId+'/measurement-feedback';
  assert.equal((await call(retained.owner,path,'POST',answer(c))).status,409);
  await closePlaced(retained,shopId);
  assert.equal((await call(retained.owner,path,'POST',{...answer(c),groceryText:'Rejected private text'})).status,422);
  const first=ok(await call(retained.owner,path,'POST',{...answer(c),consentId:c.consentId.toUpperCase()}));
  const retry=ok(await call(retained.owner,path,'POST',answer(c)));assert.equal(first.feedbackId,retry.feedbackId);assert.equal(first.incrementalBenefit,0);
  assert.equal((await call(retained.owner,path,'POST',{...answer(c),outcome:'acted'})).status,409);
  const secondConsent=await consent(retained,reader);assert.notEqual(secondConsent.consentId,c.consentId);
  ids.retained.readerConsentId=secondConsent.consentId;ids.retained.feedbackId=first.feedbackId;ids.retained.eligibleWeek=first.eligibleWeek;
  checks.canonicalResponseAndServerClosure=true;checks.codeOnlyAllowlist=true;
 });
 await t.test('retains one synthetic verified-boundary Production household through retries, renewal and two seats',async()=>{
  const b=await syntheticBilling(retained);assert.equal(await willing(retained),1);
  const state=ok(await call(retained.owner,retained.base+'/entitlements'));
  ok(await call(retained.owner,retained.base+'/billing/seats','PUT',{revision:state.revision,userIDs:[retained.owner.id,reader.id]}));
  Object.assign(b.row,{transactionID:b.original+'2',purchasedAt:Date.now()+1,signedAt:Date.now()+1});await b.verify();
  assert.equal(await willing(retained),1);ids.retained.billingOriginal=b.original;checks.oneCanonicalWillingHousehold=true;
 });
 await t.test('Sandbox, missing consent, refund and expiry never become willing households; live grace does',async()=>{
  ids.billingControls={};
  for(const kind of ['sandbox','noConsent','refunded','expired','grace']){
   const f=await fixture();let c=null;if(kind!=='noConsent')c=await consent(f);
   const options=kind==='sandbox'?{environment:'Sandbox'}:kind==='expired'?{expiresAt:Date.now()-1000}:kind==='grace'?{status:'grace',expiresAt:Date.now()-1000,graceExpiresAt:Date.now()+365*86400000}:{};
   const b=await syntheticBilling(f,f.owner,options);
   if(kind==='refunded'){assert.equal(await willing(f),1);Object.assign(b.row,{status:'revoked',signedAt:Date.now()+2});await b.verify();}
   const count=await willing(f);assert.equal(count,kind==='grace'?1:0);
   if(kind==='noConsent')assert.equal(ok(await call(f.owner,f.base+'/measurement/status')).consent,null);
   ids.billingControls[kind]={householdId:f.h,owner:publicActor(f.owner),consentId:c?.consentId??null,expectedWilling:count};
  }
  checks.billingControls=true;
 });
 await t.test('withdrawal retains a withdrawn identity and rejects consent resurrection without a new explicit grant',async()=>{
  const f=await fixture(),shopId=await extraShop(f),c=await consent(f);await closePlaced(f,shopId);
  const path=f.base+'/shops/'+shopId+'/measurement-feedback';ok(await call(f.owner,path,'POST',answer(c)));
  ok(await call(f.owner,f.base+'/measurement/withdraw','POST',{consentId:c.consentId}));
  assert.equal((await call(f.owner,path,'POST',answer(c))).status,409);
  await assert.rejects(()=>admin.query('UPDATE ritc.measurement_consent SET withdrawn_at=NULL WHERE household_id=$1 AND consent_id=$2',[f.h,c.consentId]),e=>e.code==='23514');
  ids.withdrawn={householdId:f.h,shopId,owner:publicActor(f.owner),consentId:c.consentId};checks.withdrawnConsentCannotResurrect=true;
 });
 await t.test('actual privacy acceptance and worker erase 018 proof/grant and 019 consent/response while preserving retained household',async()=>{
  const f=await fixture(),a=await f.join('Synthetic erase target');await adoptedPair(f,a);
  const shopId=await extraShop(f,a),c=await consent(f,a);await closePlaced(f,shopId,a);
  ok(await call(a,f.base+'/shops/'+shopId+'/measurement-feedback','POST',answer(c)));await syntheticBilling(f,a);assert.equal(await willing(f),1);
  const before=(await admin.query('SELECT (SELECT count(*)::int FROM ritc.store_quote_pair WHERE household_id=$1) quote_pairs,(SELECT count(*)::int FROM ritc.measurement_feedback WHERE household_id=$1) feedback,(SELECT count(*)::int FROM ritc.measurement_consent WHERE household_id=$1 AND member_id=$2) consents',[f.h,a.id])).rows[0];
  assert.deepEqual(before,{quote_pairs:1,feedback:1,consents:1});
  const deletion={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]};
  assert.equal(ok(await call(a,'/v1/privacy/deletions','POST',deletion),202).status,'pending');
  assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.measurement_feedback WHERE household_id=$1',[f.h])).rows[0].n,0);
  const result=await maintenance.run({batchSize:1});assert.equal(result.completed,1);
  for(const table of ['store_quote_pair','store_quote_proposal','store_quote_adoption','shop_budget_grant','measurement_feedback','measurement_consent','billing_state'])assert.equal((await admin.query(`SELECT count(*)::int n FROM ritc.${table} WHERE household_id=$1`,[f.h])).rows[0].n,0,table);
  assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.store_quote_mutation WHERE household_id=$1 AND actor_id=$2',[f.h,a.id])).rows[0].n,0);
  assert.equal((await runtime.query('SELECT ritc.identity_blocked($1,$2) blocked',[issuer,a.subject])).rows[0].blocked,true);
  assert.equal((await call(a,'/v1/me/workspaces')).status,401);assert.equal(await willing(f),0);
  assert.equal(ok(await call(retained.owner,retained.quotes)).currentBasis.branch,'B1');assert.equal(await willing(retained),1);
  ids.erased={householdId:f.h,quoteShopId:f.shopId,measurementShopId:shopId,subject:a.subject,memberId:a.id,jobId:deletion.clientKey};
  checks.actualErasureAcross018019=true;checks.erasureDidNotRemoveOtherHousehold=true;
 });
 await writeFile(new URL('controlled-fixture-identities.json',import.meta.url),JSON.stringify(ids,null,2)+'\n');
 await writeFile(new URL('controlled-rehearsal-checks.json',import.meta.url),JSON.stringify({checks,gatewayCalls,provider:'synthetic in-process fixture only',transport:'real loopback HTTP',database:'real local PostgreSQL',schema:'001-019'},null,2)+'\n');
});
