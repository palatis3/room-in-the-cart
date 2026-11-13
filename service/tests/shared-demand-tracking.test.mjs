import {previewTransferredRebind,previewRedactedRecovery,trackingReviewDisclosure,recordTrackingReview,sealReviewedTracking,verifyTrackingPlacement} from '../dist/shared-demand-tracking-transitions.js';
import test from 'node:test';
import assert from 'node:assert/strict';
import {recordFirstAdoption,inverseFirstAdoption,validateState,coverage,admitV1,digest,PartitionError} from '../dist/shared-demand-tracking.js';
import {applyDemandChange,demandLineTotals} from '../dist/shared-demand-domain.js';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const at='2026-11-10T12:00:00Z',H=id(1),S=id(2),OP=id(3),UNDO=id(4);
const qty=(n,literal=`${n} wraps`)=>({amount:{numerator:String(n),denominator:'1'},unit:'count',originalLiteral:literal,confirmedConversion:null});
const line=(n,name)=>({id:id(n),name,unit:'count',originalOrder:n,trashedAt:null});
const basket=(n,name,packs=1)=>({id:id(n),name,packs,priceMinor:100,feeEligible:true});
const manual=(n,l,name,q)=>({id:id(n),lineId:id(l),source:{kind:'manual'},productKey:name.toLowerCase(),productName:name,originalText:name,quantity:q,sourceExclusions:[],exclusions:[],contains:[],removedAt:null});
const empty=()=>({schemaVersion:1,conversionTableVersion:'us-customary-metric-v1',householdId:H,shopId:S,revision:0,lines:[],contributions:[],edges:[],usedIds:[]});
const command=(g,n,rows={})=>({schemaVersion:1,operationId:id(n),householdId:H,shopId:S,baseRevision:g.revision,at,lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[],...rows});
function fixture({unknown=false,conversion=false,partialAllocation=false,privateTaco=false}={}){
 const meal={...manual(21,10,'Wraps',qty(6)),source:{kind:'meal',occurrenceId:id(40),ingredientId:id(41),groupId:null,bindingId:null}};
 const lunch={...manual(22,10,'Wraps',unknown?null:qty(2)),source:{kind:'reservation',reservationId:id(42),purpose:'Protected lunch',originOccurrenceId:id(40),ingredientId:id(43),groupId:id(44),bindingId:null}};
 const restriction={occurrenceId:id(40),ingredientId:id(43),label:'Exact family wording',resolution:{kind:'unresolved'}};
 lunch.sourceExclusions=[restriction];
 const quesadilla={...manual(26,10,'Wraps',qty(4)),source:{kind:'meal',occurrenceId:id(45),ingredientId:id(46),groupId:null,bindingId:null}};
 if(privateTaco)meal.originalText='Erased taco source marker';
 const catalog=[meal,lunch,quesadilla].map(r=>({id:r.id,revision:7,source:structuredClone(r.source),sourceLabel:r.source.kind==='reservation'?'Protected lunch':'Dinner',originalText:r.originalText,originalQuantityText:r.quantity?.originalLiteral??null,quantity:structuredClone(r.quantity),sourceExclusions:structuredClone(r.sourceExclusions),requiredLineId:null}));
 // The mapping is a reviewed assertion, not overwritten source wording.
 lunch.sourceExclusions=[{...restriction,resolution:{kind:'mapped',tags:['family.reviewed'],confirmedAt:at}}];
 lunch.exclusions=['family.reviewed'];
 if(conversion)meal.quantity.confirmedConversion={sourceUnit:'count',targetUnit:'gram',targetAmountPerSourceUnit:{numerator:'30',denominator:'1'},sourceNote:'Reviewed 30 grams per wrap',confirmedAt:at};
 const graph=empty();
 const before={schemaVersion:2,authorityEpoch:3,privacyRevision:5,quoteDigest:'a'.repeat(64),graph,basket:[basket(10,'Wraps',2)],catalog,bindings:[],unbound:catalog.map(f=>({factId:f.id,transferred:null})),legacyLineIds:[id(10)],packReviews:[]};
 const within=(n,d,q)=>({id:id(n),kind:'withinExisting',demandId:id(d),supplyId:id(20),quantity:qty(q),confirmation:{productMatchConfirmed:true,confirmedAt:at,evidence:'Reviewed within existing manual twelve'}});
 const adopted=applyDemandChange(graph,command(graph,3,{lines:[line(10,'Wraps'),line(11,'Apples')],contributions:[manual(20,10,'Wraps',qty(12)),meal,lunch,quesadilla,manual(23,11,'Apples',qty(4,'4 apples'))],edges:[within(30,21,partialAllocation?5:6),...unknown?[]:[within(31,22,2)],within(32,26,4)]}));
 const after={...structuredClone(before),graph:adopted.graph,basket:[basket(10,'Wraps',3),basket(11,'Apples')],bindings:catalog.map(f=>({factId:f.id,contributionId:f.id})),unbound:[],legacyLineIds:[],packReviews:[{lineId:id(10),usablePerPack:qty(8,'8 per pack'),acceptUnresolved:unknown},{lineId:id(11),usablePerPack:qty(4,'4 per pack'),acceptUnresolved:false}]};
 const sealed=recordFirstAdoption(OP,before,after);
 const later=applyDemandChange(after.graph,command(after.graph,5,{lines:[line(12,'Rice')],contributions:[manual(24,12,'Rice',qty(1,'1 rice'))]}));
 const current={...structuredClone(after),graph:later.graph,basket:[...after.basket,basket(12,'Rice')],packReviews:[...after.packReviews,{lineId:id(12),usablePerPack:qty(1,'1 per pack'),acceptUnresolved:false}]};
 const context={operationId:UNDO,targetOperationId:OP,evidenceDigest:sealed.evidenceDigest,householdId:H,shopId:S,baseRevision:current.graph.revision,authorityEpoch:3,privacyRevision:5,at,currentCatalog:structuredClone(catalog)};
 return {before,after,current,context,...sealed};
}
const run=f=>inverseFirstAdoption(f.evidence,f.current,f.context);
const rejects=(f,code)=>assert.throws(()=>run(f),e=>e instanceof PartitionError&&e.code===code);
test('full inverse preserves legacy basket, exact unbound protected source and unrelated later staple',()=>{
 const f=fixture(),saved=digest(f),r=run(f);
 assert.equal(digest(f),saved);assert.equal(r.state.graph.revision,3);
 assert.deepEqual(r.state.graph.usedIds,f.current.graph.usedIds);
 assert.deepEqual(r.state.basket,[basket(10,'Wraps',2),basket(12,'Rice')]);
 assert.deepEqual(r.state.catalog,f.before.catalog);
 assert.deepEqual(r.state.graph.contributions.find(c=>c.id===id(24)),f.current.graph.contributions.find(c=>c.id===id(24)));
 assert.equal(r.state.graph.contributions.some(c=>c.id===id(22)),false);
 assert.deepEqual(r.state.unbound.find(u=>u.factId===id(22)).transferred,f.after.graph.contributions.find(c=>c.id===id(22)));
 assert.deepEqual(r.state.unbound.map(x=>x.factId),[id(21),id(22),id(26)]);
 assert.equal(r.state.graph.edges.length,0);
 assert.equal(r.state.graph.contributions.find(c=>c.id===id(20)).removedAt,at);
 assert.deepEqual(r.disclosure.transferredFactIds,[id(21),id(22),id(26)]);
 assert.deepEqual(r.disclosure.reversedAssertions.contributions,f.after.graph.contributions);
 assert.deepEqual(r.disclosure.reversedAssertions.edges,f.after.graph.edges);
 assert.deepEqual(r.disclosure.reversedAssertions.packReviews,f.after.packReviews);
 assert.deepEqual(r.state.packReviews,[f.current.packReviews[2]]);
 assert.equal(r.receipt.disclosureDigest,digest(r.disclosure));
 assert.equal(r.receipt.beforeDigest,digest(f.current));assert.equal(r.receipt.afterDigest,digest(r.state));
});
test('existing arithmetic retains twelve with two within-existing allocations; no second reducer',()=>{
 const f=fixture();assert.deepEqual(demandLineTotals(f.after.graph)[0].quantity,{numerator:'12',denominator:'1'});
 const r=run(f);assert.deepEqual(r.disclosure.afterCoverage.trackedSubtotals.map(x=>x.quantity),[{numerator:'1',denominator:'1'}]);
 assert.equal(r.disclosure.afterCoverage.status,'partial');assert.equal(r.disclosure.afterCoverage.completeFoodCoverage,false);
 assert.deepEqual(r.disclosure.afterCoverage.protectedUnboundFactIds,[id(22)]);assert.deepEqual(r.disclosure.afterCoverage.allocatableUnboundFactIds,[]);
});
test('unknown protected amount stays exactly null before, during and after transfer',()=>{
 const f=fixture({unknown:true});assert.equal(coverage(f.after,f.context.currentCatalog).status,'unknown');
 const r=run(f);assert.equal(r.state.unbound.find(u=>u.factId===id(22)).transferred.quantity,null);
 assert.equal(r.state.catalog.find(u=>u.id===id(22)).quantity,null);assert.equal(r.disclosure.afterCoverage.status,'partial');
});
test('all restriction and conversion assertions disclosed, source labels not replaced by mapped tags',()=>{
 const f=fixture({conversion:true}),r=run(f);
 assert.deepEqual(r.disclosure.reversedAssertions.contributions,f.after.graph.contributions);
 assert.equal(r.state.catalog[1].sourceExclusions[0].label,'Exact family wording');
 assert.equal(r.state.catalog[1].sourceExclusions[0].resolution.kind,'unresolved');
 assert.equal(r.state.unbound[1].transferred.sourceExclusions[0].resolution.kind,'mapped');
 assert.equal(r.state.unbound[0].transferred.quantity.confirmedConversion.sourceNote,'Reviewed 30 grams per wrap');
});
test('evidence is deeply immutable and tampered stored body fails trusted digest',()=>{
 const f=fixture();assert.throws(()=>{f.evidence.after.graph.lines[0].name='tamper';},TypeError);
 const changed=structuredClone(f.evidence);changed.after.basket[0].packs=9;
 assert.throws(()=>inverseFirstAdoption(changed,f.current,f.context),e=>e.code==='history_unavailable');
});
for(const [name,change,code] of [
 ['wrong target',f=>f.context.targetOperationId=id(999),'history_unavailable'],
 ['stale base',f=>f.context.baseRevision--,'stale_revision'],
 ['wrong shop',f=>f.context.shopId=id(99),'wrong_scope'],
 ['stale privacy basis',f=>f.context.privacyRevision++,'source_revision_or_privacy'],
 ['revoked epoch',f=>f.context.authorityEpoch++,'source_revision_or_privacy'],
 ['authoritative revision changed',f=>{f.context.currentCatalog[0].revision++;f.current.catalog=structuredClone(f.context.currentCatalog);},'source_revision_or_privacy'],
 ['erased source',f=>f.context.currentCatalog.splice(0,1),'source_revision_or_privacy'],
 ['quote changed',f=>f.current.quoteDigest='b'.repeat(64),'quote_conflict'],
 ['changed manual quantity',f=>f.current.graph.contributions.find(c=>c.id===id(20)).quantity=qty(13),'touched_conflict'],
 ['changed basket packs',f=>f.current.basket[0].packs=4,'basket_conflict'],
 ['later changed usable pack review',f=>f.current.packReviews[0].usablePerPack=qty(9,'9 per pack'),'pack_review_conflict'],
 ['changed target edge confirmation',f=>f.current.graph.edges[0].confirmation.evidence='new reviewed basis','touched_conflict']
])test(name,()=>{const f=fixture();change(f);rejects(f,code);});
test('later allocation referencing a target source conflicts rather than being discarded',()=>{
 const f=fixture({partialAllocation:true});const edge={...structuredClone(f.current.graph.edges[0]),id:id(33),quantity:qty(1)};
 f.current.graph.edges.push(edge);f.current.graph.usedIds.push(edge.id);rejects(f,'dependency_conflict');
});
test('later same-line contribution is an actual dependency, independent later line is not',()=>{
 const f=fixture();const added=manual(25,10,'Wraps',qty(1));f.current.graph.contributions.push(added);f.current.graph.usedIds.push(added.id);rejects(f,'line_dependency_conflict');
});
test('old v1 rejects partial state; complete existing graph remains admitted',()=>{
 const f=fixture();assert.deepEqual(admitV1(f.after,f.context.currentCatalog),f.after.graph);
 assert.throws(()=>admitV1(f.before,f.context.currentCatalog),e=>e.code==='client_requires_partition_support');
 const r=run(f);assert.throws(()=>admitV1(r.state,f.context.currentCatalog),e=>e.code==='client_requires_partition_support');
});
test('no acknowledged-unknown or client trust boolean is accepted',()=>{
 const f=fixture();assert.throws(()=>validateState({...f.before,acceptUnknown:true},f.before.catalog));
 assert.throws(()=>inverseFirstAdoption(f.evidence,f.current,{...f.context,trustedAuthority:true}));
});
test('missing privacy basis and redacted evidence cannot be supplied as usable history',()=>{
 const f=fixture();delete f.context.privacyRevision;assert.throws(()=>run(f));
 const g=fixture();g.context.evidenceDigest='0'.repeat(64);rejects(g,'history_unavailable');
});
for(const [name,mutate] of [
 ['missing protected partition',s=>s.unbound.pop()],
 ['duplicate source partition',s=>s.unbound.push(s.unbound[0])],
 ['invented source kind',s=>s.catalog[0].source={kind:'manual'}],
 ['invented basket mapping',s=>s.bindings.push({factId:id(21),contributionId:id(999)})],
 ['forged exclusion origin',s=>s.catalog[1].sourceExclusions[0].occurrenceId=id(999)]
])test(name,()=>{const f=fixture(),s=structuredClone(f.before);mutate(s);assert.throws(()=>validateState(s,s.catalog));});
test('a protected transfer cannot change quantity, protection identity or retain an allocation',()=>{
 const f=fixture(),r=run(f);
 for(const mutate of [s=>s.unbound[1].transferred.quantity=qty(1),s=>s.unbound[1].transferred.source.purpose='Not protected',s=>s.graph.edges.push(f.after.graph.edges[1])]){
  const s=structuredClone(r.state);mutate(s);assert.throws(()=>validateState(s,f.context.currentCatalog));
 }
});
test('repeated inverse requires repository receipt replay; pure mutation cannot run twice',()=>{
 const f=fixture(),r=run(f);assert.throws(()=>inverseFirstAdoption(f.evidence,r.state,{...f.context,baseRevision:3}),e=>e.code==='touched_conflict');
});
test('changed authoritative quantity cannot be hidden by matching source ID',()=>{
 const f=fixture();f.current.graph.contributions.find(c=>c.id===id(22)).quantity=qty(3);rejects(f,'authoritative_quantity');
});
test('source evidence has exact required keys, rational and unknown-vs-missing semantics',()=>{
 const f=fixture();delete f.before.catalog[0].quantity;assert.throws(()=>validateState(f.before,f.before.catalog));
 const g=fixture();g.before.catalog[0].quantity.amount={numerator:'12',denominator:'2'};assert.throws(()=>validateState(g.before,g.before.catalog));
});

