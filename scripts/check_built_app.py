#!/usr/bin/env python3
"""Verify configuration in the compiled app, where build settings can be lost."""
import argparse
import plistlib
from pathlib import Path
from app_configuration import compiled_metadata, load_configuration, require_release_metadata

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--configuration", choices=("Debug", "Staging", "Release"), required=True)
parser.add_argument("--require-release-metadata", action="store_true", help="require owner-supplied production support/privacy/terms URLs and the Apple product ID; this does not verify release readiness")
args = parser.parse_args()
if args.require_release_metadata and args.configuration != "Release":
    parser.error("--require-release-metadata requires --configuration Release")
root = Path(__file__).resolve().parents[1]
info = plistlib.loads((args.app / "Info.plist").read_bytes())
suffix = {"Debug": ".debug", "Staging": ".staging", "Release": ""}[args.configuration]
assert info["CFBundleIdentifier"] == "dev.roominthecart.app" + suffix, "Wrong environment bundle"
assert info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") == "AppIcon", "Missing app icon"
assert (args.app / "PrivacyInfo.xcprivacy").is_file(), "Missing privacy manifest"
privacy = plistlib.loads((args.app / "PrivacyInfo.xcprivacy").read_bytes())
expected_privacy = plistlib.loads((root / "ios/Resources/PrivacyInfo.xcprivacy").read_bytes())
assert privacy == expected_privacy, "Compiled privacy manifest differs from the reviewed source"
assert privacy.get("NSPrivacyTracking") is False, "Unexpected tracking declaration"
assert info.get("NSFaceIDUsageDescription"), "Missing workspace unlock purpose"
permission_keys = ["NSFaceIDUsageDescription"]
if (root / "ios/Features/Capture/OnDeviceSpeechCapture.swift").is_file():
    permission_keys += ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"]
if (root / "ios/Features/Capture/CameraCapture.swift").exists():
    permission_keys += ["NSCameraUsageDescription"]
for key in permission_keys:
    assert isinstance(info.get(key), str) and info[key].strip(), f"Missing compiled permission purpose: {key}"
for language in ("en", "es"):
    localized_info = plistlib.loads((args.app / f"{language}.lproj/InfoPlist.strings").read_bytes())
    for key in permission_keys:
        assert localized_info.get(key, "").strip(), f"Missing {language} permission purpose: {key}"
configuration = load_configuration(root, args.configuration)
for key, expected in compiled_metadata(configuration, args.configuration).items():
    actual = info.get(key, "")
    assert actual == expected, f"Incorrect compiled configuration for {key}"
    assert "$(" not in actual, f"Unresolved build setting for {key}"
if args.require_release_metadata:
    require_release_metadata(info)
for folder, name, kind, group_key, forbidden_group in (
    ("Widget", "RoomInTheCartWidget", "com.apple.widgetkit-extension", "RITCWidgetAppGroup", "RITCShareInboxAppGroup"),
    ("Share", "RoomInTheCartShare", "com.apple.share-services", "RITCShareInboxAppGroup", "RITCWidgetAppGroup"),
):
    if not (root / "ios/Extensions" / folder).is_dir():
        continue
    extension = args.app / "PlugIns" / (name + ".appex")
    assert extension.is_dir(), f"Missing embedded {folder} extension"
    extension_info = plistlib.loads((extension / "Info.plist").read_bytes())
    assert extension_info.get("CFBundleDisplayName"), "Extension display name is required for installation"
    assert extension_info["CFBundleIdentifier"] == info["CFBundleIdentifier"] + "." + folder.lower(), "Extension environment mismatch"
    assert extension_info["NSExtension"]["NSExtensionPointIdentifier"] == kind, "Wrong extension point"
    assert extension_info.get(group_key) == info.get(group_key) and info[group_key].startswith("group."), "Shared container mismatch"
    assert not extension_info.get(forbidden_group), "Extension received another surface's container configuration"
    assert "$(" not in extension_info[group_key], "Unresolved extension container setting"
print(f"Compiled {args.configuration} app metadata verified: icon, privacy resource, environment isolation, service and help/billing configuration.")
