#!/usr/bin/env python3
"""用标准库生成可直接打开的 Xcode 工程；文件标识由相对路径稳定计算。"""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent

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

products = add("products", f'isa = PBXGroup; children = {array([app])}; name = Products; sourceTree = "<group>";')
app_group = add("app-group", f'isa = PBXGroup; children = {array(file_refs)}; name = App; sourceTree = "<group>";')
main_group = add("main-group", f'isa = PBXGroup; children = {array([app_group, products])}; sourceTree = "<group>";')
package = add("local-package", 'isa = XCLocalSwiftPackageReference; relativePath = ".";')
dependency = add("core-product", f'isa = XCSwiftPackageProductDependency; package = {package}; productName = FreeReadingCore;')
linked = add("linked-core", f'isa = PBXBuildFile; productRef = {dependency};')
phases = []
for name, isa, builds in [("sources", "PBXSourcesBuildPhase", source_builds), ("frameworks", "PBXFrameworksBuildPhase", [linked]), ("resources", "PBXResourcesBuildPhase", resource_builds)]:
    phases.append(add(name, f'isa = {isa}; buildActionMask = 2147483647; files = {array(builds)}; runOnlyForDeploymentPostprocessing = 0;'))

def settings(values):
    return "{ " + " ".join(f"{key} = {quote(value)};" for key, value in values.items()) + " }"

project_configs, target_configs = [], []
for config in ("Debug", "Release"):
    project_settings = {
        "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0",
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_ANALYZER_NONNULL": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym",
    }
    if config == "Debug":
        project_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) DEBUG"
        project_settings["ONLY_ACTIVE_ARCH"] = "YES"
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
    project_configs.append(add("project-config:" + config, f'isa = XCBuildConfiguration; buildSettings = {settings(project_settings)}; name = {config};'))
    target_configs.append(add("target-config:" + config, f'isa = XCBuildConfiguration; buildSettings = {settings(target_settings)}; name = {config};'))

project_config_list = add("project-configs", f'isa = XCConfigurationList; buildConfigurations = {array(project_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target_config_list = add("target-configs", f'isa = XCConfigurationList; buildConfigurations = {array(target_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = add("target", f'isa = PBXNativeTarget; buildConfigurationList = {target_config_list}; buildPhases = {array(phases)}; buildRules = (); dependencies = (); name = FreeReading; packageProductDependencies = {array([dependency])}; productName = FreeReading; productReference = {app}; productType = "com.apple.product-type.application";')
project = add("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {target} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {project_config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (en, Base, "zh-Hans"); mainGroup = {main_group}; packageReferences = {array([package])}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {array([target])};')
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
