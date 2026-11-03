import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {migrate} from '../scripts/migrate.mjs';
import {randomUUID} from 'node:crypto';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {BillingService} from '../dist/billing/service.js';
import {createHTTPServer} from '../dist/http.js';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),subscriptions=new Map();let verifiedCalls=0;
const gateway={verifyTransaction:async value=>{const current=subscriptions.get(value);if(!current)throw Error('fixture signature');return current;},current:async id=>{verifiedCalls++;const value=subscriptions.get(id);if(!value)throw Error('fixture unavailable');return value;},verifyNotification:async()=>{throw Error('unused');}};
const issuer='https://history.fixture.invalid',audience='authenticated';const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='history';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/keys'},createLocalJWKSet({keys:[jwk]})),repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)}),billing=new BillingService(gateway),server=createHTTPServer({repository:repo,verifier,billing,maxRequestsPerMinute:20000});let origin;
before(async()=>{if(!process.env.TEST_DATABASE_URL||!process.env.TEST_ADMIN_DATABASE_URL)throw Error('Explicit isolated local database URLs required');await admin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');await migrate(process.env.TEST_ADMIN_DATABASE_URL);await new Promise(r=>server.listen(0,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;});after(async()=>{await new Promise(r=>server.close(r));await Promise.all([admin.end(),runtime.end()]);});
async function actor(){const subject=randomUUID(),session=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);const token=await new SignJWT({session_id:session}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience(audience).setIssuedAt().setExpirationTime('1h').sign(privateKey);return{subject,session,token};}
async function call(a,path,method='GET',body,headers={}){const r=await fetch(origin+path,{method,headers:{Authorization:'Bearer '+a.token,...(a.device?{'X-Device-Token':a.device}:{}),...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})});return{status:r.status,data:await r.json()};}
function ok(r,status=200){assert.equal(r.status,status,JSON.stringify(r.data));return r.data;}
async function enroll(a,h){a.device=ok(await call(a,`/v1/households/${h}/devices`,'POST',{}),201).deviceToken;a.window=ok(await call(a,`/v1/households/${h}/replay-windows`,'POST',{})).id;}
async function fixture(){const owner=await actor(),created=ok(await call(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'History fixture',alias:'Adult',adultAttestation:true}),201),h=created.householdId,base=`/v1/households/${h}`;owner.id=created.memberId;await enroll(owner,h);
 const shop=async(price=10000)=>{const id=randomUUID(),quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:100000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date(Date.now()-60000).toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()};ok(await call(owner,base+'/commands','POST',{v:1,replayWindow:owner.window,clientKey:randomUUID(),shopId:id,kind:'shop.create',base:{shopRevision:0,authorityEpoch:0},body:{quote,lines:[{lineId:randomUUID(),originalItem:'Private basket source',packs:1,unitPriceMinor:price,feeEligible:true}]}}));return id;};
 const shopId=await shop();async function paid(){const token=ok(await call(owner,base+'/billing/purchase-context','POST',{})).appAccountToken,original=String(Date.now())+String(Math.floor(Math.random()*1e6)),now=Date.now();subscriptions.set(original,{environment:'Sandbox',originalTransactionID:original,transactionID:original,appAccountToken:token,productID:'fixture.household.yearly',purchasedAt:now,signedAt:now,expiresAt:now+3600000,graceExpiresAt:null,status:'active'});ok(await call(owner,'/v1/billing/verify','POST',{householdId:h,signedTransactionInfo:original}));return original;}
 const version=async(id=shopId)=>ok(await call(owner,base+`/shops/${id}/financial-evidence`)).sourceVersion;
 const financial=async(entry,id=shopId)=>{const input={clientKey:randomUUID(),sourceVersion:await version(id),entry};return{input,result:ok(await call(owner,base+`/shops/${id}/financial-evidence`,'POST',input))};};
 return{owner,h,base,shopId,shop,paid,version,financial};}

