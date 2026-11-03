/**
 * Restart checkpoint: PROPOSED provider-independent wire contract.
 * No production guardian enrollment routes or KWS adapter implement this file yet.
 * See service/GUARDIAN-ENROLLMENT-PLAN.md before implementing a caller.
 */
export type GuardianUUID = string;
export type GuardianLanguage = 'en' | 'es';
export type GuardianScope = 'own_requests';
export interface GuardianNotice {
  version: string; digest: string; locale: GuardianLanguage; text: string;
  scope: GuardianScope;
}
export interface GuardianNoticeResponse {
  available: boolean;
  reason: 'provider_configuration_required' | 'notice_approval_required' | null;
  notice: GuardianNotice | null;
}
export type GuardianEnrollmentState =
  | 'awaiting_verification' | 'verification_pending' | 'verification_uncertain'
  | 'verified' | 'consented' | 'child_claimed' | 'child_approved' | 'active'
  | 'cancelled' | 'expired' | 'withdrawn';
/** Only the initiating adult guardian can read this projection. */
export interface GuardianEnrollment {
  enrollmentId: GuardianUUID; revision: number; childId: GuardianUUID;
  state: GuardianEnrollmentState; childAlias: string | null;
  noticeVersion: string; noticeDigest: string; scope: GuardianScope;
  expiresAt: string; verifiedAt: string | null; consentedAt: string | null;
  claimId: GuardianUUID | null;
}
/** POST /v1/households/{h}/guardian/enrollments */
export interface GuardianEnrollmentCreate {
  clientKey: GuardianUUID; noticeVersion: string; noticeDigest: string;
  language: GuardianLanguage; childLocation: string;
  guardianDeclaration: 'parent_or_legal_guardian';
  /** Existing child requires this guardian's current relationship; absent creates an opaque slot. */
  childId?: GuardianUUID;
}
export interface GuardianReviewedAction { clientKey: GuardianUUID; baseRevision: number }
/** POST .../guardian/enrollments/{id}/verification. No client email field is accepted. */
export type GuardianVerificationStart = GuardianReviewedAction;
/** POST .../guardian/enrollments/{id}/consent; distinct from adult verification. */
export interface GuardianConsentGrant extends GuardianReviewedAction {
  noticeVersion: string; noticeDigest: string; childAlias: string; decision: 'grant';
}
/** POST .../guardian/enrollments/{id}/child-invitations */
export interface GuardianChildInvitationCreate extends GuardianReviewedAction {
  /** Client creates and durably retains 32 random bytes encoded as canonical base64url. */
  secret: string;
}
export interface GuardianChildInvitation {
  inviteId: GuardianUUID; token: string; expiresAt: string;
}
/** POST /v1/child-invitations/claim, with the child's live authenticated identity. */
export interface ChildInvitationClaim {
  clientKey: GuardianUUID; token: string;
  /** Proposed eight-character base32 pairing code, generated on the child's device. */
  pairingCode: string;
}
export interface ChildInvitationClaimReceipt {
  claimId: GuardianUUID; status: 'awaiting_guardian'; expiresAt: string;
}
/** POST .../guardian/enrollments/{id}/confirm-child */
export interface GuardianChildConfirmation extends GuardianReviewedAction {
  claimId: GuardianUUID; pairingCode: string;
}
/** POST /v1/child-invitations/finish, with the same live child subject/session as the claim. */
export interface ChildInvitationFinish { clientKey: GuardianUUID; claimId: GuardianUUID; pairingCode: string }
export interface ChildEnrollmentReceipt {
  householdId: GuardianUUID; memberId: GuardianUUID; role: 'contributor';
  deviceId: GuardianUUID; deviceToken: string;
}
/** POST .../guardian/enrollments/{id}/cancel uses GuardianReviewedAction. */
export interface GuardianWithdrawalReceipt { consentId: GuardianUUID; revoked: true }
