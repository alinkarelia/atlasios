import Foundation

public enum ProjectKind: String, Codable, CaseIterable, Sendable {
    case cemetery, building, objectScan, site
}

/// A project starts in a local metric frame, or contains genuine WGS84 coordinates.
/// An AR origin is never implicitly treated as a GPS position.
public enum CoordinateReference: Codable, Hashable, Sendable {
    case localMeters(frameID: UUID)
    case wgs84

    public var frameID: UUID? {
        guard case let .localMeters(frameID) = self else { return nil }
        return frameID
    }
}

public struct MetricPoint2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct GeographicCoordinate: Codable, Hashable, Sendable {
    public var longitude: Double
    public var latitude: Double
    public init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }
}

/// Rings are stored without the duplicate closing vertex. Exporters close them.
public struct MetricPolygon: Codable, Hashable, Sendable {
    public var frameID: UUID
    public var vertices: [MetricPoint2D]
    public var holes: [[MetricPoint2D]]
    public init(frameID: UUID, vertices: [MetricPoint2D], holes: [[MetricPoint2D]] = []) {
        self.frameID = frameID; self.vertices = vertices; self.holes = holes
    }
}

public struct GeographicPolygon: Codable, Hashable, Sendable {
    public var vertices: [GeographicCoordinate]
    public var holes: [[GeographicCoordinate]]
    public init(vertices: [GeographicCoordinate], holes: [[GeographicCoordinate]] = []) {
        self.vertices = vertices; self.holes = holes
    }
}

/// An open line in one identified local metric frame. A repeated first vertex is
/// permitted only when the operator intentionally records a closed fence line.
public struct MetricPolyline: Codable, Hashable, Sendable {
    public var frameID: UUID
    public var vertices: [MetricPoint2D]
    public init(frameID: UUID, vertices: [MetricPoint2D]) {
        self.frameID = frameID; self.vertices = vertices
    }
}

public struct GeographicPolyline: Codable, Hashable, Sendable {
    public var vertices: [GeographicCoordinate]
    public init(vertices: [GeographicCoordinate]) { self.vertices = vertices }
}

public enum FeatureGeometry: Codable, Hashable, Sendable {
    case metricPolygon(MetricPolygon)
    case geographicPolygon(GeographicPolygon)
    case metricPoint(frameID: UUID, point: MetricPoint2D)
    case geographicPoint(GeographicCoordinate)
    case metricPolyline(MetricPolyline)
    case geographicPolyline(GeographicPolyline)

    public var coordinateReference: CoordinateReference {
        switch self {
        case let .metricPolygon(polygon): .localMeters(frameID: polygon.frameID)
        case let .metricPoint(frameID, _): .localMeters(frameID: frameID)
        case let .metricPolyline(line): .localMeters(frameID: line.frameID)
        case .geographicPolygon, .geographicPoint, .geographicPolyline: .wgs84
        }
    }
}

public enum FeatureCategory: String, Codable, CaseIterable, Sendable {
    case grave, sector, path, building, boundary, other
    case cemetery, road, entrance, wasteBin, fence, wasteDump
}

/// Human review is distinct from measured positional accuracy.
public enum ReviewStatus: String, Codable, CaseIterable, Sendable {
    case draft, needsReview, reviewed
}

public struct AtlasProject: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProjectKind
    public var coordinateReference: CoordinateReference
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int64
    public init(id: UUID = UUID(), name: String, kind: ProjectKind, coordinateReference: CoordinateReference,
                notes: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), revision: Int64 = 0) {
        self.id = id; self.name = name; self.kind = kind; self.coordinateReference = coordinateReference
        self.notes = notes; self.createdAt = createdAt; self.updatedAt = updatedAt; self.revision = revision
    }
}

public struct AtlasFeature: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var label: String
    public var category: FeatureCategory
    public var geometry: FeatureGeometry
    public var attributes: [String: String]
    public var notes: String
    public var reviewStatus: ReviewStatus
    public var revision: Int64
    public init(id: UUID = UUID(), projectID: UUID, label: String, category: FeatureCategory,
                geometry: FeatureGeometry, attributes: [String: String] = [:], notes: String = "",
                reviewStatus: ReviewStatus = .draft, revision: Int64 = 0) {
        self.id = id; self.projectID = projectID; self.label = label; self.category = category
        self.geometry = geometry; self.attributes = attributes; self.notes = notes
        self.reviewStatus = reviewStatus; self.revision = revision
    }
}

public struct PlanRoom: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var boundary: MetricPolygon
    public init(id: UUID = UUID(), name: String, boundary: MetricPolygon) {
        self.id = id; self.name = name; self.boundary = boundary
    }
}

