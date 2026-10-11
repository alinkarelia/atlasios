import Foundation
import Testing
@testable import AtlasCore

private let surveyEpoch = Date(timeIntervalSince1970: 1_790_000_000.125)
// Independent equatorial WGS84 radii: semi-major a and meridional radius a(1-e²).
private func surveyedCoordinate(east: Double, north: Double) -> GeographicCoordinate {
    .init(longitude: east / 6_378_137 * 180 / .pi,
          latitude: north / 6_335_439.3272928195 * 180 / .pi)
}
private func surveyedSample(east: Double = 0, north: Double = 0, seconds: Double,
                            accuracy: Double = 0.5, simulated: Bool = false) -> CemeterySurveySample {
    .init(coordinate: surveyedCoordinate(east: east, north: north), capturedAt: surveyEpoch.addingTimeInterval(seconds),
          horizontalAccuracyMeters: accuracy, altitudeMeters: 150.25, isSimulated: simulated)
}
private func surveyedRectangle(accuracy: Double = 0.5, lastEast: Double = 0.1,
                               lastNorth: Double = 0.1) throws -> CemeterySurveySession {
    var session = try CemeterySurveySession(startedAt: surveyEpoch)
    for (index, point) in [(0.0, 0.0), (8, 0), (8, 6), (0, 6), (lastEast, lastNorth)].enumerated() {
        let sample = surveyedSample(east: point.0, north: point.1, seconds: Double(index) * 3, accuracy: accuracy)
        try session.record(sample, receivedAt: sample.capturedAt)
    }
    return session
}

@Test func wgs84MetresUseKnownEquatorialEllipsoidAndBoundedProjection() throws {
    let origin = GeographicCoordinate(longitude: 0, latitude: 0)
    // 0.001 degree longitude at equator: a*sin(angle), ~111.3194908 m.
    let distance = try GeographicMetricGeometry.distance(from: origin, to: .init(longitude: 0.001, latitude: 0))
    #expect(abs(distance - 111.31949078762194) < 0.000_001)
    let north = try GeographicMetricGeometry.distance(from: origin, to: .init(longitude: 0, latitude: 0.001))
    #expect(abs(north - 110.574275815319) < 0.000_01)
    #expect(throws: GeographicMetricError.projectionExtentExceeded) {
        try GeographicMetricGeometry.distance(from: origin, to: .init(longitude: 0.1, latitude: 0))
    }
    #expect(throws: GeographicMetricError.invalidProjection) {
        try LocalWGS84Projection(anchor: origin, maximumRadiusMeters: 100_000)
    }
}

@Test func wgs84FootprintSubtractsHolesAndMeasuresMetricLine() throws {
    let polygon = GeographicPolygon(vertices: [surveyedCoordinate(east: 0, north: 0), surveyedCoordinate(east: 8, north: 0),
        surveyedCoordinate(east: 8, north: 6), surveyedCoordinate(east: 0, north: 6)],
        holes: [[surveyedCoordinate(east: 1, north: 1), surveyedCoordinate(east: 3, north: 1),
                 surveyedCoordinate(east: 3, north: 3), surveyedCoordinate(east: 1, north: 3)]])
    #expect(abs(try GeographicMetricGeometry.area(of: polygon) - 44) < 0.000_1)
    #expect(abs(try GeographicMetricGeometry.perimeter(of: polygon) - 36) < 0.000_1)
    let line = GeographicPolyline(vertices: [surveyedCoordinate(east: 0, north: 0), surveyedCoordinate(east: 3, north: 4)])
    #expect(abs(try GeographicMetricGeometry.length(of: line) - 5) < 0.000_1)
}

@Test func nearestFenceDistanceProjectsRealGeographyAndRejectsOtherMetricFrames() throws {
    let frame = UUID(), line = MetricPolyline(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 10, y: 0)])
    #expect(try GeographicMetricGeometry.nearestDistance(point: .metricPoint(frameID: frame, point: .init(x: 4, y: 3)),
                                                       toFence: .metricPolyline(line)) == 3)
    #expect(try GeographicMetricGeometry.nearestDistance(point: .metricPoint(frameID: frame, point: .init(x: 13, y: 4)),
                                                       toFence: .metricPolyline(line)) == 5)
    #expect(throws: GeometryError.coordinateFrameMismatch) {
        try GeographicMetricGeometry.nearestDistance(point: .metricPoint(frameID: UUID(), point: .init(x: 4, y: 3)),
                                                     toFence: .metricPolyline(line))
    }
    let fence = GeographicPolyline(vertices: [surveyedCoordinate(east: 0, north: 0), surveyedCoordinate(east: 10, north: 0)])
    let distance = try GeographicMetricGeometry.nearestDistance(point: .geographicPoint(surveyedCoordinate(east: 4, north: 3)),
                                                               toFence: .geographicPolyline(fence))
    #expect(abs(distance - 3) < 0.000_1)
    #expect(throws: GeometryError.coordinateFrameMismatch) {
        try GeographicMetricGeometry.nearestDistance(point: .geographicPoint(surveyedCoordinate(east: 4, north: 3)),
                                                     toFence: .metricPolyline(line))
    }
}

