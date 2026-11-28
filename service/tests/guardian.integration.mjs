import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes,createHmac} from 'node:crypto';
import pg from 'pg';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {restoreTestName,runIsolatedChildRestore,verifyChildBackup} from './guardian-child-restore-fixture.mjs';
import {GuardianEnrollmentService} from '../dist/guardian.js';
import {KWSWebhookVerifier} from '../dist/guardian-provider.js';
import {createHTTPServer} from '../dist/http.js';
import {BrowserAuthService} from '../dist/browser-auth.js';
import {guardianRuntime} from '../dist/guardian-runtime.js';
import {createRuntime,databaseConfiguration} from '../dist/runtime.js';
import {createOperationsHTTPServer} from '../dist/operations-http.js';
import {tokenHash} from '../dist/database.js';
import {PrivacyService,PrivacyMaintenance} from '../dist/privacy.js';
import {deferProfileOnlyDeletion,openPrivacyJournalFixture} from './privacy-journal-fixture.mjs';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),app=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),proof=new pg.Pool({connectionString:process.env.TEST_GUARDIAN_VERIFIER_DATABASE_URL});
const journal=await openPrivacyJournalFixture(admin);
const privacyProvider={assertAvailable:async()=>{},deleteAccount:async()=>{throw Error('Profile-only fixture must not call provider');}};
const privacyPolicy={receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1};
const issuer='https://guardian.fixture.invalid',audience='authenticated';const {publicKey,privateKey}=await generateKeyPair('ES256');const jwk=await exportJWK(publicKey);jwk.kid='guardian-fixture';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]}));
const config={organizationId:randomUUID(),scope:'product',productId:randomUUID(),environment:'test'},signing='local-fixture-only-signing-secret';
const notices=['en','es'].map(locale=>({locale,version:'fixture-reviewed-v1',methodVersion:'fixture-method-v1',scope:'own_requests',text:'Fictional reviewed notice '+locale,digest:tokenHash('Fictional reviewed notice '+locale),approvalReference:'fixture-only-not-legal-approval'}));
const mexicoNotices=notices.map(notice=>{
 const text=notice.text+' for US and MX';
 return {...notice,text,digest:tokenHash(text),version:'fixture-reviewed-v2',childCountries:['US','MX']};
});
const requests=[],otpRequests=[],otpActors=new Map();let failDelivery=false,holdVerify;
const pendingSignupFixture=new Map();
const otpProvider={async start(email){otpRequests.push(email);const newSubject=pendingSignupFixture.get(email);if(newSubject){
 await admin.query('INSERT INTO auth.users(id,email,email_confirmed_at) VALUES($1,$2,NULL)',[newSubject,email]);pendingSignupFixture.delete(email);
 }},async verify(email,code){if(holdVerify)await holdVerify();if(code!=='123456'||!otpActors.has(email))throw new Error('fixture code');await freshAuth(otpActors.get(email));return{accessToken:otpActors.get(email).token,refreshToken:'fixture-refresh'};},async refresh(){throw new Error('unused');},async logout(){}};
