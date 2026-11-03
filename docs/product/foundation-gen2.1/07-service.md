# Service, roles and sync

Keep prices, consent evidence and private meal constraints out of the contributor API by construction. Authenticate the session, select the current household and persona, check the actual object grant, then construct one of three response shapes: adult, own request, or scoped helper. A caller who knows a record ID gains no rights. Use the same rules on search, change feeds, exports, notifications, troubleshooting, stale-operation receipts and server-rendered previews.

## Authorization matrix

| Capability | Local guest | Invited contributor | Scoped helper / editor | Household adult | Active shopper |
|---|---|---|---|---|---|
| Private quick check, local meal/list and file | Own device | Own device outside household role | Own device outside grant | Own | Own |
| Submit/change/withdraw a pending request | Join to send | Own requests, current membership/consent | Only with a separate contributor invite | If enrolled | If enrolled |
| Read full household request inbox | — | Own requests only | — | — unless assigned shopper | Assigned shop only |
| Read private budget | Own local budget | — | — under a standard helper grant | Explicit adult budget grant for this shop | Assigned shop |
| Read current cook view | Dated copy | Separate view grant | One shop, selected fields, until revoked/expired | Explicit scope | Assigned shop |
| Propose a change to one shop | Own local plan | — | Editor can propose only within one grant | Explicit scope | Can review and apply to assigned shop |
| Read or plan the household meal week | Own local week | — | — | Adult planning access; paid tools also require seat | Requires adult planning access; shopper applies basket effects |
| Final basket add, deferred choice, checkout freeze, placed report or amendment review | Own private local workspace | — | — | Proposal only if someone else shops | Only current epoch holder for shared shop |
| Invite, revoke, change shopper | — | — | — | Organizer with current membership, transfer via server | Shopper role alone gives no admin power |
| Child consent, export or erasure | — | — | — | Verified guardian for their child and permitted scope | Shopper role alone gives no guardian power |
| Verify purchase / assign seats | — | — | — | Server verifies purchase, authorized account manages seats | Shopper role alone gives no billing power |

**Visibility examples.** Sam receives `{requestId, revision, originalItem, ownQuantity, authoredAt, receivedAt, route, status, ownActionAllowed}`. Optional shopper clarification uses a purpose-built message visible to Sam only; never expose another request or its author to explain a merge. A helper receives dated item/amount/action/basis and optionally authorized fields for this shop. Mia sees the private before/after preview, unknown facts and protected portions. Session refresh, role transfer and child revocation invalidate old projections and caches. When identity is unclear, show the least privileged sign-in or local option.

## HTTP surface, v1

Apply the field rules before rendering any S14–S17 or S25/S26 planning preview. An adult with planning access but no private budget scope may see authorized portions and propose a meal change. Omit prices, caps, cost deltas, budget-based rankings, and fields that indirectly reveal them. The assigned shopper completes the financial review. This rule also covers speech, logs, change feeds, export and assistive labels.

Use HTTPS, versioned JSON DTOs and fixed allowlists for query and mutation types. Keep optional extension fields backwards compatible and reject unknown mutation types. Serve consistent machine-readable errors with a correlation ID and a user's recovery action. Advertise maximum batch sizes, media bounds, locale/version support and cursor expiry. All commands below have a typed request validator, an authorization policy, a handler and a response projector.

| Endpoint family | Contract and transaction boundary |
|---|---|
| `POST /v1/invites/redeem`, `/households/{h}/invites`, `/revocations` | Verify identity, intent, expiry, unused token, role, guardian status and household; consume token and create/revoke grant in one transaction. Concurrent redemption succeeds once. Rejoining requires a fresh grant. |
| `GET /v1/me/workspaces`, `/households/{h}/bootstrap`, `/changes?cursor=…` | Return only permitted projections and opaque cursors. Rebuild when retention, schema epoch or access boundary changes. Authorize each event's current scope; no enumeration by guessable IDs. |
| `GET /v1/households/{h}/requests/mine`, `/shops/{s}/inbox` | First endpoint filters by authenticated author; second requires shop authority/private access. Page by server order; timestamps on a child's phone do not decide eligibility. |
| `POST /v1/households/{h}/commands` | One bounded intent per envelope below. May batch transport, but preserve per-command transaction and ordered dependencies. Shopper approvals are committed online; private guest work stays local. |
| `POST /v1/households/{h}/shops/{s}/previews` | Require adult scope. Compute approved pack, commitments digest and inclusive totals; return a short-lived identifier and input fingerprint. No purchase or basket mutation. A second adult's preview is a proposal. |
| `POST /v1/households/{h}/views`, `GET /v1/views/{grant}/current` | Create/redeem narrowly scoped share with expiry and explicit fields. Re-evaluate membership, version and revocation at read. Editor may propose a change, never apply solely through a view link. |
| `POST /v1/billing/verify`, `POST /v1/apple/notifications`, `GET /v1/me/entitlements` | Validate Apple evidence and environment; bind transactions globally to the correct purchase/household; handle replay and out-of-order notifications. Return current product access, not new data rights. |
| `POST /v1/privacy/deletions`, `GET /v1/privacy/jobs/{id}` | Require reauthentication plus owner/guardian scope. Create a durable erasure job, immediately revoke affected live grants; publish only safe completion status and support reference. |

