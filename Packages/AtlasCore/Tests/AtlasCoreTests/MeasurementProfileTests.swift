import Foundation
import Testing
@testable import AtlasCore

private func profileReading(project: UUID, frame: UUID, target: UUID, profile: UUID,
                            role: MeasurementRole, position: MeasurementSamplePosition,
                            from: MetricPoint3D, to: MetricPoint3D) throws -> MeasurementRecord {
    try .arRaycast(projectID: project, kind: role == .height ? .verticalDistance : .horizontalDistance,
        frameID: frame, start: from, end: to, trackingQuality: .normal,
        context: .init(role: role, target: .door, targetID: target, profileID: profile, position: position))
}

@Test func dimensionalRolesDoNotReplaceTheObservedProjectionOrInventManualAxes() throws {
    let project = UUID(), frame = UUID()
    let start = MetricPoint3D(x: 1, y: 2, z: 3), end = MetricPoint3D(x: 4, y: 14, z: 7)
    #expect(throws: MeasurementError.incompatibleHeightProjection) {
        try MeasurementRecord.arRaycast(projectID: project, kind: .distance, frameID: frame,
            start: start, end: end, trackingQuality: .normal, context: .init(role: .height))
    }
    let height = try MeasurementRecord.arRaycast(projectID: project, kind: .verticalDistance,
        frameID: frame, start: start, end: end, trackingQuality: .normal, context: .init(role: .height))
    #expect(height.originalMeters == 12)
    #expect(height.notation == "H")
    #expect(height.coordinateBasis == .arKitYUp)
    let manual = MeasurementRecord(projectID: project, source: .laserReference, originalMeters: 2.5,
        context: .init(role: .height, target: .cabinetDoor))
    try MeasurementPolicy.validate(manual)
    #expect(manual.coordinateBasis == nil && manual.start == nil)
    #expect(manual.context?.target == .cabinetDoor)
}

@Test func dimensionEndpointsKeepTheActualRaycastAndProjectOnlyTheSelectedComponent() throws {
    let a = MetricPoint3D(x: 1, y: 2, z: 3), b = MetricPoint3D(x: 4, y: 14, z: 7)
    let direct = try MeasurementGeometry.dimensionEndpoints(kind: .distance, from: a, to: b)
    let horizontal = try MeasurementGeometry.dimensionEndpoints(kind: .horizontalDistance, from: a, to: b)
    let vertical = try MeasurementGeometry.dimensionEndpoints(kind: .verticalDistance, from: a, to: b)
    #expect(direct.start == a && direct.end == b)
    #expect(horizontal.end == .init(x: 4, y: 2, z: 7))
    #expect(vertical.end == .init(x: 1, y: 14, z: 3))
    #expect(horizontal.sourceEnd == b && vertical.sourceEnd == b)
    #expect(direct.startLabel == "A" && direct.endLabel == "B")
    #expect(try MeasurementGeometry.distance(from: vertical.start, to: vertical.end) == 12)
    #expect(try MeasurementGeometry.distance(from: horizontal.start, to: horizontal.end) == 5)
}

@Test func tiltedWindowHeightAlongSurfaceIsDistinctFromGravityHeightAndCannotControlVerticalWallHeight() throws {
    let project = UUID(), frame = UUID()
    let start = MetricPoint3D(x: 0, y: 0, z: 0), end = MetricPoint3D(x: 0, y: 1.6, z: 1.2)
    var surface = try MeasurementRecord.arRaycast(projectID: project, kind: .distance,
        frameID: frame, start: start, end: end, trackingQuality: .normal,
        context: .init(role: .surfaceHeight, target: .window, targetID: UUID()))
    let vertical = try MeasurementRecord.arRaycast(projectID: project, kind: .verticalDistance,
        frameID: frame, start: start, end: end, trackingQuality: .normal,
        context: .init(role: .height, target: .window, targetID: surface.context?.targetID))
    #expect(surface.originalMeters == 2 && surface.notation == "Hₛ")
    #expect(vertical.originalMeters == 1.6 && vertical.notation == "H")
    #expect(throws: MeasurementError.incompatibleSurfaceHeightProjection) {
        try MeasurementRecord.arRaycast(projectID: project, kind: .verticalDistance,
            frameID: frame, start: start, end: end, trackingQuality: .normal,
            context: .init(role: .surfaceHeight, target: .window))
    }
    surface.revision = 1
    let wall = PlanWall(start: .init(x: 0, y: 0), end: .init(x: 4, y: 0), heightMeters: 2.5)
    let plan = AtlasFloorPlan(projectID: project, frameID: frame, walls: [wall])
    #expect(throws: PlanMeasurementError.incompatibleDimension) {
        try MeasurementPlanControl.applying(measurement: surface, to: plan, wallID: wall.id, dimension: .wallHeight)
    }
}