const gateway={kind:'fixture',configuration:config,async start(input){requests.push(input);if(failDelivery)throw new Error('lost fictional reply');}};
const repo=new HouseholdRepository(app,{allowChildNetwork:true,noticeVersion:notices[0].version,sessionStatus:new SupabaseSessionVerifier(issuer)});
const guardian=new GuardianEnrollmentService(repo,{manualReviewRetentionDays:7,unmatchedReviewRetentionDays:2,gateway,webhookVerifier:new KWSWebhookVerifier(config,[signing]),verifierPool:proof,emailDigestKey:randomBytes(32).toString('base64url'),notices,retentionPolicy:{pendingHours:1,evidenceDays:1,approvalReference:'fictional-policy'}});
const bff=new BrowserAuthService(repo,verifier,otpProvider,{encryptionKey:randomBytes(32).toString('base64'),childSignin:guardian});guardian.attachChildSignin(bff,otpProvider);
const expectedChildDeletes=new Set();
const childProvider={
 async assertAvailable(subject){assert.ok(expectedChildDeletes.has(subject),'only the explicitly expected child may be passed to the fixture provider');assert.equal((await admin.query('SELECT 1 FROM auth.users WHERE id=$1',[subject])).rowCount,1);},
 async deleteAccount(subject){assert.ok(expectedChildDeletes.has(subject));await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);await admin.query('DELETE FROM auth.users WHERE id=$1',[subject]);assert.equal((await admin.query('SELECT 1 FROM auth.users WHERE id=$1',[subject])).rowCount,0);}
};
const privacy=new PrivacyService(repo,{provider:childProvider,policy:privacyPolicy,journal:journal.port});
const webOrigin='https://guardian.web.fixture.invalid';
const server=createHTTPServer({repository:repo,verifier,guardian,privacy,browserAuth:bff,webOrigin,clientAddress:req=>req.headers['x-fixture-client-address']??req.socket.remoteAddress,maxRequestsPerMinute:10000});let origin;
before(async()=>{await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;});
after(async()=>{await new Promise(resolve=>server.close(resolve));await journal.close();await Promise.all([admin.end(),app.end(),proof.end()]);});
async function actor(email='guardian-'+randomUUID()+'@fixture.invalid',confirmed=true){const subject=randomUUID(),session=randomUUID();await admin.query('INSERT INTO auth.users(id,email,email_confirmed_at) VALUES($1,$2,$3)',[subject,email,confirmed?new Date():null]);await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);const token=await new SignJWT({session_id:session,amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)}]}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(subject).setIssuedAt().setExpirationTime('1h').sign(privateKey);const value={subject,session,token,email};otpActors.set(email,value);return value;}
async function call(person,path,method='GET',body,headers={}){const response=await fetch(origin+path,{method,headers:{...(person?{Authorization:'Bearer '+person.token,...(person.deviceToken?{'x-device-token':person.deviceToken}:{})}:{}),...(body===undefined?{}:{'content-type':'application/json'}),...headers},...(body===undefined?{}:{body:typeof body==='string'?body:JSON.stringify(body)})});return{status:response.status,data:await response.json(),headers:response.headers};}
function ok(result,status=200){assert.equal(result.status,status,JSON.stringify(result.data));return result.data;}
async function family(){const adult=await actor();const house=ok(await call(adult,'/v1/households','POST',{clientKey:randomUUID(),label:'Fictional guardian household',alias:'Fictional guardian',adultAttestation:true}),201);const base='/v1/households/'+house.householdId;Object.assign(adult,ok(await call(adult,base+'/devices','POST',{}),201));const child=await actor('child-'+randomUUID()+'@fixture.invalid');return{adult,child,house,base};}
async function create(f,extra={}){const input={clientKey:randomUUID(),noticeVersion:notices[0].version,noticeDigest:notices[0].digest,language:'en',childLocation:'US-NY',guardianDeclaration:'parent_or_legal_guardian',...extra};const setup=ok(await call(f.adult,f.base+'/guardian/enrollments','POST',input));return{setup,input};}
async function start(f,setup){const input={clientKey:randomUUID(),baseRevision:setup.revision};const value=ok(await call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/verification','POST',input));return{setup:value,request:requests.at(-1),input};}
function event(request,changes={}){return JSON.stringify({name:'parent-verified',time:new Date().toISOString(),orgId:config.organizationId,productId:config.productId,payload:{parentEmail:request.email,externalPayload:request.externalPayload,status:{verified:true,transactionId:randomUUID()}},...changes});}
async function callback(raw,signature){const t=Date.now();return call(null,'/v1/guardian/providers/kws/webhook','POST',raw,{'x-kws-signature':signature??'t='+t+',v1='+createHmac('sha256',signing).update(String(t)+'.'+raw).digest('hex')});}
async function read(f,id){return ok(await call(f.adult,f.base+'/guardian/enrollments/'+id));}
async function verified(f,extra={}){const made=await create(f,extra),sent=await start(f,made.setup);ok(await callback(event(sent.request)));return read(f,made.setup.enrollmentId);}
async function consented(f,extra={}){let setup=await verified(f,extra);const input={clientKey:randomUUID(),baseRevision:setup.revision,noticeVersion:setup.noticeVersion,noticeDigest:setup.noticeDigest,childAlias:'Fictional child',decision:'grant',childSignInEmail:f.child.email};setup=ok(await call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/consent','POST',input));return{setup,input};}
async function freshAuth(person,method='otp',age=0){person.token=await new SignJWT({session_id:person.session,amr:[{method,timestamp:Math.floor(Date.now()/1000)-age}]}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(person.subject).setIssuedAt().setExpirationTime('1h').sign(privateKey);return person;}
async function coveredNative(f,invitation){const input={clientKey:randomUUID(),token:invitation.token,email:f.child.email,challengeSecret:randomBytes(32).toString('base64url')};const challenge=ok(await call(null,'/v1/child-invitations/native-auth/start','POST',input,{'x-fixture-client-address':f.child.subject}));await freshAuth(f.child);const admit={clientKey:randomUUID(),householdId:challenge.householdId,challengeId:challenge.challengeId,challengeSecret:input.challengeSecret};ok(await call(f.child,'/v1/child-invitations/native-auth/admit','POST',admit));return{input,challenge,admit};}
async function claimed(f,extra={}){const {setup}=await consented(f,extra),invitationInput={clientKey:randomUUID(),baseRevision:setup.revision,secret:randomBytes(32).toString('base64url')};const invitation=ok(await call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/child-invitations','POST',invitationInput));await coveredNative(f,invitation);const input={clientKey:randomUUID(),token:invitation.token,pairingCode:'ABCD2345'};const claim=ok(await call(f.child,'/v1/child-invitations/claim','POST',input));return{setup:await read(f,setup.enrollmentId),claim,invitation,input,invitationInput};}
async function active(f,extra={}){let state=await claimed(f,extra);const confirm={clientKey:randomUUID(),baseRevision:state.setup.revision,claimId:state.claim.claimId,pairingCode:state.input.pairingCode};state.setup=ok(await call(f.adult,f.base+'/guardian/enrollments/'+state.setup.enrollmentId+'/confirm-child','POST',confirm));const finish={clientKey:randomUUID(),householdId:f.house.householdId,claimId:state.claim.claimId,pairingCode:state.input.pairingCode,deviceSecret:randomBytes(32).toString('base64url')};const receipt=ok(await call(f.child,'/v1/child-invitations/finish','POST',finish));Object.assign(f.child,receipt);return{...state,confirm,finish,receipt};}

const childDeletionPath='/guardian/child-account-deletions';
async function reviewChildAccount(f,enrollmentId){
 return ok(await call(f.adult,f.base+childDeletionPath+'/review','POST',{enrollmentId,childSignInEmail:f.child.email}));
}
function deletionReceipt(){return{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true};}
async function requestChildAccount(f,enrollmentId,review,body=deletionReceipt()){
 expectedChildDeletes.add(f.child.subject);
 return call(f.adult,f.base+childDeletionPath,'POST',{...body,enrollmentId,reviewId:review.reviewId});
}

test('Mexico enrollment requires a matching bilingual approval and sends only the approved residence to KWS',async()=>{
 const f=await family();
 const path=f.base+'/guardian/enrollments';
 const available=language=>call(f.adult,f.base+'/guardian/notice?language='+language);
 const input={clientKey:randomUUID(),noticeVersion:notices[1].version,noticeDigest:notices[1].digest,
  language:'es',childLocation:'MX',guardianDeclaration:'parent_or_legal_guardian'};
 assert.deepEqual(ok(await available('es')).availableChildCountries,['US']);
 assert.equal((await call(f.adult,path,'POST',input)).data.error.code,'guardian_country_unavailable');
 const original=guardian.options.notices;
 try{
  guardian.options.notices=[mexicoNotices[0],{...mexicoNotices[1],childCountries:['US']}];
  const mismatch=ok(await available('es'));
  assert.equal(mismatch.available,false);
  assert.deepEqual(mismatch.availableChildCountries,[]);

  guardian.options.notices=mexicoNotices;
  const approved=ok(await available('es'));
  assert.equal(approved.available,true);
  assert.deepEqual(approved.availableChildCountries,['US','MX']);
  assert.equal(approved.notice.digest,mexicoNotices[1].digest);
  assert.equal(approved.notice.childCountries,undefined);
  assert.equal((await call(f.adult,path,'POST',input)).data.error.code,'guardian_notice_changed');

  const exact={...input,noticeVersion:approved.notice.version,noticeDigest:approved.notice.digest};
  for (const childLocation of ['MX-CMX','PR','US-PR','US-VI','US-ZZ']) {
   assert.equal((await call(f.adult,path,'POST',{...exact,childLocation})).status,422);
 }
  const pending=ok(await call(f.adult,path,'POST',exact));
  assert.equal((await admin.query('SELECT child_location FROM ritc.guardian_enrollment WHERE enrollment_id=$1',
   [pending.enrollmentId])).rows[0].child_location,'MX');

  guardian.options.notices=notices;
  const sends=requests.length;
  const disabled=await call(f.adult,path+'/'+pending.enrollmentId+'/verification','POST',
   {clientKey:randomUUID(),baseRevision:pending.revision});
  assert.equal(disabled.data.error.code,'guardian_country_unavailable');
  assert.equal(requests.length,sends);

  guardian.options.notices=mexicoNotices;
  const sent=await start(f,pending);
  assert.equal(sent.request.location,'MX');
  assert.equal(sent.request.language,'es');
  assert.equal(sent.request.userContext,'parent');
  ok(await callback(event(sent.request)));
  const verified=await read(f,pending.enrollmentId);
  const granted=ok(await call(f.adult,path+'/'+pending.enrollmentId+'/consent','POST',
   {clientKey:randomUUID(),baseRevision:verified.revision,noticeVersion:approved.notice.version,noticeDigest:approved.notice.digest,
    childAlias:'Fictional child',decision:'grant',childSignInEmail:f.child.email}));
  assert.equal(granted.state,'consented');
 }finally{guardian.options.notices=original;}
});

test('notice/create/verification exact retry binds notice and exact current guardian session/device',async()=>{
 const f=await family();assert.equal(ok(await call(f.adult,f.base+'/guardian/notice')).available,true);
 const made=await create(f);assert.deepEqual(ok(await call(f.adult,f.base+'/guardian/enrollments','POST',made.input)),made.setup);
 const changed=await call(f.adult,f.base+'/guardian/enrollments','POST',{...made.input,childLocation:'US-CA'});assert.equal(changed.data.error.code,'key_reused');
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.member WHERE household_id=$1 AND kind=\'child\'',[f.house.householdId])).rows[0].n,0);
 const sent=await start(f,made.setup),before=requests.length;assert.deepEqual(ok(await call(f.adult,f.base+'/guardian/enrollments/'+made.setup.enrollmentId+'/verification','POST',sent.input)),sent.setup);assert.equal(requests.length,before);
 assert.equal(requests.at(-1).email,f.adult.email);assert.equal(requests.at(-1).userContext,'parent');assert.ok(Buffer.byteLength(requests.at(-1).externalPayload)<=250);
 const anotherDevice=ok(await call(f.adult,f.base+'/devices','POST',{}),201);assert.equal((await call({...f.adult,...anotherDevice},f.base+'/guardian/enrollments/'+made.setup.enrollmentId)).status,404);
 const foreign=await family();assert.equal((await call(foreign.adult,foreign.base+'/guardian/enrollments/'+made.setup.enrollmentId)).status,404);
});
test('unconfirmed email, client email/boolean, wrong provider body and spoofed redirect cannot create proof',async()=>{
 const f=await family(),made=await create(f);await admin.query('UPDATE auth.users SET email_confirmed_at=NULL WHERE id=$1',[f.adult.subject]);
 assert.equal((await call(f.adult,f.base+'/guardian/enrollments/'+made.setup.enrollmentId+'/verification','POST',{clientKey:randomUUID(),baseRevision:1})).data.error.code,'guardian_email_unconfirmed');
 await admin.query('UPDATE auth.users SET email_confirmed_at=clock_timestamp() WHERE id=$1',[f.adult.subject]);const sent=await start(f,made.setup);
 assert.equal((await call(f.adult,f.base+'/guardian/enrollments/'+made.setup.enrollmentId+'/verification','POST',{clientKey:randomUUID(),baseRevision:2,email:'spoof@fixture.invalid',verified:true})).status,422);
 const raw=event(sent.request);assert.equal((await callback(raw,'t='+Date.now()+',v1='+'0'.repeat(64))).status,401);
 ok(await callback(event(sent.request,{payload:{parentEmail:'wrong@fixture.invalid',externalPayload:sent.request.externalPayload,status:{verified:true,transactionId:randomUUID()}}})));assert.equal((await read(f,made.setup.enrollmentId)).state,'verification_pending');
 assert.equal((await call(f.adult,f.base+'/guardian/enrollments/'+made.setup.enrollmentId+'/consent','POST',{clientKey:randomUUID(),baseRevision:2,noticeVersion:notices[0].version,noticeDigest:notices[0].digest,childAlias:'Child',decision:'grant',childSignInEmail:f.child.email})).data.error.code,'guardian_verification_required');
 ok(await callback(raw));assert.equal((await read(f,made.setup.enrollmentId)).state,'verified');assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.consent WHERE household_id=$1',[f.house.householdId])).rows[0].n,0);
});
test('signed event exact retry is idempotent; changed transaction evidence and wrong nonce are rejected',async()=>{
 const f=await family(),made=await create(f),sent=await start(f,made.setup),raw=event(sent.request);ok(await callback(raw));ok(await callback(raw));assert.equal((await read(f,made.setup.enrollmentId)).revision,3);
 const value=JSON.parse(raw);value.time=new Date(Date.now()+1).toISOString();assert.equal((await callback(JSON.stringify(value))).data.error.code,'provider_event_changed');
 const context=JSON.parse(sent.request.externalPayload);context.n=randomBytes(32).toString('base64url');const wrong=event({...sent.request,externalPayload:JSON.stringify(context)});assert.equal((await callback(wrong)).status,404);
});
test('separate permission, authenticated child claim and guardian pairing are all required before activation',async()=>{
 const f=await family(),state=await claimed(f);assert.equal(state.setup.state,'child_claimed');assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.member WHERE household_id=$1 AND kind=\'child\'',[f.house.householdId])).rows[0].n,0);
 const finish={clientKey:randomUUID(),householdId:f.house.householdId,claimId:state.claim.claimId,pairingCode:state.input.pairingCode,deviceSecret:randomBytes(32).toString('base64url')};assert.equal((await call(f.child,'/v1/child-invitations/finish','POST',finish)).status,410);
 const other=await actor();assert.equal((await call(other,'/v1/child-invitations/claims/'+state.claim.claimId+'?householdId='+f.house.householdId)).status,404);
 const wrong={clientKey:randomUUID(),baseRevision:state.setup.revision,claimId:state.claim.claimId,pairingCode:'ZZZZ2345'};assert.equal((await call(f.adult,f.base+'/guardian/enrollments/'+state.setup.enrollmentId+'/confirm-child','POST',wrong)).status,404);
 const confirm={...wrong,clientKey:randomUUID(),pairingCode:state.input.pairingCode};ok(await call(f.adult,f.base+'/guardian/enrollments/'+state.setup.enrollmentId+'/confirm-child','POST',confirm));
 const receipt=ok(await call(f.child,'/v1/child-invitations/finish','POST',finish));assert.deepEqual(ok(await call(f.child,'/v1/child-invitations/finish','POST',finish)),receipt);
 assert.equal((await call(other,'/v1/child-invitations/finish','POST',finish)).status,404);assert.deepEqual(Object.keys(receipt).sort(),['householdId','memberId','role','deviceId','deviceToken'].sort());
 Object.assign(f.child,receipt);const boot=ok(await call(f.child,f.base+'/bootstrap'));assert.deepEqual(boot.capabilities,['own_requests']);assert.equal(boot.canSelectShop,false);
 assert.equal((await call(f.child,f.base+'/members')).status,404);assert.equal((await call(f.child,f.base+'/devices','POST',{})).data.error.code,'guardian_reenrollment_required');
});
test('forwarded invitation cannot change an already claimed child subject, session, code or retry payload',async()=>{
 const f=await family(),state=await claimed(f),other=await actor();assert.equal((await call(other,'/v1/child-invitations/claim','POST',{...state.input,clientKey:randomUUID()})).status,404);
 assert.deepEqual(ok(await call(f.child,'/v1/child-invitations/claim','POST',state.input)),state.claim);
 assert.equal((await call(f.child,'/v1/child-invitations/claim','POST',{...state.input,pairingCode:'ZZZZ2345'})).data.error.code,'key_reused');
 const promoted=await call(f.child,'/v1/households','POST',{clientKey:randomUUID(),label:'Forbidden promotion',alias:'No',adultAttestation:true});assert.equal(promoted.status,503);
 const parentClaim=await call(f.adult,'/v1/child-invitations/claim','POST',{...state.input,clientKey:randomUUID()});assert.equal(parentClaim.status,404);
});
test('current email change, exact guardian session loss and notice drift invalidate later authority',async()=>{
 const f=await family(),setup=await verified(f);await admin.query('UPDATE auth.users SET email=$2 WHERE id=$1',[f.adult.subject,'changed@fixture.invalid']);const grant={clientKey:randomUUID(),baseRevision:setup.revision,noticeVersion:setup.noticeVersion,noticeDigest:setup.noticeDigest,childAlias:'Child',decision:'grant',childSignInEmail:f.child.email};
 assert.equal((await call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/consent','POST',grant)).data.error.code,'guardian_email_changed');
 const g=await family(),state=await claimed(g);await admin.query('DELETE FROM auth.sessions WHERE id=$1',[g.adult.session]);assert.equal((await call(g.adult,g.base+'/guardian/enrollments/'+state.setup.enrollmentId)).status,401);
 const h=await family(),pending=await create(h);const old=notices[0].version;notices[0].version='fixture-drift';notices[1].version='fixture-drift';assert.equal((await call(h.adult,h.base+'/guardian/enrollments/'+pending.setup.enrollmentId+'/verification','POST',{clientKey:randomUUID(),baseRevision:1})).data.error.code,'guardian_notice_changed');notices[0].version=old;notices[1].version=old;
});
test('uncertain delivery persists once, permits only signed callback completion, and never resends on exact retry',async()=>{
 const f=await family(),made=await create(f),input={clientKey:randomUUID(),baseRevision:1};failDelivery=true;const before=requests.length;const result=await call(f.adult,f.base+'/guardian/enrollments/'+made.setup.enrollmentId+'/verification','POST',input);failDelivery=false;assert.equal(result.data.error.code,'verification_uncertain');assert.equal((await read(f,made.setup.enrollmentId)).state,'verification_uncertain');
 ok(await call(f.adult,f.base+'/guardian/enrollments/'+made.setup.enrollmentId+'/verification','POST',input));assert.equal(requests.length,before+1);ok(await callback(event(requests.at(-1))));assert.equal((await read(f,made.setup.enrollmentId)).state,'verified');
});
test('withdrawal retires device/window/invite/claim generation and cannot be undone through HTTP or SQL',async()=>{
 const f=await family(),state=await active(f);const window=ok(await call(f.child,f.base+'/replay-windows','POST',{}));const consent=ok(await call(f.adult,f.base+'/guardian/consents')).consents[0];ok(await call(f.adult,f.base+'/guardian/consents/'+consent.consentId+'/revoke','POST',{}));
 assert.equal((await call(f.child,f.base+'/bootstrap')).status,403);assert.equal((await call(f.child,'/v1/child-invitations/finish','POST',state.finish)).status,410);assert.equal((await read(f,state.setup.enrollmentId)).state,'withdrawn');
 assert.ok((await admin.query('SELECT revoked_at FROM ritc.replay_window WHERE household_id=$1 AND window_id=$2',[f.house.householdId,window.id])).rows[0].revoked_at);
 const db=await app.connect();try{await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[f.house.householdId]);await assert.rejects(db.query("UPDATE ritc.guardian_enrollment SET state='child_approved',revision=revision+1 WHERE household_id=$1 AND enrollment_id=$2",[f.house.householdId,state.setup.enrollmentId]),e=>e.code==='23514');await db.query('ROLLBACK');}finally{db.release();}
 const credential=await app.connect();try{await credential.query('BEGIN');await credential.query("SELECT set_config('app.household_id',$1,true)",[f.house.householdId]);await assert.rejects(credential.query('UPDATE ritc.device SET revoked_at=NULL WHERE household_id=$1 AND device_id=$2',[f.house.householdId,state.receipt.deviceId]),e=>e.code==='23514');await credential.query('ROLLBACK');}finally{credential.release();}
});
test('ordinary runtime role cannot record provider proof or mint another child device from active consent',async()=>{
 const f=await family(),state=await active(f),consent=(await admin.query('SELECT consent_id FROM ritc.guardian_enrollment WHERE household_id=$1 AND enrollment_id=$2',[f.house.householdId,state.setup.enrollmentId])).rows[0].consent_id;
 await assert.rejects(app.query('SELECT ritc.guardian_record_verification($1,$2,$3,$4,$5,$6,$7,$8,$9)',[f.house.householdId,randomUUID(),'x','x',config.organizationId,config.productId,'test','x','x']),e=>e.code==='42501');
 const db=await app.connect();try{await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[f.house.householdId]);await assert.rejects(db.query('INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id,guardian_consent_id) VALUES($1,$2,$3,$4,$5,$6)',[f.house.householdId,randomUUID(),state.receipt.memberId,tokenHash('fixture-extra'),f.child.session,consent]),e=>e.code==='23514');await db.query('ROLLBACK');}finally{db.release();}
});
test('cancelled and expired setup callbacks cannot revive authority',async()=>{
 const f=await family(),made=await create(f),sent=await start(f,made.setup);ok(await call(f.adult,f.base+'/guardian/enrollments/'+made.setup.enrollmentId+'/cancel','POST',{clientKey:randomUUID(),baseRevision:sent.setup.revision}));ok(await callback(event(sent.request)));assert.equal((await read(f,made.setup.enrollmentId)).state,'cancelled');
 const g=await family(),created=await create(g),pending=await start(g,created.setup);await admin.query("UPDATE ritc.guardian_enrollment SET state='expired',revision=revision+1 WHERE household_id=$1 AND enrollment_id=$2",[g.house.householdId,created.setup.enrollmentId]);ok(await callback(event(pending.request)));assert.equal((await read(g,created.setup.enrollmentId)).state,'expired');
});
test('pending child erasure purges claim identity and same live provider principal stays classified after marker expiry',async()=>{
 const f=await family(),state=await claimed(f),job=randomUUID(),identityHash=tokenHash(issuer+'\n'+f.child.subject);
 await admin.query(`INSERT INTO ritc.privacy_job(job_id,identity_hash,issuer,subject,receipt_hash,payload_digest,receipt_retention_days,marker_retention_days,receipt_until,marker_until) VALUES($1,$2,$3,$4,$5,$5,1,1,clock_timestamp()+interval '1 day',clock_timestamp()+interval '1 day')`,[job,identityHash,issuer,f.child.subject,tokenHash('fixture')]);await admin.query("INSERT INTO ritc.identity_erasure(identity_hash,job_id,retain_until) VALUES($1,$2,clock_timestamp()+interval '1 day')",[identityHash,job]);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.guardian_child_claim WHERE household_id=$1',[f.house.householdId])).rows[0].n,0);await admin.query('DELETE FROM ritc.identity_erasure WHERE identity_hash=$1',[identityHash]);
 assert.equal((await call(f.child,'/v1/households','POST',{clientKey:randomUUID(),label:'Forbidden post-erasure promotion',alias:'No',adultAttestation:true})).status,503);
 assert.equal((await call(f.child,'/v1/child-invitations/finish','POST',{clientKey:randomUUID(),householdId:f.house.householdId,claimId:state.claim.claimId,pairingCode:state.input.pairingCode,deviceSecret:randomBytes(32).toString('base64url')})).status,404);
 await assert.rejects(app.query('SELECT * FROM ritc.guardian_child_principal'),e=>e.code==='42501');
});

test('native child signup is authorized before OTP, retries once, and requires fresh signed OTP AMR',async()=>{
 const f=await family(),{setup}=await consented(f),invitation=ok(await call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/child-invitations','POST',{clientKey:randomUUID(),baseRevision:setup.revision,secret:randomBytes(32).toString('base64url')}));
 const start={clientKey:randomUUID(),token:invitation.token,email:f.child.email,challengeSecret:randomBytes(32).toString('base64url')};const before=otpRequests.length;
 assert.equal((await call(null,'/v1/child-invitations/native-auth/start','POST',{...start,email:'wrong-child@fixture.invalid'})).status,404);assert.equal(otpRequests.length,before);
 const challenge=ok(await call(null,'/v1/child-invitations/native-auth/start','POST',start));assert.equal(otpRequests.length,before+1);assert.deepEqual(ok(await call(null,'/v1/child-invitations/native-auth/start','POST',start)),challenge);assert.equal(otpRequests.length,before+1);
 assert.equal((await call(null,'/v1/child-invitations/native-auth/start','POST',{...start,clientKey:randomUUID()})).data.error.code,'child_signin_pending');
 const input={clientKey:randomUUID(),householdId:challenge.householdId,challengeId:challenge.challengeId,challengeSecret:start.challengeSecret};
 for(const method of ['password','oauth','sso/saml']){await freshAuth(f.child,method);assert.equal((await call(f.child,'/v1/child-invitations/native-auth/admit','POST',input)).data.error.code,'child_reauthentication_required');}
 await freshAuth(f.child,'otp',3600);assert.equal((await call(f.child,'/v1/child-invitations/native-auth/admit','POST',input)).status,401);await freshAuth(f.child);ok(await call(f.child,'/v1/child-invitations/native-auth/admit','POST',input));
 assert.equal((await call(f.child,'/v1/child-invitations/native-auth/admit','POST',{...input,challengeSecret:randomBytes(32).toString('base64url')})).status,404);
 const denied=(await app.query("SELECT has_column_privilege(current_user,'ritc.guardian_native_challenge','subject','UPDATE') AS can_update")).rows[0];assert.equal(denied.can_update,false);
 const row=(await admin.query('SELECT * FROM ritc.guardian_native_challenge WHERE household_id=$1 AND challenge_id=$2',[challenge.householdId,challenge.challengeId])).rows[0];assert.equal(row.secret_hash,tokenHash(start.challengeSecret));assert.ok(!JSON.stringify(row).includes(start.challengeSecret));
});
test('browser covered child OTP installs scoped HttpOnly session and omits credentials from finish JSON',async()=>{
 const f=await family(),{setup}=await consented(f),invitation=ok(await call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/child-invitations','POST',{clientKey:randomUUID(),baseRevision:setup.revision,secret:randomBytes(32).toString('base64url')}));
 const challenge=await call(null,'/v1/auth/session');const authCookie=challenge.headers.get('set-cookie').split(';')[0];let csrf=challenge.data.csrf;
 const headers={Origin:webOrigin,Cookie:authCookie,'x-csrf-token':csrf};ok(await call(null,'/v1/child-invitations/auth/start','POST',{token:invitation.token,email:f.child.email},headers));
 // A generic email-start against the same challenge retains and rechecks binding.
 assert.notEqual((await call(null,'/v1/auth/email/start','POST',{email:'wrong@fixture.invalid'},headers)).status,200);
 const signed=await call(null,'/v1/auth/email/verify','POST',{code:'123456'},headers);ok(signed);const nextCookie=signed.headers.getSetCookie().find(value=>value.startsWith('__Host-ritc_auth=')).split(';')[0];csrf=signed.data.csrf;const signedHeaders={Origin:webOrigin,Cookie:nextCookie,'x-csrf-token':csrf};
 const admission=ok(await call(null,'/v1/child-invitations/session','GET',undefined,{Cookie:nextCookie}));assert.equal(admission.admitted,true);assert.equal(admission.scope,'own_requests');assert.equal(admission.inviteId,invitation.inviteId);assert.equal(admission.status,'admitted');
 const claimInput={clientKey:randomUUID(),token:invitation.token,pairingCode:'QWER2345'},claim=ok(await call(null,'/v1/child-invitations/claim','POST',claimInput,signedHeaders));const latest=await read(f,setup.enrollmentId);ok(await call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/confirm-child','POST',{clientKey:randomUUID(),baseRevision:latest.revision,claimId:claim.claimId,pairingCode:claimInput.pairingCode}));
 const finish={clientKey:randomUUID(),householdId:f.house.householdId,claimId:claim.claimId,pairingCode:claimInput.pairingCode,deviceSecret:randomBytes(32).toString('base64url')};
 const result=await call(null,'/v1/child-invitations/finish','POST',finish,signedHeaders);ok(result);
 assert.deepEqual(Object.keys(result.data).sort(),['deviceId','householdId','memberId','role']);
 assert.ok(!JSON.stringify(result.data).includes(finish.deviceSecret));
 const scope=result.headers.get('set-cookie');assert.ok(scope.includes('HttpOnly'));const scopeCookie=scope.split(';')[0];
 const [cookieHousehold,sessionToken]=scopeCookie.slice('ritc_session='.length).split('.');
 assert.equal(cookieHousehold,f.house.householdId);assert.match(sessionToken,/^[A-Za-z0-9_-]{43}$/);assert.notEqual(sessionToken,finish.deviceSecret);
 const session=ok(await call(null,'/v1/session','GET',undefined,{Cookie:nextCookie+'; '+scopeCookie}));assert.equal(session.authenticated,true);assert.equal(session.memberId,result.data.memberId);assert.deepEqual(session.capabilities,['own_requests']);
 // A stored receipt cannot redirect the scoped cookie or extend the browser response.
 await admin.query("UPDATE ritc.guardian_intent SET response=response||jsonb_build_object('householdId',$3::uuid,'internalDetail','fixture') WHERE household_id=$1 AND client_key=$2 AND kind='finish'",[f.house.householdId,finish.clientKey,randomUUID()]);
 const retry=await call(null,'/v1/child-invitations/finish','POST',finish,signedHeaders);ok(retry);assert.deepEqual(retry.data,result.data);assert.ok(retry.headers.get('set-cookie').includes('HttpOnly'));assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.web_session WHERE household_id=$1 AND device_id=$2',[f.house.householdId,result.data.deviceId])).rows[0].n,1);
});
test('non-organizer cannot create child membership and organizer role loss blocks pending finalization',async()=>{
 const f=await family();await admin.query('UPDATE ritc.member SET organizer=false WHERE household_id=$1 AND member_id=$2',[f.house.householdId,f.house.memberId]);const input={clientKey:randomUUID(),noticeVersion:notices[0].version,noticeDigest:notices[0].digest,language:'en',childLocation:'US',guardianDeclaration:'parent_or_legal_guardian'};assert.equal((await call(f.adult,f.base+'/guardian/enrollments','POST',input)).data.error.code,'organizer_required');
 const g=await family(),state=await claimed(g);ok(await call(g.adult,g.base+'/guardian/enrollments/'+state.setup.enrollmentId+'/confirm-child','POST',{clientKey:randomUUID(),baseRevision:state.setup.revision,claimId:state.claim.claimId,pairingCode:state.input.pairingCode}));await admin.query('UPDATE ritc.member SET organizer=false WHERE household_id=$1 AND member_id=$2',[g.house.householdId,g.house.memberId]);assert.equal((await call(g.child,'/v1/child-invitations/finish','POST',{clientKey:randomUUID(),householdId:g.house.householdId,claimId:state.claim.claimId,pairingCode:state.input.pairingCode,deviceSecret:randomBytes(32).toString('base64url')})).status,410);
});
test('guardian revoke and adult rejoin cannot revive a child consent/device generation',async()=>{
 const f=await family(),state=await active(f);await admin.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2",[f.house.householdId,f.house.memberId]);assert.equal((await call(f.child,f.base+'/bootstrap')).status,403);await admin.query("UPDATE ritc.member SET state='active' WHERE household_id=$1 AND member_id=$2",[f.house.householdId,f.house.memberId]);assert.equal((await call(f.child,f.base+'/bootstrap')).status,403);assert.equal((await read(f,state.setup.enrollmentId)).state,'withdrawn');
 const child=(await admin.query('SELECT revoked_at FROM ritc.consent WHERE household_id=$1 AND child_id=$2',[f.house.householdId,state.receipt.memberId])).rows[0];assert.ok(child.revoked_at);
});
test('production operations HTTP performs bounded technical expiry and policy-gated pending purge without provider calls',async()=>{
 const f=await family(),{setup}=await create(f),expiredId=randomUUID();await admin.query(`INSERT INTO ritc.guardian_enrollment(household_id,enrollment_id,guardian_id,guardian_device_id,guardian_issuer,guardian_subject,guardian_session,child_id,notice_version,notice_digest,method_version,language,child_location,declaration,state,created_at,expires_at)
 SELECT household_id,$3,guardian_id,guardian_device_id,guardian_issuer,guardian_subject,guardian_session,$4,notice_version,notice_digest,method_version,language,child_location,declaration,'verification_pending',clock_timestamp()-interval '3 hours',clock_timestamp()-interval '2 hours' FROM ritc.guardian_enrollment WHERE household_id=$1 AND enrollment_id=$2`,[f.house.householdId,setup.enrollmentId,expiredId,randomUUID()]);
 const secret=randomBytes(32).toString('base64url'),environment={WORKER_DATABASE_URL:process.env.TEST_WORKER_DATABASE_URL,DATABASE_URL:process.env.TEST_DATABASE_URL,CRON_SECRET:secret};let operations=createOperationsHTTPServer(environment);await new Promise(resolve=>operations.server.listen(0,'127.0.0.1',resolve));
 async function run(){const response=await fetch('http://127.0.0.1:'+operations.server.address().port+'/internal/maintenance',{headers:{Authorization:'Bearer '+secret}});assert.equal(response.status,200);return response.json();}
 const before=requests.length+otpRequests.length;try{const result=await run();assert.equal(result.guardian.expired,1);assert.equal(result.guardian.purged,0);assert.equal(result.guardian.retentionConfigured,false);assert.equal((await admin.query('SELECT state FROM ritc.guardian_enrollment WHERE household_id=$1 AND enrollment_id=$2',[f.house.householdId,expiredId])).rows[0].state,'expired');}finally{await new Promise(resolve=>operations.server.close(resolve));await operations.close();}
 operations=createOperationsHTTPServer({...environment,GUARDIAN_PENDING_RETENTION_HOURS:'1',GUARDIAN_EVIDENCE_RETENTION_DAYS:'1',GUARDIAN_RETENTION_APPROVAL_REFERENCE:'fictional-test-policy'});await new Promise(resolve=>operations.server.listen(0,'127.0.0.1',resolve));try{const result=await run();assert.equal(result.guardian.purged,1);assert.equal(result.guardian.retentionConfigured,true);assert.equal(requests.length+otpRequests.length,before);assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.guardian_enrollment WHERE household_id=$1 AND enrollment_id=$2',[f.house.householdId,expiredId])).rows[0].n,0);}finally{await new Promise(resolve=>operations.server.close(resolve));await operations.close();}
 await assert.rejects(app.query('SELECT * FROM ritc.guardian_housekeeping(25,1,1)'),e=>e.code==='42501');
});

test('bound OTP verification racing guardian cancellation has no browser/household deadlock or post-cancel admission',async()=>{
 const f=await family(),{setup}=await consented(f),invitation=ok(await call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/child-invitations','POST',{clientKey:randomUUID(),baseRevision:setup.revision,secret:randomBytes(32).toString('base64url')}));
 const challenge=await call(null,'/v1/auth/session'),cookie=challenge.headers.get('set-cookie').split(';')[0],headers={Origin:webOrigin,Cookie:cookie,'x-csrf-token':challenge.data.csrf};ok(await call(null,'/v1/child-invitations/auth/start','POST',{token:invitation.token,email:f.child.email},headers));
 let reached,release;const entered=new Promise(resolve=>{reached=resolve;}),blocked=new Promise(resolve=>{release=resolve;});holdVerify=async()=>{reached();await blocked;};const checking=call(null,'/v1/auth/email/verify','POST',{code:'123456'},headers);await entered;
 const cancelling=call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/cancel','POST',{clientKey:randomUUID(),baseRevision:setup.revision});
 const probe=await admin.connect();let locked=false;try{for(let i=0;i<100&&!locked;i++){await probe.query('BEGIN');try{await probe.query('SELECT 1 FROM ritc.household WHERE household_id=$1 FOR UPDATE NOWAIT',[f.house.householdId]);}catch(error){if(error.code==='55P03')locked=true;else throw error;}finally{await probe.query('ROLLBACK');}if(!locked)await new Promise(resolve=>setTimeout(resolve,2));}}finally{probe.release();release();holdVerify=undefined;}
 assert.equal(locked,true,'cancellation acquired household while OTP held browser row');const [cancelled,verified]=await Promise.all([cancelling,checking]);ok(cancelled);assert.ok([401,410].includes(verified.status),JSON.stringify(verified.data));assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.guardian_child_signin WHERE household_id=$1',[f.house.householdId])).rows[0].n,0);
 assert.equal((await read(f,setup.enrollmentId)).state,'cancelled');
});

test('application SQL writer cannot use copied email digests to admit or finalize child authority',async()=>{
 const f=await family(),state=await claimed(f),db=await app.connect();
 try{await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[f.house.householdId]);
  await assert.rejects(db.query('SELECT ritc.guardian_admit_signin($1,$2,$3,$4,$5,$6)',[f.house.householdId,state.invitation.inviteId,issuer,f.child.subject,f.child.session,'0'.repeat(64)]),e=>e.code==='42501');await db.query('ROLLBACK');
  await assert.rejects(db.query('SELECT ritc.guardian_finish($1,$2,$3,$4,$5,$6,$7,$8,$9)',[f.house.householdId,state.claim.claimId,issuer,f.child.subject,f.child.session,'0'.repeat(64),'0'.repeat(64),randomUUID(),'0'.repeat(64)]),e=>e.code==='42501');
  const row=(await admin.query('SELECT child_email_digest FROM ritc.guardian_enrollment WHERE household_id=$1 AND enrollment_id=$2',[f.house.householdId,state.setup.enrollmentId])).rows[0];
  await assert.rejects(db.query('SELECT ritc.guardian_admit_child_verified($1,$2,$3,$4,$5,$6,$7)',[f.house.householdId,state.invitation.inviteId,issuer,f.child.subject,f.child.session,f.child.email,row.child_email_digest]),e=>e.code==='42501');
 }finally{db.release();}
});

test('reconsent is a fresh guardian generation; organizer-revoked membership cannot be restored by a non-organizer guardian',async()=>{
 const f=await family(),old=await active(f),consent=ok(await call(f.adult,f.base+'/guardian/consents')).consents[0];ok(await call(f.adult,f.base+'/guardian/consents/'+consent.consentId+'/revoke','POST',{}));
 const next=await active(f,{childId:old.receipt.memberId});assert.equal(next.receipt.memberId,old.receipt.memberId);assert.notEqual(next.receipt.deviceId,old.receipt.deviceId);assert.equal((await call({...f.child,...old.receipt},f.base+'/bootstrap')).status,403);ok(await call(f.child,f.base+'/bootstrap'));
 const rows=(await admin.query('SELECT consent_id,revoked_at FROM ritc.consent WHERE household_id=$1 AND child_id=$2',[f.house.householdId,next.receipt.memberId])).rows;assert.equal(rows.length,2);assert.equal(rows.filter(row=>row.revoked_at===null).length,1);
 await admin.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2",[f.house.householdId,next.receipt.memberId]);await admin.query('UPDATE ritc.member SET organizer=false WHERE household_id=$1 AND member_id=$2',[f.house.householdId,f.house.memberId]);
 const rejected=await call(f.adult,f.base+'/guardian/enrollments','POST',{clientKey:randomUUID(),childId:next.receipt.memberId,noticeVersion:notices[0].version,noticeDigest:notices[0].digest,language:'en',childLocation:'US',guardianDeclaration:'parent_or_legal_guardian'});assert.equal(rejected.data.error.code,'organizer_required');
});
test('paired child chooses an open pickup and sees only their own request until consent is revoked',async()=>{
 const f=await family();
 await active(f);
 const adultWindow=ok(await call(f.adult,f.base+'/replay-windows','POST',{}));
 const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:3800,capScope:'wholeCheckout',
  fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,
  observedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+3_600_000).toISOString()};
 const other=randomUUID(),target=randomUUID();
 for(const shopId of [other,target]){
  ok(await call(f.adult,f.base+'/commands','POST',{v:1,replayWindow:adultWindow.id,clientKey:randomUUID(),
   shopId,kind:'shop.create',base:{shopRevision:0,authorityEpoch:0},body:{quote,lines:[]}}));
 }
 const bootstrap=ok(await call(f.child,f.base+'/bootstrap'));
 assert.equal(bootstrap.selectionRequired,true);
 assert.equal(bootstrap.shopId,null);
 assert.equal(bootstrap.canSelectShop,false);
 assert.deepEqual(bootstrap.capabilities,['own_requests']);
 const choices=ok(await call(f.child,f.base+'/requests/pickups'));
 assert.deepEqual(new Set(choices.shops.map(r=>r.shopId)),new Set([target,other]));
 for(const row of choices.shops)assert.deepEqual(Object.keys(row).sort(),['createdAt','nextShopOnly','shopId']);
 const childWindow=ok(await call(f.child,f.base+'/replay-windows','POST',{}));
 const send=(person,window,shopId,item)=>call(person,f.base+'/commands','POST',{v:1,replayWindow:window.id,
  clientKey:randomUUID(),shopId,kind:'request.send',base:{shopRevision:0,authorityEpoch:0},
  body:{clientRequestId:randomUUID(),originalItem:item,ownQuantity:'one',authoredAt:new Date().toISOString()}});
 ok(await send(f.adult,adultWindow,other,'Private adult item'));
 const receipt=ok(await send(f.child,childWindow,target,'Own child item'));
 const own=ok(await call(f.child,f.base+'/requests/mine'));
 assert.equal(own.requests.length,1);
 assert.equal(own.requests[0].originalItem,'Own child item');
 assert.equal(own.requests[0].shopId,target);
 assert.equal(own.requests[0].requestId,receipt.request.requestId);
 const raw=JSON.stringify([own,choices,receipt]);
 for(const forbidden of ['Private adult item','capMinor','unitPrice','budget','guardian','parentEmail'])assert.ok(!raw.includes(forbidden));
 for(const route of ['/members','/shops','/shops/'+target,'/shops/'+target+'/inbox','/guardian/consents']){
  assert.equal((await call(f.child,f.base+route)).status,404);
 }
 const {consents}=ok(await call(f.adult,f.base+'/guardian/consents'));
 ok(await call(f.adult,f.base+'/guardian/consents/'+consents[0].consentId+'/revoke','POST',{}));
 assert.equal((await call(f.child,f.base+'/requests/pickups')).status,403);
 assert.equal((await send(f.child,childWindow,target,'Revoked attempt')).status,403);
});

test('trusted finish and pending-child identity deletion serialize in both deterministic lock orders',async t=>{
 for(const ordering of ['finish_first','deletion_first']){
  const f=await family(),state=await claimed(f);ok(await call(f.adult,f.base+'/guardian/enrollments/'+state.setup.enrollmentId+'/confirm-child','POST',{clientKey:randomUUID(),baseRevision:state.setup.revision,claimId:state.claim.claimId,pairingCode:state.input.pairingCode}));
  const review=await reviewChildAccount(f,state.setup.enrollmentId);
  const details=(await admin.query('SELECT c.pairing_hash,a.email_digest FROM ritc.guardian_child_claim c JOIN ritc.guardian_child_invitation v USING(household_id,invite_id) JOIN ritc.guardian_attempt a USING(household_id,enrollment_id) WHERE c.household_id=$1 AND c.claim_id=$2',[f.house.householdId,state.claim.claimId])).rows[0];
  const lock=await admin.connect(),trusted=await proof.connect(),deleting=await app.connect();let finalizing,deletion;
  try{
   await lock.query('BEGIN');await lock.query('SELECT 1 FROM ritc.household WHERE household_id=$1 FOR UPDATE',[f.house.householdId]);await trusted.query('BEGIN');await trusted.query("SELECT set_config('app.household_id',$1,true)",[f.house.householdId]);
   const trustedPID=(await trusted.query('SELECT pg_backend_pid() pid')).rows[0].pid,deletePID=(await deleting.query('SELECT pg_backend_pid() pid')).rows[0].pid;
   const finish=()=>trusted.query('SELECT ritc.guardian_finish_verified($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) receipt',[f.house.householdId,state.claim.claimId,issuer,f.child.subject,f.child.session,details.pairing_hash,details.email_digest,randomUUID(),tokenHash(randomUUID()),randomUUID(),tokenHash(randomUUID()),f.adult.email,f.child.email]);
   const pinnedClient={query:deleting.query.bind(deleting),release(){}};const deletionRepo=new HouseholdRepository({connect:async()=>pinnedClient,query:deleting.query.bind(deleting)},{allowChildNetwork:true,noticeVersion:notices[0].version,sessionStatus:new SupabaseSessionVerifier(issuer)});
   const deletionService=new PrivacyService(deletionRepo,{provider:privacyProvider,policy:privacyPolicy,journal:journal.port});const deletionIdentity=await verifier.verify(f.adult.token),deletionInput={...deletionReceipt(),reviewId:review.reviewId};
   t.after(()=>deferProfileOnlyDeletion(admin,deletionInput.clientKey));
   const erase=()=>deletionService.requestChild(deletionIdentity,f.house.householdId,state.setup.enrollmentId,deletionInput).then(value=>({accepted:true,value}),error=>({accepted:false,error}));
   async function awaitLock(pid){for(let i=0;i<200;i++){if((await admin.query('SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1',[pid])).rows[0]?.wait_event_type==='Lock')return;await new Promise(resolve=>setTimeout(resolve,2));}throw new Error('expected real PostgreSQL lock wait');}
   if(ordering==='finish_first'){finalizing=finish();await awaitLock(trustedPID);deletion=erase();await awaitLock(deletePID);await lock.query('COMMIT');const result=await finalizing;assert.ok(result.rows[0].receipt);await trusted.query('COMMIT');const resultDelete=await deletion;assert.equal(resultDelete.accepted,false);assert.equal(resultDelete.error.code,'unavailable');assert.equal(resultDelete.error.status,404);}
   else{deletion=erase();await awaitLock(deletePID);finalizing=finish();assert.equal((await finalizing).rows[0].receipt,null);await trusted.query('COMMIT');await lock.query('COMMIT');assert.equal((await deletion).accepted,true);}
   assert.equal((await admin.query("SELECT count(*)::int n FROM ritc.member WHERE household_id=$1 AND kind='child' AND erased_at IS NULL",[f.house.householdId])).rows[0].n,ordering==='finish_first'?1:0);
  }finally{await lock.query('ROLLBACK');await trusted.query('ROLLBACK');lock.release();trusted.release();deleting.release();}
 }
});
test('real privacy worker erases guardian plus child profile, retains independent provider account and lifetime negative authority',async t=>{
 const f=await family(),state=await active(f),job=randomUUID();
 t.after(()=>deferProfileOnlyDeletion(admin,job));
 const deletionService=new PrivacyService(repo,{provider:privacyProvider,policy:privacyPolicy,journal:journal.port});await deletionService.request(await verifier.verify(f.adult.token),{clientKey:job,statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.house.householdId,organizer:'archive',shops:[],eraseChildProfiles:[state.receipt.memberId]}]});
 const worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL}),lease=randomUUID();try{const claim=(await worker.query('SELECT * FROM ritc.privacy_claim($1)',[lease])).rows[0];assert.equal(claim.job_id,job);for(let i=0;i<5;i++){const result=(await worker.query('SELECT ritc.privacy_erase_target($1,$2) done',[job,lease])).rows[0];await journal.port.acknowledgeJob(job);if(result.done)break;}
  const profiles=(await admin.query('SELECT state,erased_at,issuer,alias FROM ritc.member WHERE household_id=$1',[f.house.householdId])).rows;assert.ok(profiles.every(profile=>profile.erased_at&&profile.state==='revoked'&&profile.issuer==='urn:ritc:erased'));assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.guardian_enrollment WHERE household_id=$1',[f.house.householdId])).rows[0].n,0);assert.equal((await admin.query('SELECT count(*)::int n FROM auth.users WHERE id=$1',[f.child.subject])).rows[0].n,1);assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.guardian_child_principal WHERE provider_user=$1',[f.child.subject])).rows[0].n,1);
  await admin.query('DELETE FROM ritc.identity_erasure WHERE identity_hash=$1',[tokenHash(issuer+'\n'+f.child.subject)]);assert.equal((await call(f.child,'/v1/households','POST',{clientKey:randomUUID(),label:'Forbidden after profile erasure',alias:'No',adultAttestation:true})).status,503);
 }finally{await worker.end();}
});

