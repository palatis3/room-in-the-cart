# Late delivery after pickup closure

Closing a shared pickup previously blocked its later physical corrections. The assigned shopper can now record late deliveries, correct received and usable quantities, match ingredients, and review protected portions. The pickup stays closed; original checkout, confirmed amendments, meal plan and spending remain separate.

Review also reproduced a durable retry bug: reading another pickup could authorize clearing the original pickup’s pending delivery. The corrected model detaches that action from the new screen, preserves its exact outbox bytes, and requires the original pickup’s facts before an explicit clear. The same native regression fails on the old guard and passes on the correction.

The final iOS 17 run passed **all 699 selected tests: 696 models and three complete UI journeys**, with zero skips or recorded runtime warnings. The closed-pickup and Spanish largest-text confirmation journeys also passed on iOS 26.2 using the same compiled products. The closed journey records a late arrival, corrects usable food and a protected amount, then verifies Closed, $37.20 paid, $0 pending and $2.40 already included in charges. The confirmation journey preserves cancel and exact retry after restart in both languages.

Largest text exposed two recovery visibility problems: explanatory text pushed Retry below the initial screen, and confirmation preserved a scroll position below it. Retry now precedes that explanation and is brought into view when the saved action becomes ready. Date and time controls occupy separate rows at accessibility sizes. Earlier failed runs remain recorded; no test limits or warning rules were relaxed.

Backend checks passed 443 unit tests and 243 PostgreSQL cases, with existing skips identified separately. Real Swift over pinned HTTPS passed six integration cases and ten exact XCTest scenarios, including closure and late corrections. All 219 Python tooling checks and the unsigned generic arm64 Release build/bundle checks passed.

[Verification, exact scopes and source hashes](verification.json) · [Backend proof](backend/verification.json) · [Real Swift wire proof](wire/verification.json) · [iOS 17 strict receipt](final-strict.txt) · [iOS 26.2 strict receipt](modern-strict.txt).

Migration 042 and the service changes remain local. Hosted staging is through approved 041. Hosted current-source validation, configured providers, signed distribution, physical-device checks and human Spanish review remain release gates.
