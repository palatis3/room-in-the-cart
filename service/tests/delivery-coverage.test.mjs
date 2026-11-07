import test from 'node:test';
import assert from 'node:assert/strict';
import {deliveryCoverage} from '../dist/delivery-coverage.js';

const q=(n,unit='count',d=1)=>({amount:{numerator:n,denominator:d},unit,originalLiteral:String(n)});
const value=n=>({numerator:String(n),denominator:'1'});
function meal(id,quantity,{protectedMeal=false,exclusions=[]}={}) {
 return {occurrenceId:id,revision:2,meal:{day:'2026-11-07',title:id,protected:protectedMeal,planning:{
   groups:[],ingredients:[{id:'wrap',name:'Wraps',quantity,groupIds:[],exclusions}]}}};
}
function source(id,quantity,ids,exclusionTags=[]) {
 return {sourceId:id,foodName:'Wraps',exclusionTags,confirmed:quantity && {quantity},
   matches:ids.map(occurrenceId=>({occurrenceId,mealRevision:2,ingredientId:'wrap'}))};
}
test('five delivered portions serve two protected lunches and three of four dinner portions',()=>{
 const dinner=meal('supper',q(6)),plan=dinner.meal.planning;
 plan.groups=[{id:'plates',protected:false},{id:'lunch',protected:true}];
 plan.ingredients[0].groupIds=['plates','lunch'];
 plan.bindings=[{ingredientId:'wrap',groupId:'plates',quantity:q(4)},{ingredientId:'wrap',groupId:'lunch',quantity:q(2)}];
 const result=deliveryCoverage([dinner],[source('lot',q(5),['supper'])]);
 assert.deepEqual(result.needs.map(n=>[n.groupIds,n.covered,n.missing]),[[['plates'],value(3),value(1)],[['lunch'],value(2),value(0)]]);
});
test('a protected group can switch lots to keep another meal covered without changing its reserved amount',()=>{
 const result=deliveryCoverage([meal('lunch',q(2),{protectedMeal:true}),meal('supper',q(3))],[
   source('both',q(3),['lunch','supper']),source('lunch-only',q(2),['lunch'])]);
 assert.deepEqual(result.needs.map(n=>n.allocations),[[{sourceId:'lunch-only',amount:value(2)}],[{sourceId:'both',amount:value(3)}]]);
});
test('unverified food, exclusions, old meal revisions, and incompatible units supply no coverage',()=>{
 const m=meal('m',q(1),{exclusions:['sesame']}),old=source('old',q(10),['m']);old.matches[0].mealRevision=1;
 const r=deliveryCoverage([m],[source('pending',null,['m']),source('sesame',q(1),['m'],['SESAME']),
   source('liquid',q(1,'liter'),['m']),old]);
 assert.deepEqual(r.needs[0].covered,value(0));assert.deepEqual(r.needs[0].issues,['unconfirmed','exclusion','unitMismatch']);
});
test('an unknown protected quantity holds only its matched food and never fabricates a group split',()=>{
 const m=meal('unknown',null,{protectedMeal:true}),plan=m.meal.planning;
 plan.groups=[{id:'a',protected:true},{id:'b',protected:false}];plan.ingredients[0].groupIds=['a','b'];
 const r=deliveryCoverage([m,meal('d',q(4))],[source('shared',q(3),['unknown','d']),source('d-only',q(1),['d'])]);
 assert.deepEqual(r.needs[0].groupIds,['a','b']);assert.equal(r.needs[0].missing,null);
 assert.ok(r.needs[0].issues.includes('unknownSplit'));assert.deepEqual(r.needs[1].covered,value(1));
 assert.ok(r.needs[1].issues.includes('protectedQuantityUnknown'));
});
test('mixed units remain exact and meals missing requirements stay visible',()=>{
 const r=deliveryCoverage([meal('m',q(1,'kilogram')), {occurrenceId:'legacy',revision:1,meal:{title:'Legacy'}}],
   [source('rice',q(1,'gram',3),['m'])]);
 assert.deepEqual(r.needs[0].covered,{numerator:'1',denominator:'3000'});
 assert.deepEqual(r.needs[0].missing,{numerator:'2999',denominator:'3000'});assert.deepEqual(r.unplannedOccurrenceIds,['legacy']);
});

