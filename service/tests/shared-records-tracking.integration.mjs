/** Real HTTP/PG Records-v2 controls. Run only in the established disposable
 * restricted-role PostgreSQL + owned privacy-journal harness. No mocks replace
 * authorization, tracking transitions, export projection, or privacy erasure. */
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import {admin,runtime,maintenance,actor,call,ok,enroll,fixture,send,source,draft,empty,q,head,invited,acceptRequest} from './request-acceptance-undo-fixture.mjs';
import {digest} from '../dist/shared-demand-tracking.js';

const routes=['/records/snapshot','/records/snapshot/v2'];
const page=async f=>ok(await call(f.owner,f.path+'/demand/tracking'));
const base=p=>({shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,graphRevision:(p.state??p.projection.state).graph.revision,stateDigest:p.basisDigest});
async function commit(f,intent){
 const c=ok(await call(f.owner,f.path+'/demand/tracking/candidates','POST',intent));
 const p=ok(await call(f.owner,f.path+'/demand/tracking/previews','POST',{candidateId:c.candidateId,candidateDigest:c.candidateDigest,acknowledgedDisclosure:c.disclosure,acceptOverage:false,acceptUnknown:true}));
 const command={v:1,replayWindow:f.owner.window,clientKey:randomUUID(),shopId:f.shopId,kind:p.action.kind,base:{shopRevision:intent.base.shopRevision,authorityEpoch:intent.base.authorityEpoch},body:{...p.action.body,demandReview:{previewId:p.previewId,previewDigest:p.previewDigest,trackingVersion:2}}};
 return{c,p,command,receipt:ok(await call(f.owner,f.base+'/commands','POST',command))};
}
async function transfer(f,to,organizer=f.owner){
 const s=await head(f),receipt=ok(await send(f,'shop.transferAuthority',{newShopperId:to.id},s.shopRevision,s.authorityEpoch,organizer));
 assert.equal(receipt.authorityEpoch,s.authorityEpoch+1);assert.equal(receipt.shopRevision,s.shopRevision);
 f.owner=to;assert.equal((await head(f)).authorityEpoch,receipt.authorityEpoch);return receipt;
}
async function partial({mealContributor=false,withRequest=true}={}){
 const f=await fixture(),shopper=f.owner;f.author=await invited(f);
 if(mealContributor)await transfer(f,f.author);
 f.occurrenceId=randomUUID();f.ingredientId=randomUUID();f.restriction='Keep the family wording exactly';
 f.meal={title:'Protected lunch original',day:null,kind:'lunch',portions:2,protected:true,planning:{groups:[],ingredients:[{id:f.ingredientId,name:'Lunch wraps',quantity:null,groupIds:[],exclusions:[f.restriction]}]}};
 let s=await head(f);ok(await send(f,'shop.patch',{quote:s.quote,lines:s.lines,mealEdit:{occurrenceId:f.occurrenceId,baseMealRevision:null,meal:f.meal}},s.shopRevision,s.authorityEpoch));
 if(mealContributor)await transfer(f,shopper,shopper);
 if(withRequest){
  s=await head(f);f.wording='Records private request '+randomUUID();f.literal='one original large packet if available';
  const request=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:f.wording,ownQuantity:f.literal,authoredAt:new Date().toISOString()},s.shopRevision,s.authorityEpoch,f.author)).request;
  f.requestId=request.requestId;f.requestAcceptance=await acceptRequest(f,request,'link');
 }
 const before=await page(f),input={...draft(f),base:base(before)};
 input.action.body.lines=[{...f.basket,packs:3}];
 input.change.contributions.push(...before.state.catalog.map(fact=>({id:fact.id,lineId:fact.requiredLineId??f.basket.lineId,source:fact.source,productKey:'wraps',productName:fact.originalText,originalText:fact.originalText,quantity:fact.quantity,sourceExclusions:fact.sourceExclusions,exclusions:[],contains:[],removedAt:null})));
 input.packs=[{lineId:f.basket.lineId,usablePerPack:q(12),acceptUnresolved:true}];
 f.adoption=await commit(f,input);f.adopted=await page(f);
 await commit(f,{mode:'firstAdoptionUndo',base:base(f.adopted),targetOperationId:f.adoption.receipt.operationId,packs:[]});
 const p=await page(f);s=await head(f);
 f.staple={lineId:randomUUID(),originalItem:'Independent later apples',packs:1,unitPriceMinor:null,feeEligible:true};
 f.stapleSource={...source({...f,basket:f.staple},q(1)),productKey:'apples',productName:f.staple.originalItem,originalText:'One independent apple'};
 const order=Math.max(-1,...p.state.graph.lines.map(l=>l.originalOrder))+1;
 await commit(f,{mode:'change',base:base(p),change:{...empty(),lines:[{id:f.staple.lineId,name:f.staple.originalItem,unit:'count',originalOrder:order,trashedAt:null}],contributions:[f.stapleSource]},unboundFactIds:p.state.unbound.map(u=>u.factId),action:{kind:'shop.patch',body:{quote:s.quote,lines:[...s.lines,f.staple]}},packs:[...p.state.packReviews,{lineId:f.staple.lineId,usablePerPack:q(1),acceptUnresolved:false}]});
 return f;
}
const tables=['shop','operation','basket_line','shop_snapshot','shared_meal_revision','request','request_link','shared_demand_revision','shared_demand_preview','shared_tracking_revision','shared_tracking_preview','shared_tracking_adoption'];
async function domainRows(f){
 const result={};for(const table of tables)result[table]=(await admin.query(`SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb) AS rows FROM ritc.${table} t WHERE household_id=$1`,[f.h])).rows[0].rows;
 return result;
}
function noSecrets(result,f){
 assert.deepEqual(Object.keys(result).sort(),['schemaVersion','asOf','recordDigest','record'].sort());
 assert.deepEqual(Object.keys(result.record).sort(),['schemaVersion','projection','origin','shopRevision','privacyRevision','phase','storeBasisRevision','storeReviewRequired','quote','mealOccurrences','food'].sort());
 assert.deepEqual(Object.keys(result.record.food).sort(),['status','graph','basket','catalog','bindings','unbound','legacyLineIds','packReview','coverage'].sort());
 const forbidden=new Set(['authorityEpoch','authority_epoch','basisDigest','quoteDigest','freezeReview','previewId','previewDigest','candidateId','candidateDigest','operationId','clientKey','replayWindow','actorId','actor_id','deviceId','device_id','token','guardianConsentId','guardian_consent_id','invalidatedStateDigest']);
 const visit=value=>{if(value&&typeof value==='object')for(const [key,child] of Object.entries(value)){assert.ok(!forbidden.has(key),key);visit(child);}};visit(result);
 const text=JSON.stringify(result);for(const secret of [f.owner.token,f.owner.device,f.owner.window,f.author?.token,f.author?.device,f.author?.window,f.adoption?.command.clientKey,f.adoption?.p.previewId,f.adoption?.receipt.operationId].filter(Boolean))assert.ok(!text.includes(secret),'authorization/replay value leaked');
 assert.equal(result.recordDigest,digest(result.record));assert.ok(Number.isFinite(Date.parse(result.asOf)));
}
async function readPair(f){const a=ok(await call(f.owner,f.path+routes[0])),b=ok(await call(f.owner,f.path+routes[1]));assert.deepEqual(a.record,b.record);assert.equal(a.recordDigest,b.recordDigest);noSecrets(a,f);noSecrets(b,f);return a;}
// Observe actual runtime SELECTs while denied reads run, rather than mocking the
// reader. Hook is installed before the imported fixture opens runtime connections.
let watching=false,contentReads=0;
runtime.on('connect',client=>{const query=client.query.bind(client);client.query=(...args)=>{const sql=typeof args[0]==='string'?args[0]:args[0]?.text??'';if(watching&&/\britc\.(?:basket_line|request_link|shared_meal_revision|shared_demand_revision|shared_tracking_revision|shop_snapshot)\b/.test(sql))contentReads++;return query(...args);};});
async function denied(f,a,status=404){
 const before=await domainRows(f);
 for(const route of routes){contentReads=0;watching=true;let response;try{response=await call(a,f.path+route);}finally{watching=false;}
  assert.equal(response.status,status,JSON.stringify(response.data));assert.equal(contentReads,0,'deny before loading record content');
  const body=JSON.stringify(response.data);for(const value of [f.wording,f.literal,'recordDigest','packReview','Protected lunch original','Independent later apples'].filter(Boolean))assert.ok(!body.includes(value));
 }
 assert.deepEqual(await domainRows(f),before);
}

