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

export {fixture,id,at,qty};
