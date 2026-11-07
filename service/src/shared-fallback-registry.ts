import { z } from 'zod';
import type { BillingService } from './billing/service.js';
import { digest } from './database.js';
import { ServiceError, unavailable } from './errors.js';
import type { Context, HouseholdRepository, Shop } from './repository.js';
import { mealAmount, mealQuantity, sharedMealSchema } from './shared-meal-planning.js';
import { sharedIdeaDraftSchema } from './shared-meal-ideas.js';
import { readRecoveryDesk } from './shared-recovery-publication.js';
import { add, amount, cmp, dimension, zero } from './physical-quantity.js';
import { reviewedID } from './shared-recovery-basis.js';

const id=z.string().uuid().transform(v=>v.toLowerCase());
const rev=z.number().int().positive().max(2147483647), seq=rev.or(z.literal(0));
const text=z.string().trim().min(1).max(240), tags=z.array(text).max(60);
const minutes=z.number().int().min(0).max(1000000).nullable();
const notes=z.string().refine(v=>Buffer.byteLength(v)<=8192);
const group=z.object({id,name:text,servings:mealAmount,protected:z.boolean(),exclusions:tags}).strict();
const binding=z.object({groupId:id,quantity:mealQuantity}).strict();
const ingredient=z.object({id,name:text,notes:notes.default(''),quantity:mealQuantity.nullable(),exclusions:tags,
  groupIds:z.array(id).max(30).optional(),bindings:z.array(binding).max(30).optional()}).strict();
export const fallbackRecipe=z.object({
  title:text,portions:z.number().int().min(1).max(1000),notes,sourceURL:z.string().refine(v=>Buffer.byteLength(v)<=2048).nullable(),
  exclusions:tags,requiredLeadMinutes:minutes,elapsedMinutes:minutes,groups:z.array(group).max(30).optional(),
  ingredients:z.array(ingredient).min(1).max(260),
}).strict().superRefine((r,ctx)=>{
  const fail=(message:string)=>ctx.addIssue({code:'custom',message});
  const wire=JSON.stringify(r);
  if(Buffer.byteLength(wire)>524288)fail('Review one recipe within the shared recipe size limit.');
  function validString(value:unknown):boolean {
    if(typeof value==='string')return !/[\u0000\uD800-\uDFFF]/u.test(value);
    if(value && typeof value==='object')return Object.values(value).every(validString);
    return true;
  }
  if(!validString(r))fail('Recipe text contains unsupported characters.');
  const groups=r.groups??[],ids=new Set(groups.map(g=>g.id));
  const assigned=groups.reduce((sum,g)=>add(sum,{n:BigInt(g.servings.numerator),d:BigInt(g.servings.denominator)}),zero);
  if(cmp(assigned,{n:BigInt(r.portions),d:1n})>0n)fail('Named portions cannot exceed the reviewed total servings.');
  if(ids.size!==groups.length || new Set(r.ingredients.map(i=>i.id)).size!==r.ingredients.length)fail('Use unique group and ingredient identities.');
  for(const i of r.ingredients){
    const targets=i.groupIds??[],parts=i.bindings??[];
    if(new Set(targets).size!==targets.length || targets.some(id=>!ids.has(id)) ||
      new Set(parts.map(b=>b.groupId)).size!==parts.length || parts.some(b=>!targets.includes(b.groupId)))fail('Bind only reviewed named portions.');
    if(!parts.length)continue;
    if(!i.quantity || parts.some(b=>dimension(b.quantity)!==dimension(i.quantity!))){fail('Review the total quantity and compatible units.');continue;}
    const diff=cmp(parts.reduce((sum,b)=>add(sum,amount(b.quantity)),zero),amount(i.quantity));
    if(diff>0n || (parts.length===targets.length && diff!==0n))fail('Keep exact named portions within the ingredient total.');
  }
});
type Recipe=z.infer<typeof fallbackRecipe>;
export interface AcceptedFallback { candidateId:string; revision:number; recipe:Recipe; usual:boolean }
const sourceRef=z.discriminatedUnion('kind',[
  z.object({kind:z.literal('meal'),occurrenceId:id,mealRevision:rev,revisionId:id.nullable()}).strict(),
  z.object({kind:z.literal('idea'),ideaId:id,revision:rev}).strict(),
]);
type Source=z.infer<typeof sourceRef>;
const reviewSource=z.object({source:sourceRef}).strict();
const common={v:z.literal(1),clientKey:id,shopRevision:rev,authorityEpoch:rev,registryRevision:seq,candidateId:id,baseRevision:rev.nullable(),reviewed:z.literal(true)};
const write=z.discriminatedUnion('action',[
  z.object({...common,action:z.literal('accept'),source:z.union([sourceRef,z.object({kind:z.literal('disclosed')}).strict()]),recipe:fallbackRecipe,usual:z.boolean()}).strict(),
  z.object({...common,action:z.literal('revoke')}).strict(),
]);
const stale=()=>new ServiceError(409,'stale_fallback','Read the current household fallback and review it again.');
function currentHeads(filter='') {
  return `SELECT DISTINCT ON(candidate_id) * FROM ritc.accepted_fallback_revision WHERE household_id=$1 ${filter} ORDER BY candidate_id,revision DESC`;
}

