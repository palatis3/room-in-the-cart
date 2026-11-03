/**
 * App-owned provider-independent wire contract.
 * Provider configuration and approved notices are deployment prerequisites.
 * See service/GUARDIAN-ENROLLMENT-PLAN.md before implementing a caller.
 */
export type GuardianUUID = string;
export type GuardianLanguage = 'en' | 'es';
export type GuardianScope = 'own_requests';
export interface GuardianNotice {
  version: string; digest: string; locale: GuardianLanguage; text: string;
  scope: GuardianScope; methodVersion: string;
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
/** POST /v1/households/{h}/guardian/enrollments. GET collection returns {enrollments: GuardianEnrollment[]}.
 * GET /{id} returns one. GET /guardian/notice?language=en|es returns GuardianNoticeResponse. */
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
  /** Collected only in this explicit action; retained server-side as a keyed digest. */
  childSignInEmail: string;
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
  householdId: GuardianUUID; claimId: GuardianUUID; status: 'awaiting_guardian'; expiresAt: string;
}
/** POST .../guardian/enrollments/{id}/confirm-child */
export interface GuardianChildConfirmation extends GuardianReviewedAction {
  claimId: GuardianUUID; pairingCode: string;
}
/** POST /v1/child-invitations/finish, with the same live child subject/session as the claim. */
export interface ChildInvitationFinish {
  clientKey: GuardianUUID; householdId: GuardianUUID; claimId: GuardianUUID; pairingCode: string;
  /** Canonical base64url of 32 device-generated random bytes, retained with exact retry intent. */
  deviceSecret: string;
}
/** GET /v1/child-invitations/claims/{id}?householdId={h}, same live child session. */
export interface ChildInvitationClaimStatus {
  claimId: GuardianUUID; status: 'awaiting_guardian' | 'approved' | 'active' | 'ended'; expiresAt: string;
}
export interface ChildEnrollmentReceipt {
  householdId: GuardianUUID; memberId: GuardianUUID; role: 'contributor';
  deviceId: GuardianUUID; deviceToken: string;
}
/** POST .../guardian/enrollments/{id}/cancel uses GuardianReviewedAction. */
export interface GuardianWithdrawalReceipt { consentId: GuardianUUID; revoked: true }

/** POST /v1/child-invitations/auth/start, before child provider signup/sign-in.
 * Requires the current BFF challenge cookie, configured Origin + x-csrf-token.
 * Continue through existing /v1/auth/email/verify, then claim with that live session. */
export interface ChildInvitationAuthStart { token: string; email: string }
/** POST /v1/child-invitations/native-auth/start, before direct native OTP verification.
 * Server sends OTP only after current guardian permission and exact email binding. */
export interface ChildNativeAuthStart { clientKey:GuardianUUID;token:string;email:string;challengeSecret:string }
export interface ChildNativeAuthChallenge { householdId:GuardianUUID;challengeId:GuardianUUID;status:'check_email';expiresAt:string }
/** POST /v1/child-invitations/native-auth/admit with the freshly verified child's
 * bearer session. Native verifies OTP with its configured provider and saves its
 * access/refresh session in the existing protected vault; no credentials return here. */
export interface ChildNativeAuthAdmit { clientKey:GuardianUUID;householdId:GuardianUUID;challengeId:GuardianUUID;challengeSecret:string }

/** Browser finish installs its HttpOnly scoped cookie and returns no credential.
 * GET /v1/session then returns the existing authenticated bootstrap/replayWindow/
 * csrf projection. Its provider session refresh remains /v1/auth/refresh. */
export type ChildBrowserEnrollmentReceipt = Omit<ChildEnrollmentReceipt, 'deviceToken'>;
/** GET /v1/guardian/availability?language=en|es (public, no invitation/parent data). */
export type GuardianAvailability = Pick<GuardianNoticeResponse, 'available' | 'reason'>;
/** GET /v1/child-invitations/session (BFF cookies, no query). This is the
 * authoritative invitation-bound admission after OTP verify and on reload.
 * Generic /v1/auth/session authenticated=true does not imply this admission. */
export interface ChildInvitationSession {
  available:boolean; authenticated:boolean; admitted:boolean; scope:GuardianScope|null;
  householdId:GuardianUUID|null; inviteId:GuardianUUID|null; claimId:GuardianUUID|null;
  status:'none'|'admitted'|'awaiting_guardian'|'approved'|'active'|'ended'; expiresAt:string|null;
}
