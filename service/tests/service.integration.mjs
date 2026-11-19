import {adultPickupTests} from './adult-pickup.wire.mjs';
import test,{before,after} from 'node:test';
import {grocery30Routing} from './grocery30-routing.mjs';
import assert from 'node:assert/strict';
import pg from 'pg';
import {randomUUID,randomBytes} from 'node:crypto';
import {generateKeyPair,exportJWK,createLocalJWKSet,decodeJwt,SignJWT} from 'jose';
import {migrate} from '../scripts/migrate.mjs';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {createHTTPServer} from '../dist/http.js';
import {assertRuntimeRole,digest,tokenHash} from '../dist/database.js';
import {BillingService} from '../dist/billing/service.js';
const runtimeURL=process.env.TEST_DATABASE_URL,adminURL=process.env.TEST_ADMIN_DATABASE_URL;
if(!runtimeURL||!adminURL)throw new Error('Real PostgreSQL tests require TEST_DATABASE_URL and TEST_ADMIN_DATABASE_URL; they are never replaced by an in-memory mock.');
const admin=new pg.Pool({connectionString:adminURL}),runtime=new pg.Pool({connectionString:runtimeURL,max:12});
const issuer='https://identity.fixture.invalid',audience='authenticated';
const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='fixture-1';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]}));
const repo=new HouseholdRepository(runtime,{allowChildNetwork:true,noticeVersion:'fixture-notice-v1',sharedContentSafety:true,moderationRetentionDays:7,sessionStatus:new SupabaseSessionVerifier(issuer)});
const server=createHTTPServer({repository:repo,verifier,billing:new BillingService(null),webOrigin:'https://web.fixture.invalid',maxRequestsPerMinute:10000});
let origin;
before(async()=>{await admin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');await migrate(adminURL);await assertRuntimeRole(runtime);await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;});
after(async()=>{await new Promise(resolve=>server.close(resolve));await Promise.all([runtime.end(),admin.end()]);});
async function fixture({createShop=true,otherAdult=false}={}) {
  const h=randomUUID(),shopId=randomUUID(),lineId=randomUUID(),actors={};
  const c=await admin.connect();try{
    await c.query('BEGIN');await c.query('INSERT INTO ritc.household(household_id,label) VALUES($1,$2)',[h,'Fictional household']);
    for(const name of ['Mia','Alex','Sam','Jo',...(otherAdult?['Lee']:[])]) {
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
  for(const [name,actor] of Object.entries(actors)) {
    if(['Sam','Jo'].includes(name)){
      // This request-command fixture starts after independently tested guardian
      // enrollment. Only its privileged fixture owner seeds granted authority;
      // the public generic device route must not enroll a child.
      const consent=(await admin.query('SELECT consent_id FROM ritc.consent WHERE household_id=$1 AND child_id=$2',[h,actor.id])).rows[0].consent_id;
      actor.deviceId=randomUUID();actor.deviceToken=randomBytes(32).toString('base64url');
      await admin.query('INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id,guardian_consent_id) VALUES($1,$2,$3,$4,$5,$6)',[h,actor.deviceId,actor.id,tokenHash(actor.deviceToken),actor.session,consent]);
      await admin.query(`INSERT INTO ritc.guardian_enrollment(household_id,enrollment_id,guardian_id,guardian_device_id,guardian_issuer,guardian_subject,guardian_session,child_id,child_alias,notice_version,notice_digest,method_version,language,child_location,declaration,state,expires_at,consent_id,verified_at,consented_at)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'fixture-notice-v1',$10,'fixture-method','en','US','parent_or_legal_guardian','active',clock_timestamp()+interval '1 hour',$11,clock_timestamp(),clock_timestamp())`,[h,randomUUID(),actors.Mia.id,actors.Mia.deviceId,issuer,actors.Mia.subject,actors.Mia.session,actor.id,name,digest('fixture-notice'),consent]);
    }else{const device=await http(actor,'POST','/devices',{});assert.equal(device.status,201,JSON.stringify(device.data));actor.deviceToken=device.data.deviceToken;actor.deviceId=device.data.deviceId;}
    const window=await http(actor,'POST','/replay-windows',{});assert.equal(window.status,200,JSON.stringify(window.data));actor.window=window.data.id;
  }
  const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:3800,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date(Date.now()-60_000).toISOString(),expiresAt:new Date(Date.now()+3_600_000).toISOString()};
  const line={lineId,originalItem:'Original basket',packs:1,unitPriceMinor:3720,feeEligible:true};
  function envelope(actor,kind,body,base={shopRevision:1,authorityEpoch:1},key=randomUUID()){return{v:1,replayWindow:actors[actor].window,clientKey:key,shopId,kind,base,body};}
  async function command(actor,kind,body,base,key){return http(actor,'POST','/commands',envelope(actor,kind,body,base,key));}
  if(createShop){const created=await command('Mia','shop.create',{quote,lines:[line]},{shopRevision:0,authorityEpoch:0});assert.equal(created.status,200,JSON.stringify(created.data));}
  async function send(actor='Sam',extra={}){const payload={clientRequestId:randomUUID(),originalItem:'Fictional cereal',ownQuantity:'one box',authoredAt:new Date().toISOString(),...extra};const c=envelope(actor,'request.send',payload,{shopRevision:0,authorityEpoch:0});const response=await http(actor,'POST','/commands',c);assert.equal(response.status,200,JSON.stringify(response.data));return{...response.data,envelope:c};}
  async function preview(request,decision={choice:'add',line:{lineId:randomUUID(),originalItem:'Fictional cereal',packs:1,unitPriceMinor:349,feeEligible:true},promote:false},actor='Mia',base={shopRevision:1,authorityEpoch:1,requestRevision:request.revision}) {
    return http(actor,'POST','/shops/'+shopId+'/previews',{requestId:request.requestId,base,decision});
  }
  return{h,shopId,lineId,line,quote,actors,http,envelope,command,send,preview};
}

adultPickupTests({fixture,admin,repo});

if(process.env.RITC_TEST_NATIVE_WIRE==='1') test('assigned iPhone shopper carries a prior request and reprices it over pinned HTTPS',async()=>{
  const f=await deferredFixture('Alex',{originalItem:'Original basket'});
  const {exerciseNativeClient}=await import('./native-wire.mjs');
  await exerciseNativeClient({service:server,owner:f.actors.Mia,householdId:f.h,shopId:f.dest,
    deferredRequestId:f.original.requestId});
});

test('a device-bound withdrawal recovers its committed receipt and rejects uncommitted withdrawals after opt-out',async()=>{
  const f=await fixture();
  const first=(await f.send('Alex')).request, second=(await f.send('Alex')).request;
  const other=(await f.send('Sam')).request;
  const {requestQueueGrant}= (await f.http('Alex','PUT','/devices/current/request-queue',{enabled:true})).data;
  const withdraw=request=>f.envelope('Alex','request.withdraw',{requestId:request.requestId},
    {shopRevision:0,authorityEpoch:0,requestRevision:request.revision});
  const submit=(envelope,grant=requestQueueGrant)=>f.http('Alex','POST','/commands',envelope,{'X-Request-Queue-Grant':grant});
  const committed=withdraw(first), uncommitted=withdraw(second);
  const receipt=await submit(committed);
  assert.equal(receipt.status,200,JSON.stringify(receipt.data));
  assert.equal(receipt.data.request.status,'withdrawn');
  const foreign=await submit(withdraw(other));
  assert.equal(foreign.status,404);
  assert.equal(foreign.data.error.code,'unavailable');
  await f.http('Alex','PUT','/devices/current/request-queue',{enabled:false});
  assert.deepEqual((await submit(committed)).data,receipt.data);
  assert.equal((await submit(uncommitted)).data.error.code,'queue_permission_ended');
  const renewed=(await f.http('Alex','PUT','/devices/current/request-queue',{enabled:true})).data.requestQueueGrant;
  assert.notEqual(requestQueueGrant,renewed);
  assert.equal((await submit(committed,renewed)).data.error.code,'key_reused');
  assert.equal((await submit(uncommitted)).data.error.code,'queue_permission_ended');
  const rows=(await f.http('Alex','GET','/requests/mine')).data.requests;
  assert.equal(rows.find(r=>r.requestId===second.requestId).status,'pending');
  assert.equal(rows.find(r=>r.requestId===first.requestId).revision,first.revision+1);
});

test('pending own requests require the current opted-in device, an unexpired grant and fresh contribution rights',async()=>{
  const f=await fixture(),route='/devices/current/request-queue';
  const permission=(actor,enabled)=>f.http(actor,'PUT',route,{enabled});
  const initial=(await f.http('Alex','GET','/bootstrap')).data;
  assert.equal(initial.canSetRequestQueue,true);
  assert.equal(initial.queueConsent,false);
  assert.equal(initial.requestQueueGrant,undefined);
  assert.equal((await permission('Sam',true)).status,404);
  const granted=(await permission('Alex',true)).data;
  assert.equal(granted.queueConsent,false); // Older clients must never open their unversioned queue.
  assert.ok(Date.parse(granted.requestQueueUntil)>Date.now());
  assert.ok(Date.parse(granted.requestQueueUntil)<=Date.now()+24*3600_000);
  assert.deepEqual((await permission('Alex',true)).data,granted);
  const second={...f.actors.Alex,deviceToken:undefined};
  const device=await f.http(second,'POST','/devices',{});
  assert.equal(device.status,201);
  second.deviceToken=device.data.deviceToken;
  assert.equal((await f.http(second,'GET','/bootstrap')).data.queueConsent,false);
  const make=()=>f.envelope('Alex','request.send',{clientRequestId:randomUUID(),originalItem:'Once',ownQuantity:null,authoredAt:new Date().toISOString()},{shopRevision:0,authorityEpoch:0});
  const send=(who,grant,command)=>f.http(who,'POST','/commands',command,{'X-Request-Queue-Grant':grant});
  const first=make(), grant=granted.requestQueueGrant;
  assert.equal((await send(second,grant,first)).data.error.code,'queue_permission_ended');
  assert.equal((await send('Mia',grant,first)).data.error.code,'queue_permission_ended');
  const received=await send('Alex',grant,first);
  assert.equal(received.status,200,JSON.stringify(received.data));
  assert.deepEqual((await send('Alex',grant,first)).data,received.data);
  assert.equal((await f.http('Alex','GET','/requests/mine')).data.requests.length,1);
  assert.equal((await permission('Alex',false)).data.queueConsent,false);
  assert.deepEqual((await send('Alex',grant,first)).data,received.data); // Historical readback, no new request.
  const pending=make();
  assert.equal((await send('Alex',grant,pending)).data.error.code,'queue_permission_ended');
  const renewed=(await permission('Alex',true)).data.requestQueueGrant;
  assert.notEqual(renewed,grant);
  assert.equal((await send('Alex',renewed,first)).data.error.code,'key_reused');
  assert.deepEqual((await send('Alex',grant,first)).data,received.data);
  assert.equal((await send('Alex',grant,pending)).data.error.code,'queue_permission_ended');
  await admin.query("UPDATE ritc.request_queue_permission SET enabled_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE household_id=$1",[f.h]);
  assert.equal((await send('Alex',renewed,pending)).data.error.code,'queue_permission_ended');
  await admin.query("UPDATE ritc.request_queue_permission SET enabled_at=now()+interval '1 hour',expires_at=now()+interval '2 hours' WHERE household_id=$1",[f.h]);
  assert.equal((await send('Alex',renewed,pending)).data.error.code,'queue_permission_ended');
  const beforeLoss=(await permission('Alex',true)).data.requestQueueGrant;
  await admin.query('UPDATE ritc.member SET can_contribute=false WHERE household_id=$1 AND member_id=$2',[f.h,f.actors.Alex.id]);
  const lost=(await f.http('Alex','GET','/bootstrap')).data;
  assert.equal(lost.canSetRequestQueue,false);
  assert.equal(lost.queueConsent,false);
  await admin.query('UPDATE ritc.member SET can_contribute=true WHERE household_id=$1 AND member_id=$2',[f.h,f.actors.Alex.id]);
  assert.equal((await send('Alex',beforeLoss,pending)).data.error.code,'queue_permission_ended');
  assert.equal((await f.http('Alex','GET','/requests/mine')).data.requests.length,1);
  await permission('Alex',true);
  assert.equal((await f.http('Alex','DELETE','/devices/current')).status,200);
  assert.equal((await admin.query('SELECT 1 FROM ritc.request_queue_permission WHERE household_id=$1',[f.h])).rowCount,0);
});

test('an implicit or selected helper view cannot recover a contributor queue receipt',async()=>{
  const f=await fixture(),grant=(await f.http('Alex','PUT','/devices/current/request-queue',{enabled:true})).data.requestQueueGrant;
  const input=f.envelope('Alex','request.send',{clientRequestId:randomUUID(),originalItem:'Private request',ownQuantity:null,authoredAt:new Date().toISOString()},{shopRevision:0,authorityEpoch:0});
  const send=(access={})=>f.http('Alex','POST','/commands',input,{'X-Request-Queue-Grant':grant,...access});
  assert.equal((await send()).status,200);
  const view=await f.http('Mia','POST','/views',{shopId:f.shopId,mode:'read',shopLabel:'Shared meal',language:'en',items:[]});
  assert.equal((await f.http('Alex','POST','/v1/invites/redeem',{token:view.data.token,intent:'join',adultAttestation:true})).status,200);
  assert.equal((await f.http('Alex','GET','/bootstrap')).data.role,'helper');
  assert.equal((await send()).data.error.code,'queue_permission_ended');
  assert.equal((await send({'X-View-Grant-ID':view.data.grantId})).status,404);
});

test('Foundation Grocery 30 routing and replay vectors over four authenticated HTTP clients',
  t=>grocery30Routing(t,fixture,admin,origin));

async function purchaseFixture(author='Sam') {
  const f=await fixture(),sent=await f.send(author),requestId=sent.request.requestId;
  const preview=await f.preview(sent.request,{choice:'link',lineId:f.lineId,promote:false});
  assert.equal(preview.status,200,JSON.stringify(preview.data));
  const applied=await f.command('Mia','request.apply',{requestId,previewId:preview.data.previewId,acceptOverage:false,acceptUnknown:false},
    {shopRevision:1,authorityEpoch:1,requestRevision:1});
  assert.equal(applied.status,200,JSON.stringify(applied.data));
  const draft=(await f.http('Mia','GET','/shops/'+f.shopId+'/inbox')).data.requests[0];
  assert.equal(draft.draftBasketLineId,f.lineId);
  assert.equal(draft.linkedLineId,undefined);
  assert.equal(draft.purchaseOutcome,undefined);
  const own=(await f.http(author,'GET','/requests/mine')).data.requests[0];
  assert.equal(own.draftBasketLineId,undefined);
  assert.equal(own.linkedLineId,undefined);
  const early=await f.command('Mia','request.confirmPurchase',{requestId,lineId:f.lineId,placedRevision:2,outcome:'bought'},
    {shopRevision:2,authorityEpoch:1,requestRevision:applied.data.requestRevision});
  assert.equal(early.data.error.code,'placed_order_required');
  assert.equal((await f.command('Mia','shop.freeze',{}, {shopRevision:applied.data.shopRevision,authorityEpoch:1})).status,200);
  const placed=await f.command('Mia','shop.reportPlaced',{occurredAt:new Date().toISOString()},{shopRevision:3,authorityEpoch:1});
  assert.equal(placed.status,200,JSON.stringify(placed.data));
  const state=(await f.http('Mia','GET','/shops/'+f.shopId)).data;
  return {...f,requestId,placedRevision:state.placedRevision,shopRevision:state.shopRevision,requestRevision:applied.data.requestRevision};
}

test('only first-hand shopper confirmation changes the added request purchase outcome on its sealed line',async()=>{
  const f=await purchaseFixture(),other=await purchaseFixture(),inbox='/shops/'+f.shopId+'/inbox';
  const mine=async()=>(await f.http('Sam','GET','/requests/mine')).data.requests[0];
  const shopper=async(actor='Mia')=>(await f.http(actor,'GET',inbox)).data.requests[0];
  const before=(await f.http('Mia','GET','/shops/'+f.shopId)).data;
  const base={shopRevision:f.shopRevision,authorityEpoch:1,requestRevision:f.requestRevision};
  const body={requestId:f.requestId,lineId:f.lineId,placedRevision:f.placedRevision,outcome:'bought'};
  const cmd=(extra={},version=base,actor='Mia')=>f.envelope(actor,'request.confirmPurchase',{...body,...extra},version);
  const send=(c,a='Mia')=>f.http(a,'POST','/commands',c);
  const ownBefore=await mine();assert.equal(ownBefore.status,'added');assert.equal(ownBefore.purchaseOutcome,undefined);
  assert.equal((await shopper()).draftBasketLineId,undefined);assert.equal((await shopper()).linkedLineId,f.lineId);assert.equal(ownBefore.linkedLineId,undefined);
  assert((await f.http('Mia','GET','/bootstrap')).data.capabilities.includes('request_purchase_confirmation'));
  assert(!(await f.http('Sam','GET','/bootstrap')).data.capabilities.includes('request_purchase_confirmation'));
  assert.equal((await f.http('Alex','GET',inbox)).status,404);
  for(const actor of ['Sam','Jo','Alex'])assert.equal((await send(cmd({},base,actor),actor)).status,404);
  assert.equal((await f.http(other.actors.Mia,'POST','/commands',cmd())).status,404);
  assert.equal((await send(cmd({requestId:other.requestId,lineId:other.lineId}))).status,404);
  assert.equal((await send(cmd({lineId:randomUUID()}))).status,404);
  assert.equal((await send(cmd({placedRevision:f.placedRevision+1}))).status,409);
  assert.equal((await send(cmd({}, {...base,requestRevision:1}))).status,409);
  assert.equal((await send(cmd({outcome:'refunded'}))).status,422);
  const first=cmd(),[a,b]=await Promise.all([send(first),send(first)]);
  assert.equal(a.status,200,JSON.stringify(a.data));assert.deepEqual(a.data,b.data);
  assert.deepEqual(a.data,{operationId:a.data.operationId,kind:'request.confirmPurchase',shopId:f.shopId,
    shopRevision:f.shopRevision,authorityEpoch:1,disposition:'recorded',requestId:f.requestId,requestRevision:3,purchaseOutcome:'bought'});
  assert.deepEqual(await mine(),{...ownBefore,revision:3,purchaseOutcome:'bought'});
  assert.equal((await send({...first,body:{...body,outcome:'unknown'}})).data.error.code,'key_reused');
  const correction=cmd({outcome:'notBought'},{...base,requestRevision:3});
  assert.equal((await send(correction)).data.purchaseOutcome,'notBought');
  assert.deepEqual(await mine(),{...ownBefore,revision:4,purchaseOutcome:'notBought'});
  assert.deepEqual((await send(first)).data,a.data); // A late retry cannot restore the earlier answer.
  assert.equal((await send(cmd({}, {...base,requestRevision:3}))).data.error.code,'stale_base');
  const clear=await send(cmd({outcome:'unknown'},{...base,requestRevision:4}));
  assert.equal(clear.data.purchaseOutcome,'unknown');assert.deepEqual(await mine(),{...ownBefore,revision:5});
  assert.deepEqual((await f.http('Jo','GET','/requests/mine')).data.requests,[]);
  assert.deepEqual((await f.http('Mia','GET','/shops/'+f.shopId)).data,before);
  const transfer=(newShopperId,epoch)=>f.command('Mia','shop.transferAuthority',{newShopperId},{shopRevision:f.shopRevision,authorityEpoch:epoch});
  assert.equal((await transfer(f.actors.Alex.id,1)).status,200);
  assert.equal((await send(first)).status,404);
  assert.equal((await send(cmd({}, {...base,requestRevision:5},'Alex'),'Alex')).data.error.code,'authority_changed');
  assert.equal((await shopper('Alex')).linkedLineId,f.lineId);
  assert.equal((await transfer(f.actors.Mia.id,2)).status,200);
  assert.equal((await send(first)).data.error.code,'refresh_required');
  const closed=await f.http('Mia','POST','/shops/'+f.shopId+'/financial-reviews',{clientKey:randomUUID(),
    sourceVersion:{shopRevision:f.shopRevision,authorityEpoch:3,financialRevision:0},allEvidenceEntered:false,closeShop:true});
  assert.equal(closed.status,200,JSON.stringify(closed.data));
  assert.deepEqual(await mine(),{...ownBefore,revision:5}); // Closing and reviewing money cannot confirm a request.
  const access=await f.http('Mia','GET','/bootstrap',undefined,{'X-Shop-Id':f.shopId});
  assert(access.data.capabilities.includes('request_purchase_confirmation'));
  const late=await send(cmd({}, {shopRevision:closed.data.sourceVersion.shopRevision,authorityEpoch:3,requestRevision:5}));
  assert.equal(late.status,200,JSON.stringify(late.data));assert.equal((await mine()).purchaseOutcome,'bought');
  assert.equal((await admin.query('SELECT 1 FROM ritc.request_purchase_review WHERE household_id=$1',[f.h])).rowCount,4);
});

test('real JWT auth denies missing, forged, expired, wrong issuer and wrong audience tokens',async()=>{
  const f=await fixture();
  assert.equal((await fetch(origin+'/v1/me/workspaces')).status,401);
  for(const claims of [{iss:'https://wrong.invalid',aud:audience,exp:'1h'},{iss:issuer,aud:'wrong',exp:'1h'},{iss:issuer,aud:audience,exp:'-1h'}]) {
    const token=await new SignJWT({session_id:randomUUID()}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(claims.iss).setAudience(claims.aud).setSubject(f.actors.Mia.subject).setIssuedAt().setExpirationTime(claims.exp).sign(privateKey);
    assert.equal((await f.http({token},'GET','/bootstrap')).status,401);
  }
  const {privateKey: untrustedKey} = await generateKeyPair('ES256');
  const forgedToken = await new SignJWT(decodeJwt(f.actors.Mia.token))
    .setProtectedHeader({alg:'ES256', kid:jwk.kid}).sign(untrustedKey);
  assert.equal((await f.http({...f.actors.Mia, token:forgedToken},'GET','/bootstrap')).status,401);
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
  const assignment='/shops/'+f.shopId+'/shopper-assignment';
  const initial=await f.http('Mia','GET',assignment);
  assert.equal(initial.data.shopperId,f.actors.Mia.id);
  assert.deepEqual(new Set(initial.data.adults.map(a=>a.id)),new Set([f.actors.Mia.id,f.actors.Alex.id]));
  assert.equal(initial.data.quote,undefined);assert.equal(initial.data.lines,undefined);
  assert.equal((await f.http('Alex','GET',assignment)).status,404);
  assert.equal((await f.command('Mia','shop.transferAuthority',{newShopperId:f.actors.Mia.id})).data.error.code,'already_assigned');
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
  const f=await fixture();assert.equal((await f.http('Sam','POST','/v1/session',{householdId:f.h},{Origin:'https://web.fixture.invalid'})).status,403);const login=await f.http('Alex','POST','/v1/session',{householdId:f.h},{Origin:'https://web.fixture.invalid'});assert.equal(login.status,200);
  const header=login.headers.get('set-cookie');assert.match(header,/HttpOnly/);assert.match(header,/Secure/);assert.match(header,/SameSite=Strict/);
  assert.equal('deviceToken'in login.data,false);assert.equal(login.data.role,'contributor');
  const cookie=header.split(';')[0];
  const path=origin+'/v1/households/'+f.h+'/devices/current/request-queue';
  const allow=headers=>fetch(path,{method:'PUT',headers:{Cookie:cookie,Origin:'https://web.fixture.invalid','Content-Type':'application/json',...headers},body:JSON.stringify({enabled:true})});
  assert.equal((await allow({})).status,403);
  assert.equal((await allow({'X-CSRF-Token':login.data.csrf})).status,200);
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
    assert.equal(result.data.role,'contributor');assert.deepEqual(result.data.capabilities,name==='Alex'?['request_queue_permission','own_requests']:['own_requests']);
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
  const boot=await f.http({...f.actors.Mia,deviceToken:enrolled.data.deviceToken},'GET','/v1/households/'+h+'/bootstrap');assert.equal(boot.data.shopId,null);assert.deepEqual(boot.data.capabilities,['meal_preferences_read','meal_preferences_admin','household_pantry','household_tonight','my_feedback_withdrawal','household_pantry_grants','request_queue_permission','own_requests','household_admin']);
});

test('invitation display names use the new member’s language and preserve existing names on blank joins',async()=>{
  const f=await fixture(),guests=await fixture();
  async function join(actor,review={},language){
    const invite=await f.http('Mia','POST','/invites',{kind:'adult_contributor'});assert.equal(invite.status,200);
    const body={token:invite.data.token,intent:'join',adultAttestation:true,...review};
    const path='/v1/invites/redeem',headers=language?{'Accept-Language':language}:{};
    const first=await f.http(actor,'POST',path,body,headers);assert.equal(first.status,200);
    assert.deepEqual((await f.http(actor,'POST',path,body,headers)).data,first.data);
    const members=await f.http('Mia','GET','/members');assert.equal(members.status,200);
    return members.data.members.find(member=>member.memberId===first.data.memberId).alias;
  }
  assert.equal(await join(guests.actors.Mia,{}),'Household member');
  assert.equal(await join(guests.actors.Mia,{},'es'),'Household member');
  assert.equal(await join(guests.actors.Alex,{},'es'),'Miembro del hogar');
  assert.equal(await join(guests.actors.Alex,{alias:'María José'},'es'),'María José');
  assert.equal(await join(guests.actors.Alex,{},'en'),'María José');
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

test('contributors see the next-shop destination after freeze and placement without checkout details',async()=>{
  const f=await fixture();
  const read=async()=>{const row=await f.http('Alex','GET','/bootstrap');assert.equal(row.status,200);return row.data;};
  assert.equal((await read()).nextShopOnly,false);
  assert.equal((await f.command('Mia','shop.freeze',{})).status,200);
  const frozen=await read();
  assert.equal(frozen.nextShopOnly,true);assert.equal(frozen.phase,undefined);assert.equal(frozen.quote,undefined);
  const sent=await f.send('Alex',{route:'current'});
  assert.equal(sent.request.route,'next');
  assert.equal((await f.command('Mia','shop.reportPlaced',{occurredAt:new Date().toISOString()},{shopRevision:2,authorityEpoch:1})).status,200);
  assert.equal((await read()).nextShopOnly,true);
});

test('request pickup choices expose only destination facts to a scoped organizer and an authorized child',async()=>{
  const {f,actor,grantId}=await helperFixture();
  const draft=await nextDraft(f);
  assert.equal((await f.command('Mia','shop.freeze',{})).status,200);
  const session=await f.http('Mia','POST','/v1/session',{householdId:f.h,scope:'own_requests'});
  assert.equal(session.status,200);
  assert.equal(session.data.role,'contributor');
  const headers={Cookie:session.headers.get('set-cookie').split(';')[0]};
  const base=origin+'/v1/households/'+f.h;
  const list=await fetch(base+'/requests/pickups',{headers});
  assert.equal(list.status,200);
  const page=await list.json();
  assert.deepEqual(Object.keys(page).sort(),['nextCursor','shops']);
  assert.equal(page.nextCursor,null);
  assert.deepEqual(page.shops.map(row=>row.shopId),[draft,f.shopId]);
  for(const row of page.shops){
    assert.deepEqual(Object.keys(row).sort(),['createdAt','nextShopOnly','shopId']);
    assert.equal(new Date(row.createdAt).toISOString(),row.createdAt);
    assert.equal(row.nextShopOnly,row.shopId===f.shopId);
  }
  const afterDraft=await fetch(base+'/requests/pickups?cursor='+draft,{headers});
  assert.equal(afterDraft.status,200);
  assert.deepEqual(await afterDraft.json(),{shops:[page.shops[1]],nextCursor:null});
  assert.equal((await fetch(base+'/shops?scope=owned',{headers})).status,404);
  const child=await f.http('Sam','GET','/requests/pickups');
  assert.equal(child.status,200);
  assert.deepEqual(child.data,page);
  assert.equal((await f.http('Sam','GET','/shops')).status,404);
  assert.equal((await f.http(actor,'GET','/requests/pickups')).status,404);
  assert.equal((await f.http(actor,'GET','/requests/pickups',undefined,{'X-View-Grant-ID':grantId})).status,404);

  const selected=page.shops[0].shopId;
  const envelope={...f.envelope('Mia','request.send',{clientRequestId:randomUUID(),originalItem:'Scoped rice',
    ownQuantity:null,authoredAt:new Date().toISOString(),route:'current'},{shopRevision:0,authorityEpoch:0}),
    replayWindow:session.data.replayWindow.id,shopId:selected};
  const sent=await fetch(base+'/commands',{method:'POST',headers:{...headers,Origin:'https://web.fixture.invalid',
    'X-CSRF-Token':session.data.csrf,'Content-Type':'application/json'},body:JSON.stringify(envelope)});
  assert.equal(sent.status,200);
  const {request}=await sent.json();
  assert.equal(request.shopId,selected);
  assert.equal(request.route,'current');
  const inbox=(shopId)=>f.http('Mia','GET','/shops/'+shopId+'/inbox',undefined,{'X-Shop-ID':shopId});
  assert.deepEqual((await inbox(selected)).data.requests.map(row=>row.requestId),[request.requestId]);
  assert.deepEqual((await inbox(f.shopId)).data.requests,[]);
  const next=await f.send('Sam',{route:'current'});
  assert.equal(next.request.shopId,f.shopId);
  assert.equal(next.request.route,'next');
});

test('closing a pickup hides its destination, preserves an exact send receipt and rejects a fresh request',async()=>{
  const f=await fixture();
  const draft=await nextDraft(f);
  const first=await f.send('Sam');
  const closed=await f.http('Mia','POST','/shops/'+f.shopId+'/financial-reviews',{clientKey:randomUUID(),
    sourceVersion:{shopRevision:1,authorityEpoch:1,financialRevision:0},allEvidenceEntered:false,closeShop:true});
  assert.equal(closed.status,200);
  assert.equal(closed.data.appShopClosed,true);
  const list=await f.http('Sam','GET','/requests/pickups');
  assert.equal(list.status,200);
  assert.deepEqual(list.data.shops.map(row=>row.shopId),[draft]);
  assert.equal((await f.http('Sam','GET','/requests/pickups?cursor='+f.shopId)).status,404);

  const {envelope,...receipt}=first;
  const replay=await f.http('Sam','POST','/commands',envelope);
  assert.equal(replay.status,200);
  assert.deepEqual(replay.data,receipt);
  const fresh={...envelope,clientKey:randomUUID(),body:{...envelope.body,clientRequestId:randomUUID()}};
  const refused=await f.http('Sam','POST','/commands',fresh);
  assert.equal(refused.status,409);
  assert.equal(refused.data.error.code,'pickup_closed');
  const mine=await f.http('Sam','GET','/requests/mine');
  assert.equal(mine.status,200);
  assert.deepEqual(mine.data.requests.map(row=>row.requestId),[first.request.requestId]);
});

test('a browser switches between cook and contributor invitations for the same household',async()=>{
  const {f,person,actor,grantId}=await helperFixture();
  const cook=await f.http(actor,'POST','/v1/session',{householdId:f.h,grantId});
  assert.equal(cook.status,200);assert.equal(cook.data.nextShopOnly,undefined);
  let cookie=cook.headers.get('set-cookie').split(';')[0],csrf=cook.data.csrf;
  async function browser(path,body){
    return fetch(origin+path,{method:body?'POST':'GET',headers:{Cookie:cookie,Origin:'https://web.fixture.invalid','X-CSRF-Token':csrf,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
  }
  async function activate(input){
    const response=await browser('/v1/session',input);
    assert.equal(response.status,200);
    cookie=response.headers.get('set-cookie').split(';')[0];
    const state=await response.json();csrf=state.csrf;return state;
  }
  const contributed={householdId:f.h,scope:'own_requests'};
  const deviceCount=async()=>(await admin.query('SELECT count(*)::int AS count FROM ritc.device WHERE household_id=$1 AND member_id=$2',[f.h,cook.data.memberId])).rows[0].count;
  const before=await deviceCount(),oldCookCookie=cookie;
  assert.equal((await f.http(actor,'POST','/v1/session',contributed)).status,403);
  assert.equal(await deviceCount(),before,'denied first-time activation rolls back enrollment');
  assert.equal((await browser('/v1/session',contributed)).status,403,'a cook alone cannot acquire contributor access');
  const issued=await f.http('Mia','POST','/invites',{kind:'adult_contributor',expiresInHours:24});
  assert.equal(issued.status,200);
  const joined=await browser('/v1/invites/redeem',{token:issued.data.token,intent:'join',adultAttestation:true});
  assert.equal(joined.status,200);assert.equal((await joined.json()).role,'contributor');
  const active=await activate(contributed);
  assert.equal(await deviceCount(),before,'switching roles reuses the current device');
  assert.equal((await fetch(origin+'/v1/session',{headers:{Cookie:oldCookCookie}})).status,403,'the replaced cook cookie is unusable');
  const limitedCredential=cookie.split('.')[1];
  assert.match(limitedCredential,/^own_[A-Za-z0-9_-]{43}$/,'older servers must reject this credential outright');
  const strippedCookie=cookie.replace('.own_','.');
  assert.equal((await fetch(origin+'/v1/session',{headers:{Cookie:strippedCookie}})).status,403);
  assert.equal(active.role,'contributor');assert.equal(active.grantId,undefined);
  assert.deepEqual(active.capabilities.sort(),['own_requests','request_queue_permission']);
  assert.equal((await (await browser('/v1/session')).json()).role,'contributor');
  assert.equal((await browser('/v1/views/'+grantId+'/current')).status,404);
  const base='/v1/households/'+f.h;
  await f.send('Alex',{originalItem:'Another person’s groceries'});
  const command={v:1,replayWindow:active.replayWindow.id,clientKey:randomUUID(),kind:'request.send',shopId:f.shopId,base:{shopRevision:0,authorityEpoch:0},body:{clientRequestId:randomUUID(),originalItem:'My rice',ownQuantity:null,authoredAt:new Date().toISOString(),route:'current'}};
  assert.equal((await browser(base+'/commands',command)).status,200);
  const mine=await browser(base+'/requests/mine');assert.equal(mine.status,200);
  assert.deepEqual((await mine.json()).requests.map(row=>row.originalItem),['My rice']);
  assert.equal((await browser(base+'/shops/'+f.shopId+'/inbox')).status,404);
  const previousScopeToken=csrf;
  assert.equal((await activate({householdId:f.h})).role,'contributor','refresh keeps the chosen scope');
  const staleRead=await fetch(origin+base+'/requests/mine',{headers:{Cookie:cookie,'X-CSRF-Token':previousScopeToken}});
  assert.equal(staleRead.status,403);
  assert.equal((await staleRead.json()).requests,undefined);
  assert.equal((await browser(base+'/requests/mine')).status,200);
  assert.equal((await browser('/v1/session',{...contributed,grantId})).status,422);
  const other=await activate({householdId:person.h});
  assert.equal(other.role,'contributor','a cookie stays scoped in the household where this person is the shopper and organizer');
  assert.deepEqual(other.capabilities.sort(),['own_requests','request_queue_permission']);
  const privileged=person.envelope('Mia','shop.create',{quote:person.quote,lines:[person.line]},{shopRevision:0,authorityEpoch:0});
  privileged.replayWindow=other.replayWindow.id;
  assert.equal((await browser('/v1/households/'+person.h+'/commands',privileged)).status,404);
  assert.equal((await activate({householdId:f.h,grantId})).grantId,grantId);
  assert.equal((await browser('/v1/views/'+grantId+'/current')).status,200);
  assert.equal((await browser(base+'/requests/mine')).status,404);
  const renewed=await activate(contributed);
  await admin.query('UPDATE ritc.member SET can_contribute=false WHERE household_id=$1 AND member_id=$2',[f.h,renewed.memberId]);
  assert.equal((await browser(base+'/requests/mine')).status,403);
  assert.equal((await browser('/v1/session')).status,403);
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
  assert.equal((await f.http('Mia','PUT','/devices/current/request-queue',{enabled:true},selected)).status,404);
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

test('shopper reviews a dated dinner and packs in one revision, preserves protected lunch, and cannot replay after transfer',async()=>{
  const f=await fixture(), path='/shops/'+f.shopId;
  const lunch={occurrenceId:randomUUID(),baseMealRevision:null,meal:{title:'Friday lunch',day:'2026-11-06',kind:'lunch',portions:2,protected:true}};
  const dinner={occurrenceId:randomUUID(),baseMealRevision:null,meal:{title:'Chickpea dinner',day:'2026-11-05',kind:'dinner',portions:3,protected:false}};
  const patch=(mealEdit,lines=[f.line])=>({quote:f.quote,lines,mealEdit});
  const base=shopRevision=>({shopRevision,authorityEpoch:1});
  assert.equal((await f.command('Sam','shop.patch',patch(lunch))).status,404);
  assert.equal((await f.command('Alex','shop.patch',patch(lunch))).status,404);
  assert.equal((await f.command('Mia','shop.patch',patch(lunch))).status,200);
  assert.equal((await f.command('Mia','shop.patch',patch(dinner),base(2))).status,200);
  const move={...dinner,baseMealRevision:3,meal:{...dinner.meal,day:'2026-11-08'}};
  const change=f.envelope('Mia','shop.patch',patch(move,[{...f.line,packs:2}]),base(3));
  const receipt=await f.http('Mia','POST','/commands',change);
  assert.equal(receipt.status,200);assert.equal(receipt.data.shopRevision,4);
  assert.deepEqual((await f.http('Mia','POST','/commands',change)).data,receipt.data);
  assert.equal((await f.command('Mia','shop.patch',patch(dinner),base(3))).data.error.code,'stale_base');
  const state=(await f.http('Mia','GET',path)).data;
  assert.deepEqual(state.meals,[{occurrenceId:lunch.occurrenceId,meal:lunch.meal,revision:2},{occurrenceId:move.occurrenceId,meal:move.meal,revision:4}]);
  assert.equal(state.lines[0].packs,2);
  assert.equal((await f.command('Mia','shop.patch',patch({...move,baseMealRevision:3}),base(4))).data.error.code,'stale_meal');
  assert.equal((await f.command('Mia','shop.patch',patch({...move,meal:{...move.meal,day:'2026-02-30'}}),base(4))).status,422);
  assert.equal((await f.command('Mia','shop.patch',{quote:f.quote,lines:[f.line]},base(4))).status,200);
  assert.deepEqual((await f.http('Mia','GET',path)).data.meals,state.meals);
  assert.equal((await f.command('Mia','shop.freeze',{},base(5))).status,200);
  assert.equal((await f.command('Mia','shop.patch',patch(dinner),base(6))).data.error.code,'checkout_locked');
  assert.equal((await f.command('Mia','shop.transferAuthority',{newShopperId:f.actors.Alex.id},base(6))).status,200);
  assert.equal((await f.http('Mia','POST','/commands',change)).status,404);
  assert.equal((await f.http('Mia','GET',path)).status,404);
  assert.deepEqual((await f.http('Alex','GET',path)).data.meals,state.meals);
});

test('placement reviewer reads original snapshot; reporter replay/status survives transfer, closure and expired window without budget disclosure',async()=>{
 const f=await fixture();await f.command('Mia','shop.freeze',{});
 const command=f.envelope('Mia','shop.reportPlaced',{occurredAt:new Date().toISOString()},{shopRevision:2,authorityEpoch:1});
 await f.command('Mia','shop.transferAuthority',{newShopperId:f.actors.Alex.id},{shopRevision:2,authorityEpoch:1});
 const headers={'X-Shop-ID':f.shopId},own='/shops/'+f.shopId+'/placement-reports/mine/'+command.clientKey+'?commandDigest='+digest(command),list='/shops/'+f.shopId+'/placement-reports';
 assert.deepEqual((await f.http('Mia','GET',own,undefined,headers)).data,{status:null});
 const sent=await Promise.all([f.http('Mia','POST','/commands',command,headers),f.http('Mia','POST','/commands',command,headers)]);
 assert.equal(sent[0].status,200,JSON.stringify(sent[0].data));assert.deepEqual(sent[0].data,sent[1].data);
 assert.deepEqual(Object.keys(sent[0].data).sort(),['operationId','kind','reportId','disposition'].sort());
 const page=await f.http('Alex','GET',list);assert.equal(page.status,200,JSON.stringify(page.data));assert.equal(page.data.reports.length,1);
 assert.equal(page.data.shopRevision,2);assert.equal(page.data.authorityEpoch,2);assert.equal(page.data.frozenRevision,2);
 const row=page.data.reports[0];assert.equal(row.reportedAuthorityEpoch,1);assert.equal(row.snapshot.revision,2);assert.equal(row.snapshot.lines[0].originalItem,'Original basket');assert.equal(row.snapshot.budget.totalMinor,3720);
 assert.equal(row.actorId,undefined);assert.equal(row.alias,undefined);assert.equal(row.snapshotDigest,digest(row.snapshot));
 assert.equal((await f.http('Mia','GET',list,undefined,headers)).status,404);assert.equal((await f.http('Sam','GET',list)).status,404);
 const foreign=await fixture();assert.equal((await f.http(foreign.actors.Mia,'GET',list)).status,404);
 const review=f.envelope('Alex','shop.reconcileReport',{reportId:row.reportId,choice:'apply'},{shopRevision:2,authorityEpoch:2});
 const applied=await Promise.all([f.http('Alex','POST','/commands',review),f.http('Alex','POST','/commands',review)]);
 assert.equal(applied[0].status,200);assert.deepEqual(applied[0].data,applied[1].data);
 const detail=await f.http('Alex','GET',list+'/'+row.reportId);assert.equal(detail.data.report.state,'applied');assert.equal(detail.data.report.resolutionClientKey,review.clientKey);
 assert.equal((await f.http('Alex','GET',list)).data.reports.length,0);
 assert.equal((await f.http('Alex','POST','/shops/'+f.shopId+'/financial-reviews',{clientKey:randomUUID(),sourceVersion:{shopRevision:3,authorityEpoch:2,financialRevision:0},allEvidenceEntered:false,closeShop:true})).status,200);
 await admin.query("UPDATE ritc.replay_window SET issued_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE household_id=$1 AND window_id=$2",[f.h,f.actors.Mia.window]);
 assert.equal((await f.http('Mia','POST','/commands',command,headers)).data.error.code,'refresh_required');
 const status=await f.http('Mia','GET',own,undefined,headers);assert.equal(status.status,200,JSON.stringify(status.data));assert.equal(status.data.status.state,'applied');
 assert.deepEqual(Object.keys(status.data.status).sort(),['clientKey','operationId','reportId','shopId','reportedRevision','reportedAuthorityEpoch','occurredAt','receivedAt','source','state'].sort());
 assert.equal(status.data.status.reportedRevision,2);assert.equal(status.data.status.reportedAuthorityEpoch,1);
 assert.equal((await f.http('Mia','GET',own.replace(digest(command),'0'.repeat(64)),undefined,headers)).data.error.code,'key_reused');
 assert.equal((await f.http('Alex','GET',own)).data.status,null);
 assert.equal((await f.http('Mia','GET','/shops/'+f.shopId,undefined,headers)).status,403);
 assert.equal((await f.http('Mia','GET',list,undefined,headers)).status,404);
 assert.equal((await f.http('Mia','GET',list+'/current-shop',undefined,headers)).status,404);
 assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.placement_report WHERE household_id=$1',[f.h])).rows[0].n,1);
 await admin.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2",[f.h,f.actors.Mia.id]);
 assert.equal((await f.http('Mia','GET',own,undefined,headers)).status,403);
});

test('changed basket cannot apply an old placement; concurrent current-shopper resolution and transfer preserve one resolution',async()=>{
 const f=await fixture();await f.command('Mia','shop.freeze',{});
 await f.command('Mia','shop.transferAuthority',{newShopperId:f.actors.Alex.id},{shopRevision:2,authorityEpoch:1});
 await f.command('Alex','shop.reopen',{}, {shopRevision:2,authorityEpoch:2});
 await f.command('Alex','shop.patch',{quote:f.quote,lines:[{...f.line,originalItem:'New private basket',unitPriceMinor:1200}]},{shopRevision:3,authorityEpoch:2});
 await f.command('Alex','shop.freeze',{}, {shopRevision:4,authorityEpoch:2});
 const reported=await f.command('Mia','shop.reportPlaced',{occurredAt:new Date().toISOString()},{shopRevision:2,authorityEpoch:1});
 const path='/shops/'+f.shopId+'/placement-reports',page=await f.http('Alex','GET',path);assert.equal(page.data.reports[0].snapshot.lines[0].originalItem,'Original basket');
 assert.equal(page.data.frozenRevision,5);assert.equal(page.data.reports[0].reportedRevision,2);
 const apply=await f.command('Alex','shop.reconcileReport',{reportId:reported.data.reportId,choice:'apply'},{shopRevision:5,authorityEpoch:2});assert.equal(apply.data.error.code,'reconciliation_required');
 const choice=f.envelope('Alex','shop.reconcileReport',{reportId:reported.data.reportId,choice:'reject'},{shopRevision:5,authorityEpoch:2});
 const transfer=f.envelope('Mia','shop.transferAuthority',{newShopperId:f.actors.Mia.id},{shopRevision:5,authorityEpoch:2});
 const raced=await Promise.all([f.http('Alex','POST','/commands',choice),f.http('Mia','POST','/commands',transfer)]);assert.equal(raced[1].status,200,JSON.stringify(raced));assert.ok([200,404].includes(raced[0].status));
 const current=await f.http('Mia','GET','/shops/'+f.shopId);assert.equal(current.data.shopRevision,5);assert.equal(current.data.authorityEpoch,3);assert.equal(current.data.phase,'frozen');assert.equal(current.data.lines[0].originalItem,'New private basket');
 const detail=await f.http('Mia','GET',path+'/'+reported.data.reportId);assert.equal(detail.data.report.state,raced[0].status===200?'rejected':'pending_reconciliation');
 assert.equal(detail.data.report.resolutionClientKey,null);assert.equal((await f.http('Alex','GET',path)).status,404);
 if(raced[0].status===404){const resolved=await f.command('Mia','shop.reconcileReport',{reportId:reported.data.reportId,choice:'reject'},{shopRevision:5,authorityEpoch:3});assert.equal(resolved.status,200);}
 assert.equal((await f.http('Mia','GET',path)).data.reports.length,0);
 assert.equal((await f.http('Mia','POST','/shops/'+f.shopId+'/financial-reviews',{clientKey:randomUUID(),sourceVersion:{shopRevision:5,authorityEpoch:3,financialRevision:0},allEvidenceEntered:false,closeShop:true})).status,200);
 assert.equal((await f.http('Alex','POST','/commands',choice,{'X-Shop-ID':f.shopId})).status,404);
});

test('placement report pages are bounded, stable and bind cursors to the authorized shop',async()=>{
 const f=await fixture();await f.command('Mia','shop.freeze',{});await f.command('Mia','shop.transferAuthority',{newShopperId:f.actors.Alex.id},{shopRevision:2,authorityEpoch:1});
 for(let i=0;i<6;i++)assert.equal((await f.command('Mia','shop.reportPlaced',{occurredAt:new Date().toISOString()},{shopRevision:2,authorityEpoch:1})).status,200);
 const path='/shops/'+f.shopId+'/placement-reports',a=await f.http('Alex','GET',path),b=await f.http('Alex','GET',path+'?cursor='+a.data.nextCursor);
 assert.equal(a.data.reports.length,5);assert.equal(a.data.nextCursor,a.data.reports[4].reportId);assert.equal(b.data.reports.length,1);assert.equal(b.data.nextCursor,null);
 assert.equal(new Set([...a.data.reports,...b.data.reports].map(r=>r.reportId)).size,6);
 assert.equal((await f.http('Alex','GET',path+'?cursor='+randomUUID())).status,404);
});


test('placement command digest matches the native fixed sorted-byte fixture',()=>{
 const command={v:1,replayWindow:'00000000-0000-4000-8000-000000000062',clientKey:'00000000-0000-4000-8000-000000000061',shopId:'00000000-0000-4000-8000-000000000063',kind:'shop.reportPlaced',base:{shopRevision:4,authorityEpoch:2},body:{occurredAt:'2026-11-03T00:00:00Z'}};
 assert.equal(digest(command),'2c5085b9ab57695f68a2164a13508eb7b1a511f08aeaa6417a1fd357df7a1218');
});

test('S24 reviewed pack source persists in private exact preview and atomic apply without author leakage',async()=>{
  const f=await fixture(),sent=await f.send('Sam');
  const q=n=>({numerator:String(n),denominator:'1',unit:'count',originalLiteral:String(n)});
  const line={lineId:randomUUID(),originalItem:'Reviewed four-wrap pack',packs:2,unitPriceMinor:300,feeEligible:true};
  const evidence={version:1,offerId:'reviewed-shelf-A',label:line.originalItem,needed:q(8),usablePerPack:q(4),packs:2,unitPriceMinor:300,productMatchConfirmed:true,availabilityConfirmed:true,availablePackLimit:2,quoteSource:'Private reviewed shelf source',quoteObservedAt:new Date().toISOString(),reviewedAt:new Date().toISOString()};
  const decision={choice:'add',line,promote:false,reviewedPackEvidence:evidence};
  const denied=await f.preview(sent.request,decision,'Sam');assert.notEqual(denied.status,200);
  const preview=await f.preview(sent.request,decision);assert.equal(preview.status,200,JSON.stringify(preview.data));
  const saved=(await admin.query('SELECT decision,fingerprint FROM ritc.preview WHERE household_id=$1 AND preview_id=$2',[f.h,preview.data.previewId])).rows[0];
  assert.deepEqual(saved.decision.reviewedPackEvidence,evidence);assert.equal(preview.data.after.totalMinor,4320);
  const alternate=await f.preview(sent.request,{...decision,reviewedPackEvidence:{...evidence,quoteSource:'Another explicitly reviewed source'}});assert.equal(alternate.status,200);
  const other=(await admin.query('SELECT fingerprint FROM ritc.preview WHERE household_id=$1 AND preview_id=$2',[f.h,alternate.data.previewId])).rows[0];assert.notEqual(other.fingerprint,saved.fingerprint);
  const command=f.envelope('Mia','request.apply',{requestId:sent.request.requestId,previewId:preview.data.previewId,acceptOverage:true,acceptUnknown:false},{shopRevision:1,authorityEpoch:1,requestRevision:1});
  const applied=await f.http('Mia','POST','/commands',command);assert.equal(applied.status,200,JSON.stringify(applied.data));
  assert.deepEqual((await f.http('Mia','POST','/commands',command)).data,applied.data);
  const persisted=(await admin.query('SELECT decision FROM ritc.preview WHERE household_id=$1 AND preview_id=$2',[f.h,preview.data.previewId])).rows[0];assert.deepEqual(persisted.decision.reviewedPackEvidence,evidence);
  const shop=await f.http('Mia','GET','/shops/'+f.shopId);assert.equal(shop.data.lines.length,2);assert.deepEqual(shop.data.lines.find(l=>l.lineId===line.lineId),line);
  const own=await f.http('Sam','GET','/requests/mine');assert.equal(own.data.requests[0].status,'added');assert.equal(JSON.stringify(own.data).includes('quoteSource'),false);assert.equal(JSON.stringify(own.data).includes('Private reviewed shelf source'),false);
});

test('request page clocks come from the scoped read and leave exact command replay immutable',async()=>{
  const f=await fixture();
  const before=(await admin.query('SELECT clock_timestamp() AS t')).rows[0].t;
  const empty=await f.http('Sam','GET','/requests/mine');
  const sent=await f.send('Sam',{authoredAt:'2025-01-01T00:00:00Z'});
  const own=await f.http('Sam','GET','/requests/mine');
  const inbox=await f.http('Mia','GET','/shops/'+f.shopId+'/inbox');
  const after=(await admin.query('SELECT clock_timestamp() AS t')).rows[0].t;
  for(const response of [empty,own,inbox]){
    assert.equal(response.status,200);
    const asOf=Date.parse(response.data.asOf);
    assert.ok(asOf>=before.getTime() && asOf<=after.getTime());
  }
  assert.deepEqual(empty.data.requests,[]);
  assert.equal(own.data.requests[0].authorAlias,undefined);
  assert.equal(inbox.data.requests[0].authorAlias,'Sam');
  assert.equal((await f.http('Jo','GET','/requests/mine?cursor='+sent.request.requestId)).status,404);
  for(let i=0;i<50;i++)await f.send('Sam',{originalItem:'Request '+i});
  const first=(await f.http('Sam','GET','/requests/mine')).data;
  assert.equal(first.requests.length,50);
  assert.equal(first.requests[0].requestId,sent.request.requestId);
  const edit=f.envelope('Sam','request.edit',{requestId:sent.request.requestId,originalItem:'Plain cereal',ownQuantity:'2 boxes'},
    {shopRevision:0,authorityEpoch:0,requestRevision:1});
  const changed=await f.http('Sam','POST','/commands',edit);
  assert.equal(changed.status,200);
  const preview=await f.preview(changed.data.request,{choice:'defer'});
  const applied=await f.command('Mia','request.apply',{requestId:sent.request.requestId,previewId:preview.data.previewId,acceptOverage:false,acceptUnknown:false},
    {shopRevision:1,authorityEpoch:1,requestRevision:2});
  assert.equal(applied.status,200);
  const more=(await f.http('Sam','GET','/requests/mine?cursor='+first.nextCursor)).data;
  assert.equal(more.requests.length,1);
  assert.ok(Date.parse(more.asOf)>Date.parse(first.asOf));
  assert.equal(first.requests[0].status,'pending');
  assert.equal((await f.http('Jo','GET','/requests/mine?cursor='+first.nextCursor)).status,404);
  const replay=await f.http('Sam','POST','/commands',edit);
  assert.deepEqual(replay.data,changed.data);
  assert.equal(replay.data.asOf,undefined);
  const current=(await f.http('Sam','GET','/requests/mine')).data;
  assert.equal(current.requests[0].revision,3);
  assert.equal(current.requests[0].status,'deferred');
  assert.ok(Date.parse(current.asOf)>=Date.parse(more.asOf));
});

test('two contributor web sessions see only their own purchase receipt through shopper corrections',
  {skip:process.env.RITC_TEST_WEB_WIRE!=='1'}, async t=>{
  const [{JSDOM},{IDBFactory},{WebApp},{API},{Outbox}]=await Promise.all([
    import('../../web/node_modules/jsdom/lib/api.js'),import('../../web/node_modules/fake-indexeddb/build/esm/index.js'),
    import('../../web/dist/app.js'),import('../../web/dist/api.js'),import('../../web/dist/outbox.js')
  ]);
  const f=await purchaseFixture('Alex'),other=await fixture();
  const outsider=other.actors.Alex;
  const invitation=await f.http('Mia','POST','/invites',{kind:'adult_contributor',expiresInHours:1});
  assert.equal(invitation.status,200);
  const joined=await f.http(outsider,'POST','/v1/invites/redeem',{token:invitation.data.token,intent:'join',adultAttestation:true,alias:'Second contributor'});
  assert.equal(joined.status,200);

  async function openBrowser(actor,language){
    const active=await f.http(actor,'POST','/v1/session',{householdId:f.h,shopId:f.shopId});
    assert.equal(active.status,200,JSON.stringify(active.data));
    assert.equal(active.data.role,'contributor');
    const cookie=active.headers.get('set-cookie').split(';')[0];
    let rows;
    const api=new API(async(path,options)=>{
      const res=await fetch(origin+path,{...options,headers:{...options.headers,Cookie:cookie,Origin:'https://web.fixture.invalid'}});
      if(path.includes('/requests/mine') && res.ok)rows=(await res.clone().json()).requests;
      return res;
    });
    const dom=new JSDOM('<div id="app"></div>',{url:'https://web.fixture.invalid/requests'});
    t.after(()=>dom.window.close());
    Object.defineProperty(dom.window.navigator,'language',{value:language});
    const root=dom.window.document.querySelector('#app');
    const app=new WebApp(root,api,new Outbox(new IDBFactory()));
    await app.start();
    return {root,rows:()=>rows,refresh:async()=>{
      const id=language==='es'?'Actualizar':'Refresh';
      const refresh=[...root.querySelectorAll('button')].find(b=>b.textContent===id);
      assert.ok(refresh);refresh.click();
      const deadline=Date.now()+5000;
      while(root.querySelector('main')?.getAttribute('aria-busy')==='true'){
        assert.ok(Date.now()<deadline);await new Promise(resolve=>setTimeout(resolve,5));
      }
    }};
  }
  const alex=await openBrowser('Alex','es'),observer=await openBrowser(outsider,'en');
  let revision=f.requestRevision;
  for(const [outcome,label] of [
    [null,'Compra sin confirmar'],['bought','La persona que hizo la compra confirmó que compró el artículo'],
    ['notBought','La persona que hizo la compra confirmó que no compró el artículo'],['unknown','Compra sin confirmar']
  ]){
    if(outcome){
      const saved=await f.command('Mia','request.confirmPurchase',
        {requestId:f.requestId,lineId:f.lineId,placedRevision:f.placedRevision,outcome},
        {shopRevision:f.shopRevision,authorityEpoch:1,requestRevision:revision});
      assert.equal(saved.status,200,JSON.stringify(saved.data));revision=saved.data.requestRevision;
    }
    await Promise.all([alex.refresh(),observer.refresh()]);
    assert.deepEqual(alex.rows().map(r=>r.requestId),[f.requestId]);
    const [own]=alex.rows();
    assert.equal(own.revision,revision);assert.equal(own.status,'added');
    assert.equal(own.purchaseOutcome,outcome==='bought'||outcome==='notBought'?outcome:undefined);
    assert.equal(Object.hasOwn(own,'linkedLineId'),false);
    assert.equal(Object.hasOwn(own,'unitPriceMinor'),false);
    assert.ok([...alex.root.querySelectorAll('p')].some(p=>p.textContent===label));
    assert.deepEqual(observer.rows(),[]);
    assert.match(alex.root.textContent,/Consultada en el servidor/);
    assert.match(observer.root.textContent,/Checked on server/);
    assert.doesNotMatch(observer.root.textContent,/Fictional cereal|Shopper confirmed|Purchase not confirmed/);
  }
});

if(process.env.RITC_TEST_NATIVE_WIRE==='1') test('assigned iPhone shopper confirms and corrects a placed request over pinned HTTPS',async()=>{
  const f=await purchaseFixture('Alex');
  const {exerciseNativeClient}=await import('./native-wire.mjs');
  await exerciseNativeClient({service:server,owner:f.actors.Mia,householdId:f.h,shopId:f.shopId,purchaseRequestId:f.requestId});
  await exerciseNativeClient({service:server,owner:f.actors.Alex,householdId:f.h,shopId:f.shopId,purchaseRequestId:f.requestId,purchaseReader:true});
  const mine=(await f.http('Alex','GET','/requests/mine')).data.requests;
  assert.equal(mine.length,1);assert.equal(mine[0].requestId,f.requestId);
  assert.equal(mine[0].status,'added');assert.equal(mine[0].revision,f.requestRevision+3);
  assert.equal(mine[0].purchaseOutcome,'notBought');assert.equal(mine[0].linkedLineId,undefined);
});

async function nextDraft(f) {
  const shopId=randomUUID();
  const created=await f.http('Mia','POST','/commands',{...f.envelope('Mia','shop.create',
    {quote:f.quote,lines:[]},{shopRevision:0,authorityEpoch:0}),shopId});
  assert.equal(created.status,200,JSON.stringify(created.data));
  return shopId;
}

async function deferredFixture(actor='Sam',requestDetails={}) {
  const f=await fixture(),original=(await f.send(actor,requestDetails)).request;
  const placed=await f.command('Mia','shop.reportPlaced',{occurredAt:new Date().toISOString()});
  assert.equal(placed.status,200);
  const dest=await nextDraft(f);
  const page=(id=dest,member='Mia',cursor='')=>f.http(member,'GET','/shops/'+id+'/deferred-requests'+(cursor?'?cursor='+cursor:''),undefined,{'X-Shop-ID':id});
  const candidate=(await page()).data.requests[0];
  const carry=(id=dest,source=candidate)=>({...f.envelope('Mia','request.carry',
    {sourceShopId:source.sourceShopId,sourceAuthorityEpoch:source.sourceAuthorityEpoch,requestId:source.requestId},
    {shopRevision:1,authorityEpoch:1,requestRevision:source.requestRevision}),shopId:id});
  const run=(e,actor='Mia')=>f.http(actor,'POST','/commands',e,{'X-Shop-ID':e.shopId});
  const inbox=async(id,member='Mia')=>(await f.http(member,'GET','/shops/'+id+'/inbox',undefined,{'X-Shop-ID':id})).data.requests;
  return {...f,original,dest,page,candidate,carry,run,inbox};
}

test('deferred request enters a later blank shop only once, with original authorship and a fresh price decision',async()=>{
  const f=await deferredFixture(),candidate=f.candidate,source=f.original;
  assert.deepEqual(candidate,{sourceShopId:f.shopId,sourceAuthorityEpoch:1,requestId:source.requestId,requestRevision:2,
    originalItem:source.originalItem,ownQuantity:source.ownQuantity,authorAlias:'Sam',authoredAt:source.authoredAt,receivedAt:source.receivedAt});
  assert.deepEqual((await f.page()).data,{shopId:f.dest,shopRevision:1,authorityEpoch:1,requests:[candidate],nextCursor:null});
  const before=(await f.http('Mia','GET','/shops/'+f.shopId)).data;
  const sourcePreview=await f.preview(source,{choice:'handled'},'Mia',{shopRevision:2,authorityEpoch:1,requestRevision:2});
  assert.equal(sourcePreview.status,200);
  assert.deepEqual(await f.inbox(f.dest),[]);
  const draftBefore=(await f.http('Mia','GET','/shops/'+f.dest)).data;
  assert.deepEqual(draftBefore.lines,[]);
  const cmd=f.carry(),[first,retry]=await Promise.all([f.run(cmd),f.run(cmd)]);
  assert.equal(first.status,200,JSON.stringify(first.data));
  const id=first.data.operationId;
  assert.deepEqual(first.data,{operationId:id,kind:'request.carry',shopId:f.dest,shopRevision:1,authorityEpoch:1,
    disposition:'recorded',requestId:id,requestRevision:1,sourceRequestId:source.requestId});
  assert.deepEqual(first.data,retry.data);assert.notEqual(id,source.requestId);
  assert.deepEqual((await f.page()).data.requests,[]);
  assert.deepEqual((await f.http('Mia','GET','/shops/'+f.dest)).data,draftBefore);
  assert.deepEqual((await f.http('Mia','GET','/shops/'+f.shopId)).data,before);
  const [old]=await f.inbox(f.shopId),[copy]=await f.inbox(f.dest);
  assert.equal(old.carriedForward,true);assert.equal(old.revision,2);assert.equal(old.ownActionAllowed,false);
  assert.deepEqual(copy,{requestId:id,shopId:f.dest,revision:1,originalItem:source.originalItem,ownQuantity:source.ownQuantity,
    authoredAt:source.authoredAt,receivedAt:copy.receivedAt,route:'current',status:'pending',fromPreviousShop:true,
    ownActionAllowed:true,clarification:null,followupTo:null,authorAlias:'Sam'});
  assert(Date.parse(copy.receivedAt)>=Date.parse(source.receivedAt));
  assert.deepEqual((await f.http('Jo','GET','/requests/mine')).data.requests,[]);
  assert.deepEqual((await f.http('Sam','GET','/requests/mine')).data.requests.map(r=>[r.shopId,r.ownActionAllowed]),[[f.shopId,false],[f.dest,true]]);
  for(const [kind,body] of [['request.edit',{originalItem:'Changed',ownQuantity:null}],['request.withdraw',{}]]){
    const r=await f.command('Sam',kind,{requestId:source.requestId,...body},{shopRevision:0,authorityEpoch:0,requestRevision:2});
    assert.equal(r.data.error.code,'followup_required');
  }
  assert.equal((await f.send('Sam',{followupTo:source.requestId})).request.followupTo,source.requestId);
  const body={requestId:source.requestId,previewId:sourcePreview.data.previewId,acceptOverage:false,acceptUnknown:false};
  assert.equal((await f.command('Mia','request.apply',body,{shopRevision:2,authorityEpoch:1,requestRevision:2})).data.error.code,'already_handled');
  assert.equal((await f.run({...f.envelope('Mia','request.apply',{...body,requestId:id},{shopRevision:1,authorityEpoch:1,requestRevision:1}),shopId:f.dest})).status,404);
  const base={shopRevision:1,authorityEpoch:1,requestRevision:1};
  const preview=await f.http('Mia','POST','/shops/'+f.dest+'/previews',{requestId:id,base,decision:{choice:'add',
    line:{lineId:randomUUID(),originalItem:copy.originalItem,packs:1,unitPriceMinor:4000,feeEligible:true}}});
  assert.equal(preview.data.requiresOverageAcceptance,true);assert.equal(preview.data.after.overCapMinor,200);
  const apply={...f.envelope('Mia','request.apply',{...body,requestId:id,previewId:preview.data.previewId},base),shopId:f.dest};
  assert.equal((await f.run(apply)).data.error.code,'overage_acceptance_required');
  apply.body.acceptOverage=true;assert.equal((await f.run(apply)).data.disposition,'added');
  assert.equal((await f.run({...f.envelope('Mia','shop.reportPlaced',{occurredAt:new Date().toISOString()},{shopRevision:2,authorityEpoch:1}),shopId:f.dest})).status,200);
  assert.deepEqual((await f.run(cmd)).data,first.data);
  assert.deepEqual((await f.http('Mia','GET','/shops/'+f.shopId)).data,before);
});

test('deferred request rejects ungranted sources, stale reviews, concurrent destinations and transferred receipt authority',async()=>{
  for(const side of ['source','destination']) {
    const f=await deferredFixture(),g=await fixture(),other=await nextDraft(f),cmd=f.carry();
    for(const member of ['Sam','Jo','Alex'])assert.equal((await f.page(f.dest,member)).status,404);
    assert.equal((await f.page(f.dest,g.actors.Mia)).status,404);
    assert.equal((await f.http('Mia','GET','/shops/'+f.dest+'/deferred-requests',undefined,{'X-Shop-ID':f.shopId})).status,404);
    for(const update of [{body:{...cmd.body,sourceShopId:g.shopId}},{body:{...cmd.body,requestId:randomUUID()}}])assert.equal((await f.run({...cmd,...update})).status,404);
    assert.equal((await f.run({...cmd,base:{...cmd.base,requestRevision:1}})).data.error.code,'stale_base');
    assert.equal((await f.run({...cmd,body:{...cmd.body,sourceAuthorityEpoch:2}})).data.error.code,'authority_changed');
    assert.equal((await f.run({...cmd,base:{...cmd.base,shopRevision:2}})).data.error.code,'stale_base');
    const rival=f.carry(other),results=await Promise.all([f.run(cmd),f.run(rival)]);
    assert.deepEqual(results.map(r=>r.status).sort(),[200,404]);
    const winner=results[0].status===200?cmd:rival;
    assert.equal((await f.run(winner)).status,200);
    const selected=side==='source'?f.shopId:winner.shopId,revision=side==='source'?2:1;
    const transfer=(member,epoch)=>f.run({...f.envelope('Mia','shop.transferAuthority',{newShopperId:f.actors[member].id},
      {shopRevision:revision,authorityEpoch:epoch}),shopId:selected});
    assert.equal((await transfer('Alex',1)).status,200);
    assert.notEqual((await f.run(winner)).status,200);
    assert.equal((await transfer('Mia',2)).status,200);
    assert.equal((await f.run(winner)).data.error.code,'refresh_required');
    assert.deepEqual((await f.page(other)).data.requests,[]);
  }
});

test('deferred request can be explicitly carried again after another deferral, and consent loss blocks the full chain',async()=>{
  const f=await deferredFixture(),first=f.carry(),firstReceipt=await f.run(first),id=firstReceipt.data.requestId;
  const base={shopRevision:1,authorityEpoch:1,requestRevision:1};
  const pv=await f.http('Mia','POST','/shops/'+f.dest+'/previews',{requestId:id,base,decision:{choice:'defer'}});
  assert.equal((await f.run({...f.envelope('Mia','request.apply',{requestId:id,previewId:pv.data.previewId,acceptOverage:false,acceptUnknown:false},base),shopId:f.dest})).data.disposition,'deferred');
  assert.equal((await f.run({...f.envelope('Mia','shop.reportPlaced',{occurredAt:new Date().toISOString()}),shopId:f.dest})).status,200);
  const third=await nextDraft(f),candidates=(await f.page(third)).data.requests;
  assert.deepEqual(candidates.map(r=>r.requestId),[id]);
  const second=f.carry(third,candidates[0]);assert.equal((await f.run(second)).status,200);
  const rows=await f.inbox(f.dest);assert.equal(rows[0].carriedForward,true);assert.equal(rows[0].fromPreviousShop,true);
  assert.deepEqual((await f.page(third)).data.requests,[]);
  const consent=(await admin.query('SELECT consent_id FROM ritc.consent WHERE household_id=$1 AND child_id=$2',[f.h,f.actors.Sam.id])).rows[0].consent_id;
  assert.equal((await f.http('Mia','POST','/guardian/consents/'+consent+'/revoke',{})).status,200);
  for(const shop of [f.shopId,f.dest,third])assert.deepEqual(await f.inbox(shop),[]);
  for(const command of [first,second])assert.equal((await f.run(command)).data.error.code,'refresh_required');
});

test('deferred request pages contain only eligible current grants and exclude older drafts and withdrawn authors',async()=>{
  const f=await fixture(),older=await nextDraft(f);
  const sourceId=await nextDraft(f);
  const request=async(actor,name)=>{
    const sent=await f.http(actor,'POST','/commands',{...f.envelope(actor,'request.send',
      {clientRequestId:randomUUID(),originalItem:name,ownQuantity:null,authoredAt:new Date().toISOString()}),shopId:sourceId});
    assert.equal(sent.status,200);return sent.data.request;
  };
  const names=[];
  for(let i=0;i<52;i++)names.push((await request('Alex','Eligible '+i)).requestId);
  const missing=await request('Jo','Withheld request');
  const consent=(await admin.query('SELECT consent_id FROM ritc.consent WHERE household_id=$1 AND child_id=$2',[f.h,f.actors.Jo.id])).rows[0].consent_id;
  assert.equal((await f.http('Mia','POST','/guardian/consents/'+consent+'/revoke',{})).status,200);
  const perform=cmd=>f.http('Mia','POST','/commands',{...cmd,shopId:sourceId});
  assert.equal((await perform(f.envelope('Mia','shop.reportPlaced',{occurredAt:new Date().toISOString()}))).status,200);
  const dest=await nextDraft(f), page=(id,after='')=>f.http('Mia','GET','/shops/'+id+'/deferred-requests'+after);
  assert.deepEqual((await page(older)).data.requests,[]);
  const first=(await page(dest)).data;
  assert.deepEqual(first.requests.map(r=>r.requestId),names.sort().slice(0,50));
  assert.equal(first.nextCursor,names[49]);
  const second=(await page(dest,'?cursor='+first.nextCursor)).data;
  assert.deepEqual(second.requests.map(r=>r.requestId),names.slice(50));assert.equal(second.nextCursor,null);
  assert.equal((await page(dest,'?cursor='+missing.requestId)).status,404);
  const candidate=first.requests[0],carry={...f.envelope('Mia','request.carry',
    {sourceShopId:sourceId,sourceAuthorityEpoch:1,requestId:candidate.requestId},{shopRevision:1,authorityEpoch:1,requestRevision:2}),shopId:dest};
  const transfer=(name,epoch)=>perform(f.envelope('Mia','shop.transferAuthority',{newShopperId:f.actors[name].id},{shopRevision:2,authorityEpoch:epoch}));
  assert.equal((await transfer('Alex',1)).status,200);
  assert.deepEqual((await page(dest)).data.requests,[]);
  assert.equal((await f.http('Mia','POST','/commands',carry)).status,404);
  assert.equal((await transfer('Mia',2)).status,200);
  assert.equal((await f.http('Mia','POST','/commands',carry)).data.error.code,'authority_changed');
  assert.equal((await page(dest)).data.requests[0].sourceAuthorityEpoch,3);
});

test('standalone household pantry checks a live adult grant and device before any receipt, with zero shops',async()=>{
  const f=await fixture({createShop:false}),foreign=await fixture({createShop:false});
  const get=(actor,path='/pantry',headers={})=>f.http(actor,'GET',path,undefined,headers);
  const grant=(enabled,expectedGrantEpoch)=>f.http('Mia','POST','/pantry/grants',
    {v:1,memberId:f.actors.Alex.id,enabled,expectedGrantEpoch});
  const write=(actor,c)=>f.http(actor,'POST','/pantry/commands',c);
  const first=await get('Mia','/pantry',{'X-Shop-ID':randomUUID()});
  assert.equal(first.status,200);assert.deepEqual(first.data.lots,[]);
  assert.equal(first.data.grantEpoch,0);assert.equal(first.data.householdId,f.h);
  assert.deepEqual((await get('Mia','/pantry/grants')).data.adults,[{memberId:f.actors.Alex.id,label:'Alex',enabled:false,grantEpoch:0}]);
  assert.equal((await get('Alex')).status,404);assert.equal((await get('Sam')).status,404);
  assert.equal((await f.http('Mia','POST','/pantry/grants',{v:1,memberId:f.actors.Sam.id,enabled:true,expectedGrantEpoch:0})).status,404);
  assert.equal((await f.http('Mia','POST','/pantry/grants',{v:1,memberId:f.actors.Mia.id,enabled:false,expectedGrantEpoch:0})).status,404);
  const granted=(await grant(true,0)).data;assert.equal(granted.adults[0].grantEpoch,1);
  assert.deepEqual((await grant(true,0)).data,granted);
  assert.equal((await get('Alex','/pantry/grants')).status,404);
  assert((await get('Alex','/bootstrap')).data.capabilities.includes('household_pantry'));
  assert(!(await get('Sam','/bootstrap')).data.capabilities.includes('household_pantry'));
  assert((await get('Alex','/bootstrap')).data.capabilities.includes('household_tonight'));
  assert(!(await get('Sam','/bootstrap')).data.capabilities.includes('household_tonight'));
  assert.equal((await get('Sam','/pantry/tonight')).status,404);
  const page=(await get('Alex')).data,time=new Date(Date.now()-1000).toISOString();
  const data={v:1,kind:'pantry.addLot',clientKey:randomUUID(),replayWindow:f.actors.Alex.window,
    grantEpoch:page.grantEpoch,pantryRevision:page.pantryRevision,body:{foodName:'Cold peas',location:'fridge',storedAt:time,useFirstAt:null,
      exclusionTags:[],confirmedAt:time,quantity:{unit:'count',amount:{numerator:3,denominator:2},originalLiteral:'1 1/2'}}};
  assert.equal((await write('Alex',{...data,body:{...data.body,foodName:'bad\u0000name'}})).status,422);
  assert.equal((await write('Alex',{...data,body:{...data.body,actorId:f.actors.Mia.id}})).status,422);
  const [one,other]=await Promise.all([write('Alex',data),write('Alex',{...data,clientKey:randomUUID(),body:{...data.body,foodName:'Another'}})]);
  assert.deepEqual([one.status,other.status].sort(),[200,409]);
  const observed=(await get('Mia')).data;
  assert.equal(observed.lots.length,1);assert.deepEqual(observed.lots[0].observation.quantity,data.body.quantity);
  assert.deepEqual(Object.keys(observed.lots[0]).sort(),['exclusionTags','foodName','location','lotId','observation','origin','purchaseObservation','storedAt','useFirstAt'].sort());
  assert.equal(observed.lots[0].location,'fridge');assert.equal(JSON.stringify(observed).includes(f.actors.Alex.id),false);
  const request={...data,pantryRevision:observed.pantryRevision,clientKey:randomUUID()};
  const committed=await write('Alex',request);assert.equal(committed.status,200,JSON.stringify(committed.data));
  assert.deepEqual((await write('Alex',request)).data,committed.data);
  assert.equal((await write('Alex',{...request,body:{...request.body,foodName:'different'}})).data.error.code,'key_reused');
  const lotId=committed.data.lotId,quantity={unit:'count',amount:{numerator:0,denominator:1},originalLiteral:'0'};
  const correction={...request,kind:'pantry.correctCount',clientKey:randomUUID(),pantryRevision:committed.data.pantryRevision,
    body:{lotId,predecessorId:committed.data.operationId,confirmedAt:time,quantity}};
  assert.equal((await write('Alex',{...correction,body:{...correction.body,predecessorId:randomUUID()}})).data.error.code,'stale_supply');
  assert.equal((await write('Alex',{...correction,body:{...correction.body,lotId:randomUUID()}})).status,404);
  const fixed=await write('Alex',correction);assert.equal(fixed.status,200,JSON.stringify(fixed.data));
  assert.equal(fixed.data.lotId,lotId);assert.notEqual(fixed.data.operationId,lotId);
  assert.deepEqual((await get('Mia')).data.lots.find(l=>l.lotId===lotId).observation.quantity,quantity);
  const missing={...correction,clientKey:randomUUID(),pantryRevision:fixed.data.pantryRevision,
    body:{...correction.body,predecessorId:fixed.data.operationId,quantity:null}};
  const unknown=await write('Alex',missing);assert.equal(unknown.status,200);
  assert.deepEqual((await write('Alex',correction)).data,fixed.data);
  assert.equal((await write('Alex',{...correction,body:{...correction.body,quantity:null}})).data.error.code,'key_reused');
  assert.equal((await write('Alex',{...correction,clientKey:randomUUID()})).data.error.code,'stale_supply');
  const reopened=(await get('Alex')).data;
  assert.equal(reopened.pantryRevision,unknown.data.pantryRevision);
  assert.equal(reopened.lots.length,2);assert.equal(reopened.lots.find(l=>l.lotId===lotId).observation.quantity,null);
  const events=(await admin.query(`SELECT operation_id,predecessor_observation_id AS predecessor,quantity,shop_id
    FROM ritc.pantry_event WHERE household_id=$1 AND lot_id=$2 ORDER BY pantry_revision`,[f.h,lotId])).rows;
  assert.deepEqual(events.map(e=>[e.operation_id,e.predecessor,e.quantity,e.shop_id]),[
    [lotId,null,request.body.quantity,null],[fixed.data.operationId,lotId,quantity,null],
    [unknown.data.operationId,fixed.data.operationId,null,null]]);
  const scoped=(await get('Mia','/pantry',{'X-View-Grant-ID':randomUUID()}));assert(scoped.status>=400);
  assert.equal((await foreign.http('Mia','GET','/pantry')).data.lots.length,0);
  assert.equal((await foreign.http(f.actors.Alex,'GET','/pantry')).status,404);
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.shop WHERE household_id=$1',[f.h])).rows[0].n,0);

  assert.equal((await grant(false,1)).data.adults[0].grantEpoch,2);
  assert.equal((await get('Alex')).status,404);assert.equal((await write('Alex',request)).status,404);
  assert.equal((await write('Alex',correction)).status,404);
  assert.equal((await grant(true,0)).status,409);
  assert.equal((await grant(true,2)).data.adults[0].grantEpoch,3);
  assert.equal((await write('Alex',request)).data.error.code,'refresh_required');
  assert.equal((await write('Alex',{...request,grantEpoch:3})).data.error.code,'refresh_required');
  assert.equal((await write('Alex',{...correction,grantEpoch:3})).data.error.code,'refresh_required');
  const now=(await get('Mia')).data;
  const keep={...data,clientKey:randomUUID(),grantEpoch:now.grantEpoch,replayWindow:f.actors.Mia.window,pantryRevision:now.pantryRevision,
    body:{...data.body,foodName:'Independent flour',location:'pantry',quantity:null}};
  const survivor=await write('Mia',keep);assert.equal(survivor.status,200);
  const edited={...data,grantEpoch:3,clientKey:randomUUID(),pantryRevision:now.pantryRevision+1};
  const later=await write('Alex',edited);assert.equal(later.status,200);
  const erasedCorrection={...correction,clientKey:randomUUID(),grantEpoch:3,pantryRevision:later.data.pantryRevision,
    body:{...correction.body,lotId:survivor.data.lotId,predecessorId:survivor.data.operationId}};
  assert.equal((await write('Alex',erasedCorrection)).status,200);
  await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.actors.Alex.id]);
  const survivingLots=(await get('Mia')).data.lots;
  assert.deepEqual(survivingLots.map(l=>l.foodName),['Independent flour']);
  assert.equal(survivingLots[0].observation,null);
  assert.equal((await write('Alex',erasedCorrection)).data.error.code,'refresh_required');
  assert.equal((await write('Alex',edited)).data.error.code,'refresh_required');
  await admin.query("UPDATE ritc.replay_window SET revoked_at=clock_timestamp() WHERE household_id=$1 AND window_id=$2",[f.h,f.actors.Mia.window]);
  assert.equal((await write('Mia',keep)).data.error.code,'refresh_required');
  await admin.query('UPDATE ritc.device SET revoked_at=clock_timestamp() WHERE household_id=$1 AND device_id=$2',[f.h,f.actors.Mia.deviceId]);
  assert.equal((await write('Mia',keep)).status,403);
});

test('private household preference grants, reviewed updates and revoked retries are isolated from pantry',async()=>{
  const f=await fixture({createShop:false}), other=await fixture({createShop:false});
  const path='/meal-preferences', get=(name,headers={})=>f.http(name,'GET',path,undefined,headers);
  const grant=(enabled,expectedGrantEpoch)=>f.http('Mia','POST',path+'/grants',
    {v:1,memberId:f.actors.Alex.id,enabled,expectedGrantEpoch});
  const command={v:1,clientKey:randomUUID(),replayWindow:f.actors.Mia.window,grantEpoch:0,expectedRevision:null,
    settings:{exclusions:['peanut'],dislikes:[],preferredBrands:['Casa'],availableAppliances:['stove'],timeLimit:{maximumMinutes:20,strict:true},
      strictDislikes:false,strictBrands:false,strictEffort:false}};
  const write=(command)=>f.http('Mia','POST',path,command);
  assert.equal((await get('Mia',{'X-Shop-ID':randomUUID()})).data.revision,null);
  assert.equal((await get('Alex')).status,404);assert.equal((await get('Sam')).status,404);
  assert.equal((await get('Mia',{'X-View-Grant-ID':randomUUID()})).status,404);
  assert.equal((await f.http('Mia','POST','/pantry/grants',{v:1,memberId:f.actors.Alex.id,enabled:true,expectedGrantEpoch:0})).status,200);
  assert.equal((await get('Alex')).status,404);
  const stored=await write(command);assert.equal(stored.status,200,JSON.stringify(stored.data));
  assert.deepEqual(stored.data.settings,command.settings);assert.deepEqual((await write(command)).data,stored.data);
  assert.equal((await write({...command,settings:null})).status,409);
  assert.equal((await grant(true,0)).status,200);
  const reader=await get('Alex');assert.equal(reader.data.canWrite,false);assert.deepEqual(reader.data.settings,command.settings);
  assert.deepEqual((await other.http('Mia','GET',path)).data.settings,null);
  assert.equal((await f.http('Alex','POST',path,command)).status,404);
  assert.equal((await grant(false,1)).status,200);assert.equal((await get('Alex')).status,404);
  assert.equal((await grant(true,2)).status,200);assert.equal((await get('Alex')).data.grantEpoch,3);
  assert.equal((await grant(false,1)).status,409);
  assert.equal((await write({...command,clientKey:randomUUID(),expectedRevision:stored.data.revision,
    settings:{...command.settings,exclusions:['pin','PIN']}})).status,422);
  const removed=await write({...command,clientKey:randomUUID(),expectedRevision:stored.data.revision,settings:null});
  assert.equal(removed.status,200);assert.equal(removed.data.settings,null);assert.notEqual(removed.data.revision,stored.data.revision);
  assert.equal((await write(command)).status,409);
  assert.equal((await write({...command,expectedRevision:removed.data.revision})).status,409);
  const restored=await write({...command,clientKey:randomUUID(),expectedRevision:removed.data.revision});
  assert.equal(restored.status,200);
  // A second organizer keeps one existing rule and adds another. Erasing the
  // original author must remove the inherited inputs while preserving the new rule.
  await admin.query("UPDATE ritc.member SET organizer=true WHERE household_id=$1 AND member_id=$2",[f.h,f.actors.Alex.id]);
  const transferred=(await get('Alex')).data;
  const updated=await f.http('Alex','POST',path,{...command,clientKey:randomUUID(),replayWindow:f.actors.Alex.window,
    expectedRevision:transferred.revision,grantEpoch:transferred.grantEpoch,settings:{...command.settings,exclusions:['Peanut','mushroom']}});
  assert.equal(updated.status,200,JSON.stringify(updated.data));
  const client=await admin.connect(),job=randomUUID(),lease=randomUUID();
  try {
    await client.query('BEGIN');
    const hash=tokenHash(issuer+'\n'+f.actors.Mia.subject);
    await client.query(`INSERT INTO ritc.privacy_job(job_id,identity_hash,issuer,subject,receipt_hash,payload_digest,state,receipt_retention_days,marker_retention_days,receipt_until,marker_until,lease_id,lease_until)
      VALUES($1,$2,$3,$4,$5,$5,'processing',1,1,now()+interval '1 day',now()+interval '1 day',$6,now()+interval '1 hour')`,
      [job,hash,issuer,f.actors.Mia.subject,tokenHash(job),lease]);
    await client.query("SELECT set_config('app.erasure_job',$1,true),set_config('app.erasure_lease',$2,true)",[job,lease]);
    await client.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.actors.Mia.id]);
    await client.query('COMMIT');
  } catch(e) { await client.query('ROLLBACK');throw e; } finally {client.release();}
  const erased=await get('Alex');
  assert.deepEqual(erased.data.settings.exclusions,['mushroom']);
  assert.deepEqual(erased.data.settings.preferredBrands,[]);
  assert.equal(erased.data.settings.availableAppliances,undefined);
  assert.notEqual(erased.data.revision,updated.data.revision);
  assert.equal(erased.data.settings.timeLimit,undefined);
  assert.equal((await write(command)).status,409);
  await admin.query('UPDATE ritc.device SET revoked_at=clock_timestamp() WHERE household_id=$1 AND device_id=$2',[f.h,f.actors.Mia.deviceId]);
  assert.equal((await write(command)).status,403);
});

test('duplicate help rechecks the assigned shopper and exact basket candidates before and after matching',async t=>{
  const f=await fixture(), {request}=await f.send('Alex',{originalItem:f.line.originalItem});
  let calls=0, changeAfterSend=false;
  const transport={budget:{dailyAccountRequests:12,dailyMicros:200,maxRequestMicros:5,maxLanguageMicros:5},
    structuredText:async text=>{
      const body=JSON.parse(text);
      calls++;
      assert.equal(body.sourceLines[0].text,f.line.originalItem);
      assert.notEqual(body.sourceLines[0].id,request.requestId);
      assert.equal(body.candidates[0].text,f.line.originalItem);
      assert.notEqual(body.candidates[0].id,f.lineId);
      if(changeAfterSend) await admin.query('UPDATE ritc.basket_line SET original_item=$1 WHERE household_id=$2 AND shop_id=$3 AND line_id=$4',
        ['Changed label',f.h,f.shopId,f.lineId]);
      return {suggestions:[{sourceLineID:body.sourceLines[0].id,candidateID:body.candidates[0].id}]};
    }};
  const mock=createHTTPServer({repository:repo,verifier,receiptAssistance:transport,webOrigin:'https://web.fixture.invalid',maxRequestsPerMinute:10000});
  await new Promise(resolve=>mock.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>mock.close(resolve)));
  const route='http://127.0.0.1:'+mock.address().port+'/v1/households/'+f.h+'/language-assistance/request-duplicate';
  const sourceLines=[{id:request.requestId,text:f.line.originalItem}], candidates=[{id:f.lineId,text:f.line.originalItem}];
  const post=async(actor,overrides={},headers={})=>{
    const user=f.actors[actor];
    return fetch(route,{method:'POST',headers:{authorization:'Bearer '+user.token,'X-Device-Token':user.deviceToken,
      'X-Shop-ID':f.shopId,'Content-Type':'application/json',...headers},body:JSON.stringify({
        version:1,requestID:randomUUID(),issuedAt:Date.now(),consent:true,locale:'en',shopID:f.shopId,shopRevision:1,
        authorityEpoch:1,requestRevision:1,sourceLines,candidates,...overrides})});
  };
  for(const actor of ['Sam','Alex']) assert.equal((await post(actor)).ok,false);
  assert.equal((await post('Mia',{}, {'X-View-Grant-Id':randomUUID()})).ok,false);
  for(const changed of [{shopID:randomUUID()},{requestRevision:2},{shopRevision:2},
    {sourceLines:[{id:request.requestId,text:'Other words'}]},{candidates:[{id:randomUUID(),text:f.line.originalItem}]},
    {candidates:[{id:f.lineId,text:'Other label'}]}]) assert.equal((await post('Mia',changed)).ok,false);
  assert.equal(calls,0);
  const accepted=await post('Mia');
  const reply=await accepted.json();
  assert.equal(accepted.status,200,JSON.stringify(reply));
  assert.deepEqual(reply.suggestions,[{sourceLineID:request.requestId,candidateID:f.lineId}]);
  changeAfterSend=true;
  assert.equal((await post('Mia')).ok,false);
  assert.equal(calls,2);
  const row=await admin.query('SELECT status FROM ritc.request WHERE household_id=$1 AND request_id=$2',[f.h,request.requestId]);
  assert.equal(row.rows[0].status,'pending');
});

test('reviewed shared receipt lines commit once, preserve partial selection and redact every replay after erasure',async()=>{
  const f=await fixture({createShop:false}),foreign=await fixture({createShop:false});
  const grant=(enabled,epoch)=>f.http('Mia','POST','/pantry/grants',{v:1,memberId:f.actors.Alex.id,enabled,expectedGrantEpoch:epoch});
  const page=()=>f.http('Mia','GET','/pantry'), write=(actor,c,headers)=>f.http(actor,'POST','/pantry/commands',c,headers);
  const q=n=>({amount:{numerator:n,denominator:1},unit:'count',originalLiteral:String(n)});
  const line=(ordinal,foodName)=>({ordinal,original:'Printed '+foodName,foodName,location:'pantry',received:q(3),usable:q(2),
    paidUSDMinor:ordinal===0?129:null,delivery:null,printed:null});
  const body={receiptId:randomUUID(),imageId:randomUUID(),layoutId:randomUUID(),merchant:'Market',reference:'Reviewed 123',zone:'UTC',
    purchaseDay:'2026-01-10',lines:[line(0,'Beans'),line(2,'Pears')]};
  const make=(base,body,actor='Alex',epoch=1)=>({v:1,kind:'pantry.acquireReceipt',replayWindow:f.actors[actor].window,
    clientKey:randomUUID(),grantEpoch:epoch,pantryRevision:base,body});
  assert.equal((await write('Alex',make(0,body))).status,404);
  assert.equal((await grant(true,0)).status,200);
  const base=(await page()).data.pantryRevision,command=make(base,body);
  assert.equal((await write('Sam',command)).status,404);
  assert.equal((await write('Alex',command,{'X-View-Grant-ID':randomUUID()})).status,404);
  assert.equal((await write('Alex',{...command,body:{...body,lines:[body.lines[0],{...line(1,'Broken'),usable:q(4)}]}})).status,422);
  const failed={...command,body:{...body,lines:[body.lines[0],{...body.lines[1],delivery:{lotId:randomUUID(),observationId:randomUUID()}}]}};
  assert.equal((await write('Alex',failed)).status,409);
  assert.equal((await page()).data.pantryRevision,base);
  const [a,b]=await Promise.all([write('Alex',command),write('Alex',command)]);
  assert.equal(a.status,200,JSON.stringify(a.data));assert.deepEqual(a,b);
  assert.equal(a.data.pantryRevision,base+1);assert.equal(a.data.savedCount,2);
  assert.deepEqual(a.data.receiptLines.map(l=>l.ordinal),[0,2]);assert.equal(new Set(a.data.receiptLines.map(l=>l.lotId)).size,2);
  const lots=(await page()).data.lots;assert.equal(lots.length,2);
  assert.deepEqual(lots.find(l=>l.foodName==='Beans').receiptEvidence.line.paidUSDMinor,129);
  assert.deepEqual(lots.find(l=>l.foodName==='Pears').observation.quantity,q(2));
  const extended=make(base+1,{...body,lines:[body.lines[0],line(4,'Milk')]});
  const later=await write('Alex',extended);assert.equal(later.status,200,JSON.stringify(later.data));assert.equal(later.data.savedCount,1);
  assert.equal(later.data.receiptLines[0].lotId,a.data.receiptLines[0].lotId);
  assert.deepEqual((await write('Alex',command)).data,a.data);
  assert.equal((await write('Alex',{...command,body:{...body,merchant:'Changed'}})).data.error.code,'key_reused');
  const repeat=make(base+2,body);const noop=await write('Alex',repeat);
  assert.equal(noop.data.savedCount,0);assert.equal(noop.data.pantryRevision,base+2);
  const changed=make(base+2,{...body,lines:[line(7,'Rollback'),{...body.lines[0],usable:q(1)}]});
  assert.equal((await write('Alex',changed)).data.error.code,'receipt_conflict');
  assert.equal((await page()).data.lots.length,3);
  assert.equal((await foreign.http('Mia','GET','/pantry')).data.lots.length,0);
  assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shop WHERE household_id=$1',[f.h])).rows[0].n,0);
  await grant(false,1);assert.equal((await write('Alex',command)).status,404);
  await grant(true,2);assert.equal((await write('Alex',command)).data.error.code,'refresh_required');
  await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.actors.Alex.id]);
  assert.equal((await page()).data.lots.length,0);
  const records=await admin.query('SELECT count(*)::int n FROM ritc.operation_response WHERE household_id=$1 AND operation_id=ANY($2::uuid[])',[f.h,[a.data.operationId,later.data.operationId,noop.data.operationId]]);
  assert.equal(records.rows[0].n,0);
  assert.equal((await write('Mia',make((await page()).data.pantryRevision,body,'Mia',0))).data.error.code,'refresh_required');
});

test('shared receipt reprints cannot append shifted lines or change saved stock and spend',async()=>{
  const f=await fixture({createShop:false});
  const quantity={amount:{numerator:2,denominator:1},unit:'count',originalLiteral:'2'};
  const row=(ordinal,method='pdfOCR')=>({ordinal,original:'OATS 2 CT $4.20',foodName:'Oats',location:'pantry',
    received:quantity,usable:quantity,paidUSDMinor:420,
    printed:method?{page:1,line:ordinal+1,method,stage:'receipt'}:null});
  const original={receiptId:randomUUID(),imageId:randomUUID(),layoutId:randomUUID(),merchant:'Market',reference:'Purchase 123',
    zone:'UTC',purchaseDay:'2026-01-10'};
  const make=(pantryRevision,header,lines)=>({v:1,kind:'pantry.acquireReceipt',replayWindow:f.actors.Mia.window,
    clientKey:randomUUID(),grantEpoch:0,pantryRevision,body:{...header,lines}});
  const send=command=>f.http('Mia','POST','/pantry/commands',command);
  const stock=async()=>(await f.http('Mia','GET','/pantry')).data;
  const expectReview=async command=>{
    const response=await send(command);
    assert.equal(response.status,409);
    assert.equal(response.data.error.code,'receipt_layout_review');
  };
  const firstCommand=make(0,original,[row(0)]),first=await send(firstCommand);
  assert.equal(first.status,200,JSON.stringify(first.data));
  const second=await send(make(1,original,[row(0),row(1)]));
  assert.equal(second.data.savedCount,1);
  assert.equal(second.data.receiptLines[0].lotId,first.data.receiptLines[0].lotId);
  assert.notEqual(second.data.receiptLines[1].lotId,first.data.receiptLines[0].lotId);
  assert.equal((await send(make(2,original,[row(0),row(1)]))).data.savedCount,0);
  const before=await stock();
  assert.equal(before.lots.length,2);
  assert.deepEqual(before.lots.map(l=>l.receiptEvidence.line.paidUSDMinor),[420,420]);
  assert.deepEqual(before.lots.map(l=>l.observation.quantity),[quantity,quantity]);
  // One reprint moves a saved line. Another puts an identical physical line into a known position.
  const reprint={...original,imageId:randomUUID(),layoutId:randomUUID()};
  await Promise.all([expectReview(make(2,reprint,[row(2)])),expectReview(make(2,reprint,[row(0)]))]);
  await expectReview(make(2,{...original,layoutId:randomUUID()},[row(0),row(2)]));
  await expectReview(make(2,{...original,imageId:randomUUID()},[row(2)]));
  const unchanged=await stock();
  assert.equal(unchanged.pantryRevision,before.pantryRevision);
  assert.deepEqual(unchanged.lots,before.lots);
  assert.deepEqual((await send(firstCommand)).data,first.data);
  const aliases=await admin.query('SELECT source_id,original_layout_digest FROM ritc.receipt_source_key WHERE household_id=$1',[f.h]);
  assert.equal(aliases.rowCount,2);
  assert.match(aliases.rows.find(r=>r.source_id===original.receiptId).original_layout_digest,/^[0-9a-f]{64}$/);
  assert.equal(aliases.rows.find(r=>r.source_id===original.imageId).original_layout_digest,null);
  const another={...original,receiptId:randomUUID(),imageId:randomUUID(),reference:'Purchase 456'};
  assert.equal((await send(make(2,another,[row(0)]))).data.savedCount,1);
  // A persisted pre-068 key must still replay byte-for-byte, even when no original layout is known.
  const legacy={...original,receiptId:randomUUID(),imageId:randomUUID(),reference:'Older receipt'};
  delete legacy.layoutId;
  const historicalCommand=make(3,legacy,[row(0,null)]),historical=await send(historicalCommand);
  assert.equal(historical.status,200,JSON.stringify(historical.data));
  const marker=await admin.query('SELECT original_layout_digest FROM ritc.receipt_source_key WHERE household_id=$1 AND source_id=$2',[f.h,legacy.receiptId]);
  assert.equal(marker.rows[0].original_layout_digest,null);
  assert.deepEqual((await send(historicalCommand)).data,historical.data);
  await expectReview(make(4,legacy,[row(1,null)]));
  await expectReview(make(4,{...legacy,layoutId:randomUUID()},[row(1,null)]));
  const textFile={...legacy,receiptId:randomUUID(),imageId:randomUUID(),reference:'UTF-8 receipt'};
  assert.equal((await send(make(4,textFile,[row(0,'textFile')]))).data.savedCount,1);
  assert.equal((await send(make(5,{...textFile,layoutId:randomUUID()},[row(1,'textFile')]))).data.savedCount,1);
  const final=await stock();
  assert.equal(final.pantryRevision,6);
  assert.equal(final.lots.length,6);
  assert.equal(final.lots.reduce((sum,l)=>sum+l.receiptEvidence.line.paidUSDMinor,0),2520);
  // An exact file can gain a missing transaction reference once. Check every saved row,
  // including after a previous row without a reference has already been acquired.
  const imageId=randomUUID(),unidentified={...original,receiptId:imageId,imageId,reference:null};
  const originalCommand=make(6,unidentified,[row(0)]),unreferenced=await send(originalCommand);
  assert.equal(unreferenced.status,200);
  const identified={...unidentified,receiptId:randomUUID(),reference:'Confirmed 123'};
  const identifiedCommand=make(7,identified,[row(1)]),linked=await send(identifiedCommand);
  assert.equal(linked.status,200);
  assert.equal(linked.data.receiptId,imageId);
  assert.deepEqual((await send(originalCommand)).data,unreferenced.data);
  assert.deepEqual((await send(identifiedCommand)).data,linked.data);
  const conflicting={...identified,receiptId:randomUUID(),reference:'Different 456'};
  await expectReview(make(8,conflicting,[row(2)]));
  assert.equal((await stock()).pantryRevision,8);
  const missing=await admin.query('SELECT 1 FROM ritc.receipt_source_key WHERE household_id=$1 AND source_id=$2',[f.h,conflicting.receiptId]);
  assert.equal(missing.rowCount,0);
  const independent=await send(make(8,{...conflicting,imageId:randomUUID()},[row(0)]));
  assert.equal(independent.data.receiptId,conflicting.receiptId);
  assert.equal(independent.data.savedCount,1);
});

test('fifty long reviewed receipt lines remain one bounded household stock revision',async()=>{
 const f=await fixture({createShop:false});
 const quantity={amount:{numerator:1,denominator:1},unit:'count',originalLiteral:'1'};
 const lines=Array.from({length:50},(_,ordinal)=>({ordinal,original:'Grocery '.repeat(215)+ordinal,foodName:'Food '+ordinal,
   location:'pantry',received:quantity,usable:quantity}));
 const body={receiptId:randomUUID(),merchant:'Market',purchaseDay:'2026-01-05',zone:'UTC',lines};
 const command={v:1,kind:'pantry.acquireReceipt',grantEpoch:0,pantryRevision:0,clientKey:randomUUID(),replayWindow:f.actors.Mia.window,body};
 const write=c=>f.http('Mia','POST','/pantry/commands',c);
 assert(Buffer.byteLength(JSON.stringify(command))>65_536);
 assert.equal((await write({...command,body:{...body,lines:[...lines,{...lines[0],ordinal:50}]}})).status,422);
 const saved=await write(command);assert.equal(saved.status,200,JSON.stringify(saved.data));
 assert.equal(saved.data.savedCount,50);assert.equal(saved.data.pantryRevision,1);
 const counts=await admin.query('SELECT count(*)::int n,count(DISTINCT operation_id)::int ops,count(DISTINCT pantry_revision)::int revisions FROM ritc.pantry_event WHERE household_id=$1',[f.h]);
 assert.deepEqual(counts.rows[0],{n:50,ops:1,revisions:1});
});

test('a reported purchaser is separate from the recorder and private to the assigned shopper', async()=>{
  const f=await purchaseFixture(), foreign=await purchaseFixture('Alex');
  const other=(await f.send('Alex')).request;
  const explicit={kind:'requestAuthor',requestId:other.requestId,requestRevision:other.revision,expectedAlias:'Alex'};
  const inbox=async()=> (await f.http('Mia','GET','/shops/'+f.shopId+'/inbox')).data.requests;
  const row=async()=> (await inbox()).find(r=>r.requestId===f.requestId);
  const send=c=>f.http('Mia','POST','/commands',c);
  function command(revision,outcome,reportedPurchaser){
    return f.envelope('Mia','request.confirmPurchase',{requestId:f.requestId,lineId:f.lineId,placedRevision:f.placedRevision,
      outcome,...(reportedPurchaser?{reportedPurchaser}:{})},{shopRevision:f.shopRevision,authorityEpoch:1,requestRevision:revision});
  }
  const rev=f.requestRevision;
  assert.equal((await inbox()).find(r=>r.requestId===other.requestId).canReportAuthorAsPurchaser,true);
  assert.equal((await row()).canReportAuthorAsPurchaser,undefined);
  assert.equal((await send(command(rev,'notBought',explicit))).status,422);
  assert.equal((await send(command(rev,'bought',{...explicit,requestId:foreign.requestId}))).status,404);
  assert.equal((await send(command(rev,'bought',{...explicit,requestRevision:other.revision+1}))).status,409);
  assert.equal((await send(command(rev,'bought',{...explicit,requestId:f.requestId,requestRevision:rev}))).status,404);
  const legacy=await send(command(rev,'bought')); assert.equal(legacy.status,200);
  let current=await row(); assert.equal(current.purchaseRecordedBy,'Mia'); assert.equal(current.reportedPurchaser,undefined);
  const selected=command(current.revision,'bought',explicit);
  const saved=await send(selected); assert.equal(saved.status,200,JSON.stringify(saved.data));
  assert.deepEqual((await send(selected)).data,saved.data);
  current=await row(); assert.equal(current.reportedPurchaser,'Alex'); assert.equal(current.purchaseRecordedBy,'Mia');
  const own=(await f.http('Sam','GET','/requests/mine')).data.requests[0];
  assert.equal(own.purchaseOutcome,'bought');
  for(const field of ['purchaseRecordedBy','reportedPurchaser','canReportAuthorAsPurchaser']) assert.equal(own[field],undefined);
  const corrected=await send(command(current.revision,'notBought')); assert.equal(corrected.status,200);
  current=await row(); assert.equal(current.purchaseOutcome,'notBought'); assert.equal(current.reportedPurchaser,undefined);
  const self=await send(command(current.revision,'bought',{kind:'self'})); assert.equal(self.status,200);
  current=await row(); assert.equal(current.reportedPurchaser,'Mia');
  assert.equal((await send(command(current.revision,'bought',{...explicit,expectedAlias:'Different adult'}))).status,409);
  const unknown=await send(command(current.revision,'bought',{kind:'unknown'})); assert.equal(unknown.status,200);
  current=await row(); assert.equal(current.purchaseOutcome,'bought'); assert.equal(current.reportedPurchaser,undefined);
});

test('shared wording is checked before publication and current moderation follows requests, questions and cook instructions',async()=>{
  const f=await fixture(),{shopId}=f;
  const supported={'X-Shared-Content-Safety':'1'};
  const bootstrap=(await f.http('Sam','GET','/bootstrap',undefined,supported)).data;
  assert(bootstrap.capabilities.includes('shared_content_safety'));
  assert(!(await f.http('Sam','GET','/bootstrap')).data.capabilities.includes('shared_content_safety'));
  const request={clientRequestId:randomUUID(),originalItem:'Jerk chicken',ownQuantity:'Te voy a hacer daño',authoredAt:new Date().toISOString()};
  const rejected=await f.command('Alex','request.send',request);
  assert.equal(rejected.status,422);
  assert.equal(rejected.data.error.code,'content_review_required');
  assert.equal(JSON.stringify(rejected.data).includes(request.ownQuantity),false);
  let inbox=await f.http('Mia','GET','/shops/'+shopId+'/inbox');
  assert.deepEqual(inbox.data.requests,[]);
  const sent=(await f.send('Alex',{...request,ownQuantity:'one package'})).request;
  const base={shopRevision:1,authorityEpoch:1,requestRevision:sent.revision};
  const edit=await f.command('Alex','request.edit',{requestId:sent.requestId,originalItem:'Go kill yourself',ownQuantity:null},base);
  assert.equal(edit.status,422);
  assert.equal((await f.command('Mia','request.clarify',{requestId:sent.requestId,question:'Te voy a matar'},base)).status,422);
  const asked=await f.command('Mia','request.clarify',{requestId:sent.requestId,question:'Frozen or fresh?'},base);
  assert.equal(asked.status,200,JSON.stringify(asked.data));
  let mine=await f.http('Alex','GET','/requests/mine',undefined,supported);
  assert.equal(mine.data.requests[0].clarification,'Frozen or fresh?');
  assert.equal(mine.data.requests[0].canReportClarification,true);
  assert.equal(mine.data.requests[0].canReportContent,undefined);
  assert.equal((await f.http('Mia','GET','/shops/'+shopId+'/inbox',undefined,supported)).data.requests[0].canReportContent,true);
  await admin.query('INSERT INTO ritc.moderation_block(household_id,viewer_id,author_id) VALUES($1,$2,$3)',[f.h,f.actors.Alex.id,f.actors.Mia.id]);
  mine=await f.http('Alex','GET','/requests/mine');
  assert.equal(mine.data.requests[0].clarification,null);
  assert.equal(mine.data.requests[0].originalItem,'Jerk chicken');
  await admin.query("INSERT INTO ritc.moderation_removal(household_id,source_kind,source_id,source_revision) VALUES($1,'request',$2,1)",[f.h,sent.requestId]);
  inbox=await f.http('Mia','GET','/shops/'+shopId+'/inbox');
  assert.deepEqual(inbox.data.requests,[]);
  assert.equal((await f.preview({...sent,revision:2})).status,404);

  const project={shopId,mode:'edit',shopLabel:'Dinner',language:'en',items:[{label:'Chicken',unit:'lb',amount:'2',action:'I will hurt you'}]};
  assert.equal((await f.http('Mia','POST','/views',project)).status,422);
  project.items[0].action='Roast the chicken';
  const view=await f.http('Mia','POST','/views',project);
  assert.equal(view.status,200);
  const grantId=view.data.grantId;
  const grant=(await admin.query('SELECT projection_author_id FROM ritc.view_grant WHERE household_id=$1 AND grant_id=$2',[f.h,grantId])).rows[0];
  assert.equal(grant.projection_author_id,f.actors.Mia.id);
  const joined=await f.http('Alex','POST','/v1/invites/redeem',{token:view.data.token,intent:'join',adultAttestation:true});
  assert.equal(joined.status,200);
  const current=await f.http('Alex','GET','/v1/views/'+grantId+'/current',undefined,{'X-View-Grant-ID':grantId,'X-Household-ID':f.h});
  assert.equal(current.status,404);
  assert(!JSON.stringify(current.data).includes('Roast the chicken'));
});

test('a retried request keeps its original safe receipt, and a removal suppresses its old wording after an edit',async()=>{
  const f=await fixture();
  const first=await f.send('Alex',{originalItem:'First wording'});
  const base={shopRevision:1,authorityEpoch:1,requestRevision:1};
  const replacement=await f.command('Alex','request.edit',{requestId:first.request.requestId,originalItem:'Reviewed wording',ownQuantity:null},base);
  assert.equal(replacement.status,200);
  const retry=()=>f.http('Alex','POST','/commands',first.envelope);
  assert.equal((await retry()).data.request.originalItem,'First wording');
  await admin.query("INSERT INTO ritc.moderation_removal(household_id,source_kind,source_id,source_revision) VALUES($1,'request',$2,1)",[f.h,first.request.requestId]);
  const redacted=await retry();
  assert.equal(redacted.status,409);
  assert(!JSON.stringify(redacted.data).includes('First wording'));
  const mine=(await f.http('Alex','GET','/requests/mine')).data.requests;
  assert.equal(mine.length,1);
  assert.equal(mine[0].originalItem,'Reviewed wording');
});

test('segmented household receipts require the same printed transaction across extensions and retakes',async()=>{
  const f=await fixture({createShop:false});
  const quantity={amount:{numerator:1,denominator:1},unit:'count',originalLiteral:'1'};
  const row=page=>({ordinal:(page-1)*200,original:'YOGUR 1 EA $2.25',foodName:'Yogur',location:'fridge',
    received:quantity,usable:quantity,paidUSDMinor:225,printed:{page,line:1,method:'imageOCR',stage:'receipt'}});
  const header={merchant:'Mercado Café',purchaseDay:'2026-01-10',zone:'UTC',reference:'Receipt 724',segmentedPhotos:true,
    receiptId:'05e32c0b-b8cf-87cb-bda7-d6a70f780aa7',imageId:randomUUID(),layoutId:randomUUID()};
  const command=(pantryRevision,fields,lines)=>({v:1,kind:'pantry.acquireReceipt',grantEpoch:0,pantryRevision,
    clientKey:randomUUID(),replayWindow:f.actors.Mia.window,body:{...fields,lines}});
  const send=c=>f.http('Mia','POST','/pantry/commands',c);
  // Selecting just a row from page one does not turn a segmented receipt into a single image.
  assert.equal((await send(command(0,{...header,reference:null},[row(1)]))).status,422);
  assert.equal((await send(command(0,{...header,receiptId:randomUUID()},[row(1)]))).status,422);
  const {segmentedPhotos,...unmarked}=header;
  assert.equal((await send(command(0,unmarked,[row(2)]))).status,422);
  const original=command(0,header,[row(1)]),saved=await send(original);
  assert.equal(saved.status,200,JSON.stringify(saved.data));
  assert.deepEqual((await send(original)).data,saved.data);
  assert.equal((await send(command(1,header,[row(1),row(2)]))).data.savedCount,1);
  // Extra final section, retaken middle section and retaken first section all require review.
  for(const firstImage of [header.imageId,header.imageId,randomUUID()]){
    const denied=await send(command(2,{...header,imageId:firstImage,layoutId:randomUUID()},[row(1),row(3)]));
    assert.equal(denied.status,409);assert.equal(denied.data.error.code,'receipt_layout_review');
  }
  const stock=(await f.http('Mia','GET','/pantry')).data;
  assert.equal(stock.pantryRevision,2);assert.equal(stock.lots.length,2);
  const separate={...header,reference:'Receipt 725',receiptId:'8534e80c-5aa0-856c-ab5b-57ae5657dc10',
    imageId:randomUUID(),layoutId:randomUUID()};
  assert.equal((await send(command(2,separate,[row(1)]))).data.savedCount,1);
});
