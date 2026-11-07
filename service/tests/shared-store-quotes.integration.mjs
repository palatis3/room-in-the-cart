import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {randomUUID,randomBytes} from 'node:crypto';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {migrate} from '../scripts/migrate.mjs';
import {HouseholdRepository} from '../dist/repository.js';
import {assertRuntimeRole} from '../dist/database.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {createHTTPServer} from '../dist/http.js';
import {PrivacyService,PrivacyMaintenance} from '../dist/privacy.js';
import {openPrivacyJournalFixture} from './privacy-journal-fixture.mjs';

const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL});
const runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
const workerURL=new URL(process.env.TEST_DATABASE_URL??'postgresql://localhost/ritc_unconfigured');workerURL.username='ritc_test_worker';
const worker=new pg.Pool({connectionString:workerURL.toString()});
const issuer='https://store-quotes.fixture.invalid',audience='authenticated';
const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='store-quotes';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/keys'},createLocalJWKSet({keys:[jwk]}));
const repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
const journal=await openPrivacyJournalFixture(admin);
const provider={assertAvailable:async()=>{},deleteAccount:async subject=>{await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);}};
const privacy=new PrivacyService(repo,{provider,journal:journal.port,policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1}});
const maintenance=new PrivacyMaintenance(worker,{provider,journal:journal.port});
const server=createHTTPServer({repository:repo,verifier,privacy,maxRequestsPerMinute:20000});let origin;
before(async()=>{
 for(const value of [process.env.TEST_ADMIN_DATABASE_URL,process.env.TEST_DATABASE_URL]){
  if(!value)throw Error('Explicit isolated local PostgreSQL URLs required');
  const url=new URL(value);if(!['localhost','127.0.0.1','[::1]'].includes(url.hostname)||!url.pathname.startsWith('/ritc_'))throw Error('Local isolated ritc_ database required');
 }
 await admin.query('CREATE SCHEMA IF NOT EXISTS auth; CREATE TABLE IF NOT EXISTS auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
 await migrate(process.env.TEST_ADMIN_DATABASE_URL);await assertRuntimeRole(runtime);
 const workerRole=(await admin.query("SELECT rolcanlogin,rolsuper,rolbypassrls,pg_has_role(oid,'ritc_worker','MEMBER') AS worker,pg_has_role(oid,'ritc_app','MEMBER') AS app FROM pg_roles WHERE rolname='ritc_test_worker'")).rows[0];
 assert.ok(workerRole?.rolcanlogin&&workerRole.worker&&!workerRole.app&&!workerRole.rolsuper&&!workerRole.rolbypassrls,'Configure the distinct existing local worker before running this fixture; no roles or memberships are changed.');
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;
});
after(async()=>{await new Promise(resolve=>server.close(resolve));await journal.close();await Promise.all([admin.end(),runtime.end(),worker.end()]);});
async function actor(){
 const subject=randomUUID(),session=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);
 const token=await new SignJWT({session_id:session,amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)}]}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience(audience).setIssuedAt().setExpirationTime('1h').sign(privateKey);
 return{subject,session,token};
}
async function call(a,path,method='GET',body,headers={}){
 const response=await fetch(origin+path,{method,headers:{Authorization:'Bearer '+a.token,...(a.device?{'X-Device-Token':a.device}:{}),...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})});
 return{status:response.status,data:await response.json()};
}
function ok(response,status=200){assert.equal(response.status,status,JSON.stringify(response.data));return response.data;}
async function enroll(a,h){a.device=ok(await call(a,`/v1/households/${h}/devices`,'POST',{}),201).deviceToken;a.window=ok(await call(a,`/v1/households/${h}/replay-windows`,'POST',{})).id;}
function entered(){
 const first={label:'First store',store:'Store A',branch:'A1',mode:'pickup',slot:new Date(Date.now()+3600000).toISOString(),observedAt:new Date(Date.now()-60000).toISOString(),
  source:'Manually reviewed complete quote',currency:'USD',terms:'No membership needed. Fees, taxes, deposits and discounts included.',itemsMinor:3600,checkoutMinor:3800,allChargesIncluded:true,
  available:true,quantitiesMatched:true,singleStore:true,tripAlreadyPlanned:true,tripMinor:0,extraMinutes:0,capMinor:3800,capScope:'wholeCheckout',eligibilityConfirmed:true};
 return{first,second:{...first,label:'Second store',store:'Store B',branch:'B1',itemsMinor:3200,checkoutMinor:3500,tripAlreadyPlanned:false,tripMinor:400,extraMinutes:18}};
}
async function fixture(){
 const owner=await actor(),created=ok(await call(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'Private quote fixture',alias:'Shopper',adultAttestation:true}),201);
 const h=created.householdId,base=`/v1/households/${h}`;owner.id=created.memberId;await enroll(owner,h);
 const shopId=randomUUID(),path=base+'/shops/'+shopId,quotes=path+'/store-quotes';
 const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:3800,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:100},taxesMinor:100,depositsMinor:0,discountsMinor:0,
  observedAt:new Date(Date.now()-60000).toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()};
 const lines=[{lineId:randomUUID(),originalItem:'Six wraps and protected lunch',packs:2,unitPriceMinor:1800,feeEligible:true}];
 const command=(kind,body,revision=1,epoch=1)=>({v:1,clientKey:randomUUID(),replayWindow:owner.window,shopId,kind,base:{shopRevision:revision,authorityEpoch:epoch},body});
 ok(await call(owner,base+'/commands','POST',command('shop.create',{quote,lines},0,0)));
 async function join(alias='Budget adult'){
  const adult=await actor(),invitation=ok(await call(owner,base+'/invites','POST',{kind:'adult_contributor'}));
  adult.id=ok(await call(adult,'/v1/invites/redeem','POST',{token:invitation.token,intent:'join',adultAttestation:true,alias})).memberId;await enroll(adult,h);return adult;
 }
 const input=(extra={},revision=1,epoch=1,grantRevision=0)=>({operationId:randomUUID(),shopRevision:revision,authorityEpoch:epoch,grantRevision,...extra});
 async function grant(adult,enabled=true,targetRevision=0,revision=1,epoch=1){return ok(await call(owner,quotes+'/grants','POST',input({adultId:adult.id,enabled,targetRevision},revision,epoch)));}
 async function save(a=owner,options=entered(),revision=1,epoch=1,grantRevision=0){const body=input({options},revision,epoch,grantRevision);return{body,receipt:ok(await call(a,quotes+'/pairs','POST',body)),pairId:body.operationId};}
 return{owner,h,base,shopId,path,quotes,quote,lines,command,join,input,grant,save};
}

