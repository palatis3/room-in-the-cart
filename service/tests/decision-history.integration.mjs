import test, {before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {BillingService} from '../dist/billing/service.js';
import {createHTTPServer} from '../dist/http.js';

const admin = new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL});
const runtime = new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
const subscriptions = new Map();
function subscription(id) {
  const value = subscriptions.get(id);
  if (!value) throw Error('Missing fictional subscription');
  return value;
}
const billing = new BillingService({verifyTransaction:subscription,current:subscription});
const issuer = 'https://decisions.fixture.invalid';
const {publicKey,privateKey} = await generateKeyPair('ES256');
const jwk = {...await exportJWK(publicKey),kid:'decisions'};
const verifier = new JWTIdentityVerifier({issuer,audience:'authenticated',jwksUrl:issuer+'/keys'},createLocalJWKSet({keys:[jwk]}));
const repository = new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
const server = createHTTPServer({repository,billing,verifier,maxRequestsPerMinute:20000});
let origin;
before(async () => {
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  origin = 'http://127.0.0.1:'+server.address().port;
});
after(async () => {
  await new Promise(resolve => server.close(resolve));
  await Promise.all([admin.end(),runtime.end()]);
});

async function actor() {
  const subject=randomUUID(), session=randomUUID();
  await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);
  const token=await new SignJWT({session_id:session}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer)
    .setSubject(subject).setAudience('authenticated').setIssuedAt().setExpirationTime('1h').sign(privateKey);
  return {session,token};
}
async function request(a,path,method='GET',body,headers={}) {
  const reqHeaders={Authorization:'Bearer '+a.token,...headers};
  if (a.device) reqHeaders['X-Device-Token']=a.device;
  if (body!==undefined) reqHeaders['Content-Type']='application/json';
  const r=await fetch(origin+path,{method,headers:reqHeaders,body:JSON.stringify(body)});
  return {status:r.status,data:await r.json()};
}
function ok(r,status=200) {assert.equal(r.status,status,JSON.stringify(r.data));return r.data;}
function code(r,status,error) {assert.equal(r.status,status,JSON.stringify(r.data));assert.equal(r.data.error.code,error);}
async function enroll(a,base) {
  a.device=ok(await request(a,base+'/devices','POST',{}),201).deviceToken;
  a.window=ok(await request(a,base+'/replay-windows','POST',{})).id;
}
async function fixture() {
  const owner=await actor();
  const creation=ok(await request(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'Fictional decisions',alias:'Adult',adultAttestation:true}),201);
  const h=creation.householdId, base='/v1/households/'+h;
  owner.id=creation.memberId;
  await enroll(owner,base);
  async function shop() {
    const shopId=randomUUID(), now=Date.now();
    const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},
      taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date(now-60000).toISOString(),expiresAt:new Date(now+3600000).toISOString()};
    ok(await request(owner,base+'/commands','POST',{v:1,replayWindow:owner.window,clientKey:randomUUID(),shopId,kind:'shop.create',
      base:{shopRevision:0,authorityEpoch:0},body:{quote,lines:[{lineId:randomUUID(),originalItem:'Fictional line',packs:1,unitPriceMinor:100,feeEligible:true}]}}));
    return shopId;
  }
  async function paid() {
    const token=ok(await request(owner,base+'/billing/purchase-context','POST',{})).appAccountToken;
    const original=String(Date.now())+String(Math.floor(Math.random()*1e6)), now=Date.now();
    subscriptions.set(original,{environment:'Sandbox',originalTransactionID:original,transactionID:original,appAccountToken:token,
      productID:'fixture.household.yearly',purchasedAt:now,signedAt:now,expiresAt:now+3600000,graceExpiresAt:null,status:'active'});
    ok(await request(owner,'/v1/billing/verify','POST',{householdId:h,signedTransactionInfo:original}));
    return original;
  }
  async function otherMember() {
    const other=await actor(), invite=ok(await request(owner,base+'/invites','POST',{kind:'adult_contributor'}));
    other.id=ok(await request(other,'/v1/invites/redeem','POST',{token:invite.token,intent:'join',adultAttestation:true,alias:'Other adult'})).memberId;
    await enroll(other,base);
    return other;
  }
  const shopId=await shop(), shopPath=base+'/shops/'+shopId, decisions=shopPath+'/decisions';
  async function transfer(from,to) {
    const current=ok(await request(from,shopPath));
    ok(await request(owner,base+'/commands','POST',{v:1,replayWindow:owner.window,clientKey:randomUUID(),shopId,kind:'shop.transferAuthority',
      base:{shopRevision:current.shopRevision,authorityEpoch:current.authorityEpoch},body:{newShopperId:to.id}}));
  }
  async function seats(ids) {
    const current=ok(await request(owner,base+'/entitlements'));
    ok(await request(owner,base+'/billing/seats','PUT',{revision:current.revision,userIDs:ids}));
  }
  return {owner,h,base,shop,shopId,shopPath,decisions,paid,otherMember,transfer,seats};
}
const preference = (extra={}) => ({clientKey:randomUUID(),kind:'preference',product:'Tomates 50%',dish:'Sopa',occasion:'Cena',decision:'Prefer the ripe ones',outcome:null,...extra});
const edit = (baseVersion,extra={}) => ({clientKey:randomUUID(),baseVersion,...extra});

