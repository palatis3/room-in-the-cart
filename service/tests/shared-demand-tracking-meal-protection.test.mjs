import test from 'node:test';
import assert from 'node:assert/strict';
import {previewTrackingMealProtection,reviewedTrackingMealProtection} from '../dist/shared-demand-tracking-meal-protection.js';
import {preserveProtectedMeal} from '../dist/shared-meal-planning.js';
import {mealDemandSources} from '../dist/shared-demand-sources.js';
import {validateState,digest,coverage} from '../dist/shared-demand-tracking.js';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const at='2026-11-10T12:00:00Z';
const mq=(n,unit,literal)=>({amount:{numerator:n,denominator:1},unit,originalLiteral:literal});
const basis={sourceUnit:'gram',targetUnit:'count',targetAmountPerSourceUnit:{numerator:'1',denominator:'30'},sourceNote:'One reserved wrap weighs 30 grams',confirmedAt:at};
function fixture({location='transferred',group=false}={}){
 const original={title:'Protected lunch',day:null,kind:'lunch',portions:2,protected:!group,planning:{exclusions:['No nuts'],groups:group?[{id:id(5),name:'Lunch',servings:{numerator:2,denominator:1},protected:true}]:[],ingredients:[{id:id(4),name:'Wraps',quantity:mq(2,'count','two reserved wraps'),groupIds:group?[id(5)]:[],exclusions:['No sesame']}],...(group?{bindings:[{id:id(6),groupId:id(5),ingredientId:id(4),quantity:mq(2,'count','two reserved wraps')}]}:{})}};
 const next=structuredClone(original);next.planning.ingredients[0].quantity=mq(60,'gram','60 measured grams');if(group)next.planning.bindings[0].quantity=mq(60,'gram','60 measured grams');
 const fact=meal=>{const {productName,...f}=mealDemandSources(id(2),[{occurrenceId:id(3),meal}])[0];return{...f,revision:7};};
 const oldFact=fact(original),newFact={...fact(next),revision:8},row={id:oldFact.id,lineId:id(7),source:oldFact.source,productKey:'wraps',productName:'Wraps',originalText:oldFact.originalText,quantity:oldFact.quantity,sourceExclusions:oldFact.sourceExclusions,exclusions:[],contains:[],removedAt:null};
 const graph={schemaVersion:1,conversionTableVersion:'us-customary-metric-v1',householdId:id(1),shopId:id(2),revision:1,lines:[{id:id(7),name:'Wraps',unit:'count',originalOrder:0,trashedAt:location==='tracked'?null:at}],contributions:location==='tracked'?[row]:[],edges:[],usedIds:[id(7),oldFact.id]};
 const before={schemaVersion:2,authorityEpoch:3,privacyRevision:5,quoteDigest:'a'.repeat(64),graph,basket:location==='tracked'?[{id:id(7),name:'Wraps',packs:1,priceMinor:100,feeEligible:true}]:[],catalog:[oldFact],bindings:location==='tracked'?[{factId:oldFact.id,contributionId:row.id}]:[],unbound:location==='tracked'?[]:[{factId:oldFact.id,transferred:row}],legacyLineIds:[],packReviews:location==='tracked'?[{lineId:id(7),usablePerPack:{...oldFact.quantity,originalLiteral:'two per pack'},acceptUnresolved:true}]:[]};
 const after=structuredClone(before);after.graph.revision++;after.catalog=[newFact];const changed={...structuredClone(row),quantity:{...newFact.quantity,confirmedConversion:structuredClone(basis)}};
 if(location==='tracked')after.graph.contributions=[changed];else after.unbound[0].transferred=changed;
 validateState(before,before.catalog);validateState(after,after.catalog);
 return{original,next,before,after,changed};
}
for(const location of ['tracked','transferred'])test('reviewed protected '+location+' 2 count to 60 gram requires the exact source basis and preserves observations',()=>{
 const f=fixture({location}),before=digest(f.before),next=digest(f.next),after=digest(f.after);
 assert.throws(()=>preserveProtectedMeal(f.original,f.next),{code:'protected_meal'});
 assert.doesNotThrow(()=>previewTrackingMealProtection(f.before)(f.original,f.next,id(3)));
 assert.doesNotThrow(()=>reviewedTrackingMealProtection(f.before,f.after)(f.original,f.next,id(3)));
 assert.equal(digest(f.before),before);assert.equal(digest(f.after),after);assert.equal(digest(f.next),next);
 assert.equal(f.next.planning.ingredients[0].quantity.unit,'gram');assert.equal(f.before.catalog[0].quantity.unit,'count');
 if(location==='transferred')assert.deepEqual(coverage(f.after,f.after.catalog).allocatableUnboundFactIds,[]);
});
test('protected explicit group binding has its own reviewed identity and conversion',()=>{const f=fixture({group:true});assert.doesNotThrow(()=>reviewedTrackingMealProtection(f.before,f.after)(f.original,f.next,id(3)));const wrong=structuredClone(f.next);wrong.planning.bindings[0].groupId=id(55);assert.throws(()=>previewTrackingMealProtection(f.before)(f.original,wrong,id(3)),{code:'protected_meal'});});
for(const bad of ['missing','reducing','wrongDimension'])test('protected conversion rejects '+bad+' evidence at the reviewed comparison',()=>{const f=fixture(),row=f.after.unbound[0].transferred;if(bad==='missing')row.quantity.confirmedConversion=null;else if(bad==='reducing')row.quantity.confirmedConversion.targetAmountPerSourceUnit.denominator='60';else row.quantity.confirmedConversion.targetUnit='cup';assert.throws(()=>reviewedTrackingMealProtection(f.before,f.after)(f.original,f.next,id(3)),{code:'protected_quantity_reduced'});});
for(const bad of ['source','factId','contributionId','line','literal','amount','privacy','authority','shop','revision'])test('protected conversion rejects '+bad+' proof substitution',()=>{const f=fixture(),row=f.after.unbound[0].transferred;if(bad==='source')row.source.ingredientId=id(88);if(bad==='factId')f.after.unbound[0].factId=id(88);if(bad==='contributionId')row.id=id(88);if(bad==='line')row.lineId=id(88);if(bad==='literal')row.quantity.originalLiteral='different source observation';if(bad==='amount')row.quantity.amount.numerator='120';if(bad==='privacy')f.after.privacyRevision++;if(bad==='authority')f.after.authorityEpoch++;if(bad==='shop')f.after.graph.shopId=id(88);if(bad==='revision')f.after.graph.revision++;assert.throws(()=>reviewedTrackingMealProtection(f.before,f.after)(f.original,f.next,id(3)));});
for(const bad of ['remove','unprotect','portions','kind','ingredient','restriction','mealRestriction'])test('conversion review retains strict non-quantity protection: '+bad,()=>{const f=fixture();let next=structuredClone(f.next);if(bad==='remove')next=null;if(bad==='unprotect')next.protected=false;if(bad==='portions')next.portions=1;if(bad==='kind')next.kind='dinner';if(bad==='ingredient')next.planning.ingredients[0].name='Rice';if(bad==='restriction')next.planning.ingredients[0].exclusions=[];if(bad==='mealRestriction')next.planning.exclusions=[];assert.throws(()=>previewTrackingMealProtection(f.before)(f.original,next,id(3)),{code:'protected_meal'});assert.throws(()=>reviewedTrackingMealProtection(f.before,f.after)(f.original,next,id(3)),{code:'protected_meal'});});
test('catalog cannot defer a plain-unbound or wrong-occurrence protected unit change',()=>{const f=fixture();assert.throws(()=>previewTrackingMealProtection(f.before)(f.original,f.next,id(99)),{code:'protected_meal'});f.before.unbound[0].transferred=null;f.before.graph.usedIds=f.before.graph.usedIds.filter(x=>x!==f.before.catalog[0].id);validateState(f.before,f.before.catalog);assert.throws(()=>previewTrackingMealProtection(f.before)(f.original,f.next,id(3)),{code:'protected_meal'});});
test('catalog cannot defer ordinary same-unit reduction or a legacy first adoption',()=>{const f=fixture(),next=structuredClone(f.original);next.planning.ingredients[0].quantity=mq(1,'count','one wrap');assert.throws(()=>previewTrackingMealProtection(f.before)(f.original,next,id(3)),{code:'protected_meal'});f.before.graph.revision=0;assert.throws(()=>previewTrackingMealProtection(f.before));});

