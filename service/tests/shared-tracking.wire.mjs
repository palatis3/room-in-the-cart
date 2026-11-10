import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import pg from 'pg';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {PrivacyService,PrivacyMaintenance} from '../dist/privacy.js';
import {openPrivacyJournalFixture} from './privacy-journal-fixture.mjs';
import {createHTTPServer} from '../dist/http.js';
assert.equal(process.env.RITC_TEST_NATIVE_WIRE,'1','Use the explicit native-wire wrapper');
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL});
const issuer='https://shared-demand.fixture.invalid';const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='fixture';
const verifier=new JWTIdentityVerifier({issuer,audience:'authenticated',jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]})),repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',trackingV2:true,sessionStatus:new SupabaseSessionVerifier(issuer)});
const journal=await openPrivacyJournalFixture(admin),provider={assertAvailable:async()=>{},deleteAccount:async subject=>{await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);}};
const privacy=new PrivacyService(repo,{provider,journal:journal.port,policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1}}),maintenance=new PrivacyMaintenance(worker,{provider,journal:journal.port});
const server=createHTTPServer({repository:repo,verifier,privacy,maxRequestsPerMinute:20000});let origin;
before(async()=>{await new Promise(r=>server.listen(0,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;});
after(async()=>{await new Promise(r=>server.close(r));await journal.close();await Promise.all([admin.end(),runtime.end(),worker.end()]);});
async function actor(subject=randomUUID()){const session=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);return{subject,session,token:await new SignJWT({session_id:session,amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)}]}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience('authenticated').setIssuedAt().setExpirationTime('1h').sign(privateKey)};}
async function call(a,path,method='GET',body){const r=await fetch(origin+path,{method,headers:{Authorization:'Bearer '+a.token,...(a.device?{'X-Device-Token':a.device}:{}),...(body===undefined?{}:{'Content-Type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})});return{status:r.status,data:await r.json()};}
function ok(r,status=200){assert.equal(r.status,status,JSON.stringify(r.data));return r.data;}
async function enroll(a,h){a.device=ok(await call(a,`/v1/households/${h}/devices`,'POST',{}),201).deviceToken;a.window=ok(await call(a,`/v1/households/${h}/replay-windows`,'POST',{})).id;}
const q=n=>({amount:{numerator:String(n),denominator:'1'},unit:'count',originalLiteral:n+' wraps',confirmedConversion:null});
const empty=()=>({lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[]});
const line=()=>({lineId:randomUUID(),originalItem:'Wraps',packs:2,unitPriceMinor:100,feeEligible:true});
async function fixture(){const owner=await actor(),h=ok(await call(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'Demand fixture',alias:'Shopper',adultAttestation:true}),201);owner.id=h.memberId;await enroll(owner,h.householdId);const shopId=randomUUID(),base=`/v1/households/${h.householdId}`,path=base+'/shops/'+shopId;
 const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date(Date.now()-60000).toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()},basket=line();
 const f={owner,h:h.householdId,base,path,shopId,quote,basket};ok(await send(f,'shop.create',{quote,lines:[basket]},0,0));return f;}
async function send(f,kind,body,revision,epoch=1,a=f.owner,extra={}){return call(a,f.base+'/commands','POST',{v:1,replayWindow:a.window,clientKey:randomUUID(),shopId:f.shopId,kind,base:{shopRevision:revision,authorityEpoch:epoch},body,...extra});}
function source(f,quantity=q(12)){return{id:randomUUID(),lineId:f.basket.lineId,source:{kind:'manual'},productKey:'wraps',productName:'Wraps',originalText:'12 wraps',quantity,exclusions:[],contains:[],removedAt:null};}
function draft(f,c=source(f)){return{mode:'adopt',base:{shopRevision:1,authorityEpoch:1,graphRevision:0},change:{...empty(),lines:[{id:f.basket.lineId,name:'Wraps',unit:'count',originalOrder:0,trashedAt:null}],contributions:[c]},action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket]}},packs:[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:false}]};}
async function invited(f){const a=await actor(),i=ok(await call(f.owner,f.base+'/invites','POST',{kind:'adult_contributor'}));a.id=ok(await call(a,'/v1/invites/redeem','POST',{token:i.token,intent:'join',adultAttestation:true,alias:'Other adult'})).memberId;await enroll(a,f.h);return a;}
const count=async(f,t)=>(await admin.query(`SELECT count(*)::int n FROM ritc.${t} WHERE household_id=$1 AND shop_id=$2`,[f.h,f.shopId])).rows[0].n;