test('used IDs remain reserved after inverse; v1 reducer rejects reusing a removed target ID',()=>{
 const f=fixture(),r=run(f);assert.throws(()=>applyDemandChange(r.state.graph,command(r.state.graph,99,{contributions:[manual(22,12,'Rice',qty(1))]})),e=>e.code==='identity_reused');
});
test('an unrelated later authoritative source partition survives',()=>{
 const f=fixture();const old=f.current.graph.contributions.find(x=>x.id===id(24));
 old.source={kind:'meal',occurrenceId:id(60),ingredientId:id(61),groupId:null,bindingId:null};
 const fact={id:id(24),revision:1,source:structuredClone(old.source),sourceLabel:'Later dinner',originalText:old.originalText,originalQuantityText:old.quantity.originalLiteral,quantity:structuredClone(old.quantity),sourceExclusions:[],requiredLineId:id(12)};
 f.context.currentCatalog.push(fact);f.current.catalog.push(structuredClone(fact));f.current.bindings.push({factId:id(24),contributionId:id(24)});
 const r=run(f);assert.deepEqual(r.state.bindings,[{factId:id(24),contributionId:id(24)}]);assert.deepEqual(r.state.graph.contributions.find(x=>x.id===id(24)),old);
});
test('immediate Undo also appends a revision and retains all identities',()=>{
 const f=fixture();f.current=structuredClone(f.after);f.context.baseRevision=1;const r=run(f);
 assert.equal(r.state.graph.revision,2);assert.deepEqual(r.state.graph.usedIds,f.after.graph.usedIds);assert.deepEqual(r.state.basket,f.before.basket);
});

