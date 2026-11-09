import {createHash} from 'node:crypto';
import {amount as unitAmount,dimension as unitDimension,inUnit,add,sub,cmp,zero,type Rat} from './physical-quantity.js';
import {sharedDemandGraphSchema,sharedDemandChangeSchema,sharedDemandReceiptSchema,demandQuantitySchema,
 type DemandGraph,type DemandChange,type DemandReceipt,type DemandQuantity,type DemandContribution,type DemandEdge} from './shared-demand-contracts.js';
export class SharedDemandError extends Error {constructor(readonly code:string){super(code);}}
function requireThat(value:unknown,code:string):asserts value {if(!value)throw new SharedDemandError(code);}
const eq=(a:unknown,b:unknown):boolean=>canonical(a)===canonical(b);
function canonical(v:unknown):string {if(v===null||typeof v!=='object')return JSON.stringify(v);if(Array.isArray(v))return '['+v.map(canonical).join(',')+']';return '{'+Object.entries(v).sort(([a],[b])=>a<b?-1:a>b?1:0).map(([k,x])=>JSON.stringify(k)+':'+canonical(x)).join(',')+'}';}
function unique(values:unknown[],code='duplicate_identity'){requireThat(new Set(values).size===values.length,code);}
const supply=(c:DemandContribution)=>c.source.kind==='manual'||c.source.kind==='import';
const active=(c:DemandContribution)=>c.removedAt===null;
const rat=(q:{numerator:string;denominator:string}):Rat=>({n:BigInt(q.numerator),d:BigInt(q.denominator)});
function reduced(n:bigint,d:bigint):Rat {let a=n<0n?-n:n,b=d;while(b){[a,b]=[b,a%b];}return {n:n/a,d:d/a};}
const mul=(a:Rat,b:Rat)=>reduced(a.n*b.n,a.d*b.d);
const div=(a:Rat,b:Rat)=>reduced(a.n*b.d,a.d*b.n);
const one=(unit:DemandQuantity['unit'])=>({amount:{numerator:'1',denominator:'1'},unit,originalLiteral:'unit'});
// Query the existing table with exactly one numeric unit; never coerce wire rationals to Number.
const unitProbe=(unit:DemandQuantity['unit'])=>({amount:{numerator:1,denominator:1},unit,originalLiteral:'unit'});
const dimension=(q:{unit:DemandQuantity['unit']})=>unitDimension(unitProbe(q.unit));
const amount=(q:{unit:DemandQuantity['unit'];amount:{numerator:string;denominator:string}})=>mul(rat(q.amount),unitAmount(unitProbe(q.unit)));
function bounded(a:Rat){requireThat(a.n>=0n&&a.n<=9223372036854775807n&&a.d>0n&&a.d<=9223372036854775807n,'rational_overflow');return a;}
function checkQuantity(q:DemandQuantity){const b=q.confirmedConversion;if(b)requireThat(dimension(one(b.sourceUnit))!==dimension(one(b.targetUnit)),'invalid_conversion_basis');}
/** Same exact unit table and bidirectional ingredient-specific basis as CoreDomain.Quantity. */
export function convertDemandQuantity(input:unknown,target:DemandQuantity['unit']):Rat|null {
 const q=demandQuantitySchema.parse(input);checkQuantity(q);let base=amount(q);
 if(dimension(q)===dimension(one(target)))return bounded(rat(inUnit(base,target)));
 const b=q.confirmedConversion;if(!b)return null;
 if(dimension(q)===dimension(one(b.sourceUnit))&&dimension(one(target))===dimension(one(b.targetUnit)))
  base=mul(mul(rat(inUnit(base,b.sourceUnit)),rat(b.targetAmountPerSourceUnit)),amount(one(b.targetUnit)));
 else if(dimension(q)===dimension(one(b.targetUnit))&&dimension(one(target))===dimension(one(b.sourceUnit)))
  base=mul(div(rat(inUnit(base,b.targetUnit)),rat(b.targetAmountPerSourceUnit)),amount(one(b.sourceUnit)));
 else return null;
 return bounded(rat(inUnit(base,target)));
}
function sameProduct(a:DemandContribution,b:DemandContribution){
 requireThat(a.productKey!==null&&a.productKey===b.productKey,'product_match_required');
 requireThat(!a.exclusions.some(x=>b.contains.includes(x))&&!b.exclusions.some(x=>a.contains.includes(x)),'excluded_product');
}
function roots(graph:DemandGraph){
 const parent=new Map(graph.contributions.filter(active).map(c=>[c.id,c.id]));
 function root(id:string):string {let r=id;while(parent.get(r)!==r){r=parent.get(r)!;}return r;}
 for(const e of graph.edges.filter(e=>e.kind==='duplicate')){const a=root(e.demandId),b=root(e.supplyId);if(a!==b)parent.set(a,b);}
 return new Map([...parent.keys()].map(id=>[id,root(id)]));
}
function cycleCheck(edges:DemandEdge[]){
 const links=new Map<string,string[]>();for(const e of edges)links.set(e.demandId,[...(links.get(e.demandId)??[]),e.supplyId]);
 const done=new Set<string>(),visiting=new Set<string>();
 for(const start of links.keys()){
  const stack:[string,boolean][]=[[start,false]];
  while(stack.length){const [id,exit]=stack.pop()!;if(exit){visiting.delete(id);done.add(id);continue;}if(done.has(id))continue;
   requireThat(!visiting.has(id),'allocation_cycle');visiting.add(id);stack.push([id,true]);for(const child of links.get(id)??[])stack.push([child,false]);}
 }
}
export function validateDemandGraph(input:unknown):DemandGraph {
 const g=sharedDemandGraphSchema.parse(input);unique(g.usedIds);unique(g.lines.map(l=>l.originalOrder),'duplicate_order');
 const ids=[...g.lines,...g.contributions,...g.edges].map(x=>x.id);unique(ids);requireThat(ids.every(id=>g.usedIds.includes(id)),'unregistered_identity');
 const lines=new Map(g.lines.map(l=>[l.id,l])),sources=new Map(g.contributions.map(c=>[c.id,c]));
 const provenance:string[]=[];
 for(const c of g.contributions){requireThat(lines.has(c.lineId),'unknown_line');if(active(c))requireThat(lines.get(c.lineId)!.trashedAt===null,'trashed_source_line');
  unique(c.exclusions,'duplicate_exclusion');unique(c.contains,'duplicate_product_fact');requireThat(!c.exclusions.some(x=>c.contains.includes(x)),'excluded_product');
  if(c.quantity)checkQuantity(c.quantity);
  unique((c.sourceExclusions??[]).map(e=>JSON.stringify([e.occurrenceId,e.ingredientId,e.label])),'duplicate_source_exclusion');
  for(const e of c.sourceExclusions??[]){
   const occurrence=c.source.kind==='meal'?c.source.occurrenceId:c.source.kind==='reservation'?c.source.originOccurrenceId:null;
   requireThat(occurrence!==null&&e.occurrenceId===occurrence&&(c.source.kind==='meal'||c.source.kind==='reservation')&&(e.ingredientId===null||e.ingredientId===c.source.ingredientId),'invalid_exclusion_origin');
   if(e.resolution.kind==='mapped'){unique(e.resolution.tags,'duplicate_exclusion');requireThat(e.resolution.tags.every(tag=>c.exclusions.includes(tag)),'missing_mapped_exclusion');}
  }
  if(c.source.kind==='request')provenance.push('request/'+c.source.requestId);
  if(c.source.kind==='import')provenance.push('import/'+c.source.batchId+'/'+c.source.entryId);
  if(c.source.kind==='meal') {requireThat((c.source.groupId===null)===(c.source.bindingId===null),'invalid_group_binding');provenance.push('meal/'+c.source.occurrenceId+'/'+c.source.ingredientId+'/'+c.source.groupId);}
  if(c.source.kind==='reservation'){requireThat(c.source.bindingId===null||c.source.groupId!==null,'invalid_group_binding');provenance.push('reservation/'+c.source.reservationId);}
 }
 unique(provenance,'duplicate_source');unique(g.edges.filter(e=>e.kind==='duplicate').map(e=>e.demandId+'/'+e.supplyId),'duplicate_edge');
 for(const e of g.edges){const d=sources.get(e.demandId),s=sources.get(e.supplyId);
  requireThat(d&&s&&d.id!==s.id&&active(d)&&active(s)&&d.lineId===s.lineId,'invalid_edge_reference');sameProduct(d,s);
  requireThat(![d,s].some(c=>c.sourceExclusions?.some(e=>e.resolution.kind==='unresolved')),'unresolved_exclusion');
  requireThat(d.quantity&&s.quantity,'unknown_edge_quantity');checkQuantity(e.quantity);
  const unit=lines.get(d.lineId)!.unit;
  const needed=convertDemandQuantity(d.quantity,unit),used=convertDemandQuantity(e.quantity,unit),available=convertDemandQuantity(s.quantity,unit);
  requireThat(needed&&used&&available,'incompatible_units');
  // A link cannot introduce a conflicting ingredient conversion basis. Check the
  // same allocated amount through each endpoint's basis and the line's fixed unit.
  for(const endpoint of [d.quantity,s.quantity]){
   const inEndpoint=convertDemandQuantity(e.quantity,endpoint.unit);requireThat(inEndpoint,'incompatible_units');
   const throughEndpoint=convertDemandQuantity({...endpoint,amount:{numerator:inEndpoint.n.toString(),denominator:inEndpoint.d.toString()}},unit);
   requireThat(throughEndpoint&&cmp(throughEndpoint,used)===0n,'conflicting_conversion_basis');
  }
  if(e.kind==='duplicate'){
   requireThat(supply(d)&&supply(s),'invalid_duplicate_source');
   // Import duplicate selection requires the same reviewed amount, as local duplicateSupply does.
   requireThat(cmp(needed,available)===0n&&cmp(used,needed)===0n,'duplicate_amount_mismatch');
  }else requireThat(!supply(d)&&supply(s),'invalid_within_source');
 }
 cycleCheck(g.edges);const groups=roots(g),usedDemand=new Map<string,Rat>(),usedSupply=new Map<string,Rat>();
 const representatives=new Map<string,DemandContribution>();for(const c of g.contributions.filter(c=>active(c)&&supply(c)))if(!representatives.has(groups.get(c.id)!))representatives.set(groups.get(c.id)!,c);
 for(const e of g.edges.filter(e=>e.kind==='withinExisting')){
  const d=sources.get(e.demandId)!,s=representatives.get(groups.get(e.supplyId)!)!;
  const unit=lines.get(d.lineId)!.unit;
  const need=convertDemandQuantity(e.quantity,unit),available=convertDemandQuantity(e.quantity,unit);
  requireThat(need&&available,'incompatible_units');
  usedDemand.set(d.id,bounded(add(usedDemand.get(d.id)??zero,need)));
  usedSupply.set(s.id,bounded(add(usedSupply.get(s.id)??zero,available)));
 }
 for(const [id,used] of [...usedDemand,...usedSupply]){const source=sources.get(id)!;const capacity=convertDemandQuantity(source.quantity,lines.get(source.lineId)!.unit)!;requireThat(cmp(used,capacity)<=0n,'allocation_exceeds_quantity');}
 // Check that a resolvable line has no overflowing or negative aggregate.
 for(const line of g.lines){
  const members=g.contributions.filter(c=>active(c)&&c.lineId===line.id);
  if(members.length>1)for(const member of members.slice(1))sameProduct(members[0]!,member);
  const exclusions=new Set(members.flatMap(member=>member.exclusions));
  requireThat(!members.some(member=>member.contains.some(fact=>exclusions.has(fact))),'excluded_product');
  lineTotal(g,line.id);
 }
 return g;
}
function lineTotal(g:DemandGraph,id:string):{amount:{numerator:string;denominator:string};unit:DemandQuantity['unit']}|null {
 const members=g.contributions.filter(c=>active(c)&&c.lineId===id);if(!members.length)return null;
 const unit=g.lines.find(l=>l.id===id)!.unit;const group=roots(g),totals=new Map<string,Rat>();
 for(const c of members){if(!c.quantity)return null;const value=convertDemandQuantity(c.quantity,unit);if(!value)return null;
  const key=group.get(c.id)!;if(!totals.has(key)||cmp(value,totals.get(key)!)>0n)totals.set(key,value);}
 let total=zero;for(const value of totals.values())total=add(total,value);
 for(const e of g.edges.filter(e=>e.kind==='withinExisting'&&members.some(c=>c.id===e.demandId))){const q=convertDemandQuantity(e.quantity,unit);if(!q)return null;total=sub(total,q);}
 bounded(total);
 return {amount:{numerator:total.n.toString(),denominator:total.d.toString()},unit};
}
export function demandLineQuantity(graph:unknown,lineId:string){const g=validateDemandGraph(graph);requireThat(g.lines.some(l=>l.id===lineId),'unknown_line');return lineTotal(g,lineId);}
/** Derived food needs, not pack counts or a claim that restrictions are resolved. */
export function demandLineTotals(graph:unknown){
 const g=validateDemandGraph(graph);
 return g.lines.flatMap(line=>{
  const activeContributionIds=g.contributions.filter(c=>active(c)&&c.lineId===line.id).map(c=>c.id);
  if(line.trashedAt!==null||!activeContributionIds.length)return [];
  return [{lineId:line.id,unit:line.unit,quantity:lineTotal(g,line.id)?.amount??null,activeContributionIds}];
 });
}
function conserve(before:DemandGraph,after:DemandGraph,restoring:ReadonlySet<string>=new Set(),quantifying:ReadonlySet<string>=new Set(),clarifying:ReadonlySet<string>=new Set()){
 for(const old of before.contributions){const next=after.contributions.find(c=>c.id===old.id);requireThat(next,'source_hard_delete');
  const bindingResolved=quantifying.has(old.id)&&old.source.kind==='reservation'&&next.source.kind==='reservation'&&old.source.bindingId===null&&next.source.bindingId!==null&&eq({...next.source,bindingId:null},old.source);
  requireThat(eq(next.source,old.source)||bindingResolved,'source_identity_changed');
  requireThat(next.originalText===old.originalText,'original_source_text_changed');
  if(old.removedAt!==null&&!restoring.has(old.id))requireThat(eq(next,old),'tombstone_changed');
  if(active(old)&&old.source.kind==='reservation'){
   requireThat(active(next)&&(next.productKey===old.productKey||(clarifying.has(old.id)&&old.productKey===null&&next.productKey!==null))&&next.productName===old.productName&&eq(next.contains,old.contains)&&old.exclusions.every(e=>next.exclusions.includes(e)),'protected_share_changed');
   if(old.quantity===null)requireThat(eq(next.quantity,old.quantity)||(quantifying.has(old.id)&&next.quantity!==null),'protected_unknown_changed');
   else {const q=next.quantity&&convertDemandQuantity(next.quantity,old.quantity.unit);requireThat(q&&cmp(q,rat(old.quantity.amount))>=0n,'protected_quantity_reduced');}
  }
 }
}
function repairId(operation:string,demand:string,supplyId:string){
 const bytes=createHash('sha1').update(Buffer.from(operation.replaceAll('-',''),'hex')).update('shared-demand-duplicate/'+demand+'/'+supplyId).digest().subarray(0,16);
 bytes[6]=(bytes[6]!&0x0f)|0x50;bytes[8]=(bytes[8]!&0x3f)|0x80;const h=bytes.toString('hex');return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;
}
function delta<T extends {id:string}>(before:T[],after:T[]){const ids=new Set([...before,...after].map(x=>x.id));return [...ids].flatMap(id=>{
 const b=before.find(x=>x.id===id)??null,a=after.find(x=>x.id===id)??null;return eq(a,b)?[]:[{id,before:b,after:a}];});}