async function mealFixture() {
 const f=await fixture(),path=f.base+'/shops/'+f.shopId,changePath=path+'/meal-plan/changes';
 const planner=await actor(),invite=ok(await call(f.owner,f.base+'/invites','POST',{kind:'adult_contributor'}));
 planner.id=ok(await call(planner,'/v1/invites/redeem','POST',{token:invite.token,intent:'join',adultAttestation:true,alias:'Planner'})).memberId;
 await enroll(planner,f.h);await f.paid();const seats=ok(await call(f.owner,f.base+'/entitlements'));
 ok(await call(f.owner,f.base+'/billing/seats','PUT',{revision:seats.revision,userIDs:[f.owner.id,planner.id]}));
 const initial=ok(await call(f.owner,path)),occurrenceId=randomUUID(),dinner=randomUUID(),lunch=randomUUID(),ingredient=randomUUID();
 const quantity=n=>({amount:{numerator:n,denominator:1},unit:'gram',originalLiteral:n+' g'});
 const meal={title:'Reviewed supper',day:'2026-11-05',kind:'dinner',portions:6,protected:false,planning:{sourceOccurrenceId:randomUUID(),
  groups:[{id:dinner,name:'Dinner group',servings:{numerator:4,denominator:1},protected:false},{id:lunch,name:'Protected lunch',servings:{numerator:2,denominator:1},protected:true}],
  ingredients:[{id:ingredient,name:'Beans',quantity:quantity(600),groupIds:[dinner,lunch],exclusions:['No sesame']}],
  bindings:[{id:randomUUID(),ingredientId:ingredient,groupId:dinner,quantity:quantity(400)},{id:randomUUID(),ingredientId:ingredient,groupId:lunch,quantity:quantity(200)}]}};
 const patch=(revision,mealEdit,extra={})=>({v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind:'shop.patch',base:{shopRevision:revision,authorityEpoch:1},body:{quote:initial.quote,lines:initial.lines,mealEdit,...extra}});
 ok(await call(f.owner,f.base+'/commands','POST',patch(1,{occurrenceId,baseMealRevision:null,meal})));
 ok(await call(f.owner,path+'/meal-plan/planner','PUT',{authorityEpoch:1,grantRevision:0,plannerId:planner.id}));
 const changed=structuredClone(meal);changed.portions=4;changed.planning.groups[0].servings.numerator=2;changed.planning.ingredients[0].quantity=quantity(400);changed.planning.bindings[0].quantity=quantity(200);
 const proposal={proposalId:randomUUID(),occurrenceId,baseMealRevision:2,shopRevision:2,authorityEpoch:1,grantRevision:1,meal:changed,reason:'Guests changed; keep the two protected lunches.'};
 return {...f,path,changePath,planner,initial,meal,changed,proposal,patch};
}

test('cross-device proposal keeps basket private and applies exact reviewed meal, packs and quote once',async()=>{
 const f=await mealFixture(),before=ok(await call(f.owner,f.path));
 const view=ok(await call(f.planner,f.changePath));assert.equal(view.shopper,false);assert.equal(view.quote,undefined);assert.equal(view.lines,undefined);
 assert.equal((await call(f.planner,f.path)).status,404);
 const saved=ok(await call(f.planner,f.changePath,'POST',f.proposal));assert.deepEqual(ok(await call(f.planner,f.changePath,'POST',f.proposal)),saved);
 assert.equal((await call(f.planner,f.changePath,'POST',{...f.proposal,reason:'Different'})).data.error.code,'key_reused');
 assert.deepEqual(ok(await call(f.owner,f.path)),before);
 const shared=ok(await call(f.owner,f.changePath));assert.deepEqual(shared.proposals[0].original,f.meal);assert.deepEqual(shared.proposals[0].request,f.proposal);
 const edit={occurrenceId:f.proposal.occurrenceId,baseMealRevision:2,meal:f.changed,changeProposalId:f.proposal.proposalId};
 assert.equal((await call(f.owner,f.base+'/commands','POST',f.patch(2,{...edit,meal:{...f.changed,title:'Silent rewrite'}}))).data.error.code,'stale_proposal');
 const command=f.patch(2,edit,{lines:f.initial.lines.map(line=>({...line,packs:2})),quote:{...f.initial.quote,taxesMinor:55}});
 const responses=await Promise.all([call(f.owner,f.base+'/commands','POST',command),call(f.owner,f.base+'/commands','POST',command)]);
 const receipt=ok(responses[0]);assert.deepEqual(ok(responses[1]),receipt);assert.equal(receipt.shopRevision,3);
 const after=ok(await call(f.owner,f.path));assert.equal(after.lines[0].packs,2);assert.equal(after.quote.taxesMinor,55);assert.deepEqual(after.meals[0].meal,f.changed);
 assert.equal(ok(await call(f.planner,f.changePath)).proposals[0].state,'applied');assert.deepEqual(ok(await call(f.planner,f.changePath,'POST',f.proposal)),saved);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_meal_revision WHERE household_id=$1',[f.h])).rows[0].n,2);
});