test('accepted request wording/revision survives transfer, required line cannot be invented',()=>{
 const f=fixture();const b=structuredClone(f.before),a=structuredClone(f.after);
 const row={...manual(28,10,'Wraps',null),source:{kind:'request',requestId:id(70),appliedRequestRevision:4},originalText:'Wraps for my shift'};
 const fact={id:row.id,revision:4,source:structuredClone(row.source),sourceLabel:'Wraps for my shift',originalText:row.originalText,originalQuantityText:'some for work',quantity:null,sourceExclusions:[],requiredLineId:id(10)};
 b.catalog.push(fact);b.unbound.push({factId:row.id,transferred:null});a.catalog.push(structuredClone(fact));a.bindings.push({factId:row.id,contributionId:row.id});a.graph.contributions.push(row);a.graph.usedIds.push(row.id);
 const sealed=recordFirstAdoption(OP,b,a);const c={...f.context,baseRevision:1,evidenceDigest:sealed.evidenceDigest,currentCatalog:structuredClone(a.catalog)};
 const r=inverseFirstAdoption(sealed.evidence,a,c);
 assert.deepEqual(r.state.catalog.find(x=>x.id===row.id),fact);assert.equal(r.state.unbound.find(x=>x.factId===row.id).transferred.quantity,null);
 const bad=structuredClone(a);bad.graph.contributions.find(x=>x.id===row.id).lineId=id(11);
 assert.throws(()=>validateState(bad,bad.catalog));
});


