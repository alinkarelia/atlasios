import Foundation

/// A derived station refers to the immutable camera movie and its exact pose
/// sidecar. Movie time is independent of GPS; an AR frame is never a geo fix.
struct VideoFrameProvenance: Codable, Sendable, Equatable {
    var schemaVersion = 1
    var source = "ARKitVideoDerivedFrame"
    var captureID: UUID
    var segmentID: UUID
    var frameID: UUID
    /// Relative to this project's Captures directory, not the app's root.
    var sourceVideoRelativePath: String
    var sourceVideoSHA256: String
    var sourceMetadataSHA256: String
    var requestedVideoSeconds: Double
    var actualVideoSeconds: Double
    var sourceARTimestamp: Double
    var sourceObservedAt: Date
    /// The original, unrotated source camera calibration is retained. It must
    /// not be applied directly to the smaller, orientation-corrected JPEG.
    var sourceIntrinsics: [Float]
    var sourceWidth: Int
    var sourceHeight: Int
    var encodedWidth: Int
    var encodedHeight: Int
    var imageRotationApplied: CaptureVideoOrientation
    var poseTimeOffsetSeconds: Double
    var trackingState: String

    var isValid: Bool {
        schemaVersion == 1 && source == "ARKitVideoDerivedFrame"
            && sourceVideoRelativePath == VideoTourPolicy.videoPath(captureID: captureID, segmentID: segmentID)
            && VideoTourPolicy.validHash(sourceVideoSHA256) && VideoTourPolicy.validHash(sourceMetadataSHA256)
            && requestedVideoSeconds.isFinite && requestedVideoSeconds >= 0
            && actualVideoSeconds.isFinite && actualVideoSeconds >= 0
            && sourceARTimestamp.isFinite && sourceARTimestamp >= 0
            && sourceObservedAt.timeIntervalSince1970.isFinite
            && poseTimeOffsetSeconds.isFinite && abs(poseTimeOffsetSeconds) <= VideoTourPolicy.maximumPoseTimeOffset
            && abs((actualVideoSeconds - requestedVideoSeconds) - poseTimeOffsetSeconds) < 0.000_001
            && VideoTourPolicy.validIntrinsics(sourceIntrinsics)
            && (2...8_192).contains(sourceWidth) && (2...8_192).contains(sourceHeight)
            && (2...1_920).contains(encodedWidth) && (2...1_920).contains(encodedHeight)
            && trackingState == "normal"
    }
}

enum VideoTourPolicy {
    /// A recorded camera pose belongs to the actual recorded frame. Reject a
    /// decoder's distant fallback rather than pretending it has that pose.
    static let maximumPoseTimeOffset = 0.01
    static func validHash(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy(\.isHexDigit) }
    static func videoPath(captureID: UUID, segmentID: UUID) -> String {
        "lidar-\(captureID.uuidString)/segments/\(segmentID.uuidString)/video.mov"
    }
    static func metadataPath(captureID: UUID, segmentID: UUID) -> String {
        "lidar-\(captureID.uuidString)/segments/\(segmentID.uuidString)/video.json"
    }
    static func validIntrinsics(_ values: [Float]) -> Bool {
        values.count == 9 && values.allSatisfy(\.isFinite)
            && values[0] > 0 && values[4] > 0 && abs(values[8] - 1) < 0.001
    }
    static func validCameraTransform(_ values: [Float]) -> Bool {
        guard values.count == 16, values.allSatisfy(\.isFinite),
              abs(values[3]) < 0.001, abs(values[7]) < 0.001,
              abs(values[11]) < 0.001, abs(values[15] - 1) < 0.001 else { return false }
        for column in 0..<3 {
            let start = column*4
            let length = values[start]*values[start]+values[start+1]*values[start+1]+values[start+2]*values[start+2]
            guard abs(length - 1) < 0.02 else { return false }
            for other in (column+1)..<3 {
                let offset = other*4
                let dot = values[start]*values[offset]+values[start+1]*values[offset+1]+values[start+2]*values[offset+2]
                guard abs(dot) < 0.02 else { return false }
            }
        }
        // A reflection is not a camera-to-world rotation.
        let determinant = values[0]*(values[5]*values[10]-values[6]*values[9])
            - values[4]*(values[1]*values[10]-values[2]*values[9])
            + values[8]*(values[1]*values[6]-values[2]*values[5])
        return abs(determinant - 1) < 0.03
    }

