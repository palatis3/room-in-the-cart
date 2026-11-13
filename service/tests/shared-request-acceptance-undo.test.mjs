import test from 'node:test';
import assert from 'node:assert/strict';
import {captureRequestAcceptance,requestContentDigest,validateRequestAcceptanceHistory,deriveRequestAcceptanceUndo as undo,replayRequestAcceptanceUndo as replay,prepareRequestAcceptanceUndo,validateRequestAcceptanceCoreHistory,requestAcceptanceComponentDigest} from '../dist/shared-request-acceptance-undo.js';
import {requestAcceptanceCertificateSchema,requestUndoCandidateSchema,requestUndoPreviewInputSchema,requestUndoApplyBodySchema,requestUndoPreviewResponseSchema} from '../dist/shared-request-undo-contracts.js';
import {applyDemandChange as apply} from '../dist/shared-demand-domain.js';
import {checkout} from '../dist/checkout.js';
import {digest} from '../dist/database.js';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const at='2026-11-10T13:00:00.000Z',now=new Date(at),clone=structuredClone;
const q=n=>({amount:{numerator:String(n),denominator:'1'},unit:'count',originalLiteral:`${n} original wraps`,confirmedConversion:null});
const line=(n,name,order=0)=>({id:id(n),name,unit:'count',originalOrder:order,trashedAt:null});
const source=(n,lineId,kind,quantity=q(2))=>({id:id(n),lineId,source:kind,productKey:'wraps',productName:'Wraps',originalText:'Original food wording',quantity,exclusions:[],contains:[],removedAt:null});
const command=(graph,patch={},operation=300)=>({schemaVersion:1,operationId:id(operation),householdId:id(100),shopId:id(101),baseRevision:graph.revision,at,lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[],...patch});
const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:'2026-11-09T12:00:00.000Z',expiresAt:'2026-11-11T16:00:00.000Z'};
function fixture({kind='tracked',choice='add',status='pending',route='current',child=false,carried=false,ownQuantity='Two original wraps'}={}){
 const content={requestId:id(10),shopId:id(101),authorId:id(2),authorKind:child?'child':'adult',consentId:child?id(7):null,
  originalItem:'Requested wraps',ownQuantity,clarification:status==='clarified'?'Which wrap?':null,authoredAt:at,receivedAt:at,followupTo:null};
 const bLine={lineId:id(20),originalItem:'Wraps',packs:2,unitPriceMinor:100,feeEligible:true};
 const addedLine={lineId:id(21),originalItem:'Request wraps',packs:1,unitPriceMinor:150,feeEligible:true};
 const targetLine=choice==='add'?addedLine.lineId:bLine.lineId;
 const beforeGraph={schemaVersion:1,conversionTableVersion:'us-customary-metric-v1',householdId:id(100),shopId:id(101),revision:1,
  lines:[line(20,'Wraps')],contributions:[source(30,id(20),{kind:'manual'},q(10)),source(31,id(20),{kind:'reservation',reservationId:id(32),purpose:'Protected lunch',originOccurrenceId:null,ingredientId:id(33),groupId:null,bindingId:null})],edges:[],usedIds:[id(20),id(30),id(31)]};
 const requestSource={...source(40,targetLine,{kind:'request',requestId:id(10),appliedRequestRevision:1}),originalText:content.originalItem};
 const edge={id:id(41),kind:'withinExisting',demandId:requestSource.id,supplyId:id(30),quantity:q(2),confirmation:{productMatchConfirmed:true,confirmedAt:at,evidence:'Same two wraps already in ten'}};
 const result=apply(beforeGraph,command(beforeGraph,{lines:choice==='add'?[line(21,'Request wraps',1)]:[],contributions:[requestSource],edges:choice==='link'?[edge]:[]}));
 const beforeLines=[bLine],afterLines=choice==='add'?[bLine,addedLine]:[bLine],mealRefs=[{occurrenceId:id(50),revision:3}];
 const snapshot=(revision,lines,g)=>{const value={shopId:id(101),revision,phase:'draft',storeBasis:{revision:null,reviewRequired:false},mealRefs,quote:clone(quote),lines:clone(lines),budget:checkout(lines,quote),...(kind==='tracked'?{demand:{schemaVersion:1,revision:g.revision,digest:digest(g)}}:{})};return{operationId:revision===5?id(300):id(200),value,digest:digest(value)};};
 const beforeSnapshot=snapshot(4,beforeLines,beforeGraph),afterSnapshot=snapshot(5,afterLines,result.graph);
 const link={requestId:id(10),shopId:id(101),lineId:targetLine,reviewedRevision:1,operationId:id(300)};
 const carry=carried?[{sourceRequestId:id(8),targetRequestId:id(10),sourceShopId:id(99),targetShopId:id(101),sourceAuthorityEpoch:1,targetAuthorityEpoch:1,operationId:id(10)}]:[];
 const cert={schemaVersion:1,householdId:id(100),shopId:id(101),operationId:id(300),actorId:id(1),deviceId:id(3),authorityEpoch:1,payloadDigest:'a'.repeat(64),baseShopRevision:4,resultShopRevision:5,
  requestId:id(10),authorId:id(2),authorKind:content.authorKind,consentId:content.consentId,contentDigest:requestContentDigest(content),
  before:{revision:1,status,route},after:{revision:2,status:'added',route:'current'},decision:choice==='add'?{choice,line:addedLine,promote:route==='next'}:{choice,lineId:targetLine,promote:route==='next'},
  beforeLink:null,afterLink:link,beforeLinksDigest:digest([]),afterLinksDigest:digest([link]),beforeSnapshotDigest:beforeSnapshot.digest,afterSnapshotDigest:afterSnapshot.digest,
  food:kind==='tracked'?{kind,beforeRevision:1,afterRevision:2,beforeDigest:digest(beforeGraph),afterDigest:digest(result.graph),receiptDigest:digest(result.receipt)}:{kind:'legacy'},carry,privacyMemberIds:[id(1),id(2)]};
 const observed={beforeContent:content,afterContent:clone(content),beforeState:clone(cert.before),afterState:clone(cert.after),beforeLinks:[],afterLinks:[link]};
 const record=captureRequestAcceptance(cert,observed);
 const history={record,operation:{householdId:id(100),shopId:id(101),operationId:id(300),kind:'request.apply',actorId:id(1),deviceId:id(3),payloadDigest:cert.payloadDigest},beforeSnapshot,afterSnapshot,
  food:kind==='tracked'?{kind,before:beforeGraph,after:result.graph,receipt:result.receipt}:{kind:'legacy'}};
 const targetFact={id:id(71),revision:1,source:requestSource.source,sourceLabel:content.originalItem,originalText:content.originalItem,originalQuantityText:content.ownQuantity,quantity:null,sourceExclusions:[],requiredLineId:targetLine};
 const lunchFact={id:id(72),revision:3,source:beforeGraph.contributions[1].source,sourceLabel:'Protected lunch',originalText:'Lunch wraps',originalQuantityText:'2 wraps',quantity:q(2),sourceExclusions:[],requiredLineId:bLine.lineId};
 const current={shopRevision:5,authorityEpoch:1,phase:'draft',storeBasis:{revision:null,reviewRequired:false},lines:clone(afterLines),quote:clone(quote),mealRefs:clone(mealRefs),request:{content:clone(content),state:clone(cert.after)},links:[clone(link)],
  food:kind==='tracked'?{kind,graph:clone(result.graph)}:{kind:'legacy',catalog:[lunchFact,targetFact]}};
 const live={householdId:id(100),shopId:id(101),actorId:id(1),deviceId:id(3),authorityEpoch:1,assignedShopperId:id(1),actorActive:true,deviceActive:true,shopperScope:true,
  privacyMembers:[{memberId:id(1),available:true},{memberId:id(2),available:true}],author:{memberId:id(2),kind:content.authorKind,consentId:content.consentId,disclosureLive:true},
  carry:carry.map(row=>({...row,sourceShopperId:id(1),sourceCurrentAuthorityEpoch:1,targetCurrentAuthorityEpoch:1,disclosureLive:true})),storeBasis:null};
 return{cert,observed,history,current,live,targetFact,requestSource,bLine,addedLine,run(){return undo(this.history,this.current,this.live,{operationId:id(900),at},now);}};
}
function later(f){
 const staple={lineId:id(80),originalItem:'Later apples',packs:1,unitPriceMinor:null,feeEligible:true};f.current.lines.push(staple);f.current.shopRevision++;
 f.current.mealRefs.push({occurrenceId:id(81),revision:f.current.shopRevision});
 if(f.current.food.kind==='tracked')f.current.food.graph=apply(f.current.food.graph,command(f.current.food.graph,{lines:[line(80,'Later apples',9)],contributions:[{...source(82,id(80),{kind:'manual'},null),originalText:'Later apples unknown',productName:'Later apples',productKey:'apples'}]},301)).graph;
 return staple;
}
const fails=(f,code)=>assert.throws(()=>f.run(),e=>e.code===code);
for(const kind of ['tracked','legacy'])for(const choice of ['add','link'])for(const [status,route] of [['pending','current'],['clarified','current'],['deferred','next'],['pending','next']])test(`${kind} ${choice} restores ${status}/${route} and preserves later independent food`,()=>{
 const f=fixture({kind,choice,status,route}),staple=later(f),before=clone(f.current);f.current.lines[0].unitPriceMinor=125;
 const result=f.run(),c=result.candidate;
 assert.equal(c.kind,'requestAcceptanceUndo');assert.equal(c.scope.requestsChanged,true);assert.equal(c.requestUndo.restored.status,status);assert.equal(c.requestUndo.restored.route,route);assert.equal(c.requestUndo.restored.revision,3);
 assert.equal(c.action.kind,'request.undoAcceptance');assert.equal(c.action.body.lines[0].unitPriceMinor,125);assert.deepEqual(c.action.body.lines.at(-1),staple);assert.deepEqual(c.action.body.quote,f.current.quote);
 assert.deepEqual(result.transition.mealRefs,before.mealRefs);assert.deepEqual(result.transition.remainingLinks,[]);assert.deepEqual(c.requestUndo.carry,[]);
 if(kind==='tracked'){
  const after=c.foodAfter.graph;assert.equal(new Set(after.lines.map(x=>x.id)).size,after.lines.length);
  assert.deepEqual(after.lines.map(x=>[x.id,x.originalOrder]).sort(),f.current.food.graph.lines.map(x=>[x.id,x.originalOrder]).sort());
  for(const row of after.lines){const prior=f.current.food.graph.lines.find(x=>x.id===row.id);assert.deepEqual({...row,trashedAt:prior.trashedAt},prior);}
  assert.deepEqual(after.usedIds,f.current.food.graph.usedIds);assert.deepEqual(after.contributions.find(x=>x.id===id(31)),f.current.food.graph.contributions.find(x=>x.id===id(31)));
  assert.equal(after.contributions.find(x=>x.id===id(40)).removedAt,at);assert.equal(after.edges.length,0);
 }else{assert.equal(result.receipt,null);assert.equal(c.foodAfter.kind,'legacy');assert.deepEqual(c.foodAfter.catalog,[f.current.food.catalog[0]]);assert.equal('graph'in c.foodAfter,false);}
 assert.deepEqual(requestUndoCandidateSchema.parse(c),c);assert.equal(f.current.request.state.status,'added');
});
test('Link preserves another author on the same existing line and exact overlap evidence is retired only once',()=>{
 const f=fixture({choice:'link'}),other={requestId:id(60),shopId:id(101),lineId:id(20),reviewedRevision:2,operationId:id(302)};
 f.current.links.push(other);const s=source(61,id(20),{kind:'request',requestId:id(60),appliedRequestRevision:2},q(1));
 f.current.food.graph=apply(f.current.food.graph,command(f.current.food.graph,{contributions:[s]},302)).graph;f.current.shopRevision++;
 const x=f.run();assert.deepEqual(x.transition.remainingLinks,[other]);assert.deepEqual(x.candidate.foodAfter.graph.contributions.find(x=>x.id===s.id),s);assert.deepEqual(x.candidate.action.body.lines,f.current.lines);
});
for(const kind of ['tracked','legacy'])test(kind+' Add cannot remove a line acquired by a later independent request',()=>{
 const f=fixture({kind}),other={requestId:id(60),shopId:id(101),lineId:id(21),reviewedRevision:1,operationId:id(302)};f.current.links.push(other);f.current.shopRevision++;
 if(kind==='tracked')f.current.food.graph=apply(f.current.food.graph,command(f.current.food.graph,{contributions:[source(61,id(21),{kind:'request',requestId:id(60),appliedRequestRevision:1},q(1))]},302)).graph;
 else f.current.food.catalog.push({...f.targetFact,id:id(62),revision:1,source:{kind:'request',requestId:id(60),appliedRequestRevision:1}});
 fails(f,kind==='tracked'?'request_undo_graph_conflict':'request_undo_dependent_source');
});
for(const field of ['packs','unitPriceMinor','originalItem','feeEligible'])test('added membership conflicts with later '+field,()=>{const f=fixture();f.current.lines[1][field]=({packs:2,unitPriceMinor:199,originalItem:'Edited',feeEligible:false})[field];fails(f,'food_undo_line_conflict');});
test('removing an added priced line does not demand a fresh current quote or restore an old one',()=>{const f=fixture();f.current.quote.expiresAt='2026-11-09T16:00:00.000Z';assert.deepEqual(f.run().candidate.action.body.quote,f.current.quote);});
for(const mutate of [f=>f.current.request.state.revision++,f=>f.current.request.state.status='pending',f=>f.current.request.content.originalItem='Later edit',f=>f.current.links[0].operationId=id(999),f=>f.current.links=[]])test('first Apply rejects changed request state, content or exact acceptance link: '+String(mutate),()=>{const f=fixture();mutate(f);fails(f,'request_undo_request_conflict');});
test('graph source changed after acceptance cannot be silently retired',()=>{const f=fixture();f.current.food.graph.contributions.find(x=>x.id===id(40)).originalText='Later source';assert.throws(()=>f.run(),e=>e.code==='request_undo_request_source_mismatch');});
test('same current facts produce the same effect digest across candidate/preview operation IDs and times',()=>{const f=fixture(),a=f.run(),b=undo(f.history,f.current,f.live,{operationId:id(901),at:'2026-11-10T13:01:00.000Z'},now);assert.equal(a.candidate.effectDigest,b.candidate.effectDigest);assert.notDeepEqual(a.receipt,b.receipt);});
test('current quote, catalog and independent meal changes invalidate held candidate digest',()=>{const f=fixture({kind:'legacy'}),d=f.run().candidate.effectDigest;f.current.quote.capMinor++;assert.notEqual(f.run().candidate.effectDigest,d);f.current.food.catalog[0].originalText='Current lunch';assert.notEqual(f.run().candidate.effectDigest,d);});
for(const field of ['actorActive','deviceActive','shopperScope'])test('live '+field+' denied before candidate',()=>{const f=fixture();f.live[field]=false;fails(f,'request_undo_access_ended');});
test('foreign household and mismatched assigned shopper cannot use acceptance evidence',()=>{const f=fixture();f.live.householdId=id(999);fails(f,'request_undo_access_ended');f.live.householdId=id(100);f.live.assignedShopperId=id(9);fails(f,'request_undo_access_ended');});
for(const index of [0,1])test('retired-link privacy retains required member '+index,()=>{const f=fixture();f.live.privacyMembers[index].available=false;fails(f,'request_undo_history_erased');});
test('child disclosure binds original consent generation, never later reconsent',()=>{const f=fixture({child:true});assert.equal(f.run().candidate.requestUndo.restored.status,'pending');f.live.author.consentId=id(9);fails(f,'request_undo_author_access_ended');});
test('carried destination Undo preserves original carry and cannot recarry its source',()=>{const f=fixture({carried:true,child:true,kind:'legacy'}),x=f.run();assert.deepEqual(x.candidate.requestUndo.carry,f.cert.carry);assert.equal(x.transition.requestId,id(10));f.live.carry[0].sourceCurrentAuthorityEpoch=2;fails(f,'request_undo_origin_access_ended');});
test('same-store basis must be current and its selected basis remain authorized',()=>{const f=fixture();for(const side of ['beforeSnapshot','afterSnapshot']){f.history[side].value.storeBasis={revision:2,reviewRequired:false};f.history[side].digest=digest(f.history[side].value);f.history.record.certificate[side+'Digest']=f.history[side].digest;}f.history.record.digest=digest(f.history.record.certificate);f.current.storeBasis.revision=2;f.live.storeBasis={revision:2,pairId:id(91),choice:'first',selectionDigest:'b'.repeat(64)};assert.equal(f.run().candidate.storeBasis.revision,2);f.live.storeBasis=null;fails(f,'request_undo_store_access_ended');});
function inverse(f){return{operationId:id(900),targetOperationId:id(300),actorId:id(1),deviceId:id(3),authorityEpoch:1,clientKey:id(901),payloadDigest:'c'.repeat(64),acceptanceDigest:f.history.record.digest,
 receipt:{operationId:id(900),kind:'request.undoAcceptance',shopId:id(101),shopRevision:6,authorityEpoch:1,disposition:'acceptanceUndone',requestId:id(10),requestRevision:3}};}
