import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import pg from 'pg';
import {trackingPrivacyFixtures,labelDigest} from './shared-demand-tracking-privacy-fixture.mjs';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {bodySchemas} from '../dist/contracts.js';
import {digest} from '../dist/database.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {PrivacyService,PrivacyMaintenance} from '../dist/privacy.js';
import {openPrivacyJournalFixture} from './privacy-journal-fixture.mjs';
import {createHTTPServer} from '../dist/http.js';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL});
let runtimeQueries=0;runtime.on('connect',client=>{const query=client.query.bind(client);client.query=(...args)=>{runtimeQueries++;return query(...args);};});
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
async function preview(f,input,a=f.owner){return call(a,f.path+'/demand/previews','POST',input);}
async function apply(f,input,p,a=f.owner){const command={v:1,replayWindow:a.window,clientKey:randomUUID(),shopId:f.shopId,kind:input.action.kind,base:{shopRevision:input.base.shopRevision,authorityEpoch:input.base.authorityEpoch,...(input.action.kind==='request.apply'?{requestRevision:1}:{})},body:{...input.action.body,demandReview:{previewId:p.previewId,previewDigest:p.previewDigest}}};return{command,response:await call(a,f.base+'/commands','POST',command)};}
async function adopt(f){const input=draft(f),p=ok(await preview(f,input)),r=await apply(f,input,p);ok(r.response);return{input,p,...r};}
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

