import Foundation

public enum GeographicMetricError: Error, LocalizedError, Equatable, Sendable {
    case invalidProjection, projectionExtentExceeded, unsupportedGeometry
    public var errorDescription: String? {
        switch self {
        case .invalidProjection: "Параметры локального расчёта WGS84 недопустимы."
        case .projectionExtentExceeded: "Локальный расчёт ограничен радиусом 5 км. Разделите маршрут или используйте геодезический инструмент."
        case .unsupportedGeometry: "Для расстояния нужны точка и линия ограды в одной системе координат."
        }
    }
}

/// Horizontal, approximate metres on a WGS84 ellipsoid, not latitude/longitude degrees.
/// ECEF coordinates (altitude zero) are projected onto the anchor's east/north tangent plane.
/// A hard 5 km chord-radius limit bounds curvature distortion; no survey-grade accuracy is implied.
/// GPS horizontal accuracy remains an independent observation uncertainty, not projection accuracy.
public struct LocalWGS84Projection: Codable, Hashable, Sendable {
    public let anchor: GeographicCoordinate
    public let maximumRadiusMeters: Double

    public init(anchor: GeographicCoordinate, maximumRadiusMeters: Double = 5_000) throws {
        try GeographicMetricGeometry.validateCoordinate(anchor)
        guard maximumRadiusMeters.isFinite, maximumRadiusMeters > 0, maximumRadiusMeters <= 5_000 else {
            throw GeographicMetricError.invalidProjection
        }
        self.anchor = anchor; self.maximumRadiusMeters = maximumRadiusMeters
    }

    public func project(_ coordinate: GeographicCoordinate) throws -> MetricPoint2D {
        try GeographicMetricGeometry.validateCoordinate(anchor)
        try GeographicMetricGeometry.validateCoordinate(coordinate)
        guard maximumRadiusMeters.isFinite, maximumRadiusMeters > 0, maximumRadiusMeters <= 5_000 else {
            throw GeographicMetricError.invalidProjection
        }
        let a = Self.ecef(anchor), b = Self.ecef(coordinate)
        let dx = b.0 - a.0, dy = b.1 - a.1, dz = b.2 - a.2
        guard sqrt(dx * dx + dy * dy + dz * dz) <= maximumRadiusMeters else {
            throw GeographicMetricError.projectionExtentExceeded
        }
        let longitude = anchor.longitude * .pi / 180, latitude = anchor.latitude * .pi / 180
        return MetricPoint2D(x: -sin(longitude) * dx + cos(longitude) * dy,
                             y: -sin(latitude) * cos(longitude) * dx - sin(latitude) * sin(longitude) * dy + cos(latitude) * dz)
    }

    private static func ecef(_ coordinate: GeographicCoordinate) -> (Double, Double, Double) {
        let latitude = coordinate.latitude * .pi / 180, longitude = coordinate.longitude * .pi / 180
        let eccentricitySquared = 6.6943799901413165e-3 // WGS84: a=6378137 m; f=1/298.257223563.
        let normal = 6_378_137 / sqrt(1 - eccentricitySquared * sin(latitude) * sin(latitude))
        return (normal * cos(latitude) * cos(longitude), normal * cos(latitude) * sin(longitude),
                normal * (1 - eccentricitySquared) * sin(latitude))
    }
}

public enum GeographicMetricGeometry {
    public static func validateCoordinate(_ point: GeographicCoordinate) throws {
        guard point.longitude.isFinite, point.latitude.isFinite else { throw GeometryError.nonFiniteCoordinate }
        guard (-180...180).contains(point.longitude), (-90...90).contains(point.latitude) else {
            throw GeometryError.geographicCoordinateOutOfRange
        }
    }

    public static func distance(from a: GeographicCoordinate, to b: GeographicCoordinate) throws -> Double {
        let projection = try LocalWGS84Projection(anchor: a)
        let point = try projection.project(b)
        return hypot(point.x, point.y)
    }

    public static func length(of line: GeographicPolyline) throws -> Double {
        try PolygonGeometry.validate(.geographicPolyline(line), in: .wgs84)
        let projection = try LocalWGS84Projection(anchor: line.vertices[0])
        return try pathLength(line.vertices.map { try projection.project($0) }, closed: false)
    }

