import Foundation
import Testing
@testable import AtlasCore

private let stationEpoch = Date(timeIntervalSince1970: 1_790_000_000.125)
private func stationSample(_ seconds: Double, east: Double = 0, north: Double = 0,
                           accuracy: Double = 8, simulated: Bool = false) -> CemeterySurveySample {
    .init(coordinate: .init(longitude: east / 6_378_137 * 180 / .pi,
                           latitude: north / 6_335_439.3272928195 * 180 / .pi),
          capturedAt: stationEpoch.addingTimeInterval(seconds), horizontalAccuracyMeters: accuracy,
          altitudeMeters: 100.25, isSimulated: simulated)
}
private func gpsStation() throws -> (StationSurvey, UUID) {
    var survey = StationSurvey(projectID: UUID(), coordinateReference: .wgs84, at: stationEpoch)
    let id = try survey.addStation(); try survey.beginGPS(stationID: id, at: stationEpoch)
    return (survey, id)
}
private func manualStations(_ points: [MetricPoint2D], frame: UUID = UUID()) throws -> StationSurvey {
    var survey = StationSurvey(projectID: UUID(), coordinateReference: .localMeters(frameID: frame), at: stationEpoch)
    for point in points {
        let id = try survey.addStation()
        try survey.enter(stationID: id, position: .metricPoint(frameID: frame, point: point), reason: "Полевой обмер", at: stationEpoch)
    }
    return survey
}

@Test func stationGPSOnlyCountsFreshUniquePostStartFixesAndRetainsRejectedRaw() throws {
    var (survey, id) = try gpsStation()
    let first = stationSample(0), duplicate = stationSample(0, east: 50)
    let samples = [first, duplicate, stationSample(-1), stationSample(0.2, simulated: true),
                   stationSample(0.4, accuracy: -1), stationSample(0.6, accuracy: 40),
                   stationSample(1.1), stationSample(4, east: 1), stationSample(8, east: 2)]
    let received = [0.0, 0, 0, 0.2, 0.4, 0.6, 5, 5, 8]
    for (sample, seconds) in zip(samples, received) {
        try survey.updateGPS(stationID: id, sample: sample, receivedAt: stationEpoch.addingTimeInterval(seconds))
    }
    try survey.finishGPS(stationID: id, at: stationEpoch.addingTimeInterval(10))
    let attempt = try #require(survey.stations[0].current)
    #expect(attempt.acceptedObservations.count == 3)
    #expect(attempt.observations.map(\.sample) == samples)
    #expect(attempt.observations.map(\.rejection) == [nil, "duplicateFix", "beforeStart", "simulated", "invalidAccuracy", "poorAccuracy", "stale", nil, nil])
    #expect(attempt.state == .accepted)
    try survey.validate()
    #expect(try JSONDecoder().decode(StationSurvey.self, from: JSONEncoder().encode(survey)) == survey)
}

@Test func stationGPSChoosesActualBestFixWithoutInventingImprovedAccuracy() throws {
    var (survey, id) = try gpsStation()
    let samples = [stationSample(1, east: 0, accuracy: 9), stationSample(4, east: 3, accuracy: 7), stationSample(8, east: 7, accuracy: 8)]
    for sample in samples { try survey.updateGPS(stationID: id, sample: sample, receivedAt: sample.capturedAt) }
    try survey.finishGPS(stationID: id, at: stationEpoch.addingTimeInterval(10))
    let attempt = try #require(survey.stations[0].current)
    #expect(attempt.position == .geographicPoint(samples[1].coordinate))
    #expect(attempt.reportedAccuracyMeters == 7)
    #expect(abs(try #require(attempt.spreadMeters) - 4) < 0.000_1)
    #expect(attempt.chosenObservation?.sample.altitudeMeters == 100.25)
}

@Test func stationGPSRequiresThreeFixesAndTenSecondsBeforeAccepting() throws {
    for (count, elapsed) in [(2, 10.0), (3, 9.0)] {
        var (survey, id) = try gpsStation()
        for index in 0..<count {
            let sample = stationSample(Double(index + 1))
            try survey.updateGPS(stationID: id, sample: sample, receivedAt: sample.capturedAt)
        }
        try survey.finishGPS(stationID: id, at: stationEpoch.addingTimeInterval(elapsed))
        #expect(survey.stations[0].attempts.last?.state == .insufficient)
        #expect(survey.stations[0].position == nil)
        #expect(survey.stations[0].attempts.last?.observations.count == count)
        try survey.validate()
    }
}

