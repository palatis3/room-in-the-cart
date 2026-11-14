import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes,createHmac} from 'node:crypto';
import pg from 'pg';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {GuardianEnrollmentService} from '../dist/guardian.js';
import {KWSWebhookVerifier} from '../dist/guardian-provider.js';
import {createHTTPServer} from '../dist/http.js';
import {BrowserAuthService} from '../dist/browser-auth.js';
import {guardianRuntime} from '../dist/guardian-runtime.js';
import {createRuntime,databaseConfiguration} from '../dist/runtime.js';
import {createOperationsHTTPServer} from '../dist/operations-http.js';
import {tokenHash} from '../dist/database.js';
import {PrivacyService} from '../dist/privacy.js';
import {deferProfileOnlyDeletion,openPrivacyJournalFixture} from './privacy-journal-fixture.mjs';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),app=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),proof=new pg.Pool({connectionString:process.env.TEST_GUARDIAN_VERIFIER_DATABASE_URL});
const journal=await openPrivacyJournalFixture(admin);
const privacyProvider={assertAvailable:async()=>{},deleteAccount:async()=>{throw Error('Profile-only fixture must not call provider');}};
const privacyPolicy={receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1};
const issuer='https://guardian.fixture.invalid',audience='authenticated';const {publicKey,privateKey}=await generateKeyPair('ES256');const jwk=await exportJWK(publicKey);jwk.kid='guardian-fixture';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]}));
const config={organizationId:randomUUID(),scope:'product',productId:randomUUID(),environment:'test'},signing='local-fixture-only-signing-secret';
const notices=['en','es'].map(locale=>({locale,version:'fixture-reviewed-v1',methodVersion:'fixture-method-v1',scope:'own_requests',text:'Fictional reviewed notice '+locale,digest:tokenHash('Fictional reviewed notice '+locale),approvalReference:'fixture-only-not-legal-approval'}));
const requests=[],otpRequests=[],otpActors=new Map();let failDelivery=false,holdVerify;
const otpProvider={async start(email){otpRequests.push(email);},async verify(email,code){if(holdVerify)await holdVerify();if(code!=='123456'||!otpActors.has(email))throw new Error('fixture code');await freshAuth(otpActors.get(email));return{accessToken:otpActors.get(email).token,refreshToken:'fixture-refresh'};},async refresh(){throw new Error('unused');},async logout(){}};
const gateway={kind:'fixture',configuration:config,async start(input){requests.push(input);if(failDelivery)throw new Error('lost fictional reply');}};
const repo=new HouseholdRepository(app,{allowChildNetwork:true,noticeVersion:notices[0].version,sessionStatus:new SupabaseSessionVerifier(issuer)});
const guardian=new GuardianEnrollmentService(repo,{gateway,webhookVerifier:new KWSWebhookVerifier(config,[signing]),verifierPool:proof,emailDigestKey:randomBytes(32).toString('base64url'),notices,retentionPolicy:{pendingHours:1,evidenceDays:1,approvalReference:'fictional-policy'}});
const bff=new BrowserAuthService(repo,verifier,otpProvider,{encryptionKey:randomBytes(32).toString('base64'),childSignin:guardian});guardian.attachChildSignin(bff,otpProvider);
const webOrigin='https://guardian.web.fixture.invalid';
const server=createHTTPServer({repository:repo,verifier,guardian,browserAuth:bff,webOrigin,maxRequestsPerMinute:10000});let origin;
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
async function coveredNative(f,invitation){const input={clientKey:randomUUID(),token:invitation.token,email:f.child.email,challengeSecret:randomBytes(32).toString('base64url')};const challenge=ok(await call(null,'/v1/child-invitations/native-auth/start','POST',input));await freshAuth(f.child);const admit={clientKey:randomUUID(),householdId:challenge.householdId,challengeId:challenge.challengeId,challengeSecret:input.challengeSecret};ok(await call(f.child,'/v1/child-invitations/native-auth/admit','POST',admit));return{input,challenge,admit};}
async function claimed(f,extra={}){const {setup}=await consented(f,extra),invitationInput={clientKey:randomUUID(),baseRevision:setup.revision,secret:randomBytes(32).toString('base64url')};const invitation=ok(await call(f.adult,f.base+'/guardian/enrollments/'+setup.enrollmentId+'/child-invitations','POST',invitationInput));await coveredNative(f,invitation);const input={clientKey:randomUUID(),token:invitation.token,pairingCode:'ABCD2345'};const claim=ok(await call(f.child,'/v1/child-invitations/claim','POST',input));return{setup:await read(f,setup.enrollmentId),claim,invitation,input,invitationInput};}
async function active(f,extra={}){let state=await claimed(f,extra);const confirm={clientKey:randomUUID(),baseRevision:state.setup.revision,claimId:state.claim.claimId,pairingCode:state.input.pairingCode};state.setup=ok(await call(f.adult,f.base+'/guardian/enrollments/'+state.setup.enrollmentId+'/confirm-child','POST',confirm));const finish={clientKey:randomUUID(),householdId:f.house.householdId,claimId:state.claim.claimId,pairingCode:state.input.pairingCode,deviceSecret:randomBytes(32).toString('base64url')};const receipt=ok(await call(f.child,'/v1/child-invitations/finish','POST',finish));Object.assign(f.child,receipt);return{...state,confirm,finish,receipt};}

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
test('enrolled child submits only own request and never receives basket, budget, roster or another author request',async()=>{
 const f=await family();await active(f);const adultWindow=ok(await call(f.adult,f.base+'/replay-windows','POST',{})),shopId=randomUUID();const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:3800,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+3_600_000).toISOString()};
 ok(await call(f.adult,f.base+'/commands','POST',{v:1,replayWindow:adultWindow.id,clientKey:randomUUID(),shopId,kind:'shop.create',base:{shopRevision:0,authorityEpoch:0},body:{quote,lines:[]}}));const childWindow=ok(await call(f.child,f.base+'/replay-windows','POST',{}));
 for(const [person,window,item]of [[f.adult,adultWindow,'Private adult item'],[f.child,childWindow,'Own child item']])ok(await call(person,f.base+'/commands','POST',{v:1,replayWindow:window.id,clientKey:randomUUID(),shopId,kind:'request.send',base:{shopRevision:0,authorityEpoch:0},body:{clientRequestId:randomUUID(),originalItem:item,ownQuantity:'one',authoredAt:new Date().toISOString()}}));
 const own=ok(await call(f.child,f.base+'/requests/mine'));assert.equal(own.requests.length,1);assert.equal(own.requests[0].originalItem,'Own child item');const raw=JSON.stringify(own);for(const forbidden of ['Private adult item','capMinor','unitPrice','budget','guardian','parentEmail'])assert.ok(!raw.includes(forbidden));
 for(const route of ['/members','/shops/'+shopId,'/shops/'+shopId+'/inbox','/guardian/consents'])assert.equal((await call(f.child,f.base+route)).status,404);
});

