import Foundation

public enum GeometryError: Error, LocalizedError, Equatable, Sendable {
    case tooFewVertices
    case nonFiniteCoordinate
    case duplicateVertex
    case degenerateRing
    case selfIntersection
    case holeOutsideExterior
    case intersectingRings
    case overlappingHoles
    case geographicCoordinateOutOfRange
    case antimeridianRequiresSplitting
    case coordinateFrameMismatch
    case invalidWall
    case tooManyVertices
    case tooFewLineVertices
    case metricCoordinateOutOfRange

    public var errorDescription: String? {
        switch self {
        case .tooFewVertices: "У полигона должно быть не менее трёх разных вершин."
        case .nonFiniteCoordinate: "Проверьте координаты: каждое значение должно быть конечным числом."
        case .duplicateVertex: "В полигоне есть повторяющиеся вершины. Удалите повтор; последнюю вершину замыкать вручную не нужно."
        case .degenerateRing: "Вершины лежат на одной линии или образуют слишком маленький контур."
        case .selfIntersection: "Границы полигона пересекают друг друга. Измените порядок или положение вершин."
        case .holeOutsideExterior: "Внутренний контур находится за пределами внешней границы."
        case .intersectingRings: "Внешний и внутренние контуры не должны пересекаться или касаться друг друга."
        case .overlappingHoles: "Внутренние контуры перекрывают друг друга. Разделите их."
        case .geographicCoordinateOutOfRange: "Долгота должна быть от −180 до 180°, широта — от −90 до 90°."
        case .antimeridianRequiresSplitting: "Контур пересекает линию 180° долготы. Перед экспортом разделите его на отдельные части."
        case .coordinateFrameMismatch: "Геометрия относится к другой системе координат. Выполните привязку или экспортируйте отдельный локальный обмер."
        case .invalidWall: "У стены должны быть разные конечные точки и положительные размеры."
        case .tooManyVertices: "Один объект может содержать не более 2048 вершин и 64 внутренних контуров. Разделите большой объект."
        case .tooFewLineVertices: "У линии должны быть не менее двух разных последовательных точек."
        case .metricCoordinateOutOfRange: "Локальные координаты слишком велики для безопасного расчёта."
        }
    }
}

/// Planar calculations are only available for metric geometry. WGS84 degrees are not meters.
/// This initial engine deliberately rejects touching rings and unsplit antimeridian polygons.
public enum PolygonGeometry {
    public static let maximumVertices = 2048
    public static let maximumHoles = 64

    public static func validate(_ polygon: MetricPolygon) throws {
        try validateBounds(polygon.vertices, holes: polygon.holes)
        try validateRings(polygon.vertices, holes: polygon.holes)
    }

    public static func validate(_ polygon: GeographicPolygon) throws {
        let rings = [polygon.vertices] + polygon.holes
        try validateCount(polygon.vertices.count, holeCounts: polygon.holes.map(\.count))
        for ring in rings {
            for point in ring {
                try validate(point)
                if let origin = polygon.vertices.first, abs(point.longitude - origin.longitude) > 180 {
                    throw GeometryError.antimeridianRequiresSplitting
                }
            }
            for index in ring.indices where ring.count > 1 {
                let next = ring[(index + 1) % ring.count]
                guard abs(ring[index].longitude - next.longitude) <= 180 else {
                    throw GeometryError.antimeridianRequiresSplitting
                }
            }
        }
        try validateRings(polygon.vertices.map(metric), holes: polygon.holes.map { $0.map(metric) })
    }

    public static func validate(_ point: MetricPoint2D) throws {
        guard point.x.isFinite, point.y.isFinite else { throw GeometryError.nonFiniteCoordinate }
        guard abs(point.x) <= 1e12, abs(point.y) <= 1e12 else { throw GeometryError.metricCoordinateOutOfRange }
    }

    public static func validate(_ point: GeographicCoordinate) throws {
        guard point.longitude.isFinite, point.latitude.isFinite else { throw GeometryError.nonFiniteCoordinate }
        guard (-180...180).contains(point.longitude), (-90...90).contains(point.latitude) else {
            throw GeometryError.geographicCoordinateOutOfRange
        }
    }

