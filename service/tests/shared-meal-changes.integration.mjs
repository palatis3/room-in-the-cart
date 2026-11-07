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

test('protecting a whole meal also preserves its named groups and their exact ingredient quantities',async()=>{
 const f=await mealFixture(), occurrenceId=f.proposal.occurrenceId;
 const protectedMeal={...f.meal,protected:true};
 ok(await call(f.owner,f.base+'/commands','POST',f.patch(2,{occurrenceId,baseMealRevision:2,meal:protectedMeal})));
 const propose=meal=>call(f.planner,f.changePath,'POST',{...f.proposal,proposalId:randomUUID(),
   baseMealRevision:3,shopRevision:3,meal});
 const apply=meal=>call(f.owner,f.base+'/commands','POST',f.patch(3,{occurrenceId,baseMealRevision:3,meal}));
 for(const change of [
   m=>{m.planning.groups[0].name='Different recipient';},
   m=>{m.planning.groups[0].servings.numerator=3;},
   m=>{m.planning.bindings[0].quantity=f.changed.planning.bindings[0].quantity;
       m.planning.bindings[1].quantity=f.meal.planning.bindings[0].quantity;},
 ]){
   const meal=structuredClone(protectedMeal);change(meal);
   assert.equal((await propose(meal)).data.error?.code,'protected_meal');
   assert.equal((await apply(meal)).data.error?.code,'protected_meal');
 }
 const renamed={...protectedMeal,title:'Reviewed dinner title'};
 ok(await propose(renamed));ok(await apply(renamed));
 assert.deepEqual(ok(await call(f.owner,f.path)).meals[0].meal,renamed);
});

test('an ordinary group binding cannot establish the amount available to an unquantified protected group',async()=>{
 const f=await mealFixture(), occurrenceId=randomUUID();
 const original=structuredClone(f.meal), ingredient=original.planning.ingredients[0];
 original.planning.bindings=original.planning.bindings.slice(0,1);
 original.planning.bindings[0].quantity=ingredient.quantity;
 const save=(revision,prior,meal)=>call(f.owner,f.base+'/commands','POST',f.patch(revision,{occurrenceId,baseMealRevision:prior,meal}));
 ok(await save(2,null,original));
 const reduced=structuredClone(original);
 reduced.planning.ingredients[0].quantity=f.changed.planning.ingredients[0].quantity;
 reduced.planning.bindings[0].quantity=reduced.planning.ingredients[0].quantity;
 const rejected=await save(3,3,reduced);
 assert.equal(rejected.status,409);assert.equal(rejected.data.error.code,'protected_meal');
 const relabeled={...original,title:'Same reserved beans'};
 ok(await save(3,3,relabeled));
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
 const send=(kind,body,revision)=>({v:1,kind,shopId:f.shopId,replayWindow:f.owner.window,clientKey:randomUUID(),
  body,base:{shopRevision:revision,authorityEpoch:1}});
 const save=cmd=>call(f.owner,f.base+'/commands','POST',cmd);
 const evidence=async()=>ok(await call(f.owner,f.path+'/delivery-evidence'));
 ok(await save(send('shop.reportPlaced',{occurredAt:new Date().toISOString()},3)));
 const sourceId=ok(await save(send('delivery.register',{supplyRevision:0,placedRevision:3,lineId:f.initial.lines[0].lineId,
  segmentKey:randomUUID(),foodName:'Beans',exclusionTags:[]},4))).sourceId;
 const matched=send('delivery.match',{sourceId,supplyRevision:1,occurrenceId:f.proposal.occurrenceId,
  mealRevision:3,ingredientId:f.changed.planning.ingredients[0].id,matched:true},4);
 ok(await save(matched));assert.equal((await evidence()).sources[0].matches.length,1);
 const quantity={amount:{numerator:1,denominator:1},unit:'gram',originalLiteral:'1 g'};
 const arrival=randomUUID();
 ok(await save(send('delivery.arrival',{sourceId,supplyRevision:2,observationId:arrival,predecessorId:null,
   arrivedAt:new Date(Date.now()-1000).toISOString(),received:quantity},4)));
 ok(await save(send('delivery.usable',{sourceId,supplyRevision:3,observationId:randomUUID(),predecessorId:null,
   arrivalObservationId:arrival,confirmedAt:new Date().toISOString(),usable:quantity},4)));
 const reserved=send('delivery.reserve',{sourceId,supplyRevision:4,occurrenceId:f.proposal.occurrenceId,
   mealRevision:3,ingredientId:f.changed.planning.ingredients[0].id,groupId:f.changed.planning.groups[1].id,
   predecessorId:null,quantity},4);
 ok(await save(reserved));
 const occurrenceId=f.proposal.occurrenceId;
 const cook=send('cookCopy.save',{placedRevision:3,supplyRevision:5,occurrenceId,mealRevision:3,language:'es',text:'Instrucciones privadas del plan.'},4);
 const dated=ok(await save(cook));
 const mark=send('cookCopy.markSent',{copyId:dated.copyId,recipient:'Cocinera',previousSendId:null},4);
 ok(await save(mark));
 await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.planner.id]);
 assert.deepEqual(ok(await call(f.owner,f.path+'/cook-copies?occurrenceId='+occurrenceId)),{copies:[],nextCursor:null});
 assert.deepEqual(ok(await call(f.owner,f.path+'/cook-copies/baseline','POST',{occurrenceId,recipient:'Cocinera'})),{baseline:null});
 assert.equal((await save(cook)).status,409);assert.equal((await save(mark)).status,409);
 const after=await evidence();
 assert.deepEqual(after.meals,[]);assert.deepEqual(after.sources[0].matches,[]);assert.equal(after.supplyRevision,6);
 assert.deepEqual(after.sources[0].reservations,[]);assert.equal((await save(reserved)).status,409);
 assert.equal(after.sources[0].sourceId,sourceId);assert.equal((await save(matched)).status,409);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_meal_change WHERE household_id=$1',[f.h])).rows[0].n,0);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_meal_revision WHERE household_id=$1',[f.h])).rows[0].n,0);
 assert.deepEqual(ok(await call(f.owner,f.path)).meals,[]);
});

