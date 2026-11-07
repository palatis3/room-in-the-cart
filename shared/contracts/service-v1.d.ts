/** Service v1 wire contracts. All IDs are opaque UUIDs. Money is integer USD cents. */
export type RequestStatus = 'pending' | 'clarified' | 'added' | 'deferred' | 'handled' | 'dismissed' | 'withdrawn';
export interface OwnRequest {
  requestId: string; shopId: string; revision: number; originalItem: string; ownQuantity: string | null;
  authoredAt: string; receivedAt: string; route: 'current' | 'next'; status: RequestStatus;
  carriedForward?: true; fromPreviousShop?: true;
  purchaseOutcome?: 'bought' | 'notBought';
  ownActionAllowed: boolean; clarification: string | null; followupTo: string | null;
}
export type RequestPurchaseOutcome=NonNullable<OwnRequest['purchaseOutcome']>|'unknown';
export interface ShopperInboxRequest extends OwnRequest {authorAlias:string;linkedLineId?:string}
export interface ConfirmRequestPurchaseBody {requestId:string;lineId:string;placedRevision:number;outcome:RequestPurchaseOutcome}
export interface ConfirmRequestPurchaseReceipt extends ShopperReceipt {
  kind:'request.confirmPurchase';disposition:'recorded';requestId:string;requestRevision:number;purchaseOutcome:RequestPurchaseOutcome;
}
export interface CommandBase { shopRevision: number; authorityEpoch: number; requestRevision?: number }
export interface CommandEnvelope {
  v: 1; replayWindow: string; clientKey: string; shopId: string;
  kind: string; base: CommandBase; body: Record<string, unknown>;
}
export interface OwnReceipt { operationId: string; kind: string; request: OwnRequest }
export interface ShopperReceipt {
  operationId: string; kind: string; shopId: string; shopRevision: number; authorityEpoch: number;
  disposition: string; requestId?: string; requestRevision?: number; reportId?: string;
}
export type FeeRule = { kind: 'fixed'; amountMinor: number | null } |
  { kind: 'threshold'; thresholdMinor: number; belowMinor: number | null; aboveMinor: number | null };
export interface BasketLine { lineId: string; originalItem: string; packs: number; unitPriceMinor: number | null; feeEligible: boolean }
export interface QuoteBasis {
  currency: 'USD'; scope: 'wholeCheckout' | 'item' | 'dinner'; complete: boolean; capMinor: number | null; capScope: 'wholeCheckout' | 'item' | 'dinner' | 'unknown';
  fee: FeeRule; taxesMinor: number | null; depositsMinor: number | null; discountsMinor: number | null;
  observedAt: string; expiresAt: string;
}
export interface BudgetResult {
  currency: 'USD'; totalMinor: number | null; overCapMinor: number | null; headroomMinor: number | null;
  status: 'withinCap' | 'overCap' | 'unresolved' | 'scopeMismatch'; scope: QuoteBasis['scope']; missing: string[];
  lowerBoundMinor: number; upperBoundMinor: number | null; wholeCheckoutWithinCap: boolean;
}
export interface RequestPreview {
  previewId: string; expiresAt: string; shopRevision: number; authorityEpoch: number; requestRevision: number;
  choice: 'add' | 'link' | 'defer' | 'dismiss' | 'handled'; before: BudgetResult; after: BudgetResult;
  changeMinor: number | null; requiresOverageAcceptance: boolean; requiresUnknownAcceptance: boolean;
}
export interface ServiceError { error: { code: string; correlationId: string; recovery: string } }

export interface SharedMealAmount { numerator: number; denominator: number }
export interface SharedMealQuantity {
  amount: SharedMealAmount;
  unit: 'count'|'gram'|'kilogram'|'ounce'|'pound'|'milliliter'|'liter'|'fluidOunce'|'cup';
  originalLiteral: string;
}
export interface SharedMealPlanning {
  sourceOccurrenceId?: string; // Explicit reviewed local-to-shared mapping; never an authority claim.
  exclusions?: string[];
  leadTimeMinutes?: number;
  completedSteps?: string[];
  groups: Array<{id:string;name:string;servings:SharedMealAmount;protected:boolean}>;
  ingredients: Array<{id:string;name:string;quantity:SharedMealQuantity|null;groupIds:string[];exclusions:string[]}>;
  bindings?: Array<{id:string;groupId:string;ingredientId:string;quantity:SharedMealQuantity}>;
}
export interface SharedMeal {
  title: string;
  day: string; // Civil date, YYYY-MM-DD
  kind: 'dinner' | 'lunch' | 'side';
  portions: number;
  protected: boolean;
  planning?: SharedMealPlanning;
}
export interface SharedMealEdit {
  occurrenceId: string;
  baseMealRevision: number | null;
  meal: SharedMeal | null;
  proposalId?: string;
  changeProposalId?: string; // Mutually exclusive with date proposalId.
}
export interface SharedMealPlan {
  shopId: string;
  shopRevision: number;
  authorityEpoch: number;
  grantRevision: number;
  shopper: boolean;
  plannerId: string | null;
  adults: Array<{ id: string; label: string }>;
  meals: Array<{ occurrenceId: string; revision: number; meal: SharedMeal }>;
  proposals: Array<{ proposalId: string; occurrenceId: string; day: string }>;
}

