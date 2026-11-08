# Other meals disclosure · original minimum-iOS failure

The original product’s disclosure does not expose a button named **“Other meals in this shop”** in this captured iPhoneSE3/iOS17.0 state. The focused case failed before any label-tap behavior was exercised: native65/strict1,59.296seconds. This baseline is preserved as a failure, not an accepted test or audit waiver.

## Exact evidence

[Original header PNG](images/other-meals-collapsed.png) and [discovery attachment](discovery.txt) show the visible label and named-button count0. [Adjacent hierarchy excerpt](hierarchy-excerpt.json) retains only original lines122–124, with the complete original20887-byte hierarchy’s hash and private path:

- StaticText “Other meals in this shop”: `(32,131.5,184.5,20.5)`.
- Adjacent Button: identifier `collapsed`, no label, `(332.5,135,10.5,13.5)`.

[Root directly viewed the PNG and read the exact records](root-review.json), reporting the reproduction. The exposed button bounds are below44pt in both dimensions; this is accessibility-frame evidence, not a physical touch hit-region measurement. The test stopped on the missing named button, so this baseline cannot establish label-tap behavior, disclosure fact preservation or a complete VoiceOver task.

The exact case is `HouseholdRequestPackUITests/testOtherMealsDisclosureHasNamed44PointControlAndLabelTapsPreserveReviewedFacts`. [Strict verification](run/strict.txt), native test/summary records and [run receipt summary](run/receipt-summary.json) preserve the failure, iOS17.0 build21A328/light/Large/increased-contrast-disabled setup, local Xcode27.1 build27A9275 and original case720/900limits. Zero runtime warning occurrences and zero animation-idle messages/runner restarts were recorded; separate Xcode `invalidDigitCount` tooling diagnostics remain in the timeline excerpt and are not hidden under that runtime-warning result.

Executed source manifest: `3dade26e9a7702f3520f6ff736d76ce679fb47f9f48782d6aa4f7cddfa43df9b`. [Baseline source pins](source-pins.json) bind the product, test fixture, test and Theme, plus collector/installation/test-patch hashes. These are the baseline inputs, not a claim that the later edited product remains identical.

## Post-case diagnostic delay

The case failed in59.296seconds. The on-failure collection used the owned `simctl diagnose --timeout600` process, as observed by root; the retained native log explicitly records a diagnostic-collection timeout after600seconds. [Timeline evidence](run/failure-and-diagnostic-timeline.json) preserves the failure, diagnostic message, tooling warnings and original log hash.

The suite ended at18:24:16.836UTC and the runner finished at18:34:19.233241UTC: **602.397241seconds between those boundaries**. This explains the roughly10minute post-case delay without treating it as test execution or an exclusive measurement of diagnostic-process latency; finalization and runner overhead are included. No large diagnostic archive is published.

## Preservation and pending follow-up

Exactly three existing attachments were selected once by the completed collector. This package independently verified all three hashes, copies the PNG and127-byte discovery text, and includes only the scoped hierarchy excerpt. [Collector receipt](capture-receipt.json) and [copy receipt](copy-and-verification-receipt.json) preserve original/source unchanged and inspection-copy-only statements. Full AX/activity/diagnostic outputs remain private; no export, inspection, native action, source edit, handoff edit or commit occurred while packaging.

A separate two-line product follow-up has been installed by root. Its qualification is pending in this baseline package; no fixed acceptance is inferred here. Broader accessibility, original36/fresh41audit closure and physical VoiceOver remain outside this evidence.