import {reviewedTrackingMealUndoProtection} from '../dist/shared-demand-tracking-meal-protection.js';
import {applyDemandChange,undoDemandChange,validateDetachedDemandInverse,validateDetachedDemandChanges} from '../dist/shared-demand-domain.js';
import {inverseMealPartition} from '../dist/shared-demand-tracking-meal-undo.js';
const command=(graph,n,contributions=[])=>({schemaVersion:1,operationId:id(n),householdId:graph.householdId,shopId:graph.shopId,baseRevision:graph.revision,at,lines:[],contributions,edges:[],removeSourceIds:[],removeEdgeIds:[]});
for(const location of ['tracked','transferred'])test('whole protected '+location+' Undo reuses recorded basis without changing original amount unit literal or conversion',()=>{
 const f=fixture({location}),original=digest(f.before),accepted=digest(f.after);let graph;
 if(location==='tracked'){
  const change=applyDemandChange(f.before.graph,command(f.before.graph,90,[f.changed]));assert.deepEqual(change.graph,f.after.graph);
  graph=undoDemandChange(f.after.graph,change.receipt,command(f.after.graph,91)).graph;
  assert.deepEqual(graph.contributions.find(x=>x.id===f.changed.id),f.before.graph.contributions[0]);
 }else graph={...f.after.graph,revision:f.after.graph.revision+1};
 const partition=inverseMealPartition(f.before,f.after,f.after,graph),restored=validateState({...f.before,graph,bindings:partition.bindings,unbound:partition.unbound},f.before.catalog);
 assert.doesNotThrow(()=>reviewedTrackingMealUndoProtection(f.after,restored,f.before,f.after)(f.next,f.original,id(3)));
 const row=location==='tracked'?restored.graph.contributions[0]:restored.unbound[0].transferred;
 assert.equal(row.quantity.confirmedConversion,null);assert.equal(row.quantity.unit,'count');assert.equal(row.quantity.amount.numerator,'2');assert.equal(row.quantity.originalLiteral,'two reserved wraps');
 assert.equal(digest(f.before),original);assert.equal(digest(f.after),accepted);
});
for(const bad of ['increase','missing','changedRecordedBasis','laterSourceChange','inventedRestoredBasis'])test('protected inverse rejects '+bad+' rather than fabricating an equivalent observation',()=>{
 const f=fixture(),current=structuredClone(f.after),restored={...structuredClone(f.before),graph:{...f.before.graph,revision:f.after.graph.revision+1}};
 if(bad==='increase'){for(const s of [f.after,current]){s.unbound[0].transferred.quantity.amount.numerator='90';s.catalog[0].quantity.amount.numerator='90';}f.next.planning.ingredients[0].quantity.amount.numerator=90;}
 if(bad==='missing'){for(const s of [f.after,current])s.unbound[0].transferred.quantity.confirmedConversion=null;}
 if(bad==='changedRecordedBasis')f.after.unbound[0].transferred.quantity.confirmedConversion.targetAmountPerSourceUnit.denominator='20';
 if(bad==='laterSourceChange')current.unbound[0].transferred.productKey='independently reviewed later';
 if(bad==='inventedRestoredBasis')restored.unbound[0].transferred.quantity.confirmedConversion={...basis,sourceNote:'Invented reverse evidence'};
 assert.throws(()=>reviewedTrackingMealUndoProtection(current,restored,f.before,f.after)(f.next,f.original,id(3)));
 if(bad==='laterSourceChange')assert.throws(()=>inverseMealPartition(f.before,f.after,current,restored.graph),{code:'tracking_meal_partition_conflict'});
});
test('tracked persisted-receipt inverse refuses true protected reduction and later touched row conflict',()=>{
 const f=fixture({location:'tracked'}),larger=structuredClone(f.changed);larger.quantity.amount.numerator='90';
 const increase=applyDemandChange(f.before.graph,command(f.before.graph,90,[larger]));assert.throws(()=>undoDemandChange(increase.graph,increase.receipt,command(increase.graph,91)),{code:'protected_quantity_reduced'});
 const equivalent=applyDemandChange(f.before.graph,command(f.before.graph,92,[f.changed])),later=structuredClone(equivalent.graph);later.contributions[0].quantity.confirmedConversion.sourceNote='Later independently reviewed evidence';
 assert.throws(()=>undoDemandChange(later,equivalent.receipt,command(later,93)),{code:'undo_conflict'});
});
test('inverse detached validator authenticates current against immutable accepted row before borrowing its basis',()=>{const f=fixture(),old=f.before.unbound[0].transferred,accepted=f.after.unbound[0].transferred;assert.doesNotThrow(()=>validateDetachedDemandInverse([accepted],[old],[accepted]));const altered=structuredClone(accepted);altered.quantity.confirmedConversion.sourceNote='Changed later';assert.throws(()=>validateDetachedDemandInverse([altered],[old],[accepted]),{code:'undo_conflict'});assert.equal(old.quantity.confirmedConversion,null);});
test('protected group-binding inverse restores its original explicit quantity without borrowing another group basis',()=>{const f=fixture({group:true}),restored={...structuredClone(f.before),graph:{...f.before.graph,revision:f.after.graph.revision+1}};assert.doesNotThrow(()=>reviewedTrackingMealUndoProtection(f.after,restored,f.before,f.after)(f.next,f.original,id(3)));const wrong=structuredClone(f.after);wrong.unbound[0].transferred.source.groupId=id(999);assert.throws(()=>reviewedTrackingMealUndoProtection(f.after,restored,f.before,wrong)(f.next,f.original,id(3)));});

