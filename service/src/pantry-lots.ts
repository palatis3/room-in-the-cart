import type {Context,Shop} from './repository.js';
import {z} from 'zod';
import {digest} from './database.js';
import {ServiceError,invalid,unavailable} from './errors.js';
import {pantryBodies,pantryObservation,type Quantity} from './recovery-contracts.js';
import {jointDeliveryInputs,requirePlaced,storedDeliveryEvidence,reviewReservation,sameTarget,lower,validateReservation} from './delivery-evidence.js';
import {deliveryCoverage,type DeliverySource,type ReservationHead,type SealedMeal} from './delivery-coverage.js';
import {add,amount,cmp,dimension,wire,zero} from './physical-quantity.js';

type Kind=keyof typeof pantryBodies;
type Location='pantry'|'freezer';
type Match=DeliverySource['matches'][number];
type Observation={observationId:string;confirmedAt:string;quantity:Quantity|null};
interface LotRow {
  lot_id:string;origin_shop_id:string;delivery_source_id:string|null;location:Location;
  stored_at:Date|null;use_first_at:Date|null;food_name:string|null;exclusion_tags:string[]|null;
}
interface Head {
  lot_id:string;shop_id:string;operation_id:string;kind:'observe'|'select'|'match'|'reserve';occurrence_id:string;
  meal_revision:number;ingredient_id:string;group_id:string;enabled:boolean;confirmed_at:Date;quantity:Quantity|null;
}
function target(head:Head):Match {return {occurrenceId:head.occurrence_id,mealRevision:head.meal_revision,ingredientId:head.ingredient_id};}
const stale=()=>new ServiceError(409,'stale_supply','Review the latest household stock and its commitments.');
const pantryScope=(ctx:Context,shop:Shop,revision:number)=>({shopId:shop.shop_id,shopRevision:shop.revision,
  authorityEpoch:shop.authority_epoch,placedRevision:shop.placed_revision!,pantryRevision:revision,
  supplyRevision:shop.supply_revision,asOf:ctx.now.toISOString()});
export async function pantryRevision(ctx:Context):Promise<number>{
  return (await ctx.db.query('SELECT pantry_revision FROM ritc.household WHERE household_id=$1',[ctx.householdId])).rows[0]!.pantry_revision;
}
async function requireReview(ctx:Context,shop:Shop,row:{supplyRevision:number;pantryRevision:number}){
  requirePlaced(shop);
  if(shop.supply_revision!==row.supplyRevision || await pantryRevision(ctx)!==row.pantryRevision) throw stale();
}
async function headRows(ctx:Context,ids:string[]){
  const {rows}=await ctx.db.query<Head>(`SELECT DISTINCT ON(lot_id,kind,(CASE WHEN kind='observe' THEN NULL ELSE shop_id END),
    occurrence_id,meal_revision,ingredient_id,group_id) * FROM ritc.pantry_event WHERE household_id=$1 AND lot_id=ANY($2::uuid[])
    ORDER BY lot_id,kind,(CASE WHEN kind='observe' THEN NULL ELSE shop_id END),occurrence_id,meal_revision,ingredient_id,group_id,pantry_revision DESC`,[ctx.householdId,ids]);
  return rows;
}
function review(heads:Head[],lotId:string,shopId:string) {
  const scoped=heads.filter(h=>h.lot_id===lotId && h.shop_id===shopId);
  return {selected:scoped.some(h=>h.kind==='select' && h.enabled),
    matches:scoped.filter(h=>h.kind==='match' && h.enabled).map(target),
    reservations:scoped.filter(h=>h.kind==='reserve').map(h=>({...target(h),groupId:h.group_id,reservationId:h.operation_id,quantity:h.quantity}))};
}
type Delivery=Awaited<ReturnType<typeof storedDeliveryEvidence>>[number];
function materialize(row:LotRow,heads:Head[],delivery:Delivery|undefined) {
  const head=heads.find(h=>h.lot_id===row.lot_id && h.kind==='observe');
  let observation:Observation|null=null;
  if(delivery?.usable) observation={observationId:delivery.usable.observationId,confirmedAt:delivery.usable.confirmedAt,quantity:delivery.confirmed?.quantity??null};
  else if(head) observation={observationId:head.operation_id,confirmedAt:head.confirmed_at.toISOString(),quantity:head.quantity};
  return {lotId:row.lot_id,origin:row.delivery_source_id?'delivery' as const:'manual' as const,
    location:row.location,storedAt:row.stored_at,useFirstAt:row.use_first_at,foodName:delivery?.foodName??row.food_name!,
    exclusionTags:delivery?.exclusionTags??row.exclusion_tags!,observation};
}