test('Free records human decisions, updates a checked outcome later, and preserves exact receipts',async () => {
  const f=await fixture(), p=preference(), path=f.decisions+'/'+p.clientKey;
  const created=ok(await request(f.owner,f.decisions,'POST',p));
  assert.equal(created.version,1);assert.equal(created.scope,'one_shop');assert.equal(created.outcome,null);
  assert.equal(created.observedAt,null);assert.equal(created.promotedAt,null);
  assert.deepEqual(ok(await request(f.owner,path)),created);
  code(await request(f.owner,f.base+'/decisions'),403,'membership_inactive');
  code(await request(f.owner,path+'/promote','POST',edit(1)),403,'membership_inactive');
  const input=edit(1,{outcome:'Delivered underripe'}), observed=ok(await request(f.owner,path+'/outcome','POST',input));
  assert.equal(observed.version,2);assert.equal(observed.outcome,input.outcome);assert.ok(observed.observedAt);
  assert.deepEqual(ok(await request(f.owner,f.decisions,'POST',p)),created);
  assert.deepEqual(ok(await request(f.owner,path+'/outcome','POST',input)),observed);
  code(await request(f.owner,f.decisions,'POST',{...p,decision:'Changed'}),409,'key_reused');
  code(await request(f.owner,path+'/outcome','POST',{...input,outcome:'Changed'}),409,'key_reused');
  code(await request(f.owner,path+'/outcome','POST',edit(1,{outcome:'Stale'})),409,'decision_changed');
  const corrections=await Promise.all(['Checked later','Read the label'].map(outcome=>request(f.owner,path+'/outcome','POST',edit(2,{outcome}))));
  assert.deepEqual(corrections.map(r=>r.status).sort(),[200,409]);
  assert.equal(ok(await request(f.owner,path)).version,3);
});

test('only explicit promotion of a temporary preference is paid; it never modifies the shop',async () => {
  const f=await fixture(), original=await f.paid(), before=ok(await request(f.owner,f.shopPath));
  for (const kind of ['approval','exclusion']) {
    const p=preference({kind,outcome:'Checked on delivery'}), row=ok(await request(f.owner,f.decisions,'POST',p));
    assert.ok(row.observedAt);assert.equal(row.outcome,p.outcome);
    code(await request(f.owner,f.decisions+'/'+row.id+'/promote','POST',edit(1)),409,'decision_changed');
  }
  const p=preference(), row=ok(await request(f.owner,f.decisions,'POST',p)), path=f.decisions+'/'+row.id, input=edit(1);
  const updates=await Promise.all([1,2].map(()=>request(f.owner,path+'/promote','POST',input)));
  const lasting=ok(updates[0]);assert.deepEqual(ok(updates[1]),lasting);
  assert.equal(lasting.scope,'lasting');assert.equal(lasting.version,2);assert.ok(lasting.promotedAt);assert.equal(lasting.observedAt,null);
  code(await request(f.owner,path+'/promote','POST',{...input,baseVersion:2}),409,'key_reused');
  code(await request(f.owner,path+'/promote','POST',edit(2)),409,'decision_changed');
  assert.deepEqual(ok(await request(f.owner,f.shopPath)),before);
  subscriptions.set(original,{...subscriptions.get(original),status:'expired',signedAt:Date.now()+1});
  code(await request(f.owner,path+'/promote','POST',input),403,'membership_inactive');
  code(await request(f.owner,f.base+'/decisions'),403,'membership_inactive');
  assert.deepEqual(ok(await request(f.owner,path)),lasting);
});