    public static func area(of polygon: GeographicPolygon) throws -> Double {
        try PolygonGeometry.area(of: projected(polygon))
    }

    public static func perimeter(of polygon: GeographicPolygon) throws -> Double {
        try PolygonGeometry.perimeter(of: projected(polygon))
    }

    /// Only an actual WGS84 point/line pair or two metric geometries with the SAME frame is accepted.
    /// An AR point with a geotag is not an aligned geographic point.
    public static func nearestDistance(point: FeatureGeometry, toFence fence: FeatureGeometry) throws -> Double {
        guard point.coordinateReference == fence.coordinateReference else { throw GeometryError.coordinateFrameMismatch }
        try PolygonGeometry.validate(point, in: point.coordinateReference)
        try PolygonGeometry.validate(fence, in: fence.coordinateReference)
        switch (point, fence) {
        case let (.metricPoint(_, point), .metricPolyline(line)):
            return nearest(point, on: line.vertices)
        case let (.geographicPoint(point), .geographicPolyline(line)):
            let projection = try LocalWGS84Projection(anchor: point)
            return try nearest(MetricPoint2D(x: 0, y: 0), on: line.vertices.map { try projection.project($0) })
        default: throw GeographicMetricError.unsupportedGeometry
        }
    }

    private static func projected(_ polygon: GeographicPolygon) throws -> MetricPolygon {
        try PolygonGeometry.validate(polygon)
        let projection = try LocalWGS84Projection(anchor: polygon.vertices[0])
        return try MetricPolygon(frameID: UUID(), vertices: polygon.vertices.map { try projection.project($0) },
                                 holes: polygon.holes.map { try $0.map { try projection.project($0) } })
    }

    fileprivate static func pathLength(_ points: [MetricPoint2D], closed: Bool) -> Double {
        guard points.count > 1 else { return 0 }
        var result = (1..<points.count).reduce(0.0) { $0 + hypot(points[$1].x - points[$1 - 1].x, points[$1].y - points[$1 - 1].y) }
        if closed { result += hypot(points[0].x - points[points.count - 1].x, points[0].y - points[points.count - 1].y) }
        return result
    }

    fileprivate static func nearest(_ point: MetricPoint2D, on line: [MetricPoint2D]) -> Double {
        (1..<line.count).reduce(Double.infinity) { result, index in
            min(result, pointSegmentDistance(point, line[index - 1], line[index]))
        }
    }

    fileprivate static func pointSegmentDistance(_ p: MetricPoint2D, _ a: MetricPoint2D, _ b: MetricPoint2D) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, squared = dx * dx + dy * dy
        let fraction = squared > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared)) : 0
        return hypot(p.x - a.x - fraction * dx, p.y - a.y - fraction * dy)
    }
}

