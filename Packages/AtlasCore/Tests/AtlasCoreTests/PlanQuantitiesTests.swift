import Foundation
import Testing
@testable import AtlasCore

private func quantityRectangle(frame: UUID, width: Double = 4, height: Double = 3) -> MetricPolygon {
    MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: width, y: 0),
        .init(x: width, y: height), .init(x: 0, y: height)])
}

@Test func floorGrossAndNetRespectObservedHolesAndWinding() throws {
    let frame = UUID()
    var contour = quantityRectangle(frame: frame)
    contour.holes = [[.init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 2, y: 2), .init(x: 1, y: 2)]]
    let result = try PlanQuantities.floorArea(of: contour, expectedFrameID: frame)
    #expect(result.grossSquareMeters == 12)
    #expect(result.holesSquareMeters == 1)
    #expect(result.netSquareMeters == 11)
    contour.vertices.reverse(); contour.holes[0].reverse()
    #expect(try PlanQuantities.floorArea(of: contour, expectedFrameID: frame) == result)
    #expect(throws: GeometryError.coordinateFrameMismatch) {
        try PlanQuantities.floorArea(of: contour, expectedFrameID: UUID())
    }
}

@Test func wallFaceNetRequiresExplicitOpeningCoverage() throws {
    let frame = UUID()
    var face = quantityRectangle(frame: frame, width: 5, height: 3)
    face.holes = [[.init(x: 1, y: 0.5), .init(x: 2, y: 0.5), .init(x: 2, y: 2.5), .init(x: 1, y: 2.5)]]
    let partial = try PlanQuantities.wallFaceArea(of: face, expectedFrameID: frame, openingsComplete: false)
    #expect(partial.grossSquareMeters == 15)
    #expect(partial.holesSquareMeters == 2)
    #expect(partial.netSquareMeters == nil)
    let complete = try PlanQuantities.wallFaceArea(of: face, expectedFrameID: frame, openingsComplete: true)
    #expect(complete.netSquareMeters == 13)
    let noObservedOpenings = try PlanQuantities.wallFaceArea(
        of: quantityRectangle(frame: frame), expectedFrameID: frame, openingsComplete: false)
    #expect(noObservedOpenings.netSquareMeters == nil)
}

@Test func rectangularWallGrossCountsOneFaceAndKeepsUnknownHeight() throws {
    var wall = PlanWall(start: .init(x: 2, y: 3), end: .init(x: 6, y: 6), heightMeters: 2.5, thicknessMeters: 0.3)
    #expect(try PlanQuantities.wallGrossArea(of: wall) == 12.5)
    wall.heightMeters = nil
    #expect(try PlanQuantities.wallGrossArea(of: wall) == nil)
    for invalid in [0.0, -1, Double.infinity, Double.nan] {
        wall.heightMeters = invalid
        #expect(throws: GeometryError.invalidWall) { try PlanQuantities.wallGrossArea(of: wall) }
    }
    wall.heightMeters = 2.5; wall.end = wall.start
    #expect(throws: GeometryError.invalidWall) { try PlanQuantities.wallGrossArea(of: wall) }
}

@Test func planSummaryShowsSubtotalsWithoutInferringCompletenessOrUnion() throws {
    let frame = UUID()
    var first = PlanRoom(name: "First", boundary: quantityRectangle(frame: frame))
    first.boundary.holes = [[.init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 2, y: 2), .init(x: 1, y: 2)]]
    let overlapping = PlanRoom(name: "Overlapping", boundary: quantityRectangle(frame: frame))
    let mismatched = PlanRoom(name: "Separate frame", boundary: quantityRectangle(frame: UUID()))
    let invalid = PlanRoom(name: "Invalid", boundary: MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0)]))
    let knownWall = PlanWall(start: .init(x: 0, y: 0), end: .init(x: 4, y: 0), heightMeters: 2.5)
    let unknownWall = PlanWall(start: .init(x: 4, y: 0), end: .init(x: 4, y: 3))
    let invalidWall = PlanWall(start: .init(x: 4, y: 3), end: .init(x: 0, y: 3), heightMeters: .infinity)
    let summary = PlanQuantities.summary(of: AtlasFloorPlan(projectID: UUID(), frameID: frame,
        rooms: [first, overlapping, mismatched, invalid, first], walls: [knownWall, unknownWall, invalidWall, knownWall]))
    #expect(summary.floorGrossSquareMeters == 24)
    #expect(summary.floorNetSquareMeters == 23)
    #expect(summary.wallGrossSquareMeters == 10)
    #expect(summary.wallNetSquareMeters == nil)
    #expect(summary.roomCount == 5 && summary.measuredRoomCount == 2)
    #expect(summary.crossFrameRoomCount == 1 && summary.invalidRoomCount == 1 && summary.duplicateRoomCount == 1)
    #expect(summary.wallCount == 4 && summary.measuredWallCount == 1)
    #expect(summary.unknownHeightWallCount == 1 && summary.invalidWallCount == 1 && summary.duplicateWallCount == 1)
    #expect(!summary.hasCompleteFloorContours && !summary.hasCompleteWallHeights)
    #expect(summary.aggregationNote.contains("пересечения не объединены"))
}

