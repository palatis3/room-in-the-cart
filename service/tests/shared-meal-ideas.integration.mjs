import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {migrate} from '../scripts/migrate.mjs';
import {randomUUID} from 'node:crypto';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {digest} from '../dist/database.js';
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
 const shopId=await shop();async function paid(){const token=ok(await call(owner,base+'/billing/purchase-context','POST',{})).appAccountToken,original=String(Date.now())+String(Math.floor(Math.random()*1e6)).padStart(6,'0'),now=Date.now();subscriptions.set(original,{environment:'Sandbox',originalTransactionID:original,transactionID:original,appAccountToken:token,productID:'fixture.household.yearly',purchasedAt:now,signedAt:now,expiresAt:now+3600000,graceExpiresAt:null,status:'active'});ok(await call(owner,'/v1/billing/verify','POST',{householdId:h,signedTransactionInfo:original}));return original;}
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

const ideaDraft=()=>({title:'Household rice bowls',source:'app_template',servings:2,minutes:25,assumedExtras:['Water'],exclusions:[],ingredients:[{id:randomUUID(),name:'Rice',required:600,unit:'gram',stock:500,reservations:[{name:'Protected Tuesday lunch',amount:250}],pack:400,usableNumerator:3,usableDenominator:4,evidence:'Household stock checked; package label entered'}]});
function mealFor(draft){return{title:draft.title,day:'2026-11-09',kind:'dinner',portions:draft.servings,protected:false,planning:{...(draft.exclusions.length ? {exclusions:draft.exclusions} : {}),...(draft.minutes!==null ? {leadTimeMinutes:draft.minutes} : {}),groups:[],ingredients:draft.ingredients.map(i=>({id:i.id,name:i.name,quantity:{amount:typeof i.required==='number'?{numerator:i.required,denominator:1}:i.required,unit:i.unit,originalLiteral:`${typeof i.required==='number'?i.required:i.required.denominator===1?i.required.numerator:i.required.numerator+'/'+i.required.denominator} ${i.unit}`},groupIds:[],exclusions:[]}))}};}
async function approved(f,author=f.planner,draft=ideaDraft()){
 const path=f.base+'/shops/'+f.shopId+'/meal-plan/ideas',page=ok(await call(author,path));
 const save={clientKey:randomUUID(),ideaId:randomUUID(),baseRevision:null,shopRevision:page.shopRevision,authorityEpoch:page.authorityEpoch,grantRevision:page.grantRevision,action:'save',draft,reviewedHouseholdEvidence:false};
 const saved=ok(await call(author,path,'POST',save));
 const approval={...save,clientKey:randomUUID(),baseRevision:saved.revision,action:'approve',reviewedHouseholdEvidence:true};
 const result=ok(await call(author,path,'POST',approval));
 const proposal={proposalId:randomUUID(),occurrenceId:randomUUID(),baseMealRevision:null,shopRevision:page.shopRevision,authorityEpoch:page.authorityEpoch,grantRevision:page.grantRevision,meal:mealFor(draft),reason:'Explicit household idea approval',approvedIdeaId:save.ideaId,approvedIdeaRevision:result.revision};
 return{path,page,save,approval,result,proposal};
}
test('adult planner corrects excluded ambiguous idea, approves only, then separately proposes and shopper applies once',async()=>{
 const f=await mealFixture(),path=f.path+'/meal-plan/ideas',before=ok(await call(f.owner,f.path));
 const draft=ideaDraft();draft.exclusions=['RICE'];draft.ingredients[0].pack=null;
 const save={clientKey:randomUUID(),ideaId:randomUUID(),baseRevision:null,shopRevision:2,authorityEpoch:1,grantRevision:1,action:'save',draft,reviewedHouseholdEvidence:false};
 const first=ok(await call(f.planner,path,'POST',save));assert.deepEqual(ok(await call(f.planner,path,'POST',save)),first);
 assert.equal((await call(f.planner,path,'POST',{...save,draft:{...draft,title:'Changed'}})).data.error.code,'key_reused');
 assert.equal((await call(f.planner,path,'POST',{...save,clientKey:randomUUID(),baseRevision:1,action:'approve',reviewedHouseholdEvidence:true})).data.error.code,'idea_review_required');
 draft.ingredients[0].name='Beans';draft.ingredients[0].pack=400;
 ok(await call(f.planner,path,'POST',{...save,clientKey:randomUUID(),baseRevision:1,draft}));
 const approval={...save,clientKey:randomUUID(),baseRevision:2,action:'approve',draft,reviewedHouseholdEvidence:true};
 const responses=await Promise.all([call(f.planner,path,'POST',approval),call(f.planner,path,'POST',approval)]);assert.deepEqual(ok(responses[0]),ok(responses[1]));
 assert.deepEqual(ok(await call(f.owner,f.path)),before);
 const page=ok(await call(f.planner,path));assert.equal(page.ideas[0].state,'approved');assert.equal(page.ideas[0].preview.ingredients[0].wholePacks,2);assert.equal(page.quote,undefined);assert.equal(page.lines,undefined);
 const proposal={proposalId:randomUUID(),occurrenceId:randomUUID(),baseMealRevision:null,shopRevision:2,authorityEpoch:1,grantRevision:1,meal:mealFor(draft),reason:'Reviewed idea',approvedIdeaId:save.ideaId,approvedIdeaRevision:3};
 const response=ok(await call(f.planner,f.changePath,'POST',proposal));assert.deepEqual(ok(await call(f.planner,f.changePath,'POST',proposal)),response);
 assert.deepEqual(ok(await call(f.owner,f.path)),before);
 const receipt=ok(await call(f.owner,f.changePath));assert.equal(receipt.proposals[0].original,null);
 const command=f.patch(2,{occurrenceId:proposal.occurrenceId,baseMealRevision:null,meal:proposal.meal,changeProposalId:proposal.proposalId});
 const applied=ok(await call(f.owner,f.base+'/commands','POST',command));assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',command)),applied);
 const current=ok(await call(f.owner,f.path));assert.equal(current.meals.length,2);assert.deepEqual(current.lines,before.lines);
});
test('Free current household shopper may approve and separately self-propose without assigning a planner',async()=>{
 const f=await fixture(),path=f.base+'/shops/'+f.shopId,created=await approved(f,f.owner);
 assert.equal(created.page.grantRevision,0);ok(await call(f.owner,path+'/meal-plan/changes','POST',created.proposal));
 const page=ok(await call(f.owner,path+'/meal-plan/changes'));assert.equal(page.proposals.length,1);assert.equal(page.proposals[0].original,null);
 const current=ok(await call(f.owner,path));assert.equal(current.meals.length,0);
 const edit={occurrenceId:created.proposal.occurrenceId,baseMealRevision:null,meal:created.proposal.meal,changeProposalId:created.proposal.proposalId};
 ok(await call(f.owner,f.base+'/commands','POST',{v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind:'shop.patch',base:{shopRevision:1,authorityEpoch:1},body:{quote:current.quote,lines:current.lines,mealEdit:edit}}));
 assert.equal(ok(await call(f.owner,path)).meals.length,1);
});
test('editing an approved idea invalidates submission and any pending shopper application',async()=>{
 const f=await mealFixture(),a=await approved(f);ok(await call(f.planner,f.changePath,'POST',a.proposal));
 ok(await call(f.planner,a.path,'POST',{...a.save,clientKey:randomUUID(),baseRevision:2,draft:{...a.save.draft,title:'New revision'}}));
 assert.equal((await call(f.planner,f.changePath,'POST',a.proposal)).data.error.code,'stale_idea');
 const edit={occurrenceId:a.proposal.occurrenceId,baseMealRevision:null,meal:a.proposal.meal,changeProposalId:a.proposal.proposalId};
 assert.equal((await call(f.owner,f.base+'/commands','POST',f.patch(2,edit))).data.error.code,'stale_idea');
 assert.equal(ok(await call(f.owner,f.path)).meals.length,1);
});
test('exact idea author, approved revision and quantities cannot be substituted',async()=>{
 const f=await mealFixture(),a=await approved(f);
 for(const proposal of [{...a.proposal,approvedIdeaRevision:1},{...a.proposal,approvedIdeaId:randomUUID()},{...a.proposal,meal:{...a.proposal.meal,portions:3}}])assert.equal((await call(f.planner,f.changePath,'POST',proposal)).status,409);
 assert.equal((await call(f.owner,f.changePath,'POST',a.proposal)).status,409);
 assert.equal((await call(f.planner,f.changePath,'POST',{...a.proposal,approvedIdeaId:undefined,approvedIdeaRevision:undefined})).status,422);
});
test('unassigned contributor and one-shop grant cannot read or approve; planner revocation stops retry',async()=>{
 const f=await mealFixture(),a=await approved(f),other=await actor();const invite=ok(await call(f.owner,f.base+'/invites','POST',{kind:'adult_contributor'}));
 other.id=ok(await call(other,'/v1/invites/redeem','POST',{token:invite.token,intent:'join',adultAttestation:true,alias:'Other adult'})).memberId;await enroll(other,f.h);
 // Preparation is synchronous app-owned template construction, not a server generation job.
 // Use a fresh, valid template-derived draft and then the exact adult-owned saved draft:
 // neither a malformed payload nor a stale revision may stand in for authority denial.
 const snapshot=async()=>({
  shop:ok(await call(f.owner,f.path)),
  ideas:(await admin.query('SELECT to_jsonb(i) AS row FROM ritc.shared_meal_idea i WHERE household_id=$1 AND shop_id=$2 ORDER BY idea_id',[f.h,f.shopId])).rows,
  receipts:(await admin.query('SELECT to_jsonb(r) AS row FROM ritc.shared_idea_receipt r WHERE household_id=$1 AND shop_id=$2 ORDER BY actor_id,client_key',[f.h,f.shopId])).rows
 });
 const before=await snapshot();
 assert.equal((await call(other,a.path)).status,404);
 assert.deepEqual(await snapshot(),before,'Denied read must leave idea, receipt and full shop state unchanged');
 const save={...a.save,clientKey:randomUUID(),ideaId:randomUUID(),draft:{...a.save.draft,title:'Fresh editable adult idea'}};
 assert.equal((await call(other,a.path,'POST',save)).status,404);
 assert.deepEqual(await snapshot(),before,'Ordinary contributor cannot save a prepared idea or create a receipt');
 const saved=ok(await call(f.planner,a.path,'POST',save));
 assert.equal(saved.ideaId,save.ideaId);assert.equal(saved.revision,1);assert.equal(saved.state,'draft');
 const afterSave=await snapshot();
 assert.deepEqual(afterSave.shop,before.shop,'Allowed adult draft save must not choose a meal or add lines');
 assert.equal(afterSave.ideas.length,before.ideas.length+1);assert.equal(afterSave.receipts.length,before.receipts.length+1);
 assert.equal(afterSave.ideas.find(value=>value.row.idea_id===save.ideaId).row.actor_id,f.planner.id);
 assert.deepEqual(ok(await call(f.planner,a.path,'POST',save)),saved);
 assert.deepEqual(await snapshot(),afterSave,'Exact allowed draft retry must add no idea or receipt');
 const approval={...save,clientKey:randomUUID(),baseRevision:saved.revision,action:'approve',reviewedHouseholdEvidence:true};
 assert.equal((await call(other,a.path,'POST',approval)).status,404);
 assert.deepEqual(await snapshot(),afterSave,'Ordinary contributor cannot approve the adult-owned idea or create a receipt');
 const accepted=ok(await call(f.planner,a.path,'POST',approval));
 assert.equal(accepted.ideaId,save.ideaId);assert.equal(accepted.revision,2);assert.equal(accepted.state,'approved');
 const afterApproval=await snapshot();
 assert.deepEqual(afterApproval.shop,before.shop,'Allowed adult approval must not choose a meal or add lines');
 assert.equal(afterApproval.ideas.length,afterSave.ideas.length);assert.equal(afterApproval.receipts.length,afterSave.receipts.length+1);
 assert.equal(afterApproval.ideas.find(value=>value.row.idea_id===save.ideaId).row.state,'approved');
 assert.equal(afterApproval.receipts.filter(value=>value.row.actor_id===other.id).length,0);
 assert.deepEqual(ok(await call(f.planner,a.path,'POST',approval)),accepted);
 assert.deepEqual(await snapshot(),afterApproval,'Exact allowed approval retry must add no idea, receipt, meal or line');
 assert.equal((await call(f.planner,a.path,'GET',undefined,{'X-View-Grant-ID':randomUUID()})).status,404);
 ok(await call(f.owner,f.path+'/meal-plan/planner','PUT',{authorityEpoch:1,grantRevision:1,plannerId:null}));
 assert.equal((await call(f.planner,a.path,'POST',a.approval)).status,404);assert.equal((await call(f.planner,f.changePath,'POST',a.proposal)).status,404);
});
test('deleting idea author erases drafts, approvals and retry receipts',async()=>{
 const f=await mealFixture(),a=await approved(f);await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.planner.id]);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_meal_idea WHERE household_id=$1',[f.h])).rows[0].n,0);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_idea_receipt WHERE household_id=$1',[f.h])).rows[0].n,0);
 assert.equal((await call(f.planner,f.changePath,'POST',a.proposal)).status,404);
});

