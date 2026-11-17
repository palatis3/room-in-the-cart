# Supporting integrations for the feature expansion

November 17, 2026. User-requested supplement to [the implementation plan](FEATURE-EXPANSION-PLAN.md). The user explicitly requested the useful “Possible support” items as part of implementation, not merely research suggestions. Attachment SHA256: `8c3c9c458cf1c12b658cbf532ac7ff801c4702c8f17a17758333f35e4a3e9e0c`. This supplement extends the original three-judge-approved scope; those earlier approvals do not imply review of this amendment. All entries below are planned work, not claims of installed or working integrations.

## Complete support mapping

Use existing app infrastructure and Apple frameworks first. Include the named optional provider paths as user-selectable enhancements with complete local/manual alternatives. “Optional” describes the customer's choice to use the service, not permission to silently omit its planned implementation. Remote activation depends on the concrete provider, privacy, cost and quality checks below.

| Feature | Support included in implementation | Owning workstream |
| --- | --- | --- |
| 1 Receipt scan | Existing Apple Vision OCR; reviewed receipt extraction; opt-in OpenAI image/text extraction with Structured Outputs for difficult lines | D, M1 |
| 2 My Pantry | Confirmed acquisitions, canonical inventory, observation history and reservations; no unnecessary AI | B/C |
| 3 Storage dates | Reviewed versioned FoodKeeper guidance, package-date OCR and Apple notifications; optional AI proposes a reference-category match only | H1/H2, M2 |
| 4 Tonight | Reviewed recipe library, available pantry and exact price calculations; optional interpretation of a request and explanations of eligible matches | H1, M2 |
| 5 Buying enough | Exact package/quantity/fee arithmetic; assisted extraction may propose inputs, never compute authoritative totals | G, M1 |
| 6 Family lists | Existing shared household service/database, local storage and recoverable sync | C |
| 7 Recipe import | Recipe structured data, Apple image/text capture and optional reviewed AI extraction | F, M1 |
| 8 Repeat last week | Saved plans, current inventory and purchase history | I |
| 9 Preferences | Explicit household/private profile and deterministic filtering; optional everyday-language interpretation into changes to review | G, M2 |
| 10 Dinner swap | Existing planner, scoped revisions/Undo; optional suggestions restricted to eligible reviewed recipes | I, M2 |
| 11 Speech | Existing device speech/dictation and structured list drafts; opt-in OpenAI transcription and structured interpretation as an alternative | K, M1/M2 |
| 12 Duplicates | Product identity and authorized household records; optional wording-match candidates, never automatic merging | C, M2 |
| 13 Digital receipts | Share extension, PDFKit/document parsing, OCR and optional extraction; separate future inbox connection tracked below | E, M1, N |
| 14 Batch products | Camera barcode/photo capture plus Open Food Facts candidate lookup, caching, attribution and correction | E |
| 15 Aliases/deduplication | Store-specific confirmed corrections, receipt identity and evidence matching; optional uncertain-name candidates | D, M2 |
| 16 Low staples | Confirmed history, conservative purchase-interval rules and stock suppression | J4 |
| 17 Cooked deductions | Reviewed recipe amounts, canonical batches, explicit consumption/leftovers and Undo | J1 |
| 18 Lunch reservations | Confirmed portions, schedules and exact held/free calculations | B/C, J1 |
| 19 Finish a package | Recipe/package matching and exact added cost; optional explanations/suggestions among eligible recipes | H1, M2 |
| 20 Shelf/checkout images | Apple Vision plus opt-in OpenAI image extraction through the same review path | E, M1 |
| 21 Actual prices | Confirmed purchase evidence and unit-price arithmetic; future retailer coverage tracked below | D/G, N |
| 23 Two options | Reviewed quotes, package/fee/minimum calculations; future retailer coverage tracked below | G, N |
| 24 Store order | Product categories, remembered customer corrections and store-specific department layout | K |
| 25 Schedule changes | Household schedule and planning calculations; optional calendar connection tracked below | I, N |
| 26 Cooking | Saved ordered instructions, persisted local timers/notification alerts, built-in speech playback | J2 |
| 28 Widgets/actions | WidgetKit, App Intents, Shortcuts and supported Siri entry points with protected adult summaries | L |
| 29 First task | Existing local drafts, onboarding, exports, Undo and subscription restoration | K |
| 30 Feedback | Saved reactions/ranking; optional written-comment interpretation into preferences for review | J3, M2 |

There are still no feature entries 22 or 27. The support work does not add a conversational cooking assistant or let a model invent expiry, allergy safety, stock, purchases or current retailer prices.

## M1: assisted capture and transcription

Add a narrow optional provider adapter to the existing capture/review contracts, not a second receipt or pantry pipeline. Start with hard receipt lines; reuse it for recipe images, selected digital documents and shelf/checkout evidence. Local OCR/text extraction remains the first path. A customer explicitly chooses remote assistance and sees what selected text, crop or audio will leave the device. Never silently upload the entire photo library, inbox, pantry or household history. Offer crop/redaction and prefer selected text when adequate. Audio upload is a separate explicit choice from local dictation; transient app/server buffers are deleted after completion, cancellation or bounded expiry. Do not claim provider zero retention without verifying the actual account settings and policy.

