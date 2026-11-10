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
async function accept(f,c,a=f.owner,disclosure=c.disclosure){return call(a,f.path+'/demand/tracking/previews','POST',{candidateId:c.candidateId,candidateDigest:c.candidateDigest,acknowledgedDisclosure:disclosure,acceptOverage:false,acceptUnknown:true});}
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
 const input={mode:'change',base:baseOf(current),change:{...empty(),lines:[{id:extra.lineId,name:extra.originalItem,unit:'count',originalOrder:Math.max(-1,...old.graph.lines.map(l=>l.originalOrder))+1,trashedAt:null}],contributions:[c]},unboundFactIds:old.unbound.map(u=>u.factId),action:{kind:'shop.patch',body:{quote:f.quote,lines:[...old.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.id===f.basket.lineId?120:l.priceMinor,feeEligible:l.feeEligible})),extra]}},packs:[...old.packReviews,{lineId:extra.lineId,usablePerPack:q(3),acceptUnresolved:false}]};await applyIntent(f,input);return{extra,c};}
async function inverse(f,target,packs){const current=await page(f);return applyIntent(f,{mode:'firstAdoptionUndo',base:baseOf(current),targetOperationId:target,packs:packs??[]});}
async function counts(f){return Promise.all(['operation','shared_demand_revision','shared_tracking_revision','shared_tracking_adoption','basket_line'].map(t=>count(f,t)));}

