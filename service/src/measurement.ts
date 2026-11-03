import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import {ServiceError,unavailable} from './errors.js';
import type {Context,HouseholdRepository} from './repository.js';

export const MEASUREMENT_NOTICE_VERSION='pickup-feedback-2026-11-03.v1';
const uuid=z.string().uuid().transform(value=>value.toLowerCase());
export const measurementConsentSchema=z.object({noticeVersion:z.literal(MEASUREMENT_NOTICE_VERSION)}).strict();
export const measurementWithdrawSchema=z.object({consentId:uuid}).strict();
export const measurementFeedbackSchema=z.object({consentId:uuid,noticeVersion:z.literal(MEASUREMENT_NOTICE_VERSION),
 outcome:z.enum(['acted','unchanged','late','unknown','already_knew','wrong']),
 baseline:z.enum(['retailer','list','usualRoutine','unknown']),comparison:z.enum(['same','different','unknown'])}).strict();
export const measurementRemoveSchema=z.object({feedbackId:uuid}).strict();
type Answer=Pick<z.infer<typeof measurementFeedbackSchema>,'outcome'|'baseline'|'comparison'>;
const consentRequired=()=>new ServiceError(409,'measurement_consent_required','Review the current optional measurement notice and choose whether to participate.');
/** Different self-reported outcomes are unverified. A tie, late result, known
 * information or unchanged plan cannot establish incremental benefit. */
export function measurementBenefit(answer:Answer):0|null {
 return answer.comparison==='same'||['late','already_knew','unchanged','wrong'].includes(answer.outcome)?0:null;
}
/** ISO week uses the recorded server closure in UTC, never retry/device time. */
export function eligibleMeasurementWeek(closedAt:Date):string {
 if(!Number.isFinite(closedAt.getTime()))throw unavailable();
 const day=new Date(Date.UTC(closedAt.getUTCFullYear(),closedAt.getUTCMonth(),closedAt.getUTCDate()));
 day.setUTCDate(day.getUTCDate()+4-(day.getUTCDay()||7));
 const year=day.getUTCFullYear(),start=Date.UTC(year,0,1);
 return `${year}-W${String(Math.ceil(((day.getTime()-start)/86400000+1)/7)).padStart(2,'0')}`;
}
/** Every method runs in the repository's authenticated, household-locked transaction.
 * It never reads/imports local records and accepts no grocery text or billing facts. */