export async function readPantry(ctx:Context,shop:Shop,cursor:string|null) {
  requirePlaced(shop,true);
  const result=await ctx.db.query<LotRow>('SELECT * FROM ritc.pantry_lot WHERE household_id=$1 AND ($2::uuid IS NULL OR lot_id>$2) ORDER BY lot_id LIMIT 51',[ctx.householdId,cursor]);
  const page=result.rows.slice(0,50),ids=page.map(l=>l.lot_id);
  const heads=await headRows(ctx,ids),delivered=await storedDeliveryEvidence(ctx,page.flatMap(l=>l.delivery_source_id?[l.delivery_source_id]:[]));
  const lots=page.map(l=>({...materialize(l,heads,delivered.find(s=>s.sourceId===l.lot_id)),...review(heads,l.lot_id,shop.shop_id)}));
  return {...pantryScope(ctx,shop,await pantryRevision(ctx)),lots,nextCursor:result.rows.length>50?ids.at(-1):null};
}

// Only shops joined by the same physical stock participate. Scope occurrence
// IDs internally because different shops may use the same application UUID.
const scoped=(shopId:string,id:string)=>shopId+'/'+id;
const unscoped=(id:string)=>id.slice(id.indexOf('/')+1);
function targetKey(sourceId:string,m:Match){return [sourceId,m.occurrenceId,m.mealRevision,m.ingredientId].join('/');}
export async function linkedComponent(ctx:Context,shop:Shop,focus:string|null){
  const {rows:edges}=await ctx.db.query<{lot_id:string;shop_id:string}>(`SELECT lot_id,shop_id FROM (
    SELECT DISTINCT ON(lot_id,shop_id) lot_id,shop_id,enabled FROM ritc.pantry_event WHERE household_id=$1 AND kind='select'
    ORDER BY lot_id,shop_id,pantry_revision DESC) current WHERE enabled
    UNION SELECT lot_id,origin_shop_id FROM ritc.pantry_lot WHERE household_id=$1 AND delivery_source_id IS NOT NULL`,[ctx.householdId]);
  const shops=new Set([shop.shop_id]),lots=new Set<string>(focus?[focus]:[]);
  let size=0;
  while(size!==shops.size+lots.size){
    size=shops.size+lots.size;
    for(const e of edges) if(shops.has(e.shop_id)||lots.has(e.lot_id)){shops.add(e.shop_id);lots.add(e.lot_id);}
  }
  return {shops,lots};
}