test('tracking v2 atomic first-adoption Cancel, exact acknowledgment, reserved UUID and persisted retry',async()=>{
 const f=await fixture(),before=await page(f),input={...draft(f),base:baseOf(before)},unchanged=await counts(f);
 const c=ok(await candidate(f,input));assert.deepEqual(await counts(f),unchanged);assert.deepEqual(await page(f),before);
 assert.equal((await accept(f,c,f.owner,{...c.disclosure,pickup:{...c.disclosure.pickup,coverageStatement:'complete'}})).status,409);
 const p=ok(await accept(f,c));const reserved=(await admin.query('SELECT operation_id FROM ritc.shared_tracking_preview WHERE household_id=$1 AND preview_id=$2',[f.h,p.previewId])).rows[0].operation_id;
 const a=await commitTracking(f,c,p,input.base),receipt=ok(a.response);assert.equal(receipt.operationId,reserved);
 assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',a.command)),receipt);assert.equal(await count(f,'shared_tracking_adoption'),1);
 const second=await actor(f.owner.subject);await enroll(second,f.h);assert.deepEqual((await page(f,second)).state,c.after);
 assert.equal((await call(second,f.base+'/commands','POST',{...a.command,replayWindow:second.window})).status,409);
});
test('complete first adoption Undo transfers protected unknown identity, preserves later staple and untouched price, then same-ID rebind',async()=>{
 const f=await fixture(),initial=await first(f),later=await addLater(f),before=await page(f),operation=ok(initial.response).operationId;
 const result=await inverse(f,operation,[{lineId:later.extra.lineId,usablePerPack:q(3),acceptUnresolved:false}]),after=await page(f);
 assert.equal(after.coverage.status,'partial');assert.equal(after.coverage.completeFoodCoverage,false);assert.deepEqual(after.coverage.allocatableUnboundFactIds,[]);
 assert.equal(after.state.basket.find(l=>l.id===f.basket.lineId).packs,2);assert.equal(after.state.basket.find(l=>l.id===f.basket.lineId).priceMinor,120);
 assert.deepEqual(after.state.graph.contributions.find(c=>c.id===later.c.id),later.c);assert.deepEqual(after.state.graph.usedIds,before.state.graph.usedIds);
 const protectedFact=after.state.catalog.find(x=>x.source.kind==='reservation'),transfer=after.state.unbound.find(x=>x.factId===protectedFact.id);
 assert.equal(protectedFact.quantity,null);assert.equal(transfer.transferred.id,protectedFact.id);assert.equal(transfer.transferred.source.reservationId,protectedFact.source.reservationId);
 assert.ok(after.state.graph.contributions.find(c=>c.id===initial.manual.id).removedAt);assert.ok(!after.state.graph.contributions.some(c=>c.id===transfer.transferred.id));
 assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',result.command)),ok(result.response));
 const line=before.state.graph.lines.find(l=>l.id===f.basket.lineId),basketRow=after.state.basket.find(l=>l.id===f.basket.lineId);
 await applyIntent(f,{mode:'rebind',base:baseOf(after),bindings:after.state.unbound.map(u=>({factId:u.factId,line,basket:basketRow,packReview:{lineId:line.id,usablePerPack:q(6),acceptUnresolved:true}}))});
 const rebound=await page(f);assert.equal(rebound.state.unbound.length,0);assert.deepEqual(rebound.state.graph.contributions.find(c=>c.id===protectedFact.id),transfer.transferred);assert.deepEqual(rebound.state.graph.usedIds,after.state.graph.usedIds);
});
test('partial state rejects v1 reads, previews, raw Undo, legacy writes and unreviewed freeze without changing state',async()=>{
 const f=await fixture(),a=await first(f);await inverse(f,ok(a.response).operationId);const p=await page(f),before=await counts(f);
 assert.equal((await call(f.owner,f.path+'/demand')).status,409);assert.equal((await call(f.owner,f.path+'/records/snapshot')).status,409);
 assert.equal((await preview(f,{...draft(f),mode:'review',base:{shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,graphRevision:p.state.graph.revision},change:empty()})).status,409);
 assert.equal((await send(f,'shop.patch',{quote:f.quote,lines:[f.basket]},p.shopRevision)).status,409);
 const unreviewedFreeze=await send(f,'shop.freeze',{},p.shopRevision);assert.equal(unreviewedFreeze.status,409);assert.equal(unreviewedFreeze.data.error.code,'tracking_review_required');assert.deepEqual(await counts(f),before);
 const record=ok(await call(f.owner,f.path+'/records/tracking-snapshot'));assert.deepEqual(record.record.food.state.unbound,p.state.unbound);assert.equal(record.record.portableExportAllowed,false);
});
test('explicitly reviewed partial pickup freezes full unknown protection, direct placement retains exact frozen basis',async()=>{
 const f=await fixture(),a=await first(f);await inverse(f,ok(a.response).operationId);const p=await page(f);assert.ok(p.freezeReview);
 const freeze=ok(await send(f,'shop.freeze',{trackingReview:p.freezeReview},p.shopRevision));assert.equal(freeze.shopRevision,p.shopRevision+1);
 const snapshot=(await admin.query('SELECT snapshot FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[f.h,f.shopId,freeze.shopRevision])).rows[0].snapshot;
 assert.deepEqual(snapshot.trackingSeal.snapshot.state.unbound,p.state.unbound);assert.equal(snapshot.trackingSeal.snapshot.review.disclosure.coverage.status,'partial');
 const report=await send(f,'shop.reportPlaced',{occurredAt:new Date().toISOString()},freeze.shopRevision);ok(report);
 assert.equal(ok(await call(f.owner,f.path)).phase,'placed');assert.deepEqual((await page(f)).state.graph.usedIds,p.state.graph.usedIds);
});
test('stale preview and touched pack edit deny first-adoption inverse',async()=>{
 const f=await fixture(),a=await first(f),current=await page(f),intent={mode:'firstAdoptionUndo',base:baseOf(current),targetOperationId:ok(a.response).operationId,packs:[]};const held=ok(await candidate(f,intent));
 await addLater(f);assert.equal((await accept(f,held)).status,409);
 const p=await page(f);const changed={mode:'review',base:baseOf(p),action:{kind:'shop.patch',body:{quote:f.quote,lines:p.state.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.id===f.basket.lineId?4:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible}))}},packs:p.state.packReviews.map(x=>({...x,usablePerPack:q(9)}))};await applyIntent(f,changed);
 assert.equal((await candidate(f,{...intent,base:baseOf(await page(f)),packs:[(await page(f)).state.packReviews.at(-1)]})).status,409,'target pack evidence changed');
});
test('source privacy erases transferred/historical/candidate copies, denies replay and both placement paths, permits selective fresh recovery',async()=>{
 const f=await fixture(),a=await first(f),old=f.owner,other=await invited(f);ok(await send(f,'shop.transferAuthority',{newShopperId:other.id},ok(a.response).shopRevision));f.owner=other;
 // A fresh current-authority review preserves facts but cannot promote old Undo authority.
 const current=await page(f),review={mode:'review',base:baseOf(current),action:{kind:'shop.patch',body:{quote:f.quote,lines:current.state.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible}))}},packs:current.state.packReviews};await applyIntent(f,review);
 const later=await addLater(f),p=await page(f);const held=ok(await candidate(f,{...review,base:baseOf(p),action:{kind:'shop.patch',body:{quote:f.quote,lines:p.state.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible}))}},packs:p.state.packReviews}));
 const frozen=ok(await send(f,'shop.freeze',{trackingReview:p.freezeReview},p.shopRevision,p.authorityEpoch));
 const pendingReport=ok(await send(f,'shop.reportPlaced',{occurredAt:new Date().toISOString()},p.shopRevision,p.authorityEpoch));assert.equal(pendingReport.disposition,'pending_reconciliation');
 const secret='six wraps',deletion={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'transfer',organizerMemberId:other.id,shops:[],eraseChildProfiles:[]}]};ok(await call(old,'/v1/privacy/deletions','POST',deletion),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal((await accept(f,held)).status,409);assert.equal((await call(old,f.base+'/commands','POST',a.command)).status,401);
 for(const table of ['shared_tracking_revision','shared_tracking_adoption','shared_tracking_preview','shared_demand_revision','shop_snapshot','operation_response'])assert.ok(!JSON.stringify((await admin.query('SELECT to_jsonb(t) AS value FROM ritc.'+table+' t WHERE household_id=$1',[f.h])).rows).includes(secret),table);
 const redacted=await page(f);assert.equal(redacted.status,'reviewRequired');assert.ok(redacted.projection.state.graph.usedIds.includes(a.manual.id));assert.deepEqual(redacted.projection.state.graph.contributions.find(c=>c.id===later.c.id),later.c);
 assert.equal((await send(f,'shop.freeze',{},redacted.shopRevision,redacted.authorityEpoch)).status,409);
 assert.equal((await send(f,'shop.reportPlaced',{occurredAt:new Date().toISOString()},frozen.shopRevision,redacted.authorityEpoch)).status,409);
 assert.equal((await send(f,'shop.reconcileReport',{reportId:pendingReport.reportId,choice:'apply'},redacted.shopRevision,redacted.authorityEpoch)).status,409);
 ok(await send(f,'shop.reopen',{},redacted.shopRevision,redacted.authorityEpoch));const opened=await page(f);
 const survivorPacks=[{lineId:later.extra.lineId,usablePerPack:q(3),acceptUnresolved:false}];await applyIntent(f,{mode:'recover',base:baseOf(opened),packs:survivorPacks});
 const recovered=await page(f);assert.equal(recovered.status,'enabled');assert.deepEqual(recovered.state.graph.contributions.find(c=>c.id===later.c.id),later.c);assert.ok(recovered.freezeReview);
});
test('nonshopper and cross-household tracking access deny before any content; feature default stays off',async()=>{
 const f=await fixture(),other=await invited(f),foreign=await fixture();assert.equal((await call(other,f.path+'/demand/tracking')).status,404);assert.equal((await call(foreign.owner,f.path+'/demand/tracking')).status,404);
 const disabled=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)}),s=createHTTPServer({repository:disabled,verifier,maxRequestsPerMinute:20000});await new Promise(r=>s.listen(0,'127.0.0.1',r));
 try{const response=await fetch('http://127.0.0.1:'+s.address().port+f.path+'/demand/tracking',{headers:{Authorization:'Bearer '+f.owner.token,'X-Device-Token':f.owner.device}});assert.equal(response.status,404);}finally{await new Promise(r=>s.close(r));}
});
async function legacySelectedStore(f,author){
 const before=ok(await call(f.owner,f.path)),path=f.path+'/store-quotes';
 const envelope=(extra={},grantRevision=0)=>({operationId:randomUUID(),shopRevision:before.shopRevision,authorityEpoch:before.authorityEpoch,grantRevision,...extra});
 ok(await call(f.owner,path+'/grants','POST',envelope({adultId:author.id,enabled:true,targetRevision:0})));
 const option={label:'Reviewed selection',store:'Same store',branch:'A',mode:'pickup',slot:new Date(Date.now()+3600000).toISOString(),observedAt:new Date(Date.now()-60000).toISOString(),source:'Entered checkout',currency:'USD',terms:'Complete quote',itemsMinor:200,checkoutMinor:200,allChargesIncluded:true,available:true,quantitiesMatched:true,singleStore:true,tripAlreadyPlanned:true,tripMinor:0,extraMinutes:0,capMinor:10000,capScope:'wholeCheckout',eligibilityConfirmed:true};
 const pair=envelope({options:{first:option,second:{...option,branch:'B'}}},1);ok(await call(author,path+'/pairs','POST',pair));
 const proposal=envelope({pairId:pair.operationId,choice:'first'},1);ok(await call(author,path+'/proposals','POST',proposal));
 const selected=ok(await call(f.owner,path+'/adoptions','POST',envelope({pairId:pair.operationId,choice:'first',proposalId:proposal.operationId})));
 ok(await send(f,'shop.patch',{quote:before.quote,lines:before.lines,reviewedStoreBasisRevision:selected.shopRevision},selected.shopRevision));return selected;
}
async function revokeSelection(f,author){const p=await page(f);ok(await call(f.owner,f.path+'/store-quotes/grants','POST',{operationId:randomUUID(),shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,grantRevision:0,adultId:author.id,enabled:false,targetRevision:1}));}
test('first-adoption compensation preserves unchanged selected-store permission at first Apply and retained receipt replay',async()=>{
 const f=await fixture(),author=await invited(f);const selected=await legacySelectedStore(f,author),a=await first(f,{withMeal:false}),p=await page(f);
 const c=ok(await candidate(f,{mode:'firstAdoptionUndo',base:baseOf(p),targetOperationId:ok(a.response).operationId,packs:[]})),review=ok(await accept(f,c)),applied=await commitTracking(f,c,review,baseOf(p));ok(applied.response);
 assert.equal(ok(await call(f.owner,f.path)).storeBasisRevision,selected.shopRevision);await revokeSelection(f,author);const unchanged=await counts(f);
 assert.equal((await call(f.owner,f.base+'/commands','POST',applied.command)).status,409);assert.deepEqual(await counts(f),unchanged);
 const g=await fixture(),writer=await invited(g);await legacySelectedStore(g,writer);const target=await first(g,{withMeal:false}),current=await page(g);
 const held=ok(await candidate(g,{mode:'firstAdoptionUndo',base:baseOf(current),targetOperationId:ok(target.response).operationId,packs:[]})),accepted=ok(await accept(g,held));await revokeSelection(g,writer);const before=await counts(g);
 assert.equal((await commitTracking(g,held,accepted,baseOf(current))).response.status,409);assert.deepEqual(await counts(g),before);
});
test('preview-only author erasure invalidates another shopper copied intent before any tracking provenance exists',async()=>{
 const f=await fixture(),author=await invited(f),secret='Uncommitted source wording';const sent=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:secret,ownQuantity:'two wraps?',authoredAt:new Date().toISOString()},1,1,author));
 const rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId:sent.request.requestId,base:{shopRevision:1,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 ok(await send(f,'request.apply',{requestId:sent.request.requestId,previewId:rp.previewId,acceptUnknown:false,acceptOverage:false},1,1,f.owner,{base:{shopRevision:1,authorityEpoch:1,requestRevision:1}}));
 const page0=await page(f),fact=page0.state.catalog.find(x=>x.source.kind==='request'),input={...draft(f),base:baseOf(page0)};input.change.contributions.push({...source(f,null),source:fact.source,originalText:fact.originalText});input.packs[0].acceptUnresolved=true;
 const c=ok(await candidate(f,input));ok(await accept(f,c));assert.equal(await count(f,'shared_tracking_revision'),0);assert.equal(await count(f,'shared_tracking_source_member'),0);
 assert.ok(JSON.stringify((await admin.query('SELECT intent,review FROM ritc.shared_tracking_preview WHERE household_id=$1',[f.h])).rows).includes(secret));
 ok(await call(author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal(await count(f,'shared_tracking_preview'),0);assert.equal((await accept(f,c)).status,409);assert.equal(await count(f,'shared_tracking_adoption'),0);
});

test('partial tracking accepts an explicitly reviewed request link without hiding unbound protected meal facts',async()=>{
 const f=await fixture(),a=await first(f);await inverse(f,ok(a.response).operationId);const author=await invited(f),p=await page(f);
 const request=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Guest wraps',ownQuantity:'maybe two?',authoredAt:new Date().toISOString()},p.shopRevision,p.authorityEpoch,author));
 const money=ok(await call(f.owner,f.path+'/previews','POST',{requestId:request.request.requestId,base:{shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 const newSource={...source(f,null),source:{kind:'request',requestId:request.request.requestId,appliedRequestRevision:1},originalText:'Guest wraps'};
 const oldLine=p.state.graph.lines.find(l=>l.id===f.basket.lineId),input={mode:'change',base:baseOf(p),change:{...empty(),lines:[{...oldLine,trashedAt:null}],contributions:[newSource]},unboundFactIds:p.state.unbound.map(u=>u.factId),action:{kind:'request.apply',body:{requestId:request.request.requestId,previewId:money.previewId,acceptUnknown:false,acceptOverage:false}},packs:[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:true}]};
 const result=await applyIntent(f,input),after=await page(f);assert.deepEqual(after.state.unbound,p.state.unbound);assert.deepEqual(after.state.graph.contributions.find(c=>c.id===newSource.id),newSource);
 const saved=after.state.catalog.find(c=>c.source.kind==='request');assert.equal(saved.originalQuantityText,'maybe two?');assert.equal(saved.quantity,null);assert.equal(saved.requiredLineId,f.basket.lineId);assert.equal(saved.source.appliedRequestRevision,1);
 assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',result.command)),ok(result.response));assert.equal(after.coverage.status,'partial');
});
test('compound first adoption plus request acceptance retains original v1 route but receives no invented full-operation lineage',async()=>{
 const f=await fixture(),author=await invited(f),p=await page(f),request=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Request at first tracking',ownQuantity:'some wraps',authoredAt:new Date().toISOString()},1,1,author));
 const money=ok(await call(f.owner,f.path+'/previews','POST',{requestId:request.request.requestId,base:{shopRevision:1,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 const requested={...source(f,null),source:{kind:'request',requestId:request.request.requestId,appliedRequestRevision:1},originalText:'Request at first tracking'};
 const input={...draft(f),base:baseOf(p),action:{kind:'request.apply',body:{requestId:request.request.requestId,previewId:money.previewId,acceptUnknown:false,acceptOverage:false}}};input.change.contributions.push(requested);input.packs[0].acceptUnresolved=true;
 const rejected=await candidate(f,input);assert.equal(rejected.status,409);assert.equal(rejected.data.error.code,'tracking_first_adoption_scope');assert.equal(await count(f,'shared_tracking_adoption'),0);
 const legacy={...input,base:{shopRevision:1,authorityEpoch:1,graphRevision:0}};const accepted=await apply(f,legacy,ok(await preview(f,legacy)));ok(accepted.response);
 assert.equal(await count(f,'shared_tracking_adoption'),0);assert.equal(await count(f,'shared_tracking_revision'),0);
 const now=await page(f);const denied=await candidate(f,{mode:'firstAdoptionUndo',base:baseOf(now),targetOperationId:ok(accepted.response).operationId,packs:[]});assert.equal(denied.status,409);assert.equal(denied.data.error.code,'tracking_history_unavailable');
});
test('selective erasure retains another author transferred protected identities through review recovery',async()=>{
 const f=await fixture(),owner=f.owner,other=await invited(f),occurrences=[];let revision=1,epoch=1;
 const meal=(title,ingredient)=>({title,day:null,kind:'dinner',portions:3,protected:false,planning:{groups:[{id:randomUUID(),name:'Protected lunch',servings:{numerator:1,denominator:1},protected:true}],ingredients:[{id:randomUUID(),name:ingredient,quantity:{amount:{numerator:6,denominator:1},unit:'count',originalLiteral:'six wraps'},groupIds:[],exclusions:[]}],exclusions:[]}});
 const a=meal('Retained dinner','Retained wraps');a.planning.ingredients[0].groupIds=[a.planning.groups[0].id];const aid=randomUUID();occurrences.push(aid);
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:aid,baseMealRevision:null,meal:a}},revision++,epoch));
 ok(await send(f,'shop.transferAuthority',{newShopperId:other.id},revision,epoch));f.owner=other;epoch++;
 const b=meal('Private author dinner','Unique erased ingredient');b.planning.ingredients[0].groupIds=[b.planning.groups[0].id];const bid=randomUUID();
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:bid,baseMealRevision:null,meal:b}},revision++,epoch));
 ok(await send(f,'shop.transferAuthority',{newShopperId:owner.id},revision,epoch,owner));f.owner=owner;epoch++;
 const legacy=await page(f),input={...draft(f),base:baseOf(legacy)};input.packs[0].acceptUnresolved=true;input.change.contributions.push(...legacy.state.catalog.map(fact=>({...source(f,fact.quantity),id:fact.id,source:fact.source,originalText:fact.originalText,sourceExclusions:fact.sourceExclusions})));const accepted=await applyIntent(f,input);
 await inverse(f,ok(accepted.response).operationId);const before=await page(f),retainedIDs=before.state.catalog.filter(x=>(x.source.occurrenceId??x.source.originOccurrenceId)===aid).map(x=>x.id),retained=before.state.unbound.filter(x=>retainedIDs.includes(x.factId));assert.equal(retained.length,2);
 ok(await call(other,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 const redacted=await page(f);assert.deepEqual(redacted.projection.state.unbound,retained);assert.deepEqual(redacted.projection.state.graph.usedIds,before.state.graph.usedIds);
 for(const table of ['shared_tracking_revision','shared_tracking_adoption','shared_tracking_preview','shop_snapshot'])assert.ok(!JSON.stringify((await admin.query('SELECT to_jsonb(t) AS value FROM ritc.'+table+' t WHERE household_id=$1',[f.h])).rows).includes('Unique erased ingredient'),table);
 await applyIntent(f,{mode:'recover',base:baseOf(redacted),packs:[]});const after=await page(f);assert.deepEqual(after.state.unbound,retained);assert.equal(after.coverage.protectedUnboundFactIds.length,1);assert.equal(after.coverage.completeFoodCoverage,false);
});

const privacyCases=trackingPrivacyFixtures({fixture,source,q,empty,draft,page,baseOf,applyIntent,invited,send,ok,call,admin});
test('link-only author erasure removes exactly that relationship and preserves unrelated sources, edges, used IDs and tombstones through recovery',async()=>{
 const c=await privacyCases.linkAuthor();await privacyCases.erase(c.f,c.eraser);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 await privacyCases.assertProjection(c);assert.equal((await call(c.eraser,c.f.base+'/commands','POST',c.committed.command)).status,401);
 await privacyCases.recover(c);
});
test('legacy copied labels are erased while independently authored matching manual text and a later independent rename survive',async()=>{
 const c=await privacyCases.legacyLabel();await privacyCases.erase(c.f,c.eraser,true);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 await privacyCases.assertProjection(c);assert.equal((await call(c.f.owner,c.f.base+'/commands','POST',c.adopted.command)).status,409);await privacyCases.recover(c);
});
test('exact label digest has a distinct UTF-8 domain and never coerces null, missing, normalization or whitespace',async()=>{
 const labels=['','a',' a ','café','cafe\u0301','"quoted"','null'];
 for(const label of labels){const r=(await admin.query('SELECT ritc.tracking_label_digest($1::text) AS hash',[label])).rows[0];assert.equal(r.hash,labelDigest(label));}
 const r=(await admin.query("SELECT ritc.tracking_label_digest(NULL::text) AS a,ritc.tracking_label_digest('{}'::jsonb->>'missing') AS b,ritc.tracking_label_digest('{\"name\":null}'::jsonb->>'name') AS c")).rows[0];assert.deepEqual(r,{a:null,b:null,c:null});
 assert.equal(new Set(labels.map(labelDigest)).size,labels.length);
});
test('046 erasure keeps 047 content-free first-use proof but cannot revive erased created-meal history or replay',async()=>{
 const f=await fixture(),firstAdoption=await first(f,{withMeal:false}),eraser=f.owner,other=await invited(f),p=await page(f),occurrenceId=randomUUID();
 const meal={title:'Private created dinner',day:null,kind:'dinner',portions:2,protected:false};
 const added=await applyIntent(f,{mode:'change',base:baseOf(p),change:{...empty(),contributions:[source(f,q(1))]},unboundFactIds:[],action:{kind:'shop.patch',body:{quote:f.quote,lines:p.state.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible})),mealEdit:{occurrenceId,baseMealRevision:null,meal}}},packs:p.state.packReviews});
 const operationId=ok(added.response).operationId,identity=(await admin.query('SELECT * FROM ritc.shared_meal_occurrence_identity WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3',[f.h,f.shopId,occurrenceId])).rows;
 assert.equal(identity.length,1);assert.equal(identity[0].first_operation_id,operationId);assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_food_meal_creation_effect WHERE household_id=$1 AND operation_id=$2',[f.h,operationId])).rows[0].n,1);
 const current=await page(f);ok(await send(f,'shop.transferAuthority',{newShopperId:other.id},current.shopRevision,current.authorityEpoch));f.owner=other;
 await privacyCases.erase(f,eraser,true);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.deepEqual((await admin.query('SELECT * FROM ritc.shared_meal_occurrence_identity WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3',[f.h,f.shopId,occurrenceId])).rows,identity);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3',[f.h,f.shopId,occurrenceId])).rows[0].n,0);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_food_meal_creation_effect WHERE household_id=$1 AND operation_id=$2',[f.h,operationId])).rows[0].n,1);
 const erased=await page(f);await applyIntent(f,{mode:'recover',base:baseOf(erased),packs:[]});
 assert.equal((await call(eraser,f.base+'/commands','POST',added.command)).status,401);
 assert.equal((await candidate(f,{mode:'firstAdoptionUndo',base:baseOf(await page(f)),targetOperationId:ok(firstAdoption.response).operationId,packs:[]})).status,409);
 for(const table of ['shared_tracking_revision','shared_tracking_adoption','shared_tracking_preview','shared_demand_revision','shop_snapshot','operation_response'])assert.ok(!JSON.stringify((await admin.query('SELECT to_jsonb(t) value FROM ritc.'+table+' t WHERE household_id=$1',[f.h])).rows).includes(meal.title),table);
});