test('literal combined filters, fifty-row pages, tied timestamps and scoped cursors',async () => {
  const f=await fixture();await f.paid();
  const ids=[];
  for (let i=0;i<52;i++) {
    const row=ok(await request(f.owner,f.decisions,'POST',preference({occasion:i===51?'Almuerzo':'Cena'})));
    ids.push(row.id);
  }
  await admin.query('UPDATE ritc.family_decision SET recorded_at=$2 WHERE household_id=$1',[f.h,new Date()]);
  const root=f.base+'/decisions', filtered=root+'?product=50%25&dish=soPA&occasion=cEn';
  const first=ok(await request(f.owner,filtered));
  assert.equal(first.decisions.length,50);assert.equal(first.nextCursor,first.decisions.at(-1).id);
  const last=ok(await request(f.owner,filtered+'&cursor='+first.nextCursor));
  assert.equal(last.nextCursor,null);
  assert.deepEqual([...first.decisions,...last.decisions].map(d=>d.id),ids.slice(0,51).sort().reverse());
  assert.deepEqual(ok(await request(f.owner,root+'?product=_')), {decisions:[],nextCursor:null});
  assert.equal((await request(f.owner,filtered+'&cursor='+ids[51])).status,404);
  for (const query of ['?dish=a&dish=b','?kind=approval','?cursor=not-a-uuid','?product=']) assert.equal((await request(f.owner,root+query)).status,422);
});

test('selected shop and current assignment narrow records, retries, search and cursors across tenants',async () => {
  const f=await fixture(), other=await f.otherMember(), second=await f.shop(), foreign=await fixture();
  await f.paid();
  const p=preference(), row=ok(await request(f.owner,f.decisions,'POST',p)), path=f.decisions+'/'+row.id, root=f.base+'/decisions';
  const q=preference(), secondPath=f.base+'/shops/'+second+'/decisions';ok(await request(f.owner,secondPath,'POST',q));
  const selected={'X-Shop-ID':second};
  assert.deepEqual(ok(await request(f.owner,root,'GET',undefined,selected)).decisions.map(r=>r.id),[q.clientKey]);
  for (const target of [path,root+'?shopId='+f.shopId,root+'?cursor='+p.clientKey]) assert.equal((await request(f.owner,target,'GET',undefined,selected)).status,404);
  assert.equal((await request(f.owner,f.decisions,'POST',p,selected)).status,404);
  assert.equal((await request(f.owner,path,'GET',undefined,{'X-View-Grant-ID':randomUUID()})).status,404);
  assert.equal((await request(f.owner,root+'?shopId='+foreign.shopId)).status,404);
  assert.equal((await request(f.owner,foreign.decisions+'/'+p.clientKey)).status>=400,true);
  assert.equal((await request(other,path)).status,404);
  await f.transfer(f.owner,other);
  assert.equal((await request(f.owner,f.decisions,'POST',p)).status,404);
  assert.equal((await request(f.owner,path)).status,404);
  assert.equal((await request(f.owner,root+'?cursor='+p.clientKey)).status,404);
  assert.deepEqual(ok(await request(f.owner,root)).decisions.map(r=>r.id),[q.clientKey]);
  assert.deepEqual(ok(await request(other,path)),row);
  code(await request(other,root),403,'membership_inactive');
  await f.seats([f.owner.id,other.id]);
  assert.deepEqual(ok(await request(other,root)).decisions.map(r=>r.id),[p.clientKey]);
  assert.equal((await request(other,secondPath+'/'+q.clientKey)).status,404);
  const scoped=await runtime.query('SELECT * FROM ritc.family_decision');
  assert.equal(scoped.rowCount,0);
});

test('rejects child, revoked, logged-out and malformed input',async () => {
  const f=await fixture(),other=await f.otherMember(),p=preference(),path=f.decisions+'/'+p.clientKey;
  ok(await request(f.owner,f.decisions,'POST',p));
  for (const bad of [{product:null,dish:null,occasion:null},{kind:'pending'},{decision:' '},{outcome:''},{product:'x'.repeat(121)},{decision:'d'.repeat(501)},{scope:'lasting'},{outcome:'bad\0value'},{decision:'\ud800'}])
    assert.equal((await request(f.owner,f.decisions,'POST',preference(bad))).status,422);
  assert.equal((await request(f.owner,path+'/outcome','POST',edit(1,{outcome:null}))).status,422);
  await f.transfer(f.owner,other);
  for (const state of ["kind='child'","kind='adult',state='revoked'"]) {
    await admin.query('UPDATE ritc.member SET '+state+' WHERE household_id=$1 AND member_id=$2',[f.h,other.id]);
    for (const [target,method,body] of [[path,'GET'],[f.decisions,'POST',p],[f.base+'/decisions','GET'],[path+'/promote','POST',edit(1)]])
      assert.ok([403,404].includes((await request(other,target,method,body)).status));
  }
  await admin.query('DELETE FROM auth.sessions WHERE id=$1',[f.owner.session]);
  assert.equal((await request(f.owner,path)).status,401);
});