// Internal to an authenticated shopper transaction; the route separately verifies the current paid seat.
export async function loadAcceptedFallbacks(ctx:Context,ids?:string[]):Promise<AcceptedFallback[]> {
  if(ctx.viewGrantId || ctx.member.kind!=='adult') throw unavailable();
  const authority=await ctx.db.query(`SELECT 1 FROM ritc.shop WHERE household_id=$1 AND shopper_id=$2 AND ($3::uuid IS NULL OR shop_id=$3) LIMIT 1`,
    [ctx.householdId,ctx.member.member_id,ctx.selectedShopId??null]);
  if(!authority.rowCount)throw unavailable();
  const selected=ids===undefined?undefined:z.array(id).max(100).parse(ids);
  const heads=currentHeads(selected===undefined?'':'AND candidate_id=ANY($2::uuid[])');
  const rows=await ctx.db.query<AcceptedFallback>(`SELECT candidate_id AS "candidateId",revision,recipe,usual
    FROM (${heads}) latest WHERE accepted AND recipe IS NOT NULL ORDER BY candidate_id`,selected===undefined?[ctx.householdId]:[ctx.householdId,selected]);
  return rows.rows;
}
export async function linkAcceptedFallback(ctx:Context,operationId:string,candidateId:string,revision:number) {
  if(ctx.viewGrantId || ctx.member.kind!=='adult')throw unavailable();
  const args=[ctx.householdId,candidateId,revision,operationId];
  const linked=await ctx.db.query(`INSERT INTO ritc.meal_recovery_fallback(household_id,candidate_id,revision,operation_id)
    SELECT household_id,candidate_id,revision,$4 FROM (${currentHeads()}) latest
    WHERE candidate_id=$2 AND revision=$3 AND accepted AND recipe IS NOT NULL AND EXISTS(
      SELECT FROM ritc.meal_recovery_revision r JOIN ritc.shop s USING(household_id,shop_id)
      WHERE r.household_id=$1 AND r.operation_id=$4 AND r.actor_id=$5 AND s.shopper_id=$5 AND r.current_meal IS NOT NULL
        AND r.authority_epoch=s.authority_epoch AND ($6::uuid IS NULL OR s.shop_id=$6)) RETURNING operation_id`,
    [...args,ctx.member.member_id,ctx.selectedShopId??null]);
  if(!linked.rowCount) throw stale();
  await ctx.db.query(`INSERT INTO ritc.meal_recovery_source_member(household_id,operation_id,member_id)
    SELECT household_id,$4,unnest(source_members) FROM ritc.accepted_fallback_revision WHERE household_id=$1 AND candidate_id=$2 AND revision=$3
    ON CONFLICT DO NOTHING`,args);
  await ctx.db.query(`INSERT INTO ritc.meal_recovery_source_shop(household_id,operation_id,shop_id)
    SELECT household_id,$4,unnest(source_shops) FROM ritc.accepted_fallback_revision WHERE household_id=$1 AND candidate_id=$2 AND revision=$3
    ON CONFLICT DO NOTHING`,args);
}

