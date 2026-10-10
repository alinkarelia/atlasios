import Foundation
import Testing
@testable import AtlasCore

private let referenceTime = Date(timeIntervalSince1970: 1_790_000_000)

private func deviceFix(longitude: Double = 37.6176, latitude: Double = 55.7558,
                       accuracy: Double? = 8, offset: TimeInterval = 0,
                       simulated: Bool = false) -> GeoLocationFix {
    .init(coordinate: .init(longitude: longitude, latitude: latitude), altitudeMeters: 156,
          horizontalAccuracyMeters: accuracy, verticalAccuracyMeters: 12,
          observedAt: referenceTime.addingTimeInterval(offset), source: .deviceLocation, isSimulated: simulated)
}

@Test func automaticPositionRemainsOriginalAfterManualCorrectionAndReset() throws {
    let original = deviceFix(simulated: true)
    var tag = GeoTag(automaticFix: original)
    #expect(tag.effectiveFix == original)
    tag.corrections.append(.init(coordinate: .init(longitude: 37.6178, latitude: 55.7559),
        altitudeMeters: 160, estimatedAccuracyMeters: 0.5, note: "По контрольной точке", changedAt: referenceTime.addingTimeInterval(4)))
    try GeoTagPolicy.validate(tag)
    let effective = try #require(tag.effectiveFix)
    #expect(effective.source == .operatorEntered)
    #expect(effective.coordinate.longitude == 37.6178)
    #expect(effective.horizontalAccuracyMeters == 0.5)
    #expect(effective.verticalAccuracyMeters == nil)
    #expect(tag.automaticFix == original)
    tag.corrections.append(.init(coordinate: nil, note: "Вернуть исходную", changedAt: referenceTime.addingTimeInterval(5)))
    try GeoTagPolicy.validate(tag)
    #expect(tag.effectiveFix == original)
    #expect(tag.corrections.count == 2)
    #expect(tag.effectiveFix?.isSimulated == true)
}

@Test func missingAutomaticLocationCanBeManuallyEnteredAndResetToMissing() throws {
    var tag = GeoTag()
    #expect(tag.effectiveFix == nil)
    tag.corrections.append(.init(coordinate: .init(longitude: -73.9, latitude: 40.7), changedAt: referenceTime))
    try GeoTagPolicy.validate(tag)
    #expect(tag.effectiveFix?.horizontalAccuracyMeters == nil)
    #expect(tag.effectiveFix?.coordinate.longitude == -73.9)
    tag.corrections.append(.init(coordinate: nil, changedAt: referenceTime))
    #expect(tag.effectiveFix == nil)
    #expect(tag.corrections.count == 2)
}

@Test func deviceLocationFreshnessBoundariesRejectCachedFutureAndUnknownAccuracy() {
    #expect(GeoTagPolicy.acceptDeviceFix(deviceFix(offset: -20), now: referenceTime))
    #expect(!GeoTagPolicy.acceptDeviceFix(deviceFix(offset: -20.01), now: referenceTime))
    #expect(GeoTagPolicy.acceptDeviceFix(deviceFix(offset: 5), now: referenceTime))
    #expect(!GeoTagPolicy.acceptDeviceFix(deviceFix(offset: 5.01), now: referenceTime))
    #expect(!GeoTagPolicy.acceptDeviceFix(deviceFix(accuracy: nil), now: referenceTime))
    #expect(!GeoTagPolicy.acceptDeviceFix(deviceFix(accuracy: -1), now: referenceTime))
    #expect(!GeoTagPolicy.acceptDeviceFix(deviceFix(accuracy: .nan), now: referenceTime))
    #expect(!GeoTagPolicy.acceptDeviceFix(deviceFix(), now: referenceTime, maximumAge: -1))
    #expect(!GeoTagPolicy.acceptDeviceFix(deviceFix(), now: referenceTime, maximumAge: .infinity))
    #expect(!GeoTagPolicy.acceptDeviceFix(deviceFix(), now: Date(timeIntervalSinceReferenceDate: .nan)))
}

@Test func validBoundaryCoordinatesIncludeGenuineZeroAndAntimeridianPoints() throws {
    for coordinate in [GeographicCoordinate(longitude: -180, latitude: -90),
                       .init(longitude: 180, latitude: 90), .init(longitude: 0, latitude: 0)] {
        let fix = GeoLocationFix(coordinate: coordinate, horizontalAccuracyMeters: 8,
                                 observedAt: referenceTime, source: .deviceLocation)
        try GeoTagPolicy.validate(.init(automaticFix: fix))
        #expect(GeoTagPolicy.acceptDeviceFix(fix, now: referenceTime))
    }
}

