# Local CI validation

The Linux source check runs the Foundation 2.1 verifier with Python 3.13. It checks the 52 launch requirements, 27 screen contracts, source checksums, SQLite constraints and reference grocery scenarios. The PostgreSQL job separately executes all twenty grocery inbox scenarios against the service.

The workflow validator uses actionlint 1.7.12 plus the hash-pinned PyYAML requirements. Use an isolated environment; CI creates one before running the full Python suite. The lock currently covers CPython 3.12 on Linux x86_64 (Ubuntu 24.04) and CPython 3.9 on macOS arm64 (this Mac). Other interpreter/platform combinations require a reviewed wheel hash; source builds and unpinned fallback installs are disabled.

From the repository root:

```sh
python3 -m venv .build/ci-yaml
.build/ci-yaml/bin/python -m pip install --disable-pip-version-check --no-cache-dir --no-deps --require-hashes --only-binary=:all: -r scripts/ci_yaml_requirements.txt
.build/ci-yaml/bin/python -m unittest discover -s scripts -p 'test_*.py'
```

Run `scripts/check_ci_workflows.py` with that environment's Python, `--actionlint` pointing to the pinned 1.7.12 executable and `--report .build/workflow-lint.json`. The workflow contains the verified download and checksum for its Linux binary. Direct actionlint alone reports its known unsupported `queue` key; the paired validator exempts only the exact error at independently validated source positions and retains all other failures.

New macOS jobs must be added to the slot policy and tests. Keep slots on leaf jobs only; reusable-workflow callers and workflow roots must not own a slot while waiting for children. Existing non-native groups require a fixed prefix that is provably disjoint from reserved slot names, including case-insensitive comparisons. Every original test selection and final all-success gate remains required.

These are static checks. Hosted execution, native results, performance measurements, signed-device/provider acceptance and human review have separate evidence requirements. See [current acceptance](CURRENT-ACCEPTANCE.md).

## Shared delivery fixture timing

The six shared-delivery cases at `3e96fe3` passed on a hosted iPhone 17 running iOS 26.2. The runner spent about 2m33s on setup before the test step, then about 16m54s running and checking the shard. The six XCTest case durations account for 860.646s of that step. The suite now includes three more journeys. The table groups each whole journey once, using the six hosted case durations and passing local iOS 17 simulator measurements for the additions. [Hosted job and test log](https://github.com/palatis3/room-in-the-cart/actions/runs/42390883332/job/128469594458).

| Contributor shard | Hosted cases (seconds) | Additional local cases (seconds) | Estimated case time |
| --- | --- | --- | ---: |
| `SharedDeliveryUITests-stock-and-purchase` | Record and correct delivery 168.852, Spanish fractional stock 134.521, freezer correction 180.859 | Linked family purchase 54.555 | 538.787 s |
| `SharedDeliveryUITests-recovery-cook-and-closeout` | Unresolved replacement 164.069, replace Wednesday 135.417, dated cook copy 76.928 | Edited cook wording 47.302, financial closeout 94.418 | 518.134 s |

Each job restores the contributor build, boots its simulator, and checks its own selector file against the completed XCTest result. The fixture matrix has 17 jobs across both profiles, admitted through the five shared macOS slots. On the next hosted run, the `iphone-fixture-results-<shard>-<attempt>` artifacts record the per-case results. The two job timelines also include setup and result collection.

## Merge protection and release checks

As of November6, `main` requires a pull request, an up-to-date branch, resolved conversations, and the four GitHub Actions checks `CI gate`, `CodeQL (javascript-typescript)`, `CodeQL (actions)` and `Dependency review`. Admins follow the same rules; force push and deletion are disabled. Zero mandatory human approvals preserves the single-owner workflow. [Applied settings and independent verification](evidence/native/main-protection-20261106/README.md).

These are the unfiltered core/security PR gates. Path-filtered fixture, deep, performance and native-wire workflows are not directly required by branch protection: a documentation-only change can skip them. A merge passing the baseline therefore does not establish full regression acceptance.

Before distribution, run the unfiltered `Pre-release regression checks` workflow on the exact release branch head and require its `Automated release gate` to succeed. It includes all six workflow scopes, strict release metadata, full lockfile vulnerability audits and exact-commit CodeQL/open-finding checks. Source changes invalidate that candidate's release result. Actual signing, live-provider acceptance and physical/human gates remain required. The future distribution integration must enforce this boundary; this manual workflow does not itself upload or technically prevent an independent App Store upload.
