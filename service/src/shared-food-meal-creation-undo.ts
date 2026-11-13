/** Pure creation-history validator. The repository must load both immutable
 * acceptance and first-use records; absence of meal rows is never this proof. */
import {z} from 'zod';
import {digest} from './database.js';
import {ServiceError} from './errors.js';
import {sharedMealSchema} from './shared-meal-planning.js';
import type {MealUndoEvidence} from './shared-food-meal-undo.js';
const id=z.string().uuid(),revision=z.number().int().positive();
const identity=z.object({householdId:id,shopId:id,occurrenceId:id,operationId:id,resultShopRevision:revision}).strict();
export const mealCreationProofSchema=z.object({
 acceptance:identity.extend({baseShopRevision:revision,absenceDigest:z.string().regex(/^[0-9a-f]{64}$/)}).strict(),
 firstUse:identity
}).strict();
export type MealCreationProof=z.infer<typeof mealCreationProofSchema>;
type Scope={householdId:string;shopId:string;operationId:string;baseShopRevision:number;resultShopRevision:number};
type Ref={occurrenceId:string;revision:number};
const eq=(a:unknown,b:unknown)=>digest(a)===digest(b);
function insist(value:unknown):asserts value{if(!value)throw new ServiceError(409,'food_undo_meal_history_unavailable','Review current meal history. Creation evidence is unavailable.');}
export function mealCreationAbsence(scope:Scope,occurrenceId:string){return {kind:'neverUsedMealOccurrence' as const,
 householdId:scope.householdId,shopId:scope.shopId,operationId:scope.operationId,occurrenceId,baseShopRevision:scope.baseShopRevision};}
export function validateMealCreationHistory(e:MealUndoEvidence,scope:Scope,beforeRefs:Ref[],afterRefs:Ref[]){
 const l=e.lineage,proof=mealCreationProofSchema.safeParse(e.creation);insist(proof.success);
 const expected={householdId:scope.householdId,shopId:scope.shopId,occurrenceId:l.occurrenceId,
  operationId:scope.operationId,resultShopRevision:scope.resultShopRevision};
 const absence=digest(mealCreationAbsence(scope,l.occurrenceId));
 insist(eq(proof.data.firstUse,expected)&&eq(proof.data.acceptance,{...expected,baseShopRevision:scope.baseShopRevision,absenceDigest:absence}));
 insist(e.authorsLive&&l.householdId===scope.householdId&&l.shopId===scope.shopId&&l.operationId===scope.operationId
  &&scope.resultShopRevision===scope.baseShopRevision+1&&l.beforeRevision===null&&e.before===null
  &&l.beforeDigest===absence&&l.afterRevision===scope.resultShopRevision);
 // New creation has no accepted change/move proposal; do not consume or invent one.
 insist(l.proposalKind===null&&l.proposalId===null&&l.proposalDigest===null&&e.proposal===null);
 const row=e.after;insist(row&&row.householdId===scope.householdId&&row.shopId===scope.shopId
  &&row.occurrenceId===l.occurrenceId&&row.revision===l.afterRevision&&digest(row)===l.afterDigest&&row.meal!==null);
 const meal=sharedMealSchema.safeParse(row.meal);insist(meal.success&&eq(meal.data,row.meal));
 insist(!beforeRefs.some(r=>r.occurrenceId===l.occurrenceId)&&afterRefs.find(r=>r.occurrenceId===l.occurrenceId)?.revision===l.afterRevision);
 const untouched=(refs:Ref[])=>refs.filter(r=>r.occurrenceId!==l.occurrenceId).sort((a,b)=>a.occurrenceId.localeCompare(b.occurrenceId));
 insist(new Set(beforeRefs.map(r=>r.occurrenceId)).size===beforeRefs.length&&new Set(afterRefs.map(r=>r.occurrenceId)).size===afterRefs.length
  &&eq(untouched(beforeRefs),untouched(afterRefs)));
 return {before:null,after:meal.data};
}

import type {Context,Shop} from './repository.js';
/** Called under the existing household/shop transaction lock, before inserting
 * the new meal revision. Older/recreated identities stay valid edits but do not
 * acquire creation-Undo eligibility. The identity ledger is never erased. */
export async function recordCreatedMealUndoEffect(ctx:Context,shop:Shop,operationId:string,edit:any){
 if(edit?.baseMealRevision!==null||edit.meal==null||edit.proposalId||edit.changeProposalId)return;
 const reserved=(await ctx.db.query(`INSERT INTO ritc.shared_meal_occurrence_identity
  (household_id,shop_id,occurrence_id,first_operation_id,first_shop_revision)
  SELECT $1,$2,$3,$4,$5
  WHERE NOT EXISTS(SELECT 1 FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3)
  AND NOT EXISTS(SELECT 1 FROM ritc.shop_snapshot s,jsonb_array_elements(COALESCE(s.snapshot->'mealRefs','[]')) r
   WHERE s.household_id=$1 AND s.shop_id=$2 AND r->>'occurrenceId'=$3::text)
  ON CONFLICT(household_id,shop_id,occurrence_id) DO NOTHING RETURNING occurrence_id`,
  [ctx.householdId,shop.shop_id,edit.occurrenceId,operationId,shop.revision+1])).rows;
 if(reserved.length===0)return;
 const scope={householdId:ctx.householdId,shopId:shop.shop_id,operationId,baseShopRevision:shop.revision,resultShopRevision:shop.revision+1};
 const after={householdId:ctx.householdId,shopId:shop.shop_id,occurrenceId:edit.occurrenceId,revision:shop.revision+1,actorId:ctx.member.member_id,meal:edit.meal};
 await ctx.db.query(`INSERT INTO ritc.shared_food_meal_creation_effect
  (household_id,shop_id,operation_id,occurrence_id,base_shop_revision,result_meal_revision,absence_digest,result_meal_digest)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[ctx.householdId,shop.shop_id,operationId,edit.occurrenceId,shop.revision,shop.revision+1,
   digest(mealCreationAbsence(scope,edit.occurrenceId)),digest(after)]);
}
/** Separate immutable first-use and acceptance records must both survive.
 * This joins content-free proof, never a fallback copy of erased meal facts. */
export async function loadCreatedMealUndoRecord(ctx:Context,shop:Shop,operationId:string){
 const r=(await ctx.db.query(`SELECT e.*,i.first_operation_id,i.first_shop_revision
  FROM ritc.shared_food_meal_creation_effect e JOIN ritc.shared_meal_occurrence_identity i
   ON (i.household_id,i.shop_id,i.occurrence_id)=(e.household_id,e.shop_id,e.occurrence_id)
  WHERE e.household_id=$1 AND e.shop_id=$2 AND e.operation_id=$3`,[ctx.householdId,shop.shop_id,operationId])).rows[0];
 if(!r)return null;
 const acceptance={householdId:r.household_id,shopId:r.shop_id,occurrenceId:r.occurrence_id,operationId:r.operation_id,
  baseShopRevision:r.base_shop_revision,resultShopRevision:r.result_meal_revision,absenceDigest:r.absence_digest};
 const firstUse={householdId:r.household_id,shopId:r.shop_id,occurrenceId:r.occurrence_id,operationId:r.first_operation_id,resultShopRevision:r.first_shop_revision};
 return {...r,before_meal_revision:null,before_meal_digest:r.absence_digest,proposal_kind:null,proposal_id:null,proposal_digest:null,
  creation:{acceptance,firstUse}};
}