@Test func outOfBoundsOrNonfiniteGeographicPositionsAreRejected() throws {
    for coordinate in [GeographicCoordinate(longitude: 180.001, latitude: 0),
                       .init(longitude: 0, latitude: -90.001),
                       .init(longitude: .infinity, latitude: 1), .init(longitude: 1, latitude: .nan)] {
        let fix = GeoLocationFix(coordinate: coordinate, horizontalAccuracyMeters: 8,
                                 observedAt: referenceTime, source: .deviceLocation)
        #expect(throws: GeoTagError.invalidCoordinate) { try GeoTagPolicy.validate(.init(automaticFix: fix)) }
        #expect(!GeoTagPolicy.acceptDeviceFix(fix, now: referenceTime))
    }
}

@Test func invalidAltitudeAccuracyAndDateCannotEnterCorrectionHistory() throws {
    let coordinate = GeographicCoordinate(longitude: 12, latitude: 45)
    #expect(throws: GeoTagError.invalidAltitude) {
        try GeoTagPolicy.validate(.init(corrections: [.init(coordinate: coordinate, altitudeMeters: .infinity)]))
    }
    #expect(throws: GeoTagError.invalidAccuracy) {
        try GeoTagPolicy.validate(.init(corrections: [.init(coordinate: coordinate, estimatedAccuracyMeters: -0.01)]))
    }
    #expect(throws: GeoTagError.invalidDate) {
        try GeoTagPolicy.validate(.init(corrections: [.init(coordinate: coordinate,
            changedAt: Date(timeIntervalSinceReferenceDate: .infinity))]))
    }
    #expect(throws: GeoTagError.invalidReset) {
        try GeoTagPolicy.validate(.init(corrections: [.init(coordinate: nil, altitudeMeters: 3)]))
    }
}

@Test func simulatedLocationIsRetainedButDoesNotBecomeUnmarkedRealLocation() throws {
    let fix = deviceFix(simulated: true)
    #expect(GeoTagPolicy.acceptDeviceFix(fix, now: referenceTime))
    let decoded = try AtlasJSON.decode(GeoTag.self, from: AtlasJSON.encode(GeoTag(automaticFix: fix)))
    #expect(decoded.effectiveFix?.isSimulated == true)
    #expect(decoded.automaticFix?.source == .deviceLocation)
}

@Test func automaticSelectionPrefersFreshAccuracyAndDropsExpiredCurrent() {
    let oldPrecise = deviceFix(accuracy: 2, offset: -21)
    let freshRough = deviceFix(accuracy: 15)
    #expect(GeoTagPolicy.bestAutomatic(current: oldPrecise, candidate: freshRough, now: referenceTime) == freshRough)
    let freshPrecise = deviceFix(accuracy: 3, offset: -2)
    #expect(GeoTagPolicy.bestAutomatic(current: freshPrecise, candidate: freshRough, now: referenceTime) == freshPrecise)
    let newerEqual = deviceFix(accuracy: 3)
    #expect(GeoTagPolicy.bestAutomatic(current: freshPrecise, candidate: newerEqual, now: referenceTime) == newerEqual)
    let invalid = deviceFix(longitude: 500)
    #expect(GeoTagPolicy.bestAutomatic(current: freshPrecise, candidate: invalid, now: referenceTime) == freshPrecise)
    #expect(GeoTagPolicy.bestAutomatic(current: oldPrecise, candidate: invalid, now: referenceTime) == nil)
}

@Test func exifUncertaintyStaysUnknownAndManualSourceCannotPretendAutomatic() throws {
    let exif = GeoLocationFix(coordinate: .init(longitude: 37, latitude: 55), observedAt: referenceTime,
                              source: .photoEXIF)
    try GeoTagPolicy.validate(.init(automaticFix: exif))
    #expect(!GeoTagPolicy.acceptDeviceFix(exif, now: referenceTime))
    #expect(GeoTagPolicy.bestAutomatic(current: nil, candidate: exif, now: referenceTime)?.horizontalAccuracyMeters == nil)
    let known = deviceFix(accuracy: 40)
    #expect(GeoTagPolicy.bestAutomatic(current: exif, candidate: known, now: referenceTime) == known)
    var manual = exif
    manual.source = .operatorEntered
    #expect(throws: GeoTagError.invalidAutomaticSource) { try GeoTagPolicy.validate(.init(automaticFix: manual)) }
}

