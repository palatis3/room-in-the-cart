import test from 'node:test';
import assert from 'node:assert/strict';
import {captureRequestAcceptance,requestContentDigest,validateRequestAcceptanceHistory,deriveRequestAcceptanceUndo as undo,replayRequestAcceptanceUndo as replay} from '../dist/shared-request-acceptance-undo.js';
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

export {fixture,id,at,now,quote,q,line,source,command};
