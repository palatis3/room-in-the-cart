import type {Context} from './repository.js';
import {HouseholdRepository} from './repository.js';
import {ServiceError,unavailable} from './errors.js';

// Read projections only. Existing report/reconciliation commands remain the mutation authority.
export class PlacementReports {
 constructor(private readonly repo:HouseholdRepository){}
 async currentShop(ctx:Context,shopId:string){return this.repo.adultShop(ctx,shopId);}
 private async current(ctx:Context,shopId:string){const shop=await this.repo.shop(ctx,shopId);this.repo.requireShopper(ctx,shop);return{shopId,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,phase:shop.phase,frozenRevision:shop.frozen_revision};}
 private row(row:Record<string,any>){return{reportId:row.report_id,shopId:row.shop_id,reportedRevision:row.reported_revision,reportedAuthorityEpoch:row.reported_epoch,occurredAt:row.occurred_at.toISOString(),receivedAt:row.received_at.toISOString(),source:row.source,state:row.state,snapshot:row.snapshot,snapshotCreatedAt:row.snapshot_created_at.toISOString(),snapshotDigest:row.snapshot_digest,resolutionOperationId:row.resolution_operation_id,resolutionClientKey:row.resolution_client_key??null};}
 private query=`SELECT r.*,s.snapshot,s.created_at AS snapshot_created_at,s.digest AS snapshot_digest,
   CASE WHEN o.actor_id=$3 THEN o.client_key END AS resolution_client_key
   FROM ritc.placement_report r JOIN ritc.shop_snapshot s ON s.household_id=r.household_id AND s.shop_id=r.shop_id AND s.revision=r.reported_revision
   LEFT JOIN ritc.operation o ON o.household_id=r.household_id AND o.operation_id=r.resolution_operation_id`;
 async pending(ctx:Context,shopId:string,cursor:string|null){
  const current=await this.current(ctx,shopId);let after:string|undefined;
  if(cursor){after=(await ctx.db.query('SELECT received_at::text AS received_at FROM ritc.placement_report WHERE household_id=$1 AND shop_id=$2 AND report_id=$3',[ctx.householdId,shopId,cursor])).rows[0]?.received_at;if(!after)throw unavailable();}
  const rows=(await ctx.db.query(this.query+` WHERE r.household_id=$1 AND r.shop_id=$2 AND r.state='pending_reconciliation'
   AND ($4::timestamptz IS NULL OR (r.received_at,r.report_id)>($4,$5::uuid)) ORDER BY r.received_at,r.report_id LIMIT 6`,[ctx.householdId,shopId,ctx.member.member_id,after??null,cursor])).rows;
  return{...current,reports:rows.slice(0,5).map(row=>this.row(row)),nextCursor:rows.length>5?rows[4].report_id:null};
 }
 async detail(ctx:Context,shopId:string,reportId:string){const current=await this.current(ctx,shopId),row=(await ctx.db.query(this.query+' WHERE r.household_id=$1 AND r.shop_id=$2 AND r.report_id=$4',[ctx.householdId,shopId,ctx.member.member_id,reportId])).rows[0];if(!row)throw unavailable();return{...current,report:this.row(row)};}
 async own(ctx:Context,shopId:string,clientKey:string,commandDigest:string){
  if(ctx.viewGrantId||ctx.member.kind!=='adult'||(ctx.selectedShopId&&ctx.selectedShopId!==shopId))throw unavailable();
  const authority=await ctx.db.query('SELECT 1 FROM ritc.shop_authority WHERE household_id=$1 AND shop_id=$2 AND member_id=$3 LIMIT 1',[ctx.householdId,shopId,ctx.member.member_id]);if(!authority.rowCount)throw unavailable();
  const row=(await ctx.db.query(`SELECT r.*,o.client_key,o.payload_digest,o.device_id FROM ritc.operation o JOIN ritc.placement_report r ON r.household_id=o.household_id AND r.operation_id=o.operation_id
   WHERE o.household_id=$1 AND o.actor_id=$2 AND o.client_key=$3 AND o.shop_id=$4 AND o.kind='shop.reportPlaced'`,[ctx.householdId,ctx.member.member_id,clientKey,shopId])).rows[0];
  if(!row)return{status:null};
  if(row.device_id!==ctx.deviceId)throw unavailable();
  if(row.payload_digest!==commandDigest)throw new ServiceError(409,'key_reused','Inspect the original saved report; do not recreate it with changed facts.');
  return{status:{clientKey:row.client_key,operationId:row.operation_id,reportId:row.report_id,shopId:row.shop_id,reportedRevision:row.reported_revision,reportedAuthorityEpoch:row.reported_epoch,occurredAt:row.occurred_at.toISOString(),receivedAt:row.received_at.toISOString(),source:row.source,state:row.state}};
 }
}
