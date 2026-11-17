import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import {cookBodies,type CookKind} from './cook-completion-contracts.js';
import {counted} from './cook-quantities.js';
import {requireCompatibleMatch} from './delivery-evidence.js';
import {invalid,refresh,unavailable,ServiceError} from './errors.js';
import {householdPantryEpoch} from './pantry-lots.js';
import {add,amount,cmp,dimension,min,sub,zero,type Rat} from './physical-quantity.js';
import type {Quantity} from './recovery-contracts.js';
import type {Context,Shop} from './repository.js';
import {loadGraph} from './shared-recovery-basis.js';
import {loadRecoveryPublication} from './shared-recovery-publication.js';

const stale=()=>new ServiceError(409,'stale_supply','Review the current meal, stock and reservations.');
const short=()=>new ServiceError(409,'reservation_review_required','Review the physical count and promised portions.');
type Complete=z.infer<typeof cookBodies['cook.complete']>;
type Resolve=z.infer<typeof cookBodies['cook.resolve']>;

async function current(ctx:Context,shop:Shop,occurrenceId:string){
  const grantEpoch=householdPantryEpoch(ctx);
  if(grantEpoch===null || shop.shopper_id!==ctx.member.member_id) throw unavailable();
  const state=await loadGraph(ctx,shop,loadRecoveryPublication);
  const meal=state.local.find(m=>m.recipe?.occurrenceId===occurrenceId)?.recipe;
  if(!meal) throw unavailable();
  const base={...state.base,grantEpoch,occurrenceId,mealRevision:meal.sourceMealRevision,recipeRevisionId:meal.revisionId};
  const active=(await ctx.db.query<{operation_id:string;servings:number;recipe_revision_id:string;meal_revision:number}>(`SELECT operation_id,servings,recipe_revision_id,meal_revision FROM ritc.shared_cook
    WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 AND undone_by IS NULL`,[ctx.householdId,shop.shop_id,occurrenceId])).rows[0];
  const lots=state.options.flatMap(option=>{
    const lot=state.stock.rows.find(r=>r.lot_id===option.sourceId);
    if(!lot) return [];
    const history=state.stock.deliverySources.find(s=>s.physical.sourceId===lot.lot_id)?.physical;
    const manual=state.stock.heads.find(h=>h.lot_id===lot.lot_id && h.kind==='observe');
    const headId=history?(history.balance?.observationId??history.usable?.observationId):manual?.operation_id;
    if(!headId) return [];
    return [{lotId:lot.lot_id,name:option.name,quantity:option.quantity,headId,usableId:history?.usable?.observationId??null}];
  });
  return {base,meal,lots,state,active};
}
type Review=Awaited<ReturnType<typeof current>>;
type Lot=Review['lots'][number];
export async function cookReview(ctx:Context,shop:Shop,id:string){
  const r=await current(ctx,shop,id);
  const unresolved=r.active?(await ctx.db.query(`SELECT u.row_id AS "rowId",u.need_id AS "needId",u.lot_id AS "lotId"
    FROM ritc.cook_use u LEFT JOIN ritc.cook_resolution x ON (x.household_id,x.row_id)=(u.household_id,u.row_id)
    WHERE u.household_id=$1 AND u.cook_id=$2 AND u.kind='unknown' AND x.row_id IS NULL ORDER BY u.row_id`,
    [ctx.householdId,r.active.operation_id])).rows:[];
  return {v:1,base:r.base,title:r.meal.title,plannedPortions:r.meal.portions,
    needs:r.meal.needs.map(n=>({id:n.id,name:n.name,quantity:n.quantity,
      lots:r.lots.filter(l=>n.matchedSourceIds?.includes(l.lotId)).map(({usableId,...l})=>l)})),
    completion:r.active?{cookId:r.active.operation_id,servings:r.active.servings,unresolved}:null};
}

