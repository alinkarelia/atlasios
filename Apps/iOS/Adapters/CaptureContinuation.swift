import Foundation

struct CaptureContinuationRecord: Identifiable, Sendable {
    let id: UUID
    let manifestURL: URL
    let name: String
    let updatedAt: Date
    let segmentCount: Int
    let status: String
}

/// Reads only this project's managed capture folders. No mesh, image, or movie
/// is loaded to list sessions, and restoring never registers independent frames.
actor CaptureContinuationStore {
    func records(in outputDirectory: URL, projectID: UUID) -> [CaptureContinuationRecord] {
        guard let iterator = FileManager.default.enumerator(at: outputDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        var result: [CaptureContinuationRecord] = []
        var examined = 0
        for case let directory as URL in iterator {
            examined += 1
            guard examined <= 1_000 else { break }
            guard directory.lastPathComponent.hasPrefix("lidar-") else { continue }
            if let value = try? CaptureContinuationPolicy.validate(
                at: directory.appendingPathComponent("manifest.json"), projectID: projectID,
                outputDirectory: outputDirectory) {
                result.append(value)
            }
        }
        return Array(result.sorted { $0.updatedAt > $1.updatedAt }.prefix(100))
    }
}

enum CaptureContinuationPolicy {
    enum ValidationError: LocalizedError {
        case invalid
        var errorDescription: String? {
            "Не удалось открыть эту съёмку: проверьте проект и сохранность исходных файлов. Оригиналы не изменены."
        }
    }

    private struct Index: Decodable {
        struct Segment: Decodable {
            let id: UUID
            let frameID: UUID
            let startedAt: Date
            let endedAt: Date?
        }
        let schemaVersion: Int
        let source: String
        let id: UUID
        let projectID: UUID
        let projectName: String
        let createdAt: Date
        let updatedAt: Date
        let status: String
        let segments: [Segment]
        let completedAssets: [String]
    }

    static func validate(at manifestURL: URL, projectID: UUID,
                         outputDirectory: URL) throws -> CaptureContinuationRecord {
        guard manifestURL.isFileURL, outputDirectory.isFileURL,
              manifestURL.lastPathComponent == "manifest.json" else { throw ValidationError.invalid }
        let directory = manifestURL.deletingLastPathComponent().standardizedFileURL
        let managed = outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent().resolvingSymlinksInPath().path == managed.path else {
            throw ValidationError.invalid
        }
        try requireDirectory(directory)
        let bytes = try requireFile(manifestURL, maximumBytes: 2 * 1_024 * 1_024)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(Index.self, from: Data(contentsOf: manifestURL))
        guard bytes > 0, index.schemaVersion == 1, index.source == "ARKit.sceneReconstruction",
              index.projectID == projectID, directory.lastPathComponent == "lidar-\(index.id.uuidString)",
              index.createdAt.timeIntervalSince1970.isFinite, index.updatedAt.timeIntervalSince1970.isFinite,
              ["ready", "recording", "paused", "interrupted", "exporting"].contains(index.status),
              !index.segments.isEmpty, index.segments.count < 256,
              Set(index.segments.map(\.id)).count == index.segments.count,
              Set(index.segments.map(\.frameID)).count == index.segments.count,
              index.segments.allSatisfy({ segment in
                  segment.startedAt.timeIntervalSince1970.isFinite &&
                      segment.endedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= segment.startedAt }) != false
              }), Set(index.completedAssets).count == index.completedAssets.count,
              index.completedAssets.count <= index.segments.count * 3 else { throw ValidationError.invalid }
        let segmentDirectory = directory.appendingPathComponent("segments", isDirectory: true)
        if FileManager.default.fileExists(atPath: segmentDirectory.path) { try requireDirectory(segmentDirectory) }
        var allowed = Set<String>()
        for segment in index.segments {
            let relative = "segments/\(segment.id.uuidString)"
            let path = directory.appendingPathComponent(relative, isDirectory: true)
            if FileManager.default.fileExists(atPath: path.path) { try requireDirectory(path) }
            for leaf in ["model.obj", "video.mov", "video.json"] { allowed.insert("\(relative)/\(leaf)") }
            let meshes = path.appendingPathComponent("meshes", isDirectory: true)
            if FileManager.default.fileExists(atPath: meshes.path) { try requireDirectory(meshes) }
        }
        for asset in index.completedAssets {
            guard allowed.contains(asset) else { throw ValidationError.invalid }
            _ = try requireFile(directory.appendingPathComponent(asset), maximumBytes: nil)
            if asset.hasSuffix("/video.mov") {
                guard index.completedAssets.contains(String(asset.dropLast(3)) + "json") else {
                    throw ValidationError.invalid
                }
            } else if asset.hasSuffix("/video.json") {
                guard index.completedAssets.contains(String(asset.dropLast(4)) + "mov") else {
                    throw ValidationError.invalid
                }
            }
        }
        return CaptureContinuationRecord(id: index.id, manifestURL: manifestURL, name: index.projectName,
            updatedAt: index.updatedAt, segmentCount: index.segments.count, status: index.status)
    }

    /// An interrupted file's last metadata write is a conservative end bound.
    /// The next day's clock must never fabricate an overnight recording interval.
    static func conservativeEnd(startedAt: Date, lastSavedAt: Date) -> Date {
        max(startedAt, lastSavedAt)
    }

    static func requireFile(_ url: URL, maximumBytes: Int?) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, maximumBytes.map({ size <= $0 }) != false else {
            throw ValidationError.invalid
        }
        return size
    }

    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ValidationError.invalid }
    }
}
