import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import pg from 'pg';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {bodySchemas} from '../dist/contracts.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {PrivacyService,PrivacyMaintenance} from '../dist/privacy.js';
import {openPrivacyJournalFixture} from './privacy-journal-fixture.mjs';
import {createHTTPServer} from '../dist/http.js';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),worker=new pg.Pool({connectionString:process.env.TEST_WORKER_DATABASE_URL});
let runtimeQueries=0;runtime.on('connect',client=>{const query=client.query.bind(client);client.query=(...args)=>{runtimeQueries++;return query(...args);};});
const issuer='https://shared-demand.fixture.invalid';const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='fixture';
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

test('shared demand preview Cancel, atomic adoption, exact replay and second device persisted read',async()=>{
 const f=await fixture(),before=ok(await call(f.owner,f.path)),legacy=ok(await call(f.owner,f.path+'/demand'));assert.equal(legacy.status,'legacy');assert.deepEqual(legacy.totals,[]);
 assert.deepEqual(legacy.legacySources,{sources:[]});
 const input=draft(f),p=ok(await preview(f,input));assert.deepEqual(p.beforeTotals,[]);assert.deepEqual(p.afterTotals,[{lineId:f.basket.lineId,unit:'count',quantity:{numerator:'12',denominator:'1'},activeContributionIds:[input.change.contributions[0].id]}]);assert.deepEqual(ok(await call(f.owner,f.path)),before);assert.equal(await count(f,'shared_demand_revision'),0);
 const a=await apply(f,input,p),receipt=ok(a.response);assert.equal(receipt.shopRevision,2);assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',a.command)),receipt);assert.equal(await count(f,'shared_demand_revision'),1);
 assert.equal(await count(f,'shared_demand_preview'),0);const second=await actor(f.owner.subject);await enroll(second,f.h);
 const saved=ok(await call(second,f.path+'/demand'));assert.deepEqual(saved.totals,p.afterTotals);assert.deepEqual(saved.graph,p.after);assert.equal(saved.graph.contributions[0].quantity.amount.numerator,'12');
 assert.equal(saved.legacySources,null);
 const snap=(await admin.query('SELECT snapshot FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=2',[f.h,f.shopId])).rows[0].snapshot;assert.equal(snap.demand.revision,1);assert.match(snap.demand.digest,/^[a-f0-9]{64}$/);
 assert.equal((await call(second,f.base+'/commands','POST',{...a.command,replayWindow:second.window})).status,409);
});
test('legacy adoption catalog preserves exact meal, protected unknown and accepted-request identities',async()=>{
 const f=await fixture(),occurrenceId=randomUUID(),ingredientId=randomUUID(),groupId=randomUUID();
 const meal={title:'Tacos with protected lunch',day:null,kind:'dinner',portions:3,protected:false,
  planning:{groups:[{id:groupId,name:'Lunch',servings:{numerator:1,denominator:1},protected:true}],
   ingredients:[{id:ingredientId,name:'Wraps',quantity:{amount:{numerator:12,denominator:2},unit:'count',originalLiteral:'six wraps'},groupIds:[groupId],exclusions:['Sesame']}],exclusions:['Peanuts']}};
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},1));
 const author=await invited(f),sent=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Wraps for guest',ownQuantity:'two bags maybe?',authoredAt:new Date().toISOString()},2,1,author));
 const requestId=sent.request.requestId;
 const rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:2,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 ok(await send(f,'request.apply',{requestId,previewId:rp.previewId,acceptOverage:false,acceptUnknown:false},2,1,f.owner,{base:{shopRevision:2,authorityEpoch:1,requestRevision:1}}));
 const page=ok(await call(f.owner,f.path+'/demand'));assert.equal(page.shopRevision,3);
 const sources=page.legacySources.sources;assert.equal(sources.length,3);
 assert.deepEqual(ok(await call(f.owner,f.path+'/demand')),page,'refresh preserves source identities');
 const m=sources.find(s=>s.source.kind==='meal'),protectedNeed=sources.find(s=>s.source.kind==='reservation'),request=sources.find(s=>s.source.kind==='request');
 assert.deepEqual(m.quantity.amount,{numerator:'6',denominator:'1'});assert.equal(m.quantity.originalLiteral,'six wraps');
 assert.equal(m.source.occurrenceId,occurrenceId);assert.equal(m.source.ingredientId,ingredientId);assert.equal(m.sourceLabel,meal.title);
 assert.equal(protectedNeed.source.groupId,groupId);assert.equal(protectedNeed.quantity,null);assert.equal(m.sourceExclusions.length,2);
 assert.deepEqual(request.source,{kind:'request',requestId,appliedRequestRevision:1});assert.equal(request.requiredLineId,f.basket.lineId);
 assert.equal(request.originalQuantityText,'two bags maybe?');assert.equal(request.quantity,null);
 assert.equal((await call(author,f.path+'/demand')).status,404,'contributor cannot read the source catalog');
 const input=draft(f);input.base.shopRevision=3;input.packs[0].acceptUnresolved=true;
 input.change.contributions=sources.map(s=>({id:s.id,lineId:s.requiredLineId??f.basket.lineId,source:s.source,productKey:'wraps',productName:s.productName,originalText:s.originalText,quantity:s.quantity,sourceExclusions:s.sourceExclusions,exclusions:[],contains:[],removedAt:null}));
 const p=ok(await preview(f,input));assert.equal(ok(await call(f.owner,f.path+'/demand')).status,'legacy','preview does not adopt');
 ok((await apply(f,input,p)).response);const adopted=ok(await call(f.owner,f.path+'/demand'));
 assert.equal(adopted.status,'enabled');assert.equal(adopted.legacySources,null);assert.deepEqual(adopted.graph.contributions.map(c=>c.id),sources.map(s=>s.id));
});
test('legacy request catalog rejects revoked source authority before returning private text',async()=>{
 const f=await fixture(),author=await invited(f),secret='Private family request';
 const requestId=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:secret,ownQuantity:'some',authoredAt:new Date().toISOString()},1,1,author)).request.requestId;
 const p=ok(await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:1,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 ok(await send(f,'request.apply',{requestId,previewId:p.previewId,acceptOverage:false,acceptUnknown:false},1,1,f.owner,{base:{shopRevision:1,authorityEpoch:1,requestRevision:1}}));
 await admin.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2",[f.h,author.id]);
 const result=await call(f.owner,f.path+'/demand');assert.equal(result.status,409);assert.equal(result.data.error.code,'demand_source_unavailable');
 assert.equal(JSON.stringify(result.data).includes(secret),false);
});
test('legacy remains usable; graph adoption retains typed unknown and rejects insufficient reviewed packs',async()=>{
 const f=await fixture();ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket]},1));
 const input=draft(f);input.base.shopRevision=2;input.change.contributions[0].quantity={...q(2),unit:'ounce'};input.packs[0].acceptUnresolved=true;
 const p=ok(await preview(f,input));assert.equal(p.afterTotals[0].quantity,null);assert.equal(p.after.contributions[0].quantity.unit,'ounce');ok((await apply(f,input,p)).response);
 const g=await fixture(),short=draft(g);short.packs[0].usablePerPack=q(5);assert.equal((await preview(g,short)).data.error.code,'demand_insufficient_packs');
});
test('unreviewed graph writer is fenced; exact action, expiry, authority and device are bound',async()=>{
 const f=await fixture();await adopt(f);assert.equal((await send(f,'shop.patch',{quote:f.quote,lines:[f.basket]},2)).data.error.code,'demand_review_required');
 const input={...draft(f),mode:'review',base:{shopRevision:2,authorityEpoch:1,graphRevision:1},change:empty()},p=ok(await preview(f,input));
 const other=await actor(f.owner.subject);await enroll(other,f.h);assert.equal((await apply(f,input,p,other)).response.status,409);
 const changed=structuredClone(input);changed.action.body.lines[0].packs=3;assert.equal((await apply(f,changed,p)).response.data.error.code,'demand_action_changed');
 await admin.query("UPDATE ritc.shared_demand_preview SET created_at=created_at-interval '11 minutes',expires_at=expires_at-interval '11 minutes' WHERE household_id=$1",[f.h]);assert.equal((await apply(f,input,p)).response.status,409);
 const fresh=ok(await preview(f,input)),planner=await invited(f);assert.equal((await call(planner,f.path+'/demand')).status,404);
 ok(await send(f,'shop.transferAuthority',{newShopperId:planner.id},2));assert.equal((await apply(f,input,fresh)).response.status,404);assert.equal(await count(f,'shared_demand_revision'),1);
});
test('failure after graph append rolls back graph, basket, head, receipt and preview consumption',async()=>{
 const f=await fixture(),input=draft(f),p=ok(await preview(f,input));
 await admin.query(`CREATE SEQUENCE ritc.fixture_demand_reached; GRANT USAGE,SELECT ON SEQUENCE ritc.fixture_demand_reached TO ritc_app; CREATE FUNCTION ritc.fixture_reject_demand() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.shop_id='${f.shopId}'::uuid AND NEW.kind='shop.patch' THEN PERFORM nextval('ritc.fixture_demand_reached'); RAISE EXCEPTION 'fixture rollback'; END IF; RETURN NEW; END $$; CREATE TRIGGER fixture_reject_demand BEFORE INSERT ON ritc.operation FOR EACH ROW EXECUTE FUNCTION ritc.fixture_reject_demand()`);
 try{assert.equal((await apply(f,input,p)).response.status,503);assert.equal((await admin.query('SELECT is_called FROM ritc.fixture_demand_reached')).rows[0].is_called,true);assert.equal(await count(f,'shared_demand_revision'),0);assert.equal(await count(f,'shared_demand_preview'),1);assert.equal(ok(await call(f.owner,f.path)).shopRevision,1);assert.equal(ok(await call(f.owner,f.path+'/demand')).status,'legacy');}
 finally{await admin.query('DROP TRIGGER fixture_reject_demand ON ritc.operation; DROP FUNCTION ritc.fixture_reject_demand(); DROP SEQUENCE ritc.fixture_demand_reached');}
});
test('touched-ID Undo survives unrelated additions and keeps all original IDs',async()=>{
 const f=await fixture(),a=await adopt(f),extra=source(f,q(3));extra.originalText='3 extra wraps';
 const add={...draft(f),mode:'change',base:{shopRevision:2,authorityEpoch:1,graphRevision:1},change:{...empty(),contributions:[extra]}};add.action.body.lines[0].packs=3;
 const p=ok(await preview(f,add)),added=ok((await apply(f,add,p)).response);
 const staple=source(f,q(1));staple.originalText='One additional wrap';const later={...add,base:{shopRevision:3,authorityEpoch:1,graphRevision:2},change:{...empty(),contributions:[staple]}};
 ok((await apply(f,later,ok(await preview(f,later)))).response);
 const undo={...later,mode:'undo',base:{shopRevision:4,authorityEpoch:1,graphRevision:3},change:empty(),undoOperationId:added.operationId};ok((await apply(f,undo,ok(await preview(f,undo)))).response);
 const graph=ok(await call(f.owner,f.path+'/demand')).graph;assert.equal(graph.contributions.find(c=>c.id===extra.id).removedAt!==null,true);assert.deepEqual(graph.contributions.find(c=>c.id===staple.id),staple);assert.deepEqual(graph.contributions.find(c=>c.id===a.input.change.contributions[0].id),a.input.change.contributions[0]);
});
test('runtime tenant RLS and append-only history are enforced independently of API',async()=>{
 const f=await fixture();await adopt(f);assert.equal((await runtime.query('SELECT count(*)::int n FROM ritc.shared_demand_revision')).rows[0].n,0);
 const db=await runtime.connect();try{await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[f.h]);assert.equal((await db.query('SELECT count(*)::int n FROM ritc.shared_demand_revision')).rows[0].n,1);await assert.rejects(db.query('UPDATE ritc.shared_demand_revision SET graph_digest=NULL'),e=>e.code==='42501');await db.query('ROLLBACK');}finally{db.release();}
 await assert.rejects(runtime.query('SELECT ritc.erase_shared_demand($1,$2)',[f.h,f.owner.id]),e=>e.code==='42501');
 await assert.rejects(admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.owner.id]),e=>e.message==='erasure authority required','even fixture admin cannot erase actual graph data without a worker lease');
});
test('request add/link needs typed review and records original author provenance; draft freeze pins graph',async()=>{
 const f=await fixture();await adopt(f);const author=await invited(f);
 const sent=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Wraps for guest',ownQuantity:'2 wraps',authoredAt:new Date().toISOString()},2,1,author));const requestId=sent.request.requestId;
 const rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:2,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 const body={requestId,previewId:rp.previewId,acceptOverage:false,acceptUnknown:false};assert.equal((await send(f,'request.apply',body,2,1,f.owner,{base:{shopRevision:2,authorityEpoch:1,requestRevision:1}})).data.error.code,'demand_review_required');
 const c=source(f,q(2));c.source={kind:'request',requestId,appliedRequestRevision:1};c.originalText='Wraps for guest';
 const input={...draft(f),mode:'change',base:{shopRevision:2,authorityEpoch:1,graphRevision:1},change:{...empty(),contributions:[c]},action:{kind:'request.apply',body}};input.packs[0].usablePerPack=q(7);
 ok((await apply(f,input,ok(await preview(f,input)))).response);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_demand_source_member WHERE household_id=$1 AND entity_id=$2 AND member_id=$3',[f.h,c.id,author.id])).rows[0].n,1);
 ok(await send(f,'shop.freeze',{},3));const snap=(await admin.query('SELECT snapshot FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=4',[f.h,f.shopId])).rows[0].snapshot;assert.equal(snap.demand.revision,2);
});
test('privacy erases source copies/receipts, keeps unrelated source and prevents old operation replay',async()=>{
 const f=await fixture();await adopt(f);const other=await invited(f);ok(await send(f,'shop.transferAuthority',{newShopperId:other.id},2));
 const oldOwner=f.owner;f.owner=other;const extra=source(f,q(3));extra.originalText='Unrelated other source';
 const input={...draft(f),mode:'change',base:{shopRevision:2,authorityEpoch:2,graphRevision:1},change:{...empty(),contributions:[extra]}};input.action.body.lines[0].packs=3;
 const a=await apply(f,input,ok(await preview(f,input)));ok(a.response);
 const deletion={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'transfer',organizerMemberId:other.id,shops:[],eraseChildProfiles:[]}]};
 ok(await call(oldOwner,'/v1/privacy/deletions','POST',deletion),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 const rows=(await admin.query('SELECT graph,receipt,pack_review,graph_digest FROM ritc.shared_demand_revision WHERE household_id=$1 ORDER BY revision',[f.h])).rows;
 for(const row of rows){assert.equal(row.receipt,null);assert.equal(row.pack_review,null);assert.equal(row.graph_digest,null);assert.ok(!JSON.stringify(row).includes('12 wraps'));}
 const read=ok(await call(other,f.path+'/demand'));assert.equal(read.status,'reviewRequired');assert.deepEqual(read.graph.contributions.find(c=>c.id===extra.id),extra);
 assert.equal((await call(other,f.base+'/commands','POST',a.command)).status,409);assert.equal((await send(f,'shop.freeze',{},read.shopRevision,2)).data.error.code,'demand_review_required');
});
test('erasing request author removes labels copied by another shopper from every graph/basket/snapshot',async()=>{
 const f=await fixture();await adopt(f);const author=await invited(f),secret='Contributor private ingredient label';
 const sent=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:secret,ownQuantity:'2 items',authoredAt:new Date().toISOString()},2,1,author));const requestId=sent.request.requestId;
 const basket={...line(),originalItem:secret,packs:1},rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:2,authorityEpoch:1,requestRevision:1},decision:{choice:'add',line:basket,promote:false}}));
 const c={...source(f,q(2)),lineId:basket.lineId,source:{kind:'request',requestId,appliedRequestRevision:1},productKey:'rice',productName:secret,originalText:secret};
 const input={...draft(f),mode:'change',base:{shopRevision:2,authorityEpoch:1,graphRevision:1},change:{...empty(),lines:[{id:basket.lineId,name:secret,unit:'count',originalOrder:1,trashedAt:null}],contributions:[c]},action:{kind:'request.apply',body:{requestId,previewId:rp.previewId,acceptOverage:false,acceptUnknown:false}},packs:[...draft(f).packs,{lineId:basket.lineId,usablePerPack:q(2),acceptUnresolved:false}]};
 ok((await apply(f,input,ok(await preview(f,input)))).response);
 const copy={...input,mode:'review',base:{shopRevision:3,authorityEpoch:1,graphRevision:2},change:empty(),action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket,basket]}}};ok((await apply(f,copy,ok(await preview(f,copy)))).response);
 const deletion={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]};
 ok(await call(author,'/v1/privacy/deletions','POST',deletion),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 for(const table of ['shared_demand_revision','shared_demand_preview','basket_line','shop_snapshot','operation_response']){
  const values=(await admin.query(`SELECT to_jsonb(t) AS value FROM ritc.${table} t WHERE household_id=$1`,[f.h])).rows;
  assert.ok(!JSON.stringify(values).includes(secret),table+' retained contributor wording');
 }
 const page=ok(await call(f.owner,f.path+'/demand'));assert.equal(page.graph.contributions.length,1);assert.equal(page.graph.contributions[0].originalText,'12 wraps');assert.equal(page.graph.contributions[0].quantity.amount.numerator,'12');assert.ok(page.graph.usedIds.includes(c.id));
});
test('persisted twelve/six/four/two source removal conserves distinct protected lunch and immutable history',async()=>{
 const f=await fixture(),meals=[];let revision=1;
 for(const [title,n,protectedMeal] of [['Tacos',6,false],['Quesadillas',4,false],['Lunch',2,true]]){
  const occurrenceId=randomUUID(),groupId=randomUUID(),ingredientId=randomUUID(),bindingId=randomUUID(),quantity={amount:{numerator:n,denominator:1},unit:'count',originalLiteral:n+' wraps'};
  const meal={title,day:null,kind:protectedMeal?'lunch':'dinner',portions:n,protected:protectedMeal,planning:{groups:[{id:groupId,name:title,servings:{numerator:n,denominator:1},protected:protectedMeal}],ingredients:[{id:ingredientId,name:'Wraps',quantity,groupIds:[groupId],exclusions:[]}],bindings:[{id:bindingId,groupId,ingredientId,quantity}]}};
  ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},revision++));meals.push({occurrenceId,groupId,ingredientId,bindingId,n,protectedMeal,meal,revision});
 }
 const input=draft(f);input.base.shopRevision=4;const manual=input.change.contributions[0];
 const imported=source(f,q(12));imported.source={kind:'import',batchId:randomUUID(),entryId:randomUUID()};imported.originalText='Imported duplicate twelve wraps';input.change.contributions.push(imported);
 input.change.edges.push({id:randomUUID(),kind:'duplicate',demandId:imported.id,supplyId:manual.id,quantity:q(12),confirmation:{productMatchConfirmed:true,confirmedAt:new Date().toISOString(),evidence:'Explicitly reviewed duplicate import of the same twelve wraps'}});
 for(const m of meals){const c=source(f,q(m.n));c.originalText=m.meal.title+' wraps';c.source=m.protectedMeal?{kind:'reservation',reservationId:randomUUID(),purpose:'Protected lunch',originOccurrenceId:m.occurrenceId,ingredientId:m.ingredientId,groupId:m.groupId,bindingId:m.bindingId}:{kind:'meal',occurrenceId:m.occurrenceId,ingredientId:m.ingredientId,groupId:m.groupId,bindingId:m.bindingId};m.sourceId=c.id;input.change.contributions.push(c);input.change.edges.push({id:randomUUID(),kind:'withinExisting',demandId:c.id,supplyId:manual.id,quantity:q(m.n),confirmation:{productMatchConfirmed:true,confirmedAt:new Date().toISOString(),evidence:'Reviewed within twelve wraps'}});}
 const first=ok(await preview(f,input));ok((await apply(f,input,first)).response);const original=ok(await call(f.owner,f.path+'/demand')).graph;
 const remove={...input,mode:'change',base:{shopRevision:5,authorityEpoch:1,graphRevision:1},change:{...empty(),removeSourceIds:[meals[0].sourceId]},action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:meals[0].occurrenceId,baseMealRevision:2,meal:null}}}};
 const p=ok(await preview(f,remove));assert.deepEqual(ok(await call(f.owner,f.path+'/demand')).graph,original,'Cancel/no Apply changes nothing');
 const applied=await apply(f,remove,p);const receipt=ok(applied.response);assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',applied.command)),receipt);
 const second=await actor(f.owner.subject);await enroll(second,f.h);const current=ok(await call(second,f.path+'/demand')).graph;
 for(const c of original.contributions.filter(c=>c.id!==meals[0].sourceId))assert.deepEqual(current.contributions.find(x=>x.id===c.id),c);
 assert.equal(current.contributions.filter(c=>c.removedAt!==null).length,1);assert.equal(current.contributions.find(c=>c.id===meals[0].sourceId).removedAt!==null,true);
 assert.deepEqual(current.edges,original.edges.filter(e=>e.demandId!==meals[0].sourceId));assert.equal(current.revision,2);assert.equal(receipt.shopRevision,6);
 assert.deepEqual((await admin.query('SELECT graph FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=1',[f.h,f.shopId])).rows[0].graph,original);
 const live=ok(await call(second,f.path));assert.equal(live.meals.length,2);assert.deepEqual(live.meals.find(m=>m.occurrenceId===meals[2].occurrenceId).meal,meals[2].meal);
});
async function mealGraph(f,label=null){
 const occurrenceId=randomUUID(),ingredientId=randomUUID(),groupId=randomUUID(),bindingId=randomUUID(),quantity={amount:{numerator:6,denominator:1},unit:'count',originalLiteral:'6 wraps'};
 const meal={title:'Meal source',day:null,kind:'dinner',portions:6,protected:false,planning:{groups:[{id:groupId,name:'Dinner',servings:{numerator:6,denominator:1},protected:false}],ingredients:[{id:ingredientId,name:'Wraps',quantity,groupIds:[groupId],exclusions:label?[label]:[]}],bindings:[{id:bindingId,groupId,ingredientId,quantity}]}};
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},1));
 const input=draft(f);input.base.shopRevision=2;const c=source(f,q(6));c.originalText='Meal source wraps';c.source={kind:'meal',occurrenceId,ingredientId,groupId,bindingId};input.change.contributions.push(c);
 const edge={id:randomUUID(),kind:'withinExisting',demandId:c.id,supplyId:input.change.contributions[0].id,quantity:q(6),confirmation:{productMatchConfirmed:true,confirmedAt:new Date().toISOString(),evidence:'Reviewed within existing'}};input.change.edges.push(edge);
 return{occurrenceId,ingredientId,groupId,bindingId,meal,input,c,edge};
}
test('source label mapping is exact and review-bound; unresolved needs stay additive and cannot hide insufficient packs',async()=>{
 const f=await fixture(),m=await mealGraph(f,'No sesame');assert.equal((await preview(f,m.input)).data.error.code,'demand_exclusion_mapping_required');
 const entry={occurrenceId:m.occurrenceId,ingredientId:m.ingredientId,label:'No sesame',resolution:{kind:'unresolved'}};m.c.sourceExclusions=[entry];
 assert.equal((await preview(f,m.input)).status,422,'unresolved restriction cannot authorize a within-existing edge');
 m.input.change.edges=[];m.input.packs[0].acceptUnresolved=true;assert.equal((await preview(f,m.input)).data.error.code,'demand_insufficient_packs');
 m.input.action.body.lines[0].packs=3;const unresolved=ok(await preview(f,m.input));assert.deepEqual(unresolved.after.contributions.find(c=>c.id===m.c.id).sourceExclusions,[entry]);
 entry.resolution={kind:'mapped',tags:['sesame'],confirmedAt:new Date().toISOString()};m.c.exclusions.push('sesame');m.input.change.edges=[m.edge];m.input.action.body.lines[0].packs=2;
 const mapped=ok(await preview(f,m.input));ok((await apply(f,m.input,mapped)).response);assert.deepEqual(ok(await call(f.owner,f.path+'/demand')).graph.contributions.find(c=>c.id===m.c.id).sourceExclusions,[entry]);
});
test('unaccepted proposal authors are not origins; exact accepted proposer becomes an origin before consume',async()=>{
 const first=await fixture(),m=await mealGraph(first),unrelated=await invited(first);
 for(const state of ['pending','dismissed'])await admin.query('INSERT INTO ritc.shared_meal_change(household_id,shop_id,proposal_id,actor_id,authority_epoch,grant_revision,shop_revision,occurrence_id,base_meal_revision,body,original_meal,fingerprint,state) VALUES($1,$2,$3,$4,1,1,2,$5,2,$6,$6,$7,$8)',[first.h,first.shopId,randomUUID(),unrelated.id,m.occurrenceId,{meal:m.meal},'f'.repeat(64),state]);
 ok((await apply(first,m.input,ok(await preview(first,m.input)))).response);const before=ok(await call(first.owner,first.path+'/demand')).graph;
 const erase=async(f,a)=>{const body={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]};ok(await call(a,'/v1/privacy/deletions','POST',body),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);};
 await erase(first,unrelated);assert.deepEqual(ok(await call(first.owner,first.path+'/demand')).graph,before);
 const f=await fixture(),n=await mealGraph(f),proposer=await invited(f);ok((await apply(f,n.input,ok(await preview(f,n.input)))).response);
 const changed=structuredClone(n.meal);changed.planning.ingredients[0].quantity.amount.numerator=5;changed.planning.bindings[0].quantity.amount.numerator=5;
 const proposalId=randomUUID();await admin.query('INSERT INTO ritc.meal_planner(household_id,shop_id,authority_epoch,revision,planner_id) VALUES($1,$2,1,1,$3)',[f.h,f.shopId,proposer.id]);
 await admin.query('INSERT INTO ritc.shared_meal_change(household_id,shop_id,proposal_id,actor_id,authority_epoch,grant_revision,shop_revision,occurrence_id,base_meal_revision,body,original_meal,fingerprint) VALUES($1,$2,$3,$4,1,1,3,$5,2,$6,$7,$8)',[f.h,f.shopId,proposalId,proposer.id,n.occurrenceId,{meal:changed},n.meal,'e'.repeat(64)]);
 const update={...n.input,mode:'change',base:{shopRevision:3,authorityEpoch:1,graphRevision:1},change:{...empty(),contributions:[{...n.c,quantity:q(5)}],edges:[{...n.edge,quantity:q(5)}]},action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:n.occurrenceId,baseMealRevision:2,changeProposalId:proposalId,meal:changed}}}};
 ok((await apply(f,update,ok(await preview(f,update)))).response);assert.equal((await admin.query('SELECT state FROM ritc.shared_meal_change WHERE household_id=$1 AND proposal_id=$2',[f.h,proposalId])).rows[0].state,'applied');
 assert.equal((await admin.query("SELECT count(*)::int n FROM ritc.shared_demand_source_member WHERE household_id=$1 AND entity_id=$2 AND entity_kind='contribution' AND member_id=$3",[f.h,n.c.id,proposer.id])).rows[0].n,1);
 await erase(f,proposer);const after=ok(await call(f.owner,f.path+'/demand')).graph;assert.ok(!after.contributions.some(c=>c.id===n.c.id));assert.equal(after.contributions[0].quantity.amount.numerator,'12');
});
test('protected unknown binding is retained, explicitly quantified once with stable identity, and cannot be undone to a weaker unknown',async()=>{
 const f=await fixture(),m=await mealGraph(f),lunchId=randomUUID();m.meal.planning.groups.push({id:lunchId,name:'Protected lunch',servings:{numerator:2,denominator:1},protected:true});m.meal.planning.ingredients[0].groupIds.push(lunchId);
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:m.occurrenceId,baseMealRevision:2,meal:m.meal}},2));m.input.base.shopRevision=3;
 const reserve={...source(f,null),originalText:'Lunch quantity not yet assigned',source:{kind:'reservation',reservationId:randomUUID(),purpose:'Protected lunch',originOccurrenceId:m.occurrenceId,ingredientId:m.ingredientId,groupId:lunchId,bindingId:null}};
 m.input.change.contributions.push(reserve);m.input.packs[0].acceptUnresolved=true;const p=ok(await preview(f,m.input));ok((await apply(f,m.input,p)).response);assert.equal(p.after.contributions.find(c=>c.id===reserve.id).quantity,null);
 const bindingId=randomUUID(),changed=structuredClone(m.meal);changed.planning.bindings[0].quantity={...changed.planning.bindings[0].quantity,amount:{numerator:4,denominator:1}};changed.planning.bindings.push({id:bindingId,groupId:lunchId,ingredientId:m.ingredientId,quantity:{amount:{numerator:2,denominator:1},unit:'count',originalLiteral:'2 wraps'}});
 const quantified={...reserve,source:{...reserve.source,bindingId},quantity:q(2)},lunchEdge={...m.edge,id:randomUUID(),demandId:reserve.id,quantity:q(2)};
 const input={...m.input,mode:'change',base:{shopRevision:4,authorityEpoch:1,graphRevision:1},change:{...empty(),contributions:[{...m.c,quantity:q(4)},quantified],edges:[{...m.edge,quantity:q(4)},lunchEdge]},action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:m.occurrenceId,baseMealRevision:3,meal:changed}}}};
 assert.equal((await preview(f,input)).status,422);input.change.quantifyReservationIds=[reserve.id];const reviewed=ok(await preview(f,input)),applied=await apply(f,input,reviewed),receipt=ok(applied.response);assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',applied.command)),receipt);
 const graph=ok(await call(f.owner,f.path+'/demand')).graph;assert.equal(graph.contributions.length,3);assert.deepEqual(graph.contributions.find(c=>c.id===reserve.id),quantified);assert.equal(graph.edges.length,2);assert.equal(graph.revision,2);
 const undo={...input,mode:'undo',base:{shopRevision:5,authorityEpoch:1,graphRevision:2},change:empty(),undoOperationId:receipt.operationId};undo.action.body.mealEdit={occurrenceId:m.occurrenceId,baseMealRevision:5,meal:m.meal};assert.equal((await preview(f,undo)).data.error.code,'protected_quantification_undo');assert.deepEqual(ok(await call(f.owner,f.path+'/demand')).graph,graph);
});
test('whole protected known ingredient without group bindings stays one known reservation',async()=>{
 const f=await fixture(),m=await mealGraph(f);m.meal.protected=true;m.meal.planning.bindings=[];
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:m.occurrenceId,baseMealRevision:2,meal:m.meal}},2));m.input.base.shopRevision=3;
 m.c.source={kind:'reservation',reservationId:randomUUID(),purpose:'Whole protected meal',originOccurrenceId:m.occurrenceId,ingredientId:m.ingredientId,groupId:null,bindingId:null};
 const p=ok(await preview(f,m.input));ok((await apply(f,m.input,p)).response);const graph=ok(await call(f.owner,f.path+'/demand')).graph;assert.equal(graph.contributions.length,2);assert.equal(graph.contributions.find(c=>c.id===m.c.id).quantity.amount.numerator,'6');
});
test('explicit protected product clarification preserves its need when adding a matching source',async()=>{
 const f=await fixture(),m=await mealGraph(f);m.meal.protected=true;m.meal.planning.bindings=[];
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:m.occurrenceId,baseMealRevision:2,meal:m.meal}},2));
 m.c.source={kind:'reservation',reservationId:randomUUID(),purpose:'Protected lunch',originOccurrenceId:m.occurrenceId,ingredientId:m.ingredientId,groupId:null,bindingId:null};m.c.productKey=null;
 const input={...m.input,base:{shopRevision:3,authorityEpoch:1,graphRevision:0},change:{...empty(),lines:m.input.change.lines,contributions:[m.c]}};
 ok((await apply(f,input,ok(await preview(f,input)))).response);
 const before=ok(await call(f.owner,f.path+'/demand')),confirmed={...m.c,productKey:'wraps'},additional=source(f,q(2));
 const update={...input,mode:'change',base:{shopRevision:4,authorityEpoch:1,graphRevision:1},change:{...empty(),contributions:[confirmed,additional]}};
 assert.equal((await preview(f,update)).data.error.code,'protected_share_changed');
 update.change.clarifyReservationProductIds=[m.c.id];
 const p=ok(await preview(f,update));assert.deepEqual(ok(await call(f.owner,f.path+'/demand')),before,'Cancel leaves the unknown identity and need intact');
 const receipt=ok((await apply(f,update,p)).response),saved=ok(await call(f.owner,f.path+'/demand'));
 assert.deepEqual(saved.graph.contributions.find(c=>c.id===m.c.id),confirmed);assert.deepEqual(saved.totals[0].quantity,{numerator:'8',denominator:'1'});
 const current={...update,base:{shopRevision:5,authorityEpoch:1,graphRevision:2}};
 const review={...current,mode:'review',change:{...empty(),clarifyReservationProductIds:[m.c.id]}};
 assert.equal((await preview(f,review)).data.error.code,'invalid_demand_review');
 const undo={...current,mode:'undo',undoOperationId:receipt.operationId,change:{...empty(),clarifyReservationProductIds:[m.c.id]}};
 assert.equal((await preview(f,undo)).data.error.code,'invalid_demand_undo');
 undo.change=empty();assert.equal((await preview(f,undo)).status,422,'Undo cannot erase a confirmed protected identity');
 assert.deepEqual(ok(await call(f.owner,f.path+'/demand')),saved);
});
test('privacy recovery replaces an expired quote without changing surviving food commitments',async()=>{
 const f=await fixture();await adopt(f);const author=await invited(f);
 const requestId=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Private guest wraps',ownQuantity:'2 wraps',authoredAt:new Date().toISOString()},2,1,author)).request.requestId;
 const rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:2,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 const requested={...source(f,q(2)),source:{kind:'request',requestId,appliedRequestRevision:1},originalText:'Private guest wraps'};
 const add={...draft(f),mode:'change',base:{shopRevision:2,authorityEpoch:1,graphRevision:1},change:{...empty(),contributions:[requested]},action:{kind:'request.apply',body:{requestId,previewId:rp.previewId,acceptOverage:false,acceptUnknown:false}},packs:[{lineId:f.basket.lineId,usablePerPack:q(7),acceptUnresolved:false}]};
 ok((await apply(f,add,ok(await preview(f,add)))).response);
 ok(await call(author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 // Age only this synthetic fixture's stored quote, avoiding a timing-dependent sleep.
 const expired={...f.quote,observedAt:new Date(Date.now()-7200000).toISOString(),expiresAt:new Date(Date.now()-3600000).toISOString()};
 await admin.query('UPDATE ritc.shop SET quote=$3 WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId,expired]);
 assert.ok(Date.parse(ok(await call(f.owner,f.path)).quote.expiresAt)<Date.now());
 const before=ok(await call(f.owner,f.path+'/demand'));assert.equal(before.status,'reviewRequired');
 const currentShop=ok(await call(f.owner,f.path)),currentLine=currentShop.lines.find(l=>l.lineId===f.basket.lineId);
 assert.ok(currentLine);assert.equal(before.graph.lines.find(l=>l.id===currentLine.lineId).name,currentLine.originalItem);
 assert.deepEqual(before.totals.find(t=>t.lineId===currentLine.lineId).quantity,{numerator:'12',denominator:'1'});
 const freshQuote={...f.quote,observedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString()},basket={...currentLine,packs:3,unitPriceMinor:125};
 const input={...draft(f),mode:'review',base:{shopRevision:before.shopRevision,authorityEpoch:before.authorityEpoch,graphRevision:before.graph.revision},change:empty(),action:{kind:'shop.patch',body:{quote:freshQuote,lines:[basket]}}};
 const p=ok(await preview(f,input));assert.deepEqual(p.beforeTotals,p.afterTotals);assert.deepEqual(p.receipt.contributions,[]);assert.deepEqual(p.receipt.lines,[]);assert.deepEqual(p.receipt.edges,[]);
 assert.deepEqual(ok(await call(f.owner,f.path+'/demand')),before,'Cancel leaves surviving needs and review state intact');
 ok((await apply(f,input,p)).response);const after=ok(await call(f.owner,f.path+'/demand')),shop=ok(await call(f.owner,f.path));
 assert.equal(after.status,'enabled');assert.deepEqual(after.graph.contributions,before.graph.contributions);assert.deepEqual(after.totals,before.totals);assert.deepEqual(shop.quote,freshQuote);assert.deepEqual(shop.lines,[basket]);
});
test('two-thousand-source adoption and unchanged review use bounded set-based origin queries',async()=>{
 const f=await fixture(),input=draft(f);input.change.contributions=Array.from({length:2000},(_,i)=>({...source(f,q(1)),originalText:'One reviewed wrap '+i}));input.action.body.lines[0].packs=334;
 let start=runtimeQueries;const p=ok(await preview(f,input));ok((await apply(f,input,p)).response);const adoptionQueries=runtimeQueries-start;assert.ok(adoptionQueries<=120,`adoption made ${adoptionQueries} runtime queries`);
 const review={...input,mode:'review',base:{shopRevision:2,authorityEpoch:1,graphRevision:1},change:empty()};start=runtimeQueries;ok((await apply(f,review,ok(await preview(f,review)))).response);const reviewQueries=runtimeQueries-start;assert.ok(reviewQueries<=120,`unchanged review made ${reviewQueries} runtime queries`);
 assert.equal(ok(await call(f.owner,f.path+'/demand')).graph.contributions.length,2000);console.log(JSON.stringify({sharedDemandQueryBudget:{sources:2000,adoptionQueries,reviewQueries,maximumPerJourney:120}}));
});
test('privacy-redacted frozen graph reopens for review but both placement paths and its old snapshot remain fenced',async()=>{
 const f=await fixture();await adopt(f);const author=await invited(f),other=await invited(f);
 const sent=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Private requested rice',ownQuantity:'2 portions',authoredAt:new Date().toISOString()},2,1,author)),requestId=sent.request.requestId;
 const basket={...line(),originalItem:'Private requested rice',packs:1},rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:2,authorityEpoch:1,requestRevision:1},decision:{choice:'add',line:basket,promote:false}}));
 const contribution={...source(f,q(2)),lineId:basket.lineId,source:{kind:'request',requestId,appliedRequestRevision:1},productKey:'rice',productName:'Rice',originalText:'Private requested rice'},requestLine={id:basket.lineId,name:basket.originalItem,unit:'count',originalOrder:1,trashedAt:null};
 const input={...draft(f),mode:'change',base:{shopRevision:2,authorityEpoch:1,graphRevision:1},change:{...empty(),lines:[requestLine],contributions:[contribution]},action:{kind:'request.apply',body:{requestId,previewId:rp.previewId,acceptOverage:false,acceptUnknown:false}},packs:[...draft(f).packs,{lineId:basket.lineId,usablePerPack:q(2),acceptUnresolved:false}]};
 ok((await apply(f,input,ok(await preview(f,input)))).response);ok(await send(f,'shop.freeze',{},3));
 ok(await send(f,'shop.transferAuthority',{newShopperId:other.id},4));ok(await send(f,'shop.transferAuthority',{newShopperId:f.owner.id},4,2));
 const pending=ok(await send(f,'shop.reportPlaced',{occurredAt:new Date().toISOString()},4,1));assert.equal(pending.disposition,'pending_reconciliation');
 ok(await call(author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 const redacted=ok(await call(f.owner,f.path+'/demand')),beforeOps=await count(f,'operation'),beforeReports=await count(f,'placement_report');assert.equal(redacted.status,'reviewRequired');
 assert.equal((await send(f,'shop.reportPlaced',{occurredAt:new Date().toISOString()},4,3)).data.error.code,'demand_review_required');
 assert.equal((await send(f,'shop.reconcileReport',{reportId:pending.reportId,choice:'apply'},redacted.shopRevision,3)).data.error.code,'demand_review_required');assert.equal(await count(f,'operation'),beforeOps);assert.equal(await count(f,'placement_report'),beforeReports);
 const old=(await admin.query('SELECT digest FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=4',[f.h,f.shopId])).rows[0];assert.equal(old.digest,'0'.repeat(64));
 const reopened=ok(await send(f,'shop.reopen',{},redacted.shopRevision,3)),snapshot=(await admin.query('SELECT snapshot FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[f.h,f.shopId,reopened.shopRevision])).rows[0].snapshot;
 assert.deepEqual(snapshot.demand,{schemaVersion:1,revision:2,digest:null,status:'reviewRequired'});assert.equal((await send(f,'shop.freeze',{},reopened.shopRevision,3)).data.error.code,'demand_review_required');
 const removedLine=redacted.graph.lines.find(l=>l.id===basket.lineId),review={...draft(f),mode:'change',base:{shopRevision:reopened.shopRevision,authorityEpoch:3,graphRevision:2},change:{...empty(),lines:[{...removedLine,trashedAt:new Date().toISOString()}]}};
 const reviewed=ok((await apply(f,review,ok(await preview(f,review)))).response);assert.equal(ok(await call(f.owner,f.path+'/demand')).status,'enabled');
 assert.equal((await send(f,'shop.reconcileReport',{reportId:pending.reportId,choice:'apply'},reviewed.shopRevision,3)).data.error.code,'demand_review_required','erased dated snapshot remains unusable even after fresh review');
 const frozen=ok(await send(f,'shop.freeze',{},reviewed.shopRevision,3));assert.equal(ok(await send(f,'shop.reportPlaced',{occurredAt:new Date().toISOString()},frozen.shopRevision,3)).disposition,'placed');
});
test('non-source request decisions cannot spend an unrelated demand preview operation',async()=>{
 const f=await fixture();await adopt(f);const a=await invited(f),request=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Later item',ownQuantity:null,authoredAt:new Date().toISOString()},2,1,a)).request;
 const rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId:request.requestId,base:{shopRevision:2,authorityEpoch:1,requestRevision:1},decision:{choice:'defer'}}));
 const input={...draft(f),mode:'review',base:{shopRevision:2,authorityEpoch:1,graphRevision:1},change:empty()},p=ok(await preview(f,input)),before=await count(f,'operation');
 const bad=await send(f,'request.apply',{requestId:request.requestId,previewId:rp.previewId,acceptUnknown:false,acceptOverage:false,demandReview:{previewId:p.previewId,previewDigest:p.previewDigest}},2,1,f.owner,{base:{shopRevision:2,authorityEpoch:1,requestRevision:1}});
 assert.equal(bad.data.error.code,'demand_action_changed');assert.equal(await count(f,'operation'),before);ok((await apply(f,input,p)).response);
});
test('database graph identity and predecessor checks reject missing JSON fields and null revision links',async()=>{
 const f=await fixture();await adopt(f);const db=await runtime.connect();
 const insert=async(graph,predecessor)=>db.query(`INSERT INTO ritc.shared_demand_revision(household_id,shop_id,revision,predecessor,shop_revision,authority_epoch,operation_id,actor_id,device_id,created_at,graph,graph_digest)
 SELECT household_id,shop_id,2,$3,3,authority_epoch,$4,actor_id,device_id,created_at,$5,graph_digest FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=1`,[f.h,f.shopId,predecessor,randomUUID(),graph]);
 const graph={...ok(await call(f.owner,f.path+'/demand')).graph,revision:2};try{
 for(const [value,predecessor] of [[graph,null],[{},1],[{...graph,householdId:randomUUID()},1],[{...graph,shopId:randomUUID()},1]]){await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[f.h]);await assert.rejects(insert(value,predecessor),e=>e.code==='23514');await db.query('ROLLBACK');}
 await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[f.h]);assert.equal((await insert(graph,1)).rowCount,1);await db.query('ROLLBACK');
 }finally{db.release();}
});
test('server-only price refresh preserves graph and cannot alter reviewed packs',async()=>{
 const f=await fixture();await adopt(f);const before=ok(await call(f.owner,f.path+'/demand')).graph,identity=await verifier.verify(f.owner.token);
 const perform=async(lines,revision)=>repo.authorized(f.h,{identity,deviceToken:f.owner.device},ctx=>repo.execute(ctx,{v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind:'shop.patch',base:{shopRevision:revision,authorityEpoch:1},body:{quote:f.quote,lines}},undefined,undefined,true));
 await perform([{...f.basket,unitPriceMinor:101}],2);assert.deepEqual(ok(await call(f.owner,f.path+'/demand')).graph,before);
 await assert.rejects(perform([{...f.basket,packs:3}],3),e=>e.code==='demand_price_only_changed');assert.equal(ok(await call(f.owner,f.path+'/demand')).shopRevision,3);
});

