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

async function reservationFixture({excluded=false,split=true,rival=false,day,rivalDay,deadline}={}) {
 const f=await mealFixture(),commands=f.base+'/commands',path=f.path+'/delivery-evidence';
 const quantity=n=>({amount:{numerator:n,denominator:1},unit:'count',originalLiteral:String(n)});
 const meal=structuredClone(f.meal),[plates,lunch]=meal.planning.groups,ingredient=meal.planning.ingredients[0];
 if(day) meal.day=day;
 if(deadline) meal.planning.deadline=deadline;
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

test('reviewed cook sections require the current source, explicit recipient baseline and live named seat',async()=>{
 const f=await mealFixture(), occurrenceId=f.proposal.occurrenceId;
 const command=(kind,body,base={shopRevision:3,authorityEpoch:1})=>({
   v:1,kind,body,base,clientKey:randomUUID(),shopId:f.shopId,replayWindow:f.owner.window});
 const write=c=>call(f.owner,f.base+'/commands','POST',c);
 ok(await write(command('shop.reportPlaced',{occurredAt:new Date().toISOString()},{shopRevision:2,authorityEpoch:1})));
 const ingredient='need.'+randomUUID(), label='Ana 🥣';
 const save=(amount,generated=true)=>{
   const rows=[['meal','Cena\n\ncon frijoles',false],[ingredient,amount,true],['scope','Entregas confirmadas',false],['stamp','Revisión 2',false]];
   const factIndex={version:1,source:'delivery',sections:rows.map(([key,text,unresolved])=>({key,bytes:Buffer.byteLength(text),unresolved}))};
   return command('cookCopy.save',{placedRevision:2,supplyRevision:0,occurrenceId,mealRevision:2,language:'es',
     text:rows.slice(0,-1).map(r=>r[1]).join('\n\n')+'\n'+rows.at(-1)[1],...(generated?{factIndex}:{})});
 };
 const first=save('Faltan 2 porciones'); const firstId=ok(await write(first)).copyId;
 const sent=ok(await write(command('cookCopy.markSent',{copyId:firstId,recipient:label,previousSendId:null}))).operationId;
 const second=save('Falta 1 porción'); const secondId=ok(await write(second)).copyId;
 const review={occurrenceId,copyId:secondId,previousCopyId:firstId,previousSendId:sent,recipient:label,destinationConfirmed:true};
 const check=(fields={},actor=f.owner)=>call(actor,f.path+'/cook-copies/correction','POST',{...review,...fields});
 const facts=ok(await check());assert.deepEqual(facts.currentFacts,second.body.factIndex);assert.deepEqual(facts.previousFacts,first.body.factIndex);
 assert.equal(facts.previousSendId,sent);
 assert.equal((await check({recipient:'Ana'})).status,409);
 assert.equal((await check({destinationConfirmed:false})).status,422);
 assert.equal((await check({previousSendId:randomUUID()})).status,409);
 assert.equal((await check({copyId:firstId})).status,409);
 assert.equal((await check({},f.planner)).status,404);
 const invalid=save('Invalid index');invalid.body.factIndex.sections[0].bytes--;
 assert.equal((await write(invalid)).status,422);
 const manual=ok(await write(save('Mi texto privado',false))).copyId;
 assert.equal(ok(await check({copyId:manual})).currentFacts,null);
 assert.equal((await check()).status,409);
 const manualSend=ok(await write(command('cookCopy.markSent',{copyId:manual,recipient:label,previousSendId:sent}))).operationId;
 const newer=ok(await write(save('Otra versión'))).copyId;
 assert.equal(ok(await check({copyId:newer,previousCopyId:manual,previousSendId:manualSend})).previousFacts,null);
 const latest={copyId:newer,previousCopyId:manual,previousSendId:manualSend};
 await admin.query("UPDATE ritc.billing_seat SET display_name='Different name' WHERE household_id=$1 AND member_id=$2",[f.h,f.owner.id]);
 assert.equal(ok(await check(latest)).copyId,newer);
 const state=(await admin.query('SELECT subscription FROM ritc.billing_state WHERE household_id=$1',[f.h])).rows[0].subscription;
 await admin.query('UPDATE ritc.billing_state SET subscription=$2 WHERE household_id=$1',[f.h,{...state,expiresAt:Date.now()-1000}]);
 assert.equal((await check(latest)).data.error.code,'membership_inactive');
 await admin.query('UPDATE ritc.billing_state SET subscription=$2 WHERE household_id=$1',[f.h,state]);
 ok(await write(command('delivery.register',{supplyRevision:0,placedRevision:2,lineId:f.initial.lines[0].lineId,segmentKey:randomUUID(),foodName:'Beans',exclusionTags:[]})));
 assert.equal((await check(latest)).data.error.code,'stale_base');
 await admin.query('DELETE FROM ritc.billing_seat WHERE household_id=$1 AND member_id=$2',[f.h,f.owner.id]);
 assert.equal((await check({copyId:newer,previousCopyId:manual,previousSendId:manualSend})).data.error.code,'membership_inactive');
 const history=ok(await call(f.owner,f.path+'/cook-copies?occurrenceId='+occurrenceId));
 assert.equal(history.copies.find(c=>c.copyId===firstId).text,first.body.text);
 assert.equal(history.copies.some(c=>'factIndex' in c),false);
 assert.equal(ok(await call(f.owner,f.path+'/cook-copies/baseline','POST',{recipient:label,occurrenceId})).baseline.send.sendId,manualSend);
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
 const preview=await repo.transaction(f.h,async(db,now)=>{
   const member=await repo.member(db,f.h,{issuer,subject:f.owner.subject}),ctx={db,now,householdId:f.h,member};
   const shop=await repo.shop(ctx,f.shopId),{loadSharedRecoveryDecisionBasis}=await import('../dist/shared-recovery-basis.js');
   const {basis,verifyReplacementCoverage}=await loadSharedRecoveryDecisionBasis(ctx,shop,async()=>emptyRecoveryPublication());
   return verifyReplacementCoverage(previewRecovery(basis,{v:1,base:basis.base,intent},now.toISOString()));
 });
 assert.equal(preview.timingConfirmed,false);assert.equal(preview.consentSatisfied,true);
 assert.deepEqual(preview.after.meals.find(m=>m.occurrenceId===tue.occurrenceId),tue);
 assert.deepEqual(preview.after.demands.filter(d=>tue.needs.some(n=>n.id===d.needId)),demands(tue));
 const published=new Map([[f.shopId,{...emptyRecoveryPublication(),recoveryRevision:1,meals:[next],usedNeedIds:[ordinary.id],usedRevisionIds:[wed.revisionId]}]]);
 const current=await realRecoveryRead(f,f.shopId,published);
 assert.equal(current.context.meals.find(m=>m.occurrenceId===wed.occurrenceId).title,next.title);
 assert.equal(current.context.mealSources.find(m=>m.occurrenceId===wed.occurrenceId).sealedRevisionId,wed.revisionId);
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
 // Restoring the earlier shop's source match would take all three already
 // allocated wraps from the later dinner. The single-shop domain preview is
 // deliberately unresolved and can be agreed to; the actual household plan vetoes it.
 await repo.transaction(f.h,async(db,now)=>{
   const member=await repo.member(db,f.h,{issuer,subject:f.owner.subject}),ctx={db,now,householdId:f.h,member};
   const shop=await repo.shop(ctx,f.shopId),{loadSharedRecoveryDecisionBasis}=await import('../dist/shared-recovery-basis.js');
   const {previewRecovery,recoveryDigest}=await import('../dist/recovery-domain.js');
   const {basis,verifyReplacementCoverage}=await loadSharedRecoveryDecisionBasis(ctx,shop,async(_,id)=>loaded.get(id)??emptyRecoveryPublication());
   const previous=basis.meals.find(m=>m.occurrenceId===old.occurrenceId),replacement={...previous,revisionId:randomUUID(),
     needs:previous.needs.map(n=>n.priority==='protected'?n:{...n,id:randomUUID(),matchedSourceIds:[f.sourceId]})};
   const intent={occurrenceId:previous.occurrenceId,targetDigest:recoveryDigest(previous),replacement,reviewedAt:now.toISOString(),
     repeatOfOccurrenceId:null,agreesToRepeat:false,proposesExtraTrip:false,agreesToExtraTrip:false,acceptsUnresolved:true};
   const preview=previewRecovery(basis,{v:1,base:basis.base,intent},now.toISOString());
   assert.equal(preview.consentSatisfied,true);assert.equal(preview.foodConfirmed,false);
   assert.throws(()=>verifyReplacementCoverage(preview),e=>e.code==='steals_food');
 });
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

test('shopper previews and publishes one actual meal replacement after pickup while checkout and other needs stay intact',async()=>{
 const f=await reservationFixture({rival:true}),path=f.path+'/meal-recovery';
 const immutable=async()=> (await admin.query(`SELECT revision,digest,snapshot FROM ritc.shop_snapshot
   WHERE household_id=$1 AND shop_id=$2 ORDER BY revision`,[f.h,f.shopId])).rows;
 const sealed=await immutable(),financialBefore=ok(await call(f.owner,f.path+'/financial-evidence'));
 const desk=ok(await call(f.owner,path)),target=desk.meals.find(m=>m.occurrenceId===f.rivalOccurrence);
 assert(target);assert.equal(target.zone,null);assert.equal(target.due,null);
 const pantryRevision=desk.base.pantryRevision;
 const replacement={...target,title:'Reviewed bean dinner',revisionId:randomUUID(),needs:target.needs.map(n=>({
   ...n,id:randomUUID(),ingredientId:randomUUID(),name:'Cooked beans',quantity:f.quantity(4),foodId:null,matchedSourceIds:[]
 }))};
 const input={v:1,base:desk.base,intent:{occurrenceId:target.occurrenceId,targetDigest:desk.targetDigests.find(d=>d.occurrenceId===target.occurrenceId).digest,
   replacement,reviewedAt:desk.asOf,repeatOfOccurrenceId:null,agreesToRepeat:false,proposesExtraTrip:true,agreesToExtraTrip:false,acceptsUnresolved:true}};
 const donor=desk.meals.find(m=>m.occurrenceId!==target.occurrenceId);
 const fakeRepeat=structuredClone(input);fakeRepeat.intent.repeatOfOccurrenceId=donor.occurrenceId;fakeRepeat.intent.agreesToRepeat=true;
 assert.equal((await call(f.owner,path+'/preview','POST',fakeRepeat)).data.error.code,'repeat_changed');
 const sameTitle=structuredClone(input);sameTitle.intent.replacement.title='  '+donor.title.toUpperCase()+'  ';
 sameTitle.intent.proposesExtraTrip=false;
 const repeated=ok(await call(f.owner,path+'/preview','POST',sameTitle));
 assert.equal(repeated.repeatRequired,true);assert.equal(repeated.consentSatisfied,false);
 const denied=ok(await call(f.owner,path+'/preview','POST',input));assert.equal(denied.consentSatisfied,false);
 const apply=(review,input)=>f.command('mealRecovery.apply',{...input,previewId:review.previewId,previewDigest:review.previewDigest});
 assert.equal((await f.send(apply(denied,input))).data.error.code,'meal_agreement_required');
 assert.deepEqual((await immutable()),sealed);
 input.intent.agreesToExtraTrip=true;
 const preview=ok(await call(f.owner,path+'/preview','POST',input));assert.equal(preview.consentSatisfied,true);
 assert.equal(preview.feasible,false);assert.equal(preview.timingConfirmed,false);
 assert.equal(preview.after.meals.find(m=>m.occurrenceId===target.occurrenceId).title,replacement.title);
 const unaffected=desk.meals.filter(m=>m.occurrenceId!==target.occurrenceId).flatMap(m=>m.needs.map(n=>n.id));
 for(const id of unaffected) assert.deepEqual(preview.after.demands.find(n=>n.needId===id),preview.before.demands.find(n=>n.needId===id));
 assert.deepEqual(preview.after.demands.find(n=>n.needId===replacement.needs[0].id).shortfall,{numerator:'4',denominator:'1'});
 assert.deepEqual(ok(await call(f.owner,path)).meals,desk.meals); // Preview does not apply the meal.
 assert.equal((await call(f.planner,path)).status,404);
 const otherDevice={...f.owner};await enroll(otherDevice,f.h);
 const original=apply(preview,input);
 assert.equal((await f.send({...original,replayWindow:otherDevice.window},otherDevice)).data.error.code,'refresh_required');
 const changed=structuredClone(original);changed.body.intent.replacement.title='Unreviewed';assert.equal((await f.send(changed)).status,409);
 const another=ok(await call(f.owner,path+'/preview','POST',input));
 const competing=apply(another,input);
 const [a,b]=await Promise.all([f.send(original),f.send(competing)]);
 const success=[a,b].find(r=>r.status===200),conflict=[a,b].find(r=>r.status===409);assert(success&&conflict);
 const winner=a.status===200?original:competing;
 // Re-submit the original accepted intent exactly. The losing client must refresh.
 assert.deepEqual(ok(await f.send(winner)),success.data);
 assert.equal(success.data.occurrenceId,target.occurrenceId);assert.equal(success.data.revisionId,replacement.revisionId);
 assert.equal(success.data.recoveryRevision,1);assert.equal(success.data.shopRevision,desk.base.shopRevision);
 const current=ok(await call(f.owner,path));assert.equal(current.base.recoveryRevision,1);
 assert.equal(current.base.pantryRevision,pantryRevision+1);
 assert.deepEqual(current.meals.find(m=>m.occurrenceId===target.occurrenceId),replacement);
 for(const m of desk.meals.filter(x=>x.occurrenceId!==target.occurrenceId)) assert.deepEqual(current.meals.find(x=>x.occurrenceId===m.occurrenceId),m);
 const effective=ok(await call(f.owner,path+'/coverage'));
 assert.deepEqual(effective.needs.find(n=>n.needId===replacement.needs[0].id).missing,{numerator:'4',denominator:'1'});
 const oldSave={occurrenceId:target.occurrenceId,mealRevision:target.sourceMealRevision,placedRevision:desk.placedRevision,
   supplyRevision:current.base.supplyRevision,pantryRevision:current.base.pantryRevision,language:'es',text:'Se necesitan cuatro porciones.'};
 assert.equal((await f.write('cookCopy.save',oldSave)).data.error.code,'stale_meal');
 assert.equal((await f.write('cookCopy.save',{...oldSave,revisionId:randomUUID(),recoveryRevision:1})).data.error.code,'stale_meal');
 const copy=ok(await f.write('cookCopy.save',{...oldSave,revisionId:replacement.revisionId,recoveryRevision:1}));
 const saved=ok(await call(f.owner,f.path+'/cook-copies?occurrenceId='+target.occurrenceId)).copies[0];
 assert.equal(saved.copyId,copy.copyId);assert.equal(saved.revisionId,replacement.revisionId);assert.equal(saved.recoveryRevision,1);
 assert.equal(saved.text,oldSave.text);
 assert.deepEqual(await immutable(),sealed);
 assert.deepEqual(ok(await call(f.owner,f.path+'/financial-evidence')).sourceVersion,financialBefore.sourceVersion);
 assert.equal((await f.delivery()).meals.find(m=>m.occurrenceId===target.occurrenceId).meal.title,target.title);
});

test('free household can repair a placed dinner and erasure removes revised text without reviving an old meal',async()=>{
 const f=await fixture(),path=f.base+'/shops/'+f.shopId,commands=f.base+'/commands';
 const control={shopRevision:1,authorityEpoch:1},q={amount:{numerator:2,denominator:1},originalLiteral:'2',unit:'count'};
 const group=randomUUID(),ingredient=randomUUID(),occurrenceId=randomUUID();
 const meal={title:'Wednesday before pickup',portions:2,day:'2026-11-11',kind:'dinner',protected:false,
   planning:{groups:[{id:group,name:'Dinner',servings:q.amount,protected:false}],
     ingredients:[{id:ingredient,name:'Two wraps',quantity:q,groupIds:[group],exclusions:[]}]}};
 const submit=(actor,kind,body)=>call(actor,commands,'POST',{v:1,replayWindow:actor.window,clientKey:randomUUID(),shopId:f.shopId,kind,base:{...control},body});
 const initial=ok(await call(f.owner,path));
 ok(await submit(f.owner,'shop.patch',{quote:initial.quote,lines:initial.lines,mealEdit:{occurrenceId,baseMealRevision:null,meal}}));control.shopRevision++;
 ok(await submit(f.owner,'shop.reportPlaced',{occurredAt:new Date().toISOString()}));control.shopRevision++;
 const guest=await actor(),invite=ok(await call(f.owner,f.base+'/invites','POST',{kind:'adult_contributor'}));
 guest.id=ok(await call(guest,'/v1/invites/redeem','POST',{token:invite.token,intent:'join',adultAttestation:true,alias:'Other adult'})).memberId;
 await enroll(guest,f.h);
 ok(await submit(f.owner,'shop.transferAuthority',{newShopperId:guest.id}));control.authorityEpoch++;
 const recovery=path+'/meal-recovery',desk=ok(await call(guest,recovery)),before=desk.meals[0];
 const replacement={...before,title:'Private revised dinner',revisionId:randomUUID(),needs:before.needs.map(n=>({...n,id:randomUUID(),ingredientId:randomUUID(),name:'Rice'}))};
 const request={v:1,base:desk.base,intent:{occurrenceId,targetDigest:desk.targetDigests[0].digest,replacement,reviewedAt:desk.asOf,repeatOfOccurrenceId:null,
   agreesToRepeat:false,proposesExtraTrip:false,agreesToExtraTrip:false,acceptsUnresolved:true}};
 const preview=ok(await call(guest,recovery+'/preview','POST',request));
 const cmd={v:1,shopId:f.shopId,base:{...control},kind:'mealRecovery.apply',clientKey:randomUUID(),replayWindow:guest.window,
   body:{...request,previewId:preview.previewId,previewDigest:preview.previewDigest}};
 const receipt=ok(await call(guest,commands,'POST',cmd));assert.equal(receipt.recoveryRevision,1);
 const current=ok(await call(guest,recovery));
 ok(await submit(guest,'cookCopy.save',{placedRevision:desk.placedRevision,mealRevision:before.sourceMealRevision,occurrenceId,supplyRevision:current.base.supplyRevision,
   pantryRevision:current.base.pantryRevision,recoveryRevision:1,revisionId:replacement.revisionId,language:'en',text:replacement.title}));
 await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,guest.id]);
 // The original placed fact is still owned by the other adult, while the live
 // recovery has been erased. No query or retry should revive its wording.
 const erased=ok(await call(guest,recovery));assert.deepEqual(erased.meals,[]);assert(erased.base.recoveryRevision>1);
 assert.equal((await call(guest,commands,'POST',cmd)).data.error.code,'refresh_required');
 assert.deepEqual(ok(await call(guest,path+'/cook-copies?occurrenceId='+occurrenceId)).copies,[]);
 assert.equal(ok(await call(guest,path+'/delivery-evidence')).meals[0].meal.title,meal.title);
 const stored=(await admin.query('SELECT current_meal,intent,decision_digest FROM ritc.meal_recovery_revision WHERE operation_id=$1',[receipt.operationId])).rows[0];
 assert.deepEqual(stored,{current_meal:null,intent:null,decision_digest:null});
});

test('accepted fallback registry tracks the exact source version and erases published copies derived from another shopper',async()=>{
 const f=await reservationFixture(),sourceShop=await f.shop(),origin=f.base+'/shops/'+sourceShop,registry=origin+'/accepted-fallbacks',recovery=f.path+'/meal-recovery';
 ok(await call(f.owner,f.base+'/commands','POST',{v:1,clientKey:randomUUID(),shopId:sourceShop,replayWindow:f.owner.window,kind:'shop.transferAuthority',
   base:{shopRevision:1,authorityEpoch:1},body:{newShopperId:f.planner.id}}));
 const scope=ok(await call(f.planner,registry));
 const recipe={title:'Separate recipe disclosure',portions:6,notes:'Keep the exact recipe.',sourceURL:null,exclusions:[],elapsedMinutes:null,requiredLeadMinutes:null,
   ingredients:[{id:randomUUID(),name:'Rice',notes:'Wash twice',quantity:null,exclusions:[]}]};
 const candidateId=randomUUID(),accept={v:1,clientKey:randomUUID(),shopRevision:scope.shopRevision,authorityEpoch:scope.authorityEpoch,registryRevision:0,
   action:'accept',reviewed:true,candidateId,baseRevision:null,source:{kind:'disclosed'},recipe,usual:false};
 ok(await call(f.planner,registry,'POST',accept));
 const desk=ok(await call(f.owner,recovery)),old=desk.meals.find(m=>m.occurrenceId===f.match.occurrenceId);
 const source={kind:'meal',occurrenceId:old.occurrenceId,mealRevision:old.sourceMealRevision,revisionId:old.revisionId};
 const current=ok(await call(f.owner,f.path+'/accepted-fallbacks/source','POST',{source})).recipe;
 assert.equal(current.groups.find(g=>g.protected).servings.numerator,2);assert.equal(current.ingredients.find(i=>i.groupIds[0]===f.lunch.id).quantity.amount.numerator,2);
 const next={...old,revisionId:randomUUID(),title:recipe.title,notes:recipe.notes,needs:old.needs.map(n=>n.priority==='protected'?n:{...n,id:randomUUID(),
   ingredientId:recipe.ingredients[0].id,name:'Rice',notes:'Wash twice',quantity:null,matchedSourceIds:[]})};
 const input={v:1,base:desk.base,intent:{occurrenceId:old.occurrenceId,targetDigest:desk.targetDigests.find(t=>t.occurrenceId===old.occurrenceId).digest,
   replacement:next,reviewedAt:desk.asOf,repeatOfOccurrenceId:null,agreesToRepeat:false,proposesExtraTrip:false,agreesToExtraTrip:false,acceptsUnresolved:true}};
 const preview=ok(await call(f.owner,recovery+'/preview','POST',input)),command=f.command('mealRecovery.apply',{...input,previewId:preview.previewId,previewDigest:preview.previewDigest});
 const receipt=ok(await f.send(command));
 const {loadAcceptedFallbacks,linkAcceptedFallback}=await import('../dist/shared-fallback-registry.js');
 const list=ids=>repo.transaction(f.h,db=>loadAcceptedFallbacks({db,householdId:f.h,member:{member_id:f.owner.id,kind:'adult'}},ids));
 assert.deepEqual(await list([]),[]);assert.deepEqual(await list([randomUUID()]),[]);
 assert.deepEqual((await list([candidateId])).map(x=>x.candidateId),[candidateId]);
 // The paid planner calls this helper in the same household transaction as publication.
 const link=revision=>repo.transaction(f.h,db=>linkAcceptedFallback({db,householdId:f.h,member:{member_id:f.owner.id,kind:'adult'}},receipt.operationId,candidateId,revision));
 await assert.rejects(()=>link(2),e=>e.code==='stale_fallback');await link(1);
 assert.equal((await admin.query('SELECT 1 FROM ritc.meal_recovery_source_member WHERE operation_id=$1 AND member_id=$2',[receipt.operationId,f.planner.id])).rowCount,1);
 const foreign=await fixture();
 await repo.transaction(foreign.h,async db=>{
   for(const table of ['accepted_fallback_revision','meal_recovery_fallback']){
     assert.equal((await db.query('SELECT 1 FROM ritc.'+table+' WHERE household_id=$1',[f.h])).rowCount,0);
     assert.equal((await db.query("SELECT has_table_privilege(current_user,$1,'UPDATE,DELETE') AS edits",['ritc.'+table])).rows[0].edits,false);
   }
 });
 const after=ok(await call(f.owner,recovery));const copy=ok(await f.write('cookCopy.save',{language:'en',text:recipe.notes,occurrenceId:old.occurrenceId,
   mealRevision:old.sourceMealRevision,revisionId:next.revisionId,recoveryRevision:1,placedRevision:after.placedRevision,supplyRevision:after.base.supplyRevision,pantryRevision:after.base.pantryRevision}));
 await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.planner.id]);
 assert.deepEqual(ok(await call(f.owner,f.path+'/accepted-fallbacks')).candidates,[]);
 assert(!ok(await call(f.owner,recovery)).meals.some(m=>m.occurrenceId===old.occurrenceId));
 assert.equal((await admin.query('SELECT 1 FROM ritc.dated_cook_copy WHERE copy_id=$1',[copy.copyId])).rowCount,0);
 assert.notEqual((await f.send(command)).status,200);
});