test('exact fractional cups survive save edit approve proposal and shopper apply; ounce and fluid ounce remain distinct',async()=>{
 const f=await mealFixture(),draft=ideaDraft();Object.assign(draft.ingredients[0],{unit:'cup',required:{numerator:1,denominator:2},stock:{numerator:1,denominator:4},reservations:[{name:'Named lunch',amount:{numerator:1,denominator:8}}],pack:1,usableNumerator:1,usableDenominator:2});
 for(const unit of ['ounce','fluidOunce'])draft.ingredients.push({...draft.ingredients[0],id:randomUUID(),unit,name:unit,required:{numerator:1,denominator:3}});
 const a=await approved(f,f.planner,draft),page=ok(await call(f.planner,a.path)),idea=page.ideas[0];assert.deepEqual(idea.draft,draft);
 assert.deepEqual(idea.preview.ingredients[0].remaining,{numerator:1,denominator:8});assert.deepEqual(idea.preview.ingredients[0].shortage,{numerator:3,denominator:8});assert.equal(idea.preview.ingredients[0].wholePacks,1);
 ok(await call(f.planner,f.changePath,'POST',a.proposal));const exact=ok(await call(f.owner,f.changePath)).proposals[0].request.meal;assert.deepEqual(exact.planning.ingredients[0].quantity,{amount:{numerator:1,denominator:2},unit:'cup',originalLiteral:'1/2 cup'});
 assert.equal(exact.planning.ingredients[1].quantity.unit,'ounce');assert.equal(exact.planning.ingredients[2].quantity.unit,'fluidOunce');
 ok(await call(f.owner,f.base+'/commands','POST',f.patch(2,{occurrenceId:a.proposal.occurrenceId,baseMealRevision:null,meal:exact,changeProposalId:a.proposal.proposalId})));
 assert.deepEqual(ok(await call(f.owner,f.path)).meals.find(m=>m.occurrenceId===a.proposal.occurrenceId).meal,exact);
});

