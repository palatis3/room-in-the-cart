# Selected-runtime checker identity

[Run42625593343](https://github.com/palatis3/room-in-the-cart/actions/runs/42625593343)
attempt1 succeeded at `02aaed31d77eac837ce08217fd31276f2ef9bd3e` on November9.
This was the existing capability-only scope: no compilation or XCTest execution.
The full run took4minutes38seconds; it is not performance acceptance.

The selected arm64 iPhone17/iOS27.0 runtime build24A434, under Xcode27.1/27A9275,
contains `libMainThreadChecker.dylib` with exactly the preserved producer's bytes:

- Size:338880bytes.
- SHA256:`1ab99e516a208f4ce91fcde55af17ee83a4aedfc9687ec1eeade456943ea32e8`.
- arm64 Mach-O UUID:`E40A186A-8D7D-3029-B5CD-D42C967992C0`.

The earlier consumer's declared mount path was missing. This separate probe shows
that the selected hosted runtime contains the same library under its own mount.
It does **not** establish effective loading in the earlier test process or explain
the missing metrics. The receipt explicitly records `loadedState: unknown` and
`releaseAcceptance: false`. No test plan or checker setting was changed.
The declared insertion belongs to the test host, not the UI target app.

All capture-capability stages also passed; this checks available commands, not
live signpost transport or captured scroll measurements. Next investigate actual
test-host image loading outside measurement windows, preserving the original
performance selectors and strict gates. Do not rerun the unchanged library probe
or rebind the plan solely from this matching-byte result.

The3465-byte artifact13678681869 was downloaded and its archive digest matched
GitHub's published digest. Originals are retained locally under
`.build/HostedRuntimeCheckerNov09/monitor/`; the GitHub artifact link alone is not
project-lifetime retention.

| Original | SHA256 |
| --- | --- |
| Capability artifact ZIP | `29730f3a36c2e56bc2a516783ace3b4f74bf6da9f2daffd1d587f34de2f4eba0` |
| `runtime-checker.json` | `a0755d6dc616893c4990cfdec599b2e9225b777e9c24d176ca40219f2084ac7f` |
| `terminal-runtime-checker-report.json` | `e9ad9a969028fad4cd4dd63f0196ea37c010b9a113ce4db0e145a56009cf541d` |
