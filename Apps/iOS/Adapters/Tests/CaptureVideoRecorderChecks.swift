import Foundation
import CoreVideo
import CoreMedia
import CoreGraphics
@preconcurrency import AVFoundation

/// Synthetic images exercise the actual Apple encoder and movie format. They
/// do not constitute an iPhone camera/LiDAR/thermal/measurement hardware test.
@main
struct CaptureVideoRecorderChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terraview-video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = CaptureVideoIdentity(captureID: UUID(), projectID: UUID(), segmentID: UUID(), frameID: UUID(),
            startedAt: Date(), orientation: .portrait)
        let recorder = CaptureVideoRecorder(identity: identity, directory: directory) { _, _ in }
        var image: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &image) == kCVReturnSuccess)
        guard let image else { fatalError("Synthetic pixel buffer unavailable") }
        precondition(CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess)
        if let bytes = CVPixelBufferGetBaseAddress(image) {
            bytes.initializeMemory(as: UInt8.self, repeating: 180, count: CVPixelBufferGetBytesPerRow(image) * 120)
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        func offer(_ index: Int) {
            let pose = CaptureVideoFrameDescriptor(arTimestamp: 1000 + Double(index) / 15,
                observedAt: Date(), cameraTransform: [1,0,0,0, 0,1,0,0, 0,0,1,0, Float(index) / 10,0,0,1],
                intrinsics: [140,0,0, 0,140,0, 80,60,1], trackingState: "normal",
                normalizedImageToDisplayTransform: [0,1,-1,0,1,0])
            recorder.offer(image: image, descriptor: pose)
        }
        offer(0)
        // Warm up the real CoreImage/H264 pipeline before paced synthetic input.
        try await Task.sleep(for: .seconds(2))
        for index in 1...24 { offer(index); try await Task.sleep(for: .milliseconds(80)) }
        let completed = await recorder.finish(reason: "syntheticEncoderCheck")
        precondition(completed.completed, "Actual AVAssetWriter must produce a sealed movie: \(completed.failure ?? "unknown")")
        precondition(completed.document.counts.encodedFrames > 1 && completed.document.keyframes.count >= 2)
        precondition(completed.identity == identity && completed.document.identity == identity)
        let movie = directory.appendingPathComponent("video.mov")
        precondition(FileManager.default.fileExists(atPath: movie.path))
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("video.partial.mov").path))
        let asset = AVURLAsset(url: movie)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        precondition(playable && duration.seconds.isFinite && duration.seconds > 1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        precondition(tracks.count == 1, "One video track; no microphone input")
        let audio = try await asset.loadTracks(withMediaType: .audio)
        precondition(audio.isEmpty)
        let transform = try await tracks[0].load(.preferredTransform)
        precondition(abs(transform.a) < 0.001 && abs(transform.b - 1) < 0.001 && abs(transform.c + 1) < 0.001)
        let descriptions = try await tracks[0].load(.formatDescriptions)
        precondition(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 } == true)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let decodedImage = try await generator.image(at: .zero)
        precondition(decodedImage.image.width == 120 && decodedImage.image.height == 160, "Actual portrait track transform")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(CaptureVideoDocument.self, from: Data(contentsOf: directory.appendingPathComponent("video.json")))
        precondition(sidecar.isCompleted && sidecar.identity.captureID == identity.captureID && sidecar.identity.projectID == identity.projectID)
        precondition(sidecar.identity.segmentID == identity.segmentID && sidecar.identity.frameID == identity.frameID && sidecar.identity.orientation == identity.orientation)
        precondition(abs(sidecar.identity.startedAt.timeIntervalSince(identity.startedAt)) < 1 && sidecar.counts == completed.document.counts)
        precondition(sidecar.keyframes.first?.frame.cameraTransform == [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])
        precondition(sidecar.normalizedImageToDisplayTransform == [0,1,-1,0,1,0])
        let secondFinish = await recorder.finish(reason: "secondRequest")
        precondition(secondFinish.completed && secondFinish.document.counts == sidecar.counts, "Idempotent finish cannot truncate a movie")
        let originalMovie = try Data(contentsOf: movie), originalSidecar = try Data(contentsOf: directory.appendingPathComponent("video.json"))
        let duplicate = CaptureVideoRecorder(identity: identity, directory: directory) { _, _ in }
        duplicate.offer(image: image, descriptor: .init(arTimestamp: 2000, observedAt: Date(),
            cameraTransform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1], intrinsics: [1,0,0, 0,1,0, 0,0,1], trackingState: "normal"))
        let duplicateResult = await duplicate.finish(reason: "existingOriginal")
        precondition(!duplicateResult.completed)
        let retainedMovie = try Data(contentsOf: movie)
        let retainedSidecar = try Data(contentsOf: directory.appendingPathComponent("video.json"))
        precondition(retainedMovie == originalMovie)
        precondition(retainedSidecar == originalSidecar,
                     "An existing original movie and sidecar remain byte-for-byte unchanged")
        let emptyDirectory = directory.appendingPathComponent("empty")
        let empty = CaptureVideoRecorder(identity: identity, directory: emptyDirectory) { _, _ in }
        let emptyResult = await empty.finish(reason: "beforeFirstCameraFrame")
        precondition(!emptyResult.completed && emptyResult.document.status == .failed)
        precondition(!FileManager.default.fileExists(atPath: emptyDirectory.appendingPathComponent("video.mov").path))
        print("Actual AVFoundation synthetic encoder: sealed/playable H264 MOV, portrait decode, sampled source poses, bounded admission, idempotent finish, empty/failure and original-preservation checks passed. Camera hardware not tested.")
    }
}
