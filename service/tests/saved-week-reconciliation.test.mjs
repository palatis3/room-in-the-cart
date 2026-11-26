import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {basketDifference, removeNight, selectedNights} from '../dist/saved-week-reconciliation.js';

const id = () => randomUUID();
const at = '2026-11-01T12:00:00Z';
const quantity = n => ({amount:{numerator:String(n),denominator:'1'},unit:'gram',originalLiteral:n+' g',confirmedConversion:null});

test('two reviewed dinner removals preserve independent quantity and reservation on a shared line', () => {
  const line = id(), tuesday = id(), thursday = id(), wednesday = id();
  const meal = occurrenceId => ({kind:'meal',occurrenceId,ingredientId:id(),groupId:null,bindingId:null});
  const held = {kind:'reservation',reservationId:id(),purpose:'Lunch',originOccurrenceId:null,ingredientId:id(),groupId:null,bindingId:null};
  const sources = [[meal(tuesday),300],[meal(thursday),300],[meal(wednesday),100],[{kind:'manual'},100],[held,200]];
  const contributions = sources.map(([source,n]) => ({id:id(),lineId:line,source,productKey:'rice',productName:'Rice',originalText:'Rice',
    quantity:quantity(n),exclusions:[],contains:[],removedAt:null}));
  const graph = {schemaVersion:1,conversionTableVersion:'us-customary-metric-v1',householdId:id(),shopId:id(),revision:2,
    lines:[{id:line,name:'Rice',unit:'gram',originalOrder:0,trashedAt:null}], contributions, edges:[],
    usedIds:[line,...contributions.map(c=>c.id)]};
  const food = {graph,packs:[{lineId:line,usablePerPack:quantity(500),acceptUnresolved:false}]};
  const initial = [{lineId:line,originalItem:'Rice',packs:2,feeEligible:true,unitPriceMinor:324}];
  const first = removeNight(initial,food,tuesday,id(),at);
  const second = removeNight(first.lines,first.food,thursday,id(),at);
  assert.equal(first.lines[0].packs,2);
  assert.equal(second.lines[0].packs,1);
  assert.deepEqual(second.food.graph.contributions.filter(c=>!c.removedAt),contributions.slice(2));
  assert.deepEqual(basketDifference(initial,second.lines,food,second.food),[{id:line,name:'Rice',before:2,after:1,unlinked:false,
    beforeNeed:{numerator:'1000',denominator:'1',unit:'gram'},afterNeed:{numerator:'400',denominator:'1',unit:'gram'},
    manual:true,held:true,mealIds:[tuesday,thursday,wednesday]}]);
  assert.throws(()=>removeNight([{...initial[0],packs:6}],food,tuesday,id(),at),{code:'review_week_sources'});
  assert.throws(()=>removeNight(initial,{...food,packs:[]},tuesday,id(),at),{code:'review_week_sources'});
  assert.equal(initial[0].packs,2);
});

test('unlinked entered packs are never assigned to a dinner based on matching text',()=>{
  const row={lineId:id(),originalItem:'Beans',packs:4,feeEligible:true,unitPriceMinor:null};
  const next=removeNight([row],null,id(),id(),at);
  assert.deepEqual(next.lines,[row]);
  assert.equal(basketDifference([row],next.lines,null,null)[0].unlinked,true);
});

test('protected, stale, duplicate and out-of-week occurrences cannot enter a batch',()=>{
  const occurrenceId=id(), meal={title:'Dinner',day:'2026-11-04',kind:'dinner',portions:3,protected:false};
  const row={occurrenceId,revision:2,meal};
  assert.equal(selectedNights([row],'2026-11-01',[occurrenceId])[0].revision,2);
  assert.throws(()=>selectedNights([row],'2026-11-08',[occurrenceId]));
  assert.throws(()=>selectedNights([row],'2026-11-01',[id()]));
  assert.throws(()=>selectedNights([row],'2026-11-01',[occurrenceId,occurrenceId]));
  assert.throws(()=>selectedNights([{...row,meal:{...meal,protected:true}}],'2026-11-01',[occurrenceId]),{code:'protected_meal'});
});
