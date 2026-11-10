import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {deriveSharedFoodUndo as undo,assertSharedFoodUndoReplay as replay} from '../dist/shared-food-operation-undo.js';
import {applyDemandChange as apply} from '../dist/shared-demand-domain.js';
import {digest} from '../dist/database.js';
import {checkout} from '../dist/checkout.js';
import {foodUndoCandidateSchema,foodUndoInputSchema,previewDemand} from '../dist/shared-demand-repository.js';
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
const fails=(f,code)=>assert.throws(()=>f.run(),e=>e.code===code);
test('complete inverse restores target graph, packs and quote while later staple and untouched price survive',()=>{
 const f=setup(),line={id:id(700),name:'Later staple',unit:'count',originalOrder:9,trashedAt:null};
 const staple={...f.added,id:id(701),lineId:line.id,productKey:'staple',productName:'Staple',originalText:'later staple',quantity:q(1)};
 f.current.graph=apply(f.current.graph,change(f.current.graph,{lines:[line],contributions:[staple]},301)).graph;
 const later={lineId:line.id,originalItem:line.name,packs:1,unitPriceMinor:200,feeEligible:false};f.current.lines.push(later);f.current.lines[0].unitPriceMinor=150;
 const before=structuredClone(f.current);const x=f.run();
 assert.equal(x.action.body.lines[0].packs,2);assert.equal(x.action.body.lines[0].unitPriceMinor,150);assert.deepEqual(x.action.body.lines[1],later);assert.deepEqual(x.action.body.quote,f.quote);
 assert.deepEqual(x.result.graph.contributions.find(c=>c.id===staple.id),staple);assert.equal(x.result.graph.contributions.find(c=>c.id===f.added.id).removedAt,at);
 assert.equal(x.result.graph.contributions[0].quantity.amount.numerator,'12');assert.equal(x.scope.graphRows,1);assert.equal(x.afterCheckout.totalMinor,500);
 assert.deepEqual(f.current,before,'derivation does not mutate current state');
});
test('later touched pack edit conflicts; no partial inverse',()=>{const f=setup();f.current.lines[0].packs=4;fails(f,'food_undo_line_conflict');});
test('later touched graph row conflicts',()=>{const f=setup();f.current.graph.contributions.find(c=>c.id===f.added.id).originalText='later edit';fails(f,'undo_conflict');});
test('quote provenance is atomic and later quote change conflicts',()=>{const f=setup();f.current.quote={...f.current.quote,taxesMinor:1};fails(f,'food_undo_quote_conflict');});
test('expired restored quote fails, including exact expiry boundary',()=>{const f=setup();f.evidence.before.snapshot.quote.expiresAt=now.toISOString();f.evidence.before.digest=digest(f.evidence.before.snapshot);fails(f,'food_undo_expired_quote');});
test('pack-only operation has a real empty graph review receipt, not a fabricated delta',()=>{const f=setup({graphChange:false,quoteChange:false});const x=f.run();assert.equal(x.action.body.lines[0].packs,2);assert.deepEqual(x.result.receipt.contributions,[]);assert.equal(x.result.graph.revision,3);assert.equal(x.scope.graphRows,0);});
test('request acceptance never becomes graph-only Undo',()=>{const f=setup();f.evidence.operation.kind='request.apply';fails(f,'food_undo_request_acceptance_unsupported');});
for(const scope of ['first_adoption','meal_action','store_action','missing_snapshot'])test(scope+' has an explicit unsupported result',()=>{const f=setup();f.evidence.effect.classification=scope;fails(f,'food_undo_'+scope+'_unsupported');});
test('historical operation without new complete effect evidence is unavailable',()=>{const f=setup();f.evidence.effect=null;fails(f,'food_undo_history_unavailable');});
test('later removal/recreation of a meal cannot evade unsupported meal scope',()=>{const f=setup();f.evidence.after.snapshot.mealRefs=[{occurrenceId:id(22),revision:3}];f.evidence.after.digest=digest(f.evidence.after.snapshot);fails(f,'food_undo_meal_action_unsupported');});
test('privacy erase blocks both initial inverse and replay without cached-preimage fallback',()=>{
 for(const mutate of [e=>{e.operation.payload_digest='0'.repeat(64);},e=>{e.before.digest='0'.repeat(64);},e=>{e.afterGraph.graph_digest=null;},e=>{e.afterGraph.receipt=null;}]){
  const f=setup();mutate(f.evidence);assert.throws(()=>f.run());assert.throws(()=>replay(f.evidence));
 }
});
test('already reversed blocks a fresh inverse but valid exact replay lineage is readable',()=>{const f=setup();f.evidence.alreadyReversed=true;fails(f,'food_undo_already_reversed');assert.doesNotThrow(()=>replay(f.evidence));});
test('inverse-of-inverse is explicitly unsupported',()=>{const f=setup();f.evidence.effect.reverses_operation_id=id(299);fails(f,'food_undo_inverse_operation_unsupported');});
test('receipt omitting an actual historical graph effect fails closed',()=>{const f=setup();f.evidence.afterGraph.receipt.contributions=[];fails(f,'food_undo_history_unavailable');});
test('cross-shop evidence fails before inverse disclosure',()=>{const f=setup();f.command.shopId=id(899);fails(f,'food_undo_history_unavailable');});
test('candidate digest is deterministic across new operation ids and binds exact current facts',()=>{const f=setup();const a=f.run();f.command.operationId=id(901);assert.equal(f.run().effectDigest,a.effectDigest);f.current.lines[0].unitPriceMinor=101;assert.notEqual(f.run().effectDigest,a.effectDigest);});
test('request schema cannot smuggle preimages, actions, receipts or an Apply token',()=>{
 const f=setup(),input={targetOperationId:id(300),base:{shopRevision:3,authorityEpoch:1,graphRevision:2,graphDigest:digest(f.current.graph)}};
 assert.equal(foodUndoCandidateSchema.parse(input).targetOperationId,input.targetOperationId);
 for(const k of ['action','receipt','before','quote','previewId'])assert.throws(()=>foodUndoCandidateSchema.parse({...input,[k]:{}}));
 assert.throws(()=>foodUndoInputSchema.parse({...input,packs:[]}));assert.equal(foodUndoInputSchema.parse({...input,effectDigest:f.run().effectDigest,packs:[]}).packs.length,0);
});
test('existing arbitrary preview endpoint cannot impersonate a server-derived inverse',async()=>{
 const f=setup();await assert.rejects(()=>previewDemand({}, {}, {}, {mode:'operationUndo',base:{shopRevision:3,authorityEpoch:1,graphRevision:2},change:empty(),undoOperationId:id(300),operationUndoDigest:f.run().effectDigest,action:{kind:'shop.patch',body:f.run().action.body},packs:[]}),e=>e.code==='operation_undo_endpoint_required');
});