test('paid fallback ranking uses the accepted household library, current physical food, deadline and explicit independent agreements',async()=>{
 const at=new Date(Date.now()+45*60_000).toISOString(),f=await reservationFixture({day:at.slice(0,10),deadline:{at,zone:'UTC'}});
 const path=f.path+'/meal-recovery',library=f.path+'/accepted-fallbacks',desk=ok(await call(f.owner,path));
 const target=desk.meals.find(m=>m.occurrenceId===f.match.occurrenceId);
 assert.equal(target.due,at);
 const targetDigest=desk.targetDigests.find(d=>d.occurrenceId===target.occurrenceId).digest;
 const base={v:1,base:desk.base,occurrenceId:target.occurrenceId,targetDigest,trip:null};
 const rank=(reviews,trip=null,actor=f.owner)=>call(actor,path+'/options','POST',{...base,reviews,trip});
 const empty=ok(await rank([]));assert.deepEqual(empty.options,[]);assert.deepEqual(empty.target,target);
 assert.deepEqual(ok(await call(f.owner,library)).candidates,[]); // Choosing the two shop dishes did not approve either.
 assert.equal((await rank([],null,f.planner)).status,404);
 const otherShop=await f.shop(),outside=f.base+'/shops/'+otherShop+'/accepted-fallbacks';
 async function approve(title,quantity,elapsedMinutes,usual=false,requiredLeadMinutes=null,extra=[]) {
   const recipe={title,portions:4,notes:'Keep the entered method',sourceURL:null,exclusions:['No sesame','No peanuts'],elapsedMinutes,requiredLeadMinutes,
     ingredients:[{id:randomUUID(),name:'Wraps',quantity:f.quantity(quantity),exclusions:[],notes:'Warm before serving'},...extra]};
   const {shopRevision,authorityEpoch,registryRevision}=ok(await call(f.owner,outside));
   const candidateId=randomUUID(),receipt=ok(await call(f.owner,outside,'POST',{v:1,clientKey:randomUUID(),shopRevision,authorityEpoch,
     registryRevision,candidateId,baseRevision:null,reviewed:true,action:'accept',source:{kind:'disclosed'},recipe,usual}));
   return {candidateId,revision:receipt.revision,remainingElapsedMinutes:null,advanceStepsCompleted:false,
     ingredients:recipe.ingredients.map(i=>({ingredientId:i.id,sourceIds:[f.sourceId],offer:null}))};
 }
 const easy=await approve('Three warm wraps',3,10,true);
 const large=await approve(target.title,6,8);
 const slow=await approve('Marinated wraps',3,10,false,120);
 const unknown=await approve('Unknown cook time',3,null);
 const trip={minutes:8,budgetMinor:500,chargesMinor:50,currency:'USD'};
 const offer={label:'Reviewed two-wrap pouch',exclusionTags:[],usablePerPack:f.quantity(2),priceMinor:200,availablePacks:2};
 large.ingredients[0].offer=offer;
 const sharedPack=await approve('Two servings from the same pack',1,5,false,null,[
   {id:randomUUID(),name:'More wraps',quantity:f.quantity(1),exclusions:[],notes:''}]);
 const packId=randomUUID();
 sharedPack.ingredients.forEach(r=>{r.sourceIds=[];r.offer={...offer,packId,availablePacks:1};});
 const pooled=ok(await rank([sharedPack],trip)).options[0];
 assert.equal(pooled.packCount,1);assert.equal(pooled.extraCashMinor,250);assert.equal(pooled.buys.length,1);
 const inconsistent=structuredClone(sharedPack);inconsistent.ingredients[1].offer.priceMinor++;
 assert.deepEqual(ok(await rank([inconsistent],trip)).options,[]);
 const single=ok(await rank([large,unknown,slow,easy]));assert.deepEqual(single.options.map(o=>o.candidateId),[easy.candidateId]);
 assert.deepEqual(single.conditional.map(c=>c.reason),['topUpUnreviewed','timingUnknown','leadStepUnconfirmed']);
 const enough=ok(await rank([slow,large,easy],trip));
 assert.equal(enough.usualMinutes,10);assert.deepEqual(enough.options.map(o=>o.candidateId),[easy.candidateId,large.candidateId]);
 const [onHand,topUp]=enough.options;
 assert.equal(onHand.kind,'onHand');assert.equal(onHand.packCount,0);
 assert.deepEqual(onHand.intent.replacement.exclusions,['No sesame']);
 assert(onHand.intent.replacement.needs.find(n=>n.priority==='required').exclusions.includes('No peanuts'));
 assert.equal(onHand.intent.replacement.needs.find(n=>n.priority==='required').notes,'Warm before serving');
 assert.deepEqual(onHand.intent.replacement.needs.filter(n=>n.priority==='protected'),target.needs.filter(n=>n.priority==='protected'));
 assert.equal(topUp.kind,'topUp');assert.equal(topUp.minutes,16);assert.equal(topUp.repeatRequired,true);
 assert.deepEqual(topUp.buys,[{ingredientId:large.ingredients[0].ingredientId,label:offer.label,packs:2,subtotalMinor:400}]);
 assert.equal(topUp.extraCashMinor,450);
 const over=ok(await rank([large],{...trip,budgetMinor:449}));assert.deepEqual(over.options,[]);
 assert.deepEqual(over.conditional,[{candidateId:large.candidateId,revision:large.revision,reason:'overBudget',extraCashMinor:450,budgetMinor:449,currency:'USD'}]);
 const sold=structuredClone(large);sold.ingredients[0].offer.availablePacks=1;
 assert.equal(ok(await rank([sold],trip)).conditional[0].requiredPacks,2);
 assert.deepEqual(ok(await rank([large],{...trip,minutes:50})).options,[]);
 const unsafe=structuredClone(large);unsafe.ingredients[0].offer.exclusionTags=['sesame'];
 const noFit=ok(await rank([unsafe,unknown,slow],trip));assert.deepEqual(noFit.options,[]);assert.deepEqual(noFit.target,target);assert.equal(noFit.conditional[0].reason,'exclusionConflict');
 assert.equal(ok(await rank([{...slow,advanceStepsCompleted:true}])).options.length,1);
 const preview=intent=>call(f.owner,path+'/preview','POST',{v:1,base:desk.base,intent});
 const apply=(intent,seen)=>f.command('mealRecovery.apply',{v:1,base:desk.base,intent,previewId:seen.previewId,previewDigest:seen.previewDigest});
 const source={kind:'meal',occurrenceId:target.occurrenceId,mealRevision:target.sourceMealRevision,revisionId:target.revisionId};
 const scoped=ok(await call(f.owner,library+'/source','POST',{source})),candidateId=randomUUID();
 ok(await call(f.owner,library,'POST',{v:1,clientKey:randomUUID(),candidateId,baseRevision:null,action:'accept',usual:false,reviewed:true,
   registryRevision:scoped.registryRevision,shopRevision:scoped.shopRevision,authorityEpoch:scoped.authorityEpoch,recipe:scoped.recipe,source}));
 const fromPlan={candidateId,revision:1,remainingElapsedMinutes:8,advanceStepsCompleted:false,
   ingredients:scoped.recipe.ingredients.map(i=>({ingredientId:i.id,sourceIds:[f.sourceId],offer}))};
 const named=ok(await rank([fromPlan],trip)).options[0];
 assert.equal(named.packCount,1);assert.equal(named.repeatRequired,true);
 assert.deepEqual(named.intent.replacement.needs.filter(n=>n.priority==='protected'),target.needs.filter(n=>n.priority==='protected'));
 const hiddenGroup=structuredClone(fromPlan);
 hiddenGroup.ingredients.find(i=>i.ingredientId===target.needs.find(n=>n.priority==='protected').id).sourceIds=[];
 assert.deepEqual(ok(await rank([hiddenGroup],trip)).options,[]);
 const original=topUp.intent;assert.equal(original.agreesToRepeat,false);assert.equal(original.agreesToExtraTrip,false);
 for(const flags of [{agreesToRepeat:true},{agreesToExtraTrip:true},{agreesToRepeat:true,agreesToExtraTrip:true}]) {
   const i={...original,...flags},p=ok(await preview(i));assert.equal(p.consentSatisfied,false);assert.equal(p.feasible,false);
   assert.equal((await f.send(apply(i,p))).data.error.code,'meal_agreement_required');
 }
 const forged=structuredClone(original);forged.replacement.title='Invented approved dish';
 assert.equal((await preview(forged)).status,409);
 const none=ok(await call(f.owner,path));assert.deepEqual(none.meals,desk.meals);
 const current=ok(await call(f.owner,outside));
 const approved=ok(await preview(onHand.intent));
 ok(await call(f.owner,outside,'POST',{v:1,action:'revoke',reviewed:true,clientKey:randomUUID(),shopRevision:current.shopRevision,
   authorityEpoch:current.authorityEpoch,registryRevision:current.registryRevision,candidateId:easy.candidateId,baseRevision:easy.revision}));
 assert.equal((await f.send(apply(onHand.intent,approved))).status,409);
 assert.equal((await rank([easy])).status,409);
 const i={...original,agreesToRepeat:true,agreesToExtraTrip:true,acceptsUnresolved:true},seen=ok(await preview(i));
 assert.equal(seen.consentSatisfied,true);assert.equal(seen.foodConfirmed,false);
 const state=(await admin.query('select subscription from ritc.billing_state where household_id=$1',[f.h])).rows[0].subscription;
 const subscription=subscriptions.get(state.originalTransactionID);
 subscriptions.set(state.originalTransactionID,{...subscription,status:'expired',expiresAt:Date.now()-1000,signedAt:Date.now()});
 assert.equal((await rank([large],trip)).data.error.code,'membership_inactive');
 assert.equal((await f.send(apply(i,seen))).data.error.code,'membership_inactive');
 assert.deepEqual(ok(await call(f.owner,path)).meals,desk.meals);
 subscriptions.set(state.originalTransactionID,{...subscription,signedAt:Date.now()+1000});
 const command=apply(i,seen),receipt=ok(await f.send(command));assert.deepEqual(ok(await f.send(command)),receipt);
 const saved=ok(await call(f.owner,path));assert.equal(saved.meals.find(m=>m.occurrenceId===target.occurrenceId).revisionId,i.replacement.revisionId);
 assert.equal((await rank([large],trip)).status,409); // Stock/recovery seals changed on the published replacement.
 assert.equal((await admin.query('select 1 from ritc.meal_recovery_fallback where household_id=$1 and candidate_id=$2 and operation_id=$3',
   [f.h,large.candidateId,receipt.operationId])).rowCount,1);
 assert.equal(ok(await call(f.owner,path+'/coverage')).needs.find(n=>n.needId===i.replacement.needs.find(n=>n.priority==='required').id).missing.numerator,'3');
 subscriptions.set(state.originalTransactionID,{...subscription,status:'expired',expiresAt:Date.now()-1000,signedAt:Date.now()+2000});
 assert.deepEqual(ok(await f.send(command)),receipt); // Read back the committed receipt after the seat lapses.
 assert.deepEqual(ok(await call(f.owner,path)).meals,saved.meals);
});