if(process.env.RITC_TEST_NATIVE_WIRE==='1') test('actual Swift planner proposal and separate shopper review travel over pinned loopback HTTPS and PostgreSQL',async()=>{
 const {exerciseSharedMealClient}=await import('./shared-meal-native-wire.mjs');const f=await mealFixture();
 await exerciseSharedMealClient({service:server,owner:f.planner,householdId:f.h,shopId:f.shopId,shopper:false});
 assert.equal(ok(await call(f.owner,f.path)).shopRevision,2);
 await exerciseSharedMealClient({service:server,owner:f.owner,householdId:f.h,shopId:f.shopId,shopper:true});
 const current=ok(await call(f.owner,f.path));assert.equal(current.shopRevision,4);assert.equal(current.placedRevision,3);
 assert.equal(current.meals[0].meal.title,'Reviewed native guest plan');
 const saved=ok(await call(f.owner,f.path+'/delivery-evidence'));
 assert.equal(saved.sources.length,1);assert.equal(saved.sources[0].confirmed.quantity.amount.numerator,7);
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

test('placed delivery corrections, split arrivals, replay and shopper changes preserve the sealed shop', async () => {
  const f=await fixture(), path=f.base+'/shops/'+f.shopId, evidence=path+'/delivery-evidence', commands=f.base+'/commands';
  const shop=ok(await call(f.owner,path)), lineId=shop.lines[0].lineId;
  const command=(kind,body,revision=2,epoch=1)=>({v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,
    kind,base:{shopRevision:revision,authorityEpoch:epoch},body});
  const save=body=>call(f.owner,commands,'POST',body);
  const read=async()=>ok(await call(f.owner,evidence));
  const q=n=>({amount:{numerator:n,denominator:1},unit:'count',originalLiteral:String(n)});
  const segment={supplyRevision:0,placedRevision:1,lineId,segmentKey:randomUUID(),foodName:'Eight wraps',exclusionTags:['sesame']};
  assert.equal((await save(command('delivery.register',segment,1))).status,409);
  ok(await save(command('shop.reportPlaced',{occurredAt:new Date().toISOString()},1)));
  const sealed=ok(await call(f.owner,path));
  assert.ok(ok(await call(f.owner,f.base+'/bootstrap')).capabilities.includes('delivery_evidence'));
  assert.deepEqual((await read()).lines,[{lineId,name:shop.lines[0].originalItem}]);
  assert.deepEqual((await read()).sources,[]);
  assert.equal((await save(command('delivery.register',{...segment,lineId:randomUUID()}))).status,404);
  const create=command('delivery.register',segment), created=ok(await save(create)), id=created.sourceId;
  assert.deepEqual(ok(await save(create)),created);
  assert.equal((await save({...create,body:{...segment,foodName:'different'}})).data.error.code,'key_reused');
  assert.equal((await save(command('delivery.register',{...segment,supplyRevision:1}))).status,409);
  const arrive=(revision,previous=null)=>({sourceId:id,observationId:randomUUID(),predecessorId:previous,supplyRevision:revision,
    arrivedAt:new Date(Date.now()-60000).toISOString(),received:q(8)});
  const a=arrive(1);
  ok(await save(command('delivery.arrival',a)));
  assert.equal((await read()).sources[0].confirmed,null);
  const review=(revision,arrival,previous,n)=>({sourceId:id,observationId:randomUUID(),predecessorId:previous,supplyRevision:revision,
    arrivalObservationId:arrival,confirmedAt:new Date().toISOString(),usable:q(n)});
  const u=review(2,a.observationId,null,6);
  assert.equal((await save(command('delivery.usable',{...u,usable:q(9)}))).status,422);
  assert.equal((await save(command('delivery.usable',{...u,usable:{...q(1),unit:'gram'}}))).status,422);
  ok(await save(command('delivery.usable',u)));
  assert.equal((await read()).sources[0].confirmed.quantity.amount.numerator,6);
  const seven=review(3,a.observationId,u.observationId,7);
  const contenders=[command('delivery.usable',seven),command('delivery.usable',{...seven,observationId:randomUUID()})];
  const results=await Promise.all(contenders.map(save));
  assert.deepEqual(results.map(r=>r.status).sort(),[200,409]);
  assert.equal((await read()).sources[0].confirmed.quantity.amount.numerator,7);
  const correction=arrive(4,a.observationId);
  ok(await save(command('delivery.arrival',correction)));
  let current=(await read()).sources[0];
  assert.equal(current.confirmed,null);
  assert.equal((await save(command('delivery.usable',review(5,a.observationId,current.usable.observationId,7)))).status,409);
  const update=review(5,correction.observationId,current.usable.observationId,7);
  ok(await save(command('delivery.usable',update)));
  const split=ok(await save(command('delivery.register',{...segment,supplyRevision:6,segmentKey:randomUUID()})));
  const future={...arrive(7),sourceId:split.sourceId,arrivedAt:new Date(Date.now()+86400000).toISOString(),received:q(2)};
  ok(await save(command('delivery.arrival',future)));
  const premature={...review(8,future.observationId,null,2),sourceId:split.sourceId};
  assert.equal((await save(command('delivery.usable',premature))).status,422);
  assert.equal((await save(command('delivery.usable',{...premature,confirmedAt:future.arrivedAt}))).status,422);
  ok(await save(command('delivery.usable',{...premature,usable:null})));
  const projection=await read();
  assert.equal(projection.supplyRevision,9);
  assert.equal(projection.sources.find(s=>s.sourceId===split.sourceId).confirmed,null);
  assert.equal(projection.sources.find(s=>s.sourceId===id).confirmed.quantity.amount.numerator,7);
  const actual={...arrive(9,future.observationId),sourceId:split.sourceId,received:q(2)};
  ok(await save(command('delivery.arrival',actual)));
  const splitCount={...review(10,actual.observationId,premature.observationId,2),sourceId:split.sourceId};
  ok(await save(command('delivery.usable',splitCount)));
  assert.deepEqual((await read()).sources.map(s=>s.confirmed.quantity.amount.numerator).sort(),[2,7]);
  assert.deepEqual(ok(await call(f.owner,path)),sealed);
  const other=await fixture();
  assert.equal((await call(other.owner,evidence)).status,404);
  const adult=await actor(), invite=ok(await call(f.owner,f.base+'/invites','POST',{kind:'adult_contributor'}));
  adult.id=ok(await call(adult,'/v1/invites/redeem','POST',{token:invite.token,intent:'join',adultAttestation:true,alias:'New shopper'})).memberId;
  await enroll(adult,f.h);
  assert.equal((await call(adult,evidence)).status,404);
  assert.ok(!ok(await call(adult,f.base+'/bootstrap')).capabilities.includes('delivery_evidence'));
  ok(await save(command('shop.transferAuthority',{newShopperId:adult.id})));
  assert.equal((await save(create)).status,404);
  assert.equal((await call(f.owner,evidence)).status,404);
  assert.equal(ok(await call(adult,evidence)).sources.length,2);
  const db=await runtime.connect();
  try {
    await db.query('BEGIN');
    await db.query("SELECT set_config('app.household_id',$1,true)",[other.h]);
    assert.equal((await db.query('SELECT * FROM ritc.delivery_observation WHERE household_id=$1',[f.h])).rowCount,0);
    assert.equal((await db.query('SELECT * FROM ritc.delivery_source WHERE household_id=$1',[f.h])).rowCount,0);
    await assert.rejects(()=>db.query('DELETE FROM ritc.delivery_observation'),error=>error.code==='42501');
  } finally { await db.query('ROLLBACK'); db.release(); }
  const currentShop=ok(await call(adult,path));
  const ownSegment={...segment,supplyRevision:11,segmentKey:randomUUID(),foodName:'Separately reviewed food'};
  const ownCommand={...command('delivery.register',ownSegment,currentShop.shopRevision,currentShop.authorityEpoch),replayWindow:adult.window};
  const ownReceipt=ok(await call(adult,commands,'POST',ownCommand));
  await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.owner.id]);
  assert.deepEqual(ok(await call(adult,evidence)).sources.map(s=>s.sourceId),[ownReceipt.sourceId]);
  assert.equal(ok(await call(adult,evidence)).supplyRevision,13);
  assert.equal((await admin.query('SELECT * FROM ritc.delivery_observation WHERE household_id=$1',[f.h])).rowCount,0);
});

test('delivery ingredient matches use the sealed occurrence, explicit shopper review and supply revision',async()=>{
 const f=await mealFixture(), endpoint=f.path+'/delivery-evidence';
 const command=(kind,body,shopRevision=4)=>({kind,v:1,replayWindow:f.owner.window,clientKey:randomUUID(),
   shopId:f.shopId,base:{shopRevision,authorityEpoch:1},body});
 const send=input=>call(f.owner,f.base+'/commands','POST',input);
 const secondOccurrence=randomUUID();
 ok(await send(f.patch(2,{occurrenceId:secondOccurrence,baseMealRevision:null,meal:{...f.meal,title:'Another lunch'}})));
 ok(await send(command('shop.reportPlaced',{occurredAt:new Date().toISOString()},3)));
 const read=async()=>ok(await call(f.owner,endpoint));
 const initial=await read();
 assert.equal(initial.meals.length,2);
 assert.deepEqual(initial.meals.find(m=>m.occurrenceId===f.proposal.occurrenceId),{occurrenceId:f.proposal.occurrenceId,revision:2,meal:f.meal});
 const sourceId=ok(await send(command('delivery.register',{supplyRevision:0,placedRevision:3,lineId:initial.lines[0].lineId,
   segmentKey:randomUUID(),foodName:'Beans',exclusionTags:[]}))).sourceId;
 const target={occurrenceId:f.proposal.occurrenceId,mealRevision:2,ingredientId:f.meal.planning.ingredients[0].id};
 const body={sourceId,supplyRevision:1,...target,matched:true};
 assert.deepEqual((await read()).sources[0].matches,[]);
 for(const bad of [{mealRevision:1},{occurrenceId:randomUUID()},{ingredientId:randomUUID()},{sourceId:randomUUID()}]){
   assert.equal((await send(command('delivery.match',{...body,...bad}))).status,404);
 }
 const save=command('delivery.match',body);
 const plannerResult=await call(f.planner,f.base+'/commands','POST',{...save,replayWindow:f.planner.window});
 assert.equal(plannerResult.status,404);
 const race=await Promise.all([send(save),send(command('delivery.match',body))]);
 assert.deepEqual(race.map(r=>r.status).sort(),[200,409]);
 const matched=await read();
 assert.deepEqual(matched.sources[0].matches,[target]);
 assert.equal(matched.sources[0].confirmed,null);assert.equal(matched.supplyRevision,2);
 assert.equal((await send(command('delivery.match',{...body,supplyRevision:2}))).status,409);
 const remove=command('delivery.match',{...body,matched:false,supplyRevision:2});
 const receipt=ok(await send(remove));assert.deepEqual(ok(await send(remove)),receipt);
 assert.deepEqual((await read()).sources[0].matches,[]);
 const restore=command('delivery.match',{...body,supplyRevision:3});
 ok(await send(restore));
 const secondTarget={...target,occurrenceId:secondOccurrence,mealRevision:3};
 ok(await send(command('delivery.match',{sourceId,...secondTarget,supplyRevision:4,matched:true})));
 const both=await read();
 assert.deepEqual(both.meals,initial.meals);
 assert.deepEqual(both.sources[0].matches.sort((a,b)=>a.occurrenceId.localeCompare(b.occurrenceId)),
   [target,secondTarget].sort((a,b)=>a.occurrenceId.localeCompare(b.occurrenceId)));
 ok(await send(command('delivery.match',{...body,supplyRevision:5,matched:false})));
 assert.deepEqual((await read()).sources[0].matches,[secondTarget]);
 await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.owner.id]);
 assert.deepEqual((await read()).meals,[]);
 assert.deepEqual((await read()).sources,[]);
 assert.equal((await send(restore)).status,409);
});

