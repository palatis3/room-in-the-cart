/** Service v1 wire contracts. All IDs are opaque UUIDs. Money is integer USD cents. */
export type RequestStatus = 'pending' | 'clarified' | 'added' | 'deferred' | 'handled' | 'dismissed' | 'withdrawn';
export interface OwnRequest {
  requestId: string; shopId: string; revision: number; originalItem: string; ownQuantity: string | null;
  authoredAt: string; receivedAt: string; route: 'current' | 'next'; status: RequestStatus;
  ownActionAllowed: boolean; clarification: string | null; followupTo: string | null;
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
