import {createHash} from 'node:crypto';
import {deliveryCoverage,type SealedMeal,type DeliverySource} from './delivery-coverage.js';
import {requirePlaced,recordDelivery,reviewReservation,validateReservation,lower} from './delivery-evidence.js';
import {unavailable,ServiceError} from './errors.js';
import {jointInputs,pantryRevision,guardDeliveryEdit,recordPantry,previewPantryObservation,type PantryProjectionLoader} from './pantry-lots.js';
import {add,amount,cmp,dimension,inUnit,sub,wire,zero,type Rat} from './physical-quantity.js';
import {deliveryReservationBody,pantryBodies,recoveryBasisSchema,recoveryMealSchema,type Quantity,type RecoveryBasis,type RecoveryMeal,type RecoveryNeed} from './recovery-contracts.js';
import {exclusionConflict} from './recovery-domain.js';
import type {Context,Shop} from './repository.js';

/** Only the publication repository supplies accepted overlays and lifetime identity fences. */
export interface SharedRecoveryPublication {
  recoveryRevision:number;contextRevision:number;meals:RecoveryMeal[];usedNeedIds:string[];usedRevisionIds:string[];
  removedOccurrences?:string[];
}
export type RecoveryPublicationLoader=(ctx:Context,shopID:string)=>Promise<SharedRecoveryPublication>;
type Stock=Awaited<ReturnType<typeof jointInputs>>;
type Origin='delivery'|'pantry'|'freezer';
interface ScopedMeal {shopId:string;sealed:SealedMeal;original:RecoveryMeal;current:RecoveryMeal|null}

