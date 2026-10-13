import AtlasCore
import Foundation

/// Coordinates refer to the unchanged source mesh, before viewer recentering.
/// This is a model reading, with explicitly known or unknown units, not an AR fix.
struct MeshDimensionObservation: Codable, Identifiable, Sendable {
    var id = UUID()
    var createdAt = Date()
    let sourceSHA256: String
    let projectID: UUID?
    let frameID: UUID?
    let start: [Double]
    let end: [Double]
    let kind: MeasurementKind
    let context: MeasurementContext
    let value: Double
    let unit: String
    let gravityYKnown: Bool
}

struct MeshDimensionSource: Sendable {
    let sha256: String
    let frameID: UUID?
    let metresKnown: Bool
    let gravityYKnown: Bool

    static func inspect(_ url: URL, atlasOBJ: Bool) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = FieldTransferDigest.Stream(), count = 0, prefix = Data()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation(); count += data.count
            guard count <= OBJPreviewLoader.maximumBytes else { throw OBJPreviewError.limit }
            if prefix.isEmpty { prefix = Data(data.prefix(1_024)) }
            hash.update(data)
        }
        var frame: UUID?, metres = false, gravity = false
        let declaration = String(decoding: prefix, as: UTF8.self).split(separator: "\n")
            .compactMap { OBJMetricFrameHeader.parse(String($0)) }.first
        // The exact derivative header declares its anchor frame independently
        // of the original-capture flag; never relabel it as a captured original.
        if let declaration, atlasOBJ || declaration.origin == .alignedDerivative {
            frame = declaration.frameID; metres = true; gravity = true
        } else if !atlasOBJ, url.lastPathComponent == "room.usdz" {
            let manifest = url.deletingLastPathComponent().appendingPathComponent("manifest.json")
            if let values = try? manifest.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 2 * 1_024 * 1_024,
               let data = try? Data(contentsOf: manifest),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["source"] as? String == "RoomPlan", object["schemaVersion"] as? Int == 1,
               (object["completedAssets"] as? [String])?.contains("room.usdz") == true,
               let raw = object["frameID"] as? String, let knownFrame = UUID(uuidString: raw) {
                frame = knownFrame; metres = true; gravity = true
            }
        }
        return .init(sha256: hash.finalize(), frameID: frame,
                     metresKnown: metres, gravityYKnown: gravity)
    }
}

actor MeshMeasurementJournal {
    // Separate viewer instances share one process-wide CAS transaction boundary.
    // This lock is used only by synchronous actor work, never by the UI actor.
    private static let transactionLock = NSLock()
    private struct Document: Codable { var schemaVersion = 1; let projectID: UUID; let sourceSHA256: String; var revision: Int64; var observations: [MeshDimensionObservation] }
    private let directory: URL?
    private let projectID: UUID?
    private var expectedRevisions: [String: Int64] = [:]
    init(directory: URL?, projectID: UUID?) { self.directory = directory; self.projectID = projectID }
    private func url(for hash: String) throws -> URL {
        guard FieldTransferDigest.isSHA256(hash), let directory, let projectID,
              directory.isFileURL, directory.lastPathComponent == "ModelMeasurements",
              directory.deletingLastPathComponent().lastPathComponent == projectID.uuidString else { throw OBJPreviewError.invalidMesh }
        let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent().standardizedFileURL == parent else { throw OBJPreviewError.invalidMesh }
        guard try FileManager.default.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType == .typeDirectory else { throw OBJPreviewError.invalidMesh }
        let root = parent.appendingPathComponent("ModelMeasurements", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            guard try FileManager.default.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else { throw OBJPreviewError.invalidMesh }
        } else { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
        return root.appendingPathComponent(hash + ".json")
    }
    func load(source: String) throws -> [MeshDimensionObservation] {
        let document = try read(source: source)
        expectedRevisions[source] = document?.revision ?? 0
        return document?.observations ?? []
    }
    /// Returns a project-scoped regular file only after validating the complete
    /// bounded envelope, original endpoints, units and every observation.
    /// Exporters must still hash the returned bytes for their own provenance.
    func verifiedExportFile(source: String) throws -> URL {
        guard try read(source: source) != nil else { throw OBJPreviewError.invalidMesh }
        return try url(for: source)
    }
    private func read(source: String) throws -> Document? {
        let file = try url(for: source)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 4 * 1_024 * 1_024 else { throw OBJPreviewError.limit }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: Data(contentsOf: file))
        guard document.schemaVersion == 1, document.projectID == projectID, document.revision > 0,
              document.sourceSHA256 == source, document.observations.count <= 2_000,
              Set(document.observations.map(\.id)).count == document.observations.count,
              document.observations.allSatisfy({ valid($0, source: source) }) else { throw OBJPreviewError.invalidMesh }
        return document
    }
    func append(_ observation: MeshDimensionObservation) throws -> [MeshDimensionObservation] {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        guard let projectID, valid(observation, source: observation.sourceSHA256) else { throw OBJPreviewError.invalidMesh }
        let previous = try read(source: observation.sourceSHA256)
        let revision = previous?.revision ?? 0
        guard expectedRevisions[observation.sourceSHA256] == revision, revision < Int64.max else { throw MeshJournalError.concurrentEdit }
        var records = previous?.observations ?? []
        guard records.count < 2_000, !records.contains(where: { $0.id == observation.id }) else { throw OBJPreviewError.limit }
        records.append(observation)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Document(projectID: projectID, sourceSHA256: observation.sourceSHA256, revision: revision + 1, observations: records))
        guard bytes.count <= 4 * 1_024 * 1_024 else { throw OBJPreviewError.limit }
        try bytes.write(to: url(for: observation.sourceSHA256), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        expectedRevisions[observation.sourceSHA256] = revision + 1
        return records
    }
    private func valid(_ value: MeshDimensionObservation, source: String) -> Bool {
        guard value.projectID == projectID, value.projectID != nil, value.sourceSHA256 == source,
              value.start.count == 3, value.end.count == 3,
              (value.start + value.end).allSatisfy({ $0.isFinite && abs($0) <= 1_000_001 }),
              value.value.isFinite, value.value >= 0, value.createdAt.timeIntervalSince1970.isFinite,
              ["m", "model-unit"].contains(value.unit), value.context.positionNote.count <= 10_000,
              value.context.role != .height || (value.gravityYKnown && value.unit == "m" && value.kind == .verticalDistance),
              value.context.role != .surfaceHeight || value.kind == .distance else { return false }
        let dx = value.end[0] - value.start[0], dy = value.end[1] - value.start[1], dz = value.end[2] - value.start[2]
        let expected: Double
        switch value.kind { case .distance: expected = sqrt(dx * dx + dy * dy + dz * dz); case .horizontalDistance: expected = hypot(dx, dz); case .verticalDistance: expected = abs(dy) }
        return abs(expected - value.value) <= max(0.000_1, expected * 0.000_001)
    }
}

private enum MeshJournalError: LocalizedError {
    case concurrentEdit
    var errorDescription: String? { "Журнал изменился в другом просмотре. Закройте и откройте модель; текущие точки остаются доступными." }
}