/** Private, optional shopper add-decision provenance; never part of an author/child projection. */
export interface ReviewedRequestPackQuantity { numerator:string; denominator:string; unit:'count'|'gram'|'kilogram'|'ounce'|'pound'|'milliliter'|'liter'|'fluidOunce'|'cup'; originalLiteral:string }
export interface ReviewedRequestPackEvidence {
  version:1; offerId:string; label:string; needed:ReviewedRequestPackQuantity; usablePerPack:ReviewedRequestPackQuantity;
  packs:number; unitPriceMinor:number|null; productMatchConfirmed:true; availabilityConfirmed:true; availablePackLimit:number|null;
  quoteSource:string; quoteObservedAt:string; reviewedAt:string;
}
export type ShopperRequestDecision={choice:'add';line:BasketLine;promote:boolean;reviewedPackEvidence?:ReviewedRequestPackEvidence}|{choice:'link';lineId:string;promote:boolean}|{choice:'defer'|'dismiss'|'handled'};

/** Existing occurrence changes require positive baseMealRevision, an unchanged date, and the current named planning adult. */
export interface SharedMealChangeRequest {
  proposalId: string;
  occurrenceId: string;
  baseMealRevision: number | null;
  shopRevision: number;
  authorityEpoch: number;
  grantRevision: number;
  meal: SharedMeal;
  reason: string;
  approvedIdeaId?: string; // Required with approvedIdeaRevision for explicit new-occurrence creation only.
  approvedIdeaRevision?: number;
}
export interface SharedMealChangePage {
  shopId: string;
  shopRevision: number;
  authorityEpoch: number;
  grantRevision: number;
  phase: 'draft'|'frozen'|'placed'|'closed';
  shopper: boolean;
  meals: Array<{occurrenceId:string;revision:number;meal:SharedMeal}>;
  proposals: Array<{proposalId:string;request:SharedMealChangeRequest;original:SharedMeal|null;state:'pending'|'applied'|'dismissed'}>;
}

/** Named reservation for one source and one exact group requirement in a placed meal. */
export interface DeliveryReservationTarget {
  occurrenceId: string;
  mealRevision: number;
  ingredientId: string;
  groupId: string;
}
export interface DeliveryReserveBody extends DeliveryReservationTarget {
  supplyRevision: number;
  sourceId: string;
  predecessorId: string | null;
  quantity: SharedMealQuantity | null; // Release the current reservation with explicit null.
}
export interface DeliveryReserveCommand extends Omit<CommandEnvelope, 'kind' | 'body'> {
  kind: 'delivery.reserve';
  body: DeliveryReserveBody;
}
export interface DeliveryReservationHead extends DeliveryReservationTarget {
  reservationId: string; // operationId in the accepted command receipt, including releases.
  quantity: SharedMealQuantity | null;
}
export interface DeliveryReservationCoverage {
  sourceId: string;
  reservationId: string;
  requested: {numerator: string; denominator: string};
  backed: {numerator: string; denominator: string}; // Exact fractions in the row's required unit.
}
/** A shopper-only line in the sealed order. Older projections may omit the ordered whole-pack count. */
export interface DeliveryEvidenceLine { lineId: string; name: string; packs?: number }
/** Additive fields for evidence pages, their sources, and coverage needs. */
export interface DeliveryEvidencePageReservations { reservationsAvailable?: boolean }
export interface DeliverySourceReservations { reservations?: DeliveryReservationHead[] }
export interface DeliveryNeedReservations { reservations?: DeliveryReservationCoverage[] }

export interface DatedCookCopyBody {
  pantryRevision?: number;
  placedRevision: number;
  supplyRevision: number;
  occurrenceId: string;
  mealRevision: number;
  language: 'en' | 'es';
  text: string;
}
export interface DatedCookCopy extends DatedCookCopyBody {
  copyId: string;
  shopId: string;
  shopRevision: number;
  authorityEpoch: number;
  version: number;
  createdAt: string;
}
export interface DatedCookCopyPage {
  copies: DatedCookCopy[];
  nextCursor: string | null;
}
export interface MarkCookCopySentBody {
  copyId: string;
  recipient: string;
  previousSendId: string | null;
}
export interface DatedCookCopyReceipt extends ShopperReceipt {
  kind: 'cookCopy.save' | 'cookCopy.markSent';
  disposition: 'recorded';
  copyId: string;
}
export interface CookCopyBaselineRequest { occurrenceId: string; recipient: string }
export interface CookCopyBaseline {
  baseline: {
    copy: DatedCookCopy;
    send: { sendId: string; copyId: string; recipient: string; sentAt: string };
  } | null;
}