@Test func gpsRejectionsRetainRawTimeAltitudeAccuracyAndSimulationProvenance() throws {
    var session = try CemeterySurveySession(startedAt: surveyEpoch)
    let badAccuracy = surveyedSample(seconds: 0, accuracy: -1)
    #expect(try session.record(badAccuracy, receivedAt: surveyEpoch).rejectionReason == .invalidAccuracy)
    let stale = surveyedSample(seconds: -6)
    #expect(try session.record(stale, receivedAt: surveyEpoch).rejectionReason == .stale)
    let future = surveyedSample(seconds: 2)
    #expect(try session.record(future, receivedAt: surveyEpoch).rejectionReason == .future)
    let simulated = surveyedSample(seconds: 0, simulated: true)
    #expect(try session.record(simulated, receivedAt: surveyEpoch).rejectionReason == .simulated)
    let coarse = surveyedSample(seconds: 0, accuracy: 40)
    #expect(try session.record(coarse, receivedAt: surveyEpoch).rejectionReason == .insufficientAccuracy)
    #expect(session.observations.map(\.sample) == [badAccuracy, stale, future, simulated, coarse])
    #expect(session.segments.isEmpty)
    let restored = try JSONDecoder().decode(CemeterySurveySession.self, from: JSONEncoder().encode(session))
    #expect(restored == session)
    #expect(restored.observations.first?.sample.capturedAt == badAccuracy.capturedAt)
    #expect(restored.observations.first?.sample.altitudeMeters == 150.25)
}

@Test func malformedNumbersRemainRejectedAndCheckpointableWithoutJsonNaN() throws {
    var session = try CemeterySurveySession(startedAt: surveyEpoch)
    let malformed = CemeterySurveySample(coordinate: .init(longitude: .nan, latitude: 0), capturedAt: surveyEpoch,
                                         horizontalAccuracyMeters: .infinity, altitudeMeters: -.infinity)
    #expect(try session.record(malformed, receivedAt: surveyEpoch).rejectionReason == .invalidCoordinate)
    let data = try JSONEncoder().encode(session)
    let restored = try JSONDecoder().decode(CemeterySurveySession.self, from: data)
    #expect(restored == session)
    #expect(restored.observations[0].sample.coordinate.longitude.isNaN)
    try restored.validateCheckpoint()
}

@Test func gpsJumpAndOutOfOrderCannotBecomeAcceptedRouteVertices() throws {
    var session = try CemeterySurveySession(startedAt: surveyEpoch)
    let first = surveyedSample(seconds: 0), jump = surveyedSample(east: 20, seconds: 1)
    try session.record(first, receivedAt: first.capturedAt)
    #expect(try session.record(jump, receivedAt: jump.capturedAt).rejectionReason == .jump)
    let earlier = surveyedSample(east: 1, seconds: 0)
    #expect(try session.record(earlier, receivedAt: jump.capturedAt).rejectionReason == .outOfOrder)
    let recovered = surveyedSample(east: 1, seconds: 2)
    let decision = try session.record(recovered, receivedAt: recovered.capturedAt)
    #expect(decision.startsNewSegment)
    #expect(decision.breakReason == .rejectedObservation)
    #expect(session.segments.count == 2)
    #expect(session.observations.count == 4)
}