test('Free grants are per-adult and independent of contribution, paid seats, meal roles or administration',async()=>{
 const f=await fixture(),adult=await f.join();
 assert.equal((await call(adult,f.quotes)).status,404);
 await admin.query('UPDATE ritc.member SET can_contribute=false WHERE household_id=$1 AND member_id=$2',[f.h,adult.id]);
 await f.grant(adult);
 const view=ok(await call(adult,f.quotes,'GET',undefined,{'X-Shop-ID':f.shopId}));assert.equal(view.shopper,false);assert.equal(view.grantRevision,1);assert.deepEqual(view.adults,[]);assert.deepEqual(view.commitments,[{id:f.lines[0].lineId,label:f.lines[0].originalItem,packs:2}]);
 const boot=ok(await call(adult,f.base+'/bootstrap','GET',undefined,{'X-Shop-ID':f.shopId}));assert.ok(boot.capabilities.includes('store_quotes'));assert.equal(boot.capabilities.includes('shopper_commands'),false);assert.equal(boot.capabilities.includes('meal_proposals'),false);
 assert.ok(ok(await call(adult,f.base+'/shops')).shops.some(s=>s.shopId===f.shopId));
 assert.equal((await call(adult,f.path)).status,404);assert.equal((await call(adult,f.quotes+'/grants','POST',f.input({adultId:f.owner.id,enabled:true,targetRevision:0},1,1,1))).status,404);
 assert.equal((await call(adult,f.path+'/meal-plan')).status,404);
 await admin.query('UPDATE ritc.member SET organizer=true WHERE household_id=$1 AND member_id=$2',[f.h,adult.id]);
 await f.grant(adult,false,1);assert.equal((await call(adult,f.quotes)).status,404);
});