function finish(before:DemandGraph,next:DemandGraph,operationId:string,restoring:ReadonlySet<string>=new Set(),quantifying:ReadonlySet<string>=new Set(),clarifying:ReadonlySet<string>=new Set()){
 requireThat(before.revision<2147483647,'revision_overflow');next.revision=before.revision+1;conserve(before,next,restoring,quantifying,clarifying);next=validateDemandGraph(next);
 const receipt=sharedDemandReceiptSchema.parse({schemaVersion:1,operationId,householdId:before.householdId,shopId:before.shopId,baseRevision:before.revision,resultRevision:next.revision,
  lines:delta(before.lines,next.lines),contributions:delta(before.contributions,next.contributions),edges:delta(before.edges,next.edges)});
 requireThat(receipt.lines.length+receipt.contributions.length+receipt.edges.length>0,'no_change');return {graph:next,receipt};
}
export function applyDemandChange(input:unknown,change:unknown){
 const g=validateDemandGraph(input),c=sharedDemandChangeSchema.parse(change),next=structuredClone(g);
 requireThat(c.householdId===g.householdId&&c.shopId===g.shopId,'wrong_scope');requireThat(c.baseRevision===g.revision,'stale_revision');
 unique(c.quantifyReservationIds??[]);const quantifying=new Set(c.quantifyReservationIds??[]);
 for(const id of quantifying){const old=g.contributions.find(x=>x.id===id),next=c.contributions.find(x=>x.id===id);requireThat(old&&active(old)&&old.source.kind==='reservation'&&old.quantity===null&&next?.quantity!==null&&next?.quantity!==undefined,'invalid_reservation_quantification');}
 unique(c.clarifyReservationProductIds??[]);const clarifying=new Set(c.clarifyReservationProductIds??[]);
 for(const id of clarifying){const old=g.contributions.find(x=>x.id===id),replacement=c.contributions.find(x=>x.id===id);
  requireThat(old&&active(old)&&old.source.kind==='reservation'&&old.productKey===null&&replacement&&active(replacement)
   &&replacement.productKey!==null&&eq({...replacement,productKey:null},old),'invalid_reservation_product_clarification');}
 const touched=[...c.lines,...c.contributions,...c.edges].map(x=>x.id);unique(touched);unique(c.removeSourceIds);unique(c.removeEdgeIds);
 requireThat(!c.removeSourceIds.some(id=>touched.includes(id))&&!c.removeEdgeIds.some(id=>touched.includes(id)),'conflicting_change');
 function upsert<T extends {id:string}>(rows:T[],updates:T[]){for(const row of updates){const index=rows.findIndex(x=>x.id===row.id);
  if(index<0){requireThat(!next.usedIds.includes(row.id),'identity_reused');next.usedIds.push(row.id);rows.push(row);}else rows[index]=row;}}
 upsert(next.lines,c.lines);upsert(next.contributions,c.contributions);upsert(next.edges,c.edges);
 for(const id of c.removeEdgeIds)requireThat(next.edges.some(e=>e.id===id),'unknown_edge');next.edges=next.edges.filter(e=>!c.removeEdgeIds.includes(e.id));
 // Source removal may rehome existing links only within an already-proven duplicate class.
 // Validate explicit edits before deriving automatic conservation repairs.
 validateDemandGraph(next);const oldRoots=roots(next),removing=new Set(c.removeSourceIds);
 for(const id of removing){const source=next.contributions.find(s=>s.id===id);requireThat(source&&active(source),'unknown_active_source');requireThat(source.source.kind!=='reservation','protected_share_changed');}
 for(const edge of next.edges.filter(e=>e.kind==='withinExisting'&&removing.has(e.supplyId)&&!removing.has(e.demandId))){
  const replacement=next.contributions.filter(s=>active(s)&&supply(s)&&!removing.has(s.id)&&oldRoots.get(s.id)===oldRoots.get(edge.supplyId)).sort((a,b)=>a.id<b.id?-1:1)[0];
  if(replacement)edge.supplyId=replacement.id;
 }
 next.edges=next.edges.filter(e=>!removing.has(e.demandId)&&!removing.has(e.supplyId));
 for(const source of next.contributions)if(removing.has(source.id))source.removedAt=c.at;
 // Removing a duplicate hub cannot turn its surviving aliases into extra demand.
 const survivors=next.contributions.filter(s=>active(s)&&supply(s)),newRoots=roots(next);
 for(const source of survivors){const anchor=survivors.find(s=>oldRoots.get(s.id)===oldRoots.get(source.id));
  if(anchor&&newRoots.get(anchor.id)!==newRoots.get(source.id)){
   const id=repairId(c.operationId,source.id,anchor.id);requireThat(!next.usedIds.includes(id),'identity_reused');
   next.usedIds.push(id);next.edges.push({id,kind:'duplicate',demandId:source.id,supplyId:anchor.id,quantity:source.quantity!,
    confirmation:{productMatchConfirmed:true,confirmedAt:c.at,evidence:'Conserved previously confirmed duplicate class during source removal'}});
   const current=roots(next);for(const [key,value] of current)newRoots.set(key,value);
  }
 }
 for(const line of next.lines)if(line.trashedAt===null&&!next.contributions.some(s=>active(s)&&s.lineId===line.id))line.trashedAt=c.at;
 return finish(g,next,c.operationId,new Set(),quantifying,clarifying);
}
/** Receipt must come from trusted persisted reducer output, never an unchecked client body.
 * Authorization, operation replay, preview expiry and durable atomicity belong to the future API. */