    public static func validate(_ line: MetricPolyline) throws {
        try validateCount(line.vertices.count, holeCounts: [])
        guard line.vertices.count >= 2 else { throw GeometryError.tooFewLineVertices }
        for point in line.vertices { try validate(point) }
        for index in 1..<line.vertices.count {
            guard line.vertices[index] != line.vertices[index - 1] else { throw GeometryError.duplicateVertex }
        }
    }

    public static func validate(_ line: GeographicPolyline) throws {
        try validateCount(line.vertices.count, holeCounts: [])
        guard line.vertices.count >= 2 else { throw GeometryError.tooFewLineVertices }
        for point in line.vertices { try validate(point) }
        for index in 1..<line.vertices.count {
            guard line.vertices[index] != line.vertices[index - 1] else { throw GeometryError.duplicateVertex }
            guard abs(line.vertices[index].longitude - line.vertices[index - 1].longitude) <= 180 else {
                throw GeometryError.antimeridianRequiresSplitting
            }
        }
    }

    /// Open lines do not acquire an implicit closing segment or enclosed area.
    public static func length(of line: MetricPolyline) throws -> Double {
        try validate(line)
        return (1..<line.vertices.count).reduce(0) { $0 + distance(line.vertices[$1 - 1], line.vertices[$1]) }
    }

    public static func validate(_ geometry: FeatureGeometry, in reference: CoordinateReference) throws {
        guard geometry.coordinateReference == reference else { throw GeometryError.coordinateFrameMismatch }
        switch geometry {
        case let .metricPolygon(polygon): try validate(polygon)
        case let .geographicPolygon(polygon): try validate(polygon)
        case let .metricPoint(_, point): try validate(point)
        case let .geographicPoint(point): try validate(point)
        case let .metricPolyline(line): try validate(line)
        case let .geographicPolyline(line): try validate(line)
        }
    }

    public static func area(of polygon: MetricPolygon) throws -> Double {
        try validate(polygon)
        return abs(signedArea(polygon.vertices)) - polygon.holes.reduce(0) { $0 + abs(signedArea($1)) }
    }

    /// Includes the exterior and all hole boundaries.
    public static func perimeter(of polygon: MetricPolygon) throws -> Double {
        try validate(polygon)
        return ([polygon.vertices] + polygon.holes).reduce(0) { total, ring in
            total + ring.indices.reduce(0) { value, index in
                value + distance(ring[index], ring[(index + 1) % ring.count])
            }
        }
    }

    public static func validate(_ plan: AtlasFloorPlan, in reference: CoordinateReference) throws {
        guard reference == .localMeters(frameID: plan.frameID) else { throw GeometryError.coordinateFrameMismatch }
        for room in plan.rooms {
            guard room.boundary.frameID == plan.frameID else { throw GeometryError.coordinateFrameMismatch }
            try validate(room.boundary)
        }
        for wall in plan.walls {
            guard wall.start.x.isFinite, wall.start.y.isFinite, wall.end.x.isFinite, wall.end.y.isFinite,
                  distance(wall.start, wall.end) > 1e-9 else { throw GeometryError.invalidWall }
            for dimension in [wall.heightMeters, wall.thicknessMeters].compactMap({ $0 }) {
                guard dimension.isFinite, dimension > 0 else { throw GeometryError.invalidWall }
            }
        }
    }