@Test func pauseAndLongTimeGapAlwaysSplitTracksInsteadOfBridging() throws {
    var session = try CemeterySurveySession(startedAt: surveyEpoch)
    let first = surveyedSample(seconds: 0)
    try session.record(first, receivedAt: first.capturedAt)
    try session.pause(at: surveyEpoch.addingTimeInterval(1))
    let paused = surveyedSample(east: 50, seconds: 2)
    #expect(try session.record(paused, receivedAt: paused.capturedAt).rejectionReason == .paused)
    try session.resume(at: surveyEpoch.addingTimeInterval(3))
    let resumed = surveyedSample(east: 50, seconds: 4)
    #expect(try session.record(resumed, receivedAt: resumed.capturedAt).breakReason == .resumed)
    let gap = surveyedSample(east: 150, seconds: 20)
    #expect(try session.record(gap, receivedAt: gap.capturedAt).breakReason == .timeGap)
    #expect(session.segments.map { $0.samples.count } == [1, 1, 1])
    try session.stop(at: surveyEpoch.addingTimeInterval(21))
    #expect(try session.activeDuration(at: surveyEpoch.addingTimeInterval(22)) == 19)
    let late = surveyedSample(seconds: 22)
    #expect(try session.record(late, receivedAt: late.capturedAt).rejectionReason == .stopped)
    #expect(try JSONDecoder().decode(CemeterySurveySession.self, from: JSONEncoder().encode(session)) == session)
}

@Test func returnToStartNeverCreatesPolygonWithoutExplicitConfirmation() throws {
    var session = try surveyedRectangle()
    #expect(session.confirmations.isEmpty)
    let segment = try #require(session.segments.first)
    let boundary = try session.confirmBoundary(segmentID: segment.id, at: surveyEpoch.addingTimeInterval(13))
    #expect(boundary.polygon.vertices.count == 4)
    #expect(boundary.sourceSampleIDs == segment.samples.map(\.id))
    #expect(boundary.vertexSampleIDs == segment.samples.dropLast().map(\.id))
    #expect(abs(boundary.areaMetersSquared - 48) < 0.000_1)
    #expect(abs(boundary.perimeterMeters - 28) < 0.000_1)
    #expect(boundary.closureDistanceMeters < boundary.closureToleranceMeters)
    #expect(boundary.maximumHorizontalAccuracyMeters == 0.5)
    #expect(session.confirmations.count == 1)
    #expect(try JSONDecoder().decode(CemeterySurveySession.self, from: JSONEncoder().encode(session)) == session)
}

@Test func gpsClosureDoesNotTreatCoarseAccuracyOrFarEndpointsAsClosed() throws {
    var coarse = try surveyedRectangle(accuracy: 10)
    let coarseSegment = try #require(coarse.segments.first)
    #expect(throws: CemeterySurveyError.closureAccuracyInsufficient) {
        try coarse.confirmBoundary(segmentID: coarseSegment.id, at: surveyEpoch.addingTimeInterval(13))
    }
    var far = try surveyedRectangle(accuracy: 3, lastEast: 6, lastNorth: 0)
    let farSegment = try #require(far.segments.first)
    #expect(throws: CemeterySurveyError.closureGapTooLarge) {
        try far.confirmBoundary(segmentID: farSegment.id, at: surveyEpoch.addingTimeInterval(13))
    }
    #expect(coarse.confirmations.isEmpty && far.confirmations.isEmpty)
    #expect(throws: CemeterySurveyError.invalidPolicy) {
        try CemeterySurveySession(policy: .init(maximumClosureGapMeters: 40), startedAt: surveyEpoch)
    }
}

@Test func selfCrossingGpsRingCannotBeHiddenBySimplification() throws {
    var session = try CemeterySurveySession(startedAt: surveyEpoch)
    for (index, point) in [(0.0, 0.0), (8, 6), (0, 6), (8, 0), (0.1, 0.1)].enumerated() {
        let sample = surveyedSample(east: point.0, north: point.1, seconds: Double(index) * 3)
        try session.record(sample, receivedAt: sample.capturedAt)
    }
    let segment = try #require(session.segments.first)
    #expect(throws: GeometryError.selfIntersection) {
        try session.confirmBoundary(segmentID: segment.id, at: surveyEpoch.addingTimeInterval(13), simplificationToleranceMeters: 1)
    }
    #expect(session.confirmations.isEmpty)
}