test('unselected budget discovery finds an oldest third shop despite a separate cook link',async()=>{
 const f=await fixture(),adult=await f.join(),newer=[];
 for(let i=0;i<2;i++){
  const shopId=randomUUID();newer.push(shopId);
  const creation={...f.command('shop.create',{quote:f.quote,lines:f.lines},0,0),shopId};
  ok(await call(f.owner,f.base+'/commands','POST',creation));
 }
 const view=ok(await call(f.owner,f.base+'/views','POST',{shopId:newer[1],mode:'read',shopLabel:'Cook instructions',language:'en',items:[{label:'Wraps',amount:'two',unit:'packs',action:'Reserve lunch'}]}));
 const attached=ok(await call(adult,'/v1/invites/redeem','POST',{token:view.token,intent:'join',adultAttestation:true,alias:'Adult with cook link'}));assert.equal(attached.memberId,adult.id);
 const helper=ok(await call(adult,f.base+'/bootstrap'));assert.equal(helper.role,'helper');assert.equal(helper.grantId,view.grantId);
 await f.grant(adult);
 const bootstrap=ok(await call(adult,f.base+'/bootstrap'));
 assert.equal(bootstrap.canSelectShop,true);assert.equal(bootstrap.selectionRequired,true);assert.equal(bootstrap.role,'contributor');assert.equal(bootstrap.shopId,null);assert.equal(bootstrap.grantId,undefined);
 assert.equal(bootstrap.capabilities.includes('helper_view'),false);assert.equal(bootstrap.capabilities.includes('store_quotes'),false);
 const shops=ok(await call(adult,f.base+'/shops'));
 assert.equal(shops.shops.length,3);assert.equal(shops.shops[2].shopId,f.shopId);assert.equal(JSON.stringify(shops).includes('capMinor'),false);
 const selected=ok(await call(adult,f.base+'/bootstrap','GET',undefined,{'X-Shop-ID':f.shopId}));
 assert.equal(selected.shopId,f.shopId);assert.equal(selected.role,'contributor');assert.equal(selected.grantId,undefined);assert.ok(selected.capabilities.includes('store_quotes'));
 const quotes=ok(await call(adult,f.quotes,'GET',undefined,{'X-Shop-ID':f.shopId}));assert.equal(quotes.grantRevision,1);assert.equal(quotes.shopper,false);
 const save=f.input({options:entered()},1,1,1);ok(await call(adult,f.quotes+'/pairs','POST',save,{'X-Shop-ID':f.shopId}));
 assert.equal(ok(await call(adult,f.quotes,'GET',undefined,{'X-Shop-ID':f.shopId})).pairs[0].pairId,save.operationId);
 assert.equal((await call(adult,f.base+'/shops/'+newer[1]+'/store-quotes','GET',undefined,{'X-Shop-ID':newer[1]})).status,404);
 const explicitHelper=ok(await call(adult,f.base+'/bootstrap','GET',undefined,{'X-View-Grant-ID':view.grantId}));
 assert.equal(explicitHelper.role,'helper');assert.equal(explicitHelper.canSelectShop,false);assert.equal(explicitHelper.capabilities.includes('store_quotes'),false);
});

test('private saves require explicit proposal; only current shopper adopts an exact submitted choice once',async()=>{
 const f=await fixture(),adult=await f.join(),other=await f.join('Other private adult');await f.grant(adult);await f.grant(other);
 const before=ok(await call(f.owner,f.path)),saved=await f.save(adult,entered(),1,1,1);
 const personal=ok(await call(adult,f.quotes));assert.equal(personal.pairs.length,1);assert.equal(personal.pairs[0].stale,false);
 assert.deepEqual(ok(await call(f.owner,f.quotes)).pairs,[]);assert.deepEqual(ok(await call(other,f.quotes)).pairs,[]);assert.deepEqual(ok(await call(f.owner,f.path)),before);
 const proposal=f.input({pairId:saved.pairId,choice:'second'},1,1,1);ok(await call(adult,f.quotes+'/proposals','POST',proposal));
 assert.equal(ok(await call(f.owner,f.quotes)).pairs[0].proposals[0].proposalId,proposal.operationId);
 const adoption=f.input({pairId:saved.pairId,choice:'second',proposalId:proposal.operationId});
 assert.equal((await call(adult,f.quotes+'/adoptions','POST',{...adoption,grantRevision:1})).status,404);
 assert.equal((await call(f.owner,f.quotes+'/adoptions','POST',{...adoption,choice:'first'})).status,404);
 const responses=await Promise.all([call(f.owner,f.quotes+'/adoptions','POST',adoption),call(f.owner,f.quotes+'/adoptions','POST',adoption)]);
 assert.deepEqual(ok(responses[1]),ok(responses[0]));assert.equal(responses[0].data.shopRevision,2);
 const after=ok(await call(f.owner,f.path));assert.equal(after.shopRevision,2);assert.equal(after.lines[0].unitPriceMinor,null);assert.equal(after.quote.fee.amountMinor,null);assert.equal(after.quote.taxesMinor,null);assert.equal(after.quote.discountsMinor,null);assert.equal(after.quote.complete,false);
 assert.equal(ok(await call(f.owner,f.quotes)).currentBasis.branch,'B1');assert.equal(ok(await call(adult,f.quotes)).pairs[0].stale,true);
 assert.deepEqual(ok(await call(adult,f.quotes+'/pairs','POST',saved.body)),saved.receipt);
 assert.equal((await call(adult,f.quotes+'/pairs','POST',{...saved.body,options:{...saved.body.options,second:{...saved.body.options.second,tripMinor:399}}})).data.error.code,'operation_conflict');
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.store_quote_adoption WHERE household_id=$1',[f.h])).rows[0].n,1);
});

