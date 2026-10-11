import Foundation

@main
struct VideoTourPolicyChecks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ description: String) {
            guard condition else { fatalError("Video tour policy: \(description)") }
            checks += 1
        }
        let projectID = UUID(), captureID = UUID(), segmentID = UUID(), frameID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let identity = CaptureVideoIdentity(captureID: captureID, projectID: projectID,
            segmentID: segmentID, frameID: frameID, startedAt: startedAt, orientation: .portrait)
        let transform: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 2,3,4,1]
        let intrinsics: [Float] = [800,0,0, 0,800,0, 640,360,1]
        func key(_ seconds: Double, tracking: String = "normal") -> CaptureVideoKeyframe {
            .init(videoSeconds: seconds, frame: .init(arTimestamp: 100+seconds,
                observedAt: startedAt.addingTimeInterval(seconds), cameraTransform: transform,
                intrinsics: intrinsics, trackingState: tracking))
        }
        var document = CaptureVideoDocument(identity: identity, status: .ready)
        document.videoFile = "video.mov"; document.firstARTimestamp = 100
        document.sourceWidth = 1_280; document.sourceHeight = 720
        document.encodedWidth = 1_280; document.encodedHeight = 720
        document.durationSeconds = 601
        document.counts.sourceFrames = 9_100; document.counts.encodedFrames = 9_000
        document.keyframes = (0...600).map { key(Double($0)) }
        document.endedAt = startedAt.addingTimeInterval(601)
        func rejects(_ value: CaptureVideoDocument, project: UUID? = nil,
                     capture: UUID? = nil, segment: UUID? = nil, frame: UUID? = nil,
                     start: Date? = nil) -> Bool {
            do {
                try VideoTourPolicy.validate(value, projectID: project ?? projectID,
                    captureID: capture ?? captureID, segmentID: segment ?? segmentID,
                    frameID: frame ?? frameID, startedAt: start ?? startedAt)
                return false
            } catch { return true }
        }
        expect(!rejects(document), "actual identity and monotonic calibrated keyframes are accepted")
        expect(VideoTourPolicy.recordedTrackTransform(document) == [0,1,-1,0,720,0],
               "legacy metadata without a recorded transform retains its original portrait mapping")
        var actualTransformDocument = document
        actualTransformDocument.normalizedImageToDisplayTransform = [0,-1,1,0,0,1]
        expect(VideoTourPolicy.recordedTrackTransform(actualTransformDocument) == [0,-1,1,0,0,1_280],
               "the actual recorded full-image transform takes precedence over the orientation guess")
        expect(!rejects(actualTransformDocument), "valid actual full-image transform remains a completed source")
        actualTransformDocument.normalizedImageToDisplayTransform = [2,0,0,2,0,0]
        expect(VideoTourPolicy.recordedTrackTransform(actualTransformDocument) == nil && rejects(actualTransformDocument),
               "a viewport crop cannot silently fall back to the legacy orientation guess")
        expect(rejects(document, project: UUID()), "another project cannot acquire the recording")
        expect(rejects(document, capture: UUID()), "capture identity must match the parent manifest")
        expect(rejects(document, segment: UUID()), "a selected segment never falls back to another segment")
        expect(rejects(document, frame: UUID()), "independent AR origins cannot be relabelled")
        expect(rejects(document, start: startedAt.addingTimeInterval(1)), "capture segment start must match")
        var bad = document; bad.status = .recording
        expect(rejects(bad), "a recording partial movie cannot become a ready route")
        bad = document; bad.videoFile = "../video.mov"
        expect(rejects(bad), "metadata does not select arbitrary movie paths")
        bad = document; bad.keyframes[5] = key(5.5)
        expect(!rejects(bad), "real irregular camera sample intervals remain valid")
        bad = document; bad.keyframes[5] = .init(videoSeconds: 5,
            frame: .init(arTimestamp: 107, observedAt: startedAt.addingTimeInterval(5),
                         cameraTransform: transform, intrinsics: intrinsics, trackingState: "normal"))
        expect(rejects(bad), "video time and the saved AR timestamp must refer to the same sample")
        bad = document; bad.keyframes[5] = .init(videoSeconds: 5,
            frame: .init(arTimestamp: 105, observedAt: startedAt.addingTimeInterval(-1),
                         cameraTransform: transform, intrinsics: intrinsics, trackingState: "normal"))
        expect(rejects(bad), "a sample predating the segment cannot be labelled as recorded evidence")
        bad = document; bad.endedAt = startedAt.addingTimeInterval(50)
        expect(rejects(bad), "sample dates after the finished movie are rejected")
        bad = document; bad.keyframes = [key(1),key(0)]
        expect(rejects(bad), "unordered poses cannot become an ordered route")
        bad = document; bad.durationSeconds = .infinity
        expect(rejects(bad), "nonfinite durations cannot be sampled")
        var brokenPose = transform; brokenPose[0] = 2
        expect(!VideoTourPolicy.validCameraTransform(brokenPose), "scaled geometry is not a camera pose")
        brokenPose = transform; brokenPose[4] = 0.5
        expect(!VideoTourPolicy.validCameraTransform(brokenPose), "nonorthogonal camera axes are rejected")
        brokenPose = transform; brokenPose[10] = -1
        expect(!VideoTourPolicy.validCameraTransform(brokenPose), "a reflected frame is not a camera rotation")
        brokenPose = transform; brokenPose[15] = 0
        expect(!VideoTourPolicy.validCameraTransform(brokenPose), "projective matrices are not accepted as AR camera poses")
        brokenPose = transform; brokenPose[12] = .nan
        expect(!VideoTourPolicy.validCameraTransform(brokenPose), "nonfinite camera translations are rejected")
        expect(VideoTourPolicy.validCameraTransform(transform), "source camera translation is preserved in metres")
        expect(!VideoTourPolicy.validIntrinsics([Float](repeating: 0, count: 9)), "zero focal lengths cannot calibrate images")
        expect(VideoTourPolicy.validIntrinsics(intrinsics), "original source-image calibration remains valid")

        let selected = try VideoTourPolicy.selectedKeyframes(document, maximumStations: 120, intervalSeconds: 3)
        expect(selected.count == 120, "long movies are bounded to the explicit station cap")
        expect(selected.first?.videoSeconds == 0 && selected.last?.videoSeconds == 600,
               "bounded sampling preserves first and last real stations")
        expect(zip(selected,selected.dropFirst()).allSatisfy { $0.videoSeconds < $1.videoSeconds },
               "downsampling retains strict acquisition order")
        expect(selected.allSatisfy { item in document.keyframes.contains { $0.videoSeconds == item.videoSeconds } },
               "sampling never fabricates unseen poses between actual recorded keyframes")
        let single = try VideoTourPolicy.selectedKeyframes(document, maximumStations: 1, intervalSeconds: 3)
        expect(single.count == 1 && single[0].videoSeconds == 0, "one remaining route slot cannot duplicate a point")
        var short = document; short.keyframes = [key(0),key(1),key(2),key(3),key(4)]
        let sparse = try VideoTourPolicy.selectedKeyframes(short, maximumStations: 120, intervalSeconds: 3)
        expect(sparse.map(\.videoSeconds) == [0,3,4], "ordinary short sampling retains its actual last frame")
        short.keyframes = [key(0,tracking:"limited"),key(1),key(2,tracking:"notAvailable"),key(3)]
        let tracked = try VideoTourPolicy.selectedKeyframes(short, maximumStations: 120, intervalSeconds: 1)
        expect(tracked.map(\.videoSeconds) == [1,3], "unstable AR poses remain in the movie but do not anchor stations")
        short.keyframes = [key(0,tracking:"limited")]
        do { _ = try VideoTourPolicy.selectedKeyframes(short, maximumStations: 120, intervalSeconds: 1); fatalError("missing rejection") }
        catch { expect(error as? VideoTourError == .noTrackedFrames, "no trustworthy frame produces a visible error") }
        for cap in [0,121,Int.max] {
            do { _ = try VideoTourPolicy.selectedKeyframes(document, maximumStations: cap, intervalSeconds: 3); fatalError("missing cap rejection") }
            catch { expect(true, "out-of-range station cap is rejected before allocation") }
        }
        for interval in [0.0,0.5,61.0,Double.infinity,Double.nan] {
            do { _ = try VideoTourPolicy.selectedKeyframes(document, maximumStations: 120, intervalSeconds: interval); fatalError("missing interval rejection") }
            catch { expect(true, "invalid sampling intervals do not create routes") }
        }

        let hash = String(repeating:"a",count:64)
        var provenance = VideoFrameProvenance(captureID: captureID, segmentID: segmentID,
            frameID: frameID, sourceVideoRelativePath: VideoTourPolicy.videoPath(captureID:captureID,segmentID:segmentID),
            sourceVideoSHA256: hash, sourceMetadataSHA256: hash,
            requestedVideoSeconds: 3, actualVideoSeconds: 3.0005, sourceARTimestamp: 103,
            sourceObservedAt: startedAt.addingTimeInterval(3), sourceIntrinsics: intrinsics,
            sourceWidth: 1_280, sourceHeight: 720, encodedWidth: 1_280, encodedHeight: 720,
            imageRotationApplied: .portrait, poseTimeOffsetSeconds: 0.0005, trackingState: "normal")
        expect(provenance.isValid, "a derived JPEG retains the exact movie and sampled pose provenance")
        var withTransform = provenance
        withTransform.normalizedImageToDisplayTransform = [0,-1,1,0,0,1]
        expect(withTransform.isValid, "derived metadata preserves the actual full-image display transform")
        withTransform.normalizedImageToDisplayTransform = [2,0,0,2,0,0]
        expect(!withTransform.isValid, "derived metadata rejects a cropped source transform")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(VideoFrameProvenance.self, from: encoder.encode(provenance))
        expect(restored == provenance, "source identity, orientation, calibration, sample clocks and hashes survive export")
        provenance.sourceVideoRelativePath = "../../video.mov"
        expect(!provenance.isValid, "a derivative cannot refer outside its exact project capture segment")
        provenance = restored; provenance.segmentID = UUID()
        expect(!provenance.isValid, "source relative path and segment identity cannot disagree")
        provenance = restored; provenance.sourceVideoSHA256 = "not-a-sha"
        expect(!provenance.isValid, "a video derivative requires a content digest")
        provenance = restored; provenance.sourceMetadataSHA256 = "not-a-sha"
        expect(!provenance.isValid, "pose provenance requires the exact sidecar digest")
        provenance = restored; provenance.actualVideoSeconds = 3.2; provenance.poseTimeOffsetSeconds = 0.2
        expect(!provenance.isValid, "a decoder fallback cannot borrow another frame's pose")
        provenance = restored; provenance.poseTimeOffsetSeconds = 0.009
        expect(!provenance.isValid, "declared timing offset must match the actual decoder moment")
        provenance = restored; provenance.trackingState = "limited"
        expect(!provenance.isValid, "derived station metadata does not hide unstable AR tracking")
        provenance = restored; provenance.sourceIntrinsics[0] = .nan
        expect(!provenance.isValid, "nonfinite calibration cannot be exported as measured evidence")
        provenance = restored; provenance.encodedWidth = 8_192
        expect(!provenance.isValid, "derived metadata preserves the recorder's encoded-size bounds")
        print("Video tour policy: \(checks) production checks passed")
    }
}
