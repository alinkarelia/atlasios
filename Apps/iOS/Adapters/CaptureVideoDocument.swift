import Foundation

/// Camera/video metadata never claims that a phone GPS fix registers an AR
/// origin. Each file belongs to exactly one independent capture segment.
enum CaptureVideoOrientation: String, Codable, Sendable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight
}

struct CaptureVideoIdentity: Codable, Sendable, Equatable {
    let captureID: UUID
    let projectID: UUID
    let segmentID: UUID
    let frameID: UUID
    let startedAt: Date
    let orientation: CaptureVideoOrientation
}

struct CaptureVideoFrameDescriptor: Codable, Sendable {
    let arTimestamp: Double
    let observedAt: Date
    /// Column-major ARKit camera-to-world matrix, metres, Y up.
    let cameraTransform: [Float]
    /// Column-major 3×3 camera intrinsic matrix in source-image pixels.
    let intrinsics: [Float]
    let trackingState: String
    /// ARKit's image-to-view transform using a full-image viewport, without
    /// aspect-fill cropping. Optional for older metadata and synthetic input.
    var normalizedImageToDisplayTransform: [Float]? = nil

    var isValid: Bool {
        arTimestamp.isFinite && arTimestamp >= 0 && observedAt.timeIntervalSince1970.isFinite
            && cameraTransform.count == 16 && cameraTransform.allSatisfy(\.isFinite)
            && intrinsics.count == 9 && intrinsics.allSatisfy(\.isFinite)
            && normalizedImageToDisplayTransform.map({ $0.count == 6 && $0.allSatisfy(\.isFinite) }) != false
    }
}

struct CaptureVideoKeyframe: Codable, Sendable {
    let videoSeconds: Double
    let frame: CaptureVideoFrameDescriptor
}

struct CaptureVideoCounts: Codable, Sendable, Equatable {
    var sourceFrames = 0
    var rateLimitedFrames = 0
    var droppedFrames = 0
    var encodedFrames = 0
}

struct CaptureVideoDocument: Codable, Sendable {
    enum Status: String, Codable, Sendable { case recording, ready, failed }
    var schemaVersion = 1
    var source = "ARKit.capturedImage"
    let identity: CaptureVideoIdentity
    var status: Status
    var videoFile = "video.partial.mov"
    var firstARTimestamp: Double?
    var sourceWidth = 0
    var sourceHeight = 0
    var encodedWidth = 0
    var encodedHeight = 0
    var normalizedImageToDisplayTransform: [Float]?
    var targetFramesPerSecond = 15
    var durationSeconds: Double = 0
    var counts = CaptureVideoCounts()
    var keyframes: [CaptureVideoKeyframe] = []
    var updatedAt = Date()
    var endedAt: Date?
    var endReason: String?
    var failure: String?
    var notes = [
        "Frames from the same ARKit camera session as the measured mesh; no second camera session.",
        "Each movie uses one independent AR frame. Different segments are not registered or joined.",
        "H.264 camera imagery is compressed evidence, not raw depth or a textured 3D reconstruction.",
        "Source intrinsics refer to sourceWidth/sourceHeight; scaling and track orientation do not change saved source camera poses.",
        "Camera-to-world matrices use metres and Y up. AR tracking and measurement accuracy require independent review.",
        "Keyframes sample recorded camera poses about once per second; no route between unseen poses is inferred.",
        "AR timestamps preserve the camera monotonic clock. ISO-8601 wall-clock dates are serialized to seconds; they do not imply hardware timestamp precision.",
        "The movie contains no microphone audio. Rate limiting to 15 fps is separate from dropped encoder/backlog frames."
    ]

