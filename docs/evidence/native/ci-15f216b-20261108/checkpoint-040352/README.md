# Hosted candidate checkpoint — November 8, 04:03:52 UTC

Candidate `15f216b01e41c111ec99bbd812419cec32e6a5e4` has four completed successful workflows: Deep, Release performance, native wire and security. Core and fixtures are still running. Core's Chromium startup timeout remains the only observed failed job; it occurred before the history-page assertions. This checkpoint is not combined green acceptance. [Original run/job snapshot](checkpoint.json)

Newly collected UI04 passed all six cases, including the full Free dinner, protected lunch, short-fill repair, settlement and next-shop journey that failed on the preceding candidate. Contributor groups 02 and 04 passed eleven and five cases respectively. Their exact serial logs, inventories and warning receipts agree, with zero skips, recorded runtime warnings or runner restarts. [UI04](ui-04.json) · [Contributor 02](contributor-balanced-02.json) · [Contributor 04](contributor-balanced-04.json)

All three Release performance jobs completed successfully. Rendered search p95 was 3,744.006 ms against 4,750 ms, and checkoff p95 was 2,662.256 ms against 3,750 ms, with twenty samples each. These include XCTest input and idle/accessibility waits; they are not pure rendering latency. The six functional readback assertions and hosted SQLite receipt qualified the 500-line pickup and twenty matching checkoffs. [Rendered evidence](rendered.json)

Scroll's five duration samples had a median of 2.584 seconds against 3.25 seconds. Median absolute memory was 97,771 kB against 150,000 kB; the median and maximum peak-memory limits also passed. The signpost comparison agreed within one millisecond. XCTest emitted no animation-hitch series, so this result cannot evaluate frame hitches. The stored 500-line pickup was verified from the hosted SQLite receipt, not a new local database replay. [Scroll evidence](scroll.json)

The collector used bounded CRC-verified archive ranges and retained source/toolchain identities. No hosted run was cancelled, repeated, dispatched or replaced. Local source and evidence remain unpublished until the existing cohort is collected. Full first-version and physical-device acceptance remain open.