test('an approved meal keeps its reviewed restrictions and time through checkout and rejects conflicting delivered food',async()=>{
 const f=await mealFixture(),draft=ideaDraft();
 draft.exclusions=['sin sésamo','No nuts'];draft.minutes=1_000_000;
 const {proposal}=await approved(f,f.planner,draft);
 const plan=proposal.meal.planning;
 assert.deepEqual(plan.exclusions,draft.exclusions);assert.equal(plan.leadTimeMinutes,1_000_000);
 assert.deepEqual(plan.ingredients[0].exclusions,[]);assert.equal(plan.completedSteps,undefined);
 for(const changed of [{...plan,exclusions:undefined,leadTimeMinutes:undefined},{...plan,exclusions:undefined},{...plan,leadTimeMinutes:undefined},{...plan,exclusions:[...plan.exclusions].reverse()},
   {...plan,leadTimeMinutes:999_999},{...plan,completedSteps:['Already prepared']}]){
   const body={...proposal,meal:{...proposal.meal,planning:changed}};
   assert.equal((await call(f.planner,f.changePath,'POST',body)).data.error?.code,'stale_idea');
 }
 ok(await call(f.planner,f.changePath,'POST',proposal));
 const received=ok(await call(f.owner,f.changePath)).proposals[0].request.meal;
 assert.deepEqual(received,proposal.meal);
 const edit={occurrenceId:proposal.occurrenceId,baseMealRevision:null,meal:received,changeProposalId:proposal.proposalId};
 const applied=f.patch(2,edit),save=body=>call(f.owner,f.base+'/commands','POST',body);
 const receipt=ok(await save(applied));assert.deepEqual(ok(await save(applied)),receipt);
 const command=(kind,body,revision=4)=>({v:1,replayWindow:f.owner.window,shopId:f.shopId,clientKey:randomUUID(),
   kind,body,base:{shopRevision:revision,authorityEpoch:1}});
 ok(await save(command('shop.reportPlaced',{occurredAt:new Date().toISOString()},3)));
 const delivery=f.path+'/delivery-evidence';
 const sealed=ok(await call(f.owner,delivery)).meals.find(m=>m.occurrenceId===proposal.occurrenceId);
 assert.equal(sealed.revision,3);assert.deepEqual(sealed.meal,received);
 const {sourceId}=ok(await save(command('delivery.register',{supplyRevision:0,placedRevision:3,
   lineId:f.initial.lines[0].lineId,segmentKey:randomUUID(),foodName:'Rice mix',exclusionTags:['SÉSAMO']})));
 const match=command('delivery.match',{sourceId,supplyRevision:1,occurrenceId:sealed.occurrenceId,
   mealRevision:sealed.revision,ingredientId:plan.ingredients[0].id,matched:true});
 const rejected=await save(match);assert.equal(rejected.status,409);assert.equal(rejected.data.error.code,'match_exclusion_conflict');
 const unchanged=ok(await call(f.owner,delivery));assert.equal(unchanged.supplyRevision,1);assert.deepEqual(unchanged.sources[0].matches,[]);
 assert.equal((await admin.query('SELECT 1 FROM ritc.operation WHERE household_id=$1 AND client_key=$2',[f.h,match.clientKey])).rowCount,0);
 const quantity=plan.ingredients[0].quantity,arrival=randomUUID();
 ok(await save(command('delivery.arrival',{sourceId,supplyRevision:1,observationId:arrival,predecessorId:null,
   arrivedAt:new Date(Date.now()-1000).toISOString(),received:quantity})));
 ok(await save(command('delivery.usable',{sourceId,supplyRevision:2,observationId:randomUUID(),predecessorId:null,
   arrivalObservationId:arrival,confirmedAt:new Date().toISOString(),usable:quantity})));
 const need=ok(await call(f.owner,delivery+'/coverage')).needs.find(n=>n.occurrenceId===sealed.occurrenceId);
 assert.deepEqual(need.issues,['noMatch']);assert.deepEqual(need.allocations,[]);
 assert.equal(need.covered.numerator,'0');assert.equal(need.missing.numerator,'600');
});

