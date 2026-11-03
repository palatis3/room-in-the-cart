# Exact source changes and identities

Live HEAD at verification: `dbf9b41ecf1914df78a536825c01da2f90a220fc`. All listed working files match the independently frozen final source.

| File | Status versus HEAD | SHA256 |
|---|---|---|
| `ios/Features/Household/SharedMealIdeasView.swift` | Modified for final correction | `001fa6043afe62d67da33a22aa99adbcda90788c73893a3b0be3601ebb7a0b76` |
| `ios/Features/Household/SharedMealIdeaProposalView.swift` | Modified for final correction | `de9c8dcc133aea46edf4d3c613dff443adff510f0f7bc407657b8984a7282881` |
| `ios/Tests/SharedMealIdeaTests.swift` | Already committed in earlier checkpoint | `a20d2890f80011ca0c02a20e698ed17a60af39fd34818fa798e3886b81519266` |
| `ios/UITestSupport/SharedMealChangeUIFixture.swift` | Already committed in earlier checkpoint | `26c77195a3f61faf112d6ed1e77c1276f3e3aa3aff637bc4135d3214db156a4c` |
| `ios/UITestSupport/SharedMealIdeaUIFixture.swift` | Already committed in earlier checkpoint | `b311a24424246b4c450c7c3bbcfd96951cd03f92d7a19db0a94a2d31c4a6a555` |
| `ios/UITests/SharedMealChangeUITests.swift` | Already committed in earlier checkpoint | `07024f5fb55ebe49e07ea88f95f8229be5f51b6119d531009581ff97d27dad78` |
| `ios/UITests/DinnerAwayCarryoverUITests.swift` | Already committed in earlier checkpoint | `5f137129937ee234cb4eda870fd6d9216905f9a67143fd7073ccf02c8f1bfca9` |
| `ios/UITests/SharedMealIdeaUITests.swift` | Modified for final correction | `b667e2cf9b9d88d25c01e1d5df6d514a0429c51159ce47cb14632aa8889b32b4` |

The three modified files provide stable scoped proposal navigation, accessible evidence/Done/Cancel controls, observing proposal content, and the permanent lifecycle regression. The five earlier committed files contain the four rational regressions, stable fixture quote timestamps/creation behavior, and corrected S17/S25 UI helpers. Both S26/S27 live dispatcher branches were preserved. No common shared-meal date formatter was edited by this lane; its uncovered display gap is recorded separately.
