# Released iOS 27.1 capability comparison

An isolated four-file diagnostic ref 78d82b30d127cf73250e8f368277e52f508cf5b4
was derived from combined candidate ed92a993. It used standard xcode-27, pinned
Xcode 27.1/27A9275 and the officially published stable iOS 27.1/24A94425/Duo
alternative. No paid runner was selected. Primary combined-candidate workflow
configuration remains unchanged; this is not new current-OS or baseline coverage.

[Run 42585657527](https://github.com/palatis3/room-in-the-cart/actions/runs/42585657527)
is terminal failure. Its preboot guard verified the exact stable runtime/build,
iPhone Duo and arm64; boot passed. The fresh postboot device query still reached
its 30-second deadline (stage 30.482s), exit -15, child still running and no normal
or late bytes. Spawn took 1.771s, then 28.342s from pipes ready to the deadline.
Runtime inventory and logging help were never reached; no compilation, transport
or XCTest ran. Changing to this supported runtime/device did not resolve discovery.
No unchanged repeat or further timeout increase follows this result.

The isolated overlay passed 58 focused and 368 offline tests plus all 17 workflow
queue-node/actionlint checks. Production differences were only workflow runtime/
device settings and collector identity checks; original app/test/source pins,
metric thresholds, baseline approval, deadlines and cleanup remained unchanged.
RC/beta, old runtime and wrong model are rejected. These offline checks are not
performance acceptance. [Official image inventory](https://github.com/actions/runner-images/blob/741e4eb8ef5f51698d730ac16ede65cadb067522/images/macos/xcode-27-arm64-Readme.md)
and [Apple simulator catalog](https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex)
support the alternative; actual installed identity was separately verified.

## Retained evidence

- `.build/Xcode27ScrollDiagnosticNov09/ios27_1-duo-r1/publication.json` — SHA256 `984740c2fdccce2acb7671c4ebf403007ef401732095473483e2845f246435ef`.
- `.build/Xcode27ScrollDiagnosticNov09/ios27_1-duo-r1/receipt.json` — SHA256 `3bffa38d17e8f4086eb0ade09aa234fb7ad22779c3ca8b6fb2381a479962176b`.
- `.build/Xcode27ScrollDiagnosticNov09/ios27_1-duo-r1/hosted-42585657527/terminal-run-attempt-1.json` — SHA256 `f0489ff40c16d93faa0b2d838495971b699eab9a17b8a079c2af23ed710ee72a`.
- `.build/Xcode27ScrollDiagnosticNov09/ios27_1-duo-r1/hosted-42585657527/first-failure.json` — SHA256 `f84af56b5c5d0451f8cf221438bc943ebe0bd670940099881da71c6f8fd22041`.
- `.build/Xcode27ScrollDiagnosticNov09/ios27_1-duo-r1/hosted-42585657527/preboot-environment.json` — SHA256 `14d1cb1b80dd0d14ed1aef9050c866c0846c0160b7d2e5723b04c60d699178f6`.
