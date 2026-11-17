import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { digest } from './database.js';
import { storedDeliveryEvidence } from './delivery-evidence.js';
import { invalid, refresh, unavailable, ServiceError } from './errors.js';
import { householdPantryEpoch, pantryRevision } from './pantry-lots.js';
import { add, amount, cmp, dimension, type Rat } from './physical-quantity.js';
import type { Context } from './repository.js';
import type { Quantity } from './recovery-contracts.js';

const id=z.uuid().toLowerCase(),day=z.iso.date(),revision=z.number().int().nonnegative().max(2147483647);
const label=z.string().trim().min(1).max(120).refine(s=>!/[\u0000\uD800-\uDFFF]/u.test(s));
const action=z.discriminatedUnion('kind',[
  z.object({kind:z.literal('enable'),enabled:z.boolean()}).strict(),
  z.object({kind:z.literal('remember'),name:label}).strict(),
  z.object({kind:z.literal('purchase'),groupId:id.nullable(),name:label.nullable(),lotId:id,observationId:id,purchaseDay:day}).strict(),
  z.object({kind:z.literal('answer'),groupId:id,basis:z.string().regex(/^[a-f0-9]{64}$/),choice:z.enum(['stillHave','dismiss','snooze'])}).strict(),
  z.object({kind:z.literal('removePurchase'),groupId:id,lotId:id}).strict(),
  z.object({kind:z.literal('forget'),groupId:id}).strict()
]);
const command=z.object({v:z.literal(1),zone:z.string().min(1).max(80),grantEpoch:revision,pantryRevision:revision,expectedRevision:id.nullable(),
  clientKey:id,replayWindow:id,action}).strict();
const dayNumber=(s:string)=>Date.parse(s+'T00:00:00Z')/86400000;
const civilDay=(day:number)=>new Date(day*86400000).toISOString().slice(0,10);
const normalize=(s:string)=>s.normalize('NFKD').toLowerCase().replace(/\p{M}/gu,'').replace(/[^\p{L}\p{N}]+/gu,' ').trim();
const scope=(ctx:Context)=>[ctx.householdId,ctx.member.member_id];
function epoch(ctx:Context){const e=householdPantryEpoch(ctx);if(e===null)throw unavailable();return e;}
interface Settings {enabled:boolean;revision:string;grant_epoch:number}
interface Group {group_id:string;name:string;answer:string|null;answer_basis:string|null;until_day:string|null}
interface Purchase {group_id:string;lot_id:string;shop_id:string;arrival_id:string;usable_id:string;purchase_day:string}
type Delivery=Awaited<ReturnType<typeof storedDeliveryEvidence>>[number];
function reviewedFood(fact:Delivery|undefined,row:Purchase):Quantity|undefined {
  if(!fact?.confirmed || !fact.arrival || !fact.usable || row.arrival_id!==fact.arrival.observationId ||
     row.usable_id!==fact.usable.observationId || fact.confirmed.quantity.amount.numerator<=0)return;
  return fact.confirmed.quantity;
}

export function comparablePurchaseInterval(purchases:{day:string;quantity:Quantity|undefined}[]) {
  const days=new Map<string,{dimension:string;total:Rat}>();
  for(const {day,quantity} of purchases){
    if(!quantity)return null;
    const measure=dimension(quantity),current=days.get(day);
    if(current && current.dimension!==measure)return null;
    days.set(day,{dimension:measure,total:current?add(current.total,amount(quantity)):amount(quantity)});
  }
  const ordered=[...days.entries()].sort(([a],[b])=>b.localeCompare(a)),latest=ordered[0];
  if(!latest)return null;
  const comparable:number[]=[];
  for(const [day,value] of ordered){
    if(value.dimension!==latest[1].dimension || cmp(value.total,latest[1].total)!==0n)break;
    comparable.push(dayNumber(day));
  }
  if(comparable.length<3)return null;
  const gaps=comparable.slice(1).map((d,i)=>comparable[i]!-d).sort((a,b)=>a-b);
  const daysBetween=Math.ceil((gaps[Math.floor((gaps.length-1)/2)]!+gaps[Math.floor(gaps.length/2)]!)/2);
  return {purchaseDays:comparable.length,intervalDays:daysBetween,dueDay:civilDay(comparable[0]!+daysBetween)};
}
async function settings(ctx:Context){
  return (await ctx.db.query<Settings>('SELECT enabled,revision,grant_epoch FROM ritc.staple_settings WHERE household_id=$1 AND member_id=$2',scope(ctx))).rows[0];
}

