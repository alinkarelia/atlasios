import Foundation

struct EmptyRoomWallQuantity: Identifiable, Sendable {
    var id: UUID
    var grossSquareMeters: Double?
    var netSquareMeters: Double?
    var openingSquareMeters: Double?
    var usesRectangularEnvelope: Bool
    var issue: String?
}

/// Quantities of the saved semantic model, never a promise of a complete survey.
/// Independent polygons are summed; overlapping rooms are not silently dissolved.
struct EmptyRoomQuantitySummary: Sendable {
    var floorGrossSquareMeters: Double?
    var floorNetSquareMeters: Double? { nil }
    var measuredFloorCount: Int
    var unknownFloorCount: Int
    var walls: [EmptyRoomWallQuantity]
    var wallGrossSquareMeters: Double? {
        let values = walls.compactMap(\.grossSquareMeters)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    var wallNetSquareMeters: Double? {
        guard !walls.isEmpty, walls.allSatisfy({ $0.netSquareMeters != nil }) else { return nil }
        return walls.compactMap(\.netSquareMeters).reduce(0, +)
    }
    var unknownWallCount: Int { walls.filter { $0.grossSquareMeters == nil }.count }
    var unknownNetWallCount: Int { walls.filter { $0.netSquareMeters == nil }.count }
}

enum EmptyRoomQuantities {
    static func summary(_ document: EmptyRoomDocument, review providedReview: EmptyRoomSurfaceReview?) -> EmptyRoomQuantitySummary {
        let review: EmptyRoomSurfaceReview?
        if let providedReview {
            do { try EmptyRoomSurfaceReviewPolicy.validate(providedReview, source: document); review = providedReview }
            catch { review = nil }
        } else { review = nil }
        let floors = document.surfaces.filter { $0.kind == .floor }
        let areas = floors.compactMap { surface -> Double? in
            let ring = surface.floorWorldRing.map { Point(x: $0.x, y: $0.z) }
            return polygonArea(ring)
        }
        let openings = document.surfaces.filter { [.door, .window, .opening].contains($0.kind) }
        let walls = document.surfaces.filter { $0.kind == .wall }
        let wallIDs = Set(walls.map(\.id))
        let orphanCount = openings.filter { $0.parentID == nil || !wallIDs.contains($0.parentID!) }.count
        let quantities = walls.map { wall -> EmptyRoomWallQuantity in
            var result = EmptyRoomWallQuantity(id: wall.id, grossSquareMeters: nil, netSquareMeters: nil,
                openingSquareMeters: nil, usesRectangularEnvelope: wall.polygonCorners.count < 3, issue: nil)
            guard !wall.isCurved else { result.issue = "Криволинейная поверхность: площадь по габариту не вычисляется."; return result }
            let boundary: [Point]
            if wall.polygonCorners.count >= 3 {
                guard wall.polygonCorners.allSatisfy({ abs($0.z) <= 0.005 }) else {
                    result.issue = "Контур стены не лежит в её плоскости; площадь неизвестна."; return result
                }
                boundary = wall.polygonCorners.map { Point(x: $0.x, y: $0.y) }
            } else if let width = wall.widthMeters, let height = wall.heightMeters,
                      width.isFinite, height.isFinite, width > 0, height > 0 {
                boundary = [Point(x: -width / 2, y: -height / 2), Point(x: width / 2, y: -height / 2),
                            Point(x: width / 2, y: height / 2), Point(x: -width / 2, y: height / 2)]
            } else { result.issue = "Нет полной длины/высоты стены; площадь неизвестна."; return result }
            guard let gross = polygonArea(boundary), rigidAxes(wall.transform) != nil else {
                result.issue = "Контур или система осей стены не пригодны для площади."; return result
            }
            result.grossSquareMeters = gross
            guard review?.latest(for: wall.id)?.openingCoverageComplete == true else {
                result.issue = "Полнота обследования проёмов стены не подтверждена."; return result
            }
            guard orphanCount == 0 else { result.issue = "Есть проёмы без известной родительской стены; чистая площадь неизвестна."; return result }
            var polygons: [[Point]] = []
            for opening in openings where opening.parentID == wall.id {
                guard let decision = review?.latest(for: opening.id), decision.semanticVerified, decision.openingGeometryVerified == true,
                      [.roomDoor, .window, .openPassage].contains(decision.role), decision.dimensionMeaning == .clearOpening,
                      !opening.isCurved, opening.polygonCorners.count >= 3 else {
                    result.issue = "Проверьте тип и реальный контур каждого проёма. Габарит W×H не заменяет арочный или неполный контур."; return result
                }
                let world = opening.polygonCorners.compactMap { opening.transform.point($0) }
                guard world.count == opening.polygonCorners.count else { result.issue = "Не прочитаны точки проёма."; return result }
                let projected = world.compactMap { project($0, onto: wall.transform) }
                guard projected.count == world.count, polygonArea(projected) != nil,
                      contained(projected, in: boundary), polygons.allSatisfy({ !overlaps($0, projected) }) else {
                    result.issue = "Проём не лежит в плоскости/границах стены либо пересекается с другим проёмом. Чистая площадь неизвестна."; return result
                }
                polygons.append(projected)
            }
            let deducted = polygons.compactMap(polygonArea).reduce(0, +)
            guard deducted <= gross + 0.000001 else { result.issue = "Площадь проёмов превышает площадь стены."; return result }
            result.openingSquareMeters = deducted
            result.netSquareMeters = max(0, gross - deducted)
            return result
        }
        return .init(floorGrossSquareMeters: areas.isEmpty ? nil : areas.reduce(0, +),
                     measuredFloorCount: areas.count, unknownFloorCount: floors.count - areas.count, walls: quantities)
    }

