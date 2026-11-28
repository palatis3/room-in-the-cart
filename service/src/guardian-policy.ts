import {z} from 'zod';
import type {GuardianChildCountry} from '../../shared/contracts/guardian-enrollment-v1.js';

const usStateAndDistrictCodes = new Set([
  'AK', 'AL', 'AR', 'AZ', 'CA', 'CO', 'CT', 'DC', 'DE', 'FL', 'GA', 'HI', 'IA',
  'ID', 'IL', 'IN', 'KS', 'KY', 'LA', 'MA', 'MD', 'ME', 'MI', 'MN', 'MO', 'MS',
  'MT', 'NC', 'ND', 'NE', 'NH', 'NJ', 'NM', 'NV', 'NY', 'OH', 'OK', 'OR', 'PA',
  'RI', 'SC', 'SD', 'TN', 'TX', 'UT', 'VA', 'VT', 'WA', 'WI', 'WV', 'WY',
]);

export function guardianChildCountry(location: string): GuardianChildCountry | null {
  if (location === 'US' || location === 'MX') return location;
  if (location.startsWith('US-') && usStateAndDistrictCodes.has(location.slice(3))) return 'US';
  return null;
}

export interface GuardianRetentionPolicy {pendingHours:number;evidenceDays:number;approvalReference:string}
export function guardianRetentionPolicy(environment:NodeJS.ProcessEnv):GuardianRetentionPolicy|undefined{
 const {GUARDIAN_PENDING_RETENTION_HOURS:pending,GUARDIAN_EVIDENCE_RETENTION_DAYS:evidence,GUARDIAN_RETENTION_APPROVAL_REFERENCE:approval}=environment;
 if(!pending&&!evidence&&!approval)return undefined;
 return{pendingHours:z.coerce.number().int().min(1).max(8760).parse(pending),evidenceDays:z.coerce.number().int().min(1).max(3650).parse(evidence),approvalReference:z.string().trim().min(1).max(200).parse(approval)};
}