@Test func conservativeGpsSimplificationKeepsAllRawProvenance() throws {
    var session = try CemeterySurveySession(startedAt: surveyEpoch)
    for (index, point) in [(0.0, 0.0), (4, 0.1), (8, 0), (8, 6), (0, 6), (0.1, 0.1)].enumerated() {
        let sample = surveyedSample(east: point.0, north: point.1, seconds: Double(index) * 3)
        try session.record(sample, receivedAt: sample.capturedAt)
    }
    let segment = try #require(session.segments.first)
    let boundary = try session.confirmBoundary(segmentID: segment.id, at: surveyEpoch.addingTimeInterval(16), simplificationToleranceMeters: 0.2)
    #expect(boundary.polygon.vertices.count == 4)
    #expect(boundary.sourceSampleIDs.count == 6)
    #expect(session.observations.count == 6)
    #expect(abs(boundary.areaMetersSquared - 48) < 0.000_1)
    #expect(throws: CemeterySurveyError.invalidSimplificationTolerance) {
        try session.confirmBoundary(segmentID: segment.id, at: surveyEpoch.addingTimeInterval(17), simplificationToleranceMeters: 2)
    }
}

@Test func stationaryGpsObservationsStayRawWithoutDuplicateGeometryVertices() throws {
    var session = try CemeterySurveySession(startedAt: surveyEpoch)
    for (index, point) in [(0.0, 0.0), (0, 0), (8, 0), (8, 0), (8, 6), (0, 6), (0, 0), (0, 0)].enumerated() {
        let sample = surveyedSample(east: point.0, north: point.1, seconds: Double(index) * 3)
        try session.record(sample, receivedAt: sample.capturedAt)
    }
    let segment = try #require(session.segments.first)
    let line = try session.makePolyline(segmentID: segment.id)
    #expect(line.vertices.count == 5)
    let boundary = try session.confirmBoundary(segmentID: segment.id, at: surveyEpoch.addingTimeInterval(22))
    #expect(boundary.polygon.vertices.count == 4)
    #expect(boundary.sourceSampleIDs.count == 8)
    #expect(session.observations.count == 8)
    #expect(abs(boundary.areaMetersSquared - 48) < 0.000_1)
}

@Test func boundedGpsJournalNeverDropsObservationsAndReservesTerminalStop() throws {
    var session = try CemeterySurveySession(policy: .init(maximumJournalEntries: 8), startedAt: surveyEpoch)
    for index in 0..<7 {
        let sample = surveyedSample(east: Double(index), seconds: Double(index))
        try session.record(sample, receivedAt: sample.capturedAt)
    }
    let before = session
    let overflow = surveyedSample(east: 7, seconds: 7)
    #expect(throws: CemeterySurveyError.capacityReached) { try session.record(overflow, receivedAt: overflow.capturedAt) }
    #expect(session == before)
    try session.stop(at: overflow.capturedAt)
    #expect(session.journal.count == 8 && session.observations.count == 7 && session.state == .stopped)
    #expect(try JSONDecoder().decode(CemeterySurveySession.self, from: JSONEncoder().encode(session)) == session)
}

@Test func checkpointRejectsForgedFilterDecisionAndOldSegmentReusedAcrossPause() throws {
    var session = try CemeterySurveySession(startedAt: surveyEpoch)
    let first = surveyedSample(seconds: 0)
    try session.record(first, receivedAt: first.capturedAt)
    try session.pause(at: surveyEpoch.addingTimeInterval(1))
    try session.resume(at: surveyEpoch.addingTimeInterval(2))
    let second = surveyedSample(east: 1, seconds: 3)
    try session.record(second, receivedAt: second.capturedAt)
    let original = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
    let firstSegment = try #require(session.segments.first?.id), secondSegment = try #require(session.segments.last?.id)
    let forged = original.replacingOccurrences(of: secondSegment.uuidString, with: firstSegment.uuidString)
    #expect(throws: CemeterySurveyError.invalidCheckpoint) {
        try JSONDecoder().decode(CemeterySurveySession.self, from: Data(forged.utf8))
    }
    #expect(throws: CemeterySurveyError.duplicateSampleID) {
        try session.record(second, receivedAt: second.capturedAt)
    }
    var malformed = try CemeterySurveySession(startedAt: surveyEpoch)
    let invalid = surveyedSample(seconds: 0, accuracy: 40)
    try malformed.record(invalid, receivedAt: surveyEpoch)
    let coarseJSON = String(decoding: try JSONEncoder().encode(malformed), as: UTF8.self)
    let forgedReason = coarseJSON.replacingOccurrences(of: "insufficientAccuracy", with: "stale")
    #expect(throws: CemeterySurveyError.invalidCheckpoint) {
        try JSONDecoder().decode(CemeterySurveySession.self, from: Data(forgedReason.utf8))
    }
}
