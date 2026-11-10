/** Lossless current-shop record read. This is NOT an export grant or recovery token.
 * Invoke only inside HouseholdRepository.authorized's household-locked transaction.
 * Imported bytes must never be passed back to this reader as authority.
 */
import {z} from 'zod';
import type {Context,HouseholdRepository,Shop} from './repository.js';
import {readDemand} from './shared-demand-repository.js';
import {digest} from './database.js';
import {ServiceError} from './errors.js';
import {lineSchema,quoteSchema} from './contracts.js';
import {sharedMealSchema} from './shared-meal-planning.js';
import {demandQuantitySchema} from './shared-demand-contracts.js';
import {demandLineTotals,validateDemandGraph} from './shared-demand-domain.js';

const id=z.string().uuid();
const packsSchema=z.array(z.object({lineId:id,usablePerPack:demandQuantitySchema.nullable(),acceptUnresolved:z.boolean()}).strict()).max(200);
const requestsSchema=z.array(z.object({requestId:id,lineId:id,reviewedRevision:z.number().int().positive(),
 originalItem:z.string().min(1).max(240),originalQuantityText:z.string().max(80).nullable()}).strict()).max(2000);
const fail=()=>new ServiceError(409,'shared_record_unavailable','Refresh the current authorized shop record.');
function requireThat(value:unknown):asserts value{if(!value)throw fail();}
function exact<T>(schema:z.ZodType<T>,value:unknown):T {
 const parsed=schema.parse(value);requireThat(digest(parsed)===digest(value));return parsed;
}
function time(value:Date|string){const date=value instanceof Date?value:new Date(value);requireThat(Number.isFinite(date.getTime()));return date.toISOString();}
type DemandPage=Awaited<ReturnType<typeof readDemand>>;
export interface SharedRecordGraphRow {
 revision:number;predecessor:number|null;created_at:Date|string;graph_digest:string|null;
 pack_review:unknown;predecessor_digest:string|null;
}
export interface SharedRecordSnapshotRow {
 revision:number;purpose:string;created_at:Date|string;snapshot:unknown;digest:string;
}
export interface SharedRecordInputs {
 shop:Shop;page:DemandPage;lines:unknown;meals:unknown;requestSources:unknown;
 graphRow:SharedRecordGraphRow|null;snapshotRow:SharedRecordSnapshotRow|null;
}

/** Projection accepts only already authorized current facts; it copies all food
 * semantics and keeps food quantities separate from whole retail pack counts.
 * Its digest covers record content, not the changing observation timestamp.
 */
export function projectSharedRecord(input:SharedRecordInputs,asOf:Date){
 const {shop,page,graphRow,snapshotRow}=input;
 requireThat(page.shopId===shop.shop_id&&page.shopRevision===shop.revision&&page.authorityEpoch===shop.authority_epoch);
 const quote=exact(quoteSchema,shop.quote),lines=exact(z.array(lineSchema).max(200),input.lines);
 const meals=exact(z.array(z.object({occurrenceId:id,revision:z.number().int().positive(),meal:sharedMealSchema}).strict()).max(100),input.meals);
 const requestSources=exact(requestsSchema,input.requestSources);
 requireThat(new Set(requestSources.map(v=>v.requestId)).size===requestSources.length&&requestSources.every(v=>lines.some(l=>l.lineId===v.lineId)));
 requireThat(new Set(lines.map(v=>v.lineId)).size===lines.length&&new Set(meals.map(v=>v.occurrenceId)).size===meals.length);
 requireThat(meals.every(v=>v.revision<=shop.revision));
 let packReview:{state:'recorded'|'notRecorded'|'erased';graphRevision:number|null;values:z.infer<typeof packsSchema>|null};
 let graphLineage:{revision:number;predecessor:number|null;recordedAt:string;digest:string|null;predecessorDigest:string|null}|null=null;
 if(page.graph){
  const graph=validateDemandGraph(page.graph);
  requireThat(graph.householdId===shop.household_id&&graph.shopId===shop.shop_id&&graph.revision===shop.demand_revision);
  requireThat(graphRow&&graphRow.revision===graph.revision&&graphRow.predecessor===(graph.revision===1?null:graph.revision-1));
  requireThat(digest(demandLineTotals(graph))===digest(page.totals));
  const occurrenceIDs=new Set(meals.map(m=>m.occurrenceId));
  requireThat(graph.contributions.filter(c=>c.removedAt===null).every(c=>
   c.source.kind==='meal'?occurrenceIDs.has(c.source.occurrenceId):
   c.source.kind==='reservation'&&c.source.originOccurrenceId!==null?occurrenceIDs.has(c.source.originOccurrenceId):true));
  const activeRequests=graph.contributions.filter(c=>c.removedAt===null&&c.source.kind==='request');
  requireThat(activeRequests.length===requestSources.length&&requestSources.every(r=>activeRequests.some(c=>
   c.source.kind==='request'&&c.source.requestId===r.requestId&&c.source.appliedRequestRevision===r.reviewedRevision&&c.lineId===r.lineId&&c.originalText===r.originalItem)));
  requireThat(page.status===(shop.demand_review_required?'reviewRequired':'enabled'));
  if(page.status==='enabled'){
   requireThat(graphRow.graph_digest===digest(graph)&&page.graphDigest===graphRow.graph_digest&&graphRow.pack_review!==null);
   const values=exact(packsSchema,graphRow.pack_review);
   const ids=values.map(v=>v.lineId).sort(),lineIDs=lines.map(v=>v.lineId).sort();
   requireThat(new Set(ids).size===ids.length&&digest(ids)===digest(lineIDs)&&digest(ids)===digest(page.totals.map(v=>v.lineId).sort()));
   requireThat(lines.every(line=>graph.lines.some(v=>v.id===line.lineId&&v.name===line.originalItem&&v.trashedAt===null)));
   packReview={state:'recorded',graphRevision:graph.revision,values};
  }else{
   requireThat(graphRow.graph_digest===null&&graphRow.pack_review===null&&page.graphDigest===null);
   packReview={state:'erased',graphRevision:graph.revision,values:null};
  }
  requireThat(graphRow.predecessor_digest===null||/^[0-9a-f]{64}$/.test(graphRow.predecessor_digest));
  graphLineage={revision:graphRow.revision,predecessor:graphRow.predecessor,recordedAt:time(graphRow.created_at),
   digest:graphRow.graph_digest,predecessorDigest:graphRow.predecessor_digest};
 }else{
  requireThat(page.status==='legacy'&&!shop.demand_revision&&graphRow===null&&page.totals.length===0);
  packReview={state:'notRecorded',graphRevision:null,values:null};
 }
 let basketLineage:{revision:number;purpose:string;recordedAt:string;digest:string|null;integrity:'recorded'|'redacted'}|null=null;
 if(snapshotRow){
  requireThat(Number.isInteger(snapshotRow.revision)&&snapshotRow.revision>0&&snapshotRow.revision<=shop.revision);
  requireThat(['create','patch','decision','freeze','reopen','placed'].includes(snapshotRow.purpose));
  const redacted=snapshotRow.digest==='0'.repeat(64);
  requireThat(snapshotRow.snapshot!==null&&typeof snapshotRow.snapshot==='object'&&
   (snapshotRow.snapshot as {shopId?:unknown}).shopId===shop.shop_id&&(snapshotRow.snapshot as {revision?:unknown}).revision===snapshotRow.revision);
  requireThat(redacted||snapshotRow.digest===digest(snapshotRow.snapshot));
  basketLineage={revision:snapshotRow.revision,purpose:snapshotRow.purpose,recordedAt:time(snapshotRow.created_at),
   digest:redacted?null:snapshotRow.digest,integrity:redacted?'redacted':'recorded'};
 }
 const record={schemaVersion:1 as const,projection:'assigned-shopper-current-record-v1' as const,
  origin:{householdId:shop.household_id,shopId:shop.shop_id},shopRevision:shop.revision,
  phase:shop.phase,storeBasisRevision:shop.store_basis_revision??null,storeReviewRequired:shop.store_review_required??false,
  quote,basketLines:lines,mealOccurrences:meals,requestSources,
  food:{status:page.status,graph:page.graph,totals:page.totals,packReview,legacySources:page.legacySources},
  lineage:{graph:graphLineage,basket:basketLineage}};
 const result={schemaVersion:1 as const,asOf:time(asOf),recordDigest:digest(record),record};
 requireThat(Buffer.byteLength(JSON.stringify(result),'utf8')<=3_000_000);
 return structuredClone(result);
}

