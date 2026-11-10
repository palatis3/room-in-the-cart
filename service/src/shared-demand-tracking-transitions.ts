/** Pure candidate/review primitives. Repository ownership/authentication, preview
 * admission, transactions and durable replay are mandatory external boundaries. */
import {z} from 'zod';
import {demandLineSchema} from './shared-demand-contracts.js';
import {trackingStateSchema,factSchema,validateState,coverage,digest,PartitionError,type TrackingState,type Fact} from './shared-demand-tracking.js';
const id=factSchema.shape.id,hash=z.string().regex(/^[a-f0-9]{64}$/),rev=z.number().int().min(0).max(2147483647),time=z.iso.datetime({offset:true});
const basket=trackingStateSchema.shape.basket.element,pack=trackingStateSchema.shape.packReviews.element;
const basisSchema=z.object({householdId:id,shopId:id,graphRevision:rev,authorityEpoch:rev,privacyRevision:rev,basisDigest:hash,currentCatalog:z.array(factSchema).max(2000)}).strict();
function check(v:unknown,code:string):asserts v{if(!v)throw new PartitionError(code);}
const eq=(a:unknown,b:unknown)=>digest(a)===digest(b);
function frozen<T>(v:T):T{if(v&&typeof v==='object'){Object.freeze(v);for(const x of Object.values(v))frozen(x);}return v;}
function scope(s:TrackingState,c:z.infer<typeof basisSchema>){
 check(s.graph.householdId===c.householdId&&s.graph.shopId===c.shopId,'wrong_scope');
 check(s.graph.revision===c.graphRevision&&c.graphRevision<2147483647,'stale_revision');
 check(s.authorityEpoch===c.authorityEpoch&&s.privacyRevision===c.privacyRevision,'source_revision_or_privacy');
}
const rebindSchema=z.object({operationId:id,at:time,bindings:z.array(z.object({factId:id,line:demandLineSchema,basket,packReview:pack}).strict()).min(1).max(2000)}).strict();
/** Restore only IDs proved by a current transferred row. No arbitrary contribution
 * body or identifier is accepted; no historic allocation is automatically restored. */
export function previewTransferredRebind(input:unknown,intentInput:unknown,basisInput:unknown){
 const c=basisSchema.parse(basisInput),s=validateState(input,c.currentCatalog),intent=rebindSchema.parse(intentInput);
 scope(s,c);check(c.basisDigest===digest(s),'stale_state');
 check(new Set(intent.bindings.map(x=>x.factId)).size===intent.bindings.length,'duplicate_rebind');
 const next=structuredClone(s),restored=[];
 for(const binding of intent.bindings){
  const unbound=next.unbound.find(u=>u.factId===binding.factId);check(unbound?.transferred,'transfer_proof_required');
  const transferred=unbound.transferred;
  check(next.graph.usedIds.includes(transferred.id)&&!next.graph.contributions.some(r=>r.id===transferred.id),'transfer_identity_lost');
  check(binding.line.trashedAt===null&&binding.line.id===binding.basket.id&&binding.line.name===binding.basket.name&&binding.packReview.lineId===binding.line.id,'rebind_line_mismatch');
  const oldLine=next.graph.lines.find(l=>l.id===binding.line.id);
  if(oldLine){
   if(oldLine.trashedAt!==null)check(oldLine.id===transferred.lineId&&eq({...oldLine,trashedAt:null},binding.line),'historical_line_conflict');
   else check(eq(oldLine,binding.line),'current_line_conflict');
   next.graph.lines[next.graph.lines.findIndex(l=>l.id===oldLine.id)]=structuredClone(binding.line);
  }else{
   check(!next.graph.usedIds.includes(binding.line.id),'identity_reused');next.graph.usedIds.push(binding.line.id);next.graph.lines.push(structuredClone(binding.line));
  }
  const oldBasket=next.basket.find(l=>l.id===binding.basket.id);
  if(oldBasket)check(eq(oldBasket,binding.basket),'basket_requires_separate_review');
  else{check(binding.basket.priceMinor===null,'new_price_requires_quote_review');next.basket.push(structuredClone(binding.basket));}
  const oldPack=next.packReviews.find(p=>p.lineId===binding.line.id);
  if(oldPack)check(eq(oldPack,binding.packReview),'pack_requires_separate_review');
  else next.packReviews.push(structuredClone(binding.packReview));
  const row={...structuredClone(transferred),lineId:binding.line.id};
  next.graph.contributions.push(row);next.bindings.push({factId:binding.factId,contributionId:row.id});
  next.unbound=next.unbound.filter(u=>u.factId!==binding.factId);next.legacyLineIds=next.legacyLineIds.filter(x=>x!==binding.line.id);
  restored.push({factId:binding.factId,before:structuredClone(unbound),after:row});
 }
 next.graph.revision++;validateState(next,c.currentCatalog);
 return frozen({kind:'rebindCandidate' as const,operationId:intent.operationId,baseDigest:digest(s),state:next,
  disclosure:{restored,allocationsRestored:[] as string[],before:coverage(s,c.currentCatalog),after:coverage(next,c.currentCatalog)}});
}
/** Only a worker/repository-produced, digest-bound surviving projection is input.
 * This function neither performs erasure nor accepts a caller's old full state. */
