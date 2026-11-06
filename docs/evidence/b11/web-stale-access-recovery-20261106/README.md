# Clear stale access denial after successful authorization

A pending request correctly rejected a changed actor, cleared private content, and sent no command. A later successful Refresh loaded the new contributor’s form but left the previous “Access has ended” notice above it. Actual Android Chrome reproduced this contradictory state.

The successful authenticated end of load now clears only that ordinary access-denial message, and only while the same authorized session remains current. Anonymous loads, storage-cleanup warnings, failed-save and receipt messages retain their behavior. The session guard also preserves a new expiry denial if helper/editor access ends while a suggestion request is awaited.

The actor-recovery regression fails on original code. A separate deferred-Refresh expiry regression fails on the first unguarded proposal. The final production build and all120web tests pass, including both helper/editor races and storage-warning retention. Actual Chrome156 on Android14 repeats the actor fence and then shows the authorized form without the stale message; zero command calls/effects occur. Root visually reviewed before/after captures.

A separate real Chrome restart preserves the fictional pending IndexedDB row, but loses the fixture session. The private wording and Retry remain hidden after offline restart and anonymous reconnect; no operation sends. This covers the safe anonymous branch, not an authenticated session-survival branch. See [verification and driver limits](verification.json).

The old and fixed bundle hashes, synthetic counters, DOM observations and tests are retained. The corrected bundle is local only, with no staging deployment or PR push. Owned fixture servers/tabs/reverse mappings and CDP forwarding are cleaned up; the public Help page is restored. Real provider, household and physical-device acceptance remain separate.
