import Foundation

public enum StationSurveyError: Error, LocalizedError, Sendable {
    case invalidDocument, capacity, missingStation, collecting, missingPosition, tooFewPoints, localGPS, historyChanged
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "Данные точечной съёмки некорректны."
        case .capacity: "Лимит точечной съёмки достигнут. Создайте отдельный проект для следующего участка."
        case .missingStation: "Станция не найдена."
        case .collecting: "Сначала завершите или отмените наблюдение."
        case .missingPosition: "У каждой включённой станции должны быть проверенные координаты."
        case .tooFewPoints: "Для линии нужны две точки, для границы — три."
        case .localGPS: "GPS записывается в WGS84. Локальные метры требуют отдельной геопривязки."
        case .historyChanged: "Исходные наблюдения и предыдущие измерения нельзя переписать."
        }
    }
}

public enum StationAttemptSource: String, Codable, Hashable, Sendable { case phoneGPS, manual }
public enum StationAttemptState: String, Codable, Hashable, Sendable { case collecting, accepted, insufficient, cancelled }

public struct StationRawObservation: Codable, Hashable, Sendable {
    public let sample: CemeterySurveySample
    public let receivedAt: Date
    public let rejection: String?
    public var accepted: Bool { rejection == nil }
}

/// The chosen GPS position is an actual observation, never a mean with a
/// manufactured smaller accuracy. Scatter and device accuracy are independent.
public struct StationSurveyAttempt: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let source: StationAttemptSource
    public let startedAt: Date
    public private(set) var finishedAt: Date?
    public private(set) var state: StationAttemptState
    public private(set) var observations: [StationRawObservation]
    public private(set) var position: FeatureGeometry?
    public let reason: String
    public var acceptedObservations: [StationRawObservation] { observations.filter(\.accepted) }
    public var chosenObservation: StationRawObservation? {
        acceptedObservations.min {
            let a = $0.sample.horizontalAccuracyMeters, b = $1.sample.horizontalAccuracyMeters
            return a == b ? $0.sample.capturedAt > $1.sample.capturedAt : a < b
        }
    }
    public var reportedAccuracyMeters: Double? { chosenObservation?.sample.horizontalAccuracyMeters }
    public var spreadMeters: Double? {
        guard let chosen = chosenObservation else { return nil }
        return try? acceptedObservations.reduce(0) {
            max($0, try GeographicMetricGeometry.distance(from: chosen.sample.coordinate, to: $1.sample.coordinate))
        }
    }
    public static let durationSeconds = 10.0
    public static let maximumObservations = 120
    public static let minimumAccepted = 3

    fileprivate init(source: StationAttemptSource, at: Date, position: FeatureGeometry? = nil, reason: String = "") {
        id = UUID(); self.source = source; startedAt = at; self.position = position; self.reason = reason
        observations = []; state = source == .manual ? .accepted : .collecting
        finishedAt = source == .manual ? at : nil
    }
    public mutating func record(_ sample: CemeterySurveySample, receivedAt: Date) throws {
        guard state == .collecting, source == .phoneGPS else { throw StationSurveyError.collecting }
        guard observations.count < Self.maximumObservations else { throw StationSurveyError.capacity }
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite,
              receivedAt >= startedAt, receivedAt >= (observations.last?.receivedAt ?? startedAt) else { throw StationSurveyError.invalidDocument }
        let rejection = Self.rejection(sample, receivedAt: receivedAt, startedAt: startedAt, previous: observations)
        observations.append(StationRawObservation(sample: sample, receivedAt: receivedAt, rejection: rejection))
    }
    private static func rejection(_ sample: CemeterySurveySample, receivedAt: Date, startedAt: Date,
                                  previous: [StationRawObservation]) -> String? {
        guard sample.capturedAt.timeIntervalSinceReferenceDate.isFinite else { return "invalidTime" }
        if previous.contains(where: { $0.sample.id == sample.id || $0.sample.capturedAt == sample.capturedAt }) { return "duplicateFix" }
        if sample.capturedAt < startedAt { return "beforeStart" }
        let age = receivedAt.timeIntervalSince(sample.capturedAt)
        if age < -1 { return "future" }
        if age > 3 { return "stale" }
        if receivedAt.timeIntervalSince(startedAt) > Self.durationSeconds { return "outsideWindow" }
        if sample.isSimulated { return "simulated" }
        if (try? PolygonGeometry.validate(sample.coordinate)) == nil { return "invalidCoordinate" }
        if !sample.horizontalAccuracyMeters.isFinite || sample.horizontalAccuracyMeters < 0 { return "invalidAccuracy" }
        if sample.horizontalAccuracyMeters > 25 { return "poorAccuracy" }
        if let last = previous.last(where: \.accepted), sample.capturedAt <= last.sample.capturedAt { return "outOfOrder" }
        return nil
    }
    public mutating func finish(at: Date, cancelled: Bool = false) throws {
        guard state == .collecting, at >= (observations.last?.receivedAt ?? startedAt), at.timeIntervalSinceReferenceDate.isFinite else {
            throw StationSurveyError.invalidDocument
        }
        finishedAt = at
        if cancelled { state = .cancelled; return }
        guard at.timeIntervalSince(startedAt) >= Self.durationSeconds,
              acceptedObservations.count >= Self.minimumAccepted, let chosen = chosenObservation else {
            state = .insufficient; return
        }
        position = .geographicPoint(chosen.sample.coordinate); state = .accepted
    }
    public func validate(in reference: CoordinateReference) throws {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite, reason.utf16.count <= 1_024 else { throw StationSurveyError.invalidDocument }
        if source == .manual {
            guard state == .accepted, observations.isEmpty, finishedAt == startedAt,
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let position else { throw StationSurveyError.invalidDocument }
            try Self.validatePoint(position, in: reference)
        } else {
            guard reference == .wgs84, observations.count <= Self.maximumObservations else { throw StationSurveyError.localGPS }
            var replay = StationSurveyAttempt(source: .phoneGPS, at: startedAt)
            for raw in observations {
                try replay.record(raw.sample, receivedAt: raw.receivedAt)
                guard replay.observations.last?.rejection == raw.rejection else { throw StationSurveyError.invalidDocument }
            }
            if let finishedAt { try replay.finish(at: finishedAt, cancelled: state == .cancelled) }
            guard replay.state == state, replay.position == position else { throw StationSurveyError.invalidDocument }
        }
    }
    fileprivate static func validatePoint(_ geometry: FeatureGeometry, in reference: CoordinateReference) throws {
        switch geometry { case .metricPoint, .geographicPoint: break; default: throw StationSurveyError.invalidDocument }
        try PolygonGeometry.validate(geometry, in: reference)
    }
}

