#!/usr/bin/env python3
"""Select an image iPhone, or opt in to a job-owned device with identical type/runtime."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from uuid import UUID, uuid4


def select_iphone(devices_by_runtime):
    candidates = []
    for runtime, devices in devices_by_runtime.items():
        if ".iOS-" not in runtime:
            continue
        version = tuple(map(int, runtime.split(".iOS-", 1)[1].split("-")))
        for device in devices:
            if device["name"].startswith("iPhone") and device.get("isAvailable"):
                candidates.append((version, runtime, device))
    if not candidates:
        raise ValueError("No available iPhone simulator")
    _, runtime, device = max(candidates, key=lambda item: (item[0], item[2]["name"] == "iPhone 17"))
    return runtime, device


def simctl(*args):
    # The workflow setup/cleanup deadlines own this bound. On a slow hosted
    # image, even listing devices has taken over three minutes; do not impose
    # a second, shorter per-command timeout or retry the operation.
    return subprocess.run(["xcrun", "simctl", *args], check=True, capture_output=True,
                          text=True).stdout


def owner_identity():
    owner = {key: os.environ[key] for key in
             ("GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB", "TEST_SHARD", "DEVELOPER_DIR")}
    if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", owner["GITHUB_REPOSITORY"])
            or any(not re.fullmatch(r"[0-9]+", owner[key]) for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"))
            or any(not re.fullmatch(r"[A-Za-z0-9_-]+", owner[key]) for key in ("GITHUB_JOB", "TEST_SHARD"))
            or not Path(owner["DEVELOPER_DIR"]).is_absolute() or "\n" in owner["DEVELOPER_DIR"]):
        raise ValueError("Invalid CI owner identity")
    return owner


def runtime_identity(identifier):
    matches = [r for r in json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
               if r.get("identifier") == identifier]
    # Do not let an identical runtime identifier conceal different installed builds.
    if len(matches) != 1 or matches[0].get("isAvailable") is not True:
        raise ValueError("Chosen runtime is unavailable or ambiguously resolves to installed builds")
    row = matches[0]
    keys = ("identifier", "version", "buildversion", "bundlePath")
    if any(not isinstance(row.get(key), str) or not row[key].strip() for key in keys):
        raise ValueError("Chosen runtime lacks exact version/build/bundle identity")
    return {key: row[key] for key in keys}


def owned_name(owner, nonce):
    UUID(nonce)
    return f"RITC-CI-{owner['GITHUB_RUN_ID']}-{owner['GITHUB_RUN_ATTEMPT']}-{owner['GITHUB_JOB']}-{owner['TEST_SHARD']}-{nonce}"


def save_receipt(path, receipt):
    # Replace our receipt atomically; never follow a receipt symlink on writes.
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("x", encoding="utf-8") as output:
        json.dump(receipt, output, indent=2)
        output.write("\n")
    temporary.replace(path)


def current_owned_device(receipt):
    if runtime_identity(receipt["runtime"]["identifier"]) != receipt["runtime"]:
        raise ValueError("Chosen runtime identity changed")
    matches = [(runtime, device) for runtime, devices in json.loads(simctl("list", "devices", "-j"))["devices"].items()
               for device in devices if device.get("udid") == receipt["createdUDID"]]
    if not matches:
        return None
    if len(matches) != 1:
        raise ValueError("Created device UUID is ambiguous")
    runtime, device = matches[0]
    if (runtime != receipt["runtime"]["identifier"] or device.get("name") != receipt["createdName"]
            or device.get("deviceTypeIdentifier") != receipt["deviceTypeIdentifier"]
            or device.get("isAvailable") is not True):
        raise ValueError("Current device does not match the owned name/type/runtime")
    return device


def provision(devices, path):
    if path.exists() or path.is_symlink():
        raise ValueError("Refusing to replace an existing simulator ownership receipt")
    runtime, source = select_iphone(devices)
    owner = owner_identity()
    source_id = str(UUID(source["udid"])).upper()
    device_type = source.get("deviceTypeIdentifier")
    if not isinstance(device_type, str) or not re.fullmatch(r"com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9-]+", device_type):
        raise ValueError("Selected image device lacks an exact device type identifier")
    nonce = str(uuid4())
    receipt = {"schema": 1, "owner": owner, "sourceUDID": source_id, "sourceName": source["name"],
               "deviceTypeIdentifier": device_type, "runtime": runtime_identity(runtime), "nonce": nonce,
               "createdName": owned_name(owner, nonce), "createdUDID": None,
               "creationStatus": "pending", "cleanup": {"status": "not-run"}}
    path.parent.mkdir(parents=True, exist_ok=True)
    save_receipt(path, receipt)
    try:
        created = str(UUID(simctl("create", receipt["createdName"], device_type, runtime).strip())).upper()
        if any(device.get("udid", "").upper() == created for rows in devices.values() for device in rows):
            raise ValueError("Creation returned a device already present in the input inventory")
        receipt.update(createdUDID=created, creationStatus="created")
        save_receipt(path, receipt)
        device = current_owned_device(receipt)
        if device is None or device.get("state") != "Shutdown":
            raise ValueError("Fresh device was not found in Shutdown state")
        receipt["creationStatus"] = "verified"
        save_receipt(path, receipt)
        publish(created, receipt["createdName"])
        return receipt
    except (KeyError, ValueError, OSError, subprocess.SubprocessError) as error:
        receipt["creationStatus"] = "failed"
        receipt["creationError"] = str(error)
        save_receipt(path, receipt)
        raise


def cleanup(path):
    if not path.exists() and not path.is_symlink():
        print("No simulator ownership receipt; no device cleanup attempted.")
        return
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise ValueError("Refusing an invalid simulator ownership receipt")
    receipt = json.loads(path.read_text(encoding="utf-8"))
    # Verify ownership before recording anything or issuing a simulator mutation.
    if receipt.get("schema") != 1 or receipt.get("owner") != owner_identity():
        raise ValueError("Simulator receipt belongs to another CI owner or toolchain")
    if receipt.get("createdName") != owned_name(receipt["owner"], receipt["nonce"]):
        raise ValueError("Simulator receipt has an invalid owned device name")
    created = receipt.get("createdUDID")
    if created is None:
        receipt["cleanup"] = {"status": "no-created-device", "note": "No verified creation UUID; no device mutation attempted."}
        save_receipt(path, receipt)
        return
    if str(UUID(created)).upper() != created or created == str(UUID(receipt["sourceUDID"])).upper():
        raise ValueError("Refusing to clean up the source image device or invalid UUID")
    if os.environ.get("SIMULATOR_ID", created) != created:
        raise ValueError("Current simulator environment does not match the owned UUID")
    receipt["cleanup"] = {"status": "checking"}
    save_receipt(path, receipt)
    try:
        device = current_owned_device(receipt)
        if device is not None:
            if device.get("state") == "Booted":
                receipt["cleanup"]["status"] = "shutting-down"
                save_receipt(path, receipt)
                simctl("shutdown", created)
                device = current_owned_device(receipt)
            if device is None or device.get("state") != "Shutdown":
                raise ValueError("Owned device is not safely shut down; refusing deletion")
            receipt["cleanup"]["status"] = "deleting"
            save_receipt(path, receipt)
            simctl("delete", created)
            if current_owned_device(receipt) is not None:
                raise ValueError("Owned device remains after deletion")
            receipt["cleanup"] = {"status": "deleted"}
        else:
            receipt["cleanup"] = {"status": "already-absent"}
        save_receipt(path, receipt)
        print("Owned CI simulator cleanup: " + receipt["cleanup"]["status"])
    except (KeyError, ValueError, OSError, subprocess.SubprocessError) as error:
        receipt["cleanup"] = {"status": "failed", "error": str(error)}
        save_receipt(path, receipt)
        raise


def publish(udid, name):
    print(f"Using {name} simulator ({udid})")
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"SIMULATOR_ID={udid}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--create-owned", type=Path, metavar="RECEIPT")
    mode.add_argument("--cleanup-owned", type=Path, metavar="RECEIPT")
    args = parser.parse_args()
    try:
        if args.cleanup_owned:
            cleanup(args.cleanup_owned)
        else:
            devices = json.load(sys.stdin)["devices"]
            if args.create_owned:
                provision(devices, args.create_owned)
            else:
                _, device = select_iphone(devices)
                publish(device["udid"], device["name"])
    except (KeyError, ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Simulator selection/ownership failed: {error}\n")


if __name__ == "__main__":
    main()
