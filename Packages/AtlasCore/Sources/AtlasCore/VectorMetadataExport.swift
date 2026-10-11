import Foundation

extension AtlasExporter {
    /// SVG drawing coordinates are metres; the page is laid out at 1:100.
    /// SVG's downward Y axis is explicitly inverted without changing the stored frame.
    static func vectorSVG(_ snapshot: AtlasProjectSnapshot, fileName: String) throws -> ExportArtifact {
        guard case let .localMeters(frameID) = snapshot.project.coordinateReference else {
            throw AtlasExportError.requiresLocalMetricCoordinates
        }
        for plan in snapshot.floorPlans {
            try PolygonGeometry.validate(plan, in: snapshot.project.coordinateReference)
        }
        var points: [MetricPoint2D] = []
        var maximumThickness = 0.08
        for feature in snapshot.features {
            switch feature.geometry {
            case let .metricPoint(_, point): points.append(point)
            case let .metricPolyline(line): points.append(contentsOf: line.vertices)
            case let .metricPolygon(polygon):
                points.append(contentsOf: polygon.vertices)
                points.append(contentsOf: polygon.holes.flatMap { $0 })
            case .geographicPoint, .geographicPolyline, .geographicPolygon: break
            }
        }
        for plan in snapshot.floorPlans {
            for room in plan.rooms {
                points.append(contentsOf: room.boundary.vertices)
                points.append(contentsOf: room.boundary.holes.flatMap { $0 })
            }
            for wall in plan.walls {
                points.append(contentsOf: [wall.start, wall.end])
                maximumThickness = max(maximumThickness, wall.thicknessMeters ?? 0.08)
            }
        }
        let padding = max(0.5, maximumThickness / 2 + 0.25)
        let minX = (points.map(\.x).min() ?? 0) - padding
        let maxX = (points.map(\.x).max() ?? 1) + padding
        let minY = -(points.map(\.y).max() ?? 1) - padding
        let maxY = -(points.map(\.y).min() ?? 0) + padding
        let width = maxX - minX, height = maxY - minY
        guard [minX, minY, width, height, width * 10, height * 10].allSatisfy(\.isFinite) else {
            throw GeometryError.nonFiniteCoordinate
        }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(exportNumber(width * 10))mm\" height=\"\(exportNumber(height * 10))mm\" viewBox=\"\(exportNumber(minX)) \(exportNumber(minY)) \(exportNumber(width)) \(exportNumber(height))\" data-generator=\"TerraView\" data-units=\"metres\" data-scale=\"1:100\" data-frame-id=\"\(frameID.uuidString)\">\n"
        xml += "<title>\(exportXML("TerraView — " + snapshot.project.name))</title>\n"
        xml += "<desc>Локальные метры; масштаб страницы 1:100. SVG X = local X, SVG Y = −local Y. Системы AR не совмещены автоматически.</desc>\n"
        func label(_ label: String, at point: MetricPoint2D) -> String {
            guard !label.isEmpty else { return "" }
            return "<text x=\"\(exportNumber(point.x))\" y=\"\(exportNumber(-point.y - 0.12))\" font-family=\"sans-serif\" font-size=\"0.18\" fill=\"#173731\">\(exportXML(label))</text>"
        }
        func polygon(_ boundary: MetricPolygon, id: UUID, label: String, category: String) -> String {
            let path = ([boundary.vertices] + boundary.holes).map { ring in
                ring.enumerated().map { index, point in
                    "\(index == 0 ? "M" : "L") \(exportNumber(point.x)) \(exportNumber(-point.y))"
                }.joined(separator: " ") + " Z"
            }.joined(separator: " ")
            var element = "<g id=\"polygon-\(id.uuidString)\" data-category=\"\(exportXML(category))\"><title>\(exportXML(label))</title>"
            element += "<path d=\"\(path)\" fill=\"#cce9e5\" fill-opacity=\"0.35\" fill-rule=\"evenodd\" stroke=\"#126c63\" stroke-width=\"0.035\"/>"
            if let first = boundary.vertices.first, !label.isEmpty {
                element += "<text x=\"\(exportNumber(first.x))\" y=\"\(exportNumber(-first.y - 0.12))\" font-family=\"sans-serif\" font-size=\"0.18\" fill=\"#173731\">\(exportXML(label))</text>"
            }
            return element + "</g>\n"
        }
        for feature in snapshot.features {
            switch feature.geometry {
            case let .metricPoint(_, point):
                xml += "<g id=\"point-\(feature.id.uuidString)\" data-category=\"\(exportXML(feature.category.rawValue))\"><title>\(exportXML(feature.label))</title>"
                // The circle is a visible marker; its centre is the actual stored point.
                xml += "<circle cx=\"\(exportNumber(point.x))\" cy=\"\(exportNumber(-point.y))\" r=\"0.08\" fill=\"#126c63\"/>"
                xml += label(feature.label, at: point) + "</g>\n"
            case let .metricPolyline(line):
                xml += "<g id=\"line-\(feature.id.uuidString)\" data-category=\"\(exportXML(feature.category.rawValue))\"><title>\(exportXML(feature.label))</title>"
                let coordinates = line.vertices.map { "\(exportNumber($0.x)),\(exportNumber(-$0.y))" }.joined(separator: " ")
                xml += "<polyline points=\"\(coordinates)\" fill=\"none\" stroke=\"#126c63\" stroke-width=\"0.035\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
                if let first = line.vertices.first { xml += label(feature.label, at: first) }
                xml += "</g>\n"
            case let .metricPolygon(boundary):
                xml += polygon(boundary, id: feature.id, label: feature.label, category: feature.category.rawValue)
            case .geographicPoint, .geographicPolyline, .geographicPolygon: break
            }
        }
        for plan in snapshot.floorPlans {
            xml += "<g id=\"plan-\(plan.id.uuidString)\" data-floor-index=\"\(plan.floorIndex)\"><title>\(exportXML(plan.name))</title>\n"
            for room in plan.rooms {
                xml += polygon(room.boundary, id: room.id, label: room.name, category: "room")
            }
            for wall in plan.walls {
                xml += "<line id=\"wall-\(wall.id.uuidString)\" x1=\"\(exportNumber(wall.start.x))\" y1=\"\(exportNumber(-wall.start.y))\" x2=\"\(exportNumber(wall.end.x))\" y2=\"\(exportNumber(-wall.end.y))\" stroke=\"#173731\" stroke-width=\"\(exportNumber(wall.thicknessMeters ?? 0.08))\" stroke-linecap=\"butt\"/>\n"
            }
            xml += "</g>\n"
        }
        xml += "</svg>\n"
        var warnings = ["SVG — векторная 2D-схема: координаты в метрах, страница 1:100. Размеры перед строительством необходимо проверить."]
        if points.isEmpty { warnings.append("В проекте пока нет локальных точек, линий, контуров, комнат или стен для отображения.") }
        if Set(snapshot.floorPlans.map(\.floorIndex)).count > 1 {
            warnings.append("Планы разных этажей показаны отдельными группами в общей локальной системе; слои могут перекрываться.")
        }
        if !snapshot.scans.isEmpty { warnings.append("Исходные фотографии и 3D-модели не вложены в SVG.") }
        return .init(fileName: fileName, contentType: "image/svg+xml", data: Data(xml.utf8), warnings: warnings)
    }