test('an older pending idea proposal missing reviewed planning facts must be reviewed again before use',async()=>{
 const f=await mealFixture(),draft=ideaDraft();draft.exclusions=['No nuts'];
 const {proposal}=await approved(f,f.planner,draft);
 ok(await call(f.planner,f.changePath,'POST',proposal));
 const old=structuredClone(proposal);
 delete old.meal.planning.exclusions;delete old.meal.planning.leadTimeMinutes;
 // Reproduce the proposal body and fingerprint written before these fields existed.
 await admin.query('UPDATE ritc.shared_meal_change SET body=$3,fingerprint=$4 WHERE household_id=$1 AND proposal_id=$2',
   [f.h,proposal.proposalId,old,digest(old)]);
 const apply=(request,meal)=>call(f.owner,f.base+'/commands','POST',f.patch(2,{
   occurrenceId:request.occurrenceId,baseMealRevision:null,meal,changeProposalId:request.proposalId}));
 const snapshot=async()=>ok(await call(f.owner,f.changePath));
 const before=await snapshot();
 assert.deepEqual(ok(await call(f.planner,f.changePath,'POST',old)),{saved:true,proposalId:old.proposalId});
 assert.equal((await call(f.planner,f.changePath,'POST',{...old,reason:'Different request'})).status,409);
 assert.equal((await call(f.planner,f.changePath,'POST',{...old,proposalId:randomUUID()})).data.error.code,'stale_idea');
 assert.deepEqual(await snapshot(),before,'Historical receipt replay must not change the proposal or shop.');
 assert.equal((await apply(old,old.meal)).data.error?.code,'stale_idea');
 assert.equal((await apply(old,proposal.meal)).data.error?.code,'stale_proposal');
 const [unchanged]=ok(await call(f.owner,f.changePath)).proposals;
 assert.equal(unchanged.state,'pending');assert.deepEqual(unchanged.request,old);
 assert.equal(ok(await call(f.owner,f.path)).meals.length,1);
 const fresh={...proposal,proposalId:randomUUID()};
 ok(await call(f.planner,f.changePath,'POST',fresh));ok(await apply(fresh,fresh.meal));
 const page=ok(await call(f.owner,f.changePath));
 assert.deepEqual(page.proposals.find(p=>p.proposalId===old.proposalId).request,old);
 assert.equal(page.proposals.find(p=>p.proposalId===fresh.proposalId).state,'applied');
 ok(await call(f.owner,f.path+'/meal-plan/planner','PUT',{authorityEpoch:1,grantRevision:1,plannerId:null}));
 assert.equal((await call(f.planner,f.changePath,'POST',old)).status,404);
});

