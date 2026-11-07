import {chosenFallbacks,fallbackDecision,FallbackConstraint,requireAssistance} from './shared-fallback-options.js';
import {loadAcceptedFallbacks,linkAcceptedFallback} from './shared-fallback-registry.js';
import type {BillingService} from './billing/service.js';
import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import {requirePlaced} from './delivery-evidence.js';
import {ServiceError, refresh, unavailable} from './errors.js';
import {linkedComponent} from './pantry-lots.js';
import {recoveryMealSchema, recoveryPreviewSchema, type RecoveryMeal,type RecoveryNeed} from './recovery-contracts.js';
import {previewRecovery, recoveryDigest, RecoveryError} from './recovery-domain.js';
import type {Context,Shop} from './repository.js';
import {loadSharedRecoveryDecisionBasis,readSharedRecoveryContext,type SharedRecoveryPublication} from './shared-recovery-basis.js';

import {recoveryApplyBody} from './contracts.js';

interface PublicationRow {
  occurrence_id:string; previous_revision_id:string; new_revision_id:string;
  current_meal:RecoveryMeal|null; need_ids:string[];
}

// Every call receives the authenticated repository transaction. Foreign-shop
// heads are internal to the allocator and are never a response projection.
export async function loadRecoveryPublication(ctx:Context,shopId:string):Promise<SharedRecoveryPublication> {
  const scope=[ctx.householdId,shopId];
  const shop=(await ctx.db.query('SELECT recovery_revision FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',scope)).rows[0];
  if(!shop) throw unavailable();
  const {rows}=await ctx.db.query<PublicationRow>(`SELECT occurrence_id,previous_revision_id,new_revision_id,current_meal,need_ids
    FROM ritc.meal_recovery_revision WHERE household_id=$1 AND shop_id=$2 ORDER BY recovery_revision`,scope);
  const heads=new Map<string,RecoveryMeal|null>();
  const usedNeedIds=new Set<string>(),usedRevisionIds=new Set<string>();
  for(const row of rows) {
    heads.set(row.occurrence_id,row.current_meal===null ? null : recoveryMealSchema.parse(row.current_meal));
    usedRevisionIds.add(row.previous_revision_id);
    usedRevisionIds.add(row.new_revision_id);
    for(const id of row.need_ids) usedNeedIds.add(id);
  }
  const meals:RecoveryMeal[]=[],removedOccurrences:string[]=[];
  for(const [occurrenceId,head] of heads) {
    if(head===null) removedOccurrences.push(occurrenceId);
    else meals.push(head);
  }
  return {recoveryRevision:shop.recovery_revision,contextRevision:shop.recovery_revision,meals,
    removedOccurrences,usedNeedIds:[...usedNeedIds],usedRevisionIds:[...usedRevisionIds]};
}

export async function readRecoveryDesk(ctx:Context,shop:Shop) {
  requirePlaced(shop,true);
  const desk=await readSharedRecoveryContext(ctx,shop,loadRecoveryPublication);
  const targetDigests=desk.meals.map(meal=>({occurrenceId:meal.occurrenceId,digest:recoveryDigest(meal)}));
  return {...desk,targetDigests};
}

function normalizeTitle(value:string) {return value.trim().replace(/\s+/gu,' ').toLocaleLowerCase('en-US');}
function needGroups(need:RecoveryNeed):string[] {return need.groupId ? [need.groupId] : need.groupIds??[];}

// A repeat names a real reviewed occurrence. Fresh IDs and fresh stock matches
// are expected, while its recipe, quantities and relevant serving groups survive.
function validateRepeat(donor:RecoveryMeal|undefined,target:RecoveryMeal) {
  const invalidRepeat=()=>new ServiceError(409,'repeat_changed','Choose the current dinner again or review the recipe as a manual replacement.');
  if(!donor || donor.occurrenceId===target.occurrenceId || donor.portions!==target.portions ||
    donor.title!==target.title || donor.sourceURL!==target.sourceURL || donor.notes!==target.notes ||
    donor.requiredLeadMinutes!==target.requiredLeadMinutes || donor.exclusions.some(tag=>!target.exclusions.includes(tag))) throw invalidRepeat();
  const from=donor.groups.filter(g=>!g.protected),to=target.groups.filter(g=>!g.protected);
  if(from.length!==to.length) throw invalidRepeat();
  const mapping=new Map<string,string>(),used=new Set<string>();
  for(const group of from) {
    const matches=to.filter(g=>!used.has(g.id) && (g.id===group.id || g.name===group.name || from.length===1) &&
      BigInt(g.servings.numerator)*BigInt(group.servings.denominator)===BigInt(group.servings.numerator)*BigInt(g.servings.denominator));
    const match=matches.length===1?matches[0]:undefined;
    if(!match) throw invalidRepeat();
    mapping.set(group.id,match.id);used.add(match.id);
  }
  if(donor.needs.some(n=>n.priority==='protected' && needGroups(n).some(id=>mapping.has(id)))) throw invalidRepeat();
  const remaining=target.needs.filter(n=>n.priority==='required');
  for(const source of donor.needs.filter(n=>n.priority==='required')) {
    const groups=needGroups(source).map(id=>mapping.get(id)).sort();
    if(groups.includes(undefined)) throw invalidRepeat();
    const index=remaining.findIndex(n=>n.name===source.name && n.notes===source.notes &&
      recoveryDigest(n.quantity)===recoveryDigest(source.quantity) && source.exclusions.every(e=>n.exclusions.includes(e)) &&
      recoveryDigest([...needGroups(n)].sort())===recoveryDigest(groups));
    if(index<0) throw invalidRepeat();
    remaining.splice(index,1);
  }
  if(remaining.length) throw invalidRepeat();
}