async function copiedRequestPreview(f,author,wording){
 const sent=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:wording,ownQuantity:'2 wraps',authoredAt:new Date().toISOString()},1,2,author)),requestId=sent.request.requestId;
 const rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:1,authorityEpoch:2,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 const c=source(f,q(2));c.source={kind:'request',requestId,appliedRequestRevision:1};c.originalText=wording;
 const input=draft(f);input.base.authorityEpoch=2;input.change.contributions.push(c);input.packs[0].usablePerPack=q(7);input.action={kind:'request.apply',body:{requestId,previewId:rp.previewId,acceptOverage:false,acceptUnknown:false}};
 const p=ok(await preview(f,input));assert.equal(await count(f,'shared_demand_source_member'),0);assert.equal(await count(f,'shared_demand_revision'),0);return{input,p};
}
test('erasing a source author invalidates another shopper preview before any graph provenance exists',async()=>{
 const f=await fixture(),author=f.owner,shopper=await invited(f);ok(await send(f,'shop.transferAuthority',{newShopperId:shopper.id},1));f.owner=shopper;
 const wording='Uncommitted contributor private wording',pending=await copiedRequestPreview(f,author,wording);
 assert.ok(JSON.stringify((await admin.query('SELECT intent FROM ritc.shared_demand_preview WHERE household_id=$1',[f.h])).rows).includes(wording));
 await assert.rejects(admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,author.id]),e=>e.message==='erasure authority required');
 ok(await call(author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'transfer',organizerMemberId:shopper.id,shops:[],eraseChildProfiles:[]}]}),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal(await count(f,'shared_demand_preview'),0);assert.equal(await count(f,'shared_demand_revision'),0);assert.equal((await apply(f,pending.input,pending.p)).response.status,409);assert.equal(ok(await call(shopper,f.path+'/demand')).status,'legacy');
});