test('old idea proposal shape stays valid with no reviewed exclusions or time',async()=>{
 const f=await mealFixture(),draft=ideaDraft();draft.minutes=null;
 const {proposal,save}=await approved(f,f.planner,draft);
 assert.deepEqual(Object.keys(proposal.meal.planning).sort(),['groups','ingredients']);
 ok(await call(f.planner,f.changePath,'POST',proposal));
 const edit={occurrenceId:proposal.occurrenceId,baseMealRevision:null,meal:proposal.meal,changeProposalId:proposal.proposalId};
 const command=f.patch(2,edit),apply=()=>call(f.owner,f.base+'/commands','POST',command);
 const receipt=ok(await apply());
 assert.deepEqual(ok(await call(f.owner,f.path)).meals.find(m=>m.occurrenceId===proposal.occurrenceId).meal,proposal.meal);

 // Model an already-applied historical revision whose source idea had more facts.
 await admin.query('UPDATE ritc.shared_meal_idea SET draft=$3 WHERE household_id=$1 AND idea_id=$2',
   [f.h,save.ideaId,{...draft,minutes:25,exclusions:['No nuts']}]);
 assert.deepEqual(ok(await apply()),receipt);
 assert.deepEqual(ok(await call(f.planner,f.changePath,'POST',proposal)),{saved:true,proposalId:proposal.proposalId});
 const page=ok(await call(f.owner,f.changePath)),applied=page.proposals.find(p=>p.proposalId===proposal.proposalId);
 assert.equal(applied.state,'applied');assert.deepEqual(applied.request.meal,proposal.meal);
 assert.deepEqual(page.meals.find(m=>m.occurrenceId===proposal.occurrenceId).meal,proposal.meal);
});

