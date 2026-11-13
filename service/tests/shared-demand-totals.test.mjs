import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';

const dist=process.env.RITC_SHARED_DEMAND_DIST;
const moduleURL=dist?pathToFileURL(resolve(dist,'shared-demand-domain.js')).href:new URL('../dist/shared-demand-domain.js',import.meta.url).href;
const {demandLineTotals,applyDemandChange}=await import(moduleURL);
const fixture=JSON.parse(await readFile(new URL('../../shared/fixtures/shared-demand/conservation-v1.json',import.meta.url),'utf8'));
const graph=()=>structuredClone(fixture.graph);
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const at='2026-11-09T13:00:00Z';
const quantity=(n,denominator='1',unit='count')=>({amount:{numerator:String(n),denominator},unit,originalLiteral:`${n}/${denominator} ${unit}`,confirmedConversion:null});
function change(g,patch){return {schemaVersion:1,operationId:id(900),householdId:g.householdId,shopId:g.shopId,baseRevision:g.revision,at,
 lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[],...patch};}
function single(amount=quantity(12)){
 const g=graph();g.contributions=g.contributions.slice(0,1);g.contributions[0].quantity=amount;g.edges=[];return g;
}

test('canonical summary counts twelve wraps once and retains every active source without mutating the graph',()=>{
 const g=graph(),before=structuredClone(g);
 assert.deepEqual(demandLineTotals(g),[{lineId:id(1),unit:'count',quantity:{numerator:'12',denominator:'1'},
  activeContributionIds:[id(11),id(12),id(13),id(14)]}]);
 assert.deepEqual(g,before);
});

test('duplicate and additional imports retain distinct source IDs while producing different food totals',()=>{
 const g=graph(),extra={...structuredClone(g.contributions[0]),id:id(15),source:{kind:'import',batchId:id(700),entryId:id(701)}};
 g.contributions.push(extra);g.usedIds.push(extra.id);
 assert.deepEqual(demandLineTotals(g)[0].quantity,{numerator:'24',denominator:'1'});
 const edge={id:id(702),kind:'duplicate',demandId:extra.id,supplyId:id(11),quantity:quantity(12),
  confirmation:{productMatchConfirmed:true,confirmedAt:at,evidence:'Reviewed the same imported twelve wraps'}};
 g.edges.push(edge);g.usedIds.push(edge.id);
 assert.deepEqual(demandLineTotals(g)[0],{lineId:id(1),unit:'count',quantity:{numerator:'12',denominator:'1'},
  activeContributionIds:[id(11),id(12),id(13),id(14),id(15)]});
});

test('source removal excludes retired IDs while preserving other meals, lunch and the original manual food',()=>{
 const g=graph(),removed=applyDemandChange(g,change(g,{removeSourceIds:[id(12)]})).graph;
 assert.deepEqual(demandLineTotals(removed)[0],{lineId:id(1),unit:'count',quantity:{numerator:'12',denominator:'1'},
  activeContributionIds:[id(11),id(13),id(14)]});
 assert.equal(removed.contributions.find(c=>c.id===id(12)).removedAt,at);
 const meals=applyDemandChange(g,change(g,{removeSourceIds:[id(11),id(12)]})).graph;
 assert.deepEqual(demandLineTotals(meals)[0].quantity,{numerator:'6',denominator:'1'});
 assert.deepEqual(demandLineTotals(meals)[0].activeContributionIds,[id(13),id(14)]);
});

test('a partial allocation adds the uncovered need rather than hiding it in a summary',()=>{
 const g=graph();g.edges[0].quantity=quantity(3);
 assert.deepEqual(demandLineTotals(g)[0].quantity,{numerator:'15',denominator:'1'});
});

test('unknown food or an unconfirmed cross-dimension conversion stays explicit null',()=>{
 for(const amount of [null,quantity(12,'1','gram')]){
  const g=single(amount),before=structuredClone(g);
  assert.deepEqual(demandLineTotals(g),[{lineId:id(1),unit:'count',quantity:null,activeContributionIds:[id(11)]}]);
  assert.deepEqual(g,before);
 }
});

test('exact rational conversion and Int64 bounds never pass through floating point',()=>{
 const g=single(quantity(1,'3','kilogram'));g.lines[0].unit='gram';
 assert.deepEqual(demandLineTotals(g)[0].quantity,{numerator:'1000',denominator:'3'});
 g.lines[0].unit='count';g.contributions[0].quantity=quantity('9223372036854775807');
 assert.deepEqual(demandLineTotals(g)[0].quantity,{numerator:'9223372036854775807',denominator:'1'});
});

test('empty and retired lines have no summary rows but remain in graph history',()=>{
 const g=single(),retired=applyDemandChange(g,change(g,{removeSourceIds:[id(11)]})).graph;
 assert.deepEqual(demandLineTotals(retired),[]);
 assert.equal(retired.lines.length,1);assert.equal(retired.lines[0].trashedAt,at);
 assert.ok(retired.usedIds.includes(id(11)));
 const empty={...g,lines:[],contributions:[],edges:[]};assert.deepEqual(demandLineTotals(empty),[]);
});

test('summary preserves graph line order, declared units and exact source membership',()=>{
 const g=single(),second={...structuredClone(g.lines[0]),id:id(2),name:'Flour',unit:'gram',originalOrder:5};
 g.lines.unshift(second);g.usedIds.push(second.id);
 const flour={...structuredClone(g.contributions[0]),id:id(16),lineId:second.id,productKey:'flour',productName:'Flour',originalText:'Half a gram',quantity:quantity(1,'2','gram')};
 g.contributions.push(flour);g.usedIds.push(flour.id);
 assert.deepEqual(demandLineTotals(g),[
  {lineId:id(2),unit:'gram',quantity:{numerator:'1',denominator:'2'},activeContributionIds:[id(16)]},
  {lineId:id(1),unit:'count',quantity:{numerator:'12',denominator:'1'},activeContributionIds:[id(11)]}
 ]);
});

test('summary cannot turn an invalid graph into a valid display projection',()=>{
 const g=graph();g.contributions[0].contains.push(g.contributions[3].exclusions[0]);
 assert.throws(()=>demandLineTotals(g));
 const bad=single();bad.contributions[0].quantity.amount.denominator='0';
 assert.throws(()=>demandLineTotals(bad));
});
