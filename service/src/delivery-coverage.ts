import type { Quantity } from './recovery-contracts.js';
import type { SharedMealValue } from './shared-meal-planning.js';
import { exclusionConflict } from './recovery-domain.js';
import { type Rat, zero, add, sub, min, amount, dimension, inUnit } from './physical-quantity.js';

export interface SealedMeal { occurrenceId:string; revision:number; meal:SharedMealValue }
interface Match { occurrenceId:string; mealRevision:number; ingredientId:string }
interface Source {
  sourceId:string; foodName:string; exclusionTags:string[]; matches:Match[];
  confirmed:{quantity:Quantity}|null;
}
type Issue = 'unknownQuantity'|'unknownSplit'|'noMatch'|'unconfirmed'|'unitMismatch'|'exclusion'|'protectedQuantityUnknown';
interface Need extends Match {
  groupIds:string[]; protected:boolean; required:Quantity|null; issues:Set<Issue>;
  eligible:Source[];
}
const targetKey = (target:Match) => [target.occurrenceId,target.mealRevision,target.ingredientId].join('/');

interface Edge { to:number; capacity:Rat; reverse:Edge }
function connect(graph:Edge[][],from:number,to:number,capacity:Rat):Edge {
  const reverse = {to:from,capacity:zero} as Edge;
  const forward = {to,capacity,reverse};
  reverse.reverse=forward;
  graph[from]!.push(forward);graph[to]!.push(reverse);
  return forward;
}

// Find a path to remaining physical food. Reverse edges can move an earlier
// group's allocation to another reviewed source without reducing its total.
function allocate(graph:Edge[][],start:number,sink:number,requested:Rat) {
  let missing=requested;
  while(missing.n>0n) {
    const previous=new Map<number,Edge>();
    const queue=[start];
    for(let head=0;head<queue.length && !previous.has(sink);head++) {
      for(const edge of graph[queue[head]!]!) {
        if(edge.capacity.n===0n || edge.to===start || previous.has(edge.to)) continue;
        previous.set(edge.to,edge);queue.push(edge.to);
        if(edge.to===sink) break;
      }
    }
    if(!previous.has(sink)) break;
    const path:Edge[]=[];
    let delta=missing;
    for(let node=sink;node!==start;) {
      const edge=previous.get(node)!;
      path.push(edge);delta=min(delta,edge.capacity);node=edge.reverse.to;
    }
    for(const edge of path) {
      edge.capacity=sub(edge.capacity,delta);
      edge.reverse.capacity=add(edge.reverse.capacity,delta);
    }
    missing=sub(missing,delta);
  }
  return missing;
}

export function deliveryCoverage(meals:SealedMeal[],sources:Source[]) {
  const matched=new Map<string,Source[]>();
  for(const source of sources) for(const match of source.matches) {
    const key=targetKey(match);
    if(!matched.has(key)) matched.set(key,[]);
    matched.get(key)!.push(source);
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
    return {need,index,edges,missing:zero};
  });
  // Input meals follow the reviewed civil date and stable occurrence ID. Preserve
  // that order within each priority, including when earlier flows are rerouted.
  for(const row of [...rows].sort((a,b)=>Number(b.need.protected)-Number(a.need.protected))) {
    if(row.need.required) row.missing=allocate(graph,row.index,sink,amount(row.need.required));
  }
  return {unplannedOccurrenceIds, needs:rows.map(({need,edges,missing})=>{
    const {eligible,issues,required,...identity}=need;
    return {...identity,required,issues:[...issues],covered:required?inUnit(sub(amount(required),missing),required.unit):null,
      missing:required?inUnit(missing,required.unit):null,
      allocations:edges.filter(({edge})=>edge.reverse.capacity.n>0n).map(({sourceId,edge})=>
        ({sourceId,amount:inUnit(edge.reverse.capacity,required!.unit)}))};
  })};
}