/** Existing membership/device/consent authorization happens before entry. No paid
 * entitlement is checked. Full shopper scope is required before any content read.
 */
export async function readSharedRecordSnapshot(repo:HouseholdRepository,ctx:Context,shop:Shop){
 repo.requireShopper(ctx,shop);
 const page=await readDemand(repo,ctx,shop),lines=await repo.lines(ctx,shop.shop_id),meals=await repo.meals(ctx,shop.shop_id);
 const linked=await ctx.db.query<{request_id:string;line_id:string;reviewed_revision:number;original_item:string;own_quantity:string|null}>(`SELECT l.request_id,l.line_id,l.reviewed_revision,r.original_item,r.own_quantity
  FROM ritc.request_link l JOIN ritc.request r ON (r.household_id,r.shop_id,r.request_id)=(l.household_id,l.shop_id,l.request_id)
  WHERE l.household_id=$1 AND l.shop_id=$2 ORDER BY l.request_id LIMIT 2001`,[ctx.householdId,shop.shop_id]);
 requireThat(linked.rows.length<=2000);
 const requestSources=linked.rows.map(r=>({requestId:r.request_id,lineId:r.line_id,reviewedRevision:r.reviewed_revision,originalItem:r.original_item,originalQuantityText:r.own_quantity}));
 let graphRow:SharedRecordGraphRow|null=null;
 if(shop.demand_revision){
  const result=await ctx.db.query<SharedRecordGraphRow>(`SELECT d.revision,d.predecessor,d.created_at,d.graph_digest,d.pack_review,p.graph_digest AS predecessor_digest
   FROM ritc.shared_demand_revision d LEFT JOIN ritc.shared_demand_revision p
   ON (p.household_id,p.shop_id,p.revision)=(d.household_id,d.shop_id,d.predecessor)
   WHERE d.household_id=$1 AND d.shop_id=$2 AND d.revision=$3`,[ctx.householdId,shop.shop_id,shop.demand_revision]);
  requireThat(result.rows.length===1);graphRow=result.rows[0]!;
 }
 const snapshots=await ctx.db.query<SharedRecordSnapshotRow>(`SELECT revision,purpose,created_at,snapshot,digest FROM ritc.shop_snapshot
  WHERE household_id=$1 AND shop_id=$2 AND revision<=$3 ORDER BY revision DESC LIMIT 1`,[ctx.householdId,shop.shop_id,shop.revision]);
 return projectSharedRecord({shop,page,lines,meals,requestSources,graphRow,snapshotRow:snapshots.rows[0]??null},ctx.now);
}