import {mkdtemp,chmod,readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {exerciseTrackingClient} from './shared-tracking-native-wire.mjs';
const state=async()=>{assert.ok(process.env.RITC_NATIVE_WIRE_STATE);const p=await mkdtemp(join(process.env.RITC_NATIVE_WIRE_STATE,'tracking-client-'));await chmod(p,0o700);return p;};
const wire=async(f,phase,privateState,extra={})=>exerciseTrackingClient({service:server,owner:f.owner,householdId:f.h,shopId:f.shopId,phase,privateState,
 before:phase==='revoked'?null:await page(f),packs:[],...extra});
function exactReview(observed,{acceptOverage=false,acceptUnknown=true}={}){
 assert.equal(observed.candidateAttempts,1);assert.equal(observed.previewAttempts,1);
 assert.equal(observed.candidateResponses.length,1);assert.equal(observed.previewResponses.length,1);
 const c=observed.candidateResponses[0],p=observed.previewResponses[0],ack=JSON.parse(observed.previewRequests[0]);
 assert.deepEqual(ack,{candidateId:c.candidateId,candidateDigest:c.candidateDigest,acknowledgedDisclosure:c.disclosure,acceptOverage,acceptUnknown});
 assert.deepEqual(p.disclosure,c.disclosure);assert.deepEqual(p.action,c.action);assert.deepEqual(p.moneyAcknowledgments,{acceptOverage,acceptUnknown});
 return c;
}
function exactApply(observed,consent){
 const c=exactReview(observed,consent),p=observed.previewResponses[0];assert.equal(observed.attempts,1);
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


function exactRequestUndoReview(observed){
 assert.equal(observed.historyAttempts,1);assert.equal(observed.historyResponses.length,1);
 assert.equal(observed.candidateAttempts,1);assert.equal(observed.previewAttempts,1);
 const c=observed.candidateResponses[0],p=observed.previewResponses[0],input=JSON.parse(observed.previewRequests[0]);
 assert.equal(c.kind,'requestAcceptanceUndo');assert.equal(p.kind,'requestAcceptanceUndoPreview');
 assert.deepEqual(input,{targetOperationId:c.targetOperationId,base:c.base,effectDigest:c.effectDigest,packs:p.packs,acceptOverage:false,acceptUnknown:true});
 assert.deepEqual(p.candidate.action,c.action);assert.deepEqual(p.candidate.requestUndo,c.requestUndo);
 assert.deepEqual(p.candidate.beforeCheckout,c.beforeCheckout);assert.deepEqual(p.candidate.afterCheckout,c.afterCheckout);
 assert.equal(c.requestUndo.originalQuantityText,'one large box, amount unknown');
 return {c,p};
}
async function acceptanceCounts(f){return{base:await counts(f),effects:await count(f,'request_acceptance_effect'),inverses:await count(f,'request_acceptance_inverse'),links:await count(f,'request_link')};}
async function ownRequest(f,author,requestId){return ok(await call(author,f.base+'/requests/mine')).requests.find(r=>r.requestId===requestId);}
async function requestPhase(f,privateState,author,requestId,phase){
 const current=await page(f),request=await ownRequest(f,author,requestId),oldLine=current.state.graph.lines.find(x=>x.id===f.basket.lineId);
 const contribution={...source(f,null),source:{kind:'request',requestId,appliedRequestRevision:request.revision},originalText:request.originalItem};
 const observed=await wire(f,phase,privateState,{requestId,requestRevision:request.revision,line:oldLine,
  change:{...empty(),lines:[{...oldLine,trashedAt:null}],contributions:[contribution]},packs:current.state.packReviews});
 const {command}=exactApply(observed);assert.equal(command.base.requestRevision,request.revision);
 const after=await page(f);assert.deepEqual(after.state.graph.contributions.find(c=>c.id===contribution.id),contribution);
 return{observed,contribution,request};
}

test('actual Swift request acceptance Undo preserves author quantity wording and exact replay across later acceptance generations',async()=>{
 const f=await fixture();await first(f);const author=await invited(f),privateState=await state(),initial=await page(f);
 const request=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Guest wraps',ownQuantity:'initial wording',authoredAt:new Date().toISOString()},initial.shopRevision,initial.authorityEpoch,author)).request;
 ok(await send(f,'request.edit',{requestId:request.requestId,originalItem:'Guest wraps revised',ownQuantity:'one large box, amount unknown'},initial.shopRevision,initial.authorityEpoch,author,{base:{shopRevision:initial.shopRevision,authorityEpoch:initial.authorityEpoch,requestRevision:request.revision}}));
 const accepted=await requestPhase(f,privateState,author,request.requestId,'request-undo-accept');
 const target=(await admin.query('SELECT operation_id FROM ritc.request_acceptance_effect WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows;assert.equal(target.length,1);
 const later=await addLater(f),before=await page(f),beforeCounts=await acceptanceCounts(f),beforeShop=ok(await call(f.owner,f.path)),beforeOwn=await ownRequest(f,author,request.requestId);
 const details={targetOperationId:target[0].operation_id,requestRevision:accepted.request.revision,originalQuantityText:'one large box, amount unknown',packs:before.state.packReviews,survivor:later.c};
 const cancel=await wire(f,'request-undo-cancel',privateState,details);exactRequestUndoReview(cancel);assert.equal(cancel.attempts,0);
 assert.deepEqual(await page(f),before);assert.deepEqual(ok(await call(f.owner,f.path)),beforeShop);assert.deepEqual(await acceptanceCounts(f),beforeCounts);assert.deepEqual(await ownRequest(f,author,request.requestId),beforeOwn);
 const lost=await wire(f,'request-undo-lost',privateState,{...details,dropFirstReply:true}),{p}=exactRequestUndoReview(lost);
 assert.equal(lost.attempts,1);assert.equal(lost.dropped,1);const command=JSON.parse(lost.commands[0]);
 assert.equal(command.kind,'request.undoAcceptance');assert.deepEqual(command.body,{...p.candidate.action.body,operationUndoReview:{previewId:p.previewId,previewDigest:p.previewDigest}});
 const undone=await page(f),undoneCounts=await acceptanceCounts(f),undoneOwn=await ownRequest(f,author,request.requestId);
 assert.equal(undoneOwn.status,'pending');assert.equal(undoneOwn.revision,beforeOwn.revision+1);assert.equal(undoneOwn.ownQuantity,'one large box, amount unknown');
 assert.deepEqual(undone.state.graph,p.candidate.foodAfter.state.graph);assert.equal(undoneCounts.inverses,beforeCounts.inverses+1);
 const oldRow=undone.state.graph.contributions.find(c=>c.id===accepted.contribution.id);assert.ok(oldRow.removedAt);assert.deepEqual(oldRow.source,accepted.contribution.source);
 assert.deepEqual(undone.state.graph.contributions.filter(c=>c.source.kind==='reservation'),before.state.graph.contributions.filter(c=>c.source.kind==='reservation'));
 assert.deepEqual(undone.state.graph.contributions.find(c=>c.id===later.c.id),later.c);assert.deepEqual(ok(await call(f.owner,f.path)).meals,beforeShop.meals);
 const retry=await wire(f,'request-undo-retry',privateState,{survivor:later.c});assert.deepEqual(retry.commands,lost.commands);assert.equal(retry.candidateAttempts,0);assert.equal(retry.previewAttempts,0);assert.equal(retry.historyAttempts,0);
 assert.deepEqual(await page(f),undone);assert.deepEqual(await acceptanceCounts(f),undoneCounts);
 const reaccepted=await requestPhase(f,privateState,author,request.requestId,'request-undo-reaccept'),current=await page(f),currentCounts=await acceptanceCounts(f),currentOwn=await ownRequest(f,author,request.requestId);
 assert.notEqual(reaccepted.contribution.id,accepted.contribution.id);assert.ok(reaccepted.request.revision>accepted.request.revision);
 const generations=current.state.graph.contributions.filter(c=>c.source.kind==='request'&&c.source.requestId===request.requestId);assert.equal(generations.length,2);assert.equal(generations.filter(c=>c.removedAt===null).length,1);
 assert.deepEqual(generations.find(c=>c.id===oldRow.id),oldRow);assert.ok(undone.state.graph.usedIds.every(id=>current.state.graph.usedIds.includes(id)));
 const replay=await wire(f,'request-undo-replay-after-reaccept',privateState,{survivor:later.c});assert.deepEqual(replay.commands,lost.commands);assert.equal(replay.candidateAttempts,0);assert.equal(replay.previewAttempts,0);
 assert.deepEqual(await page(f),current);assert.deepEqual(await acceptanceCounts(f),currentCounts);assert.deepEqual(await ownRequest(f,author,request.requestId),currentOwn);assert.equal(currentOwn.status,'added');
});

test('actual Swift compound meal adoption Undo binds complete inverse and explicit overage consent through lost reply restart',async()=>{
 const {f,manual}=await catalogFixture(),privateState=await state();
 // This existing protected lunch belongs to the original shop. The new dinner
 // is created atomically with tracking and a larger budget, then fully undone.
 f.quote={...f.quote,capMinor:100};let current=ok(await call(f.owner,f.path));ok(await send(f,'shop.patch',{quote:f.quote,lines:current.lines},current.shopRevision,current.authorityEpoch));
 const original=ok(await call(f.owner,f.path)),before=await page(f),occurrenceId=randomUUID(),ingredientId=randomUUID();
 const meal={title:'New dinner',day:null,kind:'dinner',portions:2,protected:false,planning:{groups:[],ingredients:[{id:ingredientId,name:'Wraps',quantity:{amount:{numerator:6,denominator:1},unit:'count',originalLiteral:'six dinner wraps'},groupIds:[],exclusions:[]}]}};
 const adoptedQuote={...f.quote,capMinor:10000},action={kind:'shop.patch',body:{quote:adoptedQuote,lines:original.lines,mealEdit:{occurrenceId,baseMealRevision:null,meal}}};
 const catalog=ok(await call(f.owner,f.path+'/demand/tracking/action-sources','POST',{base:baseOf(before),action}));
 const change={...empty(),lines:[{id:f.basket.lineId,name:f.basket.originalItem,unit:'count',originalOrder:0,trashedAt:null}],contributions:[manual,...catalog.sources.map(fact=>({id:fact.id,lineId:f.basket.lineId,source:fact.source,productKey:'wraps',productName:fact.productName,originalText:fact.originalText,quantity:fact.quantity,sourceExclusions:fact.sourceExclusions,exclusions:[],contains:[],removedAt:null}))]};
 const adopted=await wire(f,'compound-adopt',privateState,{action,change,packs:[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:true}]});const applied=exactApply(adopted);
 assert.equal(adopted.catalogAttempts,1);assert.deepEqual(adopted.catalogResponses[0],catalog);
 assert.deepEqual(applied.c.action.body.mealEdit,action.body.mealEdit);f.quote=adoptedQuote;
 const target=(await admin.query('SELECT operation_id FROM ritc.shared_tracking_adoption WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows;assert.equal(target.length,1);
 const later=await addLater(f),beforeUndo=await page(f),beforeCounts=await counts(f),beforeShop=ok(await call(f.owner,f.path));
 const payload={targetOperationId:target[0].operation_id,packs:[{lineId:later.extra.lineId,usablePerPack:q(3),acceptUnresolved:false}],acceptOverage:true,survivor:later.c};
 const cancel=await wire(f,'compound-undo-cancel',privateState,payload);const cancelled=exactReview(cancel,{acceptOverage:true});assert.equal(cancel.attempts,0);
 assert.equal(cancelled.disclosure.money.after.status,'overCap');assert.equal(cancelled.disclosure.changes.mealUndo.occurrenceId,occurrenceId);assert.equal(cancelled.disclosure.changes.mealUndo.restoredMeal,null);
 assert.deepEqual(await page(f),beforeUndo);assert.deepEqual(await counts(f),beforeCounts);assert.deepEqual(ok(await call(f.owner,f.path)),beforeShop);
 // The server independently enforces the same explicit monetary acceptance.
 const unaccepted=ok(await candidate(f,{mode:'firstAdoptionUndo',base:baseOf(beforeUndo),targetOperationId:target[0].operation_id,packs:payload.packs}));
 const missing=await call(f.owner,f.path+'/demand/tracking/previews','POST',{candidateId:unaccepted.candidateId,candidateDigest:unaccepted.candidateDigest,acknowledgedDisclosure:unaccepted.disclosure,acceptOverage:false,acceptUnknown:true});
 assert.equal(missing.status,409);assert.equal(missing.data.error.code,'tracking_money_acknowledgment_required');assert.deepEqual(await counts(f),beforeCounts);assert.deepEqual(await page(f),beforeUndo);
 const lost=await wire(f,'compound-undo-lost',privateState,{...payload,dropFirstReply:true});const inverse=exactApply(lost,{acceptOverage:true});assert.equal(lost.dropped,1);
 assert.deepEqual(inverse.command.body.mealEdit,{occurrenceId,baseMealRevision:beforeShop.meals.find(m=>m.occurrenceId===occurrenceId).revision,meal:null});
 const after=await page(f),afterShop=ok(await call(f.owner,f.path)),afterCounts=await counts(f);
 assert.equal(afterShop.meals.some(m=>m.occurrenceId===occurrenceId),false);
 assert.deepEqual(afterShop.meals.filter(m=>m.occurrenceId!==occurrenceId),original.meals);
 assert.equal(afterShop.quote.capMinor,100);assert.equal(after.state.basket.find(l=>l.id===f.basket.lineId).priceMinor,120);
 assert.deepEqual(after.state.graph.contributions.find(c=>c.id===later.c.id),later.c);
 const protectedFact=after.state.catalog.find(fact=>fact.source.kind==='reservation');assert.ok(protectedFact);const transfer=after.state.unbound.find(u=>u.factId===protectedFact.id);assert.ok(transfer?.transferred);assert.equal(transfer.transferred.quantity,null);
 assert.deepEqual(after.state.graph.usedIds,beforeUndo.state.graph.usedIds);
 const retry=await wire(f,'compound-undo-retry',privateState,{survivor:later.c});assert.deepEqual(retry.commands,lost.commands);assert.equal(retry.candidateAttempts,0);assert.equal(retry.previewAttempts,0);
 assert.deepEqual(await page(f),after);assert.deepEqual(ok(await call(f.owner,f.path)),afterShop);assert.deepEqual(await counts(f),afterCounts);
});

// Partial-state successor scenarios keep all setup mutations on authenticated
// routes. No tracking snapshot, fact, receipt or HTTP response is injected.
const physical=(n,unit,literal,confirmedConversion=null)=>({amount:{numerator:String(n),denominator:'1'},unit,originalLiteral:literal,confirmedConversion});
const mealQuantity=(n,unit,literal)=>({amount:{numerator:n,denominator:1},unit,originalLiteral:literal});
const conversion=(sourceUnit,targetUnit,n,d,note)=>({sourceUnit,targetUnit,targetAmountPerSourceUnit:{numerator:String(n),denominator:String(d)},sourceNote:note,confirmedAt:new Date().toISOString()});
const linesOf=p=>p.state.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible}));
const head=async f=>ok(await call(f.owner,f.path));
async function partialStoreSelection(f){
 const s=await head(f),at=new Date(Date.now()+3600000).toISOString();
 const option={label:'Reviewed partial pickup store',store:'Entered shop',branch:'A',mode:'pickup',slot:at,observedAt:new Date(Date.now()-60000).toISOString(),source:'Entered checkout',currency:'USD',terms:'Complete quote',itemsMinor:200,checkoutMinor:200,allChargesIncluded:true,available:true,quantitiesMatched:true,singleStore:true,tripAlreadyPlanned:true,tripMinor:0,extraMinutes:0,capMinor:10000,capScope:'wholeCheckout',eligibilityConfirmed:true};
 const pair={operationId:randomUUID(),shopRevision:s.shopRevision,authorityEpoch:s.authorityEpoch,grantRevision:0,options:{first:option,second:{...option,branch:'B'}}};
 ok(await call(f.owner,f.path+'/store-quotes/pairs','POST',pair));
 return ok(await call(f.owner,f.path+'/store-quotes/adoptions','POST',{operationId:randomUUID(),shopRevision:s.shopRevision,authorityEpoch:s.authorityEpoch,grantRevision:0,pairId:pair.operationId,choice:'first',proposalId:null}));
}
async function partialConversionFixture(){
 const f=await fixture(),wraps={...line(),originalItem:'Reserved lunch wraps'},flour={...f.basket,originalItem:'Flour'};
 f.basket=flour;f.occurrenceId=randomUUID();f.ingredientId=randomUUID();f.lunchId=randomUUID();f.lunchIngredientId=randomUUID();
 f.meal={title:'Flour dinner',day:null,kind:'dinner',portions:2,protected:false,planning:{groups:[],ingredients:[{id:f.ingredientId,name:'Flour',quantity:mealQuantity(1,'cup','one measured cup'),groupIds:[],exclusions:[]}],exclusions:[]}};
 f.lunch={title:'Protected lunch',day:null,kind:'lunch',portions:2,protected:true,planning:{groups:[],ingredients:[{id:f.lunchIngredientId,name:'Wraps',quantity:mealQuantity(2,'count','two reserved wraps'),groupIds:[],exclusions:[]}],exclusions:[]}};
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[flour,wraps],mealEdit:{occurrenceId:f.occurrenceId,baseMealRevision:null,meal:f.meal}},1));
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[flour,wraps],mealEdit:{occurrenceId:f.lunchId,baseMealRevision:null,meal:f.lunch}},2));
 let p=await page(f);const flourFact=p.state.catalog.find(x=>x.source.kind==='meal'),lunchFact=p.state.catalog.find(x=>x.source.kind==='reservation');assert.ok(flourFact);assert.ok(lunchFact);assert.equal(lunchFact.quantity.amount.numerator,'2');
 const flourBasis=conversion('cup','gram',120,1,'Original measured flour density');
 const bound=p.state.catalog.map(fact=>({id:fact.id,lineId:fact.id===flourFact.id?flour.lineId:wraps.lineId,source:fact.source,productKey:fact.id===flourFact.id?'flour':'wraps',productName:fact.originalText,originalText:fact.originalText,quantity:fact.id===flourFact.id?{...fact.quantity,confirmedConversion:flourBasis}:fact.quantity,sourceExclusions:fact.sourceExclusions,exclusions:[],contains:[],removedAt:null}));
 const graphLines=[{id:flour.lineId,name:flour.originalItem,unit:'gram',originalOrder:0,trashedAt:null},{id:wraps.lineId,name:wraps.originalItem,unit:'count',originalOrder:1,trashedAt:null}];
 const initial=await applyIntent(f,{mode:'adopt',base:baseOf(p),action:{kind:'shop.patch',body:{quote:f.quote,lines:[flour,wraps]}},change:{...empty(),lines:graphLines,contributions:bound},packs:[{lineId:flour.lineId,usablePerPack:physical(240,'gram','240 grams per pack'),acceptUnresolved:false},{lineId:wraps.lineId,usablePerPack:q(6),acceptUnresolved:false}]});
 await inverse(f,ok(initial.response).operationId);p=await page(f);
 assert.equal(p.state.unbound.length,2);assert.ok(p.state.unbound.every(u=>u.transferred));
 const pack={lineId:flour.lineId,usablePerPack:physical(240,'gram','240 grams per pack'),acceptUnresolved:false};
 await applyIntent(f,{mode:'rebind',base:baseOf(p),bindings:[{factId:flourFact.id,line:graphLines[0],basket:p.state.basket.find(b=>b.id===flour.lineId),packReview:pack}]});
 p=await page(f);const manual={...source(f,physical(240,'gram','240 independent grams')),productKey:'flour',productName:'Flour',originalText:'Independent flour supply'};
 const edge={id:randomUUID(),kind:'withinExisting',demandId:flourFact.id,supplyId:manual.id,quantity:physical(120,'gram','120 grams already included',flourBasis),confirmation:{productMatchConfirmed:true,confirmedAt:new Date().toISOString(),evidence:'Same measured flour'}};
 await applyIntent(f,{mode:'change',base:baseOf(p),action:{kind:'shop.patch',body:{quote:f.quote,lines:linesOf(p)}},change:{...empty(),contributions:[manual],edges:[edge]},packs:p.state.packReviews,unboundFactIds:p.state.unbound.map(x=>x.factId)});
 p=await page(f);assert.equal(p.coverage.status,'partial');assert.equal(p.state.graph.edges.length,1);assert.equal(p.state.unbound.length,1);assert.equal(p.state.unbound[0].transferred.source.kind,'reservation');
 return{f,flourFact,lunchFact,manual,edge};
}
async function partialMealPayload(f,{protectedChange=false}={}){
 const p=await page(f),s=await head(f),occurrenceId=protectedChange?f.lunchId:f.occurrenceId,current=s.meals.find(m=>m.occurrenceId===occurrenceId),next=structuredClone(current.meal);
 next.planning.ingredients[0].quantity=protectedChange?mealQuantity(60,'gram','60 measured grams'):mealQuantity(2,'cup','two freshly measured cups');
 const action={kind:'shop.patch',body:{quote:s.quote,lines:s.lines,mealEdit:{occurrenceId,baseMealRevision:current.revision,meal:next}}};
 const catalog=ok(await call(f.owner,f.path+'/demand/tracking/meal-action-sources','POST',{base:baseOf(p),action}));
 const row=catalog.sources.find(x=>x.factId===(protectedChange?p.state.unbound[0].factId:p.state.bindings[0].factId));assert.ok(row);assert.equal(row.transition,'update');assert.equal(row.proposed.quantity.confirmedConversion,null);
 const basis=protectedChange?conversion('gram','count',1,30,'One protected wrap weighs 30 grams'):conversion('cup','gram',120,1,'Freshly reviewed flour density');
 const after={...row.before,source:row.proposed.source,productName:row.proposed.productName,quantity:{...row.proposed.quantity,confirmedConversion:basis},sourceExclusions:row.proposed.sourceExclusions};
 return{action,change:{...empty(),contributions:protectedChange?[]:[after]},packs:p.state.packReviews,unboundFactIds:catalog.proposedCatalog.filter(fact=>!p.state.bindings.some(binding=>binding.factId===fact.id)).map(fact=>fact.id),...(protectedChange?{transferredChanges:[{factId:row.factId,after}]}:{}),expectedMealCatalog:catalog};
}
function exactPartialCatalog(observed,payload){assert.equal(observed.mealCatalogAttempts,1);assert.deepEqual(observed.mealCatalogResponses,[payload.expectedMealCatalog]);}