test('Records v2 HTTP partial export preserves exact protected unknown transfers, request wording, basket money and immutable PostgreSQL head',async()=>{
 const f=await partial(),p=await page(f),s=await head(f),before=await domainRows(f),r=await readPair(f);
 assert.equal(r.schemaVersion,2);assert.equal(r.record.projection,'assigned-shopper-independent-record-v2');assert.equal(r.record.food.status,'enabled');
 for(const key of ['graph','basket','catalog','bindings','unbound','legacyLineIds'])assert.deepEqual(r.record.food[key],p.state[key]);
 assert.deepEqual(r.record.food.packReview,{state:'recorded',values:p.state.packReviews});assert.deepEqual(r.record.food.coverage,p.coverage);assert.equal(p.coverage.completeFoodCoverage,false);
 assert.deepEqual(r.record.quote,s.quote);assert.deepEqual(r.record.mealOccurrences,s.meals);
 const protectedFact=r.record.food.catalog.find(x=>x.source.kind==='reservation'),transfer=r.record.food.unbound.find(x=>x.factId===protectedFact.id);
 assert.equal(protectedFact.quantity,null);assert.equal(transfer.transferred.quantity,null);assert.deepEqual(transfer.transferred,f.adopted.state.graph.contributions.find(x=>x.id===transfer.transferred.id));assert.ok(protectedFact.sourceExclusions.some(x=>x.label===f.restriction));
 const requestFact=r.record.food.catalog.find(x=>x.source.kind==='request');assert.equal(requestFact.originalText,f.wording);assert.equal(requestFact.originalQuantityText,f.literal);assert.equal(requestFact.quantity,null);
 assert.equal(r.record.food.basket.find(x=>x.id===f.staple.lineId).priceMinor,null);assert.equal(r.record.food.basket.find(x=>x.id===f.basket.lineId).packs,2);
 const persisted=(await admin.query('SELECT graph FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 AND revision=$3',[f.h,f.shopId,p.state.graph.revision])).rows[0];assert.deepEqual(r.record.food.graph,persisted.graph);
 assert.deepEqual(await domainRows(f),before);assert.equal((await call(f.owner,f.path+'/records/snapshot/v1')).status,409);
});

