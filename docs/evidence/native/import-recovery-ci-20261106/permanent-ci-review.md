# Permanent import-recovery fixture review

**No blocking defect found in the six-file candidate.** The fixed and negative evidence is sufficient for this narrowly scoped regression review. No additional native run is requested here. This review does not establish hosted Xcode 26.3 execution or full balanced02 history acceptance.

## Binding and verification

Independently rehashed all 519 fixed source inputs and all 161 fixed products from `ci-native-fixed/fixed-products`. No current negative DerivedData bytes were used as fixed evidence. Current source matches the fixed manifest. The two new files plus four tracked modifications are the complete candidate: fixture root, fixture XCTest, contributor routing, generated project, planner and planner tests. Structured project comparison finds only two new file references/build entries and the corresponding group/source-phase additions; no target settings changed. Production button-style correction remains separate in committed 80d8727.

The fixed native result is exit 0 with strict 2/2 and zero runtime warnings; independently parsed raw lifecycle confirms each selected test starts and passes exactly once, with no implicit restart. Discard 47.13s and Retry 37.46s total 84.59s. Evidence is local Debug, iPhone 17 Pro arm64, iOS 26.2/23C54, Xcode 27.1; it is not a hosted 26.3 result.

Pure planner replay reproduces the retained compiled contributor manifest exactly: 42 unique selected cases in 13 shards, with both new exact methods once in contributor-balanced-02. Every selector file matches its manifest. 47 is the source inventory across both profiles, also enforced by retained offline checks; this build's compiled enumeration is contributor 42, not a fresh compiled dinner result. Existing matrix/shard identities, five-slot policy, per-case limits and warnings policy are unchanged. The existing balanced02 group grows by two cases, so its prior full-history timing is not a measured timing for the new group.

Retained checks are 24 planner + 4 slot + 17 workflow tests = 45 passing. Project generation check passed. All eight actionlint source hashes match. The narrow workflow checker passed with 14 independently validated queue nodes: raw actionlint 1.7.12 exits 1 for precisely those known queue-schema diagnostics, with zero unexpected diagnostics. Do not describe raw actionlint as exit 0.

## Regression behavior

The fixture is gated by DEBUG and CONTRIBUTOR_CAPTURE_UI_FIXTURE plus explicit launch arguments and a fresh UUID. It uses a unique temporary synthetic LedgerModel database, the real LedgerImportView and LedgerSaveStatus, and a separate SQLite BEGIN IMMEDIATE connection. The lease never writes payloads, validates zero changes when rolling back, has a 90-second bound and releases on background/failure/destruction. It does not set a container button style that could hide the production regression.

After the ordinary Add fails, an independent LedgerStore load must still equal the baseline before releasing the lock. The root observes the real pending-state transition even if the sheet dismisses. Discard checks durable record equality/hash/revision and empty contents before checking sheet retention, recovery clearance and Add re-enablement. Retry checks one revision/batch, exact names/quantities, unique row/contribution identities and their staged/batch links, cleared pending state and one real dismissal callback. The fixture does not directly invoke Retry or Discard in place of UI taps. Failure attachments retain the last durable audit before the assertion aborts.

The negative control removes only the two borderless modifiers. The retained fixed/negative source copies and hashes verify that exact difference; the XCTest binary hashes are identical. Native exit 65 contains one failure: “Discard must preserve the independent durable record”. Its attachment mapping binds the readback to the Discard case, exact negative device and configuration. The readback is sequence 1, revision 2, one batch, one contribution and `discarded oat jars=4/1 count`, matchesBaseline=false, pending/saving=false. Thus the new test detects the actual unwanted persistence rather than merely a missing sheet or setup failure. This is the fixture's independent store readback; this review did not reopen a raw negative database.

## Limits

These two cases isolate persistence/action dispatch and callbacks. They do not replace the prior normal-app largest-text/keyboard/restart attempt 8 evidence, demonstrate every accessibility or appearance state, or validate the entire new grouped runner history. They do not prove closure-entry order inside the automatic shared-row behavior. The old production defect and earlier setup/targeting failures remain preserved. No coverage hole was found that blocks this regression candidate within that stated scope.

Exact hashes, source/product counts, structured project changes, compiled-plan replay and negative attachment binding are retained in `permanent-ci-review-hashes.json`. Only scratch review files were written. No source/Git/hosted modification, build, test execution, simulator action or active-session polling was performed.
