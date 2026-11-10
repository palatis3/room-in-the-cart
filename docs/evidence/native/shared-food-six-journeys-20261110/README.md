# Six native fixture journeys

The r5 and r7 receipts establish six selected UI passes. Each passed strict result verification against its exact selector and preserved XCTest result. The corresponding source archives, test and inspection logs, original result bundles, and receipt hashes were verified from retained files. See [proof.json](proof.json) for the exact selectors and hash inventory.

| Journey | Run | XCTest seconds | Result |
|---|---|---:|---|
| Undo, English | r5 | 201.887 | Passed |
| Undo, Spanish | r5 | 207.799 | Passed |
| Meal, English | r7 | 238.710 | Passed |
| Meal, Spanish | r7 | 238.335 | Passed |
| Quote, English | r7 | 242.017 | Passed |
| Quote, Spanish | r7 | 242.191 | Passed |

The two r5 Undo journeys also checked the same-store copy. The r7 UI-only build reused those passes, 145 HouseholdClient package passes with three expected wire skips, and 174 selected model passes. All three attempts had the same 623 source entries. The only source change after r5 was inside the Meal UI journey and its review assertions. Ordinary Undo code stayed identical. All 259 non-UI product entries matched byte for byte and by mode across the three product snapshots. The original r5 and r6 snapshots and earlier evidence were preserved and reverified.

The original r5 English Meal attempt failed when its nested query could not find “Two lunch wraps” after revealing the protected lunch source. The r6 English Meal attempt passed both corrected review assertions, reached retry confirmation, and then failed to find “Original taco dinner.” Both failures and their original results remain in custody. The r7 change reversed the initial search direction at the post-retry dinner assertion, and both Meal languages passed.

The evidence covers the six local fixture journeys under the local diagnostics setting. Screenshot review, real-service UI, and release acceptance are separate.