    static func metadataCSV(_ snapshot: AtlasProjectSnapshot, fileName: String) throws -> ExportArtifact {
        try validateExportDates(snapshot)
        var table = ExportCSVTable()
        var geometryWarnings: [String] = []
        let project = snapshot.project
        var projectRow = ExportCSVRow(kind: "project", id: project.id, projectID: project.id)
        projectRow.text("name", project.name); projectRow.text("category", project.kind.rawValue)
        projectRow.text("notes", project.notes); projectRow.number("revision", project.revision)
        projectRow.date("created_at_utc", project.createdAt)
        projectRow.date("updated_at_utc", project.updatedAt)
        projectRow.reference(project.coordinateReference)
        projectRow.text("metadata_json", try exportJSONString(project))
        table.rows.append(projectRow)
        for feature in snapshot.features {
            var row = ExportCSVRow(kind: "feature", id: feature.id, projectID: project.id)
            row.text("name", feature.label); row.text("category", feature.category.rawValue)
            row.text("status", feature.reviewStatus.rawValue); row.number("revision", feature.revision)
            row.text("notes", feature.notes); row.reference(feature.geometry.coordinateReference)
            row.text("geometry_json", try exportJSONString(feature.geometry))
            row.text("attributes_json", try exportJSONString(feature.attributes))
            switch feature.geometry {
            case let .metricPoint(_, point):
                row.text("geometry_type", "Point"); row.number("x_m", point.x); row.number("y_m", point.y)
            case let .geographicPoint(point):
                row.text("geometry_type", "Point"); row.number("longitude", point.longitude); row.number("latitude", point.latitude)
            case let .metricPolyline(line):
                row.text("geometry_type", "LineString")
                row.number("length_m", try PolygonGeometry.length(of: line))
                row.text("length_method", "local_planar_metres")
            case let .geographicPolyline(line):
                row.text("geometry_type", "LineString")
                do {
                    row.number("length_m", try GeographicMetricGeometry.length(of: line))
                    row.text("length_method", "WGS84_local_tangent_approximation")
                } catch GeographicMetricError.projectionExtentExceeded {
                    geometryWarnings.append("Длина WGS84-линии \(feature.id.uuidString) не рассчитана: объект выходит за допустимую область локальной проекции. Координаты сохранены в geometry_json.")
                } catch GeographicMetricError.invalidProjection {
                    geometryWarnings.append("Длина WGS84-линии \(feature.id.uuidString) не рассчитана: локальная проекция недоступна. Координаты сохранены в geometry_json.")
                }
            case let .metricPolygon(boundary):
                row.text("geometry_type", "Polygon")
                row.number("area_m2", try PolygonGeometry.area(of: boundary))
                row.number("perimeter_m", try PolygonGeometry.perimeter(of: boundary))
            case .geographicPolygon: row.text("geometry_type", "Polygon")
            }
            row.text("metadata_json", try exportJSONString(feature))
            table.rows.append(row)
        }
        for plan in snapshot.floorPlans {
            var row = ExportCSVRow(kind: "floorPlan", id: plan.id, projectID: project.id)
            row.text("name", plan.name); row.number("revision", plan.revision)
            row.reference(.localMeters(frameID: plan.frameID)); row.number("floor_index", plan.floorIndex)
            row.text("metadata_json", try exportJSONString(plan))
            table.rows.append(row)
            for room in plan.rooms {
                var roomRow = ExportCSVRow(kind: "room", id: room.id, projectID: project.id, parentID: plan.id)
                roomRow.text("name", room.name); roomRow.reference(.localMeters(frameID: plan.frameID))
                roomRow.number("floor_index", plan.floorIndex)
                roomRow.number("area_m2", try PolygonGeometry.area(of: room.boundary))
                roomRow.number("perimeter_m", try PolygonGeometry.perimeter(of: room.boundary))
                roomRow.text("geometry_json", try exportJSONString(room.boundary))
                roomRow.text("metadata_json", try exportJSONString(room))
                table.rows.append(roomRow)
            }
            for wall in plan.walls {
                var wallRow = ExportCSVRow(kind: "wall", id: wall.id, projectID: project.id, parentID: plan.id)
                wallRow.reference(.localMeters(frameID: plan.frameID)); wallRow.number("floor_index", plan.floorIndex)
                wallRow.number("length_m", hypot(wall.end.x - wall.start.x, wall.end.y - wall.start.y))
                wallRow.number("height_m", wall.heightMeters); wallRow.number("thickness_m", wall.thicknessMeters)
                wallRow.text("geometry_json", try exportJSONString([wall.start, wall.end]))
                wallRow.text("metadata_json", try exportJSONString(wall))
                table.rows.append(wallRow)
            }
        }
        for scan in snapshot.scans {
            var row = ExportCSVRow(kind: "scan", id: scan.id, projectID: project.id)
            row.text("source", scan.source.rawValue); row.text("status", scan.status.rawValue)
            row.reference(.localMeters(frameID: scan.frameID)); row.number("revision", scan.revision)
            row.date("created_at_utc", scan.createdAt)
            // This model records the session's creation. It has no trustworthy original
            // shutter/import timestamp for imported/photogrammetry image assets.
            if scan.source == .liDAR || scan.source == .roomPlan { row.date("captured_at_utc", scan.createdAt) }
            try row.geotag(scan.geoTag)
            row.text("metadata_json", try exportJSONString(scan))
            table.rows.append(row)
            for asset in scan.assets {
                var assetRow = ExportCSVRow(kind: "sourceAsset", id: asset.id, projectID: project.id, parentID: scan.id)
                assetRow.text("source", scan.source.rawValue)
                assetRow.text("relative_path", asset.relativePath); assetRow.text("asset_kind", asset.kind.rawValue)
                assetRow.number("bytes", asset.byteCount); assetRow.text("sha256", asset.sha256)
                assetRow.reference(.localMeters(frameID: scan.frameID))
                assetRow.text("metadata_json", try exportJSONString(asset))
                table.rows.append(assetRow)
            }
        }
        for record in snapshot.measurements ?? [] {
            var row = ExportCSVRow(kind: "measurement", id: record.id, projectID: project.id)
            row.text("name", record.label); row.text("category", record.kind.rawValue)
            row.text("source", record.source.rawValue); row.number("revision", record.revision)
            row.number("length_m", record.effectiveMeters); row.number("original_length_m", record.originalMeters)
            row.date("created_at_utc", record.createdAt); row.date("captured_at_utc", record.createdAt)
            if let frameID = record.frameID { row.reference(.localMeters(frameID: frameID)) }
            if let start = record.start, let end = record.end {
                row.text("geometry_json", try exportJSONString([start, end]))
            }
            row.text("metadata_json", try exportJSONString(record))
            table.rows.append(row)
        }
        var artifact = table.artifact(fileName: fileName)
        artifact.warnings.append(contentsOf: geometryWarnings)
        if snapshot.features.contains(where: { feature in
            if case .geographicPolyline = feature.geometry { return true }
            return false
        }) {
            artifact.warnings.append("Длины WGS84-линий — приближённые метры локальной касательной проекции эллипсоида, а не расстояния в градусах или геодезические измерения. Метод указан в length_method.")
        }
        return artifact
    }