export async function trackCookStockProvenance(ctx:Context,shop:Shop,copyId:string){
  const {shops,lots}=await linkedComponent(ctx,shop,null);
  // Snapshot the component at the time of review. Future selections cannot
  // change which historical explicit copy incorporated this physical evidence.
  await ctx.db.query(`INSERT INTO ritc.cook_copy_pantry_scope(household_id,copy_id,shop_id)
    SELECT $1,$2,unnest($3::uuid[])`,[ctx.householdId,copyId,[...shops]]);
  await ctx.db.query(`INSERT INTO ritc.cook_copy_pantry_actor(household_id,copy_id,member_id)
    SELECT $1,$2,actor_id FROM (
      SELECT actor_id FROM ritc.pantry_lot WHERE household_id=$1 AND lot_id=ANY($3::uuid[])
      UNION SELECT actor_id FROM ritc.pantry_event WHERE household_id=$1 AND lot_id=ANY($3::uuid[])
      UNION SELECT actor_id FROM ritc.operation WHERE household_id=$1 AND shop_id=ANY($4::uuid[]) AND kind LIKE 'delivery.%'
      UNION SELECT actor_id FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=ANY($4::uuid[])
    ) origins`,[ctx.householdId,copyId,[...lots],[...shops]]);
}
export async function jointInputs(ctx:Context,shop:Shop,focus:string|null=null,includeInventory=false){
  const {shops,lots}=await linkedComponent(ctx,shop,focus);
  const mealRows:SealedMeal[]=[],sources=new Map<string,DeliverySource>(),kinds=new Map<string,'delivery'|Location>();
  const delivery=await jointDeliveryInputs(ctx,[...shops],[...lots],includeInventory);
  const sourceRows=new Map<string,Delivery>();
  for(const {shopId,...meal} of delivery.meals) mealRows.push({...meal,occurrenceId:scoped(shopId,meal.occurrenceId)});
  for(const {shopId,physical} of delivery.sources){
    const map=<T extends Match>(m:T)=>({...m,occurrenceId:scoped(shopId,m.occurrenceId)});
    const matches=physical.matches.map(map);
    sourceRows.set(physical.sourceId,physical);
    sources.set(physical.sourceId,{...physical,matches,reservations:physical.reservations.map(map)});
    for(const m of matches) kinds.set(targetKey(physical.sourceId,m),'delivery');
  }
  const {rows}=await ctx.db.query<LotRow>('SELECT * FROM ritc.pantry_lot WHERE household_id=$1 AND lot_id=ANY($2::uuid[]) ORDER BY use_first_at NULLS LAST,lot_id',[ctx.householdId,[...lots]]);
  const heads=await headRows(ctx,[...lots]);
  for(const lot of rows){
    const value=materialize(lot,heads,sourceRows.get(lot.lot_id));
    const source=sources.get(lot.lot_id)??{sourceId:lot.lot_id,foodName:value.foodName,exclusionTags:value.exclusionTags,
      confirmed:value.observation?.quantity?{quantity:value.observation.quantity}:null,matches:[],reservations:[]};
    sources.set(lot.lot_id,source);
    for(const s of shops){
      const reviews=review(heads,lot.lot_id,s);
      if(!reviews.selected) continue;
      for(const match of reviews.matches){
        const m={...match,occurrenceId:scoped(s,match.occurrenceId)};
        const key=targetKey(lot.lot_id,m);
        if(kinds.has(key)) throw reviewReservation();
        kinds.set(key,lot.location);source.matches.push(m);
      }
      for(const pin of reviews.reservations) source.reservations!.push({...pin,occurrenceId:scoped(s,pin.occurrenceId)});
    }
  }
  const preferences=new Map(rows.filter(l=>l.use_first_at!==null).map(l=>[l.lot_id,l.use_first_at!.getTime()]));
  const ordered=[...sources.values()].sort((a,b)=>(preferences.get(a.sourceId)??Infinity)-(preferences.get(b.sourceId)??Infinity));
  return {meals:mealRows,sources:ordered,kinds,heads,rows,shopIds:[...shops],deliverySources:delivery.sources};
}
type Inputs=Awaited<ReturnType<typeof jointInputs>>;
type Needs=ReturnType<typeof deliveryCoverage>['needs'];
function project(input:Inputs){return deliveryCoverage(input.meals,input.sources);}
function visible(shop:Shop,occurrence:string){return occurrence.startsWith(shop.shop_id+'/');}
function bucket(allocations:{amount:{numerator:string;denominator:string};kind:string}[],kind:string){
  return wire(allocations.filter(a=>a.kind===kind).reduce((sum,a)=>add(sum,{n:BigInt(a.amount.numerator),d:BigInt(a.amount.denominator)}),zero));
}
export async function readJointCoverage(ctx:Context,shop:Shop){
  requirePlaced(shop,true);
  const input=await jointInputs(ctx,shop),report=project(input);
  const needs=report.needs.filter(n=>visible(shop,n.occurrenceId)).map(n=>{
    const allocations=n.allocations.map(a=>({...a,kind:input.kinds.get(targetKey(a.sourceId,n))!}));
    return {...n,occurrenceId:unscoped(n.occurrenceId),allocations,
      delivered:n.required?bucket(allocations,'delivery'):null,pantry:n.required?bucket(allocations,'pantry'):null,freezer:n.required?bucket(allocations,'freezer'):null};
  });
  return {...pantryScope(ctx,shop,await pantryRevision(ctx)),unplannedOccurrenceIds:report.unplannedOccurrenceIds.filter(id=>visible(shop,id)).map(unscoped),needs};
}

