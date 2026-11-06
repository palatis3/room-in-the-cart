#!/usr/bin/env python3
"""Run simctl bootstatus and reject its observed zero-exit migration failure."""

import argparse
import re
import subprocess
import sys
from uuid import UUID


MIGRATION_FAILED = re.compile(r"^\[[^\]\r\n]+\] Status=3, isTerminal=YES(?:,|\.)")


def boot_simulator(simulator):
    UUID(simulator)  # Never target the ambiguous "booted" alias.
    failed = False
    # Keep output live and keep the caller's existing job/step timeout in charge.
    # -b also supports an already-booted device without a terminal status record.
    with subprocess.Popen(
        ["xcrun", "simctl", "bootstatus", simulator, "-b"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    ) as process:
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            if line.strip() == "Data Migration Failed" or MIGRATION_FAILED.match(line):
                failed = True
        status = process.wait()
    if status:
        # Preserve ordinary nonzero codes, including timeout statuses; represent
        # signal termination with the conventional shell status (e.g. SIGTERM 143).
        return status if status > 0 else 128 - status
    if failed:
        print("Simulator boot failed: simctl reported Data Migration Failed despite exit 0.", file=sys.stderr)
        return 1
    # This is a guard for the observed failure, not a general simulator health check.
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator")
    args = parser.parse_args()
    try:
        status = boot_simulator(args.simulator)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Could not check simulator boot: {error}\n")
    sys.exit(status)
