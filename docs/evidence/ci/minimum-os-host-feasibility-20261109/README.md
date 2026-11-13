# Minimum-iOS host feasibility — read-only audit

No alternative minimum-iOS lane has been qualified. The captured XCTest callback
fault remains unresolved; changing hosts or compilers is a diagnostic hypothesis.
The existing CodeQL Xcode 26.3 exception is not an iOS acceptance lane.

The strongest same-product candidate is an arm64 macOS 26 host with explicitly
provisioned Xcode 27.1 and the exact iOS 17.0/21A328 runtime. Apple's support matrix
lists Xcode 27.1 on macOS 26.6+, and GitHub's macOS 26 image reports 26.6.2. Its
installed inventory does not include the required Xcode 27.1/runtime pair.
[Apple support matrix](https://developer.apple.com/xcode/system-requirements),
[GitHub macOS 26 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

GitHub's macOS 15 arm64 image includes Xcode 26.3, a supported pairing. Running
Xcode 27.1-built XCTest products under 26.3 is not established by the reviewed
documentation; a different-SDK rebuild would not qualify the shipping binary.
[GitHub macOS 15 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).

Apple documents simulator downloads and build/test separation. These mechanisms
do not establish current availability of the exact old runtime or cross-Xcode
compatibility. None of the reviewed hosted inventories includes iOS 17.
[Runtime installation](https://developer.apple.com/documentation/xcode/installing-additional-simulator-runtimes),
[build/test separation](https://developer.apple.com/library/archive/technotes/tn2339/_index.html),
[current xcode-27 inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

Before another journey, verify provisioning feasibility, exact runtime build,
unchanged app/test artifact hashes and SDK load commands, and resolved XCTest
identity. Preserve original selectors, assertions, checker settings and limits.
An unmet prerequisite ends the probe before an app run. Even a supported-host
comparison does not by itself establish why the callback received a null pointer.

No documented fix for this specific fault was found in the reviewed
[Xcode 27.2 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes).
No files outside this report, downloads, native execution, account changes or
workflow dispatch were performed for the audit.
