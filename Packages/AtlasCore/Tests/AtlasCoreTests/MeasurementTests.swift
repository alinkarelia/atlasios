import Foundation
import Testing
@testable import AtlasCore

private func measurementDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-measurements-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func referenceRecord(projectID: UUID = UUID(), meters: Double = 2.34,
                             source: MeasurementSource = .manualReference) -> MeasurementRecord {
    MeasurementRecord(projectID: projectID, label: "Контроль стены", source: source,
                      originalMeters: meters, createdAt: Date(timeIntervalSinceReferenceDate: 805_321_123.123456))
}

private func raycastRecord(kind: MeasurementKind = .distance) throws -> MeasurementRecord {
    try MeasurementRecord.arRaycast(projectID: UUID(), label: "Стена", kind: kind, frameID: UUID(),
        start: .init(x: 10, y: 20, z: 30), end: .init(x: 13, y: 32, z: 34), trackingQuality: .normal,
        surfaceEvidence: [.existingPlaneGeometry, .estimatedPlane])
}

@Test func distanceProjectionsRespectARVerticalAxisAndAreTranslationInvariant() throws {
    let start = MetricPoint3D(x: 10, y: 20, z: 30)
    let end = MetricPoint3D(x: 13, y: 32, z: 34)
    #expect(abs(try MeasurementGeometry.distance(from: start, to: end) - 13) < 1e-12)
    #expect(try MeasurementGeometry.horizontalDistance(from: start, to: end) == 5)
    #expect(try MeasurementGeometry.verticalDistance(from: start, to: end) == 12)
    #expect(abs(try MeasurementGeometry.distance(from: end, to: start) - 13) < 1e-12)
    #expect(abs(try MeasurementGeometry.distance(from: .init(x: 0, y: 0, z: 0), to: .init(x: 3, y: 12, z: 4)) - 13) < 1e-12)
    #expect(try MeasurementGeometry.horizontalDistance(from: start, to: .init(x: 10, y: 25, z: 30)) == 0)
}

@Test func nonfiniteAndUnboundedARPointsAreRejectedBeforeCalculation() {
    for point in [MetricPoint3D(x: .nan, y: 0, z: 0), .init(x: 0, y: .infinity, z: 0),
                  .init(x: 0, y: 0, z: -1_000_000.1)] {
        #expect(throws: MeasurementError.invalidPoint) {
            try MeasurementGeometry.distance(from: point, to: .init(x: 0, y: 0, z: 0))
        }
        #expect(throws: MeasurementError.invalidPoint) {
            try MeasurementGeometry.horizontalDistance(from: point, to: .init(x: 0, y: 0, z: 0))
        }
        #expect(throws: MeasurementError.invalidPoint) {
            try MeasurementGeometry.verticalDistance(from: point, to: .init(x: 0, y: 0, z: 0))
        }
    }
}

@Test func arFactoryFreezesSourcePointsSurfaceEvidenceAndSelectedProjection() throws {
    for (kind, value) in [(MeasurementKind.distance, 13.0), (.horizontalDistance, 5), (.verticalDistance, 12)] {
        let record = try raycastRecord(kind: kind)
        try MeasurementPolicy.validate(record)
        #expect(abs(record.originalMeters - value) < 1e-12)
        #expect(record.effectiveMeters == record.originalMeters)
        #expect(record.trackingQuality == .normal)
        #expect(record.surfaceEvidence == [.existingPlaneGeometry, .estimatedPlane])
        #expect(!record.hasManualCorrection)
    }
}

@Test func correctionAndResetKeepOriginalMeasurementAndCompleteHistory() throws {
    var record = try raycastRecord()
    let original = record
    record.corrections.append(.init(meters: 12.96, source: .laserReference, note: "Проверено лазером"))
    try MeasurementPolicy.validateTransition(from: original, to: record)
    #expect(record.effectiveMeters == 12.96)
    #expect(record.hasManualCorrection)
    let corrected = record
    record.corrections.append(.init(meters: nil, note: "Вернуть исходный AR-обмер"))
    try MeasurementPolicy.validateTransition(from: corrected, to: record)
    #expect(record.effectiveMeters == original.originalMeters)
    #expect(record.originalMeters == original.originalMeters)
    #expect(record.start == original.start)
    #expect(record.corrections.count == 2)
    #expect(!record.hasManualCorrection)
}