// Selecting a store and reviewing its actual basket prices remain distinct
// operations. Cancellation has no graph/shop side effects; durable retry emits
// the exact bytes of the command whose successful reply was lost.
test('actual Swift partial store re-review preserves detached unknowns through Cancel lost reply and exact restart retry',async()=>{
 const {f,input}=await catalogFixture(),initial=await applyIntent(f,input);await inverse(f,ok(initial.response).operationId);
 const later=await addLater(f),selected=await partialStoreSelection(f),before=await page(f),beforeShop=await head(f),beforeCounts=await counts(f),privateState=await state();
 assert.equal(before.coverage.status,'partial');assert.equal(beforeShop.storeReviewRequired,true);
 const payload={action:{kind:'shop.patch',body:{quote:{...f.quote,capMinor:300},lines:beforeShop.lines.map(l=>({...l,unitPriceMinor:250})),reviewedStoreBasisRevision:beforeShop.storeBasisRevision}},packs:before.state.packReviews,acceptOverage:true,survivor:later.c};
 const cancel=await wire(f,'partial-store-cancel',privateState,payload);exactReview(cancel,{acceptOverage:true});assert.equal(cancel.attempts,0);assert.deepEqual(await page(f),before);assert.deepEqual(await head(f),beforeShop);assert.deepEqual(await counts(f),beforeCounts);
 const lost=await wire(f,'partial-store-lost',privateState,{...payload,dropFirstReply:true});const applied=exactApply(lost,{acceptOverage:true});assert.equal(lost.dropped,1);
 const after=await page(f),shop=await head(f),afterCounts=await counts(f);assert.deepEqual(after.state,applied.c.after);assert.equal(shop.storeReviewRequired,false);assert.equal(shop.storeBasisRevision,selected.shopRevision);
 assert.deepEqual(after.state.unbound,before.state.unbound);assert.deepEqual(after.state.catalog,before.state.catalog);assert.deepEqual(after.state.graph.contributions,before.state.graph.contributions);assert.deepEqual(after.coverage.allocatableUnboundFactIds,[]);
 const retry=await wire(f,'partial-store-retry',privateState,{survivor:later.c});assert.deepEqual(retry.commands,lost.commands);assert.equal(retry.candidateAttempts,0);assert.equal(retry.previewAttempts,0);assert.equal(retry.mealCatalogAttempts,0);
 assert.deepEqual(await page(f),after);assert.deepEqual(await head(f),shop);assert.deepEqual(await counts(f),afterCounts);
});

