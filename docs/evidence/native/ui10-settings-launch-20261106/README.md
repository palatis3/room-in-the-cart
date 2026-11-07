# Reduce Motion case stopped during Settings setup

Original candidate `0d5bb1b22e9e84cd4b8c2b07317f91cfc703b60c`, core run `42316648565` attempt 1, UI10: **5 passed / 1 failed**, strict validation exit 1, zero runtime warnings. The failed Reduce Motion case timed out launching `com.apple.Preferences` at its first setup call. It did not reach reading the original preference, registering restoration, or entering the app/share-cancellation scenario. The earlier 804 share Close failure is therefore still untested by this case.

XCTest subsequently emitted an internal issue-handling assertion and restarted its runner before the next different case. Zero runtime warnings does not erase that failure or restart. The collector did not retry the case or dispatch another run. No underlying Settings launch cause or application behavior is inferred from these observations.

Root independently rehashed the original ZIP, raw log and exact candidate test source against `proof.json`, then inspected the bounded source/log excerpts. Original archive remains in `.build/CIResearch20261106/candidate-0d5bb1b/core-collection/iphone-results-ui-10-1.zip`. No raw Records/media was opened. This is a retained failure classification, not a correction or release acceptance.
