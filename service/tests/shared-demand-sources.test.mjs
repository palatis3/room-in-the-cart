import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mealDemandSources,mealSourceKey,exactSourceExclusions,requestDemandSource} from '../dist/shared-demand-sources.js';
const q=(n=6,d=1)=>({amount:{numerator:n,denominator:d},unit:'count',originalLiteral:`${n}/${d} wraps`});
function fixture(){
 const shop=randomUUID(),occurrenceId=randomUUID(),ingredientId=randomUUID(),dinner=randomUUID(),lunch=randomUUID();
 const meal={title:'Tacos and lunch',day:null,kind:'dinner',portions:3,protected:false,
  planning:{groups:[{id:dinner,name:'Dinner',servings:{numerator:2,denominator:1},protected:false},{id:lunch,name:'Lunch',servings:{numerator:1,denominator:1},protected:true}],
   ingredients:[{id:ingredientId,name:'Wraps',quantity:q(),groupIds:[dinner,lunch],exclusions:['Sesame']}],exclusions:['Peanuts']}};
 return {shop,occurrenceId,ingredientId,dinner,lunch,meal,occurrences:[{occurrenceId,meal}]};
}
test('legacy source catalog is read-only and preserves explicit quantities and protected unknowns',()=>{
 const f=fixture(),before=structuredClone(f.occurrences),rows=mealDemandSources(f.shop,f.occurrences);
 assert.deepEqual(f.occurrences,before);assert.equal(rows.length,2);
 assert.equal(rows[0].source.kind,'meal');assert.equal(rows[0].quantity.amount.numerator,'6');
 assert.equal(rows[0].originalQuantityText,'6/1 wraps');assert.equal(rows[0].sourceLabel,f.meal.title);
 assert.equal(rows[1].source.kind,'reservation');assert.equal(rows[1].source.groupId,f.lunch);
 assert.equal(rows[1].quantity,null);assert.equal(rows[1].originalQuantityText,null);assert.equal(rows[1].requiredLineId,null);
});
test('explicit group bindings stay separate and retain exact reduced rational quantities',()=>{
 const f=fixture();f.meal.planning.bindings=[{id:randomUUID(),ingredientId:f.ingredientId,groupId:f.dinner,quantity:q(8,2)},
  {id:randomUUID(),ingredientId:f.ingredientId,groupId:f.lunch,quantity:q(4,2)}];
 const rows=mealDemandSources(f.shop,f.occurrences);assert.equal(rows.length,2);
 assert.equal(rows[0].source.kind,'meal');assert.equal(rows[0].source.bindingId,f.meal.planning.bindings[0].id);
 assert.deepEqual(rows[0].quantity.amount,{numerator:'4',denominator:'1'});assert.equal(rows[0].quantity.originalLiteral,'8/2 wraps');
 assert.equal(rows[1].source.kind,'reservation');assert.equal(rows[1].source.bindingId,f.meal.planning.bindings[1].id);
 assert.deepEqual(rows[1].quantity.amount,{numerator:'2',denominator:'1'});
});
test('whole protected source is not double counted and existing whole-source representation remains valid',()=>{
 const f=fixture();f.meal.protected=true;
 assert.equal(mealDemandSources(f.shop,f.occurrences).length,1);
 f.meal.planning.bindings=[{id:randomUUID(),ingredientId:f.ingredientId,groupId:f.dinner,quantity:q(4)},{id:randomUUID(),ingredientId:f.ingredientId,groupId:f.lunch,quantity:q(2)}];
 const grouped=mealDemandSources(f.shop,f.occurrences);assert.equal(grouped.length,2);assert.ok(grouped.every(r=>r.source.kind==='reservation'));
 const whole=mealDemandSources(f.shop,f.occurrences,new Set([f.occurrenceId+'/'+f.ingredientId]));
 assert.equal(whole.length,1);assert.equal(whole[0].source.groupId,null);assert.equal(whole[0].quantity.amount.numerator,'6');
});
test('descriptor and reservation identities are stable and scoped even when recipe IDs are reused',()=>{
 const f=fixture(),first=mealDemandSources(f.shop,f.occurrences);
 assert.deepEqual(mealDemandSources(f.shop,f.occurrences),first);
 const copied=mealDemandSources(f.shop,[...f.occurrences,{occurrenceId:randomUUID(),meal:f.meal}]);
 assert.equal(new Set(copied.map(r=>r.id)).size,4);
 assert.equal(new Set(copied.filter(r=>r.source.kind==='reservation').map(r=>r.source.reservationId)).size,2);
 assert.notEqual(mealDemandSources(randomUUID(),f.occurrences)[0].id,first[0].id);
});
test('all original exclusion labels are retained once in their exact source scope',()=>{
 const f=fixture();f.meal.planning.exclusions=['Sesame','Sesame'];
 const row=mealDemandSources(f.shop,f.occurrences)[0];assert.equal(row.sourceExclusions.length,2);
 assert.deepEqual(row.sourceExclusions.map(e=>e.ingredientId),[null,f.ingredientId]);
 assert.ok(row.sourceExclusions.every(e=>e.resolution.kind==='unresolved'));
 assert.equal(exactSourceExclusions(row.sourceExclusions,row.sourceExclusions),true);
 assert.equal(exactSourceExclusions([row.sourceExclusions[0],row.sourceExclusions[0]],row.sourceExclusions),false);
 assert.equal(exactSourceExclusions(row.sourceExclusions.slice(1),row.sourceExclusions),false);
});
test('unbound meal identity cannot counterfeit a named-group source',()=>{
 const f=fixture(),row=mealDemandSources(f.shop,f.occurrences)[0];
 assert.notEqual(mealSourceKey(row.source),mealSourceKey({...row.source,groupId:f.lunch}));
});
test('request catalog retains accepted revision and line without parsing original quantity text',()=>{
 const shop=randomUUID(),request={request_id:randomUUID(),line_id:randomUUID(),reviewed_revision:4,original_item:'Wraps for guest',own_quantity:'two bags maybe?'};
 const row=requestDemandSource(shop,request);assert.deepEqual(row.source,{kind:'request',requestId:request.request_id,appliedRequestRevision:4});
 assert.equal(row.requiredLineId,request.line_id);assert.equal(row.originalText,request.original_item);
 assert.equal(row.originalQuantityText,request.own_quantity);assert.equal(row.quantity,null);
 assert.deepEqual(requestDemandSource(shop,request),row);
});
test('no sources are invented for manual-only shops or missing meal quantities',()=>{
 assert.deepEqual(mealDemandSources(randomUUID(),[]),[]);
 const f=fixture();f.meal.planning.ingredients[0].quantity=null;
 assert.ok(mealDemandSources(f.shop,f.occurrences).every(r=>r.quantity===null));
});
