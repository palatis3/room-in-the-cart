# Local CI validation

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
