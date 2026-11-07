import {type Rat,zero,add,sub,cmp,min,wire,amount,inUnit,dimension} from './physical-quantity.js';
import {createHash} from 'node:crypto';
import {recoveryBasisSchema,recoveryPreviewSchema,type RecoveryBasis,type RecoveryMeal,type RecoveryNeed,type Quantity} from './recovery-contracts.js';

export class RecoveryError extends Error { constructor(readonly code:string){super(code);} }
function requireThat(value:unknown,code='invalid_basis'):asserts value {if(!value)throw new RecoveryError(code);}
// Semantic canonical JSON; no locale-sensitive collation and no floating arithmetic.
export function recoveryDigest(value:unknown):string {return createHash('sha256').update(canonical(value)).digest('hex');}
function canonical(v:unknown):string {if(v===null||typeof v!=='object')return JSON.stringify(v);if(Array.isArray(v))return '['+v.map(canonical).join(',')+']';return '{'+Object.entries(v).sort(([a],[b])=>a<b?-1:a>b?1:0).map(([k,x])=>JSON.stringify(k)+':'+canonical(x)).join(',')+'}';}
const equal=(a:unknown,b:unknown)=>recoveryDigest(a)===recoveryDigest(b);
export function fitsReceived(usable: Quantity, received: Quantity): boolean {
  return dimension(usable) === dimension(received) && cmp(amount(usable), amount(received)) <= 0n;
}
const instant=(s:string)=>Date.parse(s);
function unique(values:string[]){requireThat(new Set(values).size===values.length);}
function scoped(b:RecoveryBasis,row:{householdId:string;shopId:string}){requireThat(row.householdId===b.householdId&&row.shopId===b.shopId,'wrong_scope');}
function checkMeal(meal:RecoveryMeal){
 unique(meal.groups.map(g=>g.id));unique(meal.needs.map(n=>n.id));
 unique(meal.needs.map(n=>n.ingredientId+'/'+n.groupId));
 for(const need of meal.needs){const group=meal.groups.find(g=>g.id===need.groupId);requireThat(group&&group.protected===(need.priority==='protected'));requireThat(need.due===meal.due);requireThat([...meal.exclusions,...group.exclusions].every(e=>need.exclusions.includes(e)),'missing_exclusions');}
 requireThat(meal.groups.every(g=>meal.needs.some(n=>n.groupId===g.id)));
}
function validateBasis(input:unknown):RecoveryBasis {
 const b=recoveryBasisSchema.parse(input);
 unique(b.foods.map(f=>f.id));unique(b.sources.map(s=>s.id));unique(b.meals.map(m=>m.occurrenceId));unique(b.meals.map(m=>m.revisionId));
 unique(b.usedNeedIds);unique(b.usedRevisionIds);unique(b.reservations.map(r=>r.id));unique(b.reservations.map(r=>r.sourceId+'/'+r.needId));
 const demands=b.meals.flatMap(m=>m.needs).concat(b.outsideNeeds);unique(demands.map(n=>n.id));
 requireThat(demands.every(n=>b.usedNeedIds.includes(n.id)));requireThat(b.meals.every(m=>b.usedRevisionIds.includes(m.revisionId)));
 for(const m of b.meals)checkMeal(m);
 for(const need of demands)requireThat(need.foodId===null||b.foods.some(f=>f.id===need.foodId),'unknown_food');
 unique(b.sources.map(s=>s.origin.kind==='delivery'?'delivery/'+s.origin.orderLineId+'/'+s.origin.segmentKey:s.origin.kind==='sharedStock'?'stock/'+s.origin.batchId:'import/'+s.origin.originBindingId)); // Same delivery segment cannot create a second lot.
 for(const source of b.sources){scoped(b,source);requireThat(b.foods.some(f=>f.id===source.foodId),'unknown_food');}
 unique(b.arrivals.map(a=>a.id).concat(b.usable.map(u=>u.id)));
 for(const rows of [b.arrivals,b.usable]){
  for(const row of rows){scoped(b,row);const source=b.sources.find(s=>s.id===row.sourceId);requireThat(source&&row.identityRevision<=source.identityRevision,'invalid_identity_revision');requireThat(row.revision>0&&row.revision<=b.base.supplyRevision);}
  for(const source of b.sources){const history=rows.filter(r=>r.sourceId===source.id).sort((a,c)=>a.revision-c.revision);let previous:typeof history[number]|undefined;
   for(const row of history){requireThat(row.predecessorId===(previous?.id??null));requireThat(!previous||(row.revision>previous.revision&&instant(row.recordedAt)>=instant(previous.recordedAt)));previous=row;}
  }
 }
 // A supply revision represents one immutable observation, across both tables.
 unique(b.arrivals.concat(b.usable as unknown as typeof b.arrivals).map(r=>String(r.revision)));
 for(const row of b.usable){const arrival=b.arrivals.find(a=>a.id===row.arrivalObservationId);requireThat(arrival&&arrival.sourceId===row.sourceId&&arrival.revision<row.revision);
  requireThat(arrival.identityRevision===row.identityRevision,'identity_mismatch');
  if(row.usable){requireThat(arrival.received&&arrival.arrivedAt,'unverified_arrival');requireThat(fitsReceived(row.usable,arrival.received),'usable_exceeds_received');}
 }
 return b;
}
export interface CanonicalLot {sourceId:string;foodId:string;identityRevision:number;quantity:Quantity;availableAt:string;arrivalId:string;usableId:string}
type ArrivalHead = Pick<RecoveryBasis['arrivals'][number], 'id'|'received'|'arrivedAt'|'recordedAt'|'identityRevision'>;
type UsableHead = Pick<RecoveryBasis['usable'][number], 'id'|'usable'|'arrivalObservationId'|'confirmedAt'|'recordedAt'|'identityRevision'>;
export function confirmedLot(source: Pick<RecoveryBasis['sources'][number], 'id'|'foodId'|'identityRevision'>,
  arrival: ArrivalHead | undefined, usable: UsableHead | undefined, asOf: string): CanonicalLot | undefined {
  if (!arrival?.arrivedAt || !arrival.received || !usable?.usable || usable.arrivalObservationId !== arrival.id ||
      arrival.identityRevision !== source.identityRevision || usable.identityRevision !== source.identityRevision) return;
  const available = Math.max(instant(arrival.arrivedAt), instant(arrival.recordedAt), instant(usable.confirmedAt), instant(usable.recordedAt));
  if (available > instant(asOf)) return;
  return {sourceId:source.id, foodId:source.foodId, identityRevision:source.identityRevision, quantity:usable.usable,
    availableAt:new Date(available).toISOString(), arrivalId:arrival.id, usableId:usable.id};
}
function supply(b:RecoveryBasis,asOf:string):CanonicalLot[]{
 const lots:CanonicalLot[]=[];
 for (const source of b.sources) {
   const latest = <T extends {sourceId:string; revision:number}>(rows:T[]) =>
     rows.filter(row => row.sourceId === source.id).sort((a,c) => c.revision-a.revision)[0];
   const lot = confirmedLot(source, latest(b.arrivals), latest(b.usable), asOf);
   if (lot) lots.push(lot);
 }
 return lots.sort((a,c)=>a.sourceId<c.sourceId?-1:1);
}
export function canonicalSupply(input:unknown,asOf:string){requireThat(Number.isFinite(instant(asOf)),'invalid_time');return supply(validateBasis(input),asOf);}
// Compare saved text without rewriting it or inferring food identity, synonyms,
// allergen families or translations. Token-bounded phrase matching
// mirrors native permittedProduct; tags remain explicit evidence, not legacy IDs.
function exclusionTerm(value: string): string {
  return value.normalize('NFKD').replace(/\p{M}/gu, '').toLocaleLowerCase('en')
    .split(/[^\p{L}\p{N}]+/u).filter(Boolean).join(' ');
}
export function exclusionConflict(need: Pick<RecoveryNeed,'name'|'exclusions'>, food: {name:string;exclusionTags:string[]}): boolean {
  const labels = [need.name, food.name].map(value => ` ${exclusionTerm(value)} `);
  const tags = food.exclusionTags.map(exclusionTerm);
  return need.exclusions.some(value => {
    const literal = exclusionTerm(value);
    // A shopper can enter either "sesame" or "no sesame" ("sin sésamo").
    // Read the prohibition only on the saved restriction, never as a safety claim on a product.
    const term = literal.replace(/^(?:no|without|sin) /u, '');
    return term.length > 0 && (tags.includes(term) || tags.includes(literal) || labels.some(label => label.includes(` ${term} `)));
  });
}
interface Allocation {needId:string;sourceId:string;amount:Rat}
function allocate(b: RecoveryBasis, needs: RecoveryNeed[], lots: CanonicalLot[], asOf: string) {
  const left = new Map(lots.map(lot => [lot.sourceId, amount(lot.quantity)]));
  const totals = new Map(needs.map(need => [need.id, zero]));
  const edges: Allocation[] = [];
  const issues = new Map(needs.map(need => [need.id, [] as string[]]));
  const pins = new Map(needs.map(need => [need.id, b.reservations
    .filter(reservation => reservation.needId === need.id)
    .sort((a, c) => a.sourceId < c.sourceId ? -1 : 1)]));

  function compatible(need: RecoveryNeed, lot: CanonicalLot) {
    // Current physical coverage is separate from whether a saved deadline passed.
    // The supplied lots have already passed the captured as-of availability filter.
    return need.foodId === lot.foodId && dimension(need.quantity) === dimension(lot.quantity);
  }

  // Validate every pin before allocating, including pins on excluded/unknown needs.
  for (const reservation of b.reservations) {
    const need = needs.find(value => value.id === reservation.needId);
    const source = b.sources.find(value => value.id === reservation.sourceId);
    requireThat(need && source && need.foodId === source.foodId &&
      dimension(reservation.quantity) === dimension(need.quantity), 'invalid_reservation');
  }
  const reservedTotals = new Map(needs.map(need => {
    const reserved = pins.get(need.id)!.reduce((total, pin) => add(total, amount(pin.quantity)), zero);
    requireThat(cmp(reserved, amount(need.quantity)) <= 0n, 'over_reserved');
    return [need.id, reserved] as const;
  }));

  function bind(need: RecoveryNeed, lot: CanonicalLot, quantity: Rat) {
    requireThat(cmp(quantity, left.get(lot.sourceId)!) <= 0n, 'reservation_shortfall');
    requireThat(cmp(add(totals.get(need.id)!, quantity), amount(need.quantity)) <= 0n, 'over_reserved');
    if (quantity.n === 0n) return;
    left.set(lot.sourceId, sub(left.get(lot.sourceId)!, quantity));
    totals.set(need.id, add(totals.get(need.id)!, quantity));
    edges.push({ needId: need.id, sourceId: lot.sourceId, amount: quantity });
  }

  // Order whole needs, not reservation rows: an unpinned protected lunch must run
  // before any required dinner, including one with a physical-source pin.
  const rank = (need: RecoveryNeed) => need.priority === 'protected' ? 0 : pins.get(need.id)!.length ? 1 : 2;
  const ordered = [...needs].sort((a, c) => rank(a) - rank(c) ||
    (a.due === null ? Infinity : instant(a.due)) - (c.due === null ? Infinity : instant(c.due)) ||
    (a.id < c.id ? -1 : 1));

  for (const need of ordered) {
    const food = b.foods.find(value => value.id === need.foodId);
    if (!food) {
      issues.get(need.id)!.push('unknown_food');
      continue;
    }
    // Exclusions gate every allocation path, including explicit reservations.
    if (exclusionConflict(need, food)) {
      issues.get(need.id)!.push('exclusion_conflict');
      continue;
    }

    for (const reservation of pins.get(need.id)!) {
      const lot = lots.find(value => value.sourceId === reservation.sourceId);
      if (!lot) {
        issues.get(need.id)!.push('reservation_unavailable');
        continue;
      }
      requireThat(compatible(need, lot), 'invalid_reservation');
      const quantity = min(amount(reservation.quantity), left.get(lot.sourceId)!);
      bind(need, lot, quantity);
      if (cmp(quantity, amount(reservation.quantity)) < 0n) {
        issues.get(need.id)!.push('reservation_shortfall');
      }
    }

    // A pin reserves an exact physical quantity. Correction/priority shortages
    // stay on that pin; another lot may cover only the genuinely unreserved part.
    let unreserved = sub(amount(need.quantity), reservedTotals.get(need.id)!);
    for (const lot of lots) {
      if (!compatible(need, lot)) continue;
      const quantity = min(unreserved, left.get(lot.sourceId)!);
      bind(need, lot, quantity);
      unreserved = sub(unreserved, quantity);
    }
  }

  return {
    totals,
    edges,
    allocations: edges.map(edge => {
      const need = needs.find(value => value.id === edge.needId)!;
      return { needId: edge.needId, sourceId: edge.sourceId,
        amount: inUnit(edge.amount, need.quantity.unit), unit: need.quantity.unit };
    }),
    demands: needs.map(need => ({
      needId: need.id,
      due: need.due,
      deadlineStatus: need.due === null ? 'unknown' : instant(need.due) < instant(asOf) ? 'pastDue' : 'notPastDue',
      allocated: inUnit(totals.get(need.id)!, need.quantity.unit),
      shortfall: inUnit(sub(amount(need.quantity), totals.get(need.id)!), need.quantity.unit),
      unit: need.quantity.unit,
      issues: issues.get(need.id)!,
    })),
  };
}
export function projectRecovery(input:unknown,asOf:string){requireThat(Number.isFinite(instant(asOf)),'invalid_time');const b=validateBasis(input);const lots=supply(b,asOf);const result=allocate(b,b.meals.flatMap(m=>m.needs).concat(b.outsideNeeds),lots,asOf);return{asOf,base:b.base,meals:b.meals,demands:result.demands,allocations:result.allocations,commitmentInventoryComplete:b.commitmentInventoryComplete};}

