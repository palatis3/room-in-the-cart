# Native Bitrise app pair

`bitrise.yml` adds one supplemental native Bitrise pipeline, `app-pair`, on
pushes to `main` and `codex/dinner-shopping-integration`. It has no pull-request,
tag, wildcard branch or schedule trigger. Disable any old dashboard trigger
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

There are no SSH-key, signing, secret, deployment, third-party upload, remote
cache or artifact-distribution steps. Source fetch is public HTTPS with Git
credential helpers disabled. Do not add account tokens. The only uploads
inherent to the CI service are its ordinary build logs/status. Retain result
bundles and logs on the build VM for inspection; this source does not publish
them elsewhere or claim long-term artifact retention. Each lane owns and deletes
only its newly created simulator. No sudo, global simulator cleanup, or runtime
installation is performed.

## Evidence and validation

Each lane prints source SHA, device, selectors, expected count, Xcode version and
script hashes in `.build/bitrise-native-receipt.txt`. Build output stays in
`.build/NativeBuild.log`; the existing strict runner exports native summary/test
details and verifies exact selectors/counts, native exit and runtime warnings.
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
