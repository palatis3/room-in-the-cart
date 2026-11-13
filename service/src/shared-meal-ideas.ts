import { z } from 'zod';
import type { Context, HouseholdRepository } from './repository.js';
import type { MealMoves } from './meal-moves.js';
import { digest } from './database.js';
import { ServiceError } from './errors.js';
import { exclusionConflict } from './recovery-domain.js';
const id = z.string().uuid().transform(value => value.toLowerCase()), label = z.string().trim().min(1).max(240);
const positive = z.number().int().min(1).max(1_000_000), nonnegative = z.number().int().min(0).max(1_000_000);
const amount = z.union([nonnegative,z.object({numerator:nonnegative,denominator:positive}).strict()]);
const positiveAmount = amount.refine(v=>typeof v==='number'?v>0:v.numerator>0);
export type IdeaAmount = z.infer<typeof amount>;
type Fraction = {n:bigint;d:bigint};
const fraction=(v:IdeaAmount):Fraction=>typeof v==='number'?{n:BigInt(v),d:1n}:{n:BigInt(v.numerator),d:BigInt(v.denominator)};
function reduced(v:Fraction):Fraction {let a=v.n<0n?-v.n:v.n,b=v.d;while(b){const r=a%b;a=b;b=r;}return{n:v.n/(a||1n),d:v.d/(a||1n)};}
const add=(a:Fraction,b:Fraction)=>reduced({n:a.n*b.d+b.n*a.d,d:a.d*b.d});
const subtract=(a:Fraction,b:Fraction)=>reduced({n:a.n*b.d>b.n*a.d?a.n*b.d-b.n*a.d:0n,d:a.d*b.d});
function wire(v:Fraction):IdeaAmount|null {const q=reduced(v),limit=BigInt(Number.MAX_SAFE_INTEGER);if(q.n>limit||q.d>limit)return null;return q.d===1n?Number(q.n):{numerator:Number(q.n),denominator:Number(q.d)};}
function literal(v:IdeaAmount):string {return typeof v==='number'?String(v):v.denominator===1?String(v.numerator):`${v.numerator}/${v.denominator}`;}

export const sharedIdeaDraftSchema = z.object({
  title: label, source: z.enum(['manual','app_template']), servings: positive.max(1000), minutes: positive.nullable(),
  assumedExtras: z.array(label).max(20), exclusions: z.array(label).max(20),
  ingredients: z.array(z.object({ id, name: label, required: positiveAmount.nullable(), unit: z.enum(['count','gram','kilogram','ounce','pound','milliliter','liter','fluidOunce','cup']),
    stock: amount.nullable(), reservations: z.array(z.object({name:label,amount:positiveAmount}).strict()).max(20),
    pack: positiveAmount.nullable(), usableNumerator: positive.nullable(), usableDenominator: positive.nullable(),
    evidence: label,
  }).strict()).min(1).max(60),
}).strict().superRefine((value,ctx) => {
  if(new Set(value.ingredients.map(i=>i.id)).size !== value.ingredients.length) ctx.addIssue({code:'custom',message:'Ingredient identifiers must be unique.'});
  if(value.ingredients.some(i=>i.usableNumerator !== null && i.usableDenominator !== null && i.usableNumerator>i.usableDenominator)) ctx.addIssue({code:'custom',message:'Usable yield cannot exceed the entered package.'});
});
export type SharedIdeaDraft = z.infer<typeof sharedIdeaDraftSchema>;
/** Only explicit household-entered evidence is evaluated. No device store or private prices are consulted. */
export function evaluateSharedIdea(value:SharedIdeaDraft) {
  const ingredients=value.ingredients.map(i=>{
    const excluded=exclusionConflict({name:i.name,exclusions:value.exclusions});
    const reserved=i.reservations.reduce((sum,r)=>add(sum,fraction(r.amount)),{n:0n,d:1n});
    const remaining=i.stock===null?null:subtract(fraction(i.stock),reserved);
    const shortage=i.required===null||remaining===null?null:subtract(fraction(i.required),remaining);
    let wholePacks:number|null=null;
    if(shortage!==null&&i.pack!==null&&i.usableNumerator!==null&&i.usableDenominator!==null){
      const pack=fraction(i.pack),numerator=shortage.n*pack.d*BigInt(i.usableDenominator),denominator=shortage.d*pack.n*BigInt(i.usableNumerator);
      const packs=(numerator+denominator-1n)/denominator;
      if(packs<=BigInt(Number.MAX_SAFE_INTEGER))wholePacks=Number(packs);
    }
    const reservedWire=wire(reserved),remainingWire=remaining===null?null:wire(remaining),shortageWire=shortage===null?null:wire(shortage);
    const arithmeticUnavailable=reservedWire===null||(remaining!==null&&remainingWire===null)||(shortage!==null&&shortageWire===null);
    return {ingredientId:i.id,excluded,reserved:reservedWire,remaining:remainingWire,shortage:shortageWire,
      wholePacks:arithmeticUnavailable?null:wholePacks,unresolvedPrice:true,arithmeticUnavailable};
  });
  return {canApprove:ingredients.every(i=>!i.excluded&&i.wholePacks!==null),ingredients};
}
export const sharedIdeaWriteSchema=z.object({clientKey:id,ideaId:id,baseRevision:z.number().int().positive().nullable(),
  shopRevision:z.number().int().positive(),authorityEpoch:z.number().int().positive(),grantRevision:z.number().int().nonnegative(),
  action:z.enum(['save','approve']),draft:sharedIdeaDraftSchema,reviewedHouseholdEvidence:z.boolean()}).strict();
