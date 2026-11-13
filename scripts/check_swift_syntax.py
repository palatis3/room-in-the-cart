#!/usr/bin/env python3
"""Cheap syntax-only check; compilation and original tests remain required."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def source_files(root, changed=False):
    commands = ([['git', 'diff', 'HEAD', '--name-only', '--diff-filter=ACMR', '-z', '--', 'ios'],
                 ['git', 'ls-files', '--others', '--exclude-standard', '-z', '--', 'ios']]
                if changed else
                [['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', 'ios']])
    names = set()
    for command in commands:
        names.update(subprocess.check_output(command, cwd=root).decode().split('\0'))
    return [root / name for name in sorted(names)
            if name.endswith('.swift') and Path(name).name != 'Package.swift'
            and (root / name).is_file()]


def check(files, timeout=60):
    if not files:
        print('No selected Swift source files.')
        return 0
    # Parse both ordinary Release and Debug fixture branches. This deliberately
    # does not import SDK modules, type-check, emit products or start a simulator.
    for label, flags in [('Release', []), ('Debug fixtures', ['-D', 'DEBUG', '-D', 'CONTRIBUTOR_CAPTURE_UI_FIXTURE'])]:
        print(f'Parsing {len(files)} Swift files ({label})', flush=True)
        try:
            result = subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', *flags,
                                     *map(str, files)], timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f'Swift syntax check could not finish: {error}', file=sys.stderr)
            return 2
        if result.returncode:
            return result.returncode if result.returncode > 0 else 1
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--changed', action='store_true', help='Include staged, unstaged and untracked iOS Swift changes against HEAD')
    args = parser.parse_args()
    return check(source_files(ROOT, args.changed))


if __name__ == '__main__':
    sys.exit(main())
