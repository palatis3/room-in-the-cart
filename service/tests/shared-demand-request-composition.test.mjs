import test from 'node:test';
import assert from 'node:assert/strict';
import {fixture,id,at,now,q,line,source,command} from './shared-demand-request-composition-fixture.mjs';
import {derivePartitionedRequestUndo as derive,validatePartitionedRequestAcceptanceHistory as validateHistory,
 deriveCompoundRequestUndo,validateCompoundRequestAcceptanceHistory} from '../dist/shared-demand-request-composition.js';
import {recordCompoundAdoption} from '../dist/shared-demand-compound-adoption.js';
import {requestAcceptanceComponentDigest} from '../dist/shared-request-acceptance-undo.js';
import {applyDemandChange} from '../dist/shared-demand-domain.js';
import {validateState,digest,coverage} from '../dist/shared-demand-tracking.js';
import {digest as storeDigest} from '../dist/database.js';
import {checkout} from '../dist/checkout.js';
const clone=structuredClone;
const basket=ls=>ls.map(l=>({id:l.lineId,name:l.originalItem,packs:l.packs,priceMinor:l.unitPriceMinor,feeEligible:l.feeEligible})).sort((a,b)=>a.id.localeCompare(b.id));
function setup({choice='link',position='bound',unboundLunch=false,carried=false,ownQuantity='Two original wraps'}={}){
 const f=fixture({kind:'legacy',choice,carried,ownQuantity}),catalog=clone(f.current.food.catalog);
 const lunch={...source(31,id(20),catalog[0].source,q(2)),originalText:catalog[0].originalText};
 const manual=source(30,id(20),{kind:'manual'},q(12));
 const empty={schemaVersion:1,conversionTableVersion:'us-customary-metric-v1',householdId:id(100),shopId:id(101),revision:0,lines:[],contributions:[],edges:[],usedIds:[]};
 const g=applyDemandChange(empty,command(empty,{lines:f.current.lines.map((l,i)=>line(Number(l.lineId.slice(-12)),l.originalItem,i)),
  contributions:[manual,...unboundLunch?[]:[lunch],f.requestSource],edges:choice==='link'?[{id:id(41),kind:'withinExisting',demandId:f.requestSource.id,supplyId:manual.id,quantity:q(2),confirmation:{productMatchConfirmed:true,confirmedAt:at,evidence:'Same request within twelve'}}]:[]},310)).graph;
 let state={schemaVersion:2,authorityEpoch:1,privacyRevision:2,quoteDigest:storeDigest(f.current.quote),graph:g,basket:basket(f.current.lines),catalog,
  bindings:[...unboundLunch?[]:[{factId:catalog[0].id,contributionId:lunch.id}],{factId:f.targetFact.id,contributionId:f.requestSource.id}],
  unbound:unboundLunch?[{factId:catalog[0].id,transferred:null}]:[],legacyLineIds:[],packReviews:g.lines.map(l=>({lineId:l.id,usablePerPack:null,acceptUnresolved:true}))};
 validateState(state,catalog);
 const snapshot={shopId:id(101),revision:6,phase:'draft',storeBasis:{revision:null,reviewRequired:false},mealRefs:clone(f.current.mealRefs),quote:clone(f.current.quote),lines:clone(f.current.lines),budget:checkout(f.current.lines,f.current.quote),
  demand:{schemaVersion:1,revision:g.revision,digest:storeDigest(g)},tracking:{schemaVersion:2,shopRevision:6,digest:digest(state),status:'recorded'}};
 const mapping={operationId:id(310),shopRevision:6,authorityEpoch:1,state:clone(state),stateDigest:digest(state),snapshotOperationId:id(310),snapshot,snapshotDigest:storeDigest(snapshot)};
 if(position!=='bound'){
  state.graph.contributions=state.graph.contributions.filter(x=>x.id!==f.requestSource.id);state.graph.edges=[];
  state.bindings=state.bindings.filter(x=>x.factId!==f.targetFact.id);
  state.unbound.push({factId:f.targetFact.id,transferred:position==='transferred'?clone(f.requestSource):null});
  if(choice==='add'){state.graph.lines.find(l=>l.id===f.addedLine.lineId).trashedAt=at;state.legacyLineIds.push(f.addedLine.lineId);state.packReviews=state.packReviews.filter(x=>x.lineId!==f.addedLine.lineId);}
  state.graph.revision++;
 }
 const staple={lineId:id(80),originalItem:'Later apples',packs:1,unitPriceMinor:null,feeEligible:true};
 state.graph=applyDemandChange(state.graph,command(state.graph,{lines:[line(80,'Later apples',9)],contributions:[{...source(82,id(80),{kind:'manual'},null),productKey:'apples',productName:'Later apples',originalText:'Later apples'}]},311)).graph;
 state.basket.push(basket([staple])[0]);state.basket.sort((a,b)=>a.id.localeCompare(b.id));state.packReviews.push({lineId:id(80),usablePerPack:null,acceptUnresolved:true});
 f.current.lines.push(staple);f.current.lines[0].unitPriceMinor=125;state.basket.find(x=>x.id===id(20)).priceMinor=125;
 f.current.shopRevision=8;f.current.food={kind:'partition',state:validateState(state,catalog)};
 return{...f,mapping,run(){return derive(this.history,this.current,this.live,{operationId:id(900),at},now,this.mapping);}};
}
for(const choice of ['add','link'])for(const position of ['bound','unbound','transferred'])test(`legacy ${choice} after tracking removes ${position} request only and preserves later manual food`,()=>{
 const f=setup({choice,position}),before=clone(f.current),r=f.run(),s=r.trackingState;
 assert.deepEqual(f.current,before);assert.equal(r.candidate.foodAfter.kind,'partition');
 assert.deepEqual(s.graph.usedIds,before.food.state.graph.usedIds);
 assert.deepEqual(s.graph.contributions.find(x=>x.id===id(30)),before.food.state.graph.contributions.find(x=>x.id===id(30)));
 assert.deepEqual(s.graph.contributions.find(x=>x.id===id(31)),before.food.state.graph.contributions.find(x=>x.id===id(31)));
 assert.deepEqual(s.graph.contributions.find(x=>x.id===id(82)),before.food.state.graph.contributions.find(x=>x.id===id(82)));
 assert.equal(s.basket.find(x=>x.id===id(20)).priceMinor,125);assert.equal(s.catalog.some(x=>x.id===f.targetFact.id),false);
 assert.equal(s.bindings.some(x=>x.factId===f.targetFact.id),false);assert.equal(s.unbound.some(x=>x.factId===f.targetFact.id),false);
 assert.equal(s.basket.some(x=>x.id===id(80)),true);assert.equal(s.basket.some(x=>x.id===f.addedLine.lineId),false);
 if(position!=='unbound')assert.equal(s.graph.contributions.find(x=>x.id===f.requestSource.id).removedAt,at);
 assert.deepEqual(r.transition.remainingLinks,[]);assert.equal(r.transition.restored.status,'pending');assert.equal(r.transition.restored.revision,3);
 assert.equal(r.receipt.baseRevision,before.food.state.graph.revision);assert.equal(r.receipt.resultRevision,s.graph.revision);
});
test('unknown unbound protected lunch remains protected and explicitly partial after request compensation',()=>{
 const f=setup({unboundLunch:true});f.current.food.state.catalog[0].quantity=null;f.current.food.state.catalog[0].originalQuantityText=null;
 // Same authoritative version must appear in retained and current mapping facts.
 f.mapping.state.catalog[0]=clone(f.current.food.state.catalog[0]);f.mapping.stateDigest=digest(f.mapping.state);
 f.mapping.snapshot.tracking.digest=f.mapping.stateDigest;f.mapping.snapshotDigest=storeDigest(f.mapping.snapshot);
 const s=f.run().trackingState,c=coverage(s,s.catalog);
 assert.equal(c.status,'partial');assert.deepEqual(c.protectedUnboundFactIds,[id(72)]);assert.deepEqual(c.allocatableUnboundFactIds,[]);
 assert.equal(s.catalog[0].quantity,null);assert.equal(s.unbound[0].transferred,null);
});
for(const [name,change] of [
 ['erased mapping',f=>f.mapping.stateDigest='0'.repeat(64)],
 ['wrong snapshot operation',f=>f.mapping.snapshotOperationId=id(999)],
 ['changed current request text',f=>f.current.request.content.originalItem='Changed'],
 ['changed request status revision',f=>f.current.request.state.revision++],
 ['changed authoritative source revision',f=>f.current.food.state.catalog[1].revision++],
 ['changed privacy basis',f=>f.current.food.state.privacyRevision++],
 ['revoked author',f=>f.live.author.disclosureLive=false],
 ['store changed',f=>f.current.storeBasis.revision=7],
 ['changed original packs',f=>{f.current.lines.find(l=>l.lineId===f.addedLine.lineId).packs=2;f.current.food.state.basket.find(l=>l.id===f.addedLine.lineId).packs=2;}]
])test(name+' blocks the entire partitioned inverse',()=>{const f=setup({choice:'add'});change(f);assert.throws(()=>f.run());});
test('request Add line acquired by independent later food cannot disappear',()=>{
 const f=setup({choice:'add'}),s=f.current.food.state;
 s.graph=applyDemandChange(s.graph,command(s.graph,{contributions:[source(83,f.addedLine.lineId,{kind:'manual'},q(1))]},312)).graph;
 assert.throws(()=>f.run(),e=>e.code==='request_undo_dependent_source');
});
test('original tracked acceptance reverses its coupled manual quantity edit, not merely its request source',()=>{
 const f=fixture({kind:'tracked',choice:'link'}),h=f.history,b=h.food.before;
 const changed={...clone(b.contributions.find(x=>x.id===id(30))),quantity:q(12)};
 const accepted=applyDemandChange(b,command(b,{contributions:[changed,f.requestSource],edges:h.food.after.edges},300));
 h.food.after=accepted.graph;h.food.receipt=accepted.receipt;
 h.afterSnapshot.value.demand={schemaVersion:1,revision:accepted.graph.revision,digest:storeDigest(accepted.graph)};
 h.afterSnapshot.digest=storeDigest(h.afterSnapshot.value);
 h.record.certificate.afterSnapshotDigest=h.afterSnapshot.digest;
 Object.assign(h.record.certificate.food,{afterDigest:storeDigest(accepted.graph),receiptDigest:storeDigest(accepted.receipt)});
 h.record.digest=storeDigest(h.record.certificate);
 const lunch=accepted.graph.contributions.find(x=>x.id===id(31));
 const lunchFact={id:id(72),revision:3,source:clone(lunch.source),sourceLabel:'Protected lunch',originalText:lunch.originalText,
  originalQuantityText:lunch.quantity.originalLiteral,quantity:clone(lunch.quantity),sourceExclusions:[],requiredLineId:id(20)};
 const state={schemaVersion:2,authorityEpoch:1,privacyRevision:2,quoteDigest:storeDigest(f.current.quote),graph:accepted.graph,basket:basket(f.current.lines),
  catalog:[lunchFact,f.targetFact],bindings:[{factId:lunchFact.id,contributionId:lunch.id},{factId:f.targetFact.id,contributionId:f.requestSource.id}],
  unbound:[],legacyLineIds:[],packReviews:[{lineId:id(20),usablePerPack:null,acceptUnresolved:true}]};
 validateState(state,state.catalog);
 const snapshot={...clone(h.afterSnapshot.value),revision:6,tracking:{schemaVersion:2,shopRevision:6,digest:digest(state),status:'recorded'}};
 const mapping={operationId:id(310),shopRevision:6,authorityEpoch:1,state:clone(state),stateDigest:digest(state),snapshotOperationId:id(310),snapshot,snapshotDigest:storeDigest(snapshot)};
 f.current.food={kind:'partition',state};f.current.shopRevision=6;
 const r=derive(h,f.current,f.live,{operationId:id(900),at},now,mapping);
 assert.deepEqual(r.trackingState.graph.contributions.find(x=>x.id===id(30)).quantity,q(10));
 assert.deepEqual(r.trackingState.graph.contributions.find(x=>x.id===lunch.id),lunch);
 assert.equal(r.trackingState.graph.contributions.find(x=>x.id===f.requestSource.id).removedAt,at);
 assert.equal(r.candidate.scope.graphRows,3); // manual + request + its original within-existing relationship
});
function partialOriginal({unboundRequest=false,firstV2=false}={}){
 const f=fixture({kind:'tracked',choice:'link'}),h=f.history,b=h.food.before;
 const manual={...clone(b.contributions.find(x=>x.id===id(30))),quantity:q(12)};
 const result=applyDemandChange(b,command(b,{contributions:[manual,...unboundRequest?[]:[f.requestSource]],edges:[]},300));
 h.food.after=result.graph;h.food.receipt=result.receipt;
 const lunch=b.contributions.find(x=>x.id===id(31)),lunchFact={id:id(72),revision:3,source:clone(lunch.source),sourceLabel:'Protected lunch',
  originalText:lunch.originalText,originalQuantityText:lunch.quantity.originalLiteral,quantity:clone(lunch.quantity),sourceExclusions:[],requiredLineId:id(20)};
 const extra={lineId:id(99),originalItem:'Unmapped legacy item',packs:3,unitPriceMinor:null,feeEligible:true};
 if(!firstV2){h.beforeSnapshot.value.lines.push(extra);h.afterSnapshot.value.lines.push(clone(extra));f.current.lines.push(clone(extra));}
 const state=(graph,catalog,after)=>({schemaVersion:2,authorityEpoch:1,privacyRevision:2,quoteDigest:storeDigest(f.current.quote),graph:clone(graph),
  basket:basket(h[after?'afterSnapshot':'beforeSnapshot'].value.lines),catalog:clone(catalog),
  bindings:[{factId:lunchFact.id,contributionId:lunch.id},...after&&!unboundRequest?[{factId:f.targetFact.id,contributionId:f.requestSource.id}]:[]],
  unbound:after&&unboundRequest?[{factId:f.targetFact.id,transferred:null}]:[],legacyLineIds:firstV2?[]:[extra.lineId],packReviews:[{lineId:id(20),usablePerPack:null,acceptUnresolved:true}]});
 const before=state(b,[lunchFact],false),after=state(result.graph,[lunchFact,f.targetFact],true);
 for(const [which,s] of [['beforeSnapshot',before],['afterSnapshot',after]]){
  const snap=h[which];snap.value.demand={schemaVersion:1,revision:s.graph.revision,digest:storeDigest(s.graph)};
  if(which==='afterSnapshot'||!firstV2)snap.value.tracking={schemaVersion:2,shopRevision:snap.value.revision,digest:digest(s),status:'recorded'};
  snap.value.budget=checkout(snap.value.lines,snap.value.quote);snap.digest=storeDigest(snap.value);
 }
 h.food.partition={before:firstV2?null:before,after};
 Object.assign(h.record.certificate,{beforeSnapshotDigest:h.beforeSnapshot.digest,afterSnapshotDigest:h.afterSnapshot.digest});
 Object.assign(h.record.certificate.food,{afterDigest:storeDigest(result.graph),receiptDigest:storeDigest(result.receipt)});h.record.digest=storeDigest(h.record.certificate);
 f.current.food={kind:'partition',state:after};
 const mapping={operationId:id(300),shopRevision:5,authorityEpoch:1,state:clone(after),stateDigest:digest(after),snapshotOperationId:id(300),snapshot:clone(h.afterSnapshot.value),snapshotDigest:h.afterSnapshot.digest};
 return{...f,mapping,run(){return derive(this.history,this.current,this.live,{operationId:id(900),at},now,this.mapping);}};
}
for(const unboundRequest of [false,true])test(`actual original partial acceptance with ${unboundRequest?'unbound':'bound'} request remains completely reversible`,()=>{
 const f=partialOriginal({unboundRequest});assert.doesNotThrow(()=>validateHistory(f.history));const r=f.run();
 assert.deepEqual(r.trackingState.basket.find(x=>x.id===id(99)),f.current.food.state.basket.find(x=>x.id===id(99)));
 assert.deepEqual(r.trackingState.legacyLineIds,[id(99)]);assert.equal(r.trackingCoverage.after.status,'partial');
 assert.deepEqual(r.trackingState.graph.contributions.find(x=>x.id===id(30)).quantity,q(10));
 assert.deepEqual(r.trackingState.catalog.map(x=>x.id),[id(72)]);
});
test('first V2 acceptance from complete V1 has explicit null prior row, never invented history',()=>{
 const f=partialOriginal({firstV2:true});assert.equal(f.history.food.partition.before,null);
 assert.doesNotThrow(()=>validateHistory(f.history));assert.equal(f.run().trackingState.catalog.length,1);
});
for(const [name,change] of [
 ['fake tracking marker',f=>{delete f.history.food.partition;}],
 ['wrong prior state digest',f=>f.history.food.partition.before.privacyRevision++],
 ['null prior despite actual partial marker',f=>f.history.food.partition.before=null],
 ['null prior with partial basket even after marker removal',f=>{f.history.food.partition.before=null;delete f.history.beforeSnapshot.value.tracking;f.history.beforeSnapshot.digest=storeDigest(f.history.beforeSnapshot.value);f.history.record.certificate.beforeSnapshotDigest=f.history.beforeSnapshot.digest;f.history.record.digest=storeDigest(f.history.record.certificate);}],
 ['after partition source version forgery',f=>f.history.food.partition.after.catalog[1].revision++],
 ['whole receipt forgery',f=>f.history.food.receipt.contributions=[]]
])test(name+' cannot waive exact historical graph/basket/partition proof',()=>{const f=partialOriginal();change(f);assert.throws(()=>validateHistory(f.history));});

 test('new assigned shopper can freshly review original request mapping without inheriting the old epoch',()=>{
  const f=setup();f.current.authorityEpoch=2;f.current.food.state.authorityEpoch=2;
  f.live.authorityEpoch=2;f.live.actorId=id(9);f.live.assignedShopperId=id(9);
  const r=f.run();assert.equal(r.candidate.base.authorityEpoch,2);assert.equal(f.mapping.authorityEpoch,1);
 });
 for(const [name,change] of [
  ['old shopper',f=>{f.live.assignedShopperId=id(9);}],
  ['stale current authority',f=>{f.live.authorityEpoch=2;}],
  ['forged historical mapping epoch',f=>{f.mapping.authorityEpoch=2;}]
 ])test(name+' cannot use the mapping as new live authority',()=>{const f=setup();change(f);assert.throws(()=>f.run());});
 test('assignment transfer cannot bypass original carry shopper and epoch fences',()=>{
  const f=setup({carried:true});f.current.authorityEpoch=2;f.current.food.state.authorityEpoch=2;
  f.live.authorityEpoch=2;f.live.actorId=id(9);f.live.assignedShopperId=id(9);
  assert.throws(()=>f.run(),e=>e.code==='request_undo_origin_access_ended');
 });