@Test func nonparallelOpeningWidthsAtThreeLevelsStaySeparateWithARealRange() throws {
    let project = UUID(), frame = UUID(), target = UUID(), profile = UUID()
    let readings = try zip([0.2, 1.2, 2.2], [MeasurementSamplePosition.lower, .middle, .upper]).enumerated().map { index, pair in
        try profileReading(project: project, frame: frame, target: target, profile: profile, role: .width,
            position: pair.1, from: .init(x: 0, y: pair.0, z: 0),
            to: .init(x: 0.8 + Double(index) * 0.05, y: pair.0 + 0.01, z: 0))
    }
    let summary = try MeasurementProfile.summarize(readings)
    #expect(summary.count == 3 && summary.coordinateComparisonAvailable)
    #expect(summary.minimumMeters == 0.8)
    #expect(abs(summary.maximumMeters - 0.9) < 1e-12)
    #expect(abs(summary.spreadMeters - 0.1) < 1e-12)
    #expect(Set(summary.observations.map(\.id)) == Set(readings.map(\.id)))
    #expect(Set(summary.observations.compactMap { $0.context?.position }) == Set([.lower, .middle, .upper]))
    #expect(summary.observations.allSatisfy { $0.end?.y != $0.start?.y })
    #expect(summary.context.position == .unspecified)
}

@Test func slopedCeilingProducesDistinctVerticalHeightsWithoutDiagonalInflation() throws {
    let project = UUID(), frame = UUID(), target = UUID(), profile = UUID()
    let readings = try [2.5, 2.67, 2.6].enumerated().map { index, height in
        try profileReading(project: project, frame: frame, target: target, profile: profile, role: .height,
            position: [.left, .center, .right][index], from: .init(x: Double(index) * 2, y: 0, z: 0),
            to: .init(x: Double(index) * 2 + 0.5, y: height, z: 0.5))
    }
    let summary = try MeasurementProfile.summarize(readings)
    #expect(summary.minimumMeters == 2.5 && summary.maximumMeters == 2.67)
    #expect(abs(summary.spreadMeters - 0.17) < 1e-12)
    #expect(summary.observations.map(\.originalMeters).sorted() == [2.5, 2.6, 2.67])
}

@Test func identifiedScalarProfileAcrossSessionsDoesNotClaimSpatialRegistration() throws {
    let project = UUID(), target = UUID(), profile = UUID(), frames = [UUID(), UUID()]
    let records = try frames.enumerated().map { index, frame in
        try profileReading(project: project, frame: frame, target: target, profile: profile, role: .width,
            position: .middle, from: .init(x: Double(index) * 20, y: 0, z: 0),
            to: .init(x: Double(index) * 20 + 1, y: 0, z: 0))
    }
    let summary = try MeasurementProfile.summarize(records)
    #expect(summary.count == 2 && summary.frameIDs.count == 2)
    #expect(!summary.coordinateComparisonAvailable)
    #expect(summary.minimumMeters == 1 && summary.maximumMeters == 1)
    #expect(summary.observations.map(\.start) != [records[0].start, records[0].start])
}

@Test func unidentifiedUnrelatedOrDuplicateDimensionsCannotBecomeOneProfile() throws {
    let project = UUID(), frame = UUID(), target = UUID(), profile = UUID()
    let first = try profileReading(project: project, frame: frame, target: target, profile: profile,
        role: .width, position: .middle, from: .init(x: 0, y: 1, z: 0), to: .init(x: 1, y: 1, z: 0))
    #expect(throws: MeasurementError.duplicateProfileObservation) { try MeasurementProfile.summarize([first, first]) }
    for replacement in 0..<5 {
        var other = first; other.id = UUID()
        switch replacement {
        case 0: other.projectID = UUID()
        case 1: other.context?.targetID = UUID()
        case 2: other.context?.profileID = UUID()
        case 3: other.context?.role = .length
        default: other.kind = .distance
        }
        #expect(throws: MeasurementError.incompatibleProfile) { try MeasurementProfile.summarize([first, other]) }
    }
    let unidentified = MeasurementRecord(projectID: project, source: .manualReference, originalMeters: 1,
        context: .init(role: .width, target: .door))
    #expect(throws: MeasurementError.incompatibleProfile) { try MeasurementProfile.summarize([unidentified]) }
    #expect(throws: MeasurementError.incompatibleProfile) { try MeasurementProfile.summarize([]) }
}

