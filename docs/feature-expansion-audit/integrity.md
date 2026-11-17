# Independent integrity recheck — draft v2

**Disposition: PASS for implementation-plan integrity.** I1–I3 are resolved at the specification level. I found no remaining material integrity correction requiring another plan revision. This approves the reviewed design and acceptance obligations, not code that has yet to be implemented or a production release.

Reviewed artifact: `IMPLEMENTATION-PLAN-v2.md`, verified SHA256 `491d032c7f246c89de6d02d677bf2e35c527ff7cbcf2b9a0717fe628c1c2b813`. Compared its changes with the independently reviewed v1 and re-read the resulting transaction, migration, authority, compatibility and cooking sections. Source remains `/Users/palatis/.codex/worktrees/accessibility-audit-context/Room in the Cart` at `e06bde5cf463fd299deefed456f94f0cefcaeb73`, verified with clean tracked status. Original attachment and Foundation contracts were inspected in preflight/v1. No implementation, builds, tests, provider actions or CI dispatches occurred in this recheck.

## Findings disposition

| Finding | V2 resolution | Verdict |
| --- | --- | --- |
| I1: `change(key:)` is not durable cross-store idempotency | Lines 43–47 explicitly correct the API characterization, put prepared intent in pickup.sqlite, require a bounded ledger-side application identity/result committed atomically with the ledger payload, and check that receipt before stale-base decisions. Reconciliation reloads the current head and respects erasure/replacement. Crash-after-ledger-COMMIT cases include newer touched and unrelated edits. | Resolved |
| I2: standalone shared pantry lacks non-shop operation/authority contract | Lines 33–37 choose a discriminated household operation scope, nullable shop provenance only for specified kinds, retained actor/client-key uniqueness and replay-window rules, pantry response scope, grant epochs, atomic batch headers and multiple event identities. Lines 58–65 map owner to organizer and separate preference/pantry rights. Compound meal/reservation effects require applicable plan/shop authority in addition to stock authority; lesser actors record permitted physical facts and proposals without releasing promises. | Resolved |
| I3: source-only migration would lose live claims or resume legacy writers | Lines 25–27 enumerate demand/portion/pin/pending-operation migration; preserve deterministic links and history; hold unresolved prepared/reserved work; define a restartable source-head-checked activation marker; and fence all legacy writers. Independent restored copies and missing/erased companions cannot silently join the canonical authority. Required phase/crash/restore fixtures are explicit. | Resolved |

The schema-version clarification from v1 is also resolved in line 19: later tables get later versions, ordinary comparison databases retain their independent identity, and only the appropriate composition root activates inventory ownership.

## Consequential product changes checked

- **Qualitative stock observations:** line 29 and the #2 acceptance example correctly supersede numeric availability with unknown, retain the old count as history, and keep reservations unresolved rather than releasing them. Opened/moved metadata preserves quantity; a fresh count restores numeric coverage. This closes the possibility that “Some left” leaves stale eight-unit stock available to suggestions.
- **Untracked or unknown cooking use:** lines 181–185 allow independently confirmed actual leftovers without inventing input quantities or purchases. Known deductions, unresolved use events and counted output share the authoritative operation. An identifiable source with unquantified use becomes unknown, preserving holds. Resolution keeps stable consumption lineage and checks whether a subsequent count already incorporates the use, preventing a second deduction. Completion, inventory reconciliation and review-needed status remain separate. This is consistent with physical evidence and does not require fabricated raw-to-cooked conversions.
- **Private/store boundary and shared privacy:** normalized ledger projection receipts stay outside the bounded whole-workspace payload; private source origins and shared grants stay distinct. Pantry editor projections exclude hidden meal/shop identifiers and prices. Existing household joint conservation remains the shared authority. No newly reviewed section grants pantry-only actors budget or named meal-completion authority.

## Remaining execution gates and minor editorial note

PR10 merge and final merged-main baseline freeze remain required. I did not independently verify the reported successful retry or merge, and this plan pass does not waive either. Implementation must demonstrate the specified migration, replay, dependency-checked Undo, erasure, authorization and old-client cases; no runtime behavior is certified by this document.

Several inserted paragraphs contain literal leading `+` characters (for example lines 24–27, 32–37, 44–47 and 182–183), and `+### #1` will not render as a heading. Remove these patch artifacts before presenting the plan. This is an editorial correction, not a material design finding; it does not change the integrity disposition if wording is otherwise preserved.

This pass is independent of the other judges' conclusions. Material implementation changes to transaction ownership, authority scope, migration/cutover or consumption semantics should return for review rather than be treated as covered by this approval.
