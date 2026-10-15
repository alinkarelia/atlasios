#!/usr/bin/env python3
"""Семейный архив: Живая память — production remote-only AVELI Xcode project."""
import hashlib
import json
from pathlib import Path

ios = Path(__file__).resolve().parents[1]
# Preserve the supplied offline prototype in source, never compile/package it.
sources = sorted(f for f in (ios / 'AVELI' / 'App').glob('*.swift') if f.name != 'EmbeddedWebServer.swift')
if not sources:
    raise SystemExit('AVELI Swift source files are missing.')

def identifier(value):
    return hashlib.sha1(('aveli:' + value).encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(value, ensure_ascii=False)

objects = []
def add(name, value):
    objects.append(f'{identifier(name)} = {{ {value} }};')

for file in sources:
    add('ref:' + file.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(file.name)}; sourceTree = "<group>";')
    add('build:' + file.name, f'isa = PBXBuildFile; fileRef = {identifier("ref:" + file.name)};')

add('ref:assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = AVELI/Assets.xcassets; sourceTree = "<group>";')
add('build:assets', f'isa = PBXBuildFile; fileRef = {identifier("ref:assets")};')
add('ref:info', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = AVELI/Info.plist; sourceTree = "<group>";')
add('ref:product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = AVELI.app; sourceTree = BUILT_PRODUCTS_DIR;')
source_refs = ', '.join(identifier('ref:' + file.name) for file in sources)
source_builds = ', '.join(identifier('build:' + file.name) for file in sources)
add('group:app', f'isa = PBXGroup; children = ({source_refs},); path = AVELI/App; sourceTree = "<group>";')
add('group:products', f'isa = PBXGroup; children = ({identifier("ref:product")},); name = Products; sourceTree = "<group>";')
add('group:main', f'isa = PBXGroup; children = ({identifier("group:app")}, {identifier("ref:assets")}, {identifier("ref:info")}, {identifier("group:products")},); sourceTree = "<group>";')
add('phase:sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({source_builds},); runOnlyForDeploymentPostprocessing = 0;')
add('phase:resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({identifier("build:assets")},); runOnlyForDeploymentPostprocessing = 0;')
add('phase:frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')

common = {
    'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES',
    'SDKROOT': 'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0',
    'SWIFT_VERSION': '5.0', 'ENABLE_BITCODE': 'NO',
    'SWIFT_STRICT_CONCURRENCY': 'targeted',
}
target = {
    'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
    'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME': 'AccentColor',
    'CODE_SIGN_STYLE': 'Automatic', 'CURRENT_PROJECT_VERSION': '5',
    'MARKETING_VERSION': '1.0.4', 'GENERATE_INFOPLIST_FILE': 'NO',
    'INFOPLIST_FILE': 'AVELI/Info.plist',
    'PRODUCT_BUNDLE_IDENTIFIER': 'ru.archiverf.aveli',
    'PRODUCT_NAME': '$(TARGET_NAME)', 'TARGETED_DEVICE_FAMILY': '1,2',
    'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks',
    'SWIFT_EMIT_LOC_STRINGS': 'YES',
}
for scope in ['project', 'target']:
    for configuration in ['Debug', 'Release']:
        settings = dict(common)
        if scope == 'target':
            settings.update(target)
        if configuration == 'Debug':
            settings.update({'SWIFT_OPTIMIZATION_LEVEL': '-Onone', 'DEBUG_INFORMATION_FORMAT': 'dwarf', 'ENABLE_TESTABILITY': 'YES', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG'})
        else:
            settings.update({'SWIFT_OPTIMIZATION_LEVEL': '-O', 'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym', 'SWIFT_COMPILATION_MODE': 'wholemodule', 'VALIDATE_PRODUCT': 'YES'})
        encoded = ' '.join(f'{key} = {quote(value)};' for key, value in sorted(settings.items()))
        add(f'config:{scope}:{configuration}', f'isa = XCBuildConfiguration; buildSettings = {{ {encoded} }}; name = {configuration};')
    add(f'configs:{scope}', f'isa = XCConfigurationList; buildConfigurations = ({identifier(f"config:{scope}:Debug")}, {identifier(f"config:{scope}:Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

add('target', f'isa = PBXNativeTarget; buildConfigurationList = {identifier("configs:target")}; buildPhases = ({identifier("phase:sources")}, {identifier("phase:frameworks")}, {identifier("phase:resources")},); buildRules = (); dependencies = (); name = AVELI; productName = AVELI; productReference = {identifier("ref:product")}; productType = "com.apple.product-type.application";')
add('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {identifier("target")} = {{ CreatedOnToolsVersion = 16.0; ProvisioningStyle = Automatic; }}; }}; }}; buildConfigurationList = {identifier("configs:project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ru; hasScannedForEncodings = 0; knownRegions = (en, ru, Base,); mainGroup = {identifier("group:main")}; productRefGroup = {identifier("group:products")}; projectDirPath = ""; projectRoot = ""; targets = ({identifier("target")},);')
project = ios / 'AVELI.xcodeproj'
project.mkdir(exist_ok=True)
body = '// !$*UTF8*$!\n{\narchiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n' + '\n'.join(objects) + f'\n}};\nrootObject = {identifier("project")};\n}}\n'
(project / 'project.pbxproj').write_text(body)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier('target')}" BuildableName="AVELI.app" BlueprintName="AVELI" ReferencedContainer="container:AVELI.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier('target')}" BuildableName="AVELI.app" BlueprintName="AVELI" ReferencedContainer="container:AVELI.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier('target')}" BuildableName="AVELI.app" BlueprintName="AVELI" ReferencedContainer="container:AVELI.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
scheme_path = project / 'xcshareddata' / 'xcschemes'
scheme_path.mkdir(parents=True, exist_ok=True)
(scheme_path / 'AVELI.xcscheme').write_text(scheme)
print(f'Generated AVELI project with {len(sources)} Swift sources.')