test('canonical HTTP totals omit retired lines and their source identities',async()=>{
 const f=await fixture(),a=await adopt(f),input={...draft(f),mode:'change',base:{shopRevision:2,authorityEpoch:1,graphRevision:1},change:{...empty(),removeSourceIds:[a.input.change.contributions[0].id]},action:{kind:'shop.patch',body:{quote:f.quote,lines:[]}},packs:[]};
 const p=ok(await preview(f,input));assert.equal(p.beforeTotals.length,1);assert.deepEqual(p.afterTotals,[]);ok((await apply(f,input,p)).response);
 const page=ok(await call(f.owner,f.path+'/demand'));assert.deepEqual(page.totals,[]);assert.equal(page.graph.lines[0].trashedAt!==null,true);assert.equal(page.graph.contributions[0].removedAt!==null,true);
});

if(process.env.RITC_TEST_NATIVE_WIRE==='1')test('actual Swift shared demand preserves typed sources and exact durable operations over HTTPS and PostgreSQL',async()=>{
 const {exerciseSharedDemandClient}=await import('./shared-demand-native-wire.mjs');const {mkdtemp,chmod}=await import('node:fs/promises');const {join}=await import('node:path');const {tmpdir}=await import('node:os');
 const privateState=await mkdtemp(join(process.env.RITC_NATIVE_WIRE_STATE??tmpdir(),'shared-demand-client-'));await chmod(privateState,0o700);
 const f=await fixture(),meals=[];let revision=1;
 for(const [title,n,protectedMeal] of [['Tacos',6,false],['Quesadillas',4,false],['Lunch',2,true]]){
  const occurrenceId=randomUUID(),groupId=randomUUID(),ingredientId=randomUUID(),bindingId=randomUUID(),quantity={amount:{numerator:n,denominator:1},unit:'count',originalLiteral:n+' wraps'};
  const meal={title,day:null,kind:protectedMeal?'lunch':'dinner',portions:n,protected:protectedMeal,planning:{groups:[{id:groupId,name:title,servings:{numerator:n,denominator:1},protected:protectedMeal}],ingredients:[{id:ingredientId,name:'Wraps',quantity,groupIds:[groupId],exclusions:title==='Tacos'?['No sesame']:[]}],bindings:[{id:bindingId,groupId,ingredientId,quantity}]}};
  ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},revision++));meals.push({occurrenceId,groupId,ingredientId,bindingId,n,protectedMeal,meal,revision});
 }
 const input=draft(f);input.base.shopRevision=4;const manual=input.change.contributions[0];
 const imported=source(f,q(12));imported.source={kind:'import',batchId:randomUUID(),entryId:randomUUID()};imported.originalText='Imported duplicate twelve wraps';input.change.contributions.push(imported);
 input.change.edges.push({id:randomUUID(),kind:'duplicate',demandId:imported.id,supplyId:manual.id,quantity:q(12),confirmation:{productMatchConfirmed:true,confirmedAt:new Date().toISOString(),evidence:'Explicitly reviewed duplicate import of the same twelve wraps'}});
 for(const m of meals){const c=source(f,q(m.n));c.originalText=m.meal.title+' original wraps';c.source=m.protectedMeal?{kind:'reservation',reservationId:randomUUID(),purpose:'Protected lunch',originOccurrenceId:m.occurrenceId,ingredientId:m.ingredientId,groupId:m.groupId,bindingId:m.bindingId}:{kind:'meal',occurrenceId:m.occurrenceId,ingredientId:m.ingredientId,groupId:m.groupId,bindingId:m.bindingId};
  if(m.meal.title==='Tacos'){c.exclusions=['sesame'];c.sourceExclusions=[{occurrenceId:m.occurrenceId,ingredientId:m.ingredientId,label:'No sesame',resolution:{kind:'mapped',tags:['sesame'],confirmedAt:new Date().toISOString()}}];}
  m.sourceId=c.id;input.change.contributions.push(c);input.change.edges.push({id:randomUUID(),kind:'withinExisting',demandId:c.id,supplyId:manual.id,quantity:q(m.n),confirmation:{productMatchConfirmed:true,confirmedAt:new Date().toISOString(),evidence:'Explicitly reviewed within twelve wraps'}});
 }
 const wire=async(phase,requests=[],owner=f.owner,extra={})=>exerciseSharedDemandClient({service:server,owner,householdId:f.h,shopId:f.shopId,phase,requests,before:owner===f.owner?ok(await call(f.owner,f.path+'/demand')):null,privateState,...extra});
 const before=ok(await call(f.owner,f.path)),operations=await count(f,'operation');
 assert.equal((await wire('adopt-cancel',[input])).attempts,0);assert.deepEqual(ok(await call(f.owner,f.path)),before);assert.equal(await count(f,'operation'),operations);assert.equal(await count(f,'shared_demand_revision'),0);
 const applied=await wire('adopt-apply',[input],f.owner,{dropFirstReply:true});assert.equal(applied.attempts,2);assert.equal(applied.dropped,1);assert.deepEqual(applied.commands[0],applied.commands[1]);assert.equal(await count(f,'operation'),operations+1);
 const adopted=ok(await call(f.owner,f.path+'/demand'));assert.equal(adopted.graph.revision,1);assert.deepEqual(adopted.graph.contributions,input.change.contributions);assert.deepEqual(adopted.totals[0].quantity,{numerator:'12',denominator:'1'});
 const review={...input,mode:'review',base:{shopRevision:5,authorityEpoch:1,graphRevision:1},change:empty()};assert.equal((await wire('stale-device',[review])).attempts,3);assert.equal(await count(f,'shared_demand_revision'),2);
 const remove={...input,mode:'change',base:{shopRevision:6,authorityEpoch:1,graphRevision:2},change:{...empty(),removeSourceIds:[meals[0].sourceId]},action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:meals[0].occurrenceId,baseMealRevision:2,meal:null}}}};
 assert.equal((await wire('remove',[remove])).attempts,1);const removed=ok(await call(f.owner,f.path+'/demand'));assert.equal(removed.graph.revision,3);assert.equal(removed.graph.contributions.filter(c=>c.removedAt!==null).length,1);
 for(const c of adopted.graph.contributions.filter(c=>c.id!==meals[0].sourceId))assert.deepEqual(removed.graph.contributions.find(x=>x.id===c.id),c);
 assert.deepEqual(removed.graph.edges,adopted.graph.edges.filter(e=>e.demandId!==meals[0].sourceId));assert.deepEqual(removed.totals[0].quantity,{numerator:'12',denominator:'1'});assert.ok(!removed.totals[0].activeContributionIds.includes(meals[0].sourceId));
 const removalOperation=(await admin.query('SELECT operation_id FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=3',[f.h,f.shopId])).rows[0].operation_id;
 const extra=source(f,q(3));extra.originalText='Unrelated added three wraps';const basket={...f.basket,packs:3};const add={...input,mode:'change',base:{shopRevision:7,authorityEpoch:1,graphRevision:3},change:{...empty(),contributions:[extra]},action:{kind:'shop.patch',body:{quote:f.quote,lines:[basket]}}};
 const undo={...add,mode:'undo',base:{shopRevision:8,authorityEpoch:1,graphRevision:4},change:empty(),undoOperationId:removalOperation,action:{kind:'shop.patch',body:{quote:f.quote,lines:[basket],mealEdit:{occurrenceId:meals[0].occurrenceId,baseMealRevision:null,meal:meals[0].meal}}}};
 assert.equal((await wire('undo',[add,undo])).attempts,2);const restored=ok(await call(f.owner,f.path+'/demand'));assert.equal(restored.graph.revision,5);assert.deepEqual(restored.graph.contributions.find(c=>c.id===extra.id),extra);for(const c of adopted.graph.contributions)assert.deepEqual(restored.graph.contributions.find(x=>x.id===c.id),c);assert.deepEqual(restored.totals[0].quantity,{numerator:'15',denominator:'1'});
 const author=await invited(f);const request=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Guest wraps unknown quantity',ownQuantity:null,authoredAt:new Date().toISOString()},9,1,author)).request;
 const rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId:request.requestId,base:{shopRevision:9,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 const requested={...source(f,null),source:{kind:'request',requestId:request.requestId,appliedRequestRevision:1},originalText:request.originalItem};
 const requestInput={...add,base:{shopRevision:9,authorityEpoch:1,graphRevision:5},change:{...empty(),contributions:[requested]},action:{kind:'request.apply',body:{requestId:request.requestId,previewId:rp.previewId,acceptUnknown:false,acceptOverage:false}},packs:[{...input.packs[0],acceptUnresolved:true}]};
 assert.equal((await wire('request',[requestInput])).attempts,1);assert.equal(ok(await call(f.owner,f.path+'/demand')).totals[0].quantity,null);assert.equal((await wire('denied',[],author)).attempts,0);
 ok(await call(author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 const privacyPage=ok(await call(f.owner,f.path+'/demand'));assert.equal(privacyPage.status,'reviewRequired');assert.deepEqual(privacyPage.graph.contributions.find(c=>c.id===manual.id),manual);assert.deepEqual(privacyPage.graph.contributions.find(c=>c.id===meals[2].sourceId),adopted.graph.contributions.find(c=>c.id===meals[2].sourceId));
 for(const table of ['shared_demand_revision','shared_demand_preview','basket_line','shop_snapshot','operation_response'])assert.ok(!JSON.stringify((await admin.query('SELECT to_jsonb(t) value FROM ritc.'+table+' t WHERE household_id=$1',[f.h])).rows).includes(request.originalItem));
 assert.equal((await wire('privacy')).attempts,1);
});

// Proposed-action catalog regression lane. Uses this suite's existing isolated database fixture.
async function catalogInput(f,action){const page=ok(await call(f.owner,f.path+'/demand'));return{base:{shopRevision:page.shopRevision,authorityEpoch:page.authorityEpoch,graphRevision:page.graph.revision,graphDigest:page.graphDigest},action};}
const catalog=(f,input,a=f.owner)=>call(a,f.path+'/demand/action-sources','POST',input);
test('action source catalog: exact graph binding, read-only cancellation and preserved arbitrary IDs/edges',async()=>{
 const f=await fixture(),m=await mealGraph(f);ok((await apply(f,m.input,ok(await preview(f,m.input)))).response);
 const before=ok(await call(f.owner,f.path+'/demand')),other=await invited(f),changed=structuredClone(m.meal);
 changed.planning.ingredients[0].quantity.amount.numerator=5;changed.planning.bindings[0].quantity.amount.numerator=5;
 const action={kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:m.occurrenceId,baseMealRevision:2,meal:changed}}},input=await catalogInput(f,action);
 const countBefore=await count(f,'shared_demand_preview'),out=ok(await catalog(f,input));
 assert.equal(out.graphDigest,before.graphDigest);assert.deepEqual(out.base,input.base);
 const row=out.sources.find(r=>r.proposed.id===m.c.id);assert.deepEqual(row.before,m.c);assert.equal(row.proposed.quantity.amount.numerator,'5');assert.equal(row.proposed.originalText,m.c.originalText);
 assert.deepEqual(out.retainedContributionIds,[m.input.change.contributions[0].id]);assert.deepEqual(out.retirementCandidates,[]);
 assert.deepEqual(ok(await call(f.owner,f.path+'/demand')),before);assert.equal(await count(f,'shared_demand_preview'),countBefore,'catalog does not reserve or mutate a preview');
 assert.equal((await catalog(f,input,other)).status,404);
 for(const base of [{...input.base,graphRevision:2},{...input.base,graphDigest:'0'.repeat(64)},{...input.base,shopRevision:2},{...input.base,authorityEpoch:2}])assert.equal((await catalog(f,{...input,base})).status,409);
 const update={...m.input,mode:'change',base:{shopRevision:3,authorityEpoch:1,graphRevision:1},change:{...empty(),contributions:[{...row.before,quantity:row.proposed.quantity}],edges:[{...m.edge,quantity:q(5)}]},action};
 const p=ok(await preview(f,update));assert.deepEqual(p.after.contributions.find(c=>c.id===m.input.change.contributions[0].id),m.input.change.contributions[0]);
 ok((await apply(f,update,p)).response);assert.equal((await catalog(f,input)).status,409,'old catalog base cannot authorize another edit');
});
test('action source catalog: legacy and privacy reviewRequired reject until surviving-food recovery',async()=>{
 const f=await fixture(),legacy=ok(await call(f.owner,f.path+'/demand'));assert.equal(legacy.graphDigest,null);
 const fake={base:{shopRevision:1,authorityEpoch:1,graphRevision:1,graphDigest:'0'.repeat(64)},action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:randomUUID(),baseMealRevision:null,meal:{title:'Meal',day:null,kind:'dinner',portions:1,protected:false}}}}};
 assert.equal((await catalog(f,fake)).data.error.code,'demand_enabled_required');
 await adopt(f);const input=await catalogInput(f,fake.action);
 await admin.query('UPDATE ritc.shop SET demand_review_required=true WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId]);
 assert.equal(ok(await call(f.owner,f.path+'/demand')).graphDigest,null);
 assert.equal((await catalog(f,input)).data.error.code,'demand_enabled_required');
});
test('action source catalog: proposal grant revocation rejects catalog, preview and previously reviewed Apply',async()=>{
 const f=await fixture(),m=await mealGraph(f),planner=await invited(f);ok((await apply(f,m.input,ok(await preview(f,m.input)))).response);
 const changed=structuredClone(m.meal);changed.planning.ingredients[0].quantity.amount.numerator=5;changed.planning.bindings[0].quantity.amount.numerator=5;
 const proposalId=randomUUID();await admin.query('INSERT INTO ritc.meal_planner(household_id,shop_id,authority_epoch,revision,planner_id) VALUES($1,$2,1,1,$3)',[f.h,f.shopId,planner.id]);
 await admin.query('INSERT INTO ritc.shared_meal_change(household_id,shop_id,proposal_id,actor_id,authority_epoch,grant_revision,shop_revision,occurrence_id,base_meal_revision,body,original_meal,fingerprint) VALUES($1,$2,$3,$4,1,1,3,$5,2,$6,$7,$8)',[f.h,f.shopId,proposalId,planner.id,m.occurrenceId,{meal:changed},m.meal,'e'.repeat(64)]);
 const action={kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:m.occurrenceId,baseMealRevision:2,changeProposalId:proposalId,meal:changed}}},input=await catalogInput(f,action);
 ok(await catalog(f,input));const update={...m.input,mode:'change',base:{shopRevision:3,authorityEpoch:1,graphRevision:1},change:{...empty(),contributions:[{...m.c,quantity:q(5)}],edges:[{...m.edge,quantity:q(5)}]},action},p=ok(await preview(f,update));
 const state=async()=>(await admin.query('SELECT state FROM ritc.shared_meal_change WHERE household_id=$1 AND proposal_id=$2',[f.h,proposalId])).rows[0].state;
 assert.equal(await state(),'pending','catalog and preview cannot consume');
 await admin.query('UPDATE ritc.meal_planner SET revision=2 WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId]);
 assert.equal((await catalog(f,input)).data.error.code,'stale_proposal');assert.equal((await preview(f,update)).data.error.code,'stale_proposal');
 assert.equal((await apply(f,update,p)).response.status,409);assert.equal(await state(),'pending');assert.equal(ok(await call(f.owner,f.path+'/demand')).graph.revision,1);
});
test('action source catalog: exact move proposal remains pending and dismissal invalidates catalog/preview',async()=>{
 const f=await fixture(),m=await mealGraph(f),planner=await invited(f);ok((await apply(f,m.input,ok(await preview(f,m.input)))).response);
 const proposalId=randomUUID(),day='2026-11-12';await admin.query('INSERT INTO ritc.meal_planner(household_id,shop_id,authority_epoch,revision,planner_id) VALUES($1,$2,1,1,$3)',[f.h,f.shopId,planner.id]);
 await admin.query('INSERT INTO ritc.meal_move(household_id,shop_id,proposal_id,actor_id,authority_epoch,grant_revision,shop_revision,occurrence_id,proposed_day) VALUES($1,$2,$3,$4,1,1,3,$5,$6)',[f.h,f.shopId,proposalId,planner.id,m.occurrenceId,day]);
 const action={kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:m.occurrenceId,baseMealRevision:2,proposalId,meal:{...m.meal,day}}}},input=await catalogInput(f,action);
 const out=ok(await catalog(f,input));assert.ok(out.sources.every(r=>r.transition==='retain'));
 const review={...m.input,mode:'review',base:{shopRevision:3,authorityEpoch:1,graphRevision:1},change:empty(),action};ok(await preview(f,review));
 assert.equal((await admin.query('SELECT state FROM ritc.meal_move WHERE household_id=$1 AND proposal_id=$2',[f.h,proposalId])).rows[0].state,'pending');
 await admin.query("UPDATE ritc.meal_move SET state='dismissed' WHERE household_id=$1 AND proposal_id=$2",[f.h,proposalId]);
 assert.equal((await catalog(f,input)).data.error.code,'stale_proposal');assert.equal((await preview(f,review)).data.error.code,'stale_proposal');
});
test('action source catalog: approved idea becomes stale independently of shop/graph revision',async()=>{
 const f=await fixture(),a=await adopt(f),ideaId=randomUUID(),ingredientId=randomUUID(),ideaPath=f.path+'/meal-plan/ideas';
 const idea={title:'Reviewed wraps',source:'manual',servings:1,minutes:5,assumedExtras:[],exclusions:[],ingredients:[{id:ingredientId,name:'Wraps',required:2,unit:'count',stock:0,reservations:[],pack:6,usableNumerator:1,usableDenominator:1,evidence:'Shopper checked package'}]};
 const write={clientKey:randomUUID(),ideaId,baseRevision:null,shopRevision:2,authorityEpoch:1,grantRevision:0,action:'save',draft:idea,reviewedHouseholdEvidence:false};
 const saved=ok(await call(f.owner,ideaPath,'POST',write));const approved=ok(await call(f.owner,ideaPath,'POST',{...write,clientKey:randomUUID(),baseRevision:saved.revision,action:'approve',reviewedHouseholdEvidence:true}));
 const meal={title:idea.title,day:null,kind:'dinner',portions:1,protected:false,planning:{leadTimeMinutes:5,groups:[],ingredients:[{id:ingredientId,name:'Wraps',quantity:{amount:{numerator:2,denominator:1},unit:'count',originalLiteral:'2 count'},groupIds:[],exclusions:[]}]}};
 const proposal={proposalId:randomUUID(),occurrenceId:randomUUID(),baseMealRevision:null,shopRevision:2,authorityEpoch:1,grantRevision:0,approvedIdeaId:ideaId,approvedIdeaRevision:approved.revision,meal,reason:'Reviewed exact meal'};
 ok(await call(f.owner,f.path+'/meal-plan/changes','POST',proposal));
 const action={kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:proposal.occurrenceId,baseMealRevision:null,changeProposalId:proposal.proposalId,meal}}},input=await catalogInput(f,action),out=ok(await catalog(f,input)),row=out.sources[0].proposed;
 assert.equal(out.sources[0].transition,'new');assert.equal(row.quantity.amount.numerator,'2');
 const contribution={id:row.id,lineId:f.basket.lineId,source:row.source,productKey:'wraps',productName:row.productName,originalText:row.originalText,quantity:row.quantity,sourceExclusions:row.sourceExclusions,exclusions:[],contains:[],removedAt:null};
 const edge={id:randomUUID(),kind:'withinExisting',demandId:row.id,supplyId:a.input.change.contributions[0].id,quantity:q(2),confirmation:{productMatchConfirmed:true,confirmedAt:new Date().toISOString(),evidence:'Shopper confirms same wraps'}};
 const update={...a.input,mode:'change',base:{shopRevision:2,authorityEpoch:1,graphRevision:1},change:{...empty(),contributions:[contribution],edges:[edge]},action},p=ok(await preview(f,update));
 ok(await call(f.owner,ideaPath,'POST',{...write,clientKey:randomUUID(),baseRevision:approved.revision,draft:{...idea,title:'Changed idea'}}));
 assert.equal((await catalog(f,input)).data.error.code,'stale_idea');assert.equal((await preview(f,update)).data.error.code,'stale_idea');assert.equal((await apply(f,update,p)).response.status,409);
 assert.equal(ok(await call(f.owner,f.path+'/demand')).graph.revision,1);assert.equal((await admin.query('SELECT state FROM ritc.shared_meal_change WHERE household_id=$1 AND proposal_id=$2',[f.h,proposal.proposalId])).rows[0].state,'pending');
});

