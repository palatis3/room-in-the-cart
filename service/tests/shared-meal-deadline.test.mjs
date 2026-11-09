import test from 'node:test';
import assert from 'node:assert/strict';
import {sharedMealSchema,moveSharedMeal} from '../dist/shared-meal-planning.js';
import {sealedRecoveryMeal} from '../dist/shared-recovery-basis.js';
import {previewRecovery} from '../dist/recovery-domain.js';
import {fixture,request,id,q} from './recovery-fixture.mjs';

function planned(day, deadline) {
  return {title:'Dinner for Sol', day, kind:'dinner', portions:4, protected:false,
    planning:{groups:[{id:id(12),name:'Dinner',servings:{numerator:4,denominator:1},protected:false}],
      ingredients:[{id:id(89),name:'Beans',quantity:q(4),groupIds:[id(12)],exclusions:[]}],leadTimeMinutes:120,
      ...(deadline ? {deadline} : {})}};
}

test('deadline validates the entered instant in the scheduled zone, including distinct clock repetitions',()=>{
  const at='2026-11-01T06:30:00Z', zone='America/New_York';
  for(const instant of ['2026-11-01T05:30:00Z',at,'2026-11-01T01:30:00-05:00']){
    assert.deepEqual(sharedMealSchema.parse(planned('2026-11-01',{at:instant,zone})).planning.deadline,{at:instant,zone});
  }
  const sameInstant='2026-11-02T07:30:00Z';
  assert.equal(sharedMealSchema.safeParse(planned('2026-11-01',{at:sameInstant,zone:'America/Los_Angeles'})).success,true);
  assert.equal(sharedMealSchema.safeParse(planned('2026-11-01',{at:sameInstant,zone:'Pacific/Kiritimati'})).success,false);
  assert.equal(sharedMealSchema.safeParse(planned('2026-11-02',{at:sameInstant,zone:'Pacific/Kiritimati'})).success,true);
  for(const bad of [{at},{zone},{at,zone:'+05:30'},{at,zone:'Made/Up'},{at:'2026-11-01T01:30:00',zone},
    {at:'2026-02-30T01:30:00Z',zone}]) assert.equal(sharedMealSchema.safeParse(planned('2026-11-01',bad)).success,false);
});

test('a date-only move preserves all other facts and never silently extends a deadline',()=>{
  const meal=planned('2026-11-01',{at:'2026-11-01T06:30:00Z',zone:'America/New_York'});
  const original=structuredClone(meal);
  const moved=moveSharedMeal(meal,'2026-11-08');
  assert.deepEqual(meal,original);
  assert.deepEqual(moveSharedMeal(meal,meal.day),original);
  assert.deepEqual(moved,planned('2026-11-08'));
  assert.equal(sharedMealSchema.safeParse({...meal,day:moved.day}).success,false);
  assert.deepEqual(moveSharedMeal({title:'Legacy',day:meal.day,kind:'side',portions:1,protected:false},moved.day),
    {title:'Legacy',day:moved.day,kind:'side',portions:1,protected:false});
});

test('sealed deadline and zone reach every recovery need and govern elapsed preparation without mutating the order',()=>{
  const b=fixture();const shop=b.shopId, occurrence=id(21), ingredient=id(89);
  const deadline={at:'2026-11-12T02:00:00Z',zone:'America/Los_Angeles'};
  const sealed={occurrenceId:shop+'/'+occurrence,revision:1,meal:planned('2026-11-11',deadline)};
  const immutable=structuredClone(sealed);
  const sources=[{sourceId:id(41),matches:[{occurrenceId:sealed.occurrenceId,mealRevision:1,ingredientId:ingredient}]}];
  const meal=sealedRecoveryMeal(sealed,shop,sources);
  assert.equal(meal.due,deadline.at);assert.equal(meal.zone,deadline.zone);assert.equal(meal.needs[0].due,deadline.at);
  b.meals[1]=meal;b.usedNeedIds.push(...meal.needs.map(n=>n.id));b.usedRevisionIds.push(meal.revisionId);
  const proposal=request(b);proposal.intent.replacement.remainingElapsedMinutes=30;
  assert.equal(previewRecovery(b,proposal,'2026-11-12T01:15:00Z').timingConfirmed,false);
  proposal.intent.replacement.advanceStepsCompleted=true;
  assert.equal(previewRecovery(b,proposal,'2026-11-12T01:15:00Z').timingConfirmed,true);
  assert.equal(previewRecovery(b,proposal,'2026-11-12T02:01:00Z').timingConfirmed,false);
  assert.throws(()=>previewRecovery(b,{...proposal,intent:{...proposal.intent,replacement:{...proposal.intent.replacement,zone:'UTC'}}},'2026-11-12T01:15:00Z'),
    e=>e.code==='changed_commitment');
  const legacy=sealedRecoveryMeal({...sealed,meal:planned('2026-11-11')},shop,sources);
  assert.equal(legacy.zone,null);assert.equal(legacy.due,null);assert.equal(legacy.needs[0].due,null);
  assert.deepEqual(sealed,immutable);
});

test('explicit unknown night remains distinct from omitted or invalid date and cannot carry a deadline',()=>{
  const meal=planned(null);
  assert.deepEqual(sharedMealSchema.parse(meal),meal);
  for(const day of [undefined,'','tomorrow','2026-02-30']) assert.equal(sharedMealSchema.safeParse({...meal,day}).success,false);
  assert.equal(sharedMealSchema.safeParse(planned(null,{at:'2026-11-01T18:00:00Z',zone:'UTC'})).success,false);
  assert.deepEqual(moveSharedMeal(meal,'2026-11-01'),{...meal,day:'2026-11-01'});
  const b=fixture(),sealed={occurrenceId:b.shopId+'/'+id(21),revision:1,meal};
  const recovery=sealedRecoveryMeal(sealed,b.shopId,[]);
  assert.equal(recovery.day,null);assert.equal(recovery.due,null);assert.equal(recovery.zone,null);
  assert(recovery.needs.every(n=>n.due===null));
});

test('an undated recovery preserves physical coverage but never manufactures on-time feasibility',()=>{
  const b=fixture();b.meals[1].day=null;b.meals[1].due=null;
  b.meals[1].needs.forEach(n=>n.due=null);
  const input=request(b),at='2026-11-10T17:00:00Z';input.intent.replacement.remainingElapsedMinutes=0;
  const result=previewRecovery(b,input,at);
  assert.equal(result.foodConfirmed,true);assert.equal(result.timingConfirmed,false);assert.equal(result.feasible,false);
  assert.equal(result.after.meals[1].day,null);
  assert.equal(result.after.meals[1].zone,b.meals[1].zone,'Known zone is independent of unknown meal night');
  assert(result.after.demands.filter(n=>n.needId===id(201)).every(n=>n.deadlineStatus==='unknown'));
  for(const mutate of [m=>m.due='2026-11-11T18:00:00Z',m=>m.needs[0].due='2026-11-11T18:00:00Z']){
    const forged=structuredClone(input);mutate(forged.intent.replacement);
    assert.throws(()=>previewRecovery(b,forged,at));
  }
});
