import {coverage,digest} from '../dist/shared-demand-tracking.js';
import {digest as storeDigest} from '../dist/database.js';
export const at='2026-11-10T12:00:00.000Z';
export const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
export function fixture(){
 const quantity={amount:{numerator:'3',denominator:'1'},unit:'count',originalLiteral:'three apples',confirmedConversion:null};
 const quote={currency:'USD',scope:'wholeCheckout',complete:false,capMinor:2000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:null},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:at,expiresAt:'2026-11-11T12:00:00.000Z'};
 const source={kind:'reservation',reservationId:id(21),purpose:'School lunch — original words',originOccurrenceId:id(30),ingredientId:id(31),groupId:null,bindingId:null};
 const restriction={occurrenceId:id(30),ingredientId:id(31),label:'Exact family restriction',resolution:{kind:'unresolved'}};
 const transferred={id:id(21),lineId:id(11),source,productKey:'wraps',productName:'Wraps',originalText:'Unknown lunch wraps',quantity:null,sourceExclusions:[restriction],exclusions:[],contains:[],removedAt:null};
 const catalog=[{id:id(21),revision:2,source,sourceLabel:'Protected lunch',originalText:transferred.originalText,originalQuantityText:null,quantity:null,sourceExclusions:[restriction],requiredLineId:null}];
 const graph={schemaVersion:1,conversionTableVersion:'us-customary-metric-v1',householdId:id(1),shopId:id(2),revision:3,
  lines:[{id:id(10),name:'Apples',unit:'count',originalOrder:0,trashedAt:null},{id:id(11),name:'Wraps',unit:'count',originalOrder:1,trashedAt:at}],
  contributions:[{id:id(20),lineId:id(10),source:{kind:'manual'},productKey:'apples',productName:'Apples',originalText:'Apples',quantity,sourceExclusions:[],exclusions:[],contains:[],removedAt:null}],edges:[],usedIds:[id(10),id(11),id(20),id(21)]};
 const state={schemaVersion:2,authorityEpoch:5,privacyRevision:2,quoteDigest:storeDigest(quote),graph,
  basket:[{id:id(10),name:'Apples',packs:1,priceMinor:200,feeEligible:true},{id:id(11),name:'Wraps',packs:2,priceMinor:null,feeEligible:true}],catalog,bindings:[],unbound:[{factId:id(21),transferred}],legacyLineIds:[id(11)],packReviews:[{lineId:id(10),usablePerPack:quantity,acceptUnresolved:false}]};
 const shop={household_id:id(1),shop_id:id(2),shopper_id:id(90),authority_epoch:5,revision:8,phase:'draft',quote,frozen_revision:null,placed_revision:null,supply_revision:0,demand_revision:3,demand_review_required:false};
 const page={schemaVersion:2,shopId:id(2),shopRevision:8,authorityEpoch:5,status:'enabled',state,projection:null,basisDigest:digest(state),coverage:coverage(state,catalog),checkout:{},freezeReview:{previewId:id(95),previewDigest:'f'.repeat(64),trackingVersion:2}};
 const meals=[{occurrenceId:id(30),revision:2,meal:{title:'Lunch',day:null,kind:'lunch',portions:2,protected:true}}];
 return {shop,page,currentCatalog:catalog,meals};
}
export function erasedFixture(){const f=fixture(),{packReviews,...state}=f.page.state;state.privacyRevision++;
 f.shop.demand_review_required=true;f.page.status='reviewRequired';f.page.state=null;
 f.page.projection={schemaVersion:1,status:'reviewRequired',invalidatedStateDigest:'a'.repeat(64),previousPrivacyRevision:2,state};
 f.page.basisDigest=digest(f.page.projection);f.page.coverage=null;f.page.freezeReview=null;return f;
}