An authenticated service endpoint holds provider credentials; no API key in the iPhone binary, repository, logs, widget or share extension. The app routes through the existing service authority boundary, with request-size/time limits, per-account quotas, an owner-approved spending cap and a server kill switch. Core manual/offline use does not require an account or remote service. Remote assistance may require adult sign-in; show that only at the chosen action. Do not invent a new subscription entitlement: document the existing applicable entitlement or retain the expansion's Free rule with bounded optional usage.

Treat OCR, uploaded documents and model responses as untrusted data, including instructions embedded in them. Give the extraction model no tools, arbitrary URL fetching or mutation authority. Use versioned bounded output schemas with source line/page references and explicit unknown fields. Validate currencies, quantities, units, source references and dates in ordinary app/service code. A valid JSON shape is not proof of correctness. Refusal, truncation, timeout, offline state, cancellation and unavailable provider preserve the local draft and manual review. Retries reuse a request identity with bounded attempts to reduce duplicate billing; they never create stock or spending. Final user-approved commit uses the existing idempotent acquisition or recipe boundary and current authority/revision checks.

## M2: constrained language assistance

Reuse the M1 transport and consent design for natural-list interpretation, preference/feedback drafts, duplicate or alias candidates, and meal explanations. Each route receives only the minimum currently authorized data. Never disclose family candidates to a contributor who could not view them in the app. Exclude child/helper personas from remote assistance until a separately reviewed permitted design exists; their existing supported manual flows remain available.

Meal ranking first applies deterministic constraints, available quantities and reservations. The model can explain or propose among the eligible candidate IDs; a response with an unknown ID, unsupported claim or excluded candidate is rejected. Cost and stock statements are rendered from current computed facts, not accepted from generated prose. Recipe creation, if later offered, must enter the ordinary reviewed recipe import path before it can become a candidate. Preference and feedback interpretation shows the proposed changes and their strength before saving; it cannot silently turn a dislike into a medical exclusion or remove a constraint.

For storage guidance the model may propose only an ID from the reviewed reference subset. A person confirms uncertain matches, and deterministic rules select any range with its assumptions and provenance. No matching reference means no estimate. Model confidence is not food-safety evidence.

## N: named future connections

Retain automatic inbox access (#13), retailer feeds (#21/#23) and calendar connections (#25) as explicit later backlog items, as the supplied list describes them. They are not silently dropped, and placeholder adapters do not count as delivery. Each needs a concrete supported provider, access scope, terms, cost, revocation/erasure design and usefulness evidence before implementation/activation. No provider is selected by this amendment. Evaluate a read-only user-selected calendar import first; never write external events by default. Retailer data must carry freshness/conditions and must not be presented as a current quote when stale. Inbox integration must use narrowly scoped customer consent, not mailbox-wide background collection by default. Shared files/messages, reviewed prices and manual schedule entry remain the complete initial paths. Report N as deferred, not complete.

## Delivery, quality and activation

Continue B's pantry foundation without interruption. Native/catalog/reference support is implemented within its owning feature PR. Build M1 after D's stable review/acquisition contract; subsequent F/E/K adapters can reuse it. Build M2 after the applicable C/G/H1/I/J3/K authorization and candidate contracts. These are two cohesive support workstreams, not one PR for every API. Unrelated deterministic features need not wait for a provider account, FoodKeeper access or M work.

Before choosing a production model, evaluate representative consented/synthetic English and Spanish examples against the local baseline: difficult receipt lines, weighted quantities, fees/discounts, ambiguous dates, poor images, natural lists and excluded meals. Record field accuracy, unsupported assertions, correction burden, latency and estimated per-task cost. Set measurable acceptance targets before evaluating; do not declare higher quality merely because AI is present. Add focused malformed/refusal/offline/privacy/authority/replay regressions and keep normal CI deterministic with provider fixtures. Live provider evaluation is bounded and explicitly configured, not an unbounded paid call on every PR. Reuse the current Bitrise/GitHub checks; no extra runner fleet or blanket suite expansion.

Before live activation, verify provider retention/deletion terms, disclosure/consent, credential storage, quota/cost behavior and evidence of benefit. Prepare the integration under the user's implementation authorization; account access, paid spending, legal acceptance and distinct staging publication retain the existing concrete review boundaries. Report implementation, live activation, qualification and future N connections separately. No service was activated or purchased by writing this plan.

## Source checks and review status

Existing native/reference/catalog sources remain in [source notes](feature-expansion-audit/sources.md). Rechecked the official [image understanding](https://developers.openai.com/api/docs/guides/images-vision), [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs) and [transcription](https://developers.openai.com/api/docs/guides/speech-to-text) documentation for this amendment. Image and schema-constrained outputs can still contain mistakes; the validation/review boundaries above are deliberate. No specific model, price, retention entitlement or deployment SDK has been selected.

Independent product/UX amendment review: approved with no material corrections. The reviewer checked all 28 mappings against the attachment and the changed plan/source references; the future N boundary follows the attachment's own later/future wording. Reviewed supplement SHA256: `46b489f018538092d67583c44b1b483219df868da636d55b6c84df67f4b8c02e` (before appending this disposition). This is one separate amendment review, not a claim of three new approvals or runtime qualification. All 28 table entries and local document links were also checked successfully.
