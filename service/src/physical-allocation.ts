import { type Rat, zero, add, sub, min } from './physical-quantity.js';

// Within a protection/reservation tier, preserve the established order of
// connected shops. Within one shop, known deadlines precede unknown ones and
// stable reviewed need identity breaks ties independently of query/input order.
export function compareDemandOrder(a:{due:string|null;id:string;scope?:number},b:{due:string|null;id:string;scope?:number}) {
  const scope=(a.scope??0)-(b.scope??0);
  if(scope) return scope;
  const deadline=(a.due===null?Infinity:Date.parse(a.due))-(b.due===null?Infinity:Date.parse(b.due));
  return deadline || (a.id<b.id?-1:a.id>b.id?1:0);
}

export interface Edge { to:number; capacity:Rat; reverse:Edge }
export function connect(graph:Edge[][],from:number,to:number,capacity:Rat):Edge {
  const reverse = {to:from,capacity:zero} as Edge;
  const forward = {to,capacity,reverse};
  reverse.reverse=forward;
  graph[from]!.push(forward);graph[to]!.push(reverse);
  return forward;
}

// Find a path to remaining physical food. Reverse edges can move an earlier
// group's allocation to another reviewed source without reducing its total.
export function allocate(graph:Edge[][],start:number,sink:number,requested:Rat) {
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