test('store adoption invalidates request previews and freeze until an explicit review at the chosen basis',async()=>{
 const f=await fixture(),adult=await f.join();
 const request=ok(await call(adult,f.base+'/commands','POST',{v:1,clientKey:randomUUID(),replayWindow:adult.window,shopId:f.shopId,kind:'request.send',base:{shopRevision:1,authorityEpoch:1},body:{clientRequestId:randomUUID(),originalItem:'Cereal',ownQuantity:'one box',route:'current',authoredAt:new Date().toISOString()}}));
 const requestId=request.request.requestId,preview=ok(await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:1,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:f.lines[0].lineId}}));
 const saved=await f.save(),adoption=f.input({pairId:saved.pairId,choice:'first',proposalId:null});ok(await call(f.owner,f.quotes+'/adoptions','POST',adoption));
 const apply=f.command('request.apply',{requestId,previewId:preview.previewId,acceptOverage:false,acceptUnknown:true},2);apply.base.requestRevision=1;
 assert.equal((await call(f.owner,f.base+'/commands','POST',apply)).data.error.code,'stale_preview');
 assert.equal((await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:2,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:f.lines[0].lineId}})).data.error.code,'stale_quote');
 assert.equal((await call(f.owner,f.base+'/commands','POST',f.command('shop.freeze',{},2))).data.error.code,'store_review_required');
 const current=ok(await call(f.owner,f.path));
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.patch',{lines:current.lines,quote:f.quote},2)));
 assert.equal((await call(f.owner,f.base+'/commands','POST',f.command('shop.freeze',{},3))).data.error.code,'store_review_required');
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.patch',{lines:f.lines,quote:f.quote,reviewedStoreBasisRevision:2},3)));
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.freeze',{},4)));
 assert.deepEqual(ok(await call(f.owner,f.quotes+'/adoptions','POST',adoption)),{operationId:adoption.operationId,shopRevision:2});
 assert.equal((await call(f.owner,f.quotes+'/adoptions','POST',f.input({pairId:saved.pairId,choice:'first',proposalId:null},5))).data.error.code,'checkout_locked');
});

test('matching store review saves unknown or expired draft costs while only a complete current reprice unlocks freeze',async()=>{
 const f=await fixture(),saved=await f.save();
 ok(await call(f.owner,f.quotes+'/adoptions','POST',f.input({pairId:saved.pairId,choice:'second',proposalId:null})));
 const adopted=ok(await call(f.owner,f.path)),basis=adopted.storeBasisRevision;
 const partial={lines:adopted.lines,quote:{...f.quote,complete:false,taxesMinor:null},reviewedStoreBasisRevision:basis};
 const wrong=await call(f.owner,f.base+'/commands','POST',f.command('shop.patch',{...partial,reviewedStoreBasisRevision:basis+1},2));
 assert.equal(wrong.status,409);assert.equal(wrong.data.error.code,'store_review_required');assert.equal(ok(await call(f.owner,f.path)).shopRevision,2);
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.patch',partial,2)));
 const draft=ok(await call(f.owner,f.path));assert.equal(draft.shopRevision,3);assert.equal(draft.storeReviewRequired,true);assert.equal(draft.quote.taxesMinor,null);assert.equal(draft.lines[0].unitPriceMinor,null);
 assert.equal((await call(f.owner,f.base+'/commands','POST',f.command('shop.freeze',{},3))).data.error.code,'store_review_required');
 const expired={...f.quote,observedAt:new Date(Date.now()-120000).toISOString(),expiresAt:new Date(Date.now()-60000).toISOString()};
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.patch',{lines:f.lines,quote:expired,reviewedStoreBasisRevision:basis},3)));
 assert.equal(ok(await call(f.owner,f.path)).storeReviewRequired,true);
 assert.equal((await call(f.owner,f.base+'/commands','POST',f.command('shop.freeze',{},4))).data.error.code,'store_review_required');
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.patch',{lines:f.lines,quote:f.quote,reviewedStoreBasisRevision:basis},4)));
 assert.equal(ok(await call(f.owner,f.path)).storeReviewRequired,false);
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.freeze',{},5)));
 assert.equal(ok(await call(f.owner,f.path)).phase,'frozen');
});

