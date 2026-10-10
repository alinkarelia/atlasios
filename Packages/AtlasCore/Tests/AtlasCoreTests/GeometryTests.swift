import Foundation
import Testing
@testable import AtlasCore

private func rectangle(_ frameID: UUID = UUID(), x: Double = 0, y: Double = 0, width: Double = 4, height: Double = 6) -> MetricPolygon {
    MetricPolygon(frameID: frameID, vertices: [.init(x: x, y: y), .init(x: x + width, y: y),
                                             .init(x: x + width, y: y + height), .init(x: x, y: y + height)])
}

@Test func metricAreaSubtractsHolesAndDoesNotDependOnWinding() throws {
    var polygon = rectangle()
    polygon.holes = [[.init(x: 1, y: 1), .init(x: 3, y: 1), .init(x: 3, y: 3), .init(x: 1, y: 3)]]
    #expect(try PolygonGeometry.area(of: polygon) == 20)
    #expect(try PolygonGeometry.perimeter(of: polygon) == 28)
    polygon.vertices.reverse()
    polygon.holes[0].reverse()
    #expect(try PolygonGeometry.area(of: polygon) == 20)
}

@Test func largeTranslationKeepsSmallMetricArea() throws {
    #expect(try PolygonGeometry.area(of: rectangle(x: 1_000_000_000, y: -1_000_000_000)) == 24)
}

@Test func unsafeRingsAreRejected() throws {
    let frame = UUID()
    let bowTie = MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 4, y: 4), .init(x: 0, y: 4), .init(x: 4, y: 0)])
    #expect(throws: GeometryError.selfIntersection) { try PolygonGeometry.validate(bowTie) }
    let line = MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 2, y: 0)])
    #expect(throws: GeometryError.degenerateRing) { try PolygonGeometry.validate(line) }
    var duplicate = rectangle(frame)
    duplicate.vertices.append(duplicate.vertices[0])
    #expect(throws: GeometryError.duplicateVertex) { try PolygonGeometry.validate(duplicate) }
    var invalid = rectangle(frame)
    invalid.vertices[0].x = .nan
    #expect(throws: GeometryError.nonFiniteCoordinate) { try PolygonGeometry.validate(invalid) }
}

@Test func exteriorAndHoleTopologyCannotSilentlyChange() throws {
    var polygon = rectangle()
    polygon.holes = [[.init(x: 8, y: 8), .init(x: 9, y: 8), .init(x: 9, y: 9), .init(x: 8, y: 9)]]
    #expect(throws: GeometryError.holeOutsideExterior) { try PolygonGeometry.validate(polygon) }
    polygon.holes = [[.init(x: 0, y: 1), .init(x: 1, y: 1), .init(x: 1, y: 2), .init(x: 0, y: 2)]]
    #expect(throws: GeometryError.intersectingRings) { try PolygonGeometry.validate(polygon) }
    polygon.holes = [
        [.init(x: 0.5, y: 0.5), .init(x: 3.5, y: 0.5), .init(x: 3.5, y: 4), .init(x: 0.5, y: 4)],
        [.init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 2, y: 2), .init(x: 1, y: 2)]
    ]
    #expect(throws: GeometryError.overlappingHoles) { try PolygonGeometry.validate(polygon) }
}

@Test func geographicValidityAndFrameIdentityAreExplicit() throws {
    let polygon = GeographicPolygon(vertices: [.init(longitude: 181, latitude: 50), .init(longitude: 37, latitude: 50), .init(longitude: 37, latitude: 51)])
    #expect(throws: GeometryError.geographicCoordinateOutOfRange) { try PolygonGeometry.validate(polygon) }
    let wrapped = GeographicPolygon(vertices: [.init(longitude: 179, latitude: 10), .init(longitude: -179, latitude: 10),
                                               .init(longitude: -179, latitude: 11), .init(longitude: 179, latitude: 11)])
    #expect(throws: GeometryError.antimeridianRequiresSplitting) { try PolygonGeometry.validate(wrapped) }
    #expect(throws: GeometryError.coordinateFrameMismatch) {
        try PolygonGeometry.validate(.metricPolygon(rectangle()), in: .localMeters(frameID: UUID()))
    }
}

@Test func floorPlanDimensionsCannotBeInvalid() throws {
    let frame = UUID()
    let plan = AtlasFloorPlan(projectID: UUID(), frameID: frame,
                             walls: [.init(start: .init(x: 0, y: 0), end: .init(x: 2, y: 0), heightMeters: -2)])
    #expect(throws: GeometryError.invalidWall) { try PolygonGeometry.validate(plan, in: .localMeters(frameID: frame)) }
}