@Test func stationCancelledRemeasurementAndManualCorrectionPreserveOriginalGPS() throws {
    var (survey, id) = try gpsStation()
    for seconds in [1.0, 4, 8] {
        let sample = stationSample(seconds)
        try survey.updateGPS(stationID: id, sample: sample, receivedAt: sample.capturedAt)
    }
    try survey.finishGPS(stationID: id, at: stationEpoch.addingTimeInterval(10))
    let original = survey
    try survey.beginGPS(stationID: id, at: stationEpoch.addingTimeInterval(20))
    let sample = stationSample(21, east: 3)
    try survey.updateGPS(stationID: id, sample: sample, receivedAt: sample.capturedAt)
    try survey.finishGPS(stationID: id, at: stationEpoch.addingTimeInterval(22), cancelled: true)
    #expect(survey.stations[0].position == original.stations[0].position)
    #expect(survey.stations[0].attempts[1].observations.count == 1)
    let corrected = FeatureGeometry.geographicPoint(.init(longitude: 30, latitude: 60))
    try survey.enter(stationID: id, position: corrected, reason: "Координаты контрольной точки", at: stationEpoch.addingTimeInterval(30))
    #expect(survey.stations[0].attempts[0] == original.stations[0].attempts[0])
    #expect(survey.stations[0].attempts.count == 3)
    #expect(survey.stations[0].position == corrected)
    #expect(survey.stations[0].current?.reportedAccuracyMeters == nil)
    try survey.validateTransition(from: original)
}

@Test func stationHistoryCannotBeSilentlyRewrittenOrDiscarded() throws {
    var survey = try manualStations([.init(x: 1, y: 2)])
    let original = survey
    try survey.enter(stationID: survey.stations[0].id, position: survey.stations[0].position!, reason: "Проверка", at: stationEpoch.addingTimeInterval(1))
    try survey.validateTransition(from: original)
    #expect(throws: StationSurveyError.self) { try original.validateTransition(from: survey) }
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(survey)) as? [String: Any])
    var stations = try #require(json["stations"] as? [[String: Any]])
    var attempts = try #require(stations[0]["attempts"] as? [[String: Any]])
    attempts[0]["reason"] = "Переписанная история"; stations[0]["attempts"] = attempts; json["stations"] = stations
    let tampered = try JSONDecoder().decode(StationSurvey.self, from: JSONSerialization.data(withJSONObject: json))
    try tampered.validate()
    #expect(throws: StationSurveyError.self) { try tampered.validateTransition(from: survey) }
}

@Test func stationManualAuditReasonIsRequiredOnDecodedDocuments() throws {
    let survey = try manualStations([.init(x: 1, y: 2)])
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(survey)) as? [String: Any])
    var stations = try #require(json["stations"] as? [[String: Any]])
    var attempts = try #require(stations[0]["attempts"] as? [[String: Any]])
    attempts[0]["reason"] = " \n "; stations[0]["attempts"] = attempts; json["stations"] = stations
    let malformed = try JSONDecoder().decode(StationSurvey.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(throws: StationSurveyError.self) { try malformed.validate() }
}

@Test func stationLocalRectangleHasCorrectSegmentsAreaAndOpenLength() throws {
    let survey = try manualStations([.init(x: 0, y: 0), .init(x: 8, y: 0), .init(x: 8, y: 6), .init(x: 0, y: 6)])
    #expect(survey.stations.map(\.label) == ["A001", "A002", "A003", "A004"])
    let closed = try StationSurveyGeometry.outline(survey, closed: true)
    #expect(closed.areaSquareMeters == 48)
    #expect(closed.perimeterMeters == 28)
    #expect(closed.segments.map(\.distanceMeters) == [8, 6, 8, 6])
    #expect(closed.segments.allSatisfy { $0.trueBearingDegrees == nil })
    #expect(closed.segments.last?.to == "A001")
    let line = try StationSurveyGeometry.outline(survey, closed: false)
    #expect(line.areaSquareMeters == nil)
    #expect(line.perimeterMeters == 22)
    #expect(line.segments.count == 3)
    #expect(line.segments.last?.to == "A004")
}