test('action source catalog: same-identity protected unknown requires explicit quantification before persisted Apply',async()=>{
 const f=await fixture(),occurrenceId=randomUUID(),ingredientId=randomUUID();
 const meal={title:'Protected lunch',day:null,kind:'lunch',portions:2,protected:true,planning:{groups:[],ingredients:[{id:ingredientId,name:'Wraps',quantity:null,groupIds:[],exclusions:[]}]}};
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},1));
 const reserve={...source(f,null),originalText:'Original protected lunch',source:{kind:'reservation',reservationId:randomUUID(),purpose:'Protected lunch',originOccurrenceId:occurrenceId,ingredientId,groupId:null,bindingId:null}};
 const adoption=draft(f,reserve);adoption.base.shopRevision=2;adoption.packs[0].acceptUnresolved=true;
 ok((await apply(f,adoption,ok(await preview(f,adoption)))).response);
 const before=ok(await call(f.owner,f.path+'/demand')),changed=structuredClone(meal);changed.planning.ingredients[0].quantity={amount:{numerator:6,denominator:1},unit:'count',originalLiteral:'6 wraps'};
 const action={kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId,baseMealRevision:2,meal:changed}}},input=await catalogInput(f,action),previews=await count(f,'shared_demand_preview');
 const out=ok(await catalog(f,input)),row=out.sources[0];assert.equal(row.transition,'quantifyReservation');assert.equal(row.proposed.id,reserve.id);assert.deepEqual(row.proposed.source,reserve.source);
 assert.deepEqual(ok(await call(f.owner,f.path+'/demand')),before);assert.equal(await count(f,'shared_demand_preview'),previews);
 const quantified={...row.before,source:row.proposed.source,quantity:row.proposed.quantity};
 const update={...adoption,mode:'change',base:{shopRevision:3,authorityEpoch:1,graphRevision:1},change:{...empty(),contributions:[quantified]},action};
 assert.equal((await preview(f,update)).data.error.code,'protected_unknown_changed');
 update.change.quantifyReservationIds=[row.proposed.id];const reviewed=ok(await preview(f,update));assert.deepEqual(ok(await call(f.owner,f.path+'/demand')),before);
 const applied=await apply(f,update,reviewed),receipt=ok(applied.response);assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',applied.command)),receipt);
 const saved=ok(await call(f.owner,f.path+'/demand'));assert.equal(saved.graph.revision,2);assert.deepEqual(saved.graph.contributions,[quantified]);assert.equal(await count(f,'shared_demand_revision'),2);
 assert.equal((await catalog(f,input)).status,409);
});