    static func geographicKML(_ snapshot: AtlasProjectSnapshot, fileName: String) throws -> ExportArtifact {
        try validateExportDates(snapshot)
        let fixes = snapshot.scans.compactMap { scan in scan.geoTag?.effectiveFix.map { (scan, $0) } }
        guard snapshot.project.coordinateReference == .wgs84 || !fixes.isEmpty else {
            throw AtlasExportError.requiresGeographicCoordinates
        }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document>\n"
        xml += "<name>\(exportXML("TerraView — " + snapshot.project.name))</name>\n"
        xml += kmlData(["generator": "TerraView", "project_id": snapshot.project.id.uuidString,
            "coordinate_system": "WGS84", "source_project_json": try exportJSONString(snapshot.project)])
        for feature in snapshot.features {
            guard feature.geometry.coordinateReference == .wgs84 else { continue }
            xml += "<Placemark id=\"feature-\(feature.id.uuidString)\"><name>\(exportXML(feature.label))</name><description>\(exportXML(feature.notes))</description>\n"
            xml += kmlData(["category": feature.category.rawValue, "review_status": feature.reviewStatus.rawValue,
                "project_id": feature.projectID.uuidString, "revision": String(feature.revision),
                "attributes_json": try exportJSONString(feature.attributes), "geometry_json": try exportJSONString(feature.geometry)])
            switch feature.geometry {
            case let .geographicPoint(point):
                xml += "<Point><altitudeMode>clampToGround</altitudeMode><coordinates>\(exportNumber(point.longitude)),\(exportNumber(point.latitude))</coordinates></Point>"
            case let .geographicPolyline(line):
                let coordinates = line.vertices.map { "\(exportNumber($0.longitude)),\(exportNumber($0.latitude))" }.joined(separator: " ")
                xml += "<LineString><tessellate>1</tessellate><altitudeMode>clampToGround</altitudeMode><coordinates>\(coordinates)</coordinates></LineString>"
            case let .geographicPolygon(polygon):
                xml += "<Polygon><altitudeMode>clampToGround</altitudeMode>"
                for (index, ring) in geographicRings(polygon).enumerated() {
                    let boundary = index == 0 ? "outerBoundaryIs" : "innerBoundaryIs"
                    let coordinates = ring.map { "\(exportNumber($0[0])),\(exportNumber($0[1]))" }.joined(separator: " ")
                    xml += "<\(boundary)><LinearRing><coordinates>\(coordinates)</coordinates></LinearRing></\(boundary)>"
                }
                xml += "</Polygon>"
            case .metricPoint, .metricPolyline, .metricPolygon: break
            }
            xml += "</Placemark>\n"
        }
        for (scan, fix) in fixes {
            xml += "<Placemark id=\"scan-\(scan.id.uuidString)\"><name>\(exportXML(scan.source.rawValue + " — " + String(scan.id.uuidString.prefix(8))))</name>"
            xml += "<TimeStamp><when>\(exportDate(fix.observedAt))</when></TimeStamp>"
            var data = ["project_id": scan.projectID.uuidString, "source": scan.source.rawValue,
                "status": scan.status.rawValue, "frame_id": scan.frameID.uuidString,
                "created_at_utc": exportDate(scan.createdAt), "location_source": fix.source.rawValue,
                "observed_at_utc": exportDate(fix.observedAt), "location_simulated": String(fix.isSimulated),
                "geotag_json": try exportJSONString(scan.geoTag)]
            if let altitude = fix.altitudeMeters { data["altitude_m"] = exportNumber(altitude) }
            if let accuracy = fix.horizontalAccuracyMeters { data["horizontal_accuracy_m"] = exportNumber(accuracy) }
            xml += kmlData(data)
            // A geotag does not establish the scan frame or an altitude datum.
            // Keep observed altitude in metadata; do not lift a model to a guessed height.
            xml += "<Point><altitudeMode>clampToGround</altitudeMode><coordinates>\(exportNumber(fix.coordinate.longitude)),\(exportNumber(fix.coordinate.latitude))</coordinates></Point></Placemark>\n"
        }
        xml += "</Document></kml>\n"
        var warnings = ["KML содержит WGS84-точки, открытые линии, контуры и геометки. Высота сохранена в метаданных; геометрия показана на поверхности. Локальные 3D-модели не геопривязаны."]
        if snapshot.project.coordinateReference != .wgs84, !snapshot.features.isEmpty {
            warnings.append("Локальные полигоны, линии и точки не включены: \(snapshot.features.count). Экспортируйте их в SVG/DXF или выполните явную геопривязку.")
        }
        if !snapshot.floorPlans.isEmpty { warnings.append("Локальные планы не включены в KML: \(snapshot.floorPlans.count).") }
        let missing = snapshot.scans.count - fixes.count
        if missing > 0 { warnings.append("Съёмки без геометки пропущены: \(missing).") }
        return .init(fileName: fileName, contentType: "application/vnd.google-earth.kml+xml", data: Data(xml.utf8), warnings: warnings)
    }
}

