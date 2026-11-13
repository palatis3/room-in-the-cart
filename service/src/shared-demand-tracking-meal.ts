/** Meal component identity for first-adoption composition. Uses existing 045/047
 * evidence; no inferred absence, resurrected proposal or new authority table. */
import type {Context,Shop} from './repository.js';
import {digest} from './database.js';
import {digest as trackingDigest} from './shared-demand-tracking.js';
import {loadCreatedMealUndoRecord} from './shared-food-meal-creation-undo.js';
import {loadMealUndoEvidence,deriveMealUndo,validateMealUndoHistory} from './shared-food-meal-undo.js';
import {validateCompoundAdoptionEvidence,type CompoundAdoptionEvidence} from './shared-demand-compound-adoption.js';
import {ServiceError} from './errors.js';
function check(v:unknown):asserts v{if(!v)throw new ServiceError(409,'tracking_meal_history_unavailable','Review the complete meal and food change.');}
/** Called after recording the immutable effect and before actual meal mutation.
 * Full before/after rows and live author/proposal evidence are reloaded for Undo. */
export async function mealComponentForTracking(ctx:Context,shop:Shop,operationId:string){
 const ordinary=(await ctx.db.query('SELECT * FROM ritc.shared_food_meal_effect WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',
  [ctx.householdId,shop.shop_id,operationId])).rows[0];
 const created=await loadCreatedMealUndoRecord(ctx,shop,operationId);check(!(ordinary&&created));const r=ordinary??created;if(!r)return null;
 const lineage={householdId:r.household_id,shopId:r.shop_id,operationId:r.operation_id,occurrenceId:r.occurrence_id,
  beforeRevision:r.before_meal_revision,afterRevision:r.result_meal_revision,beforeDigest:r.before_meal_digest,afterDigest:r.result_meal_digest,
  proposalKind:r.proposal_kind,proposalId:r.proposal_id,proposalDigest:r.proposal_digest};
 return{kind:'meal' as const,occurrenceId:lineage.occurrenceId as string,componentDigest:digest(lineage)};
}
const basket=(ls:any[])=>ls.map(l=>({id:l.lineId,name:l.originalItem,packs:l.packs,priceMinor:l.unitPriceMinor,feeEligible:l.feeEligible})).sort((a,b)=>a.id.localeCompare(b.id));
export async function validateCompoundMealHistory(ctx:Context,shop:Shop,raw:CompoundAdoptionEvidence){
 const t=validateCompoundAdoptionEvidence(raw);check(t.component.kind==='meal');
 const effect=(await ctx.db.query('SELECT * FROM ritc.shared_food_operation_effect WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',
  [ctx.householdId,shop.shop_id,t.operationId])).rows[0];
 check(effect&&effect.classification==='first_adoption'&&effect.base_graph_revision===0&&effect.result_graph_revision===1&&
  effect.result_shop_revision===effect.base_shop_revision+1);
 const rows=(await ctx.db.query('SELECT revision,snapshot,digest,operation_id FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=ANY($3::integer[])',
  [ctx.householdId,shop.shop_id,[effect.base_shop_revision,effect.result_shop_revision]])).rows;
 const b=rows.find(r=>r.revision===effect.base_shop_revision),a=rows.find(r=>r.revision===effect.result_shop_revision);
 check(b&&a&&b.digest===digest(b.snapshot)&&a.digest===digest(a.snapshot)&&a.operation_id===t.operationId&&
  b.snapshot.demand===undefined&&b.snapshot.tracking===undefined&&
  digest(basket(b.snapshot.lines))===digest(t.before.basket)&&digest(b.snapshot.quote)===digest(t.beforeQuote)&&
  digest(basket(a.snapshot.lines))===digest(t.after.basket)&&digest(a.snapshot.quote)===digest(t.afterQuote)&&
  digest(a.snapshot.demand)===digest({schemaVersion:1,revision:1,digest:digest(t.after.graph)})&&
  digest(a.snapshot.tracking)===digest({schemaVersion:2,shopRevision:effect.result_shop_revision,digest:trackingDigest(t.after),status:'recorded'}));
 const evidence=await loadMealUndoEvidence(ctx,shop,t.operationId);check(evidence&&evidence.lineage.occurrenceId===t.component.occurrenceId&&
  digest(evidence.lineage)===t.component.componentDigest);
 const scope={householdId:ctx.householdId,shopId:shop.shop_id,operationId:t.operationId,baseShopRevision:effect.base_shop_revision,resultShopRevision:effect.result_shop_revision};
 const beforeRefs=b.snapshot.mealRefs??[],afterRefs=a.snapshot.mealRefs??[];validateMealUndoHistory(evidence,scope,beforeRefs,afterRefs);
 return{evidence,scope,beforeRefs,afterRefs};
}
/** First Apply additionally derives against current facts; exact replay must only
 * authenticate retained history and live authors, never reapply current inversion. */
export async function deriveCompoundMealAction(ctx:Context,shop:Shop,raw:CompoundAdoptionEvidence){
 const {evidence,scope,beforeRefs,afterRefs}=await validateCompoundMealHistory(ctx,shop,raw);
 const inverse=deriveMealUndo(evidence,scope,beforeRefs,afterRefs,shop.revision);
 return{inverse,mealEdit:{occurrenceId:inverse.occurrenceId,baseMealRevision:inverse.current.meal===null?null:inverse.current.revision,meal:inverse.restoredMeal}};
}
