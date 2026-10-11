import Foundation
import CoreImage
import CoreVideo
import CoreMedia
import CoreGraphics
@preconcurrency import AVFoundation

/// Strong retention leases a CoreVideo pool buffer until append/conversion has
/// finished. The immutable camera image is never mutated by this recorder;
/// the gate permits at most two leases, preventing AR camera-pool exhaustion.
private final class CaptureVideoFrameLease: @unchecked Sendable {
    let image: CVPixelBuffer
    let descriptor: CaptureVideoFrameDescriptor
    init(image: CVPixelBuffer, descriptor: CaptureVideoFrameDescriptor) {
        self.image = image; self.descriptor = descriptor
    }
}

/// AVAssetWriter, CIContext and all mutable file/encoder state belong to one
/// serial worker queue. MainActor only reserves a bounded buffer lease and
/// receives small Sendable status/results; it never encodes video.
final class CaptureVideoRecorder: @unchecked Sendable {
    let identity: CaptureVideoIdentity
    private let directory: URL
    private let queue = DispatchQueue(label: "com.terraview.ar-video", qos: .userInitiated)
    private let admission = CaptureVideoAdmission()
    private let report: @Sendable (String, Bool) -> Void
    private var document: CaptureVideoDocument
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var imageContext: CIContext?
    private var lastVideoTime: Double?
    private var lastKeyframeTime: Double = -.infinity
    private var lastCheckpointTime: Double = -.infinity
    private var failure: String?
    private var finishing = false
    private var result: CaptureVideoResult?
    private var finishWaiters: [CheckedContinuation<CaptureVideoResult, Never>] = []
    private var metadataOwned = false

    init(identity: CaptureVideoIdentity, directory: URL,
         report: @escaping @Sendable (String, Bool) -> Void) {
        self.identity = identity; self.directory = directory; self.report = report
        document = CaptureVideoDocument(identity: identity, status: .recording)
    }

    /// Called only by the existing ARSession delegate while its frame is valid.
    /// Retaining a pool buffer protects it from reuse until this lease releases.
    func offer(image: CVPixelBuffer, descriptor: CaptureVideoFrameDescriptor) {
        guard descriptor.isValid, descriptor.observedAt >= identity.startedAt,
              admission.reserve(timestamp: descriptor.arTimestamp) else { return }
        let lease = CaptureVideoFrameLease(image: image, descriptor: descriptor)
        queue.async { [self, lease] in
            var encoded = false
            defer { admission.release(encoded: encoded) }
            guard !finishing, failure == nil else { return }
            do { encoded = try append(lease) }
            catch { fail(error.localizedDescription) }
        }
    }

