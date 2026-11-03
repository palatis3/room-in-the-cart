import {randomUUID} from 'node:crypto';
import type {z} from 'zod';
import {digest} from './database.js';
import type {Context} from './repository.js';
import {HouseholdLifecycle} from './lifecycle.js';
import {ServiceError,unavailable} from './errors.js';
import {viewReplacementSchema,proposalResolutionSchema} from './contracts.js';
export class HelperReview {
 constructor(private readonly lifecycle:HouseholdLifecycle){}
 async current(ctx:Context,grantId:string){const g=await this.lifecycle.grant(ctx,grantId,true);return{grantId,shopId:g.shop_id,revision:g.revision,asOf:g.as_of.toISOString(),expiresAt:g.expires_at.toISOString(),mode:g.mode,projection:g.projection};}
 private async prior(ctx:Context,grantId:string,kind:'replace'|'resolve',input:{clientKey:string},proposalId?:string){
  const fingerprint=digest({grantId,kind,...input,...(proposalId?{proposalId}:{})});
  const old=(await ctx.db.query('SELECT payload_digest,response FROM ritc.helper_mutation WHERE household_id=$1 AND actor_id=$2 AND client_key=$3',[ctx.householdId,ctx.member.member_id,input.clientKey])).rows[0];
  if(old&&old.payload_digest!==fingerprint)throw new ServiceError(409,'key_reused','Use the original reviewed action, or review a new action with a fresh key.');
  return{fingerprint,response:old?.response};
 }
 private async record(ctx:Context,grantId:string,kind:string,clientKey:string,fingerprint:string,response:{mutationId:string}){
  await ctx.db.query('INSERT INTO ritc.helper_mutation(household_id,actor_id,client_key,mutation_id,grant_id,kind,payload_digest,response) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',[ctx.householdId,ctx.member.member_id,clientKey,response.mutationId,grantId,kind,fingerprint,response]);return response;
 }
 async replace(ctx:Context,grantId:string,input:z.infer<typeof viewReplacementSchema>){
  const g=await this.lifecycle.grant(ctx,grantId,true),prior=await this.prior(ctx,grantId,'replace',input);if(prior.response)return prior.response;
  if(g.revision!==input.baseRevision)throw new ServiceError(409,'stale_base','Read and review the current helper projection before replacing it.');
  await ctx.db.query('UPDATE ritc.view_grant SET revision=revision+1,projection=$3,as_of=$4 WHERE household_id=$1 AND grant_id=$2',[ctx.householdId,grantId,input.projection,ctx.now]);
  return this.record(ctx,grantId,'replace',input.clientKey,prior.fingerprint,{mutationId:randomUUID(),...{grantId,baseRevision:input.baseRevision,revision:g.revision+1,asOf:ctx.now.toISOString(),status:'replaced' as const}});
 }
 async resolve(ctx:Context,grantId:string,proposalId:string,input:z.infer<typeof proposalResolutionSchema>){
  const g=await this.lifecycle.grant(ctx,grantId,true),prior=await this.prior(ctx,grantId,'resolve',input,proposalId);if(prior.response)return prior.response;
  const proposal=(await ctx.db.query('SELECT revision,status FROM ritc.helper_proposal WHERE household_id=$1 AND grant_id=$2 AND proposal_id=$3',[ctx.householdId,grantId,proposalId])).rows[0];if(!proposal)throw unavailable();
  if(g.revision!==input.baseRevision||proposal.revision!==input.proposalRevision)throw new ServiceError(409,'stale_base','Review the current projection and proposal before resolving it.');
  if(proposal.status!=='pending')throw new ServiceError(409,'proposal_resolved','This proposal already has a reviewed resolution.');
  const mutationId=randomUUID(),replaced=input.decision==='replace',revision=g.revision+(replaced?1:0),resolution=replaced?'replaced':'dismissed',status=replaced?'reviewed':'dismissed';
  if(replaced)await ctx.db.query('UPDATE ritc.view_grant SET revision=$3,projection=$4,as_of=$5 WHERE household_id=$1 AND grant_id=$2',[ctx.householdId,grantId,revision,input.projection,ctx.now]);
  await ctx.db.query('UPDATE ritc.helper_proposal SET revision=revision+1,status=$4,resolution=$5,resolved_revision=$6,resolved_by=$7,resolved_at=$8,resolution_id=$9 WHERE household_id=$1 AND grant_id=$2 AND proposal_id=$3',[ctx.householdId,grantId,proposalId,status,resolution,revision,ctx.member.member_id,ctx.now,mutationId]);
  return this.record(ctx,grantId,'resolve',input.clientKey,prior.fingerprint,{mutationId,...{grantId,proposalId,proposalRevision:proposal.revision+1,baseRevision:input.baseRevision,revision,status,resolution,resolvedAt:ctx.now.toISOString()}});
 }
 async managementProposal(ctx:Context,grantId:string,proposalId:string){await this.lifecycle.grant(ctx,grantId,true);const p=(await ctx.db.query('SELECT * FROM ritc.helper_proposal WHERE household_id=$1 AND grant_id=$2 AND proposal_id=$3',[ctx.householdId,grantId,proposalId])).rows[0];if(!p)throw unavailable();return proposalDTO(grantId,p);}
 async ownProposals(ctx:Context,grantId:string,cursor:string|null=null){
  await this.lifecycle.grant(ctx,grantId);let before:string|undefined;
  if(cursor){before=(await ctx.db.query('SELECT created_at::text AS created_at FROM ritc.helper_proposal WHERE household_id=$1 AND grant_id=$2 AND actor_id=$3 AND proposal_id=$4',[ctx.householdId,grantId,ctx.member.member_id,cursor])).rows[0]?.created_at;if(!before)throw unavailable();}
  const rows=(await ctx.db.query('SELECT * FROM ritc.helper_proposal WHERE household_id=$1 AND grant_id=$2 AND actor_id=$3 AND ($4::timestamptz IS NULL OR (created_at,proposal_id)<($4,$5::uuid)) ORDER BY created_at DESC,proposal_id DESC LIMIT 21',[ctx.householdId,grantId,ctx.member.member_id,before??null,cursor])).rows;
  return{proposals:rows.slice(0,20).map(p=>proposalDTO(grantId,p)),nextCursor:rows.length>20?rows[19].proposal_id:null};
 }
 async ownProposal(ctx:Context,grantId:string,proposalId:string){await this.lifecycle.grant(ctx,grantId);const proposal=(await ctx.db.query('SELECT * FROM ritc.helper_proposal WHERE household_id=$1 AND grant_id=$2 AND proposal_id=$3 AND actor_id=$4',[ctx.householdId,grantId,proposalId,ctx.member.member_id])).rows[0];if(!proposal)throw unavailable();return proposalDTO(grantId,proposal);}
}
export function proposalDTO(grantId:string,p:Record<string,any>){return{proposalId:p.proposal_id,grantId,baseRevision:p.base_revision,proposalRevision:p.revision,correction:p.correction,status:p.status,createdAt:p.created_at.toISOString(),resolution:p.resolution?{mutationId:p.resolution_id,decision:p.resolution,revision:p.resolved_revision,resolvedAt:p.resolved_at.toISOString()}:null};}