for(const expired of [false,true])test('historical price cannot borrow a later fresh quote, old expired='+expired,()=>{
 const f=setup({graphChange:false,quoteChange:false});
 if(expired){f.evidence.before.snapshot.quote.expiresAt=now.toISOString();f.evidence.after.snapshot.quote.expiresAt=now.toISOString();}
 f.evidence.after.snapshot.lines[0].unitPriceMinor=150;f.current.lines[0].unitPriceMinor=150;
 for(const row of [f.evidence.before,f.evidence.after]){row.snapshot.budget=checkout(row.snapshot.lines,row.snapshot.quote);row.digest=digest(row.snapshot);}
 f.current.quote={...f.current.quote,observedAt:now.toISOString(),expiresAt:'2026-11-09T18:00:00.000Z'};
 fails(f,'food_undo_quote_conflict');
});
test('restoring a removed historical line cannot borrow current quote provenance',()=>{
 const f=setup({graphChange:false,quoteChange:false}),before=f.evidence.beforeGraph.graph;
 const target=apply(before,change(before,{removeSourceIds:[before.contributions[0].id]}));
 f.evidence.afterGraph={graph:target.graph,graph_digest:digest(target.graph),receipt:target.receipt};
 f.evidence.after.snapshot.lines=[];f.evidence.after.snapshot.demand.digest=digest(target.graph);
 f.evidence.after.snapshot.budget=checkout([],f.evidence.after.snapshot.quote);f.evidence.after.digest=digest(f.evidence.after.snapshot);
 f.current.graph=target.graph;f.current.lines=[];f.current.quote={...f.current.quote,observedAt:now.toISOString(),expiresAt:'2026-11-09T18:00:00.000Z'};
 fails(f,'food_undo_quote_conflict');
});

