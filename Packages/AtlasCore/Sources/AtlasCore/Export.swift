import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case projectJSON, geoJSON, dxf, svg, csv, kml
}

public struct ExportArtifact: Sendable {
    public var fileName: String
    public var contentType: String
    public var data: Data
    public var warnings: [String]
    public init(fileName: String, contentType: String, data: Data, warnings: [String] = []) {
        self.fileName = fileName; self.contentType = contentType; self.data = data; self.warnings = warnings
    }
}

public enum AtlasExportError: Error, LocalizedError, Equatable, Sendable {
    case requiresGeographicCoordinates
    case requiresLocalMetricCoordinates
    case entityProjectMismatch
    case unsupportedSchema(Int)
    case invalidDate

    public var errorDescription: String? {
        switch self {
        case .requiresGeographicCoordinates: "Для географических контуров нужны координаты WGS84. KML также может выгрузить существующие достоверные геометки. Для локальных контуров доступны DXF и SVG; привязка к карте выполняется отдельно."
        case .requiresLocalMetricCoordinates: "Для DXF/SVG нужны локальные метрические координаты. Географический проект можно экспортировать в GeoJSON или KML."
        case .entityProjectMismatch: "В экспорт попал объект другого проекта. Обновите проект и повторите операцию."
        case .unsupportedSchema: "Формат проекта новее этой версии приложения. Обновите TerraView перед экспортом."
        case .invalidDate: "В метаданных указана недопустимая дата. Проверьте исходную запись перед экспортом."
        }
    }
}

public enum AtlasExporter {
    public static func export(_ snapshot: AtlasProjectSnapshot, format: ExportFormat) throws -> ExportArtifact {
        guard snapshot.schemaVersion == 1 else { throw AtlasExportError.unsupportedSchema(snapshot.schemaVersion) }
        for feature in snapshot.features {
            guard feature.projectID == snapshot.project.id else { throw AtlasExportError.entityProjectMismatch }
            try PolygonGeometry.validate(feature.geometry, in: snapshot.project.coordinateReference)
        }
        for plan in snapshot.floorPlans {
            guard plan.projectID == snapshot.project.id else { throw AtlasExportError.entityProjectMismatch }
            try PolygonGeometry.validate(plan, in: .localMeters(frameID: plan.frameID))
            try MeasurementPlanControl.validateApplications(plan)
        }
        for scan in snapshot.scans {
            guard scan.projectID == snapshot.project.id else { throw AtlasExportError.entityProjectMismatch }
            if let tag = scan.geoTag { try GeoTagPolicy.validate(tag) }
        }
        for measurement in snapshot.measurements ?? [] {
            guard measurement.projectID == snapshot.project.id else { throw AtlasExportError.entityProjectMismatch }
            try MeasurementPolicy.validate(measurement)
        }
        let name = "terraview-\(snapshot.project.id.uuidString.prefix(8).lowercased())"
        switch format {
        case .projectJSON:
            return ExportArtifact(fileName: name + ".atlas.json", contentType: "application/json",
                                  data: try AtlasJSON.encode(snapshot, pretty: true),
                                  warnings: snapshot.scans.isEmpty ? [] : ["JSON содержит метаданные и ссылки на исходники. Файлы съемки необходимо скопировать отдельно."])
        case .geoJSON:
            guard snapshot.project.coordinateReference == .wgs84 else { throw AtlasExportError.requiresGeographicCoordinates }
            let collection = GeoCollection(features: try snapshot.features.map { feature in
                guard case let .geographicPolygon(polygon) = feature.geometry else { throw AtlasExportError.requiresGeographicCoordinates }
                return GeoFeature(id: feature.id.uuidString,
                                  geometry: GeoGeometry(coordinates: geographicRings(polygon)),
                                  properties: GeoProperties(label: feature.label, category: feature.category.rawValue,
                                                            reviewStatus: feature.reviewStatus.rawValue, notes: feature.notes,
                                                            attributes: feature.attributes, projectID: feature.projectID.uuidString,
                                                            revision: feature.revision))
            })
            return ExportArtifact(fileName: name + ".geojson", contentType: "application/geo+json",
                                  data: try AtlasJSON.encode(collection, pretty: true),
                                  warnings: snapshot.floorPlans.isEmpty ? [] : ["Локальные обмеры экспортируются отдельными DXF-файлами и не включены в GeoJSON."])
        case .dxf:
            guard case .localMeters = snapshot.project.coordinateReference else { throw AtlasExportError.requiresLocalMetricCoordinates }
            for plan in snapshot.floorPlans {
                try PolygonGeometry.validate(plan, in: snapshot.project.coordinateReference)
            }
            return ExportArtifact(fileName: name + ".dxf", contentType: "application/dxf",
                                  data: Data(dxf(snapshot).utf8), warnings: ["DXF содержит 2D-контуры в метрах, названия и линии стен."])
        case .svg:
            return try vectorSVG(snapshot, fileName: name + ".svg")
        case .csv:
            return try metadataCSV(snapshot, fileName: name + ".csv")
        case .kml:
            return try geographicKML(snapshot, fileName: name + ".kml")
        }
    }

