import test from 'node:test';
import assert from 'node:assert/strict';
import {canonicalSupply,previewRecovery,projectRecovery,recoveryDigest} from '../dist/recovery-domain.js';
import {at,fixture,id,q,request} from './recovery-fixture.mjs';

const fraction = (n,d=1) => ({numerator:String(n),denominator:String(d)});
const demand = (result,n) => result.demands.find(row => row.needId === id(n));
const throwsCode = (action,code) => assert.throws(action,error => error.code === code);
const hold = (source,n,d=1,unit='count') => ({sourceId:id(source),quantity:{unit,amount:fraction(n,d)}});

function physical() {
  const b = fixture();
  b.base.pantryRevision = 12;
  b.foreignHolds = [];
  // The current shop's delivery really provided one portion. The second stock
  // is a separately issued manual freezer lot, independent of any sealed line.
  b.sources[1].origin = {kind:'sharedStock',batchId:id(41),location:'freezer'};
  b.arrivals = [b.arrivals[0]];
  b.usable = [{...b.usable[0],usable:q(1)}];
  b.pantryObservations = [{id:id(800),sourceId:id(41),householdId:b.householdId,identityRevision:1,
    revision:10,predecessorId:null,confirmedAt:at,recordedAt:at,quantity:q(5)}];
  const [tuesday,wednesday] = b.meals;
  tuesday.needs[0].foodId = null; tuesday.needs[0].matchedSourceIds = [];
  tuesday.needs[1].foodId = null; tuesday.needs[1].matchedSourceIds = [id(41)];
  wednesday.needs[0].foodId = null; wednesday.needs[0].matchedSourceIds = [id(40),id(41)];
  b.reservations = [{id:id(70),sourceId:id(41),needId:id(31),quantity:q(2)},
    {id:id(71),sourceId:id(41),needId:id(32),quantity:q(4)}];
  return b;
}

test('five observed freezer portions plus an independent delivery cover two lunches and four dinners once', () => {
  const b = physical();
  const original = structuredClone(b);
  const report = projectRecovery(b,at);
  const dinner = demand(report,32);
  assert.deepEqual(demand(report,31).allocated,fraction(2));
  assert.deepEqual(dinner.shortfall,fraction(0));
  assert.deepEqual(dinner.reservations,[{reservationId:id(71),sourceId:id(41),requested:fraction(4),backed:fraction(3)}]);
  assert.deepEqual(report.allocations.filter(row => row.needId === id(32)).map(row=>[row.sourceId,row.amount]),
    [[id(40),fraction(1)],[id(41),fraction(3)]]);
  assert.deepEqual(demand(report,30).shortfall,fraction(6));
  const lot = canonicalSupply(b,at).find(row => row.sourceId === id(41));
  assert.equal(lot.observationId,id(800));
  assert.equal(lot.location,'freezer');
  assert.equal('arrivalId' in lot,false);
  assert.deepEqual(b,original);
});

test('explicit stock observation head supersedes older evidence even when unknown, stale-identity, or future', () => {
  for (const correction of [{quantity:null},{confirmedAt:'2026-11-11T02:00:00Z'},{identityRevision:1}]) {
    const b = physical();
    if ('identityRevision' in correction) b.sources[1].identityRevision = 2;
    b.pantryObservations.push({...b.pantryObservations[0],id:id(801),revision:11,predecessorId:id(800),...correction});
    const report = projectRecovery(b,at);
    assert.deepEqual(demand(report,32).shortfall,fraction(3));
    assert.deepEqual(demand(report,32).reservations[0].requested,fraction(4));
    assert.deepEqual(demand(report,32).reservations[0].backed,fraction(0));
    assert.deepEqual(demand(report,32).sourceIssues,[{sourceId:id(41),issue:'unconfirmed_stock'}]);
    assert.equal(canonicalSupply(b,at).some(row=>row.sourceId===id(41)),false);
  }
  const zero = physical();zero.pantryObservations[0].quantity=q(0);
  assert.deepEqual(canonicalSupply(zero,at)[1].quantity,q(0));
});

