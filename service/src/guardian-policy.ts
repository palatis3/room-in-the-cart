import {z} from 'zod';
export interface GuardianRetentionPolicy {pendingHours:number;evidenceDays:number;approvalReference:string}
export function guardianRetentionPolicy(environment:NodeJS.ProcessEnv):GuardianRetentionPolicy|undefined{
 const {GUARDIAN_PENDING_RETENTION_HOURS:pending,GUARDIAN_EVIDENCE_RETENTION_DAYS:evidence,GUARDIAN_RETENTION_APPROVAL_REFERENCE:approval}=environment;
 if(!pending&&!evidence&&!approval)return undefined;
 return{pendingHours:z.coerce.number().int().min(1).max(8760).parse(pending),evidenceDays:z.coerce.number().int().min(1).max(3650).parse(evidence),approvalReference:z.string().trim().min(1).max(200).parse(approval)};
}