@Test func changingOriginalOrRemovingOldCorrectionIsRejected() throws {
    var original = referenceRecord()
    original.corrections.append(.init(meters: 2.35, note: "Контроль"))
    var changed = original
    changed.originalMeters = 2.4
    #expect(throws: MeasurementError.originalChanged) { try MeasurementPolicy.validateTransition(from: original, to: changed) }
    changed = original
    changed.projectID = UUID()
    #expect(throws: MeasurementError.originalChanged) { try MeasurementPolicy.validateTransition(from: original, to: changed) }
    changed = original
    changed.corrections.removeAll()
    #expect(throws: MeasurementError.historyChanged) { try MeasurementPolicy.validateTransition(from: original, to: changed) }
    changed = original
    changed.corrections[0].note = "Переписано"
    #expect(throws: MeasurementError.historyChanged) { try MeasurementPolicy.validateTransition(from: original, to: changed) }
}

@Test func trackingAndRaycastProvenanceCannotBeRetroactivelyImproved() throws {
    var original = try raycastRecord()
    original.trackingQuality = .limited
    var changed = original
    changed.trackingQuality = .normal
    #expect(throws: MeasurementError.originalChanged) { try MeasurementPolicy.validateTransition(from: original, to: changed) }
    changed = original
    changed.surfaceEvidence = [.existingPlaneGeometry, .existingPlaneGeometry]
    #expect(throws: MeasurementError.originalChanged) { try MeasurementPolicy.validateTransition(from: original, to: changed) }
}

@Test func incompleteOrInconsistentARObservationsAreRejected() throws {
    var record = try raycastRecord()
    record.frameID = nil
    #expect(throws: MeasurementError.invalidARObservation) { try MeasurementPolicy.validate(record) }
    record = try raycastRecord()
    record.trackingQuality = nil
    #expect(throws: MeasurementError.invalidARObservation) { try MeasurementPolicy.validate(record) }
    record = try raycastRecord()
    record.surfaceEvidence = [.estimatedPlane]
    #expect(throws: MeasurementError.invalidARObservation) { try MeasurementPolicy.validate(record) }
    record = try raycastRecord()
    record.originalMeters = 10
    #expect(throws: MeasurementError.inconsistentOriginalDistance) { try MeasurementPolicy.validate(record) }
}

@Test func enteredLaserReferenceNeverInventsARDeviceMetadata() throws {
    var reference = referenceRecord(source: .laserReference)
    try MeasurementPolicy.validate(reference)
    #expect(reference.start == nil)
    #expect(reference.frameID == nil)
    #expect(reference.trackingQuality == nil)
    reference.trackingQuality = .normal
    #expect(throws: MeasurementError.unexpectedARMetadata) { try MeasurementPolicy.validate(reference) }
}

@Test func invalidDistancesDatesAndAuditNotesCannotEnterRecords() throws {
    for meters in [-0.001, .nan, .infinity, 4_000_000.1] {
        #expect(throws: MeasurementError.invalidDistance) { try MeasurementPolicy.validate(referenceRecord(meters: meters)) }
    }
    var record = referenceRecord()
    record.createdAt = Date(timeIntervalSinceReferenceDate: .nan)
    #expect(throws: MeasurementError.invalidDate) { try MeasurementPolicy.validate(record) }
    record = referenceRecord()
    record.corrections.append(.init(meters: 2.3, note: " \n"))
    #expect(throws: MeasurementError.invalidCorrectionNote) { try MeasurementPolicy.validate(record) }
    record = referenceRecord()
    let correction = MeasurementCorrection(meters: 2.3, note: "Контроль")
    record.corrections = [correction, correction]
    #expect(throws: MeasurementError.duplicateCorrectionID) { try MeasurementPolicy.validate(record) }
}

@Test func discrepancyUsesReferenceDenominatorAndNeverClaimsCalibration() throws {
    let comparison = try MeasurementComparison.compare(measuredMeters: 2.02, referenceMeters: 2)
    #expect(abs(comparison.deltaMeters - 0.02) < 1e-12)
    #expect(abs(comparison.relativeDifferencePercent - 1) < 1e-12)
    let lower = try MeasurementComparison.compare(measuredMeters: 1.9, referenceMeters: 2)
    #expect(abs(lower.relativeDifferencePercent + 5) < 1e-12)
    for reference in [0, -1, .nan, .infinity] {
        #expect(throws: MeasurementError.invalidReference) {
            try MeasurementComparison.compare(measuredMeters: 2, referenceMeters: reference)
        }
    }
    #expect(throws: MeasurementError.invalidDistance) {
        try MeasurementComparison.compare(measuredMeters: .nan, referenceMeters: 2)
    }
}

