#!/usr/bin/env python3
"""Generate the checked-in Xcode project from project.yml and the current source tree.

No Apple SDK is needed. Requires Python 3.10+ and PyYAML 6.0.3. IDs are derived
from stable paths, so adding one source does not churn unrelated project objects.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

try:
    import yaml
except ImportError:
    raise SystemExit("Install the generator dependency: python3 -m pip install 'PyYAML==6.0.3'")

ROOT = Path(__file__).resolve().parents[1]


class Reference(str):
    pass


def identifier(kind: str, key: str) -> Reference:
    return Reference(hashlib.sha256(f"atlas:{kind}:{key}".encode()).hexdigest()[:24].upper())


def serialize(value: object, indent: int = 0) -> str:
    tabs = "\t" * indent
    if isinstance(value, Reference):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (bool, int)):
        return str(int(value))
    if isinstance(value, list):
        if not value:
            return "()"
        return "(\n" + "".join("\t" * (indent + 1) + serialize(item, indent + 1) + ",\n" for item in value) + tabs + ")"
    if isinstance(value, dict):
        if not value:
            return "{}"
        return "{\n" + "".join("\t" * (indent + 1) + json.dumps(str(key)) + " = " + serialize(item, indent + 1) + ";\n" for key, item in value.items()) + tabs + "}"
    raise TypeError(type(value))


def build_value(value: object) -> object:
    if isinstance(value, bool):
        return "YES" if value else "NO"
    if isinstance(value, (int, float)):
        return str(value)
    return value


def generate() -> dict[Path, bytes]:
    spec = yaml.safe_load((ROOT / "project.yml").read_text())
    name = spec["name"]
    target_spec = spec["targets"][name]
    ui_name = f"{name}UITests"
    ui_spec = spec["targets"].get(ui_name)
    if set(spec["targets"]) - {name, ui_name} or target_spec["type"] != "application" or target_spec["platform"] != "iOS":
        raise SystemExit("This generator supports Atlas's iOS application and optional native UI-testing bundle.")
    if ui_spec is not None and (ui_spec["type"] != "bundle.ui-testing" or ui_spec["platform"] != "iOS"):
        raise SystemExit("AtlasUITests must be an iOS UI-testing bundle.")
    app = ROOT / "Apps/iOS"
    package_path = spec["packages"]["AtlasCore"]["path"]
    exclusion_paths = {
        exclusion for source in target_spec.get("sources", [])
        if isinstance(source, dict) for exclusion in source.get("excludes", [])
    }

    def excluded(path: Path) -> bool:
        relative = path.relative_to(app).as_posix()
        return any(relative == exclusion or relative.startswith(exclusion.rstrip("/") + "/")
                   for exclusion in exclusion_paths if exclusion != "Resources/PrivacyInfo.xcprivacy")

    files: dict[str, str] = {}
    sources: list[str] = []
    resources: list[str] = []
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(ROOT).as_posix()
        if any(part.startswith(".") for part in path.relative_to(app).parts):
            continue
        if excluded(path) and path.name != "Info.plist":
            continue
        catalog_parts = [index for index, part in enumerate(path.relative_to(app).parts) if part.endswith(".xcassets")]
        if catalog_parts:
            if path.is_dir() and path.name.endswith(".xcassets"):
                files[relative] = "folder.assetcatalog"
                resources.append(relative)
            continue
        if not path.is_file():
            continue
        if path.suffix == ".swift":
            files[relative] = "sourcecode.swift"
            sources.append(relative)
        elif path.name == "Info.plist":
            files[relative] = "text.plist.xml"
        elif "Resources" in path.relative_to(app).parts and path.suffix != ".storekit":
            files[relative] = "text.xml" if path.suffix == ".xcprivacy" else "file"
            resources.append(relative)
        elif path.suffix == ".storekit":
            files[relative] = "text"

    ui_sources: list[str] = []
    if ui_spec is not None:
        for source in ui_spec.get("sources", []):
            source_path = source if isinstance(source, str) else source["path"]
            for path in sorted((ROOT / source_path).rglob("*.swift")):
                if any(part.startswith(".") for part in path.relative_to(ROOT).parts):
                    continue
                relative = path.relative_to(ROOT).as_posix()
                if relative in sources:
                    raise SystemExit(f"UI test must be excluded from the application target: {relative}")
                files[relative] = "sourcecode.swift"
                ui_sources.append(relative)
        ui_sources = sorted(set(ui_sources))
        if not ui_sources:
            raise SystemExit("AtlasUITests has no Swift test sources.")

    info_path = ROOT / target_spec["info"]["path"]
    files[info_path.relative_to(ROOT).as_posix()] = "text.plist.xml"
    info = {
        "CFBundleDevelopmentRegion": "ru",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSRequiresIPhoneOS": True,
        **target_spec["info"]["properties"],
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }
    # No device-capability or Wi-Fi requirement: manual tools work without LiDAR.
    info.pop("UIRequiredDeviceCapabilities", None)
    info.pop("UIRequiresPersistentWiFi", None)

    objects: dict[Reference, dict] = {}

    def add(isa: str, key: str, **fields: object) -> Reference:
        key_id = identifier(isa, key)
        if key_id in objects:
            raise ValueError(f"Duplicate Xcode object: {isa} {key}")
        objects[key_id] = {"isa": isa, **fields}
        return key_id

    references = {path: add("PBXFileReference", path, lastKnownFileType=file_type, name=Path(path).name,
                            path=path, sourceTree="SOURCE_ROOT") for path, file_type in sorted(files.items())}

    def source_group(directory: str) -> Reference:
        immediate_files = [references[path] for path in sorted(files) if str(Path(path).parent) == directory]
        directories = sorted({str(Path(path).parent) for path in files if path.startswith(directory + "/")})
        next_directories = sorted({directory + "/" + path[len(directory) + 1:].split("/")[0]
                                   for path in directories if path != directory})
        children = [source_group(path) for path in next_directories] + immediate_files
        return add("PBXGroup", directory, children=children, name=Path(directory).name, sourceTree="<group>")

    source_root = source_group("Apps/iOS")
    product = add("PBXFileReference", "Atlas.app", explicitFileType="wrapper.application", includeInIndex=0,
                  path=f"{name}.app", sourceTree="BUILT_PRODUCTS_DIR")
    product_references = [product]
    ui_product = None
    if ui_spec is not None:
        ui_product = add("PBXFileReference", f"{ui_name}.xctest", explicitFileType="wrapper.cfbundle", includeInIndex=0,
                         path=f"{ui_name}.xctest", sourceTree="BUILT_PRODUCTS_DIR")
        product_references.append(ui_product)
    products = add("PBXGroup", "Products", children=product_references, name="Products", sourceTree="<group>")
    main = add("PBXGroup", "Main", children=[source_root, products], sourceTree="<group>")
    package = add("XCLocalSwiftPackageReference", "AtlasCore", relativePath=package_path)
    package_product = add("XCSwiftPackageProductDependency", "AtlasCore", package=package, productName="AtlasCore")
    package_build = add("PBXBuildFile", "AtlasCore", productRef=package_product)
    source_build = [add("PBXBuildFile", "source:" + path, fileRef=references[path]) for path in sources]
    resource_build = [add("PBXBuildFile", "resource:" + path, fileRef=references[path]) for path in resources]
    source_phase = add("PBXSourcesBuildPhase", "Atlas", buildActionMask=2147483647, files=source_build, runOnlyForDeploymentPostprocessing=0)
    frameworks_phase = add("PBXFrameworksBuildPhase", "Atlas", buildActionMask=2147483647, files=[package_build], runOnlyForDeploymentPostprocessing=0)
    resource_phase = add("PBXResourcesBuildPhase", "Atlas", buildActionMask=2147483647, files=resource_build, runOnlyForDeploymentPostprocessing=0)

    common = {key: build_value(value) for key, value in spec.get("settings", {}).get("base", {}).items()}
    common.update({"SDKROOT": "iphoneos", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
                   "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17"})
    target_base = {key: build_value(value) for key, value in target_spec.get("settings", {}).get("base", {}).items()}
    target_base.update({"INFOPLIST_FILE": target_spec["info"]["path"], "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_STYLE": "Automatic", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"]})
    project_configs, target_configs = [], []
    for configuration in ["Debug", "Release"]:
        project_settings = dict(common)
        project_settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O",
                                 "DEBUG_INFORMATION_FORMAT": "dwarf" if configuration == "Debug" else "dwarf-with-dsym",
                                 "ENABLE_TESTABILITY": "YES" if configuration == "Debug" else "NO"})
        if configuration == "Debug":
            project_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = ["$(inherited)", "DEBUG"]
            project_settings["GCC_PREPROCESSOR_DEFINITIONS"] = ["$(inherited)", "DEBUG=1"]
        project_configs.append(add("XCBuildConfiguration", "project:" + configuration, buildSettings=project_settings, name=configuration))
        target_configs.append(add("XCBuildConfiguration", "target:" + configuration, buildSettings=target_base, name=configuration))
    project_list = add("XCConfigurationList", "project", buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    target_list = add("XCConfigurationList", "target", buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    target = add("PBXNativeTarget", name, buildConfigurationList=target_list, buildPhases=[source_phase, frameworks_phase, resource_phase],
                 buildRules=[], dependencies=[], name=name, packageProductDependencies=[package_product], productName=name,
                 productReference=product, productType="com.apple.product-type.application")
    all_targets = [target]
    target_attributes = {target: {"CreatedOnToolsVersion": "16.0"}}
    ui_target = None
    if ui_spec is not None:
        ui_build = [add("PBXBuildFile", "ui-source:" + path, fileRef=references[path]) for path in ui_sources]
        ui_source_phase = add("PBXSourcesBuildPhase", ui_name, buildActionMask=2147483647, files=ui_build,
                              runOnlyForDeploymentPostprocessing=0)
        ui_frameworks_phase = add("PBXFrameworksBuildPhase", ui_name, buildActionMask=2147483647, files=[],
                                  runOnlyForDeploymentPostprocessing=0)
        ui_resources_phase = add("PBXResourcesBuildPhase", ui_name, buildActionMask=2147483647, files=[],
                                 runOnlyForDeploymentPostprocessing=0)
        ui_settings = {key: build_value(value) for key, value in ui_spec.get("settings", {}).get("base", {}).items()}
        ui_settings.update({"PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]})
        ui_configs = [add("XCBuildConfiguration", f"{ui_name}:" + configuration, buildSettings=ui_settings, name=configuration)
                      for configuration in ["Debug", "Release"]]
        ui_list = add("XCConfigurationList", ui_name, buildConfigurations=ui_configs,
                      defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
        proxy = add("PBXContainerItemProxy", ui_name, containerPortal=identifier("PBXProject", name), proxyType=1,
                    remoteGlobalIDString=target, remoteInfo=name)
        dependency = add("PBXTargetDependency", ui_name, target=target, targetProxy=proxy)
        ui_target = add("PBXNativeTarget", ui_name, buildConfigurationList=ui_list,
                        buildPhases=[ui_source_phase, ui_frameworks_phase, ui_resources_phase],
                        buildRules=[], dependencies=[dependency], name=ui_name, productName=ui_name,
                        productReference=ui_product, productType="com.apple.product-type.bundle.ui-testing")
        all_targets.append(ui_target)
        target_attributes[ui_target] = {"CreatedOnToolsVersion": "16.0", "TestTargetID": target}
    project = add("PBXProject", name, attributes={"BuildIndependentTargetsInParallel": "YES", "LastSwiftUpdateCheck": "1600",
                                                 "LastUpgradeCheck": "1600", "TargetAttributes": target_attributes},
                  buildConfigurationList=project_list, compatibilityVersion="Xcode 14.0", developmentRegion="ru",
                  hasScannedForEncodings=0, knownRegions=["ru", "en", "Base"], mainGroup=main,
                  packageReferences=[package], productRefGroup=products, projectDirPath="", projectRoot="", targets=all_targets)
    document = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}
    project_data = ("// !$*UTF8*$!\n" + serialize(document) + "\n").encode()

    scheme = ET.Element("Scheme", {"LastUpgradeVersion": "1600", "version": "1.3"})

    def buildable(parent: ET.Element) -> None:
        ET.SubElement(parent, "BuildableReference", {"BuildableIdentifier": "primary", "BlueprintIdentifier": str(target),
                                                   "BuildableName": f"{name}.app", "BlueprintName": name,
                                                   "ReferencedContainer": f"container:{name}.xcodeproj"})

    build = ET.SubElement(scheme, "BuildAction", {"parallelizeBuildables": "YES", "buildImplicitDependencies": "YES"})
    entry = ET.SubElement(ET.SubElement(build, "BuildActionEntries"), "BuildActionEntry",
                          {"buildForTesting": "YES", "buildForRunning": "YES", "buildForProfiling": "YES", "buildForArchiving": "YES", "buildForAnalyzing": "YES"})
    buildable(entry)
    test = ET.SubElement(scheme, "TestAction", {"buildConfiguration": "Debug", "selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB",
                                               "selectedLauncherIdentifier": "Xcode.IDEFoundation.Launcher.LLDB", "shouldUseLaunchSchemeArgsEnv": "YES"})
    ET.SubElement(test, "Testables")  # Core tests run through SwiftPM; no simulated native-test claim.
    launch = ET.SubElement(scheme, "LaunchAction", {"buildConfiguration": "Debug", "selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB",
                                                   "selectedLauncherIdentifier": "Xcode.IDEFoundation.Launcher.LLDB", "launchStyle": "0", "useCustomWorkingDirectory": "NO",
                                                   "ignoresPersistentStateOnLaunch": "NO", "debugDocumentVersioning": "YES", "debugServiceExtension": "internal", "allowLocationSimulation": "YES"})
    buildable(ET.SubElement(launch, "BuildableProductRunnable", {"runnableDebuggingMode": "0"}))
    profile = ET.SubElement(scheme, "ProfileAction", {"buildConfiguration": "Release", "shouldUseLaunchSchemeArgsEnv": "YES",
                                                     "savedToolIdentifier": "", "useCustomWorkingDirectory": "NO", "debugDocumentVersioning": "YES"})
    buildable(ET.SubElement(profile, "BuildableProductRunnable", {"runnableDebuggingMode": "0"}))
    ET.SubElement(scheme, "AnalyzeAction", {"buildConfiguration": "Debug"})
    ET.SubElement(scheme, "ArchiveAction", {"buildConfiguration": "Release", "revealArchiveInOrganizer": "YES"})
    ET.indent(scheme, space="   ")
    scheme_data = ET.tostring(scheme, encoding="utf-8", xml_declaration=True) + b"\n"

    generated = {
        ROOT / f"{name}.xcodeproj/project.pbxproj": project_data,
        ROOT / f"{name}.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme": scheme_data,
        info_path: plistlib.dumps(info, sort_keys=False),
    }
    if ui_target is not None:
        ui_scheme = ET.Element("Scheme", {"LastUpgradeVersion": "1600", "version": "1.3"})
        ui_build_action = ET.SubElement(ui_scheme, "BuildAction", {"parallelizeBuildables": "YES", "buildImplicitDependencies": "YES"})
        ui_entries = ET.SubElement(ui_build_action, "BuildActionEntries")
        for target_id, target_name, buildable_name in [(target, name, f"{name}.app"), (ui_target, ui_name, f"{ui_name}.xctest")]:
            ui_entry = ET.SubElement(ui_entries, "BuildActionEntry", {"buildForTesting": "YES", "buildForRunning": "NO",
                                                                      "buildForProfiling": "NO", "buildForArchiving": "NO", "buildForAnalyzing": "NO"})
            ET.SubElement(ui_entry, "BuildableReference", {"BuildableIdentifier": "primary", "BlueprintIdentifier": str(target_id),
                                                            "BuildableName": buildable_name, "BlueprintName": target_name,
                                                            "ReferencedContainer": f"container:{name}.xcodeproj"})
        ui_test = ET.SubElement(ui_scheme, "TestAction", {"buildConfiguration": "Debug", "selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB",
                                                          "selectedLauncherIdentifier": "Xcode.IDEFoundation.Launcher.LLDB", "shouldUseLaunchSchemeArgsEnv": "YES"})
        ui_testable = ET.SubElement(ET.SubElement(ui_test, "Testables"), "TestableReference", {"skipped": "NO", "parallelizable": "NO"})
        ET.SubElement(ui_testable, "BuildableReference", {"BuildableIdentifier": "primary", "BlueprintIdentifier": str(ui_target),
                                                          "BuildableName": f"{ui_name}.xctest", "BlueprintName": ui_name,
                                                          "ReferencedContainer": f"container:{name}.xcodeproj"})
        ET.indent(ui_scheme, space="   ")
        generated[ROOT / f"{name}.xcodeproj/xcshareddata/xcschemes/{ui_name}.xcscheme"] = ET.tostring(ui_scheme, encoding="utf-8", xml_declaration=True) + b"\n"
    return generated


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if checked-in project or Info.plist needs regeneration")
    args = parser.parse_args()
    generated = generate()
    stale = []
    for path, data in generated.items():
        if args.check:
            if not path.exists() or path.read_bytes() != data:
                stale.append(path.relative_to(ROOT).as_posix())
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if stale:
        raise SystemExit("Regenerate Xcode files with Scripts/generate-xcode-project.py: " + ", ".join(stale))
    print("Xcode project is current" if args.check else "Generated Atlas.xcodeproj, shared scheme, and Info.plist")


if __name__ == "__main__":
    main()
