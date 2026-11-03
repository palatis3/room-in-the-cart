import {z} from 'zod';
import type {Context} from './repository.js';
import {ServiceError,unavailable} from './errors.js';
import {uuid} from './contracts.js';
import type {VerifiedIdentity} from './auth.js';

export const deviceRevocationSchema=z.object({memberId:uuid}).strict();

/** Device IDs are opaque management references, never credentials or provider-session IDs. */
export class HouseholdDeviceManagement {
  private async scope(ctx:Context){
    if(ctx.viewGrantId||ctx.member.kind!=='adult')throw unavailable();
    if(ctx.member.organizer)return 'household' as const;
    const guardian=await ctx.db.query(`SELECT 1 FROM ritc.guardian_relationship r
      JOIN ritc.member c ON c.household_id=r.household_id AND c.member_id=r.child_id
      WHERE r.household_id=$1 AND r.guardian_id=$2 AND r.revoked_at IS NULL AND c.kind='child' LIMIT 1`,[ctx.householdId,ctx.member.member_id]);
    if(!guardian.rowCount)throw unavailable();
    return 'guardian_children' as const;
  }
  private predicate=`($2::boolean OR (m.kind='child' AND EXISTS(SELECT 1 FROM ritc.guardian_relationship r
    WHERE r.household_id=m.household_id AND r.child_id=m.member_id AND r.guardian_id=$3 AND r.revoked_at IS NULL)))`;
  async list(ctx:Context,cursor:string|null){
    const scope=await this.scope(ctx),parameters=[ctx.householdId,scope==='household',ctx.member.member_id];
    let after:string|null=null;
    if(cursor){
      after=(await ctx.db.query(`SELECT d.created_at::text AS created_at FROM ritc.device d
        JOIN ritc.member m USING(household_id,member_id) WHERE d.household_id=$1 AND ${this.predicate} AND d.device_id=$4`,[...parameters,cursor])).rows[0]?.created_at;
      if(!after)throw unavailable();
    }
    const rows=(await ctx.db.query(`SELECT d.device_id,d.member_id,d.created_at,d.revoked_at,m.alias,m.kind
      FROM ritc.device d JOIN ritc.member m USING(household_id,member_id)
      WHERE d.household_id=$1 AND ${this.predicate} AND ($4::timestamptz IS NULL OR (d.created_at,d.device_id)>($4,$5::uuid))
      ORDER BY d.created_at,d.device_id LIMIT 101`,[...parameters,after,cursor])).rows;
    return{scope,devices:rows.slice(0,100).map(d=>({deviceId:d.device_id,memberId:d.member_id,memberAlias:d.alias,memberKind:d.kind,
      createdAt:d.created_at.toISOString(),revokedAt:d.revoked_at?.toISOString()??null,isCurrentDevice:d.device_id===ctx.deviceId})),nextCursor:rows.length>100?rows[99].device_id:null};
  }
  async revoke(ctx:Context,identity:VerifiedIdentity,deviceId:string,input:z.infer<typeof deviceRevocationSchema>){
    const scope=await this.scope(ctx);
    const target=(await ctx.db.query(`SELECT d.device_id,d.member_id FROM ritc.device d
      JOIN ritc.member m USING(household_id,member_id) WHERE d.household_id=$1 AND ${this.predicate}
      AND d.device_id=$4 AND d.member_id=$5`,[ctx.householdId,scope==='household',ctx.member.member_id,deviceId,input.memberId])).rows[0];
    if(!target)throw unavailable();
    if(target.device_id===ctx.deviceId)throw new ServiceError(409,'current_device','Use sign out to end access on this device.');
    // The owner-only SQL entry point rechecks exact live actor/device/session,
    // derives the target's enrollment fence and atomically ends its access.
    const row=(await ctx.db.query('SELECT ritc.revoke_household_device($1,$2,$3,$4,$5,$6,$7,$8) AS revoked_at',
      [ctx.householdId,ctx.member.member_id,ctx.deviceId,identity.issuer,identity.subject,identity.sessionId,deviceId,input.memberId])).rows[0];
    if(!row?.revoked_at)throw unavailable();
    return{deviceId,memberId:input.memberId,revoked:true,revokedAt:row.revoked_at.toISOString()};
  }
}
