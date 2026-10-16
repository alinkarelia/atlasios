import Foundation
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import CoreImage
import AtlasCore
@preconcurrency import Vision
@preconcurrency import ARKit
@preconcurrency import RealityKit

struct PhotoEvidence: Identifiable, Codable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var projectID: UUID
    var createdAt: Date
    var relativePath: String
    var metadataPath: String
    var source: String
    var byteCount: Int
    var sha256: String
    var pixelWidth: Int
    var pixelHeight: Int
    var cameraTransform: [Float]?
    /// AR pose is useful within its original frame only; it is not a GPS fix.
    var cameraFrameID: UUID?
    var ocr: EvidenceOCR?
    var recognitionIssue: String?
    /// Original automatic observation and append-only operator corrections.
    /// Optional keys keep previously saved evidence readable.
    var geoTag: GeoTag? = nil
    var capturedAt: Date? = nil
    var geoTimestampBasis: PhotoGeoTimestampBasis? = nil
    /// Source EXIF may contain coordinates without a recoverable capture time.
    /// Keep that observation separately rather than dating it at import time.
    var sourceGeoMetadata: PhotoSourceGeoMetadata? = nil
    /// Derived frames retain the exact source recording and sampled pose.
    /// They never replace the original movie or acquire the importer’s GPS.
    var videoFrameProvenance: VideoFrameProvenance? = nil
}

struct PhotoSourceGeoMetadata: Codable, Sendable {
    var coordinate: GeographicCoordinate?
    var altitudeMeters: Double?
    var horizontalAccuracyMeters: Double?
    var capturedAt: Date?
    var timestampBasis: PhotoGeoTimestampBasis
}

struct EvidenceOCR: Codable, Sendable {
    struct Line: Codable, Sendable {
        var text: String
        var confidence: Float
        /// Vision normalized rectangle, origin at the lower-left of the image.
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }
    var lines: [Line]
    var recognizedAt: Date
    var recognitionLanguages: [String]
    var supportedLanguages: [String]
    var revision: Int
    var requiresHumanReview = true
    var text: String { lines.map(\.text).joined(separator: "\n") }
}

