#!/usr/bin/env swift
import Foundation

struct ProjectCheckError: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProjectCheckError(description: message) }
}

func validateProject(at root: URL) throws {
    let data = try Data(contentsOf: root.appendingPathComponent("Atlas.xcodeproj/project.pbxproj"))
    var format = PropertyListSerialization.PropertyListFormat.openStep
    let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
    guard let document = decoded as? [String: Any],
          let objects = document["objects"] as? [String: [String: Any]],
          let projectID = document["rootObject"] as? String,
          let project = objects[projectID], project["isa"] as? String == "PBXProject" else {
        throw ProjectCheckError(description: "Invalid Xcode project object graph")
    }

    for (identifier, object) in objects {
        for key in ["fileRef", "productRef", "package", "buildConfigurationList", "productReference", "mainGroup", "productRefGroup", "target", "targetProxy", "containerPortal", "remoteGlobalIDString"] {
            if let reference = object[key] as? String {
                try require(objects[reference] != nil, "Dangling \(identifier).\(key): \(reference)")
            }
        }
        for key in ["files", "children", "buildConfigurations", "buildPhases", "targets", "packageReferences", "packageProductDependencies", "dependencies"] {
            if let references = object[key] as? [String] {
                for reference in references {
                    try require(objects[reference] != nil, "Dangling \(identifier).\(key): \(reference)")
                }
            }
        }
        if object["isa"] as? String == "PBXFileReference",
           object["sourceTree"] as? String == "SOURCE_ROOT", let path = object["path"] as? String {
            try require(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "Missing file: \(path)")
        }
    }

    guard let targetIDs = project["targets"] as? [String],
          let appID = targetIDs.first(where: { objects[$0]?["name"] as? String == "Atlas" }),
          let uiID = targetIDs.first(where: { objects[$0]?["name"] as? String == "AtlasUITests" }) else {
        throw ProjectCheckError(description: "Application and native UI-test targets must both exist")
    }
    try require(targetIDs.count == 2, "Unexpected extra native targets")
    try require(objects[appID]?["productType"] as? String == "com.apple.product-type.application", "Atlas must be an application target")
    try require(objects[uiID]?["productType"] as? String == "com.apple.product-type.bundle.ui-testing", "AtlasUITests must be a UI-testing bundle")

    func phasePaths(_ targetID: String, _ isa: String) throws -> Set<String> {
        guard let phaseIDs = objects[targetID]?["buildPhases"] as? [String],
              let phaseID = phaseIDs.first(where: { objects[$0]?["isa"] as? String == isa }),
              let phase = objects[phaseID],
              let buildIdentifiers = phase["files"] as? [String] else {
            throw ProjectCheckError(description: "Missing \(isa) for \(targetID)")
        }
        return try Set(buildIdentifiers.map { buildIdentifier in
            guard let build = objects[buildIdentifier], let reference = build["fileRef"] as? String,
                  let file = objects[reference], let path = file["path"] as? String else {
                throw ProjectCheckError(description: "Invalid build file: \(buildIdentifier)")
            }
            return path
        })
    }

    let sources = try phasePaths(appID, "PBXSourcesBuildPhase")
    let app = root.appendingPathComponent("Apps/iOS")
    guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) else {
        throw ProjectCheckError(description: "Cannot enumerate native source directory")
    }
    let expectedSources = Set(enumerator.compactMap { item -> String? in
        guard let url = item as? URL, url.pathExtension == "swift",
              !url.pathComponents.contains("Tests"), !url.pathComponents.contains("UITests"),
              !url.pathComponents.contains("Business"), !url.pathComponents.contains("Subscription"),
              url.lastPathComponent != "PurchaseService.swift",
              !url.pathComponents.contains(where: { $0.hasPrefix(".") }) else { return nil }
        return String(url.path.dropFirst(root.path.count + 1))
    })
    try require(!sources.isEmpty, "Native app has no compiled Swift sources")
    try require(sources == expectedSources, "Source membership differs; regenerate the Xcode project. Missing: \(expectedSources.subtracting(sources).sorted()); extra: \(sources.subtracting(expectedSources).sorted())")

    let uiSources = try phasePaths(uiID, "PBXSourcesBuildPhase")
    let expectedUI = Set(expectedNativeUITestSources(at: app.appendingPathComponent("UITests"), relativeTo: root))
    try require(!uiSources.isEmpty && uiSources == expectedUI, "UI-test source membership differs from Apps/iOS/UITests")
    try require(sources.isDisjoint(with: uiSources), "UI tests must not compile into the shipping application")
    try require(try phasePaths(uiID, "PBXResourcesBuildPhase").isEmpty, "UI-test resources must not duplicate application resources")
    guard let uiConfigList = objects[uiID]?["buildConfigurationList"] as? String,
          let uiConfigs = objects[uiConfigList]?["buildConfigurations"] as? [String] else {
        throw ProjectCheckError(description: "Missing UI-test build configurations")
    }
    for config in uiConfigs {
        guard let settings = objects[config]?["buildSettings"] as? [String: Any] else {
            throw ProjectCheckError(description: "Invalid UI-test settings")
        }
        try require(settings["TEST_TARGET_NAME"] as? String == "Atlas", "UI tests must launch the actual Atlas application")
        try require(settings["GENERATE_INFOPLIST_FILE"] as? String == "YES", "UI bundle requires a generated Info.plist")
    }
    let uiDependencies = objects[uiID]?["dependencies"] as? [String] ?? []
    try require(uiDependencies.contains(where: { objects[$0]?["target"] as? String == appID }), "UI-test bundle must depend on the actual app target")
    let resources = try phasePaths(appID, "PBXResourcesBuildPhase")
    try require(resources.contains("Apps/iOS/Resources/Assets.xcassets"), "Asset catalog is not bundled")
    try require(resources.contains("Apps/iOS/Resources/PrivacyInfo.xcprivacy"), "Privacy manifest is not bundled")
    try require(!resources.contains("Apps/iOS/Info.plist"), "Info.plist must not be copied as a resource")
    try require(!resources.contains(where: { $0.contains("/Tests/") || $0.contains("/UITests/") || $0.hasSuffix(".swift") }), "Test or Swift files were bundled as resources")
    let package = objects.values.first { $0["isa"] as? String == "XCLocalSwiftPackageReference" }
    try require(package?["relativePath"] as? String == "Packages/AtlasCore", "Local AtlasCore package is missing")

    let infoData = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
    let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
    try require(info?["NSCameraUsageDescription"] as? String != nil, "Missing camera permission explanation")
    guard let callbackTypes = info?["CFBundleURLTypes"] as? [[String: Any]],
          callbackTypes.count == 1,
          callbackTypes[0]["CFBundleURLName"] as? String == "com.atlasfield.family-archive",
          callbackTypes[0]["CFBundleURLSchemes"] as? [String] == ["archiverf-atlas"] else {
        throw ProjectCheckError(description: "Family Archive sign-in requires the exact archiverf-atlas callback URL scheme")
    }
    try require(info?["UIRequiredDeviceCapabilities"] == nil && info?["UIRequiresPersistentWiFi"] == nil,
                "Manual tools must remain installable on devices without LiDAR")
    let scheme = try String(contentsOf: root.appendingPathComponent("Atlas.xcodeproj/xcshareddata/xcschemes/AtlasUITests.xcscheme"), encoding: .utf8)
    try require(scheme.contains("BlueprintIdentifier=\"\(uiID)\"") && scheme.contains("TestableReference"), "Shared UI-test scheme must include the UI-test bundle")
    print("Xcode graph is valid: \(objects.count) objects, \(sources.count) native Swift sources, \(uiSources.count) UI-test sources, \(resources.count) resources. This checks project membership, not iOS type checking.")
}

func expectedNativeUITestSources(at directory: URL, relativeTo root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { item in
        guard let url = item as? URL, url.pathExtension == "swift",
              !url.pathComponents.contains(where: { $0.hasPrefix(".") }) else { return nil }
        return String(url.path.dropFirst(root.path.count + 1))
    }
}

do {
    let root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        .deletingLastPathComponent().deletingLastPathComponent()
    try validateProject(at: root)
} catch {
    FileHandle.standardError.write(Data("Project validation failed: \(error)\n".utf8))
    exit(1)
}
