import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import CryptoKit

/// The sink is the only seam: the production recorder, MOV decoder, importer,
/// source identity/path/digest checks and pose policy run unchanged. Actual app
/// evidence persistence is also checked by the iOS SDK/UI build separately.
struct PhotoEvidence: Sendable {
    let id: UUID
    let data: Data
    let capturedAt: Date
    let cameraFrameID: UUID
    let cameraTransform: [Float]
    let videoFrameProvenance: VideoFrameProvenance
}

@MainActor
final class EvidenceService {
    private(set) var photos = [PhotoEvidence]()
    func saveVideoFrame(data: Data, projectID: UUID, outputDirectory: URL,
                        capturedAt: Date, cameraFrameID: UUID, cameraTransform: [Float],
                        provenance: VideoFrameProvenance) async throws -> PhotoEvidence {
        precondition(provenance.isValid && provenance.frameID == cameraFrameID && provenance.sourceObservedAt == capturedAt)
        let photo = PhotoEvidence(id: UUID(), data: data, capturedAt: capturedAt,
            cameraFrameID: cameraFrameID, cameraTransform: cameraTransform, videoFrameProvenance: provenance)
        let folder = outputDirectory.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(photo.id.uuidString).jpg"), options: .atomic)
        photos.append(photo)
        return photo
    }
}

@MainActor
final class VideoImportCancellation {
    var task: Task<[PhotoEvidence], Error>?
}