test('shopper reads protected meal coverage from current confirmed deliveries; a correction changes the result',async()=>{
 const f=await mealFixture(),endpoint=f.path+'/delivery-evidence/coverage';
 const send=(kind,body,revision=3)=>call(f.owner,f.base+'/commands','POST',{kind,body,v:1,replayWindow:f.owner.window,
   clientKey:randomUUID(),shopId:f.shopId,base:{shopRevision:revision,authorityEpoch:1}});
 const read=async()=>ok(await call(f.owner,endpoint));
 const quantity=n=>({amount:{numerator:n,denominator:1},unit:'gram',originalLiteral:n+' g'});
 assert.equal((await call(f.owner,endpoint)).status,409);
 ok(await send('shop.reportPlaced',{occurredAt:new Date().toISOString()},2));
 assert.equal((await call(f.planner,endpoint)).status,404);
 const sourceId=ok(await send('delivery.register',{supplyRevision:0,placedRevision:2,lineId:f.initial.lines[0].lineId,
   segmentKey:randomUUID(),foodName:'Cannellini beans',exclusionTags:[]})).sourceId;
 ok(await send('delivery.match',{supplyRevision:1,sourceId,occurrenceId:f.proposal.occurrenceId,mealRevision:2,
   ingredientId:f.meal.planning.ingredients[0].id,matched:true}));
 const arrival=randomUUID(),usable=randomUUID();
 ok(await send('delivery.arrival',{sourceId,supplyRevision:2,observationId:arrival,predecessorId:null,
   arrivedAt:new Date(Date.now()-10000).toISOString(),received:quantity(600)}));
 assert.ok((await read()).needs.every(n=>n.covered.numerator==='0' && n.issues.includes('unconfirmed')));
 const review={sourceId,supplyRevision:3,observationId:usable,predecessorId:null,arrivalObservationId:arrival,
   confirmedAt:new Date().toISOString(),usable:quantity(500)};
 ok(await send('delivery.usable',review));
 const first=await read();
 assert.deepEqual(first.needs.map(n=>[n.protected,n.covered.numerator,n.missing.numerator]),[[false,'300','100'],[true,'200','0']]);
 ok(await send('delivery.usable',{...review,supplyRevision:4,observationId:randomUUID(),predecessorId:usable,usable:quantity(150)}));
 const corrected=await read();assert.equal(corrected.shopRevision,first.shopRevision);assert.equal(corrected.supplyRevision,5);
 assert.deepEqual(corrected.needs.map(n=>[n.covered.numerator,n.missing.numerator]),[['0','400'],['150','50']]);
 assert.equal(corrected.needs[1].allocations[0].sourceId,sourceId);
});

test('a shopper can record completed prep and zero lead time without removing a protected group’s meal-wide restrictions',async()=>{
 const f=await mealFixture(),occurrenceId=f.proposal.occurrenceId;
 const meal=structuredClone(f.meal);
 Object.assign(meal.planning,{exclusions:['No nuts','sin sésamo'],leadTimeMinutes:0,completedSteps:['Beans soaked','Tortillas counted']});
 ok(await call(f.owner,f.base+'/commands','POST',f.patch(2,{occurrenceId,baseMealRevision:2,meal})));
 const reduced=structuredClone(meal);reduced.planning.exclusions.pop();
 const proposal={...f.proposal,meal:reduced,baseMealRevision:3,shopRevision:3};
 const direct=f.patch(3,{occurrenceId,baseMealRevision:3,meal:reduced});
 assert.equal((await call(f.planner,f.changePath,'POST',proposal)).data.error.code,'protected_meal');
 assert.equal((await call(f.owner,f.base+'/commands','POST',direct)).data.error.code,'protected_meal');
 const protectedMeal=ok(await call(f.owner,f.path)).meals[0].meal;
 assert.deepEqual(protectedMeal,meal);
});

async function reservationFixture({excluded=false,split=true,rival=false,day,rivalDay}={}) {
 const f=await mealFixture(),commands=f.base+'/commands',path=f.path+'/delivery-evidence';
 const quantity=n=>({amount:{numerator:n,denominator:1},unit:'count',originalLiteral:String(n)});
 const meal=structuredClone(f.meal),[plates,lunch]=meal.planning.groups,ingredient=meal.planning.ingredients[0];
 if(day) meal.day=day;
 ingredient.quantity=quantity(6);
 if(split) meal.planning.bindings.forEach((b,i)=>b.quantity=quantity(i===0?4:2));
 else delete meal.planning.bindings;
 const occurrenceId=randomUUID();
 ok(await call(f.owner,commands,'POST',f.patch(2,{occurrenceId,baseMealRevision:null,meal})));
 const snapshot={shopRevision:3,authorityEpoch:1};
 const rivalOccurrence=randomUUID();
 if(rival){
   const other=structuredClone(meal);
   if(rivalDay) other.day=rivalDay;
   other.title='Another supper';other.planning.groups=[plates];other.planning.ingredients[0].groupIds=[plates.id];
   other.planning.ingredients[0].quantity=quantity(4);delete other.planning.bindings;
   ok(await call(f.owner,commands,'POST',f.patch(3,{occurrenceId:rivalOccurrence,baseMealRevision:null,meal:other})));
   snapshot.shopRevision++;
 }
 function command(kind,body,actor=f.owner) {
   return {v:1,replayWindow:actor.window,clientKey:randomUUID(),shopId:f.shopId,kind,body,base:{...snapshot}};
 }
 const send=(cmd,actor=f.owner)=>call(actor,commands,'POST',cmd);
 const write=(kind,body,actor=f.owner)=>send(command(kind,body,actor),actor);
 const target={occurrenceId,mealRevision:3,ingredientId:ingredient.id};
 const invalidSet={supplyRevision:0,sourceId:randomUUID(),...target,groupId:lunch.id,quantity:quantity(1),predecessorId:null};
 ok(await write('shop.freeze',{}));snapshot.shopRevision++;
 assert.equal((await write('delivery.reserve',invalidSet)).data.error.code,'placed_order_required');
 ok(await write('shop.reportPlaced',{occurredAt:new Date().toISOString()}));snapshot.shopRevision++;
 const delivery=async()=>ok(await call(f.owner,path));
 const coverage=async()=>{
   const page=ok(await call(f.owner,path+'/coverage'));
   return {...page,needs:page.needs.filter(n=>n.occurrenceId===occurrenceId)};
 };
 const sourceId=ok(await write('delivery.register',{supplyRevision:0,placedRevision:snapshot.shopRevision-1,lineId:f.initial.lines[0].lineId,
   segmentKey:randomUUID(),foodName:'Wraps',exclusionTags:excluded?['sesame']:[]})).sourceId;
 const match={sourceId,...target,matched:true};
 ok(await write('delivery.match',{...match,supplyRevision:1}));
 const reservation={sourceId,...target,groupId:lunch.id,quantity:quantity(2),predecessorId:null};
 assert.equal((await write('delivery.reserve',{...reservation,supplyRevision:2})).data.error.code,'reservation_review_required');
 const arrival=randomUUID();
 ok(await write('delivery.arrival',{sourceId,supplyRevision:2,observationId:arrival,predecessorId:null,
   arrivedAt:new Date(Date.now()-1000).toISOString(),received:quantity(6)}));
 const usable={sourceId,supplyRevision:3,observationId:randomUUID(),predecessorId:null,arrivalObservationId:arrival,
   confirmedAt:new Date().toISOString(),usable:quantity(5)};
 ok(await write('delivery.usable',usable));
 return {...f,command,write,send,delivery,coverage,sourceId,reservation,quantity,match,usable,plates,lunch,snapshot,rivalOccurrence};
}