public struct SurveyStation: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let number: Int
    public fileprivate(set) var attempts: [StationSurveyAttempt]
    public var included: Bool
    public var label: String { String(format: "A%03d", number) }
    public var current: StationSurveyAttempt? { attempts.last(where: { $0.state == .accepted }) }
    public var position: FeatureGeometry? { current?.position }
    fileprivate init(number: Int) { id = UUID(); self.number = number; attempts = []; included = true }
}

public struct StationSurvey: Codable, Hashable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let timestampEncoding: String
    public let id: UUID
    public let projectID: UUID
    public let coordinateReference: CoordinateReference
    public let createdAt: Date
    public private(set) var stations: [SurveyStation]
    public var revision: Int64
    public init(projectID: UUID, coordinateReference: CoordinateReference, at: Date = Date()) {
        schemaVersion = 1; timestampEncoding = "secondsSince2001UTC"; id = UUID(); self.projectID = projectID; self.coordinateReference = coordinateReference
        createdAt = at; stations = []; revision = 0
    }
    @discardableResult public mutating func addStation() throws -> UUID {
        guard stations.count < 100 else { throw StationSurveyError.capacity }
        let station = SurveyStation(number: stations.count + 1); stations.append(station); return station.id
    }
    @discardableResult public mutating func beginGPS(stationID: UUID, at: Date = Date()) throws -> UUID {
        guard coordinateReference == .wgs84 else { throw StationSurveyError.localGPS }
        guard !stations.contains(where: { $0.attempts.last?.state == .collecting }) else { throw StationSurveyError.collecting }
        guard let index = stations.firstIndex(where: { $0.id == stationID }) else { throw StationSurveyError.missingStation }
        guard stations[index].attempts.count < 40 else { throw StationSurveyError.capacity }
        let attempt = StationSurveyAttempt(source: .phoneGPS, at: at); stations[index].attempts.append(attempt); return attempt.id
    }
    public mutating func updateGPS(stationID: UUID, sample: CemeterySurveySample, receivedAt: Date) throws {
        guard let index = stations.firstIndex(where: { $0.id == stationID }), let last = stations[index].attempts.indices.last else { throw StationSurveyError.missingStation }
        try stations[index].attempts[last].record(sample, receivedAt: receivedAt)
    }
    public mutating func finishGPS(stationID: UUID, at: Date = Date(), cancelled: Bool = false) throws {
        guard let index = stations.firstIndex(where: { $0.id == stationID }), let last = stations[index].attempts.indices.last else { throw StationSurveyError.missingStation }
        try stations[index].attempts[last].finish(at: at, cancelled: cancelled)
    }
    public mutating func enter(stationID: UUID, position: FeatureGeometry, reason: String, at: Date = Date()) throws {
        try StationSurveyAttempt.validatePoint(position, in: coordinateReference)
        guard at.timeIntervalSinceReferenceDate.isFinite, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reason.utf16.count <= 1_024 else { throw StationSurveyError.invalidDocument }
        guard let index = stations.firstIndex(where: { $0.id == stationID }) else { throw StationSurveyError.missingStation }
        guard stations[index].attempts.last?.state != .collecting else { throw StationSurveyError.collecting }
        guard stations[index].attempts.count < 40 else { throw StationSurveyError.capacity }
        stations[index].attempts.append(StationSurveyAttempt(source: .manual, at: at, position: position, reason: reason))
    }
    public mutating func include(stationID: UUID, value: Bool) throws {
        guard let index = stations.firstIndex(where: { $0.id == stationID }) else { throw StationSurveyError.missingStation }
        stations[index].included = value
    }
    public func validate() throws {
        guard schemaVersion == 1, timestampEncoding == "secondsSince2001UTC", revision >= 0, stations.count <= 100,
              createdAt.timeIntervalSinceReferenceDate.isFinite, Set(stations.map(\.id)).count == stations.count else { throw StationSurveyError.invalidDocument }
        guard stations.filter({ $0.attempts.last?.state == .collecting }).count <= 1 else { throw StationSurveyError.invalidDocument }
        for (index, station) in stations.enumerated() {
            guard station.number == index + 1, station.attempts.count <= 40, Set(station.attempts.map(\.id)).count == station.attempts.count else { throw StationSurveyError.invalidDocument }
            for (offset, attempt) in station.attempts.enumerated() {
                guard attempt.state != .collecting || offset == station.attempts.count - 1 else { throw StationSurveyError.invalidDocument }
                try attempt.validate(in: coordinateReference)
            }
        }
    }
    public func validateTransition(from previous: StationSurvey) throws {
        try validate()
        guard id == previous.id, projectID == previous.projectID, coordinateReference == previous.coordinateReference,
              createdAt == previous.createdAt, stations.count >= previous.stations.count else { throw StationSurveyError.historyChanged }
        for (old, new) in zip(previous.stations, stations) {
            guard old.id == new.id, old.number == new.number, new.attempts.count >= old.attempts.count else { throw StationSurveyError.historyChanged }
            for (before, after) in zip(old.attempts, new.attempts) {
                if before.state != .collecting { guard before == after else { throw StationSurveyError.historyChanged } }
                else {
                    guard before.id == after.id, before.source == after.source, before.startedAt == after.startedAt,
                          before.reason == after.reason, after.observations.count >= before.observations.count,
                          Array(after.observations.prefix(before.observations.count)) == before.observations else { throw StationSurveyError.historyChanged }
                }
            }
        }
    }
}

