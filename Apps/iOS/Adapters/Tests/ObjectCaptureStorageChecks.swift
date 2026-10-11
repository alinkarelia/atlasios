import Foundation
import AtlasCore

/// Exercises the real dataset writer against actual files, without camera or
/// reconstruction stubs. ImageIO also inspects the valid PNG when available.
@main struct ObjectCaptureStorageChecks {
    static func main() async throws {
        let managed = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-object-checks-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managed) }
        let project = UUID(), capture = UUID()
        let root = managed.appendingPathComponent(
            "Projects/\(project.uuidString)/Captures/Object-\(capture.uuidString)", isDirectory: true)
        let writer = ObjectCaptureDatasetWriter(root: root, managedRoot: managed)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fix = GeoLocationFix(coordinate: GeographicCoordinate(longitude: 30, latitude: 60),
            horizontalAccuracyMeters: 4, observedAt: start, source: .deviceLocation)
        let operatorIdentity = FieldCaptureOperator(userID: UUID(), displayName: "Capture operator")
        let metadata = ObjectCaptureManifest(id: capture, projectID: project, projectName: "Originals",
            frameID: UUID(), createdAt: start, geoTag: GeoTag(automaticFix: fix), locationObservations: [fix],
            captureOperator: operatorIdentity, device: FieldCaptureDevice(model: "fixture", osVersion: "test", appVersion: "test"),
            timeZoneIdentifier: "Europe/Moscow", utcOffsetSeconds: 10_800)
        note("create managed capture directories")
        try await writer.create(metadata)
        // One-pixel RGBA PNG with valid chunk CRCs and no capture-time/GPS tags.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNoOKDwHwAFhAJgx+/VVgAAAABJRU5ErkJggg==")!
        let image = root.appendingPathComponent("Images/original.png")
        try png.write(to: image)
        let sidecar = Data("source depth sidecar".utf8)
        try sidecar.write(to: root.appendingPathComponent("Images/original.depth"))
        let checkpoint = root.appendingPathComponent("Checkpoints/state.bin")
        try Data("checkpoint kept locally".utf8).write(to: checkpoint)
        note("finalize original images and sidecars")
        let complete = try await writer.completeDataset(metadata)
        precondition(complete.status == "ready" && complete.modelStatus == "captured" && complete.modelRelativePath == nil,
                     "A saved image dataset must be ready without claiming a reconstructed model") // 1
        precondition(complete.images.count == 1 && complete.images[0].capturedAt == nil &&
                     complete.images[0].timestampBasis == .importedAtUnknownCaptureTime,
                     "Session start/recovery time must not become an unknown image's exposure time") // 2
        precondition(complete.images[0].geoTag == nil && complete.geoTag == metadata.geoTag && complete.locationObservations == [fix],
                     "Operator GPS must remain separate from an image's absent original GPS") // 3
        precondition(complete.images[0].sha256 == FieldTransferDigest.sha256(png) && complete.images[0].byteCount == png.count,
                     "The source manifest must describe the exact original bytes") // 4
        precondition(complete.completedAssets == ["Images/original.depth", "Images/original.png"] &&
                     FileManager.default.fileExists(atPath: checkpoint.path),
                     "Native sidecars must travel with images while reconstruction checkpoints remain retained locally") // 5
        precondition(complete.endedAt == nil, "No final exposure time was observed; finishing metadata cannot invent it") // 6
        note("recover existing originals and metadata")
        let recoveredURL = try await writer.recoverDataset()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ObjectCaptureManifest.self, from: Data(contentsOf: recoveredURL))
        precondition(restored.createdAt == start && restored.captureOperator == operatorIdentity && restored.device == metadata.device,
                     "Recovery must preserve original creation time, operator and device") // 7
        precondition(restored.status == "ready" && restored.modelStatus == "captured" && restored.recoveredAt != nil && restored.endedAt == nil,
                     "Recovery must record its own time separately and leave the native dataset usable") // 8
        let preservedImage = try Data(contentsOf: image)
        let preservedSidecar = try Data(contentsOf: root.appendingPathComponent("Images/original.depth"))
        precondition(preservedImage == png && preservedSidecar == sidecar, "Finalization/recovery must never re-encode originals") // 9
        note("reject malformed model output")
        let invalidModel = root.appendingPathComponent("reconstruction-invalid.usdz")
        try Data("not a model".utf8).write(to: invalidModel)
        do {
            _ = try await writer.commitModel(from: invalidModel, manifest: restored)
            fatalError("A malformed output must not create a ready model")
        } catch ObjectCaptureStorageError.invalidModel {} // 10
        note("reject image symlink outside capture")
        let outside = managed.appendingPathComponent("outside.png")
        try png.write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Images/link.png"), withDestinationURL: outside)
        do {
            _ = try await writer.completeDataset(metadata)
            fatalError("A link outside the capture folder must not become a source asset")
        } catch ObjectCaptureStorageError.unsafePath {} // 11
        try FileManager.default.removeItem(at: root.appendingPathComponent("Images/link.png"))
        note("construct writer through trusted alias before capture folder exists")
        let alias = managed.deletingLastPathComponent()
            .appendingPathComponent("atlas-object-alias-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: managed)
        var aliasMetadata = metadata
        aliasMetadata.id = UUID(); aliasMetadata.frameID = UUID()
        let aliasedRoot = alias.appendingPathComponent(
            "Projects/\(project.uuidString)/Captures/Object-\(aliasMetadata.id.uuidString)", isDirectory: true)
        let aliasedWriter = ObjectCaptureDatasetWriter(root: aliasedRoot, managedRoot: alias)
        try await aliasedWriter.create(aliasMetadata)
        try png.write(to: aliasedRoot.appendingPathComponent("Images/original.png"))
        try sidecar.write(to: aliasedRoot.appendingPathComponent("Images/original.depth"))
        note("finalize real originals written through aliased root after creation")
        let aliased = try await aliasedWriter.completeDataset(aliasMetadata)
        precondition(aliased.images[0].sha256 == complete.images[0].sha256 &&
                     aliased.completedAssets == complete.completedAssets,
                     "A trusted /var-style managed-root alias must resolve without relaxing source containment") // 12
        print("ObjectCapture durable storage: 12 checks PASS (real originals/depth/hash, unknown photo time/GPS, recovery, invalid model and unsafe path rejection, canonical managed-root alias)")
    }
    private static func note(_ step: String) {
        FileHandle.standardError.write(Data("ObjectCapture storage step: \(step)\n".utf8))
    }
}