test('unknown fees, unavailable packages, unmatched quantities and missing eligibility never produce a winner',async()=>{
 const f=await fixture();
 for(const patch of [{allChargesIncluded:false},{available:null},{available:false},{quantitiesMatched:false},{singleStore:false},{eligibilityConfirmed:false}]){
  const options=entered();Object.assign(options.second,patch);const saved=await f.save(f.owner,options),view=ok(await call(f.owner,f.quotes));
  assert.equal(view.pairs.find(p=>p.pairId===saved.pairId).comparison.preferred,null);
  if(patch.allChargesIncluded===false)assert.equal(view.pairs.find(p=>p.pairId===saved.pairId).comparison.secondCheckout,null);
  if(patch.allChargesIncluded!==false)assert.equal((await call(f.owner,f.quotes+'/adoptions','POST',f.input({pairId:saved.pairId,choice:'second',proposalId:null}))).data.error.code,'unreviewed_coverage');
 }
 const options=entered();options.second.tripMinor=null;const saved=await f.save(f.owner,options),pair=ok(await call(f.owner,f.quotes)).pairs.find(p=>p.pairId===saved.pairId);
 assert.equal(pair.comparison.secondBreakEven,300);assert.equal(pair.comparison.preferred,null);assert.equal(pair.comparison.cashDelta,null);assert.equal(pair.comparison.minutesDelta,18);
});

test('revocation, regrant and shopper transfer reject old proposals and successful retries without resurrecting authority',async()=>{
 const f=await fixture(),adult=await f.join();await f.grant(adult);const saved=await f.save(adult,entered(),1,1,1),proposal=f.input({pairId:saved.pairId,choice:'second'},1,1,1);
 ok(await call(adult,f.quotes+'/proposals','POST',proposal));await f.grant(adult,false,1);
 assert.equal((await call(adult,f.quotes+'/pairs','POST',saved.body)).status,404);assert.deepEqual(ok(await call(f.owner,f.quotes)).pairs,[]);
 await f.grant(adult,true,2);
 assert.equal((await call(adult,f.quotes+'/pairs','POST',saved.body)).data.error.code,'stale_base');assert.equal(ok(await call(adult,f.quotes)).pairs[0].stale,true);
 assert.equal((await call(f.owner,f.quotes+'/adoptions','POST',f.input({pairId:saved.pairId,choice:'second',proposalId:proposal.operationId}))).status,404);
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.transferAuthority',{newShopperId:adult.id})));
 assert.equal((await call(f.owner,f.quotes)).status,404);assert.equal(ok(await call(adult,f.quotes)).authorityEpoch,2);
 assert.equal((await call(adult,f.quotes+'/proposals','POST',proposal)).data.error.code,'stale_base');
});

test('frozen and placed shops preserve dated proof but refuse new save/proposal/adoption; revocation remains available',async()=>{
 const f=await fixture(),adult=await f.join();await f.grant(adult);const saved=await f.save(adult,entered(),1,1,1);
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.freeze',{})));
 assert.equal(ok(await call(adult,f.quotes)).phase,'frozen');assert.equal(ok(await call(adult,f.quotes)).pairs[0].stale,true);
 for(const [action,extra] of [['pairs',{options:entered()}],['proposals',{pairId:saved.pairId,choice:'second'}]])assert.equal((await call(adult,f.quotes+'/'+action,'POST',f.input(extra,2,1,1))).data.error.code,'checkout_locked');
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.reportPlaced',{occurredAt:new Date().toISOString()},2)));
 assert.equal(ok(await call(adult,f.quotes)).phase,'placed');await f.grant(adult,false,1,3);assert.equal((await call(adult,f.quotes)).status,404);
});