public struct CemeterySurveySample: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let coordinate: GeographicCoordinate
    public let capturedAt: Date
    public let horizontalAccuracyMeters: Double
    public let altitudeMeters: Double?
    public let isSimulated: Bool
    public init(id: UUID = UUID(), coordinate: GeographicCoordinate, capturedAt: Date,
                horizontalAccuracyMeters: Double, altitudeMeters: Double? = nil, isSimulated: Bool = false) {
        self.id = id; self.coordinate = coordinate; self.capturedAt = capturedAt
        self.horizontalAccuracyMeters = horizontalAccuracyMeters; self.altitudeMeters = altitudeMeters
        self.isSimulated = isSimulated
    }

    // Malformed CLLocation values are still rejected WITH their raw provenance. JSON represents
    // non-finite numeric observations explicitly as strings instead of dropping them or crashing.
    private enum CodingKeys: String, CodingKey { case id, coordinate, capturedAt, horizontalAccuracyMeters, altitudeMeters, isSimulated }
    private enum CoordinateKeys: String, CodingKey { case longitude, latitude }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(isSimulated, forKey: .isSimulated)
        var coordinates = container.nestedContainer(keyedBy: CoordinateKeys.self, forKey: .coordinate)
        try Self.encode(coordinate.longitude, in: &coordinates, key: .longitude)
        try Self.encode(coordinate.latitude, in: &coordinates, key: .latitude)
        try Self.encode(horizontalAccuracyMeters, in: &container, key: .horizontalAccuracyMeters)
        if let altitudeMeters { try Self.encode(altitudeMeters, in: &container, key: .altitudeMeters) }
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let coordinates = try container.nestedContainer(keyedBy: CoordinateKeys.self, forKey: .coordinate)
        let altitude: Double?
        if container.contains(.altitudeMeters), try !container.decodeNil(forKey: .altitudeMeters) {
            altitude = try Self.decode(from: container, key: .altitudeMeters)
        } else { altitude = nil }
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  coordinate: GeographicCoordinate(longitude: try Self.decode(from: coordinates, key: .longitude),
                                                   latitude: try Self.decode(from: coordinates, key: .latitude)),
                  capturedAt: try container.decode(Date.self, forKey: .capturedAt),
                  horizontalAccuracyMeters: try Self.decode(from: container, key: .horizontalAccuracyMeters),
                  altitudeMeters: altitude,
                  isSimulated: try container.decode(Bool.self, forKey: .isSimulated))
    }
    private static func encode<Key: CodingKey>(_ value: Double, in container: inout KeyedEncodingContainer<Key>, key: Key) throws {
        if value.isFinite { try container.encode(value, forKey: key) }
        else { try container.encode(value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity"), forKey: key) }
    }
    private static func decode<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, key: Key) throws -> Double {
        if let number = try? container.decode(Double.self, forKey: key) { return number }
        switch try container.decode(String.self, forKey: key) {
        case "NaN": return .nan
        case "Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: throw CemeterySurveyError.invalidCheckpoint
        }
    }
    public static func == (a: Self, b: Self) -> Bool {
        func equal(_ a: Double, _ b: Double) -> Bool { a == b || (a.isNaN && b.isNaN) }
        return a.id == b.id && a.capturedAt == b.capturedAt && a.isSimulated == b.isSimulated
            && equal(a.coordinate.longitude, b.coordinate.longitude) && equal(a.coordinate.latitude, b.coordinate.latitude)
            && equal(a.horizontalAccuracyMeters, b.horizontalAccuracyMeters)
            && ((a.altitudeMeters == nil && b.altitudeMeters == nil)
                || (a.altitudeMeters != nil && b.altitudeMeters != nil && equal(a.altitudeMeters!, b.altitudeMeters!)))
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(capturedAt); hasher.combine(isSimulated)
        for value in [coordinate.longitude, coordinate.latitude, horizontalAccuracyMeters] {
            if value.isNaN { hasher.combine("NaN") } else { hasher.combine(value) }
        }
        if let altitudeMeters {
            hasher.combine(true)
            if altitudeMeters.isNaN { hasher.combine("NaN") } else { hasher.combine(altitudeMeters) }
        } else { hasher.combine(false) }
    }
}

public struct CemeterySurveyPolicy: Codable, Hashable, Sendable {
    public let maximumAccuracyMeters: Double
    public let maximumAgeSeconds: Double
    public let maximumFutureSeconds: Double
    public let maximumGapSeconds: Double
    public let maximumStepMeters: Double
    public let maximumSpeedMetersPerSecond: Double
    public let maximumClosureAccuracyMeters: Double
    public let maximumClosureGapMeters: Double
    public let minimumClosureToleranceMeters: Double
    public let maximumSimplificationToleranceMeters: Double
    public let maximumJournalEntries: Int
    public let maximumBoundaryVertices: Int
    public let allowSimulatedSamples: Bool
    public init(maximumAccuracyMeters: Double = 10, maximumAgeSeconds: Double = 5,
                maximumFutureSeconds: Double = 1, maximumGapSeconds: Double = 10,
                maximumStepMeters: Double = 30, maximumSpeedMetersPerSecond: Double = 5,
                maximumClosureAccuracyMeters: Double = 3, maximumClosureGapMeters: Double = 5,
                minimumClosureToleranceMeters: Double = 0.75, maximumSimplificationToleranceMeters: Double = 1,
                maximumJournalEntries: Int = 10_000, maximumBoundaryVertices: Int = 2_048,
                allowSimulatedSamples: Bool = false) {
        self.maximumAccuracyMeters = maximumAccuracyMeters; self.maximumAgeSeconds = maximumAgeSeconds
        self.maximumFutureSeconds = maximumFutureSeconds; self.maximumGapSeconds = maximumGapSeconds
        self.maximumStepMeters = maximumStepMeters; self.maximumSpeedMetersPerSecond = maximumSpeedMetersPerSecond
        self.maximumClosureAccuracyMeters = maximumClosureAccuracyMeters; self.maximumClosureGapMeters = maximumClosureGapMeters
        self.minimumClosureToleranceMeters = minimumClosureToleranceMeters
        self.maximumSimplificationToleranceMeters = maximumSimplificationToleranceMeters
        self.maximumJournalEntries = maximumJournalEntries; self.maximumBoundaryVertices = maximumBoundaryVertices
        self.allowSimulatedSamples = allowSimulatedSamples
    }