if(process.env.RITC_TEST_NATIVE_WIRE==='1')test('actual Swift meal action catalog preserves Cancel, protected quantification, conversion reconfirmation and revoked proposal authority over HTTPS and PostgreSQL',async()=>{
 const {exerciseSharedDemandClient}=await import('./shared-demand-native-wire.mjs');
 const {mkdtemp,chmod}=await import('node:fs/promises');const {join}=await import('node:path');const {tmpdir}=await import('node:os');
 const state=async()=>{const p=await mkdtemp(join(process.env.RITC_NATIVE_WIRE_STATE??tmpdir(),'meal-action-client-'));await chmod(p,0o700);return p;};
 const wire=async(f,phase,request,extra={})=>exerciseSharedDemandClient({service:server,owner:f.owner,householdId:f.h,shopId:f.shopId,phase,requests:[request],before:ok(await call(f.owner,f.path+'/demand')),privateState:await state(),...extra});
 const counters=async f=>({operations:await count(f,'operation'),graphs:await count(f,'shared_demand_revision'),previews:await count(f,'shared_demand_preview')});
 // Actual typed catalog acquisition and Cancel. Preserve arbitrary persisted IDs and existing edge.
 const cancelled=await fixture(),cm=await mealGraph(cancelled);ok((await apply(cancelled,cm.input,ok(await preview(cancelled,cm.input)))).response);
 const cancelBefore=ok(await call(cancelled.owner,cancelled.path)),cancelDemand=ok(await call(cancelled.owner,cancelled.path+'/demand')),cancelCounts=await counters(cancelled);
 const paddedMeal=structuredClone(cm.meal);paddedMeal.title='  Proposed title only  ';paddedMeal.planning.groups[0].name='  Dinner group  ';paddedMeal.planning.ingredients[0].name='  Wraps  ';
 const cancelRequest={...cm.input,mode:'review',base:{shopRevision:3,authorityEpoch:1,graphRevision:1},change:empty(),action:{kind:'shop.patch',body:{quote:cancelled.quote,lines:[cancelled.basket],mealEdit:{occurrenceId:cm.occurrenceId,baseMealRevision:2,meal:paddedMeal}}}};
 const cancel=await wire(cancelled,'meal-catalog-cancel',cancelRequest);
 assert.equal(cancel.catalogAttempts,1);assert.equal(cancel.previewAttempts,0);assert.equal(cancel.attempts,0);
 const sent=JSON.parse(cancel.catalogRequests[0]);assert.deepEqual(sent.base,{...cancelRequest.base,graphDigest:cancelDemand.graphDigest});assert.equal(sent.action.kind,cancelRequest.action.kind);assert.deepEqual(bodySchemas['shop.patch'].parse(sent.action.body),bodySchemas['shop.patch'].parse(cancelRequest.action.body));
 assert.deepEqual(ok(await call(cancelled.owner,cancelled.path)),cancelBefore);assert.deepEqual(ok(await call(cancelled.owner,cancelled.path+'/demand')),cancelDemand);assert.deepEqual(await counters(cancelled),cancelCounts);
 // Explicit protected unknown -> known. JS supplies only the meal action, not a graph delta.
 const protectedCase=await fixture(),occurrenceId=randomUUID(),ingredientId=randomUUID();
 const meal={title:'Protected lunch',day:null,kind:'lunch',portions:2,protected:true,planning:{groups:[],ingredients:[{id:ingredientId,name:'Wraps',quantity:null,groupIds:[],exclusions:[]}]}};
 ok(await send(protectedCase,'shop.patch',{quote:protectedCase.quote,lines:[protectedCase.basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},1));
 const reserve={...source(protectedCase,null),originalText:'Original protected lunch',contains:['wheat'],exclusions:['sesame'],source:{kind:'reservation',reservationId:randomUUID(),purpose:'Protected lunch',originOccurrenceId:occurrenceId,ingredientId,groupId:null,bindingId:null}};
 const adoption=draft(protectedCase);adoption.base.shopRevision=2;adoption.change.contributions.push(reserve);adoption.packs[0].acceptUnresolved=true;
 ok((await apply(protectedCase,adoption,ok(await preview(protectedCase,adoption)))).response);
 const protectedBefore=ok(await call(protectedCase.owner,protectedCase.path+'/demand')),protectedCounts=await counters(protectedCase);
 const changed=structuredClone(meal);changed.planning.ingredients[0].quantity={amount:{numerator:6,denominator:1},unit:'count',originalLiteral:'6 wraps'};
 const protectedRequest={...adoption,mode:'change',base:{shopRevision:3,authorityEpoch:1,graphRevision:1},change:empty(),action:{kind:'shop.patch',body:{quote:protectedCase.quote,lines:[{...protectedCase.basket,packs:3}],mealEdit:{occurrenceId,baseMealRevision:2,meal:changed}}}};
 const applied=await wire(protectedCase,'meal-protected-apply',protectedRequest,{dropFirstReply:true});
 assert.equal(applied.attempts,2);assert.equal(applied.dropped,1);assert.deepEqual(applied.commands[0],applied.commands[1]);assert.equal(applied.catalogAttempts,2);assert.equal(applied.previewAttempts,2);
 const protectedAfter=ok(await call(protectedCase.owner,protectedCase.path+'/demand')),accepted=protectedAfter.graph.contributions.find(c=>c.id===reserve.id);
 assert.deepEqual(accepted,{...reserve,quantity:q(6)});assert.deepEqual(protectedAfter.graph.contributions.find(c=>c.id!==reserve.id),protectedBefore.graph.contributions.find(c=>c.id!==reserve.id));assert.deepEqual(protectedAfter.graph.edges,protectedBefore.graph.edges);
 assert.equal(protectedAfter.graph.revision,2);assert.equal(protectedAfter.shopRevision,4);assert.deepEqual(protectedAfter.totals[0].quantity,{numerator:'18',denominator:'1'});
 assert.equal(await count(protectedCase,'operation'),protectedCounts.operations+1);assert.equal(await count(protectedCase,'shared_demand_revision'),protectedCounts.graphs+1);assert.equal(await count(protectedCase,'shared_demand_preview'),protectedCounts.previews);
 // A real authorized grant revocation occurs after typed preview/preparation and before the second catalog dispatch.
 const revoked=await fixture(),rm=await mealGraph(revoked),planner=await invited(revoked);ok((await apply(revoked,rm.input,ok(await preview(revoked,rm.input)))).response);
 ok(await call(revoked.owner,revoked.path+'/meal-plan/planner','PUT',{authorityEpoch:1,grantRevision:0,plannerId:planner.id}));
 const proposalId=randomUUID(),proposed={...rm.meal,title:'Planner proposed title'};
 // Deterministic setup only: reuse the existing proposal fixture without adding billing/network fixtures.
 await admin.query('INSERT INTO ritc.shared_meal_change(household_id,shop_id,proposal_id,actor_id,authority_epoch,grant_revision,shop_revision,occurrence_id,base_meal_revision,body,original_meal,fingerprint) VALUES($1,$2,$3,$4,1,1,3,$5,2,$6,$7,$8)',[revoked.h,revoked.shopId,proposalId,planner.id,rm.occurrenceId,{meal:proposed},rm.meal,'e'.repeat(64)]);
 const revokedBefore=ok(await call(revoked.owner,revoked.path)),revokedDemand=ok(await call(revoked.owner,revoked.path+'/demand')),revokedCounts=await counters(revoked);let revocations=0;
 const revokedRequest={...rm.input,mode:'review',base:{shopRevision:3,authorityEpoch:1,graphRevision:1},change:empty(),action:{kind:'shop.patch',body:{quote:revoked.quote,lines:[revoked.basket],mealEdit:{occurrenceId:rm.occurrenceId,baseMealRevision:2,changeProposalId:proposalId,meal:proposed}}}};
 const rejection=await wire(revoked,'meal-proposal-revoked',revokedRequest,{beforeCatalogRequest:async attempt=>{if(attempt===2){ok(await call(revoked.owner,revoked.path+'/meal-plan/planner','PUT',{authorityEpoch:1,grantRevision:1,plannerId:null}));revocations++;}}});
 assert.equal(revocations,1);assert.equal(rejection.catalogAttempts,2);assert.equal(rejection.previewAttempts,2);assert.equal(rejection.attempts,1);assert.deepEqual(rejection.catalogRequests[0],rejection.catalogRequests[1]);
 assert.deepEqual(ok(await call(revoked.owner,revoked.path)),revokedBefore);assert.deepEqual(ok(await call(revoked.owner,revoked.path+'/demand')),revokedDemand);
 assert.equal(await count(revoked,'operation'),revokedCounts.operations);assert.equal(await count(revoked,'shared_demand_revision'),revokedCounts.graphs);
 const proposal=(await admin.query('SELECT state FROM ritc.shared_meal_change WHERE household_id=$1 AND proposal_id=$2',[revoked.h,proposalId])).rows[0];assert.equal(proposal.state,'pending');
 const grant=(await admin.query('SELECT planner_id,revision FROM ritc.meal_planner WHERE household_id=$1 AND shop_id=$2',[revoked.h,revoked.shopId])).rows[0];assert.equal(grant.planner_id,null);assert.equal(Number(grant.revision),2);
 // Fixed authoritative cups stay cups; only an explicit new endpoint basis may retain the gram allocation.
 const converted=await fixture();converted.basket={...converted.basket,originalItem:'Flour'};
 const convertOccurrence=randomUUID(),convertIngredient=randomUUID(),basis={sourceUnit:'cup',targetUnit:'gram',targetAmountPerSourceUnit:{numerator:'120',denominator:'1'},sourceNote:'Original reviewed flour label',confirmedAt:'2026-11-01T12:00:00Z'};
 const grams={amount:{numerator:'120',denominator:'1'},unit:'gram',originalLiteral:'120 g',confirmedConversion:null};
 const cup={amount:{numerator:'1',denominator:'1'},unit:'cup',originalLiteral:'1 measured cup',confirmedConversion:basis};
 const convertMeal={title:'Measured flour',day:null,kind:'dinner',portions:1,protected:false,planning:{groups:[],ingredients:[{id:convertIngredient,name:'Flour',quantity:{amount:{numerator:1,denominator:1},unit:'cup',originalLiteral:'1 measured cup'},groupIds:[],exclusions:[]}]}};
 ok(await send(converted,'shop.patch',{quote:converted.quote,lines:[converted.basket],mealEdit:{occurrenceId:convertOccurrence,baseMealRevision:null,meal:convertMeal}},1));
 const manual={...source(converted,grams),productKey:'flour',productName:'Flour',originalText:'Original manual flour'};
 const cupSource={...source(converted,cup),productKey:'flour',productName:'Flour',originalText:'Original meal flour',source:{kind:'meal',occurrenceId:convertOccurrence,ingredientId:convertIngredient,groupId:null,bindingId:null}};
 const allocation={id:randomUUID(),kind:'withinExisting',demandId:cupSource.id,supplyId:manual.id,quantity:{...grams,confirmedConversion:basis},confirmation:{productMatchConfirmed:true,confirmedAt:'2026-11-01T12:00:00Z',evidence:'Explicit same flour allocation'}};
 const convertAdoption=draft(converted,manual);convertAdoption.base.shopRevision=2;convertAdoption.change.lines[0].name='Flour';convertAdoption.change.lines[0].unit='gram';convertAdoption.change.contributions.push(cupSource);convertAdoption.change.edges.push(allocation);convertAdoption.packs[0].usablePerPack=grams;
 ok((await apply(converted,convertAdoption,ok(await preview(converted,convertAdoption)))).response);
 const convertBefore=ok(await call(converted.owner,converted.path+'/demand')),convertCounts=await counters(converted);assert.deepEqual(convertBefore.totals[0].quantity,{numerator:'120',denominator:'1'});
 const changedCup=structuredClone(convertMeal);changedCup.planning.ingredients[0].quantity.amount.numerator=2;changedCup.planning.ingredients[0].quantity.originalLiteral='2 measured cups';
 const convertRequest={...convertAdoption,mode:'change',base:{shopRevision:3,authorityEpoch:1,graphRevision:1},change:empty(),action:{kind:'shop.patch',body:{quote:converted.quote,lines:[converted.basket],mealEdit:{occurrenceId:convertOccurrence,baseMealRevision:2,meal:changedCup}}}};
 const conversion=await wire(converted,'meal-conversion-apply',convertRequest);assert.equal(conversion.attempts,1);assert.equal(conversion.dropped,0);assert.equal(conversion.previewAttempts,3);assert.equal(conversion.catalogAttempts,2);
 const convertAfter=ok(await call(converted.owner,converted.path+'/demand')),result=convertAfter.graph.contributions.find(c=>c.id===cupSource.id),newBasis=result.quantity.confirmedConversion;
 assert.deepEqual({...result,quantity:cupSource.quantity},cupSource);assert.equal(result.quantity.unit,'cup');assert.deepEqual(result.quantity.amount,{numerator:'2',denominator:'1'});assert.equal(result.quantity.originalLiteral,'2 measured cups');
 assert.deepEqual({...newBasis,sourceNote:basis.sourceNote,confirmedAt:basis.confirmedAt},basis);assert.equal(newBasis.sourceNote,'Explicit reconfirmation for changed meal');assert.notEqual(newBasis.confirmedAt,basis.confirmedAt);
 assert.deepEqual(convertAfter.graph.edges,[allocation]);assert.deepEqual(convertAfter.graph.contributions.find(c=>c.id===manual.id),manual);assert.deepEqual(convertAfter.totals[0].quantity,{numerator:'240',denominator:'1'});
 assert.equal(convertAfter.graph.revision,2);assert.equal(convertAfter.shopRevision,4);assert.equal(await count(converted,'operation'),convertCounts.operations+1);assert.equal(await count(converted,'shared_demand_revision'),convertCounts.graphs+1);assert.equal(await count(converted,'shared_demand_preview'),convertCounts.previews);
});

// Complete operation Undo: the original graph-only tests above remain unchanged.
const undoBase=page=>({shopRevision:page.shopRevision,authorityEpoch:page.authorityEpoch,graphRevision:page.graph.revision,graphDigest:page.graphDigest});
const foodHistory=async f=>ok(await call(f.owner,f.path+'/demand/operations'));
const foodCandidate=async(f,targetOperationId,page)=>call(f.owner,f.path+'/demand/operation-undo-candidates','POST',{targetOperationId,base:undoBase(page)});
const foodPreview=async(f,candidate,packs)=>call(f.owner,f.path+'/demand/operation-undo-previews','POST',{targetOperationId:candidate.targetOperationId,base:candidate.base,effectDigest:candidate.effectDigest,packs});
async function addedFoodOperation(f){
 const page=ok(await call(f.owner,f.path+'/demand')),extra=source(f,q(4)),basket={...f.basket,packs:3},quote={...f.quote,capMinor:f.quote.capMinor+100};
 const input={mode:'change',base:{shopRevision:page.shopRevision,authorityEpoch:page.authorityEpoch,graphRevision:page.graph.revision},change:{...empty(),contributions:[extra]},action:{kind:'shop.patch',body:{quote,lines:[basket]}},packs:[{lineId:basket.lineId,usablePerPack:q(6),acceptUnresolved:false}]};
 const p=ok(await preview(f,input)),accepted=await apply(f,input,p);return{input,extra,receipt:ok(accepted.response),command:accepted.command};
}
test('complete food operation Undo: relaunch, Cancel, later staple, exact graph/packs/quote and one Apply/retry',async()=>{
 const f=await fixture(),adoption=await adopt(f),target=await addedFoodOperation(f),page=ok(await call(f.owner,f.path+'/demand'));
 const basket={lineId:randomUUID(),originalItem:'Later staple',packs:1,unitPriceMinor:250,feeEligible:false};
 const extra={...source(f,q(1)),lineId:basket.lineId,productKey:'staple',productName:'Staple',originalText:'Later staple'};
 const input={mode:'change',base:{shopRevision:page.shopRevision,authorityEpoch:1,graphRevision:page.graph.revision},change:{...empty(),lines:[{id:basket.lineId,name:basket.originalItem,unit:'count',originalOrder:9,trashedAt:null}],contributions:[extra]},action:{kind:'shop.patch',body:{quote:target.input.action.body.quote,lines:[{...target.input.action.body.lines[0],unitPriceMinor:150},basket]}},packs:[...target.input.packs,{lineId:basket.lineId,usablePerPack:q(1),acceptUnresolved:false}]};
 ok((await apply(f,input,ok(await preview(f,input)))).response);
 const second=await actor(f.owner.subject);await enroll(second,f.h);f.owner=second;
 const current=ok(await call(f.owner,f.path+'/demand')),history=await foodHistory(f);
 assert.equal(history.items.find(x=>x.operationId===target.receipt.operationId).eligibility.status,'reviewable');
 assert.equal(history.items.find(x=>x.operationId===ok(adoption.response).operationId).eligibility.reason,'food_undo_first_adoption_unsupported');
 const operations=await count(f,'operation'),snapshots=await count(f,'shop_snapshot'),previews=await count(f,'shared_demand_preview');
 const candidate=ok(await foodCandidate(f,target.receipt.operationId,current));
 assert.equal(await count(f,'shared_demand_preview'),previews,'candidate creates no preview');assert.equal(await count(f,'operation'),operations);
 assert.deepEqual([...candidate.packReviewLineIds].sort(),[f.basket.lineId,basket.lineId].sort());assert.equal(candidate.action.body.lines.find(l=>l.lineId===f.basket.lineId).packs,2);assert.equal(candidate.action.body.lines.find(l=>l.lineId===f.basket.lineId).unitPriceMinor,150);
 assert.deepEqual(candidate.action.body.quote,f.quote);assert.deepEqual(candidate.after.contributions.find(c=>c.id===extra.id),extra);
 const packs=[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:false},{lineId:basket.lineId,usablePerPack:q(1),acceptUnresolved:false}];
 const cancelled=ok(await foodPreview(f,candidate,packs));assert.equal(await count(f,'operation'),operations);assert.equal(await count(f,'shop_snapshot'),snapshots);assert.deepEqual(ok(await call(f.owner,f.path+'/demand')),current);
 const p=ok(await foodPreview(f,candidate,packs));assert.notEqual(cancelled.previewId,p.previewId);
 const applied=await apply(f,{action:p.action,base:candidate.base},p),receipt=ok(applied.response);
 assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',applied.command)),receipt);
 assert.equal(await count(f,'operation'),operations+1);assert.equal(await count(f,'shared_food_operation_effect'),3+1);
 const after=ok(await call(f.owner,f.path)),graph=ok(await call(f.owner,f.path+'/demand'));
 assert.equal(after.lines.find(l=>l.lineId===f.basket.lineId).packs,2);assert.equal(after.lines.find(l=>l.lineId===f.basket.lineId).unitPriceMinor,150);assert.deepEqual(after.lines.find(l=>l.lineId===basket.lineId),basket);assert.deepEqual(after.quote,f.quote);
 assert.deepEqual(graph.graph.contributions.find(c=>c.id===extra.id),extra);assert.ok(graph.graph.contributions.find(c=>c.id===target.extra.id).removedAt);
 assert.equal((await foodCandidate(f,target.receipt.operationId,graph)).data.error.code,'food_undo_already_reversed');
 assert.equal((await call(f.owner,f.base+'/commands','POST',{...applied.command,clientKey:randomUUID()})).status,409);
 const bound=(await admin.query('SELECT reverses_operation_id FROM ritc.shared_food_operation_effect WHERE household_id=$1 AND operation_id=$2',[f.h,receipt.operationId])).rows[0];assert.equal(bound.reverses_operation_id,target.receipt.operationId);
});
test('complete Undo supports pack-only empty graph reviews and rejects a later touched pack conflict',async()=>{
 const f=await fixture();await adopt(f);let page=ok(await call(f.owner,f.path+'/demand'));
 const input={mode:'review',base:{shopRevision:page.shopRevision,authorityEpoch:1,graphRevision:page.graph.revision},change:empty(),action:{kind:'shop.patch',body:{quote:f.quote,lines:[{...f.basket,packs:3}]}},packs:[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:false}]};
 const target=ok((await apply(f,input,ok(await preview(f,input)))).response);page=ok(await call(f.owner,f.path+'/demand'));
 const candidate=ok(await foodCandidate(f,target.operationId,page));assert.equal(candidate.scope.graphRows,0);
 const p=ok(await foodPreview(f,candidate,input.packs));assert.deepEqual(p.receipt.contributions,[]);assert.equal(p.action.body.lines[0].packs,2);
 const later={...input,base:{shopRevision:page.shopRevision,authorityEpoch:1,graphRevision:page.graph.revision},action:{kind:'shop.patch',body:{quote:f.quote,lines:[{...f.basket,packs:4}]}}};
 ok((await apply(f,later,ok(await preview(f,later)))).response);page=ok(await call(f.owner,f.path+'/demand'));
 assert.equal((await foodCandidate(f,target.operationId,page)).data.error.code,'food_undo_line_conflict');
 assert.equal((await apply(f,{action:p.action,base:candidate.base},p)).response.status,409);
 assert.equal((await foodHistory(f)).items.find(x=>x.operationId===target.operationId).eligibility.reason,'food_undo_line_conflict');
});
test('complete Undo rejects an expired restored quote and does not weaken current base or authorization',async()=>{
 const f=await fixture();await adopt(f);
 // Current draft explicitly records an already-expired historical price basis; this is valid draft evidence, not fresh prices.
 const old=ok(await call(f.owner,f.path+'/demand')),expired={...f.quote,observedAt:new Date(Date.now()-120000).toISOString(),expiresAt:new Date(Date.now()-60000).toISOString()};
 const initial={mode:'review',base:{shopRevision:old.shopRevision,authorityEpoch:1,graphRevision:old.graph.revision},change:empty(),action:{kind:'shop.patch',body:{quote:expired,lines:[f.basket]}},packs:[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:false}]};
 ok((await apply(f,initial,ok(await preview(f,initial)))).response);
 const page=ok(await call(f.owner,f.path+'/demand')),fresh={...initial,base:{shopRevision:page.shopRevision,authorityEpoch:1,graphRevision:page.graph.revision},action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket]}}};
 const target=ok((await apply(f,fresh,ok(await preview(f,fresh)))).response),current=ok(await call(f.owner,f.path+'/demand'));
 assert.equal((await foodCandidate(f,target.operationId,current)).data.error.code,'food_undo_expired_quote');
 assert.equal((await foodCandidate(f,target.operationId,page)).status,409);
 const other=await invited(f);assert.equal((await call(other,f.path+'/demand/operations')).status,404);
 assert.equal((await call(other,f.path+'/demand/operation-undo-candidates','POST',{targetOperationId:target.operationId,base:undoBase(current)})).status,404);
 assert.equal((await foodHistory(f)).items.find(x=>x.operationId===target.operationId).eligibility.reason,'food_undo_expired_quote');
});
test('complete Undo exact replay cannot resurrect target history after authorized privacy erasure',async()=>{
 const f=await fixture(),author=f.owner;await adopt(f);const target=await addedFoodOperation(f),shopper=await invited(f);
 ok(await send(f,'shop.transferAuthority',{newShopperId:shopper.id},3));f.owner=shopper;
 const page=ok(await call(f.owner,f.path+'/demand')),candidate=ok(await foodCandidate(f,target.receipt.operationId,page));
 const p=ok(await foodPreview(f,candidate,[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:false}]));
 const applied=await apply(f,{action:p.action,base:candidate.base},p),receipt=ok(applied.response);assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',applied.command)),receipt);
 ok(await call(author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'transfer',organizerMemberId:shopper.id,shops:[],eraseChildProfiles:[]}]}),202);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal((await call(f.owner,f.base+'/commands','POST',applied.command)).status,409);
 const history=await foodHistory(f);assert.ok(history.items.every(x=>x.eligibility.status==='unavailable'));assert.ok(!JSON.stringify(history).includes('12 wraps'));
});
test('complete Undo does not relabel historical line prices with a later fresh quote',async()=>{
 const f=await fixture();await adopt(f);let page=ok(await call(f.owner,f.path+'/demand'));
 const input={mode:'review',base:{shopRevision:page.shopRevision,authorityEpoch:1,graphRevision:page.graph.revision},change:empty(),action:{kind:'shop.patch',body:{quote:f.quote,lines:[{...f.basket,unitPriceMinor:150}]}},packs:[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:false}]};
 const target=ok((await apply(f,input,ok(await preview(f,input)))).response);page=ok(await call(f.owner,f.path+'/demand'));
 const newQuote={...f.quote,observedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+7200000).toISOString()};
 const later={...input,base:{shopRevision:page.shopRevision,authorityEpoch:1,graphRevision:page.graph.revision},action:{kind:'shop.patch',body:{quote:newQuote,lines:input.action.body.lines}}};
 ok((await apply(f,later,ok(await preview(f,later)))).response);page=ok(await call(f.owner,f.path+'/demand'));
 const before=await count(f,'operation');assert.equal((await foodCandidate(f,target.operationId,page)).data.error.code,'food_undo_quote_conflict');assert.equal(await count(f,'operation'),before);
});
test('complete Undo admits a recorded date-only meal change but keeps request Link explicitly unsupported',async()=>{
 const f=await fixture(),m=await mealGraph(f);ok((await apply(f,m.input,ok(await preview(f,m.input)))).response);
 let page=ok(await call(f.owner,f.path+'/demand'));
 const date={mode:'review',base:{shopRevision:page.shopRevision,authorityEpoch:1,graphRevision:page.graph.revision},change:empty(),action:{kind:'shop.patch',body:{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:m.occurrenceId,baseMealRevision:2,meal:{...m.meal,day:'2026-11-10'}}}},packs:m.input.packs};
 const dated=ok((await apply(f,date,ok(await preview(f,date)))).response);page=ok(await call(f.owner,f.path+'/demand'));
 const dateCandidate=ok(await foodCandidate(f,dated.operationId,page));assert.equal(dateCandidate.scope.mealsChanged,true);
 assert.equal(dateCandidate.action.body.mealEdit.meal.day,null);assert.deepEqual(dateCandidate.mealUndo.touchedFields,['day']);
 const author=await invited(f),sent=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Guest wraps',ownQuantity:null,authoredAt:new Date().toISOString()},page.shopRevision,1,author));
 const requestId=sent.request.requestId,rp=ok(await call(f.owner,f.path+'/previews','POST',{requestId,base:{shopRevision:page.shopRevision,authorityEpoch:1,requestRevision:1},decision:{choice:'link',lineId:f.basket.lineId,promote:false}}));
 const requestSource={...source(f,null),originalText:'Guest wraps',source:{kind:'request',requestId,appliedRequestRevision:1}};
 const accepted={mode:'change',base:{shopRevision:page.shopRevision,authorityEpoch:1,graphRevision:page.graph.revision},change:{...empty(),contributions:[requestSource]},action:{kind:'request.apply',body:{requestId,previewId:rp.previewId,acceptOverage:false,acceptUnknown:true}},packs:[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:true}]};
 const linked=ok((await apply(f,accepted,ok(await preview(f,accepted)))).response);page=ok(await call(f.owner,f.path+'/demand'));
 assert.equal((await foodCandidate(f,linked.operationId,page)).data.error.code,'food_undo_request_acceptance_unsupported');
 const history=await foodHistory(f);assert.equal(history.items.find(x=>x.operationId===dated.operationId).eligibility.status,'reviewable');assert.equal(history.items.find(x=>x.operationId===linked.operationId).eligibility.reason,'food_undo_request_acceptance_unsupported');
});
for(const later of ['price','priced staple'])test('complete Undo refuses an older quote observation over later '+later,async()=>{
 const f=await fixture();await adopt(f);let page=ok(await call(f.owner,f.path+'/demand'));
 const refreshed={...f.quote,observedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+7200000).toISOString()};
 const targetInput={mode:'review',base:{shopRevision:page.shopRevision,authorityEpoch:1,graphRevision:page.graph.revision},change:empty(),action:{kind:'shop.patch',body:{quote:refreshed,lines:[f.basket]}},packs:[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:false}]};
 const target=ok((await apply(f,targetInput,ok(await preview(f,targetInput)))).response);page=ok(await call(f.owner,f.path+'/demand'));
 const input={...targetInput,base:{shopRevision:page.shopRevision,authorityEpoch:1,graphRevision:page.graph.revision},change:empty(),action:{kind:'shop.patch',body:{quote:refreshed,lines:[{...f.basket,unitPriceMinor:150}]}}};
 if(later==='priced staple'){
  const basket={lineId:randomUUID(),originalItem:'New priced staple',packs:1,unitPriceMinor:250,feeEligible:false};
  const c={...source(f,q(1)),lineId:basket.lineId,productKey:'staple',productName:'Staple',originalText:'New priced staple'};
  input.mode='change';input.change={...empty(),lines:[{id:basket.lineId,name:basket.originalItem,unit:'count',originalOrder:10,trashedAt:null}],contributions:[c]};
  input.action.body.lines=[f.basket,basket];input.packs=[...targetInput.packs,{lineId:basket.lineId,usablePerPack:q(1),acceptUnresolved:false}];
 }
 ok((await apply(f,input,ok(await preview(f,input)))).response);page=ok(await call(f.owner,f.path+'/demand'));
 const current=ok(await call(f.owner,f.path)),countBefore=await count(f,'operation');
 assert.equal((await foodCandidate(f,target.operationId,page)).data.error.code,'food_undo_quote_conflict');
 assert.equal((await foodHistory(f)).items.find(x=>x.operationId===target.operationId).eligibility.reason,'food_undo_quote_conflict');
 assert.deepEqual(ok(await call(f.owner,f.path)),current);assert.equal(await count(f,'operation'),countBefore);
});

