#!/usr/bin/env python3
"""Bound XCTest JSON export so failure evidence can still be uploaded."""
import argparse
import subprocess
import sys


EXPORT_TIMEOUT_SECONDS = 300


def export(bundle, kind):
    # No retry: a stalled reader must fail the step, preserving the original
    # result bundle for inspection and allowing always() cleanup/upload steps.
    subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", kind,
         "--path", str(bundle), "--compact"],
        check=True, timeout=EXPORT_TIMEOUT_SECONDS,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("summary", "tests"))
    parser.add_argument("--path", required=True)
    args = parser.parse_args()
    try:
        export(args.path, args.kind)
    except subprocess.TimeoutExpired:
        print(f"XCTest {args.kind} export exceeded {EXPORT_TIMEOUT_SECONDS}s; "
              "the original result bundle is retained. No retry attempted.", file=sys.stderr)
        return 124
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode > 0 else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
