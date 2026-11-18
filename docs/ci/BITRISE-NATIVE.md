# Native Bitrise app pair

`bitrise.yml` adds one supplemental native Bitrise pipeline, `app-pair`, on
pushes to `main`, `codex/dinner-shopping-integration`, and `codex/first-version-followup`. Disable any old dashboard trigger
mapping so it cannot duplicate these repository-defined triggers. Both parallel
workflows use the same event `BITRISE_GIT_COMMIT`, anonymously fetch that exact
object from the canonical public repository, and refuse a different checkout.
Queued older commits are valid; neither lane silently switches to a newer tip.

| Workflow | Device | Coverage |
| --- | --- | --- |
| `compact-cooking` | iPhone SE (3rd generation) | Real cook/cancel/confirmation/reopen UI, atomic cooking/stock transaction, selective dinner Undo preserving later coffee |
| `large-tonight` | iPhone 17 Pro Max | No-shop Pantry and Dinners entries, cancel/no unintended pickup, English and Spanish offline fallback |

The exact three and two methods live in `scripts/fixtures/bitrise-native/`.
These add compact/large iPhone layout coverage to the normal iPhone 17 GitHub
and manual Buildkite checks; they do not replace required checks or claim a full
suite. Both compile the ordinary Debug app and tests at the event source.
No fixture flags, assertions, timeouts or warning allowances are weakened.

## Project setup and stack

Use a native **Bitrise CI** macOS Apple Silicon stack containing Xcode **27.1
(27A9275)** and iOS **27.0 (24A434)**, with both simulator device types installed.
Select a supported Mac machine with at least 14 GB RAM and set native project
concurrency to two. `-jobs 2` bounds each compilation. The workflow pins the stable native stack to `osx-xcode-27.1.x`. The workspace selects the included Mac machine type.
The script fails before compiling if the pinned toolchain/runtime is absent.

The public GitHub repository sends push events to the native Bitrise project.
The project currently uses the validated copy of `bitrise.yml` stored on Bitrise.
After changing that file, run `bitrise yml validate --offline --config bitrise.yml`
and `bitrise yml update --file bitrise.yml` from this checkout. The local
`.bitrise-cli.yml` selects Room in the Cart. Use `bitrise build list` to check
which jobs actually started on a push. Build Hub and Buildkite run separately.

Both lanes fetch the public source over HTTPS with Git credential helpers disabled.
After the checkout verifies the exact commit on an allowed push branch, Bitrise
activates its Xcode compilation cache when the project has cache access. The
activation step is skippable. The build and selected tests run in either case.
On `c1dcae3a`, Xcode reported 213 hits from 288 cacheable tasks on the SE and
240 from 282 on the Pro Max. [Compact build](https://app.bitrise.io/build/e42d550e-10f4-4b28-a939-4d411a0038fd) · [Large build](https://app.bitrise.io/build/2b4c4ef1-3b23-4023-8a8b-beabb71c0fbe)

Bitrise retains ordinary build logs and status. Result bundles stay on the
build VM. Each lane creates and removes its own simulator using the installed runtime.

## Evidence and validation

Each lane prints source SHA, device, selectors, expected count, Xcode version and
script hashes in `.build/bitrise-native-receipt.txt`. Build output stays in
`.build/NativeBuild.log`; the existing strict runner exports native summary/test
details and verifies exact selectors/counts, native exit and runtime warnings.
Both lanes start the simulator boot check and the arm64 simulator build together.
XCTest starts after both succeed. The boot transcript is in `.build/NativeBoot.log`.
Before this change the [SE build](https://app.bitrise.io/build/e37a6261-8377-4c19-8abd-03774e631f5b)
spent 35 seconds booting before compilation and the
[Pro Max build](https://app.bitrise.io/build/28f9df70-66fb-4d9c-9276-e09006970305) spent 38 seconds.
Compare hosted elapsed times across revisions when assessing the saving.

A bootstrap-only retry keeps the existing guard and cannot retry a started test.
Results cannot be called passed from a build-only success.

Offline checks:

```sh
bitrise yml validate --offline --config bitrise.yml
python3 -m unittest discover -s scripts -p test_bitrise_native_app.py
bash -n scripts/run_bitrise_native_app.sh
```

The Python tests use mocked process boundaries; they prove routing and failure
handling, not native application success. Actual simulator qualification remains
required on the combined published source. The official CLI's offline validation
checks schema only, not account-specific stack/machine availability.

References: [configuration schema](https://docs.bitrise.io/en/bitrise-ci/references/configuration-yaml-reference),
[CLI offline validation](https://docs.bitrise.io/en/bitrise-ci/bitrise-cli/working-with-bitrise-yml-via-the-bitrise-cli),
[stack selection](https://docs.bitrise.io/en/bitrise-ci/configure-builds/configuring-build-settings/setting-the-stack-for-your-builds).