test('durable named reservations bind exact group, predecessor and authority through corrections and release',async()=>{
 const f=await reservationFixture(),r={...f.reservation,supplyRevision:4};
 assert.equal((await f.delivery()).reservationsAvailable,true);
 const set=f.command('delivery.reserve',r);
 assert.equal((await f.write('delivery.reserve',r,f.planner)).status,404);
 for(const bad of [{groupId:randomUUID()},{occurrenceId:randomUUID()},{ingredientId:randomUUID()},
   {quantity:{...r.quantity,unit:'gram'}},{quantity:f.quantity(3)}]){
   assert.equal((await f.write('delivery.reserve',{...r,...bad})).status,409);
 }
 assert.equal((await f.write('delivery.reserve',{...r,quantity:f.quantity(0)})).status,422);
 // An ordinary set-aside cannot consume the two portions that the protected lunch can use.
 assert.equal((await f.write('delivery.reserve',{...r,groupId:f.plates.id,quantity:f.quantity(4)})).status,409);
 const race=await Promise.all([f.send(set),f.send(set)]);
 const saved=ok(race[0]);assert.deepEqual(ok(race[1]),saved);
 assert.equal((await f.delivery()).supplyRevision,5);
 const pinId=saved.operationId,source=(await f.delivery()).sources[0];
 assert.deepEqual(source.reservations,[{groupId:r.groupId,ingredientId:r.ingredientId,mealRevision:r.mealRevision,
   occurrenceId:r.occurrenceId,reservationId:pinId,quantity:r.quantity}]);
 const readRows=async()=> (await f.coverage()).needs;
 const [plates,lunch]=await readRows();
 assert.equal(plates.covered.numerator,'3');assert.equal(plates.missing.numerator,'1');
 assert.deepEqual(lunch.reservations,[{sourceId:r.sourceId,reservationId:pinId,
   requested:{numerator:'2',denominator:'1'},backed:{numerator:'2',denominator:'1'}}]);
 assert.equal((await f.write('delivery.match',{...f.match,matched:false,supplyRevision:5})).data.error.code,'reservation_review_required');
 assert.equal((await f.send({...set,body:{...r,quantity:f.quantity(1)}})).data.error.code,'key_reused');
 assert.equal((await f.write('delivery.reserve',{...r,supplyRevision:5,quantity:f.quantity(1)})).data.error.code,'stale_supply');
 const ordinary={...r,supplyRevision:5,groupId:f.plates.id,quantity:f.quantity(3)};
 const contender=await Promise.all([f.write('delivery.reserve',ordinary),f.write('delivery.reserve',ordinary)]);
 assert.deepEqual(contender.map(v=>v.status).sort(),[200,409]);
 const ordinaryId=ok(contender.find(v=>v.status===200)).operationId;
 ok(await f.write('delivery.usable',{...f.usable,supplyRevision:6,predecessorId:f.usable.observationId,
   observationId:randomUUID(),usable:f.quantity(1)}));
 const [shortPlates,shortLunch]=await readRows();
 assert.equal(shortPlates.reservations[0].backed.numerator,'0');
 assert.equal(shortLunch.reservations[0].backed.numerator,'1');
 assert.ok(shortPlates.issues.includes('reservationShortfall') && shortLunch.issues.includes('reservationShortfall'));
 const release=(pin,groupId,supplyRevision)=>f.write('delivery.reserve',{...r,groupId,predecessorId:pin,supplyRevision,quantity:null});
 const fewer=ok(await f.write('delivery.reserve',{...ordinary,supplyRevision:7,predecessorId:ordinaryId,quantity:f.quantity(2)}));
 const [stillShort]=await readRows();
 assert.equal(stillShort.reservations[0].requested.numerator,'2');assert.equal(stillShort.reservations[0].backed.numerator,'0');
 assert.equal((await f.write('delivery.reserve',{...ordinary,supplyRevision:8,predecessorId:fewer.operationId})).status,409);
 const earlier=(await f.delivery()).sources[0].usable;
 const unknown=ok(await f.write('delivery.usable',{...earlier,supplyRevision:8,predecessorId:earlier.observationId,observationId:randomUUID(),usable:null}));
 assert.equal(unknown.supplyRevision,9);
 const update=ok(await f.write('delivery.reserve',{...r,supplyRevision:9,predecessorId:pinId,quantity:f.quantity(1)}));
 ok(await release(fewer.operationId,f.plates.id,10));
 const released=ok(await release(update.operationId,f.lunch.id,11));
 ok(await f.write('delivery.match',{...f.match,matched:false,supplyRevision:12}));
 assert.deepEqual((await readRows()).map(n=>n.reservations),[[],[]]);
 assert.equal((await f.delivery()).sources[0].reservations.find(p=>p.groupId===f.lunch.id).reservationId,released.operationId);
 assert.equal((await f.write('delivery.reserve',{...r,supplyRevision:13,predecessorId:released.operationId})).status,409);
 ok(await f.write('delivery.match',{...f.match,supplyRevision:13}));
 const unconfirmed=(await f.delivery()).sources[0].usable;
 ok(await f.write('delivery.usable',{...unconfirmed,supplyRevision:14,predecessorId:unconfirmed.observationId,observationId:randomUUID(),usable:f.quantity(1)}));
 ok(await f.write('delivery.reserve',{...r,supplyRevision:15,predecessorId:released.operationId,quantity:f.quantity(1)}));
 await admin.query("UPDATE ritc.shop SET phase='closed' WHERE household_id=$1 AND shop_id=$2",[f.h,f.shopId]);
 assert.equal((await f.coverage()).needs[1].reservations[0].backed.numerator,'1');
 assert.equal((await f.write('delivery.reserve',{...r,supplyRevision:13})).data.error.code,'placed_order_required');
});

test('durable named reservations reject excluded food and ambiguous group splits',async()=>{
 for(const settings of [{excluded:true},{split:false}]) {
   const f=await reservationFixture(settings);
   const result=await f.write('delivery.reserve',{...f.reservation,supplyRevision:4});
   assert.equal(result.data.error.code,'reservation_review_required');
   assert.deepEqual((await f.delivery()).sources[0].reservations,[]);assert.equal((await f.delivery()).supplyRevision,4);
 }
});

test('durable named reservations on two lots respect competing sealed meals and protected priority after a correction',async()=>{
 const f=await reservationFixture({rival:true}),key={occurrenceId:f.rivalOccurrence,mealRevision:4,ingredientId:f.match.ingredientId};
 const src=ok(await f.write('delivery.register',{supplyRevision:4,placedRevision:5,lineId:f.initial.lines[0].lineId,
   segmentKey:randomUUID(),foodName:'Additional wraps',exclusionTags:[]})).sourceId;
 ok(await f.write('delivery.match',{...f.match,sourceId:src,supplyRevision:5}));
 ok(await f.write('delivery.match',{...f.match,...key,supplyRevision:6}));
 const arrival=randomUUID(),usable=randomUUID();
 ok(await f.write('delivery.arrival',{sourceId:src,supplyRevision:7,observationId:arrival,predecessorId:null,
   arrivedAt:new Date(Date.now()-1000).toISOString(),received:f.quantity(2)}));
 ok(await f.write('delivery.usable',{sourceId:src,supplyRevision:8,observationId:usable,predecessorId:null,
   arrivalObservationId:arrival,confirmedAt:new Date().toISOString(),usable:f.quantity(2)}));
 const rival={...f.reservation,...key,groupId:f.plates.id,supplyRevision:9,quantity:f.quantity(4)};
 ok(await f.write('delivery.reserve',rival));
 assert.equal((await f.write('delivery.reserve',{...f.reservation,supplyRevision:10})).status,409);
 ok(await f.write('delivery.reserve',{...f.reservation,sourceId:src,supplyRevision:10}));
 const read=async()=>ok(await call(f.owner,f.path+'/delivery-evidence/coverage')).needs;
 const current=await read();
 assert.equal(current.find(n=>n.occurrenceId===key.occurrenceId).reservations[0].backed.numerator,'4');
 assert.equal(current.find(n=>n.occurrenceId===f.match.occurrenceId && n.protected).reservations[0].backed.numerator,'2');
 ok(await f.write('delivery.usable',{sourceId:src,supplyRevision:11,observationId:randomUUID(),predecessorId:usable,
   arrivalObservationId:arrival,confirmedAt:new Date().toISOString(),usable:f.quantity(0)}));
 const corrected=await read(),lunch=corrected.find(n=>n.occurrenceId===f.match.occurrenceId && n.protected);
 assert.equal(lunch.covered.numerator,'2');assert.equal(lunch.reservations[0].backed.numerator,'0');
 const other=corrected.find(n=>n.occurrenceId===key.occurrenceId);
 assert.equal(other.covered.numerator,'3');assert.equal(other.reservations[0].backed.numerator,'3');
 assert.ok(other.issues.includes('reservationShortfall') && lunch.issues.includes('reservationShortfall'));
 assert.equal(corrected.flatMap(n=>n.allocations).reduce((total,a)=>total+BigInt(a.amount.numerator),0n),5n);
});

test('reservation erasure removes all revisions involving a former shopper without reviving an older claim',async()=>{
 const f=await reservationFixture(),body={...f.reservation,supplyRevision:4};
 const saved=f.command('delivery.reserve',body),first=ok(await f.send(saved));
 ok(await f.write('shop.transferAuthority',{newShopperId:f.planner.id}));f.snapshot.authorityEpoch++;
 assert.equal((await f.send(saved)).status,404);
 const client=await runtime.connect();
 try {
   await client.query('BEGIN');
   await client.query("SELECT set_config('app.household_id',$1,true)",[randomUUID()]);
   assert.equal((await client.query('SELECT * FROM ritc.delivery_reservation WHERE household_id=$1',[f.h])).rowCount,0);
   await assert.rejects(()=>client.query('DELETE FROM ritc.delivery_reservation'),e=>e.code==='42501');
 } finally {await client.query('ROLLBACK');client.release();}
 const correction={...body,supplyRevision:5,quantity:f.quantity(1),predecessorId:first.operationId};
 ok(await f.write('delivery.reserve',correction,f.planner));
 ok(await f.write('shop.transferAuthority',{newShopperId:f.owner.id}));f.snapshot.authorityEpoch++;
 assert.equal((await f.delivery()).sources[0].reservations[0].quantity.amount.numerator,1);
 await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.planner.id]);
 const page=await f.delivery();
 assert.equal(page.supplyRevision,7);assert.deepEqual(page.sources[0].reservations,[]);
 assert.equal(page.sources[0].sourceId,f.sourceId);assert.equal(page.sources[0].matches.length,1);
 assert.deepEqual((await f.coverage()).needs.map(n=>n.reservations),[[],[]]);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.delivery_reservation WHERE household_id=$1',[f.h])).rows[0].n,0);
 assert.equal((await f.send(saved)).status,409);
});