### Example shopper decision

```json
{
  "v": 1,
  "replayWindow": "opaque-server-issued-window",
  "clientKey": "4cfe1cd5-27c3-45e8-8adc-8a52d5c57ed0",
  "kind": "request.apply",
  "shopId": "shop-thu",
  "base": {"shopRevision": "r12", "requestRevision": 2, "authorityEpoch": 3},
  "body": {"requestId": "req-7", "choice": "defer", "previewId": "preview-r12-cereal"}
}
```

An adult sees a receipt with operation ID, committed shop/request revision, actual disposition and an authorized sync cursor. Sam sees only his status “Saved for next shop.” Omit server-owned household role, calculated totals, caller-supplied child status and trusted author from the inbound body. Derive actor/device from the session. Device-generated times are evidence, never the causal clock.

**Commit sequence.** Authenticate and canonicalize versioned input. Derive the namespace `household + verified actor + clientKey`, bind kind, target, base and canonical payload digest. Open a transaction and lock the shop/membership and affected request in a deterministic order or use equivalent conditional updates. Recheck present authorization. If the key has an authorized stored receipt and digest matches, return the safe receipt without reapplying, even if the base is now old. For a reused key with different payload return `409 key_reused`. For a fresh action verify phase, authority epoch, request revision, shop head, preview fingerprint, entitlement if needed, consent, inventory and quote freshness. Atomically update line/allocation/route/revision and record operation/event; commit, then notify. Losing a response only retries the original key. Generate a fresh key after user review of a changed intent. Require a server-issued replay window bound to the enrolled household/actor/device (authenticate the presenting device). It carries an issued-at/expiry, random generation and revocation state signed or stored by the service. A queued command retains the original window and client key through retry; the window is part of its canonical envelope. Reject expired/retired windows with refresh-required before any mutation, using server time. Within a live window an authorized duplicate returns its safe receipt, or refresh-required if only the used-key marker remains. Retain markers until all windows that could present their keys expire; never rewrap an old outbox command into a new window automatically. After expiry or loss of membership, bootstrap current facts and require fresh intent. On erasure close the enrollment/windows before purging dedup markers; no grocery text survives in them.

**Errors with recovery.** `401 session_needed` → keep private draft and authenticate. `403 access_ended` → stop, clear protected cache, do not expose a prior success to a revoked user. `404 unavailable` can conceal out-of-scope resources. `409 stale_base/authority_changed` → return permitted current context and require review. `409 checkout_locked` → offer next shop, never silently alter frozen order. `422 unknown_unit/invalid_candidate` → keep fields and identify the missing fact. `429` or transport failure → retain queue, back off. A storage failure must visibly fail the local save; the system cannot say “saved on this phone” until the write succeeds.

## Command dictionary

**Receipt lifecycle.** In one commit insert the durable `operation` identity and the disposable `operation_response` row, plus the change, its event and any proposal application. Both evidence records point to the durable identity. A privileged compaction deletes just the response; its trigger retains the used key. A missing/retired response for a known operation returns refresh-required, with no original private payload and no action even on changed-body replay. Never re-create the response by executing the command. Keep referentially required identities until separately authorized erasure can remove their dependent records; close related replay windows before purging markers.