test('Records v2 HTTP repeat reads neither mint previews nor mutate current or historical domain rows',async()=>{
 const f=await partial(),before=await domainRows(f),a=await readPair(f),b=await readPair(f);assert.deepEqual(a.record,b.record);assert.equal(a.recordDigest,b.recordDigest);assert.ok(Date.parse(b.asOf)>=Date.parse(a.asOf));assert.deepEqual(await domainRows(f),before);
});

test('Records v2 HTTP denies contributor, explicitly granted planner and foreign adult before content reads',async()=>{
 const f=await partial();await denied(f,f.author);
 const s=await head(f);ok(await call(f.owner,f.path+'/meal-plan/planner','PUT',{plannerId:f.author.id,grantRevision:0,authorityEpoch:s.authorityEpoch}));
 assert.equal((await admin.query('SELECT planner_id FROM ritc.meal_planner WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows[0].planner_id,f.author.id);
 await denied(f,f.author);const foreign=await fixture();await denied(f,foreign.owner);
});

test('Records v2 HTTP denies a redeemed limited-view helper before content reads',async()=>{
 const f=await partial(),grant=ok(await call(f.owner,f.base+'/views','POST',{shopId:f.shopId,mode:'read',shopLabel:'Only the shared helper list',language:'en',items:[]})),helper=await actor();
 helper.id=ok(await call(helper,'/v1/invites/redeem','POST',{token:grant.token,intent:'join',adultAttestation:true,alias:'Limited helper'})).memberId;await enroll(helper,f.h);
 const member=(await admin.query('SELECT can_contribute,organizer FROM ritc.member WHERE household_id=$1 AND member_id=$2',[f.h,helper.id])).rows[0];assert.equal(member.can_contribute,false);assert.equal(member.organizer,false);await denied(f,helper);
});

for(const origin of ['request','meal'])test('Records v2 HTTP refuses revoked '+origin+' provenance for the still assigned shopper without changing retained facts',async()=>{
 const f=await partial({mealContributor:origin==='meal',withRequest:origin==='request'});await readPair(f);
 ok(await call(f.owner,f.base+'/revocations','POST',{kind:'member',targetId:f.author.id}));const before=await domainRows(f);
 for(const route of routes){const r=await call(f.owner,f.path+route);assert.equal(r.status,409);assert.equal(r.data.error.code,'tracking_source_unavailable');const text=JSON.stringify(r.data);for(const value of [f.wording,f.literal,'Protected lunch original','recordDigest'].filter(Boolean))assert.ok(!text.includes(value));}
 assert.deepEqual(await domainRows(f),before);
});

test('Records v2 HTTP authorized erasure exports only surviving partial facts and never recreates pack acknowledgments or private request copies',async()=>{
 const f=await partial(),before=await readPair(f),protectedBefore=before.record.food.unbound.find(x=>x.transferred?.source.kind==='reservation');assert.ok(JSON.stringify(before).includes(f.wording));
 ok(await call(f.author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);
 assert.equal((await maintenance.run({batchSize:1})).completed,1);
 const p=await page(f),persisted=await domainRows(f),r=await readPair(f);assert.equal(r.record.food.status,'reviewRequired');assert.equal(r.record.food.coverage,null);assert.deepEqual(r.record.food.packReview,{state:'erased',values:null});assert.ok(r.record.privacyRevision>before.record.privacyRevision);
 for(const key of ['graph','basket','catalog','bindings','unbound','legacyLineIds'])assert.deepEqual(r.record.food[key],p.projection.state[key]);
 assert.deepEqual(r.record.food.unbound.find(x=>x.factId===protectedBefore.factId),protectedBefore);assert.deepEqual(r.record.mealOccurrences,before.record.mealOccurrences);assert.deepEqual(r.record.quote,before.record.quote);
 assert.deepEqual(r.record.food.graph.contributions.find(x=>x.id===f.stapleSource.id),f.stapleSource);assert.deepEqual(r.record.food.basket.find(x=>x.id===f.staple.lineId),before.record.food.basket.find(x=>x.id===f.staple.lineId));
 const text=JSON.stringify(r);assert.ok(!text.includes(f.wording));assert.ok(!text.includes(f.literal));assert.ok(!text.includes(p.projection.invalidatedStateDigest));assert.ok(!r.record.food.catalog.some(x=>x.source.kind==='request'));assert.deepEqual(await domainRows(f),persisted);
 const removed=await call(f.author,f.path+routes[1]);assert.equal(removed.status,401);assert.equal(removed.data.error.code,'session_needed');
});


test('Records v2 HTTP follows current shopper assignment and denies the previous organizer shopper without leaking replay authority',async()=>{
 const f=await partial(),original=f.owner,before=await readPair(f);await transfer(f,f.author);
 const stable=await domainRows(f),current=await readPair(f);assert.deepEqual(current.record.food,before.record.food);assert.deepEqual(current.record.mealOccurrences,before.record.mealOccurrences);assert.deepEqual(current.record.quote,before.record.quote);assert.equal(current.record.shopRevision,before.record.shopRevision);assert.equal(current.recordDigest,before.recordDigest);assert.deepEqual(await domainRows(f),stable);
 await denied(f,original);
});