test('tenant scope, helper grants, children and cross-shop cursors cannot reveal private quote content',async()=>{
 const f=await fixture(),saved=await f.save(),foreign=await fixture();assert.equal((await call(foreign.owner,f.quotes)).status,404);
 const projection={shopLabel:'Cook only',language:'en',items:[{label:'Wraps',amount:'two',unit:'packs',action:'Reserve lunch'}]};
 const grant=ok(await call(f.owner,f.base+'/views','POST',{shopId:f.shopId,mode:'read',...projection})),helper=await actor();
 helper.id=ok(await call(helper,'/v1/invites/redeem','POST',{token:grant.token,intent:'join',adultAttestation:true,alias:'Cook'})).memberId;await enroll(helper,f.h);
 assert.equal((await call(helper,f.quotes)).status,404);await f.grant(helper);
 assert.equal((await call(helper,f.quotes,'GET',undefined,{'X-View-Grant-ID':grant.grantId})).status,404);ok(await call(helper,f.quotes));
 const child=await f.join('Child fixture');await admin.query("UPDATE ritc.member SET kind='child' WHERE household_id=$1 AND member_id=$2",[f.h,child.id]);
 assert.equal((await call(child,f.quotes)).status,403);
 const outsider=await foreign.save();assert.equal((await call(f.owner,f.quotes+'?cursor='+outsider.pairId)).status,404);
 const db=await runtime.connect();try{await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[foreign.h]);assert.equal((await db.query('SELECT * FROM ritc.store_quote_pair WHERE pair_id=$1',[saved.pairId])).rowCount,0);await db.query('ROLLBACK');}finally{db.release();}
});

test('proposal/adoption transaction rolls back if its durable receipt cannot be stored',async()=>{
 const f=await fixture(),saved=await f.save(),adoption=f.input({pairId:saved.pairId,choice:'second',proposalId:null}),functionName='s27_receipt_fault_'+randomUUID().replaceAll('-','');
 await admin.query(`CREATE FUNCTION ritc.${functionName}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.operation_id='${adoption.operationId}'::uuid THEN RAISE EXCEPTION 'injected local receipt failure'; END IF; RETURN NEW; END $$`);
 await admin.query(`CREATE TRIGGER ${functionName} BEFORE INSERT ON ritc.store_quote_mutation FOR EACH ROW EXECUTE FUNCTION ritc.${functionName}()`);
 try{assert.equal((await call(f.owner,f.quotes+'/adoptions','POST',adoption)).status,503);assert.equal(ok(await call(f.owner,f.path)).shopRevision,1);assert.equal(ok(await call(f.owner,f.quotes)).currentBasis,null);assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.store_quote_adoption WHERE household_id=$1',[f.h])).rows[0].n,0);}
 finally{await admin.query(`DROP TRIGGER ${functionName} ON ritc.store_quote_mutation; DROP FUNCTION ritc.${functionName}()`);}
 assert.equal(ok(await call(f.owner,f.quotes+'/adoptions','POST',adoption)).shopRevision,2);
});

// Shared integration fixtures can leave earlier jobs eligible for the same worker.
async function finishDeletion(receipt) {
 const until=Date.now()+10000;
 do {
  await maintenance.run({batchSize:1});
  if ((await privacy.status(receipt.clientKey,receipt.statusToken)).status==='complete') return;
 } while(Date.now()<until);
 assert.fail('The submitted deletion receipt did not reach complete');
}

test('real account deletion worker removes proposed/adopted private pair, copies, grant and retries without restoring old prices',async()=>{
 const f=await fixture(),adult=await f.join();await f.grant(adult);const saved=await f.save(adult,entered(),1,1,1),proposal=f.input({pairId:saved.pairId,choice:'second'},1,1,1);
 ok(await call(adult,f.quotes+'/proposals','POST',proposal));ok(await call(f.owner,f.quotes+'/adoptions','POST',f.input({pairId:saved.pairId,choice:'second',proposalId:proposal.operationId})));
 const deletion={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]};
 ok(await call(adult,'/v1/privacy/deletions','POST',deletion),202);
 await finishDeletion(deletion);
 for(const table of ['store_quote_pair','store_quote_proposal','store_quote_adoption','shop_budget_grant'])assert.equal((await admin.query(`SELECT count(*)::int n FROM ritc.${table} WHERE household_id=$1`,[f.h])).rows[0].n,0);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.store_quote_mutation WHERE household_id=$1 AND actor_id=$2',[f.h,adult.id])).rows[0].n,0);
 assert.equal(ok(await call(f.owner,f.quotes)).currentBasis,null);assert.equal(ok(await call(f.owner,f.path)).lines[0].unitPriceMinor,null);assert.equal((await call(adult,f.quotes+'/pairs','POST',saved.body)).status,401);
 const shop=ok(await call(f.owner,f.path));assert.equal(shop.storeReviewRequired,true);assert.equal(shop.storeBasisRevision,2);
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.patch',{lines:f.lines,quote:f.quote,reviewedStoreBasisRevision:shop.storeBasisRevision},2)));
 ok(await call(f.owner,f.base+'/commands','POST',f.command('shop.freeze',{},3)));
});

