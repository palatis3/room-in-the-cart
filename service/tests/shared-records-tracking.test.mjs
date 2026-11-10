import test from 'node:test';
import assert from 'node:assert/strict';
import {projectTrackingRecord,readTrackingRecordSnapshot} from '../dist/shared-records-tracking.js';
import {digest,coverage} from '../dist/shared-demand-tracking.js';
import {fixture,erasedFixture,at,id} from './shared-records-tracking-fixture.mjs';
const run=f=>projectTrackingRecord(f,new Date(at));
test('partial record preserves catalog, detached protected unknown, exact wording and pack/money separation',()=>{
 const f=fixture(),before=structuredClone(f),r=run(f);assert.deepEqual(f,before);
 const food=r.record.food;for(const key of ['graph','catalog','bindings','unbound','legacyLineIds','basket'])assert.deepEqual(food[key],f.page.state[key]);
 assert.deepEqual(food.packReview.values,f.page.state.packReviews);assert.equal(food.coverage.status,'partial');assert.equal(food.coverage.completeFoodCoverage,false);
 assert.deepEqual(food.coverage.allocatableUnboundFactIds,[]);assert.deepEqual(food.coverage.protectedUnboundFactIds,[id(21)]);
 assert.equal(food.unbound[0].transferred.quantity,null);assert.equal(food.catalog[0].quantity,null);assert.equal(food.basket[1].packs,2);assert.equal(food.basket[1].priceMinor,null);assert.equal(r.record.quote.fee.amountMinor,null);
});
test('digest is stable across observations and independent of live authorization/review tokens',()=>{
 const f=fixture(),a=run(f);f.page.freezeReview={previewId:id(99),previewDigest:'e'.repeat(64),trackingVersion:2};
 assert.equal(a.recordDigest,run(f).recordDigest);assert.equal(a.recordDigest,digest(a.record));
 const later=projectTrackingRecord(f,new Date('2026-11-10T14:00:00Z'));assert.equal(a.recordDigest,later.recordDigest);assert.notEqual(a.asOf,later.asOf);
 const text=JSON.stringify(a);for(const name of ['authorityEpoch','basisDigest','quoteDigest','freezeReview','previewId','previewDigest','invalidatedStateDigest','replayWindow','operationId','token','shopper_id'])assert.ok(!text.includes(name),name);
});
test('erased reviews stay absent, surviving partition is exact and old digest is omitted',()=>{
 const f=erasedFixture(),r=run(f);assert.deepEqual(r.record.food.packReview,{state:'erased',values:null});assert.equal(r.record.food.coverage,null);
 assert.deepEqual(r.record.food.unbound,f.page.projection.state.unbound);assert.equal(r.record.privacyRevision,3);assert.ok(!JSON.stringify(r).includes('a'.repeat(64)));
});
test('erased projection checks CURRENT source catalog',()=>{const f=erasedFixture();f.currentCatalog=[];assert.throws(()=>run(f),/source_revision_or_privacy/);});
test('corrupt basis, stale scope or privacy rejects without fallback',()=>{
 for(const edit of [f=>f.page.basisDigest='0'.repeat(64),f=>f.page.shopRevision++,f=>f.page.authorityEpoch++,f=>f.shop.household_id=id(999),f=>f.shop.demand_revision++]){const f=fixture();edit(f);assert.throws(()=>run(f));}
 const f=erasedFixture();f.page.projection.previousPrivacyRevision=3;f.page.basisDigest=digest(f.page.projection);assert.throws(()=>run(f));
});
test('partition omissions, invented totals, unknown fields and missing source meals reject',()=>{
 for(const edit of [f=>f.page.state.unbound=[],f=>f.page.coverage.completeFoodCoverage=true,f=>f.page.state.catalog[0].actorId=id(90),f=>f.meals=[],f=>f.shop.quote.accessToken='secret']){const f=fixture();edit(f);f.page.basisDigest=digest(f.page.state);assert.throws(()=>run(f));}
});
test('returned record is detached from mutable in-memory facts',()=>{const f=fixture(),r=run(f);r.record.food.catalog[0].originalText='changed';assert.notEqual(r.record.food.catalog[0].originalText,f.page.state.catalog[0].originalText);});
test('legacy unbound catalog stays explicit without invented pack reviews',()=>{
 const f=fixture(),s=f.page.state;s.graph={...s.graph,revision:0,lines:[],contributions:[],edges:[],usedIds:[]};s.unbound=s.unbound.map(u=>({...u,transferred:null}));s.legacyLineIds=s.basket.map(l=>l.id);s.packReviews=[];
 f.shop.demand_revision=null;f.page.status='legacy';f.page.basisDigest=digest(s);f.page.coverage=coverage(s,s.catalog);
 const r=run(f);assert.equal(r.record.food.status,'legacy');assert.deepEqual(r.record.food.packReview,{state:'notRecorded',values:[]});assert.equal(r.record.food.coverage.status,'partial');
});
test('nonshopper denies BEFORE any contents read',async()=>{let reads=0;const repo={requireShopper(){throw new Error('denied');},options:{trackingV2:true},meals(){reads++;}};await assert.rejects(readTrackingRecordSnapshot(repo,{db:{query(){reads++;}}},fixture().shop),/denied/);assert.equal(reads,0);});
test('feature-off v2 read fails closed without legacy fallback',async()=>{let reads=0;const repo={requireShopper(){},options:{trackingV2:false},meals(){reads++;}};await assert.rejects(readTrackingRecordSnapshot(repo,{db:{query(){reads++;}}},fixture().shop),e=>e.code==='not_available');assert.equal(reads,0);});
test('bound reader uses current household-scoped SELECTs and returns legacy untracked basket without writes',async()=>{
 const f=fixture();f.shop.demand_revision=null;let queries=0;
 const lines=f.page.state.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible}));
 const repo={options:{trackingV2:true},requireShopper(){},meals:async()=>[],lines:async()=>lines};
 const ctx={householdId:f.shop.household_id,now:new Date(at),db:{async query(sql,args){queries++;assert.match(sql.trim(),/^SELECT/);assert.equal(args[0],f.shop.household_id);return {rows:sql.includes('SELECT tracking_privacy_revision')?[{tracking_privacy_revision:0}]:[]};}}};
 const result=await readTrackingRecordSnapshot(repo,ctx,f.shop);assert.equal(result.record.food.status,'legacy');assert.deepEqual(result.record.food.legacyLineIds,lines.map(l=>l.lineId));assert.ok(queries>0);
});
test('withdrawn request source cannot be exported even by assigned shopper',async()=>{
 const f=fixture();f.shop.demand_revision=null;const repo={options:{trackingV2:true},requireShopper(){},meals:async()=>[],lines:async()=>[]};
 const ctx={householdId:f.shop.household_id,now:new Date(at),db:{async query(sql){
  if(sql.includes('FROM ritc.request_link'))return {rows:[{request_id:id(40),line_id:id(11),reviewed_revision:2,original_item:'Erased child source',own_quantity:null,author_id:id(90)}]};
  if(sql.includes('FROM ritc.member'))return {rows:[{member_id:id(90),state:'removed'}]};return {rows:[]};}}};
 await assert.rejects(readTrackingRecordSnapshot(repo,ctx,f.shop),e=>e.code==='tracking_source_unavailable');
});
