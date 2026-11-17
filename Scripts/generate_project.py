#!/usr/bin/env python3
"""用标准库生成可直接打开的 Xcode 工程；文件标识由相对路径稳定计算。"""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parent.parent

# 再生成工程时保留 Xcode 中选择的团队、Bundle ID 和其他本地构建设置。
existing_target_settings = {}
existing_share_settings = {}
existing_project_settings = {}
project_file = ROOT / "FreeReading.xcodeproj/project.pbxproj"
if project_file.exists():
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(project_file)], capture_output=True, check=True)
    previous = json.loads(result.stdout)["objects"]
    for value in previous.values():
        destination = None
        if value.get("isa") == "PBXNativeTarget" and value.get("name") == "FreeReading":
            destination = existing_target_settings
        elif value.get("isa") == "PBXNativeTarget" and value.get("name") == "FreeReadingShare":
            destination = existing_share_settings
        elif value.get("isa") == "PBXProject":
            destination = existing_project_settings
        if destination is not None:
            for identifier in previous[value["buildConfigurationList"]]["buildConfigurations"]:
                config = previous[identifier]
                destination[config["name"]] = config["buildSettings"]

def uid(name):
    return hashlib.sha1(("FreeReading:" + name).encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(str(value), ensure_ascii=False)

objects = {}
def add(name, value):
    objects[uid(name)] = value
    return uid(name)

def array(values):
    return "(" + ", ".join(values) + ("," if values else "") + ")"

app = add("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = FreeReading.app; sourceTree = BUILT_PRODUCTS_DIR;')
share_product = add("share-product", 'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = FreeReadingShare.appex; sourceTree = BUILT_PRODUCTS_DIR;')
file_refs, source_builds, resource_builds = [], [], []
files = sorted(p for p in (ROOT / "App").rglob("*") if p.is_file() and ".xcassets" not in str(p))
files += sorted((ROOT / "App").rglob("*.xcassets"))
for path in files:
    relative = path.relative_to(ROOT).as_posix()
    kind = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".js": "sourcecode.javascript", ".xcassets": "folder.assetcatalog", ".xcprivacy": "text.xml"}.get(path.suffix, "text")
    ref = add("file:" + relative, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(relative)}; sourceTree = SOURCE_ROOT;')
    file_refs.append(ref)
    if path.suffix == ".swift" or relative.startswith("App/Resources/"):
        build = add("build:" + relative, f'isa = PBXBuildFile; fileRef = {ref};')
        (source_builds if path.suffix == ".swift" else resource_builds).append(build)

share_refs, share_sources = [], []
for path in sorted((ROOT / "ShareExtension").rglob("*")):
    if not path.is_file():
        continue
    relative = path.relative_to(ROOT).as_posix()
    kind = "sourcecode.swift" if path.suffix == ".swift" else "text.plist.xml"
    ref = add("file:" + relative, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(relative)}; sourceTree = SOURCE_ROOT;')
    share_refs.append(ref)
    if path.suffix == ".swift":
        share_sources.append(add("build:" + relative, f'isa = PBXBuildFile; fileRef = {ref};'))
share_group = add("share-group", f'isa = PBXGroup; children = {array(share_refs)}; name = ShareExtension; sourceTree = "<group>";')
products = add("products", f'isa = PBXGroup; children = {array([app, share_product])}; name = Products; sourceTree = "<group>";')
app_group = add("app-group", f'isa = PBXGroup; children = {array(file_refs)}; name = App; sourceTree = "<group>";')
main_group = add("main-group", f'isa = PBXGroup; children = {array([app_group, share_group, products])}; sourceTree = "<group>";')
package = add("local-package", 'isa = XCLocalSwiftPackageReference; relativePath = ".";')
dependency = add("core-product", f'isa = XCSwiftPackageProductDependency; package = {package}; productName = FreeReadingCore;')
linked = add("linked-core", f'isa = PBXBuildFile; productRef = {dependency};')
phases = []
for name, isa, builds in [("sources", "PBXSourcesBuildPhase", source_builds), ("frameworks", "PBXFrameworksBuildPhase", [linked]), ("resources", "PBXResourcesBuildPhase", resource_builds)]:
    phases.append(add(name, f'isa = {isa}; buildActionMask = 2147483647; files = {array(builds)}; runOnlyForDeploymentPostprocessing = 0;'))
embedded = add("embed-share", f'isa = PBXBuildFile; fileRef = {share_product}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
phases.append(add("embed-extensions", f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = {array([embedded])}; name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;'))
share_dependency = add("share-core-product", f'isa = XCSwiftPackageProductDependency; package = {package}; productName = FreeReadingCore;')
share_linked = add("share-linked-core", f'isa = PBXBuildFile; productRef = {share_dependency};')
share_phases = []
for name, isa, builds in [("sources", "PBXSourcesBuildPhase", share_sources), ("frameworks", "PBXFrameworksBuildPhase", [share_linked]), ("resources", "PBXResourcesBuildPhase", [])]:
    share_phases.append(add("share-" + name, f'isa = {isa}; buildActionMask = 2147483647; files = {array(builds)}; runOnlyForDeploymentPostprocessing = 0;'))

def settings(values):
    return "{ " + " ".join(f"{quote(key)} = {setting_value(value)};" for key, value in sorted(values.items())) + " }"

def setting_value(value):
    if isinstance(value, list):
        return array([setting_value(item) for item in value])
    if isinstance(value, dict):
        return settings(value)
    return quote(value)

project_configs, target_configs, share_configs = [], [], []
for config in ("Debug", "Release"):
    project_settings = {
        "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0",
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_ANALYZER_NONNULL": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym",
        "FREEREADING_APP_GROUP": "group.com.bestjerry.FreeReading",
    }
    if config == "Debug":
        project_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) DEBUG"
        project_settings["ONLY_ACTIVE_ARCH"] = "YES"
    project_settings.update(existing_project_settings.get(config, {}))
    target_settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.bestjerry.FreeReading", "PRODUCT_NAME": "$(TARGET_NAME)",
        "INFOPLIST_FILE": "App/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "CODE_SIGN_STYLE": "Automatic",
        "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "ENABLE_PREVIEWS": "YES",
    }
    target_settings.update(existing_target_settings.get(config, {}))
    target_settings["CODE_SIGN_ENTITLEMENTS"] = "App/FreeReading.entitlements"
    share_settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": target_settings["PRODUCT_BUNDLE_IDENTIFIER"] + ".Share",
        "PRODUCT_NAME": "$(TARGET_NAME)", "INFOPLIST_FILE": "ShareExtension/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO", "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_ENTITLEMENTS": "ShareExtension/FreeReadingShare.entitlements",
        "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SKIP_INSTALL": "YES", "APPLICATION_EXTENSION_API_ONLY": "YES",
        "MARKETING_VERSION": target_settings["MARKETING_VERSION"], "CURRENT_PROJECT_VERSION": target_settings["CURRENT_PROJECT_VERSION"],
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    }
    if "DEVELOPMENT_TEAM" in target_settings:
        share_settings["DEVELOPMENT_TEAM"] = target_settings["DEVELOPMENT_TEAM"]
    share_settings.update(existing_share_settings.get(config, {}))
    project_configs.append(add("project-config:" + config, f'isa = XCBuildConfiguration; buildSettings = {settings(project_settings)}; name = {config};'))
    target_configs.append(add("target-config:" + config, f'isa = XCBuildConfiguration; buildSettings = {settings(target_settings)}; name = {config};'))
    share_configs.append(add("share-config:" + config, f'isa = XCBuildConfiguration; buildSettings = {settings(share_settings)}; name = {config};'))

project_config_list = add("project-configs", f'isa = XCConfigurationList; buildConfigurations = {array(project_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target_config_list = add("target-configs", f'isa = XCConfigurationList; buildConfigurations = {array(target_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
share_config_list = add("share-configs", f'isa = XCConfigurationList; buildConfigurations = {array(share_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
share_target = add("share-target", f'isa = PBXNativeTarget; buildConfigurationList = {share_config_list}; buildPhases = {array(share_phases)}; buildRules = (); dependencies = (); name = FreeReadingShare; packageProductDependencies = {array([share_dependency])}; productName = FreeReadingShare; productReference = {share_product}; productType = "com.apple.product-type.app-extension";')
proxy = add("share-proxy", f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {share_target}; remoteInfo = FreeReadingShare;')
share_target_dependency = add("share-target-dependency", f'isa = PBXTargetDependency; target = {share_target}; targetProxy = {proxy};')
target = add("target", f'isa = PBXNativeTarget; buildConfigurationList = {target_config_list}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array([share_target_dependency])}; name = FreeReading; packageProductDependencies = {array([dependency])}; productName = FreeReading; productReference = {app}; productType = "com.apple.product-type.application";')
project = add("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {target} = {{ CreatedOnToolsVersion = 16.0; }}; {share_target} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {project_config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (en, Base, "zh-Hans"); mainGroup = {main_group}; packageReferences = {array([package])}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {array([target, share_target])};')
directory = ROOT / "FreeReading.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text('// !$*UTF8*$!\n{\narchiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n' + "\n".join(f"{key} = {{ {value} }};" for key, value in sorted(objects.items())) + f'\n}};\nrootObject = {project};\n}}\n')
schemes = directory / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "FreeReading.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="FreeReading.app" BlueprintName="FreeReading" ReferencedContainer="container:FreeReading.xcodeproj" />
    </BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES" />
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="FreeReading.app" BlueprintName="FreeReading" ReferencedContainer="container:FreeReading.xcodeproj" /></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="FreeReading.app" BlueprintName="FreeReading" ReferencedContainer="container:FreeReading.xcodeproj" /></BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug" />
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES" />
</Scheme>
''')
print(f"Generated {directory.name}: {len(source_builds)} Swift sources, {len(resource_builds)} resources")