async function decision(ctx:Context,shop:Shop,request:z.infer<typeof recoveryPreviewSchema>,billing?:BillingService) {
  requirePlaced(shop);
  if(request.intent.fallback) await requireAssistance(ctx,billing);
  const state=await loadSharedRecoveryDecisionBasis(ctx,shop,loadRecoveryPublication);
  const {basis,verifyReplacementCoverage}=state;
  try {
    if(request.intent.fallback) {
      const selection=request.intent.fallback;
      const target=basis.meals.find(m=>m.occurrenceId===request.intent.occurrenceId);
      const candidate=(await loadAcceptedFallbacks(ctx,[selection.review.candidateId])).find(c=>c.candidateId===selection.review.candidateId && c.revision===selection.review.revision);
      if(!target || !candidate || recoveryDigest(basis.base)!==recoveryDigest(request.base)) throw refresh();
      const chosen=await chosenFallbacks(ctx,shop,state);
      const result=fallbackDecision(state,chosen,target,candidate,selection,ctx.now.toISOString(),request.intent.reviewedAt,request.intent);
      if(!result) throw refresh();
      return result.decision;
    }
    const reviewed=verifyReplacementCoverage(previewRecovery(basis,request,ctx.now.toISOString()));
    const intent=reviewed.intent;
    if(intent.repeatOfOccurrenceId) {
      validateRepeat(basis.meals.find(m=>m.occurrenceId===intent.repeatOfOccurrenceId),intent.replacement);
    } else if(basis.meals.some(m=>m.occurrenceId!==intent.occurrenceId && normalizeTitle(m.title)===normalizeTitle(intent.replacement.title))) {
      reviewed.repeatRequired=true;
      reviewed.consentSatisfied=reviewed.consentSatisfied && intent.agreesToRepeat;
      reviewed.previewDigest=recoveryDigest({decision:reviewed.previewDigest,repeatRequired:true,consentSatisfied:reviewed.consentSatisfied});
    }
    return reviewed;
  } catch(error) {
    if(error instanceof FallbackConstraint) throw refresh();
    if(!(error instanceof RecoveryError)) throw error;
    if(error.code==='stale_basis' || error.code==='stale_target') throw refresh();
    throw new ServiceError(409,'meal_recovery_review_required','Review the remaining food, meal timing and protected portions.');
  }
}

type Decision = Awaited<ReturnType<typeof decision>>;
function scopedProjection(projection:Decision['before']) {
  const localNeeds=new Set(projection.meals.flatMap(meal=>meal.needs.map(need=>need.id)));
  return {meals:projection.meals,demands:projection.demands.filter(d=>localNeeds.has(d.needId)),
    allocations:projection.allocations.filter(a=>localNeeds.has(a.needId))};
}

export async function previewSharedRecovery(ctx:Context,shop:Shop,input:unknown,billing?:BillingService) {
  const reviewed=await decision(ctx,shop,recoveryPreviewSchema.parse(input),billing);
  const previewId=randomUUID(),expiresAt=new Date(ctx.now.getTime()+10*60_000);
  await ctx.db.query('DELETE FROM ritc.meal_recovery_preview WHERE household_id=$1 AND expires_at<=$2',[ctx.householdId,ctx.now]);
  await ctx.db.query(`INSERT INTO ritc.meal_recovery_preview(household_id,shop_id,preview_id,actor_id,device_id,digest,expires_at)
    VALUES($1,$2,$3,$4,$5,$6,$7)`,[ctx.householdId,shop.shop_id,previewId,ctx.member.member_id,ctx.deviceId,reviewed.previewDigest,expiresAt]);
  return {shopId:shop.shop_id,placedRevision:shop.placed_revision,asOf:reviewed.asOf,previewId,expiresAt:expiresAt.toISOString(),
    previewDigest:reviewed.previewDigest,base:reviewed.base,before:scopedProjection(reviewed.before),after:scopedProjection(reviewed.after),
    foodConfirmed:reviewed.foodConfirmed,timingConfirmed:reviewed.timingConfirmed,repeatRequired:reviewed.repeatRequired,
    feasible:reviewed.feasible,consentSatisfied:reviewed.consentSatisfied};
}