export const redactedProjectionSchema=z.object({schemaVersion:z.literal(1),status:z.literal('reviewRequired'),invalidatedStateDigest:hash,
 previousPrivacyRevision:rev,state:trackingStateSchema.omit({packReviews:true})}).strict();
const recoveryIntentSchema=z.object({operationId:id,at:time,packReviews:trackingStateSchema.shape.packReviews}).strict();
export function previewRedactedRecovery(projectionInput:unknown,intentInput:unknown,basisInput:unknown){
 const projection=redactedProjectionSchema.parse(projectionInput),intent=recoveryIntentSchema.parse(intentInput),c=basisSchema.parse(basisInput);
 check(c.basisDigest===digest(projection),'projection_integrity');
 check(projection.state.privacyRevision>projection.previousPrivacyRevision,'privacy_not_advanced');
 const restored=validateState({...projection.state,packReviews:intent.packReviews},c.currentCatalog);scope(restored,c);
 const next=structuredClone(restored);next.graph.revision++;validateState(next,c.currentCatalog);
 return frozen({kind:'recoveryCandidate' as const,operationId:intent.operationId,projectionDigest:digest(projection),state:next,
  disclosure:{invalidatedStateDigest:projection.invalidatedStateDigest,survivingCatalog:structuredClone(next.catalog),unbound:structuredClone(next.unbound),
   freshPackReviews:structuredClone(next.packReviews),coverage:coverage(next,c.currentCatalog)}});
}
/** Honest review scope: a partial pickup is allowed, not asserted sufficient. */
export function trackingReviewDisclosure(input:unknown,currentCatalog:readonly Fact[]){
 const s=validateState(input,currentCatalog),summary=coverage(s,currentCatalog);
 const unresolvedPackIds=s.packReviews.filter(p=>p.usablePerPack===null||summary.trackedSubtotals.find(t=>t.lineId===p.lineId)?.quantity===null||
  s.graph.contributions.some(row=>row.removedAt===null&&row.lineId===p.lineId&&row.sourceExclusions?.some(e=>e.resolution.kind==='unresolved'))).map(p=>p.lineId);
 return {stateDigest:digest(s),catalogDigest:digest(s.catalog),priceBasisDigest:digest({quoteDigest:s.quoteDigest,basket:s.basket}),
  coverageStatement:'tracked_subtotals_only_no_complete_coverage_or_free_unbound_supply' as const,coverage:summary,
  unbound:s.unbound.map(u=>({fact:structuredClone(s.catalog.find(f=>f.id===u.factId)!),transferred:structuredClone(u.transferred)})),
  unpricedBasketIds:s.basket.filter(l=>l.priceMinor===null).map(l=>l.id),unresolvedPackIds,
  basket:structuredClone(s.basket),packReviews:structuredClone(s.packReviews)};
}
const reviewContextSchema=basisSchema.extend({reviewId:id,actorId:id,deviceId:id,shopRevision:rev,now:time,expiresAt:time}).strict();
/** Produces review evidence only. Authentication and accepted preview persistence
 * belong to the existing service path; these IDs are not an authority boolean. */
export function recordTrackingReview(input:unknown,acknowledgedDisclosure:unknown,contextInput:unknown){
 const c=reviewContextSchema.parse(contextInput),s=validateState(input,c.currentCatalog);scope(s,c);check(c.basisDigest===digest(s),'stale_state');
 const now=Date.parse(c.now),expiry=Date.parse(c.expiresAt);check(expiry>now&&expiry<=now+600000,'review_expiry');
 const disclosure=trackingReviewDisclosure(s,c.currentCatalog);check(eq(acknowledgedDisclosure,disclosure),'review_scope_changed');
 check(disclosure.unresolvedPackIds.every(lineId=>s.packReviews.find(p=>p.lineId===lineId)?.acceptUnresolved===true),'unresolved_pack_review_required');
 const review={schemaVersion:2 as const,reviewId:c.reviewId,actorId:c.actorId,deviceId:c.deviceId,householdId:c.householdId,shopId:c.shopId,
  shopRevision:c.shopRevision,graphRevision:c.graphRevision,authorityEpoch:c.authorityEpoch,privacyRevision:c.privacyRevision,
  createdAt:c.now,expiresAt:c.expiresAt,disclosure};
 return frozen({review,reviewDigest:digest(review)});
}
const reviewRecordSchema=z.object({schemaVersion:z.literal(2),reviewId:id,actorId:id,deviceId:id,householdId:id,shopId:id,shopRevision:rev,graphRevision:rev,authorityEpoch:rev,privacyRevision:rev,createdAt:time,expiresAt:time,disclosure:z.unknown()}).strict();
const sealContextSchema=basisSchema.extend({actorId:id,deviceId:id,baseShopRevision:rev,frozenRevision:rev,reviewDigest:hash,now:time}).strict();
/** Tracking component of a frozen snapshot. Existing quote/budget, membership,
 * phase, command and transaction checks must still be run by the repository. */