test('accepted fallback registry separates idea approval and meal choice from an explicit cross-shop recipe disclosure',async()=>{
 const f=await mealFixture(),other=await f.shop(),path=f.path+'/accepted-fallbacks',remote=f.base+'/shops/'+other+'/accepted-fallbacks';
 const selected=ok(await call(f.owner,f.path)),approvedIdea=await approved(f);
 assert.equal(ok(await call(f.owner,path)).candidates.length,0);
 const source={kind:'idea',ideaId:approvedIdea.result.ideaId,revision:approvedIdea.result.revision};
 const review=ok(await call(f.owner,path+'/source','POST',{source})),r=review.recipe;
 assert.equal(r.ingredients[0].quantity.amount.numerator,600);assert.equal(r.ingredients[1].name,'Water');assert.equal(r.ingredients[1].quantity,null);
 for(const key of ['stock','reservations','evidence','pack'])assert(!Object.hasOwn(r.ingredients[0],key));
 const input={v:1,clientKey:randomUUID(),shopRevision:review.shopRevision,authorityEpoch:review.authorityEpoch,registryRevision:review.registryRevision,
   candidateId:randomUUID(),baseRevision:null,action:'accept',reviewed:true,source,recipe:r,usual:false};
 assert.equal((await call(f.owner,path,'POST',{...input,reviewed:false})).status,422);
 assert.equal((await call(f.owner,path,'POST',{...input,recipe:{...r,title:'Not the reviewed idea'}})).data.error.code,'stale_fallback');
 const [a,b]=await Promise.all([call(f.owner,path,'POST',input),call(f.owner,path,'POST',input)]);assert.deepEqual(ok(a),ok(b));
 assert.equal(a.data.revision,1);assert.equal(a.data.registryRevision,1);
 assert.equal((await call(f.owner,path,'POST',{...input,usual:true})).data.error.code,'key_reused');
 const visible=ok(await call(f.owner,remote));assert.deepEqual(visible.candidates,[{candidateId:input.candidateId,revision:1,recipe:r,usual:false}]);
 assert(!JSON.stringify(visible).includes(f.shopId));assert(!JSON.stringify(visible).includes(f.planner.id));assert(!JSON.stringify(visible).includes(source.ideaId));
 assert.equal((await call(f.owner,remote+'/source','POST',{source})).status,409);
 assert.equal((await call(f.owner,remote,'GET',undefined,{'X-Shop-ID':f.shopId})).status,404);
 assert.equal((await call(f.planner,path)).status,404);
 const sourceMeal={kind:'meal',occurrenceId:f.proposal.occurrenceId,mealRevision:2,revisionId:null};
 const meal=ok(await call(f.owner,path+'/source','POST',{source:sourceMeal}));
 assert.deepEqual(meal.recipe.groups.map(g=>g.protected),[false,true]);assert.deepEqual(meal.recipe.ingredients[0].bindings.map(b=>b.quantity.amount.numerator),[400,200]);
 const replace={...input,clientKey:randomUUID(),baseRevision:1,registryRevision:1,source:sourceMeal,recipe:meal.recipe,usual:true};
 const next=ok(await call(f.owner,path,'POST',replace));assert.equal(next.revision,2);
 const revoke={v:1,clientKey:randomUUID(),candidateId:input.candidateId,action:'revoke',reviewed:true,shopRevision:2,authorityEpoch:1,baseRevision:2,registryRevision:2};
 assert.equal((await call(f.owner,path,'POST',{...revoke,baseRevision:1})).data.error.code,'stale_fallback');
 assert.equal(ok(await call(f.owner,path,'POST',revoke)).accepted,false);
 assert.deepEqual(ok(await call(f.owner,remote)).candidates,[]);
 assert.deepEqual(ok(await call(f.owner,path,'POST',input)),a.data);
 assert.deepEqual((await admin.query('SELECT revision,accepted,recipe IS NOT NULL AS present FROM ritc.accepted_fallback_revision WHERE household_id=$1 ORDER BY revision',[f.h])).rows,
   [{revision:1,accepted:true,present:true},{revision:2,accepted:true,present:true},{revision:3,accepted:false,present:false}]);
 assert.deepEqual(ok(await call(f.owner,f.path)),selected);
 const free=await fixture();assert.deepEqual(ok(await call(free.owner,free.base+'/shops/'+free.shopId+'/accepted-fallbacks')).candidates,[]);
 const outsider=await fixture();assert.equal((await call(outsider.owner,path)).status,404);
});

