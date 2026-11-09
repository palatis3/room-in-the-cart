# Dinner removal survives cancellation and restart

The ordinary Dinners route now has a compiled UI regression for previewing,
cancelling, then applying one dinner's removal. It verifies that the other dinner,
manual Wraps line and protected Lunch remain, including their original identities
after app restart. The reset-only seed extends the existing Debug/simulator fixture;
the ordinary app and SQLite save path perform the removal.

An independent read-only SQLite check verifies exactly two saved revisions: seed
and explicit removal. Whole-document comparison allows only the selected dinner's
removal, its source/allocation changes, and the corresponding receipt/revisions.
Manual12, other dinner4 and protected Lunch2 survive, as do earlier tombstone
dates. This also exercises the previously installed CoreDomain tombstone fix.

## Actual qualification

Frozen561-input manifest:
`bbe56492fa0890d1705b44b8e63f805621eaf5637152735d6ffa0cc971a629fd`.
Final product manifest:
`780efdedff4d84bfb126d14a412c3e357addc80a16d5baf5206264fc328b372e`.
Environment: Xcode27.1/27A9275, iPhone17, iOS27.0/24A434, light/Large,
ordinary Debug profile. Original deadlines and on-failure diagnostics retained.

- Clean build and app-bundle check pass in142.079seconds.
- Full removal journey passes native/strict checks in77.516seconds.
- Actual saved SQLite and final UI identity binding pass the whole-document check.
- Existing receipt/usable-food correction journey passes native/strict checks in
  57.436seconds, verifying the existing private-pickup seed remains usable.
- Compiled discovery finds740model and69UI cases. The new case occurs once in
  existingui-07; no new job or slot. Discovery does not claim all809cases ran.
- All419offline tests pass after installation, including eight persisted-readback
  controls. Independent Astra review found no blocking issue.
- All561native inputs match canonical after copying only the two reviewed native
  files. The verifier and its controls are installed under `scripts/`.

The initial route investigation failed because the new test expected “12 units”
while the existing quantity control displays “12 items.” The correction verifies
that exact control/value without weakening quantity or persistence invariants.
Its original result and database copy remain in `native-r1`. The first passing
candidate and products are archived before the clean SDK correction below.

## Build environment correction

The inherited `SDKROOT` selected macOS for Swift's child linker despite the
generated Swift command selecting iPhoneSimulator. Driver-only comparisons
reproduced the warning and SDK27.0 metadata. Unsetting SDKROOT removed the warning
but selected SDK17.0 metadata; explicitly resolving the simulator SDK selected27.1.
The clean build then verified all five actual package frameworks as
IOSSIMULATOR/minimum17.0/SDK27.1 with no incompatible-sysroot warnings.
Other AppIntents-extraction and signed-extension-stripping build warnings are
retained; this is not a claim of a wholly warning-free build. No Swift compiler
warnings were observed. The [local procedure](../../../CI-VALIDATION.md) now
requires target-scoped SDK selection without changing device or macOS builds.

## Retained proof and boundaries

Original local files are under `.build/SourceRemovalAcceptanceNov09/native-r3/`.
The SDK driver probes are under `.build/SDKRootDiagnosisNov09/`. These remain
local-only evidence, not an independently retrieved remote archive.

| Original | SHA256 |
| --- | --- |
| `installation.json` — input and proof map | `894716b9e0457a6a0c057d2e597c6d279cae4ccbca199ea6d2a87594d015600f` |
| `build/sdk-verification.json` | `47dafab9d0f6ad7ce7cf48e6856d5113b1769d71af7bbf176f4bda18643d1946` |
| `qualification/run.json` | `5e0477133ce1045e7055e2fcfd7c28f7f1393f113339de77ca43b562d6d22f0f` |
| `qualification/persistence/ledger-snapshot.sqlite` | `304ac3297f0b24862dab6a6529e411e2174c961e5c194b76a343da69f060e4b3` |
| `qualification/persistence/validation.stdout` | `76fa343cce56f6cd4b312d78758a96a0f133965b9561469f5b6090a0c856bd8c` |
| `private-recovery/run.json` | `e6c1e968f56f3f91d057db218f5967c035d90a3c1a6b25b8b0a173d0e1bfb308` |
| `offline-tests.log` | `366c7d80e63a441a7a333e1a11e573157d05b7caf663ec7d2ae726384bd2808d` |

The UI case joins ordinary hosted CI automatically. The companion SQLite readback
is verified locally here; it is not a new hosted database gate. F02 shared-device
tasks, minimum-OS full journeys, final combined regression and release remain
separate. Correct SDK metadata permits a new minimum-OS qualification, but does
not prove that the earlier XCTest logging crash was caused or fixed by SDKROOT.
