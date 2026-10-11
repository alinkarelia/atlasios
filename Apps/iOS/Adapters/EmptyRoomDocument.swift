import Foundation

/// An annotation sidecar for reported RoomPlan geometry. It carries no inferred
/// ceiling and no claim of survey-grade or centimetre accuracy.
struct EmptyRoomDocument: Codable, Sendable {
    var schemaVersion = 1
    var sourceRoomID: UUID
    var captureID: UUID
    var projectID: UUID
    var frameID: UUID
    var capturedAt: Date
    var sourceRoomJSONSHA256: String
    var story: Int
    var keepStorage: Bool
    var removedObjectCount: Int
    var surfaces: [EmptyRoomSurface]
    var storage: [EmptyRoomStorage]
    var reviewStatus = "semanticDraftRequiresReview"
    var units = "metres"
    var axes = "RoomPlan X/Y/Z; Y up; floor plan X/Y maps to RoomPlan X/Z"
    var ceilingObserved = false
    var floorAreaPolicy = "Horizontal X/Z projection; sum of contours without overlap union"
    var objExportIssue: String?
    var notices: [String]

    var dimensions: [EmptyRoomDimension] { surfaces.flatMap(\.dimensions) }
    var uncertainSurfaceCount: Int { surfaces.filter { $0.confidence != .high }.count }
    var floorAreaSquareMeters: Double {
        surfaces.filter { $0.kind == .floor }.reduce(0) { $0 + $1.floorAreaSquareMeters }
    }
}

enum EmptyRoomSurfaceKind: String, Codable, Sendable { case wall, floor, window, door, opening }
enum EmptyRoomConfidence: String, Codable, Sendable {
    case high, medium, low, unknown
    var title: String {
        switch self { case .high: "Высокая"; case .medium: "Средняя"; case .low: "Низкая"; case .unknown: "Не указана" }
    }
}

struct EmptyRoomPoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double
    var isFinite: Bool { [x, y, z].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 } }
    func distance(to point: Self) -> Double {
        sqrt(pow(x - point.x, 2) + pow(y - point.y, 2) + pow(z - point.z, 2))
    }
    static func midpoint(_ a: Self, _ b: Self) -> Self {
        .init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: (a.z + b.z) / 2)
    }
}

struct EmptyRoomTransform: Codable, Sendable {
    /// Column-major affine transform, exactly as reported by RoomPlan.
    var columns: [Double]
    var isValid: Bool {
        columns.count == 16 && columns.allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
            && abs(columns[3]) < 0.00001 && abs(columns[7]) < 0.00001
            && abs(columns[11]) < 0.00001 && abs(columns[15] - 1) < 0.00001
    }
    func point(_ p: EmptyRoomPoint) -> EmptyRoomPoint? {
        guard isValid, p.isFinite else { return nil }
        let result = EmptyRoomPoint(x: columns[0] * p.x + columns[4] * p.y + columns[8] * p.z + columns[12],
                                   y: columns[1] * p.x + columns[5] * p.y + columns[9] * p.z + columns[13],
                                   z: columns[2] * p.x + columns[6] * p.y + columns[10] * p.z + columns[14])
        return result.isFinite ? result : nil
    }
}

struct EmptyRoomSurface: Codable, Sendable, Identifiable {
    var id: UUID
    var parentID: UUID?
    var kind: EmptyRoomSurfaceKind
    var widthMeters: Double?
    var heightMeters: Double?
    var thicknessMeters: Double?
    var transform: EmptyRoomTransform
    var polygonCorners: [EmptyRoomPoint]
    var isCurved: Bool
    var confidence: EmptyRoomConfidence

    var title: String {
        switch kind { case .wall: "Стена"; case .floor: "Пол"; case .window: "Окно"; case .door: "Дверь"; case .opening: "Проём" }
    }
    var floorWorldRing: [EmptyRoomPoint] {
        guard kind == .floor, polygonCorners.count >= 3 else { return [] }
        let world = polygonCorners.compactMap { transform.point($0) }
        guard world.count == polygonCorners.count else { return [] }
        return EmptyRoomRingGeometry.normalized(world)
    }
    var floorAreaSquareMeters: Double {
        EmptyRoomRingGeometry.area(outer: floorWorldRing)
    }
    var dimensions: [EmptyRoomDimension] {
        if kind == .floor {
            let ring = floorWorldRing
            guard ring.count >= 3, floorAreaSquareMeters > 0.00001 else { return [] }
            return EmptyRoomRingGeometry.edges(outer: ring).enumerated().compactMap { i, edge in
                dimension("edge-\(i)", title: "Пол · сторона \(i + 1)", start: edge.start, end: edge.end)
            }
        }
        var result: [EmptyRoomDimension] = []
        let bottom = -(heightMeters ?? 0) / 2
        if let width = widthMeters, width.isFinite, width > 0,
           let start = transform.point(.init(x: -width / 2, y: bottom, z: 0)),
           let end = transform.point(.init(x: width / 2, y: bottom, z: 0)),
           let value = dimension("width", title: "\(title) · \(isCurved ? "габарит" : (kind == .wall ? "длина" : "ширина"))", start: start, end: end) { result.append(value) }
        if let height = heightMeters, height.isFinite, height > 0 {
            let side = -(widthMeters ?? 0) / 2
            if let start = transform.point(.init(x: side, y: -height / 2, z: 0)),
               let end = transform.point(.init(x: side, y: height / 2, z: 0)),
               let value = dimension("height", title: "\(title) · высота", start: start, end: end) { result.append(value) }
        }
        return result
    }
    private func dimension(_ suffix: String, title: String, start: EmptyRoomPoint, end: EmptyRoomPoint) -> EmptyRoomDimension? {
        let value = start.distance(to: end)
        guard value.isFinite, value > 0.00001, value <= 1_000_000 else { return nil }
        return .init(id: "\(id.uuidString)-\(suffix)", sourceID: id, title: title, start: start, end: end,
                     valueMeters: value, confidence: confidence)
    }
}