test('packs inverse preserves a later untouched price on the same preexisting row',()=>{
 const f=fixture();f.current.basket[0].priceMinor=120;
 validateState(f.current,f.context.currentCatalog);
 const currentDigest=digest(f.current),r=run(f);
 assert.deepEqual(r.state.basket.find(l=>l.id===id(10)),{...basket(10,'Wraps',2),priceMinor:120});
 assert.deepEqual(r.state.basket.map(l=>l.id),[id(10),id(12)]);
 assert.deepEqual(r.state.basket.find(l=>l.id===id(12)),f.current.basket.find(l=>l.id===id(12)));
 assert.equal(digest(f.current),currentDigest);
 assert.equal(r.receipt.beforeDigest,currentDigest);assert.equal(r.receipt.afterDigest,digest(r.state));
});
test('later touched pack count still conflicts even with an independent price edit',()=>{
 const f=fixture();f.current.basket[0].priceMinor=120;f.current.basket[0].packs=4;
 validateState(f.current,f.context.currentCatalog);rejects(f,'basket_conflict');
});
test('added-row membership inverse requires the whole added row unchanged',()=>{
 const f=fixture();f.current.basket.find(l=>l.id===id(11)).priceMinor=120;
 validateState(f.current,f.context.currentCatalog);rejects(f,'basket_conflict');
});


