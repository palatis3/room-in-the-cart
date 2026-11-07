import { deliverySourceBody, deliveryArrivalBody, deliveryUsableBody } from './recovery-contracts.js';
import { z } from 'zod';
import { sharedMealSchema } from './shared-meal-planning.js';
import {reviewedPackEvidenceSchema,matchesReviewedPack} from './request-pack-evidence.js';
export const uuid = z.string().uuid();
const minor = z.number().int().min(0).max(1_000_000_000);
const timestamp = z.string().datetime({ offset: true });
const item = z.string().trim().min(1).max(240);
const ownQuantity = z.string().trim().min(1).max(80).nullable();
export const lineSchema = z.object({ lineId: uuid, originalItem: item, packs: z.number().int().min(1).max(10_000), unitPriceMinor: minor.nullable(), feeEligible: z.boolean().default(true) }).strict();
export const quoteSchema = z.object({
  currency: z.literal('USD'), scope: z.enum(['wholeCheckout','item','dinner']), complete: z.boolean(), capMinor: minor.nullable(), capScope: z.enum(['wholeCheckout','item','dinner','unknown']),
  fee: z.discriminatedUnion('kind', [
    z.object({ kind: z.literal('fixed'), amountMinor: minor.nullable() }).strict(),
    z.object({ kind: z.literal('threshold'), thresholdMinor: minor, belowMinor: minor.nullable(), aboveMinor: minor.nullable() }).strict(),
  ]),
  taxesMinor: minor.nullable(), depositsMinor: minor.nullable(), discountsMinor: minor.nullable(),
  observedAt: timestamp, expiresAt: timestamp,
}).strict().refine(q => Date.parse(q.expiresAt)>Date.parse(q.observedAt), 'Quote expiry must follow observation');
export const decisionSchema = z.discriminatedUnion('choice', [
  z.object({ choice: z.literal('add'), line: lineSchema, promote: z.boolean().default(false), reviewedPackEvidence: reviewedPackEvidenceSchema.optional() }).strict(),
  z.object({ choice: z.literal('link'), lineId: uuid, promote: z.boolean().default(false) }).strict(),
  z.object({ choice: z.enum(['defer','dismiss','handled']) }).strict(),
 ]).superRefine((decision,ctx)=>{
  if(decision.choice==='add'&&decision.reviewedPackEvidence&&!matchesReviewedPack(decision.line,decision.reviewedPackEvidence))ctx.addIssue({code:'custom',message:'Reviewed pack evidence must match the chosen sufficient available whole packs',path:['reviewedPackEvidence']});
});
export const previewSchema = z.object({ requestId: uuid, base: z.object({ shopRevision: z.number().int().positive(), authorityEpoch: z.number().int().positive(), requestRevision: z.number().int().positive() }).strict(), decision: decisionSchema }).strict();
export const envelopeSchema = z.object({
  v: z.literal(1), replayWindow: uuid, clientKey: uuid, shopId: uuid,
  kind: z.enum(['delivery.register','delivery.arrival','delivery.usable','shop.create','shop.patch','shop.freeze','shop.reopen','shop.reportPlaced','shop.reconcileReport','shop.transferAuthority','request.send','request.edit','request.withdraw','request.clarify','request.apply']),
  base: z.object({ shopRevision: z.number().int().min(0), authorityEpoch: z.number().int().min(0), requestRevision: z.number().int().positive().optional() }).strict(),
  body: z.record(z.string(),z.unknown()),
}).strict();
const empty = z.object({}).strict();
const mealEdit = z.object({ occurrenceId: uuid, baseMealRevision: z.number().int().positive().nullable(), meal: sharedMealSchema.nullable(), proposalId: uuid.optional(), changeProposalId: uuid.optional() }).strict()
  .refine(value => !(value.proposalId && value.changeProposalId), 'Review one proposal at a time');
