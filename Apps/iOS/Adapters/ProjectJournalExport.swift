import Foundation
import AtlasCore

/// Validates project-owned journals without changing their original coordinates
/// or serializing their observations again. One bounded source is held at a time.
enum ProjectJournalExport {
    static let maximumModelBytes = 4 * 1_024 * 1_024
    static let maximumStationBytes = 16 * 1_024 * 1_024
    static let maximumModelFiles = 2_000
    static let maximumTeamPlanBytes = 16 * 1_024 * 1_024
    static let maximumAssemblyBytes = 8 * 1_024 * 1_024

    struct File: Sendable {
        let sourceURL: URL
        let managedRelativePath: String
        let archiveRelativePath: String
        let data: Data
        var byteCount: Int64 { Int64(data.count) }
        var sha256: String { FieldTransferDigest.sha256(data) }
    }

    private struct ModelDocument: Decodable {
        let schemaVersion: Int
        let projectID: UUID
        let sourceSHA256: String
        let revision: Int64
        let observations: [ModelObservation]
    }
    private struct ModelObservation: Decodable {
        let id: UUID
        let createdAt: Date
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

    // Foundation-only mirrors keep export validation available independently of
    // actors or UI state. Bytes are never reserialized for transfer/archive.
    private struct RevisionStamp: Decodable {
        let revision: Int64; let planSHA256: String; let parentSHA256: String?
    }
    private struct TeamDocument: Decodable {
        let schemaVersion: Int; let projectID: UUID; let sourceFeatureID: UUID
        let sourceFeatureRevision: Int64; let projectName: String?; let projectKind: ProjectKind?
        let plan: CollaborativeSurveyPlan
        let revisionStamps: [RevisionStamp]
    }
    private struct AssemblyBinding: Decodable {
        let source: FragmentSourceReference; let relativePath: String
        let byteCount: Int64; let capturedAt: Date; let gravityAlignedYUp: Bool
    }
    private struct AssemblyDocument: Decodable {
        let schemaVersion: Int; let projectID: UUID; let registry: FragmentRegistrationRegistry
        let sourceBindings: [AssemblyBinding]
    }

