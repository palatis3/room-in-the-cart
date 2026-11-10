/** Meal compensation. Historical facts and first-use evidence are never client input. */
import {validateMealCreationHistory,recordCreatedMealUndoEffect,loadCreatedMealUndoRecord,type MealCreationProof} from './shared-food-meal-creation-undo.js';
import {digest} from './database.js';
import {ServiceError} from './errors.js';
import {sharedMealSchema,preserveProtectedMeal,type SharedMealValue} from './shared-meal-planning.js';
import type {Context,Shop} from './repository.js';

type MealRow={householdId:string;shopId:string;occurrenceId:string;revision:number;actorId:string;meal:unknown};
type ProposalKind='change'|'move';
type ProposalProof={kind:ProposalKind;proposalId:string;digest:string;applied:boolean;actorId:string};
export type MealUndoLineage={householdId:string;shopId:string;operationId:string;occurrenceId:string;
 beforeRevision:number|null;afterRevision:number;beforeDigest:string;afterDigest:string;
 proposalKind:ProposalKind|null;proposalId:string|null;proposalDigest:string|null};
export type MealUndoEvidence={lineage:MealUndoLineage;before:MealRow|null;after:MealRow|null;latest:MealRow|null;
 proposal:ProposalProof|null;authorsLive:boolean;creation?:MealCreationProof};