export const bodySchemas = {
  'delivery.register': deliverySourceBody, 'delivery.arrival': deliveryArrivalBody, 'delivery.usable': deliveryUsableBody,
  'shop.create': z.object({ quote: quoteSchema, lines: z.array(lineSchema).max(200) }).strict(),
  'shop.patch': z.object({ quote: quoteSchema, lines: z.array(lineSchema).max(200), mealEdit: mealEdit.optional(), reviewedStoreBasisRevision: z.number().int().positive().optional() }).strict(),
  'shop.freeze': empty, 'shop.reopen': empty,
  'shop.reportPlaced': z.object({ occurredAt: timestamp }).strict(),
  'shop.reconcileReport': z.object({ reportId: uuid, choice: z.enum(['apply','reject']) }).strict(),
  'shop.transferAuthority': z.object({ newShopperId: uuid }).strict(),
  'request.send': z.object({ clientRequestId: uuid, originalItem: item, ownQuantity, authoredAt: timestamp, followupTo: uuid.optional(), route: z.enum(['current','next']).default('current') }).strict(),
  'request.edit': z.object({ requestId: uuid, originalItem: item, ownQuantity }).strict(),
  'request.withdraw': z.object({ requestId: uuid }).strict(),
  'request.clarify': z.object({ requestId: uuid, question: z.string().trim().min(1).max(300) }).strict(),
  'request.apply': z.object({ requestId: uuid, previewId: uuid, acceptOverage: z.boolean(), acceptUnknown: z.boolean() }).strict(),
};
export type Envelope = z.infer<typeof envelopeSchema>;
export type Decision = z.infer<typeof decisionSchema>;
export type PreviewInput = z.infer<typeof previewSchema>;
export type Quote = z.infer<typeof quoteSchema>;
export type Line = z.infer<typeof lineSchema>;
export function parseCommand(value: unknown): Envelope {
  const command = envelopeSchema.parse(value);
  return { ...command, body: bodySchemas[command.kind].parse(command.body) };
}

const alias=z.string().trim().min(1).max(80);
export const householdCreateSchema=z.object({clientKey:uuid,label:alias,alias,adultAttestation:z.literal(true)}).strict();
export const inviteCreateSchema=z.object({kind:z.enum(['adult_contributor','child_contributor']),expiresInHours:z.number().int().min(1).max(168).default(24)}).strict();
export const inviteRedeemSchema=z.object({token:z.string().regex(/^[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/),intent:z.literal('join'),alias:alias.optional(),adultAttestation:z.literal(true)}).strict();
export const viewProjectionSchema=z.object({shopLabel:alias,language:z.enum(['en','es']),items:z.array(z.object({label:item,amount:z.string().trim().min(1).max(80).nullable(),unit:z.string().trim().min(1).max(80).nullable(),action:z.string().trim().min(1).max(500)}).strict()).max(200)}).strict();
export const viewCreateSchema=viewProjectionSchema.extend({shopId:uuid,mode:z.enum(['read','edit']),expiresInHours:z.number().int().min(1).max(168).default(24)}).strict();
export const viewUpdateSchema=viewProjectionSchema.extend({baseRevision:z.number().int().positive()}).strict();
export const proposalSchema=z.object({clientKey:uuid,baseRevision:z.number().int().positive(),correction:z.string().trim().min(1).max(1000)}).strict();
export const revocationSchema=z.object({kind:z.enum(['member','invite','view']),targetId:uuid}).strict();

// Preserve the exact reviewed text. The digest binds every field after structural validation.
const reviewedText=(maximum:number)=>z.string().min(1).max(maximum).refine(value=>value.trim().length>0);
export const reviewedProjectionSchema=z.object({shopLabel:reviewedText(80),language:z.enum(['en','es']),items:z.array(z.object({label:reviewedText(240),amount:reviewedText(80).nullable(),unit:reviewedText(80).nullable(),action:reviewedText(500)}).strict()).max(200)}).strict();
export const viewReplacementSchema=z.object({clientKey:uuid,baseRevision:z.number().int().positive(),projection:reviewedProjectionSchema}).strict();
export const proposalResolutionSchema=z.discriminatedUnion('decision',[
 z.object({clientKey:uuid,baseRevision:z.number().int().positive(),proposalRevision:z.number().int().positive(),decision:z.literal('dismiss')}).strict(),
 z.object({clientKey:uuid,baseRevision:z.number().int().positive(),proposalRevision:z.number().int().positive(),decision:z.literal('replace'),projection:reviewedProjectionSchema}).strict()
]);