    static func forEachFile(project: AtlasProject, assetDirectory: URL, availableScans: [ScanRecord]? = nil,
                            _ consume: (File) throws -> Void) throws {
        guard assetDirectory.isFileURL else { throw ProjectJournalExportError.invalidPath }
        let root = assetDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let projectPrefix = "Projects/" + project.id.uuidString + "/"
        let models = projectPrefix + "ModelMeasurements"
        if let directory = try existingPath(models, root: root, directory: true) {
            var enumerationError: Error?
            guard let files = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in enumerationError = error; return false }) else {
                throw ProjectJournalExportError.invalidPath
            }
            var count = 0
            for case let file as URL in files {
                try Task.checkCancellation()
                count += 1
                guard count <= maximumModelFiles else { throw ProjectJournalExportError.tooLarge }
                let name = file.lastPathComponent
                guard name.hasSuffix(".json") else { throw ProjectJournalExportError.invalidDocument }
                let source = String(name.dropLast(5))
                guard FieldTransferDigest.isSHA256(source) else { throw ProjectJournalExportError.invalidDocument }
                let relative = models + "/" + name
                guard let safe = try existingPath(relative, root: root, directory: false) else {
                    throw ProjectJournalExportError.sourceChanged
                }
                let data = try readBounded(safe, maximum: maximumModelBytes)
                try validateModel(data, projectID: project.id, sourceSHA256: source)
                try consume(File(sourceURL: safe, managedRelativePath: relative,
                    archiveRelativePath: "ModelMeasurements/" + name, data: data))
            }
            if let enumerationError { throw enumerationError }
        }
        let stations = projectPrefix + "Captures/StationSurvey"
        if let directory = try existingPath(stations, root: root, directory: true) {
            let expected = project.id.uuidString + ".station-survey.json"
            // This directory contains one project document, including all raw
            // observations. Reject foreign names rather than silently omitting them.
            var enumerationError: Error?
            guard let files = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in enumerationError = error; return false }) else {
                throw ProjectJournalExportError.invalidPath
            }
            var count = 0
            for case let file as URL in files {
                try Task.checkCancellation()
                count += 1
                guard count == 1, file.lastPathComponent == expected else {
                    throw ProjectJournalExportError.invalidDocument
                }
                let relative = stations + "/" + expected
                guard let safe = try existingPath(relative, root: root, directory: false) else {
                    throw ProjectJournalExportError.sourceChanged
                }
                let data = try readBounded(safe, maximum: maximumStationBytes)
                let survey = try JSONDecoder().decode(StationSurvey.self, from: data)
                guard survey.projectID == project.id, survey.coordinateReference == project.coordinateReference else {
                    throw ProjectJournalExportError.invalidDocument
                }
                try survey.validate()
                try consume(File(sourceURL: safe, managedRelativePath: relative,
                    archiveRelativePath: "Captures/StationSurvey/" + expected, data: data))
            }
            if let enumerationError { throw enumerationError }
        }
        let collaboration = projectPrefix + "Captures/Collaboration"
        if let directory = try existingPath(collaboration, root: root, directory: true) {
            let teamName = project.id.uuidString + ".team-plan.json"
            let assemblyName = project.id.uuidString + ".assembly.json"
            var enumerationError: Error?
            guard let files = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in enumerationError = error; return false }) else {
                throw ProjectJournalExportError.invalidPath
            }
            var count = 0
            for case let file as URL in files {
                try Task.checkCancellation(); count += 1
                let name = file.lastPathComponent
                guard count <= 2, name == teamName || name == assemblyName else { throw ProjectJournalExportError.invalidDocument }
                let relative = collaboration + "/" + name
                guard let safe = try existingPath(relative, root: root, directory: false) else { throw ProjectJournalExportError.sourceChanged }
                let data = try readBounded(safe, maximum: name == teamName ? maximumTeamPlanBytes : maximumAssemblyBytes)
                if name == teamName { try validateTeam(data, project: project, root: root, availableScans: availableScans) }
                else { try validateAssembly(data, projectID: project.id, root: root) }
                try consume(File(sourceURL: safe, managedRelativePath: relative,
                    archiveRelativePath: "Captures/Collaboration/" + name, data: data))
            }
            if let enumerationError { throw enumerationError }
        }
    }

    /// Passport hashes refer to these exact ZIP names and original bytes.
    /// Missing, added or concurrently changed journals invalidate the archive.
    static func archiveEntries(project: AtlasProject, assetDirectory: URL,
                               passportAssets: [FieldAsset], availableScans: [ScanRecord]? = nil) throws -> [AtlasArchiveEntry] {
        let expected = passportAssets.filter {
            $0.relativePath.hasPrefix("ModelMeasurements/") || $0.relativePath.hasPrefix("Captures/StationSurvey/") ||
            $0.relativePath.hasPrefix("Captures/Collaboration/")
        }
        guard Set(expected.map(\.relativePath)).count == expected.count else {
            throw AtlasArchiveError.duplicatePath("project-journals")
        }
        var entries: [AtlasArchiveEntry] = []
        try forEachFile(project: project, assetDirectory: assetDirectory, availableScans: availableScans) { file in
            guard let asset = expected.first(where: { $0.relativePath == file.archiveRelativePath }),
                  asset.materialID == project.id, asset.kind == .metadata,
                  asset.byteCount == file.byteCount, asset.sha256 == file.sha256 else {
                throw AtlasArchiveError.sourceChanged(file.archiveRelativePath)
            }
            entries.append(AtlasArchiveEntry(relativePath: file.archiveRelativePath,
                fileURL: file.sourceURL, expectedSHA256: asset.sha256))
        }
        guard Set(entries.map(\.relativePath)) == Set(expected.map(\.relativePath)) else {
            throw AtlasArchiveError.sourceChanged("project-journals")
        }
        return entries
    }

    private static func validateTeam(_ data: Data, project: AtlasProject, root: URL, availableScans: [ScanRecord]?) throws {
        let document = try JSONDecoder().decode(TeamDocument.self, from: data)
        try document.plan.validate()
        guard document.schemaVersion == 1, document.projectID == project.id,
              document.plan.projectID == project.id, document.plan.coordinateReference == project.coordinateReference,
              document.sourceFeatureRevision >= 0, document.plan.revision <= 12_000,
              document.projectName == nil || (document.projectName!.utf8.count <= 240 && !document.projectName!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              document.revisionStamps.count == Int(document.plan.revision) + 1 else {
            throw ProjectJournalExportError.invalidDocument
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard document.revisionStamps.last?.planSHA256 == FieldTransferDigest.sha256(try encoder.encode(document.plan)) else {
            throw ProjectJournalExportError.invalidDocument
        }
        for (index, stamp) in document.revisionStamps.enumerated() {
            guard stamp.revision == Int64(index), FieldTransferDigest.isSHA256(stamp.planSHA256),
                  stamp.parentSHA256 == (index == 0 ? nil : document.revisionStamps[index - 1].planSHA256) else {
                throw ProjectJournalExportError.invalidDocument
            }
        }
        try validatePresentTeamSources(document.plan, projectID: project.id, root: root, availableScans: availableScans)
        // A JSON-only exchange may carry a colleague's declarations before their
        // originals arrive. The archive passport explicitly lists available bytes;
        // those remote references are retained, never fabricated as local files.
    }

    private struct PhotoSourceDocument: Decodable {
        let id: UUID; let projectID: UUID; let relativePath: String; let metadataPath: String
        let byteCount: Int; let sha256: String; let cameraFrameID: UUID?
    }
    private static func validatePresentTeamSources(_ plan: CollaborativeSurveyPlan, projectID: UUID,
                                                 root: URL, availableScans: [ScanRecord]?) throws {
        let scans = availableScans ?? []
        guard Set(scans.map(\.id)).count == scans.count else { throw ProjectJournalExportError.invalidDocument }
        let localScans = Dictionary(uniqueKeysWithValues: scans.map { ($0.id, $0) })
        let prefix = "Projects/" + projectID.uuidString + "/Captures/"
        var hashes = [String: String]()
        for item in plan.evidence where item.kind == .captureObserved {
            try Task.checkCancellation()
            guard let captureID = item.captureID, let expectedHash = item.sourceSHA256 else { throw ProjectJournalExportError.invalidDocument }
            if let scan = localScans[captureID] {
                guard scan.projectID == projectID, scan.status == .ready,
                      item.sourceFrameID == nil || item.sourceFrameID == scan.frameID else { throw ProjectJournalExportError.invalidDocument }
                var matched = false
                for asset in scan.assets where [.image, .video, .mesh, .roomPlanJSON].contains(asset.kind) {
                    guard asset.relativePath.hasPrefix(prefix), asset.byteCount > 0,
                          asset.byteCount <= 512 * 1_024 * 1_024 else { throw ProjectJournalExportError.invalidDocument }
                    if let declared = asset.sha256, declared.lowercased() != expectedHash { continue }
                    guard let safe = try existingPath(asset.relativePath, root: root, directory: false) else { throw ProjectJournalExportError.sourceChanged }
                    let actual: String
                    if let cached = hashes[asset.relativePath] { actual = cached }
                    else {
                        actual = try hashBoundedSource(safe, byteCount: asset.byteCount)
                        hashes[asset.relativePath] = actual
                    }
                    if actual == expectedHash { matched = true; break }
                }
                guard matched else { throw ProjectJournalExportError.sourceChanged }
            } else {
                let metadataPath = prefix + "evidence/" + captureID.uuidString + ".json"
                guard let metadata = try existingPath(metadataPath, root: root, directory: false) else { continue }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let photo = try decoder.decode(PhotoSourceDocument.self, from: readBounded(metadata, maximum: 2 * 1_024 * 1_024))
                guard photo.id == captureID, photo.projectID == projectID,
                      photo.metadataPath == "evidence/" + captureID.uuidString + ".json",
                      photo.relativePath.hasPrefix("evidence/" + captureID.uuidString + "."),
                      photo.relativePath.split(separator: "/").count == 2,
                      photo.byteCount > 0, photo.byteCount <= 100 * 1_024 * 1_024,
                      photo.sha256.lowercased() == expectedHash,
                      item.sourceFrameID == nil || item.sourceFrameID == photo.cameraFrameID,
                      let source = try existingPath(prefix + photo.relativePath, root: root, directory: false) else {
                    throw ProjectJournalExportError.invalidDocument
                }
                let relative = prefix + photo.relativePath
                if let cached = hashes[relative] {
                    guard cached == expectedHash else { throw ProjectJournalExportError.sourceChanged }
                } else {
                    let actual = try hashBoundedSource(source, byteCount: Int64(photo.byteCount))
                    guard actual == expectedHash else { throw ProjectJournalExportError.sourceChanged }
                    hashes[relative] = actual
                }
            }
        }
    }

    private static func hashBoundedSource(_ source: URL, byteCount: Int64) throws -> String {
        let before = try FileManager.default.attributesOfItem(atPath: source.path)
        guard (before[.size] as? NSNumber)?.int64Value == byteCount else { throw ProjectJournalExportError.sourceChanged }
        let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
        var hash = FieldTransferDigest.Stream(), readBytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation(); readBytes += Int64(chunk.count)
            guard readBytes <= byteCount else { throw ProjectJournalExportError.sourceChanged }
            hash.update(chunk)
        }
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        guard readBytes == byteCount, (after[.size] as? NSNumber)?.int64Value == byteCount,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber else {
            throw ProjectJournalExportError.sourceChanged
        }
        return hash.finalize()
    }

    private static func validateAssembly(_ data: Data, projectID: UUID, root: URL) throws {
        let document = try JSONDecoder().decode(AssemblyDocument.self, from: data)
        try document.registry.validate()
        guard document.schemaVersion == 1, document.projectID == projectID,
              document.registry.projectID == projectID,
              !document.sourceBindings.isEmpty, document.sourceBindings.count <= 128,
              document.sourceBindings.map(\.source) == document.registry.fragments,
              Set(document.sourceBindings.map(\.relativePath)).count == document.sourceBindings.count else {
            throw ProjectJournalExportError.invalidDocument
        }
        let prefix = "Projects/" + projectID.uuidString + "/Captures/"
        for binding in document.sourceBindings {
            try Task.checkCancellation(); try binding.source.validate()
            guard binding.relativePath.hasPrefix(prefix), !binding.relativePath.hasPrefix(prefix + "Collaboration/"),
                  binding.relativePath.lowercased().hasSuffix(".obj"), binding.gravityAlignedYUp,
                  binding.byteCount > 0, binding.byteCount <= 64 * 1_024 * 1_024,
                  binding.capturedAt.timeIntervalSince1970.isFinite,
                  let safe = try existingPath(binding.relativePath, root: root, directory: false) else {
                throw ProjectJournalExportError.invalidDocument
            }
            let before = try FileManager.default.attributesOfItem(atPath: safe.path)
            guard (before[.size] as? NSNumber)?.int64Value == binding.byteCount else { throw ProjectJournalExportError.sourceChanged }
            let handle = try FileHandle(forReadingFrom: safe); defer { try? handle.close() }
            let header = try handle.read(upToCount: 256) ?? Data()
            let line = String(decoding: header, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
            guard line == "# Atlas ARKit mesh. metres. Y up. local frame " + binding.source.frameID.uuidString else {
                throw ProjectJournalExportError.invalidDocument
            }
            guard try FieldTransferDigest.sha256(fileURL: safe) == binding.source.sourceSHA256 else { throw ProjectJournalExportError.sourceChanged }
            let after = try FileManager.default.attributesOfItem(atPath: safe.path)
            guard (after[.size] as? NSNumber)?.int64Value == binding.byteCount,
                  before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                  before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber else {
                throw ProjectJournalExportError.sourceChanged
            }
        }
        for edge in document.registry.registrations {
            // Native ARKit originals have physically observed Y up. A source
            // cannot become approved by removing the gravity gate from JSON.
            if edge.state == .approved {
                guard let gravity = edge.candidate.gravityConstraint,
                      gravity.sourceUp == MetricPoint3D(x: 0, y: 1, z: 0),
                      gravity.targetUp == MetricPoint3D(x: 0, y: 1, z: 0),
                      gravity.maximumDeviationDegrees <= 5 else { throw ProjectJournalExportError.invalidDocument }
            }
        }
    }

    private static func existingPath(_ relative: String, root: URL, directory: Bool) throws -> URL? {
        try FieldTransferPaths.validate(relativePath: relative)
        var path = root
        let components = relative.split(separator: "/")
        for (index, component) in components.enumerated() {
            path.appendPathComponent(String(component))
            let values: [FileAttributeKey: Any]
            do { values = try FileManager.default.attributesOfItem(atPath: path.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return nil
            }
            let required: FileAttributeType = index == components.count - 1 && !directory ? .typeRegular : .typeDirectory
            guard values[.type] as? FileAttributeType == required,
                  path.standardizedFileURL.path == path.standardizedFileURL.resolvingSymlinksInPath().path else {
                throw ProjectJournalExportError.invalidPath
            }
        }
        return path
    }

    private static func readBounded(_ file: URL, maximum: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0,
              bytes.int64Value <= Int64(maximum) else { throw ProjectJournalExportError.tooLarge }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)), !chunk.isEmpty {
            try Task.checkCancellation()
            data.append(chunk)
            guard data.count <= maximum else { throw ProjectJournalExportError.tooLarge }
        }
        guard Int64(data.count) == bytes.int64Value else { throw ProjectJournalExportError.sourceChanged }
        return data
    }

    private static func validateModel(_ data: Data, projectID: UUID, sourceSHA256: String) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ModelDocument.self, from: data)
        guard document.schemaVersion == 1, document.projectID == projectID,
              document.sourceSHA256 == sourceSHA256, document.revision > 0,
              document.observations.count <= 2_000,
              Set(document.observations.map(\.id)).count == document.observations.count else {
            throw ProjectJournalExportError.invalidDocument
        }
        for value in document.observations {
            guard value.projectID == projectID, value.sourceSHA256 == sourceSHA256,
                  value.start.count == 3, value.end.count == 3,
                  (value.start + value.end).allSatisfy({ $0.isFinite && abs($0) <= 1_000_001 }),
                  value.value.isFinite, value.value >= 0, value.createdAt.timeIntervalSince1970.isFinite,
                  ["m", "model-unit"].contains(value.unit), value.context.positionNote.count <= 10_000,
                  value.context.role != .height || (value.gravityYKnown && value.unit == "m" && value.kind == .verticalDistance),
                  value.context.role != .surfaceHeight || value.kind == .distance else {
                throw ProjectJournalExportError.invalidDocument
            }
            let dx = value.end[0] - value.start[0], dy = value.end[1] - value.start[1], dz = value.end[2] - value.start[2]
            let expected: Double
            switch value.kind {
            case .distance: expected = sqrt(dx * dx + dy * dy + dz * dz)
            case .horizontalDistance: expected = hypot(dx, dz)
            case .verticalDistance: expected = abs(dy)
            }
            guard abs(expected - value.value) <= max(0.000_1, expected * 0.000_001) else {
                throw ProjectJournalExportError.invalidDocument
            }
        }
    }
}

private enum ProjectJournalExportError: LocalizedError {
    case invalidPath, invalidDocument, tooLarge, sourceChanged
    var errorDescription: String? {
        switch self {
        case .invalidPath: "Каталог журналов проекта содержит ссылку или недопустимый путь. Исходники сохранены."
        case .invalidDocument: "Журнал измерений, совместной съёмки или сборки относится к другому проекту либо повреждён. Исходники сохранены."
        case .tooLarge: "Журнал превышает безопасный лимит выгрузки. Исходники сохранены."
        case .sourceChanged: "Журнал изменился во время подготовки. Завершите измерение и повторите экспорт."
        }
    }
}