test('production readiness cannot be enabled by flags, partial notices, missing onboarding or a combined verifier role',async()=>{
 const runtime=await createRuntime({DATABASE_URL:process.env.TEST_DATABASE_URL,CHILD_NETWORK_ENABLED:'true',KWS_ENABLED:'true'});await new Promise(resolve=>runtime.server.listen(0,'127.0.0.1',resolve));try{const reply=await fetch('http://127.0.0.1:'+runtime.server.address().port+'/v1/guardian/availability');assert.deepEqual(await reply.json(),{available:false,reason:'provider_configuration_required'});}finally{await new Promise(resolve=>runtime.server.close(resolve));await runtime.pool.end();}
 const environment={DATABASE_URL:process.env.TEST_DATABASE_URL,GUARDIAN_VERIFIER_DATABASE_URL:process.env.TEST_GUARDIAN_VERIFIER_DATABASE_URL,KWS_ORGANIZATION_ID:config.organizationId,KWS_SCOPE:'product',KWS_PRODUCT_ID:config.productId,KWS_ENVIRONMENT:'test',KWS_CLIENT_ID:'fixture-client',KWS_API_KEY:'fixture-key',KWS_SERVICE_ORIGIN:'https://api.kidswebservices.com',KWS_USER_AGENT:'fictional-local-test',KWS_WEBHOOK_SECRETS_JSON:JSON.stringify([signing]),GUARDIAN_EMAIL_DIGEST_KEY:randomBytes(32).toString('base64url'),GUARDIAN_APPROVED_NOTICES_JSON:JSON.stringify(notices),GUARDIAN_PENDING_RETENTION_HOURS:'1',GUARDIAN_EVIDENCE_RETENTION_DAYS:'1',GUARDIAN_RETENTION_APPROVAL_REFERENCE:'fictional-only-policy'};
 const created=await guardianRuntime(repo,environment,databaseConfiguration);try{assert.equal(created.service.notice('en').available,false);created.service.attachChildSignin(bff,otpProvider);assert.equal(created.service.notice('en').available,true);assert.equal(created.service.notice('es').available,true);}finally{await created.pool.end();}
 const partial=await guardianRuntime(repo,{...environment,GUARDIAN_APPROVED_NOTICES_JSON:JSON.stringify([notices[0]])},databaseConfiguration);try{partial.service.attachChildSignin(bff,otpProvider);assert.equal(partial.service.notice('en').available,false);assert.equal(partial.service.notice('en').reason,'notice_approval_required');}finally{await partial.pool.end();}
 await assert.rejects(guardianRuntime(repo,{...environment,GUARDIAN_VERIFIER_DATABASE_URL:process.env.TEST_DATABASE_URL},databaseConfiguration),/verifier-only/);
 const combinedRole=(await admin.query("SELECT rolcanlogin,rolsuper,rolbypassrls,pg_has_role(oid,'ritc_guardian_verifier','MEMBER') AS verifier,pg_has_role(oid,'ritc_worker','MEMBER') AS worker,pg_has_role(oid,'ritc_app','MEMBER') AS app FROM pg_roles WHERE rolname='ritc_guardian_combined_worker'")).rows[0];
 assert.ok(combinedRole?.rolcanlogin&&combinedRole.verifier&&combinedRole.worker&&!combinedRole.app&&!combinedRole.rolsuper&&!combinedRole.rolbypassrls,'The existing intentionally combined fixture role is required for this negative test; this test does not create roles or change memberships.');
 const combined=new URL(process.env.TEST_GUARDIAN_VERIFIER_DATABASE_URL);combined.username='ritc_guardian_combined_worker';await assert.rejects(guardianRuntime(repo,{...environment,GUARDIAN_VERIFIER_DATABASE_URL:combined.toString()},databaseConfiguration),/verifier-only/);
});