for(const kind of ['tracked','legacy'])test(kind+' acknowledged retry after later author edit/reacceptance returns old receipt, never mutates latest facts',()=>{const f=fixture({kind}),r=inverse(f);f.current.request.state={revision:5,status:'added',route:'current'};f.current.request.content.originalItem='Later request wording';f.current.links[0].operationId=id(902);const before=clone(f.current);assert.deepEqual(replay(f.history,f.live,r,{clientKey:r.clientKey,payloadDigest:r.payloadDigest}),r.receipt);assert.deepEqual(f.current,before);fails(f,'request_undo_request_conflict');});
for(const mutate of [r=>r.clientKey=id(99),r=>r.payloadDigest='d'.repeat(64)])test('retry exact identity/digest mismatch rejects '+String(mutate),()=>{const f=fixture(),r=inverse(f),retry={clientKey:r.clientKey,payloadDigest:r.payloadDigest};mutate(retry);assert.throws(()=>replay(f.history,f.live,r,retry),e=>e.code==='request_undo_retry_changed');});
test('acknowledged retry still refuses erased author, revoked device and changed authority',()=>{const f=fixture(),r=inverse(f),retry={clientKey:r.clientKey,payloadDigest:r.payloadDigest};f.live.author.disclosureLive=false;assert.throws(()=>replay(f.history,f.live,r,retry));f.live.author.disclosureLive=true;f.live.authorityEpoch=2;assert.throws(()=>replay(f.history,f.live,r,retry),e=>e.code==='request_undo_access_ended');});
test('legacy acceptance followed by tracked mapping requires explicit 046 composition, never unchanged-graph substitution',()=>{const f=fixture({kind:'legacy'}),tracked=fixture();f.current.food=tracked.current.food;fails(f,'request_undo_composition_required');});
test('compound request/adoption certificate is recognized but cannot pretend to be tracked inverse',()=>{const f=fixture();f.history.record.certificate.food={kind:'compoundAdoption',afterRevision:1,afterDigest:'a'.repeat(64),receiptDigest:'b'.repeat(64),compositionDigest:'c'.repeat(64)};f.history.record.digest=digest(f.history.record.certificate);f.history.food={kind:'compoundAdoption',after:f.history.food.after,receipt:f.history.food.receipt,compositionDigest:'c'.repeat(64)};fails(f,'request_undo_composition_required');});
for(const mutate of [e=>e.record=null,e=>e.record.digest='0'.repeat(64),e=>e.afterSnapshot.digest='0'.repeat(64),e=>e.operation.payloadDigest='0'.repeat(64),e=>delete e.record.certificate.beforeLink,e=>e.record.certificate.beforeLink={}])test('missing/erased history or required-null evidence never becomes an empty preimage: '+String(mutate),()=>{const f=fixture();mutate(f.history);assert.throws(()=>f.run());});
test('capture rejects unrelated link mutation and original request content mutation',()=>{const f=fixture();assert.throws(()=>captureRequestAcceptance(f.cert,{...f.observed,afterLinks:[]}));assert.throws(()=>captureRequestAcceptance(f.cert,{...f.observed,afterContent:{...f.observed.afterContent,originalItem:'Changed'}}));});
test('certificate cannot admit unsupported decision, missing promotion, different reviewed request revision or duplicate origin',()=>{for(const mutate of [c=>c.decision={choice:'defer'},c=>{c.before.route='next';c.decision.promote=false;},c=>c.afterLink.reviewedRevision=2,c=>c.privacyMemberIds.push(c.authorId)]){const f=fixture();mutate(f.cert);assert.throws(()=>captureRequestAcceptance(f.cert,f.observed));}});
test('normalized historical fields and unknown wire fields are rejected rather than repaired',()=>{const f=fixture();f.cert.decision.line.originalItem=' Request wraps ';assert.throws(()=>captureRequestAcceptance(f.cert,f.observed),e=>e.code==='request_undo_normalized_evidence');const c=fixture().run().candidate;assert.throws(()=>requestUndoCandidateSchema.parse({...c,applyToken:id(1000)}));assert.throws(()=>requestUndoCandidateSchema.parse({...c,foodAfter:{kind:'legacy'}}));});
test('historical graph receipt must prove its exact complete delta',()=>{const f=fixture();f.history.food.receipt.contributions=[];f.history.record.certificate.food.receiptDigest=digest(f.history.food.receipt);f.history.record.digest=digest(f.history.record.certificate);fails(f,'request_undo_receipt_mismatch');});
test('old acceptance cannot silently restore a changed quote or meal',()=>{const f=fixture();f.history.afterSnapshot.value.quote.capMinor++;f.history.afterSnapshot.value.budget=checkout(f.history.afterSnapshot.value.lines,f.history.afterSnapshot.value.quote);f.history.afterSnapshot.digest=digest(f.history.afterSnapshot.value);f.history.record.certificate.afterSnapshotDigest=f.history.afterSnapshot.digest;f.history.record.digest=digest(f.history.record.certificate);fails(f,'request_undo_unexpected_acceptance_effect');});
test('already compensated acceptance cannot derive another inverse',()=>{const f=fixture();assert.throws(()=>undo(f.history,f.current,f.live,{operationId:id(900),at},now,true),e=>e.code==='request_undo_already_reversed');});
test('acceptance capture binds actual pre/post status and route, not a guessed pending preimage',()=>{const f=fixture();assert.throws(()=>captureRequestAcceptance(f.cert,{...f.observed,beforeState:{revision:1,status:'clarified',route:'current'}}),e=>e.code==='request_undo_invalid_transition');});
test('exact reviewed pack evidence and literals survive capture without quantity inference',()=>{
 const f=fixture();f.cert.decision.reviewedPackEvidence={version:1,offerId:'explicit-offer',label:f.addedLine.originalItem,
  needed:{numerator:'2',denominator:'1',unit:'count',originalLiteral:'dos wraps / 2 wraps'},usablePerPack:{numerator:'4',denominator:'1',unit:'count',originalLiteral:'4 per pack'},
  packs:1,unitPriceMinor:150,productMatchConfirmed:true,availabilityConfirmed:true,availablePackLimit:null,quoteSource:' shelf label ',quoteObservedAt:at,reviewedAt:at};
 const captured=captureRequestAcceptance(f.cert,f.observed);assert.deepEqual(captured.certificate.decision.reviewedPackEvidence,f.cert.decision.reviewedPackEvidence);
 const bad=clone(f.cert);bad.decision.reviewedPackEvidence.packs=2;assert.throws(()=>captureRequestAcceptance(bad,f.observed));
});
test('tracked complete acceptance inverse cannot reduce a reservation increased in the same operation',()=>{
 const f=fixture({choice:'link'}),b=f.history.food.before,reserved={...b.contributions[1],quantity:q(3)};
 const a=apply(b,command(b,{contributions:[f.requestSource,reserved]}));
 f.history.food.after=a.graph;f.history.food.receipt=a.receipt;f.current.food.graph=clone(a.graph);
 f.history.record.certificate.food.afterDigest=digest(a.graph);f.history.record.certificate.food.receiptDigest=digest(a.receipt);
 f.history.afterSnapshot.value.demand.digest=digest(a.graph);f.history.afterSnapshot.digest=digest(f.history.afterSnapshot.value);
 f.history.record.certificate.afterSnapshotDigest=f.history.afterSnapshot.digest;f.history.record.digest=digest(f.history.record.certificate);
 assert.throws(()=>f.run(),e=>e.code==='protected_quantity_reduced');
});
test('later edge depending on accepted source cannot survive silent source removal',()=>{
 const f=fixture({choice:'add'}),consumer=source(87,id(21),{kind:'manual'},q(1));
 const edge={id:id(88),kind:'withinExisting',demandId:f.requestSource.id,supplyId:consumer.id,quantity:q(1),confirmation:{productMatchConfirmed:true,confirmedAt:at,evidence:'Later dependency'}};
 f.current.food.graph=apply(f.current.food.graph,command(f.current.food.graph,{contributions:[consumer],edges:[edge]},303)).graph;f.current.shopRevision++;
 assert.throws(()=>f.run(),e=>e.code==='invalid_edge_reference');
});
test('legacy source revision is the reviewed link revision, separate from current request state revision',()=>{
 const f=fixture({kind:'legacy'});assert.equal(f.current.food.catalog[1].revision,1);assert.equal(f.current.request.state.revision,2);f.run();
 f.current.food.catalog[1].revision=2;fails(f,'request_undo_request_source_mismatch');
});
test('operation actor/device and accepted snapshot operation must match immutable lineage',()=>{for(const mutate of [e=>e.operation.actorId=id(999),e=>e.operation.deviceId=id(999),e=>e.afterSnapshot.operationId=id(999)]){const f=fixture();mutate(f.history);assert.throws(()=>f.run());}});
test('candidate wire never trims a padded basket name or supplies omitted fee eligibility',()=>{for(const mutate of [c=>c.action.body.lines[0].originalItem=' Wraps ',c=>delete c.action.body.lines[0].feeEligible]){const c=fixture().run().candidate;mutate(c);assert.throws(()=>requestUndoCandidateSchema.parse(c));}});