interface Material { recipe:Recipe; members:string[]; shops:string[] }
const unboundProtection=()=>new ServiceError(409,'unbound_protected_recipe','Review the protected requirement and its named portions before accepting the dish.');
const unique=(v:string[])=>[...new Set(v)];

export class SharedFallbackRegistry {
  constructor(private readonly repo:HouseholdRepository,private readonly billing?:BillingService) {}

  private async scope(ctx:Context,shopId:string) {
    const shop=await this.repo.shop(ctx,shopId);
    this.repo.requireShopper(ctx,shop);
    const {rows}=await ctx.db.query('SELECT fallback_revision FROM ritc.household WHERE household_id=$1',[ctx.householdId]);
    return {shop,stamp:{shopId,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,registryRevision:rows[0].fallback_revision as number}};
  }

  private async requireAssistance(ctx:Context) {
    if(!this.billing) throw unavailable();
    await this.billing.requirePaidSeat(ctx);
  }

  async read(ctx:Context,shopId:string,after:string|null){
    const {stamp}=await this.scope(ctx,shopId);
    const cursor=after===null?null:id.parse(after);
    if(cursor && !(await ctx.db.query(`SELECT 1 FROM (${currentHeads()}) latest WHERE candidate_id=$2 AND accepted AND recipe IS NOT NULL`,[ctx.householdId,cursor])).rowCount)throw stale();
    const rows=(await ctx.db.query<AcceptedFallback>(`SELECT candidate_id AS "candidateId",revision,recipe,usual FROM (${currentHeads()}) latest
      WHERE accepted AND recipe IS NOT NULL AND ($2::uuid IS NULL OR candidate_id>$2) ORDER BY candidate_id LIMIT 21`,[ctx.householdId,cursor])).rows;
    const candidates:AcceptedFallback[]=[];
    let bytes=0;
    for(const row of rows){
      const size=Buffer.byteLength(JSON.stringify(row));
      if(candidates.length===20 || bytes+size>1400000)break;
      candidates.push(row);bytes+=size;
    }
    return {...stamp,candidates,nextCursor:rows.length>candidates.length?candidates.at(-1)!.candidateId:null};
  }