for(const location of ['tracked','transferred'])for(const scenario of [{oldGrams:45,acceptedGrams:90,allowed:false},{oldGrams:15,acceptedGrams:60,allowed:true}])test('protected '+location+' inverse uses accepted basis over contradictory original '+scenario.oldGrams+' grams per count',()=>{
 const f=fixture({location}),original=location==='tracked'?f.before.graph.contributions[0]:f.before.unbound[0].transferred;
 // Do not mutate the authoritative catalog's null conversion through a shared
 // fixture object: these are independently reviewed contribution observations.
 original.quantity={...original.quantity,confirmedConversion:{sourceUnit:'count',targetUnit:'gram',targetAmountPerSourceUnit:{numerator:String(scenario.oldGrams),denominator:'1'},sourceNote:'Earlier recorded density',confirmedAt:at}};
 const accepted=location==='tracked'?f.after.graph.contributions[0]:f.after.unbound[0].transferred;
 accepted.quantity={...accepted.quantity,amount:{numerator:String(scenario.acceptedGrams),denominator:'1'},originalLiteral:scenario.acceptedGrams+' measured grams'};
 f.after.catalog[0].quantity={...f.after.catalog[0].quantity,amount:{numerator:String(scenario.acceptedGrams),denominator:'1'},originalLiteral:accepted.quantity.originalLiteral};
 f.next.planning.ingredients[0].quantity=mq(scenario.acceptedGrams,'gram',accepted.quantity.originalLiteral);
 assert.equal(f.before.catalog[0].quantity.confirmedConversion,null);validateState(f.before,f.before.catalog);validateState(f.after,f.after.catalog);
 assert.doesNotThrow(()=>reviewedTrackingMealProtection(f.before,f.after)(f.original,f.next,id(3)));
 const beforeHash=digest(f.before),afterHash=digest(f.after);
 let inverse;
 if(location==='tracked'){
  const applied=applyDemandChange(f.before.graph,command(f.before.graph,97,[accepted]));assert.deepEqual(applied.graph,f.after.graph);
  inverse=()=>undoDemandChange(f.after.graph,applied.receipt,command(f.after.graph,98)).graph;
 }else inverse=()=>{validateDetachedDemandInverse([accepted],[original],[accepted]);return{...f.after.graph,revision:f.after.graph.revision+1};};
 if(!scenario.allowed)assert.throws(inverse,{code:'protected_quantity_reduced'});
 else{
  const graph=inverse(),partition=inverseMealPartition(f.before,f.after,f.after,graph),restored=validateState({...f.before,graph,bindings:partition.bindings,unbound:partition.unbound},f.before.catalog);
  assert.doesNotThrow(()=>reviewedTrackingMealUndoProtection(f.after,restored,f.before,f.after)(f.next,f.original,id(3)));
  assert.deepEqual(location==='tracked'?restored.graph.contributions[0]:restored.unbound[0].transferred,original);
  // Ordinary new edits still use their newly proposed conversion; historical
  // inverse authority does not leak into the normal mutation policy.
  assert.throws(()=>validateDetachedDemandChanges([accepted],[original]),{code:'protected_quantity_reduced'});
 }
 assert.equal(digest(f.before),beforeHash);assert.equal(digest(f.after),afterHash);
});
test('receipt inverse cannot fall back to original conversion when accepted cross-unit basis is absent',()=>{
 const f=fixture({location:'tracked'}),original=f.before.graph.contributions[0];original.quantity={...original.quantity,confirmedConversion:{sourceUnit:'count',targetUnit:'gram',targetAmountPerSourceUnit:{numerator:'45',denominator:'1'},sourceNote:'Earlier density',confirmedAt:at}};
 const applied=applyDemandChange(f.before.graph,command(f.before.graph,97,[f.changed])),current=structuredClone(applied.graph),receipt=structuredClone(applied.receipt);
 current.contributions[0].quantity.confirmedConversion=null;receipt.contributions[0].after.quantity.confirmedConversion=null;
 assert.throws(()=>undoDemandChange(current,receipt,command(current,98)),{code:'protected_quantity_reduced'});
});