for(const basisField of ['observedAt','expiresAt'])for(const later of ['price','priced staple'])test('restored quote basis rejects later '+later+' after '+basisField+' refresh',()=>{
 const f=setup({graphChange:false,quoteChange:false});
 const newer=basisField==='observedAt'?'2026-11-09T12:30:00.000Z':'2026-11-09T18:00:00.000Z';
 f.evidence.after.snapshot.quote={...f.evidence.after.snapshot.quote,[basisField]:newer};f.evidence.after.digest=digest(f.evidence.after.snapshot);f.current.quote=structuredClone(f.evidence.after.snapshot.quote);
 if(later==='price')f.current.lines[0].unitPriceMinor=150;
 else{
  const line={id:id(710),name:'New priced staple',unit:'count',originalOrder:10,trashedAt:null};
  const staple={...f.added,id:id(711),lineId:line.id,productKey:'staple',productName:'Staple',originalText:'New priced staple',quantity:q(1)};
  f.current.graph=apply(f.current.graph,change(f.current.graph,{lines:[line],contributions:[staple]},302)).graph;
  f.current.lines.push({lineId:line.id,originalItem:line.name,packs:1,unitPriceMinor:250,feeEligible:false});
 }
 const untouched=structuredClone(f.current);fails(f,'food_undo_quote_conflict');assert.deepEqual(f.current,untouched,'conflict preserves all later work');
});
test('restored quote basis remains eligible when its accepted pricing facts are unchanged',()=>{
 const f=setup({graphChange:false,quoteChange:false});f.evidence.after.snapshot.quote={...f.evidence.after.snapshot.quote,observedAt:'2026-11-09T12:30:00.000Z',expiresAt:'2026-11-09T18:00:00.000Z'};f.evidence.after.digest=digest(f.evidence.after.snapshot);f.current.quote=structuredClone(f.evidence.after.snapshot.quote);
 const result=f.run();assert.deepEqual(result.action.body.quote,f.evidence.before.snapshot.quote);assert.equal(result.action.body.lines[0].packs,2);
});
test('quote basis inversion preserves a later untouched pack count with unchanged pricing facts',()=>{
 const f=setup({graphChange:false,quoteChange:false});f.evidence.after.snapshot.lines[0].packs=2;
 f.evidence.after.snapshot.quote={...f.evidence.after.snapshot.quote,observedAt:'2026-11-09T12:30:00.000Z',expiresAt:'2026-11-09T18:00:00.000Z'};
 f.evidence.after.snapshot.budget=checkout(f.evidence.after.snapshot.lines,f.evidence.after.snapshot.quote);f.evidence.after.digest=digest(f.evidence.after.snapshot);
 f.current.quote=structuredClone(f.evidence.after.snapshot.quote);f.current.lines[0].packs=4;
 const result=f.run();assert.equal(result.action.body.lines[0].packs,4);assert.deepEqual(result.action.body.quote,f.evidence.before.snapshot.quote);assert.deepEqual(result.scope.touchedLines,[]);
});

