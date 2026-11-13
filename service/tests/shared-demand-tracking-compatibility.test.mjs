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
test('existing complete-operation inverse accepts exact additive tracking snapshot reference',()=>{const f=setup(),expected=f.run();for(const x of [f.evidence.before,f.evidence.after]){x.snapshot.tracking={schemaVersion:2,shopRevision:x.snapshot.revision,digest:'a'.repeat(64),status:'recorded'};x.digest=digest(x.snapshot);}const actual=f.run();assert.notEqual(actual.effectDigest,expected.effectDigest,'added metadata is bound by the snapshot digest');const {effectDigest:a,...av}=actual,{effectDigest:b,...bv}=expected;assert.deepEqual(av,bv);});
test('wrong-revision tracking metadata cannot qualify an ordinary historical snapshot',()=>{const f=setup();f.evidence.before.snapshot.tracking={schemaVersion:2,shopRevision:99,digest:'a'.repeat(64),status:'recorded'};f.evidence.before.digest=digest(f.evidence.before.snapshot);fails(f,'food_undo_history_unavailable');});
test('redacted/partial reference cannot silently pass the v1 whole-operation snapshot schema',()=>{const f=setup();f.evidence.before.snapshot.tracking={schemaVersion:2,shopRevision:2,digest:null,status:'reviewRequired'};f.evidence.before.digest=digest(f.evidence.before.snapshot);fails(f,'food_undo_history_unavailable');});
