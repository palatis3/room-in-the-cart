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
assert.equal(process.env.RITC_TEST_NATIVE_WIRE,'1','Use the explicit native-wire runner; this file is not an ordinary database test');
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL});
let runtimeQueries=0;runtime.on('connect',client=>{const query=client.query.bind(client);client.query=(...args)=>{runtimeQueries++;return query(...args);};});
const issuer='https://operation-undo.fixture.invalid';const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='fixture';
const verifier=new JWTIdentityVerifier({issuer,audience:'authenticated',jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]})),repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
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


test('actual Swift complete operation Undo preserves durable replay, later facts and privacy authority over HTTPS and PostgreSQL',async()=>{
 const {exerciseOperationUndoClient}=await import('./shared-operation-undo-native-wire.mjs');
 const {mkdtemp,chmod,readFile}=await import('node:fs/promises');const {join}=await import('node:path');
 assert.ok(process.env.RITC_NATIVE_WIRE_STATE,'Use the existing custody wrapper');
 const state=async()=>{const p=await mkdtemp(join(process.env.RITC_NATIVE_WIRE_STATE,'operation-undo-client-'));await chmod(p,0o700);return p;};
 const counters=async f=>({operations:await count(f,'operation'),graphs:await count(f,'shared_demand_revision'),snapshots:await count(f,'shop_snapshot'),effects:await count(f,'shared_food_operation_effect'),previews:await count(f,'shared_demand_preview')});
 const page=async f=>ok(await call(f.owner,f.path+'/demand'));
 const commit=async(f,change,lines,quote,packs)=>{
  const p=await page(f),input={mode:change.contributions.length||change.lines.length?'change':'review',base:{shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,graphRevision:p.graph.revision},change,action:{kind:'shop.patch',body:{quote,lines}},packs};
  return ok((await apply(f,input,ok(await preview(f,input)))).response);
 };
 const setup=async()=>{
  const f=await fixture(),initial=await adopt(f),original=source(f,q(4));original.originalText='Exact target extra wraps';
  const quote={...f.quote,capMinor:f.quote.capMinor+100},lines=[{...f.basket,packs:3}],packs=[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:false}];
  const target=await commit(f,{...empty(),contributions:[original]},lines,quote,packs);
  return{...f,target,initial,original,currentLines:lines,currentQuote:quote,packs};
 };
 const wire=async(f,phase,privateState,extra={})=>exerciseOperationUndoClient({service:server,owner:f.owner,householdId:f.h,shopId:f.shopId,phase,targetOperationId:f.target.operationId,packs:f.packs,
  before:phase==='revoked'?null:await page(f),privateState,...extra});
 const f=await setup(),author=f.owner,shopper=await invited(f),privateState=await state();
 const prior=await page(f);ok(await send(f,'shop.transferAuthority',{newShopperId:shopper.id},prior.shopRevision,prior.authorityEpoch));f.owner=shopper;
 const laterLine={lineId:randomUUID(),originalItem:'Unrelated later staple',packs:1,unitPriceMinor:250,feeEligible:false};
 const laterSource={...source(f,q(1)),lineId:laterLine.lineId,productKey:'staple',productName:'Staple',originalText:'Unrelated later staple source'};
 f.currentLines=[{...f.currentLines[0],unitPriceMinor:150},laterLine];f.packs.push({lineId:laterLine.lineId,usablePerPack:q(1),acceptUnresolved:false});
 await commit(f,{...empty(),lines:[{id:laterLine.lineId,name:laterLine.originalItem,unit:'count',originalOrder:9,trashedAt:null}],contributions:[laterSource]},f.currentLines,f.currentQuote,f.packs);
 const assertReviewRequests=(observed,current,fixture)=>{
  const expected={shopRevision:current.shopRevision,authorityEpoch:current.authorityEpoch,graphRevision:current.graph.revision,graphDigest:current.graphDigest};
  assert.deepEqual(JSON.parse(observed.candidateRequests[0]),{targetOperationId:fixture.target.operationId,base:expected});
  const reviewed=JSON.parse(observed.previewRequests[0]);assert.deepEqual(Object.keys(reviewed).sort(),['base','effectDigest','packs','targetOperationId']);
  assert.deepEqual(reviewed.base,expected);assert.equal(reviewed.targetOperationId,fixture.target.operationId);assert.deepEqual(reviewed.packs,fixture.packs);assert.match(reviewed.effectDigest,/^[a-f0-9]{64}$/);
 };
 const before=await page(f),shopBefore=ok(await call(f.owner,f.path)),counts=await counters(f);
 const cancel=await wire(f,'cancel',privateState);assert.equal(cancel.attempts,0);assert.equal(cancel.candidateAttempts,1);assert.equal(cancel.previewAttempts,1);assertReviewRequests(cancel,before,f);
 assert.deepEqual(await page(f),before);assert.deepEqual(ok(await call(f.owner,f.path)),shopBefore);
 assert.deepEqual(await counters(f),{...counts,previews:counts.previews+1},'Cancel creates only an expiring preview, never a domain revision or operation');
 const first=await wire(f,'apply-lost',privateState,{dropFirstReply:true});assert.equal(first.attempts,1);assert.equal(first.dropped,1);assert.equal(first.candidateAttempts,1);assert.equal(first.previewAttempts,1);assertReviewRequests(first,before,f);
 const expectation=JSON.parse(await readFile(join(privateState,'undo-expectation.json'),'utf8'));
 const afterCommit=await page(f),shopAfter=ok(await call(f.owner,f.path));assert.deepEqual(afterCommit.graph,expectation.afterGraph);assert.deepEqual(afterCommit.totals,expectation.afterTotals);
 assert.deepEqual(afterCommit.graph.contributions.find(c=>c.id===laterSource.id),laterSource);assert.deepEqual(shopAfter.lines.find(l=>l.lineId===laterLine.lineId),laterLine);
 assert.deepEqual(shopAfter.lines.find(l=>l.lineId===f.basket.lineId),{...f.basket,unitPriceMinor:150});assert.deepEqual(shopAfter.quote,f.quote);
 assert.ok(afterCommit.graph.contributions.find(c=>c.id===f.original.id).removedAt);assert.deepEqual(afterCommit.graph.contributions.find(c=>c.id===initialSource(f).id),initialSource(f));
 assert.deepEqual(await counters(f),{...counts,operations:counts.operations+1,graphs:counts.graphs+1,snapshots:counts.snapshots+1,effects:counts.effects+1,previews:counts.previews+1});
 const retry=await wire(f,'retry',privateState);assert.equal(retry.attempts,1);assert.equal(retry.candidateAttempts,0);assert.equal(retry.previewAttempts,0);assert.deepEqual(retry.commands,[first.commands[0]]);
 assert.deepEqual(await page(f),afterCommit);assert.equal(await count(f,'operation'),counts.operations+1);
 const inverses=(await admin.query('SELECT operation_id,reverses_operation_id FROM ritc.shared_food_operation_effect WHERE household_id=$1 AND shop_id=$2 AND reverses_operation_id=$3',[f.h,f.shopId,f.target.operationId])).rows;
 assert.deepEqual(inverses,[{operation_id:expectation.reservedOperationID,reverses_operation_id:f.target.operationId}]);
 // A different household makes a real later touched-field write after Swift's final review.
 const stale=await setup(),staleState=await state(),staleCounts=await counters(stale);let changed=0;
 const rejected=await wire(stale,'stale',staleState,{beforeCommand:async attempt=>{
  assert.equal(attempt,1);changed++;stale.currentLines=[{...stale.currentLines[0],packs:4}];
  await commit(stale,empty(),stale.currentLines,stale.currentQuote,stale.packs);
 }});
 assert.equal(changed,1);assert.equal(rejected.attempts,1);assert.equal(rejected.candidateAttempts,2);assert.equal(rejected.previewAttempts,1);
 assert.equal(await count(stale,'operation'),staleCounts.operations+1);assert.equal(await count(stale,'shared_demand_revision'),staleCounts.graphs+1);
 assert.equal(ok(await call(stale.owner,stale.path)).lines[0].packs,4);assert.deepEqual((await page(stale)).graph.contributions.find(c=>c.id===stale.original.id),stale.original);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_food_operation_effect WHERE household_id=$1 AND reverses_operation_id=$2',[stale.h,stale.target.operationId])).rows[0].n,0);
 // The original source author is erased after their former shopper role has ended.
 ok(await call(author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'transfer',organizerMemberId:shopper.id,shops:[],eraseChildProfiles:[]}]}),202);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);const erased=await page(f),erasedCounts=await counters(f);
 assert.equal(erased.status,'reviewRequired');assert.ok(!JSON.stringify(erased).includes('Exact target extra wraps'));assert.deepEqual(erased.graph.contributions.find(c=>c.id===laterSource.id),laterSource);
 const privacyResult=await wire(f,'privacy',privateState);assert.equal(privacyResult.attempts,1);assert.deepEqual(privacyResult.commands,[first.commands[0]]);assert.deepEqual(await counters(f),erasedCounts);assert.deepEqual(await page(f),erased);
 const successor=await invited(f);ok(await send(f,'shop.transferAuthority',{newShopperId:successor.id},erased.shopRevision,erased.authorityEpoch));
 const revokedCounts=await counters(f),revoked=await wire(f,'revoked',privateState);
 assert.equal(revoked.attempts,1,'Only adversarial raw replay reaches HTTP; typed client must deny before sending');assert.deepEqual(revoked.commands,[first.commands[0]]);assert.deepEqual(await counters(f),revokedCounts);
});
function initialSource(f){return f.initial.input.change.contributions[0];}