    var isCompleted: Bool {
        schemaVersion == 1 && source == "ARKit.capturedImage" && status == .ready
            && videoFile == "video.mov" && counts.encodedFrames > 0 && durationSeconds > 0
            && durationSeconds.isFinite && sourceWidth > 0 && sourceHeight > 0
            && encodedWidth > 0 && encodedHeight > 0 && max(encodedWidth, encodedHeight) <= 1920
            && normalizedImageToDisplayTransform.map({ Self.trackTransform(normalized: $0,
                width: encodedWidth, height: encodedHeight, orientation: identity.orientation) != nil }) != false
            && firstARTimestamp.map({ $0.isFinite && $0 >= 0 }) == true
            && counts.sourceFrames >= counts.encodedFrames && counts.droppedFrames >= 0 && counts.rateLimitedFrames >= 0
            && !keyframes.isEmpty && keyframes.count <= 7_200 && keyframes.allSatisfy {
                $0.videoSeconds.isFinite && $0.videoSeconds >= 0 && $0.videoSeconds <= durationSeconds && $0.frame.isValid
            }
            && zip(keyframes, keyframes.dropFirst()).allSatisfy { $0.videoSeconds < $1.videoSeconds && $0.frame.arTimestamp < $1.frame.arTimestamp }
    }

    static func outputDimensions(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width >= 2, height >= 2, width <= 8_192, height <= 8_192 else { return nil }
        let scale = min(1, 1920 / Double(max(width, height)))
        let w = max(2, Int(Double(width) * scale) / 2 * 2)
        let h = max(2, Int(Double(height) * scale) / 2 * 2)
        return (w, h)
    }

    static func trackTransform(normalized: [Float], width: Int, height: Int,
                               orientation: CaptureVideoOrientation) -> [Double]? {
        guard normalized.count == 6, normalized.allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let values = normalized.map(Double.init)
        guard abs(abs(values[0] * values[3] - values[1] * values[2]) - 1) < 0.001 else { return nil }
        let corners = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)].map { x, y in
            (values[0] * x + values[2] * y + values[4], values[1] * x + values[3] * y + values[5])
        }
        // A source image must remain complete. Never accept a viewport crop.
        guard abs((corners.map(\.0).min() ?? 1)) < 0.001,
              abs((corners.map(\.0).max() ?? 0) - 1) < 0.001,
              abs((corners.map(\.1).min() ?? 1)) < 0.001,
              abs((corners.map(\.1).max() ?? 0) - 1) < 0.001 else { return nil }
        let portrait = orientation == .portrait || orientation == .portraitUpsideDown
        let displayWidth = Double(portrait ? height : width), displayHeight = Double(portrait ? width : height)
        return [values[0] * displayWidth / Double(width), values[1] * displayHeight / Double(width),
                values[2] * displayWidth / Double(height), values[3] * displayHeight / Double(height),
                values[4] * displayWidth, values[5] * displayHeight]
    }
}

struct CaptureVideoResult: Sendable {
    let identity: CaptureVideoIdentity
    let document: CaptureVideoDocument
    let failure: String?
    var completed: Bool { failure == nil && document.isCompleted }
}

/// Reservation occurs before retaining a camera buffer or enqueueing CPU work.
/// At most two camera-pool buffers remain leased by this recorder at a time.
final class CaptureVideoAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var pending = 0
    private var lastTimestamp: Double?
    private var counts = CaptureVideoCounts()

    func reserve(timestamp: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return false }
        counts.sourceFrames += 1
        guard timestamp.isFinite, timestamp >= 0 else { counts.droppedFrames += 1; return false }
        if let lastTimestamp, timestamp <= lastTimestamp { counts.droppedFrames += 1; return false }
        if let lastTimestamp, timestamp - lastTimestamp < 1.0 / 15.0 - 0.000_001 {
            counts.rateLimitedFrames += 1; return false
        }
        guard pending < 2 else { counts.droppedFrames += 1; return false }
        pending += 1; lastTimestamp = timestamp
        return true
    }

    func release(encoded: Bool) {
        lock.lock(); defer { lock.unlock() }
        pending = max(0, pending - 1)
        if encoded { counts.encodedFrames += 1 } else { counts.droppedFrames += 1 }
    }

    func close() { lock.lock(); accepting = false; lock.unlock() }
    func snapshot() -> CaptureVideoCounts { lock.lock(); defer { lock.unlock() }; return counts }
}