@Test func duplicateCorrectionIDsAndRewrittenHistoryAreRejected() throws {
    let correction = GeoTagCorrection(coordinate: .init(longitude: 37, latitude: 55), changedAt: referenceTime)
    let old = GeoTag(automaticFix: deviceFix(), corrections: [correction])
    #expect(throws: GeoTagError.duplicateCorrectionID) {
        try GeoTagPolicy.validate(.init(corrections: [correction, correction]))
    }
    #expect(throws: GeoTagError.correctionHistoryChanged) {
        try GeoTagPolicy.validateTransition(from: old, to: .init(automaticFix: old.automaticFix))
    }
    var rewritten = old
    rewritten.corrections[0].note = "Changed original history"
    #expect(throws: GeoTagError.correctionHistoryChanged) { try GeoTagPolicy.validateTransition(from: old, to: rewritten) }
    var replaced = old
    replaced.automaticFix = deviceFix(longitude: 30)
    #expect(throws: GeoTagError.automaticFixChanged) { try GeoTagPolicy.validateTransition(from: old, to: replaced) }
    #expect(throws: GeoTagError.automaticFixChanged) { try GeoTagPolicy.validateTransition(from: old, to: nil) }
}

@Test func scanGeotagHistorySurvivesReopenAndOutboxWithoutChangingARFrame() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-geotag-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("project.sqlite").path
    let store = try AtlasStore(path: path)
    let projectFrame = UUID(), scanFrame = UUID()
    let project = try await store.saveProject(.init(name: "Сектор", kind: .cemetery,
                                                   coordinateReference: .localMeters(frameID: projectFrame)))
    var scan = try await store.saveScan(.init(projectID: project.id, source: .liDAR, status: .ready,
        frameID: scanFrame, createdAt: referenceTime.addingTimeInterval(0.123456789), geoTag: .init(automaticFix: deviceFix())))
    scan.geoTag?.corrections.append(.init(coordinate: .init(longitude: 37.618, latitude: 55.755),
                                         note: "Проверено на месте", changedAt: referenceTime.addingTimeInterval(0.123456789)))
    scan = try await store.saveScan(scan)
    scan.geoTag?.corrections.append(.init(coordinate: nil, changedAt: referenceTime.addingTimeInterval(3.123456789)))
    scan = try await store.saveScan(scan)
    #expect(scan.revision == 3)
    let reopened = try AtlasStore(path: path)
    let persisted = try #require(try await reopened.scans(projectID: project.id).first)
    #expect(persisted == scan)
    #expect(persisted.geoTag?.corrections.count == 2)
    #expect(persisted.geoTag?.effectiveFix == persisted.geoTag?.automaticFix)
    #expect(persisted.frameID == scanFrame)
    #expect(try await reopened.project(id: project.id)?.coordinateReference.frameID == projectFrame)
    let outbox = try await reopened.pendingOutbox()
    #expect(outbox.count == 4)
    let latest = try #require(outbox.last)
    #expect(try AtlasJSON.decode(ScanRecord.self, from: latest.payload) == persisted)
}

@Test func staleOperatorEditCannotEraseCommittedGeotagCorrection() async throws {
    let store = try AtlasStore(path: ":memory:")
    let project = try await store.saveProject(.init(name: "Site", kind: .site, coordinateReference: .wgs84))
    let original = try await store.saveScan(.init(projectID: project.id, source: .roomPlan, status: .ready,
        frameID: UUID(), geoTag: .init(automaticFix: deviceFix())))
    var changed = original
    changed.geoTag?.corrections.append(.init(coordinate: .init(longitude: 37.6, latitude: 55.7), changedAt: referenceTime))
    let saved = try await store.saveScan(changed)
    var stale = original
    stale.geoTag?.corrections.append(.init(coordinate: .init(longitude: 37.7, latitude: 55.8), changedAt: referenceTime))
    await #expect(throws: AtlasStoreError.revisionConflict(entityID: original.id, expected: 1, actual: 2)) {
        try await store.saveScan(stale)
    }
    #expect(try await store.scans(projectID: project.id) == [saved])
    #expect(try await store.pendingOutbox().count == 3)
}

@Test func currentRevisionCannotDeleteOriginalLocationOrHistory() async throws {
    let store = try AtlasStore(path: ":memory:")
    let project = try await store.saveProject(.init(name: "Site", kind: .site, coordinateReference: .wgs84))
    var scan = try await store.saveScan(.init(projectID: project.id, source: .liDAR, status: .ready,
        frameID: UUID(), geoTag: .init(automaticFix: deviceFix())))
    scan.geoTag?.corrections.append(.init(coordinate: .init(longitude: 38, latitude: 55), changedAt: referenceTime))
    scan = try await store.saveScan(scan)
    var erased = scan
    erased.geoTag = nil
    await #expect(throws: GeoTagError.automaticFixChanged) { try await store.saveScan(erased) }
    var erasedHistory = scan
    erasedHistory.geoTag?.corrections = []
    await #expect(throws: GeoTagError.correctionHistoryChanged) { try await store.saveScan(erasedHistory) }
    #expect(try await store.scans(projectID: project.id) == [scan])
}

