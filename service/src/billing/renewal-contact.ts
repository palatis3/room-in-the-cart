import {randomUUID,createHash} from 'node:crypto';
import {z} from 'zod';
import type {VerifiedIdentity} from '../auth.js';
import type {Context} from '../repository.js';
import type {VerifiedSubscription} from './domain.js';
import type {RenewalConfig} from './renewal-provider.js';
import {ServiceError} from '../errors.js';

export interface NoticeContactState {scope:'unavailable'|'prospective'|'bound';emailVerified:boolean;enabled:boolean;dispatchEnabled:boolean;sandboxOnly?:boolean}
const unavailable:NoticeContactState={scope:'unavailable',emailVerified:false,enabled:false,dispatchEnabled:false};
export const contactChange=z.object({enabled:z.boolean()}).strict();
export const noNoticeRoute=()=>new ServiceError(409,'renewal_notice_unavailable','Keep using Free or manage your existing subscription in Apple settings.');
export async function renewalContact(ctx:Context,identity:VerifiedIdentity,config:RenewalConfig,sandbox:boolean,change?:boolean):Promise<NoticeContactState> {
  const key=[ctx.householdId,ctx.member.member_id];
  const sandboxOnly=sandbox&&config.sandboxHomes.has(ctx.householdId.toLowerCase());
  if(ctx.member.kind!=='adult'||ctx.ownRequestsOnly||ctx.viewGrantId)return unavailable;
  // Withdrawal always remains available, including after configuration changes.
  if(change===false)await ctx.db.query('DELETE FROM ritc.renewal_contact WHERE household_id=$1 AND purchaser_id=$2',key);
  if((sandbox&&!sandboxOnly)||(config.mode==='off'&&!sandboxOnly))return unavailable;
  const row=(await ctx.db.query<{purchaser_id:string;subscription:VerifiedSubscription}>(
    'SELECT purchaser_id,subscription FROM ritc.billing_state WHERE household_id=$1',[ctx.householdId])).rows[0];
  if(row&&(row.purchaser_id!==ctx.member.member_id||row.subscription.environment!==(sandboxOnly?'Sandbox':'Production')||!row.subscription.mxAnnual||row.subscription.status!=='active'||row.subscription.expiresAt<=ctx.now.getTime()))return unavailable;
  const {rows:[user]}=await ctx.db.query<{address:string|null}>(
    'SELECT ritc.guardian_confirmed_email($1,$2,$3,$4,$5,$6) AS address',[...key,ctx.deviceId,identity.issuer,identity.subject,identity.sessionId]);
  const email=user?.address?.trim();
  const entry=(await ctx.db.query<{id:string;address_digest:Buffer;original_id:string|null;sandbox_only:boolean;live:boolean}>(
    `SELECT id,address_digest,original_id,sandbox_only,original_id IS NOT NULL OR enrolled_at>now()-interval '30 days' AS live
      FROM ritc.renewal_contact WHERE household_id=$1 AND purchaser_id=$2 FOR UPDATE`,key)).rows[0];
  const digest=(id:string)=>createHash('sha256').update(id+'\n'+email!.toLowerCase()).digest();
  let enabled=Boolean(email&&entry?.live&&entry.sandbox_only===sandboxOnly&&entry.address_digest.equals(digest(entry.id))&&(!row||sandboxOnly||entry.original_id===row.subscription.originalTransactionID));
  if(change===true&&!enabled){
    if(!email)throw noNoticeRoute();
    await ctx.db.query('DELETE FROM ritc.renewal_contact WHERE household_id=$1 AND purchaser_id=$2',key);
    const id=randomUUID();
    await ctx.db.query('INSERT INTO ritc.renewal_contact(household_id,purchaser_id,id,address_digest,original_id,sandbox_only) VALUES($1,$2,$3,$4,$5,$6)',
      [...key,id,digest(id),sandboxOnly?null:row?.subscription.originalTransactionID??null,sandboxOnly]);
    enabled=true;
  }
  let ready=false;
  if(config.provider&&!sandboxOnly){try{ready=await config.provider.ready(AbortSignal.timeout(2500));}catch{ready=false;}}
  return {scope:row?'bound':'prospective',emailVerified:Boolean(email),enabled,dispatchEnabled:ready,...(sandboxOnly?{sandboxOnly:true}:{})};
}
