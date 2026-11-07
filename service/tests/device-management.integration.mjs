import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {randomUUID,randomBytes} from 'node:crypto';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {migrate} from '../scripts/migrate.mjs';
import {HouseholdRepository} from '../dist/repository.js';
import {HouseholdDeviceManagement} from '../dist/device-management.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {createHTTPServer} from '../dist/http.js';
import {assertRuntimeRole,tokenHash} from '../dist/database.js';
import {PrivacyService} from '../dist/privacy.js';
import {deferProfileOnlyDeletion,openPrivacyJournalFixture} from './privacy-journal-fixture.mjs';

const runtimeURL=process.env.TEST_DATABASE_URL,adminURL=process.env.TEST_ADMIN_DATABASE_URL;
if(!runtimeURL||!adminURL)throw new Error('Device authority tests require disposable real PostgreSQL runtime and admin URLs.');
const admin=new pg.Pool({connectionString:adminURL}),runtime=new pg.Pool({connectionString:runtimeURL,max:8});
const journal=await openPrivacyJournalFixture(admin);
const workerURL=new URL(runtimeURL);workerURL.username='ritc_test_worker';
const worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL??workerURL.toString()});
const issuer='https://device-identity.fixture.invalid',audience='authenticated';
const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='device-fixture';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]}));
const repo=new HouseholdRepository(runtime,{allowChildNetwork:true,noticeVersion:'device-fixture-v1',sessionStatus:new SupabaseSessionVerifier(issuer)});
const server=createHTTPServer({repository:repo,verifier,maxRequestsPerMinute:10000,webOrigin:'https://web.fixture.invalid'});
let origin;
before(async()=>{
  await admin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
  await migrate(adminURL);await assertRuntimeRole(runtime);
  const role=(await admin.query("SELECT rolcanlogin,rolsuper,rolbypassrls,pg_has_role(oid,'ritc_worker','MEMBER') AS worker,pg_has_role(oid,'ritc_app','MEMBER') AS app FROM pg_roles WHERE rolname='ritc_test_worker'")).rows[0];
  assert.ok(role?.rolcanlogin&&role.worker&&!role.app&&!role.rolsuper&&!role.rolbypassrls,'Configure the distinct local test worker before running this disposable-database suite; this test does not create roles or change memberships.');
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;
});
after(async()=>{await new Promise(resolve=>server.close(resolve));await journal.close();await Promise.all([runtime.end(),admin.end(),worker.end()]);});
async function fixture(){
  const h=randomUUID(),actors={};
  await admin.query('INSERT INTO ritc.household(household_id,label) VALUES($1,$2)',[h,'Device fixture home']);
  for(const name of ['Organizer','Contributor','Guardian','OtherGuardian','Helper','Child','OtherChild']){
    const memberId=randomUUID(),subject=randomUUID(),sessionId=randomUUID(),kind=name.endsWith('Child')?'child':'adult';
    await admin.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute) VALUES($1,$2,$3,$4,$5,$6,'active',$7,$8)",[h,memberId,issuer,subject,name,kind,name==='Organizer',name!=='Helper']);
    await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[sessionId,subject]);
    const token=await new SignJWT({session_id:sessionId}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(subject).setIssuedAt().setExpirationTime('1h').sign(privateKey);
    actors[name]={memberId,subject,sessionId,token,identity:{issuer,subject,sessionId,expiresAt:new Date(Date.now()+3_600_000)}};
  }
  for(const [child,guardian] of [['Child','Guardian'],['OtherChild','OtherGuardian']])await admin.query('INSERT INTO ritc.guardian_relationship(household_id,child_id,guardian_id,proof_ref) VALUES($1,$2,$3,$4)',[h,actors[child].memberId,actors[guardian].memberId,'independently-verified-fixture']);
  const path='/v1/households/'+h;
  async function http(actor,method,tail,value,extra={}){
    const a=typeof actor==='string'?actors[actor]:actor;
    const res=await fetch(origin+(tail.startsWith('/v1/')?tail:path+tail),{method,headers:{...(a?.token?{Authorization:'Bearer '+a.token}:{}),...(a?.deviceToken?{'X-Device-Token':a.deviceToken}:{}),...(value===undefined?{}:{'Content-Type':'application/json'}),...extra},...(value===undefined?{}:{body:JSON.stringify(value)})});
    return{status:res.status,data:await res.json(),headers:res.headers};
  }
  for(const [name,a] of Object.entries(actors)){
    if(name.endsWith('Child')){
      a.deviceId=randomUUID();a.deviceToken=randomBytes(32).toString('base64url');
      await admin.query('INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id) VALUES($1,$2,$3,$4,$5)',[h,a.deviceId,a.memberId,tokenHash(a.deviceToken),a.sessionId]);
    }else{const d=await http(a,'POST','/devices',{});assert.equal(d.status,201,JSON.stringify(d.data));Object.assign(a,d.data);}
  }
  async function second(name){const a={...actors[name]},d=await http(a,'POST','/devices',{});assert.equal(d.status,201);Object.assign(a,d.data);return a;}
  async function window(a){const r=await http(a,'POST','/replay-windows',{});assert.equal(r.status,200,JSON.stringify(r.data));return r.data.id;}
  return{h,actors,http,second,window};
}
const revokedPath=a=>'/devices/'+a.deviceId+'/revocation';
const targetBody=a=>({memberId:a.memberId});