test('dated cook copies keep exact sealed text; only an explicit recipient send advances its baseline',async()=>{
 const f=await mealFixture(), occurrenceId=f.proposal.occurrenceId;
 const command=(kind,body,base={shopRevision:3,authorityEpoch:1})=>({v:1,kind,body,base,clientKey:randomUUID(),shopId:f.shopId,replayWindow:f.owner.window});
 const write=(c,actor=f.owner)=>call(actor,f.base+'/commands','POST',c);
 const history=(actor=f.owner,cursor=null)=>call(actor,f.path+'/cook-copies?occurrenceId='+occurrenceId+(cursor?'&cursor='+cursor:''));
 const baseline=(recipient,actor=f.owner)=>call(actor,f.path+'/cook-copies/baseline','POST',{occurrenceId,recipient});
 const make=(text,language='en',supplyRevision=0)=>command('cookCopy.save',{placedRevision:2,supplyRevision,occurrenceId,mealRevision:2,language,text});
 const mark=(copyId,recipient,previousSendId)=>command('cookCopy.markSent',{copyId,recipient,previousSendId});
 const copy=make('  Wraps — ½ cup\nSave two.  ');
 assert.equal((await history()).status,409);
 ok(await write(command('shop.reportPlaced',{occurredAt:new Date().toISOString()},{shopRevision:2,authorityEpoch:1})));
 assert.ok(ok(await call(f.owner,f.base+'/bootstrap')).capabilities.includes('cook_copies'));
 const saved=ok(await write(copy));
 assert.equal(saved.copyId,saved.operationId);
 assert.equal(saved.disposition,'recorded');
 assert.deepEqual(ok(await write(copy)),saved);
 assert.equal((await write({...copy,body:{...copy.body,text:copy.body.text.trim()}})).data.error.code,'key_reused');
 assert.equal((await write({...make('edited'),body:{...copy.body,mealRevision:1}})).status,404);
 assert.equal((await write({...make('edited'),body:{...copy.body,occurrenceId:randomUUID()}})).status,404);
 const old=ok(await history()).copies[0];
 assert.deepEqual(old,{copyId:saved.copyId,shopId:f.shopId,occurrenceId,mealRevision:2,version:1,language:'en',text:copy.body.text,
   placedRevision:2,shopRevision:3,authorityEpoch:1,supplyRevision:0,createdAt:old.createdAt});
 assert.ok(Number.isFinite(Date.parse(old.createdAt)));assert.deepEqual(ok(await baseline('Ana')),{baseline:null});
 assert.equal((await history(f.planner)).status,404);assert.equal((await baseline('Ana',f.planner)).status,404);
 assert.equal((await write({...copy,replayWindow:f.planner.window},f.planner)).status,404);
 ok(await write(command('delivery.register',{supplyRevision:0,placedRevision:2,lineId:f.initial.lines[0].lineId,segmentKey:randomUUID(),foodName:'Wraps',exclusionTags:[]})));
 assert.equal((await write(make('Stale correction'))).data.error.code,'stale_supply');
 const updated=ok(await write(make('Guardar dos porciones.','es',1)));
 assert.deepEqual(ok(await baseline('Ana')),{baseline:null});
 const first=mark(old.copyId,' Ana ',null), sent=ok(await write(first));
 assert.deepEqual(ok(await write(first)),sent);
 assert.equal(sent.copyId,old.copyId);assert.notEqual(sent.operationId,sent.copyId);
 let last=ok(await baseline('Ana')).baseline;
 assert.deepEqual(last.copy,old);assert.deepEqual(last.send,{sendId:sent.operationId,copyId:old.copyId,recipient:'Ana',sentAt:last.send.sentAt});
 assert.ok(Number.isFinite(Date.parse(last.send.sentAt)));assert.deepEqual(ok(await baseline('Ben')),{baseline:null});
 assert.equal((await write(mark(updated.copyId,'Ana',null))).data.error.code,'stale_base');
 const contenders=[mark(updated.copyId,'Ana',sent.operationId),mark(updated.copyId,'Ana',sent.operationId)];
 const competing=await Promise.all(contenders.map(c=>write(c)));
 assert.deepEqual(competing.map(r=>r.status).sort(),[200,409]);
 last=ok(await baseline('Ana')).baseline;
 assert.equal(last.copy.version,2);assert.equal(last.copy.language,'es');assert.equal(last.copy.text,'Guardar dos porciones.');
 assert.equal(last.send.sendId,competing.find(r=>r.status===200).data.operationId);
 assert.deepEqual(ok(await write(first)),sent);assert.equal(ok(await baseline('Ana')).baseline.copy.copyId,updated.copyId);
 ok(await write(mark(old.copyId,'Ben',null)));assert.equal(ok(await baseline('Ben')).baseline.copy.copyId,old.copyId);
 assert.deepEqual(ok(await history()).copies.map(c=>c.copyId),[updated.copyId,old.copyId]);
 // Household membership and service receipt retention do not own a historical copy.
 await admin.query('DELETE FROM ritc.billing_seat WHERE household_id=$1',[f.h]);
 await admin.query('DELETE FROM ritc.operation_response WHERE household_id=$1 AND operation_id=$2',[f.h,saved.operationId]);
 assert.equal((await write(copy)).status,409);
 assert.deepEqual(ok(await baseline('Ben')).baseline.copy,old);
 for(let version=3;version<=22;version++) ok(await write(make('Reviewed version '+version,'en',1)));
 const page=ok(await history());assert.equal(page.copies.length,20);
 assert.equal(page.nextCursor,page.copies[19].copyId);
 const tail=ok(await history(f.owner,page.nextCursor));assert.deepEqual(tail.copies.map(c=>c.version),[2,1]);assert.equal(tail.nextCursor,null);
 assert.equal((await history(f.owner,randomUUID())).status,404);
 assert.equal((await write(make('   ','en',1))).status,422);
 // Shopper authority is rechecked for reads, new sends and exact retries.
 ok(await write(command('shop.transferAuthority',{newShopperId:f.planner.id})));
 assert.equal((await history()).status,404);assert.equal((await write(first)).status,404);
 assert.equal(ok(await baseline('Ben',f.planner)).baseline.copy.copyId,old.copyId);
 const wrongEpoch={...mark(old.copyId,'Fran',null),replayWindow:f.planner.window};
 assert.equal((await write(wrongEpoch,f.planner)).status,409);
 const newHead={...mark(updated.copyId,'Ben',ok(await baseline('Ben',f.planner)).baseline.send.sendId),
   replayWindow:f.planner.window,base:{shopRevision:3,authorityEpoch:2}};
 ok(await write(newHead,f.planner));assert.equal(ok(await baseline('Ben',f.planner)).baseline.copy.copyId,updated.copyId);
 const formerCopy={...make('Later private wording','en',1),replayWindow:f.planner.window,base:{shopRevision:3,authorityEpoch:2}};
 ok(await write(formerCopy,f.planner));assert.equal(ok(await history(f.planner)).copies[0].version,23);
 await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.planner.id]);
 assert.equal(ok(await baseline('Ben',f.planner)).baseline,null); // No resurrection of the earlier head.
 assert.equal(ok(await baseline('Ana',f.planner)).baseline.copy.copyId,updated.copyId);
 assert.equal((await write(newHead,f.planner)).status,409);
 assert.equal((await write(formerCopy,f.planner)).status,409);
 assert.equal(ok(await history(f.planner)).copies[0].version,22);
 ok(await write(command('shop.transferAuthority',{newShopperId:f.owner.id},{shopRevision:3,authorityEpoch:2})));
 ok(await write({...make('Next reviewed copy','es',1),base:{shopRevision:3,authorityEpoch:3}}));
 assert.deepEqual(ok(await history()).copies.slice(0,2).map(c=>c.version),[24,22]);
});

