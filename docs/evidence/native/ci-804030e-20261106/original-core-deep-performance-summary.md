# Candidate 804030e — original attempt 1

All three named runs are terminal. This collection does not establish release acceptance.

| Lane | Conclusion | Retained result |
| --- | --- | --- |
| Core | failure | Models 601/601; ordinary 48/51 passed, 3 failed, 6 runtime warnings |
| Deep | failure | Address/thread each 389 passed + 3 declared skips; Spanish 15/15; English never acquired a runner |
| Performance | failure | Launch/rendered native and approved-baseline pass; scroll failed before native execution |

Core native failures remain explicit: UI06 saved-offer deadline reminder exceeded the unchanged 720-second allowance with ten animation-idle synchronization delays; UI10 Reduce Motion share cancellation failed its Close-readiness expectation. UI07 next-shop cancel/open-fresh-list also exceeded 720 seconds, with twelve animation synchronization delays. All three failing shards include an implicit XCTest runner restart and strict lifecycle failure. The UI06 largest-type/dark case passed this attempt; the prior failure remains preserved. UI10 case-only video, exact attachment mapping, hierarchy and query timeline are retained in ui10-share-failure-inspection/. A sampled pre-failure frame shows the sheet and Close control visible, which does not prove accessibility hittability.

English job 128079949194 has runner 0, empty steps and hosted-capacity acquisition annotations. Scroll job 128083892445 failed setup with exit 60 after bootstatus reported Finished; native execution and validation were skipped. There is no new scroll metric or saved-pickup outcome. Previous missing-scroll-series evidence remains open.

Exact source and compiled-case parity: 2,338 immutable Git files, 153 verifier inputs, 601 model + 51 ordinary UI cases, 15 dedicated StoreKit cases disabled in this plan; original IDs/groups/order and duration assignments preserved. Actual expected Xcode 26.3/17C529 and observed XCTest iPhone 17 arm64/iOS 26.2/23C54 remain required.

All 23 available scoped ZIPs match GitHub digest/size. Current original extracted result members match their ZIP bytes. The model/UI03 copy-path correction and identical fresh-copy confirmations are preserved. Deep/performance scoped freezes remain unchanged. Swift security semantics are root-reviewed separately, retaining known extraction limits.

Timing uses first/last step timestamps for runner execution and separately reports run wall spans; job started_at is not treated as execution time. See evidence/timing-summary.json.

Details: FINAL-AUDIT.json, core-summary.json, evidence/native-execution.json, evidence/scroll-pretest-setup-failure.json, evidence/storekit-en-runner-acquisition-failure.json, and the adjacent freeze.json. No retry, dispatch, local native app/test execution, source/Git edit or remote mutation was performed by this collector.