    /// Export one independent session in its actual metric frame, without claiming registration.
    public static func exportFloorPlan(_ plan: AtlasFloorPlan, format: ExportFormat = .dxf) throws -> ExportArtifact {
        let reference = CoordinateReference.localMeters(frameID: plan.frameID)
        try PolygonGeometry.validate(plan, in: reference)
        let project = AtlasProject(id: plan.projectID, name: plan.name, kind: .building, coordinateReference: reference)
        var artifact = try export(.init(project: project, floorPlans: [plan]), format: format)
        let suffix = artifact.fileName.firstIndex(of: ".").map { String(artifact.fileName[$0...]) } ?? ""
        artifact.fileName = "terraview-plan-\(plan.id.uuidString.prefix(8).lowercased())" + suffix
        artifact.warnings.append("Отдельный локальный обмер. Координаты относятся к этой сессии; единицы — метры.")
        return artifact
    }

    static func geographicRings(_ polygon: GeographicPolygon) -> [[[Double]]] {
        ([polygon.vertices] + polygon.holes).enumerated().map { index, ring in
            let signedArea = PolygonGeometry.signedArea(ring.map { MetricPoint2D(x: $0.longitude, y: $0.latitude) })
            let shouldReverse = index == 0 ? signedArea < 0 : signedArea > 0
            let ordered = shouldReverse ? Array(ring.reversed()) : ring
            return (ordered + [ordered[0]]).map { [$0.longitude, $0.latitude] }
        }
    }

    private static func dxf(_ snapshot: AtlasProjectSnapshot) -> String {
        var fields: [String] = []
        func pair(_ code: Int, _ value: String) { fields.append(String(code)); fields.append(value) }
        func number(_ value: Double) -> String { String(value == 0 ? 0 : value) }
        func polygon(_ polygon: MetricPolygon, layer: String) {
            for (index, ring) in ([polygon.vertices] + polygon.holes).enumerated() {
                pair(0, "LWPOLYLINE"); pair(100, "AcDbEntity"); pair(8, index == 0 ? layer : layer + "_HOLES")
                pair(100, "AcDbPolyline"); pair(90, String(ring.count)); pair(70, "1")
                for point in ring { pair(10, number(point.x)); pair(20, number(point.y)) }
            }
        }
        func text(_ label: String, at point: MetricPoint2D, layer: String) {
            guard !label.isEmpty else { return }
            pair(0, "TEXT"); pair(100, "AcDbEntity"); pair(8, layer); pair(100, "AcDbText")
            pair(10, number(point.x)); pair(20, number(point.y)); pair(30, "0")
            pair(40, "0.15"); pair(1, dxfText(label)); pair(100, "AcDbText")
        }
        pair(999, "TerraView - local metric 2D export")
        pair(0, "SECTION"); pair(2, "HEADER")
        pair(9, "$ACADVER"); pair(1, "AC1015")
        pair(9, "$DWGCODEPAGE"); pair(3, "ANSI_1252")
        pair(9, "$INSUNITS"); pair(70, "6")
        pair(9, "$MEASUREMENT"); pair(70, "1")
        pair(0, "ENDSEC"); pair(0, "SECTION"); pair(2, "ENTITIES")
        for feature in snapshot.features {
            guard case let .metricPolygon(boundary) = feature.geometry else { continue }
            let layer = "FEATURE_" + feature.category.rawValue.uppercased()
            polygon(boundary, layer: layer)
            if let first = boundary.vertices.first { text(feature.label, at: first, layer: layer + "_LABELS") }
        }
        for plan in snapshot.floorPlans {
            let floor = plan.floorIndex >= 0 ? "FLOOR_\(plan.floorIndex)" : "BASEMENT_\(String(plan.floorIndex).dropFirst())"
            for room in plan.rooms {
                polygon(room.boundary, layer: floor + "_ROOMS")
                if let first = room.boundary.vertices.first { text(room.name, at: first, layer: floor + "_LABELS") }
            }
            for wall in plan.walls {
                pair(0, "LINE"); pair(100, "AcDbEntity"); pair(8, floor + "_WALLS"); pair(100, "AcDbLine")
                pair(10, number(wall.start.x)); pair(20, number(wall.start.y)); pair(30, "0")
                pair(11, number(wall.end.x)); pair(21, number(wall.end.y)); pair(31, "0")
            }
        }
        pair(0, "ENDSEC"); pair(0, "EOF")
        return fields.joined(separator: "\n") + "\n"
    }

    /// R2000 text is ASCII with UTF-16 escape sequences. Newlines cannot inject group codes.
    private static func dxfText(_ text: String) -> String {
        text.utf16.map { unit in
            if unit >= 32, unit < 127, unit != 92 { return String(UnicodeScalar(unit)!) }
            if unit < 32 { return " " }
            return String(format: "\\U+%04X", unit)
        }.joined()
    }
}

private struct GeoCollection: Encodable {
    let type = "FeatureCollection"
    let features: [GeoFeature]
}
private struct GeoFeature: Encodable {
    let type = "Feature"
    let id: String
    let geometry: GeoGeometry
    let properties: GeoProperties
}
private struct GeoGeometry: Encodable {
    let type = "Polygon"
    let coordinates: [[[Double]]]
}
private struct GeoProperties: Encodable {
    let label: String
    let category: String
    let reviewStatus: String
    let notes: String
    let attributes: [String: String]
    let projectID: String
    let revision: Int64
}