// R3 pure candidates: these helpers construct synthetic server-owned bases,
// not client authorization tokens or repository/HTTP proof.
const basis=s=>({householdId:H,shopId:S,graphRevision:s.graph.revision,authorityEpoch:s.authorityEpoch,privacyRevision:s.privacyRevision,basisDigest:digest(s),currentCatalog:structuredClone(s.catalog)});
function partial(options={}){const f=fixture(options);return {...f,state:run(f).state};}
function rebindIntent(f,ids=[id(21),id(22),id(26)]){
 return {operationId:id(80),at,bindings:ids.map(factId=>({factId,line:{...f.state.graph.lines.find(l=>l.id===id(10)),trashedAt:null},basket:structuredClone(f.state.basket.find(l=>l.id===id(10))),packReview:structuredClone(f.after.packReviews[0])}))};
}
function reviewed(s){const ctx={...basis(s),reviewId:id(90),actorId:id(91),deviceId:id(92),shopRevision:10,now:at,expiresAt:'2026-11-10T12:05:00Z'};
 const disclosure=trackingReviewDisclosure(s,s.catalog);const recorded=recordTrackingReview(s,disclosure,ctx);return {ctx,disclosure,...recorded};}
function sealed(s){const r=reviewed(s),ctx={...basis(s),actorId:id(91),deviceId:id(92),baseShopRevision:10,frozenRevision:11,reviewDigest:r.reviewDigest,now:'2026-11-10T12:01:00Z'};
 return {...r,...sealReviewedTracking(s,r.review,ctx)};}
