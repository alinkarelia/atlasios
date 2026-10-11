import Foundation
import AtlasCore
#if canImport(ImageIO)
import ImageIO
#endif

/// Saved image times come from their source metadata. A session's start time
/// and the operator's GPS observations are separate from an image's exposure.
struct ObjectCaptureImageMetadata: Codable, Sendable {
    var relativePath: String
    var byteCount: Int64
    var sha256: String
    var capturedAt: Date?
    var timestampBasis: PhotoGeoTimestampBasis
    var width: Int?
    var height: Int?
    var exifDateTimeOriginal: String?
    var exifOffsetTimeOriginal: String?
    var geoTag: GeoTag?
}

struct ObjectCaptureManifest: Codable, Sendable {
    var schemaVersion = 1
    var source = "ObjectCapture"
    var id: UUID
    var projectID: UUID
    var projectName: String
    /// This is a new local metric frame, not the project's geographic frame.
    var frameID: UUID
    var createdAt: Date
    var endedAt: Date?
    var recoveredAt: Date?
    var status = "recording"
    /// Dataset readiness does not imply that a 3D model was reconstructed.
    var modelStatus = "captured"
    var imagesDirectory = "Images"
    var completedAssets: [String] = []
    var images: [ObjectCaptureImageMetadata] = []
    var geoTag: GeoTag?
    var locationObservations: [GeoLocationFix] = []
    var captureOperator: FieldCaptureOperator?
    var device: FieldCaptureDevice
    var timeZoneIdentifier: String
    var utcOffsetSeconds: Int
    var modelRelativePath: String?
    var modelSHA256: String?
    var notes: [String] = [
        "Original Object Capture images and embedded metadata are retained without re-encoding.",
        "Image capturedAt is absent when the original metadata has no unambiguous time zone.",
        "Session GPS describes the operator's position, not image GPS or a registration of the model in WGS84.",
        "The model has its own local coordinate frame; metres, Y up. Independent scans are not automatically aligned."
    ]
    var warnings: [String] = []
}

enum ObjectCaptureStorageError: Error, LocalizedError, Sendable {
    case unsafePath, insufficientStorage, emptyDataset, oversizedDataset, invalidModel
    var errorDescription: String? {
        switch self {
        case .unsafePath: "Каталог съёмки содержит недопустимый путь. Оригиналы сохранены."
        case .insufficientStorage: "Для съёмки нужен минимум 1 ГБ свободной памяти. Освободите место и повторите."
        case .emptyDataset: "Камера ещё не сохранила снимки объекта. Начните новый обход и дождитесь счётчика кадров."
        case .oversizedDataset: "Набор слишком велик для обработки на устройстве. Оригиналы оставлены в каталоге съёмки."
        case .invalidModel: "Обработка не создала проверяемый файл 3D-модели. Исходные снимки сохранены."
        }
    }
}

