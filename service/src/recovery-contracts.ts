import { z } from 'zod';
import { mealQuantity, mealAmount } from './shared-meal-planning.js';

const id = z.string().uuid().transform(s => s.toLowerCase());
const revision = z.number().int().min(0).max(2_147_483_647);
const time = z.iso.datetime({ offset: true });
const label = z.string().trim().min(1).max(240);
const hash = z.string().regex(/^[a-f0-9]{64}$/);
// Preserve entered text; match native ledger UTF-8 limits rather than trimming notes.
const notes = z.string().refine(value => Buffer.byteLength(value, 'utf8') <= 8192, 'Notes exceed the shared text limit');
const sourceURL = z.string().refine(value => Buffer.byteLength(value, 'utf8') <= 2048, 'Source reference exceeds the shared text limit').nullable();
const zeroAmount = z.object({ numerator: z.number().int().min(0).max(1_000_000_000), denominator: z.number().int().min(1).max(1_000_000_000) }).strict();
export const usableQuantitySchema = mealQuantity.extend({amount: zeroAmount});
export const recoveryBaseSchema = z.object({shopRevision:revision,authorityEpoch:revision,recoveryRevision:revision,supplyRevision:revision,contextRevision:revision,pantryRevision:revision.optional()}).strict();
export const recoveryNeedSchema = z.object({id,foodId:id.nullable(),matchedSourceIds:z.array(id).max(1000).optional(),ingredientId:id,groupId:id.nullable(),groupIds:z.array(id).max(30).optional(),name:label,notes,quantity:mealQuantity.nullable(),priority:z.enum(['protected','required']),due:time.nullable(),exclusions:z.array(label).max(60)}).strict();
export const recoveryMealSchema = z.object({
  occurrenceId:id,revisionId:id,sourceMealRevision:revision,title:label,notes,sourceURL,
  // Match the current shared service contract; reject fractional total servings.
  portions:z.number().int().min(1).max(1000),day:z.iso.date().nullable(),zone:z.string().min(1).max(100).refine(s=>{try{new Intl.DateTimeFormat('en',{timeZone:s});return true;}catch{return false;}}).nullable(),
  due:time.nullable(),exclusions:z.array(label).max(20),
  template:z.object({id,version:revision}).strict().nullable(),
  groups:z.array(z.object({id,name:label,servings:mealAmount,protected:z.boolean(),exclusions:z.array(label).max(20)}).strict()).max(30),
  needs:z.array(recoveryNeedSchema).max(260),
  remainingElapsedMinutes:z.number().int().min(0).max(1_000_000).nullable(),requiredLeadMinutes:z.number().int().min(0).max(1_000_000).nullable(),advanceStepsCompleted:z.boolean(),
}).strict().superRefine((meal,ctx)=>{
  if(meal.day===null && (meal.due!==null || meal.needs.some(need=>need.due!==null)))
    ctx.addIssue({code:'custom',path:['day'],message:'Keep the deadline unresolved until a meal night is selected.'});
});
const minutes=z.number().int().min(0).max(1_000_000);
const minor=z.number().int().min(0).max(1_000_000_000);
const fallbackOffer=z.object({packId:id.optional(),label,exclusionTags:z.array(label).max(20),
  usablePerPack:mealQuantity,priceMinor:minor,availablePacks:z.number().int().nonnegative().max(1_000_000)}).strict();
export const fallbackReviewSchema=z.object({candidateId:id,revision:revision.min(1),
  remainingElapsedMinutes:minutes.nullable(),remainingTimeUnknown:z.literal(true).optional(),advanceStepsCompleted:z.boolean(),
  ingredients:z.array(z.object({ingredientId:id,sourceIds:z.array(id).max(100),offer:fallbackOffer.nullable()}).strict()).max(260)}).strict()
  .refine(review=>!review.remainingTimeUnknown || review.remainingElapsedMinutes===null);
const fallbackTrip=z.object({minutes,budgetMinor:minor,chargesMinor:minor,currency:z.string().regex(/^[A-Z]{3}$/)}).strict();
export const fallbackSelectionSchema=z.object({review:fallbackReviewSchema,trip:fallbackTrip.nullable()}).strict();
export const fallbackOptionsSchema=z.object({v:z.literal(1),base:recoveryBaseSchema,occurrenceId:id,targetDigest:hash,
  reviews:z.array(fallbackReviewSchema).max(100),trip:fallbackTrip.nullable()}).strict();