/// Evidence is kept locally. OCR supplies a draft and never assigns identities,
/// burial dates, legal statuses, or registry links without a human decision.
@MainActor
final class EvidenceService: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var latestEvidence: PhotoEvidence?
    @Published private(set) var photos: [PhotoEvidence] = []
    @Published private(set) var errorMessage: String?
    private let processor = EvidenceProcessor.shared

    func loadEvidence(projectID: UUID, outputDirectory: URL) async {
        do {
            photos = try await processor.load(projectID: projectID, directory: outputDirectory)
            latestEvidence = photos.first
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func select(_ photo: PhotoEvidence) { latestEvidence = photo }

    func importPhoto(data: Data, projectID: UUID, outputDirectory: URL,
                     recognizeText: Bool = true) async throws -> PhotoEvidence {
        try await save(data: data, projectID: projectID, outputDirectory: outputDirectory,
                       source: "photoLibrary", cameraTransform: nil, cameraFrameID: nil,
                       geoFix: nil, capturedAt: nil, recognizeText: recognizeText)
    }

    func saveVideoFrame(data: Data, projectID: UUID, outputDirectory: URL,
                        capturedAt: Date, cameraFrameID: UUID, cameraTransform: [Float],
                        provenance: VideoFrameProvenance) async throws -> PhotoEvidence {
        guard provenance.isValid, provenance.frameID == cameraFrameID,
              provenance.sourceObservedAt == capturedAt,
              VideoTourPolicy.validCameraTransform(cameraTransform) else { throw EvidenceError.unsupportedMetadata }
        return try await save(data: data, projectID: projectID, outputDirectory: outputDirectory,
            source: "videoDerivedFrame", cameraTransform: cameraTransform, cameraFrameID: cameraFrameID,
            geoFix: nil, capturedAt: capturedAt, recognizeText: false, videoFrameProvenance: provenance)
    }

    /// Saves AVCapturePhotoOutput's original encoded file, including EXIF and
    /// orientation. Validation, hashing, disk writes and OCR run on the evidence
    /// actor, so capturing a full-resolution photo does not block the UI actor.
    func capturePhoto(data: Data, projectID: UUID, outputDirectory: URL,
                      geoFix: GeoLocationFix? = nil, capturedAt: Date? = nil) async throws -> PhotoEvidence {
        let captureTime = capturedAt ?? Date()
        let acceptedFix = geoFix.flatMap { GeoTagPolicy.acceptDeviceFix($0, now: captureTime) ? $0 : nil }
        return try await save(data: data, projectID: projectID, outputDirectory: outputDirectory,
            source: "cameraPhoto", cameraTransform: nil, cameraFrameID: nil,
            geoFix: acceptedFix, capturedAt: captureTime, recognizeText: true)
    }

    /// Copies an actual camera frame into JPEG on its owning executor. Neither
    /// ARFrame nor CVPixelBuffer is passed to the asynchronous evidence actor.
    func captureCameraPhoto(from view: ARView, projectID: UUID, frameID: UUID?,
                            outputDirectory: URL, geoFix: GeoLocationFix? = nil,
                            acceptsFrame: (TimeInterval) -> Bool) async throws -> PhotoEvidence {
        guard let frame = view.session.currentFrame, acceptsFrame(frame.timestamp) else {
            throw EvidenceError.cameraNotReady
        }
        let now = ProcessInfo.processInfo.systemUptime
        let capturedAt = Date().addingTimeInterval(frame.timestamp - now)
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let imageOrientation: CGImagePropertyOrientation
        switch orientation {
        case .portrait: imageOrientation = .right
        case .portraitUpsideDown: imageOrientation = .left
        case .landscapeLeft: imageOrientation = .up
        case .landscapeRight: imageOrientation = .down
        default: imageOrientation = .right
        }
        let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(imageOrientation)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: image, colorSpace: space,
                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.94]) else {
            throw EvidenceError.invalidImage
        }
        let transform = frame.camera.transform
        let values = (0..<4).flatMap { column in (0..<4).map { row in transform[column][row] } }
        // A cached, malformed, or unavailable GPS fix never prevents the photo.
        let acceptedFix = geoFix.flatMap { GeoTagPolicy.acceptDeviceFix($0, now: capturedAt) ? $0 : nil }
        return try await save(data: data, projectID: projectID, outputDirectory: outputDirectory,
            source: "cameraSnapshot", cameraTransform: values, cameraFrameID: frameID,
            geoFix: acceptedFix, capturedAt: capturedAt, recognizeText: true)
    }

    /// The original image and automatic observation stay intact. A stale editor
    /// receives a conflict rather than replacing another operator's change.
    func updateGeoTag(photoID: UUID, correction: GeoTagCorrection,
                      expectedGeoTag: GeoTag?, outputDirectory: URL) async throws -> PhotoEvidence {
        guard !isProcessing else { throw EvidenceError.alreadyProcessing }
        guard let known = photos.first(where: { $0.id == photoID }) else { throw EvidenceError.evidenceNotFound }
        isProcessing = true; errorMessage = nil
        defer { isProcessing = false }
        do {
            let updated = try await processor.updateGeoTag(photoID: photoID, projectID: known.projectID,
                correction: correction, expectedGeoTag: expectedGeoTag, directory: outputDirectory)
            if let index = photos.firstIndex(where: { $0.id == photoID }) { photos[index] = updated }
            if latestEvidence?.id == photoID { latestEvidence = updated }
            return updated
        } catch { errorMessage = error.localizedDescription; throw error }
    }

    private func save(data: Data, projectID: UUID, outputDirectory: URL, source: String,
                      cameraTransform: [Float]?, cameraFrameID: UUID?, geoFix: GeoLocationFix?,
                      capturedAt: Date?, recognizeText: Bool,
                      videoFrameProvenance: VideoFrameProvenance? = nil) async throws -> PhotoEvidence {
        guard !isProcessing else { throw EvidenceError.alreadyProcessing }
        isProcessing = true; errorMessage = nil
        defer { isProcessing = false }
        do {
            let evidence = try await processor.save(data: data, projectID: projectID, directory: outputDirectory,
                source: source, cameraTransform: cameraTransform, cameraFrameID: cameraFrameID,
                geoFix: geoFix, capturedAt: capturedAt, recognizeText: recognizeText,
                videoFrameProvenance: videoFrameProvenance)
            latestEvidence = evidence
            photos.removeAll { $0.id == evidence.id }
            photos.insert(evidence, at: 0)
            return evidence
        } catch { errorMessage = error.localizedDescription; throw error }
    }
}