@Test func profileUsesAuditedCorrectionAndRetainsOriginalObservationContext() throws {
    let project = UUID(), target = UUID()
    var first = MeasurementRecord(projectID: project, source: .manualReference, originalMeters: 0.9,
        context: .init(role: .width, target: .door, targetID: target, position: .lower))
    let original = first
    first.corrections.append(.init(meters: 0.88, note: "Проверено нижнее сечение рулеткой"))
    try MeasurementPolicy.validateTransition(from: original, to: first)
    let second = MeasurementRecord(projectID: project, source: .laserReference, originalMeters: 0.91,
        context: .init(role: .width, target: .door, targetID: target, position: .upper))
    let summary = try MeasurementProfile.summarize([first, second])
    #expect(summary.minimumMeters == 0.88 && summary.maximumMeters == 0.91)
    #expect(summary.observations.first { $0.id == first.id }?.originalMeters == 0.9)
    #expect(summary.observations.first { $0.id == first.id }?.corrections.count == 1)
    #expect(!summary.coordinateComparisonAvailable && summary.frameIDs.isEmpty)
    var rewritten = first; rewritten.context?.target = .cabinetDoor
    #expect(throws: MeasurementError.originalChanged) { try MeasurementPolicy.validateTransition(from: first, to: rewritten) }
}

@Test func legacyMeasurementsDecodeWithoutContextAndNewContextSurvivesRepositoryReload() async throws {
    let project = UUID()
    let legacy = MeasurementRecord(projectID: project, source: .manualReference, originalMeters: 4)
    let data = try AtlasJSON.encode(legacy)
    #expect(!String(decoding: data, as: UTF8.self).contains("context"))
    #expect(try AtlasJSON.decode(MeasurementRecord.self, from: data).context == nil)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try MeasurementRepository(directory: directory)
    let record = MeasurementRecord(projectID: project, source: .laserReference, originalMeters: 0.76,
        context: .init(role: .width, target: .cabinetDoor, targetID: UUID(), profileID: UUID(),
                       position: .custom, positionNote: "Справа у петли"))
    let saved = try await repository.save(record)
    let reopened = try MeasurementRepository(directory: directory)
    #expect(await reopened.measurements(projectID: project) == [saved])
}

@Test func contextPositionValidationRejectsUnspecifiedCustomLocationsAndOversizedNotes() {
    let project = UUID()
    for note in ["  \n", String(repeating: "a", count: 501)] {
        let record = MeasurementRecord(projectID: project, source: .manualReference, originalMeters: 1,
            context: .init(role: .width, position: .custom, positionNote: note))
        #expect(throws: MeasurementError.invalidContext) { try MeasurementPolicy.validate(record) }
    }
}

@Test func clearOpeningAndReportedBoundingWidthCannotBeMixedAndMissingDefinitionStaysUnknown() throws {
    let project = UUID(), target = UUID(), profile = UUID()
    let clear = MeasurementRecord(projectID: project, source: .manualReference, originalMeters: 0.8,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        context: .init(role: .width, target: .door, targetID: target, profileID: profile, definition: .clearOpening))
    var bounding = clear; bounding.id = UUID(); bounding.originalMeters = 0.95
    bounding.context?.definition = .reportedBounds
    #expect(throws: MeasurementError.incompatibleProfile) { try MeasurementProfile.summarize([clear, bounding]) }
    var legacy = clear; legacy.context?.definition = nil
    let encoded = try AtlasJSON.encode(legacy)
    let decoded = try AtlasJSON.decode(MeasurementRecord.self, from: encoded)
    #expect(decoded.context?.definition == nil)
    #expect(decoded.context?.effectiveDefinition == .unspecified)
    #expect(decoded == legacy)
    var changed = clear; changed.context?.definition = .doorLeaf
    #expect(throws: MeasurementError.originalChanged) { try MeasurementPolicy.validateTransition(from: clear, to: changed) }
}

@Test func semanticHeightAndThicknessCannotControlUnrelatedPlanDimensions() throws {
    let project = UUID(), frame = UUID()
    let wall = PlanWall(start: .init(x: 0, y: 0), end: .init(x: 4, y: 0), heightMeters: 2.5)
    let plan = AtlasFloorPlan(projectID: project, frameID: frame, walls: [wall])
    var height = MeasurementRecord(projectID: project, source: .manualReference, originalMeters: 2.6,
        revision: 1, context: .init(role: .height, target: .wall, targetID: wall.id))
    #expect(throws: PlanMeasurementError.incompatibleDimension) {
        try MeasurementPlanControl.applying(measurement: height, to: plan, wallID: wall.id, dimension: .wallLength)
    }
    let updated = try MeasurementPlanControl.applying(measurement: height, to: plan, wallID: wall.id, dimension: .wallHeight)
    #expect(updated.walls[0].heightMeters == 2.6)
    height.context?.role = .thickness
    #expect(throws: PlanMeasurementError.incompatibleDimension) {
        try MeasurementPlanControl.applying(measurement: height, to: plan, wallID: wall.id, dimension: .wallHeight)
    }
}
