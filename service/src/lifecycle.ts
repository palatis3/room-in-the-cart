import {randomBytes,randomUUID} from 'node:crypto';
import {proposalDTO} from './helper-review.js';
import type {z} from 'zod';
import type {VerifiedIdentity} from './auth.js';
import {HouseholdRepository,type Context} from './repository.js';
import {digest,tokenHash} from './database.js';
import {ServiceError,unavailable,accessEnded} from './errors.js';
import {householdCreateSchema,inviteCreateSchema,inviteRedeemSchema,viewCreateSchema,viewUpdateSchema,proposalSchema,revocationSchema} from './contracts.js';
const consentUnavailable=()=>new ServiceError(503,'consent_unavailable','Child enrollment is unavailable until verified guardian consent is configured.');
export class HouseholdLifecycle {
  constructor(readonly repo:HouseholdRepository){}
  organizer(ctx:Context){if(ctx.member.kind!=='adult'||!ctx.member.organizer)throw unavailable();}
  async create(identity:VerifiedIdentity,input:z.infer<typeof householdCreateSchema>){
    const db=await this.repo.pool.connect();try{
      await db.query('BEGIN');await db.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='3s'");
      const now=(await db.query('SELECT clock_timestamp() AS now')).rows[0].now;
      await this.repo.assertSession(db,identity,now);
      await db.query("SELECT set_config('app.issuer',$1,true),set_config('app.subject',$2,true)",[identity.issuer,identity.subject]);
      await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[identity.issuer+'|'+identity.subject]);
      const prior=(await db.query('SELECT household_id,member_id,payload_digest FROM ritc.household_creation WHERE issuer=$1 AND subject=$2 AND client_key=$3',[identity.issuer,identity.subject,input.clientKey])).rows[0];
      if(prior){
        if(prior.payload_digest!==digest(input))throw new ServiceError(409,'key_reused','Use a fresh key for a changed household.');
        await db.query("SELECT set_config('app.household_id',$1,true)",[prior.household_id]);
        const member=await this.repo.member(db,prior.household_id,identity);if(!member.organizer)throw accessEnded();
        await db.query('COMMIT');return{householdId:prior.household_id,memberId:prior.member_id,role:'organizer' as const};
      }
      // A child identity cannot confer adult privileges by checking an attestation.
      const knownChild=await db.query('SELECT ritc.identity_has_child_profile($1,$2) AS child',[identity.issuer,identity.subject]);
      if(knownChild.rows[0].child)throw consentUnavailable();
      const total=await db.query('SELECT count(*)::integer AS count FROM ritc.household_creation WHERE issuer=$1 AND subject=$2',[identity.issuer,identity.subject]);
      if(total.rows[0].count>=10)throw new ServiceError(429,'household_limit','Use an existing household.');
      const householdId=randomUUID(),memberId=randomUUID();
      await db.query("SELECT set_config('app.household_id',$1,true)",[householdId]);
      await db.query('INSERT INTO ritc.household(household_id,label) VALUES($1,$2)',[householdId,input.label]);
      await db.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute) VALUES($1,$2,$3,$4,$5,'adult','active',true,true)",[householdId,memberId,identity.issuer,identity.subject,input.alias]);
      await db.query('INSERT INTO ritc.household_creation(issuer,subject,client_key,household_id,member_id,payload_digest) VALUES($1,$2,$3,$4,$5,$6)',[identity.issuer,identity.subject,input.clientKey,householdId,memberId,digest(input)]);
      await db.query('COMMIT');return{householdId,memberId,role:'organizer' as const};
    }catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}
  }
  async invite(ctx:Context,input:z.infer<typeof inviteCreateSchema>){
    this.organizer(ctx);if(input.kind==='child_contributor')throw consentUnavailable();
    return this.issue(ctx,input.kind,input.expiresInHours,null);
  }
  async issue(ctx:Context,kind:'adult_contributor'|'helper_read'|'helper_edit',hours:number,grantId:string|null){
    const active=await ctx.db.query('SELECT count(*)::int AS count FROM ritc.invite WHERE household_id=$1 AND revoked_at IS NULL AND redeemed_at IS NULL AND expires_at>$2',[ctx.householdId,ctx.now]);
    if(active.rows[0].count>=100)throw new ServiceError(429,'invite_limit','Revoke an unused invitation before creating another.');
    const inviteId=randomUUID(),secret=randomBytes(32).toString('base64url'),expiresAt=new Date(ctx.now.getTime()+hours*3_600_000);
    await ctx.db.query('INSERT INTO ritc.invite(household_id,invite_id,token_hash,kind,created_by,grant_id,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)',[ctx.householdId,inviteId,tokenHash(secret),kind,ctx.member.member_id,grantId,expiresAt]);
    return{inviteId,token:ctx.householdId+'.'+secret,expiresAt:expiresAt.toISOString()};
  }
  async redeem(identity:VerifiedIdentity,input:z.infer<typeof inviteRedeemSchema>){
    const [householdId,secret]=input.token.split('.');
    return this.repo.transaction(householdId!,async(db,now)=>{
      await this.repo.assertSession(db,identity,now);
      if((await db.query('SELECT ritc.identity_has_child_profile($1,$2) AS child',[identity.issuer,identity.subject])).rows[0].child)throw consentUnavailable();
      const invite=(await db.query(`SELECT i.* FROM ritc.invite i JOIN ritc.member m ON m.household_id=i.household_id AND m.member_id=i.created_by
        WHERE i.household_id=$1 AND i.token_hash=$2 AND i.revoked_at IS NULL AND i.expires_at>$3 AND m.state='active' AND m.kind='adult'`,[householdId,tokenHash(secret!),now])).rows[0];
      if(!invite)throw unavailable();
      let member=(await db.query('SELECT * FROM ritc.member WHERE household_id=$1 AND issuer=$2 AND subject=$3',[householdId,identity.issuer,identity.subject])).rows[0];
      if(member?.kind==='child')throw consentUnavailable();
      if(invite.redeemed_at){
        if(!member||member.state!=='active'||invite.redeemed_by!==member.member_id)throw unavailable();
      }else{
        const memberId=member?.member_id??randomUUID(),contribute=invite.kind==='adult_contributor';
        if(member){
          await db.query("UPDATE ritc.member SET state='active',organizer=CASE WHEN state='active' THEN organizer ELSE false END,can_contribute=$3 OR (state='active' AND can_contribute),alias=COALESCE($4,alias) WHERE household_id=$1 AND member_id=$2",[householdId,memberId,contribute,input.alias??null]);
        }else{
          await db.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute) VALUES($1,$2,$3,$4,$5,'adult','active',false,$6)",[householdId,memberId,identity.issuer,identity.subject,input.alias??'Household member',contribute]);
        }
        member={member_id:memberId};
        await db.query('UPDATE ritc.invite SET redeemed_at=$3,redeemed_by=$4 WHERE household_id=$1 AND invite_id=$2',[householdId,invite.invite_id,now,memberId]);
        if(invite.grant_id)await db.query('UPDATE ritc.view_grant SET recipient_id=$3 WHERE household_id=$1 AND grant_id=$2 AND recipient_id IS NULL',[householdId,invite.grant_id,memberId]);
      }
      if(invite.grant_id){const grant=await db.query('SELECT 1 FROM ritc.view_grant WHERE household_id=$1 AND grant_id=$2 AND recipient_id=$3 AND revoked_at IS NULL AND expires_at>$4',[householdId,invite.grant_id,member.member_id,now]);if(!grant.rowCount)throw accessEnded();}
      return{householdId:householdId!,memberId:member.member_id as string,role:invite.kind==='adult_contributor'?'contributor':invite.kind==='helper_edit'?'editor':'helper',...(invite.grant_id?{grantId:invite.grant_id as string}:{})};
    });
  }
  async members(ctx:Context){
    this.organizer(ctx);
    const rows=(await ctx.db.query('SELECT member_id,alias,kind,state,organizer,can_contribute FROM ritc.member WHERE household_id=$1 ORDER BY alias,member_id LIMIT 200',[ctx.householdId])).rows;
    return{members:rows.map(m=>({memberId:m.member_id,alias:m.alias,kind:m.kind,state:m.state,role:m.organizer?'organizer':m.can_contribute?'contributor':'helper'}))};
  }
  async invites(ctx:Context){
    this.organizer(ctx);
    const rows=(await ctx.db.query('SELECT invite_id,kind,grant_id,expires_at,redeemed_at,revoked_at FROM ritc.invite WHERE household_id=$1 ORDER BY expires_at DESC,invite_id LIMIT 200',[ctx.householdId])).rows;
    return{invites:rows.map(i=>({inviteId:i.invite_id,kind:i.kind,grantId:i.grant_id,expiresAt:i.expires_at.toISOString(),redeemedAt:i.redeemed_at?.toISOString()??null,revokedAt:i.revoked_at?.toISOString()??null,status:i.revoked_at?'revoked':i.expires_at<=ctx.now?'expired':i.redeemed_at?'redeemed':'pending'}))};
  }
  async views(ctx:Context){
    if(ctx.viewGrantId||ctx.member.kind!=='adult')throw unavailable();
    const rows=(await ctx.db.query(`SELECT g.grant_id,g.shop_id,g.mode,g.revision,g.projection->>'shopLabel' AS shop_label,g.expires_at,g.revoked_at,m.alias AS recipient_alias
      FROM ritc.view_grant g JOIN ritc.shop s ON s.household_id=g.household_id AND s.shop_id=g.shop_id LEFT JOIN ritc.member m ON m.household_id=g.household_id AND m.member_id=g.recipient_id
      WHERE g.household_id=$1 AND ($2::boolean OR s.shopper_id=$3) ORDER BY g.expires_at DESC,g.grant_id LIMIT 200`,[ctx.householdId,ctx.member.organizer,ctx.member.member_id])).rows;
    return{views:rows.map(g=>({grantId:g.grant_id,shopId:g.shop_id,mode:g.mode,revision:g.revision,shopLabel:g.shop_label,expiresAt:g.expires_at.toISOString(),revokedAt:g.revoked_at?.toISOString()??null,recipientAlias:g.recipient_alias,status:g.revoked_at?'revoked':g.expires_at<=ctx.now?'expired':g.recipient_alias?'active':'available'}))};
  }
  async createView(ctx:Context,input:z.infer<typeof viewCreateSchema>){
    this.repo.requireShopper(ctx,await this.repo.shop(ctx,input.shopId));
    const grantId=randomUUID(),expiresAt=new Date(ctx.now.getTime()+input.expiresInHours*3_600_000);
    const projection={shopLabel:input.shopLabel,language:input.language,items:input.items};
    await ctx.db.query('INSERT INTO ritc.view_grant(household_id,grant_id,shop_id,created_by,mode,projection,as_of,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',[ctx.householdId,grantId,input.shopId,ctx.member.member_id,input.mode,projection,ctx.now,expiresAt]);
    const invitation=await this.issue(ctx,input.mode==='edit'?'helper_edit':'helper_read',input.expiresInHours,grantId);
    return{grantId,...invitation};
  }
  async grant(ctx:Context,grantId:string,management=false){
    if(ctx.viewGrantId&&ctx.viewGrantId!==grantId)throw unavailable();
    const g=(await ctx.db.query(`SELECT g.* FROM ritc.view_grant g JOIN ritc.member m ON m.household_id=g.household_id AND m.member_id=g.created_by
      WHERE g.household_id=$1 AND g.grant_id=$2 AND g.revoked_at IS NULL AND g.expires_at>$3 AND m.state='active'`,[ctx.householdId,grantId,ctx.now])).rows[0];
    if(!g)throw unavailable();
    if(management)this.repo.requireShopper(ctx,await this.repo.shop(ctx,g.shop_id));
    else if(g.recipient_id!==ctx.member.member_id)throw unavailable();
    return g;
  }
  async currentView(ctx:Context,grantId:string){
    const g=await this.grant(ctx,grantId);
    return{grantId,shopId:g.shop_id,revision:g.revision,asOf:g.as_of.toISOString(),expiresAt:g.expires_at.toISOString(),mode:g.mode,canPropose:g.mode==='edit',shopLabel:g.projection.shopLabel,language:g.projection.language,items:g.projection.items};
  }
  async updateView(ctx:Context,grantId:string,input:z.infer<typeof viewUpdateSchema>){
    const g=await this.grant(ctx,grantId,true);if(g.revision!==input.baseRevision)throw new ServiceError(409,'stale_base','Review the current cook instructions before replacing them.');
    const projection={shopLabel:input.shopLabel,language:input.language,items:input.items};
    await ctx.db.query('UPDATE ritc.view_grant SET revision=revision+1,projection=$3,as_of=$4 WHERE household_id=$1 AND grant_id=$2',[ctx.householdId,grantId,projection,ctx.now]);
    return{grantId,revision:g.revision+1,asOf:ctx.now.toISOString()};
  }
  async propose(ctx:Context,grantId:string,input:z.infer<typeof proposalSchema>){
    const g=await this.grant(ctx,grantId);if(g.mode!=='edit')throw unavailable();
    const fingerprint=digest({grantId,...input});
    const old=(await ctx.db.query('SELECT proposal_id,grant_id,base_revision,payload_digest,status FROM ritc.helper_proposal WHERE household_id=$1 AND actor_id=$2 AND client_key=$3',[ctx.householdId,ctx.member.member_id,input.clientKey])).rows[0];
    if(old){if(old.payload_digest!==fingerprint)throw new ServiceError(409,'key_reused','Use a fresh key for a changed suggestion.');return{proposalId:old.proposal_id,grantId:old.grant_id,baseRevision:old.base_revision,status:'pending' as const};}
    if(g.revision!==input.baseRevision)throw new ServiceError(409,'stale_base','Read the current instructions before proposing a correction.');
    const proposalId=randomUUID();
    await ctx.db.query('INSERT INTO ritc.helper_proposal(household_id,proposal_id,grant_id,actor_id,client_key,base_revision,correction,payload_digest) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',[ctx.householdId,proposalId,grantId,ctx.member.member_id,input.clientKey,input.baseRevision,input.correction,fingerprint]);
    return{proposalId,grantId,baseRevision:input.baseRevision,status:'pending' as const};
  }
  async proposals(ctx:Context,grantId:string,cursor:string|null=null){
    await this.grant(ctx,grantId,true);let after:string|undefined;
    if(cursor){after=(await ctx.db.query('SELECT created_at::text AS created_at FROM ritc.helper_proposal WHERE household_id=$1 AND grant_id=$2 AND proposal_id=$3',[ctx.householdId,grantId,cursor])).rows[0]?.created_at;if(!after)throw unavailable();}
    const rows=(await ctx.db.query('SELECT * FROM ritc.helper_proposal WHERE household_id=$1 AND grant_id=$2 AND ($3::timestamptz IS NULL OR (created_at,proposal_id)>($3,$4::uuid)) ORDER BY created_at,proposal_id LIMIT 101',[ctx.householdId,grantId,after??null,cursor])).rows;
    return{proposals:rows.slice(0,100).map(p=>proposalDTO(grantId,p)),nextCursor:rows.length>100?rows[99].proposal_id:null};
  }

  async revoke(ctx:Context,input:z.infer<typeof revocationSchema>){
    if(input.kind==='view'){
      const g=(await ctx.db.query('SELECT shop_id FROM ritc.view_grant WHERE household_id=$1 AND grant_id=$2',[ctx.householdId,input.targetId])).rows[0];if(!g)throw unavailable();
      if(!ctx.member.organizer)this.repo.requireShopper(ctx,await this.repo.shop(ctx,g.shop_id));
      await ctx.db.query('UPDATE ritc.view_grant SET revoked_at=COALESCE(revoked_at,$3) WHERE household_id=$1 AND grant_id=$2',[ctx.householdId,input.targetId,ctx.now]);
      await ctx.db.query('UPDATE ritc.invite SET revoked_at=COALESCE(revoked_at,$3) WHERE household_id=$1 AND grant_id=$2',[ctx.householdId,input.targetId,ctx.now]);
    }else{
      this.organizer(ctx);
      if(input.kind==='invite'){
        const i=await ctx.db.query('UPDATE ritc.invite SET revoked_at=COALESCE(revoked_at,$3) WHERE household_id=$1 AND invite_id=$2 RETURNING invite_id',[ctx.householdId,input.targetId,ctx.now]);if(!i.rowCount)throw unavailable();
      }else{
        if(input.targetId===ctx.member.member_id)throw new ServiceError(409,'organizer_required','Transfer household administration before leaving.');
        const shopper=await ctx.db.query("SELECT 1 FROM ritc.shop WHERE household_id=$1 AND shopper_id=$2 AND phase<>'closed'",[ctx.householdId,input.targetId]);if(shopper.rowCount)throw new ServiceError(409,'shopper_transfer_required','Transfer active pickups before revoking this member.');
        const changed=await ctx.db.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2 RETURNING member_id",[ctx.householdId,input.targetId]);if(!changed.rowCount)throw unavailable();
        await this.revokeDevices(ctx,input.targetId);
      }
    }
    return{revoked:true,kind:input.kind,targetId:input.targetId};
  }
  async revokeDevices(ctx:Context,memberId:string){
    for(const table of ['web_session','replay_window','device'])await ctx.db.query(`UPDATE ritc.${table} SET revoked_at=COALESCE(revoked_at,$3) WHERE household_id=$1 AND member_id=$2`,[ctx.householdId,memberId,ctx.now]);
    await ctx.db.query('UPDATE ritc.view_grant SET revoked_at=COALESCE(revoked_at,$3) WHERE household_id=$1 AND (recipient_id=$2 OR created_by=$2)',[ctx.householdId,memberId,ctx.now]);
    await ctx.db.query('UPDATE ritc.invite SET revoked_at=COALESCE(revoked_at,$3) WHERE household_id=$1 AND created_by=$2',[ctx.householdId,memberId,ctx.now]);
  }
  async consents(ctx:Context){
    if(ctx.member.kind!=='adult')throw unavailable();
    const rows=(await ctx.db.query(`SELECT c.consent_id,c.child_id,c.notice_version,c.granted_at,c.revoked_at,m.alias FROM ritc.consent c
      JOIN ritc.guardian_relationship r USING(household_id,child_id,guardian_id) JOIN ritc.member m ON m.household_id=c.household_id AND m.member_id=c.child_id
      WHERE c.household_id=$1 AND c.guardian_id=$2 AND r.revoked_at IS NULL ORDER BY c.granted_at DESC LIMIT 100`,[ctx.householdId,ctx.member.member_id])).rows;
    return{enrollmentEnabled:false,consents:rows.map(c=>({consentId:c.consent_id,childId:c.child_id,childAlias:c.alias,noticeVersion:c.notice_version,grantedAt:c.granted_at.toISOString(),revokedAt:c.revoked_at?.toISOString()??null}))};
  }
  async revokeConsent(ctx:Context,consentId:string){
    if(ctx.member.kind!=='adult')throw unavailable();
    const consent=(await ctx.db.query('SELECT c.child_id,c.revoked_at FROM ritc.consent c JOIN ritc.guardian_relationship r USING(household_id,child_id,guardian_id) WHERE c.household_id=$1 AND c.consent_id=$2 AND c.guardian_id=$3 AND r.revoked_at IS NULL',[ctx.householdId,consentId,ctx.member.member_id])).rows[0];if(!consent)throw unavailable();
    if(!consent.revoked_at)await ctx.db.query('UPDATE ritc.consent SET revoked_at=$3 WHERE household_id=$1 AND child_id=$2 AND revoked_at IS NULL',[ctx.householdId,consent.child_id,ctx.now]);
    await this.revokeDevices(ctx,consent.child_id);
    return{consentId,revoked:true};
  }
}