function reviewedLot(r:Review,needId:string,lotId:string,headId:string){
  const n=r.meal.needs.find(n=>n.id===needId),lot=r.lots.find(l=>l.lotId===lotId);
  if(!n || !lot || !n.matchedSourceIds?.includes(lotId)) throw unavailable();
  if(lot.headId!==headId) throw stale();
  requireCompatibleMatch(n,r.state.stock.sources.find(s=>s.sourceId===lotId)!);
  return lot;
}
function exactAmount(value:{numerator:string;denominator:string},unit:Quantity['unit']):Rat{
  const scale=amount({amount:{numerator:1,denominator:1},unit,originalLiteral:'1'});
  return {n:BigInt(value.numerator)*scale.n,d:BigInt(value.denominator)*scale.d};
}
function protectedRemainder(r:Review,shop:Shop,lot:Lot,fulfilled:Map<string,Quantity>):Rat{
  let held=zero;
  const scope=shop.shop_id+'/'+r.meal.occurrenceId;
  for(const need of r.state.graph.report.needs){
    const pin=need.reservations.find(p=>p.sourceId===lot.lotId);
    const allocation=need.allocations.find(a=>a.sourceId===lot.lotId);
    if(!need.required){
      const source=r.state.graph.sources.find(s=>s.sourceId===lot.lotId);
      if(need.protected && need.occurrenceId!==scope && source?.matches.some(m=>m.ingredientId===need.ingredientId)) throw short();
      continue;
    }
    let promised=pin?exactAmount(pin.requested,need.required.unit):zero;
    if(pin && fulfilled.has(pin.reservationId)) promised=sub(promised,amount(fulfilled.get(pin.reservationId)!));
    if(allocation && need.occurrenceId!==scope && (need.protected || !need.occurrenceId.startsWith(shop.shop_id+'/'))){
      const fixed=pin?exactAmount(pin.backed,need.required.unit):zero;
      promised=add(promised,sub(exactAmount(allocation.amount,need.required.unit),fixed));
    }
    if(promised.n>0n && (!lot.quantity || dimension(lot.quantity)!==dimension(need.required))) throw short();
    held=add(held,promised);
  }
  return held;
}
async function writeCount(ctx:Context,shop:Shop,cookId:string,operationId:string,revision:number,
  lotId:string,before:Quantity|null,after:Quantity|null,usableId:string|null,isOutput=false){
  const eventId=randomUUID();
  await ctx.db.query(`INSERT INTO ritc.pantry_event(household_id,shop_id,operation_id,lot_id,event_id,actor_id,kind,pantry_revision,confirmed_at,quantity,delivery_usable_id)
    VALUES($1,$2,$3,$4,$5,$6,'observe',$7,$8,$9,$10)`,[ctx.householdId,shop.shop_id,operationId,lotId,eventId,ctx.member.member_id,revision,ctx.now,after,usableId]);
  await ctx.db.query(`INSERT INTO ritc.cook_stock_change(household_id,cook_id,operation_id,lot_id,event_id,before_quantity,is_output)
    VALUES($1,$2,$3,$4,$5,$6,$7)`,[ctx.householdId,cookId,operationId,lotId,eventId,before,isOutput]);
}
async function complete(ctx:Context,shop:Shop,r:Review,body:Complete,operationId:string,next:number){
  if(r.active) throw stale();
  const {uses,outputs}=body,needIds=new Set(uses.map(u=>u.needId));
  if(needIds.size!==r.meal.needs.length || r.meal.needs.some(n=>!needIds.has(n.id)) ||
     new Set(uses.map(u=>u.rowId)).size!==uses.length || new Set(outputs.map(o=>o.lotId)).size!==outputs.length) throw invalid();
  const changes=new Map<string,{lot:Lot;known:Rat;unknown:boolean}>(),fulfilled=new Map<string,Quantity>();
  const pairs=new Set<string>();
  for(const use of uses){
    const pair=use.needId+'/'+('lotId' in use?use.lotId:'none');
    if(pairs.has(pair) || use.kind==='notUsed' && uses.some(u=>u!==use && u.needId===use.needId)) throw invalid();
    pairs.add(pair);
    if(use.kind==='notUsed' || !use.lotId || !use.headId) continue;
    const lot=reviewedLot(r,use.needId,use.lotId,use.headId);
    const change=changes.get(lot.lotId)??{lot,known:zero,unknown:false};changes.set(lot.lotId,change);
    if(use.kind==='unknown'){change.unknown=true;continue;}
    if(!lot.quantity || dimension(lot.quantity)!==dimension(use.quantity)) throw short();
    change.known=add(change.known,amount(use.quantity));
    const pin=r.state.graph.pins.find(p=>p.shopId===shop.shop_id && p.needId===use.needId && p.sourceId===lot.lotId);
    if(pin && dimension(pin.quantity)===dimension(use.quantity))
      fulfilled.set(pin.id,counted(min(amount(pin.quantity),amount(use.quantity)),pin.quantity.unit));
  }
  const updates=[...changes.values()].map(({lot,known,unknown})=>{
    const before=lot.quantity;
    if(known.n && (!before || cmp(sub(amount(before),known),protectedRemainder(r,shop,lot,fulfilled))<0n)) throw short();
    return {lot,after:unknown || !before?null:counted(sub(amount(before),known),before.unit)};
  });
  await ctx.db.query(`INSERT INTO ritc.shared_cook(household_id,shop_id,operation_id,occurrence_id,meal_revision,recipe_revision_id,actor_id,servings)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[ctx.householdId,shop.shop_id,operationId,body.occurrenceId,body.mealRevision,body.recipeRevisionId,ctx.member.member_id,body.servings]);
  for(const use of uses) await ctx.db.query(`INSERT INTO ritc.cook_use(household_id,cook_id,row_id,need_id,kind,lot_id,quantity)
    VALUES($1,$2,$3,$4,$5,$6,$7)`,[ctx.householdId,operationId,use.rowId,use.needId,use.kind,'lotId' in use?use.lotId:null,'quantity' in use?use.quantity:null]);
  for(const [id,q] of fulfilled) await ctx.db.query('INSERT INTO ritc.cook_fulfillment VALUES($1,$2,$3,$4,$2)',[ctx.householdId,operationId,id,q]);
  for(const {lot,after} of updates) await writeCount(ctx,shop,operationId,operationId,next,lot.lotId,lot.quantity,after,lot.usableId);
  for(const out of outputs){
    const exists=await ctx.db.query('SELECT 1 FROM ritc.pantry_lot WHERE household_id=$1 AND lot_id=$2 UNION ALL SELECT 1 FROM ritc.delivery_source WHERE household_id=$1 AND source_id=$2',[ctx.householdId,out.lotId]);
    if(exists.rowCount) throw stale();
    await ctx.db.query(`INSERT INTO ritc.pantry_lot(household_id,lot_id,origin_shop_id,location,stored_at,food_name,exclusion_tags,actor_id,operation_id,cook_output)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,true)`,[ctx.householdId,out.lotId,shop.shop_id,out.location,ctx.now,out.name,
        [...new Set(r.state.stock.sources.filter(s=>changes.has(s.sourceId)).flatMap(s=>s.exclusionTags))],ctx.member.member_id,operationId]);
    await writeCount(ctx,shop,operationId,operationId,next,out.lotId,null,counted({n:BigInt(out.portions),d:1n},'count'),null,true);
  }
  return operationId;
}
async function resolve(ctx:Context,shop:Shop,r:Review,body:Resolve,operationId:string,next:number){
  if(r.active?.operation_id!==body.cookId) throw stale();
  const row=(await ctx.db.query(`SELECT u.need_id,u.lot_id,b.pantry_revision FROM ritc.cook_use u JOIN ritc.pantry_batch b
    ON (b.household_id,b.operation_id)=(u.household_id,u.cook_id) LEFT JOIN ritc.cook_resolution x ON (x.household_id,x.row_id)=(u.household_id,u.row_id)
    WHERE u.household_id=$1 AND u.cook_id=$2 AND u.row_id=$3 AND u.kind='unknown' AND x.row_id IS NULL`,[ctx.householdId,body.cookId,body.rowId])).rows[0];
  if(!row || row.lot_id && row.lot_id!==body.lotId) throw stale();
  const lot=reviewedLot(r,row.need_id,body.lotId,body.headId);
  const count=(await ctx.db.query(`SELECT e.operation_id,e.pantry_revision,c.before_quantity,o.kind FROM ritc.pantry_event e
    JOIN ritc.operation o USING(household_id,operation_id) LEFT JOIN ritc.cook_stock_change c USING(household_id,event_id)
    WHERE e.household_id=$1 AND e.event_id=$2`,[ctx.householdId,body.headId])).rows[0];
  const delivered=!count && lot.usableId ? (await ctx.db.query('SELECT household_revision FROM ritc.delivery_observation WHERE household_id=$1 AND source_id=$2 AND observation_id=$3',
    [ctx.householdId,lot.lotId,lot.usableId])).rows[0] : null;
  const laterCount=Boolean(count && count.pantry_revision>row.pantry_revision && !count.kind.startsWith('cook.') || delivered && delivered.household_revision>row.pantry_revision);
  const fulfilled=new Map<string,Quantity>();
  const pin=r.state.graph.pins.find(p=>p.shopId===shop.shop_id && p.needId===row.need_id && p.sourceId===lot.lotId);
  if(pin && dimension(pin.quantity)===dimension(body.quantity)) fulfilled.set(pin.id,counted(min(amount(body.quantity),amount(pin.quantity)),pin.quantity.unit));
  if(body.includedInCount){
    if(!laterCount || !lot.quantity || dimension(lot.quantity)!==dimension(body.quantity)) throw stale();
  } else {
    if(laterCount || count && count.pantry_revision>row.pantry_revision) throw stale();
    const before:Quantity|null=count?.operation_id===body.cookId?count.before_quantity:lot.quantity;
    // Several unknown splits on one physical source require a later actual recount.
    const siblings=await ctx.db.query("SELECT 1 FROM ritc.cook_use WHERE household_id=$1 AND cook_id=$2 AND lot_id=$3 AND row_id<>$4 AND kind='unknown'",
      [ctx.householdId,body.cookId,body.lotId,body.rowId]);
    if(siblings.rowCount || !before || dimension(before)!==dimension(body.quantity)) throw short();
    const known=await ctx.db.query("SELECT quantity FROM ritc.cook_use WHERE household_id=$1 AND cook_id=$2 AND lot_id=$3 AND kind='known'",[ctx.householdId,body.cookId,body.lotId]);
    const start=count?.operation_id===body.cookId?known.rows.reduce((total,r)=>sub(total,amount(r.quantity)),amount(before)):amount(before);
    const left=sub(start,amount(body.quantity));
    if(cmp(left,protectedRemainder(r,shop,{...lot,quantity:before},fulfilled))<0n) throw short();
    await writeCount(ctx,shop,body.cookId,operationId,next,body.lotId,lot.quantity,counted(left,before.unit),lot.usableId);
  }
  for(const [id,q] of fulfilled) await ctx.db.query('INSERT INTO ritc.cook_fulfillment VALUES($1,$2,$3,$4,$5)',[ctx.householdId,body.cookId,id,q,operationId]);
  await ctx.db.query('INSERT INTO ritc.cook_resolution VALUES($1,$2,$3,$4,$5,$6)',[ctx.householdId,body.rowId,operationId,body.lotId,body.quantity,body.includedInCount]);
  return body.cookId;
}
async function undo(ctx:Context,shop:Shop,r:Review,cookId:string,op:string,next:number){
  if(r.active?.operation_id!==cookId) throw stale();
  const recount=await ctx.db.query(`SELECT 1 FROM ritc.cook_resolution x JOIN ritc.cook_use u USING(household_id,row_id)
    WHERE u.household_id=$1 AND u.cook_id=$2 AND x.included_in_count`,[ctx.householdId,cookId]);
  if(recount.rowCount) throw stale();
  const {rows}=await ctx.db.query(`SELECT c.*,e.pantry_revision,e.delivery_usable_id,e.quantity FROM ritc.cook_stock_change c
    JOIN ritc.pantry_event e USING(household_id,event_id) WHERE c.household_id=$1 AND c.cook_id=$2 ORDER BY e.pantry_revision`,[ctx.householdId,cookId]);
  const lots=new Set<string>(rows.map(s=>s.lot_id));
  for(const lot of lots){
    const changes=rows.filter(s=>s.lot_id===lot),first=changes[0]!,last=changes.at(-1)!;
    const downstream=await ctx.db.query(`SELECT 1 FROM ritc.pantry_event e WHERE e.household_id=$1 AND e.lot_id=$2
      AND e.pantry_revision>$3 AND NOT EXISTS(SELECT 1 FROM ritc.cook_stock_change c WHERE (c.household_id,c.event_id)=(e.household_id,e.event_id) AND c.cook_id=$4)
      UNION ALL SELECT 1 FROM ritc.cook_use u JOIN ritc.pantry_batch b ON (b.household_id,b.operation_id)=(u.household_id,u.cook_id)
      WHERE u.household_id=$1 AND u.lot_id=$2 AND b.pantry_revision>$3 AND u.cook_id<>$4 LIMIT 1`,
      [ctx.householdId,lot,first.pantry_revision,cookId]);
    if(downstream.rowCount || last.delivery_usable_id && r.lots.find(l=>l.lotId===lot)?.headId!==last.event_id) throw stale();
    if(last.delivery_usable_id){
      const edits=await ctx.db.query(`SELECT 1 FROM ritc.delivery_reservation WHERE household_id=$1 AND source_id=$2 AND household_revision>$3
        UNION ALL SELECT 1 FROM ritc.delivery_ingredient_review WHERE household_id=$1 AND source_id=$2 AND household_revision>$3
        UNION ALL SELECT 1 FROM ritc.delivery_observation WHERE household_id=$1 AND source_id=$2 AND household_revision>$3 LIMIT 1`,
        [ctx.householdId,lot,first.pantry_revision]);
      if(edits.rowCount) throw stale();
    }
    await writeCount(ctx,shop,cookId,op,next,lot,last.quantity,first.is_output?counted(zero,'count'):first.before_quantity,last.delivery_usable_id,first.is_output);
  }
  await ctx.db.query('UPDATE ritc.shared_cook SET undone_by=$3 WHERE household_id=$1 AND operation_id=$2',[ctx.householdId,cookId,op]);
  return cookId;
}
export async function recordCook(ctx:Context,shop:Shop,kind:CookKind,input:unknown,op:string){
  const body=cookBodies[kind].parse(input);
  const r=await current(ctx,shop,body.occurrenceId);
  if(body.grantEpoch!==r.base.grantEpoch) throw refresh();
  for(const key of ['pantryRevision','supplyRevision','contextRevision','recoveryRevision','mealRevision','recipeRevisionId'] as const)
    if(body[key]!==r.base[key]) throw stale();
  if(r.active && (r.active.recipe_revision_id!==body.recipeRevisionId || r.active.meal_revision!==body.mealRevision)) throw stale();
  const next=body.pantryRevision+1;
  await ctx.db.query('INSERT INTO ritc.pantry_batch(household_id,operation_id,pantry_revision) VALUES($1,$2,$3)',[ctx.householdId,op,next]);
  const cookId='uses' in body?await complete(ctx,shop,r,body,op,next):'rowId' in body?await resolve(ctx,shop,r,cookBodies['cook.resolve'].parse(body),op,next):await undo(ctx,shop,r,body.cookId,op,next);
  await ctx.db.query('UPDATE ritc.household SET pantry_revision=$2 WHERE household_id=$1',[ctx.householdId,next]);
  return {cookId,pantryRevision:next,grantEpoch:r.base.grantEpoch};
}
export async function cookReceiptExists(ctx:Context,shop:Shop,receipt:{cookId:string;authorityEpoch:number}|null){
  if(!receipt || householdPantryEpoch(ctx)===null || receipt.authorityEpoch!==shop.authority_epoch) return false;
  return Boolean((await ctx.db.query('SELECT 1 FROM ritc.shared_cook WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',[ctx.householdId,shop.shop_id,receipt.cookId])).rowCount);
}