public extension AtlasExporter {
    /// The immutable transfer manifest supplies optional original capture/import times
    /// for photo materials absent from the legacy project snapshot schema.
    static func exportMaterialMetadata(_ manifest: FieldTransferManifest) throws -> ExportArtifact {
        try manifest.validate()
        var artifact = try exportMaterialMetadata(projectID: manifest.projectID, projectName: manifest.title,
            materials: manifest.materials, assets: manifest.assets)
        artifact.fileName = "terraview-materials-\(manifest.id.uuidString.prefix(8).lowercased()).csv"
        return artifact
    }

    /// Export a local delivery passport without an account, destination or package
    /// preparation date. Empty capture times remain unknown even after import.
    static func exportMaterialMetadata(projectID: UUID, projectName: String,
                                       materials: [FieldMaterial], assets: [FieldAsset]) throws -> ExportArtifact {
        guard materials.count <= 50_000, assets.count <= 50_000 else { throw FieldTransferError.invalidManifest }
        var materialIDs = Set<UUID>(), assetIDs = Set<UUID>(), paths = Set<String>()
        for material in materials {
            guard materialIDs.insert(material.id).inserted,
                  material.endedAt == nil || material.capturedAt != nil else { throw FieldTransferError.invalidManifest }
            if let start = material.capturedAt, let end = material.endedAt, end < start {
                throw FieldTransferError.invalidManifest
            }
            for date in [material.capturedAt, material.endedAt, material.importedAt].compactMap({ $0 }) {
                try validateExportDate(date)
            }
            try validateExportTagDates(material.geoTag)
            if let tag = material.geoTag { try GeoTagPolicy.validate(tag) }
        }
        for asset in assets {
            try FieldTransferPaths.validate(relativePath: asset.relativePath)
            guard materialIDs.contains(asset.materialID), assetIDs.insert(asset.id).inserted,
                  paths.insert(asset.relativePath).inserted, asset.byteCount >= 0,
                  FieldTransferDigest.isSHA256(asset.sha256),
                  asset.byteCount != 0 || asset.sha256 == FieldTransferDigest.sha256(Data()) else {
                throw FieldTransferError.invalidManifest
            }
        }
        var table = ExportCSVTable()
        var project = ExportCSVRow(kind: "project", id: projectID, projectID: projectID)
        project.text("name", projectName)
        project.text("metadata_json", try exportJSONString(["id": projectID.uuidString, "name": projectName]))
        table.rows.append(project)
        for material in materials {
            var row = ExportCSVRow(kind: "material", id: material.id, projectID: projectID)
            row.text("source_entity_id", material.sourceEntityID.uuidString)
            row.text("category", material.kind.rawValue)
            row.date("captured_at_utc", material.capturedAt); row.date("ended_at_utc", material.endedAt)
            row.date("imported_at_utc", material.importedAt)
            if let frameID = material.frameID { row.reference(.localMeters(frameID: frameID)) }
            try row.geotag(material.geoTag)
            row.text("metadata_json", try exportJSONString(material))
            table.rows.append(row)
        }
        for asset in assets {
            var row = ExportCSVRow(kind: "sourceAsset", id: asset.id, projectID: projectID, parentID: asset.materialID)
            row.text("relative_path", asset.relativePath); row.text("asset_kind", asset.kind.rawValue)
            row.number("bytes", asset.byteCount); row.text("sha256", asset.sha256)
            row.text("metadata_json", try exportJSONString(asset))
            table.rows.append(row)
        }
        return table.artifact(fileName: "terraview-materials-\(projectID.uuidString.prefix(8).lowercased()).csv")
    }
}

