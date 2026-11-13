# E09 entered price and budget history

Local service implementation. Migration 012 follows migrations 009–011. Wire DTOs: `../shared/contracts/history-v1.d.ts`. Executable input bounds: `src/history-contracts.ts`. The HTTP adapter reuses the existing configured `BillingService`; no new privileged provider key or runtime constructor is required for these routes.

## Authority and Free records

Every route authenticates the fixed issuer/signed subject, live exact provider session, current household membership and enrolled device. Selected-helper contexts are rejected. Reads independently require either the current adult shopper or an enabled `shop_budget_grant` for that adult and the shop's current authority epoch. A shopper transfer invalidates the former epoch's grants. Organizer status, paid seats, meal-planning access, imported documents and client-supplied IDs cannot grant budget access. `X-Shop-ID` further narrows the scope when present.

All financial, observation and period mutations still require current shopper authority for every affected shop. A read grant cannot append evidence, close or reconcile a shop, retire history, save a period, or replay a write made before losing shopper authority. Period ownership remains private: a budget grant permits reading an owner's saved period only when that owner has current read access to every source; it does not grant another adult access to the owner's period record.

Paid history, period planning and financial reconciliation refresh the existing Apple-backed named-seat entitlement on each call. Missing provider configuration returns `billing_unavailable`; lapse, seat removal or invalid status returns `membership_inactive`. They do not erase the saved raw records. Free remains able to record/read its currently authorized manual evidence, read a single saved observation, discover its own saved period IDs, read a saved period record when every source remains authorized, and explicitly close an app shop without claiming a financial reconciliation.

The stored entries are **shopper-reported evidence**, never bank/provider verification. No service route charges a retailer, cancels an order, releases a bank hold, or verifies a bank balance.

## Exact routes

All `{h}` paths are `/v1/households/{h}`. POST mutations require the existing browser exact-origin/CSRF rules or the verified native bearer/device context.

| Route | Input | Result |
|---|---|---|
| `GET /history-readable-shops?cursor={shopId}` | — | `{shopIds:UUID[],nextCursor}`. Free discovery of at most 50 current budget-readable, nonretired sources. Only permitted IDs are returned, with selected-shop narrowing. A revoked, foreign or out-of-scope cursor is rejected. |
| `GET /shops?scope=history-owned&cursor={shopId}` | — | Shopper-only history picker. Returns up to 50 current, nonretired assigned shops, including closed pickups. A selected pickup narrows both discovery and pagination. |
| `GET /shops/{s}/financial-evidence?cursor={entryId}` | — | `FinancialPage`, at most 50 entries and the current `SourceVersion`. Free/current budget reader. |
| `POST /shops/{s}/financial-evidence` | `FinancialAppend` | `FinancialAppendReceipt`. Free/manual evidence. |
| `POST /shops/{s}/financial-reviews` | `FinancialReview` | `FinancialReviewReceipt`. `allEvidenceEntered:true` requires paid tools; closing alone is Free. |
| `GET /shops/{s}/records/history/v1` | Optional `includeRetirementStatus=true` | Returns retained history. With the option enabled, the current assigned shopper receives `404 shared_history_retired` for a retired history. Other callers receive the usual access response. Current pickup data remains independently scoped. |
| `POST /shops/{s}/history-retire` | `{clientKey,sourceVersion,confirm:true}` | `{shopId,retired:true}`; removes this source from history analysis without pretending the source data was erased. |
| `POST /price-observations` | `{clientKey,observation:PriceObservation}` | `{observationId,shopId,recorded:true}`. Free/manual record. |
| `GET /price-observations/{id}` | — | `{observation:PriceObservation}`. Free/saved record with current source authority. |
| `GET /price-observations?cursor={observationId}` | — | `{observations:PriceObservation[],nextCursor}`. Paid history; at most 100 permitted observations. |
| `POST /budget-history` | `{shopIds:UUID[]}` | `{permitted:PermittedSubtotal}`. Paid; at most 100 requested IDs. Unknown/foreign/retired/inaccessible shops contribute no rows or signals. |
| `GET /budget-periods?cursor={periodId}` | — | `{periods:[{periodId,revision,updatedAt}],nextCursor}`. Free own saved-record discovery, at most 50; no funding/title/hidden-shop data. |
| `POST /budget-periods` | `PeriodWrite` | `PeriodReceipt`. Paid explicit full plan; baseRevision 0 creates, otherwise exact current revision. |
| `GET /budget-periods/{id}` | — | `PeriodResponse`. Paid; complete current scope is required for envelope/remaining data. |
| `GET /budget-periods/{id}/record` | — | `{periodId,revision,period}`. Free own saved raw plan, only if every source remains currently authorized. Otherwise 404, never a paid subtotal bypass. |

