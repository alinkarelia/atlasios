import Foundation
import AtlasCore

// These DTOs isolate the file assembler from UIKit and the network; the actual
// transport has a separate integration smoke against the real server.
enum TeamError: LocalizedError { case rejected(String); var errorDescription: String? { switch self { case let .rejected(value): value } } }
enum FieldTransportError: Error { case invalidResponse, alteredOriginal, tooLarge }
enum FieldTransferTransport { static let maximumChunk = 1_048_576 }
struct RemoteFieldMaterial: Codable, Sendable {
    var captureID: UUID; var projectID: UUID; var manifest: FieldTransferManifest
}
struct DownloadedFieldMaterial: Sendable {
    var material: RemoteFieldMaterial; var directory: URL; var snapshot: AtlasProjectSnapshot
}

@main struct FieldAssemblerChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-assembler-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = AtlasProject(name: "Originals", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID()))
        let frame = project.coordinateReference.frameID!
        let photoID = UUID(), sourceID = UUID(), segment2ID = UUID()
        let prefix = "Projects/" + project.id.uuidString + "/Captures/"
        let captures = directory.appendingPathComponent(String(prefix.dropLast()))
        let evidence = captures.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let original = Data("Original image bytes including encoded metadata".utf8)
        let photoPath = "evidence/" + photoID.uuidString + ".jpg"
        try original.write(to: captures.appendingPathComponent(photoPath))
        let imported = Date(timeIntervalSince1970: 1_700_000_000)
        let photoMetadata: [String: Any] = ["id": photoID.uuidString, "projectID": project.id.uuidString,
            "createdAt": ISO8601DateFormatter().string(from: imported), "relativePath": photoPath,
            "metadataPath": "evidence/" + photoID.uuidString + ".json", "source": "photoLibrary",
            "byteCount": original.count, "sha256": FieldTransferDigest.sha256(original)]
        try JSONSerialization.data(withJSONObject: photoMetadata, options: [.sortedKeys]).write(to: evidence.appendingPathComponent(photoID.uuidString + ".json"))
        let scanDirectory = captures.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: scanDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: scanDirectory.appendingPathComponent("manifest.json"))
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: scanDirectory.appendingPathComponent("one.obj"))
        try Data("v 0 0 0\nv 2 0 0\nv 0 2 0\nf 1 2 3\n".utf8).write(to: scanDirectory.appendingPathComponent("two.obj"))
        func asset(_ name: String, _ kind: SourceAssetKind) -> SourceAssetReference {
            SourceAssetReference(relativePath: prefix + "capture/" + name, kind: kind, byteCount: 0)
        }
        let scans = [ScanRecord(id: sourceID, projectID: project.id, source: .liDAR, status: .ready, frameID: frame,
            assets: [asset("manifest.json", .cameraMetadata), asset("one.obj", .mesh)], createdAt: imported),
            ScanRecord(id: segment2ID, projectID: project.id, source: .liDAR, status: .ready, frameID: UUID(),
            assets: [asset("manifest.json", .cameraMetadata), asset("two.obj", .mesh)], createdAt: imported)]
        var feature = AtlasFeature(projectID: project.id, label: "A", category: .grave,
            geometry: .metricPolygon(MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 2, y: 0), .init(x: 0, y: 2)])))
        var plan = AtlasFloorPlan(projectID: project.id, frameID: frame, name: "First plan")
        var measurement = MeasurementRecord(projectID: project.id, source: .manualReference, originalMeters: 2)
        var snapshot = AtlasProjectSnapshot(project: project, features: [feature], floorPlans: [plan], scans: scans, measurements: [measurement])
        let scope = FieldTransferScope(serverOrigin: "https://team.example.test", userID: UUID(), organizationID: UUID())
        let device = FieldCaptureDevice(model: "fixture", osVersion: "test", appVersion: "test")
        let assembler = FieldTransferAssembler(directory: directory)
        let first = try await assembler.prepare(snapshot: snapshot, assetDirectory: directory, scope: scope, device: device)
        precondition(first.count == 1)
        let manifest = first[0].manifest
        precondition(manifest.materials.first(where: { $0.id == photoID })?.capturedAt == nil)
        precondition(manifest.materials.first(where: { $0.id == photoID })?.importedAt == imported)
        precondition(manifest.assets.first(where: { $0.kind == .originalPhoto })?.sha256 == FieldTransferDigest.sha256(original))
        let repeated = try await assembler.prepare(snapshot: snapshot, assetDirectory: directory, scope: scope, device: device, previous: [manifest])
        precondition(repeated.isEmpty, "Shared scan manifests must not produce duplicate sends")
        feature.notes = "Manual correction"; feature.revision = 1
        snapshot.features = [feature]
        let updated = try await assembler.prepare(snapshot: snapshot, assetDirectory: directory, scope: scope, device: device, previous: [manifest])
        precondition(updated.count == 1 && updated[0].manifest.id != manifest.id)
        precondition(updated[0].snapshot.features[0].notes == "Manual correction")
        precondition(!updated[0].manifest.assets.contains(where: { $0.kind == .originalPhoto }), "Unchanged original must not upload twice")
        plan.name = "Corrected plan"; plan.revision = 1
        measurement.corrections = [MeasurementCorrection(meters: 2.5, note: "Control reading")]
        measurement.revision = 1
        snapshot.floorPlans = [plan]; snapshot.measurements = [measurement]
        let controls = try await assembler.prepare(snapshot: snapshot, assetDirectory: directory, scope: scope, device: device,
            previous: [manifest, updated[0].manifest])
        precondition(controls.count == 1 && controls[0].snapshot.floorPlans[0].name == "Corrected plan")
        precondition(controls[0].snapshot.measurements?[0].effectiveMeters == 2.5)
        precondition(!controls[0].manifest.assets.contains(where: { $0.kind == .originalPhoto }))
        var partial = snapshot; partial.scans.append(ScanRecord(projectID: project.id, source: .liDAR, status: .recording, frameID: UUID()))
        let preparedPartial = try await assembler.prepare(snapshot: partial, assetDirectory: directory, scope: scope, device: device)
        precondition(preparedPartial[0].skippedScans == 1 && preparedPartial[0].snapshot.scans.count == 2)
        let passportData = try await assembler.deliveryPassport(snapshot: snapshot, assetDirectory: directory, device: device, preparedBy: nil)
        let passport = try FieldTransferJSON.decode(FieldDeliveryPassport.self, from: passportData)
        let archivedPhoto = passport.assets.first(where: { $0.relativePath == "Captures/" + photoPath })!
        precondition(archivedPhoto.sha256 == FieldTransferDigest.sha256(original))
        precondition(passport.materials.first(where: { $0.source.id == photoID })?.captureOperator == nil)
        let exportedProjectSHA = FieldTransferDigest.sha256(try AtlasExporter.export(snapshot, format: .projectJSON).data)
        precondition(passport.assets.first(where: { $0.relativePath == "project.json" })?.sha256 == exportedProjectSHA)
        let crossScope = FieldTransferScope(serverOrigin: scope.serverOrigin, userID: UUID(), organizationID: scope.organizationID)
        let other = try await assembler.prepare(snapshot: snapshot, assetDirectory: directory, scope: crossScope, device: device)
        precondition(other[0].manifest.id != updated[0].manifest.id)
        // Enough tiny originals to exercise real automatic batching, without
        // allocating a gigabyte or fabricating a successful network transfer.
        for index in 0..<1_024 {
            let id = UUID(), path = "evidence/" + id.uuidString + ".jpg"
            let bytes = Data("fixture original \(index)".utf8)
            try bytes.write(to: captures.appendingPathComponent(path))
            let metadata: [String: Any] = ["id": id.uuidString, "projectID": project.id.uuidString,
                "createdAt": ISO8601DateFormatter().string(from: imported), "relativePath": path,
                "metadataPath": "evidence/" + id.uuidString + ".json", "source": "photoLibrary",
                "byteCount": bytes.count, "sha256": FieldTransferDigest.sha256(bytes)]
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: evidence.appendingPathComponent(id.uuidString + ".json"))
        }
        let batched = try await assembler.prepare(snapshot: snapshot, assetDirectory: directory, scope: scope, device: device)
        precondition(batched.count >= 2)
        let originalIDs = batched.flatMap { $0.manifest.assets }.filter { $0.kind == .originalPhoto }.map(\.id)
        precondition(Set(originalIDs).count == 1_025 && originalIDs.count == 1_025)
        for batch in batched { try batch.manifest.validate() }
        let unchangedOriginal = try Data(contentsOf: captures.appendingPathComponent(photoPath))
        precondition(unchangedOriginal == original)
        print("Field transfer assembler: originals, unknown import time, shared-manifest dedup, correction delta, partial scan, scope isolation, offline passport, plan/measurement corrections, 1025-photo batching passed.")
    }
}