private func exportNumber(_ number: Double) -> String { String(number == 0 ? 0 : number) }
private func validateExportDate(_ date: Date) throws {
    let seconds = date.timeIntervalSince1970
    guard seconds.isFinite, seconds >= -62_135_596_800, seconds < 253_402_300_800 else {
        throw AtlasExportError.invalidDate
    }
}
private func validateExportTagDates(_ tag: GeoTag?) throws {
    if let date = tag?.automaticFix?.observedAt { try validateExportDate(date) }
    for correction in tag?.corrections ?? [] { try validateExportDate(correction.changedAt) }
}
private func validateExportDates(_ snapshot: AtlasProjectSnapshot) throws {
    try validateExportDate(snapshot.project.createdAt); try validateExportDate(snapshot.project.updatedAt)
    for scan in snapshot.scans {
        try validateExportDate(scan.createdAt); try validateExportTagDates(scan.geoTag)
    }
    for measurement in snapshot.measurements ?? [] {
        try validateExportDate(measurement.createdAt)
        for correction in measurement.corrections { try validateExportDate(correction.changedAt) }
    }
}
private func exportDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
private func exportJSONString<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try AtlasJSON.encode(value), as: UTF8.self)
}

/// XML 1.0 cannot represent certain control characters, even as numeric entities.
/// Replace them visibly rather than allowing malformed documents or injected markup.
private func exportXML(_ text: String) -> String {
    text.unicodeScalars.map { scalar -> String in
        let value = scalar.value
        guard value == 9 || value == 10 || value == 13 || (0x20...0xd7ff).contains(value)
                || (0xe000...0xfffd).contains(value) || (0x10000...0x10ffff).contains(value) else { return "�" }
        switch scalar {
        case "&": return "&amp;"
        case "<": return "&lt;"
        case ">": return "&gt;"
        case "\"": return "&quot;"
        case "'": return "&apos;"
        default: return String(scalar)
        }
    }.joined()
}
private func kmlData(_ values: [String: String]) -> String {
    "<ExtendedData>" + values.keys.sorted().map { key in
        "<Data name=\"\(exportXML(key))\"><value>\(exportXML(values[key] ?? ""))</value></Data>"
    }.joined() + "</ExtendedData>\n"
}