test(restoreTestName,async()=>{
 if(!process.env.RITC_CHILD_RESTORE_DIRECTORY)return runIsolatedChildRestore();
 const f=await family(),enrolled=await active(f),id=enrolled.setup.enrollmentId;
 const unjoined=await family(),pending=await claimed(unjoined),pendingId=pending.setup.enrollmentId;
 for(const child of [f.child,unjoined.child]){
  const preview=ok(await call(child,'/v1/privacy/deletion-preview'));
  assert.equal(preview.adult,false);assert.equal(preview.deletionAvailable,false);assert.deepEqual(preview.households,[]);
 }
 const other=await family(),paired=await active(other),consent=ok(await call(other.adult,other.base+'/guardian/consents')).consents[0];
 const pendingFamily=await family(),claim=await claimed(pendingFamily);
 ok(await call(other.child,other.base+'/bootstrap'));
 const review=await reviewChildAccount(f,id),pendingReview=await reviewChildAccount(unjoined,pendingId);
 async function checkAuthority(db,retired){
  const evidence=(await db.query(`SELECT c.revoked_at,e.state,e.revision,v.revoked_at AS device_retired,
      m.state AS member_state,EXISTS(SELECT FROM ritc.guardian_relationship g WHERE g.household_id=c.household_id
      AND g.child_id=c.child_id AND g.guardian_id=c.guardian_id AND g.revoked_at IS NULL) AS guardian_retained
      FROM ritc.consent c JOIN ritc.guardian_enrollment e USING(household_id,consent_id)
      JOIN ritc.device v ON v.household_id=c.household_id AND v.device_id=$2
      JOIN ritc.member m ON (m.household_id,m.member_id)=(c.household_id,c.guardian_id)
      WHERE c.consent_id=$1`,[consent.consentId,paired.receipt.deviceId])).rows[0];
  assert.equal(evidence.revoked_at!==null,retired);
  assert.equal(evidence.device_retired!==null,retired);
  assert.equal(evidence.state,retired?'withdrawn':'active');
  assert.equal(evidence.member_state,'active');
  assert.equal(evidence.guardian_retained,true);
  const pending=(await db.query(`SELECT e.state,i.revoked_at AS invite_retired,c.revoked_at AS claim_retired
      FROM ritc.guardian_enrollment e JOIN ritc.guardian_child_invitation i USING(household_id,enrollment_id)
      JOIN ritc.guardian_child_claim c USING(household_id,invite_id) WHERE e.enrollment_id=$1`,[claim.setup.enrollmentId])).rows[0];
  assert.equal(pending.state,retired?'withdrawn':'child_claimed');
  assert.equal(pending.invite_retired!==null,retired);
  assert.equal(pending.claim_retired!==null,retired);
  return {evidence,pending};
 }
 async function checkRenewal(urls){
  const appPool=new pg.Pool({connectionString:urls.app}),proofPool=new pg.Pool({connectionString:urls.verifier});
  const repository=new HouseholdRepository(appPool,repo.options);
  const enrollment=new GuardianEnrollmentService(repository,{...guardian.options,verifierPool:proofPool});
  const browser=new BrowserAuthService(repository,verifier,otpProvider,{encryptionKey:randomBytes(32).toString('base64'),childSignin:enrollment});
  enrollment.attachChildSignin(browser,otpProvider);
  const probe=createHTTPServer({repository,verifier,guardian:enrollment,browserAuth:browser,maxRequestsPerMinute:10000});
  const sourceOrigin=origin;
  try{
   await new Promise(resolve=>probe.listen(0,'127.0.0.1',resolve));
   origin='http://127.0.0.1:'+probe.address().port;
   ok(await call(other.adult,other.base+'/bootstrap'));
   assert.equal((await call(other.child,other.base+'/bootstrap')).status,403);
   const pending=await claimed(other,{childId:paired.receipt.memberId});
   assert.equal((await call(other.child,other.base+'/bootstrap')).status,403);
   const pairing={claimId:pending.claim.claimId,pairingCode:pending.input.pairingCode};
   ok(await call(other.adult,other.base+'/guardian/enrollments/'+pending.setup.enrollmentId+'/confirm-child','POST',
      {...pairing,clientKey:randomUUID(),baseRevision:pending.setup.revision}));
   const renewed=ok(await call(other.child,'/v1/child-invitations/finish','POST',
      {...pairing,clientKey:randomUUID(),householdId:other.house.householdId,deviceSecret:randomBytes(32).toString('base64url')}));
   assert.equal(renewed.memberId,paired.receipt.memberId);
   assert.notEqual(renewed.deviceId,paired.receipt.deviceId);
   assert.equal((await call(other.child,other.base+'/bootstrap')).status,403);
   assert.deepEqual(ok(await call({...other.child,...renewed},other.base+'/bootstrap')).capabilities,['own_requests']);
  }finally{
   origin=sourceOrigin;
   await new Promise(resolve=>probe.close(resolve));
   await Promise.all([appPool.end(),proofPool.end()]);
  }
 }
 await verifyChildBackup({family:f,unjoined,childMemberId:enrolled.receipt.memberId,journal,checkAuthority,checkRenewal,accept:async()=>{
  ok(await call(other.adult,other.base+'/guardian/consents/'+consent.consentId+'/revoke','POST',{}));
  assert.equal((await call(other.child,other.base+'/bootstrap')).status,403);
  ok(await call(other.adult,other.base+'/bootstrap'));
  const account=deletionReceipt(),noMembership=deletionReceipt();
  ok(await requestChildAccount(f,id,review,account),202);
  ok(await requestChildAccount(unjoined,pendingId,pendingReview,noMembership),202);
  return {member:account.clientKey,unjoined:noMembership.clientKey};
 }});
});

