import Foundation

@main
struct CaptureVideoDocumentChecks {
    static func main() throws {
        var checks = 0
        func check(_ result: Bool, _ message: String) {
            precondition(result, message); checks += 1
        }
        for (width, height, expectedW, expectedH) in [(1920, 1440, 1920, 1440), (3840, 2160, 1920, 1080),
            (1440, 1920, 1440, 1920), (1280, 720, 1280, 720), (641, 481, 640, 480)] {
            let dimensions = CaptureVideoDocument.outputDimensions(width: width, height: height)
            check(dimensions?.width == expectedW && dimensions?.height == expectedH, "Proportional even H264 dimensions")
        }
        for (width, height) in [(0, 100), (100, 0), (-1, 2), (1, 200), (9000, 200)] {
            check(CaptureVideoDocument.outputDimensions(width: width, height: height) == nil, "Reject invalid/unbounded image")
        }
        check(CaptureVideoDocument.trackTransform(normalized: [0,1,-1,0,1,0], width: 1920, height: 1440,
            orientation: .portrait) == [0,1,-1,0,1440,0], "AR source transform preserves full portrait image")
        check(CaptureVideoDocument.trackTransform(normalized: [-1,0,0,-1,1,1], width: 1920, height: 1440,
            orientation: .landscapeLeft) == [-1,0,0,-1,1920,1440], "Source-derived landscape rotation is retained")
        check(CaptureVideoDocument.trackTransform(normalized: [1,0,0,1,0,0], width: 1280, height: 720,
            orientation: .landscapeRight) == [1,0,0,1,0,0], "Native orientation is not guessed from a different source")
        for value: [Float] in [[2,0,0,1,-0.5,0], [0.5,0.5,0.5,0.5,0,0], [.nan,0,0,1,0,0], [1,0]] {
            check(CaptureVideoDocument.trackTransform(normalized: value, width: 1920, height: 1440,
                orientation: .portrait) == nil, "Crop, collapse or corrupt transform cannot silently alter source image")
        }
        let admission = CaptureVideoAdmission()
        check(admission.reserve(timestamp: 100), "Reserve first camera pool lease")
        check(!admission.reserve(timestamp: 100.01), "Intentional 15fps sampling skips dense AR frames")
        check(admission.reserve(timestamp: 100.1), "Reserve second camera buffer")
        check(!admission.reserve(timestamp: 100.2), "Backlog must never retain a third camera buffer")
        admission.release(encoded: true)
        check(admission.reserve(timestamp: 100.2), "Capacity returns only after conversion/append completes")
        admission.release(encoded: false)
        admission.release(encoded: true)
        check(!admission.reserve(timestamp: 99), "Reject out-of-order camera timestamp")
        check(!admission.reserve(timestamp: .nan), "Reject nonfinite camera timestamp")
        admission.close()
        check(!admission.reserve(timestamp: 101), "Finishing movie accepts no late camera buffers")
        let counts = admission.snapshot()
        check(counts.sourceFrames == 7 && counts.rateLimitedFrames == 1 && counts.encodedFrames == 2 && counts.droppedFrames == 4,
              "Sampling, encoder drops and encoded frames accounted independently")
        let identity = CaptureVideoIdentity(captureID: UUID(), projectID: UUID(), segmentID: UUID(), frameID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), orientation: .portrait)
        let pose = CaptureVideoFrameDescriptor(arTimestamp: 100, observedAt: identity.startedAt,
            cameraTransform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 3,4,5,1], intrinsics: [800,0,0, 0,800,0, 640,360,1], trackingState: "normal")
        check(pose.isValid, "Actual source pose and intrinsic dimensions")
        var document = CaptureVideoDocument(identity: identity, status: .ready)
        document.videoFile = "video.mov"; document.firstARTimestamp = 100
        document.sourceWidth = 1920; document.sourceHeight = 1440; document.encodedWidth = 1920; document.encodedHeight = 1440
        document.durationSeconds = 2
        document.counts = .init(sourceFrames: 120, rateLimitedFrames: 90, droppedFrames: 0, encodedFrames: 30)
        document.keyframes = [.init(videoSeconds: 0, frame: pose)]
        check(document.isCompleted, "A completed real-source movie requires encoded frames, valid poses and identity")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CaptureVideoDocument.self, from: encoder.encode(document))
        check(decoded.identity == identity && decoded.keyframes.first?.frame.cameraTransform == pose.cameraTransform,
              "Identity/original frame/units and source camera pose survive sidecar round-trip")
        for status in [CaptureVideoDocument.Status.recording, .failed] {
            var incomplete = document; incomplete.status = status
            check(!incomplete.isCompleted, "Partial/failed movie never masquerades as complete")
        }
        var invalid = document; invalid.videoFile = "video.partial.mov"
        check(!invalid.isCompleted, "Unsealed source filename cannot enter completed assets")
        invalid = document; invalid.counts.encodedFrames = 0
        check(!invalid.isCompleted, "No frames means no saved video")
        invalid = document; invalid.durationSeconds = .nan
        check(!invalid.isCompleted, "Nonfinite video duration rejected")
        invalid = document; invalid.keyframes = []
        check(!invalid.isCompleted, "Movie cannot lose all camera provenance")
        invalid = document; invalid.encodedWidth = 3840
        check(!invalid.isCompleted, "Video stays bounded to 1920")
        invalid = document; invalid.keyframes = [.init(videoSeconds: 5, frame: pose)]
        check(!invalid.isCompleted, "Keyframe lies inside actual movie timeline")
        invalid = document; invalid.normalizedImageToDisplayTransform = [2,0,0,1,-0.5,0]
        check(!invalid.isCompleted, "Completed source cannot hide a viewport crop")
        print("Capture video provenance/backpressure: \(checks) checks passed")
    }
}