function pantryHarness(f,shopId=f.shopId,base=f.snapshot) {
 const path=f.base+'/shops/'+shopId+'/pantry-lots',time=new Date(Date.now()-1000).toISOString();
 const stock=async()=>ok(await call(f.owner,path));
 const joint=async()=>ok(await call(f.owner,path+'/coverage'));
 const scope=async()=>{const {pantryRevision,supplyRevision}=await stock();return {pantryRevision,supplyRevision};};
 const envelope=(kind,body)=>({...f.command(kind,body),shopId,base:{...base}});
 const send=cmd=>f.send(cmd);
 const edit=async(kind,body)=>ok(await send(envelope(kind,{...await scope(),...body})));
 const preview=async(lotId,quantity)=>{
   const page=await stock(),lot=page.lots.find(l=>l.lotId===lotId);
   const row={pantryRevision:page.pantryRevision,supplyRevision:page.supplyRevision,lotId,quantity,confirmedAt:time,predecessorId:lot.observation?.observationId??null};
   const result=ok(await call(f.owner,path+'/observation-preview','POST',row));
   return {result,cmd:envelope('pantry.observe',{...row,previewDigest:result.previewDigest})};
 };
 const create=(name,tags=[])=>edit('pantry.create',{location:'freezer',storedAt:null,useFirstAt:time,foodName:name,exclusionTags:tags});
 const match={occurrenceId:f.match.occurrenceId,mealRevision:f.match.mealRevision,ingredientId:f.match.ingredientId};
 return {stock,joint,scope,envelope,send,edit,preview,create,match,time,path};
}

test('shared pantry allocates one freezer count and delivery together, previews correction and preserves explicit cook seal',async()=>{
 const f=await reservationFixture(),p=pantryHarness(f),q=f.quantity;
 ok(await f.write('delivery.match',{...f.match,supplyRevision:4,matched:false}));
 const {lotId}=await p.create('Freezer wraps');
 assert.deepEqual((await p.stock()).lots[0],{lotId,origin:'manual',location:'freezer',storedAt:null,useFirstAt:p.time,foodName:'Freezer wraps',
   exclusionTags:[],selected:false,observation:null,matches:[],reservations:[]});
 await p.edit('pantry.select',{lotId,selected:true});
 await p.edit('pantry.match',{lotId,...p.match,matched:true});
 const rows=async()=>(await p.joint()).needs.filter(n=>n.occurrenceId===p.match.occurrenceId);
 assert((await rows()).every(n=>n.issues.includes('unconfirmed')));
 const first=await p.preview(lotId,q(5));assert.equal(first.result.needs.length,2);
 assert.equal((await p.stock()).lots[0].observation,null);
 const poisoned=structuredClone(first.cmd);poisoned.body.quantity=q(6);
 assert.equal((await p.send(poisoned)).data.error.code,'stale_supply');
 const confirmed=ok(await p.send(first.cmd));assert.deepEqual(ok(await p.send(first.cmd)),confirmed);
 const reserved=await p.edit('pantry.reserve',{lotId,...p.match,groupId:f.lunch.id,predecessorId:null,quantity:q(2)});
 const [dinner,lunch]=await rows(),num=v=>v.numerator;
 assert.deepEqual([dinner.freezer,lunch.freezer,dinner.missing,lunch.missing].map(num),['3','2','1','0']);
 assert.equal(lunch.reservations[0].reservationId,reserved.operationId);
 assert.deepEqual((await f.coverage()).needs.map(n=>n.covered.numerator),['0','0']);
 assert.equal((await p.stock()).lots[0].observation.observationId,confirmed.operationId);
 const old=await p.scope();
 ok(await f.write('delivery.usable',{...f.usable,supplyRevision:5,observationId:randomUUID(),predecessorId:f.usable.observationId,usable:q(1)}));
 ok(await f.write('delivery.match',{...f.match,supplyRevision:6}));
 const both=await rows();assert.deepEqual(both.map(n=>n.missing.numerator),['0','0']);
 assert.equal(both[0].delivered.numerator,'1');assert.equal(both[0].freezer.numerator,'3');
 assert.deepEqual(both[0].allocations.map(a=>a.kind).sort(),['delivery','freezer']);
 assert.equal((await f.coverage()).needs.find(n=>n.protected).covered.numerator,'1');
 const copy={placedRevision:(await f.delivery()).placedRevision,supplyRevision:7,pantryRevision:old.pantryRevision,
   occurrenceId:p.match.occurrenceId,mealRevision:p.match.mealRevision,language:'en',text:'Keep two lunches.'};
 assert.equal((await f.write('cookCopy.save',copy)).data.error.code,'stale_supply');
 const fresh=await p.scope();ok(await f.write('cookCopy.save',{...copy,...fresh}));
 const hist=ok(await call(f.owner,f.path+'/cook-copies?occurrenceId='+p.match.occurrenceId));
 assert.equal(hist.copies[0].pantryRevision,fresh.pantryRevision);
 for(const quantity of [q(0),null]){
   const next=await p.preview(lotId,quantity);assert.equal(next.result.needs.length,2);
   ok(await p.send(next.cmd));const current=await rows();assert.equal(current[1].reservations[0].backed.numerator,'0');
   assert(current[1].issues.includes('reservationShortfall'));assert.equal(current[1].issues.includes('unconfirmed'),quantity===null);
 }
 const shrink=await p.edit('pantry.reserve',{lotId,...p.match,groupId:f.lunch.id,predecessorId:reserved.operationId,quantity:q(1)});
 await p.edit('pantry.reserve',{lotId,...p.match,groupId:f.lunch.id,predecessorId:shrink.operationId,quantity:null});
 const wrong=await call(f.planner,p.path);assert.equal(wrong.status,404);
 assert.equal((await call(f.planner,p.path+'/coverage')).status,404);
 ok(await f.write('shop.transferAuthority',{newShopperId:f.planner.id}));assert.equal((await p.send(first.cmd)).status,404);
});

test('stored delivery retains one physical count across two shops and protects other commitments during carryover',async()=>{
 const f=await reservationFixture(),p=pantryHarness(f),q=f.quantity;
 const alias=await p.edit('pantry.storeDelivery',{sourceId:f.sourceId,location:'freezer',storedAt:p.time,useFirstAt:null});
 assert.equal(alias.lotId,f.sourceId);assert.equal((await p.stock()).lots[0].observation.quantity.amount.numerator,5);
 await p.edit('pantry.select',{lotId:alias.lotId,selected:true});
 const duplicate=p.envelope('pantry.match',{...await p.scope(),lotId:alias.lotId,...p.match,matched:true});
 assert.equal((await p.send(duplicate)).data.error.code,'reservation_review_required');
 // Create a second, independent sealed shop; reuse the same client occurrence/ingredient UUIDs deliberately.
 const otherShop=await f.shop(),otherBase={shopRevision:1,authorityEpoch:1},other=pantryHarness(f,otherShop,otherBase);
 const initial=ok(await call(f.owner,f.base+'/shops/'+otherShop)),meal=structuredClone(f.meal);
 meal.planning.groups=[f.plates];meal.planning.ingredients[0].groupIds=[f.plates.id];meal.planning.ingredients[0].quantity=q(4);delete meal.planning.bindings;
 ok(await f.send(other.envelope('shop.patch',{quote:initial.quote,lines:initial.lines,mealEdit:{occurrenceId:p.match.occurrenceId,baseMealRevision:null,meal}})));
 otherBase.shopRevision++;
 ok(await f.send(other.envelope('shop.reportPlaced',{occurredAt:p.time})));otherBase.shopRevision++;
 const m={...p.match,mealRevision:2};
 assert.equal((await other.stock()).lots[0].selected,false);assert.deepEqual((await other.stock()).lots[0].matches,[]);
 await other.edit('pantry.select',{lotId:f.sourceId,selected:true});await other.edit('pantry.match',{lotId:f.sourceId,...m,matched:true});
 assert.equal((await other.joint()).needs[0].covered.numerator,'0');
 assert.equal((await other.send(other.envelope('pantry.reserve',{...await other.scope(),lotId:f.sourceId,...m,groupId:f.plates.id,quantity:q(1),predecessorId:null}))).data.error.code,'reservation_review_required');
 // Give one unit of physical surplus by correcting origin usable to six and raising received to seven.
 const arrival=randomUUID();
 ok(await f.write('delivery.arrival',{sourceId:f.sourceId,supplyRevision:4,observationId:arrival,predecessorId:f.usable.arrivalObservationId,arrivedAt:p.time,received:q(7)}));
 assert.equal((await other.stock()).lots[0].observation.quantity,null);
 ok(await f.write('delivery.usable',{...f.usable,supplyRevision:5,observationId:randomUUID(),predecessorId:f.usable.observationId,arrivalObservationId:arrival,usable:q(7)}));
 const one=(await other.joint()).needs[0];assert.deepEqual([one.covered.numerator,one.freezer.numerator,one.missing.numerator],['1','1','3']);
 assert.equal((await other.stock()).lots[0].observation.quantity.amount.numerator,7);
 assert((await p.joint()).needs.filter(n=>n.occurrenceId===p.match.occurrenceId).every(n=>n.missing.numerator==='0'));
 const pin=await other.edit('pantry.reserve',{lotId:f.sourceId,...m,groupId:f.plates.id,quantity:q(1),predecessorId:null});
 assert.equal((await other.joint()).needs[0].reservations[0].reservationId,pin.operationId);
 assert.equal((await p.stock()).lots[0].reservations.length,0);
 const manual=(await p.create('Shared wraps')).lotId;
 await other.edit('pantry.select',{lotId:manual,selected:true});await other.edit('pantry.match',{lotId:manual,...m,matched:true});
 const correction=await p.preview(manual,q(2));
 assert.equal(correction.result.otherShopsAffected,true);assert.deepEqual(correction.result.needs,[]);
 assert(!JSON.stringify(correction.result).includes(otherShop));
 ok(await p.send(correction.cmd));assert.equal((await other.joint()).needs[0].missing.numerator,'1');
 const excluded=(await p.create('Sesame wraps',['sesame'])).lotId;
 await p.edit('pantry.select',{lotId:excluded,selected:true});await p.edit('pantry.match',{lotId:excluded,...p.match,matched:true});
 const e=await p.preview(excluded,q(30));ok(await p.send(e.cmd));
 const excludedNeeds=(await p.joint()).needs.filter(n=>n.occurrenceId===p.match.occurrenceId);
 assert(excludedNeeds.every(n=>n.issues.includes('exclusion') && !n.allocations.some(a=>a.sourceId===excluded)));
});

