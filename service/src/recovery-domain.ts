import {type Rat,zero,add,sub,cmp,min,wire,amount,inUnit,dimension} from './physical-quantity.js';
import {type Edge, connect, compareDemandOrder, allocate as sendFlow} from './physical-allocation.js';
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
type Source = RecoveryBasis['sources'][number];
const groupIds = (need:RecoveryNeed) => need.groupId === null ? need.groupIds ?? [] : [need.groupId];
function checkMeal(meal:RecoveryMeal) {
  unique(meal.groups.map(group => group.id));
  unique(meal.needs.map(need => need.id));
  unique(meal.needs.flatMap(need => (groupIds(need).length ? groupIds(need) : ['']).map(id => need.ingredientId + '/' + id)));
  for (const need of meal.needs) {
    const ids = groupIds(need);
    unique(ids);
    requireThat(need.groupIds === undefined || (need.groupId === null && ids.length !== 1));
    const groups = ids.map(id => meal.groups.find(group => group.id === id));
    requireThat(groups.every(group => group !== undefined));
    requireThat(!ids.length || groups.some(group => group.protected) === (need.priority === 'protected'));
    requireThat(need.due === meal.due);
    requireThat([...meal.exclusions, ...groups.flatMap(group => group.exclusions)].every(e => need.exclusions.includes(e)), 'missing_exclusions');
  }
}

function checkMatches(b:RecoveryBasis, need:RecoveryNeed) {
  requireThat(need.foodId === null || b.foods.some(food => food.id === need.foodId), 'unknown_food');
  if (need.matchedSourceIds) {
    unique(need.matchedSourceIds);
    requireThat(need.matchedSourceIds.every(id => b.sources.some(source => source.id === id)), 'unknown_source');
  }
}

function matches(need:RecoveryNeed, source:Source, currentShop:string) {
  if (need.matchedSourceIds) return need.matchedSourceIds.includes(source.id);
  return source.origin.kind !== 'sharedStock' && source.shopId === currentShop && need.foodId === source.foodId;
}