public struct StationSurveySegment: Hashable, Sendable {
    public let from: String, to: String
    public let distanceMeters: Double
    /// Clockwise from true north; absent in an unoriented local AR frame.
    public let trueBearingDegrees: Double?
}
public struct StationSurveyOutline: Sendable {
    public let geometry: FeatureGeometry
    public let segments: [StationSurveySegment]
    public let perimeterMeters: Double
    public let areaSquareMeters: Double?
}

public enum StationSurveyGeometry {
    public static func outline(_ survey: StationSurvey, closed: Bool) throws -> StationSurveyOutline {
        try survey.validate()
        let stations = survey.stations.filter(\.included)
        guard stations.count >= (closed ? 3 : 2) else { throw StationSurveyError.tooFewPoints }
        guard stations.allSatisfy({ $0.position != nil }) else { throw StationSurveyError.missingPosition }
        let geometry: FeatureGeometry, metric: [MetricPoint2D]
        var geographic: [GeographicCoordinate] = []
        switch survey.coordinateReference {
        case let .localMeters(frame):
            metric = try stations.map { guard case let .metricPoint(_, point) = $0.position else { throw StationSurveyError.invalidDocument }; return point }
            geometry = closed ? .metricPolygon(MetricPolygon(frameID: frame, vertices: metric)) : .metricPolyline(MetricPolyline(frameID: frame, vertices: metric))
        case .wgs84:
            geographic = try stations.map { guard case let .geographicPoint(point) = $0.position else { throw StationSurveyError.invalidDocument }; return point }
            let projection = try LocalWGS84Projection(anchor: geographic[0])
            metric = try geographic.map { try projection.project($0) }
            geometry = closed ? .geographicPolygon(GeographicPolygon(vertices: geographic)) : .geographicPolyline(GeographicPolyline(vertices: geographic))
        }
        try PolygonGeometry.validate(geometry, in: survey.coordinateReference)
        let segments = try (0..<(closed ? stations.count : stations.count - 1)).map { index in
            let next = (index + 1) % stations.count, a = metric[index], b = metric[next]
            var angle: Double?
            if survey.coordinateReference == .wgs84 {
                let direction = try LocalWGS84Projection(anchor: geographic[index]).project(geographic[next])
                angle = (atan2(direction.x, direction.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            }
            return StationSurveySegment(from: stations[index].label, to: stations[next].label, distanceMeters: hypot(b.x - a.x, b.y - a.y), trueBearingDegrees: angle)
        }
        let area: Double?
        switch geometry {
        case let .metricPolygon(polygon): area = try PolygonGeometry.area(of: polygon)
        case let .geographicPolygon(polygon): area = try GeographicMetricGeometry.area(of: polygon)
        default: area = nil
        }
        return StationSurveyOutline(geometry: geometry, segments: segments, perimeterMeters: segments.reduce(0) { $0 + $1.distanceMeters }, areaSquareMeters: area)
    }
}

public enum StationSurveyExporter {
    public static func json(_ survey: StationSurvey) throws -> ExportArtifact {
        try survey.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return ExportArtifact(fileName: "station-survey-\(survey.id).json", contentType: "application/json", data: try encoder.encode(survey),
            warnings: ["Координаты GPS приблизительные. Даты исходного Swift Codable: секунды от 2001-01-01 UTC."])
    }
    public static func geoJSON(_ survey: StationSurvey) throws -> ExportArtifact {
        try survey.validate()
        guard survey.coordinateReference == .wgs84 else { throw StationSurveyError.localGPS }
        let encoder = JSONEncoder()
        var features: [[String: Any]] = []
        for station in survey.stations {
            let geometry: Any
            if case let .geographicPoint(point) = station.position {
                geometry = ["type": "Point", "coordinates": [point.longitude, point.latitude]]
            } else { geometry = NSNull() }
            let metadata = try JSONSerialization.jsonObject(with: encoder.encode(station))
            features.append(["type": "Feature", "id": station.id.uuidString,
                "geometry": geometry,
                "properties": ["label": station.label, "surveyID": survey.id.uuidString, "projectID": survey.projectID.uuidString,
                    "station": metadata, "timestampEncoding": survey.timestampEncoding, "accuracyMeaning": "deviceReportedNotImprovedByAveraging"]])
        }
        return ExportArtifact(fileName: "station-survey-\(survey.id).geojson", contentType: "application/geo+json",
            data: try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features], options: [.prettyPrinted, .sortedKeys]),
            warnings: ["GPS и наблюдаемый разброс не подтверждают геодезическую точность."])
    }
}
