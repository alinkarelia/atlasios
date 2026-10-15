import Foundation
import Testing
@testable import AtlasCore

private let transferTime = Date(timeIntervalSince1970: 1_785_000_000.123)

private func transferScope(server: String = "https://atlas.example.test", userID: UUID = UUID(), organizationID: UUID = UUID()) -> FieldTransferScope {
    FieldTransferScope(serverOrigin: server, userID: userID, organizationID: organizationID)
}

private func transferManifest(id: UUID = UUID(), projectID: UUID = UUID(), title: String = "Сектор 4", geoTag: GeoTag? = nil) -> FieldTransferManifest {
    let material = FieldMaterial(sourceEntityID: UUID(), kind: .photo, capturedAt: transferTime,
                                 frameID: UUID(), geoTag: geoTag)
    let asset = FieldAsset(materialID: material.id, relativePath: "transfers/immutable/photo.jpg", mediaType: "image/jpeg",
                           byteCount: 10, sha256: FieldTransferDigest.sha256(Data("0123456789".utf8)), kind: .originalPhoto)
    return FieldTransferManifest(id: id, projectID: projectID, title: title, createdAt: transferTime.addingTimeInterval(60),
                                  timeZoneIdentifier: "Europe/Moscow", utcOffsetSeconds: 10_800, materials: [material], assets: [asset])
}

private func transferDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-transfer-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func transferSHA256MatchesIndependentKnownVectorsAndStreamingFiles() throws {
    #expect(FieldTransferDigest.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(FieldTransferDigest.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(FieldTransferDigest.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    let directory = try transferDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("million-a")
    try Data(repeating: 97, count: 1_000_000).write(to: url)
    #expect(try FieldTransferDigest.sha256(fileURL: url) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    #expect(FieldTransferDigest.isSHA256(String(repeating: "a", count: 64)))
    #expect(!FieldTransferDigest.isSHA256(String(repeating: "A", count: 64)))
}

@Test func incrementalSHA256IsIndependentOfChunkBoundariesAndCanBeInspectedWithoutConsumption() {
    var stream = FieldTransferDigest.Stream()
    stream.update(Data("a".utf8))
    #expect(stream.finalize() == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
    stream.update(Data("b".utf8)); stream.update(Data("c".utf8))
    #expect(stream.finalize() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(stream.finalize() == stream.finalize())
    var boundary = FieldTransferDigest.Stream()
    let block = Data(repeating: 97, count: 1_000)
    for _ in 0..<1_000 { boundary.update(block) }
    #expect(boundary.finalize() == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
}

@Test func fieldManifestKeepsCaptureTimeSeparateFromPackageCreationAndUnknownTimes() throws {
    let original = transferManifest()
    try original.validate()
    let data = try FieldTransferJSON.encode(original)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((json["createdAt"] as? NSNumber)?.int64Value == 1_785_000_060_123)
    let decoded = try FieldTransferJSON.decode(FieldTransferManifest.self, from: data)
    #expect(abs(try #require(decoded.materials.first?.capturedAt).timeIntervalSince(transferTime)) < 0.001)
    #expect(decoded.materials.first?.capturedAt != decoded.createdAt)
    #expect(try FieldTransferJSON.encode(decoded) == data)
    let unknown = FieldMaterial(sourceEntityID: UUID(), kind: .feature)
    let asset = FieldAsset(materialID: unknown.id, relativePath: "feature.json", mediaType: "application/json", byteCount: 0,
                           sha256: FieldTransferDigest.sha256(Data()), kind: .feature)
    let manifest = FieldTransferManifest(projectID: UUID(), title: "Imported", materials: [unknown], assets: [asset])
    try manifest.validate()
    #expect(try FieldTransferJSON.decode(FieldTransferManifest.self, from: FieldTransferJSON.encode(manifest)).materials[0].capturedAt == nil)
}

@Test func transferCanonicalJSONDoesNotDriftWhenDatesHaveSubmillisecondPrecision() throws {
    let manifest = FieldTransferManifest(projectID: UUID(), title: "Canonical", createdAt: Date(timeIntervalSince1970: 1_785_000_000.1234567),
                                        materials: transferManifest().materials, assets: [])
    let encoded = try FieldTransferJSON.encode(manifest)
    var next = encoded
    for _ in 0..<20 { next = try FieldTransferJSON.encode(FieldTransferJSON.decode(FieldTransferManifest.self, from: next)) }
    #expect(next == encoded)
}

