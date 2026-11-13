# Household and helper HTTP contracts

Implemented service contracts, 2026-11-03. All IDs are opaque UUIDs. Mutation objects are strict allowlists. Errors use `{error:{code,correlationId,recovery}}`; private payloads and database errors are never included. Identity requires a signed provider JWT and a live `auth.sessions` row bound to its signed subject. Native household calls also require `X-Device-Token`; browser calls use the existing secure session cookie and `X-CSRF-Token` plus the configured exact Origin for mutations.

## Adult household and invitations

| Route | Input | Successful output |
|---|---|---|
| `POST /v1/households` | `{clientKey,label,alias,adultAttestation:true}` | HTTP 201 `{householdId,memberId,role:'organizer'}`. Same identity/key/body returns the same receipt; changed body is `409 key_reused`. |
| `POST /v1/households/{h}/devices` | `{}` | HTTP 201 `{deviceId,deviceToken}`. Enroll only after membership exists. |
| `GET /v1/households/{h}/members` | — | Organizer only: `{members:[{memberId,alias,kind,state,role}]}`. No credential, guardian proof, budget or billing data. |
| `POST /v1/households/{h}/invites` | `{kind:'adult_contributor',expiresInHours?:1..168}` | `{inviteId,token,expiresAt}`; default expiry 24 hours. Organizer only. |
| `POST /v1/invites/redeem` | `{token,intent:'join',adultAttestation:true,alias?:string}` | `{householdId,memberId,role:'contributor'|'helper'|'editor',grantId?:UUID}`. Bearer identity or current authenticated cookie with CSRF. |
| `POST /v1/households/{h}/revocations` | `{kind:'member'|'invite'|'view',targetId}` | `{revoked:true,kind,targetId}`. Organizer manages membership/invitations; assigned shopper may revoke a view for their shop. |

Labels and aliases are 1–80 characters. Adult attestation is a self-declaration, not provider-verified age evidence. An identity already enrolled as a child cannot acquire adult authority through creation or redemption. Child invitation kind `child_contributor` returns `503 consent_unavailable`; no client payload records verification evidence.

Invite tokens have format `householdUUID.randomSecret` and only a SHA-256 hash is stored. Redemption, membership and helper grant binding are one transaction. A different identity cannot redeem a consumed token. The original identity may retry while its membership, invitation and any view grant remain valid. Revoked/expired links return `404 unavailable`; no secret is returned by a read endpoint. Rejoining a revoked membership needs a new invite. An active shopper must be transferred before member revocation.

## Browser activation and exact helper context

`POST /v1/session` accepts `{householdId,grantId?:UUID}` and returns the existing secure cookie plus the session DTO below. After invite redemption, pass the returned `householdId` and `grantId`. An authenticated browser may switch household using its existing CSRF token. A helper session stays bound to the selected grant; expiry or revocation returns `403 access_ended`, never a different helper view.

`GET /v1/session` returns `{authenticated:false}` when there is no session, or:

```ts
{
  authenticated: true,
  household: {id: string, label: string}, memberId: string,
  role: 'shopper'|'organizer'|'contributor'|'helper'|'editor',
  shopId: string|null, grantId?: string, enrolled: true, queueConsent: boolean, canSetRequestQueue: boolean,
  requestQueueGrant?: string, requestQueueUntil?: string,
  capabilities: string[], replayWindow: {id:string, expiresAt:string}, csrf:string
}
```

`GET /v1/households/{h}/bootstrap` returns the same household/member/role/shop/grant/enrollment/capability fields without session/CSRF/replay metadata. `own_requests` requires contribution rights. `shopper_inbox`, `request_preview` and `shopper_commands` require the adult assigned to the selected shop. `household_admin` requires organizer status. A selected helper session has only `helper_view` and, for editor grants, `helper_propose`; it cannot use shopper authority even if that identity has a broader adult membership.

Enrolled adult contributors may explicitly allow pending requests on their current device through `PUT /v1/households/{h}/devices/current/request-queue` with `{enabled:true|false}`. The capability is `request_queue_permission`. Permission defaults off and expires by the current replay window, at most 24 hours after enablement. The legacy wire flag `queueConsent` stays false. Generation-aware clients use the capability, `requestQueueGrant` and `requestQueueUntil` to authorize bounded storage. Bootstrap returns this pair only while the authenticated member and device remain eligible. A saved send, edit or withdrawal carries its original `X-Request-Queue-Grant` and command bytes on every attempt. A withdrawal still requires current connectivity when first confirmed. The server checks the current grant before a new write. Within the original live replay window an authorized same-device exact retry can recover its committed receipt using the original grant after opt-out or rotation. Turning permission off, revoking the device or removing contribution rights retires the grant. Re-enabling creates a different grant. Helper and child sessions cannot enable it.