/** Pure preview only: caller must load trusted complete state inside an authorized
 * transaction. No persistence, actor assertion, receipt or cook publication occurs. */
export function previewRecovery(input:unknown,requestInput:unknown,asOf:string){
 requireThat(Number.isFinite(instant(asOf)),'invalid_time');const b=validateBasis(input),request=recoveryPreviewSchema.parse(requestInput),i=request.intent;
 requireThat(equal(request.base,b.base),'stale_basis');requireThat(instant(i.reviewedAt)<=instant(asOf),'future_review');
 const old=b.meals.find(m=>m.occurrenceId===i.occurrenceId);requireThat(old&&recoveryDigest(old)===i.targetDigest,'stale_target');const next=i.replacement;checkMeal(next);
 // No accepted-template repository has been implemented. A client-chosen ID/version
 // must not turn a manual definition into verified recipe provenance.
 requireThat(next.template===null,'unverified_template');
 requireThat(i.repeatOfOccurrenceId===null||b.meals.some(meal=>meal.occurrenceId===i.repeatOfOccurrenceId),'unverified_repeat_source');
 requireThat(next.needs.every(n=>n.foodId===null||b.foods.some(f=>f.id===n.foodId)),'unknown_food');
 requireThat(next.occurrenceId===old.occurrenceId&&!b.usedRevisionIds.includes(next.revisionId),'invalid_lineage');
 requireThat(next.sourceMealRevision===old.sourceMealRevision&&next.portions===old.portions&&next.day===old.day&&next.zone===old.zone&&next.due===old.due,'changed_commitment');
 requireThat(old.exclusions.every(e=>next.exclusions.includes(e)),'changed_exclusions');
 requireThat(equal(old.groups,next.groups),'changed_groups');
 requireThat(equal(old.needs.filter(n=>n.priority==='protected'),next.needs.filter(n=>n.priority==='protected')),'protected_need');
 const removed=old.needs.filter(n=>n.priority!=='protected');const added=next.needs.filter(n=>n.priority!=='protected');requireThat(removed.length&&added.length,'empty_replacement');
 requireThat(added.every(n=>!b.usedNeedIds.includes(n.id)),'reused_need');requireThat(!b.reservations.some(r=>removed.some(n=>n.id===r.needId)),'pinned_target');
 for(const n of next.needs){const group=next.groups.find(g=>g.id===n.groupId)!;const restrictions=[...old.exclusions,...group.exclusions,...removed.filter(o=>o.groupId===n.groupId).flatMap(o=>o.exclusions)];requireThat(restrictions.every(e=>n.exclusions.includes(e)),'changed_exclusions');}
 const meals=b.meals.map(m=>m.occurrenceId===old.occurrenceId?next:m),beforeNeeds=b.meals.flatMap(m=>m.needs).concat(b.outsideNeeds),afterNeeds=meals.flatMap(m=>m.needs).concat(b.outsideNeeds);unique(afterNeeds.map(n=>n.id));
 const lots=supply(b,asOf),before=allocate(b,beforeNeeds,lots,asOf),after=allocate(b,afterNeeds,lots,asOf);
 for(const need of beforeNeeds.filter(n=>!removed.some(r=>r.id===n.id))){requireThat(cmp(after.totals.get(need.id)!,before.totals.get(need.id)!)>=0n,'steals_food');
  requireThat(equal(before.demands.find(n=>n.needId===need.id)?.issues,after.demands.find(n=>n.needId===need.id)?.issues),'changes_unrelated_issues');
  if(b.reservations.some(r=>r.needId===need.id))requireThat(equal(before.edges.filter(e=>e.needId===need.id).map(e=>({...e,amount:wire(e.amount)})),after.edges.filter(e=>e.needId===need.id).map(e=>({...e,amount:wire(e.amount)}))),'changes_reservation');
 }
 const foodConfirmed=b.commitmentInventoryComplete&&after.demands.filter(n=>next.needs.some(x=>x.id===n.needId)).every(n=>n.shortfall.numerator==='0'&&n.issues.length===0);
 const timingConfirmed=next.due!==null&&next.remainingElapsedMinutes!==null&&instant(asOf)+next.remainingElapsedMinutes*60000<=instant(next.due)&&(next.requiredLeadMinutes===null||next.remainingElapsedMinutes>=next.requiredLeadMinutes||next.advanceStepsCompleted);
 const repeatRequired=i.repeatOfOccurrenceId!==null;const feasible=foodConfirmed&&timingConfirmed;
 const consentSatisfied=(!repeatRequired||i.agreesToRepeat)&&(!i.proposesExtraTrip||i.agreesToExtraTrip)&&(feasible||i.acceptsUnresolved);
 const result={base:b.base,intent:i,evidenceDigest:recoveryDigest(lots),before:{meals:b.meals,demands:before.demands,allocations:before.allocations},after:{meals,demands:after.demands,allocations:after.allocations},foodConfirmed,timingConfirmed,repeatRequired,feasible,consentSatisfied};
 // Clock is displayed, but a harmless clock tick must not stale an identical decision.
 // Time-dependent evidence, allocations and timing are included in the digest.
 return{asOf,...result,previewDigest:recoveryDigest(result)};
}
