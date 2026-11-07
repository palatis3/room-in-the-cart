import type {BillingService} from './billing/service.js';
import {billingUnavailable} from './billing/domain.js';
import {requirePlaced} from './delivery-evidence.js';
import {invalid,refresh,ServiceError} from './errors.js';
import {add,amount,dimension,zero,type Rat} from './physical-quantity.js';
import {fallbackOptionsSchema,recoveryIntentSchema,type FallbackSelection,type RecoveryIntent,type RecoveryMeal,type RecoveryNeed} from './recovery-contracts.js';
import {exclusionConflict,previewRecovery,recoveryDigest,RecoveryError} from './recovery-domain.js';
import type {Context,Shop} from './repository.js';
import {loadSharedRecoveryDecisionBasis,reviewedID,type RecoveryPublicationLoader} from './shared-recovery-basis.js';
import {loadAcceptedFallbacks,type AcceptedFallback} from './shared-fallback-registry.js';

type State=Awaited<ReturnType<typeof loadSharedRecoveryDecisionBasis>>;
type Reason='timingUnknown'|'topUpUnreviewed'|'deadlineExceeded'|'leadStepUnconfirmed'|'exclusionConflict'|'insufficientPacks'|'overBudget'|'foodUnconfirmed'|'protectedCommitment';
type Totals={minutes?:number;availableMinutes?:number;requiredPacks?:number;availablePacks?:number;extraCashMinor?:number;budgetMinor?:number;currency?:string};
export class FallbackConstraint extends Error {
  constructor(readonly reason:Reason,readonly totals:Totals={}) {super(reason);}
}
const unmet=(reason:Reason,totals?:Totals):never=>{throw new FallbackConstraint(reason,totals);};
type Decision=ReturnType<typeof previewRecovery>;
type Offer=NonNullable<FallbackSelection['review']['ingredients'][number]['offer']>;
const unique=<T>(values:T[])=>[...new Set(values)];
const same=(a:unknown,b:unknown)=>recoveryDigest(a)===recoveryDigest(b);
const normal=(s:string)=>s.trim().replace(/\s+/gu,' ').toLowerCase();
const groupIds=(n:RecoveryNeed)=>n.groupId?[n.groupId]:n.groupIds??[];

export async function requireAssistance(ctx:Context,billing?:BillingService) {
  if(!billing) throw billingUnavailable();
  await billing.requirePaidSeat(ctx);
}

function scaled(quantity:NonNullable<RecoveryNeed['quantity']>,servings:{numerator:number;denominator:number},recipePortions:number) {
  const ratio=add(zero,{n:BigInt(quantity.amount.numerator)*BigInt(servings.numerator),
    d:BigInt(quantity.amount.denominator)*BigInt(servings.denominator)*BigInt(recipePortions)});
  if(ratio.n>1_000_000_000n || ratio.d>1_000_000_000n) return null;
  const sameAmount=ratio.n*BigInt(quantity.amount.denominator)===ratio.d*BigInt(quantity.amount.numerator);
  const literal=ratio.d===1n?String(ratio.n):ratio.n+'/'+ratio.d;
  return {...quantity,amount:{numerator:Number(ratio.n),denominator:Number(ratio.d)},
    originalLiteral:sameAmount?quantity.originalLiteral:literal+' '+quantity.unit};
}