export class HouseholdMeasurement {
 constructor(private readonly repo:HouseholdRepository){}
 private adult(ctx:Context){if(ctx.viewGrantId||ctx.member.kind!=='adult'||ctx.member.state!=='active')throw unavailable();}
 async status(ctx:Context){this.adult(ctx);const consent=(await ctx.db.query('SELECT consent_id,notice_version,granted_at FROM ritc.measurement_consent WHERE household_id=$1 AND member_id=$2 AND withdrawn_at IS NULL AND notice_version=$3',[ctx.householdId,ctx.member.member_id,MEASUREMENT_NOTICE_VERSION])).rows[0];return {noticeVersion:MEASUREMENT_NOTICE_VERSION,consent:consent?{consentId:consent.consent_id,noticeVersion:consent.notice_version,grantedAt:consent.granted_at.toISOString()}:null};}
 async consent(ctx:Context,raw:unknown){this.adult(ctx);measurementConsentSchema.parse(raw);
  // A lost reply or second device repeats the same current explicit choice. Only
  // this endpoint creates consent; billing, archives and status reads never do.
  const current=await this.status(ctx);if(current.consent)return current;
  await ctx.db.query('UPDATE ritc.measurement_consent SET withdrawn_at=$3 WHERE household_id=$1 AND member_id=$2 AND withdrawn_at IS NULL',[ctx.householdId,ctx.member.member_id,ctx.now]);
  const consentId=randomUUID();await ctx.db.query('INSERT INTO ritc.measurement_consent(household_id,consent_id,member_id,notice_version,granted_at) VALUES($1,$2,$3,$4,$5)',[ctx.householdId,consentId,ctx.member.member_id,MEASUREMENT_NOTICE_VERSION,ctx.now]);
  return {noticeVersion:MEASUREMENT_NOTICE_VERSION,consent:{consentId,noticeVersion:MEASUREMENT_NOTICE_VERSION,grantedAt:ctx.now.toISOString()}};
 }
 async withdraw(ctx:Context,raw:unknown){this.adult(ctx);const {consentId}=measurementWithdrawSchema.parse(raw);
  const prior=(await ctx.db.query('SELECT consent_id FROM ritc.measurement_consent WHERE household_id=$1 AND member_id=$2 AND consent_id=$3',[ctx.householdId,ctx.member.member_id,consentId])).rows[0];if(!prior)throw unavailable();
  await ctx.db.query('UPDATE ritc.measurement_consent SET withdrawn_at=$4 WHERE household_id=$1 AND member_id=$2 AND consent_id=$3 AND withdrawn_at IS NULL',[ctx.householdId,ctx.member.member_id,consentId,ctx.now]);
  await ctx.db.query('DELETE FROM ritc.measurement_feedback WHERE household_id=$1 AND member_id=$2 AND consent_id=$3',[ctx.householdId,ctx.member.member_id,consentId]);return {withdrawn:true};
 }
 private async eligible(ctx:Context,shopId:string){this.adult(ctx);const shop=await this.repo.shop(ctx,shopId);this.repo.requireShopper(ctx,shop);
  const row=(await ctx.db.query('SELECT measurement_closed_at FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[ctx.householdId,shopId])).rows[0];
  if(shop.phase!=='closed'||shop.placed_revision===null||!row?.measurement_closed_at)throw new ServiceError(409,'measurement_not_eligible','Optional feedback is available after a placed shared pickup is closed.');
  return eligibleMeasurementWeek(row.measurement_closed_at);
 }
 private projection(row:Record<string,any>){return {feedbackId:row.feedback_id,shopId:row.shop_id,eligibleWeek:row.eligible_week,consentVersion:row.consent_version,outcome:row.outcome,baseline:row.baseline,comparison:row.comparison,incrementalBenefit:measurementBenefit(row as Answer),recordedAt:row.recorded_at.toISOString()};}
 async read(ctx:Context,shopId:string){const eligibleWeek=await this.eligible(ctx,shopId);const row=(await ctx.db.query('SELECT * FROM ritc.measurement_feedback WHERE household_id=$1 AND shop_id=$2 AND eligible_week=$3',[ctx.householdId,shopId,eligibleWeek])).rows[0];return {shopId,eligibleWeek,feedback:row?this.projection(row):null};}
 async feedback(ctx:Context,shopId:string,raw:unknown){const input=measurementFeedbackSchema.parse(raw),eligibleWeek=await this.eligible(ctx,shopId);
  const consent=(await ctx.db.query('SELECT 1 FROM ritc.measurement_consent WHERE household_id=$1 AND member_id=$2 AND consent_id=$3 AND notice_version=$4 AND withdrawn_at IS NULL',[ctx.householdId,ctx.member.member_id,input.consentId,input.noticeVersion])).rows[0];if(!consent)throw consentRequired();
  const old=(await ctx.db.query('SELECT * FROM ritc.measurement_feedback WHERE household_id=$1 AND shop_id=$2 AND eligible_week=$3',[ctx.householdId,shopId,eligibleWeek])).rows[0];
  if(old){if(old.member_id!==ctx.member.member_id||old.outcome!==input.outcome||old.baseline!==input.baseline||old.comparison!==input.comparison)throw new ServiceError(409,'measurement_already_recorded','Review or remove the existing response before recording a different response.');return this.projection(old);}
  const row=(await ctx.db.query('INSERT INTO ritc.measurement_feedback(household_id,feedback_id,shop_id,eligible_week,consent_id,member_id,consent_version,outcome,baseline,comparison,recorded_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING *',[ctx.householdId,randomUUID(),shopId,eligibleWeek,input.consentId,ctx.member.member_id,input.noticeVersion,input.outcome,input.baseline,input.comparison,ctx.now])).rows[0];return this.projection(row);
 }
 async removeFeedback(ctx:Context,shopId:string,raw:unknown){const {feedbackId}=measurementRemoveSchema.parse(raw);await this.eligible(ctx,shopId);await ctx.db.query('DELETE FROM ritc.measurement_feedback WHERE household_id=$1 AND shop_id=$2 AND feedback_id=$3 AND member_id=$4',[ctx.householdId,shopId,feedbackId,ctx.member.member_id]);return {removed:true};}
}
