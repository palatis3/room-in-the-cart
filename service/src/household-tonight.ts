import {chooseTonight} from './contracts.js';
import {z} from 'zod';
import {digest} from './database.js';
import {refresh,ServiceError,unavailable} from './errors.js';
import {mealConstraints,mealEligibility,mealEvidence} from './meal-preferences.js';
import {householdPantryEpoch,pantryRevision,tonightStock} from './pantry-lots.js';
import {amount,dimension,inUnit,min,sub,zero} from './physical-quantity.js';
import type {Context,HouseholdRepository,Shop} from './repository.js';
import {mealQuantity,sharedMealSchema} from './shared-meal-planning.js';

const id=z.uuid().toLowerCase(),rev=z.number().int().positive().max(2147483647);
const label=z.string().trim().min(1).max(240).refine(s=>!/[\p{Cc}\uD800-\uDFFF]/u.test(s));
const recipe=z.object({title:label,portions:z.number().int().min(1).max(1000),minutes:z.number().int().min(0).max(525600).nullable(),
  ingredients:z.array(z.object({id,name:label,quantity:mealQuantity.nullable(),reviewedLotIds:z.array(id).max(12).default([]).refine(ids=>new Set(ids).size===ids.length)}).strict()).min(1).max(60),
  preferenceEvidence:mealEvidence.nullish()}).strict().refine(r=>new Set(r.ingredients.map(i=>i.id)).size===r.ingredients.length && Buffer.byteLength(JSON.stringify(r))<=60000);
type Recipe=z.infer<typeof recipe>;
const save=z.object({v:z.literal(1),clientKey:id,replayWindow:id,grantEpoch:rev.or(z.literal(0)),recipeId:id,baseRevision:rev.nullable(),reviewed:z.literal(true),recipe}).strict();

const linked=(r:Recipe)=>r.ingredients.flatMap(i=>i.reviewedLotIds);
function authority(ctx:Context){const epoch=householdPantryEpoch(ctx);if(epoch===null)throw unavailable();return epoch;}