test('validation bounds money and exactly two alternatives; runtime cannot rewrite or delete saved proof',async()=>{
 const f=await fixture();
 for(const value of [-1,0.5,1_000_000_001]){
  const options=entered();options.first.checkoutMinor=value;
  assert.equal((await call(f.owner,f.quotes+'/pairs','POST',f.input({options}))).status,422);
 }
 const options=entered();assert.equal((await call(f.owner,f.quotes+'/pairs','POST',f.input({options:{...options,third:options.first}}))).status,422);
 options.first.observedAt=new Date(Date.now()+600000).toISOString();assert.equal((await call(f.owner,f.quotes+'/pairs','POST',f.input({options}))).data.error.code,'future_evidence');
 const saved=await f.save(),db=await runtime.connect();
 try{
  await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[f.h]);
  await assert.rejects(()=>db.query('UPDATE ritc.store_quote_pair SET options=options WHERE pair_id=$1',[saved.pairId]),error=>error.code==='42501');await db.query('ROLLBACK');
  await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[f.h]);
  await assert.rejects(()=>db.query('DELETE FROM ritc.store_quote_pair WHERE pair_id=$1',[saved.pairId]),error=>error.code==='42501');await db.query('ROLLBACK');
 }finally{db.release();}
});

test('dated proof paginates without overlap and revoked members disappear from the shopper proposal read',async()=>{
 const f=await fixture(),adult=await f.join();await f.grant(adult);
 for(let i=0;i<31;i++)await f.save(adult,entered(),1,1,1);
 const first=ok(await call(adult,f.quotes));assert.equal(first.pairs.length,30);assert.ok(first.nextCursor);
 const second=ok(await call(adult,f.quotes+'?cursor='+first.nextCursor));assert.equal(second.pairs.length,1);assert.equal(second.nextCursor,null);
 assert.equal(new Set([...first.pairs,...second.pairs].map(pair=>pair.pairId)).size,31);
 const proposal=f.input({pairId:first.pairs[0].pairId,choice:'first'},1,1,1);ok(await call(adult,f.quotes+'/proposals','POST',proposal));
 assert.equal(ok(await call(f.owner,f.quotes)).pairs.length,1);
 ok(await call(f.owner,f.base+'/revocations','POST',{kind:'member',targetId:adult.id}));
 assert.deepEqual(ok(await call(f.owner,f.quotes)).pairs,[]);assert.equal((await call(adult,f.quotes+'/proposals','POST',proposal)).status,403);
});

test('simultaneous grant revocation and adoption serialize with no partial basket or resurrected proposal',async()=>{
 const f=await fixture(),adult=await f.join();await f.grant(adult);const saved=await f.save(adult,entered(),1,1,1),proposal=f.input({pairId:saved.pairId,choice:'second'},1,1,1);
 ok(await call(adult,f.quotes+'/proposals','POST',proposal));
 const [revoked,adopted]=await Promise.all([
  call(f.owner,f.quotes+'/grants','POST',f.input({adultId:adult.id,enabled:false,targetRevision:1})),
  call(f.owner,f.quotes+'/adoptions','POST',f.input({pairId:saved.pairId,choice:'second',proposalId:proposal.operationId}))]);
 assert.ok([200,409].includes(revoked.status),JSON.stringify(revoked));assert.ok([200,404].includes(adopted.status),JSON.stringify(adopted));
 const shop=ok(await call(f.owner,f.path)),didAdopt=adopted.status===200;assert.equal(shop.shopRevision,didAdopt?2:1);assert.equal(shop.lines[0].unitPriceMinor,didAdopt?null:1800);
 if(revoked.status===409)await f.grant(adult,false,1,2);
 assert.equal((await call(adult,f.quotes)).status,404);
});

if(process.env.RITC_TEST_NATIVE_WIRE==='1')test('real Swift adult proposal and separate shopper adoption use pinned loopback HTTPS and PostgreSQL',async()=>{
 const {exerciseStoreQuoteClient}=await import('./shared-store-quotes-native-wire.mjs');
 const f=await fixture(),adult=await f.join();await f.grant(adult);
 await exerciseStoreQuoteClient({service:server,owner:adult,householdId:f.h,shopId:f.shopId,shopper:false});
 assert.equal(ok(await call(f.owner,f.path)).shopRevision,1);assert.equal(ok(await call(f.owner,f.quotes)).pairs.length,1);
 await exerciseStoreQuoteClient({service:server,owner:f.owner,householdId:f.h,shopId:f.shopId,shopper:true});
 const current=ok(await call(f.owner,f.path));assert.equal(current.shopRevision,2);assert.equal(current.lines[0].unitPriceMinor,null);
 assert.equal(ok(await call(f.owner,f.quotes)).currentBasis.branch,'West branch');
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.store_quote_pair WHERE household_id=$1',[f.h])).rows[0].n,2);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.store_quote_adoption WHERE household_id=$1',[f.h])).rows[0].n,1);
});