@Test func levelReadingHasDegreeBoundsAndNoDistanceUnitMixing() throws {
    try LevelReading(pitchDegrees: -90, rollDegrees: 180).validate()
    #expect(throws: MeasurementError.invalidOrientation) { try LevelReading(pitchDegrees: .nan, rollDegrees: 0).validate() }
    #expect(throws: MeasurementError.invalidOrientation) { try LevelReading(pitchDegrees: 0, rollDegrees: 180.1).validate() }
    #expect(throws: MeasurementError.invalidDate) {
        try LevelReading(pitchDegrees: 0, rollDegrees: 0, observedAt: Date(timeIntervalSinceReferenceDate: .infinity)).validate()
    }
}

@Test func repositorySurvivesReopeningAndRetainsSubsecondAuditDates() async throws {
    let directory = try measurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try MeasurementRepository(directory: directory)
    let original = try await repository.save(referenceRecord())
    #expect(original.revision == 1)
    var corrected = original
    corrected.corrections.append(.init(meters: 2.35, note: "Контрольная рулетка",
        changedAt: Date(timeIntervalSinceReferenceDate: 805_321_124.987654)))
    let saved = try await repository.save(corrected)
    let reopened = try MeasurementRepository(directory: directory)
    let loaded = try #require(await reopened.measurements(projectID: original.projectID).first)
    #expect(loaded == saved)
    #expect(loaded.createdAt == original.createdAt)
    #expect(loaded.corrections[0].changedAt == corrected.corrections[0].changedAt)
    #expect(loaded.revision == 2)
    var reset = loaded
    reset.corrections.append(.init(meters: nil, note: "Вернуть оригинал"))
    let resetSaved = try await reopened.save(reset)
    #expect(resetSaved.effectiveMeters == original.originalMeters)
    #expect(resetSaved.corrections.count == 2)
}

@Test func staleRepositoryCannotOverwriteNewRevisionOrLoseAnotherRecord() async throws {
    let directory = try measurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try MeasurementRepository(directory: directory)
    let original = try await first.save(referenceRecord())
    let second = try MeasurementRepository(directory: directory)
    var edit = original
    edit.corrections.append(.init(meters: 2.36, note: "Новое значение"))
    let newest = try await first.save(edit)
    await #expect(throws: MeasurementError.revisionConflict(entityID: original.id, expected: 1, actual: 2)) {
        try await second.save(original)
    }
    _ = try await second.save(referenceRecord(projectID: original.projectID, meters: 3))
    try await first.reload()
    let loaded = await first.measurements(projectID: original.projectID)
    #expect(loaded.count == 2)
    #expect(loaded.contains(newest))
}

@Test func rejectedMeasurementLeavesPersistentFileAndCacheUntouched() async throws {
    let directory = try measurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try MeasurementRepository(directory: directory)
    let original = try await repository.save(referenceRecord())
    let file = directory.appendingPathComponent("measurements.atlas.json")
    let bytes = try Data(contentsOf: file)
    var invalid = original
    invalid.originalMeters = 999
    await #expect(throws: MeasurementError.originalChanged) { try await repository.save(invalid) }
    #expect(try Data(contentsOf: file) == bytes)
    #expect(await repository.measurements(projectID: original.projectID) == [original])
}

@Test func corruptAndFutureFilesArePreservedWithoutSilentReset() async throws {
    let directory = try measurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("measurements.atlas.json")
    let corrupt = Data("{\"schemaVersion\":1,\"records\":broken".utf8)
    try corrupt.write(to: file)
    #expect(throws: MeasurementError.invalidStoredData) { try MeasurementRepository(directory: directory) }
    #expect(try Data(contentsOf: file) == corrupt)
    let future = Data("{\"schemaVersion\":999,\"new-format\":true}".utf8)
    try future.write(to: file)
    #expect(throws: MeasurementError.unsupportedSchema(999)) { try MeasurementRepository(directory: directory) }
    #expect(try Data(contentsOf: file) == future)
}