@Test func scanCanReceiveFirstManualLocationAfterCaptureWithoutGPS() async throws {
    let store = try AtlasStore(path: ":memory:")
    let project = try await store.saveProject(.init(name: "Indoor", kind: .building,
                                                   coordinateReference: .localMeters(frameID: UUID())))
    var scan = try await store.saveScan(.init(projectID: project.id, source: .roomPlan, status: .ready, frameID: UUID()))
    #expect(scan.geoTag == nil)
    scan.geoTag = .init(corrections: [.init(coordinate: .init(longitude: 37, latitude: 55), changedAt: referenceTime)])
    scan = try await store.saveScan(scan)
    #expect(scan.geoTag?.effectiveFix?.source == .operatorEntered)
    #expect(scan.geoTag?.automaticFix == nil)
}

@Test func scanPayloadCreatedBeforeGeotagsStillDecodesWithoutMigration() throws {
    let legacy = ScanRecord(projectID: UUID(), source: .liDAR, status: .ready, frameID: UUID(), createdAt: referenceTime)
    var object = try #require(JSONSerialization.jsonObject(with: AtlasJSON.encode(legacy)) as? [String: Any])
    object.removeValue(forKey: "geoTag")
    let decoded = try AtlasJSON.decode(ScanRecord.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded == legacy)
    #expect(decoded.geoTag == nil)
}

@Test func geotagGeoJSONExportsEffectiveWGS84PointsAndPreservesHistoryInLocalProject() throws {
    let project = AtlasProject(name: "Local LiDAR", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID()))
    let tag = GeoTag(automaticFix: deviceFix(simulated: true), corrections: [.init(
        coordinate: .init(longitude: 37.618, latitude: 55.756), estimatedAccuracyMeters: 1,
        note: "На карту вручную", changedAt: referenceTime)])
    let scan = ScanRecord(projectID: project.id, source: .liDAR, status: .ready, frameID: UUID(), geoTag: tag)
    let missing = ScanRecord(projectID: project.id, source: .roomPlan, status: .ready, frameID: UUID())
    let artifact = try AtlasExporter.exportGeotags(.init(project: project, scans: [scan, missing]))
    let document = try #require(JSONSerialization.jsonObject(with: artifact.data) as? [String: Any])
    #expect(document["type"] as? String == "FeatureCollection")
    #expect(document["crs"] == nil)
    let features = try #require(document["features"] as? [[String: Any]])
    #expect(features.count == 1)
    #expect(features[0]["id"] as? String == scan.id.uuidString)
    let geometry = try #require(features[0]["geometry"] as? [String: Any])
    #expect(geometry["type"] as? String == "Point")
    #expect(geometry["coordinates"] as? [Double] == [37.618, 55.756])
    let properties = try #require(features[0]["properties"] as? [String: Any])
    let original = try #require(properties["originalFix"] as? [String: Any])
    let effective = try #require(properties["effectiveFix"] as? [String: Any])
    #expect(original["isSimulated"] as? Bool == true)
    #expect(effective["source"] as? String == "operatorEntered")
    #expect((properties["corrections"] as? [[String: Any]])?.count == 1)
    #expect(artifact.warnings.count == 2)
    #expect(artifact.contentType == "application/geo+json")
    #expect(throws: AtlasExportError.requiresGeographicCoordinates) {
        try AtlasExporter.export(.init(project: project, scans: [scan]), format: .geoJSON)
    }
}

@Test func geotagGeoJSONRejectsInvalidOrForeignScanAndNeverFabricatesMissingPoint() throws {
    let project = AtlasProject(name: "Site", kind: .site, coordinateReference: .wgs84)
    let missing = ScanRecord(projectID: project.id, source: .liDAR, status: .ready, frameID: UUID())
    let empty = try AtlasExporter.exportGeotags(.init(project: project, scans: [missing]))
    let document = try #require(JSONSerialization.jsonObject(with: empty.data) as? [String: Any])
    #expect((document["features"] as? [Any])?.isEmpty == true)
    var invalid = missing
    invalid.geoTag = .init(automaticFix: deviceFix(latitude: 91))
    #expect(throws: GeoTagError.invalidCoordinate) { try AtlasExporter.exportGeotags(.init(project: project, scans: [invalid])) }
    var foreign = missing
    foreign.projectID = UUID()
    #expect(throws: AtlasExportError.entityProjectMismatch) { try AtlasExporter.exportGeotags(.init(project: project, scans: [foreign])) }
}
