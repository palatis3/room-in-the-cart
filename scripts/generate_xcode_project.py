#!/usr/bin/env python3
"""Generate the dependency-free, committed Xcode project from repository sources."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"
PROJECT = IOS / "RoomInTheCart.xcodeproj"
OBJECTS = {}


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
        if is_project:
            settings.update(ONLY_ACTIVE_ARCH="YES" if name != "Release" else "NO", SWIFT_OPTIMIZATION_LEVEL="-Onone" if name != "Release" else "-O", DEBUG_INFORMATION_FORMAT="dwarf" if name != "Release" else "dwarf-with-dsym", ENABLE_TESTABILITY="YES" if name != "Release" else "NO", SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) " + {"Debug": "DEBUG", "Staging": "STAGING", "Release": "RELEASE"}[name])
        elif key == "app":
            settings["PRODUCT_BUNDLE_IDENTIFIER"] = "dev.roominthecart.app" + {"Debug": ".debug", "Staging": ".staging", "Release": ""}[name]
            settings["INFOPLIST_KEY_CFBundleDisplayName"] = "Room in the Cart"
            if name in ("Debug", "Staging"):
                config_path = ROOT / "config/staging.json"
                config = json.loads(config_path.read_text()) if config_path.exists() else {}
                for info_key, config_key in (("SupabaseProjectURL", "supabaseURL"), ("SupabasePublishableKey", "publishableKey"), ("HouseholdServiceURL", "serviceURL")):
                    if config.get(config_key):
                        settings["INFOPLIST_KEY_" + info_key] = config[config_key]
        configs.append(obj(f"config:{key}:{name}", "XCBuildConfiguration", buildSettings=settings, name=name))
    return obj("configs:" + key, "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


def target(key, name, source_paths, product_type, bundle, dependencies=(), packages=()):
    source_phase = obj(key + ":sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=[build_file(str(p.relative_to(IOS)), "sourcecode.swift") for p in source_paths], runOnlyForDeploymentPostprocessing="0")
    framework_files = [obj(key + ":package:" + p, "PBXBuildFile", productRef=ident("product:" + p)) for p in packages]
    framework_phase = obj(key + ":frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=framework_files, runOnlyForDeploymentPostprocessing="0")
    resources = []
    if key == "app":
        for p in sorted((IOS / "Resources").glob("*")) + sorted((IOS / "Features").rglob("*.xcstrings")):
            kind = {".xcassets": "folder.assetcatalog", ".xcstrings": "text.json.xcstrings", ".xcprivacy": "text.xml"}.get(p.suffix)
            if kind:
                resources.append(build_file(str(p.relative_to(IOS)), kind))
    resources_phase = obj(key + ":resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=resources, runOnlyForDeploymentPostprocessing="0")
    product = obj(key + ":output", "PBXFileReference", explicitFileType="wrapper.application" if key == "app" else "wrapper.cfbundle", includeInIndex="0", path=name + (".app" if key == "app" else ".xctest"), sourceTree="BUILT_PRODUCTS_DIR")
    settings = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER=bundle, GENERATE_INFOPLIST_FILE="YES", CODE_SIGN_STYLE="Automatic", SWIFT_EMIT_LOC_STRINGS="YES")
    if key == "app":
        settings.update(INFOPLIST_FILE="App/Info.plist", INFOPLIST_KEY_UIApplicationSceneManifest_Generation="YES", INFOPLIST_KEY_UILaunchScreen_Generation="YES", INFOPLIST_KEY_UISupportedInterfaceOrientations="UIInterfaceOrientationPortrait", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks"])
    elif key == "unit":
        settings.update(TEST_HOST="$(BUILT_PRODUCTS_DIR)/RoomInTheCart.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/RoomInTheCart", BUNDLE_LOADER="$(TEST_HOST)")
    else:
        settings["TEST_TARGET_NAME"] = "RoomInTheCart"
    return obj("target:" + key, "PBXNativeTarget", buildConfigurationList=config_list(key, settings), buildPhases=[source_phase, framework_phase, resources_phase], buildRules=[], dependencies=list(dependencies), name=name, packageProductDependencies=[ident("product:" + p) for p in packages], productName=name, productReference=product, productType=product_type)


def scheme(name, config, target_ids):
    def ref(key, product):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:" + key)}" BuildableName="{product}" BlueprintName="{product.rsplit(".", 1)[0]}" ReferencedContainer="container:RoomInTheCart.xcodeproj"/>'
    app = ref("app", "RoomInTheCart.app")
    tests = "".join('<TestableReference skipped="NO">' + ref(key, product) + '</TestableReference>' for key, product in target_ids)
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{tests}</Testables></TestAction>
  <LaunchAction buildConfiguration="{config}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="{config}"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''


def outputs():
    package_names = tuple(sorted(p.parent.name for p in (IOS / "Packages").glob("*/Package.swift")))
    packages = [obj("package:" + name, "XCLocalSwiftPackageReference", relativePath="Packages/" + name) for name in package_names]
    for name in package_names:
        obj("product:" + name, "XCSwiftPackageProductDependency", package=ident("package:" + name), productName=name)
    app_sources = sorted((IOS / "App").rglob("*.swift")) + sorted((IOS / "Features").rglob("*.swift"))
    targets = [target("app", "RoomInTheCart", app_sources, "com.apple.product-type.application", "dev.roominthecart.app", packages=package_names)]
    test_ids = []
    for key, folder, name, kind in (("unit", "Tests", "RoomInTheCartTests", "unit-test"), ("ui", "UITests", "RoomInTheCartUITests", "ui-testing")):
        paths = sorted((IOS / folder).rglob("*.swift"))
        if not paths:
            continue
        proxy = obj(key + ":proxy", "PBXContainerItemProxy", containerPortal=ident("project"), proxyType="1", remoteGlobalIDString=ident("target:app"), remoteInfo="RoomInTheCart")
        dep = obj(key + ":dependency", "PBXTargetDependency", target=ident("target:app"), targetProxy=proxy)
        targets.append(target(key, name, paths, "com.apple.product-type.bundle." + kind, "dev.roominthecart." + name, dependencies=[dep], packages=package_names if key == "unit" else ()))
        test_ids.append((key, name + ".xctest"))
    product_group = obj("products", "PBXGroup", children=[ident(key + ":output") for key in ("app", "unit", "ui") if ident(key + ":output") in OBJECTS], name="Products", sourceTree="<group>")
    refs = sorted(identifier for identifier, value in OBJECTS.items() if value["isa"] == "PBXFileReference" and value.get("sourceTree") == "<group>")
    group = obj("main", "PBXGroup", children=refs + [product_group], sourceTree="<group>")
    settings = dict(ALWAYS_SEARCH_USER_PATHS="NO", CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", IPHONEOS_DEPLOYMENT_TARGET="17.0", SDKROOT="iphoneos", SUPPORTED_PLATFORMS="iphoneos iphonesimulator", SUPPORTS_MACCATALYST="NO", SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD="NO", SWIFT_VERSION="5.0", TARGETED_DEVICE_FAMILY="1", MARKETING_VERSION="0.1.0", CURRENT_PROJECT_VERSION="1")
    obj("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600"}, buildConfigurationList=config_list("project", settings, True), compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings="0", knownRegions=["en", "es", "Base"], mainGroup=group, packageReferences=packages, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=targets)
    project = {"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": dict(sorted(OBJECTS.items())), "rootObject": ident("project")}
    result = {PROJECT / "project.pbxproj": "// !$*UTF8*$!\n" + serialize(project) + "\n"}
    for name, config in (("RoomInTheCart", "Debug"), ("RoomInTheCart-Staging", "Staging"), ("RoomInTheCart-Release", "Release")):
        result[PROJECT / "xcshareddata" / "xcschemes" / (name + ".xcscheme")] = scheme(name, config, test_ids)
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