test('protected group identities, servings, ingredients, exclusions and fixed allocations cannot be reduced through proposal or direct patch',async()=>{
 const f=await mealFixture();
 const mutations=[m=>m.planning.groups.pop(),m=>m.planning.groups[1].servings.numerator=1,m=>m.planning.groups[1].protected=false,
  m=>m.planning.ingredients[0].exclusions=[],m=>m.planning.bindings[1].quantity.amount.numerator=100,
  m=>m.planning.ingredients=[],m=>m.planning.groups[1].name='Repurposed'];
 for(const mutate of mutations){const meal=structuredClone(f.changed);mutate(meal);const response=await call(f.planner,f.changePath,'POST',{...f.proposal,proposalId:randomUUID(),meal});assert.ok([409,422].includes(response.status),JSON.stringify(response));
  const direct=await call(f.owner,f.base+'/commands','POST',f.patch(2,{occurrenceId:f.proposal.occurrenceId,baseMealRevision:2,meal}));assert.ok([409,422].includes(direct.status));}
 ok(await call(f.planner,f.changePath,'POST',f.proposal));
 assert.equal(ok(await call(f.owner,f.path)).shopRevision,2);
});

test('stale source, changed calendar day, changed unit and invented group identity fail closed',async()=>{
 const f=await mealFixture();
 for(const meal of [{...f.changed,day:'2026-11-06'},{...f.changed,planning:{...f.changed.planning,groups:[f.changed.planning.groups[0],f.changed.planning.groups[0]]}}])
  assert.ok([409,422].includes((await call(f.planner,f.changePath,'POST',{...f.proposal,meal})).status));
 const mixed=structuredClone(f.changed);mixed.planning.bindings[0].quantity.unit='milliliter';assert.equal((await call(f.planner,f.changePath,'POST',{...f.proposal,meal:mixed})).status,422);
 ok(await call(f.planner,f.changePath,'POST',f.proposal));ok(await call(f.owner,f.base+'/commands','POST',f.patch(2,undefined)));
 const edit={occurrenceId:f.proposal.occurrenceId,baseMealRevision:2,meal:f.changed,changeProposalId:f.proposal.proposalId};
 assert.equal((await call(f.owner,f.base+'/commands','POST',f.patch(3,edit))).data.error.code,'stale_proposal');
 assert.equal((await call(f.planner,f.changePath,'POST',{...f.proposal,proposalId:randomUUID()})).status,409);
});

test('frozen/placed order retains an amendment proposal without any automatic retailer or basket edit',async()=>{
 const f=await mealFixture();ok(await call(f.owner,f.base+'/commands','POST',{v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind:'shop.freeze',base:{shopRevision:2,authorityEpoch:1},body:{}}));
 const proposal={...f.proposal,shopRevision:3};ok(await call(f.planner,f.changePath,'POST',proposal));
 assert.ok(ok(await call(f.planner,f.base+'/bootstrap')).capabilities.includes('meal_proposals'));
 const command=f.patch(3,{occurrenceId:proposal.occurrenceId,baseMealRevision:2,meal:proposal.meal,changeProposalId:proposal.proposalId});
 assert.equal((await call(f.owner,f.base+'/commands','POST',command)).data.error.code,'checkout_locked');
 ok(await call(f.owner,f.base+'/commands','POST',{v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind:'shop.reportPlaced',base:{shopRevision:3,authorityEpoch:1},body:{occurredAt:new Date().toISOString()}}));
 const placed=ok(await call(f.planner,f.changePath));assert.equal(placed.phase,'placed');assert.equal(placed.proposals[0].state,'pending');
 assert.deepEqual(ok(await call(f.owner,f.path)).lines,f.initial.lines);
});