@main
struct VideoTourImporterChecks {
    static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ description: String) {
            guard condition else { fatalError("Actual video tour importer: \(description)") }
            checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-tour-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = CaptureVideoIdentity(captureID: UUID(), projectID: UUID(), segmentID: UUID(), frameID: UUID(),
            startedAt: Date(), orientation: .portrait)
        let captureRoot = root.appendingPathComponent("lidar-\(identity.captureID.uuidString)",isDirectory:true)
        let segmentRoot = captureRoot.appendingPathComponent("segments/\(identity.segmentID.uuidString)",isDirectory:true)
        let recorder = CaptureVideoRecorder(identity: identity,directory: segmentRoot) { _, _ in }
        let actualImageTransform: [Float] = [0,-1,1,0,0,1]
        var sourceImage: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        expect(CVPixelBufferCreate(kCFAllocatorDefault,160,120,kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,&sourceImage) == kCVReturnSuccess,"synthetic actual encoder input available")
        guard let sourceImage else { fatalError("Missing synthetic image") }
        expect(CVPixelBufferLockBaseAddress(sourceImage,[]) == kCVReturnSuccess,"camera-like immutable pixel buffer writable during fixture setup")
        if let memory = CVPixelBufferGetBaseAddress(sourceImage) {
            memory.initializeMemory(as: UInt8.self,repeating: 160,count: CVPixelBufferGetBytesPerRow(sourceImage)*120)
        }
        CVPixelBufferUnlockBaseAddress(sourceImage,[])
        func offer(_ index: Int) {
            recorder.offer(image:sourceImage,descriptor:.init(arTimestamp: 100+Double(index)/15,
                observedAt:Date(),cameraTransform:[1,0,0,0,0,1,0,0,0,0,1,0,Float(index)/10,0,0,1],
                intrinsics:[140,0,0,0,140,0,80,60,1],trackingState:"normal",
                normalizedImageToDisplayTransform:actualImageTransform))
        }
        offer(0)
        try await Task.sleep(for:.seconds(2))
        for index in 1...34 { offer(index); try await Task.sleep(for:.milliseconds(80)) }
        let result = await recorder.finish(reason:"syntheticVideoTourIntegration")
        expect(result.completed,"production recorder seals its actual H264 movie")
        expect(result.document.keyframes.count >= 3,"actual movie contains several real source pose keys")
        expect(result.document.normalizedImageToDisplayTransform == actualImageTransform,
               "the actual AR full-image transform is retained rather than guessed from orientation")

        let manifestURL = captureRoot.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        struct Parent: Encodable {
            struct Segment: Encodable { let id: UUID; let frameID: UUID; let startedAt: Date }
            var schemaVersion = 1
            var source = "ARKit.sceneReconstruction"
            let id: UUID
            let projectID: UUID
            var status = "ready"
            let segments: [Segment]
            let completedAssets: [String]
        }
        let parent = Parent(id:identity.captureID,projectID:identity.projectID,
            segments:[.init(id:identity.segmentID,frameID:identity.frameID,startedAt:identity.startedAt)],
            completedAssets:["segments/\(identity.segmentID.uuidString)/video.mov","segments/\(identity.segmentID.uuidString)/video.json"])
        let parentData = try encoder.encode(parent)
        try parentData.write(to:manifestURL,options:.atomic)
        let movieURL = segmentRoot.appendingPathComponent("video.mov")
        let sidecarURL = segmentRoot.appendingPathComponent("video.json")
        let originalMovie = try Data(contentsOf:movieURL), originalSidecar = try Data(contentsOf:sidecarURL)
        let importer = VideoTourImporter()
        let listing = try await importer.sources(projectID:identity.projectID,directory:root)
        expect(listing.issues.isEmpty && listing.sources.count == 1,"finished exact project segment appears explicitly")
        guard let source = listing.sources.first else { fatalError("Missing ready source") }
        expect(source.id == identity.segmentID && source.frameID == identity.frameID,"source identity retains independent AR origin")
        expect(source.videoRelativePath == VideoTourPolicy.videoPath(captureID:identity.captureID,segmentID:identity.segmentID),"source path is the actual selected segment")
        let sink = await MainActor.run { EvidenceService() }
        let photos = try await importer.importStations(source:source,projectID:identity.projectID,directory:root,
            evidence:sink,maximumStations:10,intervalSeconds:1)
        expect(photos.count >= 3 && photos.count <= 10,"actual image generator extracts bounded ordered stations")
        let movieHash = SHA256.hash(data:originalMovie).map { String(format:"%02x",$0) }.joined()
        for photo in photos {
            let p = photo.videoFrameProvenance
            expect(p.isValid && p.sourceVideoSHA256 == movieHash,"derived image retains actual original movie hash")
            expect(p.frameID == identity.frameID && p.captureID == identity.captureID && p.segmentID == identity.segmentID,"derived image retains actual project capture/segment/frame provenance")
            expect(p.normalizedImageToDisplayTransform == actualImageTransform,"derived JPEG retains the actual source transform even when it differs from legacy rotation")
            expect(abs(p.actualVideoSeconds-p.requestedVideoSeconds) <= 0.01,"actual decoder moment belongs to the selected recorded pose")
            expect(photo.cameraTransform.count == 16 && photo.capturedAt == p.sourceObservedAt,"recorded camera pose/date survive extraction")
            guard let image = CGImageSourceCreateWithData(photo.data as CFData,nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any] else {
                fatalError("Invalid derived JPEG")
            }
            expect(properties[kCGImagePropertyPixelWidth] as? Int == 120
                && properties[kCGImagePropertyPixelHeight] as? Int == 160,"source portrait transform applies to real derived JPEG pixels")
        }
        let retainedMovie = try Data(contentsOf:movieURL), retainedSidecar = try Data(contentsOf:sidecarURL)
        expect(retainedMovie == originalMovie && retainedSidecar == originalSidecar,"extractor preserves original movie and metadata byte-for-byte")
        expect(zip(photos,photos.dropFirst()).allSatisfy { $0.videoFrameProvenance.actualVideoSeconds < $1.videoFrameProvenance.actualVideoSeconds },"ordered stations use actual movie times")

        let wrongProject = try await importer.sources(projectID:UUID(),directory:root)
        expect(wrongProject.sources.isEmpty && !wrongProject.issues.isEmpty,"another project's source is rejected visibly")
        var changedParent = parent; changedParent.status = "paused"
        try encoder.encode(changedParent).write(to:manifestURL,options:.atomic)
        let paused = try await importer.sources(projectID:identity.projectID,directory:root)
        expect(paused.sources.isEmpty,"unfinished parent is not silently offered as ready")
        do {
            _ = try await importer.importStations(source:source,projectID:identity.projectID,directory:root,evidence:sink)
            fatalError("An altered selected parent must be rejected")
        } catch { expect(error as? VideoTourError == .sourceChanged,"selection detects changed source manifest") }
        try parentData.write(to:manifestURL,options:.atomic)
        var broken = result.document
        broken.keyframes[0] = .init(videoSeconds:0,frame:.init(arTimestamp:999,
            observedAt:Date(),cameraTransform:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],
            intrinsics:[140,0,0,0,140,0,80,60,1],trackingState:"normal"))
        try encoder.encode(broken).write(to:sidecarURL,options:.atomic)
        let corrupt = try await importer.sources(projectID:identity.projectID,directory:root)
        expect(corrupt.sources.isEmpty && !corrupt.issues.isEmpty,"bad time/pose sidecar is reported rather than relabelled")
        try originalSidecar.write(to:sidecarURL,options:.atomic)
        let cancellation = await MainActor.run { VideoImportCancellation() }
        let cancelSink = await MainActor.run { EvidenceService() }
        let extraction = Task {
            try await importer.importStations(source:source,projectID:identity.projectID,directory:root,
                evidence:cancelSink,maximumStations:10,intervalSeconds:1,progress:{ done, _ in
                    if done == 1 { cancellation.task?.cancel() }
                })
        }
        await MainActor.run { cancellation.task = extraction }
        do { _ = try await extraction.value; fatalError("Mid-extraction cancellation must be visible") }
        catch { expect(error is CancellationError,"caller cancellation stops extraction between real decoded frames") }
        let cancelledPhotos = await MainActor.run { cancelSink.photos }
        expect(cancelledPhotos.count == 1,"already saved evidence remains available after cancellation")
        let afterCancel = try Data(contentsOf:movieURL)
        expect(afterCancel == originalMovie,"cancellation never removes or truncates the source movie")
        let legacyIdentity = CaptureVideoIdentity(captureID:UUID(),projectID:identity.projectID,
            segmentID:UUID(),frameID:UUID(),startedAt:Date(),orientation:.portrait)
        let legacyRoot = root.appendingPathComponent("lidar-\(legacyIdentity.captureID.uuidString)",isDirectory:true)
        let legacySegment = legacyRoot.appendingPathComponent("segments/\(legacyIdentity.segmentID.uuidString)",isDirectory:true)
        let legacyRecorder = CaptureVideoRecorder(identity:legacyIdentity,directory:legacySegment) { _, _ in }
        legacyRecorder.offer(image:sourceImage,descriptor:.init(arTimestamp:500,observedAt:Date(),
            cameraTransform:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],
            intrinsics:[140,0,0,0,140,0,80,60,1],trackingState:"normal"))
        try await Task.sleep(for:.seconds(2))
        let legacyResult = await legacyRecorder.finish(reason:"syntheticLegacyTransform")
        expect(legacyResult.completed && legacyResult.document.normalizedImageToDisplayTransform == nil,
               "older synthetic sources retain the existing legacy orientation format")
        let legacyParent = Parent(id:legacyIdentity.captureID,projectID:identity.projectID,
            segments:[.init(id:legacyIdentity.segmentID,frameID:legacyIdentity.frameID,startedAt:legacyIdentity.startedAt)],
            completedAssets:["segments/\(legacyIdentity.segmentID.uuidString)/video.mov","segments/\(legacyIdentity.segmentID.uuidString)/video.json"])
        try encoder.encode(legacyParent).write(to:legacyRoot.appendingPathComponent("manifest.json"),options:.atomic)
        let both = try await importer.sources(projectID:identity.projectID,directory:root)
        guard let legacySource = both.sources.first(where:{$0.segmentID == legacyIdentity.segmentID}) else { fatalError("Missing explicit legacy source") }
        let legacyPhotos = try await importer.importStations(source:legacySource,projectID:identity.projectID,
            directory:root,evidence:sink,maximumStations:1)
        expect(legacyPhotos.count == 1 && legacyPhotos[0].videoFrameProvenance.normalizedImageToDisplayTransform == nil,
               "the production importer also decodes legacy sources without inventing new display metadata")
        print("Actual MOV → photo-tour integration: \(checks) checks passed; original bytes, timestamp-matched portrait pixels, pose/frame/hash provenance, visible identity failures and mid-extraction cancellation. Synthetic encoder input; iPhone sensors not tested.")
    }
}