    fileprivate func validate() throws {
        let positive = [maximumAccuracyMeters, maximumAgeSeconds, maximumGapSeconds, maximumStepMeters,
                        maximumSpeedMetersPerSecond, maximumClosureAccuracyMeters, maximumClosureGapMeters,
                        minimumClosureToleranceMeters]
        guard positive.allSatisfy({ $0.isFinite && $0 > 0 }), maximumFutureSeconds.isFinite, maximumFutureSeconds >= 0,
              maximumSimplificationToleranceMeters.isFinite, (0...1).contains(maximumSimplificationToleranceMeters),
              maximumAccuracyMeters <= 50, maximumAgeSeconds <= 60, maximumFutureSeconds <= 5, maximumGapSeconds <= 60,
              maximumStepMeters <= 100, maximumSpeedMetersPerSecond <= 10,
              maximumClosureAccuracyMeters <= 5, maximumClosureAccuracyMeters <= maximumAccuracyMeters,
              maximumClosureGapMeters <= 5, minimumClosureToleranceMeters <= maximumClosureGapMeters,
              (8...20_000).contains(maximumJournalEntries), (3...2_048).contains(maximumBoundaryVertices) else {
            throw CemeterySurveyError.invalidPolicy
        }
    }
}

public enum CemeterySurveyError: Error, LocalizedError, Equatable, Sendable {
    case invalidPolicy, invalidTimestamp, invalidState, capacityReached, duplicateSampleID, invalidCheckpoint
    case segmentNotFound, tooFewSamples, tooManyBoundaryVertices, closureAccuracyInsufficient
    case closureGapTooLarge, invalidSimplificationTolerance
    public var errorDescription: String? {
        switch self {
        case .invalidPolicy: "Параметры GPS-съёмки недопустимы."
        case .invalidTimestamp: "Время GPS-съёмки недопустимо."
        case .invalidState: "Сначала проверьте состояние GPS-съёмки."
        case .capacityReached: "Журнал GPS заполнен. Завершите съёмку и сохраните текущие материалы."
        case .duplicateSampleID: "Эта GPS-точка уже записана в журнал."
        case .invalidCheckpoint: "GPS-черновик повреждён или его решения не соответствуют исходным наблюдениям."
        case .segmentNotFound: "Непрерывный участок маршрута не найден."
        case .tooFewSamples: "Для контура нужно не менее трёх различных точек и возвращение к началу."
        case .tooManyBoundaryVertices: "В контуре слишком много точек. Разделите маршрут или явно примените упрощение."
        case .closureAccuracyInsufficient: "У начала или конца контура слишком низкая точность GPS. Уточните положение перед замыканием."
        case .closureGapTooLarge: "Вернитесь ближе к началу контура. Пробел автоматически не соединяется."
        case .invalidSimplificationTolerance: "Допуск упрощения должен быть от 0 до 1 метра в пределах настроенного ограничения."
        }
    }
}

public enum CemeterySurveyRejection: String, Codable, Hashable, Sendable {
    case invalidCoordinate, invalidAccuracy, invalidAltitude, stale, future, outOfOrder, insufficientAccuracy
    case simulated, paused, stopped, jump
}
public enum CemeterySurveyState: String, Codable, Hashable, Sendable { case recording, paused, stopped }
public enum CemeterySurveyAcceptance: String, Codable, Hashable, Sendable { case accepted, rejected }
public enum CemeterySurveyBreak: String, Codable, Hashable, Sendable { case started, resumed, timeGap, rejectedObservation }