export type SharedIdeaWrite=z.infer<typeof sharedIdeaWriteSchema>;
const stale=()=>new ServiceError(409,'stale_idea','Refresh household access and review the current idea again.');
export class SharedMealIdeas {
  constructor(private readonly repo:HouseholdRepository,private readonly moves:MealMoves){}
  async read(ctx:Context,id:string){
    const {shop,shopper,plannerId,grantRevision}=await this.moves.context(ctx,id,true);
    const rows=(await ctx.db.query(`SELECT idea_id,revision,actor_id,state,draft FROM ritc.shared_meal_idea
      WHERE household_id=$1 AND shop_id=$2 AND authority_epoch=$3 AND grant_revision=$4
      AND actor_id IN ($5,$6) ORDER BY updated_at DESC,idea_id LIMIT 100`,
      [ctx.householdId,id,shop.authority_epoch,grantRevision,ctx.member.member_id,shopper?plannerId:ctx.member.member_id])).rows;
    return {shopId:id,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,grantRevision,shopper,
      ideas:rows.map(row=>({ideaId:row.idea_id,revision:row.revision,actorId:row.actor_id,state:row.state,draft:row.draft,preview:evaluateSharedIdea(sharedIdeaDraftSchema.parse(row.draft))}))};
  }
  async write(ctx:Context,id:string,input:SharedIdeaWrite){
    const {shop,grantRevision}=await this.moves.context(ctx,id,true);
    if(shop.authority_epoch!==input.authorityEpoch||grantRevision!==input.grantRevision)throw stale();
    const prior=(await ctx.db.query('SELECT fingerprint,response FROM ritc.shared_idea_receipt WHERE household_id=$1 AND actor_id=$2 AND client_key=$3',[ctx.householdId,ctx.member.member_id,input.clientKey])).rows[0];
    if(prior){if(prior.fingerprint!==digest({shopId:id,...input}))throw new ServiceError(409,'key_reused','Retry the exact reviewed idea.');return prior.response;}
    if(shop.revision!==input.shopRevision)throw stale();
    const current=(await ctx.db.query('SELECT revision,actor_id,authority_epoch,grant_revision,state,draft FROM ritc.shared_meal_idea WHERE household_id=$1 AND shop_id=$2 AND idea_id=$3',[ctx.householdId,id,input.ideaId])).rows[0];
    if(current ? current.actor_id!==ctx.member.member_id||current.authority_epoch!==shop.authority_epoch||current.grant_revision!==grantRevision||current.revision!==input.baseRevision : input.baseRevision!==null)throw stale();
    const preview=evaluateSharedIdea(input.draft);
    if(input.action==='approve'&&(!current||!input.reviewedHouseholdEvidence||!preview.canApprove||digest(current.draft)!==digest(input.draft)))throw new ServiceError(409,'idea_review_required','Save corrections, review household evidence and resolve excluded or ambiguous quantities before approval.');
    if(!current){const count=await ctx.db.query('SELECT count(*)::int AS n FROM ritc.shared_meal_idea WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,id]);if(count.rows[0].n>=100)throw new ServiceError(409,'idea_limit','Review the existing ideas before adding another.');}
    const revision=(current?.revision??0)+1,state=input.action==='approve'?'approved':'draft';
    await ctx.db.query(`INSERT INTO ritc.shared_meal_idea(household_id,shop_id,idea_id,actor_id,authority_epoch,grant_revision,revision,state,draft)
      VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT(household_id,shop_id,idea_id) DO UPDATE SET revision=$7,state=$8,draft=$9,updated_at=now()`,
      [ctx.householdId,id,input.ideaId,ctx.member.member_id,shop.authority_epoch,grantRevision,revision,state,input.draft]);
    const response={saved:true,ideaId:input.ideaId,revision,state};
    await ctx.db.query('INSERT INTO ritc.shared_idea_receipt(household_id,shop_id,idea_id,actor_id,client_key,fingerprint,response) VALUES($1,$2,$3,$4,$5,$6,$7)',[ctx.householdId,id,input.ideaId,ctx.member.member_id,input.clientKey,digest({shopId:id,...input}),response]);
    return response;
  }
}

/** A new occurrence must match the approved idea under the current adult's grant. */
export async function requireApprovedSharedIdea(ctx:Context,shopId:string,authorityEpoch:number,grantRevision:number,
  actorId:string,ideaId:string,revision:number,meal:unknown,exactProposalReceipt=false) {
  const row=(await ctx.db.query(`SELECT draft FROM ritc.shared_meal_idea WHERE household_id=$1 AND shop_id=$2 AND idea_id=$3
    AND actor_id=$4 AND authority_epoch=$5 AND grant_revision=$6 AND revision=$7 AND state='approved'`,
    [ctx.householdId,shopId,ideaId,actorId,authorityEpoch,grantRevision,revision])).rows[0];
  if(!row)throw stale();
  const draft=sharedIdeaDraftSchema.parse(row.draft),day=(meal as {day?:unknown})?.day;
  if(!evaluateSharedIdea(draft).canApprove)throw stale();
  const ingredients=draft.ingredients.map(i=>({
    id:i.id,name:i.name,quantity:i.required===null ? null : {
      amount:typeof i.required==='number' ? {numerator:i.required,denominator:1} : i.required,
      unit:i.unit,originalLiteral:`${literal(i.required)} ${i.unit}`,
    },groupIds:[],exclusions:[],
  }));
  const baseMeal={title:draft.title,day,kind:'dinner',portions:draft.servings,protected:false,planning:{groups:[],ingredients}};
  const submitted=digest(meal);
  // Older clients saved only the base shape. An exact receipt can acknowledge that
  // historical write; creating a proposal or consuming it still requires the reviewed facts.
  if(exactProposalReceipt && submitted===digest(baseMeal))return;
  const planning={
    ...baseMeal.planning,
    ...(draft.exclusions.length ? {exclusions:draft.exclusions} : {}),
    ...(draft.minutes!==null ? {leadTimeMinutes:draft.minutes} : {}),
  };
  if(submitted!==digest({...baseMeal,planning}))throw stale();
}