All history mutations bind `(household,actor,clientKey)` to the operation, target and full canonical payload. Exact retries return their original durable receipt after current authority is checked. Changed intent with a used key returns `key_reused`; new financial actions against a changed quote/authority/evidence version return `stale_source`. Read current source facts again before forming a new action. Financial evidence keys and linked credit/hold IDs are UUID identities, not bank-account numbers or user-supplied authority.

Text is preserved with explicit UTF-8 byte bounds. Pack labels, source text, observed date, store, branch, channel, fulfillment mode, eligibility and locale are separate fields. A warehouse observation is not conflated with a retailer website; a mass ounce is not a fluid ounce or a count. No implicit density/pack conversion or automatic price matching occurs. All amounts are integer USD cents; another currency is rejected rather than converted or mixed.

## Financial and period semantics

A `SourceVersion` is the tuple `(shopRevision,authorityEpoch,financialRevision)`. Appending financial evidence increments its financial revision and invalidates an older review. Quote/basket changes and shopper transfers also invalidate reviews through the tuple. Reconciliation is true only when an explicit financial review matches that tuple, the app shop is closed, and no pending credits or payment holds remain. Closing alone does not supply that review. Closing preserves existing requests, needs/history and retailer facts; it only closes the application's shop.

Pending credits do not reduce posted spending. An included credit is explanatory and is not subtracted again. A posted credit reduces posted net once; its credit identity cannot also settle as included. A hold is not spending, and a release references one exact hold with the same amount. Cross-shop or missing charge/hold links are rejected.

An inclusive checkout estimate already contains posted cash. Projected commitment is `max(posted net, checkout expectation)` for each bound, not their sum. Expected unpaid is that projection minus posted net. Without an upper bound, the minimum remaining amount stays unknown. Only an explicit, current, closed-shop financial review can use posted net alone as reconciled entered spending.

A period is an **explicit shop-plan envelope**, not a posting-date bank statement. Its dates/timezone identify a planning window. All entered settlement evidence for its assigned shops is included, including later credits. `shopBudgetMinor` is already net of the stated reserve; `alreadyExcludedReserveMinor` is explanatory and is never subtracted again. A reserved future plan reduces available planning money; applying it transfers that plan to its assigned shop, so it is not also counted as a reservation. Applied/released reservation evidence cannot be rewritten into a new reserved plan under the same reservation ID.

If every assigned shop is currently permitted and not retired, the period response includes the saved envelope, reservations, conditional remaining range and reconciliation flag. Otherwise it returns **only `{permitted:...}`**. It contains no period title, funding, reservations, remaining balance, hidden-shop count, denied IDs, hidden subtotal or reason describing missing sources. A selected-shop context is deliberately narrower and can therefore return only its independently permitted subtotal. Cached receipts and files cannot restore lost access.

## Bounds, erasure and evidence

A shop accepts at most 2,000 financial evidence entries in this initial service implementation; it fails explicitly at the boundary rather than silently truncating a complete financial source. Periods and budget queries support at most 100 shop IDs. Ordinary request-body limits still apply. All monetary addition checks safe integer overflow. PostgreSQL authorization/household transactions retain their statement and lock timeouts; timeout is a retryable failure, never a fabricated complete summary.

Migration 012 extends the private erasure hook introduced by 011. It removes the deleted actor's observation text, period plans and mutation receipts; redacts their financial free text; and invalidates review of changed sources. De-identified amount and linked credit/hold UUID facts remain for another currently authorized shopper's records. It neither erases another author's private requests nor treats retained evidence as continuing consent.

Current evidence: 76/76 combined real PostgreSQL tests, 32/32 explicit fast tests, and 5/5 isolated PostgreSQL maintenance tests, all with zero failures/skips. Logs are under `../evidence/`. Seven history integration tests cover partial-source secrecy, fresh paid authorization, named-seat limits, lapse with saved-record access, inclusive math, credits/holds, planning-window/later-credit semantics, source-version invalidation, UTF-8 bounds and exact pagination. A separate account-erasure test verifies cleanup of the new helper/history tables and preservation of another shopper's de-identified financial facts.

Apple/provider fixtures are fictional. Real Apple sandbox/provider, native HTTP integration and deployment remain separate release evidence. No main service installation or live endpoint availability is claimed.
