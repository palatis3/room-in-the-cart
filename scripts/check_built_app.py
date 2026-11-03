#!/usr/bin/env python3
"""Verify configuration in the compiled app, where build settings can be lost."""
import argparse
import json
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--configuration", choices=("Debug", "Staging", "Release"), required=True)
args = parser.parse_args()
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
configuration = json.loads((root / "config/staging.json").read_text()) if args.configuration != "Release" else {}
assert info.get("RITCEmailOTPEnabled") == ("YES" if configuration.get("emailOTPEnabled") is True else "NO"), "Incorrect email-provider availability"
for key, source in (("HouseholdServiceURL", "serviceURL"), ("SupabaseProjectURL", "supabaseURL"), ("SupabasePublishableKey", "publishableKey")):
    actual = info.get(key, "")
    assert actual == configuration.get(source, ""), f"Incorrect compiled configuration for {key}"
    assert "$(" not in actual, f"Unresolved build setting for {key}"
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
print(f"Compiled {args.configuration} app metadata verified: icon, privacy resource, environment isolation and service configuration.")