@Test func manualPreparationNeverUploadsUntilExplicitSendAndPreferenceSurvivesRestart() async throws {
    let directory = try transferDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("queue.sqlite").path
    let scope = transferScope(), manifest = transferManifest()
    let queue = try FieldTransferQueue(path: path)
    #expect(try await queue.settings(projectID: manifest.projectID, scope: scope) == FieldTransferSettings(policy: .manual, wifiOnly: true))
    let registered = try await queue.register(manifest: manifest, scope: scope)
    #expect(registered.state == .ready)
    #expect(registered.queuedAt == nil)
    #expect(try await queue.pending(scope: scope, network: .wifi).isEmpty)
    try await queue.requestSend(projectID: manifest.projectID, scope: scope)
    let reopened = try FieldTransferQueue(path: path)
    let pending = try await reopened.pending(scope: scope, network: .wifi)
    #expect(pending.map(\.id) == [manifest.id])
    #expect(pending[0].explicitlyRequested)
    #expect(try await reopened.pending(scope: scope, network: .cellular).isEmpty)
    try await reopened.setSettings(.init(policy: .manual, wifiOnly: false), projectID: manifest.projectID, scope: scope)
    #expect(try await reopened.pending(scope: scope, network: .cellular).map(\.id) == [manifest.id])
}

@Test func automaticUploadHonorsWiFiAndNetworkChangesWithoutLosingPackage() async throws {
    let queue = try FieldTransferQueue(path: ":memory:"), scope = transferScope(), manifest = transferManifest()
    try await queue.setSettings(.init(policy: .automatic, wifiOnly: true), projectID: manifest.projectID, scope: scope)
    let record = try await queue.register(manifest: manifest, scope: scope)
    #expect(record.state == .queued)
    #expect(!record.explicitlyRequested)
    #expect(try await queue.pending(scope: scope, network: .offline).isEmpty)
    #expect(try await queue.pending(scope: scope, network: .cellular).isEmpty)
    #expect(try await queue.pending(scope: scope, network: .wifi).map(\.id) == [manifest.id])
    try await queue.setSettings(.init(policy: .automatic, wifiOnly: false), projectID: manifest.projectID, scope: scope)
    #expect(try await queue.pending(scope: scope, network: .cellular).count == 1)
}

@Test func transferModeChangesRespectManualConsentAndPausedPackages() async throws {
    let queue = try FieldTransferQueue(path: ":memory:"), scope = transferScope(), manifest = transferManifest()
    _ = try await queue.register(manifest: manifest, scope: scope)
    try await queue.setSettings(.init(policy: .automatic), projectID: manifest.projectID, scope: scope)
    #expect(try await queue.pending(scope: scope, network: .wifi).count == 1)
    _ = try await queue.claimNext(scope: scope, network: .wifi)
    try await queue.setSettings(.init(policy: .manual), projectID: manifest.projectID, scope: scope)
    #expect(try await queue.record(id: manifest.id)?.state == .ready)
    _ = try await queue.markFailed(id: manifest.id, message: "cancelled old automatic request", retryable: true)
    #expect(try await queue.record(id: manifest.id)?.state == .ready)
    try await queue.requestSend(projectID: manifest.projectID, scope: scope)
    _ = try await queue.pause(id: manifest.id)
    try await queue.setSettings(.init(policy: .automatic), projectID: manifest.projectID, scope: scope)
    #expect(try await queue.pending(scope: scope, network: .wifi).isEmpty)
    try await queue.requestSend(projectID: manifest.projectID, scope: scope, transferIDs: [manifest.id])
    #expect(try await queue.pending(scope: scope, network: .wifi).count == 1)
}

@Test func duplicateRegistrationIsIdempotentAndChangedMetadataNeedsNewPackageID() async throws {
    let queue = try FieldTransferQueue(path: ":memory:"), scope = transferScope(), manifest = transferManifest()
    let first = try await queue.register(manifest: manifest, scope: scope)
    #expect(try await queue.register(manifest: manifest, scope: scope) == first)
    let changed = FieldTransferManifest(id: manifest.id, projectID: manifest.projectID, title: "Changed", createdAt: manifest.createdAt,
                                       materials: manifest.materials, assets: manifest.assets)
    await #expect(throws: FieldTransferError.immutableManifest) { try await queue.register(manifest: changed, scope: scope) }
    await #expect(throws: FieldTransferError.immutableManifest) { try await queue.register(manifest: manifest, scope: transferScope()) }
    #expect(try await queue.records().count == 1)
    #expect(try await queue.record(id: manifest.id)?.manifest.title == manifest.title)
}

