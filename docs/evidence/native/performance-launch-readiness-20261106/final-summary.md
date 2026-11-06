# Performance readiness follow-up 807aa3c

Run 42304515547, attempt1: failure. No release acceptance claim.

| Case | Setup | Native strict | Measurements | Persisted pickup |
| --- | --- | --- | --- | --- |
| launch | passed | 0 | passed | not applicable |
| rendered | passed | 0 | passed | passed |
| scroll | passed | 0 | failed required measurement structure | passed |

All 5 retained archives match API size/digest. Exact 155 verifier inputs rehashed; original804 core/recovery freezes remain unchanged. Source is exactly f117 plus the reviewed four-line Shop readiness insertion.

See FINAL-AUDIT.json, evidence/outcomes.json, evidence/performance.json, native lifecycle proof and freeze.json. Original failures remain preserved.

All three native cases passed with zero runtime warnings and no implicit runner restart. Launch and rendered passed the unchanged approved baselines. Scroll failed because the required five-sample duration series is absent; original XCTest SQLite confirms only three memory series. Scroll saved-pickup readback passed independently.

The prior f117 passing scroll diagnostic has one event pair in all six activity windows. This run lacks pairs in warm-up and measured swipe 1 while retaining pairs in swipes 2–5. These are activity windows, not XCTest measurement boundaries; the difference does not establish cause or replace the missing metric.
