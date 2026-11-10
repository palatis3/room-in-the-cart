import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {deriveSharedFoodUndo as undo,assertSharedFoodUndoReplay as replay} from '../dist/shared-food-operation-undo.js';
import {applyDemandChange as apply} from '../dist/shared-demand-domain.js';
import {digest} from '../dist/database.js';
import {checkout} from '../dist/checkout.js';
import {mealCreationAbsence} from '../dist/shared-food-meal-creation-undo.js';
const golden=JSON.parse(await readFile(new URL('../../shared/fixtures/shared-demand/conservation-v1.json',import.meta.url),'utf8'));
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const at='2026-11-09T13:00:00.000Z',now=new Date('2026-11-09T13:01:00.000Z');
const q=n=>({amount:{numerator:String(n),denominator:'1'},unit:'count',originalLiteral:n+' wraps',confirmedConversion:null});
const empty=()=>({lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[]});
const change=(g,patch={},op=300)=>({schemaVersion:1,operationId:id(op),householdId:g.householdId,shopId:g.shopId,baseRevision:g.revision,at,...empty(),...patch});
function setup({graphChange=true,quoteChange=true}={}){
 const before=structuredClone(golden.graph);before.revision=1;before.contributions=before.contributions.slice(0,1);before.edges=[];
 const added={...structuredClone(before.contributions[0]),id:id(201),source:{kind:'manual'},originalText:'extra 4 wraps',quantity:q(4)};
 const target=graphChange?apply(before,change(before,{contributions:[added]})):{graph:{...structuredClone(before),revision:2},receipt:{schemaVersion:1,operationId:id(300),householdId:before.householdId,shopId:before.shopId,baseRevision:1,resultRevision:2,lines:[],contributions:[],edges:[]}};
 const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:'2026-11-09T12:00:00.000Z',expiresAt:'2026-11-09T16:00:00.000Z'};
 const b={lineId:before.lines[0].id,originalItem:before.lines[0].name,packs:2,unitPriceMinor:100,feeEligible:true},a={...b,packs:3};
 const aq={...quote,capMinor:quoteChange?11000:10000};
 const snapshot=(revision,g,lines,quote)=>{const snapshot={shopId:before.shopId,revision,phase:'draft',demand:{schemaVersion:1,revision:g.revision,digest:digest(g)},lines,quote,budget:checkout(lines,quote)};return{snapshot,digest:digest(snapshot)};};
 const evidence={operation:{operation_id:id(300),household_id:before.householdId,shop_id:before.shopId,kind:'shop.patch',payload_digest:'a'.repeat(64)},
 effect:{operation_id:id(300),household_id:before.householdId,shop_id:before.shopId,base_shop_revision:2,result_shop_revision:3,base_graph_revision:1,result_graph_revision:2,classification:'eligible',reverses_operation_id:null},
 before:snapshot(2,before,[b],quote),after:snapshot(3,target.graph,[a],aq),beforeGraph:{graph:before,graph_digest:digest(before)},afterGraph:{graph:target.graph,graph_digest:digest(target.graph),receipt:target.receipt},alreadyReversed:false};
 const current={graph:structuredClone(target.graph),lines:[structuredClone(a)],quote:structuredClone(aq)};
 return{evidence,current,added,b,a,quote,command:{operationId:id(900),householdId:before.householdId,shopId:before.shopId,baseRevision:current.graph.revision,at},run(){this.command.baseRevision=this.current.graph.revision;return undo(this.evidence,this.current,this.command,now);}};
}

