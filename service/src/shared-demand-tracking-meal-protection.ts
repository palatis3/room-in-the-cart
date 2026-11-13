/** A tracking-only quantity review; the default meal guard remains strict.
 * Catalog reads can disclose a cross-unit proposal only for an existing known
 * reservation. Candidate/command evaluation must prove its exact replacement.
 * Neither path changes the authoritative meal or invents an allocation. */
import {preserveProtectedMeal,type SharedMealValue} from './shared-meal-planning.js';
import {validateState,digest,type TrackingState} from './shared-demand-tracking.js';
import {validateDetachedDemandChanges,validateDetachedDemandInverse} from './shared-demand-domain.js';
import type {DemandContribution,DemandQuantity} from './shared-demand-contracts.js';
import {ServiceError} from './errors.js';
export type TrackingMealProtection=(original:SharedMealValue|undefined,next:SharedMealValue|null,occurrenceId:string)=>void;
type MealQuantity=NonNullable<NonNullable<SharedMealValue['planning']>['ingredients'][number]['quantity']>;
type Located={factId:string;location:'tracked'|'transferred';row:DemandContribution};
function reject():never {throw new ServiceError(409,'protected_meal','Keep existing protected portions and ingredient reservations.');}
function rows(state:TrackingState):Located[]{
 return [...state.bindings.map(b=>({factId:b.factId,location:'tracked' as const,row:state.graph.contributions.find(c=>c.id===b.contributionId)!})),
  ...state.unbound.flatMap(u=>u.transferred?[{factId:u.factId,location:'transferred' as const,row:u.transferred}]:[])];
}
function quantityMatches(actual:DemandQuantity|null,expected:MealQuantity){
 return actual!==null&&actual.unit===expected.unit&&actual.originalLiteral===expected.originalLiteral&&
  BigInt(actual.amount.numerator)*BigInt(expected.amount.denominator)===BigInt(expected.amount.numerator)*BigInt(actual.amount.denominator);
}
function protection(before:TrackingState,after:TrackingState|undefined,history?:{before:TrackingState;after:TrackingState}):TrackingMealProtection {
 validateState(before,before.catalog);
 if(before.graph.revision===0)reject();
 if(after){
  validateState(after,after.catalog);
  if(after.graph.householdId!==before.graph.householdId||after.graph.shopId!==before.graph.shopId||
   after.graph.revision!==before.graph.revision+1||after.authorityEpoch!==before.authorityEpoch||after.privacyRevision!==before.privacyRevision)reject();
 }
 if(history){
  validateState(history.before,history.before.catalog);validateState(history.after,history.after.catalog);
  if(history.before.graph.householdId!==before.graph.householdId||history.before.graph.shopId!==before.graph.shopId||
   history.after.graph.householdId!==before.graph.householdId||history.after.graph.shopId!==before.graph.shopId||
   history.after.graph.revision!==history.before.graph.revision+1||history.after.graph.revision>before.graph.revision||
   history.before.privacyRevision!==before.privacyRevision||history.after.privacyRevision!==before.privacyRevision)reject();
 }
 const prior=rows(before),proposed=after?rows(after):undefined;
 return(original,next,occurrenceId)=>{
  if(!original||!next){preserveProtectedMeal(original,next);return;}
  const comparable=structuredClone(next);
  const reviewed=(ingredientId:string,groupId:string|null,bindingId:string|null,oldQuantity:MealQuantity,newQuantity:MealQuantity)=>{
   if(oldQuantity.unit===newQuantity.unit)return false;
   const matches=prior.filter(({row})=>row.removedAt===null&&row.source.kind==='reservation'&&row.source.originOccurrenceId===occurrenceId&&
    row.source.ingredientId===ingredientId&&row.source.groupId===groupId&&row.source.bindingId===bindingId&&quantityMatches(row.quantity,oldQuantity));
   if(matches.length!==1)return false;
   const old=matches[0]!;
   if(proposed){
    const replacement=proposed.find(x=>x.factId===old.factId);
    if(!replacement||replacement.location!==old.location||replacement.row.id!==old.row.id||replacement.row.lineId!==old.row.lineId||
     !quantityMatches(replacement.row.quantity,newQuantity))reject();
    // Exact source identity, original text, product, protection, and converted
    // >= old amount use the same conservation policy as detached/graph edits.
    if(history){
     const original=rows(history.before).find(x=>x.factId===old.factId),accepted=rows(history.after).find(x=>x.factId===old.factId);
     if(!original||!accepted||original.location!==replacement.location||accepted.location!==old.location||digest(original.row)!==digest(replacement.row))reject();
     validateDetachedDemandInverse([old.row],[original.row],[accepted.row]);
    }else validateDetachedDemandChanges([old.row],[replacement.row]);
   }
   return true;
  };
  for(const old of original.planning?.ingredients??[]){
   const replacement=comparable.planning?.ingredients.find(i=>i.id===old.id);
   if(old.quantity&&replacement?.quantity&&reviewed(old.id,null,null,old.quantity,replacement.quantity))replacement.quantity=structuredClone(old.quantity);
  }
  for(const old of original.planning?.bindings??[]){
   const replacement=comparable.planning?.bindings?.find(b=>b.id===old.id);
   if(replacement&&replacement.ingredientId===old.ingredientId&&replacement.groupId===old.groupId&&
    reviewed(old.ingredientId,old.groupId,old.id,old.quantity,replacement.quantity))replacement.quantity=structuredClone(old.quantity);
  }
  // Only the comparison clone uses the old quantities. All structural guards
  // still run, and callers keep next's entered amount/unit/literal unchanged.
  preserveProtectedMeal(original,comparable);
 };
}
/** Preflight only. Every candidate and command must also run the reviewed comparison. */
export function previewTrackingMealProtection(before:TrackingState):TrackingMealProtection {return protection(before,undefined);}
/** Invoke only with current server-derived before and fully validated after state. */
export function reviewedTrackingMealProtection(before:TrackingState,after:TrackingState):TrackingMealProtection {return protection(before,after);}
/** Whole-operation inverse only: caller has authenticated immutable tracking
 * before/after snapshots. No caller-entered reverse conversion is accepted. */
export function reviewedTrackingMealUndoProtection(current:TrackingState,restored:TrackingState,originalBefore:TrackingState,originalAfter:TrackingState):TrackingMealProtection {
 return protection(current,restored,{before:originalBefore,after:originalAfter});
}