  private async material(ctx:Context,shop:Shop,source:Source):Promise<Material> {
    const scope=[ctx.householdId,shop.shop_id];
    if(source.kind==='idea'){
      const row=(await ctx.db.query(`SELECT i.actor_id,i.draft FROM ritc.shared_meal_idea i
        LEFT JOIN ritc.meal_planner p ON p.household_id=i.household_id AND p.shop_id=i.shop_id
        JOIN ritc.member a ON a.household_id=i.household_id AND a.member_id=i.actor_id AND a.state='active'
        WHERE i.household_id=$1 AND i.shop_id=$2 AND i.idea_id=$3 AND i.revision=$4 AND i.authority_epoch=$5
          AND i.grant_revision=coalesce(p.revision,0) AND (i.actor_id=$6 OR (p.authority_epoch=$5 AND i.actor_id=p.planner_id))`,
        [...scope,source.ideaId,source.revision,shop.authority_epoch,ctx.member.member_id])).rows[0];
      if(!row) throw stale();
      const d=sharedIdeaDraftSchema.parse(row.draft);
      const ingredients=d.ingredients.map(i=>{
        const a=typeof i.required==='number'?{numerator:i.required,denominator:1}:i.required;
        const literal=a?(a.denominator===1?String(a.numerator):a.numerator+'/'+a.denominator):null;
        return {id:i.id,name:i.name,notes:'',quantity:a?{unit:i.unit,amount:a,originalLiteral:literal+' '+i.unit}:null,exclusions:[]};
      });
      for(const [index,name] of d.assumedExtras.entries())ingredients.push({id:reviewedID(source.ideaId,'assumed',index),name,notes:'',quantity:null,exclusions:[]});
      return {recipe:fallbackRecipe.parse({title:d.title,portions:d.servings,notes:'',sourceURL:null,exclusions:d.exclusions,requiredLeadMinutes:d.minutes,elapsedMinutes:null,ingredients}),
        members:[row.actor_id],shops:[shop.shop_id]};
    }

    const args=[...scope,source.occurrenceId,source.mealRevision];
    const authors=await ctx.db.query(`SELECT actor_id FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 AND revision<=$4
      UNION SELECT actor_id FROM ritc.shared_meal_change WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 AND state='applied' AND shop_revision<$4`,args);
    const members=authors.rows.map(r=>r.actor_id as string), shops=[shop.shop_id];
    let recipe:Recipe;
    if(shop.placed_revision!==null){
      const desk=await readRecoveryDesk(ctx,shop);
      const meal=desk.meals.find(m=>m.occurrenceId===source.occurrenceId && m.sourceMealRevision===source.mealRevision && m.revisionId===source.revisionId);
      if(!meal) throw stale();
      if(meal.needs.some(n=>n.priority==='protected' && !n.groupId && !n.groupIds?.length))throw unboundProtection();
      recipe={title:meal.title,portions:meal.portions,sourceURL:meal.sourceURL,notes:meal.notes,exclusions:meal.exclusions,
        elapsedMinutes:null,requiredLeadMinutes:meal.requiredLeadMinutes,groups:meal.groups,
        ingredients:meal.needs.map(n=>({id:n.id,name:n.name,notes:n.notes,quantity:n.quantity,exclusions:n.exclusions,
          groupIds:n.groupId?[n.groupId]:n.groupIds??[],...(n.groupId&&n.quantity?{bindings:[{groupId:n.groupId,quantity:n.quantity}]}:{})}))};
      const origins=(await ctx.db.query(`SELECT r.actor_id,ARRAY(SELECT m.member_id FROM ritc.meal_recovery_source_member m WHERE (m.household_id,m.operation_id)=(r.household_id,r.operation_id)) AS members,
        ARRAY(SELECT s.shop_id FROM ritc.meal_recovery_source_shop s WHERE (s.household_id,s.operation_id)=(r.household_id,r.operation_id)) AS shops
        FROM ritc.meal_recovery_revision r WHERE r.household_id=$1 AND r.shop_id=$2 AND r.new_revision_id=$3`,[...scope,source.revisionId])).rows[0];
      if(origins){members.push(origins.actor_id,...origins.members);shops.push(...origins.shops);}
    }else{
      const current=(await this.repo.meals(ctx,shop.shop_id)).find(m=>m.occurrenceId===source.occurrenceId && m.revision===source.mealRevision);
      if(!current || source.revisionId!==null)throw stale();
      const meal=sharedMealSchema.parse(current.meal);
      if(meal.protected && meal.planning?.ingredients.some(i=>!i.groupIds.length))throw unboundProtection();
      recipe={title:meal.title,portions:meal.portions,notes:'',sourceURL:null,exclusions:meal.planning?.exclusions??[],
        requiredLeadMinutes:meal.planning?.leadTimeMinutes??null,elapsedMinutes:null,
        groups:(meal.planning?.groups??[]).map(g=>({...g,protected:meal.protected||g.protected,exclusions:[]})),
        ingredients:(meal.planning?.ingredients??[]).map(({id,name,quantity,exclusions,groupIds})=>({id,name,notes:'',quantity,exclusions,groupIds,
          bindings:(meal.planning?.bindings??[]).filter(b=>b.ingredientId===id).map(({groupId,quantity})=>({groupId,quantity}))}))};
    }
    if(!recipe.ingredients.length)throw new ServiceError(409,'incomplete_recipe','Review individual ingredients before accepting this recipe.');
    return {recipe:fallbackRecipe.parse(recipe),members,shops};
  }

