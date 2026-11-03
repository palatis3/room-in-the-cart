import test from 'node:test';
import assert from 'node:assert/strict';
import {decisionSchema} from '../dist/contracts.js';
const quantity=(numerator,unit='count')=>({numerator:String(numerator),denominator:'1',unit,originalLiteral:String(numerator)});
const line={lineId:'77777777-7777-4777-8777-777777777777',originalItem:'Reviewed wraps',packs:2,unitPriceMinor:300,feeEligible:true};
const evidence=()=>({version:1,offerId:'shelf-A',label:line.originalItem,needed:quantity(8),usablePerPack:quantity(4),packs:2,unitPriceMinor:300,productMatchConfirmed:true,availabilityConfirmed:true,availablePackLimit:2,quoteSource:'Shelf label at reviewed branch',quoteObservedAt:'2026-11-03T00:00:00Z',reviewedAt:'2026-11-03T00:01:00Z'});
test('optional reviewed evidence retains exact selected source and quantities; legacy manual omits it',()=>{
 const plain=decisionSchema.parse({choice:'add',line,promote:false});assert.equal('reviewedPackEvidence'in plain,false);
 const e=evidence();assert.deepEqual(decisionSchema.parse({...plain,reviewedPackEvidence:e}).reviewedPackEvidence,e);
});
test('reviewed choice must match price, label, count, exact ceil and confirmed available limit',()=>{
 for(const patch of [{unitPriceMinor:0},{label:'Other pack'},{packs:1},{needed:quantity(9)},{availablePackLimit:1},{productMatchConfirmed:false},{availabilityConfirmed:false},{usablePerPack:quantity(0)},{usablePerPack:quantity(4,'gram')}]) {
  assert.equal(decisionSchema.safeParse({choice:'add',line,promote:false,reviewedPackEvidence:{...evidence(),...patch}}).success,false,JSON.stringify(patch));
 }
});
test('same-dimension exact conversions and null prices are validated without inventing price',()=>{
 const e={...evidence(),needed:quantity(1500,'gram'),usablePerPack:quantity(1,'kilogram'),unitPriceMinor:null};
 assert.equal(decisionSchema.parse({choice:'add',line:{...line,unitPriceMinor:null},promote:false,reviewedPackEvidence:e}).reviewedPackEvidence.unitPriceMinor,null);
});
test('metadata cannot attach to links, contributor-like decisions, or unbounded malformed fields',()=>{
 assert.equal(decisionSchema.safeParse({choice:'link',lineId:line.lineId,promote:false,reviewedPackEvidence:evidence()}).success,false);
 for(const patch of [{quoteSource:' '},{quoteObservedAt:'2026-11-03T01:00:00Z'},{needed:{...quantity(8),denominator:'0'}},{needed:{...quantity(8),numerator:'90071992547409930000'}}])assert.equal(decisionSchema.safeParse({choice:'add',line,promote:false,reviewedPackEvidence:{...evidence(),...patch}}).success,false);
});
