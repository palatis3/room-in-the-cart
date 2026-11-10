import test from 'node:test';
import assert from 'node:assert/strict';
import {recordCompoundAdoption,inverseCompoundAdoptionPartition} from '../dist/shared-demand-compound-adoption.js';
import {deriveMealUndo} from '../dist/shared-food-meal-undo.js';
import {mealCreationAbsence} from '../dist/shared-food-meal-creation-undo.js';
import {mealDemandSources} from '../dist/shared-demand-sources.js';
import {applyDemandChange} from '../dist/shared-demand-domain.js';
import {digest,validateState} from '../dist/shared-demand-tracking.js';
import {digest as storedDigest} from '../dist/database.js';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const H=id(1),S=id(2),OP=id(3),actor=id(4),occurrence=id(40),at='2026-11-10T12:00:00.000Z';
const quantity=n=>({amount:{numerator:n,denominator:1},unit:'count',originalLiteral:`${n} exact wraps`});
const food=n=>({amount:{numerator:String(n),denominator:'1'},unit:'count',originalLiteral:`${n} reviewed wraps`,confirmedConversion:null});
const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:'2026-11-09T12:00:00Z',expiresAt:'2026-11-11T12:00:00Z'};
const meal=(title,ingredient,n,protectedMeal=false)=>({title,day:null,kind:protectedMeal?'lunch':'dinner',portions:2,protected:protectedMeal,
 planning:{groups:[],ingredients:[{id:ingredient,name:'Wraps',quantity:n===null?null:quantity(n),groupIds:[],exclusions:[]}]}});