export type FallbackSelection=z.infer<typeof fallbackSelectionSchema>;
export const recoveryIntentSchema = z.object({
  occurrenceId:id,targetDigest:hash,replacement:recoveryMealSchema,reviewedAt:time,fallback:fallbackSelectionSchema.optional(),
  // Explicit manual repeat choice; not proof of an accepted recipe/template.
  repeatOfOccurrenceId:id.nullable(),
  agreesToRepeat:z.boolean(),proposesExtraTrip:z.boolean(),agreesToExtraTrip:z.boolean(),acceptsUnresolved:z.boolean(),
}).strict();
export const recoveryPreviewSchema = z.object({v:z.literal(1),base:recoveryBaseSchema,intent:recoveryIntentSchema}).strict();
export const recoveryCommitSchema = recoveryPreviewSchema.extend({clientKey:id,replayWindow:id,previewDigest:hash,proposalId:id.optional()});

// Arrival time and received quantity may independently be unknown; usable stock
// still requires both plus an explicit usable confirmation.
// Public evidence commands contain observations only. They cannot establish a source,
// food identity, owned import mapping, actor, current head, or successful allocation.
export const arrivalCommandSchema = z.object({v:z.literal(1),clientKey:id,replayWindow:id,base:recoveryBaseSchema,
  sourceId:id,observationId:id,predecessorId:id.nullable(),arrivedAt:time.nullable(),received:usableQuantitySchema.nullable(),
}).strict();
export const usableCommandSchema = z.object({v:z.literal(1),clientKey:id,replayWindow:id,base:recoveryBaseSchema,
  sourceId:id,observationId:id,predecessorId:id.nullable(),arrivalObservationId:id,confirmedAt:time,usable:usableQuantitySchema.nullable(),
}).strict();
// The standard household command envelope carries shopper authority, replay window and client key.
export const deliverySourceBody = z.object({
  supplyRevision: revision, placedRevision: revision.min(1), lineId: id, segmentKey: id,
  foodName: label, exclusionTags: z.array(label).max(20),
}).strict();
export const deliveryMatchBody = z.object({
  supplyRevision: revision, sourceId: id, occurrenceId: id, mealRevision: revision.min(1),
  ingredientId: id, matched: z.boolean(),
}).strict();
export const deliveryReservationBody = deliveryMatchBody.omit({matched:true}).extend({
  groupId:id, predecessorId:id.nullable(), quantity:mealQuantity.nullable(),
});
const observationFields = {sourceId: true, observationId: true, predecessorId: true} as const;
export const deliveryArrivalBody = arrivalCommandSchema.pick({...observationFields, arrivedAt: true, received: true})
  .extend({supplyRevision: revision});
export const deliveryUsableBody = usableCommandSchema.pick({...observationFields, arrivalObservationId: true, confirmedAt: true, usable: true})
  .extend({supplyRevision: revision});
// Review IDs refer to server-held exact disclosure records; this is deliberately not
// a bulk private-library upload contract. Origin ownership verification is still required.
export const importApprovalSchema = z.object({v:z.literal(1),clientKey:id,replayWindow:id,base:recoveryBaseSchema,
  reviewId:id,reviewRevision:revision,disclosureDigest:hash,
}).strict();

