/** Actual HTTP/PG cases; run only through the established disposable DB/journal harness.
 * Domain writes use public commands. The explicitly labelled internal-price case
 * uses the existing server-only writer; it is not a newly exposed HTTP mutation.
 */
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
import {digest} from '../dist/database.js';

const applicationName='shared-records-'+randomUUID();
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL});
const runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL,application_name:applicationName});
const worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL});
let watchDenied=false,deniedContentReads=0;
runtime.on('connect',client=>{const query=client.query.bind(client);client.query=(...args)=>{
 const sql=typeof args[0]==='string'?args[0]:args[0]?.text??'';
 if(watchDenied&&/\britc\.(?:shared_demand_revision|basket_line|shared_meal_revision|request_link|shop_snapshot)\b/.test(sql))deniedContentReads++;
 return query(...args);
};});
const issuer='https://shared-records.fixture.invalid';
const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='fixture';
const verifier=new JWTIdentityVerifier({issuer,audience:'authenticated',jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]}));
const repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
const journal=await openPrivacyJournalFixture(admin);
const provider={assertAvailable:async()=>{},deleteAccount:async subject=>{await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);}};
const privacy=new PrivacyService(repo,{provider,journal:journal.port,policy:{receiptRetentionDays:1,erasureMarkerRetentionDays:2,verifiedBackupRetentionDays:1}});
const maintenance=new PrivacyMaintenance(worker,{provider,journal:journal.port});
const server=createHTTPServer({repository:repo,verifier,privacy,maxRequestsPerMinute:20000});let origin;
before(async()=>{await new Promise(r=>server.listen(0,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;});
after(async()=>{await new Promise(r=>server.close(r));await journal.close();await Promise.all([admin.end(),runtime.end(),worker.end()]);});
async function actor(subject=randomUUID()){
 const session=randomUUID();await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);
 return{subject,session,token:await new SignJWT({session_id:session,amr:[{method:'otp',timestamp:Math.floor(Date.now()/1000)}]})
  .setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setSubject(subject).setAudience('authenticated').setIssuedAt().setExpirationTime('1h').sign(privateKey)};
}
async function call(a,path,method='GET',body){
 const r=await fetch(origin+path,{signal:AbortSignal.timeout(15000),method,headers:{Authorization:'Bearer '+a.token,...(a.device?{'X-Device-Token':a.device}:{}),...(body===undefined?{}:{'Content-Type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})});
 return{status:r.status,data:await r.json()};
}
function ok(r,status=200){assert.equal(r.status,status,JSON.stringify(r.data));return r.data;}
async function enroll(a,h){a.device=ok(await call(a,`/v1/households/${h}/devices`,'POST',{}),201).deviceToken;a.window=ok(await call(a,`/v1/households/${h}/replay-windows`,'POST',{})).id;}
const q=n=>({amount:{numerator:String(n),denominator:'1'},unit:'count',originalLiteral:n+' wraps',confirmedConversion:null});
const empty=()=>({lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[]});
async function send(f,kind,body,base,a=f.owner){return call(a,f.base+'/commands','POST',{v:1,replayWindow:a.window,clientKey:randomUUID(),shopId:f.shopId,kind,base,body});}
async function invite(f){const a=await actor(),i=ok(await call(f.owner,f.base+'/invites','POST',{kind:'adult_contributor'}));a.id=ok(await call(a,'/v1/invites/redeem','POST',{token:i.token,intent:'join',adultAttestation:true,alias:'Contributor'})).memberId;await enroll(a,f.h);return a;}
async function apply(f,input,preview){return send(f,input.action.kind,{...input.action.body,demandReview:{previewId:preview.previewId,previewDigest:preview.previewDigest}},
 {shopRevision:input.base.shopRevision,authorityEpoch:input.base.authorityEpoch});}
async function fixture(){
 const owner=await actor(),created=ok(await call(owner,'/v1/households','POST',{clientKey:randomUUID(),label:'Shared Records fixture',alias:'Shopper',adultAttestation:true}),201);
 owner.id=created.memberId;await enroll(owner,created.householdId);
 const h=created.householdId,shopId=randomUUID(),base='/v1/households/'+h,path=base+'/shops/'+shopId;
 const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,
  observedAt:new Date(Date.now()-60000).toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()};
 const basket={lineId:randomUUID(),originalItem:'Shared wraps',packs:2,unitPriceMinor:100,feeEligible:true};
 const f={owner,h,shopId,base,path,quote,basket};ok(await send(f,'shop.create',{quote,lines:[basket]},{shopRevision:0,authorityEpoch:0}));
 let revision=1;const meals=[];
 for(const [title,n,protectedMeal] of [['Tacos',6,false],['Quesadillas',4,false],['Lunch',2,true]]){
  const occurrenceId=randomUUID(),ingredientId=randomUUID(),groupId=randomUUID(),bindingId=randomUUID();
  const quantity={amount:{numerator:n,denominator:1},unit:'count',originalLiteral:n+' wraps'};
  const meal={title,day:null,kind:protectedMeal?'lunch':'dinner',portions:n,protected:protectedMeal,planning:{groups:[{id:groupId,name:title,servings:{numerator:n,denominator:1},protected:protectedMeal}],
   ingredients:[{id:ingredientId,name:'Wraps',quantity,groupIds:[groupId],exclusions:[]}],bindings:[{id:bindingId,groupId,ingredientId,quantity}]}};
  ok(await send(f,'shop.patch',{quote,lines:[basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},{shopRevision:revision++,authorityEpoch:1}));meals.push({occurrenceId,ingredientId,groupId,bindingId,meal});
 }
 const author=await invite(f),wording='Records contributor wording '+randomUUID(),literal='one packet if available';
 const requested=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:wording,ownQuantity:literal,authoredAt:new Date().toISOString()},{shopRevision:revision,authorityEpoch:1},author)).request;
 const decision=ok(await call(owner,path+'/previews','POST',{requestId:requested.requestId,base:{shopRevision:revision,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:basket.lineId,promote:false}}));
 ok(await send(f,'request.apply',{requestId:requested.requestId,previewId:decision.previewId,acceptOverage:false,acceptUnknown:false},{shopRevision:revision++,authorityEpoch:1,requestRevision:1}));
 const legacy=ok(await call(owner,path+'/demand'));
 const manual={id:randomUUID(),lineId:basket.lineId,source:{kind:'manual'},productKey:'wraps',productName:'Wraps',originalText:'12 manually recorded wraps',quantity:q(12),exclusions:[],contains:[],removedAt:null};
 const sources=legacy.legacySources.sources.map(s=>({id:s.id,lineId:s.requiredLineId??basket.lineId,source:s.source,productKey:'wraps',productName:s.productName,originalText:s.originalText,quantity:s.quantity,sourceExclusions:s.sourceExclusions,exclusions:[],contains:[],removedAt:null}));
 const edges=sources.filter(c=>c.quantity!==null).map(c=>({id:randomUUID(),kind:'withinExisting',demandId:c.id,supplyId:manual.id,quantity:c.quantity,
  confirmation:{productMatchConfirmed:true,confirmedAt:new Date().toISOString(),evidence:'Explicit same-wraps allocation inside manual twelve'}}));
 const input={mode:'adopt',base:{shopRevision:revision,authorityEpoch:1,graphRevision:0},change:{...empty(),lines:[{id:basket.lineId,name:basket.originalItem,unit:'count',originalOrder:0,trashedAt:null}],contributions:[manual,...sources],edges},
  action:{kind:'shop.patch',body:{quote,lines:[basket]}},packs:[{lineId:basket.lineId,usablePerPack:q(6),acceptUnresolved:true}]};
 const preview=ok(await call(owner,path+'/demand/previews','POST',input));ok(await apply(f,input,preview));
 return{...f,author,wording,literal,requestId:requested.requestId,meals,input,preview,revision:revision+1};
}
const snapshot=f=>call(f.owner,f.path+'/records/snapshot');
async function persisted(f){
 const shop=ok(await call(f.owner,f.path)),demand=ok(await call(f.owner,f.path+'/demand'));
 const graph=(await admin.query('SELECT revision,predecessor,created_at,graph_digest,pack_review,graph FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[f.h,f.shopId,demand.graph.revision])).rows[0];
 const latest=(await admin.query('SELECT revision,created_at,digest FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 ORDER BY revision DESC LIMIT 1',[f.h,f.shopId])).rows[0];
 return{shop,demand,graph,latest};
}
test('authorized HTTP record preserves exact PostgreSQL graph, packs, basket, meal sources and request literal',async()=>{
 const f=await fixture(),r=ok(await snapshot(f)),db=await persisted(f);
 assert.equal(r.recordDigest,digest(r.record));assert.equal(r.record.projection,'assigned-shopper-current-record-v1');
 assert.deepEqual(r.record.food.graph,db.graph.graph);assert.deepEqual(r.record.food.totals,db.demand.totals);assert.equal(r.record.food.totals[0].quantity,null,'unparsed accepted request stays unknown');
 assert.deepEqual(r.record.food.packReview,{state:'recorded',graphRevision:db.graph.revision,values:db.graph.pack_review});
 assert.deepEqual(r.record.basketLines,db.shop.lines);assert.deepEqual(r.record.quote,db.shop.quote);assert.deepEqual(r.record.mealOccurrences,db.shop.meals);
 assert.deepEqual(r.record.requestSources,[{requestId:f.requestId,lineId:f.basket.lineId,reviewedRevision:1,originalItem:f.wording,originalQuantityText:f.literal}]);
 assert.equal(r.record.food.graph.contributions.find(c=>c.id===f.input.change.contributions[0].id).quantity.amount.numerator,'12');
 assert.equal(r.record.food.graph.edges.length,3);assert.equal(r.record.food.graph.contributions.find(c=>c.source.kind==='reservation').quantity.amount.numerator,'2');
 assert.equal(r.record.lineage.graph.recordedAt,db.graph.created_at.toISOString());assert.equal(r.record.lineage.basket.digest,db.latest.digest);
 const text=JSON.stringify(r);for(const forbidden of [f.owner.token,f.owner.device,f.author.device,'authorityEpoch','clientKey','replayWindow','actor_id','guardian_consent_id'])assert.ok(!text.includes(forbidden));
});
test('repeated authorized record reads retain exact immutable identity and make no domain writes',async()=>{
 const f=await fixture(),counts=await admin.query('SELECT (SELECT count(*) FROM ritc.operation WHERE household_id=$1)::int operations,(SELECT count(*) FROM ritc.shared_demand_revision WHERE household_id=$1)::int revisions',[f.h]);
 const a=ok(await snapshot(f)),b=ok(await snapshot(f));assert.deepEqual(a.record,b.record);assert.equal(a.recordDigest,b.recordDigest);assert.ok(Date.parse(b.asOf)>=Date.parse(a.asOf));
 assert.deepEqual((await admin.query('SELECT (SELECT count(*) FROM ritc.operation WHERE household_id=$1)::int operations,(SELECT count(*) FROM ritc.shared_demand_revision WHERE household_id=$1)::int revisions',[f.h])).rows,counts.rows);
});
test('nonshopper and foreign-household reads deny before loading record contents',async()=>{
 const f=await fixture(),foreign=await fixture();
 for(const a of [f.author,foreign.owner]){deniedContentReads=0;watchDenied=true;let r;
  try{r=await call(a,f.path+'/records/snapshot');}finally{watchDenied=false;}
  assert.equal(r.status,404);assert.equal(deniedContentReads,0);const body=JSON.stringify(r.data);for(const value of [f.wording,f.literal,'recordDigest','packReview','basketLines'])assert.ok(!body.includes(value));
 }
});
test('snapshot stays atomic while a concurrently reviewed HTTP price update waits on its household lock',async()=>{
 const f=await fixture(),before=ok(await snapshot(f)),demand=ok(await call(f.owner,f.path+'/demand'));
 const input={...f.input,mode:'review',base:{shopRevision:f.revision,authorityEpoch:1,graphRevision:demand.graph.revision},change:empty(),action:{kind:'shop.patch',body:{quote:f.quote,lines:[{...f.basket,unitPriceMinor:125}]}}};
 const preview=ok(await call(f.owner,f.path+'/demand/previews','POST',input));
 const original=repo.lines.bind(repo);let entered,release;const arrived=new Promise(r=>entered=r),held=new Promise(r=>release=r);let once=true;
 repo.lines=async(ctx,shopID)=>{const rows=await original(ctx,shopID);if(once&&ctx.householdId===f.h&&shopID===f.shopId){once=false;entered();await held;}return rows;};
 let reading,writing,arrivalTimer;
 try{
  reading=snapshot(f);
  await Promise.race([arrived,reading.then(()=>{throw Error('snapshot returned before the lock barrier');}),
   new Promise((_,reject)=>{arrivalTimer=setTimeout(()=>reject(Error('snapshot did not reach the lock barrier')),5000);})]);
  clearTimeout(arrivalTimer);writing=apply(f,input,preview);
  let blocked=false;const deadline=Date.now()+1500;
  while(Date.now()<deadline){const q=await admin.query("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name=$1 AND wait_event_type='Lock' AND query LIKE 'SELECT household_id FROM ritc.household%') AS blocked",[applicationName]);if(q.rows[0].blocked){blocked=true;break;}await new Promise(r=>setTimeout(r,20));}
  assert.equal(blocked,true,'actual concurrent command must wait for the read transaction');release();
  const read=ok(await reading);assert.deepEqual(read.record,before.record);ok(await writing);
 }finally{clearTimeout(arrivalTimer);release();repo.lines=original;await Promise.allSettled([reading,writing].filter(Boolean));}
 const after=ok(await snapshot(f));assert.equal(after.record.basketLines[0].unitPriceMinor,125);assert.equal(after.record.shopRevision,f.revision+1);assert.equal(after.record.food.graph.revision,demand.graph.revision+1);
});
test('existing server-only price refresh keeps the older accepted head pack basis with the newer basket',async()=>{
 const f=await fixture(),before=ok(await snapshot(f)),identity=await verifier.verify(f.owner.token);
 await repo.authorized(f.h,{identity,deviceToken:f.owner.device},ctx=>repo.execute(ctx,{v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind:'shop.patch',base:{shopRevision:f.revision,authorityEpoch:1},body:{quote:f.quote,lines:[{...f.basket,unitPriceMinor:135}]}},undefined,undefined,true));
 const after=ok(await snapshot(f));assert.equal(after.record.shopRevision,f.revision+1);assert.equal(after.record.basketLines[0].unitPriceMinor,135);
 assert.deepEqual(after.record.food,before.record.food);assert.deepEqual(after.record.lineage.graph,before.record.lineage.graph);assert.equal(after.record.lineage.basket.revision,f.revision+1);assert.notEqual(after.recordDigest,before.recordDigest);
});
test('worker-authorized erasure yields review-required current facts without historical request wording or old pack acknowledgment',async()=>{
 const f=await fixture(),before=ok(await snapshot(f));assert.ok(JSON.stringify(before).includes(f.wording));
 ok(await call(f.author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 const after=ok(await snapshot(f)),demand=ok(await call(f.owner,f.path+'/demand'));assert.equal(after.record.food.status,'reviewRequired');
 assert.deepEqual(after.record.food.graph,demand.graph);assert.deepEqual(after.record.food.totals,demand.totals);
 assert.deepEqual(after.record.food.packReview,{state:'erased',graphRevision:demand.graph.revision,values:null});assert.equal(after.record.lineage.graph.digest,null);assert.equal(after.record.lineage.basket.digest,null);
 assert.deepEqual(after.record.requestSources,[]);const text=JSON.stringify(after);assert.ok(!text.includes(f.wording));assert.ok(!text.includes(f.literal));
 for(const c of before.record.food.graph.contributions.filter(c=>c.source.kind!=='request'))assert.deepEqual(after.record.food.graph.contributions.find(x=>x.id===c.id),c);
 assert.deepEqual(after.record.food.graph.edges,before.record.food.graph.edges);assert.deepEqual(after.record.mealOccurrences,before.record.mealOccurrences);
 assert.equal(after.record.food.totals[0].quantity.numerator,'12');assert.notEqual(after.recordDigest,before.recordDigest);
 assert.notEqual((await call(f.author,f.path+'/records/snapshot')).status,200);
});