test('shared pantry corrections serialize competing reviews, reject stale predecessors and isolate household reads',async()=>{
 const f=await reservationFixture(),p=pantryHarness(f),{lotId}=await p.create('Private count'),q=f.quantity;
 const [a,b]=await Promise.all([p.preview(lotId,q(4)),p.preview(lotId,q(6))]);
 const result=await Promise.all([p.send(a.cmd),p.send(b.cmd)]);
 assert.deepEqual(result.map(r=>r.status).sort(),[200,409]);
 const i=result.findIndex(r=>r.status===200),winner=i===0?a:b,loser=i===0?b:a;
 assert.equal(result[1-i].data.error.code,'stale_supply');
 assert.deepEqual(ok(await p.send(winner.cmd)),ok(result[i]));
 const page=await p.stock();assert.equal(page.lots[0].observation.observationId,result[i].data.operationId);
 assert.equal(page.pantryRevision,winner.cmd.body.pantryRevision+1);
 const {previewDigest,...stale}=loser.cmd.body;
 assert.equal((await call(f.owner,p.path+'/observation-preview','POST',{...stale,...await p.scope()})).data.error.code,'stale_supply');
 assert.equal((await call(f.planner,p.path+'/observation-preview','POST',stale)).status,404);
 const db=await runtime.connect();
 try{
   await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[randomUUID()]);
   for(const table of ['pantry_lot','pantry_event']) assert.equal((await db.query('SELECT 1 FROM ritc.'+table+' WHERE household_id=$1',[f.h])).rowCount,0);
   await assert.rejects(db.query('DELETE FROM ritc.pantry_event'),e=>e.code==='42501');
 }finally{await db.query('ROLLBACK');db.release();}
});

const emptyRecoveryPublication=()=>({recoveryRevision:0,contextRevision:0,meals:[],usedNeedIds:[],usedRevisionIds:[]});
async function realRecoveryRead(f,shopId=f.shopId,publications=new Map(),actor=f.owner) {
 const {loadSharedRecoveryBasis,readSharedRecoveryContext,readSharedRecoveryCoverage}=await import('../dist/shared-recovery-basis.js');
 const {projectRecovery}=await import('../dist/recovery-domain.js');
 return repo.transaction(f.h,async(db,now)=>{
   const member=await repo.member(db,f.h,{issuer,subject:actor.subject}),ctx={db,now,householdId:f.h,member,selectedShopId:shopId};
   const shop=await repo.shop(ctx,shopId),load=async(_,id)=>publications.get(id)??emptyRecoveryPublication();
   const basis=await loadSharedRecoveryBasis(ctx,shop,load);
   return {basis,projection:projectRecovery(basis,now.toISOString()),context:await readSharedRecoveryContext(ctx,shop,load),coverage:await readSharedRecoveryCoverage(ctx,shop,load)};
 });
}

test('trusted recovery basis reads real freezer history, preserves Tuesday and protects two lunch portions on Wednesday',async()=>{
 const f=await reservationFixture({rival:true,rivalDay:'2026-11-03',day:'2026-11-04'}),p=pantryHarness(f),q=f.quantity;
 ok(await f.write('delivery.match',{...f.match,supplyRevision:4,matched:false}));
 const {lotId}=await p.create('Frozen wraps');
 const unused=(await p.create('Unselected private batch')).lotId;
 await p.edit('pantry.select',{lotId,selected:true});
 await p.edit('pantry.match',{lotId,...p.match,matched:true});
 const first=await p.preview(lotId,q(5));ok(await p.send(first.cmd));
 const reservation=await p.edit('pantry.reserve',{lotId,...p.match,groupId:f.lunch.id,predecessorId:null,quantity:q(2)});
 const before=await realRecoveryRead(f),wed=before.basis.meals.find(m=>m.occurrenceId===p.match.occurrenceId),
   tue=before.basis.meals.find(m=>m.occurrenceId===f.rivalOccurrence);
 assert.equal(wed.day,'2026-11-04');assert.equal(tue.day,'2026-11-03');assert.equal(wed.due,null);assert.equal(wed.zone,null);
 assert.equal(before.basis.arrivals.filter(a=>a.sourceId===lotId).length,0);
 assert.equal(before.basis.pantryObservations.length,1);assert.equal(before.basis.pantryObservations[0].id,(await p.stock()).lots.find(l=>l.lotId===lotId).observation.observationId);
 assert(!before.context.sourceOptions.some(o=>o.sourceId===unused));
 assert.equal(before.context.sourceOptions.find(o=>o.sourceId===lotId).kind,'freezer');
 const [ordinary,protectedLunch]=wed.needs;
 assert.equal(protectedLunch.priority,'protected');assert.deepEqual(before.basis.reservations,[{id:reservation.operationId,sourceId:lotId,needId:protectedLunch.id,quantity:q(2)}]);
 const demands=m=>before.projection.demands.filter(d=>m.needs.some(n=>n.id===d.needId));
 assert.deepEqual(demands(wed).map(d=>[d.allocated.numerator,d.shortfall.numerator]),[['3','1'],['2','0']]);
 const {previewRecovery,recoveryDigest}=await import('../dist/recovery-domain.js');
 const next={...wed,title:'Repaired Wednesday',revisionId:randomUUID(),needs:[{...ordinary,id:randomUUID(),quantity:q(3)},protectedLunch]};
 const intent={occurrenceId:wed.occurrenceId,targetDigest:recoveryDigest(wed),replacement:next,reviewedAt:before.context.asOf,repeatOfOccurrenceId:null,
   agreesToRepeat:false,proposesExtraTrip:false,agreesToExtraTrip:false,acceptsUnresolved:true};
 const preview=previewRecovery(before.basis,{v:1,base:before.basis.base,intent},before.context.asOf);
 assert.equal(preview.timingConfirmed,false);assert.equal(preview.consentSatisfied,true);
 assert.deepEqual(preview.after.meals.find(m=>m.occurrenceId===tue.occurrenceId),tue);
 assert.deepEqual(preview.after.demands.filter(d=>tue.needs.some(n=>n.id===d.needId)),demands(tue));
 const published=new Map([[f.shopId,{...emptyRecoveryPublication(),recoveryRevision:1,meals:[next],usedNeedIds:[ordinary.id],usedRevisionIds:[wed.revisionId]}]]);
 const current=await realRecoveryRead(f,f.shopId,published);
 assert.equal(current.context.meals.find(m=>m.occurrenceId===wed.occurrenceId).title,next.title);
 assert.deepEqual(current.coverage.needs.filter(n=>n.occurrenceId===wed.occurrenceId).map(n=>n.missing.numerator),['0','0']);
 assert.equal((await f.delivery()).meals.find(m=>m.occurrenceId===wed.occurrenceId).meal.title,f.meal.title);
 const edit=await p.preview(lotId,q(1));ok(await p.send(edit.cmd));
 const reduced=await realRecoveryRead(f,f.shopId,published);
 assert.deepEqual(reduced.basis.pantryObservations.map(h=>h.predecessorId),[null,current.basis.pantryObservations[0].id]);
 assert.equal(reduced.coverage.needs.find(n=>n.needId===protectedLunch.id).reservations[0].backed.numerator,'1');
 await assert.rejects(realRecoveryRead(f,f.shopId,published,f.planner),e=>e.status===404);
 const erased=new Map([[f.shopId,{...emptyRecoveryPublication(),recoveryRevision:2,removedOccurrences:[wed.occurrenceId]}]]);
 assert(!(await realRecoveryRead(f,f.shopId,erased)).context.meals.some(m=>m.occurrenceId===wed.occurrenceId));
});

