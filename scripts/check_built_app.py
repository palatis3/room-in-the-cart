#!/usr/bin/env python3
"""Verify configuration in the compiled app, where build settings can be lost."""
import argparse
import os
import plistlib
from pathlib import Path

from app_configuration import compiled_metadata, load_configuration, require_release_metadata


ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENT_SUFFIXES = {"Debug": ".debug", "Staging": ".staging", "Release": ""}
IPHONE_PLATFORMS = (["iPhoneOS"], ["iPhoneSimulator"])


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_plist(path):
    with path.open("rb") as file:
        value = plistlib.load(file)
    require(isinstance(value, dict), f"Expected a plist dictionary: {path}")
    return value


def nonempty_file(path):
    return path.is_file() and path.stat().st_size > 0


def nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def verify_iphone_bundle(bundle, executable_name):
    info = read_plist(bundle / "Info.plist")
    require(info.get("UIDeviceFamily") == [1], f"{bundle.name} must target iPhone only")
    require(info.get("MinimumOSVersion") == "17.0", f"{bundle.name} must support iOS 17.0")
    require(info.get("CFBundleSupportedPlatforms") in IPHONE_PLATFORMS,
            f"{bundle.name} must be built for iPhoneOS or iPhoneSimulator")
    require(info.get("CFBundleExecutable") == executable_name, f"Wrong {bundle.name} executable name")
    executable = bundle / executable_name
    require(nonempty_file(executable) and os.access(executable, os.X_OK),
            f"Missing or nonexecutable bundle executable: {executable_name}")
    return info


def verify_built_app(app, configuration, *, require_production_metadata=False):
    suffix = ENVIRONMENT_SUFFIXES[configuration]
    bundle_id = "dev.roominthecart.app" + suffix
    scheme = "roominthecart" + suffix.replace(".", "-")
    widget_key, share_key = "RITCWidgetAppGroup", "RITCShareInboxAppGroup"
    groups = {widget_key: f"group.{bundle_id}.widget", share_key: f"group.{bundle_id}.share-inbox"}

    info = verify_iphone_bundle(app, "RoomInTheCart")
    require(info.get("CFBundleIdentifier") == bundle_id, "Wrong environment bundle")
    require(info.get("RITCSurfaceURLScheme") == scheme, "Wrong app URL scheme")
    require(info.get("CFBundleURLTypes") == [{
        "CFBundleTypeRole": "Editor",
        "CFBundleURLName": bundle_id + ".surface",
        "CFBundleURLSchemes": [scheme],
    }], "Wrong app URL scheme registration")
    for key, expected in groups.items():
        require(info.get(key) == expected, f"Wrong app container: {key}")

    # Xcode intentionally embeds the hosted unit tests in the Debug app during xcodebuild test.
    debug_test_bundle = app / "PlugIns/RoomInTheCartTests.xctest"
    for test_bundle in app.rglob("*.xctest"):
        require(configuration == "Debug" and test_bundle == debug_test_bundle,
                f"Unexpected test bundle: {test_bundle.relative_to(app)}")

    if configuration in ("Release", "Staging"):
        fixture_names = {path.name for path in (ROOT / "ios/UITests/Fixtures").rglob("*") if path.is_file()}
        for path in app.rglob("*"):
            require(path.name not in fixture_names and path.suffix.lower() != ".storekit",
                    f"Test resource embedded in {configuration} app: {path.relative_to(app)}")

    icon = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName")
    require(icon == "AppIcon", "Missing app icon")
    require(nonempty_file(app / "Assets.car"), "Missing compiled asset catalog")
    privacy_file = app / "PrivacyInfo.xcprivacy"
    require(privacy_file.is_file(), "Missing privacy manifest")
    privacy = read_plist(privacy_file)
    expected_privacy = read_plist(ROOT / "ios/Resources/PrivacyInfo.xcprivacy")
    require(privacy == expected_privacy, "Compiled privacy manifest differs from the reviewed source")
    require(privacy.get("NSPrivacyTracking") is False, "Unexpected tracking declaration")
    permission_keys = ["NSFaceIDUsageDescription"]
    if (ROOT / "ios/Features/Capture/OnDeviceSpeechCapture.swift").is_file():
        permission_keys += ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"]
    if (ROOT / "ios/Features/Capture/CameraCapture.swift").is_file():
        permission_keys += ["NSCameraUsageDescription"]
    for key in permission_keys:
        require(nonempty_string(info.get(key)), f"Missing compiled permission purpose: {key}")
    for language in ("en", "es"):
        localized_info = read_plist(app / f"{language}.lproj/InfoPlist.strings")
        for key in permission_keys:
            require(nonempty_string(localized_info.get(key)), f"Missing {language} permission purpose: {key}")

    for key, expected in compiled_metadata(load_configuration(ROOT, configuration), configuration).items():
        require(info.get(key, "") == expected, f"Incorrect compiled configuration for {key}")
    if require_production_metadata:
        require_release_metadata(info)

    version_keys = ("CFBundleShortVersionString", "CFBundleVersion")
    for key in version_keys:
        require(nonempty_string(info.get(key)), f"Missing app version field: {key}")
    for folder, kind, group_key, forbidden_group in (
        ("Widget", "com.apple.widgetkit-extension", widget_key, share_key),
        ("Share", "com.apple.share-services", share_key, widget_key),
    ):
        name = "RoomInTheCart" + folder
        extension = app / "PlugIns" / (name + ".appex")
        require(extension.is_dir(), f"Missing embedded {folder} extension")
        extension_info = verify_iphone_bundle(extension, name)
        require(extension_info.get("CFBundleSupportedPlatforms") == info["CFBundleSupportedPlatforms"],
                f"{folder} extension and app platform mismatch")
        require(nonempty_string(extension_info.get("CFBundleDisplayName")), f"Missing {folder} extension display name")
        require(extension_info.get("CFBundleIdentifier") == bundle_id + "." + folder.lower(),
                f"Wrong {folder} extension environment")
        for key in version_keys:
            require(extension_info.get(key) == info[key], f"{folder} extension version mismatch: {key}")
        extension_metadata = extension_info.get("NSExtension", {})
        require(extension_metadata.get("NSExtensionPointIdentifier") == kind, f"Wrong {folder} extension point")
        require(extension_info.get(group_key) == groups[group_key], f"Wrong {folder} extension container: {group_key}")
        require(forbidden_group not in extension_info, f"{folder} extension received another surface's container")
        if folder == "Widget":
            require(extension_info.get("RITCSurfaceURLScheme") == scheme, "Wrong Widget extension URL scheme")
        else:
            activation_rule = extension_metadata.get("NSExtensionAttributes", {}).get("NSExtensionActivationRule")
            require(isinstance(activation_rule, dict) and set(activation_rule) == {"NSExtensionActivationSupportsText"}
                    and activation_rule["NSExtensionActivationSupportsText"] is True,
                    "Share extension must activate for text only")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--configuration", choices=ENVIRONMENT_SUFFIXES, required=True)
    parser.add_argument("--require-release-metadata", action="store_true",
                        help="require owner-supplied production support/privacy/terms URLs and the Apple product ID; this does not verify release readiness")
    args = parser.parse_args()
    if args.require_release_metadata and args.configuration != "Release":
        parser.error("--require-release-metadata requires --configuration Release")
    try:
        verify_built_app(args.app, args.configuration, require_production_metadata=args.require_release_metadata)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Built app verification failed: {error}\n")
    print(f"Compiled {args.configuration} iPhone app verified: executable, assets, privacy, environment, and embedded extensions.")


if __name__ == "__main__":
    main()