test('actual Swift partial meal fresh conversion keeps allocation through whole Undo Cancel lost reply and exact restart retry',async()=>{
 const {f,manual,edge}=await partialConversionFixture(),before=await page(f),beforeShop=await head(f),beforeCounts=await counts(f),privateState=await state(),payload=await partialMealPayload(f);
 const missingBasis=structuredClone(payload.change);missingBasis.contributions[0].quantity.confirmedConversion=null;
 const denied=await candidate(f,{mode:'change',base:baseOf(before),action:payload.action,change:missingBasis,packs:payload.packs,unboundFactIds:payload.unboundFactIds});assert.equal(denied.status,422);assert.equal(denied.data.error.code,'incompatible_units');assert.deepEqual(await page(f),before);assert.deepEqual(await counts(f),beforeCounts);
 const cancel=await wire(f,'partial-meal-cancel',privateState,payload);exactPartialCatalog(cancel,payload);exactReview(cancel);assert.equal(cancel.attempts,0);assert.deepEqual(await page(f),before);assert.deepEqual(await head(f),beforeShop);assert.deepEqual(await counts(f),beforeCounts);
 const lost=await wire(f,'partial-meal-lost',privateState,{...payload,dropFirstReply:true});exactPartialCatalog(lost,payload);const applied=exactApply(lost);assert.equal(lost.dropped,1);
 const after=await page(f),afterCounts=await counts(f);assert.deepEqual(after.state.graph.edges,[edge]);assert.deepEqual(after.state.graph.contributions.find(c=>c.id===manual.id),manual);assert.deepEqual(after.state.unbound,before.state.unbound);
 assert.equal(after.coverage.trackedSubtotals.find(t=>t.lineId===f.basket.lineId).quantity.numerator,'360');assert.equal(after.state.graph.contributions.find(c=>c.id===edge.demandId).quantity.confirmedConversion.sourceNote,'Freshly reviewed flour density');
 const retry=await wire(f,'partial-meal-retry',privateState);assert.deepEqual(retry.commands,lost.commands);assert.equal(retry.candidateAttempts,0);assert.equal(retry.previewAttempts,0);assert.deepEqual(await page(f),after);assert.deepEqual(await counts(f),afterCounts);
 const target=(await admin.query('SELECT operation_id FROM ritc.operation WHERE household_id=$1 AND shop_id=$2 AND client_key=$3',[f.h,f.shopId,applied.command.clientKey])).rows;assert.equal(target.length,1);
 const later=await addLater(f),beforeUndo=await page(f),shopBeforeUndo=await head(f),undoCounts=await counts(f),undoPayload={targetOperationId:target[0].operation_id,packs:beforeUndo.state.packReviews,survivor:later.c};
 const undoCancel=await wire(f,'partial-meal-undo-cancel',privateState,undoPayload);exactReview(undoCancel);assert.equal(undoCancel.trackingHistoryAttempts,1);assert.equal(undoCancel.attempts,0);assert.deepEqual(await page(f),beforeUndo);assert.deepEqual(await head(f),shopBeforeUndo);assert.deepEqual(await counts(f),undoCounts);
 const undoLost=await wire(f,'partial-meal-undo-lost',privateState,{...undoPayload,dropFirstReply:true});const inverseReview=exactApply(undoLost);assert.equal(undoLost.dropped,1);assert.equal(inverseReview.c.disclosure.changes.kind,'mealOperationUndo');
 const restored=await page(f),restoredShop=await head(f),restoredCounts=await counts(f);assert.deepEqual(restored.state.graph.edges,[edge]);assert.deepEqual(restored.state.unbound,before.state.unbound);assert.deepEqual(restored.state.graph.contributions.find(c=>c.id===manual.id),manual);assert.deepEqual(restored.state.graph.contributions.find(c=>c.id===later.c.id),later.c);
 assert.deepEqual(restoredShop.meals.find(m=>m.occurrenceId===f.occurrenceId).meal,beforeShop.meals.find(m=>m.occurrenceId===f.occurrenceId).meal);assert.deepEqual(restored.state.graph.contributions.find(c=>c.id===edge.demandId),before.state.graph.contributions.find(c=>c.id===edge.demandId));
 const undoRetry=await wire(f,'partial-meal-undo-retry',privateState,{survivor:later.c});assert.deepEqual(undoRetry.commands,undoLost.commands);assert.equal(undoRetry.candidateAttempts,0);assert.equal(undoRetry.previewAttempts,0);assert.deepEqual(await page(f),restored);assert.deepEqual(await head(f),restoredShop);assert.deepEqual(await counts(f),restoredCounts);
});

