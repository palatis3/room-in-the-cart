#!/usr/bin/env python3
"""Boot the specified simulator, optionally restarting it before a launch retry."""

import argparse
import re
import subprocess
import sys
from uuid import UUID


MIGRATION_FAILED = re.compile(r"^\[[^\]\r\n]+\] Status=3, isTerminal=YES(?:,|\.)")


def boot_simulator(simulator, restart=False):
    UUID(simulator)  # Never target the ambiguous "booted" alias.
    if restart:
        shutdown = subprocess.run(
            ["xcrun", "simctl", "shutdown", simulator],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        print(shutdown.stdout, end="", flush=True)
        if shutdown.returncode:
            # CoreSimulator reports 405 (shell status 149) when the launch
            # service has already taken this simulator down. It is ready to boot.
            already_down = (
                shutdown.returncode == 149
                and "domain=com.apple.CoreSimulator.SimError, code=405" in shutdown.stdout
                and "Unable to shutdown device in current state: Shutdown" in shutdown.stdout.splitlines()
            )
            if not already_down:
                return shutdown.returncode if shutdown.returncode > 0 else 128 - shutdown.returncode
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
    parser.add_argument("--restart", action="store_true")
    args = parser.parse_args()
    try:
        status = boot_simulator(args.simulator, restart=args.restart)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Could not check simulator boot: {error}\n")
    sys.exit(status)