function localDay(time:Date,zone:string):string {
  if(!zone || zone.length>80)throw invalid();
  try{return new Intl.DateTimeFormat('en-CA',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit'}).format(time);}
  catch{throw invalid();}
}
export async function householdStaples(ctx:Context,zone:string) {
  const grantEpoch=epoch(ctx),s=await settings(ctx),stock=await pantryRevision(ctx),today=localDay(ctx.now,zone);
  const state={v:1,today,zone,householdId:ctx.householdId,memberId:ctx.member.member_id,grantEpoch,pantryRevision:stock,
    enabled:s?.grant_epoch===grantEpoch && s.enabled,revision:s?.grant_epoch===grantEpoch?s.revision:null};
  if(!state.enabled)return {...state,groups:[]};
  const groups=(await ctx.db.query<Group>(`SELECT group_id,name,answer,answer_basis,until_day::text FROM ritc.staple_group
    WHERE household_id=$1 AND member_id=$2 ORDER BY name,group_id`,scope(ctx))).rows;
  const purchases=(await ctx.db.query<Purchase>(`SELECT group_id,lot_id,shop_id,arrival_id,usable_id,purchase_day::text FROM ritc.staple_purchase
    WHERE household_id=$1 AND member_id=$2 ORDER BY purchase_day,lot_id`,scope(ctx))).rows;
  const facts=new Map((await storedDeliveryEvidence(ctx,purchases.map(p=>p.lot_id),null,true)).map(x=>[x.sourceId,x]));
  // Names are used only to suppress a question. They never create a purchase link.
  // Nothing about the originating request, shop, member or financial records leaves this endpoint.
  const open=(await ctx.db.query<{name:string}>(`SELECT DISTINCT name FROM (
    SELECT original_item AS name FROM ritc.request WHERE household_id=$1 AND status IN ('pending','clarified','deferred')
    UNION ALL SELECT b.original_item FROM ritc.basket_line b JOIN ritc.shop s USING(household_id,shop_id)
    WHERE b.household_id=$1 AND s.phase IN ('draft','frozen')) demand LIMIT 2001`,[ctx.householdId])).rows;
  const aliases=new Map<string,Set<string>>();
  for(const group of groups){
    for(const name of [group.name,...purchases.filter(p=>p.group_id===group.group_id).map(p=>facts.get(p.lot_id)?.foodName??'')]){
      const alias=normalize(name);
      if(alias){const ids=aliases.get(alias)??new Set<string>();ids.add(group.group_id);aliases.set(alias,ids);}
    }
  }
  return {...state,groups:groups.map(group=>{
    const rows=purchases.filter(p=>p.group_id===group.group_id);
    const candidate=comparablePurchaseInterval(rows.map(p=>({day:p.purchase_day,quantity:reviewedFood(facts.get(p.lot_id),p)})));
    const basis=digest(rows.map(p=>[p.lot_id,p.arrival_id,p.usable_id,p.purchase_day]));
    const answered=group.answer_basis===basis && (group.answer!=='snooze' || (group.until_day??'')>today);
    const openDemand=open.length>2000 || open.some(r=>{const ids=aliases.get(normalize(r.name));return !ids || ids.has(group.group_id);});
    const prompt=candidate && !answered && !openDemand && candidate.dueDay<=today?{...candidate,basis}:null;
    return {id:group.group_id,name:group.name,purchases:rows.map(p=>({lotId:p.lot_id,day:p.purchase_day,foodName:facts.get(p.lot_id)?.foodName??null})),prompt};
  })};
}

export async function changeHouseholdStaples(ctx:Context,input:unknown) {
  const currentEpoch=epoch(ctx),c=command.parse(input),owner=scope(ctx);
  if(c.grantEpoch!==currentEpoch)throw refresh();
  const active=await ctx.db.query(`SELECT 1 FROM ritc.replay_window WHERE household_id=$1 AND window_id=$2 AND member_id=$3 AND
    device_id=$4 AND revoked_at IS NULL AND expires_at>$5`,[ctx.householdId,c.replayWindow,ctx.member.member_id,ctx.deviceId,ctx.now]);
  if(!active.rowCount)throw refresh();
  const fingerprint=digest({scope:'household_staples',household:ctx.householdId,command:c}),s=await settings(ctx);
  const prior=(await ctx.db.query(`SELECT operation_id,authority_scope,pantry_grant_epoch,device_id,payload_digest,kind FROM ritc.operation
    WHERE household_id=$1 AND actor_id=$2 AND client_key=$3`,[...owner,c.clientKey])).rows[0];
  if(prior){
    if(prior.device_id!==ctx.deviceId || (prior.authority_scope==='household_pantry' && prior.pantry_grant_epoch!==currentEpoch))throw refresh();
    if(prior.kind!=='pantry.staples' || prior.payload_digest!==fingerprint)throw new ServiceError(409,'key_reused','Review the changed request.');
    // A retry acknowledges the stored operation by returning the live projection, including
    // any later changes from another enrolled device. It never restores an old answer.
    if(!s || s.grant_epoch!==currentEpoch)throw refresh();
    return householdStaples(ctx,c.zone);
  }
  if((s?.revision??null)!==c.expectedRevision || c.pantryRevision!==await pantryRevision(ctx))throw refresh();
  const a=c.action,operation=randomUUID();
  if(a.kind==='enable'){
    if(a.enabled===(s?.enabled??false))throw refresh();
    if(!a.enabled)await ctx.db.query('DELETE FROM ritc.staple_group WHERE household_id=$1 AND member_id=$2',owner);
    await ctx.db.query(`INSERT INTO ritc.staple_settings(household_id,member_id,grant_epoch,revision,enabled) VALUES($1,$2,$3,$4,$5)
      ON CONFLICT(household_id,member_id) DO UPDATE SET revision=excluded.revision,enabled=excluded.enabled,grant_epoch=excluded.grant_epoch`,
      [...owner,currentEpoch,operation,a.enabled]);
  }else{
    if(!s?.enabled || s.grant_epoch!==currentEpoch)throw unavailable();
    const groups=(await ctx.db.query<Group>('SELECT group_id,name FROM ritc.staple_group WHERE household_id=$1 AND member_id=$2',owner)).rows;
    if('groupId' in a && a.groupId && !groups.some(g=>g.group_id===a.groupId))throw unavailable();
    async function createGroup(name:string){
      if(groups.length>=32 || !normalize(name) || groups.some(g=>normalize(g.name)===normalize(name)))throw invalid();
      const group=randomUUID();
      await ctx.db.query('INSERT INTO ritc.staple_group(household_id,member_id,group_id,name) VALUES($1,$2,$3,$4)',[...owner,group,name]);
      return group;
    }
    if(a.kind==='remember'){
      await createGroup(a.name);
    }else if(a.kind==='purchase'){
      if((a.groupId===null)!==(a.name!==null) || a.purchaseDay>localDay(ctx.now,c.zone))throw invalid();
      const lot=(await ctx.db.query('SELECT origin_shop_id FROM ritc.pantry_lot WHERE household_id=$1 AND lot_id=$2 AND delivery_source_id=lot_id',[ctx.householdId,a.lotId])).rows[0];
      if(!lot)throw unavailable();
      const [d]=await storedDeliveryEvidence(ctx,[a.lotId],lot.origin_shop_id,true);
      if(!d?.confirmed || !d.usable || !d.arrival?.arrivedAt || a.observationId!==d.usable.observationId ||
         d.confirmed.quantity.amount.numerator<=0 || a.purchaseDay>localDay(new Date(d.arrival.arrivedAt),c.zone))throw refresh();
      const existing=(await ctx.db.query<Purchase>('SELECT group_id,shop_id,lot_id,purchase_day::text FROM ritc.staple_purchase WHERE household_id=$1 AND member_id=$2',owner)).rows;
      if(existing.some(p=>p.lot_id===a.lotId && p.group_id!==a.groupId) ||
          existing.some(p=>p.lot_id!==a.lotId && p.shop_id===lot.origin_shop_id && p.purchase_day!==a.purchaseDay))throw refresh();
      const group=a.groupId??await createGroup(a.name!);
      if(!existing.some(x=>x.lot_id===a.lotId) && existing.filter(x=>x.group_id===group).length>=64)throw invalid();
      await ctx.db.query(`INSERT INTO ritc.staple_purchase(household_id,member_id,group_id,lot_id,shop_id,arrival_id,usable_id,purchase_day)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(household_id,member_id,lot_id) DO UPDATE SET
        arrival_id=excluded.arrival_id,usable_id=excluded.usable_id,purchase_day=excluded.purchase_day`,
        [...owner,group,a.lotId,lot.origin_shop_id,d.arrival.observationId,d.usable.observationId,a.purchaseDay]);
    }else if(a.kind==='removePurchase'){
      const removed=await ctx.db.query('DELETE FROM ritc.staple_purchase WHERE household_id=$1 AND member_id=$2 AND group_id=$3 AND lot_id=$4',
        [...owner,a.groupId,a.lotId]);
      if(!removed.rowCount)throw refresh();
    }else if(a.kind==='forget'){
      await ctx.db.query('DELETE FROM ritc.staple_group WHERE household_id=$1 AND member_id=$2 AND group_id=$3',[...owner,a.groupId]);
    }else{
      const prompt=(await householdStaples(ctx,c.zone)).groups.find(g=>g.id===a.groupId)?.prompt;
      if(prompt?.basis!==a.basis)throw refresh();
      const until=a.choice==='snooze'?civilDay(dayNumber(localDay(ctx.now,c.zone))+7):null;
      await ctx.db.query('UPDATE ritc.staple_group SET answer=$4,answer_basis=$5,until_day=$6 WHERE household_id=$1 AND member_id=$2 AND group_id=$3',
        [...owner,a.groupId,a.choice,a.basis,until]);
    }
    await ctx.db.query('UPDATE ritc.staple_settings SET revision=$3 WHERE household_id=$1 AND member_id=$2',[...owner,operation]);
  }
  await ctx.db.query(`INSERT INTO ritc.operation(household_id,operation_id,actor_id,device_id,client_key,window_id,kind,
    shop_id,payload_digest,response_scope,authority_scope,pantry_grant_epoch)
    VALUES($1,$2,$3,$4,$5,$6,'pantry.staples',NULL,$7,'pantry','household_pantry',$8)`,
    [ctx.householdId,operation,ctx.member.member_id,ctx.deviceId,c.clientKey,c.replayWindow,fingerprint,currentEpoch]);
  return householdStaples(ctx,c.zone);
}