function checkOthers(shop:Shop,before:Needs,after:Needs){
  for(const [index,old] of before.entries()){
    if(visible(shop,old.occurrenceId)) continue;
    const now=after[index]!;
    if(old.covered && now.covered && lower(now.covered,old.covered)) throw reviewReservation();
    for(const pin of old.reservations){
      const updated=now.reservations.find(p=>p.reservationId===pin.reservationId);
      if(!updated || lower(updated.backed,pin.backed)) throw reviewReservation();
    }
  }
}
export interface EffectivePantryProjection {
  needs():Needs;
  matches(row:Needs[number],sourceId:string):boolean;
}
export type PantryProjectionLoader=(ctx:Context,shop:Shop,input:Inputs)=>Promise<EffectivePantryProjection|undefined>;
async function observationImpact(ctx:Context,shop:Shop,row:z.infer<typeof pantryObservation>,loadProjection?:PantryProjectionLoader){
  await requireReview(ctx,shop,row);
  if(Date.parse(row.confirmedAt)>ctx.now.getTime()) throw invalid();
  const input=await jointInputs(ctx,shop,row.lotId,Boolean(loadProjection));
  const lot=input.rows.find(l=>l.lot_id===row.lotId);
  if(!lot) throw unavailable();
  if(lot.delivery_source_id) throw reviewReservation();
  const head=input.heads.find(h=>h.lot_id===row.lotId && h.kind==='observe');
  if((head?.operation_id??null)!==row.predecessorId) throw stale();
  const source=input.sources.find(s=>s.sourceId===row.lotId)!;
  const effective=await loadProjection?.(ctx,shop,input);
  const needsForStock=()=>effective?effective.needs():project(input).needs;
  const matches=(row:Needs[number])=>effective?effective.matches(row,source.sourceId):source.matches.some(m=>sameTarget(row,m));
  const before=needsForStock();
  source.confirmed=row.quantity?{quantity:row.quantity}:null;
  const after=needsForStock();
  let otherShopsAffected=false,otherShopsCommitted=false;
  const needs=before.flatMap((n,i)=>{
    const next=after[i]!,changed=digest(n)!==digest(next);
    if(!visible(shop,n.occurrenceId)){
      if(changed) otherShopsAffected=true;
      if([n,next].some(row=>row.allocations.some(a=>a.sourceId===source.sourceId) || row.reservations.some(p=>p.sourceId===source.sourceId) ||
        row.protected && !row.required && matches(row))) otherShopsCommitted=true;
      return [];
    }
    if(!changed && !matches(n)) return [];
    return [{occurrenceId:unscoped(n.occurrenceId),mealRevision:n.mealRevision,ingredientId:n.ingredientId,groupIds:n.groupIds,required:n.required,
      beforeCovered:n.covered,afterCovered:next.covered,beforeMissing:n.missing,afterMissing:next.missing,
      beforeReservations:n.reservations,afterReservations:next.reservations}];
  });
  const previewDigest=digest({household:ctx.householdId,shop:shop.shop_id,revision:shop.revision,epoch:shop.authority_epoch,
    member:ctx.member.member_id,row,before,after});
  return {...pantryScope(ctx,shop,row.pantryRevision),lotId:row.lotId,previewDigest,needs,otherShopsAffected,otherShopsCommitted};
}
export function previewPantryObservation(ctx:Context,shop:Shop,input:unknown,projection?:PantryProjectionLoader){return observationImpact(ctx,shop,pantryObservation.parse(input),projection);}