struct EmptyRoomStorage: Codable, Sendable, Identifiable {
    var id: UUID
    var category = "storage"
    var widthMeters: Double?
    var heightMeters: Double?
    var depthMeters: Double?
    var transform: EmptyRoomTransform
    var confidence: EmptyRoomConfidence
}

struct EmptyRoomDimension: Codable, Sendable, Identifiable {
    var id: String
    var sourceID: UUID
    var title: String
    var start: EmptyRoomPoint
    var end: EmptyRoomPoint
    var valueMeters: Double
    var confidence: EmptyRoomConfidence
    var label: String { "\(title): \(valueMeters.formatted(.number.precision(.fractionLength(2)))) м" }
}

struct EmptyRoomExport: Sendable {
    var manifestURL: URL
    var documentURL: URL
    var usdzURL: URL
    var objURL: URL?
    var document: EmptyRoomDocument
}

struct SavedEmptyRoomSource: Sendable, Identifiable {
    var id: UUID
    var directory: URL
    var createdAt: Date
    var name: String
}

struct SavedEmptyRoomListing: Sendable {
    var rooms: [SavedEmptyRoomSource]
    var issues: [String]
}

enum EmptyRoomError: LocalizedError {
    case unsupportedSchema, invalidGeometry, wrongProject, noSource, sourceLimit, noRenderedImage, presentationLimit
    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "Формат RoomPlan не поддерживается для безопасного удаления объектов. Исходный обмер сохранён."
        case .invalidGeometry: "RoomPlan вернул некорректную геометрию. Исходный обмер сохранён; проверьте его перед использованием."
        case .wrongProject: "Обмер принадлежит другому проекту."
        case .noSource: "В сохранённом обмере нет готового room.json."
        case .sourceLimit: "Исходный RoomPlan превышает предел повторной обработки: 32 МБ. Исходные файлы доступны для выгрузки из проекта."
        case .noRenderedImage: "Сначала дождитесь 3D-предпросмотра, затем сохраните изображение."
        case .presentationLimit: "Ведомость превышает предел PDF: 10 000 размеров. Полная геометрия и размеры сохранены в USDZ/JSON."
        }
    }
}

/// CapturedRoom.objects has no setter. Filter its Codable representation and
/// re-decode it natively; every other key remains intact, including future keys.
enum EmptyRoomJSONFilter {
    static func filter(_ data: Data, retaining identifiers: Set<UUID>) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]] else { throw EmptyRoomError.unsupportedSchema }
        var seen = Set<UUID>()
        var retained: [[String: Any]] = []
        for object in objects {
            guard let text = object["identifier"] as? String, let id = UUID(uuidString: text), seen.insert(id).inserted else {
                throw EmptyRoomError.unsupportedSchema
            }
            if identifiers.contains(id) { retained.append(object) }
        }
        guard identifiers.isSubset(of: seen) else { throw EmptyRoomError.unsupportedSchema }
        root["objects"] = retained
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

/// Shared by RoomPlan floor labels and the manual floor-plan drawing. Holes are
/// real independent rings, never connected to the outer ring by invented edges.
enum EmptyRoomRingGeometry {
    struct Edge: Sendable {
        var start: EmptyRoomPoint
        var end: EmptyRoomPoint
        var holeIndex: Int?
        var length: Double { start.distance(to: end) }
    }
    static func normalized(_ input: [EmptyRoomPoint]) -> [EmptyRoomPoint] {
        guard input.allSatisfy(\.isFinite) else { return [] }
        var ring = input
        if let first = ring.first, let last = ring.last, first.distance(to: last) < 0.00001 { ring.removeLast() }
        guard ring.count >= 3 else { return [] }
        return ring
    }
    static func edges(outer: [EmptyRoomPoint], holes: [[EmptyRoomPoint]] = []) -> [Edge] {
        let rings: [([EmptyRoomPoint], Int?)] = [(normalized(outer), nil)] + holes.enumerated().map { (normalized($0.element), Optional($0.offset)) }
        return rings.flatMap { ring, hole in
            ring.indices.compactMap { i in
                let edge = Edge(start: ring[i], end: ring[(i + 1) % ring.count], holeIndex: hole)
                return edge.length > 0.00001 ? edge : nil
            }
        }
    }
    static func area(outer: [EmptyRoomPoint], holes: [[EmptyRoomPoint]] = []) -> Double {
        func ringArea(_ input: [EmptyRoomPoint]) -> Double {
            let ring = normalized(input)
            guard ring.count >= 3, let origin = ring.first else { return 0 }
            var sum = 0.0, compensation = 0.0
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                let term = (a.x - origin.x) * (b.z - origin.z) - (b.x - origin.x) * (a.z - origin.z)
                let corrected = term - compensation, next = sum + corrected
                compensation = (next - sum) - corrected; sum = next
            }
            return abs(sum) / 2
        }
        return max(0, ringArea(outer) - holes.reduce(0) { $0 + ringArea($1) })
    }
}