function replacement(state:State,target:RecoveryMeal,c:AcceptedFallback,s:FallbackSelection,revisionId:string):RecoveryMeal|null {
  const {recipe}=c, {review}=s;
  const required=target.needs.filter(n=>n.priority==='required'),protectedNeeds=target.needs.filter(n=>n.priority==='protected');
  if(!required.length || !recipe.ingredients.length || recipe.ingredients.length!==review.ingredients.length) return null;
  const scopes=unique(required.map(n=>groupIds(n).join('/')));
  // An unsplit requirement or a mixed grouped/ungrouped target has no reviewed
  // per-group serving basis on which to distribute this recipe.
  if(scopes.some(id=>id.includes('/')) || scopes.includes('') && (scopes.length>1 || protectedNeeds.length)) return null;
  if(recipe.elapsedMinutes!==null && review.remainingElapsedMinutes!==null &&
    review.remainingElapsedMinutes<recipe.elapsedMinutes && !review.advanceStepsCompleted) return unmet('leadStepUnconfirmed',{minutes:recipe.elapsedMinutes});
  const mapping=new Map<string,RecoveryMeal['groups'][number]>();
  for(const group of recipe.groups??[]) {
    const matches=target.groups.filter(g=>(g.id===group.id || normal(g.name)===normal(group.name)) &&
      g.protected===group.protected && BigInt(g.servings.numerator)*BigInt(group.servings.denominator)===
      BigInt(group.servings.numerator)*BigInt(g.servings.denominator));
    if(matches.length!==1 || [...mapping.values()].some(g=>g.id===matches[0]!.id)) return null;
    mapping.set(group.id,matches[0]!);
  }
  const confirmedProtected=new Set<string>();
  // A new dish restriction belongs on each of its ingredient rows. It can
  // apply to the entire occurrence when every retained protected row agrees.
  const mealExclusions=unique([...target.exclusions,...recipe.exclusions.filter(e=>protectedNeeds.every(n=>n.exclusions.includes(e)))]);
  const needs:RecoveryNeed[]=[...protectedNeeds];
  const foods=new Map(state.basis.foods.map(f=>[f.id,f]));
  for(const ingredient of recipe.ingredients) {
    const match=review.ingredients.find(i=>i.ingredientId===ingredient.id);
    if(!match || !ingredient.quantity || unique(match.sourceIds).length!==match.sourceIds.length || match.sourceIds.some(id=>!foods.has(id))) return null;
    const ingredientGroups=ingredient.groupIds??[];
    const bindings=ingredient.bindings??[];
    const structured=mapping.size>0;
    if(structured && ingredientGroups.some(id=>!mapping.has(id)) ||
      ingredientGroups.length>1 && bindings.length!==ingredientGroups.length) return null;
    const partitions=structured?ingredientGroups.length?ingredientGroups:['']:scopes;
    for(const part of partitions) {
      const group=structured?mapping.get(part):target.groups.find(g=>g.id===part);
      const scope=group?.id??'';
      const servings=scope?group?.servings:{numerator:target.portions,denominator:1};
      if(!servings) return null;
      const binding=bindings.find(b=>b.groupId===part);
      if(bindings.length && !binding) return null;
      const quantity=structured?binding?.quantity??ingredient.quantity:scaled(ingredient.quantity,servings,recipe.portions);
      if(!quantity) return null;
      const sourceGroup=recipe.groups?.find(g=>g.id===part);
      const recipeRestrictions=unique([...recipe.exclusions,...ingredient.exclusions,...sourceGroup?.exclusions??[]]);
      if(group?.protected) {
        const existing=protectedNeeds.find(n=>!confirmedProtected.has(n.id) && n.groupId===group.id &&
          n.name===ingredient.name && n.notes===ingredient.notes && same(n.quantity,quantity) &&
          recipeRestrictions.every(e=>n.exclusions.includes(e)) && same([...(n.matchedSourceIds??[])].sort(),[...match.sourceIds].sort()));
        if(!existing) return null;
        confirmedProtected.add(existing.id);
        continue;
      }
      if(!scopes.includes(scope)) return null;
      const exclusions=unique([...mealExclusions,...recipeRestrictions,...group?.exclusions??[],
        ...required.filter(n=>(n.groupId??'')===scope).flatMap(n=>n.exclusions)]);
      const need:RecoveryNeed={id:reviewedID(revisionId,ingredient.id,scope),ingredientId:ingredient.id,
        groupId:group?.id??null,priority:'required',quantity,foodId:null,matchedSourceIds:match.sourceIds,
        name:ingredient.name,notes:ingredient.notes,due:target.due,exclusions};
      if(exclusionConflict(need) || match.sourceIds.some(id=>exclusionConflict(need,foods.get(id)))) return unmet('exclusionConflict');
      needs.push(need);
    }
  }
  return {...target,title:recipe.title,revisionId,template:null,notes:recipe.notes,sourceURL:recipe.sourceURL,exclusions:mealExclusions,needs,
    remainingElapsedMinutes:review.remainingTimeUnknown?null:review.remainingElapsedMinutes??recipe.elapsedMinutes,requiredLeadMinutes:recipe.requiredLeadMinutes,
    advanceStepsCompleted:review.advanceStepsCompleted};
}