async function page(f,a=f.owner){return ok(await call(a,f.path+'/demand/tracking'));}
const baseOf=p=>({shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,graphRevision:(p.state??p.projection.state).graph.revision,stateDigest:p.basisDigest});
async function candidate(f,intent,a=f.owner){return call(a,f.path+'/demand/tracking/candidates','POST',intent);}
async function accept(f,c,a=f.owner,disclosure=c.disclosure){return call(a,f.path+'/demand/tracking/previews','POST',{candidateId:c.candidateId,candidateDigest:c.candidateDigest,acknowledgedDisclosure:disclosure});}
async function commitTracking(f,c,p,base,a=f.owner){const command={v:1,replayWindow:a.window,clientKey:randomUUID(),shopId:f.shopId,kind:p.action.kind,base:{shopRevision:base.shopRevision,authorityEpoch:base.authorityEpoch,...(p.action.kind==='request.apply'?{requestRevision:c.after.catalog.find(f=>f.source.kind==='request'&&f.source.requestId===p.action.body.requestId).source.appliedRequestRevision}:{})},body:{...p.action.body,demandReview:{previewId:p.previewId,previewDigest:p.previewDigest,trackingVersion:2}}};return{command,response:await call(a,f.base+'/commands','POST',command)};}
async function applyIntent(f,intent){const c=ok(await candidate(f,intent)),p=ok(await accept(f,c)),a=await commitTracking(f,c,p,intent.base);ok(a.response);return{c,p,...a};}
async function first(f,{withMeal=true}={}){
 if(withMeal){f.occurrenceId=randomUUID();f.ingredientId=randomUUID();f.groupId=randomUUID();
  f.meal={title:'Dinner and protected lunch',day:null,kind:'dinner',portions:3,protected:false,planning:{groups:[{id:f.groupId,name:'Lunch',servings:{numerator:1,denominator:1},protected:true}],ingredients:[{id:f.ingredientId,name:'Wraps',quantity:{amount:{numerator:6,denominator:1},unit:'count',originalLiteral:'six wraps'},groupIds:[f.groupId],exclusions:[]}],exclusions:[]}};
  ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:f.occurrenceId,baseMealRevision:null,meal:f.meal}},1));
 }
 const before=await page(f),manual=source(f),catalog=before.state.catalog;
 const bound=catalog.map(fact=>({id:fact.id,lineId:f.basket.lineId,source:fact.source,productKey:'wraps',productName:'Wraps',originalText:fact.originalText,quantity:fact.quantity,sourceExclusions:fact.sourceExclusions,exclusions:[],contains:[],removedAt:null}));
 const input={...draft(f,manual),base:baseOf(before)};input.action.body.lines=[{...f.basket,packs:3}];input.change.contributions.push(...bound);input.packs[0].acceptUnresolved=withMeal;
 const accepted=await applyIntent(f,input);return{before,manual,input,...accepted};
}
async function addLater(f){const current=await page(f),old=current.state,extra={lineId:randomUUID(),originalItem:'Later apples',packs:1,unitPriceMinor:120,feeEligible:true};const c={...source({...f,basket:extra},q(3)),productKey:'apples',productName:'Apples',originalText:'three apples'};
 const input={mode:'change',base:baseOf(current),change:{...empty(),lines:[{id:extra.lineId,name:extra.originalItem,unit:'count',originalOrder:1,trashedAt:null}],contributions:[c]},unboundFactIds:old.unbound.map(u=>u.factId),action:{kind:'shop.patch',body:{quote:f.quote,lines:[...old.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.id===f.basket.lineId?120:l.priceMinor,feeEligible:l.feeEligible})),extra]}},packs:[...old.packReviews,{lineId:extra.lineId,usablePerPack:q(3),acceptUnresolved:false}]};await applyIntent(f,input);return{extra,c};}