test('actual Swift protected transferred unit change keeps equivalent reviewed quantity detached from all supply',async()=>{
 const {f,manual,edge}=await partialConversionFixture(),before=await page(f),beforeCounts=await counts(f),privateState=await state(),payload=await partialMealPayload(f,{protectedChange:true});
 // A missing basis does not prove that sixty grams preserve two wraps.
 const missing=structuredClone(payload);missing.transferredChanges[0].after.quantity.confirmedConversion=null;
 const denied=await candidate(f,{mode:'change',base:baseOf(before),action:missing.action,change:missing.change,packs:missing.packs,unboundFactIds:missing.unboundFactIds,transferredChanges:missing.transferredChanges});
 assert.equal(denied.status,422);assert.equal(denied.data.error.code,'protected_quantity_reduced');assert.deepEqual(await page(f),before);assert.deepEqual(await counts(f),beforeCounts);
 const reduced=structuredClone(payload);reduced.transferredChanges[0].after.quantity.confirmedConversion.targetAmountPerSourceUnit.denominator='60';
 const reduction=await candidate(f,{mode:'change',base:baseOf(before),action:reduced.action,change:reduced.change,packs:reduced.packs,unboundFactIds:reduced.unboundFactIds,transferredChanges:reduced.transferredChanges});assert.equal(reduction.status,422);assert.equal(reduction.data.error.code,'protected_quantity_reduced');assert.deepEqual(await page(f),before);assert.deepEqual(await counts(f),beforeCounts);
 const applied=await wire(f,'partial-protected-apply',privateState,payload);exactPartialCatalog(applied,payload);const reviewed=exactApply(applied);const after=await page(f);
 assert.deepEqual(after.state,reviewed.c.after);assert.deepEqual(after.state.graph.contributions,before.state.graph.contributions);assert.deepEqual(after.state.graph.edges,[edge]);assert.deepEqual(after.state.graph.contributions.find(c=>c.id===manual.id),manual);assert.deepEqual(after.state.graph.usedIds,before.state.graph.usedIds);
 const transfer=after.state.unbound.find(u=>u.factId===payload.transferredChanges[0].factId);assert.deepEqual(transfer.transferred,payload.transferredChanges[0].after);assert.equal(transfer.transferred.quantity.amount.numerator,'60');assert.equal(transfer.transferred.quantity.unit,'gram');assert.equal(transfer.transferred.quantity.confirmedConversion.targetAmountPerSourceUnit.denominator,'30');assert.deepEqual(after.coverage.allocatableUnboundFactIds,[]);assert.equal(after.coverage.status,'partial');
});