| Intent(s) | Required guards and durable effect |
|---|---|
| `request.send/edit/withdraw/clarify` | Verify author, active membership and child consent where applicable. Pending author updates increment request version. After acceptance, a correction becomes a linked follow-up; no automatic quantity removal. The author may answer a scoped clarification. Only the assigned shopper may ask it, and only about a request in their assigned inbox. |
| `request.apply` (link existing/add/defer/dismiss/handled) | Shopper + current epoch, reviewed request/preview/head, open shop for basket effects. Existing box can satisfy several requests after review; adding a genuine second box must be explicit. On defer keep obligation, no charge. |
| `shop.patch/undo/freeze/reopen/reportPlaced/reconcileReport` | Patch exact base with a new revision; reverse via a compensating revision. Freeze exact dated snapshot. Reopen a distinct revision, preserving sent/order evidence. After placed, never amend retailer truth through a draft edit. |
| `shop.transferAuthority` | Organizer-authorized transfer is online and atomic; verify old epoch, current shop and new adult's active eligibility. Increment epoch, preserve frozen basket. Stale shopper cannot close the new shopper’s revision. |
| `meal.saveTemplate/schedule/move/guest/away`, `proposal.apply` | Authorized adult or private device; captures template version and dates. Household meal planning checks the adult planning grant; scoped editors use a distinct shop proposal without calendar access. A seat controls assisted tools, not early read/write into the basket. Shopper checks base when applying a basket effect. |
| `idea.create/edit/approve/discard` | Validate sources, portions, ingredients and exclusions per current idea revision. Durable candidate approval is independent from scheduling and list application. |
| `quote.record/compare/adopt` | Private local or shop-budget-authorized adult quotes only. Quotes can be incomplete; forbid a comparable-winner claim with missing facts. Adoption requires current shopper, same commitments and an open draft. Preserve quote snapshot after adoption. |
| `offer.record/decide/expire`, `amendment.recordResponse` | Record deadline/offer evidence, pending choice and provider response separately. A late local preference cannot resurrect a retailer opportunity. Explicit confirmation or manual evidence determines status. |
| `fill.record/correctUsable`, `stock.confirm/reserve`, `ledger.append` | Verify source identity, dimension, same shop/lot and prior observations. Keep partial/split delivery history; reject over-allocation; correction creates a new record. No financial effect from a meal repair. |
| `handoff.prepare/recordAction/acknowledge` | Explicit destination/projection. Cancel does not move the intentional-send baseline. Record actual observed destination only when known. Acknowledgment never means an order was placed. |
| `grant.create/revoke`, `consent.record/revoke`, `seat.assign/release` | Authority specific to action; consent proof and billing verification are server-only. A revoked child cannot replay a queued submission. Never expose a guardian proof to the shopper. |
| `import.stage/commit/undo`, `backup.recoverBranch` | Local or permitted owner-scope operations. Validate full batch and projection; compare revisions; commit once and preserve existing private fields. Files cannot grant membership or activate payment. |

## State transitions worth testing before UI polish

| Trigger | Shared basket / order | Request and client result |
|---|---|---|
| Incoming request in open shop | Basket unchanged | Pending current shop; authored and received times independent. |
| Freeze to prepare handoff | Freeze current revision, preserve undecided items outside the frozen plan | New arrivals route next. Existing undecided remain visible to shopper. Copying a list alone never records placement. |
| Explicit reopen after cancelled checkout | New open draft with traceable parent | Next-shop items stay there until intentionally promoted after review. |
| Shopper reports placement | Pin frozen or reconciled revision; source “shopper reported” | Route new and still-undecided requests next. A pending contributor draft can sync later with accurate server route. |
| Offline placement during authority transfer | Keep local cutoff; accept separately attributed external report for reconciliation if old authority lost | New shopper decides whether it applies to the frozen basket. Stale device cannot close, reroute or modify the newer order. |
| Later provider change / order cancellation | Keep order and amendment history; record response separately. Reopen or start another distinct draft if cancelled. | Never silently delete other households' contributions, add a duplicate box, or infer that the family received the item. |
| Confirm actual arrival | Record observed/usable quantity once; allocation can change suggestions | “Bought” requires an explicit applicable confirmation. A refund does not imply the food was missing and vice versa. |

The 20 routing and replay traces in [inbox-scenarios.json](references/grocery30/inbox-scenarios.json) exercise these distinctions with fictional names. Run each trace against the real API and two actual synchronized clients during B07. Test packet loss before commit, after commit/before reply, process death, clock skew, stale views, simultaneous edits and a revoked identity replaying an old success.


**Live-view lifecycle.** S10 issues a view after checking the creator's current authority to share every selected field. S21 manages and revokes it. S20 links to the scoped management panel. The recipient uses the helper branch of S10, identified by a grant for exactly one shop. A contribution link alone cannot open it. An editor can submit allowed fields as a proposal. The assigned shopper opens S17 and applies against the current base or requests a new review. Preserve the ordinary S10 dated text path after cancellation, expiry and membership lapse.

**Period query.** Authorize every participating shop before aggregating money for S20 or an export. Use the same currency for period and shop reservations. If the caller has incomplete scope, return only information independently derivable from the permitted rows, with no hidden subtotal, remaining balance, count, ranking or hint. Deny access before generating cached responses, readback or a file.
