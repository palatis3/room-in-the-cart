# Household fixture isolation — November 9

## Confirmed defect and installed correction

Two household models used a process-wide S24 test server/interceptor. Creating
fixture B redirected later requests from A into B, even with sequential test
execution. A lock around the old pointer alone would not correct ownership.

The new regression uses original helper APIs. On unfixed source it failed with
A's totals 3720/4020 instead of 0/300, A's preview count 0 instead of 1, and B's count 2
instead of 1. Native 65/strict 1; the expected four assertion failures and original
result are preserved. This establishes the defect, not an inferred race.

Each fixture now owns a unique HTTPS .invalid host and ephemeral session. A
locked weak registry routes requests, and each held response retains its original
server. Interceptors and change callbacks run outside registry/server locks.
Explicit teardown unregisters hosts, clears capturing callbacks and invalidates
sessions. Vault state is locked. Unknown and retired destinations fail locally;
no request falls through to the real network. No URLProtocol Sendable claim or
test serialization was added.

All 26 original cases remain, with two additions. All 28 passed native and strict
validation on the owned iPhone 17 Pro/iOS 26.2 simulator under Xcode 27.1/27A9275.
The held-response case changes both interceptors after fixture B starts, then
verifies A retains its own response. The lifetime check verifies that retaining
a session does not retain the fixture and retired hosts cannot resolve elsewhere.
The compiler-supported immutable weak binding was typechecked in Swift 5 mode and
validated natively. Final build/bundle checks passed in 13.102 seconds, with no
compiler warnings; tests completed in 14.109 seconds. The frozen candidate and
canonical installation match all 561 product inputs. Only three test files changed
from ed92a993; app and production transport code are unchanged.

This is scoped fixture isolation, not general Foundation concurrency certification.
Manual interceptor responses retain their existing controlled sequencing, and
cancellation cannot retract callbacks already running. Membership/restoration
fixture shared-state follow-ups remain separate. Full combined CI and release
acceptance remain open.

## Faster local qualification without discarding proof

Before reusing execution paths, prior source and products were APFS-cloned and
verified against complete manifests, including executable modes. Logs, results
and existing receipts were not changed. Frozen copies live under
`.build/NativeQualificationArchivesNov09/<source-manifest-SHA>/`. Their custody
records identify the old mutable execution paths; old executors are historical
and must not be rerun against newer contents. Archived xctestruns retain absolute
paths, so any independent replay requires explicit path review and a new receipt.

The two earlier fresh-path builds took 211.313 and 213.238 seconds. Reusing the same
source/DerivedData paths yielded 16.100 seconds for the negative-control build,
15.125 seconds for the initial fix build and 13.102 seconds for the final build.
These are observed runs with different inputs, not a controlled benchmark or
promise for every change. Preserved source/product identity enables incremental
work while retaining the first failure and previous qualification originals.

## Retained evidence

- `.build/S24FixtureIsolationNov09/negative-r1/source.json` — SHA256 `3b14f3b3c9c18da1a9df10c635e8e4b98b09694cdea0787b89cf41e429fab80e`.
- `.build/S24FixtureIsolationNov09/negative-r1/negative-control/inspection/verification.json` — SHA256 `4648a52ef37acc7dc12401f159d349d813390e9f8e903949fc1f8daf46b48e5d`.
- `.build/S24FixtureIsolationNov09/positive-r2/source.json` — SHA256 `7e9f3a6c427ff90dd2b35f56acdbd78179e1ac28ab08c459b27e89c83ac7ff7a`.
- `.build/S24FixtureIsolationNov09/positive-r2/build/run.json` — SHA256 `ffc23c72267fb7778f7be956d0b778f2c377f64e9557ae8f60bbd10af1678a38`.
- `.build/S24FixtureIsolationNov09/positive-r2/s24-regression/inspection/verification.json` — SHA256 `8b431547f5a51e4a50f3d0ca59f285b8c5a26128dd7667b90c3ee5181ba9b0d4`.
- `.build/S24FixtureIsolationNov09/positive-r2/installation.json` — SHA256 `306527b82c0f4dbaeceb28975ae21dedf181ac90f7a0792bff41bd4e5519b515`.
- `.build/S24FixtureIsolationNov09/fixture-isolation-r2.patch` — SHA256 `3cab191d8c4d35b8d5d2d3de2f0eb4074d4bd5224d3efc4c7ad8bb7dabbc3b68`.
- `.build/NativeQualificationArchivesNov09/REVIEW.md` — SHA256 `6b0de17f88aa17867237fe9590adc0194a76650b06d3c5801812ee4da6d423ca`.