for(const kind of ['legacy','tracked'])test(kind+' preview wire is explicit about nullable receipt and requires a separate Apply proof',()=>{
 const f=fixture({kind}),result=f.run(),candidate=result.candidate;
 const packs=candidate.packReviewLineIds.map(lineId=>({lineId,usablePerPack:null,acceptUnresolved:true}));
 const input={targetOperationId:candidate.targetOperationId,base:candidate.base,effectDigest:candidate.effectDigest,packs,acceptOverage:false,acceptUnknown:false};
 assert.deepEqual(requestUndoPreviewInputSchema.parse(input),input);
 assert.throws(()=>requestUndoPreviewInputSchema.parse({...input,action:candidate.action}));
 const response={schemaVersion:1,kind:'requestAcceptanceUndoPreview',candidate,previewId:id(950),previewDigest:'f'.repeat(64),expiresAt:'2026-11-10T13:10:00.000Z',operationId:id(900),packs,foodReceipt:{kind,receipt:result.receipt}};
 assert.deepEqual(requestUndoPreviewResponseSchema.parse(response),response);
 const missing=clone(response);delete missing.foodReceipt.receipt;assert.throws(()=>requestUndoPreviewResponseSchema.parse(missing));
 assert.throws(()=>requestUndoApplyBodySchema.parse(candidate.action.body));
 const body={...candidate.action.body,operationUndoReview:{previewId:response.previewId,previewDigest:response.previewDigest}};
 assert.deepEqual(requestUndoApplyBodySchema.parse(body),body);
 assert.throws(()=>requestUndoApplyBodySchema.parse({...body,decision:{choice:'defer'}}));
});

