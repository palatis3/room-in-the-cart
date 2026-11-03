# Enrolled household device management

S21 lists actual service enrollments. One phone/browser can have several enrollments; the opaque reference and enrollment date identify which access an adult reviews. These records do not claim to identify hardware, a phone model, location or last activity.

Every call requires a verified live provider session, active membership and the currently presenting device. A selected helper/editor view cannot use management routes. An organizer can inspect the household. Another adult must have an existing, current verified guardian relationship and can inspect/revoke only that child's enrollments. Ordinary contributors, helpers, children and unrelated adults receive no inventory. Guardian responses contain no adult roster or devices of other children.

`GET /v1/households/{h}/devices?cursor={deviceId}` returns:

```ts
{
  scope: 'household' | 'guardian_children',
  devices: [{
    deviceId: string, memberId: string, memberAlias: string,
    memberKind: 'adult' | 'child', createdAt: string,
    revokedAt: string | null, isCurrentDevice: boolean
  }],
  nextCursor: string | null
}
```

Pages contain at most 100 enrollments, ordered by enrollment time and device ID. A cursor must itself be visible under the caller's current management scope. The projection deliberately omits credential hashes, tokens, provider identity/session, email, guardian proof, budgets and grocery content. Responses use `Cache-Control: no-store`.

`POST /v1/households/{h}/devices/{deviceId}/revocation` accepts the strict body `{memberId}` and returns `{deviceId,memberId,revoked:true,revokedAt}`. Both target IDs must name one authorized enrollment. This operation is naturally idempotent: the device ID never identifies a replacement enrollment, and repeated calls preserve the original revocation timestamp. It revokes that device's replay windows and web sessions atomically with its enrollment. Existing household membership, shopper authority, consent and sibling devices remain separate. The presenting device cannot revoke itself here (`409 current_device`); the existing `DELETE /devices/current` sign-out path ends its access.

The household transaction lock orders revocation against reads and commands. A command already authorized may finish before revocation; access beginning after its commit fails, including exact replay of an old successful queued command. A receipt can only be re-read by a presently authorized manager, so a revoked manager cannot use a previous success to expose protected data.

Migration `023_device_enrollment_fence.sql` also fences replacement enrollment for the target's provider session. The old bearer cannot bypass revocation through `POST /devices` or `POST /v1/session`; a fresh provider sign-in/session can enroll. Existing sibling enrollments, including those using that same provider session, remain usable. The owner-only table contains only household/member references and a session digest. Runtime has no table privileges. Two guarded SQL entry points recheck live identity and derive the target session digest internally; no supplied hash can create a fence. The existing device INSERT boundary also checks the fence under the household lock. Erasing a member's device sessions deletes that member's fences through a narrow owner trigger, including deletion-journal reapplication after restore.

The native client stores only immutable actor/household/device/target references and fixed request bytes in a dedicated protected, backup-excluded retry file. It saves before sending and retries only the original target. Recreated views recheck current authentication and exact enrollment before showing a pending action. Backgrounding clears displayed inventory and pending references; foregrounding fetches current authority again. Account/household cleanup purges matching pending actions and invalidates stale writers.

`tests/device-management.integration.mjs` exercises these boundaries against PostgreSQL using the non-owner runtime role and actual HTTP requests. Native client and model suites cover exact bytes, response substitution, persistence, scoped purge, backgrounding and authority changes during asynchronous work.