public struct CemeterySurveyDecision: Codable, Hashable, Sendable {
    public let sampleID: UUID
    public let status: CemeterySurveyAcceptance
    public let rejectionReason: CemeterySurveyRejection?
    public let segmentID: UUID?
    public let startsNewSegment: Bool
    public let breakReason: CemeterySurveyBreak?
}
public struct CemeterySurveyObservation: Codable, Hashable, Sendable {
    public let sample: CemeterySurveySample
    public let receivedAt: Date
    public let decision: CemeterySurveyDecision
}
public struct CemeterySurveySegment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let startReason: CemeterySurveyBreak
    public let samples: [CemeterySurveySample]
}
public struct CemeterySurveyBoundary: Codable, Hashable, Sendable {
    public let polygon: GeographicPolygon
    public let sourceSegmentID: UUID
    /// All accepted raw observations, including the closing observation removed from the ring.
    public let sourceSampleIDs: [UUID]
    /// Subset retained in the polygon; raw observations are never deleted by simplification.
    public let vertexSampleIDs: [UUID]
    public let confirmedAt: Date
    public let closureDistanceMeters: Double
    public let closureToleranceMeters: Double
    public let maximumHorizontalAccuracyMeters: Double
    public let simplificationToleranceMeters: Double
    public let areaMetersSquared: Double
    public let perimeterMeters: Double
}
public enum CemeterySurveyJournalEntry: Codable, Hashable, Sendable {
    case observation(CemeterySurveyObservation)
    case paused(Date), resumed(Date), stopped(Date)
    case boundaryConfirmed(CemeterySurveyBoundary)
}