@Test func emptyAndUnobservedPlansNeverShowZeroAsMeasuredArea() throws {
    let frame = UUID()
    let empty = PlanQuantities.summary(of: AtlasFloorPlan(projectID: UUID(), frameID: frame))
    #expect(empty.floorGrossSquareMeters == nil && empty.floorNetSquareMeters == nil)
    #expect(empty.wallGrossSquareMeters == nil && empty.wallNetSquareMeters == nil)
    #expect(!empty.hasCompleteFloorContours && !empty.hasCompleteWallHeights)
    let unobserved = PlanQuantities.summary(of: AtlasFloorPlan(projectID: UUID(), frameID: frame,
        rooms: [.init(name: "Foreign", boundary: quantityRectangle(frame: UUID()))],
        walls: [.init(start: .init(x: 0, y: 0), end: .init(x: 4, y: 0))]))
    #expect(unobserved.floorNetSquareMeters == nil && unobserved.wallGrossSquareMeters == nil)
    #expect(unobserved.crossFrameRoomCount == 1 && unobserved.unknownHeightWallCount == 1)
}

@Test func validProvidedObjectsCanBeCompleteWhileTheirScanCoverageIsStillUnknown() {
    let frame = UUID()
    let summary = PlanQuantities.summary(of: AtlasFloorPlan(projectID: UUID(), frameID: frame,
        rooms: [.init(name: "Only observed room", boundary: quantityRectangle(frame: frame))],
        walls: [.init(start: .init(x: 0, y: 0), end: .init(x: 4, y: 0), heightMeters: 2.5)]))
    #expect(summary.hasCompleteFloorContours && summary.hasCompleteWallHeights)
    #expect(summary.wallNetSquareMeters == nil)
    #expect(summary.aggregationNote.contains("горизонтальная проекция"))
}

@Test func duplicatedInvalidRecordCannotBeReplacedSilentlyByLaterGeometry() {
    let frame = UUID(), id = UUID()
    let original = PlanRoom(id: id, name: "Unregistered", boundary: quantityRectangle(frame: UUID()))
    let changed = PlanRoom(id: id, name: "Registered", boundary: quantityRectangle(frame: frame))
    let summary = PlanQuantities.summary(of: AtlasFloorPlan(projectID: UUID(), frameID: frame, rooms: [original, changed]))
    #expect(summary.floorNetSquareMeters == nil)
    #expect(summary.crossFrameRoomCount == 1 && summary.duplicateRoomCount == 1 && summary.measuredRoomCount == 0)
}

@Test func wallSubtotalOverflowIsExcludedAndNeverPublishedAsInfinity() {
    let first = PlanWall(start: .init(x: 0, y: 0), end: .init(x: 1, y: 0), heightMeters: 1e308)
    let second = PlanWall(start: .init(x: 1, y: 0), end: .init(x: 2, y: 0), heightMeters: 1e308)
    let summary = PlanQuantities.summary(of: AtlasFloorPlan(projectID: UUID(), frameID: UUID(), walls: [first, second]))
    #expect(summary.wallGrossSquareMeters == 1e308)
    #expect(summary.measuredWallCount == 1 && summary.invalidWallCount == 1)
    #expect(!summary.hasCompleteWallHeights)
}