async function rememberSources(ctx:Context,shop:Shop,operationId:string) {
  const {shops,lots}=await linkedComponent(ctx,shop,null);
  const scope=[ctx.householdId,operationId,[...shops]];
  await ctx.db.query(`INSERT INTO ritc.meal_recovery_source_shop(household_id,operation_id,shop_id)
    SELECT $1,$2,source FROM (
     SELECT unnest($3::uuid[]) AS source
     UNION SELECT s.shop_id FROM ritc.meal_recovery_revision r JOIN ritc.meal_recovery_source_shop s USING(household_id,operation_id)
      WHERE r.household_id=$1 AND r.shop_id=ANY($3::uuid[]) AND r.current_meal IS NOT NULL
    ) origins`,scope);
  await ctx.db.query(`INSERT INTO ritc.meal_recovery_source_member(household_id,operation_id,member_id)
    SELECT $1,$2,actor_id FROM (
     SELECT actor_id FROM ritc.pantry_lot WHERE household_id=$1 AND lot_id=ANY($4::uuid[])
     UNION SELECT actor_id FROM ritc.pantry_event WHERE household_id=$1 AND lot_id=ANY($4::uuid[])
     UNION SELECT actor_id FROM ritc.operation WHERE household_id=$1 AND shop_id=ANY($3::uuid[]) AND kind LIKE 'delivery.%'
     UNION SELECT actor_id FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=ANY($3::uuid[])
     UNION SELECT actor_id FROM ritc.shared_meal_change WHERE household_id=$1 AND shop_id=ANY($3::uuid[]) AND state='applied'
     UNION SELECT actor_id FROM ritc.meal_recovery_revision WHERE household_id=$1 AND shop_id=ANY($3::uuid[]) AND current_meal IS NOT NULL
     UNION SELECT m.member_id FROM ritc.meal_recovery_revision r JOIN ritc.meal_recovery_source_member m USING(household_id,operation_id)
      WHERE r.household_id=$1 AND r.shop_id=ANY($3::uuid[]) AND r.current_meal IS NOT NULL
    ) origins`,[...scope,[...lots]]);
}

export async function recordSharedRecovery(ctx:Context,shop:Shop,input:unknown,operationId:string,billing?:BillingService) {
  const {previewId,previewDigest,...request}=recoveryApplyBody.parse(input);
  const scope=[ctx.householdId,shop.shop_id];
  const stored=await ctx.db.query(`SELECT 1 FROM ritc.meal_recovery_preview
    WHERE household_id=$1 AND shop_id=$2 AND preview_id=$3 AND actor_id=$4 AND device_id=$5 AND digest=$6 AND expires_at>$7`,
    [...scope,previewId,ctx.member.member_id,ctx.deviceId,previewDigest,ctx.now]);
  if(!stored.rowCount) throw refresh();
  const reviewed=await decision(ctx,shop,request,billing);
  if(reviewed.previewDigest!==previewDigest) throw refresh();
  if(!reviewed.consentSatisfied) throw new ServiceError(409,'meal_agreement_required','Review the repeat, extra trip or unresolved meal before applying.');
  const meal=reviewed.intent.replacement;
  const previous=reviewed.before.meals.find(m=>m.occurrenceId===meal.occurrenceId)!;
  const updated=await ctx.db.query(`UPDATE ritc.shop SET recovery_revision=recovery_revision+1,supply_revision=supply_revision+1 WHERE household_id=$1 AND shop_id=$2
    AND recovery_revision=$3 RETURNING recovery_revision`,[...scope,request.base.recoveryRevision]);
  if(!updated.rowCount) throw refresh();
  const recoveryRevision:number=updated.rows[0]!.recovery_revision;
  await ctx.db.query(`INSERT INTO ritc.meal_recovery_revision
    (household_id,shop_id,recovery_revision,operation_id,occurrence_id,source_meal_revision,previous_revision_id,new_revision_id,
     placed_revision,authority_epoch,supply_revision,pantry_revision,actor_id,created_at,current_meal,intent,decision_digest,need_ids)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18)`,
    [...scope,recoveryRevision,operationId,meal.occurrenceId,meal.sourceMealRevision,previous.revisionId,meal.revisionId,
      shop.placed_revision,shop.authority_epoch,shop.supply_revision,reviewed.base.pantryRevision,ctx.member.member_id,ctx.now,
      meal,reviewed.intent,previewDigest,[...new Set([...previous.needs,...meal.needs].map(n=>n.id))]]);
  await rememberSources(ctx,shop,operationId);
  const fallback=reviewed.intent.fallback?.review;
  if(fallback) await linkAcceptedFallback(ctx,operationId,fallback.candidateId,fallback.revision);
  await ctx.db.query('DELETE FROM ritc.meal_recovery_preview WHERE household_id=$1 AND preview_id=$2',[ctx.householdId,previewId]);
  return {recoveryRevision,occurrenceId:meal.occurrenceId,revisionId:meal.revisionId};
}