type Buy={ingredientId:string,label:string,packs:number,subtotalMinor:number};
function estimate(state:State,decision:Decision,s:FallbackSelection,asOf:string) {
  const next=decision.intent.replacement,rows=new Map(decision.after.demands.map(d=>[d.needId,d]));
  if(!state.basis.commitmentInventoryComplete) return null;
  const packs=new Map<string,{ingredientId:string,offer:Offer,short:Rat}>();
  const selected=next.needs.filter(n=>n.priority==='required');
  const dueByPack=new Map<string,string>();
  for(const need of next.needs) {
    const row=rows.get(need.id);
    if(!need.quantity || !row?.shortfall) return null;
    const gap=row.shortfall;
    if(need.priority==='protected') {
      if(row.issues.some(issue=>issue!=='reservation_shortfall')) return unmet('protectedCommitment');
      continue;
    }
    const review=s.review.ingredients.find(i=>i.ingredientId===need.ingredientId)!;
    if(row.issues.some(issue=>issue!=='unknown_food' || review.sourceIds.length)) return null;
    if('sourceIssues' in row && row.sourceIssues.length) return null;
    if(gap.numerator==='0') continue;
    const o=review.offer;
    if(review.sourceIds.some(id=>state.outsideProtectedSources.has(id))) return unmet('protectedCommitment');
    if(!o || !s.trip) return unmet('topUpUnreviewed');
    if(exclusionConflict(need,{name:o.label,exclusionTags:o.exclusionTags})) return unmet('exclusionConflict');
    if(dimension(need.quantity)!==dimension(o.usablePerPack)) return null;
    const key=o.packId??need.ingredientId;
    const previous=packs.get(key);
    if(previous && !same(previous.offer,o)) return null;
    const unit=amount({...need.quantity,amount:{numerator:1,denominator:1}});
    const short={n:BigInt(gap.numerator)*unit.n,d:BigInt(gap.denominator)*unit.d};
    packs.set(key,{ingredientId:previous?.ingredientId??need.ingredientId,offer:o,short:add(previous?.short??zero,short)});
    for(const source of review.sourceIds) {
      if(dueByPack.has(source) && dueByPack.get(source)!==key) return null;
      dueByPack.set(source,key);
    }
  }
  // A reviewed offer for the same physical food must also make good on a known
  // shortage for another meal. Do not count one outside requirement twice.
  for(const meal of decision.after.meals) for(const n of meal.needs) {
    if(selected.some(own=>own.id===n.id)) continue;
    const keys=unique((n.matchedSourceIds??[]).flatMap(id=>dueByPack.has(id)?[dueByPack.get(id)!]:[]));
    const row=rows.get(n.id);
    const keptLunch=meal.occurrenceId===next.occurrenceId && n.priority==='protected';
    if(!keys.length) {
      if(keptLunch && (row?.shortfall?.numerator!=='0' || row.issues.length)) return unmet('protectedCommitment');
      continue;
    }
    if(!n.quantity || !row?.shortfall || row.issues.length) return unmet('protectedCommitment');
    if(row.shortfall.numerator==='0') continue;
    if(keys.length!==1) return null;
    const p=packs.get(keys[0]!)!;
    if(dimension(n.quantity)!==dimension(p.offer.usablePerPack)) return null;
    const unit=amount({...n.quantity,amount:{numerator:1,denominator:1}});
    p.short=add(p.short,{n:BigInt(row.shortfall.numerator)*unit.n,d:BigInt(row.shortfall.denominator)*unit.d});
  }
  const buys:Buy[]=[];
  let packCount=0,merchandiseMinor=0;
  for(const {ingredientId,offer,short} of packs.values()) {
    const yieldAmount=amount(offer.usablePerPack);
    const n=short.n*yieldAmount.d,d=short.d*yieldAmount.n;
    const count=(n+d-1n)/d;
    if(count>BigInt(offer.availablePacks)) return unmet('insufficientPacks',count>BigInt(Number.MAX_SAFE_INTEGER)?{availablePacks:offer.availablePacks}:
      {requiredPacks:Number(count),availablePacks:offer.availablePacks});
    const packs=Number(count),subtotalMinor=packs*offer.priceMinor;
    packCount+=packs; merchandiseMinor+=subtotalMinor;
    buys.push({ingredientId,label:offer.label,packs,subtotalMinor});
  }
  if(!packCount && !decision.foodConfirmed) return null;
  const extraCashMinor=merchandiseMinor+(packCount?s.trip!.chargesMinor:0);
  if(packCount && extraCashMinor>s.trip!.budgetMinor) return unmet('overBudget',{
    ...(Number.isSafeInteger(extraCashMinor)?{extraCashMinor}:{}),budgetMinor:s.trip!.budgetMinor,currency:s.trip!.currency});
  if(next.remainingElapsedMinutes===null || !next.due) return unmet('timingUnknown');
  if(next.requiredLeadMinutes!==null && next.remainingElapsedMinutes<next.requiredLeadMinutes && !next.advanceStepsCompleted)
    return unmet('leadStepUnconfirmed',{minutes:next.requiredLeadMinutes});
  const minutes=next.remainingElapsedMinutes+(packCount?s.trip!.minutes:0);
  const availableMinutes=Math.max(0,Math.floor((Date.parse(next.due)-Date.parse(asOf))/60_000));
  if(!decision.timingConfirmed || Date.parse(asOf)+minutes*60_000>Date.parse(next.due))
    return unmet('deadlineExceeded',{minutes,availableMinutes});
  return {kind:packCount?'topUp' as const:'onHand' as const,minutes,packCount,merchandiseMinor,extraCashMinor,
    currency:packCount?s.trip!.currency:null,buys};
}

