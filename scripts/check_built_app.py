#!/usr/bin/env python3
"""Verify configuration in the compiled app, where build settings can be lost."""
import argparse
import os
import plistlib
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from app_configuration import (compiled_metadata, load_configuration, privacy_manifest_profile, require_private_release_metadata,
                               require_release_metadata)


ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENT_SUFFIXES = {"Debug": ".debug", "Staging": ".staging", "Release": ""}
IPHONE_PLATFORMS = (["iPhoneOS"], ["iPhoneSimulator"])


SHARE_ACTIVATION_RULE = (
    'extensionItems.@count == 1 AND SUBQUERY(extensionItems, $item, ($item.attachments.@count == 0 AND '
    '$item.attributedContentText != nil) OR ($item.attachments.@count == 1 AND '
    'SUBQUERY($item.attachments, $p, ANY $p.registeredTypeIdentifiers UTI-CONFORMS-TO "com.adobe.pdf" '
    'OR ANY $p.registeredTypeIdentifiers UTI-CONFORMS-TO "public.image" OR ANY '
    '$p.registeredTypeIdentifiers UTI-CONFORMS-TO "public.plain-text" OR (ANY '
    '$p.registeredTypeIdentifiers UTI-CONFORMS-TO "public.url" AND NOT ANY $p.registeredTypeIdentifiers '
    'UTI-CONFORMS-TO "public.file-url")).@count == 1) OR ($item.attachments.@count == 2 AND '
    'SUBQUERY($item.attachments, $p, ANY $p.registeredTypeIdentifiers UTI-CONFORMS-TO "public.url" AND '
    'NOT ANY $p.registeredTypeIdentifiers UTI-CONFORMS-TO "public.file-url").@count == 1 AND '
    'SUBQUERY($item.attachments, $p, ANY $p.registeredTypeIdentifiers UTI-CONFORMS-TO '
    '"public.plain-text").@count >= 1)).@count == 1'
)

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


def verify_privacy_manifest(bundle, source_folder):
    path = bundle / "PrivacyInfo.xcprivacy"
    require(path.is_file(), f"Missing privacy manifest in {bundle.name}")
    privacy = read_plist(path)
    require(privacy == read_plist(source_folder / path.name),
            f"Compiled privacy manifest differs from the reviewed source in {bundle.name}")
    require(privacy.get("NSPrivacyTracking") is False, f"Unexpected tracking declaration in {bundle.name}")


def verify_built_app(app, configuration, *, require_production_metadata=False, require_private_metadata=False):
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
    expected_extensions = {app / "PlugIns" / f"RoomInTheCart{name}.appex" for name in ("Widget", "Share")}
    for extension in app.rglob("*.appex"):
        require(extension in expected_extensions, f"Unexpected embedded extension: {extension.relative_to(app)}")

    if configuration in ("Release", "Staging"):
        fixture_names = {path.name for path in (ROOT / "ios/UITests/Fixtures").rglob("*") if path.is_file()}
        for path in app.rglob("*"):
            require(path.name not in fixture_names and path.suffix.lower() != ".storekit",
                    f"Test resource embedded in {configuration} app: {path.relative_to(app)}")

    icon = info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName")
    require(icon == "AppIcon", "Missing app icon")
    require(nonempty_file(app / "Assets.car"), "Missing compiled asset catalog")
    verify_privacy_manifest(app, ROOT / "ios/Resources/Privacy" / privacy_manifest_profile(info))
    permission_keys = ["NSFaceIDUsageDescription", "NSRemindersFullAccessUsageDescription"]
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
    if require_private_metadata:
        require_private_release_metadata(info)
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
        verify_privacy_manifest(extension, ROOT / "ios/Extensions" / folder)
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
            require(activation_rule == SHARE_ACTIVATION_RULE,
                    "Share extension must accept supported receipt files, selected text and one web URL")


def dwarf_uuids(path):
    require(nonempty_file(path), f"Missing or empty file: {path}")
    result = subprocess.run(["xcrun", "dwarfdump", "--uuid", str(path)], capture_output=True, text=True)
    matches = re.findall(r"^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\) ", result.stdout, re.MULTILINE)
    require(result.returncode == 0 and matches, f"Could not read Mach-O UUIDs from {path}")
    return {(identifier.lower(), architecture) for identifier, architecture in matches}


def verify_archive_symbols(archive, app):
    require(read_plist(app / "Info.plist").get("CFBundleSupportedPlatforms") == ["iPhoneOS"],
            "Expected a device archive")
    for product in [app, *sorted((app / "PlugIns").glob("*.appex"))]:
        executable = read_plist(product / "Info.plist")["CFBundleExecutable"]
        symbols = archive / "dSYMs" / (product.name + ".dSYM") / "Contents/Resources/DWARF" / executable
        binary_ids = dwarf_uuids(product / executable)
        require(any(architecture == "arm64" for _, architecture in binary_ids),
                f"Missing arm64 in {product.name}")
        require(dwarf_uuids(symbols) == binary_ids, f"Crash symbols do not match {product.name}")