export function undoDemandChange(input:unknown,storedReceipt:unknown,command:unknown){
 const g=validateDemandGraph(input),r=sharedDemandReceiptSchema.parse(storedReceipt),c=sharedDemandChangeSchema.parse(command);
 requireThat(c.lines.length+c.contributions.length+c.edges.length+c.removeSourceIds.length+c.removeEdgeIds.length+(c.quantifyReservationIds?.length??0)+(c.clarifyReservationProductIds?.length??0)===0,'undo_has_changes');
 requireThat(c.householdId===g.householdId&&c.shopId===g.shopId&&r.householdId===g.householdId&&r.shopId===g.shopId,'wrong_scope');
 requireThat(c.baseRevision===g.revision&&r.resultRevision<=g.revision&&r.resultRevision===r.baseRevision+1,'stale_revision');
 requireThat(!r.contributions.some(x=>x.before?.source.kind==='reservation'&&x.before.quantity===null&&x.after?.quantity!==null),'protected_quantification_undo');
 requireThat(!r.contributions.some(x=>x.before?.source.kind==='reservation'&&x.before.productKey===null&&x.after!==null&&x.after.productKey!==null),'protected_product_clarification_undo');
 const next=structuredClone(g);
 for(const rows of [r.lines,r.contributions,r.edges]){unique(rows.map(x=>x.id));for(const row of rows)requireThat((row.before===null||row.before.id===row.id)&&(row.after===null||row.after.id===row.id),'invalid_receipt');}
 function restore<T extends {id:string}>(rows:T[],changes:{id:string;before:T|null;after:T|null}[],created:(row:T)=>T|null):T[]{
  for(const change of changes){const found=rows.find(row=>row.id===change.id)??null;requireThat(eq(found,change.after),'undo_conflict');
   const replacement=change.before??(change.after&&created(change.after));rows=rows.filter(row=>row.id!==change.id);if(replacement)rows.push(replacement);}
  return rows;
 }
 next.contributions=restore(next.contributions,r.contributions,row=>({...row,removedAt:c.at}));
 next.edges=restore(next.edges,r.edges,()=>null);
 next.lines=restore(next.lines,r.lines,row=>({...row,trashedAt:next.contributions.some(s=>active(s)&&s.lineId===row.id)?null:c.at}));
 // Only the exact receipt-bound tombstones may be restored; finish still records
 // their actual prior state, and all protected/identity invariants remain checked.
 const restoring=new Set(r.contributions.filter(x=>x.before?.removedAt===null&&x.after?.removedAt!==null).map(x=>x.id));
 return finish(g,next,c.operationId,restoring);
}
