"""Import exact iOS 26.2 on disposable GitHub runners before StoreKit device creation."""
import json
import os
import platform
import subprocess
import time
import uuid
from pathlib import Path


def require_standalone(target):
    """Reject the fallback Cryptex/temporary-parent form that lost its runtime."""
    assert target.get("kind") == "Disk Image", target
    assert not target.get("parentMountPath") and not target.get("parentIdentifier"), target
    path = target.get("path", "")
    assert path.startswith("/Library/Developer/CoreSimulator/") and "/Images/" in path, path


def prepare():
    assert os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
    assert os.environ.get("GITHUB_ACTIONS") == "true"
    assert platform.system() == "Darwin" and platform.machine() == "arm64"
    developer = "/Applications/Xcode_27.1.app/Contents/Developer"
    assert os.environ.get("DEVELOPER_DIR") == developer
    evidence = Path(".build/storekit-runtime-import")
    evidence.mkdir(parents=True, exist_ok=True)
    runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
    build = "23C54"
    asset_prefix = "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/"


    def capture(name, *args, timeout=None):
        result = subprocess.run(["xcrun", "simctl", *args], text=True, capture_output=True, timeout=timeout)
        (evidence / name).write_text(result.stdout)
        (evidence / (name + ".stderr.log")).write_text(result.stderr)
        result.check_returncode()
        return json.loads(result.stdout)


    def images(name, timeout=None):
        rows = capture(name, "runtime", "list", "-j", timeout=timeout)
        assert isinstance(rows, dict)
        return rows


    def targets(rows):
        return [r for r in rows.values()
                if r.get("runtimeIdentifier") == runtime and r.get("build") == build]


    def operation(name, command):
        with (evidence / (name + ".log")).open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        (evidence / (name + "-exit.json")).write_text(json.dumps({"exit": result.returncode}) + "\n")
        return result


    images("before.json")
    capture("before-simctl.json", "list", "-j")
    export = Path(".build/storekit-runtime-export")
    export.mkdir()
    result = operation("export", ["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion", build,
                                  "-exportPath", str(export.resolve()), "-architectureVariant", "arm64"])
    # An exporter exit 70 is tolerated only provisionally: a real bundle, successful
    # privileged import, and exact Ready image checks below must still all succeed.
    assert result.returncode in (0, 70), result.returncode
    bundles = list(export.glob("*.exportedBundle"))
    assert len(bundles) == 1 and bundles[0].is_dir(), "Expected one exported platform bundle"
    files = [{"name": str(f.relative_to(bundles[0])), "bytes": f.stat().st_size}
             for f in bundles[0].rglob("*") if f.is_file()]
    assert any(f["bytes"] > 0 for f in files), "Empty exported bundle"
    (evidence / "export-bundle.json").write_text(json.dumps({"bundle": str(bundles[0]), "files": files}, indent=2) + "\n")
    devices = capture("before-replacement-devices.json", "list", "devices", "-j")
    assert all(d["state"] == "Shutdown" for d in devices["devices"].get(runtime, []))
    replacement = targets(images("before-replacement.json"))
    # The initial image may have no 26.2 registration. Never delete an imported
    # image or another runtime/build. Validate the complete set before any mutation.
    for row in replacement:
        uuid.UUID(row["identifier"])
        assert row.get("deletable") is True, row
        assert row.get("path", "").startswith(asset_prefix), row
    asset_paths = {row["path"] for row in replacement}
    payload_names = [f["name"] for f in files if f["name"].endswith(".dmg") and f["bytes"] > 0]
    assert len(payload_names) == 1, "Expected one exact disk-image payload in exported 23C54 bundle"
    payload_name = Path(payload_names[0])
    assert not payload_name.is_absolute() and ".." not in payload_name.parts
    payload_paths = {str(Path(root) / payload_name) for root in asset_paths}
    allowed_paths = asset_paths | payload_paths
    (evidence / "original-asset-paths.json").write_text(json.dumps({
        "roots": sorted(asset_paths), "payloads": sorted(payload_paths)}, indent=2) + "\n")


    def original_rows(rows):
        # Include identity-less pending children; exact-build filters alone miss them.
        return [row for row in rows.values() if any(
            row.get("path", "") == root or row.get("path", "").startswith(root + "/") or
            row.get("parentMountPath") == root for root in asset_paths)]


    def validate_original(row, require_identity=True):
        uuid.UUID(row["identifier"])
        assert row.get("path") in allowed_paths, "Unexpected original-asset descendant: " + repr(row)
        if row["path"] in payload_paths:
            assert row.get("parentMountPath") in asset_paths
            assert row["path"] == str(Path(row["parentMountPath"]) / payload_name)
        assert row.get("deletable") is True
        for key, expected in (("runtimeIdentifier", runtime), ("build", build)):
            assert row.get(key) in (None, expected), "Wrong runtime identity: " + repr(row)
            if require_identity:
                assert row.get(key) == expected, "Runtime identity still unknown: " + repr(row)


    def wait_for_scan_identity(timeout_seconds=120):
        deadline = time.monotonic() + timeout_seconds
        observations = []
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "Recovery scan did not settle to exact 26.2/23C54 identity"
            current = images(f"recovery-wait-{len(observations):03d}.json", timeout=min(30, remaining))
            related = original_rows(current)
            for row in related:
                validate_original(row, require_identity=False)
            assert all(row in related for row in targets(current)), "Unexpected exact-build asset after scan"
            observations.append({"time": time.time(), "rows": related})
            (evidence / "recovery-wait.json").write_text(json.dumps(observations, indent=2) + "\n")
            if related and all(row.get("runtimeIdentifier") == runtime and row.get("build") == build
                               and row.get("state") in ("Ready", "Unusable") for row in related):
                return related
            assert all(row.get("state") in ("Copying", "Verifying", "Mounting", "Ready", "Unusable")
                       for row in related), "Unexpected scan state"
            time.sleep(min(5, max(0, deadline - time.monotonic())))


    def require_no_original(rows):
        assert not targets(rows), "Exact runtime was re-registered before import"
        assert not original_rows(rows), "Original asset still has a known or pending registration"


    def confirm_absence(timeout_seconds=45):
        # Scan completion can precede registration. Observe the entire settling window;
        # any exact-build OR original-path pending row fails, even without identity.
        deadline = time.monotonic() + timeout_seconds
        observations = []
        while True:
            current = images(f"removal-confirm-{len(observations):03d}.json", timeout=30)
            observations.append({"time": time.time(), "imageCount": len(current), "originalRows": original_rows(current)})
            (evidence / "removal-confirm.json").write_text(json.dumps(observations, indent=2) + "\n")
            require_no_original(current)
            assert not any(Path(path).exists() for path in payload_paths), "Original payload reappeared"
            if time.monotonic() >= deadline:
                return
            time.sleep(min(5, max(0, deadline - time.monotonic())))


    def delete_exact(rows, prefix, allow_known_purge_failure=False):
        # A rescan can change UUIDs; never expand deletion to another build or asset.
        for row in rows:
            validate_original(row)
        for row in rows:
            identifier = row["identifier"]
            remaining = images(prefix + "-before-" + identifier + ".json")
            if identifier not in remaining:
                continue  # Removing one shared MobileAsset may already retire its twin.
            live = remaining[identifier]
            validate_original(live)
            assert live in targets(remaining) and live.get("path") == row["path"]
            name = prefix + "-" + identifier
            result = operation(name, ["xcrun", "simctl", "runtime", "delete", identifier])
            if result.returncode:
                detail = (evidence / (name + ".log")).read_text()
                expected = "Removed the runtime, but did not reclaim its MobileAsset: " + live["path"].rstrip("/") + "/"
                known = (result.returncode == 30 and
                         "domain=com.apple.CoreSimulator.simdiskimaged.SimDiskImageError, code=30" in detail and
                         expected in detail and
                         "Run 'xcrun simctl runtime scan-and-mount' to re-register the runtime, then delete it again." in detail)
                after_failure = images(name + "-after-failure.json")
                if allow_known_purge_failure and known and identifier not in after_failure:
                    (evidence / "known-purge-recovery.json").write_text(json.dumps({
                        "identifier": identifier, "path": live["path"], "exit": 30,
                        "reason": "Explicit simctl recovery instruction; one bounded scan/delete retry"}) + "\n")
                    return False
                result.check_returncode()
        return True


    if not delete_exact(replacement, "delete", allow_known_purge_failure=True):
        # simctl exposes no target-specific scan. Only this one documented recovery
        # scan is allowed; every subsequent deletion is revalidated to original assets.
        operation("purge-recovery-scan", ["xcrun", "simctl", "runtime", "scan-and-mount"]).check_returncode()
        retry_rows = wait_for_scan_identity()
        assert delete_exact(retry_rows, "purge-retry"), "Purge retry did not complete"
    require_no_original(images("after-removal.json"))
    # A catalog-only AssetData directory is allowed; the exact exported payload must
    # be gone, and neither known nor pending original-path rows may survive the scan.
    asset_state = {path: Path(path).exists() for path in sorted(payload_paths)}
    (evidence / "after-removal-payloads.json").write_text(json.dumps(asset_state, indent=2) + "\n")
    assert not any(asset_state.values()), "Original disk-image payload remains available for re-registration"
    operation("confirm-removal-scan", ["xcrun", "simctl", "runtime", "scan-and-mount"]).check_returncode()
    confirm_absence()
    disk_image = bundles[0] / payload_name
    assert disk_image.is_file() and disk_image.stat().st_size > 0
    (evidence / "import-input.json").write_text(json.dumps({
        "mode": "direct-dmg", "path": str(disk_image.resolve()),
        "bundle": str(bundles[0].resolve()), "relativePayload": str(payload_name)}) + "\n")
    operation("import", ["sudo", "-n", "/usr/bin/env", "DEVELOPER_DIR=" + developer,
                         "/usr/bin/xcodebuild", "-importPlatform", str(disk_image.resolve())]).check_returncode()
    after_import = images("after-import.json")
    assert not original_rows(after_import), "Original asset reappeared during import"
    installed = targets(after_import)
    assert len(installed) == 1 and installed[0].get("state") == "Ready", installed
    target = installed[0]
    (evidence / "registration-candidate.json").write_text(json.dumps(target, indent=2) + "\n")
    require_standalone(target)
    uuid.UUID(target["identifier"])
    path = target.get("path", "")
    assert Path(path).exists() and Path(target["runtimeBundlePath"]).is_dir()
    assert target.get("mountPath") and Path(target["mountPath"]).is_dir()
    assert "arm64" in target.get("supportedArchitectures", [])
    snapshot = capture("after-import-simctl.json", "list", "-j")
    matches = [r for r in snapshot["runtimes"] if r["identifier"] == runtime]
    exact = [r for r in matches if r["buildversion"] == build]
    assert len(exact) == 1 and exact[0].get("isAvailable") is True
    actual = exact[0]
    assert actual["version"] == "26.2" and actual["bundlePath"] == target["runtimeBundlePath"]
    (evidence / "target.json").write_text(json.dumps(target, indent=2) + "\n")


if __name__ == "__main__":
    prepare()