test('account erasure removes a later shopper’s delivery copy linked to a redacted sealed line', async () => {
  const f=await fixture(), contributor=await f.join(), commands=f.base+'/commands', evidence=f.path+'/delivery-evidence';
  const save=(actor,command)=>call(actor,commands,'POST',{...command,replayWindow:actor.window});
  ok(await save(f.owner,f.command('shop.transferAuthority',{newShopperId:contributor.id})));
  const line={...f.lines[0],originalItem:'Source description supplied by the former shopper'};
  ok(await save(contributor,f.command('shop.patch',{quote:f.quote,lines:[line]},1,2)));
  ok(await save(f.owner,f.command('shop.transferAuthority',{newShopperId:f.owner.id},2,2)));
  const occurrenceId=randomUUID(),meal={title:'Later shopper meal',day:'2026-11-07',kind:'dinner',portions:2,protected:false};
  ok(await save(f.owner,f.command('shop.patch',{quote:f.quote,lines:[line],mealEdit:{occurrenceId,baseMealRevision:null,meal}},2,3)));
  ok(await save(f.owner,f.command('shop.reportPlaced',{occurredAt:new Date().toISOString()},3,3)));
  const body={placedRevision:3,supplyRevision:0,lineId:line.lineId,segmentKey:randomUUID(),foodName:line.originalItem,exclusionTags:[]};
  const retained=f.command('delivery.register',body,4,3);
  ok(await save(f.owner,retained));
  assert.equal(ok(await call(f.owner,evidence)).sources[0].foodName,line.originalItem);
  const cook=f.command('cookCopy.save',{occurrenceId,mealRevision:3,placedRevision:3,supplyRevision:1,language:'en',text:line.originalItem},4,3);
  const {copyId}=ok(await save(f.owner,cook));
  const mark=f.command('cookCopy.markSent',{copyId,recipient:'Cook',previousSendId:null},4,3);
  ok(await save(f.owner,mark));
  const list=async()=>ok(await call(f.owner,f.path+'/cook-copies?occurrenceId='+occurrenceId)).copies;
  const baseline=async()=>ok(await call(f.owner,f.path+'/cook-copies/baseline','POST',{occurrenceId,recipient:'Cook'})).baseline;
  const deletion={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,
    households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]};
  const earlier=await f.join('Other adult');
  const otherDeletion={...deletion,clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url')};
  ok(await call(earlier,'/v1/privacy/deletions','POST',otherDeletion),202);
  ok(await call(contributor,'/v1/privacy/deletions','POST',deletion),202);
  await maintenance.run({batchSize:1});
  assert.notEqual((await privacy.status(deletion.clientKey,deletion.statusToken)).status,'complete');
  await finishDeletion(deletion);
  assert.deepEqual(await list(),[]);assert.equal(await baseline(),null);
  assert.equal((await save(f.owner,cook)).data.error.code,'refresh_required');
  assert.equal((await save(f.owner,mark)).data.error.code,'refresh_required');
  const erased=ok(await call(f.owner,evidence));
  assert.equal(erased.meals[0].occurrenceId,occurrenceId);

  assert.deepEqual(erased.sources,[]);
  assert.deepEqual(erased.lines,[]);
  assert.equal(erased.supplyRevision,2);
  const fresh=ok(await save(f.owner,f.command('cookCopy.save',{...cook.body,text:'Only the remaining meal facts',supplyRevision:2},4,3)));
  const unrelated=await f.join('Later adult');
  const laterDeletion={...deletion,clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url')};
  ok(await call(unrelated,'/v1/privacy/deletions','POST',laterDeletion),202);
  await finishDeletion(laterDeletion);
  assert.deepEqual((await list()).map(c=>[c.copyId,c.version]),[[fresh.copyId,2]]);
  assert.equal((await save(f.owner,retained)).data.error.code,'refresh_required');
  assert.equal((await save(f.owner,f.command('delivery.register',{...body,supplyRevision:2},4,3))).status,404);
});
