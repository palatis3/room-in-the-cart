/** Private acceptance evidence and proposed dedicated request Undo wire v1.
 * No schema here authorizes untrusted input or performs database writes. */
import {z} from 'zod';
import {quoteSchema,decisionSchema} from './contracts.js';
import {sharedDemandGraphSchema,sharedDemandReceiptSchema} from './shared-demand-contracts.js';
import {factSchema,trackingStateSchema} from './shared-demand-tracking.js';
export const requestUndoID=z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
const id=requestUndoID,rev=z.number().int().min(1).max(2147483646),hash=z.string().regex(/^[a-f0-9]{64}$/).refine(x=>x!=='0'.repeat(64)),time=z.string().datetime({offset:true});
const lineSchema=z.object({lineId:id,originalItem:z.string().min(1).max(240).refine(x=>x===x.trim()),packs:z.number().int().min(1).max(10000),unitPriceMinor:z.number().int().min(0).max(1000000000).nullable(),feeEligible:z.boolean()}).strict();
export const requestStateSchema=z.object({revision:rev,status:z.enum(['pending','clarified','deferred','added']),route:z.enum(['current','next'])}).strict();
export const requestContentSchema=z.object({requestId:id,shopId:id,authorId:id,authorKind:z.enum(['adult','child']),consentId:id.nullable(),
 originalItem:z.string().min(1).max(240),ownQuantity:z.string().min(1).max(80).nullable(),clarification:z.string().max(300).nullable(),
 authoredAt:time,receivedAt:time,followupTo:id.nullable()}).strict();
export const requestLinkSchema=z.object({requestId:id,shopId:id,lineId:id,reviewedRevision:rev,operationId:id}).strict();
export const carryOriginSchema=z.object({sourceRequestId:id,targetRequestId:id,sourceShopId:id,targetShopId:id,
 sourceAuthorityEpoch:rev,targetAuthorityEpoch:rev,operationId:id}).strict();
const basis=z.object({revision:rev.nullable(),reviewRequired:z.boolean()}).strict();
const money=z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
export const requestUndoBudgetSchema=z.object({currency:z.literal('USD'),totalMinor:money.nullable(),overCapMinor:money.nullable(),headroomMinor:z.number().int().min(-Number.MAX_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER).nullable(),
 status:z.enum(['withinCap','overCap','unresolved','scopeMismatch']),scope:z.enum(['wholeCheckout','item','dinner']),
 missing:z.array(z.enum(['remaining_original_items','line_price','fee','tax','deposit','discount','cap','scope_mismatch'])).max(8),
 lowerBoundMinor:money,upperBoundMinor:money.nullable(),wholeCheckoutWithinCap:z.boolean()}).strict();
export const requestUndoSnapshotSchema=z.object({shopId:id,revision:rev,phase:z.literal('draft'),storeBasis:basis.optional(),
 demand:z.object({schemaVersion:z.literal(1),revision:rev,digest:hash}).strict().optional(),
 tracking:z.object({schemaVersion:z.literal(2),shopRevision:rev,digest:hash,status:z.literal('recorded')}).strict().optional(),
 mealRefs:z.array(z.object({occurrenceId:id,revision:rev}).strict()).max(100).optional(),quote:quoteSchema,lines:z.array(lineSchema).max(200),budget:requestUndoBudgetSchema}).strict();