/// An offline value-type journal. A gap, pause, or rejected observation creates a new segment;
/// no route or polygon combines those segments implicitly. Reaching the bound throws before mutation.
/// Codable checkpoints re-run filtering and geometry validation, rather than trusting saved decisions.
public struct CemeterySurveySession: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let policy: CemeterySurveyPolicy
    public let startedAt: Date
    public private(set) var journal: [CemeterySurveyJournalEntry]
    public private(set) var state: CemeterySurveyState
    private var activeSegmentID: UUID?
    private var lastAccepted: CemeterySurveySample?
    private var nextBreak: CemeterySurveyBreak
    private var sampleIDs: Set<UUID>
    private var segmentIDs: Set<UUID>

    public init(id: UUID = UUID(), policy: CemeterySurveyPolicy = CemeterySurveyPolicy(), startedAt: Date = Date()) throws {
        try policy.validate()
        guard startedAt.timeIntervalSinceReferenceDate.isFinite else { throw CemeterySurveyError.invalidTimestamp }
        self.id = id; self.policy = policy; self.startedAt = startedAt; journal = []; state = .recording
        activeSegmentID = nil; lastAccepted = nil; nextBreak = .started; sampleIDs = []; segmentIDs = []
    }

    public var observations: [CemeterySurveyObservation] {
        journal.compactMap { if case let .observation(value) = $0 { value } else { nil } }
    }
    public var segments: [CemeterySurveySegment] {
        var order: [UUID] = [], samples: [UUID: [CemeterySurveySample]] = [:], reasons: [UUID: CemeterySurveyBreak] = [:]
        for observation in observations where observation.decision.status == .accepted {
            guard let segmentID = observation.decision.segmentID else { continue }
            if samples[segmentID] == nil { order.append(segmentID); reasons[segmentID] = observation.decision.breakReason ?? .started }
            samples[segmentID, default: []].append(observation.sample)
        }
        return order.map { CemeterySurveySegment(id: $0, startReason: reasons[$0] ?? .started, samples: samples[$0] ?? []) }
    }
    public var confirmations: [CemeterySurveyBoundary] {
        journal.compactMap { if case let .boundaryConfirmed(value) = $0 { value } else { nil } }
    }

    /// Foreground recording time only. Pauses and the interval after stop are excluded.
    public func activeDuration(at: Date = Date()) throws -> TimeInterval {
        guard at.timeIntervalSinceReferenceDate.isFinite, at >= startedAt else { throw CemeterySurveyError.invalidTimestamp }
        var activeStart: Date? = startedAt, duration: TimeInterval = 0
        for entry in journal {
            switch entry {
            case let .paused(time), let .stopped(time):
                guard time <= at else { throw CemeterySurveyError.invalidTimestamp }
                if let start = activeStart { duration += time.timeIntervalSince(start) }; activeStart = nil
            case let .resumed(time):
                guard time <= at else { throw CemeterySurveyError.invalidTimestamp }
                activeStart = time
            case .observation, .boundaryConfirmed: break
            }
        }
        if let start = activeStart { duration += at.timeIntervalSince(start) }
        return duration
    }

    @discardableResult public mutating func record(_ sample: CemeterySurveySample, receivedAt: Date = Date()) throws -> CemeterySurveyDecision {
        try record(sample, receivedAt: receivedAt, preferredSegmentID: nil)
    }

    public mutating func pause(at: Date = Date()) throws {
        guard state == .recording else { throw CemeterySurveyError.invalidState }
        try reserve(at: at); journal.append(.paused(at)); state = .paused; activeSegmentID = nil; nextBreak = .resumed
    }
    public mutating func resume(at: Date = Date()) throws {
        guard state == .paused else { throw CemeterySurveyError.invalidState }
        try reserve(at: at); journal.append(.resumed(at)); state = .recording; activeSegmentID = nil; nextBreak = .resumed
    }
    public mutating func stop(at: Date = Date()) throws {
        guard state != .stopped else { throw CemeterySurveyError.invalidState }
        try reserve(at: at, terminal: true); journal.append(.stopped(at)); state = .stopped; activeSegmentID = nil
    }

    public func makePolyline(segmentID: UUID) throws -> GeographicPolyline {
        guard let segment = segments.first(where: { $0.id == segmentID }) else { throw CemeterySurveyError.segmentNotFound }
        var vertices: [GeographicCoordinate] = []
        for sample in segment.samples where vertices.last != sample.coordinate { vertices.append(sample.coordinate) }
        let line = GeographicPolyline(vertices: vertices)
        try PolygonGeometry.validate(.geographicPolyline(line), in: .wgs84)
        return line
    }

    /// The caller must explicitly request confirmation. Endpoint uncertainty is combined by hypot,
    /// but the tolerance never exceeds 5 m and both endpoints must individually meet closure accuracy.
    /// The last observation establishes return-to-start and is omitted from the unclosed stored ring.
    @discardableResult public mutating func confirmBoundary(segmentID: UUID, at: Date = Date(),
                                                            simplificationToleranceMeters: Double = 0) throws -> CemeterySurveyBoundary {
        try reserve(at: at)
        guard simplificationToleranceMeters.isFinite,
              (0...policy.maximumSimplificationToleranceMeters).contains(simplificationToleranceMeters) else {
            throw CemeterySurveyError.invalidSimplificationTolerance
        }
        guard let segment = segments.first(where: { $0.id == segmentID }) else { throw CemeterySurveyError.segmentNotFound }
        guard segment.samples.count >= 4, let first = segment.samples.first, let last = segment.samples.last else {
            throw CemeterySurveyError.tooFewSamples
        }
        guard first.horizontalAccuracyMeters <= policy.maximumClosureAccuracyMeters,
              last.horizontalAccuracyMeters <= policy.maximumClosureAccuracyMeters else {
            throw CemeterySurveyError.closureAccuracyInsufficient
        }
        let gap = try GeographicMetricGeometry.distance(from: first.coordinate, to: last.coordinate)
        let tolerance = min(policy.maximumClosureGapMeters,
                            max(policy.minimumClosureToleranceMeters, hypot(first.horizontalAccuracyMeters, last.horizontalAccuracyMeters)))
        guard gap <= tolerance else { throw CemeterySurveyError.closureGapTooLarge }
        let projection = try LocalWGS84Projection(anchor: first.coordinate)
        let rawRing = Array(segment.samples.dropLast())
        // Standing still may yield several timestamped fixes at exactly the same coordinate.
        // Collapse only consecutive duplicates (and the redundant final closing coordinate).
        // A repeated interior coordinate remains a topology error. Every observation stays raw.
        var source: [CemeterySurveySample] = []
        for sample in rawRing where source.last?.coordinate != sample.coordinate { source.append(sample) }
        if source.count > 1, source.last?.coordinate == source.first?.coordinate { source.removeLast() }
        let projected = try source.map { try projection.project($0.coordinate) }
        guard projected.count <= 20_000 else { throw CemeterySurveyError.tooManyBoundaryVertices }
        // Validate the original ring before simplifying: a tolerance cannot conceal a crossing.
        guard projected.count <= policy.maximumBoundaryVertices else { throw CemeterySurveyError.tooManyBoundaryVertices }
        try PolygonGeometry.validate(MetricPolygon(frameID: id, vertices: projected))
        let indices = Self.simplifiedIndices(projected, tolerance: simplificationToleranceMeters)
        let polygon = GeographicPolygon(vertices: indices.map { source[$0].coordinate })
        try PolygonGeometry.validate(polygon)
        let boundary = try CemeterySurveyBoundary(polygon: polygon, sourceSegmentID: segmentID,
                                                  sourceSampleIDs: segment.samples.map(\.id), vertexSampleIDs: indices.map { source[$0].id },
                                                  confirmedAt: at, closureDistanceMeters: gap, closureToleranceMeters: tolerance,
                                                  maximumHorizontalAccuracyMeters: segment.samples.map(\.horizontalAccuracyMeters).max() ?? 0,
                                                  simplificationToleranceMeters: simplificationToleranceMeters,
                                                  areaMetersSquared: GeographicMetricGeometry.area(of: polygon),
                                                  perimeterMeters: GeographicMetricGeometry.perimeter(of: polygon))
        journal.append(.boundaryConfirmed(boundary)); return boundary
    }

    public func validateCheckpoint() throws {
        guard try Self.replay(id: id, policy: policy, startedAt: startedAt, journal: journal) == self else {
            throw CemeterySurveyError.invalidCheckpoint
        }
    }

    private mutating func record(_ sample: CemeterySurveySample, receivedAt: Date, preferredSegmentID: UUID?) throws -> CemeterySurveyDecision {
        // Keep one journal slot available for the terminal stop marker.
        guard journal.count < policy.maximumJournalEntries - 1 else { throw CemeterySurveyError.capacityReached }
        try reserve(at: receivedAt)
        guard sample.capturedAt.timeIntervalSinceReferenceDate.isFinite else { throw CemeterySurveyError.invalidTimestamp }
        guard !sampleIDs.contains(sample.id) else { throw CemeterySurveyError.duplicateSampleID }
        let rejection = try rejection(for: sample, receivedAt: receivedAt)
        let decision: CemeterySurveyDecision
        if let rejection {
            decision = CemeterySurveyDecision(sampleID: sample.id, status: .rejected, rejectionReason: rejection,
                                               segmentID: nil, startsNewSegment: false, breakReason: nil)
            if state == .recording { activeSegmentID = nil; nextBreak = .rejectedObservation }
        } else {
            if let previous = lastAccepted, activeSegmentID != nil,
               sample.capturedAt.timeIntervalSince(previous.capturedAt) > policy.maximumGapSeconds {
                activeSegmentID = nil; nextBreak = .timeGap
            }
            let starts = activeSegmentID == nil
            if starts {
                let nextID = preferredSegmentID ?? UUID()
                guard !segmentIDs.contains(nextID) else { throw CemeterySurveyError.invalidCheckpoint }
                activeSegmentID = nextID; segmentIDs.insert(nextID)
            }
            decision = CemeterySurveyDecision(sampleID: sample.id, status: .accepted, rejectionReason: nil,
                                               segmentID: activeSegmentID, startsNewSegment: starts, breakReason: starts ? nextBreak : nil)
            lastAccepted = sample
        }
        sampleIDs.insert(sample.id)
        journal.append(.observation(CemeterySurveyObservation(sample: sample, receivedAt: receivedAt, decision: decision)))
        return decision
    }

    private func rejection(for sample: CemeterySurveySample, receivedAt: Date) throws -> CemeterySurveyRejection? {
        if state == .paused { return .paused }; if state == .stopped { return .stopped }
        if (try? GeographicMetricGeometry.validateCoordinate(sample.coordinate)) == nil { return .invalidCoordinate }
        if !sample.horizontalAccuracyMeters.isFinite || sample.horizontalAccuracyMeters < 0 { return .invalidAccuracy }
        if let altitude = sample.altitudeMeters, !altitude.isFinite { return .invalidAltitude }
        if sample.isSimulated && !policy.allowSimulatedSamples { return .simulated }
        let age = receivedAt.timeIntervalSince(sample.capturedAt)
        if age > policy.maximumAgeSeconds { return .stale }
        if age < -policy.maximumFutureSeconds { return .future }
        if sample.horizontalAccuracyMeters > policy.maximumAccuracyMeters { return .insufficientAccuracy }
        if let previous = lastAccepted {
            let interval = sample.capturedAt.timeIntervalSince(previous.capturedAt)
            if interval <= 0 { return .outOfOrder }
            if activeSegmentID != nil || nextBreak == .rejectedObservation, interval <= policy.maximumGapSeconds {
                guard let distance = try? GeographicMetricGeometry.distance(from: previous.coordinate, to: sample.coordinate) else { return .jump }
                let errorAllowance = hypot(previous.horizontalAccuracyMeters, sample.horizontalAccuracyMeters)
                if distance > policy.maximumStepMeters || max(0, distance - errorAllowance) > policy.maximumSpeedMetersPerSecond * interval {
                    return .jump
                }
            }
        }
        return nil
    }

    private func reserve(at: Date, terminal: Bool = false) throws {
        guard journal.count < policy.maximumJournalEntries - (terminal ? 0 : 1) else { throw CemeterySurveyError.capacityReached }
        guard at.timeIntervalSinceReferenceDate.isFinite, at >= startedAt else { throw CemeterySurveyError.invalidTimestamp }
        let latest: Date? = journal.last.map {
            switch $0 {
            case let .observation(observation): observation.receivedAt
            case let .paused(time), let .resumed(time), let .stopped(time): time
            case let .boundaryConfirmed(boundary): boundary.confirmedAt
            }
        }
        if let latest, at < latest { throw CemeterySurveyError.invalidTimestamp }
    }

    /// Conservative iterative RDP retains original observations. Both resulting topology and metrics
    /// are validated. A zero tolerance performs no simplification, and no raw provenance is removed.
    private static func simplifiedIndices(_ points: [MetricPoint2D], tolerance: Double) -> [Int] {
        guard tolerance > 0, points.count > 3 else { return Array(points.indices) }
        var retained: Set<Int> = [0, points.count - 1], pending = [(0, points.count - 1)]
        while let (start, end) = pending.popLast() {
            guard end > start + 1 else { continue }
            var maximum = tolerance, chosen: Int?
            for index in (start + 1)..<end {
                let distance = GeographicMetricGeometry.pointSegmentDistance(points[index], points[start], points[end])
                if distance > maximum { maximum = distance; chosen = index }
            }
            if let index = chosen { retained.insert(index); pending.append((start, index)); pending.append((index, end)) }
        }
        let result = retained.sorted()
        return result.count >= 3 ? result : Array(points.indices)
    }

    private enum CodingKeys: String, CodingKey { case id, policy, startedAt, journal }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(policy, forKey: .policy)
        try container.encode(startedAt, forKey: .startedAt); try container.encode(journal, forKey: .journal)
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self.replay(id: container.decode(UUID.self, forKey: .id),
                               policy: container.decode(CemeterySurveyPolicy.self, forKey: .policy),
                               startedAt: container.decode(Date.self, forKey: .startedAt),
                               journal: container.decode([CemeterySurveyJournalEntry].self, forKey: .journal))
    }
    private static func replay(id: UUID, policy: CemeterySurveyPolicy, startedAt: Date,
                               journal: [CemeterySurveyJournalEntry]) throws -> CemeterySurveySession {
        var result = try CemeterySurveySession(id: id, policy: policy, startedAt: startedAt)
        guard journal.count <= policy.maximumJournalEntries else { throw CemeterySurveyError.capacityReached }
        for entry in journal {
            switch entry {
            case let .observation(observation):
                let actual = try result.record(observation.sample, receivedAt: observation.receivedAt,
                                               preferredSegmentID: observation.decision.segmentID)
                guard actual == observation.decision else { throw CemeterySurveyError.invalidCheckpoint }
            case let .paused(at): try result.pause(at: at)
            case let .resumed(at): try result.resume(at: at)
            case let .stopped(at): try result.stop(at: at)
            case let .boundaryConfirmed(boundary):
                let actual = try result.confirmBoundary(segmentID: boundary.sourceSegmentID, at: boundary.confirmedAt,
                                                        simplificationToleranceMeters: boundary.simplificationToleranceMeters)
                guard actual == boundary else { throw CemeterySurveyError.invalidCheckpoint }
            }
        }
        return result
    }
}
