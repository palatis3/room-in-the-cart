/** Authoritative source facts for first adoption; no pack inference or allocation. */
import {sharedMealSchema} from './shared-meal-planning.js';
import {reviewedID} from './reviewed-identity.js';
import type {DemandContribution, DemandQuantity} from './shared-demand-contracts.js';

type Source = DemandContribution['source'];
type Exclusions = NonNullable<DemandContribution['sourceExclusions']>;
export interface LegacyDemandSource {
  id: string;
  source: Source;
  sourceLabel: string;
  productName: string;
  originalText: string;
  originalQuantityText: string|null;
  quantity: DemandQuantity|null;
  sourceExclusions: Exclusions;
  requiredLineId: string|null;
}
type MealQuantity = {amount:{numerator:number;denominator:number};unit:DemandQuantity['unit'];originalLiteral:string};
function quantity(value:MealQuantity|null):DemandQuantity|null {
  if (!value) return null;
  let n=BigInt(value.amount.numerator),d=BigInt(value.amount.denominator),a=n,b=d;
  while(b){[a,b]=[b,a%b];}
  return {amount:{numerator:String(n/a),denominator:String(d/a)},unit:value.unit,
    originalLiteral:value.originalLiteral,confirmedConversion:null};
}
export function mealSourceKey(source:Source):string {
  if(source.kind==='meal')return JSON.stringify(['meal',source.occurrenceId,source.ingredientId,source.groupId,source.bindingId]);
  if(source.kind==='reservation')return JSON.stringify(['reservation',source.originOccurrenceId,source.ingredientId,source.groupId,source.bindingId]);
  return JSON.stringify([source.kind]);
}
export function exactSourceExclusions(actual:Exclusions, expected:Exclusions):boolean {
  const key=(e:Exclusions[number])=>JSON.stringify([e.occurrenceId,e.ingredientId,e.label]);
  const required=new Set(expected.map(key)),supplied=new Set(actual.map(key));
  return actual.length===required.size && supplied.size===required.size && [...supplied].every(k=>required.has(k));
}

/** Existing graphs may explicitly represent a wholly protected ingredient once.
 * New catalogs preserve explicit group bindings, including protected unknowns. */
export function mealDemandSources(shopId:string, occurrences:{occurrenceId:string;meal:unknown}[],
  wholeProtectedIngredients:ReadonlySet<string>=new Set()):LegacyDemandSource[] {
  const sources:LegacyDemandSource[]=[];
  for(const occurrence of occurrences){
    const meal=sharedMealSchema.parse(occurrence.meal),occurrenceId=occurrence.occurrenceId;
    for(const ingredient of meal.planning?.ingredients??[]){
      const labels=[...(meal.planning?.exclusions??[]).map(label=>({occurrenceId,ingredientId:null,label})),
        ...ingredient.exclusions.map(label=>({occurrenceId,ingredientId:ingredient.id,label}))];
      const sourceExclusions:Exclusions=[...new Map(labels.map(e=>[JSON.stringify([e.occurrenceId,e.ingredientId,e.label]),e])).values()]
        .map(e=>({...e,resolution:{kind:'unresolved' as const}}));
      const emit=(groupId:string|null,bindingId:string|null,value:MealQuantity|null,protectedNeed:boolean,purpose:string)=>{
        const identity=[occurrenceId,ingredient.id,groupId??'',bindingId??''];
        const source:Source=protectedNeed?{kind:'reservation',reservationId:reviewedID(shopId,'legacy-demand-reservation-v1',...identity),
          purpose,originOccurrenceId:occurrenceId,ingredientId:ingredient.id,groupId,bindingId}:
          {kind:'meal',occurrenceId,ingredientId:ingredient.id,groupId,bindingId};
        sources.push({id:reviewedID(shopId,'legacy-demand-source-v1',source.kind,...identity),source,sourceLabel:meal.title,
          productName:ingredient.name,originalText:ingredient.name,originalQuantityText:value?.originalLiteral??null,
          quantity:quantity(value),sourceExclusions,requiredLineId:null});
      };
      const bindings=meal.planning?.bindings?.filter(b=>b.ingredientId===ingredient.id)??[];
      const wholeProtected=meal.protected&&wholeProtectedIngredients.has(occurrenceId+'/'+ingredient.id);
      if(!bindings.length||wholeProtected)emit(null,null,ingredient.quantity,meal.protected,meal.title);
      else for(const binding of bindings){
        const group=meal.planning!.groups.find(g=>g.id===binding.groupId)!;
        emit(group.id,binding.id,binding.quantity,meal.protected||group.protected,group.name);
      }
      if(!(meal.protected&&(!bindings.length||wholeProtected))) {
        for(const group of meal.planning!.groups.filter(g=>(meal.protected||g.protected)&&ingredient.groupIds.includes(g.id)&&!bindings.some(b=>b.groupId===g.id))) {
          emit(group.id,null,null,true,group.name);
        }
      }
    }
  }
  return sources;
}

export function requestDemandSource(shopId:string, row:{request_id:string;line_id:string;reviewed_revision:number;original_item:string;own_quantity:string|null}):LegacyDemandSource {
  return {id:reviewedID(shopId,'legacy-demand-request-v1',row.request_id),
    source:{kind:'request',requestId:row.request_id,appliedRequestRevision:row.reviewed_revision},
    sourceLabel:row.original_item,productName:row.original_item,originalText:row.original_item,
    originalQuantityText:row.own_quantity,quantity:null,sourceExclusions:[],requiredLineId:row.line_id};
}