function creation({protectedMeal=false,protectedSource=false}={}){
 const f=setup({quoteChange:false}),occurrence=id(820),actor=id(821),ingredient=id(822);
 const meal={title:'New taco dinner',day:null,kind:'dinner',portions:2,protected:protectedMeal,
  planning:{groups:[],ingredients:[{id:ingredient,name:'Wraps',quantity:{amount:{numerator:4,denominator:1},unit:'count',originalLiteral:'4 wraps'},groupIds:[],exclusions:[]}]}};
 const added={...f.added,source:protectedSource?{kind:'reservation',reservationId:id(823),purpose:'New lunch',originOccurrenceId:occurrence,ingredientId:ingredient,groupId:null,bindingId:null}:{kind:'meal',occurrenceId:occurrence,ingredientId:ingredient,groupId:null,bindingId:null}};
 const target=apply(f.evidence.beforeGraph.graph,change(f.evidence.beforeGraph.graph,{contributions:[added]}));
 f.evidence.afterGraph={graph:target.graph,graph_digest:digest(target.graph),receipt:target.receipt};
 f.evidence.after.snapshot.demand={schemaVersion:1,revision:target.graph.revision,digest:digest(target.graph)};
 f.current.graph=structuredClone(target.graph);f.current.shopRevision=3;f.evidence.effect.classification='meal_action';
 const scope={householdId:f.command.householdId,shopId:f.command.shopId,operationId:id(300),baseShopRevision:2,resultShopRevision:3};
 const firstUse={householdId:scope.householdId,shopId:scope.shopId,occurrenceId:occurrence,operationId:scope.operationId,resultShopRevision:3};
 const absenceDigest=digest(mealCreationAbsence(scope,occurrence));
 const after={householdId:scope.householdId,shopId:scope.shopId,occurrenceId:occurrence,revision:3,actorId:actor,meal};
 f.evidence.meal={lineage:{...firstUse,beforeRevision:null,afterRevision:3,beforeDigest:absenceDigest,afterDigest:digest(after),proposalKind:null,proposalId:null,proposalDigest:null},before:null,after,latest:structuredClone(after),proposal:null,authorsLive:true,
  creation:{firstUse,acceptance:{...firstUse,baseShopRevision:2,absenceDigest}}};
 f.evidence.before.snapshot.mealRefs=[{occurrenceId:id(830),revision:1}];
 f.evidence.after.snapshot.mealRefs=[...f.evidence.before.snapshot.mealRefs,{occurrenceId:occurrence,revision:3}];
 f.evidence.after.digest=digest(f.evidence.after.snapshot);f.evidence.before.digest=digest(f.evidence.before.snapshot);
 return f;
}
test('creation Undo removes only target meal and its added food while restoring packs',()=>{
 const f=creation(),saved=structuredClone({evidence:f.evidence,current:f.current}),x=f.run();
 assert.deepEqual(x.action.body.mealEdit,{occurrenceId:id(820),baseMealRevision:3,meal:null});
 assert.deepEqual(x.mealUndo.targetBefore,{revision:null,meal:null});assert.deepEqual(x.mealUndo.touchedFields,['membership']);
 assert.equal(x.result.graph.contributions.find(r=>r.id===id(201)).removedAt,at);
 assert.equal(x.action.body.lines[0].packs,2);assert.deepEqual(x.action.body.quote,f.quote);
 assert.deepEqual(f.evidence,saved.evidence);assert.deepEqual(f.current,saved.current);
});
test('independent later staple and price survive; compensation names no unrelated meal',()=>{
 const f=creation(),line={id:id(700),name:'Later staple',unit:'count',originalOrder:9,trashedAt:null};
 const staple={...f.added,id:id(701),lineId:line.id,productKey:'staple',productName:'Staple',originalText:'later staple',quantity:q(1)};
 f.current.graph=apply(f.current.graph,change(f.current.graph,{lines:[line],contributions:[staple]},301)).graph;
 const basket={lineId:line.id,originalItem:line.name,packs:1,unitPriceMinor:200,feeEligible:false};f.current.lines.push(basket);f.current.lines[0].unitPriceMinor=150;f.current.shopRevision=4;
 const x=f.run();assert.deepEqual(x.action.body.lines[1],basket);assert.equal(x.action.body.lines[0].unitPriceMinor,150);
 assert.deepEqual(x.result.graph.contributions.find(r=>r.id===id(701)),staple);assert.equal(x.action.body.mealEdit.occurrenceId,id(820));
});
for(const [name,mutate] of [
 ['later identical meal revision',m=>{m.latest.revision=4;}],
 ['later title edit',m=>{m.latest.revision=4;m.latest.meal.title='Later dinner';}],
 ['later skipped tombstone',m=>{m.latest.revision=4;m.latest.meal=null;}],
 ['later recreate with original bytes',m=>{m.latest.revision=6;}]
])test(name+' conflicts atomically',()=>{const f=creation();mutate(f.evidence.meal);f.current.shopRevision=6;assert.throws(()=>f.run(),e=>e.code==='food_undo_meal_conflict');});
for(const [name,mutate] of [
 ['missing accepted creation',m=>{m.after=null;}],
 ['erased historical bytes',m=>{m.after.meal=null;}],
 ['changed history',m=>{m.after.meal.title='Removed item';}],
 ['inactive author',m=>{m.authorsLive=false;}],
 ['missing first-use proof',m=>{delete m.creation;}],
 ['reused occurrence identity',m=>{m.creation.firstUse.operationId=id(999);} ],
 ['wrong accepted scope',m=>{m.creation.acceptance.shopId=id(999);} ],
 ['absence confused with missing',m=>{delete m.before;}],
 ['tombstone confused with absence',m=>{m.before={...m.after,revision:1,meal:null};}],
 ['invented proposal',m=>{m.lineage.proposalKind='move';m.lineage.proposalId=id(999);m.lineage.proposalDigest='b'.repeat(64);}]
])test(name+' rejects both candidate and exact replay',()=>{const f=creation();mutate(f.evidence.meal);assert.throws(()=>f.run());assert.throws(()=>replay(f.evidence));});
test('protected meal removal remains forbidden',()=>{const f=creation({protectedMeal:true});assert.throws(()=>f.run(),e=>e.code==='food_undo_meal_protected');});
test('protected source removal remains forbidden even without a whole-meal flag',()=>{const f=creation({protectedSource:true});assert.throws(()=>f.run(),e=>e.code==='protected_share_changed');});
test('later dependency on created food blocks whole inverse',()=>{
 const f=creation(),edge={id:id(850),kind:'withinExisting',demandId:id(201),supplyId:f.current.graph.contributions[0].id,quantity:q(1),confirmation:{productMatchConfirmed:true,confirmedAt:at,evidence:'Later reviewed overlap'}};
 f.current.graph=apply(f.current.graph,change(f.current.graph,{edges:[edge]},301)).graph;f.current.shopRevision=4;
 assert.throws(()=>f.run());
});
test('exact replay validates original lineage without deriving or reapplying after a later edit',()=>{
 const f=creation();f.evidence.meal.latest={...f.evidence.meal.latest,revision:5,meal:null};f.evidence.alreadyReversed=true;
 assert.doesNotThrow(()=>replay(f.evidence));assert.throws(()=>f.run(),e=>e.code==='food_undo_already_reversed');
 f.evidence.operation.payload_digest='0'.repeat(64);assert.throws(()=>replay(f.evidence));
});
test('same-store boundary remains authoritative for created-meal compensation',()=>{
 const f=creation();f.evidence.before.snapshot.storeBasis={revision:1,reviewRequired:false};f.evidence.after.snapshot.storeBasis={revision:1,reviewRequired:false};
 for(const k of ['before','after'])f.evidence[k].digest=digest(f.evidence[k].snapshot);
 f.current.storeBasis={revision:1,reviewRequired:false};assert.throws(()=>f.run(),e=>e.code==='food_undo_store_action_unsupported');
});
test('meal-only creation has a genuine empty graph delta and nullable removal command',()=>{
 const f=creation(),g={...structuredClone(f.evidence.beforeGraph.graph),revision:2};
 f.evidence.afterGraph={graph:g,graph_digest:digest(g),receipt:{schemaVersion:1,operationId:id(300),householdId:g.householdId,shopId:g.shopId,baseRevision:1,resultRevision:2,lines:[],contributions:[],edges:[]}};
 f.current.graph=structuredClone(g);f.current.lines=structuredClone(f.evidence.before.snapshot.lines);
 f.evidence.after.snapshot.lines=structuredClone(f.current.lines);f.evidence.after.snapshot.budget=checkout(f.current.lines,f.quote);
 f.evidence.after.snapshot.demand={schemaVersion:1,revision:2,digest:digest(g)};f.evidence.after.digest=digest(f.evidence.after.snapshot);
 delete f.evidence.meal.after.meal.planning;f.evidence.meal.latest=structuredClone(f.evidence.meal.after);f.evidence.meal.lineage.afterDigest=digest(f.evidence.meal.after);
 const x=f.run();assert.equal(x.scope.graphRows,0);assert.deepEqual(x.scope.touchedLines,[]);assert.equal(x.action.body.mealEdit.meal,null);
 assert.deepEqual(x.result.receipt.contributions,[]);assert.equal(x.result.graph.revision,3);
});
test('creation cannot disguise removal of an unrelated accepted meal reference',()=>{
 const f=creation();f.evidence.after.snapshot.mealRefs=f.evidence.after.snapshot.mealRefs.filter(r=>r.occurrenceId!==id(830));
 f.evidence.after.digest=digest(f.evidence.after.snapshot);assert.throws(()=>f.run(),e=>e.code==='food_undo_meal_history_unavailable');
});
