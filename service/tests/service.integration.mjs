import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {randomUUID} from 'node:crypto';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {migrate} from '../scripts/migrate.mjs';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {createHTTPServer} from '../dist/http.js';
import {assertRuntimeRole} from '../dist/database.js';
import {BillingService} from '../dist/billing/service.js';
const runtimeURL=process.env.TEST_DATABASE_URL,adminURL=process.env.TEST_ADMIN_DATABASE_URL;
if(!runtimeURL||!adminURL)throw new Error('Real PostgreSQL tests require TEST_DATABASE_URL and TEST_ADMIN_DATABASE_URL; they are never replaced by an in-memory mock.');
const admin=new pg.Pool({connectionString:adminURL}),runtime=new pg.Pool({connectionString:runtimeURL,max:12});
const issuer='https://identity.fixture.invalid',audience='authenticated';
const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='fixture-1';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]}));
const repo=new HouseholdRepository(runtime,{allowChildNetwork:true,noticeVersion:'fixture-notice-v1',sessionStatus:new SupabaseSessionVerifier(issuer)});
const server=createHTTPServer({repository:repo,verifier,billing:new BillingService(null),webOrigin:'https://web.fixture.invalid',maxRequestsPerMinute:10000});
let origin;
before(async()=>{await admin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');await migrate(adminURL);await assertRuntimeRole(runtime);await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;});
after(async()=>{await new Promise(resolve=>server.close(resolve));await Promise.all([runtime.end(),admin.end()]);});
async function fixture() {
  const h=randomUUID(),shopId=randomUUID(),lineId=randomUUID(),actors={};
  const c=await admin.connect();try{
    await c.query('BEGIN');await c.query('INSERT INTO ritc.household(household_id,label) VALUES($1,$2)',[h,'Fictional household']);
    for(const name of ['Mia','Alex','Sam','Jo']) {
      const id=randomUUID(),session=randomUUID(),subject=randomUUID(),kind=['Sam','Jo'].includes(name)?'child':'adult';
      await c.query('INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute) VALUES($1,$2,$3,$4,$5,$6,\'active\',$7,true)',[h,id,issuer,subject,name,kind,name==='Mia']);
      const token=await new SignJWT({session_id:session}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(subject).setIssuedAt().setExpirationTime('1h').sign(privateKey);
      await c.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);
      actors[name]={id,token,subject,session};
    }
    for(const name of ['Sam','Jo']) {
      await c.query('INSERT INTO ritc.guardian_relationship(household_id,child_id,guardian_id,proof_ref) VALUES($1,$2,$3,$4)',[h,actors[name].id,actors.Mia.id,'fictional-provider-proof']);
      await c.query('INSERT INTO ritc.consent(household_id,consent_id,child_id,guardian_id,notice_version,verification_ref) VALUES($1,$2,$3,$4,$5,$6)',[h,randomUUID(),actors[name].id,actors.Mia.id,'fixture-notice-v1','fictional-provider-consent']);
    }
    await c.query('COMMIT');
  }catch(e){await c.query('ROLLBACK');throw e;}finally{c.release();}
  const path='/v1/households/'+h;
  async function http(actor,method,tail,value,extra={}) {
    const a=typeof actor==='string'?actors[actor]:actor;
    const response=await fetch(origin+(tail.startsWith('/v1/')?tail:path+tail),{method,headers:{Authorization:'Bearer '+a.token,...(a.deviceToken?{'X-Device-Token':a.deviceToken}:{}),...(value===undefined?{}:{'Content-Type':'application/json'}),...extra},...(value===undefined?{}:{body:JSON.stringify(value)})});
    return{status:response.status,data:await response.json(),headers:response.headers};
  }
  for(const actor of Object.values(actors)) {
    const device=await http(actor,'POST','/devices',{});assert.equal(device.status,201,JSON.stringify(device.data));actor.deviceToken=device.data.deviceToken;actor.deviceId=device.data.deviceId;
    const window=await http(actor,'POST','/replay-windows',{});assert.equal(window.status,200);actor.window=window.data.id;
  }
  const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:3800,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date(Date.now()-60_000).toISOString(),expiresAt:new Date(Date.now()+3_600_000).toISOString()};
  const line={lineId,originalItem:'Original basket',packs:1,unitPriceMinor:3720,feeEligible:true};
  function envelope(actor,kind,body,base={shopRevision:1,authorityEpoch:1},key=randomUUID()){return{v:1,replayWindow:actors[actor].window,clientKey:key,shopId,kind,base,body};}
  async function command(actor,kind,body,base,key){return http(actor,'POST','/commands',envelope(actor,kind,body,base,key));}
  const created=await command('Mia','shop.create',{quote,lines:[line]},{shopRevision:0,authorityEpoch:0});assert.equal(created.status,200,JSON.stringify(created.data));
  async function send(actor='Sam',extra={}){const payload={clientRequestId:randomUUID(),originalItem:'Fictional cereal',ownQuantity:'one box',authoredAt:new Date().toISOString(),...extra};const c=envelope(actor,'request.send',payload,{shopRevision:0,authorityEpoch:0});const response=await http(actor,'POST','/commands',c);assert.equal(response.status,200,JSON.stringify(response.data));return{...response.data,envelope:c};}
  async function preview(request,decision={choice:'add',line:{lineId:randomUUID(),originalItem:'Fictional cereal',packs:1,unitPriceMinor:349,feeEligible:true},promote:false},actor='Mia',base={shopRevision:1,authorityEpoch:1,requestRevision:request.revision}) {
    return http(actor,'POST','/shops/'+shopId+'/previews',{requestId:request.requestId,base,decision});
  }
  return{h,shopId,lineId,line,quote,actors,http,envelope,command,send,preview};
}

test('real JWT auth denies missing, forged, expired, wrong issuer and wrong audience tokens',async()=>{
  const f=await fixture();
  assert.equal((await fetch(origin+'/v1/me/workspaces')).status,401);
  for(const claims of [{iss:'https://wrong.invalid',aud:audience,exp:'1h'},{iss:issuer,aud:'wrong',exp:'1h'},{iss:issuer,aud:audience,exp:'-1h'}]) {
    const token=await new SignJWT({session_id:randomUUID()}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(claims.iss).setAudience(claims.aud).setSubject(f.actors.Mia.subject).setIssuedAt().setExpirationTime(claims.exp).sign(privateKey);
    assert.equal((await f.http({token},'GET','/bootstrap')).status,401);
  }
  assert.equal((await f.http({token:f.actors.Mia.token.slice(0,-2)+'zz'},'GET','/bootstrap')).status,401);
});
test('whole checkout recompute requires explicit $2.69 overage approval; exact retry applies once',async()=>{
  const f=await fixture(),sent=await f.send(),p=await f.preview(sent.request);assert.equal(p.status,200);
  assert.equal(p.data.before.totalMinor,3720);assert.equal(p.data.after.totalMinor,4069);assert.equal(p.data.after.overCapMinor,269);
  const c=f.envelope('Mia','request.apply',{requestId:sent.request.requestId,previewId:p.data.previewId,acceptOverage:false,acceptUnknown:false},{shopRevision:1,authorityEpoch:1,requestRevision:1});
  let r=await f.http('Mia','POST','/commands',c);assert.equal(r.data.error.code,'overage_acceptance_required');
  const count=await admin.query('SELECT count(*)::int AS count FROM ritc.basket_line WHERE household_id=$1',[f.h]);assert.equal(count.rows[0].count,1);
  c.body.acceptOverage=true;r=await f.http('Mia','POST','/commands',c);assert.equal(r.status,200,JSON.stringify(r.data));
  const duplicate=await f.http('Mia','POST','/commands',c);assert.deepEqual(duplicate.data,r.data);
  const state=await f.http('Mia','GET','/shops/'+f.shopId);assert.equal(state.data.shopRevision,2);assert.equal(state.data.lines.length,2);
  c.body.acceptUnknown=true;assert.equal((await f.http('Mia','POST','/commands',c)).data.error.code,'key_reused');
  const own=await f.http('Sam','GET','/requests/mine');assert.equal(own.data.requests[0].status,'added');assert.equal(own.data.requests[0].shopId,f.shopId);
  assert.deepEqual(Object.keys(own.data.requests[0]).sort(),['requestId','shopId','revision','originalItem','ownQuantity','authoredAt','receivedAt','route','status','ownActionAllowed','clarification','followupTo'].sort());
});
test('known foreign IDs cannot cross tenant or author boundaries, including a child preview',async()=>{
  const a=await fixture(),b=await fixture(),sent=await a.send('Jo');
  assert.equal((await a.http(b.actors.Mia,'GET','/shops/'+a.shopId)).status,404);
  assert.equal((await a.http('Sam','GET','/shops/'+a.shopId+'/inbox')).status,404);
  assert.equal((await a.preview(sent.request,undefined,'Sam')).status,404);
  assert.equal((await a.command('Sam','request.edit',{requestId:sent.request.requestId,originalItem:'Changed',ownQuantity:'2'},{shopRevision:0,authorityEpoch:0,requestRevision:1})).status,404);
  const own=await a.http('Sam','GET','/requests/mine');assert.deepEqual(own.data.requests,[]);
  const workspaces=await a.http('Mia','GET','/v1/me/workspaces');assert.deepEqual(workspaces.data.workspaces.map(w=>w.householdId),[a.h]);
});
test('revocation blocks prior success replay and child consent cannot be resurrected',async()=>{
  const f=await fixture(),sent=await f.send();
  await admin.query('UPDATE ritc.consent SET revoked_at=now() WHERE household_id=$1 AND child_id=$2',[f.h,f.actors.Sam.id]);
  assert.equal((await f.http('Sam','POST','/commands',sent.envelope)).status,403);
  await assert.rejects(admin.query('UPDATE ritc.consent SET revoked_at=NULL WHERE household_id=$1 AND child_id=$2',[f.h,f.actors.Sam.id]));
});
test('replay window expiry and compacted receipt never recreate a command',async()=>{
  const f=await fixture(),sent=await f.send();
  await admin.query('DELETE FROM ritc.operation_response WHERE household_id=$1 AND operation_id=$2',[f.h,sent.operationId]);
  assert.equal((await f.http('Sam','POST','/commands',sent.envelope)).data.error.code,'refresh_required');
  sent.envelope.body.originalItem='Changed';assert.equal((await f.http('Sam','POST','/commands',sent.envelope)).data.error.code,'refresh_required');
  await admin.query("UPDATE ritc.replay_window SET issued_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE household_id=$1 AND window_id=$2",[f.h,f.actors.Jo.window]);
  const c=f.envelope('Jo','request.send',{clientRequestId:randomUUID(),originalItem:'Fixture',ownQuantity:null,authoredAt:new Date().toISOString()},{shopRevision:0,authorityEpoch:0});
  assert.equal((await f.http('Jo','POST','/commands',c)).data.error.code,'refresh_required');
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.request WHERE household_id=$1',[f.h])).rows[0].n,1);
});
test('simultaneous exact retries and competing approvals conserve lines and revisions',async()=>{
  const f=await fixture(),sent=await f.send(),p=await f.preview(sent.request);
  const c=f.envelope('Mia','request.apply',{requestId:sent.request.requestId,previewId:p.data.previewId,acceptOverage:true,acceptUnknown:false},{shopRevision:1,authorityEpoch:1,requestRevision:1});
  const results=await Promise.all([f.http('Mia','POST','/commands',c),f.http('Mia','POST','/commands',c)]);assert.equal(results[0].status,200);assert.deepEqual(results[0].data,results[1].data);
  const competing=await f.http('Mia','POST','/commands',{...c,clientKey:randomUUID()});assert.equal(competing.status,409);
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.request_link WHERE household_id=$1',[f.h])).rows[0].n,1);
});
test('request edit invalidates preview; deferral preserves basket and routes obligation next',async()=>{
  const f=await fixture(),sent=await f.send(),p=await f.preview(sent.request);
  assert.equal((await f.command('Sam','request.edit',{requestId:sent.request.requestId,originalItem:'Two cereal boxes',ownQuantity:'two boxes'},{shopRevision:0,authorityEpoch:0,requestRevision:1})).status,200);
  assert.equal((await f.command('Mia','request.apply',{requestId:sent.request.requestId,previewId:p.data.previewId,acceptOverage:true,acceptUnknown:false},{shopRevision:1,authorityEpoch:1,requestRevision:1})).data.error.code,'stale_preview');
  const fresh=await f.preview({...sent.request,revision:2},{choice:'defer'});assert.equal(fresh.status,200);
  const d=await f.command('Mia','request.apply',{requestId:sent.request.requestId,previewId:fresh.data.previewId,acceptOverage:false,acceptUnknown:false},{shopRevision:1,authorityEpoch:1,requestRevision:2});assert.equal(d.status,200);assert.equal(d.data.shopRevision,1);
  const mine=await f.http('Sam','GET','/requests/mine');assert.equal(mine.data.requests[0].status,'deferred');assert.equal(mine.data.requests[0].route,'next');
});
test('freeze survives authority transfer and stale placement is preserved without closing the new shop',async()=>{
  const f=await fixture(),sent=await f.send();
  assert.equal((await f.command('Mia','shop.freeze',{})).status,200);
  assert.equal((await f.command('Mia','shop.transferAuthority',{newShopperId:f.actors.Alex.id},{shopRevision:2,authorityEpoch:1})).status,200);
  const late=await f.send('Jo');assert.equal(late.request.route,'next');
  const report=await f.command('Mia','shop.reportPlaced',{occurredAt:new Date().toISOString()},{shopRevision:2,authorityEpoch:1});assert.equal(report.status,200);assert.equal(report.data.disposition,'pending_reconciliation');assert.equal('shopRevision'in report.data,false);
  let shop=await f.http('Alex','GET','/shops/'+f.shopId);assert.equal(shop.data.phase,'frozen');assert.equal(shop.data.shopRevision,2);assert.equal(shop.data.authorityEpoch,2);
  const applied=await f.command('Alex','shop.reconcileReport',{reportId:report.data.reportId,choice:'apply'},{shopRevision:2,authorityEpoch:2});assert.equal(applied.status,200,JSON.stringify(applied.data));
  shop=await f.http('Alex','GET','/shops/'+f.shopId);assert.equal(shop.data.phase,'placed');assert.equal(shop.data.placedRevision,2);
  assert.equal((await f.http('Sam','GET','/requests/mine')).data.requests[0].route,'next');
  await assert.rejects(admin.query("UPDATE ritc.shop_snapshot SET snapshot='{}' WHERE household_id=$1",[f.h]));
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.placement_report WHERE household_id=$1',[f.h])).rows[0].n,1);
});
test('SQL exception at event insert rolls back basket, operation and request mutation together',async()=>{
  const f=await fixture(),sent=await f.send(),p=await f.preview(sent.request);
  const functionName='failure_'+f.h.replaceAll('-','');
  await admin.query(`CREATE FUNCTION ritc.${functionName}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.household_id='${f.h}'::uuid THEN RAISE EXCEPTION 'injected fixture failure'; END IF; RETURN NEW; END $$`);
  await admin.query(`CREATE TRIGGER ${functionName} BEFORE INSERT ON ritc.event FOR EACH ROW EXECUTE FUNCTION ritc.${functionName}()`);
  const c=f.envelope('Mia','request.apply',{requestId:sent.request.requestId,previewId:p.data.previewId,acceptOverage:true,acceptUnknown:false},{shopRevision:1,authorityEpoch:1,requestRevision:1});
  try{assert.equal((await f.http('Mia','POST','/commands',c)).status,503);}finally{await admin.query(`DROP TRIGGER ${functionName} ON ritc.event; DROP FUNCTION ritc.${functionName}()`);}
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.basket_line WHERE household_id=$1',[f.h])).rows[0].n,1);
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.operation WHERE household_id=$1 AND client_key=$2',[f.h,c.clientKey])).rows[0].n,0);
  assert.equal((await f.http('Sam','GET','/requests/mine')).data.requests[0].status,'pending');
  assert.equal((await f.http('Mia','POST','/commands',c)).status,200);
});
test('BFF cookie is HttpOnly, CSRF required, logout revokes protected reads; no tokens in JSON',async()=>{
  const f=await fixture();const login=await f.http('Sam','POST','/v1/session',{householdId:f.h},{Origin:'https://web.fixture.invalid'});assert.equal(login.status,200);
  const header=login.headers.get('set-cookie');assert.match(header,/HttpOnly/);assert.match(header,/Secure/);assert.match(header,/SameSite=Strict/);
  assert.equal('deviceToken'in login.data,false);assert.equal(login.data.role,'contributor');
  const cookie=header.split(';')[0];
  const denied=await fetch(origin+'/v1/session',{method:'DELETE',headers:{Cookie:cookie,Origin:'https://web.fixture.invalid'}});assert.equal(denied.status,403);
  const logout=await fetch(origin+'/v1/session',{method:'DELETE',headers:{Cookie:cookie,Origin:'https://web.fixture.invalid','X-CSRF-Token':login.data.csrf}});assert.equal(logout.status,200);assert.match(logout.headers.get('set-cookie'),/Max-Age=0/);
  assert.equal((await fetch(origin+'/v1/session',{headers:{Cookie:cookie}})).status,403);
});
test('runtime RLS hides cross-tenant rows and runtime cannot rewrite evidence or enroll members',async()=>{
  const a=await fixture(),b=await fixture();const c=await runtime.connect();try{
    await c.query('BEGIN');await c.query("SELECT set_config('app.household_id',$1,true)",[a.h]);
    assert.equal((await c.query('SELECT * FROM ritc.shop WHERE household_id=$1',[b.h])).rowCount,0);
    await assert.rejects(c.query("UPDATE ritc.shop_snapshot SET digest=repeat('0',64) WHERE household_id=$1",[a.h]));await c.query('ROLLBACK');
    await c.query('BEGIN');await c.query("SELECT set_config('app.household_id',$1,true)",[a.h]);
    await assert.rejects(c.query("UPDATE ritc.member SET organizer=true WHERE household_id=$1 AND member_id=$2",[a.h,a.actors.Sam.id]));await c.query('ROLLBACK');
  }finally{c.release();}
});

test('missing prices stay unresolved, expired previews fail and foreign browser origins are denied',async()=>{
  const f=await fixture(),sent=await f.send();
  const p=await f.preview(sent.request,{choice:'add',line:{lineId:randomUUID(),originalItem:'Unknown-price pack',packs:1,unitPriceMinor:null,feeEligible:true},promote:false});
  assert.equal(p.status,200);assert.equal(p.data.after.totalMinor,null);assert.equal(p.data.after.wholeCheckoutWithinCap,false);assert.equal(p.data.requiresUnknownAcceptance,true);
  const c=f.envelope('Mia','request.apply',{requestId:sent.request.requestId,previewId:p.data.previewId,acceptOverage:false,acceptUnknown:false},{shopRevision:1,authorityEpoch:1,requestRevision:1});
  assert.equal((await f.http('Mia','POST','/commands',c)).data.error.code,'unknown_acceptance_required');
  await admin.query("UPDATE ritc.preview SET expires_at=now()-interval '1 second' WHERE household_id=$1 AND preview_id=$2",[f.h,p.data.previewId]);
  c.body.acceptUnknown=true;assert.equal((await f.http('Mia','POST','/commands',c)).data.error.code,'stale_preview');
  assert.equal((await f.http('Mia','GET','/bootstrap',undefined,{Origin:'https://hostile.fixture.invalid'})).status,403);
  const bytes=await fetch(origin+'/v1/households/'+f.h+'/commands',{method:'POST',headers:{Authorization:'Bearer '+f.actors.Mia.token,'X-Device-Token':f.actors.Mia.deviceToken,'Content-Type':'application/json'},body:JSON.stringify({value:'x'.repeat(65536)})});assert.equal(bytes.status,413);
});

test('child default-off gate and device/session binding reject authenticated but unauthorized clients',async()=>{
  const f=await fixture();
  const closed=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture-notice-v1',sessionStatus:new SupabaseSessionVerifier(issuer)});
  const childIdentity=await verifier.verify(f.actors.Sam.token);
  await assert.rejects(closed.authorized(f.h,{identity:childIdentity,deviceToken:f.actors.Sam.deviceToken},ctx=>closed.bootstrap(ctx)),e=>e.code==='access_ended');
  const otherSession=await new SignJWT({session_id:randomUUID()}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(f.actors.Mia.subject).setIssuedAt().setExpirationTime('1h').sign(privateKey);
  assert.equal((await f.http({...f.actors.Mia,token:otherSession},'GET','/bootstrap')).status,401);
  assert.equal((await f.http('Mia','DELETE','/devices/current')).status,200);
  assert.equal((await f.http('Mia','GET','/bootstrap')).status,403);
});


test('billing HTTP wiring remains Free and blocks delivery without configured Apple authority',async()=>{
  const f=await fixture();
  const snapshot=await f.http('Mia','GET','/entitlements');assert.equal(snapshot.status,200);assert.equal(snapshot.data.status,'free');
  const context=await f.http('Mia','POST','/billing/purchase-context',{});assert.equal(context.status,503);assert.equal(context.data.error.code,'billing_unavailable');
  const forged=await f.http('Mia','POST','/v1/billing/verify',{householdId:f.h,signedTransactionInfo:'not-a-real-signed-transaction'});assert.equal(forged.status,503);
  assert.equal((await f.http('Sam','GET','/entitlements')).status,403);
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.billing_delivery WHERE household_id=$1',[f.h])).rows[0].n,0);
});

test('two contributors can reuse the same local key and local request ID without collision',async()=>{
  const f=await fixture(),clientKey=randomUUID(),clientRequestId=randomUUID();
  const payload={clientRequestId,originalItem:'Same fictional item',ownQuantity:'one box',authoredAt:new Date().toISOString()};
  const sam=await f.command('Sam','request.send',payload,{shopRevision:0,authorityEpoch:0},clientKey);
  const jo=await f.command('Jo','request.send',payload,{shopRevision:0,authorityEpoch:0},clientKey);
  assert.equal(sam.status,200);assert.equal(jo.status,200);assert.notEqual(sam.data.request.requestId,jo.data.request.requestId);
  assert.equal((await f.http('Sam','GET','/requests/mine')).data.requests.length,1);
  assert.equal((await f.http('Jo','GET','/requests/mine')).data.requests.length,1);
  const samReplay=await f.command('Sam','request.send',payload,{shopRevision:0,authorityEpoch:0},clientKey);assert.deepEqual(samReplay.data,sam.data);
});


test('signed provider sessions require a live row bound to subject; cookie and reenrollment recheck revocation',async()=>{
  const f=await fixture();
  const cookieResponse=await f.http('Mia','POST','/v1/session',{householdId:f.h});assert.equal(cookieResponse.status,200);
  const cookie=cookieResponse.headers.get('set-cookie').split(';')[0];
  await admin.query('DELETE FROM auth.sessions WHERE id=$1',[f.actors.Mia.session]);
  assert.equal((await f.http('Mia','GET','/bootstrap')).status,401);
  assert.equal((await f.http('Mia','GET','/v1/me/workspaces')).status,401);
  assert.equal((await f.http('Mia','POST','/devices',{})).status,401);
  assert.equal((await fetch(origin+'/v1/session',{headers:{Cookie:cookie}})).status,401);
  await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[f.actors.Mia.session,f.actors.Alex.subject]);
  assert.equal((await f.http('Mia','GET','/bootstrap')).status,401);
  await admin.query("UPDATE auth.sessions SET user_id=$2,not_after=now()-interval '1 minute' WHERE id=$1",[f.actors.Mia.session,f.actors.Mia.subject]);
  assert.equal((await f.http('Mia','GET','/bootstrap')).status,401);
  await assert.rejects(runtime.query('SELECT id FROM auth.sessions'),e=>e.code==='42501');
});
test('bootstrap shopper capabilities follow adult role and assigned current shop',async()=>{
  const f=await fixture();
  for(const name of ['Alex','Sam','Jo']) {
    const result=await f.http(name,'GET','/bootstrap');assert.equal(result.status,200);
    assert.equal(result.data.role,'contributor');assert.deepEqual(result.data.capabilities,['own_requests']);
  }
  const shopper=await f.http('Mia','GET','/bootstrap');assert.equal(shopper.data.role,'shopper');
  assert.ok(shopper.data.capabilities.includes('shopper_inbox'));
  await f.command('Mia','shop.transferAuthority',{newShopperId:f.actors.Alex.id});
  const old=await f.http('Mia','GET','/bootstrap');assert.equal(old.data.role,'organizer');assert.equal(old.data.capabilities.includes('shopper_commands'),false);
  const current=await f.http('Alex','GET','/bootstrap');assert.equal(current.data.role,'shopper');assert.ok(current.data.capabilities.includes('shopper_commands'));
});

test('self-serve adult household creation is atomic, idempotent and rejects child elevation',async()=>{
  const f=await fixture(),input={clientKey:randomUUID(),label:'New fictional home',alias:'Mia',adultAttestation:true};
  const pair=await Promise.all([f.http('Mia','POST','/v1/households',input),f.http('Mia','POST','/v1/households',input)]);
  assert.equal(pair[0].status,201,JSON.stringify(pair[0].data));assert.deepEqual(pair[0].data,pair[1].data);
  const h=pair[0].data.householdId;assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.member WHERE household_id=$1',[h])).rows[0].n,1);
  assert.equal((await f.http('Mia','POST','/v1/households',{...input,label:'Changed'})).status,409);
  assert.equal((await f.http('Sam','POST','/v1/households',{...input,clientKey:randomUUID()})).status,503);
  await admin.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2",[f.h,f.actors.Sam.id]);
  assert.equal((await f.http('Sam','POST','/v1/households',{...input,clientKey:randomUUID()})).status,503);
  const enrolled=await f.http('Mia','POST','/v1/households/'+h+'/devices',{});assert.equal(enrolled.status,201);
  const boot=await f.http({...f.actors.Mia,deviceToken:enrolled.data.deviceToken},'GET','/v1/households/'+h+'/bootstrap');assert.equal(boot.data.shopId,null);assert.deepEqual(boot.data.capabilities,['own_requests','household_admin']);
});

test('single-use invitations serialize racing identities and permit only the original identity retry',async()=>{
  const f=await fixture(),a=await fixture(),b=await fixture();
  assert.equal((await f.http('Alex','POST','/invites',{kind:'adult_contributor'})).status,404);
  const child=await f.http('Mia','POST','/invites',{kind:'child_contributor'});assert.equal(child.status,503);assert.equal(child.data.error.code,'consent_unavailable');
  const invitation=await f.http('Mia','POST','/invites',{kind:'adult_contributor',expiresInHours:24});assert.equal(invitation.status,200);
  const payload={token:invitation.data.token,intent:'join',adultAttestation:true,alias:'Fictional invitee'};
  const results=await Promise.all([f.http(a.actors.Mia,'POST','/v1/invites/redeem',payload),f.http(b.actors.Mia,'POST','/v1/invites/redeem',payload)]);
  assert.deepEqual(results.map(r=>r.status).sort(),[200,404]);
  const winner=results[0].status===200?a:b,receipt=results.find(r=>r.status===200).data;
  assert.deepEqual((await f.http(winner.actors.Mia,'POST','/v1/invites/redeem',payload)).data,receipt);
  assert.equal((await f.http('Sam','POST','/v1/invites/redeem',payload)).status,503);
  const rows=await admin.query('SELECT token_hash FROM ritc.invite WHERE household_id=$1 AND invite_id=$2',[f.h,invitation.data.inviteId]);assert.equal(rows.rows[0].token_hash.length,64);assert.notEqual(rows.rows[0].token_hash,invitation.data.token);
  const enrolled=await f.http(winner.actors.Mia,'POST','/devices',{});const actor={...winner.actors.Mia,deviceToken:enrolled.data.deviceToken};
  assert.equal((await f.http(actor,'GET','/members')).status,404);
  const revoked=await f.http('Mia','POST','/revocations',{kind:'member',targetId:receipt.memberId});assert.equal(revoked.status,200);
  assert.equal((await f.http(actor,'GET','/bootstrap')).status,403);
  assert.equal((await f.http(winner.actors.Mia,'POST','/v1/invites/redeem',payload)).status,404);
});

async function helperFixture(mode='edit'){
  const f=await fixture(),person=await fixture();
  const projection={shopLabel:'Tuesday pickup',language:'en',items:[{label:'Wraps',amount:'six',unit:'wraps',action:'Keep two for lunch'}]};
  const created=await f.http('Mia','POST','/views',{...projection,shopId:f.shopId,mode,expiresInHours:24});assert.equal(created.status,200,JSON.stringify(created.data));
  const redeemed=await f.http(person.actors.Mia,'POST','/v1/invites/redeem',{token:created.data.token,intent:'join',adultAttestation:true,alias:'Cook'});assert.equal(redeemed.status,200);
  const enrolled=await f.http(person.actors.Mia,'POST','/devices',{});assert.equal(enrolled.status,201);
  const actor={...person.actors.Mia,deviceToken:enrolled.data.deviceToken};
  const route='/v1/views/'+created.data.grantId;
  const call=(method,path,value)=>f.http(actor,method,route+path,value,{'X-Household-ID':f.h});
  return{f,person,actor,projection,grantId:created.data.grantId,call,created};
}

test('helper projection excludes private data and durable proposals never mutate the shared basket',async()=>{
  const {f,actor,projection,grantId,call}=await helperFixture();
  const boot=await f.http(actor,'GET','/bootstrap');assert.equal(boot.data.role,'editor');assert.equal(boot.data.grantId,grantId);assert.deepEqual(boot.data.capabilities,['helper_view','helper_propose']);
  const view=await call('GET','/current');assert.equal(view.status,200);assert.deepEqual(view.data.items,projection.items);
  assert.deepEqual(Object.keys(view.data).sort(),['grantId','shopId','revision','asOf','expiresAt','mode','canPropose','shopLabel','language','items'].sort());
  assert.equal((await f.http(actor,'GET','/shops/'+f.shopId+'/inbox')).status,404);
  const input={clientKey:randomUUID(),baseRevision:1,correction:'Set aside three wraps for lunch'};
  const response=await call('POST','/proposals',input);assert.equal(response.status,200);assert.deepEqual(Object.keys(response.data).sort(),['proposalId','grantId','baseRevision','status'].sort());
  assert.deepEqual((await call('POST','/proposals',input)).data,response.data);
  assert.equal((await call('POST','/proposals',{...input,correction:'Changed'})).status,409);
  const before=await f.http('Mia','GET','/shops/'+f.shopId);assert.equal(before.data.shopRevision,1);assert.equal(before.data.lines.length,1);
  const proposals=await f.http('Mia','GET','/views/'+grantId+'/proposals');assert.equal(proposals.data.proposals[0].correction,input.correction);
  assert.equal((await f.http(actor,'GET','/views/'+grantId+'/proposals')).status,404);
  assert.equal((await f.http('Mia','PUT','/views/'+grantId,{...projection,baseRevision:1,budget:3800})).status,422);
  assert.equal((await f.http('Mia','PUT','/views/'+grantId,{...projection,baseRevision:1,items:[{...projection.items[0],action:'Keep three for lunch'}]})).status,200);
  assert.equal((await call('GET','/current')).data.revision,2);
  assert.deepEqual((await call('POST','/proposals',input)).data,response.data);
  assert.equal((await call('POST','/proposals',{...input,clientKey:randomUUID()})).status,409);
  await f.http('Mia','POST','/revocations',{kind:'view',targetId:grantId});
  assert.equal((await call('GET','/current')).status,404);assert.equal((await call('POST','/proposals',input)).status,404);
});

test('read-only helper and expired grants cannot propose; browser can switch to its newly redeemed household',async()=>{
  const {f,person,actor,grantId,call}=await helperFixture('read');
  assert.equal((await f.http(actor,'GET','/bootstrap')).data.role,'helper');
  assert.equal((await call('POST','/proposals',{clientKey:randomUUID(),baseRevision:1,correction:'Change'})).status,404);
  const old=await person.http('Mia','POST','/v1/session',{householdId:person.h});assert.equal(old.status,200);
  const response=await fetch(origin+'/v1/session',{method:'POST',headers:{Cookie:old.headers.get('set-cookie').split(';')[0],Origin:'https://web.fixture.invalid','X-CSRF-Token':old.data.csrf,'Content-Type':'application/json'},body:JSON.stringify({householdId:f.h})});
  assert.equal(response.status,200);const switched=await response.json();assert.equal(switched.household.id,f.h);assert.equal(switched.grantId,grantId);assert.equal(switched.role,'helper');
  const current=await fetch(origin+'/v1/views/'+grantId+'/current',{headers:{Cookie:response.headers.get('set-cookie').split(';')[0]}});assert.equal(current.status,200);
  await admin.query("UPDATE ritc.view_grant SET expires_at=now()-interval '1 second' WHERE household_id=$1 AND grant_id=$2",[f.h,grantId]);
  assert.equal((await call('GET','/current')).status,404);
});

test('guardian access is scoped to actual relationships and withdrawal revokes child devices and replay',async()=>{
  const f=await fixture(),sent=await f.send();
  const mine=await f.http('Mia','GET','/guardian/consents');assert.equal(mine.data.enrollmentEnabled,false);assert.equal(mine.data.consents.length,2);
  assert.equal(JSON.stringify(mine.data).includes('verification_ref'),false);assert.equal(JSON.stringify(mine.data).includes('fictional-provider'),false);
  assert.deepEqual((await f.http('Alex','GET','/guardian/consents')).data.consents,[]);
  const consent=mine.data.consents.find(c=>c.childId===f.actors.Sam.id);
  assert.equal((await f.http('Alex','POST','/guardian/consents/'+consent.consentId+'/revoke',{})).status,404);
  const result=await f.http('Mia','POST','/guardian/consents/'+consent.consentId+'/revoke',{});assert.equal(result.status,200);
  assert.deepEqual((await f.http('Mia','POST','/guardian/consents/'+consent.consentId+'/revoke',{})).data,result.data);
  assert.equal((await f.http('Sam','POST','/commands',sent.envelope)).status,403);
  assert.equal((await f.http('Mia','POST','/guardian/enrollment',{})).data.error.code,'consent_unavailable');
});

test('new private tables enforce tenant isolation and provider checker cannot leak sessions',async()=>{
  const f=await fixture(),client=await runtime.connect();try{
    await client.query('BEGIN');
    for(const table of ['household','member','view_grant','invite','helper_proposal'])assert.equal((await client.query('SELECT * FROM ritc.'+table)).rowCount,0);
    await client.query("SELECT set_config('app.household_id',$1,true)",[f.h]);
    assert.equal((await client.query('SELECT household_id FROM ritc.household')).rowCount,1);
    await client.query('ROLLBACK');
  }finally{client.release();}
  const security=await admin.query("SELECT p.prosecdef,p.proconfig,has_function_privilege('public',p.oid,'EXECUTE') AS public_execute FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='ritc' AND p.proname='provider_session_live'");
  assert.equal(security.rows[0].public_execute,false);assert.equal(security.rows[0].prosecdef,true);assert.deepEqual(security.rows[0].proconfig,['search_path=pg_catalog']);
});

test('browser helper session stays bound to its selected grant and cannot fall back after revocation',async()=>{
  const {f,actor,projection,grantId}=await helperFixture();
  const newer=await f.http('Mia','POST','/views',{...projection,shopId:f.shopId,shopLabel:'Newer instructions',mode:'read',expiresInHours:24});
  assert.equal((await f.http(actor,'POST','/v1/invites/redeem',{token:newer.data.token,intent:'join',adultAttestation:true})).status,200);
  const session=await f.http(actor,'POST','/v1/session',{householdId:f.h,grantId});assert.equal(session.status,200);assert.equal(session.data.grantId,grantId);assert.equal(session.data.role,'editor');
  const headers={Cookie:session.headers.get('set-cookie').split(';')[0]};
  const current=await fetch(origin+'/v1/session',{headers});assert.equal(current.status,200);assert.equal((await current.json()).grantId,grantId);
  const other=await fetch(origin+'/v1/views/'+newer.data.grantId+'/current',{headers});
  // A selected helper session cannot select another grant merely by changing the URL.
  assert.equal(other.status,404);
  await f.http('Mia','POST','/revocations',{kind:'view',targetId:grantId});
  assert.equal((await fetch(origin+'/v1/session',{headers})).status,403);
});
test('only shopper inbox includes author aliases; own requests and receipts remain minimal',async()=>{
  const f=await fixture(),sent=await f.send('Sam');
  assert.equal('authorAlias' in sent.request,false);
  const inbox=await f.http('Mia','GET','/shops/'+f.shopId+'/inbox');assert.equal(inbox.data.requests[0].authorAlias,'Sam');
  const own=await f.http('Sam','GET','/requests/mine');assert.equal('authorAlias' in own.data.requests[0],false);
});

test('JWT without signed session_id is rejected before device enrollment',async()=>{
  const f=await fixture();
  const token=await new SignJWT({}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(f.actors.Mia.subject).setIssuedAt().setExpirationTime('1h').sign(privateKey);
  assert.equal((await f.http({token},'POST','/devices',{})).status,401);
});
test('live provider session lock serializes logout with the authorized transaction',async()=>{
  const f=await fixture(),identity=await verifier.verify(f.actors.Mia.token),provider=await admin.connect();
  try{
    await repo.authorized(f.h,{identity,deviceToken:f.actors.Mia.deviceToken},async()=>{
      await provider.query("BEGIN; SET LOCAL lock_timeout='100ms'");
      await assert.rejects(provider.query('DELETE FROM auth.sessions WHERE id=$1',[identity.sessionId]),e=>e.code==='55P03');
      await provider.query('ROLLBACK');
    });
    await provider.query('DELETE FROM auth.sessions WHERE id=$1',[identity.sessionId]);
    assert.equal((await f.http('Mia','GET','/bootstrap')).status,401);
  }finally{await provider.query('ROLLBACK');provider.release();}
});

test('native selected-grant header enforces the exact recipient and removes broader shopper authority',async()=>{
  const f=await fixture();
  const view=await f.http('Mia','POST','/views',{shopId:f.shopId,mode:'edit',shopLabel:'Selected native view',language:'en',items:[{label:'Wraps',amount:'six',unit:'wraps',action:'Save two'}]});
  assert.equal(view.status,200);
  assert.equal((await f.http('Mia','POST','/v1/invites/redeem',{token:view.data.token,intent:'join',adultAttestation:true})).status,200);
  const selected={'X-View-Grant-ID':view.data.grantId};
  const boot=await f.http('Mia','GET','/bootstrap',undefined,selected);assert.equal(boot.status,200);assert.equal(boot.data.role,'editor');assert.equal(boot.data.grantId,view.data.grantId);assert.deepEqual(boot.data.capabilities,['helper_view','helper_propose']);
  assert.equal((await f.http('Mia','GET','/shops/'+f.shopId+'/inbox',undefined,selected)).status,404);
  assert.equal((await f.http('Mia','GET','/members',undefined,selected)).status,404);
  assert.equal((await f.http('Mia','GET','/entitlements',undefined,selected)).status,404);
  assert.equal((await f.http('Mia','GET','/requests/mine',undefined,selected)).status,404);
  assert.equal((await f.http('Alex','GET','/bootstrap',undefined,selected)).status,403);
  assert.equal((await f.http('Mia','GET','/bootstrap',undefined,{'X-View-Grant-ID':'not-a-uuid'})).status,422);
});
test('managed invitation and view lists reconcile creation without disclosing tokens or unrelated shops',async()=>{
  const {f,actor,grantId,created}=await helperFixture();
  const invitation=await f.http('Mia','POST','/invites',{kind:'adult_contributor'});
  const invites=await f.http('Mia','GET','/invites');assert.equal(invites.status,200);assert.equal(invites.data.invites.find(i=>i.inviteId===invitation.data.inviteId).status,'pending');
  assert.equal(invites.data.invites.find(i=>i.inviteId===created.data.inviteId).status,'redeemed');
  assert.equal(JSON.stringify(invites.data).includes(invitation.data.token),false);assert.equal(JSON.stringify(invites.data).includes('token_hash'),false);
  assert.equal((await f.http('Alex','GET','/invites')).status,404);
  const views=await f.http('Mia','GET','/views');assert.equal(views.status,200);assert.equal(views.data.views[0].grantId,grantId);assert.equal(views.data.views[0].recipientAlias,'Cook');
  assert.equal(JSON.stringify(views.data).includes(created.data.token),false);assert.deepEqual((await f.http('Alex','GET','/views')).data.views,[]);
  assert.equal((await f.http(actor,'GET','/views',undefined,{'X-View-Grant-ID':grantId})).status,404);
  await f.http('Mia','POST','/revocations',{kind:'view',targetId:grantId});
  assert.equal((await f.http('Mia','GET','/views')).data.views[0].status,'revoked');
});