@Test func damagedFileAfterOpeningCannotPublishUnsavedChangesOrReplaceIt() async throws {
    let directory = try measurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try MeasurementRepository(directory: directory)
    let record = try await repository.save(referenceRecord())
    let file = directory.appendingPathComponent("measurements.atlas.json")
    let bytes = try Data(contentsOf: file)
    // An invalid on-disk replacement is an actual persistence failure on every platform,
    // including root-run CI where permissions alone do not reliably prohibit writes.
    try Data("invalid".utf8).write(to: file)
    var edit = record
    edit.label = "Изменённый размер"
    await #expect(throws: MeasurementError.invalidStoredData) { try await repository.save(edit) }
    #expect(await repository.measurements(projectID: record.projectID) == [record])
    #expect(try String(contentsOf: file, encoding: .utf8) == "invalid")
    try bytes.write(to: file)
    try await repository.reload()
    #expect(await repository.measurements(projectID: record.projectID) == [record])
}

@Test func snapshotWithoutMeasurementsStillDecodesAndNewExportRetainsMeasurements() throws {
    let project = AtlasProject(name: "Дом", kind: .building, coordinateReference: .localMeters(frameID: UUID()))
    let legacy = AtlasProjectSnapshot(project: project)
    let legacyData = try AtlasJSON.encode(legacy)
    #expect(!String(decoding: legacyData, as: UTF8.self).contains("measurements"))
    #expect(try AtlasJSON.decode(AtlasProjectSnapshot.self, from: legacyData).measurements == nil)
    let measurement = referenceRecord(projectID: project.id)
    let snapshot = AtlasProjectSnapshot(project: project, measurements: [measurement])
    let artifact = try AtlasExporter.export(snapshot, format: .projectJSON)
    let decoded = try AtlasJSON.decode(AtlasProjectSnapshot.self, from: artifact.data)
    #expect(decoded.measurements?.count == 1)
    #expect(decoded.measurements?[0].originalMeters == 2.34)
    #expect(decoded.measurements?[0].source == .manualReference)
}

private func controlPlan(projectID: UUID) -> AtlasFloorPlan {
    let frame = UUID()
    return AtlasFloorPlan(projectID: projectID, frameID: frame,
        rooms: [.init(name: "Комната", boundary: .init(frameID: frame,
            vertices: [.init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 3), .init(x: 0, y: 3)]))],
        walls: [.init(start: .init(x: 10, y: 20), end: .init(x: 13, y: 24), heightMeters: 2.8, thicknessMeters: 0.2),
                .init(start: .init(x: 13, y: 24), end: .init(x: 17, y: 24), heightMeters: 2.8, thicknessMeters: 0.2)],
        revision: 7)
}

@Test func applyingLengthChangesOnlyChosenWallAndRetainsStartDirectionAndIndependentFrame() throws {
    var measurement = referenceRecord(meters: 10)
    measurement.revision = 3
    let plan = controlPlan(projectID: measurement.projectID)
    let now = Date(timeIntervalSinceReferenceDate: 805_321_900.123456)
    let updated = try MeasurementPlanControl.applying(measurement: measurement, to: plan,
        wallID: plan.walls[0].id, dimension: .wallLength, now: now)
    #expect(updated.walls[0].start == plan.walls[0].start)
    #expect(updated.walls[0].end == MetricPoint2D(x: 16, y: 28))
    #expect(updated.walls[0].heightMeters == plan.walls[0].heightMeters)
    #expect(updated.walls[1] == plan.walls[1])
    #expect(updated.rooms == plan.rooms)
    #expect(updated.frameID == plan.frameID)
    #expect(updated.revision == plan.revision)
    let application = try #require(updated.measurementApplications?.first)
    #expect(application.measurementID == measurement.id)
    #expect(application.measurementRevision == 3)
    #expect(application.previousMeters == 5)
    #expect(application.appliedMeters == 10)
    #expect(application.appliedAt == now)
}

@Test func applyingHeightOrThicknessRetainsWallEndpointsAndAppendsControlHistory() throws {
    var measurement = referenceRecord(meters: 3)
    measurement.revision = 1
    let plan = controlPlan(projectID: measurement.projectID)
    let height = try MeasurementPlanControl.applying(measurement: measurement, to: plan,
        wallID: plan.walls[0].id, dimension: .wallHeight)
    #expect(height.walls[0].heightMeters == 3)
    #expect(height.walls[0].start == plan.walls[0].start)
    #expect(height.walls[0].end == plan.walls[0].end)
    #expect(height.measurementApplications?[0].previousMeters == 2.8)
    measurement.corrections.append(.init(meters: 0.25, note: "Толщина по контрольной рулетке"))
    measurement.revision = 2
    let thickness = try MeasurementPlanControl.applying(measurement: measurement, to: height,
        wallID: plan.walls[0].id, dimension: .wallThickness)
    #expect(thickness.walls[0].thicknessMeters == 0.25)
    #expect(thickness.walls[0].heightMeters == 3)
    #expect(thickness.measurementApplications?.count == 2)
    #expect(thickness.measurementApplications?[1].appliedMeters == 0.25)
    #expect(thickness.measurementApplications?[1].measurementRevision == 2)
}