const fail=(reason='meal_history_unavailable')=>new ServiceError(409,'food_undo_'+reason,'Review a current meal correction. This meal change cannot be undone.');
function requireThat(value:unknown,reason?:string):asserts value{if(!value)throw fail(reason);}
const eq=(a:unknown,b:unknown)=>digest(a)===digest(b);
const fields=['title','day','kind','portions','protected','planning'] as const;
type Ref={occurrenceId:string;revision:number};
type Scope={householdId:string;shopId:string;operationId:string;baseShopRevision:number;resultShopRevision:number};
function parsed(row:MealRow,scope:Scope,occurrence:string):SharedMealValue|null {
 requireThat(row.householdId===scope.householdId&&row.shopId===scope.shopId&&row.occurrenceId===occurrence
  &&Number.isSafeInteger(row.revision)&&row.revision>0);
 if(row.meal===null)return null;
 const value=sharedMealSchema.safeParse(row.meal);requireThat(value.success&&eq(value.data,row.meal));
 return value.data;
}
/** Also used during exact replay: erased historical meal/proposal facts remain fatal. */
export function validateMealUndoHistory(e:MealUndoEvidence,scope:Scope,beforeRefs:Ref[],afterRefs:Ref[]){
 const l=e.lineage;
 if(l.beforeRevision===null)return validateMealCreationHistory(e,scope,beforeRefs,afterRefs);
 requireThat(e.creation===undefined);
 requireThat(l.householdId===scope.householdId&&l.shopId===scope.shopId&&l.operationId===scope.operationId
  &&l.beforeRevision<=scope.baseShopRevision&&l.afterRevision===scope.resultShopRevision&&e.authorsLive);
 requireThat(e.before&&e.after&&e.before.revision===l.beforeRevision&&e.after.revision===l.afterRevision
  &&digest(e.before)===l.beforeDigest&&digest(e.after)===l.afterDigest);
 const before=parsed(e.before,scope,l.occurrenceId),after=parsed(e.after,scope,l.occurrenceId);
 requireThat(before!==null,'meal_creation_unsupported');
 const br=beforeRefs.find(r=>r.occurrenceId===l.occurrenceId),ar=afterRefs.find(r=>r.occurrenceId===l.occurrenceId);
 requireThat(br?.revision===l.beforeRevision&&(after===null?ar===undefined:ar?.revision===l.afterRevision));
 const untouched=(refs:Ref[])=>refs.filter(r=>r.occurrenceId!==l.occurrenceId).sort((a,b)=>a.occurrenceId.localeCompare(b.occurrenceId));
 requireThat(new Set(beforeRefs.map(r=>r.occurrenceId)).size===beforeRefs.length
  &&new Set(afterRefs.map(r=>r.occurrenceId)).size===afterRefs.length&&eq(untouched(beforeRefs),untouched(afterRefs)));
 if(l.proposalId===null)requireThat(l.proposalKind===null&&l.proposalDigest===null&&e.proposal===null);
 else requireThat(e.proposal&&e.proposal.applied&&e.proposal.proposalId===l.proposalId
  &&e.proposal.kind===l.proposalKind&&e.proposal.digest===l.proposalDigest);
 return {before,after};
}
export function deriveMealUndo(e:MealUndoEvidence,scope:Scope,beforeRefs:Ref[],afterRefs:Ref[],currentShopRevision:number){
 const {before,after}=validateMealUndoHistory(e,scope,beforeRefs,afterRefs),l=e.lineage;
 requireThat(e.latest&&e.latest.revision>=l.afterRevision&&e.latest.revision<=currentShopRevision,'meal_conflict');
 if(e.latest.revision===l.afterRevision)requireThat(eq(e.latest,e.after));
 const current=parsed(e.latest,scope,l.occurrenceId);
 let restored:SharedMealValue|null;let touched:string[];
 if(before===null){
  // Membership is atomic: even a later identical edit or tombstone is a conflict.
  requireThat(after!==null&&current!==null&&e.latest.revision===l.afterRevision&&eq(e.latest,e.after),'meal_conflict');
  restored=null;touched=['membership'];
 }else if(after===null){
  // Absence in the active list is insufficient: remove/recreate/remove is a conflict.
  requireThat(current===null&&e.latest.revision===l.afterRevision,'meal_conflict');
  restored=structuredClone(before);touched=['membership'];
 }else{
  requireThat(current!==null,'meal_conflict');
  restored=structuredClone(current);touched=fields.filter(key=>!eq(before[key]??null,after[key]??null));
  for(const key of touched as (typeof fields[number])[]){
   requireThat(eq(current[key]??null,after[key]??null),'meal_conflict');
   if(key==='planning'&&before.planning===undefined)delete restored.planning;
   else Object.assign(restored,{[key]:structuredClone(before[key])});
  }
 }
 requireThat(touched.length>0,'no_effect');
 if(restored!==null){const candidate=sharedMealSchema.safeParse(restored);requireThat(candidate.success&&eq(candidate.data,restored),'meal_conflict');}
 // Planning is one atomic quantity/identity/deadline basis. Never splice groups,
 // bindings or exclusions from two independently valid revisions.
 try{preserveProtectedMeal(current??undefined,restored);}
 catch(error){if(error instanceof ServiceError&&error.code==='protected_meal')throw fail('meal_protected');throw error;}
 return {occurrenceId:l.occurrenceId,targetBefore:{revision:l.beforeRevision,meal:before},
  targetAfter:{revision:l.afterRevision,meal:after},current:{revision:e.latest.revision,meal:current},
  restoredMeal:restored,touchedFields:touched,proposal:l.proposalId===null?null:{kind:l.proposalKind!,proposalId:l.proposalId}};
}
const row=(r:any):MealRow=>({householdId:r.household_id,shopId:r.shop_id,occurrenceId:r.occurrence_id,
 revision:r.revision,actorId:r.actor_id,meal:r.meal});
