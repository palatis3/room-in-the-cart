# Feature expansion — independent audit disposition

November 17, 2026. The [implementation plan](FEATURE-EXPANSION-PLAN.md) covers all 28 requested features (1–21, 23–26, 28–30). Three separate Astra-high judges inspected the original request, actual source and immutable drafts. They did not author the plan or feature implementation.

Reviewed v1 SHA256: `07c3795f5a8d53f23bf817270c9ee7acfbfc1b477cece7889bd52229e0f53b76`.
Reviewed v2 SHA256: `491d032c7f246c89de6d02d677bf2e35c527ff7cbcf2b9a0717fe628c1c2b813`.
Original published plan SHA256: `50a8e9c2aca70ea9583fd745d1cf67bbf3fbcaae97feeba50e47bd5bdd4fc40c` (before the subsequent support amendment).

That original published version removes accidental leading patch markers and updates factual approval/baseline/link text; its implementation contracts are unchanged from approved v2. The later user-requested [support amendment](FEATURE-SUPPORT-PLAN.md) changes provider implementation scope and is reviewed separately; the original three approvals must not be represented as covering it. Original drafts and detailed v1 findings remain in `.build/FeatureExpansionNov17/`. This compact record avoids publishing routine raw evidence.

## Material corrections before approval

| Finding | Correction | Independent recheck |
| --- | --- | --- |
| I1 / delivery P1: current change(key:) is not restart-durable replay | Ledger-side projection identity/result atomically committed with the effect; exact receipt checked before stale-base logic; reload current head | Integrity and delivery passed |
| I2: shared pantry assumes required shop anchors | Explicit household command scope, grant epochs, standalone provenance, batch event identity and compound authority | Integrity passed |
| I3: migrating food without live claims can free held food | Claim/pin/pending-phase migration, restartable cutover and legacy write fence; isolated restore holds | Integrity passed |
| Product: Tonight depends on a selected shop/recipe library | Standalone read context, useful empty state and explicit destination creation | Product passed |
| Product: qualitative status could leave an old numeric count active | Qualitative observation supersedes numeric availability; holds remain unresolved | Product and integrity passed |
| Product: untracked ingredients could block real cooking completion | Stable unresolved-use events, supported deductions, counted outputs and later count-aware resolution | Product and integrity passed |
| Delivery: FoodKeeper blocks unrelated meals/widgets | H1 deterministic/manual use-soon independent from H2 verified estimates | Delivery passed |

Final independent reports: [integrity](feature-expansion-audit/integrity.md), [product](feature-expansion-audit/product.md), [delivery](feature-expansion-audit/delivery.md). Each approved v2; no material dissent remains. These are specification approvals, not claims of runtime testing or App Store readiness.

## Source and merge prerequisite

PR [#10](https://github.com/palatis3/room-in-the-cart/pull/10) merged with normal protection as `3b767679ef97f77b53e31e6ae400c22fce6eddd6`. Tree `f8669d2e701d9dd0408a120ff9944d718c9d5381` exactly equals qualified/reviewed head `e06bde5cf463fd299deefed456f94f0cefcaeb73`. Required checks and fixture gate passed; no unresolved review threads, force or bypass. The one bounded UI08 retry used unchanged products/selectors and passed 8/8; original timeout remains unexplained and retained. Full qualifying PR coverage: 1,046 model tests, 74 ordinary UI tests and 94 fixtures. Main postmerge checks are separate ongoing observations.

Implementation order and acceptance are in the plan. Distinct staging updates, provider activation, physical-device verification and public release retain their existing boundaries. Automated GitHub Codex review quota is separate from these independent in-chat judges and CI.

## November 17 scope and implementation recheck

Three independent GPT-6.2 Astra reviewers on high reasoning reviewed feature coverage, code and delivery. The two source attachments contain the same 28 numbered feature descriptions. All 28 have implementation and support entries. The amended plan adds explicit acceptance for cached household data with pending local changes, incomplete recipe drafts, available appliances and cooking minutes, multiple barcode-free product photos and manually entered paid prices.

The code review also identified two missing user journeys for Slice B: choosing a confirmed recent purchase to start a pantry and adjusting a lunch reservation from its food batch. Start Slice B qualification at a fresh adult launch, enter My Pantry before creating a pickup, change food, reopen, then verify recovery and erasure. The production root still opens the pickup model without pantry configuration at this checkpoint. Component tests alone cannot qualify that route.

For delivery, keep one owner on pantry integration. Recipe import and branch-specific department order can ship separately through their existing editors. Prioritize reviewed receipts and paid-price history once the pantry acquisition path works. The support plan retains opt-in assisted capture and language features. H2 depends on verified storage guidance. The reviewers also identified repeated full-history reads on routine edits and full-archive rechecks on each privacy page. Measure both against long-history fixtures and preserve verification while reducing repeat work. This recheck concerns scope and implementation priorities; original v2 sign-offs are recorded above.