test('046 recorded snapshot metadata is bound to its exact snapshot revision',()=>{
 const f=fixture();for(const side of ['beforeSnapshot','afterSnapshot']){const row=f.history[side];row.value.tracking={schemaVersion:2,shopRevision:row.value.revision,digest:'e'.repeat(64),status:'recorded'};row.digest=digest(row.value);f.history.record.certificate[side+'Digest']=row.digest;}f.history.record.digest=digest(f.history.record.certificate);f.run();
 f.history.afterSnapshot.value.tracking.shopRevision--;f.history.afterSnapshot.digest=digest(f.history.afterSnapshot.value);f.history.record.certificate.afterSnapshotDigest=f.history.afterSnapshot.digest;f.history.record.digest=digest(f.history.record.certificate);fails(f,'request_undo_snapshot_unavailable');
});
test('common composition preparation retains target revision, link and authority checks without granting graph admission',()=>{
 const f=fixture({kind:'legacy'});assert.deepEqual(validateRequestAcceptanceCoreHistory(f.history),f.history);
 const prepare=()=>prepareRequestAcceptanceUndo(f.history,f.current,f.live,{operationId:id(900),at},now);
 assert.equal(prepare().restored.status,'pending');f.live.deviceActive=false;assert.throws(prepare,e=>e.code==='request_undo_access_ended');f.live.deviceActive=true;f.current.request.state.revision++;assert.throws(prepare,e=>e.code==='request_undo_request_conflict');
});
test('dedicated preview requires explicit monetary acknowledgments, never inferred from packs',()=>{
 const f=fixture(),c=f.run().candidate,input={targetOperationId:c.targetOperationId,base:c.base,effectDigest:c.effectDigest,packs:[]};assert.throws(()=>requestUndoPreviewInputSchema.parse(input));assert.deepEqual(requestUndoPreviewInputSchema.parse({...input,acceptOverage:false,acceptUnknown:true}),{...input,acceptOverage:false,acceptUnknown:true});
});

