import Foundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@preconcurrency import AVFoundation

struct VideoTourSource: Identifiable, Sendable {
    var id: UUID { segmentID }
    let captureID: UUID
    let projectID: UUID
    let segmentID: UUID
    let frameID: UUID
    let startedAt: Date
    let durationSeconds: Double
    let keyframeCount: Int
    let title: String
    let videoRelativePath: String
    let metadataRelativePath: String
    let metadataSHA256: String
    let parentManifestSHA256: String
    let videoByteCount: Int64
}

struct VideoTourListing: Sendable {
    var sources: [VideoTourSource]
    var issues: [String]
}

/// Extraction and streaming source checks run off the UI actor. Only finished
/// AR camera movies with their exact source poses can become registered photo
/// stations. The source movie is never moved, overwritten or deleted.
actor VideoTourImporter {
    private var importing = false
    private let maximumMetadataBytes = 8*1_024*1_024
    private let maximumVideoBytes: Int64 = 8*1_024*1_024*1_024

    func sources(projectID: UUID, directory: URL) throws -> VideoTourListing {
        guard FileManager.default.fileExists(atPath: directory.path) else { return .init(sources: [], issues: []) }
        let folders = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("lidar-") }
        guard folders.count <= 500 else { throw VideoTourError.invalidSource }
        var result = VideoTourListing(sources: [], issues: [])
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            do {
                let manifest = try readParent(folder: folder, projectID: projectID, directory: directory)
                // An unfinished capture is not an import error or a ready tour.
                guard manifest.value.status == "ready" else { continue }
                for segment in manifest.value.segments {
                    let movie = "segments/\(segment.id.uuidString)/video.mov"
                    let metadata = "segments/\(segment.id.uuidString)/video.json"
                    let assets = Set(manifest.value.completedAssets)
                    guard assets.contains(movie) || assets.contains(metadata) else { continue }
                    do {
                        guard assets.contains(movie), assets.contains(metadata) else { throw VideoTourError.invalidSource }
                        let source = try readSource(parent: manifest, segment: segment,
                            projectID: projectID, directory: directory)
                        result.sources.append(source.value)
                    } catch { result.issues.append("\(folder.lastPathComponent) · \(segment.id.uuidString.prefix(8)): \(error.localizedDescription)") }
                }
            } catch { result.issues.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
            guard result.sources.count <= 1_000 else { throw VideoTourError.invalidSource }
        }
        return result
    }

    func importStations(source: VideoTourSource, projectID: UUID, directory: URL,
                        evidence: EvidenceService, maximumStations: Int = 120,
                        intervalSeconds: Double = 3,
                        progress: @escaping @MainActor @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [PhotoEvidence] {
        guard !importing else { throw VideoTourError.importInProgress }
        importing = true; defer { importing = false }
        try Task.checkCancellation()
        guard source.projectID == projectID,
              source.videoRelativePath == VideoTourPolicy.videoPath(captureID: source.captureID, segmentID: source.segmentID),
              source.metadataRelativePath == VideoTourPolicy.metadataPath(captureID: source.captureID, segmentID: source.segmentID) else {
            throw VideoTourError.invalidSource
        }
        let folder = directory.appendingPathComponent("lidar-\(source.captureID.uuidString)", isDirectory: true)
        let parent = try readParent(folder: folder, projectID: projectID, directory: directory)
        guard parent.value.status == "ready", parent.sha256 == source.parentManifestSHA256,
              let segment = parent.value.segments.first(where: { $0.id == source.segmentID }) else { throw VideoTourError.sourceChanged }
        let current = try readSource(parent: parent, segment: segment, projectID: projectID, directory: directory)
        guard current.value.metadataSHA256 == source.metadataSHA256,
              current.value.videoByteCount == source.videoByteCount,
              current.value.frameID == source.frameID else { throw VideoTourError.sourceChanged }
        let keys = try VideoTourPolicy.selectedKeyframes(current.document,
            maximumStations: maximumStations, intervalSeconds: intervalSeconds)
        let movieURL = directory.appendingPathComponent(source.videoRelativePath)
        let movieHash = try streamingHash(movieURL)
        let asset = AVURLAsset(url: movieURL)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, duration <= 7_202, tracks.count == 1,
              let track = tracks.first, keys.allSatisfy({ $0.videoSeconds < duration + 0.002 }) else {
            throw VideoTourError.unreadableMovie
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        guard abs(size.width - Double(current.document.encodedWidth)) < 1,
              abs(size.height - Double(current.document.encodedHeight)) < 1,
              expectedTransform(transform, document: current.document) else { throw VideoTourError.invalidSource }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_600, height: 1_600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }
        await progress(0, keys.count)
        var photos = [PhotoEvidence]()
        for key in keys {
            try Task.checkCancellation()
            let decoded = try await generator.image(at: CMTime(seconds: key.videoSeconds, preferredTimescale: 600))
            try Task.checkCancellation()
            let actualSeconds = decoded.actualTime.seconds
            let offset = actualSeconds - key.videoSeconds
            guard actualSeconds.isFinite, actualSeconds >= 0, abs(offset) <= VideoTourPolicy.maximumPoseTimeOffset else {
                throw VideoTourError.frameTimeMismatch
            }
            let provenance = VideoFrameProvenance(captureID: source.captureID, segmentID: source.segmentID,
                frameID: source.frameID, sourceVideoRelativePath: source.videoRelativePath,
                sourceVideoSHA256: movieHash, sourceMetadataSHA256: source.metadataSHA256,
                requestedVideoSeconds: key.videoSeconds, actualVideoSeconds: actualSeconds,
                sourceARTimestamp: key.frame.arTimestamp, sourceObservedAt: key.frame.observedAt,
                sourceIntrinsics: key.frame.intrinsics, sourceWidth: current.document.sourceWidth,
                sourceHeight: current.document.sourceHeight, encodedWidth: current.document.encodedWidth,
                encodedHeight: current.document.encodedHeight, imageRotationApplied: current.document.identity.orientation,
                poseTimeOffsetSeconds: offset, trackingState: key.frame.trackingState)
            guard provenance.isValid else { throw VideoTourError.invalidSource }
            let data = try jpeg(decoded.image)
            let photo = try await evidence.saveVideoFrame(data: data, projectID: projectID,
                outputDirectory: directory, capturedAt: key.frame.observedAt,
                cameraFrameID: source.frameID, cameraTransform: key.frame.cameraTransform, provenance: provenance)
            photos.append(photo)
            await progress(photos.count, keys.count)
        }
        try Task.checkCancellation()
        // Recheck actual movie bytes after extraction. An altered source cannot
        // silently be claimed as the origin of an accepted route batch.
        guard try streamingHash(movieURL) == movieHash,
              SHA256.hash(data: Data(contentsOf: directory.appendingPathComponent(source.metadataRelativePath)))
                .map({ String(format: "%02x", $0) }).joined() == source.metadataSHA256 else {
            throw VideoTourError.sourceChanged
        }
        return photos
    }

    private struct CaptureManifest: Decodable {
        struct Segment: Decodable { let id: UUID; let frameID: UUID; let startedAt: Date }
        let schemaVersion: Int
        let source: String
        let id: UUID
        let projectID: UUID
        let status: String
        let segments: [Segment]
        let completedAssets: [String]
    }
    private struct Parent { let value: CaptureManifest; let sha256: String }
    private struct Source { let value: VideoTourSource; let document: CaptureVideoDocument }

    private func readParent(folder: URL, projectID: UUID, directory: URL) throws -> Parent {
        try safeDirectory(folder, within: directory)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let data = try boundedData(manifestURL, within: directory, maximumBytes: 2*1_024*1_024)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CaptureManifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.source == "ARKit.sceneReconstruction",
              manifest.projectID == projectID, folder.lastPathComponent == "lidar-\(manifest.id.uuidString)",
              !manifest.segments.isEmpty, manifest.segments.count <= 1_000,
              Set(manifest.segments.map(\.id)).count == manifest.segments.count,
              Set(manifest.segments.map(\.frameID)).count == manifest.segments.count,
              manifest.completedAssets.count <= 3_000,
              Set(manifest.completedAssets).count == manifest.completedAssets.count else { throw VideoTourError.invalidSource }
        return Parent(value: manifest, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func readSource(parent: Parent, segment: CaptureManifest.Segment,
                            projectID: UUID, directory: URL) throws -> Source {
        let identity = parent.value
        let moviePath = VideoTourPolicy.videoPath(captureID: identity.id, segmentID: segment.id)
        let metadataPath = VideoTourPolicy.metadataPath(captureID: identity.id, segmentID: segment.id)
        guard identity.completedAssets.contains("segments/\(segment.id.uuidString)/video.mov"),
              identity.completedAssets.contains("segments/\(segment.id.uuidString)/video.json") else { throw VideoTourError.invalidSource }
        let movie = directory.appendingPathComponent(moviePath)
        let metadata = directory.appendingPathComponent(metadataPath)
        try safeDirectory(movie.deletingLastPathComponent(), within: directory)
        let bytes = try regularFileSize(movie, within: directory)
        guard bytes > 0, bytes <= maximumVideoBytes else { throw VideoTourError.invalidSource }
        let data = try boundedData(metadata, within: directory, maximumBytes: maximumMetadataBytes)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(CaptureVideoDocument.self, from: data)
        try VideoTourPolicy.validate(document, projectID: projectID, captureID: identity.id,
            segmentID: segment.id, frameID: segment.frameID, startedAt: segment.startedAt)
        let value = VideoTourSource(captureID: identity.id, projectID: projectID, segmentID: segment.id,
            frameID: segment.frameID, startedAt: segment.startedAt, durationSeconds: document.durationSeconds,
            keyframeCount: document.keyframes.count,
            title: "\(identity.id.uuidString.prefix(8)) · фрагмент \(segment.id.uuidString.prefix(8))",
            videoRelativePath: moviePath, metadataRelativePath: metadataPath,
            metadataSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            parentManifestSHA256: parent.sha256, videoByteCount: bytes)
        return Source(value: value, document: document)
    }

    private func safeDirectory(_ url: URL, within root: URL) throws {
        try safePath(url, within: root)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw VideoTourError.invalidSource }
    }
    private func safePath(_ url: URL, within root: URL) throws {
        guard url.isFileURL, root.isFileURL,
              url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path+"/"),
              url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path+"/") else {
            throw VideoTourError.invalidSource
        }
    }
    private func regularFileSize(_ url: URL, within root: URL) throws -> Int64 {
        try safePath(url, within: root)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else { throw VideoTourError.invalidSource }
        return Int64(size)
    }
    private func boundedData(_ url: URL, within root: URL, maximumBytes: Int) throws -> Data {
        let size = try regularFileSize(url, within: root)
        guard size <= maximumBytes else { throw VideoTourError.invalidSource }
        let data = try Data(contentsOf: url)
        guard data.count == Int(size), data.count <= maximumBytes else { throw VideoTourError.sourceChanged }
        return data
    }
    private func streamingHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_024*1_024), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func jpeg(_ image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0, image.width <= 1_600, image.height <= 1_600 else { throw VideoTourError.invalidFrame }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw VideoTourError.invalidFrame
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { throw VideoTourError.invalidFrame }
        return Data(referencing: data)
    }
    private func expectedTransform(_ actual: CGAffineTransform, document: CaptureVideoDocument) -> Bool {
        let w = CGFloat(document.encodedWidth), h = CGFloat(document.encodedHeight)
        let expected: CGAffineTransform
        switch document.identity.orientation {
        case .portrait: expected = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .portraitUpsideDown: expected = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .landscapeLeft: expected = .identity
        case .landscapeRight: expected = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        }
        return zip([actual.a, actual.b, actual.c, actual.d, actual.tx, actual.ty],
                   [expected.a, expected.b, expected.c, expected.d, expected.tx, expected.ty])
            .allSatisfy { abs($0 - $1) < 0.001 }
    }
}
