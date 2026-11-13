#!/usr/bin/env python3
"""Generate the dependency-free, committed Xcode project from repository sources."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
from app_configuration import build_settings, load_configuration

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"
PROJECT = IOS / "RoomInTheCart.xcodeproj"
OBJECTS = {}
STAGING_SUITES = {"unit": "StagingServiceTests", "ui": "StagingHelpUITests"}


def ident(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()


def obj(key, isa, **fields):
    identifier = ident(key)
    OBJECTS[identifier] = {"isa": isa, **fields}
    return identifier


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


def serialize(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + quote(k) + " = " + serialize(v, level + 1) + ";\n" for k, v in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(serialize(item, level) for item in value) + ("," if value else "") + ")"
    return quote(value)


def file_ref(path, kind):
    return obj("file:" + path, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="<group>")


def build_file(path, kind):
    return obj("build:" + path, "PBXBuildFile", fileRef=file_ref(path, kind))


def config_list(key, base, is_project=False):
    configs = []
    for name in ("Debug", "Staging", "Release"):
        settings = dict(base)
        environment_suffix = {"Debug": ".debug", "Staging": ".staging", "Release": ""}[name]
        if key in ("app", "widget", "share"):
            app_bundle = "dev.roominthecart.app" + environment_suffix
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = app_bundle + ("." + key if key != "app" else "")
            settings["RITC_WIDGET_APP_GROUP"] = "group." + app_bundle + ".widget"
            settings["RITC_SHARE_INBOX_APP_GROUP"] = "group." + app_bundle + ".share-inbox"
            settings["RITC_SURFACE_URL_SCHEME"] = "roominthecart" + ("-" + name.lower() if name != "Release" else "")
        if is_project:
            settings.update(ONLY_ACTIVE_ARCH="YES" if name != "Release" else "NO", SWIFT_OPTIMIZATION_LEVEL="-Onone" if name != "Release" else "-O", DEBUG_INFORMATION_FORMAT="dwarf" if name != "Release" else "dwarf-with-dsym", ENABLE_TESTABILITY="YES" if name != "Release" else "NO", SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) " + {"Debug": "DEBUG", "Staging": "STAGING", "Release": "RELEASE"}[name])
        elif name == "Staging" and key in STAGING_SUITES:
            # The staging scheme runs its live service and Safari smoke suites.
            # Debug-only package fixtures require modules compiled for testing.
            settings["EXCLUDED_SOURCE_FILE_NAMES"] = "*.swift"
            settings["INCLUDED_SOURCE_FILE_NAMES"] = STAGING_SUITES[key] + ".swift"
        elif key == "app":
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.roominthecart.app" + {"Debug": ".debug", "Staging": ".staging", "Release": ""}[name]
            settings["INFOPLIST_KEY_CFBundleDisplayName"] = "Room in the Cart"
            settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
            settings.update(build_settings(load_configuration(ROOT, name), name))
        configs.append(obj(f"config:{key}:{name}", "XCBuildConfiguration", buildSettings=settings, name=name))
    return obj("configs:" + key, "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


def target(key, name, source_paths, product_type, bundle, dependencies=(), packages=(), extension_folder=None):
    source_phase = obj(key + ":sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=[build_file(str(p.relative_to(IOS)), "sourcecode.swift") for p in source_paths], runOnlyForDeploymentPostprocessing="0")
    framework_files = [obj(key + ":package:" + p, "PBXBuildFile", productRef=ident("product:" + p)) for p in packages]
    framework_phase = obj(key + ":frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=framework_files, runOnlyForDeploymentPostprocessing="0")
    resources = []
    if key == "app":
        for p in sorted((IOS / "Resources").glob("*")) + sorted((IOS / "Features").rglob("*.xcstrings")):
            kind = {".xcassets": "folder.assetcatalog", ".xcstrings": "text.json.xcstrings", ".xcprivacy": "text.xml"}.get(p.suffix)
            if kind:
                resources.append(build_file(str(p.relative_to(IOS)), kind))
    elif extension_folder:
        catalog = IOS / "Features/DeviceSurfaces/DeviceSurfaces.xcstrings"
        if catalog.exists():
            resources.append(build_file(str(catalog.relative_to(IOS)), "text.json.xcstrings"))
        for p in sorted(extension_folder.glob("*.xcprivacy")):
            resources.append(build_file(str(p.relative_to(IOS)), "text.xml"))
    elif key == "unit":
        storekit = IOS / "Features/Membership/HouseholdLocalTesting.storekit"
        if storekit.exists():
            resources.append(build_file(str(storekit.relative_to(IOS)), "text.json"))
    elif key == "ui":
        snapshot = IOS / "UITests/Fixtures/SharedFallbackShop.json"
        if snapshot.exists():
            resources.append(build_file(str(snapshot.relative_to(IOS)), "text.json"))
        fixture = IOS / "UITests/Fixtures/ReleaseLedger500.txt"
        if fixture.exists():
            resources.append(build_file(str(fixture.relative_to(IOS)), "text"))
    resources_phase = obj(key + ":resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=resources, runOnlyForDeploymentPostprocessing="0")
    product = obj(key + ":output", "PBXFileReference", explicitFileType="wrapper.application" if key == "app" else "wrapper.app-extension" if extension_folder else "wrapper.cfbundle", includeInIndex="0", path=name + (".app" if key == "app" else ".appex" if extension_folder else ".xctest"), sourceTree="BUILT_PRODUCTS_DIR")
    settings = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER=bundle, GENERATE_INFOPLIST_FILE="YES", CODE_SIGN_STYLE="Automatic", SWIFT_EMIT_LOC_STRINGS="YES")
    if key == "app":
        settings.update(INFOPLIST_FILE="App/Info.plist", INFOPLIST_KEY_UIApplicationSceneManifest_Generation="YES", INFOPLIST_KEY_UILaunchScreen_Generation="YES", INFOPLIST_KEY_UISupportedInterfaceOrientations="UIInterfaceOrientationPortrait", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks"])
        if dependencies:
            settings["CODE_SIGN_ENTITLEMENTS"] = "Configuration/App.entitlements"
    elif extension_folder:
        settings.update(INFOPLIST_FILE=str((extension_folder / "Info.plist").relative_to(IOS)), APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES", CODE_SIGN_ENTITLEMENTS=f"Configuration/{key.title()}.entitlements", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"])
    elif key == "unit":
        settings.update(TEST_HOST="$(BUILT_PRODUCTS_DIR)/RoomInTheCart.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/RoomInTheCart", BUNDLE_LOADER="$(TEST_HOST)")
    else:
        settings["TEST_TARGET_NAME"] = "RoomInTheCart"
    phases = [source_phase, framework_phase, resources_phase]
    if key == "app" and dependencies:
        phases.append(ident("app:embedExtensions"))
    return obj("target:" + key, "PBXNativeTarget", buildConfigurationList=config_list(key, settings), buildPhases=phases, buildRules=[], dependencies=list(dependencies), name=name, packageProductDependencies=[ident("product:" + p) for p in packages], productName=name, productReference=product, productType=product_type)


def scheme(name, config, target_ids, local_storekit=False, performance=False):
    def ref(key, product):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:" + key)}" BuildableName="{product}" BlueprintName="{product.rsplit(".", 1)[0]}" ReferencedContainer="container:RoomInTheCart.xcodeproj"/>'
    app = ref("app", "RoomInTheCart.app")
    tests = "".join('<TestableReference skipped="NO">' + ref(key, product) + ('<SkippedTests><Test Identifier="StoreKitScenarioTests"/></SkippedTests>' if key == "unit" else '') + '</TestableReference>' for key, product in target_ids)
    test_configuration = '<TestPlans><TestPlanReference reference="container:Tests/LocalStoreKit.xctestplan" default="YES"/></TestPlans>' if local_storekit else '<Testables>' + tests + '</Testables>'
    test_build = "Staging" if config == "Staging" else "Debug"
    distribution_build = "Staging" if config == "Staging" else "Release"
    test_attributes = f'buildConfiguration="{test_build}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"'
    if config == "Staging":
        test_configuration = '<Testables>' + "".join(
            '<TestableReference skipped="NO">' + ref(key, product) +
            f'<SelectedTests><Test Identifier="{STAGING_SUITES[key]}"/></SelectedTests></TestableReference>'
            for key, product in target_ids
        ) + '</Testables>'
    if performance:
        test_configuration = (
            '<Testables><TestableReference skipped="NO">' + ref("ui", "RoomInTheCartUITests.xctest") +
            '<SelectedTests><Test Identifier="ReleasePerformanceUITests"/></SelectedTests>'
            '</TestableReference></Testables>'
        )
        test_attributes = (
            'buildConfiguration="Release" selectedDebuggerIdentifier="" '
            'selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="NO" '
            'codeCoverageEnabled="NO" enableAddressSanitizer="NO" enableThreadSanitizer="NO" '
            'enableUBSanitizer="NO" disableMainThreadChecker="YES" disablePerformanceAntipatternChecker="YES"'
        )
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction {test_attributes}>{test_configuration}</TestAction>
  <LaunchAction buildConfiguration="{config}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="{distribution_build}" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="{config}"/>
  <ArchiveAction buildConfiguration="{distribution_build}" revealArchiveInOrganizer="YES"/>
</Scheme>
'''


def outputs():
    OBJECTS.clear()
    package_names = tuple(sorted(p.parent.name for p in (IOS / "Packages").glob("*/Package.swift")))
    packages = [obj("package:" + name, "XCLocalSwiftPackageReference", relativePath="Packages/" + name) for name in package_names]
    for name in package_names:
        obj("product:" + name, "XCSwiftPackageProductDependency", package=ident("package:" + name), productName=name)
    app_sources = sorted((IOS / "App").rglob("*.swift")) + sorted((IOS / "Features").rglob("*.swift")) + sorted((IOS / "UITestSupport").rglob("*.swift"))
    targets, extension_dependencies, extension_embeds = [], [], []
    extension_keys = []
    for key, folder, name in (("widget", "Widget", "RoomInTheCartWidget"), ("share", "Share", "RoomInTheCartShare")):
        directory = IOS / "Extensions" / folder
        sources = sorted(directory.rglob("*.swift"))
        if not sources:
            continue
        if "DeviceSurfaces" not in package_names or not (directory / "Info.plist").exists():
            raise ValueError(f"{name} needs DeviceSurfaces and its explicit Info.plist")
        targets.append(target(key, name, sources, "com.apple.product-type.app-extension", "dev.roominthecart.app." + key, packages=("DeviceSurfaces",), extension_folder=directory))
        proxy = obj(key + ":embedProxy", "PBXContainerItemProxy", containerPortal=ident("project"), proxyType="1", remoteGlobalIDString=ident("target:" + key), remoteInfo=name)
        extension_dependencies.append(obj(key + ":embedDependency", "PBXTargetDependency", target=ident("target:" + key), targetProxy=proxy))
        extension_embeds.append(obj(key + ":embedFile", "PBXBuildFile", fileRef=ident(key + ":output"), settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]}))
        extension_keys.append(key)
    if extension_embeds:
        obj("app:embedExtensions", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="", dstSubfolderSpec="13", files=extension_embeds, name="Embed App Extensions", runOnlyForDeploymentPostprocessing="0")
    targets.insert(0, target("app", "RoomInTheCart", app_sources, "com.apple.product-type.application", "dev.roominthecart.app", dependencies=extension_dependencies, packages=package_names))
    test_ids = []
    for key, folder, name, kind in (("unit", "Tests", "RoomInTheCartTests", "unit-test"), ("ui", "UITests", "RoomInTheCartUITests", "ui-testing")):
        paths = sorted((IOS / folder).rglob("*.swift"))
        if not paths:
            continue
        proxy = obj(key + ":proxy", "PBXContainerItemProxy", containerPortal=ident("project"), proxyType="1", remoteGlobalIDString=ident("target:app"), remoteInfo="RoomInTheCart")
        dep = obj(key + ":dependency", "PBXTargetDependency", target=ident("target:app"), targetProxy=proxy)
        targets.append(target(key, name, paths, "com.apple.product-type.bundle." + kind, "dev.roominthecart." + name, dependencies=[dep], packages=package_names if key == "unit" else ()))
        test_ids.append((key, name + ".xctest"))
    product_group = obj("products", "PBXGroup", children=[ident(key + ":output") for key in ("app", "unit", "ui", *extension_keys) if ident(key + ":output") in OBJECTS], name="Products", sourceTree="<group>")
    refs = sorted(identifier for identifier, value in OBJECTS.items() if value["isa"] == "PBXFileReference" and value.get("sourceTree") == "<group>")
    group = obj("main", "PBXGroup", children=refs + [product_group], sourceTree="<group>")
    settings = dict(ALWAYS_SEARCH_USER_PATHS="NO", CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", IPHONEOS_DEPLOYMENT_TARGET="17.0", SDKROOT="iphoneos", SUPPORTED_PLATFORMS="iphoneos iphonesimulator", SUPPORTS_MACCATALYST="NO", SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD="NO", SWIFT_VERSION="5.0", TARGETED_DEVICE_FAMILY="1", MARKETING_VERSION="0.1.0", CURRENT_PROJECT_VERSION="1")
    obj("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600"}, buildConfigurationList=config_list("project", settings, True), compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings="0", knownRegions=["en", "es", "Base"], mainGroup=group, packageReferences=packages, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=targets)
    project = {"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": dict(sorted(OBJECTS.items())), "rootObject": ident("project")}
    result = {PROJECT / "project.pbxproj": "// !$*UTF8*$!\n" + serialize(project) + "\n"}
    if extension_keys:
        for name, groups in (("App", ["$(RITC_WIDGET_APP_GROUP)", "$(RITC_SHARE_INBOX_APP_GROUP)"]), ("Widget", ["$(RITC_WIDGET_APP_GROUP)"]), ("Share", ["$(RITC_SHARE_INBOX_APP_GROUP)"])):
            result[IOS / "Configuration" / (name + ".entitlements")] = plistlib.dumps({"com.apple.security.application-groups": groups, "com.apple.developer.default-data-protection": "NSFileProtectionComplete"}).decode()
    for name, config in (("RoomInTheCart", "Debug"), ("RoomInTheCart-Staging", "Staging"), ("RoomInTheCart-Release", "Release")):
        result[PROJECT / "xcshareddata" / "xcschemes" / (name + ".xcscheme")] = scheme(name, config, test_ids)
    if (IOS / "Tests/LocalStoreKit.xctestplan").exists():
        result[PROJECT / "xcshareddata/xcschemes/RoomInTheCart-LocalStoreKit.xcscheme"] = scheme("RoomInTheCart-LocalStoreKit", "Debug", test_ids, local_storekit=True)
    if (IOS / "UITests/ReleasePerformanceUITests.swift").exists():
        result[PROJECT / "xcshareddata/xcschemes/RoomInTheCart-Performance.xcscheme"] = scheme("RoomInTheCart-Performance", "Release", test_ids, performance=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if committed project differs")
    args = parser.parse_args()
    stale = []
    for path, content in outputs().items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    if stale:
        parser.exit(1, "Regenerate Xcode project: python3 scripts/generate_xcode_project.py\n" + "\n".join(stale) + "\n")


if __name__ == "__main__":
    main()