test('manual, retail and carried aliases cannot manufacture or duplicate a physical source', () => {
  const b = physical(); const fakeArrival = {...b.arrivals[0],id:id(810),sourceId:id(41),revision:3};
  b.arrivals.push(fakeArrival);
  throwsCode(()=>projectRecovery(b,at),'not_delivery_evidence');
  const alias = physical();alias.sources.push({...alias.sources[1],id:id(42)});
  assert.throws(()=>projectRecovery(alias,at));
  const phantom = physical();phantom.pantryObservations[0].sourceId=id(40);
  throwsCode(()=>projectRecovery(phantom,at),'invalid_pantry_observation');
  const missingChain = physical();missingChain.pantryObservations[0].predecessorId=id(999);
  assert.throws(()=>projectRecovery(missingChain,at));
  const flag = physical();delete flag.foreignHolds;
  throwsCode(()=>projectRecovery(flag,at),'incomplete_pantry_basis');
});

test('carry needs an explicit selection, original shop history, and that shop’s real supply seal', () => {
  const b = physical();
  const origin = id(90);
  b.sources[0].shopId = origin;
  b.arrivals[0].shopId = origin;b.arrivals[0].revision = 76;
  b.usable[0].shopId = origin;b.usable[0].revision = 77;
  b.selectedCarrySourceIds = [id(40)];
  b.carrySupplyRevisions = [{shopId:origin,supplyRevision:77}];
  const report = projectRecovery(b,at);
  assert.deepEqual(demand(report,32).shortfall,fraction(0));
  assert.equal(JSON.stringify(report).includes(origin),false);
  for (const change of [basis=>{basis.carrySupplyRevisions[0].supplyRevision=75;},
    basis=>{basis.selectedCarrySourceIds=[];},basis=>{basis.arrivals[0].shopId=basis.shopId;},
    basis=>{basis.sources[0].householdId=id(999);}]) {
    const bad = structuredClone(b);change(bad);assert.throws(()=>projectRecovery(bad,at));
  }
  b.meals[1].needs[0].matchedSourceIds = [id(41)];
  assert.deepEqual(demand(projectRecovery(b,at),32).shortfall,fraction(1));
});

test('opaque foreign holds protect exact fractions, unknown holds lock the lot, and incompatible units reject', () => {
  const b = physical();b.foreignHolds = [hold(41,3,2)];
  const report = projectRecovery(b,at);
  assert.deepEqual(demand(report,31).allocated,fraction(2));
  assert.deepEqual(demand(report,32).shortfall,fraction(3,2));
  const large = '1'+'0'.repeat(48);
  b.foreignHolds=[hold(41,'1',large)];
  assert.deepEqual(demand(projectRecovery(b,at),32).shortfall,fraction(1,large));
  b.foreignHolds[0].quantity = null;
  const dinner = demand(projectRecovery(b,at),32);
  assert.deepEqual(dinner.shortfall,fraction(3));
  assert.ok(dinner.issues.includes('foreign_hold_unknown'));
  b.foreignHolds = [hold(41,2,1,'gram')];throwsCode(()=>projectRecovery(b,at),'invalid_foreign_hold');
});

test('explicit new recipe need may match independent foods while excluded or incompatible sources remain visible', () => {
  const b = physical();
  b.reservations = b.reservations.filter(pin => pin.needId !== id(32));
  const r = request(b);
  const replacement = r.intent.replacement.needs[0];
  replacement.foodId=null;replacement.matchedSourceIds=[id(41),id(40)];
  assert.equal(replacement.ingredientId,id(1201));
  assert.equal(previewRecovery(b,r,at).feasible,true);
  const confused = structuredClone(r);confused.intent.replacement.needs[0].matchedSourceIds=[id(999)];
  throwsCode(()=>previewRecovery(b,confused,at),'unknown_source');
  b.foods[0].exclusionTags=['sesame'];replacement.exclusions=['sesame'];
  const review = previewRecovery(b,r,at);
  assert.equal(review.feasible,false);
  assert.deepEqual(demand(review.after,201).sourceIssues,[{sourceId:id(40),issue:'exclusion_conflict'}]);
  assert.deepEqual(demand(review.after,201).shortfall,fraction(1));
  b.foods[0].exclusionTags=[];b.usable[0].usable=q(1,'gram');b.arrivals[0].received=q(2,'gram');
  assert.deepEqual(demand(previewRecovery(b,r,at).after,201).sourceIssues,[{sourceId:id(40),issue:'unit_mismatch'}]);
});