test('fresh joint evidence recovers a withdrawn child account after scheduled enrollment evidence retirement',async()=>{
 const f=await family(),first=await active(f),consent=ok(await call(f.adult,f.base+'/guardian/consents')).consents[0];
 ok(await call(f.adult,f.base+'/guardian/consents/'+consent.consentId+'/revoke','POST',{}));
 // The scheduled job's due-row check is relative to the immutable revocation
 // timestamp. Expire the enrollment evidence just as a completed policy purge does.
 await admin.query('DELETE FROM ritc.guardian_enrollment WHERE household_id=$1 AND enrollment_id=$2',[f.house.householdId,first.setup.enrollmentId]);
 assert.deepEqual(ok(await call(f.adult,f.base+childDeletionPath)),{children:[]});
 const {setup}=await consented(f,{childId:consent.childId});
 const invitation=ok(await call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/child-invitations','POST',{clientKey:randomUUID(),baseRevision:setup.revision,secret:randomBytes(32).toString('base64url')}));
 await coveredNative(f,invitation);
 const review=await reviewChildAccount(f,setup.enrollmentId);
 assert.equal(review.enrollmentId,setup.enrollmentId);
 assert.equal((await admin.query('SELECT 1 FROM ritc.consent WHERE household_id=$1 AND child_id=$2 AND revoked_at IS NULL',[f.house.householdId,consent.childId])).rowCount,0);
});
test('a second household requires independent proof for the same guardian and exact child',async()=>{
 const f=await family(),first=await active(f);
 const otherHouse=ok(await call(f.adult,'/v1/households','POST',{clientKey:randomUUID(),label:'Private second household',alias:'Guardian',adultAttestation:true}),201);
 const base='/v1/households/'+otherHouse.householdId;
 const adult={...f.adult,...ok(await call(f.adult,base+'/devices','POST',{}),201)};
 const second={adult,child:{...f.child},house:otherHouse,base};
 await active(second);
 const list=ok(await call(f.adult,f.base+childDeletionPath));
 assert.deepEqual(list.children,[{enrollmentId:first.setup.enrollmentId,childAlias:'Fictional child'}]);
 const review=await reviewChildAccount(f,first.setup.enrollmentId);
 assert.ok(!JSON.stringify(review).includes(otherHouse.householdId));
 await admin.query("UPDATE ritc.guardian_relationship SET revoked_at=clock_timestamp() WHERE household_id=$1 AND child_id=$2",[otherHouse.householdId,second.child.memberId]);
 assert.deepEqual(ok(await call(f.adult,f.base+childDeletionPath)),{children:[]});
 assert.equal((await requestChildAccount(f,first.setup.enrollmentId,review)).status,404);
});

test('private guardian case intake, receipt, operator transitions and erasure never initiate provider deletion',async()=>{
 const f=await family(),state=await active(f),enrollmentId=state.setup.enrollmentId;
 const manual=f.base+childDeletionPath+'/manual-reviews',body={enrollmentId,clientKey:randomUUID(),childSignInEmail:f.child.email,confirm:true};
 const other=await actor(),secondGuardian=randomUUID();
 await admin.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer) VALUES($1,$2,$3,$4,'Other','adult','active',false)",[f.house.householdId,secondGuardian,issuer,other.subject]);
 await admin.query('INSERT INTO ritc.guardian_relationship(household_id,child_id,guardian_id,proof_ref) VALUES($1,$2,$3,$4)',[f.house.householdId,state.receipt.memberId,secondGuardian,'fixture']);
 assert.deepEqual(ok(await call(f.adult,f.base+childDeletionPath)),{children:[]});
 assert.deepEqual(ok(await call(f.adult,manual)),{available:true,children:[{enrollmentId,childAlias:'Fictional child',identityState:'confirmed'}],requests:[]});
 assert.equal((await call(f.adult,manual,'POST',{...body,childSignInEmail:other.email})).status,404);
 await freshAuth(f.adult,'otp',301);assert.equal((await call(f.adult,manual,'POST',body)).status,401);await freshAuth(f.adult);
 const receipt=ok(await call(f.adult,manual,'POST',body),202);
 assert.deepEqual(Object.keys(receipt).sort(),['requestId','status','createdAt','updatedAt','expiresAt'].sort());
 assert.equal(receipt.requestId,body.clientKey);assert.equal(receipt.status,'received');
 assert.deepEqual(ok(await call(f.adult,manual,'POST',body),202),receipt);
 assert.equal((await call(f.adult,manual,'POST',{...body,clientKey:randomUUID()})).data.error.code,'review_already_requested');
 const secondDevice={...other,...ok(await call(other,f.base+'/devices','POST',{}),201)};
 assert.deepEqual(ok(await call(secondDevice,manual)),{available:true,children:[],requests:[]});
 assert.equal((await call(secondDevice,manual,'POST',body)).status,404);
 await assert.rejects(app.query('SELECT * FROM ritc.guardian_case_queue(5)'),error=>error.code==='42501');
 await assert.rejects(app.query('SELECT * FROM ritc.guardian_deletion_case'),error=>error.code==='42501');
 const operator=await admin.connect();
 try{
   await operator.query('BEGIN');await operator.query('SET LOCAL ROLE ritc_guardian_case_reviewer');
   const queue=(await operator.query('SELECT * FROM ritc.guardian_case_queue(100)')).rows;
   assert.ok(queue.some(item=>item.request_id===body.clientKey));assert.ok(!JSON.stringify(queue).includes(f.child.email));
   assert.equal((await operator.query("SELECT ritc.guardian_case_update($1,'received','in_review') AS updated",[body.clientKey])).rows[0].updated,true);
   await operator.query('COMMIT');
 }finally{await operator.query('ROLLBACK');operator.release();}
 assert.equal(ok(await call(f.adult,manual)).requests[0].status,'in_review');
 const disabled=new GuardianEnrollmentService(repo,{emailDigestKey:guardian.options.emailDigestKey});
 const auth={identity:await verifier.verify(f.adult.token),deviceToken:f.adult.deviceToken};
 const list=await repo.authorized(f.house.householdId,auth,ctx=>disabled.manualDeletionCases(ctx,auth.identity));
 assert.equal(list.available,false);assert.equal(list.requests[0].status,'in_review');assert.deepEqual(list.children,[]);
 await assert.rejects(repo.authorized(f.house.householdId,auth,ctx=>disabled.openManualDeletionCase(ctx,auth.identity,body)),e=>e.code==='manual_review_unavailable');
 assert.equal((await admin.query('SELECT 1 FROM ritc.privacy_job WHERE subject=$1',[f.child.subject])).rowCount,0);
 // Resolve the competing relationship, then independently authorize deletion.
 await admin.query('UPDATE ritc.guardian_relationship SET revoked_at=clock_timestamp() WHERE household_id=$1 AND child_id=$2 AND guardian_id=$3',[f.house.householdId,state.receipt.memberId,secondGuardian]);
 const review=await reviewChildAccount(f,enrollmentId),receiptInput=deletionReceipt();
 ok(await requestChildAccount(f,enrollmentId,review,receiptInput),202);
 await deferProfileOnlyDeletion(admin,receiptInput.clientKey);
 assert.deepEqual(ok(await call(f.adult,manual)).requests,[]);
});

