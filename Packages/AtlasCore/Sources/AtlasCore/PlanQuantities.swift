import Foundation

/// Areas refer to one observed planar face. They do not include both sides of a
/// wall, reveal surfaces, thickness, or an inferred ceiling.
public struct PlanSurfaceArea: Codable, Hashable, Sendable {
    public let grossSquareMeters: Double
    public let holesSquareMeters: Double
    /// Unknown when the opening survey is incomplete. An empty list of observed
    /// openings does not by itself establish that a wall has no openings.
    public let netSquareMeters: Double?
}

/// Subtotals over the objects supplied in one plan, not a claim that the entire
/// apartment or building has been surveyed. Repeated IDs are counted once.
public struct PlanQuantitySummary: Codable, Hashable, Sendable {
    public let floorGrossSquareMeters: Double?
    public let floorNetSquareMeters: Double?
    public let wallGrossSquareMeters: Double?
    /// PlanWall does not record opening coverage, so its net area is unknown.
    public var wallNetSquareMeters: Double? { nil }
    public let roomCount: Int
    public let measuredRoomCount: Int
    public let invalidRoomCount: Int
    public let crossFrameRoomCount: Int
    public let duplicateRoomCount: Int
    public let wallCount: Int
    public let measuredWallCount: Int
    public let unknownHeightWallCount: Int
    public let invalidWallCount: Int
    public let duplicateWallCount: Int

    /// Completeness of the supplied contours only; overlapping rooms are not
    /// dissolved into a union and missing rooms cannot be discovered here.
    public var hasCompleteFloorContours: Bool {
        roomCount > 0 && measuredRoomCount == roomCount
    }
    public var hasCompleteWallHeights: Bool {
        wallCount > 0 && measuredWallCount == wallCount
    }
    public var aggregationNote: String {
        "Сумма контуров помещений; пересечения не объединены. Площадь пола — горизонтальная проекция. Площадь стен — прямоугольная модель одной стороны; проёмы не вычтены."
    }
}

public enum PlanQuantities {
    /// Floor contours are horizontal projections in their explicitly identified
    /// local metric frame. Holes are excluded; no sloped surface area is inferred.
    public static func floorArea(of polygon: MetricPolygon, expectedFrameID: UUID) throws -> PlanSurfaceArea {
        try area(of: polygon, expectedFrameID: expectedFrameID, holesComplete: true)
    }

    /// A wall-face polygon must be observed in that face's own metric plane.
    /// Explicit interior holes represent observed openings. As with other metric
    /// polygons, a hole may not touch the exterior: a floor-attached door cannot
    /// be entered as a touching hole. Callers must affirm that opening coverage
    /// is complete before displaying a net area.
    public static func wallFaceArea(of polygon: MetricPolygon, expectedFrameID: UUID,
                                    openingsComplete: Bool) throws -> PlanSurfaceArea {
        try area(of: polygon, expectedFrameID: expectedFrameID, holesComplete: openingsComplete)
    }

    /// Gross area of a rectangular wall, on one side. A missing height remains
    /// unknown. This helper cannot account for sloped tops or opening coverage.
    public static func wallGrossArea(of wall: PlanWall) throws -> Double? {
        try PolygonGeometry.validate(wall.start)
        try PolygonGeometry.validate(wall.end)
        let length = hypot(wall.end.x - wall.start.x, wall.end.y - wall.start.y)
        guard length > 1e-9 else { throw GeometryError.invalidWall }
        guard let height = wall.heightMeters else { return nil }
        guard height.isFinite, height > 0 else { throw GeometryError.invalidWall }
        let result = length * height
        guard result.isFinite else { throw GeometryError.invalidWall }
        return result
    }

    /// Rooms with a different local frame and invalid geometry are excluded,
    /// with explicit counts. For duplicate IDs, the first supplied record wins;
    /// later copies cannot inflate quantities or rescue an invalid first record.
    public static func summary(of plan: AtlasFloorPlan) -> PlanQuantitySummary {
        var roomIDs = Set<UUID>(), wallIDs = Set<UUID>()
        var grossFloors = StableSum(), netFloors = StableSum(), grossWalls = StableSum()
        var measuredRooms = 0, invalidRooms = 0, crossFrameRooms = 0, duplicateRooms = 0
        var measuredWalls = 0, unknownWalls = 0, invalidWalls = 0, duplicateWalls = 0
        for room in plan.rooms {
            guard roomIDs.insert(room.id).inserted else { duplicateRooms += 1; continue }
            guard room.boundary.frameID == plan.frameID else { crossFrameRooms += 1; continue }
            do {
                let quantity = try floorArea(of: room.boundary, expectedFrameID: plan.frameID)
                guard let net = quantity.netSquareMeters else { invalidRooms += 1; continue }
                guard let nextGross = grossFloors.adding(quantity.grossSquareMeters),
                      let nextNet = netFloors.adding(net) else { invalidRooms += 1; continue }
                grossFloors = nextGross
                netFloors = nextNet
                measuredRooms += 1
            } catch { invalidRooms += 1 }
        }
        for wall in plan.walls {
            guard wallIDs.insert(wall.id).inserted else { duplicateWalls += 1; continue }
            do {
                guard let quantity = try wallGrossArea(of: wall) else { unknownWalls += 1; continue }
                guard let next = grossWalls.adding(quantity) else { invalidWalls += 1; continue }
                grossWalls = next
                measuredWalls += 1
            } catch { invalidWalls += 1 }
        }
        return PlanQuantitySummary(
            floorGrossSquareMeters: measuredRooms == 0 ? nil : grossFloors.value,
            floorNetSquareMeters: measuredRooms == 0 ? nil : netFloors.value,
            wallGrossSquareMeters: measuredWalls == 0 ? nil : grossWalls.value,
            roomCount: plan.rooms.count, measuredRoomCount: measuredRooms,
            invalidRoomCount: invalidRooms, crossFrameRoomCount: crossFrameRooms,
            duplicateRoomCount: duplicateRooms, wallCount: plan.walls.count,
            measuredWallCount: measuredWalls, unknownHeightWallCount: unknownWalls,
            invalidWallCount: invalidWalls, duplicateWallCount: duplicateWalls)
    }

    private static func area(of polygon: MetricPolygon, expectedFrameID: UUID,
                             holesComplete: Bool) throws -> PlanSurfaceArea {
        guard polygon.frameID == expectedFrameID else { throw GeometryError.coordinateFrameMismatch }
        let net = try PolygonGeometry.area(of: polygon)
        let gross = abs(PolygonGeometry.signedArea(polygon.vertices))
        return PlanSurfaceArea(grossSquareMeters: gross, holesSquareMeters: gross - net,
                               netSquareMeters: holesComplete ? net : nil)
    }

    private struct StableSum {
        private(set) var value = 0.0
        private var compensation = 0.0
        func adding(_ item: Double) -> StableSum? {
            let adjusted = item - compensation
            let next = value + adjusted
            guard next.isFinite else { return nil }
            var result = self
            result.compensation = (next - value) - adjusted
            result.value = next
            return result
        }
    }
}
