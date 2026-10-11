import Foundation

@main
struct CaptureContinuationChecks {
    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-continuation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let managed = base.appendingPathComponent("Captures"), id = UUID(), project = UUID(), segment = UUID(), frame = UUID()
        let directory = managed.appendingPathComponent("lidar-\(id.uuidString)")
        let manifest = directory.appendingPathComponent("manifest.json")
        let source = directory.appendingPathComponent("segments/\(segment.uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let model = source.appendingPathComponent("model.obj")
        let original = Data("# completed original\nv 1 2 3\n".utf8)
        try original.write(to: model)
        let originalJSON: [String: Any] = [
            "schemaVersion": 1, "source": "ARKit.sceneReconstruction", "id": id.uuidString,
            "projectID": project.uuidString, "projectName": "Квартал 4", "status": "ready",
            "createdAt": "2026-10-10T10:00:00Z", "updatedAt": "2026-10-10T10:30:00Z",
            "segments": [["id": segment.uuidString, "frameID": frame.uuidString,
                          "startedAt": "2026-10-10T10:00:00Z", "endedAt": "2026-10-10T10:30:00Z"]],
            "completedAssets": ["segments/\(segment.uuidString)/model.obj"]
        ]
        func write(_ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: manifest, options: .atomic)
        }
        func valid() -> Bool {
            (try? CaptureContinuationPolicy.validate(at: manifest, projectID: project, outputDirectory: managed)) != nil
        }
        var assertions = 0
        func check(_ value: Bool, _ description: String) {
            precondition(value, description); assertions += 1
        }
        try write(originalJSON)
        let metadataBefore = try Data(contentsOf: manifest)
        let record = try CaptureContinuationPolicy.validate(at: manifest, projectID: project, outputDirectory: managed)
        check(record.id == id && record.name == "Квартал 4" && record.segmentCount == 1 && record.status == "ready", "Exact source identity is retained")
        let metadataAfter = try Data(contentsOf: manifest), originalAfter = try Data(contentsOf: model)
        check(metadataBefore == metadataAfter && originalAfter == original, "Listing and validation cannot mutate original sources")
        let records = await CaptureContinuationStore().records(in: managed, projectID: project)
        print("Continuation listing diagnostic: count=\(records.count), matchingID=\(records.first?.id == id), matchingFile=\(records.first?.manifestURL.resolvingSymlinksInPath().path == manifest.resolvingSymlinksInPath().path)")
        check(records.count == 1 && records.first?.id == id &&
            records.first?.manifestURL.resolvingSymlinksInPath().path == manifest.resolvingSymlinksInPath().path,
            "Only valid managed capture source identity and actual file are listed")
        let listedBytes = try Data(contentsOf: records[0].manifestURL)
        check(listedBytes == metadataBefore, "Enumerated source is the exact original file")
        let alias = base.appendingPathComponent("CapturesAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: managed)
        let aliasManifest = alias.appendingPathComponent("lidar-\(id.uuidString)/manifest.json")
        let aliasRecord = try CaptureContinuationPolicy.validate(at: aliasManifest, projectID: project, outputDirectory: alias)
        check(aliasRecord.id == id && aliasRecord.manifestURL.path == manifest.resolvingSymlinksInPath().path,
              "Filesystem aliases return one canonical source identity")
        let aliasBytes = try Data(contentsOf: aliasRecord.manifestURL)
        check(aliasBytes == metadataBefore, "Canonical alias opens the exact original without copying or mutation")
        let otherRecords = await CaptureContinuationStore().records(in: managed, projectID: UUID())
        check(otherRecords.isEmpty, "Other projects' scans are not offered")
        check((try? CaptureContinuationPolicy.validate(at: manifest, projectID: project, outputDirectory: base)) == nil, "Nested or external folders are not managed captures")
        for (field, value) in [("schemaVersion", 2 as Any), ("source", "RoomPlan" as Any),
                               ("status", "unknown" as Any), ("projectID", UUID().uuidString as Any),
                               ("id", UUID().uuidString as Any), ("segments", [] as Any),
                               ("updatedAt", "not a date" as Any)] {
            var modified = originalJSON; modified[field] = value; try write(modified)
            check(!valid(), "Reject unsupported or inconsistent \(field)")
        }
        var modified = originalJSON
        let firstSegment = (originalJSON["segments"] as! [[String: Any]])[0]
        modified["segments"] = [firstSegment, firstSegment]; try write(modified)
        check(!valid(), "Duplicate segment/frame identities are not independent sources")
        modified = originalJSON
        var reversed = firstSegment; reversed["endedAt"] = "2026-10-09T00:00:00Z"
        modified["segments"] = [reversed]; try write(modified)
        check(!valid(), "End time cannot precede start")
        for assets in [["../original.obj"], ["segments/\(UUID().uuidString)/model.obj"],
                       ["segments/\(segment.uuidString)/video.mov"], ["segments/\(segment.uuidString)/video.json"],
                       ["segments/\(segment.uuidString)/model.obj", "segments/\(segment.uuidString)/model.obj"]] {
            modified = originalJSON; modified["completedAssets"] = assets; try write(modified)
            check(!valid(), "No traversal, unknown segment, unpaired or duplicate completed assets")
        }
        try write(originalJSON)
        try FileManager.default.removeItem(at: model)
        try Data().write(to: model)
        check(!valid(), "Empty completed originals fail validation")
        try FileManager.default.removeItem(at: model)
        let external = base.appendingPathComponent("external.obj"); try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: model, withDestinationURL: external)
        check(!valid(), "Symbolic-link source cannot cross managed capture boundary")
        try FileManager.default.removeItem(at: model); try original.write(to: model)
        let priorDirectory = source.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: source, to: priorDirectory)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: priorDirectory)
        check(!valid(), "Symbolic-link segment directory is rejected")
        try FileManager.default.removeItem(at: source); try FileManager.default.moveItem(at: priorDirectory, to: source)
        try Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1).write(to: manifest)
        check(!valid(), "Manifest allocation is bounded before decoding")
        try write(originalJSON)
        check(valid(), "Unchanged original is still available after failed restore attempts")
        let start = Date(timeIntervalSince1970: 100), saved = Date(timeIntervalSince1970: 120)
        check(CaptureContinuationPolicy.conservativeEnd(startedAt: start, lastSavedAt: saved) == saved, "Reopening uses previous metadata timestamp rather than next day's wall clock")
        check(CaptureContinuationPolicy.conservativeEnd(startedAt: start, lastSavedAt: Date(timeIntervalSince1970: 90)) == start, "Conservative interval remains valid with clock change")
        print("Capture continuation: \(assertions) managed-path, identity, bounded metadata, independent-frame and original-preservation checks passed.")
    }
}