test('accepted fallback registry preserves per-ingredient notes and rejects stale approvals, guessed groups and unauthorized replay',async()=>{
 const f=await mealFixture(),path=f.path+'/accepted-fallbacks',receipt=ok(await call(f.owner,path));
 const qty=n=>({amount:{numerator:n,denominator:1},unit:'gram',originalLiteral:String(n)}),group=randomUUID();
 const recipe={title:'One deliberately shared home recipe',notes:'Finish slowly.',portions:2,exclusions:['sesame'],elapsedMinutes:20,requiredLeadMinutes:null,sourceURL:null,
   groups:[{id:group,name:'Almuerzo',servings:{numerator:2,denominator:1},protected:true,exclusions:[]}],
   ingredients:[{id:randomUUID(),name:'Beans',notes:'  Remojar.\nEscurrir.  ',quantity:qty(4),exclusions:[],groupIds:[group],bindings:[{groupId:group,quantity:qty(4)}]}]};
 const input={v:1,clientKey:randomUUID(),action:'accept',reviewed:true,registryRevision:receipt.registryRevision,shopRevision:receipt.shopRevision,
   authorityEpoch:1,candidateId:randomUUID(),baseRevision:null,usual:true,recipe,source:{kind:'disclosed'}};
 const wrong=structuredClone(input);wrong.recipe.ingredients[0].bindings[0].quantity=qty(5);
 assert.equal((await call(f.owner,path,'POST',wrong)).status,422);
 const prior=ok(await call(f.owner,path,'POST',input));assert.equal(prior.revision,1);assert.deepEqual(ok(await call(f.owner,path)).candidates[0].recipe,recipe);
 const sibling={...input,candidateId:randomUUID(),clientKey:randomUUID()};
 assert.equal((await call(f.owner,path,'POST',sibling)).data.error.code,'stale_fallback');
 assert.equal((await call(f.owner,path,'POST',{...sibling,registryRevision:1})).data.error.code,'usual_fallback_exists');
 const newDevice={...f.owner};await enroll(newDevice,f.h);assert.equal((await call(newDevice,path,'POST',input)).status,409);
 ok(await call(f.owner,f.base+'/commands','POST',{v:1,clientKey:randomUUID(),replayWindow:f.owner.window,shopId:f.shopId,kind:'shop.transferAuthority',
   base:{shopRevision:2,authorityEpoch:1},body:{newShopperId:f.planner.id}}));
 assert.equal((await call(f.owner,path,'POST',input)).status,404);assert.equal((await call(f.owner,path)).status,404);
 const current=ok(await call(f.planner,path));assert.equal(current.candidates[0].candidateId,input.candidateId);
 await admin.query('DELETE FROM ritc.billing_seat WHERE household_id=$1',[f.h]);
 assert.equal(ok(await call(f.planner,path)).candidates[0].recipe.title,recipe.title);
 assert.equal((await call(f.planner,path+'/source','POST',{source:{kind:'meal',occurrenceId:f.proposal.occurrenceId,mealRevision:2,revisionId:null}})).data.error.code,'membership_inactive');
 assert.equal((await call(f.planner,path,'POST',{...input,clientKey:randomUUID(),authorityEpoch:current.authorityEpoch,shopRevision:current.shopRevision})).data.error.code,'membership_inactive');
 const withdraw={v:1,clientKey:randomUUID(),action:'revoke',candidateId:input.candidateId,baseRevision:1,reviewed:true,
   authorityEpoch:current.authorityEpoch,shopRevision:current.shopRevision,registryRevision:current.registryRevision};
 assert.equal(ok(await call(f.planner,path,'POST',withdraw)).accepted,false);
 assert.deepEqual(ok(await call(f.planner,path)).candidates,[]);
 await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.owner.id]);
 assert.deepEqual(ok(await call(f.planner,path)).candidates,[]);
 const stored=(await admin.query('SELECT recipe,source,fingerprint FROM ritc.accepted_fallback_revision WHERE household_id=$1 AND candidate_id=$2 AND revision=1',[f.h,input.candidateId])).rows[0];
 assert.deepEqual(stored,{recipe:null,source:null,fingerprint:null});
});

