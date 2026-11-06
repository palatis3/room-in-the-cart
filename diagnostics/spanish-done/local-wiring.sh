#!/bin/bash
set -euo pipefail
: "${EXPECTED_SHA:?Use the exact reviewed diagnostic commit, not the acceptance checkout}"
: "${DIAGNOSTIC_RUNTIME:?Select an explicit installed runtime for this wiring-only run}"
: "${DIAGNOSTIC_RUNTIME_BUILD:?Select the exact expected runtime build, for example 23C54}"
test ! -e .build/spanish-done
finish() {
    initial=$?
    trap - EXIT INT TERM
    set +e
    python3 diagnostics/spanish-done/run.py collect
    collected=$?
    python3 diagnostics/spanish-done/run.py cleanup
    cleaned=$?
    if (( initial != 0 || collected != 0 || cleaned != 0 )); then exit 1; fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 diagnostics/spanish-done/run.py prepare --wiring --runtime "$DIAGNOSTIC_RUNTIME" --runtime-build "$DIAGNOSTIC_RUNTIME_BUILD"
bash diagnostics/spanish-done/build.sh
python3 diagnostics/spanish-done/run.py execute