test('every three-meal/three-lot matching pattern preserves the best protected-first coverage and conserves each lot',()=>{
 const names=['breakfast','lunch','dinner'], caps=[1,2,1], demand=[2,1,2];
 const meals=names.map((name,i)=>meal(name,q(demand[i]),{protectedMeal:i===1}));
 // Independent integer oracle: assign each individual portion to an eligible meal or leave it unused.
 const priority=[1,0,2];
 for(let mask=0;mask<512;mask++) {
   const lots=caps.map((capacity,s)=>source('lot'+s,q(capacity),names.filter((_,n)=>(mask&(1<<(s*3+n)))!==0)));
   const portions=[0,1,1,2], counts=[0,0,0];
   let best=-1;
   function enumerate(position) {
     if(position===portions.length) {
       best=Math.max(best,priority.reduce((score,n)=>score*4+counts[n],0));return;
     }
     enumerate(position+1);
     for(let n=0;n<3;n++) if(counts[n]<demand[n] && (mask&(1<<(portions[position]*3+n)))) {
       counts[n]++;enumerate(position+1);counts[n]--;
     }
   }
   enumerate(0);
   const {needs}=deliveryCoverage(meals,lots), used=[0,0,0];
   const score=priority.reduce((n,i)=>n*4+Number(needs[i].covered.numerator),0);
   assert.equal(score,best,'matching pattern '+mask);
   needs.forEach((need,n)=>{
     let total=0;
     for(const a of need.allocations) {
       const s=lots.findIndex(l=>l.sourceId===a.sourceId);
       assert.ok(mask&(1<<(s*3+n)));assert.equal(a.amount.denominator,'1');
       const units=Number(a.amount.numerator);used[s]+=units;total+=units;
     }
     assert.deepEqual(need.covered,value(total));assert.deepEqual(need.missing,value(demand[n]-total));
   });
   assert.ok(used.every((n,s)=>n<=caps[s]));
 }
});

test('an explicitly entered prohibition blocks its named food in English and Spanish',()=>{
 for(const [restriction,tag] of [['No sesame','sesame'],['Sin sésamo','sésamo'],['Without sesame','sesame']]) {
   const r=deliveryCoverage([meal('m',q(1),{exclusions:[restriction]})],[source('lot',q(1),['m'],[tag])]);
   assert.deepEqual(r.needs[0].covered,value(0));assert.deepEqual(r.needs[0].issues,['exclusion']);
 }
});

test('a partially itemized multi-group requirement holds the total once until the protected split is known',()=>{
 const m=meal('tuesday',q(4));
 m.meal.planning.groups=[{id:'dinner',protected:false},{id:'packed',protected:true}];
 m.meal.planning.ingredients[0].groupIds=['dinner','packed'];
 m.meal.planning.bindings=[{ingredientId:'wrap',groupId:'dinner',quantity:q(4)}];
 const earlier=meal('monday',q(2));
 const r=deliveryCoverage([earlier,m],[source('bag',q(5),['tuesday','monday'])]);
 assert.equal(r.needs.length,2);assert.deepEqual(r.needs[0].covered,value(1));
 const combined=r.needs[1];assert.deepEqual(combined.groupIds,['dinner','packed']);assert.equal(combined.protected,true);
 assert.deepEqual(combined.covered,value(4));assert.deepEqual(combined.issues,['unknownSplit']);
});
test('confirmed zero is distinct from waiting for a usable count',()=>{
 const m=meal('lunch',q(2)),food=source('delivery',q(0),['lunch']);
 const zero=deliveryCoverage([m],[food]).needs[0];
 assert.deepEqual(zero.covered,value(0));assert.deepEqual(zero.missing,value(2));assert.deepEqual(zero.issues,[]);
 const waiting=deliveryCoverage([m],[{...food,confirmed:null}]).needs[0];
 assert.deepEqual(waiting.missing,zero.missing);assert.deepEqual(waiting.issues,['unconfirmed']);
});