function mealSetup({removed=false}={}){
 const f=setup({graphChange:false,quoteChange:false}),occurrence=id(820),actor=id(821);
 // A genuine date-only complete operation changes no food graph, basket or quote.
 f.evidence.after.snapshot.lines=structuredClone(f.evidence.before.snapshot.lines);
 f.evidence.after.snapshot.budget=checkout(f.evidence.after.snapshot.lines,f.quote);
 f.current.lines=structuredClone(f.evidence.before.snapshot.lines);f.current.shopRevision=3;
 const meal={title:'Tacos',day:'2026-11-08',kind:'dinner',portions:6,protected:false};
 const row=(revision,value)=>({householdId:f.command.householdId,shopId:f.command.shopId,occurrenceId:occurrence,revision,actorId:actor,meal:value});
 const before=row(2,meal),after=row(3,removed?null:{...meal,day:'2026-11-09'});
 f.evidence.effect.classification='meal_action';
 f.evidence.meal={lineage:{householdId:f.command.householdId,shopId:f.command.shopId,operationId:id(300),occurrenceId:occurrence,
  beforeRevision:2,afterRevision:3,beforeDigest:digest(before),afterDigest:digest(after),proposalKind:null,proposalId:null,proposalDigest:null},
  before,after,latest:structuredClone(after),proposal:null,authorsLive:true};
 f.evidence.before.snapshot.mealRefs=[{occurrenceId:occurrence,revision:2}];
 if(!removed)f.evidence.after.snapshot.mealRefs=[{occurrenceId:occurrence,revision:3}];
 f.rehash=()=>{for(const key of ['before','after']){f.evidence[key].digest=digest(f.evidence[key].snapshot);f.evidence.meal.lineage[key+'Digest']=digest(f.evidence.meal[key]);}};
 f.rehash();return f;
}
test('existing meal date-only Undo exposes exact complete facts and no fictitious graph changes',()=>{
 const f=mealSetup(),before=structuredClone(f.evidence),x=f.run(),m=f.evidence.meal;
 assert.equal(x.scope.mealsChanged,true);assert.equal(x.scope.requestsChanged,false);
 assert.equal(x.scope.graphRows,0);assert.deepEqual(x.scope.touchedLines,[]);assert.equal(x.scope.quoteChanged,false);
 assert.deepEqual(x.mealUndo.touchedFields,['day']);assert.deepEqual(x.mealUndo.current,{revision:3,meal:m.after.meal});
 assert.deepEqual(x.action.body.mealEdit,{occurrenceId:m.lineage.occurrenceId,baseMealRevision:3,meal:m.before.meal});
 assert.equal(x.result.graph.revision,3);assert.deepEqual(x.result.receipt.contributions,[]);
 assert.deepEqual(f.evidence,before,'candidate derivation mutates neither historical nor current facts');
 const plain=setup().run();assert.equal('mealUndo' in plain,false);assert.equal('mealEdit' in plain.action.body,false);
});
test('meal inverse retains later untouched title while using the exact latest revision',()=>{
 const f=mealSetup();f.current.shopRevision=4;f.evidence.meal.latest.revision=4;f.evidence.meal.latest.meal.title='Later title';
 const x=f.run();assert.equal(x.action.body.mealEdit.baseMealRevision,4);
 assert.deepEqual(x.action.body.mealEdit.meal,{...f.evidence.meal.before.meal,title:'Later title'});
});
test('touched meal field conflict rejects the entire inverse without changing later facts',()=>{
 const f=mealSetup();f.current.shopRevision=4;f.evidence.meal.latest.revision=4;f.evidence.meal.latest.meal.day='2026-11-10';
 const old=structuredClone(f.evidence.meal);fails(f,'food_undo_meal_conflict');assert.deepEqual(f.evidence.meal,old);
});
test('date and civil deadline restore together; a later planning change is not overwritten',()=>{
 const f=mealSetup(),m=f.evidence.meal;
 m.before.meal.planning={groups:[],ingredients:[],deadline:{at:'2026-11-08T18:00:00-05:00',zone:'America/New_York'}};
 m.after.meal.planning={groups:[],ingredients:[]};m.latest=structuredClone(m.after);f.rehash();
 assert.deepEqual(f.run().action.body.mealEdit.meal,m.before.meal);
 m.latest.meal.planning.leadTimeMinutes=90;m.latest.revision=4;f.current.shopRevision=4;
 fails(f,'food_undo_meal_conflict');
});
test('skip Undo requires the exact accepted null tombstone, not merely active-list absence',()=>{
 const f=mealSetup({removed:true}),x=f.run();
 assert.equal(x.mealUndo.targetAfter.meal,null);assert.equal(x.mealUndo.current.meal,null);
 assert.deepEqual(x.mealUndo.touchedFields,['membership']);assert.equal(x.action.body.mealEdit.baseMealRevision,null);
 assert.deepEqual(x.action.body.mealEdit.meal,f.evidence.meal.before.meal);
 f.evidence.meal.latest.revision=5;f.current.shopRevision=5;fails(f,'food_undo_meal_conflict');
 f.evidence.meal.latest.meal=structuredClone(f.evidence.meal.before.meal);fails(f,'food_undo_meal_conflict');
});
test('meal preview digest binds latest revision even when currently displayed meal facts match',()=>{
 const f=mealSetup(),first=f.run().effectDigest;f.command.operationId=id(901);assert.equal(f.run().effectDigest,first);
 f.evidence.meal.latest.revision=4;f.current.shopRevision=4;assert.notEqual(f.run().effectDigest,first);
});
test('existing protected meal portions cannot be reduced by an inverse',()=>{
 const f=mealSetup(),m=f.evidence.meal;
 m.before.meal.protected=true;m.after.meal={...m.before.meal,portions:8};m.latest=structuredClone(m.after);f.rehash();
 fails(f,'food_undo_meal_protected');
});
test('missing, changed or revoked historical meal facts reject both candidate and exact replay',()=>{
 for(const mutate of [
  m=>{m.before=null;},m=>{m.after=null;},m=>{m.before.meal.title='Changed historical text';},
  m=>{m.after.meal=null;},m=>{m.authorsLive=false;},m=>{m.lineage.occurrenceId=id(999);}
 ]){
  const f=mealSetup();mutate(f.evidence.meal);assert.throws(()=>f.run());assert.throws(()=>replay(f.evidence));
 }
});
test('proposal-backed meal compensation retains provenance and never resends consumed proposal IDs',()=>{
 const f=mealSetup(),m=f.evidence.meal;
 m.lineage.proposalKind='change';m.lineage.proposalId=id(830);m.lineage.proposalDigest='b'.repeat(64);
 m.proposal={kind:'change',proposalId:id(830),digest:'b'.repeat(64),applied:true,actorId:id(831)};
 const x=f.run();assert.deepEqual(x.mealUndo.proposal,{kind:'change',proposalId:id(830)});
 assert.equal('proposalId' in x.action.body.mealEdit,false);assert.equal('changeProposalId' in x.action.body.mealEdit,false);
 m.latest={...m.latest,revision:4,meal:structuredClone(m.before.meal)};assert.doesNotThrow(()=>replay(f.evidence));
 for(const proof of [null,{...m.proposal,applied:false},{...m.proposal,digest:'c'.repeat(64)}]){
  m.proposal=proof;assert.throws(()=>replay(f.evidence));
 }
});
test('a changed unrelated historical meal reference cannot be silently omitted from complete compensation',()=>{
 const f=mealSetup();f.evidence.before.snapshot.mealRefs.push({occurrenceId:id(840),revision:1});
 f.evidence.after.snapshot.mealRefs.push({occurrenceId:id(840),revision:3});f.rehash();
 fails(f,'food_undo_meal_history_unavailable');
});
test('new-meal creation and unrecorded old meal effects remain explicitly unsupported',()=>{
 const f=mealSetup();delete f.evidence.meal;fails(f,'food_undo_meal_action_unsupported');
});