@Test func transferQueueCannotSendAcrossServerAccountOrganizationOrProject() async throws {
    let queue = try FieldTransferQueue(path: ":memory:"), scope = transferScope(), manifest = transferManifest()
    _ = try await queue.register(manifest: manifest, scope: scope)
    try await queue.requestSend(projectID: manifest.projectID, scope: scope)
    let scopes = [FieldTransferScope(serverOrigin: "https://other.example.test", userID: scope.userID, organizationID: scope.organizationID),
                  FieldTransferScope(serverOrigin: scope.serverOrigin, userID: UUID(), organizationID: scope.organizationID),
                  FieldTransferScope(serverOrigin: scope.serverOrigin, userID: scope.userID, organizationID: UUID())]
    for other in scopes {
        #expect(try await queue.pending(scope: other, network: .wifi).isEmpty)
        await #expect(throws: FieldTransferError.invalidScope) {
            try await queue.requestSend(projectID: manifest.projectID, scope: other, transferIDs: [manifest.id])
        }
    }
    await #expect(throws: FieldTransferError.invalidScope) {
        try await queue.requestSend(projectID: UUID(), scope: scope, transferIDs: [manifest.id])
    }
}

@Test func claimedTransferKeepsAcknowledgedOffsetsAfterCrashAndDoesNotClaimTwice() async throws {
    let directory = try transferDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("queue.sqlite").path
    let queue = try FieldTransferQueue(path: path), scope = transferScope(), manifest = transferManifest()
    _ = try await queue.register(manifest: manifest, scope: scope)
    try await queue.requestSend(projectID: manifest.projectID, scope: scope)
    #expect(try await queue.claimNext(scope: scope, network: .wifi)?.id == manifest.id)
    #expect(try await queue.claimNext(scope: scope, network: .wifi) == nil)
    _ = try await queue.recordAcknowledgedOffset(id: manifest.id, assetID: manifest.assets[0].id, offset: 6)
    let reopened = try FieldTransferQueue(path: path)
    let record = try #require(try await reopened.claimNext(scope: scope, network: .wifi))
    #expect(record.uploadedBytes == 6)
    #expect(record.attemptCount == 2)
    #expect(record.id == manifest.id)
    #expect(abs(record.fractionCompleted - 0.6) < 0.001)
}

@Test func taskSelectionSkipsAnotherProjectsOlderPackageWithoutRebindingOrLosingIt() async throws {
    let directory = try transferDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
    let path = directory.appendingPathComponent("queue.sqlite").path
    let scope = transferScope(), oldTask = transferManifest(), currentTask = transferManifest()
    let queue = try FieldTransferQueue(path:path)
    _ = try await queue.register(manifest:oldTask, scope:scope)
    try await queue.requestSend(projectID:oldTask.projectID, scope:scope)
    let preserved = try #require(try await queue.record(id:oldTask.id))
    let originalBytes = try FieldTransferJSON.encode(preserved.manifest)
    _ = try await queue.register(manifest:currentTask, scope:scope)
    try await queue.requestSend(projectID:currentTask.projectID, scope:scope)
    #expect(try await queue.claimNext(scope:scope, network:.wifi, allowedProjectIDs:[]) == nil)
    let selected = try #require(try await queue.claimNext(scope:scope, network:.wifi,
        allowedProjectIDs:[currentTask.projectID]))
    #expect(selected.id == currentTask.id)
    #expect(try await queue.record(id:oldTask.id) == preserved)
    let reopened = try FieldTransferQueue(path:path)
    let old = try #require(try await reopened.record(id:oldTask.id))
    #expect(old == preserved)
    #expect(try FieldTransferJSON.encode(old.manifest) == originalBytes)
    // Optional filtering preserves existing queue callers and persisted schema.
    #expect(try await reopened.claimNext(scope:scope, network:.wifi)?.id == oldTask.id)
}