test('flexible multi-food match can move without starving a later single-source need', () => {
  const b = physical();
  b.reservations=[];
  b.meals[0].needs[1].matchedSourceIds=[id(40),id(41)];
  b.meals[0].needs[1].quantity=q(1);
  b.meals[1].needs[0].matchedSourceIds=[id(40)];b.meals[1].needs[0].quantity=q(1);
  assert.deepEqual(projectRecovery(b,at).allocations.map(row=>[row.needId,row.sourceId]),
    [[id(31),id(41)],[id(32),id(40)]]);
});

test('unknown protected amounts reserve their matched sources; an unsplit group total stays singular and unresolved', () => {
  const b=physical();b.reservations=[];
  b.meals[0].needs[1].quantity=null;
  b.meals[0].zone=null;
  const p=projectRecovery(b,at);
  assert.equal(demand(p,31).shortfall,null);
  assert.deepEqual(demand(p,32).shortfall,fraction(3));
  assert.ok(demand(p,32).issues.includes('protected_quantity_unknown'));
  const [meal] = b.meals;
  meal.needs[1].groupId=null;meal.needs[1].groupIds=meal.groups.map(group=>group.id);
  meal.needs[1].quantity=q(2);
  const aggregate=projectRecovery(b,at);
  assert.deepEqual(demand(aggregate,31).allocated,fraction(2));
  assert.ok(demand(aggregate,31).issues.includes('unknown_split'));
  assert.equal(aggregate.meals[0].needs[1].groupId,null);
});

test('a captured preview stales on a revised pantry seal or newly committed foreign food', () => {
  const b=physical();b.reservations=b.reservations.filter(pin=>pin.needId!==id(32));
  const r=request(b);r.intent.replacement.needs[0].matchedSourceIds=[id(40),id(41)];
  const previous=previewRecovery(b,r,at);
  b.foreignHolds=[hold(41,1)];assert.notEqual(previewRecovery(b,r,at).previewDigest,previous.previewDigest);
  const stale=structuredClone(r);b.base.pantryRevision++;
  throwsCode(()=>previewRecovery(b,stale,at),'stale_basis');
  const immutable=structuredClone(b.meals[1]);assert.equal(recoveryDigest(immutable),r.intent.targetDigest);
});

test('ungrouped and unplanned recorded meals stay readable; a replacement cannot abandon a named commitment', () => {
  const b=physical();b.reservations=[];
  const old=b.meals[1];old.groups=[];old.needs[0].groupId=null;old.zone=null;
  b.meals[0].needs=[];
  const report=projectRecovery(b,at);
  assert.deepEqual(report.meals[0].needs,[]);
  assert.equal(report.meals[1].zone,null);
  assert.deepEqual(demand(report,32).allocated,fraction(4));
  const named=physical();named.reservations=[];
  const drop=request(named);drop.intent.replacement.needs[0].groupId=null;
  throwsCode(()=>previewRecovery(named,drop,at),'changed_groups');
});

test('manual stock converts compatible units exactly and never gains implicit food-ID eligibility', () => {
  const b=physical(); b.reservations=[];
  b.pantryObservations[0].quantity=q(1,'pound',2);
  b.meals[0].needs[1].matchedSourceIds=[];
  b.meals[1].needs[0].quantity=q(230,'gram');
  b.meals[1].needs[0].matchedSourceIds=[id(41)];
  const dinner=demand(projectRecovery(b,at),32);
  assert.deepEqual(dinner.allocated,fraction(45359237,200000));
  assert.deepEqual(dinner.shortfall,fraction(640763,200000));
  b.meals[1].needs[0].foodId=id(6);delete b.meals[1].needs[0].matchedSourceIds;
  assert.deepEqual(demand(projectRecovery(b,at),32).allocated,fraction(0));
});