async function readProposal(ctx:Context,shopId:string,kind:ProposalKind,id:string):Promise<ProposalProof|null>{
 const table=kind==='change'?'shared_meal_change':'meal_move';
 const columns=kind==='move'?'*,proposed_day::text AS proposed_day':'*';
 const r=(await ctx.db.query('SELECT '+columns+' FROM ritc.'+table+' WHERE household_id=$1 AND shop_id=$2 AND proposal_id=$3',[ctx.householdId,shopId,id])).rows[0];
 if(!r)return null;
 // State changes pending -> applied inside the original transaction. Bind all
 // other stored facts; a new Undo never consumes the proposal again.
 const {state,...facts}=r;
 return {kind,proposalId:id,digest:digest(JSON.parse(JSON.stringify(facts))),applied:state==='applied',actorId:r.actor_id};
}
export async function recordMealUndoEffect(ctx:Context,shop:Shop,operationId:string,edit:any){
 if(!edit)return;
 if(edit.baseMealRevision===null){await recordCreatedMealUndoEffect(ctx,shop,operationId,edit);return;}
 const old=(await ctx.db.query('SELECT * FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 ORDER BY revision DESC LIMIT 1',
  [ctx.householdId,shop.shop_id,edit.occurrenceId])).rows[0];
 requireThat(old&&old.revision===edit.baseMealRevision&&old.meal!==null);
 const before=row(old),after:MealRow={householdId:ctx.householdId,shopId:shop.shop_id,occurrenceId:edit.occurrenceId,
  revision:shop.revision+1,actorId:ctx.member.member_id,meal:edit.meal};
 const kind:ProposalKind|null=edit.changeProposalId?'change':edit.proposalId?'move':null;
 const proposalId:string|null=edit.changeProposalId??edit.proposalId??null;
 const proof=kind&&proposalId?await readProposal(ctx,shop.shop_id,kind,proposalId):null;
 requireThat(proposalId===null||proof);
 await ctx.db.query(`INSERT INTO ritc.shared_food_meal_effect(household_id,shop_id,operation_id,occurrence_id,
  before_meal_revision,result_meal_revision,before_meal_digest,result_meal_digest,proposal_kind,proposal_id,proposal_digest)
  VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
  [ctx.householdId,shop.shop_id,operationId,edit.occurrenceId,before.revision,after.revision,digest(before),digest(after),kind,proposalId,proof?.digest??null]);
}
export async function loadMealUndoEvidence(ctx:Context,shop:Shop,operationId:string):Promise<MealUndoEvidence|null>{
 let r=(await ctx.db.query('SELECT * FROM ritc.shared_food_meal_effect WHERE household_id=$1 AND shop_id=$2 AND operation_id=$3',
  [ctx.householdId,shop.shop_id,operationId])).rows[0];
 if(!r)r=await loadCreatedMealUndoRecord(ctx,shop,operationId);
 if(!r)return null;
 const lineage:MealUndoLineage={householdId:r.household_id,shopId:r.shop_id,operationId:r.operation_id,occurrenceId:r.occurrence_id,
  beforeRevision:r.before_meal_revision,afterRevision:r.result_meal_revision,beforeDigest:r.before_meal_digest,afterDigest:r.result_meal_digest,
  proposalKind:r.proposal_kind,proposalId:r.proposal_id,proposalDigest:r.proposal_digest};
 const rows=(await ctx.db.query(`SELECT * FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3
  AND (revision=ANY($4::integer[]) OR revision=(SELECT max(revision) FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3))`,
  [ctx.householdId,shop.shop_id,lineage.occurrenceId,[lineage.beforeRevision,lineage.afterRevision]])).rows.map(row);
 const before=rows.find(x=>x.revision===lineage.beforeRevision)??null,after=rows.find(x=>x.revision===lineage.afterRevision)??null;
 const latest=rows.reduce<MealRow|null>((a,b)=>!a||b.revision>a.revision?b:a,null);
 const proposal=lineage.proposalKind&&lineage.proposalId?await readProposal(ctx,shop.shop_id,lineage.proposalKind,lineage.proposalId):null;
 const origins=(await ctx.db.query(`SELECT actor_id FROM ritc.shared_meal_revision WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3
  UNION SELECT actor_id FROM ritc.shared_meal_change WHERE household_id=$1 AND shop_id=$2 AND occurrence_id=$3 AND state='applied'`,
  [ctx.householdId,shop.shop_id,lineage.occurrenceId])).rows;
 const authors=[...new Set([...origins.map(x=>x.actor_id as string),...(proposal?[proposal.actorId]:[])])];
 const live=(await ctx.db.query("SELECT member_id FROM ritc.member WHERE household_id=$1 AND member_id=ANY($2::uuid[]) AND state='active' AND kind='adult'",
  [ctx.householdId,authors])).rows;
 return {lineage,before,after,latest,proposal,authorsLive:authors.length>0&&live.length===authors.length,...(r.creation?{creation:r.creation}:{})};
}