@Test func invalidOffsetsAndPrematureCompletionCannotProduceDeliveredStatus() async throws {
    let queue = try FieldTransferQueue(path: ":memory:"), scope = transferScope(), manifest = transferManifest()
    _ = try await queue.register(manifest: manifest, scope: scope)
    try await queue.requestSend(projectID: manifest.projectID, scope: scope)
    _ = try await queue.claimNext(scope: scope, network: .wifi)
    for offset in [-1, 11] {
        await #expect(throws: FieldTransferError.invalidOffset) {
            try await queue.recordAcknowledgedOffset(id: manifest.id, assetID: manifest.assets[0].id, offset: Int64(offset))
        }
    }
    await #expect(throws: FieldTransferError.invalidOffset) {
        try await queue.recordAcknowledgedOffset(id: manifest.id, assetID: UUID(), offset: 2)
    }
    _ = try await queue.recordAcknowledgedOffset(id: manifest.id, assetID: manifest.assets[0].id, offset: 6)
    await #expect(throws: FieldTransferError.invalidOffset) {
        try await queue.recordAcknowledgedOffset(id: manifest.id, assetID: manifest.assets[0].id, offset: 4)
    }
    await #expect(throws: FieldTransferError.incompleteAssets) { try await queue.markCompleted(id: manifest.id, serverReceiptID: "receipt") }
    _ = try await queue.reconcileAcknowledgedOffset(id: manifest.id, assetID: manifest.assets[0].id, offset: 4)
    _ = try await queue.recordAcknowledgedOffset(id: manifest.id, assetID: manifest.assets[0].id, offset: 10)
    let completed = try await queue.markCompleted(id: manifest.id, serverReceiptID: "receipt", completedAt: transferTime)
    #expect(completed.state == .completed)
    #expect(completed.fractionCompleted == 1)
    #expect(try await queue.markCompleted(id: manifest.id, serverReceiptID: "receipt").state == .completed)
    await #expect(throws: FieldTransferError.invalidTransition) { try await queue.markCompleted(id: manifest.id, serverReceiptID: "other-receipt") }
}

@Test func retryBackoffSurvivesRestartAndTerminalFailuresNeedExplicitRetry() async throws {
    let directory = try transferDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("queue.sqlite").path
    let queue = try FieldTransferQueue(path: path), scope = transferScope(), manifest = transferManifest()
    _ = try await queue.register(manifest: manifest, scope: scope)
    try await queue.requestSend(projectID: manifest.projectID, scope: scope)
    _ = try await queue.claimNext(scope: scope, network: .wifi)
    let failed = try await queue.markFailed(id: manifest.id, message: "Network disconnected", retryable: true, now: transferTime)
    #expect(failed.state == .waiting)
    let reopened = try FieldTransferQueue(path: path)
    #expect(try await reopened.pending(scope: scope, network: .wifi, now: transferTime.addingTimeInterval(1)).isEmpty)
    #expect(try await reopened.pending(scope: scope, network: .wifi, now: transferTime.addingTimeInterval(3)).count == 1)
    _ = try await reopened.markFailed(id: manifest.id, message: "Forbidden", retryable: false)
    #expect(try await reopened.pending(scope: scope, network: .wifi).isEmpty)
    try await reopened.requestSend(projectID: manifest.projectID, scope: scope)
    #expect(try await reopened.pending(scope: scope, network: .wifi).count == 1)
}

@Test func removingTransferQueueEntryDoesNotDeleteOriginalFile() async throws {
    let directory = try transferDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("original.jpg")
    try Data("Original EXIF photo bytes".utf8).write(to: original)
    let queue = try FieldTransferQueue(path: directory.appendingPathComponent("queue.sqlite").path)
    let scope = transferScope(), manifest = transferManifest()
    _ = try await queue.register(manifest: manifest, scope: scope)
    try await queue.removeQueued(id: manifest.id)
    try await queue.removeQueued(id: manifest.id)
    #expect(try await queue.records().isEmpty)
    #expect(try String(contentsOf: original, encoding: .utf8) == "Original EXIF photo bytes")
}