async function inverse(f,target,packs){const current=await page(f);return applyIntent(f,{mode:'firstAdoptionUndo',base:baseOf(current),targetOperationId:target,packs:packs??[]});}
async function counts(f){return Promise.all(['operation','shared_demand_revision','shared_tracking_revision','shared_tracking_adoption','basket_line'].map(t=>count(f,t)));}

import {mkdtemp,chmod,readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {exerciseTrackingClient} from './shared-tracking-native-wire.mjs';
const state=async()=>{assert.ok(process.env.RITC_NATIVE_WIRE_STATE);const p=await mkdtemp(join(process.env.RITC_NATIVE_WIRE_STATE,'tracking-client-'));await chmod(p,0o700);return p;};
const wire=async(f,phase,privateState,extra={})=>exerciseTrackingClient({service:server,owner:f.owner,householdId:f.h,shopId:f.shopId,phase,privateState,
 before:phase==='revoked'?null:await page(f),packs:[],...extra});
function exactReview(observed){
 assert.equal(observed.candidateAttempts,1);assert.equal(observed.previewAttempts,1);
 assert.equal(observed.candidateResponses.length,1);assert.equal(observed.previewResponses.length,1);
 const c=observed.candidateResponses[0],p=observed.previewResponses[0],ack=JSON.parse(observed.previewRequests[0]);
 assert.deepEqual(ack,{candidateId:c.candidateId,candidateDigest:c.candidateDigest,acknowledgedDisclosure:c.disclosure});
 assert.deepEqual(p.disclosure,c.disclosure);assert.deepEqual(p.action,c.action);
 return c;
}
function exactApply(observed){
 const c=exactReview(observed),p=observed.previewResponses[0];assert.equal(observed.attempts,1);
 const command=JSON.parse(observed.commands[0]);assert.equal(command.kind,p.action.kind);
 assert.deepEqual(command.body,{...p.action.body,demandReview:{previewId:p.previewId,previewDigest:p.previewDigest,trackingVersion:2}});
 return {c,command};
}
async function catalogFixture(){
 const f=await fixture();f.occurrenceId=randomUUID();f.ingredientId=randomUUID();f.groupId=randomUUID();
 const meal={title:'Dinner and protected lunch',day:null,kind:'dinner',portions:3,protected:false,planning:{groups:[{id:f.groupId,name:'Lunch',servings:{numerator:1,denominator:1},protected:true}],ingredients:[{id:f.ingredientId,name:'Wraps',quantity:{amount:{numerator:6,denominator:1},unit:'count',originalLiteral:'six wraps'},groupIds:[f.groupId],exclusions:[]}],exclusions:[]}};
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:f.occurrenceId,baseMealRevision:null,meal}},1));
 const before=await page(f),manual=source(f),input={...draft(f,manual),base:baseOf(before)};
 input.change.contributions.push(...before.state.catalog.map(fact=>({id:fact.id,lineId:f.basket.lineId,source:fact.source,productKey:'wraps',productName:'Wraps',originalText:fact.originalText,quantity:fact.quantity,sourceExclusions:fact.sourceExclusions,exclusions:[],contains:[],removedAt:null})));
 input.action.body.lines=[{...f.basket,packs:3}];input.packs[0].acceptUnresolved=true;
 assert.equal(before.state.catalog.filter(x=>x.source.kind==='reservation'&&x.quantity===null).length,1);
 return{f,before,manual,input};
}