test('planner revocation and authority transfer block old submissions and shopper applications, including successful retries',async()=>{
 const f=await mealFixture();ok(await call(f.planner,f.changePath,'POST',f.proposal));
 ok(await call(f.owner,f.path+'/meal-plan/planner','PUT',{authorityEpoch:1,grantRevision:1,plannerId:null}));
 assert.equal((await call(f.planner,f.changePath,'POST',f.proposal)).status,404);
 const edit={occurrenceId:f.proposal.occurrenceId,baseMealRevision:2,meal:f.changed,changeProposalId:f.proposal.proposalId};
 assert.equal((await call(f.owner,f.base+'/commands','POST',f.patch(2,edit))).status,409);
 ok(await call(f.owner,f.base+'/commands','POST',{v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind:'shop.transferAuthority',base:{shopRevision:2,authorityEpoch:1},body:{newShopperId:f.planner.id}}));
 assert.equal((await call(f.owner,f.changePath)).status,404);assert.equal((await call(f.owner,f.base+'/commands','POST',f.patch(2,edit))).status,404);
 assert.deepEqual(ok(await call(f.planner,f.changePath)).proposals,[]);
});

test('named planning seat lapse blocks proposal reads and retries; Free shopper review remains available',async()=>{
 const f=await mealFixture();ok(await call(f.planner,f.changePath,'POST',f.proposal));
 await admin.query('DELETE FROM ritc.billing_seat WHERE household_id=$1 AND member_id=$2',[f.h,f.planner.id]);
 assert.equal((await call(f.planner,f.changePath)).data.error.code,'membership_inactive');
 assert.equal((await call(f.planner,f.changePath,'POST',f.proposal)).data.error.code,'membership_inactive');
 assert.equal(ok(await call(f.owner,f.changePath)).proposals.length,1);
 const foreign=await mealFixture();assert.equal((await call(foreign.owner,f.changePath)).status,404);
});

test('account erasure removes accepted proposal copies and exact retry evidence without restoring old meal labels',async()=>{
 const f=await mealFixture();ok(await call(f.planner,f.changePath,'POST',f.proposal));
 ok(await call(f.owner,f.base+'/commands','POST',f.patch(2,{occurrenceId:f.proposal.occurrenceId,baseMealRevision:2,meal:f.changed,changeProposalId:f.proposal.proposalId})));
 await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.planner.id]);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_meal_change WHERE household_id=$1',[f.h])).rows[0].n,0);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_meal_revision WHERE household_id=$1',[f.h])).rows[0].n,0);
 assert.deepEqual(ok(await call(f.owner,f.path)).meals,[]);
});

if(process.env.RITC_TEST_NATIVE_WIRE==='1') test('actual Swift planner proposal and separate shopper review travel over pinned loopback HTTPS and PostgreSQL',async()=>{
 const {exerciseSharedMealClient}=await import('./shared-meal-native-wire.mjs');const f=await mealFixture();
 await exerciseSharedMealClient({service:server,owner:f.planner,householdId:f.h,shopId:f.shopId,shopper:false});
 assert.equal(ok(await call(f.owner,f.path)).shopRevision,2);
 await exerciseSharedMealClient({service:server,owner:f.owner,householdId:f.h,shopId:f.shopId,shopper:true});
 const current=ok(await call(f.owner,f.path));assert.equal(current.shopRevision,3);assert.equal(current.meals[0].meal.title,'Reviewed native guest plan');
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_meal_change WHERE household_id=$1',[f.h])).rows[0].n,1);
});


test('concurrent planning grant revocation and shopper apply serialize without a partially consumed proposal',async()=>{
 const f=await mealFixture();ok(await call(f.planner,f.changePath,'POST',f.proposal));
 const edit={occurrenceId:f.proposal.occurrenceId,baseMealRevision:2,meal:f.changed,changeProposalId:f.proposal.proposalId};
 const [revocation,application]=await Promise.all([
  call(f.owner,f.path+'/meal-plan/planner','PUT',{authorityEpoch:1,grantRevision:1,plannerId:null}),
  call(f.owner,f.base+'/commands','POST',f.patch(2,edit))]);
 ok(revocation);assert.ok([200,409].includes(application.status),JSON.stringify(application));
 const applied=application.status===200,shop=ok(await call(f.owner,f.path));
 assert.equal(shop.shopRevision,applied?3:2);assert.deepEqual(shop.meals[0].meal,applied?f.changed:f.meal);
 const state=(await admin.query('SELECT state FROM ritc.shared_meal_change WHERE household_id=$1 AND proposal_id=$2',[f.h,f.proposal.proposalId])).rows[0].state;
 assert.equal(state,applied?'applied':'pending');assert.equal((await call(f.planner,f.changePath,'POST',f.proposal)).status,404);
});
