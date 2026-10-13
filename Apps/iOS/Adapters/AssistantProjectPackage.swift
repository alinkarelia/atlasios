import Foundation
import AtlasCore

/// A stable, plain JSON entry point for a designer or a data-processing tool.
/// All geometry remains in project.json and the unchanged referenced originals.
struct AssistantProjectIndex: Codable, Sendable {
    struct Plan: Codable, Sendable {
        var id: UUID; var name: String; var floorIndex: Int; var frameID: UUID
        var roomCount: Int; var wallCount: Int; var summedRoomAreasSquareMeters: Double
        var areaMethod: String
    }
    struct CollaborationJournal: Codable, Sendable {
        var path: String; var sha256: String; var byteCount: Int64
        var format: String; var timestampEncoding: String
    }
    var schemaVersion = 1
    var application = "TerraView"
    var projectID: UUID
    var projectName: String
    var preparedAt: Date
    var projectFile = "project.json"
    var historyFile = "feature-revisions.json"
    var provenanceFile = "delivery-passport.json"
    var timestampEncoding = "project/index/history/passport: milliseconds since Unix epoch; original capture/photo manifests: declared source format (normally ISO 8601); station/team/assembly journals: Foundation Date seconds since 2001-01-01 UTC"
    var coordinateReference: CoordinateReference
    var plans: [Plan]
    var assets: [FieldAsset]
    var collaborationJournals: [CollaborationJournal]?
    var interpretationRules: [String]

    init(snapshot: AtlasProjectSnapshot, passport: FieldDeliveryPassport) throws {
        projectID = snapshot.project.id; projectName = snapshot.project.name
        preparedAt = passport.preparedAt; coordinateReference = snapshot.project.coordinateReference
        plans = try snapshot.floorPlans.map { plan in
            let area = try plan.rooms.reduce(0.0) { try $0 + PolygonGeometry.area(of: $1.boundary) }
            return Plan(id: plan.id, name: plan.name, floorIndex: plan.floorIndex,
                frameID: plan.frameID, roomCount: plan.rooms.count, wallCount: plan.walls.count,
                summedRoomAreasSquareMeters: area, areaMethod: "sum-of-room-polygons-minus-holes; overlaps-not-unioned")
        }
        assets = passport.assets
        collaborationJournals = passport.assets.filter { $0.relativePath.hasPrefix("Captures/Collaboration/") }.map { asset in
            CollaborationJournal(path: asset.relativePath, sha256: asset.sha256, byteCount: asset.byteCount,
                format: asset.relativePath.hasSuffix(".team-plan.json") ? "CollaborativeSurveyStoredPlan/schema1" : "FragmentAssemblyDocument/schema1",
                timestampEncoding: "Foundation JSONEncoder default Date: seconds since 2001-01-01T00:00:00Z")
        }
        interpretationRules = [
            "Geographic coordinates are WGS84 longitude/latitude in degrees. Metric geometry uses metres and its declared frameID.",
            "RoomPlan and AR meshes use a room-local X,Y,Z frame with Y up. Floor plans use X,Y for the corresponding AR X,Z plane.",
            "Independent frameIDs are not registered by shared units, project membership, GPS or compass readings.",
            "Collaboration journals are exact original JSON bytes. A team plan records its original source feature/revision/boundary/hash; later map edits do not silently move that plan.",
            "Team grid boundsVertices are rectangles, not work polygons: intersect with the original exterior and holes. center is an interior representative point; partialRequiresReview remains an edge completeness task.",
            "gpsWalk means visited only; captureObserved means a declared measured point or operator-mapped footprint has linked material; operatorVerified means human completeness review, not survey-grade accuracy.",
            "A JSON-only colleague exchange can retain evidence whose original is absent here. Match every captureID/sourceSHA256 to the passport's available material/assets before treating it as available geometry or imagery.",
            "operatorMapped footprints are human assertions, not automatic 3D registration. registeredCapture requires the actual approved source-frame-to-grid registration; a nonempty registration UUID alone is not proof.",
            "Assignment changes and evidence UUIDs are append-only. Overlap does not replace another worker's original; unresolved rescan events stay outstanding until explicitly reviewed.",
            "Assembly registries map selected originals into the anchor's original local 3D frame. That common frame is not automatically the WGS84 map or the team plan grid frame.",
            "Interpret sourceToTarget rigid matrices in their declared direction and units; preserve control residuals, held-out checks, gravity gate, human decisions and cycle consistency limits.",
            "Aligned fragment OBJ derivatives retain overlapping source geometry and may have gaps. They are not automatically fused, textured, watertight, globally positioned or safe navigation routes.",
            "Floor indices group room plans; they do not supply elevation or physical registration between floors.",
            "Unknown dimensions, dates, personal identities and source accuracy must remain unknown.",
            "RoomPlan models are semantic drafts. Confidence and observed/inferred surfaces are in source room and structural metadata.",
            "Do not reconstruct occluded walls as measured facts. Label design assumptions separately from survey observations.",
            "Cemetery burial confirmation and personal identity are independent. survey.status=candidate is a proposal, not a confirmed burial.",
            "Terrain anomalies are visible-surface observations, not proof of underground remains or a validated burial probability.",
            "Terrain cells use column*cellSize and row*cellSize in local AR X/Z; height+referenceHeight is representative AR Y. Residual is deviation from fitted local background. Absent cells are unobserved.",
            "Only a terrain registration with approvedAt authorizes its WGS84 overlay. Control accuracy and residuals limit interpretation; cell spacing is not positional accuracy.",
            "Rejected or removed features and source histories remain data. Preserve their stable UUIDs when correcting or enriching records.",
            "Original photo EXIF stays in original bytes. capturedAt may be absent; preparedAt and importedAt are not capture time.",
            "Delivery passport hashes refer to exact archive members; verify hashes before interpreting a derivative or associating a photo."
        ]
    }
}