test('trusted recovery basis carries a genuine foreign delivery once and publishes only scoped current needs and stock',async()=>{
 const f=await reservationFixture(),p=pantryHarness(f),q=f.quantity;
 await p.edit('pantry.storeDelivery',{sourceId:f.sourceId,location:'freezer',storedAt:null,useFirstAt:null});
 const otherId=await f.shop(),otherBase={shopRevision:1,authorityEpoch:1},other=pantryHarness(f,otherId,otherBase);
 const initial=ok(await call(f.owner,f.base+'/shops/'+otherId)),meal=structuredClone(f.meal);
 meal.title='Later household dinner';meal.planning.groups=[f.plates];meal.planning.ingredients[0].groupIds=[f.plates.id];
 meal.planning.ingredients[0].quantity=q(4);delete meal.planning.bindings;
 ok(await f.send(other.envelope('shop.patch',{quote:initial.quote,lines:initial.lines,mealEdit:{occurrenceId:p.match.occurrenceId,baseMealRevision:null,meal}})));
 otherBase.shopRevision++;ok(await f.send(other.envelope('shop.reportPlaced',{occurredAt:p.time})));otherBase.shopRevision++;
 assert.deepEqual((await realRecoveryRead(f,otherId)).context.sourceOptions,[]);
 await other.edit('pantry.select',{lotId:f.sourceId,selected:true});
 await other.edit('pantry.match',{lotId:f.sourceId,...p.match,mealRevision:2,matched:true});
 const before=await realRecoveryRead(f,otherId);
 assert.equal(before.basis.sources[0].shopId,f.shopId);assert.equal(before.basis.sources[0].origin.kind,'delivery');
 assert.equal(before.basis.arrivals[0].shopId,f.shopId);assert.equal(before.basis.usable[0].arrivalObservationId,f.usable.arrivalObservationId);
 assert.deepEqual(before.basis.selectedCarrySourceIds,[f.sourceId]);assert.deepEqual(before.basis.carrySupplyRevisions,[{shopId:f.shopId,supplyRevision:4}]);
 assert.deepEqual(before.basis.foreignHolds,[{sourceId:f.sourceId,quantity:{unit:'count',amount:{numerator:'5',denominator:'1'}}}]);
 assert.equal(before.projection.demands[0].shortfall.numerator,'4');
 for(const response of [before.context,before.coverage,before.projection]){
   assert(!JSON.stringify(response).includes(f.shopId));assert(!JSON.stringify(response).includes(f.usable.observationId));
 }
 const old=(await realRecoveryRead(f)).context.meals.find(m=>m.occurrenceId===p.match.occurrenceId);
 const accepted={...old,revisionId:randomUUID(),needs:old.needs.map(n=>n.priority==='protected'?n:{...n,id:randomUUID(),matchedSourceIds:[]})};
 const loaded=new Map([[f.shopId,{...emptyRecoveryPublication(),recoveryRevision:1,meals:[accepted]}]]);
 const after=await realRecoveryRead(f,otherId,loaded);
 assert.equal(after.basis.foreignHolds[0].quantity.amount.numerator,'2');
 assert.equal(after.projection.demands[0].allocated.numerator,'3');
 assert.equal(after.coverage.needs[0].freezer.numerator,'3');
 // Different shops can issue identical client observation UUIDs for independent
 // physical lots. Each usable count must still bind to its actual shop/source.
 const local=ok(await f.send(other.envelope('delivery.register',{supplyRevision:0,placedRevision:2,lineId:initial.lines[0].lineId,
   segmentKey:randomUUID(),foodName:'Separate local wraps',exclusionTags:[]}))).sourceId;
 ok(await f.send(other.envelope('delivery.arrival',{sourceId:local,supplyRevision:1,observationId:f.usable.arrivalObservationId,predecessorId:null,
   arrivedAt:p.time,received:q(1)})));
 ok(await f.send(other.envelope('delivery.usable',{sourceId:local,supplyRevision:2,observationId:f.usable.observationId,predecessorId:null,
   confirmedAt:p.time,arrivalObservationId:f.usable.arrivalObservationId,usable:q(1)})));
 const colliding=await realRecoveryRead(f,otherId,loaded);
 assert.equal(colliding.basis.usable.filter(r=>r.id===f.usable.observationId).length,2);
 assert.equal(colliding.projection.demands[0].allocated.numerator,'3');
 // A deliberately removed selection cannot leak its previous food ID through
 // a retained replacement. The meal stays readable with its shortage open.
 await other.edit('pantry.match',{lotId:f.sourceId,...p.match,mealRevision:2,matched:false});
 await other.edit('pantry.select',{lotId:f.sourceId,selected:false});
 const later=before.context.meals[0],saved={...later,revisionId:randomUUID(),needs:later.needs.map(n=>({...n,id:randomUUID(),foodId:f.sourceId,matchedSourceIds:[f.sourceId]}))};
 loaded.set(otherId,{...emptyRecoveryPublication(),recoveryRevision:1,meals:[saved]});
 const removed=await realRecoveryRead(f,otherId,loaded);
 assert.equal(removed.basis.meals[0].needs[0].foodId,null);assert.deepEqual(removed.basis.meals[0].needs[0].matchedSourceIds,[]);
 assert.equal(removed.projection.demands[0].shortfall.numerator,'4');
});

test('trusted recovery basis guards retired legacy targets and previews the current recipe before recording a correction',async()=>{
 const {recordCurrentDelivery,recordCurrentPantry,previewCurrentPantryObservation,readSharedRecoveryCoverage}=await import('../dist/shared-recovery-basis.js');
 const f=await reservationFixture(),p=pantryHarness(f),q=f.quantity;
 const {lotId}=await p.create('Separate freezer batch');await p.edit('pantry.select',{lotId,selected:true});
 const physical=await p.preview(lotId,q(3));ok(await p.send(physical.cmd));
 const pin=ok(await f.write('delivery.reserve',{...f.reservation,supplyRevision:4}));
 const released=ok(await f.write('delivery.reserve',{...f.reservation,supplyRevision:5,quantity:null,predecessorId:pin.operationId}));
 const original=(await realRecoveryRead(f)).context.meals.find(m=>m.occurrenceId===f.match.occurrenceId),
   changedIngredient=randomUUID(),replacement={...original,revisionId:randomUUID(),needs:original.needs.map(n=>n.priority==='protected'?n:
     {...n,id:randomUUID(),ingredientId:changedIngredient,matchedSourceIds:[lotId],quantity:q(3)})};
 const load=async()=>({...emptyRecoveryPublication(),recoveryRevision:1,meals:[replacement]});
 const next=await p.preview(lotId,q(1)),{previewDigest,...observation}=next.cmd.body;
 const run=fn=>repo.transaction(f.h,async(db,now)=>{
   const member=await repo.member(db,f.h,{issuer,subject:f.owner.subject}),ctx={db,now,householdId:f.h,member,selectedShopId:f.shopId};
   const shop=await repo.shop(ctx,f.shopId);
   // Exercise the command handler and both projections on actual transaction rows.
   // The enclosing repository normally writes a receipt after this hook returns.
   await db.query('SAVEPOINT review_change');
   try{return await fn(ctx,shop);}finally{await db.query('ROLLBACK TO SAVEPOINT review_change');}
 });
 const result=await run((ctx,shop)=>previewCurrentPantryObservation(ctx,shop,observation,load));
 assert.equal(result.needs.length,1);assert.equal(result.needs[0].ingredientId,changedIngredient);
 assert.deepEqual([result.needs[0].beforeMissing.numerator,result.needs[0].afterMissing.numerator],['0','2']);
 assert.notEqual(result.previewDigest,previewDigest);
 await assert.rejects(run((ctx,shop)=>recordCurrentPantry(ctx,shop,'pantry.observe',next.cmd.body,randomUUID(),load)),e=>e.code==='stale_supply');
 await run(async(ctx,shop)=>{
   await recordCurrentPantry(ctx,shop,'pantry.observe',{...observation,previewDigest:result.previewDigest},randomUUID(),load);
   const report=await readSharedRecoveryCoverage(ctx,shop,load),current=report.needs.find(n=>n.ingredientId===changedIngredient);
   assert.deepEqual(current.missing,result.needs[0].afterMissing);
 });
 await assert.rejects(run((ctx,shop)=>recordCurrentDelivery(ctx,shop,'delivery.reserve',{...f.reservation,
   quantity:q(1),supplyRevision:6,groupId:f.plates.id},randomUUID(),load)),e=>e.code==='stale_supply');
 await run(async(ctx,shop)=>{
   const id=randomUUID();
   await recordCurrentDelivery(ctx,shop,'delivery.reserve',{...f.reservation,supplyRevision:6,predecessorId:released.operationId},id,load);
   const report=await readSharedRecoveryCoverage(ctx,shop,load);
   assert.equal(report.needs.find(n=>n.needId===original.needs.find(n=>n.priority==='protected').id).reservations[0].reservationId,id);
 });
});