const scoped = {householdId:id,shopId:id};
export const sourceSchema = z.object({...scoped,id,foodId:id,identityRevision:revision.min(1),
  origin:z.discriminatedUnion('kind',[
    z.object({kind:z.literal('delivery'),sealedOrderRevision:revision,orderLineId:id,segmentKey:id}).strict(),
    z.object({kind:z.literal('sharedStock'),batchId:id,location:z.enum(['pantry','freezer'])}).strict(),
    z.object({kind:z.literal('reviewedImport'),originBindingId:id,reviewId:id,disclosureDigest:hash}).strict(),
  ]),
}).strict();
// Identity revision is captured by the server when it admits an observation.
// A request cannot relabel historical evidence by supplying this field.
const observation = {...scoped,id,sourceId:id,identityRevision:revision.min(1),revision:revision,predecessorId:id.nullable(),recordedAt:time,actorId:id,operationId:id};
export const arrivalObservationSchema = z.object({...observation,arrivedAt:time.nullable(),received:usableQuantitySchema.nullable()}).strict();
export const usableObservationSchema = z.object({...observation,arrivalObservationId:id,confirmedAt:time,usable:usableQuantitySchema.nullable()}).strict();
export const reservationSchema = z.object({id,sourceId:id,needId:id,quantity:mealQuantity}).strict();
// Manual observations follow the household pantry revision chain. They carry no
// retailer arrival, order line, receipt, or member identity into the projection.
const pantryObservationHistoryRow = z.object({
  householdId:id, id, sourceId:id, identityRevision:revision.min(1), revision:revision.min(1),
  predecessorId:id.nullable(), confirmedAt:time, recordedAt:time, quantity:usableQuantitySchema.nullable(),
}).strict();
// Already committed elsewhere, in an exact physical unit. A null hold means
// the loader could not quantify that source's foreign commitments.
const foreignHold = z.object({sourceId:id, quantity:z.object({
  unit:mealQuantity.shape.unit, amount:z.object({
    numerator:z.string().regex(/^(0|[1-9][0-9]*)$/).max(4096),
    denominator:z.string().regex(/^[1-9][0-9]*$/).max(4096),
  }).strict(),
}).strict().nullable()}).strict();
export const recoveryBasisSchema = z.object({...scoped,base:recoveryBaseSchema,
  // These rows must be read from trusted transaction state; this schema is NOT a request body.
  foods:z.array(z.object({id,name:label,exclusionTags:z.array(label).max(20)}).strict()).max(1000),
  sources:z.array(sourceSchema).max(1000),arrivals:z.array(arrivalObservationSchema).max(5000),usable:z.array(usableObservationSchema).max(5000),
  selectedCarrySourceIds:z.array(id).max(1000).optional(),carrySupplyRevisions:z.array(z.object({shopId:id,supplyRevision:revision}).strict()).max(1000).optional(),
  pantryObservations:z.array(pantryObservationHistoryRow).max(5000).optional(),foreignHolds:z.array(foreignHold).max(1000).optional(),
  meals:z.array(recoveryMealSchema).max(100),outsideNeeds:z.array(recoveryNeedSchema).max(1000),reservations:z.array(reservationSchema).max(1000),
  usedNeedIds:z.array(id).max(10000),usedRevisionIds:z.array(id).max(10000),knownTemplateIds:z.array(id).max(1000),
  commitmentInventoryComplete:z.boolean(),
}).strict();
export type RecoveryBasis=z.infer<typeof recoveryBasisSchema>;
export type RecoveryMeal=z.infer<typeof recoveryMealSchema>;
export type RecoveryNeed=z.infer<typeof recoveryNeedSchema>;
export type RecoveryIntent=z.infer<typeof recoveryIntentSchema>;
export type Quantity=z.infer<typeof usableQuantitySchema>;

const pantryScope = {pantryRevision:revision,supplyRevision:revision};
const storage = {location:z.enum(['pantry','freezer']),storedAt:time.nullable(),useFirstAt:time.nullable()};
const lot = {...pantryScope,lotId:id};
const target = {occurrenceId:id,mealRevision:revision.min(1),ingredientId:id};
export const pantryObservation = z.object({...lot,predecessorId:id.nullable(),confirmedAt:time,quantity:usableQuantitySchema.nullable()}).strict();
export const pantryBodies = {
  'pantry.create':z.object({...pantryScope,...storage,foodName:label,exclusionTags:z.array(label).max(20)}).strict(),
  'pantry.storeDelivery':z.object({...pantryScope,...storage,sourceId:id}).strict(),
  'pantry.observe':pantryObservation.extend({previewDigest:hash}),
  'pantry.select':z.object({...lot,selected:z.boolean()}).strict(),
  'pantry.match':z.object({...lot,...target,matched:z.boolean()}).strict(),
  'pantry.reserve':z.object({...lot,...target,groupId:id,predecessorId:id.nullable(),quantity:mealQuantity.nullable()}).strict(),
};
