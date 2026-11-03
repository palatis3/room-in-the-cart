import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {randomUUID} from 'node:crypto';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {createHTTPServer} from '../dist/http.js';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
const issuer='https://helper-review.fixture.invalid',audience='authenticated';
const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='helper-review';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]})),repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
const server=createHTTPServer({repository:repo,verifier,webOrigin:'https://browser.fixture.invalid',maxRequestsPerMinute:10000});let origin;
before(async()=>{await new Promise(r=>server.listen(0,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;});
after(async()=>{await new Promise(r=>server.close(r));await Promise.all([admin.end(),runtime.end()]);});
async function actor(){const subject=randomUUID(),session=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);const token=await new SignJWT({session_id:session}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience(audience).setIssuedAt().setExpirationTime('1h').sign(privateKey);return{subject,session,token};}
async function call(a,path,method='GET',body,headers={}){const r=await fetch(origin+path,{method,headers:{...(a?{Authorization:'Bearer '+a.token}:{}),...(a?.device?{'X-Device-Token':a.device}:{}),...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})});return{status:r.status,data:await r.json(),headers:r.headers};}
function ok(r,status=200){assert.equal(r.status,status,JSON.stringify(r.data));return r.data;}
async function enroll(a,h){a.device=ok(await call(a,`/v1/households/${h}/devices`,'POST',{}),201).deviceToken;a.window=ok(await call(a,`/v1/households/${h}/replay-windows`,'POST',{})).id;}
const projection=(label='Reviewed instructions')=>({shopLabel:label,language:'en',items:[{label:'Cereal',amount:'one',unit:'box',action:'Use the reviewed amount.'}]});
async function fixture(){
 const owner=await actor(),created=ok(await call(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'Helper fixture',alias:'Shopper',adultAttestation:true}),201),h=created.householdId;owner.id=created.memberId;await enroll(owner,h);
 const shop=async()=>{const id=randomUUID(),quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date(Date.now()-60000).toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()};ok(await call(owner,`/v1/households/${h}/commands`,'POST',{v:1,replayWindow:owner.window,clientKey:randomUUID(),shopId:id,kind:'shop.create',base:{shopRevision:0,authorityEpoch:0},body:{quote,lines:[{lineId:randomUUID(),originalItem:'Private basket',packs:1,unitPriceMinor:1234,feeEligible:true}]}}));return id;};
 const shopId=await shop(),grant=ok(await call(owner,`/v1/households/${h}/views`,'POST',{shopId,mode:'edit',...projection()})),helper=await actor();helper.id=ok(await call(helper,'/v1/invites/redeem','POST',{token:grant.token,intent:'join',adultAttestation:true,alias:'Helper'})).memberId;await enroll(helper,h);
 const base=`/v1/households/${h}`,managed=base+'/views/'+grant.grantId,recipient=`/v1/views/${grant.grantId}`;
 const headers={'X-Household-ID':h,'X-View-Grant-ID':grant.grantId};
 async function propose(){const input={clientKey:randomUUID(),baseRevision:1,correction:'Untrusted suggestion text'};return{input,receipt:ok(await call(helper,recipient+'/proposals','POST',input,headers))};}
 return{owner,helper,h,shopId,grantId:grant.grantId,shop,base,managed,recipient,headers,propose};
}
test('shopper management projection is exact and recipients cannot read or mutate management routes',async()=>{
 const f=await fixture();const read=ok(await call(f.owner,f.managed));assert.deepEqual(read.projection,projection());assert.equal(read.revision,1);assert.equal(read.shopId,f.shopId);assert.equal(read.mode,'edit');assert.ok(read.expiresAt);
 assert.equal((await call(f.helper,f.managed)).status,404);assert.equal((await call(f.helper,f.managed,'GET',undefined,f.headers)).status,404);
 assert.equal((await call(f.helper,f.managed+'/replacements','POST',{clientKey:randomUUID(),baseRevision:1,projection:projection('Illicit')},f.headers)).status,404);
 const foreign=await fixture();assert.equal((await call(foreign.owner,f.managed)).status,404);assert.equal(JSON.stringify(read).includes('Private basket'),false);
});
test('full projection replacement replays its durable receipt and binds exact reviewed text',async()=>{
 const f=await fixture(),input={clientKey:randomUUID(),baseRevision:1,projection:projection('  Preserved spacing  ')};
 const result=ok(await call(f.owner,f.managed+'/replacements','POST',input));assert.equal(result.revision,2);assert.equal(result.status,'replaced');assert.deepEqual(ok(await call(f.owner,f.managed+'/replacements','POST',input)),result);
 const changed={...input,projection:projection('Preserved spacing')};assert.equal((await call(f.owner,f.managed+'/replacements','POST',changed)).data.error.code,'key_reused');
 assert.equal(ok(await call(f.owner,f.managed)).projection.shopLabel,'  Preserved spacing  ');assert.equal((await call(f.owner,f.managed+'/replacements','POST',{...input,clientKey:randomUUID()})).data.error.code,'stale_base');
 assert.equal((await admin.query('SELECT revision FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows[0].revision,1);
 assert.equal((await admin.query('SELECT count(*)::int AS n FROM ritc.basket_line WHERE household_id=$1',[f.h])).rows[0].n,1);
});
test('proposal replacement is explicit, durably reviewed and never automatically copies a suggestion or changes the basket',async()=>{
 const f=await fixture(),proposal=await f.propose();const input={clientKey:randomUUID(),baseRevision:1,proposalRevision:1,decision:'replace',projection:projection('Explicit shopper review')};
 assert.equal((await call(f.owner,f.managed+'/proposals/'+proposal.receipt.proposalId+'/resolve','POST',{clientKey:randomUUID(),baseRevision:1,proposalRevision:1,decision:'replace'})).status,422);
 const result=ok(await call(f.owner,f.managed+'/proposals/'+proposal.receipt.proposalId+'/resolve','POST',input));assert.equal(result.status,'reviewed');assert.equal(result.resolution,'replaced');assert.equal(result.revision,2);assert.equal(result.proposalRevision,2);
 assert.deepEqual(ok(await call(f.owner,f.managed+'/proposals/'+proposal.receipt.proposalId+'/resolve','POST',input)),result);
 const own=ok(await call(f.helper,f.recipient+'/proposals/'+proposal.receipt.proposalId,'GET',undefined,f.headers));assert.equal(own.resolution.mutationId,result.mutationId);assert.equal(own.status,'reviewed');
 assert.deepEqual(ok(await call(f.helper,f.recipient+'/proposals','POST',proposal.input,f.headers)),proposal.receipt);
 const list=ok(await call(f.owner,f.managed+'/proposals'));assert.equal(list.proposals[0].proposalRevision,2);assert.equal(list.proposals[0].resolution.revision,2);assert.equal(list.nextCursor,null);assert.deepEqual(ok(await call(f.owner,f.managed+'/proposals/'+proposal.receipt.proposalId)),own);assert.equal((await call(f.helper,f.managed+'/proposals/'+proposal.receipt.proposalId)).status,404);
 const view=ok(await call(f.helper,f.recipient+'/current','GET',undefined,f.headers));assert.equal(view.shopLabel,'Explicit shopper review');assert.equal(JSON.stringify(view).includes('Untrusted suggestion text'),false);
 assert.equal((await admin.query('SELECT revision FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows[0].revision,1);
});
test('dismissal leaves instructions unchanged; stale or competing proposal resolution cannot commit twice',async()=>{
 const f=await fixture(),p=await f.propose(),path=f.managed+'/proposals/'+p.receipt.proposalId+'/resolve',input={clientKey:randomUUID(),baseRevision:1,proposalRevision:1,decision:'dismiss'};
 const responses=await Promise.all([call(f.owner,path,'POST',input),call(f.owner,path,'POST',input)]);const receipt=ok(responses[0]);assert.deepEqual(ok(responses[1]),receipt);assert.equal(receipt.revision,1);assert.equal(receipt.status,'dismissed');assert.deepEqual(ok(await call(f.owner,f.managed)).projection,projection());
 assert.equal((await call(f.owner,path,'POST',{...input,clientKey:randomUUID()})).data.error.code,'stale_base');
 const stranger=await actor();assert.equal((await call(stranger,f.recipient+'/proposals/'+p.receipt.proposalId,'GET',undefined,{'X-Household-ID':f.h})).status,404);
 await call(f.owner,f.base+'/revocations','POST',{kind:'view',targetId:f.grantId});assert.equal((await call(f.owner,path,'POST',input)).status,404);assert.equal((await call(f.helper,f.recipient+'/proposals/'+p.receipt.proposalId,'GET',undefined,f.headers)).status,403);
});
test('multiple shops require explicit selection and native selection cannot drift to a newer or foreign shop',async()=>{
 const f=await fixture(),second=await f.shop();let bootstrap=ok(await call(f.owner,f.base+'/bootstrap'));assert.equal(bootstrap.shopId,null);assert.equal(bootstrap.selectionRequired,true);assert.equal(bootstrap.capabilities.includes('shopper_commands'),false);
 const list=ok(await call(f.owner,f.base+'/shops'));assert.deepEqual(new Set(list.shops.map(s=>s.shopId)),new Set([f.shopId,second]));assert.equal(JSON.stringify(list).includes('capMinor'),false);assert.equal(JSON.stringify(list).includes('Private basket'),false);
 bootstrap=ok(await call(f.owner,f.base+'/bootstrap','GET',undefined,{'X-Shop-ID':f.shopId}));assert.equal(bootstrap.shopId,f.shopId);assert.equal(bootstrap.role,'shopper');assert.equal(bootstrap.selectionRequired,false);
 assert.equal((await call(f.owner,f.base+'/shops/'+second,'GET',undefined,{'X-Shop-ID':f.shopId})).status,404);assert.equal((await call(f.owner,f.base+'/bootstrap','GET',undefined,{'X-Shop-ID':randomUUID()})).status,403);assert.equal((await call(f.owner,f.base+'/bootstrap','GET',undefined,{'X-Shop-ID':'invalid'})).status,422);
 assert.deepEqual(ok(await call(f.helper,f.base+'/shops')).shops,[]);assert.equal((await call(f.helper,f.base+'/bootstrap','GET',undefined,{'X-Shop-ID':f.shopId})).status,403);
 assert.equal((await call(f.helper,f.base+'/bootstrap','GET',undefined,{...f.headers,'X-Shop-ID':f.shopId})).status,404);
});
test('browser selected shop is persisted and revalidated rather than inferred on refresh',async()=>{
 const f=await fixture(),second=await f.shop();const activated=await call(f.owner,'/v1/session','POST',{householdId:f.h,shopId:f.shopId});const first=ok(activated);assert.equal(first.shopId,f.shopId);
 const cookie=activated.headers.get('set-cookie').split(';')[0],read=ok(await call(null,'/v1/session','GET',undefined,{Cookie:cookie}));assert.equal(read.shopId,f.shopId);
 const switched=await call(null,'/v1/session','POST',{householdId:f.h,shopId:second},{Cookie:cookie,Origin:'https://browser.fixture.invalid','X-CSRF-Token':first.csrf});assert.equal(ok(switched).shopId,second);
 assert.equal((await call(f.owner,'/v1/session','POST',{householdId:f.h,shopId:second,grantId:f.grantId})).status,422);
 await admin.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2",[f.h,f.owner.id]);assert.equal((await call(null,'/v1/session','GET',undefined,{Cookie:cookie})).status,403);
});

test('proposal pagination is bounded and binds cursors to the currently authorized grant',async()=>{
 const f=await fixture();await admin.query(`INSERT INTO ritc.helper_proposal(household_id,proposal_id,grant_id,actor_id,client_key,base_revision,correction,payload_digest) SELECT $1,gen_random_uuid(),$2,$3,gen_random_uuid(),1,'Pagination fixture',repeat('a',64) FROM generate_series(1,101)`,[f.h,f.grantId,f.helper.id]);
 const first=ok(await call(f.owner,f.managed+'/proposals'));assert.equal(first.proposals.length,100);assert.equal(first.nextCursor,first.proposals[99].proposalId);
 const second=ok(await call(f.owner,f.managed+'/proposals?cursor='+first.nextCursor));assert.equal(second.proposals.length,1);assert.equal(second.nextCursor,null);assert.equal(first.proposals.some(p=>p.proposalId===second.proposals[0].proposalId),false);
 assert.deepEqual(ok(await call(f.owner,f.managed+'/proposals/'+second.proposals[0].proposalId)),second.proposals[0]);
 const foreign=await fixture(),foreignProposal=await foreign.propose();assert.equal((await call(f.owner,f.managed+'/proposals?cursor='+foreignProposal.receipt.proposalId)).status,404);assert.equal((await call(f.owner,f.managed+'/proposals/'+foreignProposal.receipt.proposalId)).status,404);
 await call(f.owner,f.base+'/revocations','POST',{kind:'view',targetId:f.grantId});assert.equal((await call(f.owner,f.managed+'/proposals?cursor='+first.nextCursor)).status,404);
});

test('shop and request cursors preserve PostgreSQL submillisecond peers without omission or repetition',async()=>{
 const f=await fixture();await admin.query(`INSERT INTO ritc.shop(household_id,shop_id,shopper_id,quote,created_at) SELECT household_id,gen_random_uuid(),shopper_id,quote,'2026-01-01 00:00:00.123456+00'::timestamptz FROM ritc.shop CROSS JOIN generate_series(1,51) WHERE household_id=$1 AND shop_id=$2`,[f.h,f.shopId]);
 const first=ok(await call(f.owner,f.base+'/shops')),second=ok(await call(f.owner,f.base+'/shops?cursor='+first.nextCursor));assert.equal(first.shops.length,50);assert.equal(second.shops.length,2);assert.equal(new Set([...first.shops,...second.shops].map(s=>s.shopId)).size,52);assert.equal(second.nextCursor,null);
 await admin.query(`INSERT INTO ritc.request(household_id,request_id,author_id,client_request_id,shop_id,original_item,route,authored_at,received_at) SELECT $1,gen_random_uuid(),$2,gen_random_uuid(),$3,'Own request','current',now(),'2026-01-01 00:00:00.123456+00' FROM generate_series(1,51)`,[f.h,f.owner.id,f.shopId]);
 for(const route of ['/requests/mine','/shops/'+f.shopId+'/inbox']){const a=ok(await call(f.owner,f.base+route)),b=ok(await call(f.owner,f.base+route+'?cursor='+a.nextCursor));assert.equal(a.requests.length,50);assert.equal(b.requests.length,1);assert.equal(new Set([...a.requests,...b.requests].map(r=>r.requestId)).size,51);assert.equal(b.nextCursor,null);}
});

test('a selected shop excludes another shop’s own request, cursor, command and prior receipt',async()=>{
  const f=await fixture(), second=await f.shop();
  const selected={'X-Shop-ID':f.shopId}, other={'X-Shop-ID':second};
  function send(shopId,name) {
    return {v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId,kind:'request.send',
      base:{shopRevision:0,authorityEpoch:0},body:{clientRequestId:randomUUID(),originalItem:name,ownQuantity:null,authoredAt:new Date().toISOString()}};
  }
  const first=send(f.shopId,'First shop request'), later=send(second,'Other shop request');
  ok(await call(f.owner,f.base+'/commands','POST',first,selected));
  assert.equal((await call(f.owner,f.base+'/commands','POST',later,selected)).status,404);
  const received=ok(await call(f.owner,f.base+'/commands','POST',later,other));
  assert.equal((await call(f.owner,f.base+'/commands','POST',later,selected)).status,404);
  const mine=ok(await call(f.owner,f.base+'/requests/mine','GET',undefined,selected));
  assert.deepEqual(mine.requests.map(r=>r.originalItem),['First shop request']);
  assert.equal((await call(f.owner,f.base+'/requests/mine?cursor='+received.request.requestId,'GET',undefined,selected)).status,404);
});

test('real browser WebApp and API recover a dropped helper reply with exact original bytes after a newer projection', {skip:process.env.RITC_TEST_WEB_WIRE!=='1'}, async()=>{
 const [{JSDOM},{IDBFactory},{WebApp},{API},{Outbox}]=await Promise.all([
  import('../../web/node_modules/jsdom/lib/api.js'),import('../../web/node_modules/fake-indexeddb/build/esm/index.js'),
  import('../../web/dist/app.js'),import('../../web/dist/api.js'),import('../../web/dist/outbox.js')]);
 const f=await fixture(),activation=await call(f.helper,'/v1/session','POST',{householdId:f.h,grantId:f.grantId});
 assert.equal(ok(activation).role,'editor');assert.equal(activation.data.queueConsent,false);
 const cookie=activation.headers.get('set-cookie').split(';')[0],sent=[];let dropped=false,acceptedReceipt;
 const api=new API(async(path,options)=>{
  assert.equal(options.credentials,'same-origin');assert.equal(options.cache,'no-store');assert.equal(options.headers.Authorization,undefined);
  const response=await fetch(origin+path,{...options,headers:{...options.headers,Cookie:cookie,Origin:'https://browser.fixture.invalid'}});
  if(options.method==='POST'&&path===f.recipient+'/proposals'){
   sent.push(options.body);
   if(!dropped){assert.equal(response.status,200);acceptedReceipt=await response.clone().json();dropped=true;throw Error('Deliberately dropped after actual service commit');}
  }
  return response;
 });
 const dom=new JSDOM('<div id="app"></div>',{url:'https://browser.fixture.invalid/view'}),root=dom.window.document.getElementById('app'),outbox=new Outbox(new IDBFactory()),app=new WebApp(root,api,outbox);
 const idle=async()=>{const deadline=Date.now()+5000;while(root.querySelector('main')?.getAttribute('aria-busy')==='true'){assert.ok(Date.now()<deadline,root.textContent);await new Promise(r=>setTimeout(r,5));}};
 const click=async label=>{const button=[...root.querySelectorAll('button')].find(b=>b.textContent===label);assert.ok(button,`${label}: ${root.textContent}`);button.click();await idle();};
 await app.start();const correction='  No-salt frijoles / dos latas — keep original wording  ',input=root.querySelector('#correction');assert.ok(input);
 input.value=correction;input.dispatchEvent(new dom.window.Event('input',{bubbles:true}));root.querySelector('form').dispatchEvent(new dom.window.Event('submit',{cancelable:true,bubbles:true}));await idle();
 assert.ok(dropped);assert.match(root.textContent,/receipt is unconfirmed/);assert.doesNotMatch(root.textContent,/Not saved/);
 let rows=(await admin.query('SELECT proposal_id,base_revision,correction,client_key FROM ritc.helper_proposal WHERE household_id=$1 AND actor_id=$2',[f.h,f.helper.id])).rows;
 assert.equal(rows.length,1);assert.equal(rows[0].correction,correction.trim());assert.equal(rows[0].base_revision,1);assert.equal(rows[0].proposal_id,acceptedReceipt.proposalId);
 ok(await call(f.owner,f.managed+'/replacements','POST',{clientKey:randomUUID(),baseRevision:1,projection:projection('New current instructions')}));
 await click('Refresh');assert.match(root.textContent,/New current instructions/);assert.match(root.textContent,/Reviewed revision: 1/);
 await click('Retry original suggestion');assert.equal(sent.length,2);assert.equal(sent[0],sent[1]);assert.equal(JSON.parse(sent[1]).clientKey,rows[0].client_key);
 assert.match(root.textContent,/Suggestion received for shopper review/);
 ok(await call(f.owner,f.managed+'/proposals/'+acceptedReceipt.proposalId+'/resolve','POST',{clientKey:randomUUID(),baseRevision:2,proposalRevision:1,decision:'replace',projection:projection('Explicit approved correction')}));
 await click('Check suggestion status');assert.match(root.textContent,/Suggestion reviewed/);assert.doesNotMatch(root.textContent,/Private basket|capMinor|1234/);
 rows=(await admin.query('SELECT proposal_id,base_revision,correction,status FROM ritc.helper_proposal WHERE household_id=$1 AND actor_id=$2',[f.h,f.helper.id])).rows;
 assert.equal(rows.length,1);assert.equal(rows[0].base_revision,1);assert.equal(rows[0].correction,correction.trim());assert.equal(rows[0].status,'reviewed');
 // Recreating has no local retry envelope, but independently recovers received status from the service.
 // It must show a blank new draft and never automatically submit a duplicate.
 const recreated=new WebApp(root,api,outbox);await recreated.start();assert.equal(root.querySelector('#correction').value,'');assert.equal(sent.length,2);
 assert.match(root.textContent,/only kept on this page/);assert.match(root.textContent,/Suggestion reviewed/);assert.equal(dom.window.localStorage.length,0);assert.deepEqual(await outbox.list(f.h+'/'+f.helper.id),[]);
 await app.start();assert.match(root.textContent,/Suggestion reviewed/);
 ok(await call(f.owner,f.base+'/revocations','POST',{kind:'view',targetId:f.grantId}));await click('Check suggestion status');
 assert.match(root.textContent,/Access has ended/);assert.doesNotMatch(root.textContent,/No-salt frijoles|Explicit approved correction/);assert.equal(sent.length,2);
 dom.window.close();
});

test('own suggestion discovery is bounded, author/grant-scoped and preserves submillisecond cursor order',async()=>{
 const f=await fixture();await admin.query(`INSERT INTO ritc.helper_proposal(household_id,proposal_id,grant_id,actor_id,client_key,base_revision,correction,payload_digest,created_at) SELECT $1,gen_random_uuid(),$2,$3,gen_random_uuid(),1,'Own received suggestion',repeat('a',64),'2026-01-01 00:00:00.123456+00' FROM generate_series(1,41)`,[f.h,f.grantId,f.helper.id]);
 const foreignActor=(await admin.query(`INSERT INTO ritc.helper_proposal(household_id,proposal_id,grant_id,actor_id,client_key,base_revision,correction,payload_digest) VALUES($1,gen_random_uuid(),$2,$3,gen_random_uuid(),1,'OTHER ACTOR PRIVATE',repeat('b',64)) RETURNING proposal_id`,[f.h,f.grantId,f.owner.id])).rows[0].proposal_id;
 const read=cursor=>call(f.helper,f.recipient+'/proposals'+(cursor?'?cursor='+cursor:''),'GET',undefined,f.headers);
 const a=ok(await read()),b=ok(await read(a.nextCursor)),c=ok(await read(b.nextCursor));assert.equal(a.proposals.length,20);assert.equal(b.proposals.length,20);assert.equal(c.proposals.length,1);assert.equal(c.nextCursor,null);
 assert.equal(new Set([...a.proposals,...b.proposals,...c.proposals].map(p=>p.proposalId)).size,41);
 for(const page of [a,b,c])for(const proposal of page.proposals)assert.deepEqual(Object.keys(proposal).sort(),['proposalId','grantId','baseRevision','proposalRevision','correction','status','createdAt','resolution'].sort());
 assert.equal(JSON.stringify(a).includes('OTHER ACTOR PRIVATE'),false);assert.equal((await read(foreignActor)).status,404);
 const foreign=await fixture(),p=await foreign.propose();assert.equal((await read(p.receipt.proposalId)).status,404);
 assert.equal((await call(f.owner,f.recipient+'/proposals','GET',undefined,{'X-Household-ID':f.h})).status,404);
 assert.equal((await call(foreign.helper,f.recipient+'/proposals','GET',undefined,foreign.headers)).status,404);
 await admin.query("UPDATE ritc.view_grant SET mode='read' WHERE household_id=$1 AND grant_id=$2",[f.h,f.grantId]);assert.equal(ok(await read()).proposals.length,20);
 await call(f.owner,f.base+'/revocations','POST',{kind:'view',targetId:f.grantId});assert.equal((await read()).status,403);
});

test('real full browser recreation recovers a lost received suggestion with read-only retries and fences identity, expiry and revocation', {skip:process.env.RITC_TEST_WEB_WIRE!=='1'},async()=>{
 const [{JSDOM},{IDBFactory},{WebApp},{API},{Outbox}]=await Promise.all([
  import('../../web/node_modules/jsdom/lib/api.js'),import('../../web/node_modules/fake-indexeddb/build/esm/index.js'),
  import('../../web/dist/app.js'),import('../../web/dist/api.js'),import('../../web/dist/outbox.js')]);
 const f=await fixture(),other=await fixture();
 const activate=async fixture=>{const response=await call(fixture.helper,'/v1/session','POST',{householdId:fixture.h,grantId:fixture.grantId});assert.equal(ok(response).queueConsent,false);return response.headers.get('set-cookie').split(';')[0];};
 let cookie=await activate(f),posts=0,dropPost=true,dropDiscovery=false,holdDiscovery=false,release,accepted;
 const otherCookie=await activate(other),requests=[];
 const fetcher=async(path,options)=>{
  requests.push({path,method:options.method,body:options.body});
  const response=await fetch(origin+path,{...options,headers:{...options.headers,Cookie:cookie,Origin:'https://browser.fixture.invalid'}});
  if(options.method==='POST'&&path.endsWith('/proposals')){posts++;assert.equal(response.status,200);accepted=await response.clone().json();if(dropPost){dropPost=false;throw Error('Drop accepted response before client sees its receipt');}}
  if(options.method==='GET'&&path===f.recipient+'/proposals'){
   if(dropDiscovery){dropDiscovery=false;assert.equal(response.status,200);throw Error('Drop received-list response');}
   if(holdDiscovery){holdDiscovery=false;await new Promise(resolve=>{release=resolve;});}
  }
  return response;
 };
 let dom,root,app;
 const recreate=async()=>{dom?.window.close();dom=new JSDOM('<div id="app"></div>',{url:'https://browser.fixture.invalid/view'});root=dom.window.document.getElementById('app');app=new WebApp(root,new API(fetcher),new Outbox(new IDBFactory()));await app.start();};
 const idle=async()=>{const deadline=Date.now()+5000;while(root.querySelector('main')?.getAttribute('aria-busy')==='true'){assert.ok(Date.now()<deadline,root.textContent);await new Promise(r=>setTimeout(r,5));}};
 const click=async label=>{const button=[...root.querySelectorAll('button')].find(b=>b.textContent===label);assert.ok(button,`${label}: ${root.textContent}`);button.click();await idle();};
 await recreate();const input=root.querySelector('#correction');input.value='Recover this original received suggestion';input.dispatchEvent(new dom.window.Event('input',{bubbles:true}));root.querySelector('form').dispatchEvent(new dom.window.Event('submit',{cancelable:true,bubbles:true}));await idle();assert.match(root.textContent,/receipt is unconfirmed/);assert.equal(posts,1);
 ok(await call(f.owner,f.managed+'/replacements','POST',{clientKey:randomUUID(),baseRevision:1,projection:projection('Newer instructions after lost reply')}));
 // A completely new DOM, API, WebApp and empty storage have no original envelope or receipt ID.
 dropDiscovery=true;await recreate();assert.equal(root.querySelector('#correction'),null);assert.match(root.textContent,/Retry recovery before sending/);assert.equal(posts,1);
 await click('Check received suggestions');assert.match(root.textContent,/Recover this original received suggestion/);assert.match(root.textContent,/Reviewed revision: 1/);assert.match(root.textContent,/Newer instructions after lost reply/);assert.equal(root.querySelectorAll('[data-proposal-id]').length,1);assert.equal(posts,1);
 await click('Check received suggestions');assert.equal(posts,1);assert.equal(root.querySelectorAll('[data-proposal-id]').length,1);
 let rows=(await admin.query('SELECT proposal_id,base_revision,correction FROM ritc.helper_proposal WHERE household_id=$1 AND actor_id=$2',[f.h,f.helper.id])).rows;assert.equal(rows.length,1);assert.equal(rows[0].proposal_id,accepted.proposalId);assert.equal(rows[0].base_revision,1);assert.equal(rows[0].correction,'Recover this original received suggestion');
 ok(await call(f.owner,f.managed+'/proposals/'+accepted.proposalId+'/resolve','POST',{clientKey:randomUUID(),baseRevision:2,proposalRevision:1,decision:'dismiss'}));
 await admin.query("UPDATE ritc.view_grant SET mode='read' WHERE household_id=$1 AND grant_id=$2",[f.h,f.grantId]);await recreate();assert.match(root.textContent,/Suggestion dismissed/);assert.match(root.textContent,/read-only/);assert.equal(root.querySelector('#correction'),null);assert.equal(posts,1);assert.equal(dom.window.localStorage.length,0);
 // Delay an actual successful old-account list response; post-read session verification must fence it.
 holdDiscovery=true;const checking=click('Check received suggestions');while(!release)await new Promise(r=>setTimeout(r,5));cookie=otherCookie;release();await checking;
 assert.doesNotMatch(root.textContent,/Recover this original received suggestion/);assert.match(root.textContent,/Access has ended/);
 await recreate();assert.match(root.textContent,/No received suggestions/);assert.doesNotMatch(root.textContent,/Recover this original received suggestion/);
 cookie=await activate(f);await admin.query("UPDATE ritc.view_grant SET expires_at=now()-interval '1 second' WHERE household_id=$1 AND grant_id=$2",[f.h,f.grantId]);await recreate();assert.match(root.textContent,/Access has ended/);assert.doesNotMatch(root.textContent,/Recover this original received suggestion/);
 // Independent active grant verifies revoked receipt discovery after an actual prior submission.
 cookie=otherCookie;const own=await other.propose();await recreate();assert.match(root.textContent,/Untrusted suggestion text/);
 ok(await call(other.owner,other.base+'/revocations','POST',{kind:'view',targetId:other.grantId}));await recreate();assert.match(root.textContent,/Access has ended/);assert.doesNotMatch(root.textContent,/Untrusted suggestion text/);
 assert.equal((await call(other.helper,other.recipient+'/proposals/'+own.receipt.proposalId,'GET',undefined,other.headers)).status,403);
 assert.equal(posts,1);assert.equal(requests.filter(r=>r.method==='POST'&&r.path.endsWith('/proposals')).length,1);dom.window.close();
});
