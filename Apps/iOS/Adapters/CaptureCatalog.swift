import Foundation
import AtlasCore

/// Reads the exact manifests written by CaptureCoordinator/RoomCaptureAdapter.
/// No geometry is inferred, registered, or moved into a project's coordinate
/// frame. References use paths relative to Atlas's managed app directory.
enum CaptureCatalog {
    static func records(at manifestURL: URL, relativeTo root: URL) throws -> [ScanRecord] {
        let managedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let manifestFile = try regularFile(manifestURL, within: managedRoot)
        guard manifestFile.byteCount <= 2 * 1_024 * 1_024 else { throw CatalogError.invalidManifest }
        let data = try Data(contentsOf: manifestFile.url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        guard header.schemaVersion == 1 else { throw CatalogError.unsupportedSchema }
        let captureRoot = manifestFile.url.deletingLastPathComponent()
        let status = try scanStatus(header.status)
        switch header.source {
        case "ARKit.sceneReconstruction":
            let manifest = try decoder.decode(LiDARManifest.self, from: data)
            guard !manifest.segments.isEmpty,
                  Set(manifest.segments.map(\.id)).count == manifest.segments.count,
                  Set(manifest.segments.map(\.frameID)).count == manifest.segments.count else {
                throw CatalogError.invalidManifest
            }
            let segmentPrefixes = Set(manifest.segments.map { "segments/\($0.id.uuidString)/model.obj" })
            guard manifest.completedAssets.allSatisfy(segmentPrefixes.contains) else { throw CatalogError.invalidAssetPath }
            var completed = [String: FileReference]()
            for path in manifest.completedAssets {
                completed[path] = try regularFile(try child(path, in: captureRoot), within: managedRoot)
            }
            if status == .ready && completed.isEmpty { throw CatalogError.invalidManifest }
            return try manifest.segments.map { segment in
                if let geoTag = segment.geoTag { try GeoTagPolicy.validate(geoTag) }
                var assets = [asset(manifestFile, kind: .cameraMetadata, namespace: segment.id, root: managedRoot)]
                let modelPath = "segments/\(segment.id.uuidString)/model.obj"
                if let model = completed[modelPath] { assets.append(asset(model, kind: .mesh, namespace: segment.id, root: managedRoot)) }
                let meshesRoot = captureRoot.appendingPathComponent("segments/\(segment.id.uuidString)/meshes", isDirectory: true)
                let meshes = try regularFiles(in: meshesRoot, within: managedRoot, suffix: ".mesh.json")
                assets += meshes.map { asset($0, kind: .mesh, namespace: segment.id, root: managedRoot) }
                assets += try photoAssets(projectID: manifest.projectID, frameID: segment.frameID,
                    captureRoot: captureRoot, namespace: segment.id, root: managedRoot)
                let segmentStatus: ScanStatus = status == .ready && completed[modelPath] == nil ? .interrupted : status
                return ScanRecord(id: segment.id, projectID: manifest.projectID, source: .liDAR,
                    status: segmentStatus, frameID: segment.frameID, assets: assets,
                    createdAt: segment.startedAt, revision: 0, geoTag: segment.geoTag)
            }
        case "RoomPlan":
            let manifest = try decoder.decode(RoomManifest.self, from: data)
            if let geoTag = manifest.geoTag { try GeoTagPolicy.validate(geoTag) }
            let permitted = Set(["room.json", "room-data.json", "room.usdz"])
            guard manifest.completedAssets.allSatisfy(permitted.contains) else { throw CatalogError.invalidAssetPath }
            var assets = [asset(manifestFile, kind: .cameraMetadata, namespace: manifest.id, root: managedRoot)]
            let paths = Set(manifest.completedAssets).union(permitted.filter { FileManager.default.fileExists(atPath: captureRoot.appendingPathComponent($0).path) })
            if status == .ready && !paths.isSuperset(of: ["room.json", "room.usdz"]) { throw CatalogError.invalidManifest }
            for path in paths.sorted() {
                let file = try regularFile(try child(path, in: captureRoot), within: managedRoot)
                assets.append(asset(file, kind: path.hasSuffix(".usdz") ? .mesh : .roomPlanJSON, namespace: manifest.id, root: managedRoot))
            }
            assets += try photoAssets(projectID: manifest.projectID, frameID: manifest.frameID,
                captureRoot: captureRoot, namespace: manifest.id, root: managedRoot)
            return [ScanRecord(id: manifest.id, projectID: manifest.projectID, source: .roomPlan,
                status: status, frameID: manifest.frameID, assets: assets, createdAt: manifest.createdAt,
                revision: 0, geoTag: manifest.geoTag)]
        case "ObjectCapture":
            let manifest = try decoder.decode(ObjectManifest.self, from: data)
            if let geoTag = manifest.geoTag { try GeoTagPolicy.validate(geoTag) }
            guard Set(manifest.images.map(\.relativePath)).count == manifest.images.count,
                  manifest.images.count <= 5_000 else { throw CatalogError.invalidManifest }
            let imagePaths = Set(manifest.images.map(\.relativePath))
            guard manifest.completedAssets.allSatisfy({ $0.hasPrefix("Images/") || $0 == manifest.modelRelativePath }),
                  imagePaths.isSubset(of: Set(manifest.completedAssets)),
                  status != .ready || !manifest.images.isEmpty else { throw CatalogError.invalidManifest }
            var assets = [asset(manifestFile, kind: .cameraMetadata, namespace: manifest.id, root: managedRoot)]
            for image in manifest.images {
                guard image.relativePath.hasPrefix("Images/"),
                      ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "dng"].contains(URL(fileURLWithPath: image.relativePath).pathExtension.lowercased()),
                      image.sha256.count == 64, image.sha256.allSatisfy(\.isHexDigit) else { throw CatalogError.invalidAssetPath }
                let file = try regularFile(try child(image.relativePath, in: captureRoot), within: managedRoot)
                guard file.byteCount == image.byteCount else { throw CatalogError.invalidManifest }
                assets.append(asset(file, kind: .image, namespace: manifest.id, root: managedRoot, sha256: image.sha256))
            }
            for path in Set(manifest.completedAssets).subtracting(imagePaths).sorted() where path.hasPrefix("Images/") {
                let file = try regularFile(try child(path, in: captureRoot), within: managedRoot)
                assets.append(asset(file, kind: .depth, namespace: manifest.id, root: managedRoot))
            }
            if let path = manifest.modelRelativePath {
                guard path == "object.usdz", manifest.completedAssets.contains(path) else { throw CatalogError.invalidAssetPath }
                assets.append(asset(try regularFile(try child(path, in: captureRoot), within: managedRoot),
                                    kind: .mesh, namespace: manifest.id, root: managedRoot))
            }
            return [ScanRecord(id: manifest.id, projectID: manifest.projectID, source: .photogrammetry,
                status: status, frameID: manifest.frameID, assets: assets, createdAt: manifest.createdAt,
                revision: 0, geoTag: manifest.geoTag)]
        default: throw CatalogError.unsupportedSource
        }
    }