    struct Point: Sendable { var x: Double; var y: Double }
    private static let tolerance = 0.000001
    static func polygonArea(_ input: [Point]) -> Double? {
        var ring = input
        if let first = ring.first, let last = ring.last, hypot(first.x - last.x, first.y - last.y) < tolerance { ring.removeLast() }
        guard (3...1_024).contains(ring.count), ring.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else { return nil }
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            guard hypot(a.x - b.x, a.y - b.y) > tolerance else { return nil }
            for j in ring.indices where j > i && j != i + 1 && !(i == 0 && j == ring.count - 1) {
                if intersects(a, b, ring[j], ring[(j + 1) % ring.count], includingTouch: true) { return nil }
            }
        }
        let origin = ring[0]
        var twiceArea = 0.0
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let first = (a.x - origin.x) * (b.y - origin.y)
            let second = (b.x - origin.x) * (a.y - origin.y)
            twiceArea += first - second
        }
        let area = abs(twiceArea) / 2
        return area.isFinite && area > tolerance ? area : nil
    }
    private static func cross(_ a: Point, _ b: Point, _ c: Point) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
    private static func onSegment(_ p: Point, _ a: Point, _ b: Point) -> Bool {
        abs(cross(a, b, p)) <= tolerance && p.x >= min(a.x, b.x) - tolerance && p.x <= max(a.x, b.x) + tolerance
            && p.y >= min(a.y, b.y) - tolerance && p.y <= max(a.y, b.y) + tolerance
    }
    private static func intersects(_ a: Point, _ b: Point, _ c: Point, _ d: Point, includingTouch: Bool) -> Bool {
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        if ((abC > tolerance && abD < -tolerance) || (abC < -tolerance && abD > tolerance))
            && ((cdA > tolerance && cdB < -tolerance) || (cdA < -tolerance && cdB > tolerance)) { return true }
        return includingTouch && (onSegment(a, c, d) || onSegment(b, c, d) || onSegment(c, a, b) || onSegment(d, a, b))
    }
    private static func inside(_ point: Point, ring: [Point], boundaryAllowed: Bool) -> Bool {
        var inside = false
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if onSegment(point, a, b) { return boundaryAllowed }
            if (a.y > point.y) != (b.y > point.y), point.x < a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y) { inside.toggle() }
        }
        return inside
    }
    private static func contained(_ polygon: [Point], in boundary: [Point]) -> Bool {
        guard polygon.allSatisfy({ inside($0, ring: boundary, boundaryAllowed: true) }) else { return false }
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            guard inside(.init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), ring: boundary, boundaryAllowed: true) else { return false }
            for j in boundary.indices where intersects(a, b, boundary[j], boundary[(j + 1) % boundary.count], includingTouch: false) { return false }
        }
        return true
    }
    private static func overlaps(_ a: [Point], _ b: [Point]) -> Bool {
        if a.contains(where: { inside($0, ring: b, boundaryAllowed: false) }) || b.contains(where: { inside($0, ring: a, boundaryAllowed: false) }) { return true }
        for i in a.indices {
            for j in b.indices where intersects(a[i], a[(i + 1) % a.count], b[j], b[(j + 1) % b.count], includingTouch: true) { return true }
        }
        return false
    }

    /// Require a rigid native frame before treating local x/y as square metres.
    private static func rigidAxes(_ transform: EmptyRoomTransform) -> [[Double]]? {
        guard transform.isValid else { return nil }
        let c = transform.columns
        let axes = [[c[0], c[1], c[2]], [c[4], c[5], c[6]], [c[8], c[9], c[10]]]
        for i in 0..<3 {
            guard abs(axes[i].reduce(0) { $0 + $1 * $1 } - 1) < 0.001 else { return nil }
            for j in 0..<i where abs(zip(axes[i], axes[j]).reduce(0) { $0 + $1.0 * $1.1 }) >= 0.001 { return nil }
        }
        return axes
    }
    private static func project(_ world: EmptyRoomPoint, onto transform: EmptyRoomTransform) -> Point? {
        guard let axes = rigidAxes(transform) else { return nil }
        let c = transform.columns, delta = [world.x - c[12], world.y - c[13], world.z - c[14]]
        func coordinate(_ index: Int) -> Double { zip(delta, axes[index]).reduce(0) { $0 + $1.0 * $1.1 } }
        // Numerical coplanarity check, not an accuracy claim or a registration.
        guard abs(coordinate(2)) <= 0.005 else { return nil }
        return .init(x: coordinate(0), y: coordinate(1))
    }
}