test('organizer inventory projects opaque enrollment metadata, current device and exact member aliases only',async()=>{
  const f=await fixture(),r=await f.http('Organizer','GET','/devices');assert.equal(r.status,200,JSON.stringify(r.data));
  assert.equal(r.data.scope,'household');assert.equal(r.data.devices.length,7);assert.equal(r.data.nextCursor,null);
  assert.deepEqual(new Set(r.data.devices.map(d=>d.memberId)),new Set(Object.values(f.actors).map(a=>a.memberId)));
  for(const row of r.data.devices){
    assert.deepEqual(Object.keys(row).sort(),['deviceId','memberId','memberAlias','memberKind','createdAt','revokedAt','isCurrentDevice'].sort());
    assert.equal(row.isCurrentDevice,row.deviceId===f.actors.Organizer.deviceId);assert.equal(row.revokedAt,null);assert.ok(Number.isFinite(Date.parse(row.createdAt)));
  }
  assert.equal(r.headers.get('cache-control'),'no-store');
  const wire=JSON.stringify(r.data);for(const a of Object.values(f.actors))for(const value of [a.token,a.subject,a.sessionId,a.deviceToken,tokenHash(a.deviceToken)])assert.ok(!wire.includes(value));
});
test('ordinary contributor/helper, scoped organizer editor, child and foreign actor cannot inspect or revoke devices',async()=>{
  const f=await fixture(),other=await fixture();
  for(const name of ['Contributor','Helper','Child']){
    assert.ok([403,404].includes((await f.http(name,'GET','/devices')).status));
    assert.ok([403,404].includes((await f.http(name,'POST',revokedPath(f.actors.Organizer),targetBody(f.actors.Organizer))).status));
  }
  for(const name of ['Contributor','Helper','Organizer']){
    assert.equal((await f.http(name,'GET','/devices',undefined,{'X-View-Grant-ID':randomUUID()})).status,403);
    assert.equal((await f.http(name,'POST',revokedPath(f.actors.Contributor),targetBody(f.actors.Contributor),{'X-View-Grant-ID':randomUUID()})).status,404);
  }
  assert.equal((await f.http(other.actors.Organizer,'GET','/devices')).status,404);
  assert.equal((await f.http('Organizer','POST',revokedPath(other.actors.Contributor),targetBody(other.actors.Contributor))).status,404);
  assert.equal((await f.http('Organizer','POST',revokedPath(f.actors.Contributor),targetBody(f.actors.Helper))).status,404);
  assert.equal((await f.http('Organizer','POST',revokedPath(f.actors.Contributor),{...targetBody(f.actors.Contributor),sessionId:'forged'})).status,422);
});
test('actual guardian sees and revokes only verified children; revoked relationship removes management authority',async()=>{
  const f=await fixture(),g=await f.http('Guardian','GET','/devices');assert.equal(g.status,200);
  assert.equal(g.data.scope,'guardian_children');assert.deepEqual(g.data.devices.map(d=>d.deviceId),[f.actors.Child.deviceId]);
  for(const name of ['Organizer','Guardian','OtherChild'])assert.equal((await f.http('Guardian','POST',revokedPath(f.actors[name]),targetBody(f.actors[name]))).status,404);
  assert.equal((await f.http('Guardian','GET','/devices?cursor='+f.actors.OtherChild.deviceId)).status,404);
  assert.equal((await f.http('Guardian','POST',revokedPath(f.actors.Child),targetBody(f.actors.Child))).status,200);
  await admin.query('UPDATE ritc.guardian_relationship SET revoked_at=clock_timestamp() WHERE household_id=$1 AND guardian_id=$2',[f.h,f.actors.Guardian.memberId]);
  assert.equal((await f.http('Guardian','GET','/devices')).status,404);
  assert.equal((await f.http('Guardian','POST',revokedPath(f.actors.Child),targetBody(f.actors.Child))).status,404);
});
test('current device uses separate sign out; repeated precise revocation preserves siblings, provider session, membership and shopper authority',async()=>{
  const f=await fixture(),current=f.actors.Organizer,target=await f.second('Organizer'),sibling=await f.second('Organizer');
  const tw=await f.window(target),sw=await f.window(sibling),cookie=randomBytes(32).toString('base64url'),csrf=randomBytes(32).toString('base64url');
  await admin.query('INSERT INTO ritc.web_session(household_id,token_hash,member_id,device_id,csrf,expires_at) VALUES($1,$2,$3,$4,$5,clock_timestamp()+interval \'1 hour\')',[f.h,tokenHash(cookie),target.memberId,target.deviceId,csrf]);
  const shopId=randomUUID();await admin.query("INSERT INTO ritc.shop(household_id,shop_id,shopper_id,quote) VALUES($1,$2,$3,'{}')",[f.h,shopId,current.memberId]);
  assert.equal((await f.http(current,'POST',revokedPath(current),targetBody(current))).data.error.code,'current_device');
  const calls=await Promise.all([f.http(current,'POST',revokedPath(target),targetBody(target)),f.http(current,'POST',revokedPath(target),targetBody(target))]);
  assert.equal(calls[0].status,200);assert.deepEqual(calls[0].data,calls[1].data);
  assert.equal((await f.http(target,'GET','/bootstrap')).status,403);
  const cookieResponse=await fetch(origin+'/v1/session',{headers:{Cookie:'ritc_session='+f.h+'.'+cookie}});assert.equal(cookieResponse.status,403);
  assert.equal((await f.http(sibling,'GET','/bootstrap')).status,200);assert.equal((await f.http(current,'GET','/bootstrap')).status,200);
  const rows=(await admin.query('SELECT window_id,revoked_at FROM ritc.replay_window WHERE household_id=$1 AND window_id=ANY($2::uuid[])',[f.h,[tw,sw]])).rows;
  assert.ok(rows.find(r=>r.window_id===tw).revoked_at);assert.equal(rows.find(r=>r.window_id===sw).revoked_at,null);
  assert.equal((await admin.query('SELECT state FROM ritc.member WHERE household_id=$1 AND member_id=$2',[f.h,current.memberId])).rows[0].state,'active');
  assert.equal((await admin.query('SELECT shopper_id FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[f.h,shopId])).rows[0].shopper_id,current.memberId);
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM auth.sessions WHERE id=$1',[current.sessionId])).rows[0].n,1);
  assert.equal((await f.http(current,'POST',revokedPath(target),targetBody(target))).data.revokedAt,calls[0].data.revokedAt);
  const ended=await f.http(current,'DELETE','/devices/current');assert.equal(ended.status,200);assert.equal((await f.http(current,'GET','/devices')).status,403);
});
test('revocation commits before queued reads/writes recheck enrollment; a stored old success is never replayed',async()=>{
  const f=await fixture(),target=f.actors.Contributor,shopId=randomUUID(),window=await f.window(target);
  await admin.query("INSERT INTO ritc.shop(household_id,shop_id,shopper_id,quote) VALUES($1,$2,$3,'{}')",[f.h,shopId,f.actors.Organizer.memberId]);
  const command={v:1,replayWindow:window,clientKey:randomUUID(),shopId,kind:'request.send',base:{shopRevision:0,authorityEpoch:0},body:{clientRequestId:randomUUID(),originalItem:'Fixture food',ownQuantity:null,authoredAt:new Date().toISOString()}};
  assert.equal((await f.http(target,'POST','/commands',command)).status,200);
  let held,release;const holding=new Promise(resolve=>held=resolve),gate=new Promise(resolve=>release=resolve);
  const revoking=repo.authorized(f.h,{identity:f.actors.Organizer.identity,deviceToken:f.actors.Organizer.deviceToken},async ctx=>{
    const result=await new HouseholdDeviceManagement().revoke(ctx,f.actors.Organizer.identity,target.deviceId,targetBody(target));held();await gate;return result;
  });
  await holding;
  const queuedRead=f.http(target,'GET','/requests/mine'),queuedReplay=f.http(target,'POST','/commands',command);
  release();await revoking;assert.equal((await queuedRead).status,403);assert.equal((await queuedReplay).status,403);
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.request WHERE household_id=$1',[f.h])).rows[0].n,1);
  assert.equal((await f.http(target,'GET','/devices')).status,403);
});
test('stable pagination covers all actual enrollments without leaking an inaccessible or foreign cursor',async()=>{
  const f=await fixture(),other=await fixture();
  for(let i=0;i<100;i++)await admin.query('INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id,created_at) VALUES($1,$2,$3,$4,$5,$6)',[f.h,randomUUID(),f.actors.Contributor.memberId,tokenHash(randomUUID()),f.actors.Contributor.sessionId,new Date('2026-01-01T00:00:00Z')]);
  const first=await f.http('Organizer','GET','/devices');assert.equal(first.data.devices.length,100);assert.equal(first.data.nextCursor,first.data.devices.at(-1).deviceId);
  const second=await f.http('Organizer','GET','/devices?cursor='+first.data.nextCursor);assert.equal(second.data.devices.length,7);assert.equal(second.data.nextCursor,null);
  assert.equal(new Set([...first.data.devices,...second.data.devices].map(d=>d.deviceId)).size,107);
  assert.equal((await f.http('Organizer','GET','/devices?cursor='+other.actors.Organizer.deviceId)).status,404);
});

async function freshLogin(actor){
  const sessionId=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[sessionId,actor.subject]);
  const token=await new SignJWT({session_id:sessionId}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(actor.subject).setIssuedAt().setExpirationTime('1h').sign(privateKey);
  return{...actor,sessionId,token,identity:{...actor.identity,sessionId},deviceId:undefined,deviceToken:undefined};
}
test('lost-device bearer cannot replace enrollment through devices or browser session; fresh provider login can',async()=>{
  const f=await fixture(),target=f.actors.Contributor,sibling=await f.second('Contributor');
  assert.equal((await f.http('Organizer','POST',revokedPath(target),targetBody(target))).status,200);
  const refused=await f.http(target,'POST','/devices',{});assert.equal(refused.status,401);assert.equal(refused.data.error.code,'session_needed');
  const browser=await f.http(target,'POST','/v1/session',{householdId:f.h});assert.equal(browser.status,401);assert.equal(browser.data.error.code,'session_needed');
  assert.equal((await f.http(sibling,'GET','/bootstrap')).status,200);
  const fresh=await freshLogin(target),created=await f.http(fresh,'POST','/devices',{});assert.equal(created.status,201,JSON.stringify(created.data));
  Object.assign(fresh,created.data);assert.equal((await f.http(fresh,'GET','/bootstrap')).status,200);
  const fence=(await admin.query('SELECT * FROM ritc.device_enrollment_fence WHERE household_id=$1',[f.h])).rows;
  assert.equal(fence.length,1);assert.equal(fence[0].session_hash,tokenHash(target.sessionId));assert.ok(!JSON.stringify(fence).includes(target.sessionId));
});
test('new fence is owner-only, cannot accept supplied hashes, and guarded SQL rejects wrong actors/sessions/targets',async()=>{
  const f=await fixture(),other=await fixture(),target=f.actors.Contributor;
  for(const sql of ['SELECT * FROM ritc.device_enrollment_fence',
    'INSERT INTO ritc.device_enrollment_fence(household_id,member_id,session_hash) VALUES($1,$2,$3)',
    'UPDATE ritc.device_enrollment_fence SET session_hash=$3 WHERE household_id=$1 AND member_id=$2',
    'DELETE FROM ritc.device_enrollment_fence WHERE household_id=$1 AND member_id=$2']){
    const values=sql.startsWith('SELECT')?[]:sql.startsWith('DELETE')?[f.h,target.memberId]:[f.h,target.memberId,tokenHash('arbitrary')];
    await assert.rejects(runtime.query(sql,values),e=>e.code==='42501');
  }
  const db=await runtime.connect();try{
    await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[f.h]);
    for(const [actor,device,session,deviceTarget,memberTarget] of [
      [f.actors.Contributor,f.actors.Contributor.deviceId,f.actors.Contributor.sessionId,f.actors.Organizer.deviceId,f.actors.Organizer.memberId],
      [f.actors.Guardian,f.actors.Guardian.deviceId,f.actors.Guardian.sessionId,f.actors.OtherChild.deviceId,f.actors.OtherChild.memberId],
      [f.actors.Organizer,f.actors.Organizer.deviceId,f.actors.Contributor.sessionId,target.deviceId,target.memberId],
      [f.actors.Organizer,f.actors.Contributor.deviceId,f.actors.Organizer.sessionId,target.deviceId,target.memberId],
      [f.actors.Organizer,f.actors.Organizer.deviceId,f.actors.Organizer.sessionId,other.actors.Contributor.deviceId,other.actors.Contributor.memberId],
      [f.actors.Organizer,f.actors.Organizer.deviceId,f.actors.Organizer.sessionId,target.deviceId,f.actors.Helper.memberId],
      [f.actors.Organizer,f.actors.Organizer.deviceId,f.actors.Organizer.sessionId,f.actors.Organizer.deviceId,f.actors.Organizer.memberId]
    ]){
      const r=await db.query('SELECT ritc.revoke_household_device($1,$2,$3,$4,$5,$6,$7,$8) AS result',[f.h,actor.memberId,device,issuer,actor.subject,session,deviceTarget,memberTarget]);assert.equal(r.rows[0].result,null);
    }
    assert.equal((await db.query('SELECT ritc.device_enrollment_permitted($1,$2,$3,$4,$5) AS result',[other.h,other.actors.Organizer.memberId,issuer,other.actors.Organizer.subject,other.actors.Organizer.sessionId])).rows[0].result,false);
    await db.query('COMMIT');
  }catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.device_enrollment_fence WHERE household_id=$1',[f.h])).rows[0].n,0);
  assert.equal((await f.http('Organizer','POST',revokedPath(target),targetBody(target))).status,200);
  // The owner erasure hook is unreachable through general runtime credential
  // UPDATE authority; runtime may only retire revoked_at, never replace identity.
  for(const [column,value] of [['session_id','erased'],['token_hash',tokenHash('replacement')],['member_id',f.actors.Helper.memberId],['device_id',randomUUID()],['household_id',other.h],['guardian_consent_id',randomUUID()],['created_at',new Date().toISOString()]]){
    await assert.rejects(repo.transaction(f.h,db=>db.query(`UPDATE ritc.device SET ${column}=$3 WHERE household_id=$1 AND device_id=$2`,[f.h,target.deviceId,value])),e=>e.code==='42501');
  }
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.device_enrollment_fence WHERE household_id=$1 AND member_id=$2',[f.h,target.memberId])).rows[0].n,1);
  // Even the pre-existing runtime INSERT grant cannot bypass the SQL fence.
  await assert.rejects(repo.transaction(f.h,db=>db.query('INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id) VALUES($1,$2,$3,$4,$5)',[f.h,randomUUID(),target.memberId,tokenHash(randomUUID()),target.sessionId])),e=>e.code==='23514');
});
test('both enrollment/revocation lock orderings preserve a prior sibling and reject replacement after revocation',async()=>{
  const f=await fixture(),a=f.actors.Contributor,deviceId=randomUUID(),deviceToken=randomBytes(32).toString('base64url');
  let hold,release;const entered=new Promise(resolve=>hold=resolve),gate=new Promise(resolve=>release=resolve);
  const enrolling=repo.transaction(f.h,async db=>{
    await db.query('INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id) VALUES($1,$2,$3,$4,$5)',[f.h,deviceId,a.memberId,tokenHash(deviceToken),a.sessionId]);hold();await gate;
  });
  await entered;const revoking=f.http('Organizer','POST',revokedPath(a),targetBody(a));release();await enrolling;assert.equal((await revoking).status,200);
  assert.equal((await f.http({...a,deviceId,deviceToken},'GET','/bootstrap')).status,200);
  const g=await fixture(),b=g.actors.Contributor;let hold2,release2;
  const entered2=new Promise(resolve=>hold2=resolve),gate2=new Promise(resolve=>release2=resolve);
  const revoking2=repo.authorized(g.h,{identity:g.actors.Organizer.identity,deviceToken:g.actors.Organizer.deviceToken},async ctx=>{
    await new HouseholdDeviceManagement().revoke(ctx,g.actors.Organizer.identity,b.deviceId,targetBody(b));hold2();await gate2;
  });
  await entered2;const enrolling2=g.http(b,'POST','/devices',{});release2();await revoking2;assert.equal((await enrolling2).status,401);
  assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.device WHERE household_id=$1 AND member_id=$2',[g.h,b.memberId])).rows[0].n,1);
});
test('owner erasure drops only the erased member fence and restore reapplication removes reintroduced pseudonyms',async()=>{
  const f=await fixture(),a=f.actors.Contributor,b=f.actors.Helper;
  for(const target of [a,b])assert.equal((await f.http('Organizer','POST',revokedPath(target),targetBody(target))).status,200);
  await admin.query("UPDATE ritc.device SET session_id='erased' WHERE household_id=$1 AND member_id=$2",[f.h,a.memberId]);
  assert.deepEqual((await admin.query('SELECT member_id FROM ritc.device_enrollment_fence WHERE household_id=$1',[f.h])).rows.map(r=>r.member_id),[b.memberId]);
  // Model a restored old fence alongside a device whose erasure is already present.
  await admin.query('INSERT INTO ritc.device_enrollment_fence(household_id,member_id,session_hash) VALUES($1,$2,$3)',[f.h,a.memberId,tokenHash(a.sessionId)]);
  await admin.query("UPDATE ritc.device SET session_id='erased' WHERE household_id=$1 AND member_id=$2",[f.h,a.memberId]);
  assert.deepEqual((await admin.query('SELECT member_id FROM ritc.device_enrollment_fence WHERE household_id=$1',[f.h])).rows.map(r=>r.member_id),[b.memberId]);
});
test('a legitimate separately leased privacy worker erases session fences while preserving another member fence',async t=>{
  const f=await fixture(),a=f.actors.Contributor,b=f.actors.Helper,job=randomUUID(),lease=randomUUID();
  t.after(()=>deferProfileOnlyDeletion(admin,job));
  for(const target of [a,b])assert.equal((await f.http('Organizer','POST',revokedPath(target),targetBody(target))).status,200);
  const choices=[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}];
  const token=await new SignJWT({session_id:a.sessionId,amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)}]}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(a.subject).setIssuedAt().setExpirationTime('1h').sign(privateKey);
  const privacy=new PrivacyService(repo,{provider:{assertAvailable:async()=>{},deleteAccount:async()=>{throw Error('Profile-only fixture must not call provider');}},policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1},journal:journal.port});
  await privacy.request(await verifier.verify(token),{clientKey:job,statusToken:randomBytes(32).toString('base64url'),confirm:true,households:choices});
  await admin.query("UPDATE ritc.privacy_job SET state='processing',lease_id=$2,lease_until=clock_timestamp()+interval '1 minute' WHERE job_id=$1",[job,lease]);
  assert.equal((await worker.query('SELECT ritc.privacy_erase_target($1,$2) AS erased',[job,randomUUID()])).rows[0].erased,false);
  assert.equal((await worker.query('SELECT ritc.privacy_erase_target($1,$2) AS erased',[job,lease])).rows[0].erased,true);await journal.port.acknowledgeJob(job);
  assert.equal((await admin.query('SELECT session_id FROM ritc.device WHERE household_id=$1 AND device_id=$2',[f.h,a.deviceId])).rows[0].session_id,'erased');
  assert.deepEqual((await admin.query('SELECT member_id FROM ritc.device_enrollment_fence WHERE household_id=$1',[f.h])).rows.map(r=>r.member_id),[b.memberId]);
  const member=(await admin.query('SELECT state,erased_at FROM ritc.member WHERE household_id=$1 AND member_id=$2',[f.h,a.memberId])).rows[0];assert.equal(member.state,'revoked');assert.ok(member.erased_at);
});