/** Household-entered stock is reviewed explicitly against each sealed shop. */
export interface PantryScope {
  shopId:string; shopRevision:number; placedRevision:number; authorityEpoch:number;
  supplyRevision:number; pantryRevision:number; asOf:string;
}
export type PantryMatch=Omit<DeliveryReservationTarget,'groupId'>;
export type PantryLocation='pantry'|'freezer';
export interface PantryStorage {location:PantryLocation;storedAt:string|null;useFirstAt:string|null}
export interface PantryObservation {observationId:string;confirmedAt:string;quantity:SharedMealQuantity|null}
export interface PantryLot extends PantryStorage {
  lotId:string;origin:'manual'|'delivery';foodName:string;exclusionTags:string[];
  observation:PantryObservation|null;selected:boolean;matches:PantryMatch[];reservations:DeliveryReservationHead[];
}
export interface PantryPage extends PantryScope {lots:PantryLot[];nextCursor:string|null}
export type PantryReview=Pick<PantryScope,'pantryRevision'|'supplyRevision'>;
export interface PantryObservationProposal extends PantryReview {
  lotId:string;predecessorId:string|null;confirmedAt:string;quantity:SharedMealQuantity|null;
}
export type PantryCommandBodies = {
  'pantry.create':PantryReview & PantryStorage & {foodName:string;exclusionTags:string[]};
  'pantry.storeDelivery':PantryReview & PantryStorage & {sourceId:string};
  'pantry.observe':PantryObservationProposal & {previewDigest:string};
  'pantry.select':PantryReview & {lotId:string;selected:boolean};
  'pantry.match':PantryReview & PantryMatch & {lotId:string;matched:boolean};
  'pantry.reserve':PantryReview & DeliveryReservationTarget & {lotId:string;predecessorId:string|null;quantity:SharedMealQuantity|null};
};
export interface PantryReceipt extends ShopperReceipt,PantryReview {lotId:string;kind:keyof PantryCommandBodies}
export type ExactSupplyFraction={numerator:string;denominator:string};
export interface PantryNeed extends PantryMatch {
  groupIds:string[];protected:boolean;required:SharedMealQuantity|null;issues:string[];
  covered:ExactSupplyFraction|null;missing:ExactSupplyFraction|null;
  delivered:ExactSupplyFraction|null;pantry:ExactSupplyFraction|null;freezer:ExactSupplyFraction|null;
  reservations:DeliveryReservationCoverage[];
  allocations:{sourceId:string;kind:'delivery'|PantryLocation;amount:ExactSupplyFraction}[];
}
export interface PantryCoverage extends PantryScope {unplannedOccurrenceIds:string[];needs:PantryNeed[]}
export interface PantryObservationPreview extends PantryScope {
  lotId:string;previewDigest:string;otherShopsAffected:boolean;otherShopsCommitted:boolean;
  needs:(PantryMatch & {groupIds:string[];required:SharedMealQuantity|null;beforeCovered:ExactSupplyFraction|null;
    afterCovered:ExactSupplyFraction|null;beforeMissing:ExactSupplyFraction|null;afterMissing:ExactSupplyFraction|null;
    beforeReservations:DeliveryReservationCoverage[];afterReservations:DeliveryReservationCoverage[]})[];
}

export interface AcceptedFallbackRecipe {
  title:string; portions:number; notes:string; sourceURL:string|null; exclusions:string[];
  elapsedMinutes:number|null; requiredLeadMinutes:number|null;
  groups?:Array<{id:string;name:string;servings:SharedMealAmount;protected:boolean;exclusions:string[]}>;
  ingredients:Array<{id:string;name:string;notes?:string;quantity:SharedMealQuantity|null;exclusions:string[];groupIds?:string[];
    bindings?:Array<{groupId:string;quantity:SharedMealQuantity}>}>;
}
export interface AcceptedFallback { candidateId:string;revision:number;usual:boolean;recipe:AcceptedFallbackRecipe }
export interface FallbackRegistryScope { shopId:string;shopRevision:number;authorityEpoch:number;registryRevision:number }
export interface FallbackRegistryPage extends FallbackRegistryScope {candidates:AcceptedFallback[];nextCursor:string|null}
export type FallbackSource = {kind:'idea';ideaId:string;revision:number} |
  {kind:'meal';occurrenceId:string;mealRevision:number;revisionId:string|null};
export interface FallbackSourceReview extends FallbackRegistryScope {source:FallbackSource;recipe:AcceptedFallbackRecipe}
export type FallbackRegistryChange = Omit<FallbackRegistryScope,'shopId'> &
  {v:1;clientKey:string;candidateId:string;baseRevision:number|null;reviewed:true} &
  ({action:'accept';source:FallbackSource|{kind:'disclosed'};usual:boolean;recipe:AcceptedFallbackRecipe}|{action:'revoke'});
export interface FallbackRegistryReceipt extends FallbackRegistryScope {candidateId:string;revision:number;accepted:boolean}