export async function saveTonightRecipe(ctx:Context,input:unknown){
  const epoch=authority(ctx);if(!ctx.member.organizer)throw unavailable();
  const cmd=save.parse(input);if(cmd.grantEpoch!==epoch)throw refresh();
  if(!(await ctx.db.query('SELECT FROM ritc.replay_window WHERE household_id=$1 AND window_id=$2 AND member_id=$3 AND device_id=$4 AND revoked_at IS NULL AND expires_at>$5',[ctx.householdId,cmd.replayWindow,ctx.member.member_id,ctx.deviceId,ctx.now])).rowCount)throw refresh();
  const args=[ctx.householdId,cmd.recipeId],prior=(await ctx.db.query('SELECT * FROM ritc.tonight_recipe WHERE household_id=$1 AND recipe_id=$2',args)).rows[0];
  if(prior && (!prior.recipe || prior.actor_id!==ctx.member.member_id))throw refresh();
  if(prior?.client_key===cmd.clientKey){if(prior.fingerprint!==digest(cmd)||prior.device_id!==ctx.deviceId)throw refresh();return{recipeId:cmd.recipeId,recipeRevision:prior.revision};}
  if((prior?.revision??null)!==cmd.baseRevision)throw refresh();
  if(!prior && (await ctx.db.query('SELECT count(*)::int n FROM ritc.tonight_recipe WHERE household_id=$1 AND recipe IS NOT NULL',[ctx.householdId])).rows[0].n>=100)throw new ServiceError(409,'recipe_limit','Review your existing household recipes.');
  const ids=[...new Set(linked(cmd.recipe))];
  if((await tonightStock(ctx,ids)).length!==ids.length)throw refresh();
  const revision=(prior?.revision??0)+1;
  await ctx.db.query(`INSERT INTO ritc.tonight_recipe(household_id,recipe_id,actor_id,revision,recipe,client_key,device_id,fingerprint) VALUES($1,$2,$3,$4,$5,$6,$7,$8)
    ON CONFLICT(household_id,recipe_id) DO UPDATE SET revision=$4,recipe=$5,client_key=$6,device_id=$7,fingerprint=$8`,[...args,ctx.member.member_id,revision,cmd.recipe,cmd.clientKey,ctx.deviceId,digest(cmd)]);
  return{recipeId:cmd.recipeId,recipeRevision:revision};
}
type Stock=Awaited<ReturnType<typeof tonightStock>>;
function needs(r:Recipe,stock:Stock,now:Date,settings:Awaited<ReturnType<typeof mealConstraints>>['settings']){
  const available=stock.map(l=>{
    const q=l.observed?.quantity;
    const unsuitable=mealEligibility(settings,[l.name,...l.tags],r.preferenceEvidence??undefined,r.minutes).blocked.length>0;
    return {id:l.id,q,free:l.free?{n:BigInt(l.free.numerator),d:BigInt(l.free.denominator)}:null,soon:l.useFirstAt!==null&&Date.parse(l.useFirstAt)<=now.getTime()+3*86400000,evidenceAt:l.observed?.confirmedAt??null,unsuitable};
  });
  return r.ingredients.map(i=>{
    const q=i.quantity,candidates=available.filter(l=>i.reviewedLotIds.includes(l.id)&&!l.unsuitable);
    const base={id:i.id,name:i.name,evidenceAt:candidates.flatMap(l=>l.evidenceAt?[l.evidenceAt]:[]).sort()[0]??null};if(!q)return{...base,status:'unknown' as const,missing:null,useSoon:false};
    let unmet=amount(q),usedSoon=false,uncertain=!i.reviewedLotIds.length || candidates.length!==i.reviewedLotIds.length;
    for(const l of candidates){
      if(!l.q || l.free===null || dimension(q)!==dimension(l.q)){uncertain=true;continue;}
      const take=min(unmet,l.free);if(take.n>0n && l.soon)usedSoon=true;
      l.free=sub(l.free,take);unmet=sub(unmet,take);if(unmet.n===0n)break;
    }
    if(unmet.n===0n)return{...base,status:'covered' as const,missing:null,useSoon:usedSoon};
    const left=inUnit(unmet,q.unit),n=Number(left.numerator),d=Number(left.denominator);
    if(uncertain||n>1e9||d>1e9)return{...base,status:'unknown' as const,missing:null,useSoon:usedSoon};
    return{...base,status:'missing' as const,missing:{amount:{numerator:n,denominator:d},unit:q.unit,originalLiteral:d===1?String(n):n+'/'+d},useSoon:usedSoon};
  });
}
async function candidates(ctx:Context){
  const epoch=authority(ctx),revision=await pantryRevision(ctx),profile=await mealConstraints(ctx);
  const rows=await ctx.db.query<{recipe_id:string;revision:number;recipe:Recipe}>('SELECT recipe_id,revision,recipe FROM ritc.tonight_recipe WHERE household_id=$1 AND recipe IS NOT NULL ORDER BY recipe_id LIMIT 100',[ctx.householdId]);
  const stock=await tonightStock(ctx,[...new Set(rows.rows.flatMap(row=>linked(row.recipe)))]), scope=digest({member:ctx.member.member_id,household:ctx.householdId,epoch,pantry:revision,profile:profile.revision,stock});
  let excludedCount=0;
  const list=rows.rows.flatMap(row=>{
    const r=row.recipe,e=mealEligibility(profile.settings,r.ingredients.map(i=>i.name),r.preferenceEvidence??undefined,r.minutes);
    if(e.blocked.length){excludedCount++;return [];}
    const ingredients=needs(r,stock,ctx.now,profile.settings),covered=ingredients.filter(i=>i.status==='covered').length,soon=ingredients.filter(i=>i.useSoon).length;
    const item={recipeId:row.recipe_id,recipeRevision:row.revision,title:r.title,portions:r.portions,minutes:r.minutes,status:e.eligible?'eligible':'unresolved',
      ingredients,checkoutEstimate:covered===ingredients.length?'noPurchaseNeeded':'incomplete',
      reviewToken:e.eligible?digest({scope,id:row.recipe_id,revision:row.revision,ingredients}):null};
    return[{item,recipe:r,covered,soon,soft:e.soft.length}];
  });
  list.sort((a,b)=>Number(b.item.status==='eligible')-Number(a.item.status==='eligible')||b.soon-a.soon||b.covered*a.recipe.ingredients.length-a.covered*b.recipe.ingredients.length||a.soft-b.soft||(a.recipe.minutes??Infinity)-(b.recipe.minutes??Infinity)||a.item.recipeId.localeCompare(b.item.recipeId));
  return {epoch,revision,list,excludedCount};
}
export async function householdTonight(ctx:Context){
  const {epoch,revision,list,excludedCount}=await candidates(ctx);
  return {v:1,householdId:ctx.householdId,grantEpoch:epoch,pantryRevision:revision,asOf:ctx.now.toISOString(),canReviewRecipes:ctx.member.organizer,recipes:list.map(v=>v.item),excludedCount};
}
export async function recordTonight(ctx:Context,shop:Shop,body:unknown,operationId:string,repo:HouseholdRepository){
  repo.requireDraft(shop);const b=chooseTonight.parse(body),{epoch,list}=await candidates(ctx);
  const selection=list.find(v=>v.item.recipeId===b.recipeId);
  if(b.grantEpoch!==epoch || !selection || selection.item.recipeRevision!==b.recipeRevision || selection.item.reviewToken!==b.reviewToken)throw refresh();
  const existing=await repo.meals(ctx,shop.shop_id);
  if(existing.length>=100 || existing.some(m=>m.occurrenceId===b.occurrenceId)|| (await ctx.db.query('SELECT FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 LIMIT 1',[ctx.householdId,shop.shop_id,b.occurrenceId])).rowCount)throw refresh();
  const r=selection.recipe,meal=sharedMealSchema.parse({title:r.title,day:b.day,kind:'dinner',portions:r.portions,protected:false,
    planning:{groups:[],ingredients:r.ingredients.map(({id,name,quantity})=>({id,name,quantity,groupIds:[],exclusions:[]})),...(r.minutes===null?{}:{leadTimeMinutes:r.minutes})}});
  await ctx.db.query('INSERT INTO ritc.shared_meal_revision(household_id,shop_id,occurrence_id,revision,actor_id,meal) VALUES($1,$2,$3,$4,$5,$6)',[ctx.householdId,shop.shop_id,b.occurrenceId,shop.revision+1,ctx.member.member_id,meal]);
  await ctx.db.query('INSERT INTO ritc.tonight_choice VALUES($1,$2,$3,$4,$5,$6,$7)',[ctx.householdId,shop.shop_id,b.occurrenceId,operationId,b.recipeId,b.recipeRevision,epoch]);
  await ctx.db.query('UPDATE ritc.shop SET revision=revision+1 WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shop.shop_id]);
  return b.occurrenceId;
}
export async function checkTonightReplay(ctx:Context,shop:Shop,id:string){
 const epoch=authority(ctx);
 if(!(await ctx.db.query(`SELECT FROM ritc.tonight_choice c JOIN ritc.tonight_recipe r USING(household_id,recipe_id)
   WHERE c.household_id=$1 AND c.shop_id=$2 AND c.operation_id=$3 AND c.grant_epoch=$4 AND r.recipe IS NOT NULL
   AND (SELECT meal IS NOT NULL FROM ritc.shared_meal_revision WHERE household_id=c.household_id AND shop_id=c.shop_id AND occurrence_id=c.occurrence_id ORDER BY revision DESC LIMIT 1)`,[ctx.householdId,shop.shop_id,id,epoch])).rowCount)throw refresh();
}