@Test func planControlRejectsUnsavedForeignMissingZeroAndIncompatibleDimensions() throws {
    var measurement = referenceRecord(meters: 2)
    let plan = controlPlan(projectID: measurement.projectID)
    #expect(throws: PlanMeasurementError.unsavedMeasurement) {
        try MeasurementPlanControl.applying(measurement: measurement, to: plan, wallID: plan.walls[0].id, dimension: .wallLength)
    }
    measurement.revision = 1
    var foreign = measurement
    foreign.projectID = UUID()
    #expect(throws: PlanMeasurementError.projectMismatch) {
        try MeasurementPlanControl.applying(measurement: foreign, to: plan, wallID: plan.walls[0].id, dimension: .wallLength)
    }
    #expect(throws: PlanMeasurementError.wallNotFound) {
        try MeasurementPlanControl.applying(measurement: measurement, to: plan, wallID: UUID(), dimension: .wallLength)
    }
    var zero = plan
    zero.walls[0].end = zero.walls[0].start
    #expect(throws: PlanMeasurementError.zeroLengthWall) {
        try MeasurementPlanControl.applying(measurement: measurement, to: zero, wallID: zero.walls[0].id, dimension: .wallLength)
    }
    measurement.kind = .verticalDistance
    #expect(throws: PlanMeasurementError.incompatibleDimension) {
        try MeasurementPlanControl.applying(measurement: measurement, to: plan, wallID: plan.walls[0].id, dimension: .wallLength)
    }
    #expect(throws: PlanMeasurementError.incompatibleDimension) {
        try MeasurementPlanControl.applying(measurement: measurement, to: plan, wallID: plan.walls[0].id, dimension: .wallThickness)
    }
    _ = try MeasurementPlanControl.applying(measurement: measurement, to: plan, wallID: plan.walls[0].id, dimension: .wallHeight)
    measurement.originalMeters = 0
    #expect(throws: PlanMeasurementError.nonpositiveDimension) {
        try MeasurementPlanControl.applying(measurement: measurement, to: plan, wallID: plan.walls[0].id, dimension: .wallHeight)
    }
}

@Test func controlAuditCannotBeRewrittenDeletedOrDuplicated() throws {
    var measurement = referenceRecord(meters: 3)
    measurement.revision = 1
    let before = controlPlan(projectID: measurement.projectID)
    let saved = try MeasurementPlanControl.applying(measurement: measurement, to: before,
        wallID: before.walls[0].id, dimension: .wallHeight)
    var changed = saved
    changed.measurementApplications = nil
    #expect(throws: PlanMeasurementError.applicationHistoryChanged) {
        try MeasurementPlanControl.validateTransition(from: saved, to: changed)
    }
    changed = saved
    changed.measurementApplications?[0].appliedMeters = 4
    #expect(throws: PlanMeasurementError.applicationHistoryChanged) {
        try MeasurementPlanControl.validateTransition(from: saved, to: changed)
    }
    changed = saved
    changed.measurementApplications?.append(saved.measurementApplications![0])
    #expect(throws: PlanMeasurementError.invalidApplication) { try MeasurementPlanControl.validateApplications(changed) }
}