const foodCertificate=z.discriminatedUnion('kind',[
 z.object({kind:z.literal('legacy')}).strict(),
 z.object({kind:z.literal('tracked'),beforeRevision:rev,afterRevision:rev,beforeDigest:hash,afterDigest:hash,receiptDigest:hash}).strict(),
 // Recognized, but this first packet cannot derive a mixed-adoption inverse.
 z.object({kind:z.literal('compoundAdoption'),afterRevision:z.literal(1),afterDigest:hash,receiptDigest:hash,compositionDigest:hash}).strict()
]);
export const requestAcceptanceCertificateSchema=z.object({schemaVersion:z.literal(1),householdId:id,shopId:id,operationId:id,actorId:id,deviceId:id,
 authorityEpoch:rev,payloadDigest:hash,baseShopRevision:rev,resultShopRevision:rev,requestId:id,authorId:id,authorKind:z.enum(['adult','child']),consentId:id.nullable(),
 contentDigest:hash,before:requestStateSchema,after:requestStateSchema,decision:decisionSchema,
 beforeLink:z.null(),afterLink:requestLinkSchema,beforeLinksDigest:hash,afterLinksDigest:hash,
 beforeSnapshotDigest:hash,afterSnapshotDigest:hash,food:foodCertificate,carry:z.array(carryOriginSchema).max(50),privacyMemberIds:z.array(id).min(1).max(100)
}).strict();
export type RequestAcceptanceCertificate=z.infer<typeof requestAcceptanceCertificateSchema>;
export const requestAcceptanceRecordSchema=z.object({certificate:requestAcceptanceCertificateSchema,digest:hash}).strict();
export const requestUndoHistoricalSchema=z.object({record:requestAcceptanceRecordSchema,
 operation:z.object({householdId:id,shopId:id,operationId:id,kind:z.literal('request.apply'),actorId:id,deviceId:id,payloadDigest:hash}).strict(),
 beforeSnapshot:z.object({operationId:id,value:requestUndoSnapshotSchema,digest:hash}).strict(),afterSnapshot:z.object({operationId:id,value:requestUndoSnapshotSchema,digest:hash}).strict(),
 food:z.discriminatedUnion('kind',[
  z.object({kind:z.literal('legacy')}).strict(),
  z.object({kind:z.literal('tracked'),before:sharedDemandGraphSchema,after:sharedDemandGraphSchema,receipt:sharedDemandReceiptSchema,partition:z.object({before:trackingStateSchema.nullable(),after:trackingStateSchema}).strict().optional()}).strict(),
  z.object({kind:z.literal('compoundAdoption'),after:sharedDemandGraphSchema,receipt:sharedDemandReceiptSchema,compositionDigest:hash}).strict()
 ])
}).strict();
export const requestUndoLiveSchema=z.object({householdId:id,shopId:id,actorId:id,deviceId:id,authorityEpoch:rev,assignedShopperId:id,
 actorActive:z.boolean(),deviceActive:z.boolean(),shopperScope:z.boolean(),
 privacyMembers:z.array(z.object({memberId:id,available:z.boolean()}).strict()).max(100),
 author:z.object({memberId:id,kind:z.enum(['adult','child']),consentId:id.nullable(),disclosureLive:z.boolean()}).strict(),
 carry:z.array(carryOriginSchema.extend({sourceShopperId:id,sourceCurrentAuthorityEpoch:rev,targetCurrentAuthorityEpoch:rev,disclosureLive:z.boolean()}).strict()).max(50),
 storeBasis:z.object({revision:rev,pairId:id,choice:z.enum(['first','second']),selectionDigest:hash}).strict().nullable()
}).strict();
export const requestUndoCurrentSchema=z.object({shopRevision:rev,authorityEpoch:rev,phase:z.literal('draft'),storeBasis:basis,
 lines:z.array(lineSchema).max(200),quote:quoteSchema,mealRefs:z.array(z.object({occurrenceId:id,revision:rev}).strict()).max(100),
 request:z.object({content:requestContentSchema,state:requestStateSchema}).strict(),links:z.array(requestLinkSchema).max(2000),
 food:z.discriminatedUnion('kind',[
  z.object({kind:z.literal('legacy'),catalog:z.array(factSchema).max(2000)}).strict(),
  z.object({kind:z.literal('tracked'),graph:sharedDemandGraphSchema}).strict(),
  z.object({kind:z.literal('partition'),state:trackingStateSchema}).strict()
 ])
}).strict();
export const requestUndoActionSchema=z.object({kind:z.literal('request.undoAcceptance'),body:z.object({
 targetOperationId:id,requestId:id,baseRequestRevision:rev,lines:z.array(lineSchema).max(200),quote:quoteSchema
}).strict()}).strict();
const sourceState=z.discriminatedUnion('kind',[
 z.object({kind:z.literal('legacy'),catalog:z.array(factSchema).max(2000)}).strict(),
 z.object({kind:z.literal('tracked'),graph:sharedDemandGraphSchema}).strict(),
  z.object({kind:z.literal('partition'),state:trackingStateSchema}).strict()
]);
export const requestUndoCandidateSchema=z.object({schemaVersion:z.literal(1),kind:z.literal('requestAcceptanceUndo'),shopId:id,targetOperationId:id,effectDigest:hash,
 base:z.object({shopRevision:rev,authorityEpoch:rev,requestRevision:rev,food:z.discriminatedUnion('kind',[
  z.object({kind:z.literal('legacy'),catalogDigest:hash}).strict(),z.object({kind:z.literal('tracked'),graphRevision:rev,graphDigest:hash}).strict(),
  z.object({kind:z.literal('partition'),graphRevision:rev,graphDigest:hash,stateDigest:hash,privacyRevision:z.number().int().min(0)}).strict()
 ])}).strict(),
 action:requestUndoActionSchema,requestUndo:z.object({requestId:id,choice:z.enum(['add','link']),originalItem:z.string().min(1).max(240),originalQuantityText:requestContentSchema.shape.ownQuantity,
 targetBefore:requestStateSchema,targetAfter:requestStateSchema,current:requestStateSchema,restored:requestStateSchema,
 beforeLink:requestLinkSchema,afterLink:z.null(),carry:z.array(carryOriginSchema).max(50)}).strict(),
 scope:z.object({requestsChanged:z.literal(true),mealsChanged:z.literal(false),quoteChanged:z.literal(false),firstAdoptionReversed:z.literal(true).optional(),
 touchedLines:z.array(z.object({lineId:id,fields:z.array(z.enum(['membership','originalItem','packs','unitPriceMinor','feeEligible'])).min(1)}).strict()).max(200),graphRows:z.number().int().min(0).max(6200)}).strict(),
 foodBefore:sourceState,foodAfter:sourceState,beforeCheckout:requestUndoBudgetSchema,afterCheckout:requestUndoBudgetSchema,
 packReviewLineIds:z.array(id).max(200),storeBasis:requestUndoLiveSchema.shape.storeBasis
}).strict();
export const requestUndoInverseRecordSchema=z.object({operationId:id,targetOperationId:id,actorId:id,deviceId:id,authorityEpoch:rev,
 clientKey:id,payloadDigest:hash,acceptanceDigest:hash,
 receipt:z.object({operationId:id,kind:z.literal('request.undoAcceptance'),shopId:id,shopRevision:rev,authorityEpoch:rev,
 disposition:z.literal('acceptanceUndone'),requestId:id,requestRevision:rev}).strict()
}).strict();
export type RequestUndoHistorical=z.infer<typeof requestUndoHistoricalSchema>;
export type RequestUndoCurrent=z.infer<typeof requestUndoCurrentSchema>;
export type RequestUndoLive=z.infer<typeof requestUndoLiveSchema>;
/** Proposed request-family endpoints. Shape validation is not source/pack/authority
 * validation; repository hooks must rederive and compare the complete candidate. */
const pack=z.object({lineId:id,usablePerPack:factSchema.shape.quantity,acceptUnresolved:z.boolean()}).strict();
export const requestUndoPreviewInputSchema=z.object({targetOperationId:id,base:requestUndoCandidateSchema.shape.base,effectDigest:hash,packs:z.array(pack).max(200),acceptOverage:z.boolean(),acceptUnknown:z.boolean()}).strict();
export const requestUndoApplyBodySchema=requestUndoActionSchema.shape.body.extend({operationUndoReview:z.object({previewId:id,previewDigest:hash}).strict()}).strict();
export const requestUndoPreviewResponseSchema=z.object({schemaVersion:z.literal(1),kind:z.literal('requestAcceptanceUndoPreview'),candidate:requestUndoCandidateSchema,
 previewId:id,previewDigest:hash,expiresAt:time,operationId:id,packs:z.array(pack).max(200),
 foodReceipt:z.discriminatedUnion('kind',[z.object({kind:z.literal('legacy'),receipt:z.null()}).strict(),z.object({kind:z.literal('tracked'),receipt:sharedDemandReceiptSchema}).strict()])
}).strict();