const row=(meal,revision)=>({householdId:H,shopId:S,occurrenceId:occurrence,revision,actorId:actor,meal});
const catalog=ms=>mealDemandSources(S,ms).map(({productName,...x})=>({...x,revision:ms.find(m=>m.occurrenceId===(x.source.kind==='meal'?x.source.occurrenceId:x.source.originOccurrenceId)).revision}));
function setup({kind='quantity',laterTitle=false,unknownLunch=false,proposal=null}={}){
 const lunch={occurrenceId:id(50),revision:1,meal:meal('Protected lunch',id(51),unknownLunch?null:2,true)};
 const oldMeal=meal('Tacos',id(41),6),nextMeal=kind==='creation'?meal('New dinner',id(41),4):kind==='quantity'?meal('Tacos',id(41),4):{...oldMeal,day:'2026-11-12'};
 const beforeMeal=kind==='creation'?null:row(oldMeal,2),afterMeal=row(nextMeal,3),latest=laterTitle?row({...nextMeal,title:'Later independent title'},4):structuredClone(afterMeal);
 const scope={householdId:H,shopId:S,operationId:OP,baseShopRevision:2,resultShopRevision:3};
 const beforeMeals=[lunch,...beforeMeal?[{occurrenceId:occurrence,revision:2,meal:oldMeal}]:[]],afterMeals=[lunch,{occurrenceId:occurrence,revision:3,meal:nextMeal}];
 const absence=storedDigest(mealCreationAbsence(scope,occurrence));
 const lineage={householdId:H,shopId:S,operationId:OP,occurrenceId:occurrence,beforeRevision:beforeMeal?2:null,afterRevision:3,
  beforeDigest:beforeMeal?storedDigest(beforeMeal):absence,afterDigest:storedDigest(afterMeal),proposalKind:proposal,proposalId:proposal?id(70):null,proposalDigest:proposal?'f'.repeat(64):null};
 const firstUse={householdId:H,shopId:S,occurrenceId:occurrence,operationId:OP,resultShopRevision:3};
 const evidence={lineage,before:beforeMeal,after:afterMeal,latest,proposal:proposal?{kind:proposal,proposalId:id(70),digest:'f'.repeat(64),applied:true,actorId:id(71)}:null,authorsLive:true,
  ...kind==='creation'?{creation:{firstUse,acceptance:{...firstUse,baseShopRevision:2,absenceDigest:absence}}}:{}};
 const blank={schemaVersion:1,conversionTableVersion:'us-customary-metric-v1',householdId:H,shopId:S,revision:0,lines:[],contributions:[],edges:[],usedIds:[]};
 const beforeCatalog=catalog(beforeMeals),afterCatalog=catalog(afterMeals),line={id:id(10),name:'Wraps',unit:'count',originalOrder:0,trashedAt:null};
 const manual={id:id(20),lineId:line.id,source:{kind:'manual'},productKey:'wraps',productName:'Wraps',originalText:'Manually entered twelve',quantity:food(12),sourceExclusions:[],exclusions:[],contains:[],removedAt:null};
 const contributions=[manual,...afterCatalog.map(f=>({id:f.id,lineId:line.id,source:f.source,productKey:'wraps',productName:f.originalText,originalText:f.originalText,quantity:f.quantity,sourceExclusions:f.sourceExclusions,exclusions:[],contains:[],removedAt:null}))];
 const adopted=applyDemandChange(blank,{schemaVersion:1,operationId:OP,householdId:H,shopId:S,baseRevision:0,at,lines:[line],contributions,edges:[],removeSourceIds:[],removeEdgeIds:[]});
 const before={schemaVersion:2,authorityEpoch:1,privacyRevision:2,quoteDigest:storedDigest(quote),graph:blank,basket:[{id:line.id,name:line.name,packs:2,priceMinor:100,feeEligible:true}],catalog:beforeCatalog,bindings:[],unbound:beforeCatalog.map(f=>({factId:f.id,transferred:null})),legacyLineIds:[line.id],packReviews:[]};
 const after={...structuredClone(before),graph:adopted.graph,basket:[{...before.basket[0],packs:3}],catalog:afterCatalog,bindings:afterCatalog.map(f=>({factId:f.id,contributionId:f.id})),unbound:[],legacyLineIds:[],packReviews:[{lineId:line.id,usablePerPack:null,acceptUnresolved:true}]};
 const record=recordCompoundAdoption(OP,before,after,quote,quote,{kind:'meal',occurrenceId:occurrence,componentDigest:storedDigest(lineage)});
 const current=structuredClone(after);current.graph.revision++;current.basket[0].priceMinor=125;
 current.catalog=catalog([lunch,{occurrenceId:occurrence,revision:latest.revision,meal:latest.meal}]);validateState(current,current.catalog);
 function run(){
  const inverse=deriveMealUndo(evidence,scope,beforeMeals.map(m=>({occurrenceId:m.occurrenceId,revision:m.revision})),afterMeals.map(m=>({occurrenceId:m.occurrenceId,revision:m.revision})),latest.revision);
  const restoredMeals=[lunch,...inverse.restoredMeal?[{occurrenceId:occurrence,revision:latest.revision+1,meal:inverse.restoredMeal}]:[]];
  const result=inverseCompoundAdoptionPartition(record.evidence,current,{operationId:id(90),targetOperationId:OP,evidenceDigest:record.evidenceDigest,
   householdId:H,shopId:S,baseRevision:current.graph.revision,authorityEpoch:1,privacyRevision:2,at},quote,catalog(restoredMeals),new Date(at));
  return{inverse,...result};
 }
 return{run,evidence,record,before,after,current,lunch};
}
for(const kind of ['creation','quantity','day'])test(`complete adoption with meal ${kind} reverses food and exact meal together`,()=>{
 const f=setup({kind}),r=f.run();assert.equal(r.state.basket[0].packs,2);assert.equal(r.state.basket[0].priceMinor,125);
 assert.equal(r.state.graph.contributions.find(c=>c.id===id(20)).removedAt,at);
 const lunch=r.state.catalog.find(f=>f.source.kind==='reservation');assert.equal(lunch.quantity.amount.numerator,'2');
 assert.equal(r.state.unbound.find(u=>u.factId===lunch.id).transferred.quantity.amount.numerator,'2');
 if(kind==='creation'){assert.equal(r.inverse.restoredMeal,null);assert.equal(r.state.catalog.some(f=>f.source.kind==='meal'),false);}
 else{const fact=r.state.catalog.find(f=>f.source.kind==='meal');assert.equal(fact.quantity.amount.numerator,'6');
  assert.equal(r.inverse.restoredMeal.day,null);if(kind==='quantity')assert.equal(r.state.unbound.find(u=>u.factId===fact.id).transferred,null);}
 assert.equal(r.disclosure.afterCoverage.status,'partial');assert.deepEqual(r.state.graph.usedIds,f.current.graph.usedIds);
});
for(const proposal of ['change','move'])test(`accepted ${proposal} proposal remains applied while untouched later title survives day compensation`,()=>{
 const f=setup({kind:'day',laterTitle:true,unknownLunch:true,proposal}),r=f.run();
 assert.equal(r.inverse.restoredMeal.title,'Later independent title');assert.equal(r.inverse.restoredMeal.day,null);
 assert.deepEqual(r.inverse.proposal,{kind:proposal,proposalId:id(70)});assert.equal(f.evidence.proposal.applied,true);
 const lunch=r.state.catalog.find(x=>x.source.kind==='reservation');assert.equal(lunch.quantity,null);
 assert.deepEqual(r.disclosure.afterCoverage.protectedUnboundFactIds,[lunch.id]);
});
test('a post-adoption touched meal field or revoked proposal author rejects the whole operation',()=>{
 const f=setup({kind:'day',proposal:'move'});f.evidence.latest.meal.day='2026-11-13';assert.throws(()=>f.run());
 const g=setup({kind:'day',proposal:'change'});g.evidence.authorsLive=false;assert.throws(()=>g.run());
 const h=setup({kind:'creation'});h.evidence.creation.firstUse.operationId=id(99);assert.throws(()=>h.run());
});