test('actual Swift tracking adoption and first Undo preserve protected unknown facts through Cancel lost reply restart and same-ID rebind',async()=>{
 const {f,before,manual,input}=await catalogFixture(),privateState=await state(),initialCounts=await counts(f);
 const payload={action:input.action,change:input.change,packs:input.packs};
 const cancel=await wire(f,'adopt-cancel',privateState,payload);exactReview(cancel);assert.equal(cancel.attempts,0);assert.deepEqual(await page(f),before);assert.deepEqual(await counts(f),initialCounts);
 const lost=await wire(f,'adopt-lost',privateState,{...payload,dropFirstReply:true});const {c}=exactApply(lost);assert.equal(lost.dropped,1);
 const adopted=await page(f);assert.deepEqual(adopted.state,c.after);assert.equal(await count(f,'shared_tracking_adoption'),1);
 const committedCounts=await counts(f),retry=await wire(f,'adopt-retry',privateState);
 assert.deepEqual(retry.commands,lost.commands);assert.equal(retry.candidateAttempts,0);assert.equal(retry.previewAttempts,0);assert.deepEqual(await counts(f),committedCounts);assert.deepEqual(await page(f),adopted);
 const target=(await admin.query('SELECT operation_id FROM ritc.shared_tracking_adoption WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows;assert.equal(target.length,1);
 const later=await addLater(f),beforeUndo=await page(f),line=beforeUndo.state.graph.lines.find(x=>x.id===f.basket.lineId);
 const undo=await wire(f,'first-undo',privateState,{targetOperationId:target[0].operation_id,packs:[{lineId:later.extra.lineId,usablePerPack:q(3),acceptUnresolved:false}],survivor:later.c});exactApply(undo);
 const undone=await page(f),protectedFact=undone.state.catalog.find(x=>x.source.kind==='reservation'),transferred=undone.state.unbound.find(x=>x.factId===protectedFact.id);
 assert.equal(undone.coverage.status,'partial');assert.equal(undone.coverage.completeFoodCoverage,false);assert.deepEqual(undone.coverage.allocatableUnboundFactIds,[]);
 assert.equal(protectedFact.quantity,null);assert.equal(transferred.transferred.id,protectedFact.id);assert.equal(transferred.transferred.quantity,null);
 assert.deepEqual(undone.state.graph.contributions.find(x=>x.id===later.c.id),later.c);assert.ok(undone.state.graph.contributions.find(x=>x.id===manual.id).removedAt);
 assert.deepEqual(undone.state.graph.usedIds,beforeUndo.state.graph.usedIds);assert.equal(undone.state.basket.find(x=>x.id===f.basket.lineId).priceMinor,120);assert.equal(undone.state.basket.find(x=>x.id===f.basket.lineId).packs,2);
 const rebound=await wire(f,'rebind',privateState,{line,survivor:later.c});exactApply(rebound);
 const final=await page(f);assert.deepEqual(final.state.unbound,[]);assert.deepEqual(final.state.graph.contributions.find(x=>x.id===protectedFact.id),transferred.transferred);assert.deepEqual(final.state.graph.usedIds,undone.state.graph.usedIds);assert.deepEqual(final.state.graph.contributions.find(x=>x.id===later.c.id),later.c);
});

test('actual Swift tracking request uses explicit current preview revision and distinct frozen review before exact placement',async()=>{
 const f=await fixture(),initial=await first(f);await inverse(f,ok(initial.response).operationId);const author=await invited(f),p=await page(f),privateState=await state();
 const sent=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Guest wraps',ownQuantity:'maybe two?',authoredAt:new Date().toISOString()},p.shopRevision,p.authorityEpoch,author));
 // A real author edit makes current request revision2; revision1 cannot be guessed from catalog history.
 ok(await send(f,'request.edit',{requestId:sent.request.requestId,originalItem:'Guest wraps revised',ownQuantity:'still unknown'},p.shopRevision,p.authorityEpoch,author,{base:{shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,requestRevision:1}}));
 const current=await page(f),newSource={...source(f,null),source:{kind:'request',requestId:sent.request.requestId,appliedRequestRevision:2},originalText:'Guest wraps revised'};
 const oldLine=current.state.graph.lines.find(x=>x.id===f.basket.lineId),change={...empty(),lines:[{...oldLine,trashedAt:null}],contributions:[newSource]},packs=[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:true}];
 const applied=await wire(f,'request',privateState,{requestId:sent.request.requestId,requestRevision:2,line:oldLine,change,packs});const reviewed=exactApply(applied);
 assert.equal(reviewed.command.base.requestRevision,2);const after=await page(f);assert.deepEqual(after.state.unbound,current.state.unbound);assert.deepEqual(after.state.graph.contributions.find(x=>x.id===newSource.id),newSource);
 const placed=await wire(f,'freeze-place',privateState);assert.equal(placed.attempts,3,'One rejected token, one exact freeze, one placement');
 const commands=placed.commands.map(x=>JSON.parse(x));assert.equal(commands[0].kind,'shop.freeze');assert.equal(commands[1].kind,'shop.freeze');assert.deepEqual(commands[1].body,{trackingReview:after.freezeReview});assert.equal(commands[2].kind,'shop.reportPlaced');
 const shop=ok(await call(f.owner,f.path));assert.equal(shop.phase,'placed');assert.equal(shop.shopRevision,after.shopRevision+2);
 const frozen=(await admin.query('SELECT snapshot FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[f.h,f.shopId,after.shopRevision+1])).rows[0].snapshot;
 assert.deepEqual(frozen.trackingSeal.snapshot.state,after.state);assert.equal(frozen.trackingSeal.snapshot.review.disclosure.coverage.status,'partial');
 assert.deepEqual((await page(f)).state.unbound,after.state.unbound);
});

test('actual Swift tracking erasure preserves independent sources through recovery and refuses revoked shopper replay',async()=>{
 const f=await fixture(),author=await invited(f),rice={lineId:randomUUID(),originalItem:'Rice',packs:2,unitPriceMinor:100,feeEligible:true};
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket,rice]},1));let p=await page(f);
 const sent=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Private guest wraps',ownQuantity:'two?',authoredAt:new Date().toISOString()},p.shopRevision,p.authorityEpoch,author));
 const money=ok(await call(f.owner,f.path+'/previews','POST',{requestId:sent.request.requestId,base:{shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 ok(await send(f,'request.apply',{requestId:sent.request.requestId,previewId:money.previewId,acceptUnknown:false,acceptOverage:false},p.shopRevision,p.authorityEpoch,f.owner,{base:{shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,requestRevision:1}}));
 p=await page(f);const fact=p.state.catalog.find(x=>x.source.kind==='request'),survivor={...source({...f,basket:rice}),productKey:'rice',productName:'Rice',originalText:'Independent rice'},request={...source(f,null),source:fact.source,originalText:fact.originalText};
 const change={...empty(),lines:[f.basket,rice].map((x,i)=>({id:x.lineId,name:x.originalItem,unit:'count',originalOrder:i,trashedAt:null})),contributions:[survivor,request]},packs=[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:true},{lineId:rice.lineId,usablePerPack:q(6),acceptUnresolved:false}],privateState=await state();
 const adopted=await wire(f,'privacy-adopt',privateState,{action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket,rice]}},change,packs,survivor});exactApply(adopted);
 ok(await call(author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 const erased=await page(f);assert.equal(erased.status,'reviewRequired');assert.deepEqual(erased.projection.state.graph.contributions.find(x=>x.id===survivor.id),survivor);assert.ok(!JSON.stringify(erased).includes('Private guest wraps'));
 const recovered=await wire(f,'recover',privateState,{packs:[packs[1]],survivor});assert.equal(recovered.attempts,2,'Old exact replay denied, then fresh recovery');exactReview(recovered);
 assert.deepEqual(recovered.commands[0],adopted.commands[0]);const accepted=recovered.previewResponses[0],recoveryCommand=JSON.parse(recovered.commands[1]);
 assert.equal(recoveryCommand.kind,accepted.action.kind);assert.deepEqual(recoveryCommand.body,{...accepted.action.body,demandReview:{previewId:accepted.previewId,previewDigest:accepted.previewDigest,trackingVersion:2}});
 const after=await page(f);assert.equal(after.status,'enabled');assert.deepEqual(after.state.graph.contributions.find(x=>x.id===survivor.id),survivor);assert.ok(after.freezeReview);
 const newShopper=await invited(f);ok(await send(f,'shop.transferAuthority',{newShopperId:newShopper.id},after.shopRevision,after.authorityEpoch));const beforeCounts=await counts(f),revoked=await wire(f,'revoked',privateState);
 assert.equal(revoked.attempts,1,'Only raw adversarial replay reaches command route');assert.deepEqual(revoked.commands,[recovered.commands[1]]);assert.deepEqual(await counts(f),beforeCounts);
 assert.equal((await call(f.owner,f.path+'/demand/tracking')).status,404);assert.equal(ok(await call(newShopper,f.path+'/demand/tracking')).state.graph.contributions.find(x=>x.id===survivor.id).originalText,survivor.originalText);
});
