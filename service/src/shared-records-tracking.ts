/** Assigned-shopper-only independent record. This representation is deliberately
 * not TrackingState: it has no authority epoch, live basis, review or replay token.
 * All reads run inside the existing authorized household-locked transaction. */
import {z} from 'zod';
import type {Context,HouseholdRepository,Shop} from './repository.js';
import {loadDemand} from './shared-demand-repository.js';
import {readTracking,trackingCatalog} from './shared-demand-tracking-repository.js';
import {trackingStateSchema,validateState,coverage,digest,type Fact} from './shared-demand-tracking.js';
import {redactedProjectionSchema} from './shared-demand-tracking-transitions.js';
import {quoteSchema} from './contracts.js';
import {sharedMealSchema} from './shared-meal-planning.js';
import {digest as storageDigest} from './database.js';
import {ServiceError} from './errors.js';
const id=z.string().uuid(),rev=z.number().int().min(0).max(2147483647);
const mealsSchema=z.array(z.object({occurrenceId:id,revision:rev,meal:sharedMealSchema}).strict()).max(100);
const fail=()=>new ServiceError(409,'shared_record_unavailable','Refresh the current authorized shop record.');
function check(value:unknown):asserts value{if(!value)throw fail();}
function exact<T>(schema:z.ZodType<T>,value:unknown):T{const parsed=schema.parse(value);check(digest(parsed)===digest(value));return parsed;}
type Page=Awaited<ReturnType<typeof readTracking>>;
export interface TrackingRecordInput {shop:Shop;page:Page;currentCatalog:readonly Fact[];meals:unknown;}
export function projectTrackingRecord(input:TrackingRecordInput,asOf:Date){
 const {shop,page}=input;check(Number.isFinite(asOf.getTime()));
 check(page.schemaVersion===2&&page.shopId===shop.shop_id&&page.shopRevision===shop.revision&&page.authorityEpoch===shop.authority_epoch);
 check(['draft','frozen','placed','closed'].includes(shop.phase));
 const quote=exact(quoteSchema,shop.quote),meals=exact(mealsSchema,input.meals);
 check(new Set(meals.map(m=>m.occurrenceId)).size===meals.length&&meals.every(m=>m.revision>0&&m.revision<=shop.revision));
 const erased=page.status==='reviewRequired';
 check(erased?(!page.state&&!!page.projection&&page.coverage===null&&!!shop.demand_review_required): (!!page.state&&!page.projection&&!shop.demand_review_required));
 const projection=erased?exact(redactedProjectionSchema,page.projection):null;
 const raw=projection?.state??exact(trackingStateSchema,page.state);
 check(raw.graph.householdId===shop.household_id&&raw.graph.shopId===shop.shop_id&&raw.authorityEpoch===shop.authority_epoch);
 check(raw.graph.revision===(shop.demand_revision??0)&&raw.quoteDigest===storageDigest(quote));
 check(page.basisDigest===digest(projection??raw));
 if(projection)check(projection.state.privacyRevision>projection.previousPrivacyRevision);
 // Missing erased pack assertions are never recovered or exported. Temporary
 // unknown rows ONLY let the existing validator check the surviving partition.
 const state=validateState({...raw,packReviews:erased?raw.graph.lines.filter(l=>l.trashedAt===null).map(l=>({lineId:l.id,usablePerPack:null,acceptUnresolved:false})):page.state!.packReviews},input.currentCatalog);
 const occurrences=new Set(meals.map(m=>m.occurrenceId));
 check(state.catalog.every(f=>f.source.kind==='meal'?occurrences.has(f.source.occurrenceId):f.source.kind==='reservation'&&f.source.originOccurrenceId!==null?occurrences.has(f.source.originOccurrenceId):true));
 const summary=erased?null:coverage(state,input.currentCatalog);
 check(erased||digest(summary)===digest(page.coverage));
 check(erased||page.status===(state.graph.revision===0?'legacy':'enabled'));
 const record={schemaVersion:2 as const,projection:'assigned-shopper-independent-record-v2' as const,
  origin:{householdId:shop.household_id,shopId:shop.shop_id},shopRevision:shop.revision,privacyRevision:state.privacyRevision,
  phase:shop.phase,storeBasisRevision:shop.store_basis_revision??null,storeReviewRequired:shop.store_review_required??false,
  quote,mealOccurrences:meals,
  food:{status:page.status,graph:state.graph,basket:state.basket,catalog:state.catalog,bindings:state.bindings,unbound:state.unbound,legacyLineIds:state.legacyLineIds,
   packReview:{state:erased?'erased' as const:state.graph.revision===0?'notRecorded' as const:'recorded' as const,values:erased?null:state.packReviews},coverage:summary}};
 const result={schemaVersion:2 as const,asOf:asOf.toISOString(),recordDigest:digest(record),record};
 check(Buffer.byteLength(JSON.stringify(result),'utf8')<=1_800_000);
 return structuredClone(result);
}
/** No subscription gate. requireShopper excludes helpers, children and other
 * planners BEFORE reading quote/meal/source data; the assigned adult shopper has
 * current-shop budget scope. This is not a period or guardian export endpoint. */
export async function readTrackingRecordSnapshot(repo:HouseholdRepository,ctx:Context,shop:Shop){
 repo.requireShopper(ctx,shop);
 const page=await readTracking(repo,ctx,shop);
 const state=page.state??page.projection!.state;
 const currentGraph=await loadDemand(ctx,shop);
 check(currentGraph?digest(currentGraph.graph)===digest(state.graph):state.graph.revision===0);
 // Re-authorize surviving source provenance even for the erased projection.
 const currentCatalog=await trackingCatalog(repo,ctx,shop,undefined,{...state.graph,contributions:[...state.graph.contributions,...state.unbound.flatMap(u=>u.transferred?[u.transferred]:[])]});
 const meals=await repo.meals(ctx,shop.shop_id);
 return projectTrackingRecord({shop,page,currentCatalog,meals},ctx.now);
}