export function sealReviewedTracking(input:unknown,reviewInput:unknown,contextInput:unknown){
 const review=reviewRecordSchema.parse(reviewInput);
 const c=sealContextSchema.parse(contextInput),s=validateState(input,c.currentCatalog);scope(s,c);
 check(c.basisDigest===digest(s)&&c.reviewDigest===digest(review),'review_integrity');
 check(review.schemaVersion===2&&review.actorId===c.actorId&&review.deviceId===c.deviceId&&review.householdId===c.householdId&&review.shopId===c.shopId,'review_identity');
 check(review.shopRevision===c.baseShopRevision&&c.frozenRevision===c.baseShopRevision+1&&review.graphRevision===c.graphRevision,'stale_revision');
 check(review.authorityEpoch===c.authorityEpoch&&review.privacyRevision===c.privacyRevision,'source_revision_or_privacy');
 check(Date.parse(review.createdAt)<=Date.parse(c.now)&&Date.parse(review.expiresAt)>Date.parse(c.now),'review_expired');
 check(eq(review.disclosure,trackingReviewDisclosure(s,c.currentCatalog)),'review_scope_changed');
 const snapshot={schemaVersion:2 as const,householdId:c.householdId,shopId:c.shopId,revision:c.frozenRevision,
  authorityEpoch:c.authorityEpoch,privacyRevision:c.privacyRevision,stateDigest:digest(s),reviewDigest:c.reviewDigest,
  review:{...structuredClone(review),disclosure:trackingReviewDisclosure(s,c.currentCatalog)},state:structuredClone(s)};
 return frozen({snapshot,snapshotDigest:digest(snapshot)});
}
const snapshotSchema=z.object({schemaVersion:z.literal(2),householdId:id,shopId:id,revision:rev,authorityEpoch:rev,privacyRevision:rev,stateDigest:hash,reviewDigest:hash,review:reviewRecordSchema,state:trackingStateSchema}).strict();
const placementContextSchema=basisSchema.extend({frozenRevision:rev,storedSnapshotDigest:hash}).strict();
/** Validates only the tracking basis, not permission to place or an actual fill.
 * A review can expire after a valid freeze; reporting that frozen order is distinct
 * from accepting a fresh quote or inventing arrived stock. */
export function verifyTrackingPlacement(snapshotInput:unknown,currentInput:unknown,contextInput:unknown){
 const snapshot=snapshotSchema.parse(snapshotInput);
 const c=placementContextSchema.parse(contextInput),s=validateState(currentInput,c.currentCatalog);scope(s,c);
 check(c.storedSnapshotDigest===digest(snapshot)&&snapshot.stateDigest===digest(snapshot.state)&&snapshot.reviewDigest===digest(snapshot.review),'snapshot_integrity');
 check(snapshot.schemaVersion===2&&snapshot.householdId===c.householdId&&snapshot.shopId===c.shopId&&snapshot.revision===c.frozenRevision,'snapshot_identity');
 check(snapshot.authorityEpoch===c.authorityEpoch&&snapshot.privacyRevision===c.privacyRevision,'source_revision_or_privacy');
 check(c.basisDigest===digest(s)&&snapshot.stateDigest===digest(s),'stale_snapshot');
 check(snapshot.review.householdId===c.householdId&&snapshot.review.shopId===c.shopId&&snapshot.review.shopRevision+1===c.frozenRevision&&snapshot.review.graphRevision===c.graphRevision&&snapshot.review.authorityEpoch===c.authorityEpoch&&snapshot.review.privacyRevision===c.privacyRevision,'review_identity');
 const disclosure=trackingReviewDisclosure(s,c.currentCatalog);
 check(eq(snapshot.review.disclosure,disclosure),'review_scope_changed');
 return frozen({trackingScope:disclosure.coverage.status,coverage:disclosure.coverage,placementDoesNotConfirmFill:true as const});
}
