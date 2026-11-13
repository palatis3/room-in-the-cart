# Fresh-simulator performance result — November 9

[Run 42598431187](https://github.com/palatis3/room-in-the-cart/actions/runs/42598431187),
attempt 1, tested `040ec583e80cc2a70b215df81df60695c99f01fd` and is terminal failure.
The owned-device receipt and XCTest result agree on a newly created iPhone 17,
arm64, iOS 27.0/24A434, using Xcode 27.1/27A9275. The original scroll test passed
1/1 in 161.425 seconds, but required scroll-duration measurements remain absent.
The original result SQLite and JSON export agree: three memory series, five
samples each. No calibration or approved baseline resulted.

Fresh-device provenance alone did not repair this observed failure. Both runs
used the same recorded host OS, simulator runtime and Xcode; different runners
and source revisions still limit causal attribution. The original performance
test, fixture, scheme, validators and baseline bytes match the prior run.
The post-hoc query captured zero events; that does not prove no emission.

The new failure-preservation path passed. Its WAL-consistent ledger snapshot
matched the exact 500-item fixture, with 500 contributions, zero checkoffs and
valid SQLite integrity. It matched the strict saved-pickup head. Only after
preservation did owned cleanup succeed and record deletion. No image-provided
simulator was deleted. Preservation took 2 seconds; cleanup took 13 seconds.

Original evidence is retained once under
`.build/HostedPerformanceCurrentNov09/hosted-42598431187/`.

| Proof | SHA-256 |
| --- | --- |
| Terminal report | `709232e4f147692656963f4a7adf28ca5473013897eae9688d9450ad3c1b5325` |
| First failure | `8b9d2fd5724ea8dbcdd1b9bc45decb98360a4d46c045edb82c4f307434b099ed` |
| Artifact 13665981859 ZIP, matched to GitHub | `9a9b058a260b17df9d4249abf443525987bf62265025e55721ce550b6e9f19e2` |
| Original result SQLite, unchanged after read-only inspection | `1c385e7f5619ad979c8be1c6185fe87eddb9d6718ce4c8a355f2a67e4eb96f22` |
| Preserved ledger snapshot, unchanged after read-only inspection | `79ded9f43aa69fbb36bc341e56f7ec478ca0b63628d7cfe9a6deb194f9a22a87` |

The existing build archive was subsequently inspected once without another
native run. Its GitHub ZIP digest matched, and only the 5,381-byte test plan was
extracted. Hosted and successful-local producer plans agree on the allowlisted
instrumentation settings; both reference the same runtime prefix for Main Thread
Checker. That describes generated plans, not loaded libraries or effective process
environments. Consumer restoration and reference availability remain unobserved.
The comparison is retained at `build-plan-review/producer-plan-comparison.json`
under the original evidence directory, SHA-256
`546a05dcfd414f219f4235092970216da3a41b742c8befa2299f8cdbbf8b4354`.

No unchanged retry is planned. Add bounded producer/consumer provenance to the
next justified build/restoration before proposing another native experiment.
The diagnostic remains opt-in; ordinary coverage, strict metrics, baseline
enforcement and full combined qualification are unchanged.
