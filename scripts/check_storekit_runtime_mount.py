"""Reconcile the iOS 26.2 StoreKit runtime mount before booting a locale device."""

import json
from pathlib import Path
import subprocess
import sys
import time


RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
BUILD = "23C54"
FALLBACK = Path("/Library/Developer/CoreSimulator/Volumes/iOS_23C54")


def simctl(*args, deadline=None):
    timeout = 240 if deadline is None else min(240, max(0, deadline - time.monotonic()))
    return subprocess.check_output(["xcrun", "simctl", *args], text=True, timeout=timeout)


def mount_state(deadline=None):
    runtimes = json.loads(simctl("list", "runtimes", "-j", deadline=deadline))["runtimes"]
    selected = [r for r in runtimes if r["identifier"] == RUNTIME and r["buildversion"] == BUILD]
    images = [image for image in json.loads(simctl("runtime", "list", "-j", deadline=deadline)).values()
              if image.get("runtimeIdentifier") == RUNTIME and image.get("build") == BUILD]
    if len(selected) == 1 and selected[0]["isAvailable"]:
        bundle = Path(selected[0]["bundlePath"])
        ready = [i for i in images if i["state"] == "Ready" and i.get("runtimeBundlePath") == str(bundle)]
        if len(ready) == 1:
            image = ready[0]
            print(f"StoreKit {BUILD}: {image['identifier']} {image['kind']} at {bundle}", flush=True)
            # A DMG installed directly can legitimately live under Volumes.
            # The downloaded Cryptex at this fallback mount was displaced during XCTest.
            asset = Path(image["path"])
            if (FALLBACK in bundle.parents and image["kind"] == "Patchable Cryptex Disk Image"
                    and asset.name == "AssetData" and asset.parent.suffix == ".asset"):
                return "fallback"
            return "ready"
    if not any(i["state"] == "Ready" for i in images) and any(
            i.get("unusableSubstate") == "Cryptex Mount Preferred" for i in images):
        return "replacing"
    return "unavailable"


def check_mount():
    state = mount_state()
    if state == "ready":
        return
    if state == "unavailable":
        raise RuntimeError(f"StoreKit runtime {RUNTIME}/{BUILD} is unavailable or ambiguous")
    print(f"Reconciling {state} StoreKit Cryptex mount before boot", flush=True)
    simctl("runtime", "scan-and-mount")
    # On the hosted runner an explicit rescan left the fallback in place. The
    # periodic scan replaced that mount after 600s; the actual remount took 8s.
    deadline = time.monotonic() + (660 if state == "fallback" else 60)
    while True:
        state = mount_state(deadline=deadline)
        if state == "ready":
            return
        now = time.monotonic()
        if state != "fallback":
            deadline = min(deadline, now + 60)
        if now >= deadline:
            raise RuntimeError(f"StoreKit runtime {RUNTIME}/{BUILD} after rescan: {state}")
        time.sleep(min(10, deadline - now))


if __name__ == "__main__":
    try:
        check_mount()
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        sys.exit(str(error))
