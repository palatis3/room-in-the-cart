/** Read-only reconciliation of authoritative meal facts with persisted graph identities. */
import {digest} from './database.js';
import {ServiceError} from './errors.js';
import {convertDemandQuantity} from './shared-demand-domain.js';
import {mealDemandSources,mealSourceKey,type LegacyDemandSource} from './shared-demand-sources.js';
import type {DemandGraph,DemandContribution} from './shared-demand-contracts.js';

export interface ActionDemandSource {
 before:DemandContribution|null;
 proposed:LegacyDemandSource;
 transition:'retain'|'update'|'new'|'quantifyReservation';
}
export interface ActionDemandSourceCatalog {
 sources:ActionDemandSource[];
 retirementCandidates:string[];
 retainedContributionIds:string[];
}
const fail=(code:string):never=>{throw new ServiceError(409,code,'Refresh and review the exact meal source identities.');};
const isMeal=(c:DemandContribution)=>c.source.kind==='meal'||c.source.kind==='reservation';
function lineage(source:DemandContribution['source']):string {
 if(source.kind==='meal')return JSON.stringify(['meal',source.occurrenceId,source.ingredientId,source.groupId]);
 if(source.kind==='reservation')return JSON.stringify(['reservation',source.originOccurrenceId,source.ingredientId,source.groupId]);
 return JSON.stringify([source.kind]);
}
const exclusionKey=(e:NonNullable<DemandContribution['sourceExclusions']>[number])=>JSON.stringify([e.occurrenceId,e.ingredientId,e.label]);

export function actionDemandSources(shopId:string,occurrences:{occurrenceId:string;meal:unknown}[],before:DemandGraph|null):ActionDemandSourceCatalog {
 const existing=before?.contributions??[],active=existing.filter(c=>c.removedAt===null&&isMeal(c));
 const wholeProtected=new Set(active.flatMap(c=>c.source.kind==='reservation'&&c.source.originOccurrenceId&&c.source.groupId===null&&c.source.bindingId===null?[c.source.originOccurrenceId+'/'+c.source.ingredientId]:[]));
 const facts=mealDemandSources(shopId,occurrences,wholeProtected),matched=new Set<string>();
 if(facts.length>2000)fail('demand_source_limit');
 const sources:ActionDemandSource[]=facts.map(fact=>{
  let matches=active.filter(c=>mealSourceKey(c.source)===mealSourceKey(fact.source));
  let quantifying=false;
  if(!matches.length&&fact.source.kind==='reservation'&&fact.source.bindingId!==null&&fact.quantity!==null){
   matches=active.filter(c=>c.source.kind==='reservation'&&c.source.bindingId===null&&c.quantity===null&&lineage(c.source)===lineage(fact.source));
   quantifying=matches.length>0;
  }
  if(matches.length>1)fail('demand_source_ambiguous');
  const old=matches[0];
  if(!old){
   if(existing.some(c=>isMeal(c)&&c.removedAt!==null&&lineage(c.source)===lineage(fact.source)))fail('demand_source_retired');
   if(active.some(c=>lineage(c.source)===lineage(fact.source)))fail('demand_source_rebinding_required');
   if(before?.usedIds.includes(fact.id))fail('demand_source_identity_reused');
   return {before:null,proposed:fact,transition:'new'};
  }
  if(matched.has(old.id))fail('demand_source_ambiguous');matched.add(old.id);
  const source=quantifying&&old.source.kind==='reservation'&&fact.source.kind==='reservation'
   ? {...old.source,bindingId:fact.source.bindingId}:structuredClone(old.source);
  // Origin text and persisted reservation purpose/ID are immutable. Product matching stays explicit.
  // A confirmed ingredient conversion belongs to these exact reviewed food/quantity facts.
  // Fresh meal enumeration has no conversion evidence; retain it only when nothing it
  // describes changed, and only when it still bridges both of its declared units.
  let quantity=fact.quantity;
  const previous=old.quantity,basis=previous?.confirmedConversion;
  if(previous&&basis&&old.productName===fact.productName&&digest(old.source)===digest(source)
   &&digest({...previous,confirmedConversion:null})===digest(fact.quantity)
   &&convertDemandQuantity(previous,basis.sourceUnit)!==null&&convertDemandQuantity(previous,basis.targetUnit)!==null)
   quantity=structuredClone(previous);
  const proposed:LegacyDemandSource={...fact,quantity,id:old.id,source,originalText:old.originalText,
   productName:old.source.kind==='reservation'?old.productName:fact.productName,requiredLineId:old.lineId,
   sourceExclusions:fact.sourceExclusions.map(e=>structuredClone((old.sourceExclusions??[]).find(x=>exclusionKey(x)===exclusionKey(e))??e))};
  const unchanged=digest(old.source)===digest(source)&&digest(old.quantity)===digest(proposed.quantity)
   &&old.productName===proposed.productName&&digest(old.sourceExclusions??[])===digest(proposed.sourceExclusions);
  const quantifiesReservation=old.source.kind==='reservation'&&old.quantity===null&&proposed.quantity!==null;
  return {before:structuredClone(old),proposed,transition:quantifiesReservation?'quantifyReservation':unchanged?'retain':'update'};
 });
 const retired=active.filter(c=>!matched.has(c.id));
 if(retired.some(c=>c.source.kind==='reservation'))fail('demand_protected_source_missing');
 const retirementCandidates=retired.map(c=>c.id);
 return {sources,retirementCandidates,retainedContributionIds:existing.filter(c=>!matched.has(c.id)&&!retirementCandidates.includes(c.id)).map(c=>c.id)};
}