/// Directory enumeration, ImageIO inspection and streaming SHA never run on
/// the camera/UI actor. Only small, Sendable manifest values cross the boundary.
actor ObjectCaptureDatasetWriter {
    let root: URL
    private let managedRoot: URL
    init(root: URL, managedRoot: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.managedRoot = managedRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    func create(_ manifest: ObjectCaptureManifest) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let relative = "Projects/\(manifest.projectID.uuidString)/Captures/Object-\(manifest.id.uuidString)"
        let expected = try FieldTransferPaths.resolve(relativePath: relative, root: managedRoot)
        guard expected.standardizedFileURL.path == root.resolvingSymlinksInPath().path else {
            throw ObjectCaptureStorageError.unsafePath
        }
        #if os(iOS)
        let capacity = try managedRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < 1_024 * 1_024 * 1_024 {
            throw ObjectCaptureStorageError.insufficientStorage
        }
        #else
        if let space = try manager.attributesOfFileSystem(forPath: managedRoot.path)[.systemFreeSize] as? NSNumber,
           space.int64Value < 1_024 * 1_024 * 1_024 { throw ObjectCaptureStorageError.insufficientStorage }
        #endif
        try manager.createDirectory(at: root.appendingPathComponent("Images", isDirectory: true),
                                    withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Checkpoints", isDirectory: true),
                                    withIntermediateDirectories: true)
        try save(manifest)
    }

    func save(_ manifest: ObjectCaptureManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let destination = try FieldTransferPaths.resolve(relativePath: "manifest.json", root: root)
        try encoder.encode(manifest).write(to: destination, options: .atomic)
    }

    func completeDataset(_ original: ObjectCaptureManifest) throws -> ObjectCaptureManifest {
        var manifest = original
        let imageRoot = try FieldTransferPaths.resolve(relativePath: manifest.imagesDirectory, root: root)
        guard let enumerator = FileManager.default.enumerator(at: imageRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { throw ObjectCaptureStorageError.emptyDataset }
        var files: [String] = []
        var images: [ObjectCaptureImageMetadata] = []
        var totalBytes: Int64 = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw ObjectCaptureStorageError.unsafePath }
            guard values.isRegularFile == true else { continue }
            let prefix = root.path + "/"
            guard file.path.hasPrefix(prefix) else { throw ObjectCaptureStorageError.unsafePath }
            let relative = String(file.path.dropFirst(prefix.count))
            let safe = try FieldTransferPaths.resolve(relativePath: relative, root: root)
            guard safe.path == file.standardizedFileURL.resolvingSymlinksInPath().path,
                  let size = values.fileSize, size >= 0 else {
                throw ObjectCaptureStorageError.unsafePath
            }
            totalBytes += Int64(size)
            guard files.count < 4_096, size <= 512 * 1_024 * 1_024,
                  totalBytes <= 8 * 1_024 * 1_024 * 1_024 else { throw ObjectCaptureStorageError.oversizedDataset }
            files.append(relative)
            let extensions = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "dng"]
            guard extensions.contains(file.pathExtension.lowercased()) else { continue }
            let digest = try FieldTransferDigest.sha256(fileURL: safe)
            images.append(try imageMetadata(at: safe, relativePath: relative, size: Int64(size), digest: digest))
        }
        guard !images.isEmpty else { throw ObjectCaptureStorageError.emptyDataset }
        manifest.images = images.sorted { $0.relativePath < $1.relativePath }
        manifest.completedAssets = files.sorted()
        manifest.status = "ready"
        try save(manifest)
        return manifest
    }

    func commitModel(from temporary: URL, manifest original: ObjectCaptureManifest) throws -> ObjectCaptureManifest {
        try Task.checkCancellation()
        let relative = temporary.lastPathComponent
        let safe = try FieldTransferPaths.resolve(relativePath: relative, root: root)
        guard safe.path == temporary.standardizedFileURL.resolvingSymlinksInPath().path,
              safe.pathExtension.lowercased() == "usdz" else {
            throw ObjectCaptureStorageError.invalidModel
        }
        let values = try safe.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 512 * 1_024 * 1_024 else {
            throw ObjectCaptureStorageError.invalidModel
        }
        let handle = try FileHandle(forReadingFrom: safe)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw ObjectCaptureStorageError.invalidModel
        }
        let digest = try FieldTransferDigest.sha256(fileURL: safe)
        let destination = try FieldTransferPaths.resolve(relativePath: "object.usdz", root: root)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: safe)
        } else { try FileManager.default.moveItem(at: safe, to: destination) }
        var manifest = original
        manifest.modelStatus = "ready"
        manifest.modelRelativePath = "object.usdz"
        manifest.modelSHA256 = digest
        if !manifest.completedAssets.contains("object.usdz") { manifest.completedAssets.append("object.usdz") }
        manifest.completedAssets.sort()
        try save(manifest)
        return manifest
    }

    /// Recovery reads only files already committed by the capture framework.
    /// It never opens a camera, starts reconstruction or invents an end time.
    func recoverDataset() throws -> URL {
        let file = try FieldTransferPaths.resolve(relativePath: "manifest.json", root: root)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 2 * 1_024 * 1_024 else {
            throw ObjectCaptureStorageError.unsafePath
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var metadata = try decoder.decode(ObjectCaptureManifest.self, from: Data(contentsOf: file))
        let expected = try FieldTransferPaths.resolve(relativePath:
            "Projects/\(metadata.projectID.uuidString)/Captures/Object-\(metadata.id.uuidString)", root: managedRoot)
        guard metadata.schemaVersion == 1, metadata.source == "ObjectCapture",
              metadata.imagesDirectory == "Images", expected.path == root.resolvingSymlinksInPath().path else {
            throw ObjectCaptureStorageError.unsafePath
        }
        metadata.recoveredAt = Date()
        metadata.warnings.append("Recovered from saved original images. Unknown capture end time was not replaced by recovery time.")
        let model = try FieldTransferPaths.resolve(relativePath: "object.usdz", root: root)
        if metadata.modelRelativePath == "object.usdz", let hash = metadata.modelSHA256,
           FileManager.default.fileExists(atPath: model.path),
           (try? FieldTransferDigest.sha256(fileURL: model)) == hash {
            metadata.modelStatus = "ready"
        } else {
            metadata.modelRelativePath = nil; metadata.modelSHA256 = nil
            metadata.modelStatus = "captured"
        }
        var completed = try completeDataset(metadata)
        if completed.modelStatus == "ready" { completed.completedAssets.append("object.usdz"); try save(completed) }
        return file
    }

    private func imageMetadata(at file: URL, relativePath: String, size: Int64,
                               digest: String) throws -> ObjectCaptureImageMetadata {
        var metadata = ObjectCaptureImageMetadata(relativePath: relativePath, byteCount: size,
            sha256: digest, timestampBasis: .importedAtUnknownCaptureTime)
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw ObjectCaptureStorageError.emptyDataset
        }
        let normalized = PhotoGeoMetadata.normalize(properties)
        metadata.capturedAt = normalized.capturedAt
        metadata.timestampBasis = normalized.timestampBasis
        metadata.width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
        metadata.height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        let exif = properties["{Exif}"] as? [String: Any]
        metadata.exifDateTimeOriginal = exif?["DateTimeOriginal"] as? String
        metadata.exifOffsetTimeOriginal = exif?["OffsetTimeOriginal"] as? String
        // An EXIF coordinate without an unambiguous observation time remains
        // in the untouched original. It is never stamped with today's time.
        if let observation = normalized.observation, let time = normalized.capturedAt {
            let fix = GeoLocationFix(coordinate: GeographicCoordinate(longitude: observation.longitude,
                latitude: observation.latitude), altitudeMeters: observation.altitudeMeters,
                horizontalAccuracyMeters: observation.horizontalAccuracyMeters, observedAt: time, source: .photoEXIF)
            let tag = GeoTag(automaticFix: fix)
            try GeoTagPolicy.validate(tag)
            metadata.geoTag = tag
        }
        #endif
        return metadata
    }
}