    func finish(reason: String) async -> CaptureVideoResult {
        admission.close()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let result { continuation.resume(returning: result); return }
                finishWaiters.append(continuation)
                guard !finishing else { return }
                finishing = true
                document.endReason = reason; document.endedAt = Date()
                guard let writer, let input, document.counts.encodedFrames > 0, writer.status == .writing else {
                    complete(failure: failure ?? "Камера не предоставила кадров для видео."); return
                }
                input.markAsFinished()
                queue.asyncAfter(deadline: .now() + 15) { [self] in
                    guard result == nil else { return }
                    complete(failure: "Видеокодировщик не завершил файл вовремя. Частичный исходник сохранён.")
                }
                writer.finishWriting { [self] in
                    queue.async { [self] in
                        guard result == nil else { return }
                        guard self.writer?.status == .completed else {
                            complete(failure: self.writer?.error?.localizedDescription ?? "Не удалось завершить видеофайл."); return
                        }
                        if let failure { complete(failure: failure); return }
                        do {
                            let partial = directory.appendingPathComponent("video.partial.mov")
                            let final = directory.appendingPathComponent("video.mov")
                            guard !FileManager.default.fileExists(atPath: final.path) else {
                                throw CaptureVideoError.existingMovie
                            }
                            try FileManager.default.moveItem(at: partial, to: final)
                            document.videoFile = "video.mov"
                            complete(failure: nil)
                        } catch { complete(failure: error.localizedDescription) }
                    }
                }
            }
        }
    }

    private func configure(_ lease: CaptureVideoFrameLease) throws {
        let width = CVPixelBufferGetWidth(lease.image), height = CVPixelBufferGetHeight(lease.image)
        guard let dimensions = CaptureVideoDocument.outputDimensions(width: width, height: height) else {
            throw CaptureVideoError.unsupportedImage
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["video.mov", "video.partial.mov", "video.json"] {
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw CaptureVideoError.existingMovie
            }
        }
        let output = try AVAssetWriter(outputURL: directory.appendingPathComponent("video.partial.mov"), fileType: .mov)
        output.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000,
                AVVideoExpectedSourceFrameRateKey: 15, AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        ]
        let track = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        track.expectsMediaDataInRealTime = true
        track.transform = orientationTransform(width: dimensions.width, height: dimensions.height)
        guard output.canAdd(track) else { throw CaptureVideoError.encoderUnavailable }
        output.add(track)
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard output.startWriting() else { throw output.error ?? CaptureVideoError.encoderUnavailable }
        output.startSession(atSourceTime: .zero)
        writer = output; input = track; adaptor = pixels
        metadataOwned = true
        imageContext = CIContext(options: [.cacheIntermediates: false])
        document.firstARTimestamp = lease.descriptor.arTimestamp
        document.sourceWidth = width; document.sourceHeight = height
        document.encodedWidth = dimensions.width; document.encodedHeight = dimensions.height
        try checkpoint()
    }

    private func append(_ lease: CaptureVideoFrameLease) throws -> Bool {
        if writer == nil { try configure(lease) }
        guard let writer, writer.status == .writing else {
            throw self.writer?.error ?? CaptureVideoError.encoderUnavailable
        }
        guard let input, let adaptor, let imageContext,
              let first = document.firstARTimestamp else { throw CaptureVideoError.encoderUnavailable }
        if document.counts.encodedFrames == 0, lease.descriptor.arTimestamp - first > 8 {
            throw CaptureVideoError.encoderUnavailable
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return false }
        let seconds = lease.descriptor.arTimestamp - first
        guard seconds.isFinite, seconds >= 0, lastVideoTime.map({ seconds > $0 }) ?? true else { return false }
        guard document.keyframes.count < 7_200 else { throw CaptureVideoError.durationLimit }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return false }
        let image = CIImage(cvPixelBuffer: lease.image)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: Double(document.encodedWidth) / Double(document.sourceWidth),
                                                             y: Double(document.encodedHeight) / Double(document.sourceHeight)))
        imageContext.render(scaled, to: destination,
            bounds: CGRect(x: 0, y: 0, width: document.encodedWidth, height: document.encodedHeight),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        guard adaptor.append(destination, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) else {
            throw writer.error ?? CaptureVideoError.encoderUnavailable
        }
        lastVideoTime = seconds
        document.counts.encodedFrames += 1
        document.durationSeconds = seconds + 1.0 / 15.0
        if seconds - lastKeyframeTime >= 1 || document.keyframes.isEmpty {
            document.keyframes.append(.init(videoSeconds: seconds, frame: lease.descriptor))
            lastKeyframeTime = seconds
        }
        if seconds - lastCheckpointTime >= 5 {
            try checkpoint(); lastCheckpointTime = seconds
            report("Видео записывается · \(Int(seconds)) с", true)
        }
        return true
    }

    private func orientationTransform(width: Int, height: Int) -> CGAffineTransform {
        let w = CGFloat(width), h = CGFloat(height)
        switch identity.orientation {
        case .portrait: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .portraitUpsideDown: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .landscapeLeft: return .identity
        case .landscapeRight: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        }
    }

    private func checkpoint() throws {
        if !metadataOwned {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A failed attempt never replaces another recorder's original.
            for name in ["video.mov", "video.partial.mov", "video.json"] {
                guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                    throw CaptureVideoError.existingMovie
                }
            }
            metadataOwned = true
        }
        let counts = admission.snapshot()
        // release(encoded:) occurs after append returns; include the current
        // encoded frame here without losing accounting for source/drop events.
        document.counts.sourceFrames = counts.sourceFrames
        document.counts.rateLimitedFrames = counts.rateLimitedFrames
        document.counts.droppedFrames = counts.droppedFrames
        document.updatedAt = Date()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: directory.appendingPathComponent("video.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message; admission.close()
        // Keep already encoded movie fragments. finish() gracefully seals a
        // still-writing encoder; cancelWriting() can discard the output file.
        document.status = .failed; document.failure = message
        try? checkpoint()
        report("Видео не сохранено: \(message)", false)
    }

    private func complete(failure message: String?) {
        guard result == nil else { return }
        if let message { failure = message }
        document.status = failure == nil ? .ready : .failed
        document.failure = failure
        document.counts = admission.snapshot()
        do { try checkpoint() }
        catch { failure = error.localizedDescription; document.status = .failed; document.failure = failure }
        let completed = CaptureVideoResult(identity: identity, document: document, failure: failure)
        result = completed
        writer = nil; input = nil; adaptor = nil; imageContext = nil
        let callbacks = finishWaiters; finishWaiters.removeAll()
        for callback in callbacks { callback.resume(returning: completed) }
        if completed.completed { report("Видео сохранено · \(Int(document.durationSeconds.rounded())) с", false) }
        else { report("Видео не завершено: \(failure ?? "неполные данные")", false) }
    }
}

private enum CaptureVideoError: LocalizedError {
    case unsupportedImage, existingMovie, encoderUnavailable, durationLimit
    var errorDescription: String? {
        switch self {
        case .unsupportedImage: "Размер изображения AR-камеры не поддерживается для видеозаписи."
        case .existingMovie: "Видео этого фрагмента уже существует. Начните новый фрагмент; оригинал сохранён."
        case .encoderUnavailable: "Видеокодировщик недоступен. Сетка и исходные файлы сохраняются отдельно."
        case .durationLimit: "Видеофрагмент достиг двух часов. Завершите его и начните следующий."
        }
    }
}
