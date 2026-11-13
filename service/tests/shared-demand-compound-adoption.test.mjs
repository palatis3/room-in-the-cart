import test from 'node:test';
import assert from 'node:assert/strict';
import {fixture,id,at} from './shared-demand-compound-fixture.mjs';
import {recordCompoundAdoption,inverseCompoundAdoptionPartition} from '../dist/shared-demand-compound-adoption.js';
import {digest as storedDigest} from '../dist/database.js';
import {digest,admitV1} from '../dist/shared-demand-tracking.js';
const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,
 observedAt:'2026-11-09T12:00:00.000Z',expiresAt:'2026-11-11T16:00:00.000Z'};
function setup(){
 const f=structuredClone(fixture({unknown:true})),beforeQuote=structuredClone(quote),afterQuote={...quote,capMinor:15000};
 f.current=structuredClone(f.current); // break fixture sharing: later edits must not mutate accepted after-state
 f.before.quoteDigest=storedDigest(beforeQuote);f.after.quoteDigest=storedDigest(afterQuote);f.current.quoteDigest=storedDigest(afterQuote);
 f.current.basket[0].priceMinor=125;
 const record=recordCompoundAdoption(id(3),f.before,f.after,beforeQuote,afterQuote,{kind:'none'});
 const context={operationId:id(4),targetOperationId:id(3),evidenceDigest:record.evidenceDigest,householdId:id(1),shopId:id(2),baseRevision:f.current.graph.revision,authorityEpoch:3,privacyRevision:5,at};
 return{...f,...record,beforeQuote,afterQuote,context,run(){return inverseCompoundAdoptionPartition(this.evidence,this.current,this.context,this.afterQuote,this.before.catalog,new Date(at));}};
}
test('complete first adoption plus budget edit restores all initial assertions and keeps later staple/price/unknown protection',()=>{
 const f=setup(),before=digest(f.current),r=f.run();
 assert.equal(digest(f.current),before);assert.equal(r.quote.capMinor,10000);
 assert.equal(r.state.basket[0].priceMinor,125);assert.equal(r.state.basket[0].packs,2);
 assert.equal(r.state.basket.at(-1).name,'Rice');assert.deepEqual(r.state.graph.usedIds,f.current.graph.usedIds);
 assert.deepEqual(r.disclosure.reversedAssertions.contributions,f.after.graph.contributions);
 assert.deepEqual(r.disclosure.reversedAssertions.edges,f.after.graph.edges);assert.deepEqual(r.disclosure.reversedAssertions.packReviews,f.after.packReviews);
 assert.equal(r.state.unbound.find(x=>x.factId===id(22)).transferred.quantity,null);
 assert.deepEqual(r.disclosure.afterCoverage.protectedUnboundFactIds,[id(22)]);assert.deepEqual(r.disclosure.afterCoverage.allocatableUnboundFactIds,[]);
 assert.equal(r.disclosure.afterCoverage.status,'partial');assert.throws(()=>admitV1(r.state,r.state.catalog));
 assert.equal(r.receipt.resultRevision,r.state.graph.revision);
});
test('version2 evidence is immutable and its complete quote/partition digest is checked',()=>{
 const f=setup();assert.throws(()=>{f.evidence.beforeQuote.capMinor=5;},TypeError);
 const changed=structuredClone(f.evidence);changed.beforeQuote.capMinor=9000;changed.before.quoteDigest=storedDigest(changed.beforeQuote);
 assert.throws(()=>inverseCompoundAdoptionPartition(changed,f.current,f.context,f.afterQuote,f.before.catalog,new Date(at)),e=>e.code==='history_unavailable');
});
for(const [name,change] of [
 ['later touched packs',f=>f.current.basket[0].packs=4],
 ['later touched manual amount',f=>f.current.graph.contributions[0].quantity.amount.numerator='13'],
 ['privacy changed',f=>f.context.privacyRevision++],
 ['authority changed',f=>f.context.authorityEpoch++],
 ['current quote changed',f=>{f.afterQuote={...f.afterQuote,capMinor:16000};f.current.quoteDigest=storedDigest(f.afterQuote);}],
 ['missing protected source',f=>f.before.catalog.splice(1,1)],
 ['invented restored source',f=>f.before.catalog.push({...structuredClone(f.before.catalog[0]),id:id(999)})]
])test(name+' rejects whole first-adoption compensation',()=>{const f=setup();change(f);assert.throws(()=>f.run());});
test('expired historical quote cannot be borrowed for full compensation',()=>{
 const f=setup();assert.throws(()=>inverseCompoundAdoptionPartition(f.evidence,f.current,f.context,f.afterQuote,f.before.catalog,new Date('2026-11-12T12:00:00Z')),e=>e.code==='food_undo_expired_quote');
});
test('recording source-changing forward history does not grant protected reverse authority',()=>{
 const f=setup(),before=structuredClone(f.before),after=structuredClone(f.after);
 before.catalog=before.catalog.filter(x=>x.id!==id(22));before.unbound=before.unbound.filter(x=>x.factId!==id(22));
 // The separately authenticated meal component creates the protected commitment.
 const r=recordCompoundAdoption(id(3),before,after,f.beforeQuote,f.afterQuote,{kind:'meal',occurrenceId:id(40),componentDigest:'f'.repeat(64)});
 assert.throws(()=>inverseCompoundAdoptionPartition(r.evidence,f.current,{...f.context,evidenceDigest:r.evidenceDigest},f.afterQuote,before.catalog,new Date(at)),e=>e.code==='protected_source_effect');
});
