import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';
import {HouseholdRepository} from '../dist/repository.js';
import {HouseholdMeasurement,MEASUREMENT_NOTICE_VERSION} from '../dist/measurement.js';
import {BillingService} from '../dist/billing/service.js';
import {createHTTPServer} from '../dist/http.js';
const runtimeURL=process.env.TEST_DATABASE_URL,adminURL=process.env.TEST_ADMIN_DATABASE_URL;
test('optional measurement PostgreSQL identities, RLS, consent and verified billing',{skip:!runtimeURL||!adminURL},async t=>{
 const runtime=new pg.Pool({connectionString:runtimeURL,max:4}),admin=new pg.Pool({connectionString:adminURL,max:2});
 const h=randomUUID(),foreign=randomUUID(),adult=randomUUID(),other=randomUUID(),child=randomUUID(),shop=randomUUID();
 const repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'test'}),service=new HouseholdMeasurement(repo);
 const run=(member,fn,household=h)=>repo.transaction(household,async(db,now)=>fn({db,householdId:household,member:{member_id:member,kind:member===child?'child':'adult',state:'active',organizer:true,can_contribute:true,alias:'Unused'},deviceId:randomUUID(),now}));
 let consent,receipt;
 try{
  await admin.query("INSERT INTO ritc.household(household_id,label) VALUES($1,'Measurement fixture'),($2,'Foreign fixture')",[h,foreign]);
  for(const [id,kind] of [[adult,'adult'],[other,'adult'],[child,'child']])await admin.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state) VALUES($1,$2::uuid,'test-only',$2::text,'Fixture',$3,'active')",[h,id,kind]);
  await admin.query("INSERT INTO ritc.shop(household_id,shop_id,shopper_id,quote) VALUES($1,$2,$3,'{}')",[h,shop,adult]);
  await t.test('default off, helper/child denial, fresh notice only',async()=>{
   assert.equal((await run(adult,ctx=>service.status(ctx))).consent,null);
   await assert.rejects(()=>run(child,ctx=>service.consent(ctx,{noticeVersion:MEASUREMENT_NOTICE_VERSION})));
   await assert.rejects(()=>run(adult,ctx=>service.status({...ctx,viewGrantId:randomUUID()})));
   await assert.rejects(()=>run(adult,ctx=>service.consent(ctx,{noticeVersion:'old'})));
   consent=(await run(adult,ctx=>service.consent(ctx,{noticeVersion:MEASUREMENT_NOTICE_VERSION}))).consent;
  });
  const answer=()=>({consentId:consent.consentId,noticeVersion:MEASUREMENT_NOTICE_VERSION,outcome:'already_knew',baseline:'list',comparison:'different'});
  await t.test('requires a placed closed shop and pins week to server closure',async()=>{
   await assert.rejects(()=>run(adult,ctx=>service.feedback(ctx,shop,answer())),e=>e.code==='measurement_not_eligible');
   await admin.query("UPDATE ritc.shop SET phase='closed',placed_revision=1 WHERE household_id=$1 AND shop_id=$2",[h,shop]);
   receipt=await run(adult,ctx=>service.feedback(ctx,shop,answer()));assert.equal(receipt.incrementalBenefit,0);
   assert.match(receipt.eligibleWeek,/^\d{4}-W\d{2}$/);
   const before=(await admin.query('SELECT measurement_closed_at FROM ritc.shop WHERE household_id=$1',[h])).rows[0].measurement_closed_at;
   await admin.query("UPDATE ritc.shop SET measurement_closed_at='2000-01-01' WHERE household_id=$1",[h]);
   assert.deepEqual((await admin.query('SELECT measurement_closed_at FROM ritc.shop WHERE household_id=$1',[h])).rows[0].measurement_closed_at,before);
  });
  await t.test('second device and retry have one household/shop/week response',async()=>{
   const [a,b]=await Promise.all([run(adult,ctx=>service.feedback(ctx,shop,answer())),run(adult,ctx=>service.feedback(ctx,shop,answer()))]);
   assert.equal(a.feedbackId,receipt.feedbackId);assert.equal(b.feedbackId,receipt.feedbackId);
   assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.measurement_feedback WHERE household_id=$1',[h])).rows[0].n,1);
   await assert.rejects(()=>run(adult,ctx=>service.feedback(ctx,shop,{...answer(),outcome:'acted'})),e=>e.code==='measurement_already_recorded');
   assert.equal((await repo.transaction(foreign,db=>db.query('SELECT * FROM ritc.measurement_feedback'))).rowCount,0);
   await assert.rejects(()=>run(other,ctx=>service.read(ctx,shop)));
  });
  await t.test('withdrawal removes response, stale consent cannot be replayed or resurrected',async()=>{
   await run(adult,ctx=>service.withdraw(ctx,{consentId:consent.consentId}));
   assert.equal((await run(adult,ctx=>service.read(ctx,shop))).feedback,null);
   await assert.rejects(()=>run(adult,ctx=>service.feedback(ctx,shop,answer())),e=>e.code==='measurement_consent_required');
   await assert.rejects(()=>admin.query('UPDATE ritc.measurement_consent SET withdrawn_at=NULL WHERE household_id=$1',[h]),e=>e.code==='23514');
   const old=consent;consent=(await run(adult,ctx=>service.consent(ctx,{noticeVersion:MEASUREMENT_NOTICE_VERSION}))).consent;assert.notEqual(old.consentId,consent.consentId);
  });
  await t.test('only server-verified production billing counts one canonical willing household; refund removes it',async()=>{
   const now=Date.now(),original=BigInt('0x'+randomUUID().replaceAll('-','')).toString();let current={environment:'Production',originalTransactionID:original,transactionID:original+'1',appAccountToken:'',productID:'test-only',purchasedAt:now-1000,signedAt:now,expiresAt:now+3600000,graceExpiresAt:null,status:'active'};
   const gateway={async verifyTransaction(){return current;},async current(){return current;},async verifyNotification(){return {notificationID:randomUUID(),transaction:current};}};
   const billing=new BillingService(gateway);current.appAccountToken=(await run(adult,ctx=>billing.prepare(ctx))).appAccountToken;
   const count=async()=>(await run(adult,ctx=>ctx.db.query('SELECT count(*)::int n FROM ritc.measurement_willing_household'))).rows[0].n;
   assert.equal(await count(),0);
   await Promise.all([run(adult,ctx=>billing.verify(ctx,'test-only')),run(adult,ctx=>billing.verify(ctx,'test-only'))]);assert.equal(await count(),1);
   // A receipt replay and a new renewal transaction cannot create another household.
   current={...current,transactionID:original+'2',purchasedAt:now+1,signedAt:now+1};await run(adult,ctx=>billing.verify(ctx,'test-only'));assert.equal(await count(),1);
   current={...current,status:'revoked',signedAt:now+2};await run(adult,ctx=>billing.verify(ctx,'test-only'));assert.equal(await count(),0);
   assert.notEqual((await run(adult,ctx=>service.status(ctx))).consent,null);
  });
  await t.test('authenticated HTTP consent, code-only send, read, DELETE and withdrawal stay connected',async()=>{
   // Only identity-provider verification is replaced; device enrollment, authorization,
   // transport parsing, RLS and all measurement writes use the real implementations.
   const identity={issuer:'test-only',subject:adult,sessionId:randomUUID(),expiresAt:new Date(Date.now()+3600000)};
   const httpRepo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'test',sessionStatus:{async assertLive(){}}});
   const device=await httpRepo.enroll(h,identity),server=createHTTPServer({repository:httpRepo,verifier:{async verify(){return identity;}}});
   await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
   const base=`http://127.0.0.1:${server.address().port}/v1/households/${h}`;
   const call=async(path,method='GET',body)=>{const response=await fetch(base+path,{method,headers:{Authorization:'Bearer test-only','X-Device-Token':device.deviceToken,...(body===undefined?{}:{'Content-Type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})});return {status:response.status,body:await response.json()};};
   try{
    assert.equal((await call('/measurement/status')).status,200);
    const granted=await call('/measurement/consent','POST',{noticeVersion:MEASUREMENT_NOTICE_VERSION});assert.equal(granted.status,200);consent=granted.body.consent;
    const path=`/shops/${shop}/measurement-feedback`;
    assert.equal((await call(path,'POST',{...answer(),groceryText:'Private grocery'})).status,422);
    assert.equal((await call(path,'POST',answer())).status,200);
    const saved=await call(path);assert.equal(saved.status,200);assert.equal(saved.body.feedback.incrementalBenefit,0);
    assert.equal((await call(path,'DELETE',{feedbackId:saved.body.feedback.feedbackId})).status,200);
    assert.equal((await call(path)).body.feedback,null);
    assert.equal((await call('/measurement/withdraw','POST',{consentId:consent.consentId})).status,200);
    assert.equal((await call(path,'POST',answer())).status,409);
    consent=(await call('/measurement/consent','POST',{noticeVersion:MEASUREMENT_NOTICE_VERSION})).body.consent;
   }finally{await new Promise(resolve=>server.close(resolve));}
  });
  await t.test('member erasure removes measurement without restoring consent',async()=>{
   await run(adult,ctx=>service.feedback(ctx,shop,answer()));
   await admin.query('UPDATE ritc.member SET erased_at=now() WHERE household_id=$1 AND member_id=$2',[h,adult]);
   assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.measurement_feedback WHERE household_id=$1',[h])).rows[0].n,0);
   assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.measurement_consent WHERE household_id=$1',[h])).rows[0].n,0);
  });
 }finally{await runtime.end();await admin.end();}
});