test('erasure drops authored records and all receipts carrying erased current or superseded observations',async () => {
  const f=await fixture(), other=await f.otherMember();
  await f.paid();
  const retained=ok(await request(f.owner,f.decisions,'POST',preference()));
  const retained2=ok(await request(f.owner,f.decisions,'POST',preference()));
  await f.transfer(f.owner,other);
  const authored=ok(await request(other,f.decisions,'POST',preference({decision:'Erase this authored decision'})));
  const path=f.decisions+'/'+retained.id, path2=f.decisions+'/'+retained2.id;
  for (const target of [path,path2]) ok(await request(other,target+'/outcome','POST',edit(1,{outcome:'Other private outcome'})));
  await f.seats([f.owner.id,other.id]);
  ok(await request(other,path2+'/promote','POST',edit(2)));
  await f.transfer(other,f.owner);
  const promotion=edit(2);
  ok(await request(f.owner,path+'/promote','POST',promotion));
  ok(await request(f.owner,path+'/outcome','POST',edit(3,{outcome:'A later independently checked outcome'})));
  // Invoke the worker's erasure extension for the single fixture member, without claiming unrelated jobs.
  await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,other.id]);
  const current=ok(await request(f.owner,path)), stripped=ok(await request(f.owner,path2));
  assert.equal(current.scope,'lasting');assert.equal(current.outcome,'A later independently checked outcome');
  assert.equal(stripped.scope,'one_shop');assert.equal(stripped.promotedAt,null);assert.equal(stripped.outcome,null);assert.equal(stripped.observedAt,null);
  assert.equal(stripped.version,4);
  assert.equal((await request(f.owner,f.decisions+'/'+authored.id)).status,404);
  const receipts=(await admin.query('SELECT * FROM ritc.decision_receipt WHERE household_id=$1',[f.h])).rows;
  assert.ok(receipts.every(r=>r.actor_id!==other.id && r.decision_id!==authored.id));
  assert.equal(JSON.stringify(receipts).includes('Other private outcome'),false);
  code(await request(f.owner,path+'/promote','POST',promotion),409,'decision_changed');
  await assert.rejects(runtime.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,other.id]),e=>e.code==='42501');
});

test('a redeemed helper cannot access decisions; closure preserves history while explicit retirement removes access',async () => {
  const f=await fixture();await f.paid();
  const p=preference(),row=ok(await request(f.owner,f.decisions,'POST',p)),path=f.decisions+'/'+row.id;
  const grant=ok(await request(f.owner,f.base+'/views','POST',{shopId:f.shopId,mode:'read',shopLabel:'Fictional list',language:'en',items:[]}));
  const helper=await actor();
  ok(await request(helper,'/v1/invites/redeem','POST',{token:grant.token,intent:'join',adultAttestation:true,alias:'Helper'}));
  await enroll(helper,f.base);
  const headers={'X-Household-ID':f.h,'X-View-Grant-ID':grant.grantId};
  ok(await request(helper,'/v1/views/'+grant.grantId+'/current','GET',undefined,headers));
  for(const selection of [headers,{}]) {
    for(const [target,method,body] of [[path,'GET'],[f.decisions,'POST',p],[f.base+'/decisions','GET'],[path+'/outcome','POST',edit(1,{outcome:'Hidden'})]])
      assert.equal((await request(helper,target,method,body,selection)).status,404);
  }
  const source=async()=>ok(await request(f.owner,f.shopPath+'/financial-evidence')).sourceVersion;
  ok(await request(f.owner,f.shopPath+'/financial-reviews','POST',{clientKey:randomUUID(),sourceVersion:await source(),closeShop:true,allEvidenceEntered:false}));
  assert.deepEqual(ok(await request(f.owner,path)),row);
  assert.deepEqual(ok(await request(f.owner,f.base+'/decisions')).decisions,[row]);
  ok(await request(f.owner,f.shopPath+'/history-retire','POST',{clientKey:randomUUID(),sourceVersion:await source(),confirm:true}));
  assert.equal((await request(f.owner,path)).status,404);
  assert.equal((await request(f.owner,f.decisions,'POST',p)).status,404);
  assert.equal((await request(f.owner,f.base+'/decisions?shopId='+f.shopId)).status,404);
});