@Test func transferGeoProvenanceIsFrozenWithOriginalAndManualHistory() async throws {
    let automatic = GeoLocationFix(coordinate: .init(longitude: 34.36, latitude: 61.78), horizontalAccuracyMeters: 8,
                                    observedAt: transferTime, source: .deviceLocation)
    let correction = GeoTagCorrection(coordinate: .init(longitude: 34.37, latitude: 61.79), estimatedAccuracyMeters: 3,
                                      note: "Контрольная точка", changedAt: transferTime.addingTimeInterval(50))
    var tag = GeoTag(automaticFix: automatic, corrections: [correction])
    let manifest = transferManifest(geoTag: tag), scope = transferScope(), queue = try FieldTransferQueue(path: ":memory:")
    _ = try await queue.register(manifest: manifest, scope: scope)
    tag.corrections.append(.init(coordinate: nil, changedAt: transferTime.addingTimeInterval(100)))
    let persisted = try #require(try await queue.record(id: manifest.id)?.manifest.materials.first?.geoTag)
    #expect(persisted.automaticFix?.coordinate == automatic.coordinate)
    #expect(persisted.corrections.map(\.id) == [correction.id])
    #expect(persisted.effectiveFix?.source == .operatorEntered)
}

@Test func transferPathsRejectTraversalControlCharactersAndSymlinkEscape() throws {
    let directory = try transferDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for path in ["", "../outside", "nested/../../outside", "/absolute", "a//b", "a/./b", "C:/outside", "a\\b", "a\0b", "a\nb"] {
        #expect(throws: FieldTransferError.invalidAssetPath(path)) { try FieldTransferPaths.resolve(relativePath: path, root: root) }
    }
    let outside = directory.appendingPathComponent("outside")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    #expect(throws: FieldTransferError.invalidAssetPath("escape")) { try FieldTransferPaths.resolve(relativePath: "escape", root: root) }
    #expect(try FieldTransferPaths.resolve(relativePath: "nested/photo.jpg", root: root).path == root.appendingPathComponent("nested/photo.jpg").path)
}

@Test func assetDescriptorAndVerificationDetectChangedBytesAndMissingFiles() throws {
    let root = try transferDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("original.jpg"), bytes = Data("0123456789".utf8)
    try bytes.write(to: url)
    let asset = try FieldTransferDigest.describe(materialID: UUID(), relativePath: "original.jpg", root: root,
                                                 mediaType: "image/jpeg", kind: .originalPhoto)
    #expect(asset.byteCount == 10)
    #expect(try FieldTransferPaths.verify(asset: asset, root: root) == url)
    try Data("9876543210".utf8).write(to: url)
    #expect(throws: FieldTransferError.assetChanged("original.jpg")) { try FieldTransferPaths.verify(asset: asset, root: root) }
    try FileManager.default.removeItem(at: url)
    #expect(throws: FieldTransferError.missingAsset("original.jpg")) { try FieldTransferPaths.verify(asset: asset, root: root) }
}

@Test func malformedManifestsCannotEnterTheQueue() async throws {
    let queue = try FieldTransferQueue(path: ":memory:"), scope = transferScope(), good = transferManifest()
    let badAsset = FieldAsset(materialID: UUID(), relativePath: "photo.jpg", mediaType: "image/jpeg", byteCount: 10,
                              sha256: FieldTransferDigest.sha256(Data()), kind: .originalPhoto)
    let manifests = [FieldTransferManifest(projectID: UUID(), title: "", materials: good.materials, assets: good.assets),
                     FieldTransferManifest(projectID: UUID(), title: "Invalid link", materials: good.materials, assets: [badAsset]),
                     FieldTransferManifest(projectID: UUID(), title: "Duplicate assets", materials: good.materials, assets: good.assets + good.assets),
                     FieldTransferManifest(projectID: UUID(), title: "No assets", materials: good.materials, assets: [])]
    for manifest in manifests {
        await #expect(throws: FieldTransferError.invalidManifest) { try await queue.register(manifest: manifest, scope: scope) }
    }
    #expect(try await queue.records().isEmpty)
}

@Test func scopesCanonicalizeEquivalentOriginsAndRejectCredentialsOrInsecureRemoteHosts() throws {
    let userID = UUID(), organizationID = UUID()
    let a = FieldTransferScope(serverOrigin: "HTTPS://ATLAS.EXAMPLE.TEST:443/", userID: userID, organizationID: organizationID)
    let b = FieldTransferScope(serverOrigin: "https://atlas.example.test", userID: userID, organizationID: organizationID)
    try a.validate(); try b.validate()
    #expect(a == b)
    #expect(a.key == b.key)
    for origin in ["https://name:password@example.test", "https://example.test?token=private", "http://example.test", "file:///private", "https://example.test#fragment"] {
        #expect(throws: FieldTransferError.invalidScope) { try transferScope(server: origin).validate() }
    }
    try transferScope(server: "http://localhost:3000").validate()
}