  async source(ctx:Context,shopId:string,input:unknown){
    const {shop,stamp}=await this.scope(ctx,shopId),{source}=reviewSource.parse(input);
    await this.requireAssistance(ctx);
    const {recipe}=await this.material(ctx,shop,source);
    return {...stamp,source,recipe};
  }

  async change(ctx:Context,shopId:string,input:unknown){
    const {shop,stamp}=await this.scope(ctx,shopId),request=write.parse(input),scope=[ctx.householdId,request.candidateId];
    if(request.action==='accept')await this.requireAssistance(ctx);
    const fingerprint=digest({shopId,request});
    const prior=(await ctx.db.query(`SELECT * FROM ritc.accepted_fallback_revision WHERE household_id=$1 AND actor_id=$2 AND client_key=$3`,
      [ctx.householdId,ctx.member.member_id,request.clientKey])).rows[0];
    if(prior){
      if(prior.device_id!==ctx.deviceId || prior.shop_id!==shopId || prior.authority_epoch!==shop.authority_epoch || !prior.fingerprint)throw stale();
      if(prior.fingerprint!==fingerprint)throw new ServiceError(409,'key_reused','Retry the exact reviewed fallback change.');
      return {shopId,shopRevision:prior.shop_revision,authorityEpoch:prior.authority_epoch,candidateId:prior.candidate_id,revision:prior.revision,
        registryRevision:prior.registry_revision,accepted:prior.accepted};
    }
    this.repo.checkBase(shop,request);
    if(request.registryRevision!==stamp.registryRevision)throw stale();
    const current=(await ctx.db.query(`SELECT * FROM ritc.accepted_fallback_revision WHERE household_id=$1 AND candidate_id=$2 ORDER BY revision DESC LIMIT 1`,scope)).rows[0];
    if((current?.revision??null)!==request.baseRevision || current && !current.fingerprint)throw stale();
    const accepted=request.action==='accept';
    let material:Material|null=null;
    if(accepted){
      material=request.source.kind==='disclosed'?{recipe:request.recipe,members:[],shops:[]}:await this.material(ctx,shop,request.source);
      if(digest(material.recipe)!==digest(request.recipe))throw stale();
      const other=(await ctx.db.query(`SELECT count(*)::int AS count,bool_or(usual) AS usual FROM (${currentHeads()}) latest
        WHERE candidate_id<>$2 AND accepted AND recipe IS NOT NULL`,scope)).rows[0];
      if(other.count>=100) throw new ServiceError(409,'fallback_limit','Review existing household fallbacks before adding another.');
      if(request.usual && other.usual)throw new ServiceError(409,'usual_fallback_exists','Review the current usual fallback before changing the usual dish.');
    }else if(!current?.accepted)throw stale();
    const registryRevision=stamp.registryRevision+1,revision=(request.baseRevision??0)+1;
    const members=unique([ctx.member.member_id,...(material?.members??[]),...(current?.source_members??[])]),shops=unique([...(material?.shops??[]),...(current?.source_shops??[])]);
    await ctx.db.query('UPDATE ritc.household SET fallback_revision=$2 WHERE household_id=$1',[ctx.householdId,registryRevision]);
    await ctx.db.query(`INSERT INTO ritc.accepted_fallback_revision(household_id,candidate_id,revision,registry_revision,actor_id,device_id,client_key,shop_id,shop_revision,
      authority_epoch,accepted,usual,source,recipe,fingerprint,source_members,source_shops,created_at)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18)`,
      [...scope,revision,registryRevision,ctx.member.member_id,ctx.deviceId,request.clientKey,shopId,shop.revision,shop.authority_epoch,accepted,
        accepted&&request.usual,accepted?request.source:null,material?.recipe??null,fingerprint,members,shops,ctx.now]);
    return {...stamp,registryRevision,candidateId:request.candidateId,revision,accepted};
  }
}
