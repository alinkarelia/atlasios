import Foundation
import AtlasCore

/// Validates project-owned journals without changing their original coordinates
/// or serializing their observations again. One bounded source is held at a time.
enum ProjectJournalExport {
    static let maximumModelBytes = 4 * 1_024 * 1_024
    static let maximumStationBytes = 16 * 1_024 * 1_024
    static let maximumModelFiles = 2_000

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

    static func forEachFile(project: AtlasProject, assetDirectory: URL,
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
    }

    /// Passport hashes refer to these exact ZIP names and original bytes.
    /// Missing, added or concurrently changed journals invalidate the archive.
    static func archiveEntries(project: AtlasProject, assetDirectory: URL,
                               passportAssets: [FieldAsset]) throws -> [AtlasArchiveEntry] {
        let expected = passportAssets.filter {
            $0.relativePath.hasPrefix("ModelMeasurements/") || $0.relativePath.hasPrefix("Captures/StationSurvey/")
        }
        guard Set(expected.map(\.relativePath)).count == expected.count else {
            throw AtlasArchiveError.duplicatePath("project-journals")
        }
        var entries: [AtlasArchiveEntry] = []
        try forEachFile(project: project, assetDirectory: assetDirectory) { file in
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
        case .invalidDocument: "Журнал измерений или точечной съёмки относится к другому проекту либо повреждён. Исходники сохранены."
        case .tooLarge: "Журнал превышает безопасный лимит выгрузки. Исходники сохранены."
        case .sourceChanged: "Журнал изменился во время подготовки. Завершите измерение и повторите экспорт."
        }
    }
}
