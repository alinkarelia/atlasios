import Foundation

extension AtlasExporter {
    /// GPS tracks remain separate at pauses/rejections/gaps. Standard GPX points
    /// contain accepted observations; extensions retain raw rejected observations.
    public static func exportSurveyTrack(_ session: CemeterySurveySession, name: String = "GPS-съёмка") throws -> ExportArtifact {
        try session.validateCheckpoint()
        var xml = gpxHeader()
        let rejected = session.observations.filter { $0.decision.status == .rejected }
        xml += "<metadata><name>\(gpxXML(name))</name><time>\(gpxDate(session.startedAt))</time>"
        xml += gpxExtensions(["session_id": session.id.uuidString, "policy_json": try gpxJSON(session.policy),
            "rejected_observations_json": try gpxJSON(rejected), "confirmations_json": try gpxJSON(session.confirmations),
            "state": session.state.rawValue]) + "</metadata>\n"
        for (index, segment) in session.segments.enumerated() {
            xml += "<trk><name>\(gpxXML(name)) — \(index + 1)</name><type>GPS observation</type>"
            xml += gpxExtensions(["segment_id": segment.id.uuidString, "break_reason": segment.startReason.rawValue])
            xml += "<trkseg>"
            for sample in segment.samples {
                var fields = ["sample_id": sample.id.uuidString, "horizontal_accuracy_m": String(sample.horizontalAccuracyMeters),
                              "is_simulated": String(sample.isSimulated)]
                if let altitude = sample.altitudeMeters { fields["altitude_m"] = String(altitude) }
                xml += gpxPoint("trkpt", coordinate: sample.coordinate, time: sample.capturedAt, extensions: fields)
            }
            xml += "</trkseg></trk>\n"
        }
        xml += "</gpx>\n"
        return .init(fileName: "terraview-gps-\(session.id.uuidString.prefix(8).lowercased()).gpx",
                     contentType: "application/gpx+xml", data: Data(xml.utf8),
                     warnings: ["GPX содержит принятые GPS-точки с исходным временем и точностью. Участки после пауз, разрывов и отклонённых точек не соединены.",
                                "Отклонённые наблюдения и подтверждённые контуры сохранены в расширениях TerraView. Высота — исходное наблюдение с неизвестной вертикальной системой, а не геодезическая отметка."])
    }