def verify_distribution_entitlements(values, bundle_id, team, groups, *, regional_age_check=None):
    require(values.get("application-identifier") == f"{team}.{bundle_id}", f"Wrong signed app identifier: {bundle_id}")
    require(values.get("com.apple.developer.team-identifier") == team, f"Wrong signing team: {bundle_id}")
    actual_groups = values.get("com.apple.security.application-groups")
    require(isinstance(actual_groups, list) and all(isinstance(group, str) for group in actual_groups)
            and sorted(actual_groups) == sorted(groups),
            f"Wrong signed App Groups: {bundle_id}")
    require(values.get("com.apple.developer.default-data-protection") == "NSFileProtectionComplete",
            f"Missing complete data protection: {bundle_id}")
    require(values.get("get-task-allow", False) is False, f"Debugging enabled: {bundle_id}")
    if regional_age_check is not None:
        require(values.get("com.apple.developer.declared-age-range", False) is regional_age_check,
                f"Wrong Declared Age Range entitlement: {bundle_id}")


def verify_distribution_signing(app):
    app = app.resolve()
    options = read_plist(ROOT / "config/AppStoreExport.plist")
    team = options["teamID"]
    requirement = (f'=anchor apple generic and certificate leaf[subject.OU] = "{team}" '
                   'and certificate leaf[field.1.2.840.113635.100.6.1.4] exists')
    def run(*command, cwd=None):
        result = subprocess.run(command, cwd=cwd, capture_output=True)
        require(result.returncode == 0, f"Distribution check failed ({command[0]}): {result.stderr.decode().strip()}")
        return result.stdout

    run("codesign", "--verify", "--strict", "--deep", str(app))
    for bundle in [app, *sorted((app / "PlugIns").glob("*.appex"))]:
        info = read_plist(bundle / "Info.plist")
        require(info["CFBundleSupportedPlatforms"] == ["iPhoneOS"], "Distribution signing requires an iPhone device build")
        bundle_id = info["CFBundleIdentifier"]
        groups = [info[key] for key in ("RITCWidgetAppGroup", "RITCShareInboxAppGroup") if key in info]
        run("codesign", "--verify", "--strict", "-R", requirement, str(bundle))
        signing = plistlib.loads(run("codesign", "-d", "--xml", "--entitlements", "-", str(bundle)))
        profile = plistlib.loads(run("security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")))
        require(profile.get("Name") == options["provisioningProfiles"].get(bundle_id)
                and profile.get("TeamIdentifier") == [team], f"Unexpected distribution profile: {bundle_id}")
        require(profile["ExpirationDate"].replace(tzinfo=timezone.utc) > datetime.now(timezone.utc),
                f"Expired distribution profile: {bundle_id}")
        require(profile["Entitlements"].get("beta-reports-active") is True and not profile.get("ProvisionsAllDevices")
                and not profile.get("ProvisionedDevices"), f"Expected an App Store distribution profile: {bundle_id}")
        with tempfile.TemporaryDirectory() as scratch:
            run("codesign", "-d", "--extract-certificates", str(bundle), cwd=scratch)
            require((Path(scratch) / "codesign0").read_bytes() in profile["DeveloperCertificates"],
                    f"Distribution profile does not authorize the signing certificate: {bundle_id}")
        enabled = bundle == app and info.get("RITCRegionalAgeCheckEnabled") == "YES"
        verify_distribution_entitlements(signing, bundle_id, team, groups, regional_age_check=enabled)
        verify_distribution_entitlements(profile["Entitlements"], bundle_id, team, groups,
                                        regional_age_check=True if enabled else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("product", type=Path, help="compiled .app or device .xcarchive")
    parser.add_argument("--configuration", choices=ENVIRONMENT_SUFFIXES, required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--require-private-release-metadata", action="store_true",
                      help="require public native Privacy and Support links with household access and email sign-in disabled")
    mode.add_argument("--require-release-metadata", action="store_true",
                      help="require production household service and identity settings, public support and policy URLs, and the Apple product ID")
    parser.add_argument("--require-distribution-signing", action="store_true",
                        help="verify the App Store signatures, embedded provisioning profiles, and signed entitlements")
    args = parser.parse_args()
    if args.require_private_release_metadata and args.configuration != "Release":
        parser.error("--require-private-release-metadata requires --configuration Release")
    if args.require_release_metadata and args.configuration != "Release":
        parser.error("--require-release-metadata requires --configuration Release")
    if args.require_distribution_signing and args.configuration != "Release":
        parser.error("--require-distribution-signing requires --configuration Release")
    try:
        archive = args.product.suffix == ".xcarchive"
        app = args.product / "Products/Applications/RoomInTheCart.app" if archive else args.product
        verify_built_app(app, args.configuration, require_production_metadata=args.require_release_metadata,
                         require_private_metadata=args.require_private_release_metadata)
        if archive:
            verify_archive_symbols(args.product, app)
        if args.require_distribution_signing:
            verify_distribution_signing(app)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Built app verification failed: {error}\n")
    if args.require_private_release_metadata:
        print("Verified private Release configuration for Privacy, Support, email sign-in, and household access.")
    if archive:
        print("Archived iPhone app and extension binaries matched their crash symbols.")
    if args.require_distribution_signing:
        print("Verified App Store signing identities, profiles, and entitlements for the app and both extensions.")
    print(f"Compiled {args.configuration} iPhone app verified: executable, assets, privacy, environment, and embedded extensions.")


if __name__ == "__main__":
    main()