export async function pantryOperationExists(ctx:Context,id:string){
  return (await ctx.db.query(`SELECT 1 FROM ritc.pantry_lot WHERE household_id=$1 AND operation_id=$2
    UNION ALL SELECT 1 FROM ritc.pantry_event WHERE household_id=$1 AND operation_id=$2`,[ctx.householdId,id])).rowCount===1;
}

export async function recordPantry(ctx:Context,shop:Shop,kind:Kind,input:unknown,operationId:string,verifyEffective?:()=>Promise<void>,projection?:PantryProjectionLoader){
  const body=pantryBodies[kind].parse(input);
  await requireReview(ctx,shop,body);
  const revision=body.pantryRevision+1;
  const lotId='lotId' in body?body.lotId:'sourceId' in body?body.sourceId:operationId;
  const scope=[ctx.householdId,lotId,shop.shop_id];
  if('location' in body){
    if(body.storedAt && Date.parse(body.storedAt)>ctx.now.getTime()) throw invalid();
    if('sourceId' in body){
      const [delivery]=await storedDeliveryEvidence(ctx,[body.sourceId],shop.shop_id);
      if(!delivery?.confirmed) throw reviewReservation();
    }
    const result=await ctx.db.query(`INSERT INTO ritc.pantry_lot(household_id,lot_id,origin_shop_id,delivery_source_id,location,
      stored_at,use_first_at,food_name,exclusion_tags,actor_id,operation_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
      ON CONFLICT(household_id,lot_id) DO NOTHING`,[...scope,'sourceId' in body?lotId:null,body.location,body.storedAt,body.useFirstAt,
        'foodName' in body?body.foodName:null,'exclusionTags' in body?body.exclusionTags:null,ctx.member.member_id,operationId]);
    if(!result.rowCount) throw stale();
  }else{
    if('previewDigest' in body){
      const {previewDigest,...observation}=body;
      if((await observationImpact(ctx,shop,observation,projection)).previewDigest!==previewDigest) throw stale();
    }else{
      const joint=await jointInputs(ctx,shop,lotId),source=joint.sources.find(s=>s.sourceId===lotId);
      if(!source || !joint.rows.some(l=>l.lot_id===lotId)) throw unavailable();
      const current=review(joint.heads,lotId,shop.shop_id);
      if('selected' in body){
        if(current.selected===body.selected) throw stale();
        if(!body.selected && current.matches.length) throw reviewReservation();
      }else{
        if(!current.selected) throw reviewReservation();
        const m={occurrenceId:scoped(shop.shop_id,body.occurrenceId),mealRevision:body.mealRevision,ingredientId:body.ingredientId};
        const meal=joint.meals.find(v=>v.occurrenceId===m.occurrenceId && v.revision===m.mealRevision);
        if(!meal?.meal.planning?.ingredients.some(i=>i.id===m.ingredientId)) throw unavailable();
        const matched=current.matches.some(r=>sameTarget(r,body));
        if('matched' in body){
          if(matched===body.matched) throw stale();
          if(body.matched && source.matches.some(r=>sameTarget(r,m)) ||
             !body.matched && current.reservations.some(p=>p.quantity && sameTarget(p,body))) throw reviewReservation();
          if(!verifyEffective){
            const before=project(joint).needs;
            source.matches=source.matches.filter(r=>!sameTarget(r,m));
            if(body.matched) source.matches.push(m);
            checkOthers(shop,before,project(joint).needs);
          }
        }else{
          if(!matched) throw reviewReservation();
          const head=current.reservations.find(r=>sameTarget(r,body) && r.groupId===body.groupId);
          if((head?.reservationId??null)!==body.predecessorId || (!body.quantity && !head?.quantity)) throw stale();
          const reduction=head?.quantity && body.quantity && dimension(head.quantity)===dimension(body.quantity) && cmp(amount(body.quantity),amount(head.quantity))<0n;
          if(body.quantity && !reduction && !verifyEffective){
            const updated:ReservationHead[]=(source.reservations??[]).filter(p=>p.reservationId!==body.predecessorId);
            updated.push({...m,groupId:body.groupId,quantity:body.quantity,reservationId:operationId});
            validateReservation(joint.meals,joint.sources,source,{...body,...m,sourceId:lotId},updated);
            const before=project(joint).needs;
            source.reservations=updated;
            checkOthers(shop,before,project(joint).needs);
          }
        }
      }
    }
    await ctx.db.query(`INSERT INTO ritc.pantry_event(household_id,lot_id,shop_id,operation_id,actor_id,kind,pantry_revision,occurrence_id,
      meal_revision,ingredient_id,group_id,enabled,confirmed_at,quantity) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
      [...scope,operationId,ctx.member.member_id,kind.slice(7),revision,'occurrenceId' in body?body.occurrenceId:null,'mealRevision' in body?body.mealRevision:null,
        'ingredientId' in body?body.ingredientId:null,'groupId' in body?body.groupId:null,
        'selected' in body?body.selected:'matched' in body?body.matched:null,'confirmedAt' in body?body.confirmedAt:null,'quantity' in body?body.quantity:null]);
  }
  await ctx.db.query('UPDATE ritc.household SET pantry_revision=$2 WHERE household_id=$1',[ctx.householdId,revision]);
  await verifyEffective?.();
  return {lotId,pantryRevision:revision,supplyRevision:shop.supply_revision};
}
export function isPantryCommand(kind:string):kind is Kind{return Object.hasOwn(pantryBodies,kind);}

// Older delivery clients edit through their existing route. Check linked pantry
// commitments in the same command transaction, so either all changes or none commit.
export async function guardDeliveryEdit(ctx:Context,shop:Shop,kind:string,body:Record<string,unknown>){
  if(kind!=='delivery.match' && kind!=='delivery.reserve') return;
  const linked=await ctx.db.query(`SELECT 1 FROM ritc.pantry_event WHERE household_id=$1 AND shop_id=$2 AND kind='select'
    UNION ALL SELECT 1 FROM ritc.pantry_lot WHERE household_id=$1 AND origin_shop_id=$2 AND delivery_source_id IS NOT NULL LIMIT 1`,[ctx.householdId,shop.shop_id]);
  if(!linked.rowCount) return;
  const before=await jointInputs(ctx,shop,String(body.sourceId)),old=project(before).needs;
  const source=before.sources.find(s=>s.sourceId===body.sourceId);
  if(!source) throw unavailable();
  const m={occurrenceId:scoped(shop.shop_id,String(body.occurrenceId)),mealRevision:Number(body.mealRevision),ingredientId:String(body.ingredientId)};
  if(kind==='delivery.match' && body.matched && before.kinds.has(targetKey(source.sourceId,m)) && before.kinds.get(targetKey(source.sourceId,m))!=='delivery') throw reviewReservation();
  return async ()=>{
    const next=await jointInputs(ctx,shop),after=project(next).needs;
    checkOthers(shop,old,after);
    if(kind!=='delivery.reserve' || !body.quantity) return;
    const newSource=next.sources.find(s=>s.sourceId===body.sourceId)!;
    const quantity=body.quantity as Quantity,head=source.reservations?.find(p=>p.reservationId===body.predecessorId);
    if(head?.quantity && dimension(quantity)===dimension(head.quantity) && cmp(amount(quantity),amount(head.quantity))<0n) return;
    validateReservation(before.meals,before.sources,source,{...m,sourceId:source.sourceId,supplyRevision:shop.supply_revision,groupId:String(body.groupId),
      predecessorId:head?.reservationId??null,quantity},newSource.reservations!);
  };
}