enum EvidenceError: LocalizedError {
    case invalidImage, cameraNotReady, imageTooLarge, alreadyProcessing, insufficientDisk
    case evidenceNotFound, unsafeEvidencePath, geoTagConflict, unsupportedMetadata
    var errorDescription: String? {
        switch self {
        case .invalidImage: "Не удалось прочитать изображение. Выберите исходную фотографию."
        case .cameraNotReady: "Камера ещё не готова. Дождитесь изображения или перезапустите камеру."
        case .imageTooLarge: "Фото больше 100 МБ. Импортируйте отдельные снимки меньшего размера."
        case .alreadyProcessing: "Дождитесь сохранения текущей фотографии."
        case .insufficientDisk: "Недостаточно места для безопасного сохранения фотографии."
        case .evidenceNotFound: "Фотография не найдена. Обновите список проекта."
        case .unsafeEvidencePath: "Метаданные фотографии не соответствуют исходному файлу проекта."
        case .geoTagConflict: "Геометка уже изменилась. Обновите фотографию и повторите корректировку."
        case .unsupportedMetadata: "Формат метаданных фотографии не поддерживается этой версией приложения."
        }
    }
}

private actor EvidenceProcessor {
    // All app windows/editors share the compare-and-write executor.
    static let shared = EvidenceProcessor()

    func load(projectID: UUID, directory: URL) throws -> [PhotoEvidence] {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let root = directory.appendingPathComponent("evidence", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return files.compactMap { file in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return nil }
            return try? readMetadata(photoID: id, projectID: projectID, directory: directory)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func save(data: Data, projectID: UUID, directory: URL, source: String,
              cameraTransform: [Float]?, cameraFrameID: UUID?, geoFix: GeoLocationFix?,
              capturedAt: Date?, recognizeText: Bool,
              videoFrameProvenance: VideoFrameProvenance? = nil) throws -> PhotoEvidence {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard data.count < 100 * 1_024 * 1_024 else { throw EvidenceError.imageTooLarge }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(imageSource) > 0,
              let identifier = CGImageSourceGetType(imageSource),
              let imageType = UTType(identifier as String), imageType.conforms(to: .image),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw EvidenceError.invalidImage
        }
        // Validate decoding without expanding a full-resolution image into RAM.
        let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceCreateThumbnailWithTransform: true]
        guard CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) != nil else {
            throw EvidenceError.invalidImage
        }
        let id = UUID()
        let relativePath = "evidence/\(id.uuidString).\(imageType.preferredFilenameExtension ?? "image")"
        let metadataPath = "evidence/\(id.uuidString).json"
        let evidenceDirectory = directory.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try ensureEvidenceDirectory(directory)
        let capacity = try evidenceDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard (capacity.volumeAvailableCapacityForImportantUsage ?? 0) > Int64(data.count * 2 + 16 * 1_024 * 1_024) else {
            throw EvidenceError.insufficientDisk
        }
        let output = directory.appendingPathComponent(relativePath)
        // Library and native-camera images remain byte-for-byte originals,
        // including their EXIF dictionaries and encoded orientation.
        try data.write(to: output, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let importedAt = Date()
        var evidence = PhotoEvidence(id: id, projectID: projectID, createdAt: importedAt, relativePath: relativePath,
            metadataPath: metadataPath, source: source, byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            pixelWidth: width, pixelHeight: height, cameraTransform: cameraTransform,
            cameraFrameID: cameraFrameID, ocr: nil, recognitionIssue: nil)
        evidence.videoFrameProvenance = videoFrameProvenance
        if source == "photoLibrary" {
            // An imported photograph uses only its own metadata, never the
            // phone's current location. The original file remains unchanged.
            let rawProperties = Dictionary(uniqueKeysWithValues: properties.map { ($0.key as String, $0.value) })
            let normalized = PhotoGeoMetadata.normalize(rawProperties)
            evidence.capturedAt = normalized.capturedAt
            evidence.geoTimestampBasis = normalized.timestampBasis
            evidence.sourceGeoMetadata = PhotoSourceGeoMetadata(
                coordinate: normalized.observation.map { .init(longitude: $0.longitude, latitude: $0.latitude) },
                altitudeMeters: normalized.observation?.altitudeMeters,
                horizontalAccuracyMeters: normalized.observation?.horizontalAccuracyMeters,
                capturedAt: normalized.capturedAt, timestampBasis: normalized.timestampBasis)
            if let observation = normalized.observation, let captureTime = normalized.capturedAt {
                evidence.geoTag = GeoTag(automaticFix: GeoLocationFix(
                    coordinate: .init(longitude: observation.longitude, latitude: observation.latitude),
                    altitudeMeters: observation.altitudeMeters,
                    horizontalAccuracyMeters: observation.horizontalAccuracyMeters,
                    observedAt: captureTime, source: .photoEXIF))
            }
        } else if source == "videoDerivedFrame" {
            guard videoFrameProvenance != nil, let capturedAt,
                  cameraFrameID != nil, cameraTransform?.count == 16,
                  cameraTransform?.allSatisfy(\.isFinite) == true else { throw EvidenceError.unsupportedMetadata }
            evidence.capturedAt = capturedAt
            evidence.geoTimestampBasis = .cameraCapture
        } else {
            let rawProperties = Dictionary(uniqueKeysWithValues: properties.map { ($0.key as String, $0.value) })
            let normalized = PhotoGeoMetadata.normalize(rawProperties)
            let photoTime = normalized.capturedAt ?? capturedAt ?? importedAt
            // A fix that expired during photo processing must never become an
            // automatic location for a different capture time.
            let acceptedFix = geoFix.flatMap { GeoTagPolicy.acceptDeviceFix($0, now: photoTime) ? $0 : nil }
            evidence.capturedAt = photoTime
            evidence.geoTimestampBasis = acceptedFix == nil ? .cameraCapture : .deviceLocation
            evidence.geoTag = acceptedFix.map { GeoTag(automaticFix: $0) }
        }
        if let tag = evidence.geoTag { try GeoTagPolicy.validate(tag) }
        // Commit a record before OCR. Recognition failure never loses a photo.
        try writeMetadata(evidence, directory: directory)
        if recognizeText {
            do {
                let orientation = CGImagePropertyOrientation(rawValue: (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1) ?? .up
                let result = try recognize(data: data, orientation: orientation)
                evidence.ocr = result
                if !result.recognitionLanguages.contains(where: { $0.lowercased().hasPrefix("ru") }) {
                    evidence.recognitionIssue = "Vision на этом устройстве не поддерживает русский OCR. Проверьте надписи вручную; исходное фото сохранено."
                }
            } catch {
                evidence.recognitionIssue = "Фото сохранено. Текст не распознан: \(error.localizedDescription)"
            }
            try writeMetadata(evidence, directory: directory)
        }
        // Read the committed representation so timestamp serialization cannot
        // cause a false conflict when the operator edits this returned record.
        return try readMetadata(photoID: id, projectID: projectID, directory: directory)
    }

    func updateGeoTag(photoID: UUID, projectID: UUID, correction: GeoTagCorrection,
                      expectedGeoTag: GeoTag?, directory: URL) throws -> PhotoEvidence {
        var evidence = try readMetadata(photoID: photoID, projectID: projectID, directory: directory)
        guard evidence.geoTag == expectedGeoTag else { throw EvidenceError.geoTagConflict }
        var changed = evidence.geoTag ?? GeoTag()
        changed.corrections.append(correction)
        try GeoTagPolicy.validateTransition(from: evidence.geoTag, to: changed)
        evidence.geoTag = changed
        try writeMetadata(evidence, directory: directory)
        return try readMetadata(photoID: photoID, projectID: projectID, directory: directory)
    }

    private func recognize(data: Data, orientation: CGImagePropertyOrientation) throws -> EvidenceOCR {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Dictionary correction can silently alter surnames and inscriptions.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        let requested = ["ru-RU", "en-US"]
        let chosen = requested.filter { preferred in supported.contains(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) }
        if !chosen.isEmpty { request.recognitionLanguages = chosen }
        let handler = VNImageRequestHandler(data: data, orientation: orientation, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation -> EvidenceOCR.Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let bounds = observation.boundingBox
            return EvidenceOCR.Line(text: candidate.string, confidence: candidate.confidence,
                x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
        }.sorted { first, second in
            if abs(first.y - second.y) > 0.02 { return first.y > second.y }
            return first.x < second.x
        }
        return EvidenceOCR(lines: lines, recognizedAt: Date(), recognitionLanguages: request.recognitionLanguages,
                           supportedLanguages: supported, revision: request.revision)
    }

    private func writeMetadata(_ evidence: PhotoEvidence, directory: URL) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try ensureEvidenceDirectory(directory)
        guard evidence.metadataPath == "evidence/\(evidence.id.uuidString).json" else { throw EvidenceError.unsafeEvidencePath }
        let destination = directory.appendingPathComponent(evidence.metadataPath).standardizedFileURL
        guard destination.resolvingSymlinksInPath().path == destination.path else { throw EvidenceError.unsafeEvidencePath }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: destination,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func readMetadata(photoID: UUID, projectID: UUID, directory: URL) throws -> PhotoEvidence {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try ensureEvidenceDirectory(directory)
        let metadataPath = "evidence/\(photoID.uuidString).json"
        let metadata = directory.appendingPathComponent(metadataPath).standardizedFileURL
        guard metadata.resolvingSymlinksInPath().path == metadata.path,
              FileManager.default.fileExists(atPath: metadata.path) else { throw EvidenceError.evidenceNotFound }
        let values = try metadata.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 20 * 1_024 * 1_024 else {
            throw EvidenceError.unsafeEvidencePath
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let evidence = try decoder.decode(PhotoEvidence.self, from: Data(contentsOf: metadata))
        guard evidence.schemaVersion == 1 else { throw EvidenceError.unsupportedMetadata }
        guard evidence.id == photoID, evidence.projectID == projectID, evidence.metadataPath == metadataPath else {
            throw EvidenceError.unsafeEvidencePath
        }
        let expectedPrefix = "evidence/\(photoID.uuidString)."
        guard evidence.relativePath.hasPrefix(expectedPrefix) else { throw EvidenceError.unsafeEvidencePath }
        let suffix = evidence.relativePath.dropFirst(expectedPrefix.count)
        guard (1...16).contains(suffix.count), suffix.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }) else { throw EvidenceError.unsafeEvidencePath }
        let image = directory.appendingPathComponent(evidence.relativePath).standardizedFileURL
        guard image.resolvingSymlinksInPath().path == image.path,
              (try image.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw EvidenceError.unsafeEvidencePath
        }
        if let tag = evidence.geoTag { try GeoTagPolicy.validate(tag) }
        return evidence
    }

    private func ensureEvidenceDirectory(_ directory: URL) throws {
        // iOS may expose /var through /private/var; resolve the trusted base,
        // then reject any symlink introduced inside this project's evidence.
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let root = base.appendingPathComponent("evidence", isDirectory: true).standardizedFileURL
        guard root.path.hasPrefix(base.path + "/"), root.resolvingSymlinksInPath().path == root.path,
              (try root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw EvidenceError.unsafeEvidencePath
        }
    }
}
