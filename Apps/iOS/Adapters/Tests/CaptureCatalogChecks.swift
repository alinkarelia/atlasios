import Foundation
import AtlasCore

@main struct CaptureCatalogChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID(), scan = UUID(), frame = UUID()
        let folder = root.appendingPathComponent("Projects/\(project)/Captures/Object-\(scan)")
        let images = folder.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let original = Data([1, 2, 3, 4, 5])
        try original.write(to: images.appendingPathComponent("original.HEIC"))
        try Data([6, 7]).write(to: images.appendingPathComponent("depth.bin"))
        let manifestFile = folder.appendingPathComponent("manifest.json")
        var object: [String: Any] = ["schemaVersion": 1, "source": "ObjectCapture", "status": "ready",
            "id": scan.uuidString, "projectID": project.uuidString, "frameID": frame.uuidString,
            "createdAt": "2026-10-11T12:00:00Z", "modelStatus": "unsupported",
            "completedAssets": ["Images/original.HEIC", "Images/depth.bin"],
            "images": [["relativePath": "Images/original.HEIC", "byteCount": 5,
                        "sha256": FieldTransferDigest.sha256(original)]]]
        func write() throws { try JSONSerialization.data(withJSONObject: object).write(to: manifestFile, options: .atomic) }
        func records() throws -> [ScanRecord] { try write(); return try CaptureCatalog.records(at: manifestFile, relativeTo: root) }
        let first = try records()
        precondition(first.count == 1 && first[0].id == scan && first[0].projectID == project && first[0].frameID == frame)
        precondition(first[0].source == .photogrammetry && first[0].status == .ready)
        precondition(first[0].assets.filter { $0.kind == .image }.count == 1 && first[0].assets.allSatisfy { $0.kind != .mesh })
        precondition(first[0].assets.contains { $0.kind == .depth && $0.byteCount == 2 })
        let repeated = try records()
        precondition(first[0].assets.map(\.id) == repeated[0].assets.map(\.id))
        func rejects(_ change: () -> Void) throws {
            let saved = object
            change()
            do { _ = try records(); preconditionFailure("Unsafe ObjectCapture metadata accepted") }
            catch { object = saved }
        }
        try rejects { object["completedAssets"] = ["../outside.HEIC"] }
        try rejects { object["completedAssets"] = ["Images/depth.bin"] }
        try rejects { object["images"] = [] }
        try rejects { object["images"] = [["relativePath": "Images/original.HEIC", "byteCount": 6, "sha256": String(repeating: "a", count: 64)]] }
        try rejects { object["modelRelativePath"] = "missing.usdz" }
        try rejects { object["schemaVersion"] = 2 }
        let outside = root.appendingPathComponent("outside.HEIC")
        try original.write(to: outside)
        let linked = images.appendingPathComponent("linked.HEIC")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        try rejects {
            object["images"] = [["relativePath": "Images/linked.HEIC", "byteCount": 5, "sha256": String(repeating: "a", count: 64)]]
            object["completedAssets"] = ["Images/linked.HEIC"]
        }
        try Data([0x50, 0x4b]).write(to: folder.appendingPathComponent("object.usdz"))
        object["modelRelativePath"] = "object.usdz"
        object["completedAssets"] = ["Images/original.HEIC", "Images/depth.bin", "object.usdz"]
        let modeled = try records()
        precondition(modeled[0].assets.contains { $0.kind == .mesh })
        let retained = try Data(contentsOf: images.appendingPathComponent("original.HEIC"))
        precondition(retained == original)
        // Structural derivatives belong to the original semantic capture/frame.
        // A fixed filename inside a UUID namespace is permitted, arbitrary paths are not.
        let derivativeID = UUID()
        let relative = "empty-room/\(derivativeID.uuidString)/"
        let derived = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        for name in ["room.json", "room-data.json", "room.usdz"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        let names = ["structural-room.json", "structural-room.usdz", "structural-room.obj", "dimensions.json", "model.png", "measurements.pdf"]
        for name in names { try Data(name.utf8).write(to: derived.appendingPathComponent(name)) }
        object["source"] = "RoomPlan"
        object["completedAssets"] = ["room.json", "room-data.json", "room.usdz"] + names.map { relative + $0 }
        let structural = try records()
        precondition(structural.count == 1 && structural[0].id == scan && structural[0].frameID == frame)
        precondition(structural[0].assets.filter { $0.kind == .mesh }.count == 3)
        precondition(structural[0].assets.contains { $0.relativePath.hasSuffix("dimensions.json") })
        let derivedAgain = try records()
        precondition(structural[0].assets.map(\.id) == derivedAgain[0].assets.map(\.id))
        let sourceBeforeReview = try Data(contentsOf: folder.appendingPathComponent("room.json"))
        let reviewFile = derived.appendingPathComponent("surface-review.json")
        let rawReview = Data("{\"schemaVersion\":1,\"events\":[]}".utf8)
        try rawReview.write(to: reviewFile)
        object["completedAssets"] = ["room.json", "room.usdz"] + names.map { relative + $0 } + [relative + "surface-review.json"]
        let reviewed = try records()
        precondition(reviewed[0].assets.contains { $0.relativePath.hasSuffix("surface-review.json") && $0.kind == .cameraMetadata && $0.byteCount == rawReview.count })
        let sourceAfterReview = try Data(contentsOf: folder.appendingPathComponent("room.json"))
        precondition(sourceAfterReview == sourceBeforeReview)
        try Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1).write(to: reviewFile)
        do { _ = try records(); preconditionFailure("Oversized review accepted") } catch { }
        try FileManager.default.removeItem(at: reviewFile)
        try FileManager.default.createSymbolicLink(at: reviewFile, withDestinationURL: outside)
        do { _ = try records(); preconditionFailure("Aliased review accepted") } catch { }
        try FileManager.default.removeItem(at: reviewFile)
        try rawReview.write(to: reviewFile)
        try rejects { object["completedAssets"] = ["room.json", "room.usdz", "empty-room/surface-review.json"] }
        try rejects { object["completedAssets"] = ["room.json", "room.usdz", relative + "../surface-review.json"] }
        try rejects { object["completedAssets"] = ["room.json", "room.usdz", relative + "unexpected.json"] }
        try rejects { object["completedAssets"] = ["room.json", "room.usdz", "empty-room/not-a-uuid/dimensions.json"] }
        try rejects { object["completedAssets"] = ["room.json", "room.usdz", relative + "../dimensions.json"] }
        try rejects { object["completedAssets"] = ["room.json", "room.usdz", "/" + relative + "dimensions.json"] }
        let segmentID = UUID()
        let segment = folder.appendingPathComponent("segments/\(segmentID.uuidString)")
        try FileManager.default.createDirectory(at: segment, withIntermediateDirectories: true)
        let videoRelative = "segments/\(segmentID.uuidString)/"
        try Data("synthetic movie byte fixture".utf8).write(to: segment.appendingPathComponent("video.mov"))
        let identity = CaptureVideoIdentity(captureID: scan, projectID: project, segmentID: segmentID, frameID: frame,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), orientation: .portrait)
        var videoDocument = CaptureVideoDocument(identity: identity, status: .ready)
        videoDocument.videoFile = "video.mov"; videoDocument.firstARTimestamp = 100
        videoDocument.sourceWidth = 1_920; videoDocument.sourceHeight = 1_440
        videoDocument.encodedWidth = 1_920; videoDocument.encodedHeight = 1_440
        videoDocument.durationSeconds = 2
        videoDocument.counts = .init(sourceFrames: 60, rateLimitedFrames: 30, droppedFrames: 0, encodedFrames: 30)
        videoDocument.keyframes = [.init(videoSeconds: 0, frame: .init(arTimestamp: 100, observedAt: identity.startedAt,
            cameraTransform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1], intrinsics: [800,0,0, 0,800,0, 640,360,1], trackingState: "normal"))]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        func writeVideo() throws { try encoder.encode(videoDocument).write(to: segment.appendingPathComponent("video.json"), options: .atomic) }
        try writeVideo()
        object["source"] = "ARKit.sceneReconstruction"
        object["segments"] = [["id": segmentID.uuidString, "frameID": frame.uuidString,
            "startedAt": ISO8601DateFormatter().string(from: identity.startedAt)]]
        object["completedAssets"] = [videoRelative + "video.mov", videoRelative + "video.json"]
        let videoOnly = try records()
        precondition(videoOnly.count == 1 && videoOnly[0].id == segmentID && videoOnly[0].status == .ready)
        precondition(videoOnly[0].assets.contains { $0.kind == .video } && !videoOnly[0].assets.contains { $0.kind == .mesh })
        object["status"] = "recording"
        object["segments"] = [["id": segmentID.uuidString, "frameID": frame.uuidString,
            "startedAt": ISO8601DateFormatter().string(from: identity.startedAt), "endedAt": "2026-10-11T12:00:00Z"],
            ["id": UUID().uuidString, "frameID": UUID().uuidString, "startedAt": "2026-10-11T12:01:00Z"]]
        let continued = try records()
        precondition(continued.count == 2 && continued[0].status == .ready && continued[1].status == .recording,
            "Sealed original remains usable while the next independent fragment records")
        object["status"] = "ready"
        object["segments"] = [["id": segmentID.uuidString, "frameID": frame.uuidString,
            "startedAt": ISO8601DateFormatter().string(from: identity.startedAt)]]
        try rejects { object["completedAssets"] = [videoRelative + "video.mov"] }
        try rejects { object["completedAssets"] = [videoRelative + "video.json"] }
        try rejects { object["projectID"] = UUID().uuidString }
        videoDocument.status = .recording; try writeVideo()
        do { _ = try records(); preconditionFailure("Partial video accepted as ready") } catch { }
        videoDocument.status = .ready; videoDocument.keyframes = []; try writeVideo()
        do { _ = try records(); preconditionFailure("Video without source poses accepted") } catch { }
        print("CaptureCatalog: 36 dataset readiness, original/derivative/review/video identity and path isolation checks passed.")
    }
}