private struct ExportCSVRow {
    var fields: [String: String] = [:]
    init(kind: String, id: UUID, projectID: UUID, parentID: UUID? = nil) {
        text("generator", "TerraView")
        text("record_type", kind); text("id", id.uuidString); text("project_id", projectID.uuidString)
        text("parent_id", parentID?.uuidString)
    }
    mutating func text(_ key: String, _ value: String?) {
        guard let value else { return }
        // Spreadsheet applications execute formulas even inside quoted CSV cells.
        // Numeric fields use number() and retain genuine negative numeric values.
        let first = value.drop(while: { $0.isWhitespace }).first
        fields[key] = first.map { "=+-@".contains($0) } == true ? "'" + value : value
    }
    mutating func number<T: BinaryInteger>(_ key: String, _ value: T) { fields[key] = String(value) }
    mutating func number(_ key: String, _ value: Double?) {
        if let value { fields[key] = exportNumber(value) }
    }
    mutating func date(_ key: String, _ value: Date?) {
        if let value { fields[key] = exportDate(value) }
    }
    mutating func reference(_ reference: CoordinateReference) {
        switch reference {
        case let .localMeters(frameID): text("coordinate_system", "local_metres"); text("frame_id", frameID.uuidString)
        case .wgs84: text("coordinate_system", "WGS84_degrees")
        }
    }
    mutating func geotag(_ tag: GeoTag?) throws {
        guard let tag else { return }
        try GeoTagPolicy.validate(tag)
        if let effective = tag.effectiveFix {
            number("longitude", effective.coordinate.longitude); number("latitude", effective.coordinate.latitude)
            number("altitude_m", effective.altitudeMeters); number("horizontal_accuracy_m", effective.horizontalAccuracyMeters)
            date("observed_at_utc", effective.observedAt); text("location_source", effective.source.rawValue)
            text("location_simulated", String(effective.isSimulated))
        }
        if let original = tag.automaticFix {
            number("original_longitude", original.coordinate.longitude); number("original_latitude", original.coordinate.latitude)
            date("original_observed_at_utc", original.observedAt); text("original_location_source", original.source.rawValue)
        }
        text("geotag_json", try exportJSONString(tag))
    }
}
private struct ExportCSVTable {
    var rows: [ExportCSVRow] = []
    private static let columns = ["generator", "record_type", "id", "project_id", "parent_id", "source_entity_id", "name", "category", "source", "status", "revision",
        "coordinate_system", "frame_id", "floor_index", "created_at_utc", "updated_at_utc", "captured_at_utc", "ended_at_utc", "imported_at_utc",
        "observed_at_utc", "longitude", "latitude", "altitude_m", "horizontal_accuracy_m", "location_source", "location_simulated",
        "original_longitude", "original_latitude", "original_observed_at_utc", "original_location_source", "geotag_json", "geometry_json",
        "area_m2", "perimeter_m", "length_m", "original_length_m", "height_m", "thickness_m", "relative_path", "asset_kind", "bytes", "sha256",
        "attributes_json", "notes", "metadata_json", "geometry_type", "length_method", "x_m", "y_m"]
    func artifact(fileName: String) -> ExportArtifact {
        func csv(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = [Self.columns.map(csv).joined(separator: ",")] + rows.map { row in
            Self.columns.map { csv(row.fields[$0] ?? "") }.joined(separator: ",")
        }
        return .init(fileName: fileName, contentType: "text/csv; charset=utf-8",
            data: Data(("\u{feff}" + lines.joined(separator: "\r\n") + "\r\n").utf8),
            warnings: ["CSV содержит метаданные, а не исходные файлы. Пустые ячейки означают неизвестные значения. Геометки WGS84 не преобразуют локальные координаты в карту.",
                "Текст с начальным =, +, − или @ защищён апострофом от выполнения формул; исходные значения остаются в metadata_json. Даты указаны в UTC."])
    }
}
