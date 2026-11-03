# Helper review and explicit shop context

Local service implementation. Migration 011 follows privacy migrations 009–010. Executable validation: `src/contracts.ts`; DTO declarations: `../shared/contracts/household-review-v1.d.ts`.

All management calls require the currently assigned adult shopper for that exact shop. Organizer status alone does not grant shop budgets or instruction editing. Expired/revoked grants, a revoked creator, cross-household IDs and selected-helper contexts fail closed before reading stored replay receipts. These are Free manual review operations and never mutate the basket or claim retailer action.

- `GET /v1/households/{h}/views/{grantId}` → `ManagedHelperView`, including canonical projection, language/items, current revision, mode, asOf and expiry.
- `POST /v1/households/{h}/views/{grantId}/replacements` with `HelperReplacement` → `HelperReplacementReceipt`. The entire reviewed projection is required. Exact whitespace in reviewed text is preserved. The mutation increments grant revision once.
- `POST /v1/households/{h}/views/{grantId}/proposals/{proposalId}/resolve` with `HelperResolution` → `HelperResolutionReceipt`. Replace requires a full explicit shopper-reviewed projection; it never interprets or copies the proposal correction automatically. Dismiss leaves the projection and grant revision unchanged. Both increment proposal revision once.
- `GET /v1/households/{h}/views/{grantId}/proposals?cursor={proposalId}` → `HelperProposalPage`, bounded at 100 with `nextCursor`, including proposal revision and durable resolution. A cursor must belong to that currently authorized grant.
- `GET /v1/households/{h}/views/{grantId}/proposals/{proposalId}` → exact current `HelperProposalStatus` for shopper reconciliation after a lost response.
- `GET /v1/views/{grantId}/proposals?cursor={proposalId}` → the authenticated recipient's own `HelperProposalPage`, bounded at 20, newest first by `(created_at, proposal_id)`. Each cursor must belong to this same household, grant and actor; foreign/random cursors are unavailable. The existing grant must be current, unexpired and unrevoked and its creator/recipient must remain authorized. Read-only helpers may inspect their own earlier submissions; this route grants no edit or management authority. Only the existing proposal-status DTO is returned, never actor IDs, client keys, digest, basket, budget or another recipient's data.
- `GET /v1/views/{grantId}/proposals/{proposalId}` → the recipient's own `HelperProposalStatus`. Native bearer callers supply `X-Household-ID`; selected helper callers keep `X-View-Grant-ID`. No other recipient's proposal is returned.

Each management mutation binds `(household, actor, clientKey)` to the canonical full request, target and operation kind. Same-key exact retries return the original durable receipt even after a later grant revision. Changed reviewed text/base/target/decision with that key returns 409 `key_reused`. A new action against a changed grant or proposal revision returns 409 `stale_base`. Current authority is always checked before replay. Existing `PUT /views/{grantId}` remains a legacy non-idempotent replacement; new clients should use `/replacements`. The initial recipient proposal receipt remains `{proposalId,grantId,baseRevision,status:'pending'}` even on a retry after resolution; read the status route for the current review outcome.

## Shop selection

`GET /v1/households/{h}/shops?scope=active|owned&cursor={shopId}` returns `ShopPage`, bounded at 50 rows. Active returns active shops independently available for contributing or shopping; owned returns only shops where the caller is the current adult shopper, including closed shops. It contains dates/phases and own shopper revisions, never quotes, line text, prices or hidden-shop counts. A helper-only member without shopper/contributor authority gets no shop enumeration, and selected helper contexts cannot use this route.

Native sends `X-Shop-ID: <uuid>` on selected-shop requests. It is distinct from, and incompatible with, `X-View-Grant-ID`. The service validates current access at each authorization, and shop-specific reads/commands must match the selection. Unknown, inaccessible or stale membership cannot fall back to a different shop. Remove the selection when explicitly creating a new shop; the new shop's UUID does not exist before creation.