test('accepted fallback registry paginates whole recipes within native read bounds and checks exact named servings',async()=>{
 const f=await mealFixture(),path=f.path+'/accepted-fallbacks';
 const recipe={title:'Review one recipe',portions:2,notes:'',sourceURL:null,requiredLeadMinutes:null,elapsedMinutes:null,exclusions:[],
   ingredients:[{id:randomUUID(),name:'Beans',quantity:null,exclusions:[]}]};
 const input={v:1,action:'accept',clientKey:randomUUID(),candidateId:randomUUID(),shopRevision:2,authorityEpoch:1,registryRevision:0,baseRevision:null,
   reviewed:true,source:{kind:'disclosed'},recipe,usual:false};
 const groups=[{id:randomUUID(),name:'Lunch',protected:true,exclusions:[],servings:{numerator:5,denominator:2}}];
 assert.equal((await call(f.owner,path,'POST',{...input,recipe:{...recipe,groups}})).status,422);
 assert.equal((await call(f.owner,path,'POST',{...input,recipe:{...recipe,notes:'Control\u0000'}})).status,422);
 const ids=[];
 for(let i=0;i<21;i++){ids.push(randomUUID());ok(await call(f.owner,path,'POST',{...input,registryRevision:i,clientKey:randomUUID(),candidateId:ids[i]}));}
 let page=ok(await call(f.owner,path));assert.deepEqual(page.candidates.map(c=>c.candidateId),ids.sort().slice(0,20));assert.equal(page.nextCursor,ids[19]);
 const end=ok(await call(f.owner,path+'?cursor='+page.nextCursor));assert.deepEqual(end.candidates.map(c=>c.candidateId),ids.slice(20));assert.equal(end.nextCursor,null);
 assert.equal(end.registryRevision,page.registryRevision);
 assert.equal((await call(f.owner,path+'?cursor='+randomUUID())).data.error.code,'stale_fallback');
 const large={...recipe,ingredients:Array.from({length:60},()=>({id:randomUUID(),name:'Rice',notes:'x'.repeat(7500),quantity:null,exclusions:[]}))};
 for(let i=0;i<4;i++)ok(await call(f.owner,path,'POST',{...input,registryRevision:21+i,recipe:large,clientKey:randomUUID(),candidateId:randomUUID()}));
 const seen=new Set();let cursor=null;
 do{
   page=ok(await call(f.owner,path+(cursor?'?cursor='+cursor:'')));
   assert.equal(page.registryRevision,25);assert(Buffer.byteLength(JSON.stringify(page))<2000000);
   for(const c of page.candidates){assert(!seen.has(c.candidateId));seen.add(c.candidateId);}
   cursor=page.nextCursor;if(cursor)assert.equal(cursor,page.candidates.at(-1).candidateId);
 }while(cursor);
 assert.equal(seen.size,25);
});

test('approved shared idea can be selected with unknown night before a separate date proposal',async()=>{
 const f=await mealFixture(),a=await approved(f),before=ok(await call(f.owner,f.path));
 const proposal={...a.proposal,meal:{...a.proposal.meal,day:null}};
 const submitted=ok(await call(f.planner,f.changePath,'POST',proposal));
 assert.deepEqual(ok(await call(f.planner,f.changePath,'POST',proposal)),submitted);
 assert.deepEqual(ok(await call(f.owner,f.path)),before);
 const edit={occurrenceId:proposal.occurrenceId,baseMealRevision:null,meal:proposal.meal,changeProposalId:proposal.proposalId};
 const command=f.patch(2,edit),receipt=ok(await call(f.owner,f.base+'/commands','POST',command));
 assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',command)),receipt);
 const selected=ok(await call(f.owner,f.path)),occurrence=selected.meals.find(m=>m.occurrenceId===proposal.occurrenceId);
 assert.deepEqual(occurrence.meal,proposal.meal);assert.deepEqual(selected.lines,before.lines);
 assert.equal(selected.meals.at(-1).occurrenceId,proposal.occurrenceId,'Unknown nights sort after dated occurrences');
 const move={proposalId:randomUUID(),occurrenceId:proposal.occurrenceId,day:'2099-11-01',shopRevision:3,authorityEpoch:1,grantRevision:1};
 ok(await call(f.planner,f.path+'/meal-plan/proposals','POST',move));
 const scheduled={...proposal.meal,day:move.day};
 ok(await call(f.owner,f.base+'/commands','POST',f.patch(3,{occurrenceId:move.occurrenceId,baseMealRevision:3,meal:scheduled,proposalId:move.proposalId})));
 const after=ok(await call(f.owner,f.path));assert.equal(after.meals.length,selected.meals.length);
 assert.deepEqual(after.meals.find(m=>m.occurrenceId===move.occurrenceId).meal,scheduled);
 assert.deepEqual(after.lines,before.lines);
});
