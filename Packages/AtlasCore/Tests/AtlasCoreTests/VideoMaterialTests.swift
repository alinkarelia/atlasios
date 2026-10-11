import Foundation
import Testing
@testable import AtlasCore

@Test func videoSourceReferencesPersistAlongsideLegacyPhotoAndMetadataAtSchemaOne() async throws {
    let legacy = Data("""
        {"id":"00000000-0000-4000-8000-000000000001","relativePath":"original.jpg","kind":"image","byteCount":12}
        """.utf8)
    #expect(try AtlasJSON.decode(SourceAssetReference.self, from: legacy).kind == .image)
    let video = Data("""
        {"id":"00000000-0000-4000-8000-000000000002","relativePath":"capture/original.mov","kind":"video","byteCount":24}
        """.utf8)
    let videoAsset = try AtlasJSON.decode(SourceAssetReference.self, from: video)
    #expect(videoAsset.kind == .video)
    let store = try AtlasStore(path: ":memory:")
    let project = try await store.saveProject(.init(name: "Видео обхода", kind: .site, coordinateReference: .localMeters(frameID: UUID())))
    let scan = try await store.saveScan(.init(projectID: project.id, source: .liDAR, status: .captured,
        frameID: project.coordinateReference.frameID!, assets: [videoAsset, .init(relativePath: "capture/poses.json", kind: .cameraMetadata, byteCount: 100)]))
    let snapshot = try await store.snapshot(projectID: project.id)
    let decoded = try AtlasJSON.decode(AtlasProjectSnapshot.self, from: AtlasExporter.export(snapshot, format: .projectJSON).data)
    #expect(decoded.schemaVersion == 1 && decoded.scans == [scan])
    #expect(decoded.scans[0].assets.map(\.kind) == [.video, .cameraMetadata])
    #expect(decoded.scans[0].source == .liDAR)
}

@Test func videoOnlyAndMixedMeshManifestsDescribeOriginalVideoWithoutRenamingItsContent() throws {
    // Opaque fixture bytes exercise packaging, not a claim that a camera/codec ran on Linux.
    let bytes = Data("original-movie-bytes-with-source-metadata".utf8)
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    for materialKind: FieldMaterialKind in [.video, .mesh] {
        let material = FieldMaterial(sourceEntityID: UUID(), kind: materialKind,
                                     capturedAt: capturedAt, endedAt: capturedAt.addingTimeInterval(18), frameID: UUID())
        let asset = FieldAsset(materialID: material.id, relativePath: "scans/segment-01/original.mov", mediaType: "video/quicktime",
                              byteCount: Int64(bytes.count), sha256: FieldTransferDigest.sha256(bytes), kind: .originalVideo)
        let package = FieldTransferManifest(projectID: UUID(), title: "Обход", materials: [material], assets: [asset])
        try package.validate()
        let encoded = try FieldTransferJSON.encode(package)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let materials = try #require(json["materials"] as? [[String: Any]])
        let assets = try #require(json["assets"] as? [[String: Any]])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(materials[0]["kind"] as? String == materialKind.rawValue)
        #expect(assets[0]["kind"] as? String == "originalVideo")
        #expect(assets[0]["mediaType"] as? String == "video/quicktime")
        #expect(assets[0]["sha256"] as? String == FieldTransferDigest.sha256(bytes))
        let decoded = try FieldTransferJSON.decode(FieldTransferManifest.self, from: encoded)
        #expect(decoded.assets[0].kind == .originalVideo && decoded.materials[0].endedAt == material.endedAt)
        let csv = try AtlasExporter.exportMaterialMetadata(projectID: package.projectID, projectName: "Обход",
                                                          materials: package.materials, assets: package.assets)
        let text = String(decoding: csv.data, as: UTF8.self)
        #expect(text.contains("originalVideo") && text.contains("original.mov"))
    }
}
