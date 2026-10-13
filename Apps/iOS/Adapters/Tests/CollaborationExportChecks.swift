import Foundation
import AtlasCore

@main struct CollaborationExportChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func reject(_ message: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure("Expected rejection: " + message) } catch { checks += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collaboration-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID(), frame = UUID(), captureFrame = UUID(), captureID = UUID()
        let project = AtlasProject(id: projectID, name: "Field team", kind: .cemetery, coordinateReference: .localMeters(frameID: frame))
        let polygon = MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 20, y: 0), .init(x: 20, y: 20), .init(x: 0, y: 20)])
        let plan = try CollaborativeSurveyPlanner.create(projectID: projectID, boundary: .metricPolygon(polygon),
            workers: [.init(name: "One"), .init(name: "Two")], cellSizeMeters: 10)
        let path = "Projects/\(projectID.uuidString)/Captures/lidar-\(UUID().uuidString)/segments/\(captureID.uuidString)/model.obj"
        let source = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceBytes = Data("# Atlas ARKit mesh. metres. Y up. local frame \(captureFrame.uuidString)\nv 0 0 0\nv 4 0 0\nv 0 0 4\nf 1 2 3\n".utf8)
        try sourceBytes.write(to: source)
        let hash = FieldTransferDigest.sha256(sourceBytes)
        let scan = ScanRecord(id: captureID, projectID: projectID, source: .liDAR, status: .ready, frameID: captureFrame,
            assets: [.init(relativePath: path, kind: .mesh, byteCount: Int64(sourceBytes.count))])
        let actualLabel = String(repeating: "Ж", count: 160)
        var document = try CollaborativeSurveyStoredPlan(plan: plan, sourceFeatureID: UUID(), sourceFeatureRevision: 0,
            projectName: actualLabel, projectKind: .cemetery, sourceFeatureLabel: actualLabel, sourceFeatureCategory: .cemetery)
        var observed = plan
        try observed.recordEvidence(.init(workerID: plan.workers[0].id, kind: .captureObserved, timestamp: Date(),
            cellIDs: [plan.cells[0].id], captureID: captureID, sourceSHA256: hash,
            footprintProvenance: .operatorMapped, sourceFrameID: captureFrame, footprint: polygon, quality: .usable), expectedRevision: 0)
        try document.append(observed)
        let folder = root.appendingPathComponent("Projects/\(projectID.uuidString)/Captures/Collaboration")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let teamFile = folder.appendingPathComponent(projectID.uuidString + ".team-plan.json")
        let teamBytes = try CollaborativeSurveyStoredPlan.canonical(document)
        try teamBytes.write(to: teamFile)
        let reference = FragmentSourceReference(captureID: captureID, frameID: captureFrame, sourceSHA256: hash, sourceVersion: 1)
        let registry = try FragmentRegistrationRegistry(projectID: projectID, anchor: reference)
        let binding = FragmentAssemblySourceBinding(source: reference, relativePath: path, byteCount: Int64(sourceBytes.count), capturedAt: Date(), gravityAlignedYUp: true)
        let assembly = FragmentAssemblyDocument(schemaVersion: 1, projectID: projectID, registry: registry, sourceBindings: [binding])
        let assemblyFile = folder.appendingPathComponent(projectID.uuidString + ".assembly.json")
        let assemblyBytes = try FragmentAssemblyDocument.canonical(assembly)
        try assemblyBytes.write(to: assemblyFile)
        func collect(_ scans: [ScanRecord]? = [scan]) throws -> [ProjectJournalExport.File] {
            var files = [ProjectJournalExport.File]()
            try ProjectJournalExport.forEachFile(project: project, assetDirectory: root, availableScans: scans) { files.append($0) }
            return files
        }
        let files = try collect()
        check(files.count == 2, "both journals exported")
        check(files.first { $0.sourceURL == teamFile }?.data == teamBytes, "team bytes unchanged")
        check(files.first { $0.sourceURL == assemblyFile }?.data == assemblyBytes, "assembly bytes unchanged")
        let retainedTeamBytes = files.first { $0.sourceURL == teamFile }!.data
        let retainedDocument = try JSONDecoder().decode(CollaborativeSurveyStoredPlan.self, from: retainedTeamBytes)
        check(retainedDocument.sourceFeatureLabel == actualLabel && retainedDocument.projectName == actualLabel,
              "160 Cyrillic characters preserve the actual source and project names")
        check(retainedDocument.sourceFeatureCategory == .cemetery, "actual source category preserved, not inferred from geometry")
        var legacyTeam = try JSONSerialization.jsonObject(with: retainedTeamBytes) as! [String: Any]
        legacyTeam.removeValue(forKey: "sourceFeatureLabel"); legacyTeam.removeValue(forKey: "sourceFeatureCategory")
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacyTeam)
        let legacyDocument = try JSONDecoder().decode(CollaborativeSurveyStoredPlan.self, from: legacyBytes)
        try legacyDocument.validate()
        check(legacyDocument.sourceFeatureLabel == nil && legacyDocument.sourceFeatureCategory == nil,
              "legacy source metadata remains unknown")
        try legacyBytes.write(to: teamFile)
        check(try collect().first { $0.sourceURL == teamFile }?.data == legacyBytes, "legacy exact bytes remain exportable")
        try teamBytes.write(to: teamFile)
        check(files.allSatisfy { $0.archiveRelativePath.hasPrefix("Captures/Collaboration/") }, "archive path")
        let assets = files.map { FieldAsset(materialID: projectID, relativePath: $0.archiveRelativePath, mediaType: "application/json", byteCount: $0.byteCount, sha256: $0.sha256, kind: .metadata) }
        let passport = FieldDeliveryPassport(projectID: projectID, projectName: project.name, preparedAt: Date(),
            timeZoneIdentifier: "UTC", utcOffsetSeconds: 0,
            device: FieldCaptureDevice(model: "fixture", osVersion: "test", appVersion: "test"),
            preparedBy: nil, materials: [], assets: assets, notes: [])
        let assistantIndex = try AssistantProjectIndex(snapshot: AtlasProjectSnapshot(project: project), passport: passport)
        check(assistantIndex.collaborationJournals?.count == 2, "assistant identifies both exact journal files")
        check(assistantIndex.collaborationJournals?.allSatisfy { journal in
            assets.contains { $0.relativePath == journal.path && $0.sha256 == journal.sha256 && $0.byteCount == journal.byteCount }
        } == true, "assistant exact journal hashes and bytes")
        check(assistantIndex.collaborationJournals?.allSatisfy { $0.timestampEncoding.contains("2001-01-01") } == true, "explicit source date epoch")
        check(assistantIndex.interpretationRules.contains { $0.contains("not automatically the WGS84") }, "no false common-frame map alignment")
        check(assistantIndex.interpretationRules.contains { $0.contains("original is absent") }, "remote proof stays declared")
        var legacyIndex = try JSONSerialization.jsonObject(with: FieldTransferJSON.encode(assistantIndex)) as! [String: Any]
        legacyIndex.removeValue(forKey: "collaborationJournals")
        let decodedLegacy = try FieldTransferJSON.decode(AssistantProjectIndex.self, from: JSONSerialization.data(withJSONObject: legacyIndex))
        check(decodedLegacy.collaborationJournals == nil, "legacy assistant index remains readable")
        let entries = try ProjectJournalExport.archiveEntries(project: project, assetDirectory: root, passportAssets: assets, availableScans: [scan])
        check(entries.count == 2, "no duplicate journal entries")
        let zip = root.appendingPathComponent("collaboration.zip")
        try AtlasArchiveWriter.write(entries: entries, to: zip)
        check(FileManager.default.fileExists(atPath: zip.path), "real archive created")
        reject("missing passport journal") { _ = try ProjectJournalExport.archiveEntries(project: project, assetDirectory: root, passportAssets: Array(assets.dropFirst()), availableScans: [scan]) }
        try (sourceBytes + Data("x".utf8)).write(to: source)
        reject("changed local source") { _ = try collect() }
        try sourceBytes.write(to: source)
        try FileManager.default.removeItem(at: assemblyFile)
        try FileManager.default.removeItem(at: source)
        reject("missing declared local source") { _ = try collect() }
        let remote = try collect([])
        check(remote.count == 1 && remote[0].data == teamBytes, "remote absent original preserves declaration only")
        try sourceBytes.write(to: source)
        try assemblyBytes.write(to: assemblyFile)
        var wrongFrame = scan; wrongFrame.frameID = UUID()
        reject("wrong local source frame") { _ = try collect([wrongFrame]) }
        var tampered = try JSONSerialization.jsonObject(with: teamBytes) as! [String: Any]
        var stamps = tampered["revisionStamps"] as! [[String: Any]]
        stamps[stamps.count - 1]["planSHA256"] = String(repeating: "0", count: 64); tampered["revisionStamps"] = stamps
        try JSONSerialization.data(withJSONObject: tampered).write(to: teamFile)
        reject("team checksum mismatch") { _ = try collect() }
        try teamBytes.write(to: teamFile)
        var malformedOptional = try JSONSerialization.jsonObject(with: teamBytes) as! [String: Any]
        malformedOptional["projectName"] = String(repeating: "Ж", count: 161)
        try JSONSerialization.data(withJSONObject: malformedOptional).write(to: teamFile)
        reject("bounded optional project name") { _ = try collect() }
        malformedOptional["projectName"] = "Valid name"; malformedOptional["projectKind"] = "unrecognizedKind"
        try JSONSerialization.data(withJSONObject: malformedOptional).write(to: teamFile)
        reject("known optional project kind") { _ = try collect() }
        malformedOptional = try JSONSerialization.jsonObject(with: teamBytes) as! [String: Any]
        malformedOptional["sourceFeatureLabel"] = String(repeating: "Ж", count: 161)
        try JSONSerialization.data(withJSONObject: malformedOptional).write(to: teamFile)
        reject("source label exceeds actual 160 UTF16 limit") { _ = try collect() }
        malformedOptional["sourceFeatureLabel"] = " \n "
        try JSONSerialization.data(withJSONObject: malformedOptional).write(to: teamFile)
        reject("empty source label") { _ = try collect() }
        malformedOptional["sourceFeatureLabel"] = actualLabel; malformedOptional["sourceFeatureCategory"] = "unrecognizedFeatureCategory"
        try JSONSerialization.data(withJSONObject: malformedOptional).write(to: teamFile)
        reject("unknown source category must not be guessed") { _ = try collect() }
        try teamBytes.write(to: teamFile)
        try Data("# foreign header\n".utf8).write(to: source)
        reject("assembly native source header") { _ = try collect([]) }
        try sourceBytes.write(to: source)
        try Data(repeating: 32, count: ProjectJournalExport.maximumAssemblyBytes + 1).write(to: assemblyFile)
        reject("bounded assembly journal") { _ = try collect() }
        try assemblyBytes.write(to: assemblyFile)
        for invalidRevision in [Int64(-1), Int64.max] {
            var malformedAssembly = try JSONSerialization.jsonObject(with: assemblyBytes) as! [String: Any]
            var bindings = malformedAssembly["sourceBindings"] as! [[String: Any]]
            bindings[0]["catalogRevisionAtRegistration"] = invalidRevision
            malformedAssembly["sourceBindings"] = bindings
            try JSONSerialization.data(withJSONObject: malformedAssembly).write(to: assemblyFile)
            reject("invalid catalog metadata revision \(invalidRevision)") { _ = try collect() }
        }
        try assemblyBytes.write(to: assemblyFile)
        let unknown = folder.appendingPathComponent("unknown.json"); try Data("{}".utf8).write(to: unknown)
        reject("unrecognized collaboration document") { _ = try collect() }
        try FileManager.default.removeItem(at: unknown)
        // Keep the symlink target outside the journal directory so the test checks
        // the source path, not an unrecognized additional document.
        let external = root.appendingPathComponent("source-retained.obj"); try sourceBytes.write(to: external)
        try FileManager.default.removeItem(at: source); try FileManager.default.createSymbolicLink(at: source, withDestinationURL: external)
        reject("source symlink") { _ = try collect() }
        print("Collaboration export checks passed (\(checks) checks).")
    }
}