test('privacy extension delegates only unrelated legacy no-op work and still clears legacy-only hashes under a real worker lease',async()=>{
 const f=await fixture(),original=f.owner,other=await invited(f);
 const origins=async()=> (await admin.query('SELECT line_id,label_digest,member_id FROM ritc.shared_tracking_basket_origin WHERE household_id=$1 ORDER BY line_id,label_digest,member_id',[f.h])).rows;
 const before=await origins();assert.ok(before.some(r=>r.member_id===original.id));assert.equal(await count(f,'shared_demand_revision'),0);
 await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,original.id]);assert.deepEqual(await origins(),before,'unauthorized no-op delegation does not mutate new immutable evidence');
 await assert.rejects(runtime.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,original.id]),e=>e.code==='42501');
 const g=await fixture(),p=await page(g),held=ok(await candidate(g,{...draft(g),base:baseOf(p)}));
 await assert.rejects(admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[g.h,g.owner.id]),e=>e.code==='P0001'&&e.message==='erasure authority required');
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_tracking_preview WHERE household_id=$1 AND preview_id=$2',[g.h,held.candidateId])).rows[0].n,1,'failed unauthorized call leaves preview intact');
 ok(await send(f,'shop.transferAuthority',{newShopperId:other.id},1));f.owner=other;
 await privacyCases.erase(f,original,true);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal((await origins()).filter(r=>r.member_id===original.id).length,0,'authorized erasure purges target hashes even without any graph/tracking row');
});