Browser `POST /v1/session` accepts `{householdId,shopId?}` or `{householdId,grantId?}`, never both selectors. The opaque session stores the selected shop. Refresh uses that exact selection and rechecks current authority. Existing identity/Origin/CSRF rules still apply.

Bootstrap adds `selectionRequired:boolean`. With multiple available active shops and no explicit shop/grant, `shopId:null` and no shopper capabilities are returned. With one available shop, the prior single-shop flow remains compatible. A selected closed shop is available only to its current shopper. Explicit selection does not grant broader authority and does not authorize access to any other shop.

## Evidence and limits

The final combined real PostgreSQL suite passed 76 tests with zero failures or skips; eight cover helper review and selected-shop context, including pagination. The full evidence is `../.build/history-pg.log`. Explicit fast tests passed 32/32 and isolated maintenance tests passed 5/5. Pagination retains PostgreSQL timestamp microseconds, preventing duplicate or omitted rows at a page boundary; this also corrects the existing request pager in the independent scratch copy.

Frozen privacy package files and migrations 001–010 remain unchanged. This slice has not been installed or deployed. Native adapter integration and live end-to-end evidence remain separate work.

### Shop selection and dated meals

An enrolled native adult selects a shop with `X-Shop-ID`. The service checks the selected shop for reads, commands and replays. A scoped helper keeps its separate view grant. The app saves the selected shop with its enrollment and clears the previous projection before switching.

The following paths are relative to `/v1/households/{householdId}/shops/{shopId}`.

| Method and path | Action |
| --- | --- |
| GET `/shopper-assignment` | Review the current buying authority and eligible reassignment choices. |
| GET `/meal-plan` | Read current dated meals and pending moves within the caller's planning access. |
| PUT `/meal-plan/planner` | Shopper grants or revokes access for one adult using the current grant revision and authority epoch. |
| POST `/meal-plan/proposals` | The explicitly assigned, seated planner proposes a new civil date against the current shop, grant and authority versions. |
| POST `/meal-plan/dismissals` | Shopper dismisses a pending move against the reviewed versions. |

A shopper creates, edits or removes one dated occurrence through the existing `shop.patch` command. Include the reviewed quote and pack lines alongside `mealEdit`. Set `baseMealRevision` to null for creation or the reviewed revision for an existing occurrence. Set `meal` to null for removal. Accepting a planner's move includes its `proposalId`; the shopper reviews the meal, packs and price before applying. A stale base requires a new review. Frozen snapshots carry versioned meal references, allowing later erasure of personal meal content.

## Browser recovery without private local persistence

The browser loads received suggestions from the scoped endpoint after full page/app recreation. Failed discovery blocks a fresh suggestion until the user retries recovery; list/status retries are reads and never reconstruct or submit a new proposal. A response dropped after commit is recovered as a received server record even when the original page and its in-memory key are gone. A same-page uncertain submission still retries its original exact bytes, key and base. Matching receipt IDs share the current status instead of showing duplicate received cards.

The current bootstrap reports `queueConsent:false`; no protected helper text is put in browser storage and no storage policy is widened. A genuinely unsent draft cannot be recovered after a reload. The interface distinguishes that draft from dated suggestions recovered from the service and warns about the unsent-data limitation. Recovery checks the current session both before and after fetching, fences late results by local generation/expiry, and clears protected results on account/grant/role loss. Revoked or expired grants cannot recover old receipts.

Regression coverage: `web/tests/client.test.mjs` covers full recreation, recovery failure/retry, page validation, read-only status, late account/expiry races and receipt-card deduplication. `service/tests/helper-review.integration.mjs` covers author/grant cursor isolation and submillisecond pages. Set `RITC_TEST_WEB_WIRE=1` with explicit isolated local PostgreSQL runtime/admin URLs after building web and service to run the real compiled WebApp/API → loopback HTTP/BFF → PostgreSQL dropped-response/full-recreation tests. These use JSDOM rendering, not a deployed or physical supported-browser certification.
