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

export {mealSetup,id,q,at,now};