@Test func stationWGS84CoordinatesProduceMetricAreaAndTrueNorthBearings() throws {
    var survey = StationSurvey(projectID: UUID(), coordinateReference: .wgs84, at: stationEpoch)
    for (east, north) in [(0.0, 0.0), (8, 0), (8, 6), (0, 6)] {
        let id = try survey.addStation()
        try survey.enter(stationID: id, position: .geographicPoint(stationSample(0, east: east, north: north).coordinate), reason: "Контрольная координата", at: stationEpoch)
    }
    let outline = try StationSurveyGeometry.outline(survey, closed: true)
    #expect(abs(try #require(outline.areaSquareMeters) - 48) < 0.000_1)
    #expect(abs(outline.perimeterMeters - 28) < 0.000_1)
    for (segment, expected) in zip(outline.segments, [90.0, 0, 270, 180]) {
        #expect(abs(try #require(segment.trueBearingDegrees) - expected) < 0.000_1)
    }
}

@Test func stationBoundaryRejectsCrossingsMissingCoordinatesAndMixedFrames() throws {
    let crossing = try manualStations([.init(x: 0, y: 0), .init(x: 8, y: 6), .init(x: 8, y: 0), .init(x: 0, y: 6)])
    #expect(throws: GeometryError.self) { try StationSurveyGeometry.outline(crossing, closed: true) }
    var valid = try manualStations([.init(x: 0, y: 0), .init(x: 8, y: 0), .init(x: 8, y: 6)])
    let empty = try valid.addStation()
    #expect(throws: StationSurveyError.self) { try StationSurveyGeometry.outline(valid, closed: true) }
    try valid.include(stationID: empty, value: false)
    #expect(try StationSurveyGeometry.outline(valid, closed: true).areaSquareMeters == 24)
    #expect(throws: GeometryError.coordinateFrameMismatch) {
        try valid.enter(stationID: empty, position: .metricPoint(frameID: UUID(), point: .init(x: 1, y: 1)), reason: "Обмер")
    }
    #expect(throws: StationSurveyError.self) { try valid.beginGPS(stationID: empty) }
    #expect(throws: StationSurveyError.self) { try StationSurveyExporter.geoJSON(valid) }
}

@Test func stationGeoJSONKeepsFailedStationsRawDataAndLongitudeLatitudeOrder() throws {
    var (survey, id) = try gpsStation()
    let raw = stationSample(1, east: 5, north: 2)
    try survey.updateGPS(stationID: id, sample: raw, receivedAt: raw.capturedAt)
    try survey.finishGPS(stationID: id, at: stationEpoch.addingTimeInterval(2), cancelled: true)
    let manual = try survey.addStation()
    try survey.enter(stationID: manual, position: .geographicPoint(.init(longitude: 30, latitude: 60)), reason: "Контроль", at: stationEpoch.addingTimeInterval(3))
    let output = try StationSurveyExporter.geoJSON(survey)
    let json = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
    let features = try #require(json["features"] as? [[String: Any]])
    #expect(features.count == 2)
    #expect(features[0]["geometry"] is NSNull)
    let props = try #require(features[0]["properties"] as? [String: Any])
    #expect(props["timestampEncoding"] as? String == "secondsSince2001UTC")
    let metadata = try #require(props["station"] as? [String: Any])
    let attempts = try #require(metadata["attempts"] as? [[String: Any]])
    #expect((attempts[0]["observations"] as? [Any])?.count == 1)
    let geometry = try #require(features[1]["geometry"] as? [String: Any])
    #expect(geometry["coordinates"] as? [Double] == [30, 60])
    #expect(try JSONDecoder().decode(StationSurvey.self, from: StationSurveyExporter.json(survey).data) == survey)
}

@Test func stationMalformedCoordinatesRemainRawAndNeverBecomePosition() throws {
    var (survey, id) = try gpsStation()
    let malformed = CemeterySurveySample(coordinate: .init(longitude: .nan, latitude: 0), capturedAt: stationEpoch,
                                         horizontalAccuracyMeters: .infinity, altitudeMeters: -.infinity)
    try survey.updateGPS(stationID: id, sample: malformed, receivedAt: stationEpoch)
    try survey.finishGPS(stationID: id, at: stationEpoch.addingTimeInterval(10))
    #expect(survey.stations[0].attempts[0].observations[0].rejection == "invalidCoordinate")
    let restored = try JSONDecoder().decode(StationSurvey.self, from: JSONEncoder().encode(survey))
    #expect(restored == survey)
    try restored.validate()
}
