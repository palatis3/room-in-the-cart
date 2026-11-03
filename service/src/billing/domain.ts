import { ServiceError } from '../errors.js';

export type BillingStatus = 'active' | 'grace' | 'expired' | 'revoked' | 'free' | 'billingRetry';
export interface VerifiedSubscription {
  environment: 'Production' | 'Sandbox';
  originalTransactionID: string;
  transactionID: string;
  appAccountToken: string;
  productID: string;
  purchasedAt: number;
  signedAt: number;
  expiresAt: number;
  graceExpiresAt: number | null;
  status: Exclude<BillingStatus, 'free'>;
}
export interface EntitlementSnapshot {
  householdID: string; purchaserID: string; revision: number; status: BillingStatus;
  expiresAt: string | null; graceExpiresAt: string | null;
  verifiedAt: string; validUntil: string;
  seats: { userID: string; displayName: string; isAdult: boolean }[];
}
export const BILLING_CACHE_MS = 5 * 60 * 1000;
export const billingUnavailable = () => new ServiceError(503, 'billing_unavailable', 'Keep using Free and retry membership verification later.');
export const invalidApple = () => new ServiceError(422, 'billing_verification_failed', 'Restore purchases from the purchasing account.');
export const bindingConflict = () => new ServiceError(409, 'purchase_already_bound', 'Use the purchasing account and its original household.');

/** Apple event order, not receipt expiry order. Equal-version denial wins. */
export function supersedes(next: VerifiedSubscription, current: VerifiedSubscription): boolean {
  if (next.purchasedAt !== current.purchasedAt) return next.purchasedAt > current.purchasedAt;
  if (next.signedAt !== current.signedAt) return next.signedAt > current.signedAt;
  const severity = { active: 0, grace: 1, expired: 2, billingRetry: 3, revoked: 4 };
  return severity[next.status] > severity[current.status];
}
export function effectiveStatus(state: VerifiedSubscription, now: number): Exclude<BillingStatus, 'free'> {
  if (state.status === 'revoked' || state.status === 'billingRetry' || state.status === 'expired') return state.status;
  if (state.status === 'grace') return state.graceExpiresAt !== null && state.graceExpiresAt > now ? 'grace' : 'expired';
  return state.expiresAt > now ? 'active' : 'expired';
}
export function validityEnd(state: VerifiedSubscription, verifiedAt: number, now: number): number {
  const status = effectiveStatus(state, now);
  const end = status === 'active' ? state.expiresAt : status === 'grace' ? state.graceExpiresAt! : now;
  return Math.min(end, verifiedAt + BILLING_CACHE_MS);
}
export function hasPaidSeat(snapshot: EntitlementSnapshot, memberID: string, now: Date): boolean {
  return (snapshot.status === 'active' || snapshot.status === 'grace') && Date.parse(snapshot.validUntil) > now.getTime()
    && snapshot.seats.some(seat => seat.userID === memberID && seat.isAdult);
}