test('provider signup interrupted before child admission opens only an enrollment investigation',async()=>{
 const f=await family();
 const newEmail='abandoned-'+randomUUID()+'@fixture.invalid',providerSubject=randomUUID();
 f.child={email:newEmail};
 const {setup}=await consented(f),enrollmentId=setup.enrollmentId;
 const url=f.base+childDeletionPath+'/manual-reviews';
 const input={clientKey:randomUUID(),enrollmentId,childSignInEmail:newEmail,confirm:true};
 const invitation=ok(await call(f.adult,f.base+'/guardian/enrollments/'+enrollmentId+'/child-invitations','POST',{clientKey:randomUUID(),baseRevision:setup.revision,secret:randomBytes(32).toString('base64url')}));
 assert.deepEqual(ok(await call(f.adult,url)).children,[]);
 assert.equal((await call(f.adult,url,'POST',input)).status,404);
 pendingSignupFixture.set(newEmail,providerSubject);
 ok(await call(null,'/v1/child-invitations/native-auth/start','POST',{clientKey:randomUUID(),token:invitation.token,email:newEmail,challengeSecret:randomBytes(32).toString('base64url')}));
 assert.equal((await admin.query('SELECT 1 FROM auth.users WHERE id=$1',[providerSubject])).rowCount,1);
 assert.equal((await admin.query('SELECT 1 FROM ritc.guardian_child_principal WHERE provider_user=$1',[providerSubject])).rowCount,0);
 assert.deepEqual(ok(await call(f.adult,f.base+childDeletionPath)).children,[]);
 assert.equal((await call(f.adult,f.base+childDeletionPath+'/review','POST',{enrollmentId,childSignInEmail:newEmail})).status,404);
 assert.deepEqual(ok(await call(f.adult,url)).children,[{enrollmentId,childAlias:'Fictional child',identityState:'unmatched'}]);
 assert.equal((await call(f.adult,url,'POST',{...input,childSignInEmail:f.adult.email})).status,404);
 const receipt=ok(await call(f.adult,url,'POST',input),202);
 assert.deepEqual(ok(await call(f.adult,url,'POST',input),202),receipt);
 assert.ok(Math.abs(Date.parse(receipt.expiresAt)-Date.parse(receipt.createdAt)-2*86400000)<1000);
 const row=(await admin.query('SELECT * FROM ritc.guardian_deletion_case WHERE request_id=$1',[receipt.requestId])).rows[0];
 assert.equal(row.child_hash,null);assert.ok(!JSON.stringify(row).includes(newEmail));assert.ok(!JSON.stringify(row).includes(providerSubject));
 assert.equal((await admin.query('SELECT 1 FROM ritc.privacy_job WHERE subject=$1',[providerSubject])).rowCount,0);
 await admin.query('DELETE FROM ritc.guardian_enrollment WHERE household_id=$1 AND enrollment_id=$2',[f.house.householdId,enrollmentId]);
 assert.deepEqual(ok(await call(f.adult,url)),{available:true,children:[],requests:[]});
 assert.equal((await admin.query('SELECT 1 FROM auth.users WHERE id=$1',[providerSubject])).rowCount,1);
});
test('whole child account deletion reaches completion for a withdrawn profile and an interrupted child sign-in',async()=>{
 const worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL});
 const originalNotices=guardian.options.notices;
 try{
  for(const [paired,country] of [[true,'US'],[false,'US'],[true,'MX']]){
   const reviewNotice=country==='MX'?mexicoNotices[1]:notices[0];
   guardian.options.notices=country==='MX'?mexicoNotices:notices;
   const f=await family();
   let enrollmentId;
   if(paired){
    const state=await active(f,{childLocation:country,language:reviewNotice.locale,
     noticeVersion:reviewNotice.version,noticeDigest:reviewNotice.digest});
    enrollmentId=state.setup.enrollmentId;
    const consent=ok(await call(f.adult,f.base+'/guardian/consents')).consents[0];
    ok(await call(f.adult,f.base+'/guardian/consents/'+consent.consentId+'/revoke','POST',{}));
    assert.equal((await admin.query('SELECT 1 FROM ritc.privacy_job WHERE subject=$1',[f.child.subject])).rowCount,0);
   }else{
    const {setup}=await consented(f);enrollmentId=setup.enrollmentId;
    const invitation=ok(await call(f.adult,f.base+'/guardian/enrollments/'+enrollmentId+'/child-invitations','POST',{clientKey:randomUUID(),baseRevision:setup.revision,secret:randomBytes(32).toString('base64url')}));
    assert.deepEqual(ok(await call(f.adult,f.base+childDeletionPath)),{children:[]});
    await coveredNative(f,invitation);
    assert.equal((await admin.query("SELECT 1 FROM ritc.member WHERE household_id=$1 AND kind='child'",[f.house.householdId])).rowCount,0);
   }
   const candidates=ok(await call(f.adult,f.base+childDeletionPath));
   assert.deepEqual(candidates,{children:[{enrollmentId,childAlias:'Fictional child'}]});
   expectedChildDeletes.add(f.child.subject);
   const adultSelf=await call(f.child,'/v1/privacy/deletions','POST',{...deletionReceipt(),households:[]});
   assert.equal(adultSelf.status,404);
   const review=await reviewChildAccount(f,enrollmentId);
   assert.deepEqual(Object.keys(review).sort(),['enrollmentId','childAlias','expiresAt','reviewId','verifiedBackupRetentionDays'].sort());
   const receipt=deletionReceipt(),accepted=ok(await requestChildAccount(f,enrollmentId,review,receipt),202);
   assert.equal(accepted.status,'pending');
   const status='/v1/privacy/jobs/'+receipt.clientKey;
   assert.equal((await call(null,status,'GET',undefined,{'x-deletion-token':deletionReceipt().statusToken})).status,404);
   assert.deepEqual(ok(await call(null,status,'GET',undefined,{'x-deletion-token':receipt.statusToken})),accepted);
   const runner=new PrivacyMaintenance(worker,{provider:childProvider,journal:journal.port,issuer});
   assert.equal((await runner.run({batchSize:1})).completed,1);
   const done=ok(await call(null,status,'GET',undefined,{'x-deletion-token':receipt.statusToken}));
   assert.equal(done.status,'complete');assert.equal(done.providerAccountDeleted,true);
   assert.equal((await admin.query('SELECT 1 FROM auth.users WHERE id=$1',[f.adult.subject])).rowCount,1);
   ok(await call(f.adult,f.base+'/bootstrap'));
  }
 }finally{guardian.options.notices=originalNotices;await worker.end();}
});

