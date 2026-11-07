import { type Edge, connect, allocate } from './physical-allocation.js';
import type { Quantity } from './recovery-contracts.js';
import type { SharedMealValue } from './shared-meal-planning.js';
import { exclusionConflict } from './recovery-domain.js';
import { type Rat, zero, add, sub, min, amount, dimension, inUnit } from './physical-quantity.js';

export interface SealedMeal { occurrenceId:string; revision:number; meal:SharedMealValue }
export interface Match { occurrenceId:string; mealRevision:number; ingredientId:string }
export interface ReservationHead extends Match {
  groupId:string; reservationId:string; quantity:Quantity|null;
}
export interface DeliverySource {
  sourceId:string; foodName:string; exclusionTags:string[]; matches:Match[];
  confirmed:{quantity:Quantity}|null; reservations?:ReservationHead[];
}
type Issue = 'unknownQuantity'|'unknownSplit'|'noMatch'|'unconfirmed'|'unitMismatch'|'exclusion'|'protectedQuantityUnknown'|'reservationShortfall';
interface Need extends Match {
  groupIds:string[]; protected:boolean; required:Quantity|null; issues:Set<Issue>;
  eligible:DeliverySource[];
}
const targetKey = (target:Match) => [target.occurrenceId,target.mealRevision,target.ingredientId].join('/');

export function deliveryCoverage(meals:SealedMeal[],sources:DeliverySource[]) {
  const matched=new Map<string,DeliverySource[]>();
  for(const source of sources) for(const match of source.matches) {
    const key=targetKey(match);
    if(!matched.has(key)) matched.set(key,[]);
    matched.get(key)!.push(source);
  }
  const pins=new Map<string,{sourceId:string;reservationId:string;quantity:Quantity}[]>();
  for(const source of sources) for(const pin of source.reservations??[]) {
    if(!pin.quantity) continue;
    const key=targetKey(pin)+'/'+pin.groupId;
    if(!pins.has(key)) pins.set(key,[]);
    pins.get(key)!.push({sourceId:source.sourceId,reservationId:pin.reservationId,quantity:pin.quantity});
  }
  const needs:Need[]=[];
  const unplannedOccurrenceIds:string[]=[];
  for(const {occurrenceId,revision,meal} of meals) {
    const plan=meal.planning;
    if(!plan?.ingredients.length) { unplannedOccurrenceIds.push(occurrenceId);continue; }
    for(const ingredient of plan.ingredients) {
      const target={occurrenceId,mealRevision:revision,ingredientId:ingredient.id};
      const restrictions={name:ingredient.name,exclusions:[...(plan.exclusions??[]),...ingredient.exclusions]};
      const bindings=(plan.bindings??[]).filter(b=>b.ingredientId===ingredient.id);
      const exact=bindings.length>0 && bindings.length===ingredient.groupIds.length;
      const parts=exact ? bindings.map(b=>({groupIds:[b.groupId],required:b.quantity})) :
        [{groupIds:ingredient.groupIds,required:ingredient.quantity}];
      for(const {groupIds,required} of parts) {
        const issues=new Set<Issue>();
        if(!required) issues.add('unknownQuantity');
        if(!exact && groupIds.length>1) issues.add('unknownSplit');
        const candidates=matched.get(targetKey(target))??[];
        if(!candidates.length) issues.add('noMatch');
        const eligible=candidates.filter(source=>{
          if(exclusionConflict(restrictions,{name:source.foodName,exclusionTags:source.exclusionTags})) {issues.add('exclusion');return false;}
          if(!source.confirmed) {issues.add('unconfirmed');return false;}
          if(required && dimension(required)!==dimension(source.confirmed.quantity)) {issues.add('unitMismatch');return false;}
          return true;
        });
        const protectedGroup=meal.protected || plan.groups.some(g=>g.protected && groupIds.includes(g.id));
        needs.push({...target,groupIds,required,protected:protectedGroup,issues,eligible});
      }
    }
  }
  // A protected commitment with an unknown amount leaves no defensible surplus
  // on its reviewed sources. Rerunning after a correction releases that hold.
  const held=new Set(needs.filter(n=>n.protected && !n.required).flatMap(n=>n.eligible.map(s=>s.sourceId)));
  const stock=new Map<string,number>();
  const sink=needs.length+sources.length;
  const graph:Edge[][]=Array.from({length:sink+1},()=>[]);
  sources.forEach((source,index)=>{
    const node=needs.length+index;
    stock.set(source.sourceId,node);
    if(source.confirmed && !held.has(source.sourceId)) connect(graph,node,sink,amount(source.confirmed.quantity));
  });
  const rows=needs.map((need,index)=>{
    const edges=need.eligible.flatMap(source=>{
      if(held.has(source.sourceId)) {need.issues.add('protectedQuantityUnknown');return [];}
      if(!need.required) return [];
      return [{sourceId:source.sourceId,edge:connect(graph,index,stock.get(source.sourceId)!,amount(need.required))}];
    });
    const requests=(need.groupIds.length===1 ? pins.get(targetKey(need)+'/'+need.groupIds[0])??[] : [])
      .sort((a,b)=>a.sourceId.localeCompare(b.sourceId));
    const reservations=requests.map(pin=>({...pin,backed:zero}));
    return {need,index,edges,reservations,missing:need.required?amount(need.required):zero};
  });
  // Each priority first sets aside its named amounts on their exact sources. A
  // source-to-sink path can reroute earlier flexible allocations without undoing
  // their coverage. Fixed quantities have no reverse edge to another source.
  for(const priority of [true,false]) {
    const group=rows.filter(row=>row.need.protected===priority);
    for(const row of group) for(const pin of row.reservations) {
      const requested=amount(pin.quantity);
      if(row.need.required && row.edges.some(edge=>edge.sourceId===pin.sourceId)) {
        const limit=min(requested,row.missing);
        const remainder=allocate(graph,stock.get(pin.sourceId)!,sink,limit);
        pin.backed=sub(limit,remainder);
        row.missing=sub(row.missing,pin.backed);
      }
      if(sub(requested,pin.backed).n>0n) row.need.issues.add('reservationShortfall');
    }
    for(const row of group) row.missing=allocate(graph,row.index,sink,row.missing);
  }
  return {unplannedOccurrenceIds, needs:rows.map(({need,edges,reservations,missing})=>{
    const {eligible,issues,required,...identity}=need;
    const fixed=new Map(reservations.map(pin=>[pin.sourceId,pin.backed]));
    return {...identity,required,issues:[...issues],covered:required?inUnit(sub(amount(required),missing),required.unit):null,
      missing:required?inUnit(missing,required.unit):null,
      reservations:reservations.map(pin=>({sourceId:pin.sourceId,reservationId:pin.reservationId,
        requested:inUnit(amount(pin.quantity),required!.unit),backed:inUnit(pin.backed,required!.unit)})),
      allocations:edges.flatMap(({sourceId,edge})=>{
        const total=add(edge.reverse.capacity,fixed.get(sourceId)??zero);
        return total.n>0n ? [{sourceId,amount:inUnit(total,required!.unit)}] : [];
      })};
  })};
}