// UUIDv5 within the occurrence namespace. Scoped recipe copies can legitimately
// reuse every ingredient, binding and named-group UUID of another dinner.
function reviewedID(occurrence:string,...parts:(string|number)[]){
  const hash=createHash('sha1').update(Buffer.from(occurrence.replaceAll('-',''),'hex')).update(JSON.stringify(parts)).digest();
  hash[6]=((hash[6]??0)&0x0f)|0x50;hash[8]=((hash[8]??0)&0x3f)|0x80;
  const hex=hash.toString('hex',0,16);
  return [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');
}
const unique=<T>(values:T[])=>[...new Set(values)];
function sealedDefinition(fact:SealedMeal,shopId:string,stock:Stock):RecoveryMeal {
  const {revision,meal}=fact,occurrenceId=fact.occurrenceId.split('/')[1]!,plan=meal.planning;
  const groups=(plan?.groups??[]).map(g=>({...g,protected:meal.protected||g.protected,exclusions:[]}));
  const exclusions=plan?.exclusions??[];
  const needs=(plan?.ingredients??[]).flatMap(ingredient=>{
    const bindings=(plan?.bindings??[]).filter(b=>b.ingredientId===ingredient.id);
    const complete=bindings.length>0 && bindings.length===ingredient.groupIds.length;
    const parts=complete?bindings.map(b=>({ids:[b.groupId],quantity:b.quantity})):[{ids:ingredient.groupIds,quantity:ingredient.quantity}];
    const matchedSourceIds=stock.sources.filter(s=>s.matches.some(m=>m.occurrenceId===fact.occurrenceId &&
      m.mealRevision===revision && m.ingredientId===ingredient.id)).map(s=>s.sourceId);
    return parts.map(({ids,quantity})=>{
      const groupId=ids.length===1?ids[0]!:null;
      return {id:reviewedID(occurrenceId,shopId,revision,'need',ingredient.id,...ids),foodId:null,ingredientId:ingredient.id,
        groupId,...(groupId===null?{groupIds:ids}:{}),name:ingredient.name,notes:'',quantity,matchedSourceIds,
        priority:meal.protected||groups.some(g=>g.protected&&ids.includes(g.id))?'protected' as const:'required' as const,
        due:null,exclusions:unique([...exclusions,...ingredient.exclusions])};
    });
  });
  return recoveryMealSchema.parse({occurrenceId,revisionId:reviewedID(occurrenceId,shopId,revision,'meal'),sourceMealRevision:revision,
    title:meal.title,notes:'',sourceURL:null,portions:meal.portions,day:meal.day,zone:null,due:null,exclusions,template:null,
    groups,needs,remainingElapsedMinutes:null,requiredLeadMinutes:plan?.leadTimeMinutes??null,advanceStepsCompleted:false});
}

function eligibleOrigin(stock:Stock,shopId:string,sourceId:string):Origin|undefined{
  const lot=stock.rows.find(l=>l.lot_id===sourceId);
  if(lot && stock.heads.some(h=>h.lot_id===sourceId && h.shop_id===shopId && h.kind==='select' && h.enabled)) return lot.location;
  if(stock.deliverySources.some(s=>s.shopId===shopId && s.physical.sourceId===sourceId)) return 'delivery';
}
function originForNeed(stock:Stock,m:ScopedMeal,n:RecoveryNeed,sourceId:string):Origin|undefined{
  const prefix=m.shopId+'/'+m.current!.occurrenceId;
  if(m.original.needs.some(old=>old.id===n.id)){
    const reviewed=stock.kinds.get([sourceId,prefix,m.sealed.revision,n.ingredientId].join('/'));
    if(reviewed) return reviewed;
  }
  return eligibleOrigin(stock,m.shopId,sourceId);
}
async function effectiveMeals(ctx:Context,stock:Stock,load:RecoveryPublicationLoader){
  const publications=new Map<string,SharedRecoveryPublication>();
  for(const id of stock.shopIds) publications.set(id,await load(ctx,id));
  const meals:ScopedMeal[]=stock.meals.map(sealed=>{
    const shopId=sealed.occurrenceId.split('/')[0]!,p=publications.get(shopId)!;
    const original=sealedDefinition(sealed,shopId,stock);
    const accepted=p.meals.find(m=>m.occurrenceId===original.occurrenceId);
    if(accepted && accepted.sourceMealRevision!==sealed.revision) throw unavailable();
    // Original identities follow current reviews; replacement identities use their
    // accepted explicit matches while the original lot is still in this scope.
    const current=p.removedOccurrences?.includes(original.occurrenceId)?null:accepted?recoveryMealSchema.parse({...accepted,
      needs:accepted.needs.map(n=>{
        const retained=original.needs.find(old=>old.id===n.id);
        const nativeFood=stock.deliverySources.find(s=>s.shopId===shopId && s.physical.foodId===n.foodId);
        const accepted=n.matchedSourceIds??(nativeFood?[nativeFood.physical.sourceId]:[]);
        return {...n,matchedSourceIds:retained?.matchedSourceIds??accepted.filter(id=>eligibleOrigin(stock,shopId,id))};
      })}):original;
    return {shopId,sealed,original,current};
  });
  return {meals,publications};
}

// Existing delivery allocation accepts one ingredient mapped to one or more
// groups. Give each effective recovery need an internal key so two groups'
// explicitly reviewed sources or exclusions can differ after publication.
function effectiveGraph(stock:Stock,meals:ScopedMeal[]){
  const sources:DeliverySource[]=stock.sources.map(s=>({...s,matches:[],reservations:[]}));
  const byId=new Map(sources.map(s=>[s.sourceId,s])),pins:(RecoveryBasis['reservations'][number]&{shopId:string})[]=[],needByKey=new Map<string,RecoveryNeed>();
  const kinds=new Map<string,Origin>();
  const projected:SealedMeal[]=meals.flatMap(m=>{
    const meal=m.current;
    if(!meal) return [];
    const ingredients=meal.needs.map(n=>{
      const key=m.shopId+'/'+n.id;
      needByKey.set(key,n);
      const ids=n.groupId?[n.groupId]:n.groupIds??[];
      const matched=n.matchedSourceIds??[];
      for(const id of matched){
        const source=byId.get(id),kind=originForNeed(stock,m,n,id);
        if(!source||!kind) continue;
        const target={occurrenceId:m.sealed.occurrenceId,mealRevision:m.sealed.revision,ingredientId:key};
        source.matches.push(target);kinds.set(id+'/'+key,kind);
        const physical=stock.sources.find(s=>s.sourceId===id)!;
        for(const pin of physical.reservations??[]) if(pin.occurrenceId===target.occurrenceId &&
          pin.mealRevision===m.sealed.revision && pin.ingredientId===n.ingredientId && pin.groupId===n.groupId &&
          m.original.needs.some(old=>old.id===n.id)){
          source.reservations!.push({...pin,...target});
          if(pin.quantity) pins.push({shopId:m.shopId,id:pin.reservationId,sourceId:id,needId:n.id,quantity:pin.quantity});
        }
      }
      return {id:key,name:n.name,quantity:n.quantity,groupIds:ids,exclusions:n.exclusions};
    });
    return [{...m.sealed,protectedIngredientIds:meal.needs.filter(n=>n.priority==='protected').map(n=>m.shopId+'/'+n.id),
      meal:{...m.sealed.meal,title:meal.title,day:meal.day,portions:meal.portions,
      planning:{groups:meal.groups,ingredients}}}];
  });
  return {report:deliveryCoverage(projected,sources),projected,needByKey,kinds,pins,sources};
}
const fraction=(f:{numerator:string;denominator:string}):Rat=>({n:BigInt(f.numerator),d:BigInt(f.denominator)});
type Graph=ReturnType<typeof effectiveGraph>;
function outsideHolds(shop:Shop,graph:Graph,visible:Set<string>){
  const held=new Map<string,{unit:Quantity['unit'];value:Rat}|null>();
  for(const row of graph.report.needs){
    if(row.occurrenceId.startsWith(shop.shop_id+'/')) continue;
    const restricted=graph.needByKey.get(row.ingredientId)!;
    for(const source of graph.sources){
      if(!visible.has(source.sourceId)||held.get(source.sourceId)===null) continue;
      if(!source.matches.some(m=>m.ingredientId===row.ingredientId)) continue;
      if(!row.required){
        if(row.protected && !exclusionConflict(restricted,{name:source.foodName,exclusionTags:source.exclusionTags})) held.set(source.sourceId,null);
        continue;
      }
      // Backed named portions are already included in allocations. Also hold
      // unbacked requests so a later recovery cannot acquire another shop's promise.
      const allocation=row.allocations.find(a=>a.sourceId===source.sourceId);
      const pin=row.reservations.find(p=>p.sourceId===source.sourceId);
      const used=add(allocation?fraction(allocation.amount):zero,pin?sub(fraction(pin.requested),fraction(pin.backed)):zero);
      if(used.n===0n) continue;
      const prior=held.get(source.sourceId),unit=prior?.unit??row.required.unit;
      if(dimension({...row.required,unit})!==dimension(row.required) ||
         source.confirmed && dimension(source.confirmed.quantity)!==dimension(row.required)){
        held.set(source.sourceId,null);continue;
      }
      const scale=amount({...row.required,amount:{numerator:1,denominator:1}});
      held.set(source.sourceId,{unit,value:add(prior?.value??zero,{n:used.n*scale.n,d:used.d*scale.d})});
    }
  }
  return [...held].map(([sourceId,h])=>({sourceId,quantity:h?{unit:h.unit,amount:inUnit(h.value,h.unit)}:null}));
}

async function loadGraph(ctx:Context,shop:Shop,load:RecoveryPublicationLoader,focus:string|null=null){
  if(shop.household_id!==ctx.householdId || shop.shopper_id!==ctx.member.member_id || ctx.member.kind!=='adult' ||
     ctx.viewGrantId || ctx.selectedShopId && shop.shop_id!==ctx.selectedShopId) throw unavailable();
  requirePlaced(shop,true);
  const stock=await jointInputs(ctx,shop,focus,true);
  const {meals,publications}=await effectiveMeals(ctx,stock,load);
  const local=meals.filter(m=>m.shopId===shop.shop_id);
  const current=local.flatMap(m=>m.current?[m.current]:[]);
  const options=stock.sources.flatMap(s=>{
    const kind=eligibleOrigin(stock,shop.shop_id,s.sourceId);
    return kind?[{sourceId:s.sourceId,name:s.foodName,exclusionTags:s.exclusionTags,kind,quantity:s.confirmed?.quantity??null}]:[];
  });
  const p=publications.get(shop.shop_id)!;
  const base={shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,recoveryRevision:p.recoveryRevision,
    contextRevision:p.contextRevision,supplyRevision:shop.supply_revision,pantryRevision:await pantryRevision(ctx)};
  return {stock,graph:effectiveGraph(stock,meals),local,current,options,base,p,hasRecovery:[...publications.values()].some(p=>p.recoveryRevision>0)};
}
type Loaded=Awaited<ReturnType<typeof loadGraph>>;

async function history(ctx:Context,shop:Shop,state:Loaded){
  const ids=state.options.map(s=>s.sourceId);
  const deliveries=(await ctx.db.query(`SELECT s.source_id,s.shop_id,s.placed_revision,s.line_id,s.segment_key,sh.supply_revision
    FROM ritc.delivery_source s JOIN ritc.shop sh USING(household_id,shop_id)
    WHERE s.household_id=$1 AND s.source_id=ANY($2::uuid[]) ORDER BY s.source_id`,[ctx.householdId,ids])).rows;
  const sources=state.options.map(o=>{
    const delivery=deliveries.find(d=>d.source_id===o.sourceId);
    const lot=state.stock.rows.find(l=>l.lot_id===o.sourceId);
    if(!delivery && !lot) throw unavailable();
    return {householdId:ctx.householdId,id:o.sourceId,foodId:o.sourceId,identityRevision:1,shopId:delivery?.shop_id??lot!.origin_shop_id,
      origin:delivery?{kind:'delivery',sealedOrderRevision:delivery.placed_revision,orderLineId:delivery.line_id,segmentKey:delivery.segment_key}:
        {kind:'sharedStock',batchId:o.sourceId,location:lot!.location}};
  });
  const deliveryRows=await ctx.db.query(`SELECT * FROM ritc.delivery_observation WHERE household_id=$1 AND source_id=ANY($2::uuid[])
    ORDER BY shop_id,supply_revision`,[ctx.householdId,deliveries.map(d=>d.source_id)]);
  const arrivals=[],usable=[];
  for(const d of deliveryRows.rows){
    const common={householdId:ctx.householdId,shopId:d.shop_id,id:d.observation_id,sourceId:d.source_id,identityRevision:1,
      revision:d.supply_revision,predecessorId:d.body.predecessorId,recordedAt:d.recorded_at.toISOString(),actorId:d.actor_id,operationId:d.operation_id};
    if(d.kind==='arrival')arrivals.push({...common,arrivedAt:d.body.arrivedAt,received:d.body.received});
    else usable.push({...common,arrivalObservationId:d.body.arrivalObservationId,confirmedAt:d.body.confirmedAt,usable:d.body.usable});
  }
  const pantry=await ctx.db.query(`SELECT e.lot_id AS "sourceId",e.operation_id AS id,e.pantry_revision AS revision,e.quantity,
    e.confirmed_at AS "confirmedAt",o.committed_at AS "recordedAt",lag(e.operation_id) OVER(PARTITION BY e.lot_id ORDER BY e.pantry_revision) AS "predecessorId"
    FROM ritc.pantry_event e JOIN ritc.operation o USING(household_id,operation_id) WHERE e.household_id=$1 AND e.kind='observe'
    AND e.lot_id=ANY($2::uuid[]) ORDER BY e.lot_id,e.pantry_revision`,[ctx.householdId,ids]);
  const pantryObservations=pantry.rows.map(r=>({...r,householdId:ctx.householdId,identityRevision:1,confirmedAt:r.confirmedAt.toISOString(),recordedAt:r.recordedAt.toISOString()}));
  const selectedCarrySourceIds=sources.filter(s=>s.shopId!==shop.shop_id).map(s=>s.id);
  const carrySupplyRevisions=[...new Map(deliveries.filter(d=>d.shop_id!==shop.shop_id).map(d=>
    [d.shop_id,{shopId:d.shop_id,supplyRevision:d.supply_revision}])).values()];
  return {sources,arrivals,usable,pantryObservations,selectedCarrySourceIds,carrySupplyRevisions};
}

/** Call inside an authorized household command/read transaction. Never serialize
 * this internal basis: it includes genuine observation provenance from carried lots. */
export async function loadSharedRecoveryBasis(ctx:Context,shop:Shop,load:RecoveryPublicationLoader):Promise<RecoveryBasis>{
  const state=await loadGraph(ctx,shop,load),own=new Set(state.options.map(s=>s.sourceId));
  const physical=await history(ctx,shop,state);
  const used=[...state.local.map(m=>m.original),...state.current];
  const localNeedIds=new Set(state.current.flatMap(m=>m.needs.map(n=>n.id)));
  return recoveryBasisSchema.parse({householdId:ctx.householdId,shopId:shop.shop_id,base:state.base,...physical,
    foods:state.options.map(o=>({id:o.sourceId,name:o.name,exclusionTags:o.exclusionTags})),
    meals:state.current,outsideNeeds:[],reservations:state.graph.pins.filter(p=>p.shopId===shop.shop_id && own.has(p.sourceId)&&localNeedIds.has(p.needId)).map(({shopId,...pin})=>pin),
    foreignHolds:outsideHolds(shop,state.graph,own),
    usedNeedIds:unique([...state.p.usedNeedIds,...used.flatMap(m=>m.needs.map(n=>n.id))]),
    usedRevisionIds:unique([...state.p.usedRevisionIds,...used.map(m=>m.revisionId)]),knownTemplateIds:[],
    commitmentInventoryComplete:state.current.every(m=>m.needs.length>0)});
}

export async function readSharedRecoveryContext(ctx:Context,shop:Shop,load:RecoveryPublicationLoader){
  const state=await loadGraph(ctx,shop,load);
  const ideas=await ctx.db.query(`SELECT c.occurrence_id,c.shop_revision+1 AS meal_revision,
    c.body->>'approvedIdeaId' AS id,(c.body->>'approvedIdeaRevision')::integer AS revision
    FROM ritc.shared_meal_change c JOIN ritc.shared_meal_revision m ON (m.household_id,m.shop_id,m.occurrence_id,m.revision)=
      (c.household_id,c.shop_id,c.occurrence_id,c.shop_revision+1) AND m.meal=c.body->'meal'
    WHERE c.household_id=$1 AND c.shop_id=$2 AND c.state='applied' AND c.base_meal_revision IS NULL AND c.body ? 'approvedIdeaId'`,[ctx.householdId,shop.shop_id]);
  const mealSources=state.local.filter(m=>m.current).map(m=>{
    const original=m.sealed.meal.planning,idea=ideas.rows.find(r=>r.occurrence_id===m.original.occurrenceId && r.meal_revision===m.sealed.revision);
    const source=original?.sourceOccurrenceId;
    return {occurrenceId:m.original.occurrenceId,sourceMealRevision:m.sealed.revision,completedSteps:original?.completedSteps??[],
      sourceOccurrenceId:source&&source!==m.original.occurrenceId&&state.current.some(x=>x.occurrenceId===source)?source:null,
      approvedIdea:idea?{id:idea.id,revision:idea.revision}:null};
  });
  return {shopId:shop.shop_id,placedRevision:shop.placed_revision!,base:state.base,asOf:ctx.now.toISOString(),meals:state.current,
    sourceOptions:state.options,mealSources,unplannedOccurrenceIds:state.current.filter(m=>!m.needs.length).map(m=>m.occurrenceId),
    commitmentInventoryComplete:state.current.every(m=>m.needs.length>0)};
}
export async function readSharedRecoveryCoverage(ctx:Context,shop:Shop,load:RecoveryPublicationLoader){
  const {graph,base}=await loadGraph(ctx,shop,load),prefix=shop.shop_id+'/';
  const needs=graph.report.needs.filter(n=>n.occurrenceId.startsWith(prefix)).map(n=>{
    const need=graph.needByKey.get(n.ingredientId)!;
    const allocations=n.allocations.map(a=>({...a,kind:graph.kinds.get(a.sourceId+'/'+n.ingredientId)!}));
    const from=(kind:Origin)=>n.required?wire(allocations.filter(a=>a.kind===kind).reduce((sum,a)=>add(sum,fraction(a.amount)),zero)):null;
    return {...n,needId:need.id,ingredientId:need.ingredientId,occurrenceId:n.occurrenceId.slice(prefix.length),allocations,
      delivered:from('delivery'),pantry:from('pantry'),freezer:from('freezer')};
  });
  return {shopId:shop.shop_id,placedRevision:shop.placed_revision!,...base,asOf:ctx.now.toISOString(),needs,
    unplannedOccurrenceIds:graph.report.unplannedOccurrenceIds.filter(id=>id.startsWith(prefix)).map(id=>id.slice(prefix.length))};
}

// Once any connected shop has an accepted replacement, previews and legacy
// command guards must use the very same effective requirements as recovery.
function effectivePantryProjection(load:RecoveryPublicationLoader):PantryProjectionLoader{
  return async(ctx,_shop,input)=>{
    const {meals,publications}=await effectiveMeals(ctx,input,load);
    if(![...publications.values()].some(p=>p.recoveryRevision>0)) return;
    const matches=new Map<string,Set<string>>();
    const needs=()=>{
      const graph=effectiveGraph(input,meals);
      return graph.report.needs.map(row=>{
        const n=graph.needByKey.get(row.ingredientId)!;
        const key=[row.occurrenceId,n.ingredientId,...row.groupIds].join('/');
        matches.set(key,new Set(n.matchedSourceIds));
        return {...row,ingredientId:n.ingredientId};
      });
    };
    return {needs,matches:(row,id)=>matches.get([row.occurrenceId,row.ingredientId,...row.groupIds].join('/'))?.has(id)??false};
  };
}
export function previewCurrentPantryObservation(ctx:Context,shop:Shop,input:unknown,load:RecoveryPublicationLoader){
  return previewPantryObservation(ctx,shop,input,effectivePantryProjection(load));
}

type DeliveryKind=Parameters<typeof recordDelivery>[2];
type PantryKind=Parameters<typeof recordPantry>[2];
async function effectiveEdit(ctx:Context,shop:Shop,kind:DeliveryKind|PantryKind,body:Record<string,unknown>,operationId:string,load:RecoveryPublicationLoader){
  if(!['pantry.select','pantry.match','pantry.reserve','delivery.match','delivery.reserve'].includes(kind)) return;
  const id=String(body.lotId??body.sourceId),before=await loadGraph(ctx,shop,load,id);
  if(!before.hasRecovery) return;
  const old=before.graph,scope=shop.shop_id+'/';
  const meal=before.local.find(m=>m.original.occurrenceId===body.occurrenceId);
  const retained=meal?.current?.needs.filter(n=>n.ingredientId===body.ingredientId && (!body.groupId || n.groupId===body.groupId) &&
    meal.original.needs.some(o=>o.id===n.id));
  if(body.occurrenceId && !retained?.length && body.matched!==false && body.quantity!==null)
    throw new ServiceError(409,'stale_supply','Review the current meal and its physical sources.');
  const reserve=kind==='pantry.reserve'||kind==='delivery.reserve';
  if(reserve && body.quantity){
    const request=kind==='delivery.reserve'?deliveryReservationBody.parse(body):{...pantryBodies['pantry.reserve'].parse(body),sourceId:id};
    const current=retained?.[0],source=old.sources.find(s=>s.sourceId===id);
    if(!current || !source) throw reviewReservation();
    const target={...request,occurrenceId:scope+request.occurrenceId,ingredientId:scope+current.id},quantity=request.quantity!;
    const head=source.reservations?.find(p=>p.occurrenceId===target.occurrenceId&&p.ingredientId===target.ingredientId&&p.groupId===request.groupId);
    if((head?.reservationId??null)!==request.predecessorId) throw reviewReservation();
    const reducing=head?.quantity && dimension(head.quantity)===dimension(quantity) && cmp(amount(quantity),amount(head.quantity))<0n;
    if(!reducing){
      const updated=(source.reservations??[]).filter(r=>r!==head);
      updated.push({...target,quantity,reservationId:operationId});
      validateReservation(old.projected,old.sources,source,target,updated);
    }
  }
  return async()=>{
    const after=(await loadGraph(ctx,shop,load,id)).graph.report.needs;
    const byNeed=new Map(after.map(n=>[n.ingredientId,n]));
    for(const n of old.report.needs){
      if(n.occurrenceId.startsWith(scope)) continue;
      const next=byNeed.get(n.ingredientId);
      if(!next || n.covered && next.covered && lower(next.covered,n.covered)) throw reviewReservation();
      for(const pin of n.reservations){
        const kept=next.reservations.find(p=>p.reservationId===pin.reservationId);
        if(!kept||lower(kept.backed,pin.backed))throw reviewReservation();
      }
    }
  };
}
export async function recordCurrentDelivery(ctx:Context,shop:Shop,kind:DeliveryKind,body:Record<string,unknown>,operationId:string,load:RecoveryPublicationLoader){
  const current=await effectiveEdit(ctx,shop,kind,body,operationId,load);
  if(current) return recordDelivery(ctx,shop,kind,body,operationId,current);
  const legacy=await guardDeliveryEdit(ctx,shop,kind,body);
  const receipt=await recordDelivery(ctx,shop,kind,body,operationId);
  await legacy?.();
  return receipt;
}
export async function recordCurrentPantry(ctx:Context,shop:Shop,kind:PantryKind,body:Record<string,unknown>,operationId:string,load:RecoveryPublicationLoader){
  const current=await effectiveEdit(ctx,shop,kind,body,operationId,load);
  return recordPantry(ctx,shop,kind,body,operationId,current,effectivePantryProjection(load));
}
