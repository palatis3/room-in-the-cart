#!/usr/bin/env python3
"""Check the repository Node pin against official release and support metadata."""

from datetime import date, datetime, timezone
from http.client import HTTPException
import json
from pathlib import Path
import re
import sys
from urllib.request import urlopen


INDEX_URL = "https://nodejs.org/dist/index.json"
SCHEDULE_URL = "https://raw.githubusercontent.com/nodejs/Release/main/schedule.json"
NETWORK_TIMEOUT_SECONDS = 8
NUMBER = r"(0|[1-9][0-9]*)"
VERSION = re.compile(rf"{NUMBER}\.{NUMBER}\.{NUMBER}")
RELEASE_TAG = re.compile(rf"v{VERSION.pattern}(?:-(?P<prerelease>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")


def read_pin(root):
    pin = (root / ".node-version").read_text(encoding="utf-8").strip()
    match = VERSION.fullmatch(pin)
    if not match:
        raise ValueError(".node-version must specify an exact stable version such as 22.23.4")
    version = tuple(map(int, match.groups()))
    expected = f">={pin} <{version[0] + 1}"
    for project in ("service", "web"):
        for filename in ("package.json", "package-lock.json"):
            path = f"{project}/{filename}"
            try:
                document = json.loads((root / path).read_text(encoding="utf-8"))
                package = document if filename == "package.json" else document["packages"][""]
                actual = package["engines"]["node"]
            except (KeyError, TypeError) as error:
                raise ValueError(f"{path} is missing its root Node engine constraint") from error
            if actual != expected:
                raise ValueError(f"{path} root Node engine must be {expected!r}; found {actual!r}")
    return version


def check_release(version, index, schedule, today):
    major = f"v{version[0]}"
    if not isinstance(schedule, dict) or not isinstance(schedule.get(major), dict):
        raise ValueError(f"Official Node schedule is missing {major}")
    try:
        start = date.fromisoformat(schedule[major]["start"])
        end = date.fromisoformat(schedule[major]["end"])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(f"Official Node schedule has incomplete or invalid dates for {major}") from error
    if not start < end:
        raise ValueError(f"Official Node schedule has inconsistent dates for {major}")
    if today < start:
        raise ValueError(f"Node {major} is not yet supported; scheduled start is {start}")
    if today >= end:
        raise ValueError(f"Node {major} reached end of life on {end}")

    if not isinstance(index, list) or not index:
        raise ValueError("Official Node release index is missing or invalid")
    releases = {}
    for entry in index:
        if not isinstance(entry, dict):
            raise ValueError("Official Node release index contains a malformed release")
        tag = entry.get("version")
        match = RELEASE_TAG.fullmatch(tag) if isinstance(tag, str) else None
        if not match or type(entry.get("security")) is not bool:
            raise ValueError(f"Official Node release index has invalid version or security data for {tag!r}")
        released = tuple(map(int, match.group(1, 2, 3)))
        if match.group("prerelease") or released[0] != version[0]:
            continue
        if released in releases:
            raise ValueError(f"Official Node release index contains a duplicate release {tag}")
        releases[released] = entry["security"]

    pin = ".".join(map(str, version))
    if version not in releases:
        raise ValueError(f"Node {pin} is not a published stable release in the official index")
    floor = max((released for released, security in releases.items() if security), default=None)
    if floor is None:
        raise ValueError(f"Official Node release index does not establish a security floor for {major}")
    floor_text = ".".join(map(str, floor))
    if version < floor:
        raise ValueError(f"Node {pin} is below the security floor {floor_text} for {major}")
    return floor_text, end


def fetch_json(url):
    try:
        with urlopen(url, timeout=NETWORK_TIMEOUT_SECONDS) as response:
            return json.load(response)
    except (OSError, HTTPException, ValueError) as error:
        raise ValueError(f"Cannot read official Node metadata from {url}: {error}") from error


def main():
    try:
        root = Path(__file__).resolve().parents[1]
        version = read_pin(root)
        index = fetch_json(INDEX_URL)
        schedule = fetch_json(SCHEDULE_URL)
        floor, end = check_release(version, index, schedule, datetime.now(timezone.utc).date())
    except (OSError, ValueError) as error:
        sys.exit(f"Node runtime check failed: {error}")
    pin = ".".join(map(str, version))
    print(f"Node {pin} meets the security floor {floor} and is supported until {end}.")


if __name__ == "__main__":
    main()