struct AssistantFeatureHistory: Codable, Sendable {
    var schemaVersion = 1
    var projectID: UUID
    var histories: [Entry]
    struct Entry: Codable, Sendable {
        var featureID: UUID
        var revisions: [AtlasFeature]
    }
}

enum AssistantProjectPackage {
    static func prepare(snapshot: AtlasProjectSnapshot, passportData: Data,
                        histories: [AssistantFeatureHistory.Entry], staging: URL) throws -> [URL] {
        var delivery = try FieldTransferJSON.decode(FieldDeliveryPassport.self, from: passportData)
        let history = staging.appendingPathComponent("feature-revisions.json")
        let readme = staging.appendingPathComponent("READ-ME.txt")
        let index = staging.appendingPathComponent("assistant-index.json")
        try AtlasExporter.export(snapshot, format: .projectJSON).data
            .write(to: staging.appendingPathComponent("project.json"), options: .atomic)
        try FieldTransferJSON.encode(AssistantFeatureHistory(projectID: snapshot.project.id, histories: histories), pretty: true)
            .write(to: history, options: .atomic)
        try Data(Self.readme.utf8).write(to: readme, options: .atomic)
        for file in [history, readme] {
            let data = try Data(contentsOf: file)
            delivery.assets.append(FieldAsset(materialID: snapshot.project.id, relativePath: file.lastPathComponent,
                mediaType: file.pathExtension == "json" ? "application/json" : "text/plain",
                byteCount: Int64(data.count), sha256: FieldTransferDigest.sha256(data), kind: .metadata))
        }
        let indexData = try FieldTransferJSON.encode(AssistantProjectIndex(snapshot: snapshot, passport: delivery), pretty: true)
        try indexData.write(to: index, options: .atomic)
        delivery.assets.append(FieldAsset(materialID: snapshot.project.id, relativePath: index.lastPathComponent,
            mediaType: "application/json", byteCount: Int64(indexData.count),
            sha256: FieldTransferDigest.sha256(indexData), kind: .metadata))
        try FieldTransferJSON.encode(delivery, pretty: true)
            .write(to: staging.appendingPathComponent("delivery-passport.json"), options: .atomic)
        return [history, readme, index]
    }

    static let readme = """
    TERRAVIEW — PROJECT FOR DESIGN AND FIELD DATA PROCESSING

    Start with assistant-index.json, then project.json and delivery-passport.json.
    project.json contains every current feature, its raw attributes and geometry,
    cemetery links, burial cards, floor plans, scans and control measurements.
    feature-revisions.json contains the retained operator-edit history. A project
    upgraded from an older version may have only its migration baseline and later edits.

    Captures/ contains unchanged original photos, source RoomPlan/AR data, meshes,
    structural clean-room derivatives, GPS journals and terrain sidecars where available.
    Paths and SHA-256 hashes are listed in delivery-passport.json. Derivatives never
    replace source evidence. Room JSON carries doors/windows/openings and confidence.

    Captures/Collaboration/ contains the shared team plan and/or fragment registration
    journal when present. These files use Foundation Date seconds since 2001-01-01 UTC;
    assistant-index.json identifies their exact paths, SHA-256 hashes and byte counts.
    Grid rectangles must be clipped to the original polygon and holes. GPS walking is
    not scanned coverage, and an operator review is not a positional-accuracy guarantee.
    A colleague's JSON can reference originals not yet shared; verify their availability
    and capture IDs against the passport before using them for processing.

    Assembly records preserve separate original frames, control/check-point residuals,
    gravity constraints and operator decisions. A geometry-only aligned OBJ remains a
    derivative with possible overlap and gaps; no automatic fusion or textures are implied.
    The anchor's local 3D frame does not itself establish a WGS84/map-grid registration.

    Local geometry is in metres in its named frame; geographic geometry is WGS84.
    Different frames and floors require explicit registration. A map geotag alone
    does not register a local scan. Room polygons may overlap; summed areas are not
    a unioned total floor area. No print scale or survey-grade accuracy is implied.

    For a design project: inspect observed structural geometry, dimensions, openings
    and photographs. Separate existing conditions, proposed design and unresolved
    survey assumptions. Missing ceiling height, hidden walls or services require
    confirmation before a construction drawing. The package supports design work;
    it does not itself certify construction documentation.

    For a cemetery: keep possible and confirmed burials separate, allow unknown
    identity, and preserve specialist notes and every photo link. Terrain anomalies
    are inspection prompts. Absence of an anomaly does not establish absence of burial.

    No server is required to read this archive. Website/x0 delivery is a later integration.
    """
}