// Existing-occurrence complete Undo: real HTTP, no client-provided preimages.
async function mealUndoFixture(){
 const f=await fixture(),m=await mealGraph(f);ok((await apply(f,m.input,ok(await preview(f,m.input)))).response);return {f,m};
}
async function mealUndoPatch(f,occurrenceId,meal,{change=empty(),lines,quote,proposal={}}={}){
 const shop=ok(await call(f.owner,f.path)),page=ok(await call(f.owner,f.path+'/demand'));
 const current=shop.meals.find(m=>m.occurrenceId===occurrenceId);
 const input={mode:Object.values(change).some(values=>values.length>0)?'change':'review',base:{shopRevision:page.shopRevision,authorityEpoch:page.authorityEpoch,graphRevision:page.graph.revision},change,
  action:{kind:'shop.patch',body:{quote:quote??shop.quote,lines:lines??shop.lines,mealEdit:{occurrenceId,baseMealRevision:current?.revision??null,meal,...proposal}}},
  packs:(lines??shop.lines).map(l=>({lineId:l.lineId,usablePerPack:q(6),acceptUnresolved:false}))};
 const p=ok(await preview(f,input)),accepted=await apply(f,input,p);return {...accepted,receipt:ok(accepted.response),input};
}
test('meal complete Undo restores a skipped dinner, original source and packs while later meal, staple and protected lunch survive',async()=>{
 const f=await fixture(),m=await mealGraph(f),lunchId=randomUUID(),ingredientId=randomUUID();
 const lunch={title:'Protected lunch',day:'2026-11-11',kind:'lunch',portions:2,protected:true,
  planning:{groups:[],ingredients:[{id:ingredientId,name:'Wraps',quantity:{amount:{numerator:2,denominator:1},unit:'count',originalLiteral:'two lunch wraps'},groupIds:[],exclusions:[]}]}};
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId:lunchId,baseMealRevision:null,meal:lunch}},2));
 const legacy=ok(await call(f.owner,f.path+'/demand')),entry=legacy.legacySources.sources.find(s=>s.source.kind==='reservation'&&s.source.originOccurrenceId===lunchId);
 assert.ok(entry);const reservation={id:entry.id,lineId:f.basket.lineId,source:entry.source,productKey:'wraps',productName:entry.productName,originalText:entry.originalText,quantity:entry.quantity,sourceExclusions:entry.sourceExclusions,exclusions:[],contains:[],removedAt:null};
 m.input.base.shopRevision=3;m.input.change.edges=[];m.input.change.contributions[0].quantity=q(4);m.input.change.contributions.push(reservation);
 ok((await apply(f,m.input,ok(await preview(f,m.input)))).response);
 const original=ok(await call(f.owner,f.path)),originalGraph=ok(await call(f.owner,f.path+'/demand'));
 const target=await mealUndoPatch(f,m.occurrenceId,null,{change:{...empty(),removeSourceIds:[m.c.id]},lines:[{...f.basket,packs:1}],quote:{...f.quote,capMinor:11000}});
 const tombstone=(await admin.query('SELECT revision,meal FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 ORDER BY revision DESC LIMIT 1',[f.h,f.shopId,m.occurrenceId])).rows[0];
 assert.equal(tombstone.meal,null);assert.equal(tombstone.revision,target.receipt.shopRevision);
 const laterId=randomUUID(),laterMeal={title:'Later soup',day:null,kind:'dinner',portions:2,protected:false};
 const staple={lineId:randomUUID(),originalItem:'Later apples',packs:1,unitPriceMinor:200,feeEligible:false};
 const apples={...source(f,q(1)),lineId:staple.lineId,productKey:'apples',productName:'Apples',originalText:'Later apples'};
 await mealUndoPatch(f,laterId,laterMeal,{change:{...empty(),lines:[{id:staple.lineId,name:staple.originalItem,unit:'count',originalOrder:9,trashedAt:null}],contributions:[apples]},lines:[{...f.basket,packs:1},staple]});
 const second=await actor(f.owner.subject);await enroll(second,f.h);f.owner=second;
 const page=ok(await call(f.owner,f.path+'/demand')),shop=ok(await call(f.owner,f.path));
 const counts={operations:await count(f,'operation'),snapshots:await count(f,'shop_snapshot'),meals:await count(f,'shared_meal_revision'),previews:await count(f,'shared_demand_preview')};
 const candidate=ok(await foodCandidate(f,target.receipt.operationId,page));assert.equal(await count(f,'shared_demand_preview'),counts.previews);
 assert.equal(candidate.mealUndo.current.meal,null);assert.equal(candidate.mealUndo.current.revision,tombstone.revision);
 assert.deepEqual(candidate.mealUndo.touchedFields,['membership']);assert.equal(candidate.action.body.mealEdit.baseMealRevision,null);
 assert.deepEqual(candidate.action.body.mealEdit.meal,m.meal);assert.equal(candidate.action.body.lines.find(l=>l.lineId===f.basket.lineId).packs,2);
 assert.deepEqual(candidate.action.body.quote,original.quote);assert.deepEqual(candidate.after.contributions.find(c=>c.id===reservation.id),reservation);
 const packs=candidate.packReviewLineIds.map(lineId=>({lineId,usablePerPack:q(6),acceptUnresolved:false}));
 ok(await foodPreview(f,candidate,packs));assert.deepEqual(ok(await call(f.owner,f.path)),shop,'Cancel writes no meal or basket');
 assert.equal(await count(f,'shared_meal_revision'),counts.meals);assert.equal(await count(f,'operation'),counts.operations);
 const p=ok(await foodPreview(f,candidate,packs));assert.deepEqual(p.mealUndo,candidate.mealUndo);
 const applied=await apply(f,{action:p.action,base:candidate.base},p),receipt=ok(applied.response);
 assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',applied.command)),receipt,'lost response retries original command once');
 const after=ok(await call(f.owner,f.path)),afterPage=ok(await call(f.owner,f.path+'/demand'));
 assert.equal(await count(f,'operation'),counts.operations+1);assert.equal(await count(f,'shop_snapshot'),counts.snapshots+1);assert.equal(await count(f,'shared_meal_revision'),counts.meals+1);
 assert.deepEqual(after.meals.find(x=>x.occurrenceId===m.occurrenceId),{occurrenceId:m.occurrenceId,revision:receipt.shopRevision,meal:m.meal});
 for(const occurrenceId of [lunchId,laterId])assert.deepEqual(after.meals.find(x=>x.occurrenceId===occurrenceId),shop.meals.find(x=>x.occurrenceId===occurrenceId));
 for(const source of [reservation,apples])assert.deepEqual(afterPage.graph.contributions.find(x=>x.id===source.id),source);
 assert.deepEqual(afterPage.graph.contributions.find(x=>x.id===m.c.id),originalGraph.graph.contributions.find(x=>x.id===m.c.id));
 assert.deepEqual(after.lines.find(x=>x.lineId===staple.lineId),staple);assert.deepEqual(after.quote,original.quote);
 assert.equal((await foodCandidate(f,target.receipt.operationId,afterPage)).data.error.code,'food_undo_already_reversed');
 assert.equal((await foodCandidate(f,receipt.operationId,afterPage)).data.error.code,'food_undo_inverse_operation_unsupported');
});
test('meal date Undo retains a later untouched title and conflicts with a later touched date',async()=>{
 const {f,m}=await mealUndoFixture();const target=await mealUndoPatch(f,m.occurrenceId,{...m.meal,day:'2026-11-10'});
 await mealUndoPatch(f,m.occurrenceId,{...m.meal,day:'2026-11-10',title:'Later title'});
 let page=ok(await call(f.owner,f.path+'/demand')),candidate=ok(await foodCandidate(f,target.receipt.operationId,page));
 assert.deepEqual(candidate.mealUndo.touchedFields,['day']);assert.equal(candidate.mealUndo.current.revision,5);
 assert.equal(candidate.action.body.mealEdit.baseMealRevision,5);assert.deepEqual(candidate.action.body.mealEdit.meal,{...m.meal,title:'Later title'});
 const p=ok(await foodPreview(f,candidate,m.input.packs));
 await mealUndoPatch(f,m.occurrenceId,{...m.meal,day:'2026-11-12',title:'Later title'});
 page=ok(await call(f.owner,f.path+'/demand'));const current=ok(await call(f.owner,f.path));
 assert.equal((await foodCandidate(f,target.receipt.operationId,page)).data.error.code,'food_undo_meal_conflict');
 assert.equal((await apply(f,{action:p.action,base:candidate.base},p)).response.status,409);assert.deepEqual(ok(await call(f.owner,f.path)),current);
});
test('meal skip Undo rejects remove-recreate-remove even when active meals and original food tombstones match',async()=>{
 const {f,m}=await mealUndoFixture();const target=await mealUndoPatch(f,m.occurrenceId,null,{change:{...empty(),removeSourceIds:[m.c.id],removeEdgeIds:[m.edge.id]}});
 await mealUndoPatch(f,m.occurrenceId,{...m.meal,planning:{groups:[],ingredients:[]}});
 await mealUndoPatch(f,m.occurrenceId,null);
 const page=ok(await call(f.owner,f.path+'/demand')),before=await count(f,'operation');
 assert.equal((await foodCandidate(f,target.receipt.operationId,page)).data.error.code,'food_undo_meal_conflict');assert.equal(await count(f,'operation'),before);
});
for(const kind of ['change','move'])test('meal Undo keeps accepted '+kind+' proposal applied without regranting or reconsuming it',async()=>{
 const {f,m}=await mealUndoFixture(),planner=await invited(f),proposalId=randomUUID(),day='2026-11-12';
 await admin.query('INSERT INTO ritc.meal_planner(household_id,shop_id,authority_epoch,revision,planner_id) VALUES($1,$2,1,1,$3)',[f.h,f.shopId,planner.id]);
 const amount={amount:{numerator:5,denominator:1},unit:'count',originalLiteral:'5 wraps'};
 const changed=kind==='move'?{...m.meal,day}:{...m.meal,title:'Planner title',planning:{...m.meal.planning,
  ingredients:m.meal.planning.ingredients.map(i=>({...i,quantity:amount})),bindings:m.meal.planning.bindings.map(b=>({...b,quantity:amount}))}};
 if(kind==='change')await admin.query('INSERT INTO ritc.shared_meal_change(household_id,shop_id,proposal_id,actor_id,authority_epoch,grant_revision,shop_revision,occurrence_id,base_meal_revision,body,original_meal,fingerprint) VALUES($1,$2,$3,$4,1,1,3,$5,2,$6,$7,$8)',[f.h,f.shopId,proposalId,planner.id,m.occurrenceId,{meal:changed},m.meal,'e'.repeat(64)]);
 else await admin.query('INSERT INTO ritc.meal_move(household_id,shop_id,proposal_id,actor_id,authority_epoch,grant_revision,shop_revision,occurrence_id,proposed_day) VALUES($1,$2,$3,$4,1,1,3,$5,$6)',[f.h,f.shopId,proposalId,planner.id,m.occurrenceId,day]);
 const target=await mealUndoPatch(f,m.occurrenceId,changed,{proposal:kind==='change'?{changeProposalId:proposalId}:{proposalId},
  change:kind==='change'?{...empty(),contributions:[{...m.c,quantity:q(5)}],edges:[{...m.edge,quantity:q(5)}]}:empty()});
 ok(await call(f.owner,f.path+'/meal-plan/planner','PUT',{authorityEpoch:1,grantRevision:1,plannerId:null}));
 const table=kind==='change'?'shared_meal_change':'meal_move',state=async()=>(await admin.query('SELECT state FROM ritc.'+table+' WHERE household_id=$1 AND shop_id=$2 AND proposal_id=$3',[f.h,f.shopId,proposalId])).rows[0].state;
 const page=ok(await call(f.owner,f.path+'/demand')),candidate=ok(await foodCandidate(f,target.receipt.operationId,page));
 assert.deepEqual(candidate.mealUndo.proposal,{kind,proposalId});assert.equal(await state(),'applied');
 assert.equal('proposalId' in candidate.action.body.mealEdit,false);assert.equal('changeProposalId' in candidate.action.body.mealEdit,false);
 const p=ok(await foodPreview(f,candidate,m.input.packs));assert.equal(await state(),'applied');
 const applied=await apply(f,{action:p.action,base:candidate.base},p);ok(applied.response);ok(await call(f.owner,f.base+'/commands','POST',applied.command));
 assert.equal(await state(),'applied');assert.deepEqual(ok(await call(f.owner,f.path)).meals.find(x=>x.occurrenceId===m.occurrenceId).meal,m.meal);
 const graph=ok(await call(f.owner,f.path+'/demand')).graph;assert.deepEqual(graph.contributions.find(x=>x.id===m.c.id),m.c);assert.deepEqual(graph.edges.find(x=>x.id===m.edge.id),m.edge);
 const grant=(await admin.query('SELECT planner_id,revision FROM ritc.meal_planner WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows[0];assert.equal(grant.planner_id,null);assert.equal(grant.revision,2);
});
test('meal Undo rejects a revoked accepted proposal author before disclosure and Apply',async()=>{
 const {f,m}=await mealUndoFixture(),planner=await invited(f),proposalId=randomUUID(),changed={...m.meal,title:'Private planner wording'};
 await admin.query('INSERT INTO ritc.meal_planner(household_id,shop_id,authority_epoch,revision,planner_id) VALUES($1,$2,1,1,$3)',[f.h,f.shopId,planner.id]);
 await admin.query('INSERT INTO ritc.shared_meal_change(household_id,shop_id,proposal_id,actor_id,authority_epoch,grant_revision,shop_revision,occurrence_id,base_meal_revision,body,original_meal,fingerprint) VALUES($1,$2,$3,$4,1,1,3,$5,2,$6,$7,$8)',[f.h,f.shopId,proposalId,planner.id,m.occurrenceId,{meal:changed},m.meal,'e'.repeat(64)]);
 const target=await mealUndoPatch(f,m.occurrenceId,changed,{proposal:{changeProposalId:proposalId}});
 const page=ok(await call(f.owner,f.path+'/demand')),candidate=ok(await foodCandidate(f,target.receipt.operationId,page)),p=ok(await foodPreview(f,candidate,m.input.packs)),before=await count(f,'operation');
 await admin.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2",[f.h,planner.id]);
 const rejected=await foodCandidate(f,target.receipt.operationId,page);assert.equal(rejected.data.error.code,'food_undo_meal_history_unavailable');
 assert.equal(JSON.stringify(rejected.data).includes('Private planner wording'),false);
 assert.equal((await apply(f,{action:p.action,base:candidate.base},p)).response.status,409);assert.equal(await count(f,'operation'),before);
});
test('meal Undo rejects protected portion reduction without issuing a partial candidate',async()=>{
 const f=await fixture(),occurrenceId=randomUUID(),meal={title:'Protected lunch',day:null,kind:'lunch',portions:2,protected:true};
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},1));
 const input=draft(f);input.base.shopRevision=2;ok((await apply(f,input,ok(await preview(f,input)))).response);
 const target=await mealUndoPatch(f,occurrenceId,{...meal,portions:3}),page=ok(await call(f.owner,f.path+'/demand')),before=await count(f,'operation');
 assert.equal((await foodCandidate(f,target.receipt.operationId,page)).data.error.code,'food_undo_meal_protected');assert.equal(await count(f,'operation'),before);
 assert.equal((await foodHistory(f)).items.find(x=>x.operationId===target.receipt.operationId).eligibility.reason,'food_undo_meal_protected');
});
test('meal Undo preview rejects wrong device, expiry, changed action and current authority loss',async()=>{
 const {f,m}=await mealUndoFixture(),target=await mealUndoPatch(f,m.occurrenceId,{...m.meal,day:'2026-11-10'});
 const page=ok(await call(f.owner,f.path+'/demand')),candidate=ok(await foodCandidate(f,target.receipt.operationId,page)),p=ok(await foodPreview(f,candidate,m.input.packs));
 const before=await count(f,'operation'),other=await actor(f.owner.subject);await enroll(other,f.h);
 assert.equal((await apply(f,{action:p.action,base:candidate.base},p,other)).response.status,409);
 const changed=structuredClone(p.action);changed.body.mealEdit.meal.title='Not reviewed';assert.equal((await apply(f,{action:changed,base:candidate.base},p)).response.status,409);
 await admin.query("UPDATE ritc.shared_demand_preview SET created_at=created_at-interval '11 minutes',expires_at=expires_at-interval '11 minutes' WHERE household_id=$1 AND preview_id=$2",[f.h,p.previewId]);
 assert.equal((await apply(f,{action:p.action,base:candidate.base},p)).response.status,409);assert.equal(await count(f,'operation'),before);
 const fresh=ok(await foodPreview(f,candidate,m.input.packs)),shopper=await invited(f);ok(await send(f,'shop.transferAuthority',{newShopperId:shopper.id},page.shopRevision));
 assert.equal((await apply(f,{action:fresh.action,base:candidate.base},fresh)).response.status,404);
});
test('meal Undo cannot return private history or exact replay after accepted meal author erasure',async()=>{
 const {f,m}=await mealUndoFixture(),author=f.owner,target=await mealUndoPatch(f,m.occurrenceId,{...m.meal,title:'Private meal title'}),shopper=await invited(f);
 ok(await send(f,'shop.transferAuthority',{newShopperId:shopper.id},target.receipt.shopRevision));f.owner=shopper;
 const page=ok(await call(f.owner,f.path+'/demand')),candidate=ok(await foodCandidate(f,target.receipt.operationId,page)),p=ok(await foodPreview(f,candidate,m.input.packs));
 const accepted=await apply(f,{action:p.action,base:candidate.base},p);ok(accepted.response);ok(await call(f.owner,f.base+'/commands','POST',accepted.command));
 ok(await call(author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'transfer',organizerMemberId:shopper.id,shops:[],eraseChildProfiles:[]}]}),202);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal((await call(f.owner,f.base+'/commands','POST',accepted.command)).status,409);
 const history=await foodHistory(f);assert.ok(history.items.every(x=>x.eligibility.status==='unavailable'));assert.equal(JSON.stringify(history).includes('Private meal title'),false);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3',[f.h,f.shopId,m.occurrenceId])).rows[0].n,0);
 assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.shared_food_meal_effect WHERE household_id=$1 AND operation_id=$2',[f.h,target.receipt.operationId])).rows[0].n,1,'content-free lineage cannot resurrect erased meal facts');
});