    static func validate(_ document: CaptureVideoDocument, projectID: UUID, captureID: UUID,
                         segmentID: UUID, frameID: UUID, startedAt: Date) throws {
        guard document.isCompleted, document.identity.projectID == projectID,
              document.identity.captureID == captureID, document.identity.segmentID == segmentID,
              document.identity.frameID == frameID, document.identity.startedAt == startedAt,
              document.durationSeconds <= 7_201,
              let first = document.firstARTimestamp,
              document.keyframes.allSatisfy({
                  abs(($0.frame.arTimestamp - first) - $0.videoSeconds) < 0.002
                    && $0.frame.observedAt >= document.identity.startedAt
                    && $0.frame.trackingState.count <= 250
                    && validIntrinsics($0.frame.intrinsics)
                    && validCameraTransform($0.frame.cameraTransform)
              }) else { throw VideoTourError.invalidSource }
        if let endedAt = document.endedAt {
            guard endedAt >= startedAt,
                  document.keyframes.allSatisfy({ $0.frame.observedAt <= endedAt.addingTimeInterval(1) }) else {
                throw VideoTourError.invalidSource
            }
        }
    }

    /// Select only real recorded keyframes with normal AR tracking. Sampling
    /// is bounded, preserves acquisition order and never interpolates poses.
    static func selectedKeyframes(_ document: CaptureVideoDocument, maximumStations: Int,
                                  intervalSeconds: Double) throws -> [CaptureVideoKeyframe] {
        guard (1...120).contains(maximumStations), intervalSeconds.isFinite,
              (1...60).contains(intervalSeconds), document.isCompleted else { throw VideoTourError.invalidSource }
        let candidates = document.keyframes.filter { $0.frame.trackingState == "normal" }
        guard let first = candidates.first else { throw VideoTourError.noTrackedFrames }
        var selected = [first]
        for candidate in candidates.dropFirst() {
            if candidate.videoSeconds - selected[selected.count-1].videoSeconds >= intervalSeconds {
                selected.append(candidate)
            }
        }
        if let last = candidates.last, last.videoSeconds > selected[selected.count-1].videoSeconds { selected.append(last) }
        guard selected.count > maximumStations else { return selected }
        if maximumStations == 1 { return [selected[0]] }
        return (0..<maximumStations).map { index in
            selected[Int((Double(index)*Double(selected.count-1)/Double(maximumStations-1)).rounded())]
        }
    }
}

enum VideoTourError: LocalizedError {
    case invalidSource, sourceChanged, noTrackedFrames, unreadableMovie, frameTimeMismatch, invalidFrame, importInProgress
    var errorDescription: String? {
        switch self {
        case .invalidSource: "Видео или метаданные не соответствуют завершённому фрагменту LiDAR этого проекта."
        case .sourceChanged: "Исходное видео или метаданные изменились. Обновите список и выберите фрагмент заново."
        case .noTrackedFrames: "В видео нет сохранённых точек с устойчивым AR-слежением. Исходное видео сохранено; выберите другой фрагмент."
        case .unreadableMovie: "Не удалось открыть завершённое видео. Исходный файл остаётся в проекте."
        case .frameTimeMismatch: "Декодер вернул другой момент видео. Такой кадр не получит позу выбранной точки."
        case .invalidFrame: "Не удалось создать фотографию остановки из кадра видео."
        case .importInProgress: "Дождитесь завершения текущего извлечения кадров или отмените его."
        }
    }
}
