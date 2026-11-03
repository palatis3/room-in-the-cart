import {test} from 'node:test';
import assert from 'node:assert/strict';
import {compareStoreQuotes} from '../dist/shared-store-quotes.js';
const a={itemsMinor:3600,checkoutMinor:3800,allChargesIncluded:true,tripMinor:0,extraMinutes:0,available:true,quantitiesMatched:true,singleStore:true,eligibilityConfirmed:true,capMinor:3800,capScope:'wholeCheckout'};
const b={...a,itemsMinor:3200,checkoutMinor:3500,tripMinor:400,extraMinutes:18};
const compare=(first,second)=>compareStoreQuotes({first,second});
test('separates item, checkout, incremental trip and elapsed time',()=>{
 const out=compare(a,b);assert.equal(out.itemDelta,-400);assert.equal(out.checkoutDelta,-300);assert.equal(out.cashDelta,100);
 assert.equal(out.minutesDelta,18);assert.equal(out.preferred,'first');assert.equal(out.firstTrip,3800);assert.equal(out.secondTrip,3900);
});
test('unknown travel keeps the winner open and yields a conditional break-even',()=>{
 const out=compare(a,{...b,tripMinor:null});assert.equal(out.preferred,null);assert.equal(out.cashDelta,null);assert.equal(out.secondBreakEven,300);
});
test('unreviewed charges leave checkout and winner unknown',()=>{
 const out=compare(a,{...b,allChargesIncluded:false});assert.equal(out.secondCheckout,null);assert.equal(out.preferred,null);
});
test('unavailable or unknown availability gives no winner',()=>{
 for(const available of [null,false])assert.equal(compare(a,{...b,available}).preferred,null);
});
test('unmatched quantities and multistore packages are incomparable',()=>{
 for(const patch of [{quantitiesMatched:false},{singleStore:false}]){
  const out=compare(a,{...b,...patch});assert.equal(out.comparable,false);assert.equal(out.itemDelta,null);assert.equal(out.preferred,null);
 }
});
test('ties and missing minutes remain explicit',()=>{
 const out=compare(a,{...b,tripMinor:300,extraMinutes:null});assert.equal(out.cashDelta,0);assert.equal(out.preferred,null);assert.equal(out.minutesDelta,null);
});
test('each cap uses its own scope and excludes incremental travel',()=>{
 const out=compare(a,{...b,capMinor:3300,capScope:'itemsOnly'});
 assert.deepEqual(out.firstCap,{amountMinor:3800,scope:'wholeCheckout',status:'withinCap',overMinor:0,headroomMinor:0});
 assert.deepEqual(out.secondCap,{amountMinor:3300,scope:'itemsOnly',status:'withinCap',overMinor:0,headroomMinor:100});
 const cashCap=compare(a,{...b,capMinor:3400,capScope:'wholeCheckout'}).secondCap;
 assert.equal(cashCap.status,'overCap');assert.equal(cashCap.overMinor,100);assert.equal(cashCap.headroomMinor,-100);
});
test('missing fee does not resolve a whole-checkout cap while a known item scope stays explicit',()=>{
 const unknown=compare(a,{...b,allChargesIncluded:false}).secondCap;assert.equal(unknown.status,'unresolved');assert.equal(unknown.overMinor,null);
 const itemCap=compare(a,{...b,allChargesIncluded:false,capScope:'itemsOnly'}).secondCap;assert.equal(itemCap.status,'withinCap');assert.equal(itemCap.scope,'itemsOnly');
});
test('unknown eligibility preserves conditional deltas but withholds winner and break-even',()=>{
 const out=compare(a,{...b,eligibilityConfirmed:false,tripMinor:null});assert.equal(out.checkoutDelta,-300);assert.equal(out.preferred,null);assert.equal(out.secondBreakEven,null);
});
test('either option can have extra travel and cents stay exact at the accepted bound',()=>{
 const out=compare({...a,checkoutMinor:1_000_000_000,tripMinor:1_000_000_000},{...b,checkoutMinor:999_999_999,tripMinor:1_000_000_000});
 assert.equal(out.firstTrip,2_000_000_000);assert.equal(out.cashDelta,-1);assert.equal(out.preferred,'second');
});