    static func geographicGPX(_ snapshot: AtlasProjectSnapshot, fileName: String) throws -> ExportArtifact {
        for date in [snapshot.project.createdAt, snapshot.project.updatedAt] + snapshot.scans.map(\.createdAt) {
            guard date.timeIntervalSinceReferenceDate.isFinite else { throw AtlasExportError.invalidDate }
        }
        let geographic = snapshot.features.filter { $0.geometry.coordinateReference == .wgs84 }
        let fixes = snapshot.scans.compactMap { scan in scan.geoTag?.effectiveFix.map { (scan, $0) } }
        guard snapshot.project.coordinateReference == .wgs84 || !fixes.isEmpty else { throw AtlasExportError.requiresGeographicCoordinates }
        var xml = gpxHeader()
        xml += "<metadata><name>\(gpxXML(snapshot.project.name))</name>"
        xml += gpxExtensions(["project_id": snapshot.project.id.uuidString, "coordinate_system": "WGS84",
                              "project_json": try gpxJSON(snapshot.project)]) + "</metadata>\n"
        // GPX orders waypoints before tracks; local frame points are never GPS waypoints.
        for feature in geographic {
            if case let .geographicPoint(point) = feature.geometry {
                xml += gpxPoint("wpt", coordinate: point, name: feature.label, description: feature.notes,
                                type: feature.category.rawValue, extensions: ["feature_json": try gpxJSON(feature)])
            }
        }
        for (scan, fix) in fixes {
            var fields = ["scan_id": scan.id.uuidString, "frame_id": scan.frameID.uuidString, "geotag_json": try gpxJSON(scan.geoTag),
                          "location_source": fix.source.rawValue, "is_simulated": String(fix.isSimulated)]
            if let accuracy = fix.horizontalAccuracyMeters { fields["horizontal_accuracy_m"] = String(accuracy) }
            if let altitude = fix.altitudeMeters { fields["altitude_m"] = String(altitude) }
            xml += gpxPoint("wpt", coordinate: fix.coordinate, time: fix.observedAt, name: "Съёмка — \(scan.id.uuidString.prefix(8))",
                            type: "scan geotag", extensions: fields)
        }
        for feature in geographic {
            let rings: [[GeographicCoordinate]]
            let boundary: Bool
            switch feature.geometry {
            case let .geographicPolyline(line): rings = [line.vertices]; boundary = false
            case let .geographicPolygon(polygon): rings = [polygon.vertices] + polygon.holes; boundary = true
            default: continue
            }
            for (index, ring) in rings.enumerated() {
                let role = boundary ? (index == 0 ? "exterior_boundary" : "hole_boundary") : "open_line"
                xml += "<trk><name>\(gpxXML(feature.label))</name><desc>\(gpxXML(feature.notes))</desc><type>\(role)</type>"
                xml += gpxExtensions(["feature_id": feature.id.uuidString, "ring_role": role, "ring_index": String(index),
                                      "feature_json": try gpxJSON(feature)]) + "<trkseg>"
                for point in boundary ? ring + [ring[0]] : ring { xml += gpxPoint("trkpt", coordinate: point) }
                xml += "</trkseg></trk>\n"
            }
        }
        xml += "</gpx>\n"
        var warnings = ["GPX содержит WGS84-точки и отдельные линии. Границы полигонов и отверстий — отдельные замкнутые треки; полная геометрия и атрибуты сохранены в расширениях TerraView.",
                        "Время неизвестных точек не выдумывается. Геометка не совмещает локальную AR-модель с картой; высота сохранена только в метаданных."]
        let skipped = snapshot.features.count - geographic.count
        if skipped > 0 { warnings.append("Локальные объекты не включены в GPX: \(skipped). Для них доступны SVG/DXF.") }
        if !snapshot.floorPlans.isEmpty { warnings.append("Локальные планы не включены в GPX: \(snapshot.floorPlans.count).") }
        if snapshot.scans.count > fixes.count { warnings.append("Съёмки без геометки не включены в GPX: \(snapshot.scans.count - fixes.count).") }
        return .init(fileName: fileName, contentType: "application/gpx+xml", data: Data(xml.utf8), warnings: warnings)
    }
}

private func gpxHeader() -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"TerraView\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:tv=\"urn:terraview:field-survey:1\">\n"
}
private func gpxPoint(_ element: String, coordinate: GeographicCoordinate, time: Date? = nil, name: String? = nil,
                      description: String? = nil, type: String? = nil, extensions: [String: String] = [:]) -> String {
    var xml = "<\(element) lat=\"\(coordinate.latitude)\" lon=\"\(coordinate.longitude)\">"
    if let time { xml += "<time>\(gpxDate(time))</time>" }
    if let name { xml += "<name>\(gpxXML(name))</name>" }
    if let description { xml += "<desc>\(gpxXML(description))</desc>" }
    if let type { xml += "<type>\(gpxXML(type))</type>" }
    xml += gpxExtensions(extensions)
    return xml + "</\(element)>\n"
}
private func gpxExtensions(_ fields: [String: String]) -> String {
    guard !fields.isEmpty else { return "" }
    return "<extensions>" + fields.keys.sorted().map { "<tv:\($0)>\(gpxXML(fields[$0]!))</tv:\($0)>" }.joined() + "</extensions>"
}
private func gpxJSON<T: Encodable>(_ value: T) throws -> String { String(decoding: try AtlasJSON.encode(value), as: UTF8.self) }
private func gpxDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
private func gpxXML(_ value: String) -> String {
    value.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value)
        || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value) }.map(String.init).joined()
        .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
