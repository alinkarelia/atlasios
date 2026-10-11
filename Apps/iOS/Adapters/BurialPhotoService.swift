import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import AtlasCore

/// Cards reference original evidence records; thumbnails are disposable views.
@MainActor
final class BurialPhotoService: ObservableObject {
    @Published private(set) var photos: [PhotoEvidence] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var errorMessage: String?
    private let evidence = EvidenceService()
    private let reader = BurialPhotoReader()

    func load(projectID: UUID, captureDirectory: URL) async {
        await evidence.loadEvidence(projectID: projectID, outputDirectory: captureDirectory)
        photos = evidence.photos; errorMessage = evidence.errorMessage
    }

    func importOriginal(data: Data, projectID: UUID, captureDirectory: URL) async throws -> PhotoEvidence {
        guard !isProcessing else { throw EvidenceError.alreadyProcessing }
        isProcessing = true; errorMessage = nil
        defer { isProcessing = false }
        do {
            let photo = try await evidence.importPhoto(data: data, projectID: projectID, outputDirectory: captureDirectory)
            photos = evidence.photos
            return photo
        } catch { errorMessage = error.localizedDescription; throw error }
    }

    func captureOriginal(data: Data, projectID: UUID, captureDirectory: URL,
                         operatorFix: GeoLocationFix?, capturedAt: Date) async throws -> PhotoEvidence {
        guard !isProcessing else { throw EvidenceError.alreadyProcessing }
        isProcessing = true; errorMessage = nil
        defer { isProcessing = false }
        do {
            let photo = try await evidence.capturePhoto(data: data, projectID: projectID,
                outputDirectory: captureDirectory, geoFix: operatorFix, capturedAt: capturedAt)
            photos = evidence.photos
            return photo
        } catch { errorMessage = error.localizedDescription; throw error }
    }

    func photoURL(_ photo: PhotoEvidence, captureDirectory: URL) async throws -> URL {
        try await reader.validatedURL(photo, directory: captureDirectory)
    }

    func thumbnail(_ photo: PhotoEvidence, captureDirectory: URL,
                   maxPixelSize: Int = 600) async throws -> Data {
        try await reader.thumbnail(photo, directory: captureDirectory, maxPixelSize: maxPixelSize)
    }
}

private actor BurialPhotoReader {
    func validatedURL(_ photo: PhotoEvidence, directory: URL) throws -> URL {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard photo.metadataPath == "evidence/\(photo.id.uuidString).json",
              photo.relativePath.hasPrefix("evidence/\(photo.id.uuidString)."),
              !photo.relativePath.contains(".."), !photo.relativePath.contains("\\"),
              photo.relativePath.split(separator: "/").count == 2,
              photo.byteCount > 0, photo.byteCount < 100 * 1_024 * 1_024 else {
            throw EvidenceError.unsafeEvidencePath
        }
        let metadata = root.appendingPathComponent(photo.metadataPath)
        let file = root.appendingPathComponent(photo.relativePath)
        for url in [metadata, file] {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw EvidenceError.unsafeEvidencePath
            }
        }
        guard (try metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2 * 1_024 * 1_024 else {
            throw EvidenceError.unsupportedMetadata
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(PhotoEvidence.self, from: Data(contentsOf: metadata))
        guard stored.id == photo.id, stored.projectID == photo.projectID,
              stored.relativePath == photo.relativePath, stored.metadataPath == photo.metadataPath,
              stored.byteCount == photo.byteCount, stored.sha256 == photo.sha256,
              try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == photo.byteCount else {
            throw EvidenceError.unsafeEvidencePath
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1_024 * 1_024), !block.isEmpty {
            try Task.checkCancellation()
            hash.update(data: block)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == photo.sha256.lowercased() else {
            throw EvidenceError.unsafeEvidencePath
        }
        return file
    }

    func thumbnail(_ photo: PhotoEvidence, directory: URL, maxPixelSize: Int) throws -> Data {
        let url = try validatedURL(photo, directory: directory)
        let limit = min(1_200, max(64, maxPixelSize))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw EvidenceError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EvidenceError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EvidenceError.invalidImage }
        return output as Data
    }
}
