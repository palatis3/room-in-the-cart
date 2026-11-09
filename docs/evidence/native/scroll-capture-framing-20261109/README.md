# Strict log framing correction — November 9

The optional collector rejected an observed `log stream --style ndjson` banner as
JSON and treated a nonzero emitted-event count as a terminal error. The original
failure and two synthetic-control probes remain preserved in the
[local performance investigation](../local-performance-metrics-20261109/README.md).

The collector now accepts only the exact expected initial banner for its issued
predicate and generated diagnostic namespace. A banner cannot repeat or follow an
event. The terminal object must contain exactly `count` and `finished`, with strict
integer types, `finished=1`, and a nonnegative count equal to validated events.
Duplicate JSON members, mismatched counts, extra/drop fields, and records after
the footer fail. Earlier errors and all event/byte/time caps remain fatal.

Stderr still produces `stderr_present` and prevents capture qualification. No
warning suppression, source-pin change, app/test change, metric substitution or
baseline relaxation was made. This fixes parsing; it does not qualify the
warning-bearing transport or resolve missing hosted measurements.

Validation: **64 focused tests and all 378 offline tests pass**. Tests cover exact
production predicate/banner construction, chunk boundaries, eventful and zero
footers, malformed counts, conflicting/equal duplicate keys, ordering, caps and
the retained UID warning failure. Independent review found the duplicate-key
hole in the first draft; the final version rejects it before metadata admission.
Replay of the retained three-event probe validates all three records and its
footer while retaining the 44-byte stderr warning as an unresolved failure.

The actual broader predicate banner was observed in one bounded, one-second
stream with no emissions or native test. It matched the generated expectation;
only the header and stderr digest/count were retained, not app event contents.

Local-only originals are under `.build/HostedPerformanceCurrentNov09/`; retain
them for project lifetime. `framing-evidence-sha256.json` binds the source, patch
and checks. Key digests:

| Original | SHA-256 |
| --- | --- |
| `actual-predicate-banner.json` | `922745f792e38dd0c1c0e003538efb9dede9b2f7d07b05abd38bd6bf974a3c69` |
| `parser-replay-r2.json` | `d1dd45149f6c0459d67f2a0c132950c21a44dde24916e22b74235a83256577ea` |
| `offline-parser-tests-r2.log` | `721cf3c33bb5bc8b167e249fac2d50ef94c8c12fe012a1b1ee5c07a27f0ba3f2` |
| `framing-r2.patch` | `385c9a5cacc90ce30da355e69b684f5643072de2e5c853247e3a61b9a713e652` |

Hosted scroll run42592941333 is separately pinned to pre-correction revision
`e95fcec9988a2fb4b7e98e3d543d89b790f16c95`, with optional capture disabled. It cannot
qualify this parser change. Its original test, metric requirements and strict
validation remain enabled; no baseline is enforced or approved by that diagnostic.
