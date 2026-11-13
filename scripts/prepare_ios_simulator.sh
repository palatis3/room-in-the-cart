#!/bin/bash
# Overlap the existing boot check with artifact transfer. The wait command must
# succeed before XCTest starts; a background failure cannot be lost.
set -euo pipefail
receipt=.build/test-simulator-boot.status
log=.build/test-simulator-boot.log
case "${1:-}" in
    start)
        : "${SIMULATOR_ID:?Select an iPhone simulator first}"
        mkdir -p .build
        test ! -e "$receipt"
        test ! -e "$log"
        nohup /bin/bash -c '
            status=0
            python3 scripts/boot_ios_simulator.py "$SIMULATOR_ID" || status=$?
            printf "%s\n" "$status" > .build/test-simulator-boot.status.tmp
            mv .build/test-simulator-boot.status.tmp .build/test-simulator-boot.status
        ' > "$log" 2>&1 < /dev/null &
        ;;
    wait)
        test -f "$log"
        # The workflow retains its eight-minute timeout. Preserve diagnostics
        # when interrupted too; the runner cleans up tracked background processes.
        trap 'cat "$log"' EXIT
        while [ ! -f "$receipt" ]; do sleep 1; done
        status=$(cat "$receipt")
        if [[ ! "$status" =~ ^[0-9]+$ ]] || [ "$status" -gt 255 ]; then
            echo 'Invalid simulator boot result.' >&2
            exit 1
        fi
        exit "$status"
        ;;
    *) echo 'Usage: prepare_ios_simulator.sh start|wait' >&2; exit 2 ;;
esac