public struct PlanWall: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var start: MetricPoint2D
    public var end: MetricPoint2D
    public var heightMeters: Double?
    public var thicknessMeters: Double?
    public init(id: UUID = UUID(), start: MetricPoint2D, end: MetricPoint2D,
                heightMeters: Double? = nil, thicknessMeters: Double? = nil) {
        self.id = id; self.start = start; self.end = end
        self.heightMeters = heightMeters; self.thicknessMeters = thicknessMeters
    }
}

public struct AtlasFloorPlan: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var frameID: UUID
    public var name: String
    public var floorIndex: Int
    public var rooms: [PlanRoom]
    public var walls: [PlanWall]
    public var revision: Int64
    /// Controls change selected dimensions; independent AR frames remain independent.
    public var measurementApplications: [PlanMeasurementApplication]?
    public init(id: UUID = UUID(), projectID: UUID, frameID: UUID, name: String = "План",
                floorIndex: Int = 0, rooms: [PlanRoom] = [], walls: [PlanWall] = [], revision: Int64 = 0,
                measurementApplications: [PlanMeasurementApplication]? = nil) {
        self.id = id; self.projectID = projectID; self.frameID = frameID; self.name = name
        self.floorIndex = floorIndex; self.rooms = rooms; self.walls = walls; self.revision = revision
        self.measurementApplications = measurementApplications
    }
}

public enum ScanSource: String, Codable, Sendable { case liDAR, roomPlan, photogrammetry, imported }
public enum ScanStatus: String, Codable, Sendable { case recording, interrupted, captured, processing, ready, failed }
public enum SourceAssetKind: String, Codable, Sendable { case image, video, depth, mesh, cameraMetadata, roomPlanJSON }

public struct SourceAssetReference: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Relative to the project's managed asset directory; never an arbitrary absolute path.
    public var relativePath: String
    public var kind: SourceAssetKind
    public var byteCount: Int64
    public var sha256: String?
    public init(id: UUID = UUID(), relativePath: String, kind: SourceAssetKind, byteCount: Int64, sha256: String? = nil) {
        self.id = id; self.relativePath = relativePath; self.kind = kind; self.byteCount = byteCount; self.sha256 = sha256
    }
}

public struct ScanRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var source: ScanSource
    public var status: ScanStatus
    public var frameID: UUID
    public var assets: [SourceAssetReference]
    public var createdAt: Date
    public var revision: Int64
    /// A geographic observation is independent of the scan's local AR frame.
    public var geoTag: GeoTag?
    public init(id: UUID = UUID(), projectID: UUID, source: ScanSource, status: ScanStatus,
                frameID: UUID, assets: [SourceAssetReference] = [], createdAt: Date = Date(), revision: Int64 = 0,
                geoTag: GeoTag? = nil) {
        self.id = id; self.projectID = projectID; self.source = source; self.status = status
        self.frameID = frameID; self.assets = assets; self.createdAt = createdAt; self.revision = revision
        self.geoTag = geoTag
    }
}

public struct AtlasProjectSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var project: AtlasProject
    public var features: [AtlasFeature]
    public var floorPlans: [AtlasFloorPlan]
    public var scans: [ScanRecord]
    /// Optional for archives made before the field measurement tool was added.
    public var measurements: [MeasurementRecord]?
    public init(project: AtlasProject, features: [AtlasFeature] = [], floorPlans: [AtlasFloorPlan] = [], scans: [ScanRecord] = [],
                measurements: [MeasurementRecord]? = nil) {
        schemaVersion = 1; self.project = project; self.features = features; self.floorPlans = floorPlans; self.scans = scans
        self.measurements = measurements
    }
}

public enum SyncEntityKind: String, Codable, Sendable { case project, feature, floorPlan, scan }

/// At-least-once delivery requires the server to deduplicate this immutable event ID.
public struct OutboxEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var entityID: UUID
    public var projectID: UUID
    public var entityKind: SyncEntityKind
    public var baseRevision: Int64
    public var revision: Int64
    public var payload: Data
    public var createdAt: Date
    public init(id: UUID = UUID(), entityID: UUID, projectID: UUID, entityKind: SyncEntityKind,
                baseRevision: Int64, revision: Int64, payload: Data, createdAt: Date = Date()) {
        self.id = id; self.entityID = entityID; self.projectID = projectID; self.entityKind = entityKind
        self.baseRevision = baseRevision; self.revision = revision; self.payload = payload; self.createdAt = createdAt
    }
}