test('trusted finish and pending-child identity deletion serialize in both deterministic lock orders',async t=>{
 for(const ordering of ['finish_first','deletion_first']){
  const f=await family(),state=await claimed(f);ok(await call(f.adult,f.base+'/guardian/enrollments/'+state.setup.enrollmentId+'/confirm-child','POST',{clientKey:randomUUID(),baseRevision:state.setup.revision,claimId:state.claim.claimId,pairingCode:state.input.pairingCode}));
  const details=(await admin.query('SELECT c.pairing_hash,a.email_digest FROM ritc.guardian_child_claim c JOIN ritc.guardian_child_invitation v USING(household_id,invite_id) JOIN ritc.guardian_attempt a USING(household_id,enrollment_id) WHERE c.household_id=$1 AND c.claim_id=$2',[f.house.householdId,state.claim.claimId])).rows[0];
  const lock=await admin.connect(),trusted=await proof.connect(),deleting=await app.connect();let finalizing,deletion;
  try{
   await lock.query('BEGIN');await lock.query('SELECT 1 FROM ritc.household WHERE household_id=$1 FOR UPDATE',[f.house.householdId]);await trusted.query('BEGIN');await trusted.query("SELECT set_config('app.household_id',$1,true)",[f.house.householdId]);
   const trustedPID=(await trusted.query('SELECT pg_backend_pid() pid')).rows[0].pid,deletePID=(await deleting.query('SELECT pg_backend_pid() pid')).rows[0].pid;
   const finish=()=>trusted.query('SELECT ritc.guardian_finish_verified($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) receipt',[f.house.householdId,state.claim.claimId,issuer,f.child.subject,f.child.session,details.pairing_hash,details.email_digest,randomUUID(),tokenHash(randomUUID()),randomUUID(),tokenHash(randomUUID()),f.adult.email,f.child.email]);
   const pinnedClient={query:deleting.query.bind(deleting),release(){}};const deletionRepo=new HouseholdRepository({connect:async()=>pinnedClient,query:deleting.query.bind(deleting)},{allowChildNetwork:true,noticeVersion:notices[0].version,sessionStatus:new SupabaseSessionVerifier(issuer)});
   const deletionService=new PrivacyService(deletionRepo,{provider:privacyProvider,policy:privacyPolicy,journal:journal.port});const deletionIdentity=await verifier.verify(f.child.token),deletionInput={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[]};
   t.after(()=>deferProfileOnlyDeletion(admin,deletionInput.clientKey));
   const erase=()=>deletionService.request(deletionIdentity,deletionInput).then(value=>({accepted:true,value}),error=>({accepted:false,error}));
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
