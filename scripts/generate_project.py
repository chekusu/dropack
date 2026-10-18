#!/usr/bin/env python3
"""Generate the checked-in Xcode project without Xcode or third-party packages.

Run from any directory after adding or removing a Swift file. IDs depend on paths,
not discovery order, so regenerated projects produce small, reproducible diffs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "PhotoRelay"
PROJECT = ROOT / "Dropack.xcodeproj"


class Literal(str):
    """An unquoted OpenStep token, including an object reference."""


def identifier(name: str) -> Literal:
    return Literal(hashlib.sha256(f"PhotoRelay:{name}".encode()).hexdigest()[:24].upper())


def encode(value: object, level: int = 0) -> str:
    indent = "\t" * level
    if isinstance(value, Literal):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, dict):
        lines = ["{"]
        for key, child in value.items():
            token = str(key) if re.fullmatch(r"[A-Za-z0-9_]+", str(key)) else encode(str(key))
            lines.append(f"{indent}\t{token} = {encode(child, level + 1)};")
        lines.append(f"{indent}}}")
        return "\n".join(lines)
    if isinstance(value, (list, tuple)):
        if not value:
            return "()"
        lines = ["("]
        lines.extend(f"{indent}\t{encode(child, level + 1)}," for child in value)
        lines.append(f"{indent})")
        return "\n".join(lines)
    raise TypeError(f"Unsupported OpenStep value: {type(value)!r}")


def generate() -> dict[Path, str]:
    objects: dict[Literal, dict[str, object]] = {}

    def add(label: str, kind: str, **values: object) -> Literal:
        ref = identifier(label)
        if ref in objects:
            raise ValueError(f"Duplicate project object: {label}")
        objects[ref] = {"isa": Literal(kind), **values}
        return ref

    swift_files = sorted(path.relative_to(APP) for path in APP.rglob("*.swift") if path.is_file())
    catalogs = sorted(path.relative_to(APP) for path in APP.rglob("*.xcassets") if path.is_dir())
    json_resources = sorted(path.relative_to(APP) for path in (APP / "Core/Resources").glob("*.json"))
    privacy_manifests = sorted(path.relative_to(APP) for path in APP.rglob("*.xcprivacy") if path.is_file())
    paths = sorted(set(swift_files + catalogs + privacy_manifests + json_resources + [Path("Info.plist")]))
    source_builds: list[Literal] = []
    resource_builds: list[Literal] = []
    references: dict[Path, Literal] = {}
    for path in paths:
        path_string = path.as_posix()
        file_type = "sourcecode.swift" if path.suffix == ".swift" else (
            "folder.assetcatalog" if path.suffix == ".xcassets" else "text.json" if path.suffix == ".json" else "text.plist.xml"
        )
        references[path] = add(
            f"file:{path_string}", "PBXFileReference", lastKnownFileType=file_type,
            path=path.name, sourceTree="<group>",
        )
        if path in swift_files:
            source_builds.append(add(f"source:{path_string}", "PBXBuildFile", fileRef=references[path]))
        elif path in catalogs or path in privacy_manifests or path in json_resources:
            resource_builds.append(add(f"resource:{path_string}", "PBXBuildFile", fileRef=references[path]))

    def group(directory: Path) -> Literal:
        files = [references[path] for path in paths if path.parent == directory]
        descendants = {
            directory / path.relative_to(directory).parts[0]
            for path in paths if directory in path.parents and path.parent != directory
        }
        children = [group(child) for child in sorted(descendants)] + files
        name = directory.as_posix()
        return add(
            f"group:{name}", "PBXGroup", children=children,
            path="PhotoRelay" if directory == Path(".") else directory.name,
            sourceTree="<group>",
        )

    localized_info_refs = []
    for file in sorted((APP / "Resources").glob("*.lproj/InfoPlist.strings")):
        locale = file.parent.stem
        localized_info_refs.append(add(f"localized-info:{locale}", "PBXFileReference",
            lastKnownFileType="text.plist.strings", name=locale,
            path=file.relative_to(ROOT).as_posix(), sourceTree="SOURCE_ROOT"))
    info_variant = None
    if localized_info_refs:
        info_variant = add("localized-info", "PBXVariantGroup", children=localized_info_refs,
            name="InfoPlist.strings", sourceTree="<group>")
        resource_builds.append(add("localized-info-resource", "PBXBuildFile", fileRef=info_variant))
    app_group = group(Path("."))
    if info_variant:
        objects[app_group]["children"].append(info_variant)
    product = add(
        "product", "PBXFileReference", explicitFileType="wrapper.application",
        includeInIndex=0, path="Dropack.app", sourceTree="BUILT_PRODUCTS_DIR",
    )
    products = add("products", "PBXGroup", children=[product], name="Products", sourceTree="<group>")
    main_group = add("main-group", "PBXGroup", children=[app_group, products], sourceTree="<group>")
    package = add(
        "zip-package", "XCRemoteSwiftPackageReference",
        repositoryURL="https://github.com/weichsel/ZIPFoundation.git",
        requirement={"kind": Literal("exactVersion"), "version": "0.9.20"},
    )
    package_product = add(
        "zip-product", "XCSwiftPackageProductDependency", package=package, productName="ZIPFoundation",
    )
    package_build = add("zip-framework", "PBXBuildFile", productRef=package_product)
    sources = add(
        "sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
        files=source_builds, runOnlyForDeploymentPostprocessing=0,
    )
    frameworks = add(
        "frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
        files=[package_build], runOnlyForDeploymentPostprocessing=0,
    )
    resources = add(
        "resources", "PBXResourcesBuildPhase", buildActionMask=2147483647,
        files=resource_builds, runOnlyForDeploymentPostprocessing=0,
    )

    # ActivityAttributes must be compiled into both executables with the same
    # schema. Keep their sources separate from the app-only services and views.
    shared_refs, shared_widget_builds = [], []
    for file in sorted((ROOT / "Shared").glob("*.swift")):
        path = file.relative_to(ROOT).as_posix()
        ref = add(f"shared-file:{path}", "PBXFileReference",
                  lastKnownFileType="sourcecode.swift", path=path, sourceTree="SOURCE_ROOT")
        shared_refs.append(ref)
        source_builds.append(add(f"shared-app-source:{path}", "PBXBuildFile", fileRef=ref))
        shared_widget_builds.append(add(f"shared-widget-source:{path}", "PBXBuildFile", fileRef=ref))
    shared_group = add("shared-group", "PBXGroup", name="Shared",
                       children=shared_refs, sourceTree="<group>")
    objects[main_group]["children"].append(shared_group)

    project_configurations: list[Literal] = []
    target_configurations: list[Literal] = []
    for configuration in ("Debug", "Release"):
        debug = configuration == "Debug"
        project_settings: dict[str, object] = {
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "DEBUG_INFORMATION_FORMAT": "dwarf" if debug else "dwarf-with-dsym",
            "ENABLE_TESTABILITY": "YES" if debug else "NO",
            "GCC_C_LANGUAGE_STANDARD": "gnu17",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
            "ONLY_ACTIVE_ARCH": "YES" if debug else "NO",
            "SDKROOT": "iphoneos",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if debug else "-O",
            "SWIFT_VERSION": "5.0",
        }
        if debug:
            project_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG $(inherited)"
        else:
            project_settings["SWIFT_COMPILATION_MODE"] = "wholemodule"
            project_settings["VALIDATE_PRODUCT"] = "YES"
        target_settings: dict[str, object] = {
            "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": "14",
            "ENABLE_PREVIEWS": "YES",
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "PhotoRelay/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "MARKETING_VERSION": "1.0",
            "PRODUCT_BUNDLE_IDENTIFIER": "app.dropack.ios",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "SUPPORTS_MACCATALYST": "NO",
            "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "TARGETED_DEVICE_FAMILY": "1,2",
        }
        if any((APP / catalog / "AppIcon.appiconset").is_dir() for catalog in catalogs):
            target_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
        if any((APP / catalog / "AccentColor.colorset").is_dir() for catalog in catalogs):
            target_settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
        project_configurations.append(add(
            f"project-configuration:{configuration}", "XCBuildConfiguration",
            buildSettings=project_settings, name=configuration,
        ))
        target_configurations.append(add(
            f"target-configuration:{configuration}", "XCBuildConfiguration",
            buildSettings=target_settings, name=configuration,
        ))
    project_configs = add(
        "project-configurations", "XCConfigurationList", buildConfigurations=project_configurations,
        defaultConfigurationIsVisible=0, defaultConfigurationName="Release",
    )
    target_configs = add(
        "target-configurations", "XCConfigurationList", buildConfigurations=target_configurations,
        defaultConfigurationIsVisible=0, defaultConfigurationName="Release",
    )
    target = add(
        "target", "PBXNativeTarget", buildConfigurationList=target_configs,
        buildPhases=[sources, frameworks, resources], buildRules=[], dependencies=[],
        name="Dropack", packageProductDependencies=[package_product], productName="Dropack",
        productReference=product, productType="com.apple.product-type.application",
    )

    widget_refs, widget_builds, widget_resources = [], list(shared_widget_builds), []
    widget_builds.append(add("widget-l10n-source", "PBXBuildFile", fileRef=references[Path("Core/L10n.swift")]))
    for path in json_resources:
        widget_resources.append(add(f"widget-resource:{path}", "PBXBuildFile", fileRef=references[path]))
    widget_directory = ROOT / "DropackLiveActivity"
    widget_files = (sorted(widget_directory.glob("*.swift"))
                    + sorted(widget_directory.glob("*.plist"))
                    + sorted(widget_directory.glob("*.xcprivacy")))
    for file in widget_files:
        path = file.relative_to(ROOT).as_posix()
        is_swift = file.suffix == ".swift"
        ref = add(f"widget-file:{path}", "PBXFileReference",
                  lastKnownFileType="sourcecode.swift" if is_swift else "text.plist.xml",
                  path=path, sourceTree="SOURCE_ROOT")
        widget_refs.append(ref)
        if is_swift:
            widget_builds.append(add(f"widget-source:{path}", "PBXBuildFile", fileRef=ref))
        elif file.suffix == ".xcprivacy":
            widget_resources.append(add(f"widget-resource:{path}", "PBXBuildFile", fileRef=ref))
    widget_group = add("widget-group", "PBXGroup", name="DropackLiveActivity",
                       children=widget_refs, sourceTree="<group>")
    objects[main_group]["children"].append(widget_group)
    widget_product = add("widget-product", "PBXFileReference", explicitFileType="wrapper.app-extension",
                         includeInIndex=0, path="DropackLiveActivity.appex", sourceTree="BUILT_PRODUCTS_DIR")
    objects[products]["children"].append(widget_product)
    widget_configurations = []
    for configuration in ("Debug", "Release"):
        settings = {
            "APPLICATION_EXTENSION_API_ONLY": "YES", "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": "14", "MARKETING_VERSION": "1.0",
            "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "DropackLiveActivity/Info.plist",
            "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "PRODUCT_BUNDLE_IDENTIFIER": "app.dropack.ios.liveactivity",
            "PRODUCT_NAME": "$(TARGET_NAME)", "SKIP_INSTALL": "YES", "SWIFT_VERSION": "5.0",
            "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
        }
        widget_configurations.append(add(f"widget-configuration:{configuration}", "XCBuildConfiguration",
                                          buildSettings=settings, name=configuration))
    widget_configs = add("widget-configurations", "XCConfigurationList",
                         buildConfigurations=widget_configurations, defaultConfigurationIsVisible=0,
                         defaultConfigurationName="Release")
    widget_sources = add("widget-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
                         files=widget_builds, runOnlyForDeploymentPostprocessing=0)
    widget_frameworks = add("widget-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                            files=[], runOnlyForDeploymentPostprocessing=0)
    widget_resource_phase = add("widget-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647,
                                files=widget_resources, runOnlyForDeploymentPostprocessing=0)
    widget_target = add("widget-target", "PBXNativeTarget", name="DropackLiveActivity",
                        productName="DropackLiveActivity", productReference=widget_product,
                        productType="com.apple.product-type.app-extension", buildConfigurationList=widget_configs,
                        buildPhases=[widget_sources, widget_frameworks, widget_resource_phase],
                        buildRules=[], dependencies=[])
    widget_proxy = add("widget-proxy", "PBXContainerItemProxy", containerPortal=identifier("project"),
                       proxyType=1, remoteGlobalIDString=widget_target, remoteInfo="DropackLiveActivity")
    widget_dependency = add("widget-dependency", "PBXTargetDependency",
                            target=widget_target, targetProxy=widget_proxy)
    objects[target]["dependencies"].append(widget_dependency)
    embedded_widget = add("widget-embed", "PBXBuildFile", fileRef=widget_product,
                          settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
    embed_phase = add("widget-embed-phase", "PBXCopyFilesBuildPhase", buildActionMask=2147483647,
                      dstPath="", dstSubfolderSpec=13, files=[embedded_widget],
                      name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0)
    objects[target]["buildPhases"].append(embed_phase)
    test_targets = []
    test_buildables = []
    for test_name, test_directory, is_ui in [
        ("DropackIntegrationTests", "Tests/AppIntegrationTests", False),
        ("DropackUITests", "Tests/AppUITests", True),
    ]:
        files = sorted((ROOT / test_directory).glob("*.swift"))
        if not files:
            continue
        refs, builds = [], []
        for file in files:
            ref = add(f"test-file:{file.relative_to(ROOT)}", "PBXFileReference",
                      lastKnownFileType="sourcecode.swift", path=str(file.relative_to(ROOT)),
                      sourceTree="SOURCE_ROOT")
            refs.append(ref)
            builds.append(add(f"test-source:{file.relative_to(ROOT)}", "PBXBuildFile", fileRef=ref))
        test_group = add(f"test-group:{test_name}", "PBXGroup", name=test_name,
                         children=refs, sourceTree="<group>")
        objects[main_group]["children"].append(test_group)
        test_product = add(f"test-product:{test_name}", "PBXFileReference",
                           explicitFileType="wrapper.cfbundle", includeInIndex=0,
                           path=f"{test_name}.xctest", sourceTree="BUILT_PRODUCTS_DIR")
        objects[products]["children"].append(test_product)
        test_configs = []
        for config in ("Debug", "Release"):
            settings = {
                "PRODUCT_BUNDLE_IDENTIFIER": f"app.dropack.{test_name}",
                "PRODUCT_NAME": "$(TARGET_NAME)", "GENERATE_INFOPLIST_FILE": "YES",
                "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0",
                "TARGETED_DEVICE_FAMILY": "1,2", "CODE_SIGN_STYLE": "Automatic",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
            }
            if is_ui:
                settings["TEST_TARGET_NAME"] = "Dropack"
            else:
                settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/Dropack.app/Dropack"
                settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
            test_configs.append(add(f"test-config:{test_name}:{config}", "XCBuildConfiguration",
                                    buildSettings=settings, name=config))
        test_config_list = add(f"test-configs:{test_name}", "XCConfigurationList",
                               buildConfigurations=test_configs,
                               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
        test_sources = add(f"test-sources:{test_name}", "PBXSourcesBuildPhase",
                           buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)
        zip_build = add(f"test-zip:{test_name}", "PBXBuildFile", productRef=package_product)
        test_frameworks = add(f"test-frameworks:{test_name}", "PBXFrameworksBuildPhase",
                              buildActionMask=2147483647, files=[] if is_ui else [zip_build],
                              runOnlyForDeploymentPostprocessing=0)
        proxy = add(f"test-proxy:{test_name}", "PBXContainerItemProxy", containerPortal=identifier("project"),
                    proxyType=1, remoteGlobalIDString=target, remoteInfo="Dropack")
        dependency = add(f"test-dependency:{test_name}", "PBXTargetDependency", target=target, targetProxy=proxy)
        test_target = add(f"test-target:{test_name}", "PBXNativeTarget", name=test_name,
                          productName=test_name, productReference=test_product,
                          productType="com.apple.product-type.bundle.ui-testing" if is_ui else "com.apple.product-type.bundle.unit-test",
                          buildConfigurationList=test_config_list, buildPhases=[test_sources, test_frameworks],
                          buildRules=[], dependencies=[dependency],
                          packageProductDependencies=[] if is_ui else [package_product])
        test_targets.append(test_target)
        test_buildables.append(
            f'<TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" '
            f'BlueprintIdentifier="{test_target}" BuildableName="{test_name}.xctest" '
            f'BlueprintName="{test_name}" ReferencedContainer="container:Dropack.xcodeproj" /></TestableReference>'
        )
    project = add(
        "project", "PBXProject",
        attributes={"BuildIndependentTargetsInParallel": "YES", "LastSwiftUpdateCheck": "1600",
                    "LastUpgradeCheck": "1600", "TargetAttributes": {target: {"CreatedOnToolsVersion": "16.0"}}},
        buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0",
        developmentRegion="en", hasScannedForEncodings=0, knownRegions=["Base", "en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "it", "pt-BR", "nl", "pl", "tr", "ar", "hi", "id"],
        mainGroup=main_group, packageReferences=[package], productRefGroup=products,
        projectDirPath="", projectRoot="", targets=[target, widget_target] + test_targets,
    )
    ordered_objects = dict(sorted(objects.items(), key=lambda pair: (str(pair[1]["isa"]), pair[0])))
    document = {"archiveVersion": 1, "classes": {}, "objectVersion": 56,
                "objects": ordered_objects, "rootObject": project}
    project_text = "// !$*UTF8*$!\n" + encode(document) + "\n"
    buildable = (
        f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" '
        'BuildableName="Dropack.app" BlueprintName="Dropack" '
        'ReferencedContainer="container:Dropack.xcodeproj" />'
    )
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        {buildable}
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO">
    <Testables>{''.join(test_buildables)}</Testables>
    <EnvironmentVariables><EnvironmentVariable key="DROPACK_QA" value="1" isEnabled="YES" /></EnvironmentVariables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal">
    <BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug" />
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES" />
</Scheme>
'''
    workspace = '''<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
  <FileRef location="self:" />
</Workspace>
'''
    return {
        PROJECT / "project.pbxproj": project_text,
        PROJECT / "xcshareddata/xcschemes/Dropack.xcscheme": scheme,
        PROJECT / "project.xcworkspace/contents.xcworkspacedata": workspace,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if committed project files need regeneration.")
    args = parser.parse_args()
    stale: list[str] = []
    for path, text in generate().items():
        if args.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != text:
                stale.append(path.relative_to(ROOT).as_posix())
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    if stale:
        print("Project files need regeneration: " + ", ".join(stale))
        print("Run: python3 scripts/generate_project.py")
        return 1
    print("Xcode project is current." if args.check else "Generated Dropack.xcodeproj and shared Dropack scheme.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