    private static func scanStatus(_ value: String) throws -> ScanStatus {
        switch value {
        case "recording": .recording
        case "paused", "interrupted": .interrupted
        case "captured": .captured
        case "processing", "exporting": .processing
        case "ready": .ready
        case "failed": .failed
        default: throw CatalogError.invalidManifest
        }
    }

    private static func child(_ path: String, in parent: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\"),
              !components.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { throw CatalogError.invalidAssetPath }
        let url = parent.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(parent.standardizedFileURL.path + "/") else { throw CatalogError.invalidAssetPath }
        return url
    }

    private static func regularFile(_ input: URL, within root: URL) throws -> FileReference {
        guard input.isFileURL else { throw CatalogError.outsideManagedDirectory }
        let normalized = input.standardizedFileURL
        let canonical = normalized.resolvingSymlinksInPath()
        guard canonical.path.hasPrefix(root.path + "/") else { throw CatalogError.outsideManagedDirectory }
        let values = try normalized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, let bytes = values.fileSize, bytes >= 0 else {
            throw CatalogError.notRegularFile
        }
        return FileReference(url: canonical, byteCount: Int64(bytes))
    }

    private static func regularFiles(in directory: URL, within root: URL, suffix: String) throws -> [FileReference] {
        let normalized = directory.standardizedFileURL
        guard normalized.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw CatalogError.outsideManagedDirectory }
        guard FileManager.default.fileExists(atPath: normalized.path) else { return [] }
        let values = try normalized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CatalogError.notRegularFile }
        return try FileManager.default.contentsOfDirectory(at: normalized, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try regularFile($0, within: root) }
    }

    private static func photoAssets(projectID: UUID, frameID: UUID, captureRoot: URL, namespace: UUID, root: URL) throws -> [SourceAssetReference] {
        // EvidenceService stores photos beside capture folders, under Captures/evidence.
        // Library imports without an AR frame remain project evidence; they are
        // not silently attached to whichever scan was most recently recorded.
        let projectCaptures = captureRoot.deletingLastPathComponent()
        let photos = try regularFiles(in: projectCaptures.appendingPathComponent("evidence", isDirectory: true), within: root, suffix: ".json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var result = [SourceAssetReference]()
        for metadata in photos {
            guard metadata.byteCount <= 2 * 1_024 * 1_024,
                  let record = try? decoder.decode(PhotoIndex.self, from: Data(contentsOf: metadata.url)),
                  record.projectID == projectID, record.cameraFrameID == frameID else { continue }
            let photo = try regularFile(try child(record.relativePath, in: projectCaptures), within: root)
            let hash = record.sha256.flatMap { value in value.count == 64 && value.allSatisfy(\.isHexDigit) ? value : nil }
            result.append(asset(photo, kind: .image, namespace: namespace, root: root, sha256: hash))
            result.append(asset(metadata, kind: .cameraMetadata, namespace: namespace, root: root))
        }
        return result
    }

    private static func asset(_ file: FileReference, kind: SourceAssetKind, namespace: UUID, root: URL, sha256: String? = nil) -> SourceAssetReference {
        let path = String(file.url.path.dropFirst(root.path.count + 1))
        return SourceAssetReference(id: stableAssetID(namespace: namespace, path: path), relativePath: path,
                                    kind: kind, byteCount: file.byteCount, sha256: sha256)
    }

    /// Deterministic identity only, not a security/content digest. Keeping asset
    /// IDs stable makes a repeated registration preserve reference identities.
    private static func stableAssetID(namespace: UUID, path: String) -> UUID {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in (namespace.uuidString + ":" + path).utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x100000001b3
        }
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: first >> (56 - $0 * 8)) }
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: second >> (56 - $0 * 8)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private struct FileReference { var url: URL; var byteCount: Int64 }
    private struct Header: Decodable { var schemaVersion: Int; var source: String; var status: String }
    private struct LiDARManifest: Decodable {
        struct Segment: Decodable { var id: UUID; var frameID: UUID; var startedAt: Date; var geoTag: GeoTag? }
        var projectID: UUID
        var segments: [Segment]
        var completedAssets: [String]
    }
    private struct RoomManifest: Decodable {
        var id: UUID
        var projectID: UUID
        var frameID: UUID
        var createdAt: Date
        var completedAssets: [String]
        var geoTag: GeoTag?
    }
    private struct PhotoIndex: Decodable {
        var projectID: UUID
        var cameraFrameID: UUID?
        var relativePath: String
        var sha256: String?
    }
    private struct ObjectManifest: Decodable {
        struct Image: Decodable {
            var relativePath: String
            var byteCount: Int64
            var sha256: String
        }
        var id: UUID
        var projectID: UUID
        var frameID: UUID
        var createdAt: Date
        var completedAssets: [String]
        var images: [Image]
        var modelRelativePath: String?
        var geoTag: GeoTag?
    }

    enum CatalogError: LocalizedError {
        case invalidManifest, unsupportedSchema, unsupportedSource, invalidAssetPath, outsideManagedDirectory, notRegularFile
        var errorDescription: String? {
            switch self {
            case .invalidManifest: "Метаданные съёмки неполны или противоречат файлам."
            case .unsupportedSchema: "Эта версия метаданных съёмки пока не поддерживается."
            case .unsupportedSource: "Неизвестный источник съёмки."
            case .invalidAssetPath: "В метаданных найден недопустимый путь к файлу."
            case .outsideManagedDirectory: "Файл съёмки находится за пределами каталога приложения."
            case .notRegularFile: "Ссылка на исходник не является обычным файлом."
            }
        }
    }
}