export async function chosenFallbacks(ctx:Context,shop:Shop,state:State) {
  // An accepted recipe can be renamed between versions. Join the exact current
  // cooked versions so a title change does not silently remove repeat consent.
  const {rows}=await ctx.db.query<{candidate_id:string}>(`SELECT DISTINCT f.candidate_id
    FROM ritc.meal_recovery_fallback f JOIN ritc.meal_recovery_revision r USING(household_id,operation_id)
    WHERE f.household_id=$1 AND r.shop_id=$2 AND r.new_revision_id=ANY($3::uuid[]) AND r.current_meal IS NOT NULL`,
    [ctx.householdId,shop.shop_id,state.basis.meals.map(m=>m.revisionId)]);
  return new Set(rows.map(r=>r.candidate_id));
}

export function fallbackDecision(state:State,chosen:Set<string>,target:RecoveryMeal,c:AcceptedFallback,s:FallbackSelection,
  asOf:string,reviewedAt:string,submitted?:RecoveryIntent) {
  const revisionId=reviewedID(target.revisionId,'fallback',c.candidateId,c.revision);
  // A shelf count, price and availability were reviewed together. Refresh the
  // real offer before a delayed preview or apply can use it for a second trip.
  if(submitted?.proposesExtraTrip && Date.parse(asOf)-Date.parse(reviewedAt)>10*60_000) return null;
  const next=replacement(state,target,c,s,revisionId);
  if(!next) return null;
  const intent:RecoveryIntent={occurrenceId:target.occurrenceId,targetDigest:recoveryDigest(target),replacement:next,reviewedAt,
    repeatOfOccurrenceId:null,agreesToRepeat:submitted?.agreesToRepeat??false,proposesExtraTrip:submitted?.proposesExtraTrip??false,
    agreesToExtraTrip:submitted?.agreesToExtraTrip??false,acceptsUnresolved:submitted?.acceptsUnresolved??false,fallback:s};
  if(!recoveryIntentSchema.safeParse(intent).success || submitted && !same(intent,submitted)) return null;
  const decide=()=>state.verifyReplacementCoverage(previewRecovery(state.basis,{v:1,base:state.basis.base,intent},asOf));
  let decision=decide();
  const estimateResult=estimate(state,decision,s,asOf);
  if(!estimateResult) return null;
  const trip=estimateResult.kind==='topUp';
  if(submitted && submitted.proposesExtraTrip!==trip) return null;
  if(trip!==intent.proposesExtraTrip) {intent.proposesExtraTrip=trip;decision=decide();}
  const repeatRequired=chosen.has(c.candidateId) || state.basis.meals.some(m=>normal(m.title)===normal(c.recipe.title));
  decision.repeatRequired=repeatRequired;
  decision.consentSatisfied=decision.consentSatisfied && (!repeatRequired || intent.agreesToRepeat);
  decision.previewDigest=recoveryDigest({decision:decision.previewDigest,repeatRequired,consentSatisfied:decision.consentSatisfied,estimate:estimateResult});
  return {decision,option:{candidateId:c.candidateId,revision:c.revision,title:c.recipe.title,...estimateResult,repeatRequired,intent,after:{demands:decision.after.demands,allocations:decision.after.allocations}}};
}