test('child account reviews require recent actual guardian, exact child email, current device and unchanged authority',async()=>{
 const f=await family(),state=await active(f),id=state.setup.enrollmentId;
 const reviewPath=f.base+childDeletionPath+'/review',body={enrollmentId:id,childSignInEmail:f.child.email};
 const foreign=await family();
 assert.equal((await call(foreign.adult,foreign.base+childDeletionPath+'/review','POST',body)).status,404);
 assert.equal((await call(f.child,reviewPath,'POST',body)).status,404);
 assert.equal((await call(f.adult,reviewPath,'POST',{...body,childSignInEmail:foreign.child.email})).status,404);
 assert.equal((await call(f.adult,reviewPath,'POST',{...body,targetSubject:f.child.subject})).status,422);
 await freshAuth(f.adult,'otp',301);
 assert.equal((await call(f.adult,reviewPath,'POST',body)).data.error.code,'reauthentication_required');
 await freshAuth(f.adult);
 const old=await reviewChildAccount(f,id),review=await reviewChildAccount(f,id);
 assert.equal((await requestChildAccount(f,id,old)).status,404);
 const sibling=ok(await call(f.adult,f.base+'/devices','POST',{}),201);
 assert.equal((await requestChildAccount({...f,adult:{...f.adult,...sibling}},id,review)).status,404);
 await admin.query("UPDATE ritc.guardian_child_deletion_review SET expires_at=now()-interval '1 second' WHERE review_id=$1",[review.reviewId]);
 assert.equal((await requestChildAccount(f,id,review)).status,404);
 const renewed=await reviewChildAccount(f,id);
 await admin.query('UPDATE auth.users SET email=$1 WHERE id=$2',[foreign.child.email,f.child.subject]);
 assert.equal((await requestChildAccount(f,id,renewed)).status,404);
 await admin.query('UPDATE auth.users SET email=$1 WHERE id=$2',[f.child.email,f.child.subject]);
 const other=await actor();
 const otherId=randomUUID();
 await admin.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer) VALUES($1,$2,$3,$4,'Second guardian','adult','active',false)",[f.house.householdId,otherId,issuer,other.subject]);
 await admin.query('INSERT INTO ritc.guardian_relationship(household_id,child_id,guardian_id,proof_ref) VALUES($1,$2,$3,$4)',[f.house.householdId,state.receipt.memberId,otherId,'fixture']);
 assert.deepEqual(ok(await call(f.adult,f.base+childDeletionPath)),{children:[]});
 assert.equal((await requestChildAccount(f,id,renewed)).status,404);
 assert.equal((await admin.query('SELECT 1 FROM ritc.privacy_job WHERE subject=$1',[f.child.subject])).rowCount,0);
 await assert.rejects(app.query('SELECT * FROM ritc.guardian_deletion_admission'),error=>error.code==='42501');
 await assert.rejects(app.query('SELECT * FROM ritc.guardian_child_deletion_review'),error=>error.code==='42501');
});