function compoundRequest(ownQuantity='Two original wraps'){
 const f=fixture({kind:'legacy',choice:'add',ownQuantity}),h=f.history,c=h.record.certificate;
 const empty={schemaVersion:1,conversionTableVersion:'us-customary-metric-v1',householdId:id(100),shopId:id(101),revision:0,lines:[],contributions:[],edges:[],usedIds:[]};
 const lunchFact=clone(f.current.food.catalog[0]),lunch={...source(31,id(20),lunchFact.source,q(2)),originalText:lunchFact.originalText};
 const adopted=applyDemandChange(empty,command(empty,{lines:[line(20,'Wraps'),line(21,'Request wraps',1)],
  contributions:[source(30,id(20),{kind:'manual'},q(12)),lunch,f.requestSource]},300));
 const before={schemaVersion:2,authorityEpoch:1,privacyRevision:2,quoteDigest:storeDigest(f.current.quote),graph:empty,basket:basket(h.beforeSnapshot.value.lines),catalog:[lunchFact],
  bindings:[],unbound:[{factId:lunchFact.id,transferred:null}],legacyLineIds:[id(20)],packReviews:[]};
 const after={...clone(before),graph:adopted.graph,basket:basket(h.afterSnapshot.value.lines),catalog:[lunchFact,clone(f.targetFact)],
  bindings:[{factId:lunchFact.id,contributionId:lunch.id},{factId:f.targetFact.id,contributionId:f.requestSource.id}],unbound:[],legacyLineIds:[],
  packReviews:[id(20),id(21)].map(lineId=>({lineId,usablePerPack:null,acceptUnresolved:true}))};
 const compound=recordCompoundAdoption(c.operationId,before,after,f.current.quote,f.current.quote,
  {kind:'requestAcceptance',requestId:c.requestId,componentDigest:requestAcceptanceComponentDigest(c)});
 h.afterSnapshot.value.demand={schemaVersion:1,revision:1,digest:storeDigest(adopted.graph)};
 h.afterSnapshot.value.tracking={schemaVersion:2,shopRevision:5,digest:digest(after),status:'recorded'};
 h.afterSnapshot.digest=storeDigest(h.afterSnapshot.value);c.afterSnapshotDigest=h.afterSnapshot.digest;
 c.food={kind:'compoundAdoption',afterRevision:1,afterDigest:storeDigest(adopted.graph),receiptDigest:storeDigest(adopted.receipt),compositionDigest:compound.evidenceDigest};
 h.record.digest=storeDigest(c);h.food={kind:'compoundAdoption',after:adopted.graph,receipt:adopted.receipt,compositionDigest:compound.evidenceDigest};
 const current=clone(after),staple={lineId:id(80),originalItem:'Later apples',packs:1,unitPriceMinor:null,feeEligible:true};
 current.graph=applyDemandChange(current.graph,command(current.graph,{lines:[line(80,'Later apples',9)],contributions:[{...source(82,id(80),{kind:'manual'},null),productKey:'apples',productName:'Later apples',originalText:'Later apples'}]},301)).graph;
 current.basket.push(basket([staple])[0]);current.packReviews.push({lineId:id(80),usablePerPack:null,acceptUnresolved:true});current.basket[0].priceMinor=125;
 f.current.lines.push(staple);f.current.lines[0].unitPriceMinor=125;f.current.shopRevision=6;f.current.food={kind:'partition',state:current};
 return{...f,compound,run(){return deriveCompoundRequestUndo(this.history,this.current,this.live,{operationId:id(900),at},now,this.compound.evidence);}};
}
test('request plus initial adoption reverses the whole manual/mapping effect and request outcome in one candidate',()=>{
 const f=compoundRequest(),r=f.run(),s=r.trackingState;
 assert.equal(r.candidate.scope.firstAdoptionReversed,true);assert.equal(r.targetAdoptionOperationId,id(300));
 assert.equal(s.graph.contributions.find(x=>x.id===id(30)).removedAt,at);
 assert.equal(s.graph.contributions.find(x=>x.id===f.requestSource.id).removedAt,at);
 assert.equal(s.graph.contributions.some(x=>x.id===id(31)),false);assert.equal(s.unbound[0].transferred.id,id(31));
 assert.deepEqual(s.legacyLineIds,[id(20)]);assert.equal(s.basket.find(x=>x.id===id(20)).priceMinor,125);
 assert.equal(s.basket.some(x=>x.id===f.addedLine.lineId),false);assert.equal(s.basket.some(x=>x.id===id(80)),true);
 assert.equal(s.graph.contributions.find(x=>x.id===id(82)).removedAt,null);assert.deepEqual(r.transition.remainingLinks,[]);
 assert.equal(r.transition.restored.status,'pending');assert.equal(r.trackingDisclosure.afterCoverage.status,'partial');
 assert.deepEqual(s.graph.usedIds,f.current.food.state.graph.usedIds);
});
test('compound historical replay validation remains independent of later mutable current facts',()=>{
 const f=compoundRequest();f.current.food.state.graph.contributions.find(x=>x.id===id(30)).quantity=q(13);
 assert.doesNotThrow(()=>validateCompoundRequestAcceptanceHistory(f.history,f.compound.evidence));
 assert.throws(()=>f.run(),e=>e.code==='touched_conflict');
});
for(const [name,change] of [
 ['different acceptance component',f=>{f.history.record.certificate.payloadDigest='b'.repeat(64);f.history.operation.payloadDigest='b'.repeat(64);f.history.record.digest=storeDigest(f.history.record.certificate);}],
 ['missing compound digest',f=>f.history.food.compositionDigest='0'.repeat(64)],
 ['missing actual after partition marker',f=>{delete f.history.afterSnapshot.value.tracking;f.history.afterSnapshot.digest=storeDigest(f.history.afterSnapshot.value);f.history.record.certificate.afterSnapshotDigest=f.history.afterSnapshot.digest;f.history.record.digest=storeDigest(f.history.record.certificate);}],
 ['forged incomplete initial receipt',f=>{f.history.food.receipt.contributions=[];f.history.record.certificate.food.receiptDigest=storeDigest(f.history.food.receipt);f.history.record.digest=storeDigest(f.history.record.certificate);}],
 ['new authority on full first adoption',f=>{f.current.authorityEpoch=2;f.current.food.state.authorityEpoch=2;f.live.authorityEpoch=2;}]
])test(name+' denies complete compound request Undo',()=>{const f=compoundRequest();change(f);assert.throws(()=>f.run());});

for(const ownQuantity of ['One LARGE box · 2 × 15 oz',null]){
 test(`partition request Undo retains authenticated quantity wording ${ownQuantity===null?'null':'text'}`,()=>{
  const f=setup({ownQuantity}),before=clone(f.current),r=f.run();
  assert.equal(r.candidate.requestUndo.originalQuantityText,ownQuantity);assert.deepEqual(f.current,before);
 });
 test(`compound request Undo retains authenticated quantity wording ${ownQuantity===null?'null':'text'}`,()=>{
  const f=compoundRequest(ownQuantity),before=clone(f.current),r=f.run();
  assert.equal(r.candidate.requestUndo.originalQuantityText,ownQuantity);assert.equal(r.candidate.scope.firstAdoptionReversed,true);assert.deepEqual(f.current,before);
 });
}