export async function rankSharedFallbacks(ctx:Context,shop:Shop,input:unknown,load:RecoveryPublicationLoader) {
  requirePlaced(shop);
  const request=fallbackOptionsSchema.parse(input);
  if(unique(request.reviews.map(r=>r.candidateId)).length!==request.reviews.length) throw invalid();
  const state=await loadSharedRecoveryDecisionBasis(ctx,shop,load);
  const target=state.basis.meals.find(m=>m.occurrenceId===request.occurrenceId);
  if(!same(request.base,state.basis.base) || !target || request.targetDigest!==recoveryDigest(target)) throw refresh();
  const {rows:[household]}=await ctx.db.query<{fallback_revision:number}>(
    'SELECT fallback_revision FROM ritc.household WHERE household_id=$1',[ctx.householdId]);
  const registryRevision=household!.fallback_revision;
  const library=new Map((await loadAcceptedFallbacks(ctx,request.reviews.map(r=>r.candidateId))).map(c=>[c.candidateId,c]));
  const chosen=await chosenFallbacks(ctx,shop,state);
  const asOf=ctx.now.toISOString(),options=[];
  const conditional:({candidateId:string,revision:number,reason:Reason}&Totals)[]=[];
  const head={shopId:shop.shop_id,base:state.basis.base,asOf,target,registryRevision};
  const capacity=1_800_000;
  let bytes=Buffer.byteLength(JSON.stringify(head))+128, nextReviewIndex:number|null=null;
  const oversized=()=>new ServiceError(413,'fallback_option_too_large','Review fewer meal requirements or continue with a manual repair.');
  if(bytes>capacity) throw oversized();
  for(const [index,review] of request.reviews.entries()) {
    const c=library.get(review.candidateId);
    if(!c || c.revision!==review.revision) throw refresh();
    try {
      const result=fallbackDecision(state,chosen,target,c,{review,trip:request.trip},asOf,asOf);
      if(result) options.push(result.option);
      else conditional.push({candidateId:c.candidateId,revision:c.revision,reason:'foodUnconfirmed'});
    } catch(error) {
      if(!(error instanceof RecoveryError || error instanceof FallbackConstraint)) throw error;
      const reason=error instanceof FallbackConstraint?error.reason:
        ['steals_food','changes_reservation','protected_need','pinned_target','changes_unrelated_issues'].includes(error.code)?'protectedCommitment':'foodUnconfirmed';
      conditional.push({candidateId:c.candidateId,revision:c.revision,reason,...error instanceof FallbackConstraint?error.totals:{}});
    }
    const matches=options.at(-1)?.candidateId===c.candidateId?options:conditional;
    bytes+=Buffer.byteLength(JSON.stringify(matches.at(-1)))+1;
    if(bytes>capacity) {
      if(index===0) throw oversized();
      matches.pop();
      nextReviewIndex=index;
      break;
    }
  }
  const usual=options.filter(o=>library.get(o.candidateId)?.usual).map(o=>o.minutes);
  options.sort((a,b)=>a.packCount-b.packCount || a.extraCashMinor-b.extraCashMinor || a.minutes-b.minutes || a.candidateId.localeCompare(b.candidateId));
  return {...head,options,conditional,nextReviewIndex,usualMinutes:usual.length?Math.min(...usual):null};
}