@Test func horizontalARProjectionCannotBecomeWallHeightButGenericDistanceRemainsExplicitControl() throws {
    var horizontal = try raycastRecord(kind: .horizontalDistance)
    horizontal.revision = 1
    let plan = controlPlan(projectID: horizontal.projectID)
    #expect(throws: PlanMeasurementError.incompatibleDimension) {
        try MeasurementPlanControl.applying(measurement: horizontal, to: plan,
            wallID: plan.walls[0].id, dimension: .wallHeight)
    }
    let length = try MeasurementPlanControl.applying(measurement: horizontal, to: plan,
        wallID: plan.walls[0].id, dimension: .wallLength)
    #expect(length.measurementApplications?.first?.appliedMeters == 5)
    _ = try MeasurementPlanControl.applying(measurement: horizontal, to: plan,
        wallID: plan.walls[0].id, dimension: .wallThickness)
    var generic = try MeasurementRecord.arRaycast(projectID: plan.projectID, frameID: UUID(),
        start: .init(x: 0, y: 0, z: 0), end: .init(x: 0, y: 3, z: 0), trackingQuality: .normal)
    generic.revision = 1
    let height = try MeasurementPlanControl.applying(measurement: generic, to: plan,
        wallID: plan.walls[0].id, dimension: .wallHeight)
    #expect(height.walls[0].heightMeters == 3)
    #expect(height.frameID == plan.frameID)
    #expect(height.frameID != generic.frameID)
}

@Test func appliedControlsPersistCanonicalAuditDatesAndRejectHistoryDeletionInStore() async throws {
    let directory = try measurementDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AtlasStore(path: directory.appendingPathComponent("project.sqlite").path)
    let project = try await store.saveProject(.init(name: "Обмер дома", kind: .building,
        coordinateReference: .localMeters(frameID: UUID())))
    var plan = controlPlan(projectID: project.id)
    plan.revision = 0
    plan = try await store.saveFloorPlan(plan)
    var measurement = referenceRecord(projectID: project.id, meters: 6)
    measurement.revision = 2
    let first = try MeasurementPlanControl.applying(measurement: measurement, to: plan, wallID: plan.walls[0].id,
        dimension: .wallLength, now: Date(timeIntervalSinceReferenceDate: 805_321_900.123456789))
    let saved = try await store.saveFloorPlan(first)
    let reopened = try AtlasStore(path: directory.appendingPathComponent("project.sqlite").path)
    let loaded = try #require(try await reopened.floorPlans(projectID: project.id).first)
    #expect(saved == loaded)
    #expect(loaded.measurementApplications?[0].measurementID == measurement.id)
    #expect(loaded.measurementApplications?[0].measurementRevision == 2)
    let second = try MeasurementPlanControl.applying(measurement: measurement, to: loaded, wallID: loaded.walls[0].id,
        dimension: .wallHeight, now: Date(timeIntervalSinceReferenceDate: 805_321_901.987654321))
    let twice = try await reopened.saveFloorPlan(second)
    #expect(twice.measurementApplications?.count == 2)
    var erased = twice
    erased.measurementApplications = []
    await #expect(throws: PlanMeasurementError.applicationHistoryChanged) { try await reopened.saveFloorPlan(erased) }
    #expect(try await reopened.floorPlans(projectID: project.id) == [twice])
}

@Test func legacyFloorPlanWithoutControlHistoryDecodesUnchanged() throws {
    let plan = controlPlan(projectID: UUID())
    let data = try AtlasJSON.encode(plan)
    #expect(!String(decoding: data, as: UTF8.self).contains("measurementApplications"))
    let decoded = try AtlasJSON.decode(AtlasFloorPlan.self, from: data)
    #expect(decoded.measurementApplications == nil)
    #expect(decoded.walls == plan.walls)
}

@Test func externalSnapshotsCannotBypassMeasurementAndPlanControlValidationDuringExport() throws {
    let project = AtlasProject(name: "Контрольный план", kind: .building,
        coordinateReference: .localMeters(frameID: UUID()))
    for (revision, appliedMeters) in [(Int64(0), 3.0), (1, Double.nan), (1, Double.infinity)] {
        var plan = controlPlan(projectID: project.id)
        plan.measurementApplications = [.init(measurementID: UUID(), measurementRevision: revision,
            wallID: plan.walls[0].id, dimension: .wallHeight, previousMeters: 2.8,
            appliedMeters: appliedMeters)]
        let snapshot = AtlasProjectSnapshot(project: project, floorPlans: [plan])
        #expect(throws: PlanMeasurementError.invalidApplication) {
            try AtlasExporter.export(snapshot, format: .projectJSON)
        }
    }
    let malformed = referenceRecord(projectID: project.id, meters: .nan)
    #expect(throws: MeasurementError.invalidDistance) {
        try AtlasExporter.export(.init(project: project, measurements: [malformed]), format: .projectJSON)
    }
    let foreign = referenceRecord(projectID: UUID())
    #expect(throws: AtlasExportError.entityProjectMismatch) {
        try AtlasExporter.export(.init(project: project, measurements: [foreign]), format: .projectJSON)
    }
}
