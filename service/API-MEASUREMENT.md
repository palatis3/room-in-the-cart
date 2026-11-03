# Optional pickup measurement

All routes below run inside the existing authenticated household/device transaction.
They reject children, helper grants, revoked membership and foreign household scope.
They do not read or import the private native ledger or local pickup responses.

| Route under `/v1/households/:household` | Request | Result |
| --- | --- | --- |
| `GET /measurement/status` | None | Current notice and this adult's live consent, or `null` |
| `POST /measurement/consent` | `{noticeVersion}` | Explicit consent; a repeated current choice returns its existing identity |
| `POST /measurement/withdraw` | `{consentId}` | Irreversible withdrawal and deletion of responses under that consent |
| `GET /shops/:shop/measurement-feedback` | None | Server eligible week and one coded response, or `null` |
| `POST /shops/:shop/measurement-feedback` | `{consentId,noticeVersion,outcome,baseline,comparison}` | One response for the canonical household/shop/week |
| `DELETE /shops/:shop/measurement-feedback` | `{feedbackId}` | Removes this adult's selected response |

The current notice is `pickup-feedback-2026-11-03.v1`. Outcomes are `acted`,
`unchanged`, `late`, `unknown`, `already_knew`, `wrong`. Baselines are `retailer`,
`list`, `usualRoutine`, `unknown`; comparison is `same`, `different`, `unknown`.
Every write body is strict. Grocery text, monetary amounts, client household/week
claims, membership assertions and Apple transaction fields are rejected.

Only the current shopper may record or read feedback for a placed, closed shared
shop. The database pins closure time; its ISO week in UTC is stable across retries,
devices and later dates. Closed shops predating migration 019 have unknown closure
time and are not silently assigned a week. A different self-reported result has
unknown incremental benefit. Ties, unchanged plans, late/known/wrong information
have zero benefit. No response claims verified savings.

`ritc.measurement_willing_household` is a live, tenant-scoped projection of existing
server-verified Production billing state and explicit current measurement consent.
It has at most one row per canonical household. Devices, seats, delivery receipts,
restore calls and renewal transactions do not increment it. Revocation/refund,
expiry and consent withdrawal exclude the household; Sandbox never counts as a
retained buyer. It is not a client-writable analytics counter. Apple reconciliation
and notifications retain their existing verification requirements.

Native Settings exposes a separate explicit household measurement notice and
grant/withdraw action. Closed placed shared shops expose a fresh code-only form;
local responses are never prepopulated or uploaded. Local feedback remains stored
with the local pickup. Its versioned workspace preference lives outside archive
payloads; legacy booleans, exported files and billing restores cannot grant either
kind of consent. Account erasure deletes measurement records through the existing
member erasure boundary, and revocation withdraws current consent.