    /// Stable for a small ring translated far from the origin.
    static func signedArea(_ ring: [MetricPoint2D]) -> Double {
        guard let origin = ring.first else { return 0 }
        var twiceArea = 0.0
        var compensation = 0.0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            let term = (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x)
            let corrected = term - compensation
            let next = twiceArea + corrected
            compensation = (next - twiceArea) - corrected
            twiceArea = next
        }
        return twiceArea / 2
    }

    private static func metric(_ point: GeographicCoordinate) -> MetricPoint2D {
        MetricPoint2D(x: point.longitude, y: point.latitude)
    }

    private static func validateCount(_ exteriorCount: Int, holeCounts: [Int]) throws {
        guard holeCounts.count <= maximumHoles, exteriorCount <= maximumVertices,
              holeCounts.reduce(exteriorCount, +) <= maximumVertices else { throw GeometryError.tooManyVertices }
    }

    private static func validateBounds(_ exterior: [MetricPoint2D], holes: [[MetricPoint2D]]) throws {
        try validateCount(exterior.count, holeCounts: holes.map(\.count))
        for point in exterior { try validate(point) }
        for hole in holes { for point in hole { try validate(point) } }
    }

    private static func validateRings(_ exterior: [MetricPoint2D], holes: [[MetricPoint2D]]) throws {
        try validateRing(exterior)
        for hole in holes {
            try validateRing(hole)
            guard !ringsIntersect(exterior, hole) else { throw GeometryError.intersectingRings }
            guard let first = hole.first, contains(first, in: exterior) else { throw GeometryError.holeOutsideExterior }
        }
        for a in holes.indices {
            for b in holes.indices where b > a {
                if ringsIntersect(holes[a], holes[b]) { throw GeometryError.intersectingRings }
                if contains(holes[a][0], in: holes[b]) || contains(holes[b][0], in: holes[a]) {
                    throw GeometryError.overlappingHoles
                }
            }
        }
    }

    private static func validateRing(_ ring: [MetricPoint2D]) throws {
        guard ring.count >= 3 else { throw GeometryError.tooFewVertices }
        guard ring.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw GeometryError.nonFiniteCoordinate }
        let tolerance = linearTolerance(ring)
        for i in ring.indices {
            for j in ring.indices where j > i {
                if distance(ring[i], ring[j]) <= tolerance { throw GeometryError.duplicateVertex }
            }
        }
        for i in ring.indices {
            let iNext = (i + 1) % ring.count
            for j in ring.indices where j > i {
                let jNext = (j + 1) % ring.count
                if iNext == j || jNext == i { continue }
                if intersects(ring[i], ring[iNext], ring[j], ring[jNext], tolerance: tolerance) {
                    throw GeometryError.selfIntersection
                }
            }
        }
        let computedArea = abs(signedArea(ring))
        guard computedArea.isFinite, computedArea > tolerance * tolerance else { throw GeometryError.degenerateRing }
    }

    private static func distance(_ a: MetricPoint2D, _ b: MetricPoint2D) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private static func linearTolerance(_ ring: [MetricPoint2D]) -> Double {
        guard let origin = ring.first else { return 1e-9 }
        let extent = ring.reduce(1.0) { max($0, abs($1.x - origin.x), abs($1.y - origin.y)) }
        return extent * 1e-10
    }

    private static func cross(_ a: MetricPoint2D, _ b: MetricPoint2D, _ c: MetricPoint2D) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func intersects(_ a: MetricPoint2D, _ b: MetricPoint2D, _ c: MetricPoint2D, _ d: MetricPoint2D,
                                   tolerance: Double) -> Bool {
        let scale = max(1, distance(a, b), distance(c, d))
        let crossTolerance = tolerance * scale
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        func onSegment(_ p: MetricPoint2D, _ q: MetricPoint2D, _ r: MetricPoint2D, crossValue: Double) -> Bool {
            abs(crossValue) <= crossTolerance && r.x >= min(p.x, q.x) - tolerance && r.x <= max(p.x, q.x) + tolerance
                && r.y >= min(p.y, q.y) - tolerance && r.y <= max(p.y, q.y) + tolerance
        }
        if onSegment(a, b, c, crossValue: abC) || onSegment(a, b, d, crossValue: abD)
            || onSegment(c, d, a, crossValue: cdA) || onSegment(c, d, b, crossValue: cdB) { return true }
        return ((abC > crossTolerance && abD < -crossTolerance) || (abC < -crossTolerance && abD > crossTolerance))
            && ((cdA > crossTolerance && cdB < -crossTolerance) || (cdA < -crossTolerance && cdB > crossTolerance))
    }

    private static func ringsIntersect(_ a: [MetricPoint2D], _ b: [MetricPoint2D]) -> Bool {
        let tolerance = max(linearTolerance(a), linearTolerance(b))
        for i in a.indices {
            for j in b.indices {
                if intersects(a[i], a[(i + 1) % a.count], b[j], b[(j + 1) % b.count], tolerance: tolerance) { return true }
            }
        }
        return false
    }

    private static func contains(_ point: MetricPoint2D, in ring: [MetricPoint2D]) -> Bool {
        var result = false
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                result.toggle()
            }
        }
        return result
    }
}