test('compound component digest binds actual acceptance facts and excludes only snapshot/food hash cycle',()=>{
 const f=fixture(),a=requestAcceptanceComponentDigest(f.cert),other=clone(f.cert);other.beforeSnapshotDigest='e'.repeat(64);other.afterSnapshotDigest='f'.repeat(64);other.food={kind:'compoundAdoption',compositionDigest:'a'.repeat(64)};assert.equal(requestAcceptanceComponentDigest(other),a);
 for(const change of [x=>x.after.revision++,x=>x.decision.line.packs++,x=>x.authorId=id(999),x=>x.afterLinksDigest='b'.repeat(64)]){const c=clone(f.cert);change(c);assert.notEqual(requestAcceptanceComponentDigest(c),a);}
 const missing=clone(f.cert);delete missing.beforeLink;assert.throws(()=>requestAcceptanceComponentDigest(missing));
});
test('partition current state is explicit and cannot fall through the legacy compensation path',()=>{
 const f=fixture(),legacy=fixture({kind:'legacy'}),state={schemaVersion:2,authorityEpoch:1,privacyRevision:0,quoteDigest:digest(f.current.quote),graph:f.current.food.graph,basket:f.current.lines.map(x=>({id:x.lineId,name:x.originalItem,packs:x.packs,priceMinor:x.unitPriceMinor,feeEligible:x.feeEligible})),catalog:legacy.current.food.catalog,bindings:[{factId:id(72),contributionId:id(31)},{factId:id(71),contributionId:id(40)}],unbound:[],legacyLineIds:[],packReviews:f.current.lines.map(x=>({lineId:x.lineId,usablePerPack:q(10),acceptUnresolved:true}))};
 f.current.food={kind:'partition',state};const prepared=prepareRequestAcceptanceUndo(f.history,f.current,f.live,{operationId:id(900),at},now);assert.deepEqual(prepared.current.food,{kind:'partition',state});fails(f,'request_undo_composition_required');
});

for(const kind of ['legacy','tracked'])for(const ownQuantity of ['One LARGE box · 2 × 15 oz',null])test(`${kind} request Undo preserves exact original quantity wording ${ownQuantity===null?'null':'text'}`,()=>{
 const f=fixture({kind,ownQuantity}),before=clone(f.current),candidate=f.run().candidate;
 assert.equal(candidate.requestUndo.originalQuantityText,ownQuantity);
 assert.deepEqual(f.current,before);assert.equal(candidate.action.body.lines.some(l=>Object.hasOwn(l,'originalQuantityText')),false);
 assert.deepEqual(requestUndoCandidateSchema.parse(candidate),candidate);
});
test('original quantity wording is required-null and never inferred from typed graph quantity',()=>{
 const c=fixture({ownQuantity:null}).run().candidate;assert.equal(c.requestUndo.originalQuantityText,null);
 const missing=clone(c);delete missing.requestUndo.originalQuantityText;assert.throws(()=>requestUndoCandidateSchema.parse(missing));
 const empty=clone(c);empty.requestUndo.originalQuantityText='';assert.throws(()=>requestUndoCandidateSchema.parse(empty));
});