The email-code BFF in API-AUTH.md is implemented but remains disabled until real provider code delivery is configured. These lifecycle APIs do not create a provider login or treat an invitation token as identity.

## Scoped helper views and suggestions

The reviewed projection is:

```ts
{
  shopLabel: string, // 1..80 characters
  language: 'en'|'es',
  items: Array<{ // at most 200
    label: string, // 1..240 characters
    amount: string|null, unit: string|null, // original reviewed text, 1..80 when present
    action: string // 1..500 characters
  }>
}
```

| Route | Input | Successful output |
|---|---|---|
| `POST /v1/households/{h}/views` | Projection above plus `{shopId,mode:'read'|'edit',expiresInHours?:1..168}` | `{grantId,inviteId,token,expiresAt}`. Assigned shopper only. Redeem this token through `/v1/invites/redeem`. |
| `GET /v1/views/{grant}/current` | Cookie; native clients add `X-Household-ID` and device token | Projection plus `{grantId,shopId,revision,asOf,expiresAt,mode,canPropose}`. Current recipient only. No prices, budgets, receipts, other requests, membership lists or guardian evidence. |
| `PUT /v1/households/{h}/views/{grant}` | Projection plus `{baseRevision}` | `{grantId,revision,asOf}`. Current shopper only; stale base returns 409. |
| `POST /v1/views/{grant}/proposals` | `{clientKey,baseRevision,correction}` | Exactly `{proposalId,grantId,baseRevision,status:'pending'}`. Editor only; correction is 1–1000 characters. |
| `GET /v1/households/{h}/views/{grant}/proposals` | — | `{proposals:[{proposalId,grantId,baseRevision,correction,status,createdAt}]}`. Current shopper only. |

Proposal receipts are durable and idempotent for the authenticated member/key/body. A changed payload returns `409 key_reused`; a new suggestion against an old view revision returns `409 stale_base`. A revoked grant cannot replay a previous success. Suggestions do not mutate basket lines, prices, checkout or authority. Applying a suggestion to the basket remains a distinct shopper review; an automatic apply endpoint is not implemented.

## Guardian controls

`GET /v1/households/{h}/guardian/consents` returns `{enrollmentEnabled:false,consents:[{consentId,childId,childAlias,noticeVersion,grantedAt,revokedAt}]}` for the authenticated adult's current verified guardian relationships only. It omits proof/provider references. `POST /v1/households/{h}/guardian/consents/{consentId}/revoke` accepts `{}` and returns `{consentId,revoked:true}`. Withdrawal revokes current child consent and child devices, windows, browser sessions and helper access in one transaction. Repeated withdrawal is safe; consent rows cannot be unrevoked.

`POST /v1/households/{h}/guardian/enrollment` returns `503 consent_unavailable`. Runtime child networking remains disabled regardless of environment flags until an actual reviewed consent provider is integrated. No self-reported checkbox, local import or receipt can establish guardian verification.

## Shopper inbox addition

`GET /v1/households/{h}/shops/{s}/inbox` now adds `authorAlias:string` to each existing own-request-shaped row, for the assigned shopper only. `/requests/mine` and own command receipts continue to omit this field and every other author's information.

## Native helper context and management lists

Bearer clients may send `X-View-Grant-ID: UUID` together with their enrolled device token. The service validates the exact live grant and recipient, then restricts the context to that helper view. An assigned shopper selecting a helper grant loses shopper, household-admin, contribution and billing routes in that context. Invalid UUIDs fail validation; a missing, expired or wrong-recipient grant ends access. The header is not a membership or invitation credential.

`GET /v1/households/{h}/invites` is organizer-only and returns `{invites:[{inviteId,kind,grantId,expiresAt,redeemedAt,revokedAt,status}]}`. Nullable IDs/dates use JSON null. Status is `pending`, `redeemed`, `revoked` or `expired`.

`GET /v1/households/{h}/views` returns `{views:[{grantId,shopId,mode,revision,shopLabel,expiresAt,revokedAt,recipientAlias,status}]}`. The organizer can manage household grants; another adult sees only grants for shops they currently shop. A selected helper context cannot list them. `recipientAlias` and `revokedAt` are nullable. Status is `available`, `active`, `revoked` or `expired`.

Both lists are bounded to 200 rows and ordered by expiry descending. Neither returns an invitation secret, token hash, credentials or provider evidence. Link creation is not an idempotent operation: after an uncertain response, refresh management, review/revoke the uncertain link, and require explicit fresh intent before creating another. Do not automatically repeat creation or claim an original token can be recovered from its hash.

See [API-AUTH.md](API-AUTH.md) for the implemented, explicitly gated email-code BFF and its live-provider deployment blocker.