function placement(s,seal){return verifyTrackingPlacement(seal.snapshot,s,{...basis(s),frozenRevision:11,storedSnapshotDigest:seal.snapshotDigest});}
function projectionFixture(){const f=partial({privateTaco:true}),old=structuredClone(f.state);const state=structuredClone(old);delete state.packReviews;state.privacyRevision++;
 state.catalog=state.catalog.filter(x=>x.id!==id(21));state.unbound=state.unbound.filter(x=>x.factId!==id(21));
 const projection={schemaVersion:1,status:'reviewRequired',invalidatedStateDigest:digest(old),previousPrivacyRevision:old.privacyRevision,state};
 const ctx={...basis({...state,packReviews:f.state.packReviews}),basisDigest:digest(projection)};
 const intent={operationId:id(81),at,packReviews:structuredClone(f.state.packReviews)};return {f,old,projection,ctx,intent};}

test('same-ID rebind restores proved sources only, preserves later staple and creates no old allocation',()=>{
 const f=partial(),before=digest(f.state),result=previewTransferredRebind(f.state,rebindIntent(f),basis(f.state));
 assert.equal(digest(f.state),before);assert.equal(result.state.graph.revision,f.state.graph.revision+1);
 assert.deepEqual(result.state.graph.usedIds,f.state.graph.usedIds);assert.deepEqual(result.state.unbound,[]);
 for(const u of f.state.unbound)assert.deepEqual(result.state.graph.contributions.find(x=>x.id===u.transferred.id),u.transferred);
 assert.deepEqual(result.state.graph.edges,[]);assert.deepEqual(result.disclosure.allocationsRestored,[]);
 assert.deepEqual(result.state.graph.contributions.find(x=>x.id===id(24)),f.state.graph.contributions.find(x=>x.id===id(24)));
 assert.deepEqual(demandLineTotals(result.state.graph).find(x=>x.lineId===id(10)).quantity,{numerator:'12',denominator:'1'});
});
test('unknown protected food remains unknown after explicit rebind and reviewed pickup',()=>{
 const f=partial({unknown:true}),r=previewTransferredRebind(f.state,rebindIntent(f,[id(22)]),basis(f.state));
 assert.equal(r.state.graph.contributions.find(x=>x.id===id(22)).quantity,null);
 assert.equal(r.disclosure.after.status,'partial');const seal=sealed(r.state),placed=placement(r.state,seal);
 assert.equal(placed.trackingScope,'partial');assert.equal(placed.coverage.completeFoodCoverage,false);
 assert.deepEqual(placed.coverage.allocatableUnboundFactIds,[]);
});
test('rebind may explicitly create an unpriced mapping line without deleting the old legacy basket',()=>{
 const f=partial(),intent=rebindIntent(f,[id(22)]);intent.bindings[0]={...intent.bindings[0],line:line(71,'Lunch wraps'),basket:{...basket(71,'Lunch wraps'),priceMinor:null},packReview:{...intent.bindings[0].packReview,lineId:id(71)}};
 const r=previewTransferredRebind(f.state,intent,basis(f.state));assert.ok(r.state.graph.usedIds.includes(id(71)));
 assert.deepEqual(r.state.basket.find(x=>x.id===id(10)),f.state.basket.find(x=>x.id===id(10)));
 assert.ok(r.state.legacyLineIds.includes(id(10)));assert.equal(r.state.graph.contributions.find(x=>x.id===id(22)).lineId,id(71));
});
test('a never-tracked fact is not a proof to reuse a contribution ID',()=>{
 const f=partial();assert.throws(()=>previewTransferredRebind(f.before,rebindIntent(f),basis(f.before)),e=>e.code==='transfer_proof_required');
});
test('rebind rejects invented contribution facts and arbitrary reserved IDs',()=>{
 const f=partial(),intent=rebindIntent(f,[id(22)]);intent.bindings[0].contribution={...f.state.unbound[1].transferred,quantity:qty(1)};
 assert.throws(()=>previewTransferredRebind(f.state,intent,basis(f.state)));
 delete intent.bindings[0].contribution;intent.bindings[0].line=line(23,'Wrong reused ID');intent.bindings[0].basket={...basket(23,'Wrong reused ID'),priceMinor:null};intent.bindings[0].packReview.lineId=id(23);
 assert.throws(()=>previewTransferredRebind(f.state,intent,basis(f.state)),e=>e.code==='identity_reused');
});
test('rebind requires exact historical line, current basket and fresh scope',()=>{
 for(const mutate of [x=>x.bindings[0].line.name='Rename without review',x=>x.bindings[0].basket.packs=99,x=>x.bindings.push(x.bindings[0])]){
  const f=partial(),intent=rebindIntent(f);mutate(intent);assert.throws(()=>previewTransferredRebind(f.state,intent,basis(f.state)));
 }
 const f=partial();assert.throws(()=>previewTransferredRebind(f.state,rebindIntent(f),{...basis(f.state),privacyRevision:99}),e=>e.code==='source_revision_or_privacy');
});
test('redacted recovery preserves surviving transferred IDs and cannot resurrect erased text',()=>{
 const f=projectionFixture(),before=digest(f.projection),r=previewRedactedRecovery(f.projection,f.intent,f.ctx);
 assert.equal(digest(f.projection),before);assert.deepEqual(r.state.graph.usedIds,f.old.graph.usedIds);
 assert.deepEqual(r.state.unbound,f.projection.state.unbound);assert.ok(!JSON.stringify(r).includes('Erased taco source marker'));
 assert.ok(r.state.graph.usedIds.includes(id(21)));assert.ok(!r.state.catalog.some(x=>x.id===id(21)));
 assert.equal(r.state.privacyRevision,6);assert.equal(r.state.graph.revision,4);
 const seal=sealed(r.state);assert.equal(placement(r.state,seal).trackingScope,'partial');
 const g={...f.f,state:r.state};assert.throws(()=>previewTransferredRebind(r.state,rebindIntent(g,[id(21)]),basis(r.state)),e=>e.code==='transfer_proof_required');
 // The remaining protected row can still be rebound with its original identity.
 const rebound=previewTransferredRebind(r.state,rebindIntent(g,[id(22)]),basis(r.state));assert.ok(rebound.state.graph.contributions.some(x=>x.id===id(22)));
});
test('recovery needs a new privacy basis and complete explicit pack review',()=>{
 const f=projectionFixture();const bad=structuredClone(f.projection);bad.previousPrivacyRevision=6;
 assert.throws(()=>previewRedactedRecovery(bad,f.intent,{...f.ctx,basisDigest:digest(bad)}),e=>e.code==='privacy_not_advanced');
 assert.throws(()=>previewRedactedRecovery(f.projection,{...f.intent,packReviews:[]},f.ctx),e=>e.code==='pack_review_partition');
 assert.throws(()=>previewRedactedRecovery(f.projection,{...f.intent,state:f.old},f.ctx));
});
test('tampered redacted projection or changed current source revision is rejected',()=>{
 const f=projectionFixture(),bad=structuredClone(f.projection);bad.state.unbound[0].transferred.quantity=qty(1);
 assert.throws(()=>previewRedactedRecovery(bad,f.intent,f.ctx),e=>e.code==='projection_integrity');
 const changed=structuredClone(f.ctx);changed.currentCatalog[0].revision++;
 assert.throws(()=>previewRedactedRecovery(f.projection,f.intent,changed),e=>e.code==='source_revision_or_privacy');
});
test('reviewed partial manual pickup freezes and reports without full mapping or quantified protection',()=>{
 const f=partial({unknown:true}),seal=sealed(f.state),r=placement(f.state,seal);
 assert.equal(r.trackingScope,'partial');assert.equal(r.placementDoesNotConfirmFill,true);
 assert.equal(seal.review.disclosure.unbound.find(x=>x.fact.id===id(22)).fact.quantity,null);
 assert.deepEqual(seal.review.disclosure.unbound.map(x=>x.fact),f.state.catalog);
 assert.equal(seal.review.disclosure.coverageStatement,'tracked_subtotals_only_no_complete_coverage_or_free_unbound_supply');
 assert.equal(r.coverage.completeFoodCoverage,false);assert.deepEqual(r.coverage.protectedUnboundFactIds,[id(22)]);
 assert.throws(()=>admitV1(f.state,f.state.catalog),e=>e.code==='client_requires_partition_support');
});
test('an unreviewed partial or raw reviewRequired projection cannot be sealed',()=>{
 const f=partial();assert.throws(()=>sealReviewedTracking(f.state,{}, {...basis(f.state),actorId:id(91),deviceId:id(92),baseShopRevision:10,frozenRevision:11,reviewDigest:'0'.repeat(64),now:at}));
 const p=projectionFixture();assert.throws(()=>recordTrackingReview(p.projection,{},reviewed(f.state).ctx));
});
test('omitting unknown/protected facts or asserting complete coverage cannot count as review',()=>{
 const f=partial({unknown:true}),r=reviewed(f.state);
 for(const mutate of [a=>a.unbound.pop(),a=>a.coverage.completeFoodCoverage=true,a=>a.coverage.protectedUnboundFactIds=[],a=>a.unbound[1].fact.revision++]){
  const ack=structuredClone(r.disclosure);mutate(ack);assert.throws(()=>recordTrackingReview(f.state,ack,r.ctx),e=>e.code==='review_scope_changed');
 }
});
test('unknown tracked pack/food review remains explicit and is not a protection waiver',()=>{
 const f=partial({unknown:true}),r=previewTransferredRebind(f.state,rebindIntent(f,[id(22)]),basis(f.state));
 const bad=structuredClone(r.state);bad.packReviews.find(x=>x.lineId===id(10)).acceptUnresolved=false;
 assert.throws(()=>reviewed(bad),e=>e.code==='unresolved_pack_review_required');
 const good=reviewed(r.state);assert.ok(good.review.disclosure.unresolvedPackIds.includes(id(10)));
});
for(const [name,mutate] of [
 ['price',s=>s.basket[0].priceMinor=120],['quote',s=>s.quoteDigest='b'.repeat(64)],
 ['authority',s=>s.authorityEpoch++],['privacy',s=>s.privacyRevision++],
 ['catalog revision',s=>s.catalog[0].revision++]
])test('later '+name+' invalidates an earlier frozen tracking review',()=>{
 const f=partial(),seal=sealed(f.state),changed=structuredClone(f.state);mutate(changed);
 assert.throws(()=>placement(changed,seal));
});
test('review expires for a new freeze, while reporting a valid frozen copy remains distinct',()=>{
 const f=partial(),r=reviewed(f.state);
 assert.throws(()=>sealReviewedTracking(f.state,r.review,{...basis(f.state),actorId:id(91),deviceId:id(92),baseShopRevision:10,frozenRevision:11,reviewDigest:r.reviewDigest,now:'2026-11-10T12:06:00Z'}),e=>e.code==='review_expired');
 const seal=sealed(f.state);assert.equal(placement(f.state,seal).trackingScope,'partial');
});
test('snapshot tampering, stale revision and cross-device seal fail exact binding',()=>{
 const f=partial(),seal=sealed(f.state),bad=structuredClone(seal.snapshot);bad.review.disclosure.unbound=[];
 assert.throws(()=>verifyTrackingPlacement(bad,f.state,{...basis(f.state),frozenRevision:11,storedSnapshotDigest:seal.snapshotDigest}),e=>e.code==='snapshot_integrity');
 assert.throws(()=>verifyTrackingPlacement(seal.snapshot,f.state,{...basis(f.state),frozenRevision:12,storedSnapshotDigest:seal.snapshotDigest}),e=>e.code==='snapshot_identity');
 assert.throws(()=>sealReviewedTracking(f.state,seal.review,{...basis(f.state),actorId:id(91),deviceId:id(93),baseShopRevision:10,frozenRevision:11,reviewDigest:seal.reviewDigest,now:at}),e=>e.code==='review_identity');
});
test('no caller trust flag or unsupported snapshot version admits placement',()=>{
 const f=partial(),seal=sealed(f.state);
 assert.throws(()=>verifyTrackingPlacement(seal.snapshot,f.state,{...basis(f.state),frozenRevision:11,storedSnapshotDigest:seal.snapshotDigest,authorized:true}));
 assert.throws(()=>verifyTrackingPlacement({...seal.snapshot,schemaVersion:1},f.state,{...basis(f.state),frozenRevision:11,storedSnapshotDigest:seal.snapshotDigest}));
});

test('erased source or changed protection cannot be validated under an old frozen review',()=>{
 const f=partial({unknown:true}),seal=sealed(f.state),ctx={...basis(f.state),frozenRevision:11,storedSnapshotDigest:seal.snapshotDigest};
 ctx.currentCatalog=ctx.currentCatalog.filter(x=>x.id!==id(22));
 assert.throws(()=>verifyTrackingPlacement(seal.snapshot,f.state,ctx),e=>e.code==='source_revision_or_privacy');
 const changed=structuredClone(f.state);changed.catalog[1].source.purpose='Different protected purpose';
 assert.throws(()=>placement(changed,seal));
});