function validateBasis(input:unknown):RecoveryBasis {
 const b=recoveryBasisSchema.parse(input);
 unique(b.foods.map(f=>f.id));unique(b.sources.map(s=>s.id));unique(b.meals.map(m=>m.occurrenceId));unique(b.meals.map(m=>m.revisionId));
 unique(b.usedNeedIds);unique(b.usedRevisionIds);unique(b.reservations.map(r=>r.id));unique(b.reservations.map(r=>r.sourceId+'/'+r.needId));
 const demands=b.meals.flatMap(m=>m.needs).concat(b.outsideNeeds);unique(demands.map(n=>n.id));
 requireThat(demands.every(n=>b.usedNeedIds.includes(n.id)));requireThat(b.meals.every(m=>b.usedRevisionIds.includes(m.revisionId)));
 for(const m of b.meals)checkMeal(m);
 for (const need of demands) checkMatches(b, need);
 const carry = new Set(b.selectedCarrySourceIds ?? []);
 const foreignRevisions = new Map(b.carrySupplyRevisions?.map(row => [row.shopId, row.supplyRevision]));
 const manual = b.sources.filter(source => source.origin.kind === 'sharedStock');
 if (b.base.pantryRevision !== undefined) {
   requireThat(b.pantryObservations && b.foreignHolds, 'incomplete_pantry_basis');
   requireThat(!b.outsideNeeds.length, 'use_opaque_foreign_holds');
 } else {
   requireThat(!manual.length && !carry.size && !foreignRevisions.size && !b.pantryObservations && !b.foreignHolds, 'missing_pantry_revision');
 }
 unique(b.selectedCarrySourceIds ?? []);
 unique((b.carrySupplyRevisions ?? []).map(row => row.shopId));
 requireThat([...carry].every(id => b.sources.some(source => source.id === id && source.shopId !== b.shopId)), 'wrong_scope');
 requireThat([...foreignRevisions.keys()].every(shop => b.sources.some(source => source.shopId === shop && carry.has(source.id) && source.origin.kind === 'delivery')), 'wrong_scope');
 unique(b.sources.map(s=>s.origin.kind==='delivery'?'delivery/'+s.shopId+'/'+s.origin.orderLineId+'/'+s.origin.segmentKey:s.origin.kind==='sharedStock'?'stock/'+s.origin.batchId:'import/'+s.origin.originBindingId));
 for (const source of b.sources) {
   requireThat(source.householdId === b.householdId && (source.shopId === b.shopId || carry.has(source.id)), 'wrong_scope');
   requireThat(b.foods.some(f => f.id === source.foodId), 'unknown_food');
   if (source.origin.kind === 'sharedStock') requireThat(source.id === source.origin.batchId, 'invalid_physical_id');
   if (carry.has(source.id) && source.origin.kind !== 'sharedStock')
     requireThat(source.origin.kind === 'delivery' && foreignRevisions.has(source.shopId), 'wrong_scope');
 }
 const pantryRows = b.pantryObservations ?? [];
 unique([...b.arrivals, ...b.usable].map(row => row.shopId + "/" + row.id));
 unique(pantryRows.map(row => row.id));
 unique(pantryRows.map(row => String(row.revision)));
 for (const row of pantryRows) {
   requireThat(row.householdId === b.householdId, 'wrong_scope');
   const source = manual.find(source => source.id === row.sourceId);
   requireThat(source && row.identityRevision <= source.identityRevision, 'invalid_pantry_observation');
   requireThat(row.revision <= b.base.pantryRevision!);
 }
 const holds = b.foreignHolds ?? [];
 unique(holds.map(hold => hold.sourceId));
 requireThat(holds.every(hold => b.sources.some(source => source.id === hold.sourceId)), 'unknown_source');
 for(const rows of [b.arrivals,b.usable,pantryRows]){
  for(const row of rows){
    if (!('shopId' in row)) continue;
    const source = b.sources.find(s=>s.id===row.sourceId);
    requireThat(source && source.origin.kind !== 'sharedStock', 'not_delivery_evidence');
    requireThat(row.householdId === b.householdId && row.shopId === source.shopId, 'wrong_scope');
    requireThat(row.identityRevision<=source.identityRevision,'invalid_identity_revision');
    const revision = row.shopId === b.shopId ? b.base.supplyRevision : foreignRevisions.get(row.shopId);
    requireThat(revision !== undefined && row.revision>0 && row.revision<=revision);
  }
  for(const source of b.sources){const history=rows.filter(r=>r.sourceId===source.id).sort((a,c)=>a.revision-c.revision);let previous:typeof history[number]|undefined;
   for(const row of history){requireThat(row.predecessorId===(previous?.id??null));requireThat(!previous||(row.revision>previous.revision&&instant(row.recordedAt)>=instant(previous.recordedAt)));previous=row;}
  }
 }
 // A supply revision represents one immutable observation, across both tables.
 unique(b.arrivals.concat(b.usable as unknown as typeof b.arrivals).map(r=>r.shopId+'/'+r.revision));
 for(const row of b.usable){const arrival=b.arrivals.find(a=>a.shopId===row.shopId && a.sourceId===row.sourceId && a.id===row.arrivalObservationId);requireThat(arrival&&arrival.sourceId===row.sourceId&&arrival.revision<row.revision);
  requireThat(arrival.identityRevision===row.identityRevision,'identity_mismatch');
  if(row.usable){requireThat(arrival.received&&arrival.arrivedAt,'unverified_arrival');requireThat(fitsReceived(row.usable,arrival.received),'usable_exceeds_received');}
 }
 return b;
}
export interface CanonicalLot {sourceId:string;foodId:string;identityRevision:number;quantity:Quantity;availableAt:string;arrivalId:string;usableId:string}
interface ManualLot {
  sourceId:string; foodId:string; identityRevision:number; quantity:Quantity; availableAt:string;
  location:'pantry'|'freezer'; observationId:string;
}
type PhysicalLot = CanonicalLot | ManualLot;
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
function supply(b:RecoveryBasis,asOf:string):PhysicalLot[]{
 const lots:PhysicalLot[]=[];
 for (const source of b.sources) {
   const latest = <T extends {sourceId:string; revision:number}>(rows:T[]) =>
     rows.filter(row => row.sourceId === source.id).sort((a,c) => c.revision-a.revision)[0];
   if (source.origin.kind === 'sharedStock') {
     const head = latest(b.pantryObservations ?? []);
     if (head?.quantity && head.identityRevision === source.identityRevision) {
       const available = Math.max(instant(head.confirmedAt), instant(head.recordedAt));
       if (available <= instant(asOf)) {
         lots.push({sourceId:source.id, foodId:source.foodId, identityRevision:source.identityRevision,
           quantity:head.quantity, availableAt:new Date(available).toISOString(), observationId:head.id, location:source.origin.location});
       }
     }
     continue;
   }
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
export function exclusionConflict(need: Pick<RecoveryNeed,'name'|'exclusions'>, food?: {name:string;exclusionTags:string[]}): boolean {
  const labels = (food ? [need.name, food.name] : [need.name]).map(value => ` ${exclusionTerm(value)} `);
  const tags = (food?.exclusionTags ?? []).map(exclusionTerm);
  return need.exclusions.some(value => {
    const literal = exclusionTerm(value);
    // A shopper can enter either "sesame" or "no sesame" ("sin sésamo").
    // Read the prohibition only on the saved restriction, never as a safety claim on a product.
    const term = literal.replace(/^(?:no|without|sin) /u, '');
    return term.length > 0 && (tags.includes(term) || tags.includes(literal) || labels.some(label => label.includes(` ${term} `)));
  });
}
interface Allocation {needId:string;sourceId:string;amount:Rat}
type KnownNeed = RecoveryNeed & {quantity:Quantity};
function allocateLegacy(b: RecoveryBasis, needs: KnownNeed[], lots: PhysicalLot[], asOf: string) {
  const left = new Map(lots.map(lot => [lot.sourceId, amount(lot.quantity)]));
  const totals = new Map(needs.map(need => [need.id, zero]));
  const edges: Allocation[] = [];
  const issues = new Map(needs.map(need => [need.id, [] as string[]]));
  const pins = new Map(needs.map(need => [need.id, b.reservations
    .filter(reservation => reservation.needId === need.id)
    .sort((a, c) => a.sourceId < c.sourceId ? -1 : 1)]));

  function compatible(need: KnownNeed, lot: PhysicalLot) {
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

  function bind(need: KnownNeed, lot: PhysicalLot, quantity: Rat) {
    requireThat(cmp(quantity, left.get(lot.sourceId)!) <= 0n, 'reservation_shortfall');
    requireThat(cmp(add(totals.get(need.id)!, quantity), amount(need.quantity)) <= 0n, 'over_reserved');
    if (quantity.n === 0n) return;
    left.set(lot.sourceId, sub(left.get(lot.sourceId)!, quantity));
    totals.set(need.id, add(totals.get(need.id)!, quantity));
    edges.push({ needId: need.id, sourceId: lot.sourceId, amount: quantity });
  }

  // Order whole needs, not reservation rows: an unpinned protected lunch must run
  // before any required dinner, including one with a physical-source pin.
  const rank = (need: KnownNeed) => need.priority === 'protected' ? 0 : pins.get(need.id)!.length ? 1 : 2;
  const ordered = [...needs].sort((a, c) => rank(a) - rank(c) ||
    compareDemandOrder(a,c));

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
type Hold = NonNullable<RecoveryBasis['foreignHolds']>[number];
function freeStock(lot:PhysicalLot, hold:Hold | undefined) {
  const stock = amount(lot.quantity);
  if (!hold) return stock;
  if (!hold.quantity) return zero;
  const one = {unit:hold.quantity.unit, amount:{numerator:1, denominator:1}, originalLiteral:'1'};
  requireThat(dimension(one) === dimension(lot.quantity), 'invalid_foreign_hold');
  const scale = amount(one);
  const reserved = {n:BigInt(hold.quantity.amount.numerator)*scale.n, d:BigInt(hold.quantity.amount.denominator)*scale.d};
  return sub(stock, min(stock, reserved));
}

function allocate(b:RecoveryBasis, needs:RecoveryNeed[], lots:PhysicalLot[], asOf:string) {
  if (b.base.pantryRevision === undefined &&
      needs.every((n): n is KnownNeed => n.quantity !== null && n.matchedSourceIds === undefined && n.groupId !== null)) {
    return allocateLegacy(b, needs, lots, asOf);
  }
  const lotById = new Map(lots.map(lot => [lot.sourceId, lot]));
  const foods = new Map(b.foods.map(food => [food.id, food]));
  const stock = [...b.sources].sort((a,c) => a.id < c.id ? -1 : 1);
  const sourceNode = new Map(stock.map((source,index) => [source.id, needs.length + index]));
  const sink = needs.length + stock.length;
  const graph:Edge[][] = Array.from({length:sink+1}, () => []);
  const claims = new Map(needs.map(need => [need.id, [] as RecoveryBasis['reservations']]));
  for (const pin of b.reservations) {
    const need = needs.find(row => row.id === pin.needId);
    const source = stock.find(row => row.id === pin.sourceId);
    requireThat(need?.quantity && source && matches(need,source,b.shopId) && dimension(pin.quantity) === dimension(need.quantity), 'invalid_reservation');
    claims.get(need.id)!.push(pin);
  }

  const rows = needs.map((need,index) => {
    const pins = claims.get(need.id)!.sort((a,c) => a.sourceId < c.sourceId ? -1 : 1);
    if (need.quantity) {
      const requested = pins.reduce((sum,pin) => add(sum,amount(pin.quantity)),zero);
      requireThat(cmp(requested,amount(need.quantity)) <= 0n, 'over_reserved');
    }
    const candidates = stock.filter(source => matches(need, source, b.shopId));
    const allowed = candidates.filter(source => !exclusionConflict(need,foods.get(source.foodId)));
    const observed = allowed.filter(source => lotById.has(source.id));
    const eligible = observed.filter(source => !need.quantity || dimension(lotById.get(source.id)!.quantity) === dimension(need.quantity));
    const issues = new Set<string>();
    if (!need.quantity) issues.add('unknown_quantity');
    if (groupIds(need).length > 1) issues.add('unknown_split');
    if (!candidates.length) issues.add('unknown_food');
    else if (!allowed.length) issues.add('exclusion_conflict');
    else if (!observed.length) issues.add('unconfirmed_stock');
    else if (!eligible.length) issues.add('unit_mismatch');
    const sourceIssues = candidates.flatMap(source => {
      const lot = lotById.get(source.id);
      let issue: string;
      if (exclusionConflict(need, foods.get(source.foodId))) issue = 'exclusion_conflict';
      else if (!lot) issue = 'unconfirmed_stock';
      else if (need.quantity && dimension(lot.quantity) !== dimension(need.quantity)) issue = 'unit_mismatch';
      else return [];
      return [{sourceId:source.id,issue}];
    });
    const reservations = pins.map(pin => ({pin, backed:zero}));
    return {need,index,eligible,issues,sourceIssues,reservations,missing:need.quantity ? amount(need.quantity) : zero,
      flexible:[] as {sourceId:string;edge:Edge}[]};
  });

  // A protected need with unknown quantity holds its matched physical sources.
  const held = new Set(rows.filter(row => row.need.priority === 'protected' && !row.need.quantity)
    .flatMap(row => row.eligible.map(source => source.id)));
  const foreign = new Map(b.foreignHolds?.map(hold => [hold.sourceId,hold]));
  for (const lot of lots) {
    if (!held.has(lot.sourceId)) connect(graph,sourceNode.get(lot.sourceId)!,sink,freeStock(lot,foreign.get(lot.sourceId)));
  }
  for (const row of rows) {
    for (const source of row.eligible) {
      if (held.has(source.id)) continue;
      if (!row.need.quantity) continue;
      row.flexible.push({sourceId:source.id,edge:connect(graph,row.index,sourceNode.get(source.id)!,row.missing)});
    }
  }

  const sorted = [...rows].sort((a,c) => compareDemandOrder(a.need,c.need));
  for (const priority of ['protected','required']) {
    const group = sorted.filter(row => row.need.priority === priority);
    for (const row of group) {
      for (const claim of row.reservations) {
        const requested = amount(claim.pin.quantity);
        if (row.flexible.some(edge => edge.sourceId === claim.pin.sourceId)) {
          const limit = min(row.missing, requested);
          claim.backed = sub(limit, sendFlow(graph,sourceNode.get(claim.pin.sourceId)!,sink,limit));
          row.missing = sub(row.missing,claim.backed);
        }
        if (cmp(claim.backed,requested) < 0n) row.issues.add('reservation_shortfall');
      }
    }
    for (const row of group) {
      row.missing = sendFlow(graph,row.index,sink,row.missing);
      if (row.missing.n > 0n && row.eligible.some(source => held.has(source.id))) row.issues.add('protected_quantity_unknown');
      if (row.missing.n > 0n && row.eligible.some(source => foreign.get(source.id)?.quantity === null)) row.issues.add('foreign_hold_unknown');
    }
  }

  const edges:Allocation[] = [];
  const totals = new Map<string,Rat>();
  const demands = rows.map(row => {
    const {need,missing} = row;
    const required = need.quantity;
    const total = required ? sub(amount(required),missing) : zero;
    totals.set(need.id,total);
    for (const {sourceId,edge} of row.flexible) {
      const fixed = row.reservations.find(claim => claim.pin.sourceId === sourceId)?.backed ?? zero;
      const allocated = add(fixed,edge.reverse.capacity);
      if (allocated.n > 0n) edges.push({needId:need.id,sourceId,amount:allocated});
    }
    return {needId:need.id,due:need.due,
      deadlineStatus:need.due === null ? 'unknown' : instant(need.due) < instant(asOf) ? 'pastDue' : 'notPastDue',
      allocated:required ? inUnit(total,required.unit) : null,shortfall:required ? inUnit(missing,required.unit) : null,
      unit:required?.unit ?? null,issues:[...row.issues],sourceIssues:row.sourceIssues,
      reservations:row.reservations.map(({pin,backed}) => ({reservationId:pin.id,sourceId:pin.sourceId,
        requested:inUnit(amount(pin.quantity),required!.unit),backed:inUnit(backed,required!.unit)}))};
  });
  const units = new Map(needs.map(need => [need.id,need.quantity?.unit]));
  const allocations = edges.map(edge => {
    const unit = units.get(edge.needId)!;
    return {needId:edge.needId,sourceId:edge.sourceId,amount:inUnit(edge.amount,unit),unit};
  });
  return {demands,edges,totals,allocations};
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
 for(const need of next.needs)checkMatches(b,need);
 requireThat(next.occurrenceId===old.occurrenceId&&!b.usedRevisionIds.includes(next.revisionId),'invalid_lineage');
 requireThat(next.sourceMealRevision===old.sourceMealRevision&&next.portions===old.portions&&next.day===old.day&&next.zone===old.zone&&next.due===old.due,'changed_commitment');
 requireThat(old.exclusions.every(e=>next.exclusions.includes(e)),'changed_exclusions');
 requireThat(equal(old.groups,next.groups),'changed_groups');
 requireThat(equal(old.needs.filter(n=>n.priority==='protected'),next.needs.filter(n=>n.priority==='protected')),'protected_need');
 const removed=old.needs.filter(n=>n.priority!=='protected');const added=next.needs.filter(n=>n.priority!=='protected');requireThat(removed.length&&added.length,'empty_replacement');
 requireThat(added.every(n=>!b.usedNeedIds.includes(n.id)),'reused_need');requireThat(!b.reservations.some(r=>removed.some(n=>n.id===r.needId)),'pinned_target');
 const preservesGroupDemands = removed.every(need => {
   const ids = groupIds(need);
   return ids.length ? ids.every(id => added.some(row => groupIds(row).includes(id))) : added.some(row => !groupIds(row).length);
 });
 requireThat(preservesGroupDemands, 'changed_groups');
 for (const need of next.needs) {
   const ids = groupIds(need);
   const sameGroup = (oldNeed:RecoveryNeed) => ids.length ? groupIds(oldNeed).some(id => ids.includes(id)) : !groupIds(oldNeed).length;
   const restrictions = [...old.exclusions, ...removed.filter(sameGroup).flatMap(n => n.exclusions)];
   requireThat(restrictions.every(e => need.exclusions.includes(e)), 'changed_exclusions');
 }
 const meals=b.meals.map(m=>m.occurrenceId===old.occurrenceId?next:m),beforeNeeds=b.meals.flatMap(m=>m.needs).concat(b.outsideNeeds),afterNeeds=meals.flatMap(m=>m.needs).concat(b.outsideNeeds);unique(afterNeeds.map(n=>n.id));
 const lots=supply(b,asOf),before=allocate(b,beforeNeeds,lots,asOf),after=allocate(b,afterNeeds,lots,asOf);
 for(const need of beforeNeeds.filter(n=>!removed.some(r=>r.id===n.id))){requireThat(cmp(after.totals.get(need.id)!,before.totals.get(need.id)!)>=0n,'steals_food');
  requireThat(equal(before.demands.find(n=>n.needId===need.id)?.issues,after.demands.find(n=>n.needId===need.id)?.issues),'changes_unrelated_issues');
  if (b.reservations.some(r => r.needId === need.id) && b.base.pantryRevision !== undefined) {
    const prior = before.demands.find(row => row.needId === need.id);
    const current = after.demands.find(row => row.needId === need.id);
    requireThat(prior && current && 'reservations' in prior && 'reservations' in current &&
      equal(prior.reservations,current.reservations), 'changes_reservation');
  }
  if(b.reservations.some(r=>r.needId===need.id))requireThat(equal(before.edges.filter(e=>e.needId===need.id).map(e=>({...e,amount:wire(e.amount)})),after.edges.filter(e=>e.needId===need.id).map(e=>({...e,amount:wire(e.amount)}))),'changes_reservation');
 }
 const foodConfirmed=b.commitmentInventoryComplete&&after.demands.filter(n=>next.needs.some(x=>x.id===n.needId)).every(n=>n.shortfall?.numerator==='0'&&n.issues.length===0);
 const timingConfirmed=next.due!==null&&next.remainingElapsedMinutes!==null&&instant(asOf)+next.remainingElapsedMinutes*60000<=instant(next.due)&&(next.requiredLeadMinutes===null||next.remainingElapsedMinutes>=next.requiredLeadMinutes||next.advanceStepsCompleted);
 const repeatRequired=i.repeatOfOccurrenceId!==null;const feasible=foodConfirmed&&timingConfirmed;
 const consentSatisfied=(!repeatRequired||i.agreesToRepeat)&&(!i.proposesExtraTrip||i.agreesToExtraTrip)&&(feasible||i.acceptsUnresolved);
 const result={base:b.base,intent:i,evidenceDigest:recoveryDigest(b.base.pantryRevision === undefined ? lots : {lots,foreignHolds:b.foreignHolds,carrySupplyRevisions:b.carrySupplyRevisions ?? []}),before:{meals:b.meals,demands:before.demands,allocations:before.allocations},after:{meals,demands:after.demands,allocations:after.allocations},foodConfirmed,timingConfirmed,repeatRequired,feasible,consentSatisfied};
 // Clock is displayed, but a harmless clock tick must not stale an identical decision.
 // Time-dependent evidence, allocations and timing are included in the digest.
 return{asOf,...result,previewDigest:recoveryDigest(result)};
}
