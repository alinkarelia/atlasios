import Foundation
import Testing
@testable import AtlasCore

/// Use independent standard-library parsers: no exporter internals or duplicated
/// XML/CSV escaping routines take part in checking the generated documents.
private func independentlyReadExports(_ files: [String: Data], python: String) throws {
    #if os(Linux) || os(macOS)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terraview-export-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
    #expect(python.utf8.allSatisfy { $0 < 0x80 })
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", python, directory.path]
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #endif
}

private func fixtureBoundary(_ frame: UUID) -> MetricPolygon {
    .init(frameID: frame, vertices: [.init(x: -2, y: 3), .init(x: 2, y: 3), .init(x: 2, y: 8), .init(x: -2, y: 8)],
          holes: [[.init(x: -1, y: 4), .init(x: 0, y: 4), .init(x: 0, y: 5), .init(x: -1, y: 5)]])
}

@Test func svgIsReadableVectorGeometryWithMetricScaleHolesWallsAndSafeLabels() throws {
    let frame = UUID()
    let project = AtlasProject(name: "Дом <сектор> & \"А\"", kind: .building, coordinateReference: .localMeters(frameID: frame))
    let feature = AtlasFeature(projectID: project.id, label: "<script> & \"Могила\"\u{1}", category: .grave,
                               geometry: .metricPolygon(fixtureBoundary(frame)))
    let plan = AtlasFloorPlan(projectID: project.id, frameID: frame, name: "Этаж & 1", floorIndex: -1,
        rooms: [.init(name: "Комната", boundary: fixtureBoundary(frame))],
        walls: [.init(start: .init(x: -2, y: 3), end: .init(x: 2, y: 3), heightMeters: 2.8, thicknessMeters: 0.2)])
    let artifact = try AtlasExporter.export(.init(project: project, features: [feature], floorPlans: [plan]), format: .svg)
    #expect(artifact.fileName.hasPrefix("terraview-")); #expect(artifact.contentType == "image/svg+xml")
    try independentlyReadExports(["plan.svg": artifact.data], python: #"""
        import sys, pathlib, re, xml.etree.ElementTree as ET
        root = ET.parse(pathlib.Path(sys.argv[1]) / 'plan.svg').getroot()
        ns = {'s': 'http://www.w3.org/2000/svg'}
        assert root.tag == '{http://www.w3.org/2000/svg}svg'
        assert root.attrib['data-units'] == 'metres' and root.attrib['data-scale'] == '1:100'
        bounds = [float(n) for n in root.attrib['viewBox'].split()]
        assert float(root.attrib['width'][:-2]) == bounds[2] * 10
        assert float(root.attrib['height'][:-2]) == bounds[3] * 10
        paths = root.findall('.//s:path', ns)
        assert len(paths) == 2
        for path in paths:
            assert path.attrib['fill-rule'] == 'evenodd'
            rings = re.findall(r'M ([^Z]+) Z', path.attrib['d'])
            assert len(rings) == 2
            coordinates = [[float(n) for n in re.findall(r'[-\d.]+', r)] for r in rings]
            assert coordinates[0] == [-2, -3, 2, -3, 2, -8, -2, -8]
            assert coordinates[1] == [-1, -4, 0, -4, 0, -5, -1, -5]
            def area(values):
                p = list(zip(values[::2], values[1::2]))
                return abs(sum(a[0]*b[1] - b[0]*a[1] for a,b in zip(p,p[1:]+p[:1])) / 2)
            assert area(coordinates[0]) - area(coordinates[1]) == 19
        line = root.find('.//s:line', ns)
        assert [float(line.attrib[k]) for k in ('x1','y1','x2','y2')] == [-2,-3,2,-3]
        assert float(line.attrib['stroke-width']) == 0.2
        assert root.find('.//s:g[@data-floor-index="-1"]', ns) is not None
        assert root.find('.//s:script', ns) is None
        assert any('<script>' in (t.text or '') for t in root.findall('.//s:title', ns))
        """#)
}

@Test func svgRefusesFalseFrameAlignmentButIndividualPlanKeepsItsOwnFrame() throws {
    let projectFrame = UUID(), independentFrame = UUID()
    let project = AtlasProject(name: "Frames", kind: .building, coordinateReference: .localMeters(frameID: projectFrame))
    let plan = AtlasFloorPlan(projectID: project.id, frameID: independentFrame,
                             rooms: [.init(name: "Room", boundary: fixtureBoundary(independentFrame))])
    #expect(throws: GeometryError.coordinateFrameMismatch) {
        try AtlasExporter.export(.init(project: project, floorPlans: [plan]), format: .svg)
    }
    let independent = try AtlasExporter.exportFloorPlan(plan, format: .svg)
    #expect(independent.fileName.hasSuffix(".svg"))
    #expect(String(decoding: independent.data, as: UTF8.self).contains(independentFrame.uuidString))
    let geographic = AtlasProject(name: "Degrees", kind: .site, coordinateReference: .wgs84)
    var geographicPlan = plan; geographicPlan.projectID = geographic.id
    #expect(throws: AtlasExportError.requiresLocalMetricCoordinates) {
        try AtlasExporter.export(.init(project: geographic, floorPlans: [geographicPlan]), format: .svg)
    }
}

@Test func csvIndependentParserRetainsMultilineMetadataGeometryAndUnknownDatesWithoutFormulas() throws {
    let frame = UUID()
    let created = Date(timeIntervalSince1970: 1_577_836_800.125)
    let project = AtlasProject(name: "CSV", kind: .cemetery, coordinateReference: .localMeters(frameID: frame), createdAt: created, updatedAt: created)
    let feature = AtlasFeature(projectID: project.id, label: "=HYPERLINK(\"https://example.invalid\",\"А, Б\")",
        category: .grave, geometry: .metricPolygon(fixtureBoundary(frame)),
        attributes: ["description": "Первая строка\r\nВторая, с \"кавычкой\""], notes: "заметка\nдва ряда")
    let imported = ScanRecord(projectID: project.id, source: .imported, status: .ready, frameID: UUID(),
        assets: [.init(relativePath: "photos/А,\"Б\".jpg", kind: .image, byteCount: 123)], createdAt: created)
    let manual = MeasurementRecord(projectID: project.id, source: .manualReference, originalMeters: 5, createdAt: created,
        corrections: [.init(meters: 5.25, note: "Проверено рулеткой", changedAt: created)])
    let artifact = try AtlasExporter.export(.init(project: project, features: [feature], scans: [imported], measurements: [manual]), format: .csv)
    #expect(artifact.fileName.hasSuffix(".csv"))
    let expected = try AtlasJSON.encode(["label": feature.label, "notes": feature.notes, "attribute": feature.attributes["description"]!, "path": imported.assets[0].relativePath])
    try independentlyReadExports(["metadata.csv": artifact.data, "expected.json": expected], python: #"""
        import sys, pathlib, csv, json
        p = pathlib.Path(sys.argv[1])
        expected = json.loads((p / 'expected.json').read_text(encoding='utf-8'))
        with (p / 'metadata.csv').open(encoding='utf-8-sig', newline='') as f:
            rows = list(csv.DictReader(f, strict=True))
        assert len(rows) == 5 and all(None not in r for r in rows)
        assert all(r['generator'] == 'TerraView' for r in rows)
        feature = next(r for r in rows if r['record_type'] == 'feature')
        assert feature['name'] == "'" + expected['label']
        assert json.loads(feature['metadata_json'])['label'] == expected['label']
        assert feature['notes'] == expected['notes']
        assert json.loads(feature['attributes_json'])['description'] == expected['attribute']
        assert float(feature['area_m2']) == 19 and float(feature['perimeter_m']) == 22
        assert feature['created_at_utc'] == feature['captured_at_utc'] == ''
        assert feature['longitude'] == feature['latitude'] == ''
        scan = next(r for r in rows if r['record_type'] == 'scan')
        assert scan['captured_at_utc'] == scan['imported_at_utc'] == ''
        assert scan['created_at_utc'] == '2020-01-01T00:00:00.125Z'
        asset = next(r for r in rows if r['record_type'] == 'sourceAsset')
        assert asset['relative_path'] == expected['path'] and asset['bytes'] == '123'
        assert asset['sha256'] == asset['captured_at_utc'] == ''
        measurement = next(r for r in rows if r['record_type'] == 'measurement')
        assert measurement['source'] == 'manualReference'
        assert float(measurement['length_m']) == 5.25 and float(measurement['original_length_m']) == 5
        assert measurement['coordinate_system'] == measurement['frame_id'] == ''
        """#)
}

@Test func materialCSVPreservesUnknownPhotoCaptureTimeImportTimeAndOriginalCorrectedGPS() throws {
    let captured = Date(timeIntervalSince1970: 1_577_836_800)
    let imported = Date(timeIntervalSince1970: 1_609_459_200)
    let tag = GeoTag(automaticFix: .init(coordinate: .init(longitude: -77, latitude: 38), observedAt: captured, source: .photoEXIF),
        corrections: [.init(coordinate: .init(longitude: -76.99, latitude: 38.01), estimatedAccuracyMeters: 2,
                            note: "Уточнено", changedAt: imported)])
    let photo = FieldMaterial(sourceEntityID: UUID(), kind: .photo, importedAt: imported, geoTag: tag)
    let manifest = FieldTransferManifest(projectID: UUID(), title: "Photo", createdAt: imported.addingTimeInterval(999),
        timeZoneIdentifier: "UTC", utcOffsetSeconds: 0, materials: [photo],
        assets: [.init(materialID: photo.id, relativePath: "photo.jpg", mediaType: "image/jpeg", byteCount: 3,
                       sha256: FieldTransferDigest.sha256(Data([1, 2, 3])), kind: .originalPhoto)])
    let artifact = try AtlasExporter.exportMaterialMetadata(manifest)
    try independentlyReadExports(["metadata.csv": artifact.data], python: #"""
        import sys, pathlib, csv, json
        with (pathlib.Path(sys.argv[1]) / 'metadata.csv').open(encoding='utf-8-sig', newline='') as f:
            rows = list(csv.DictReader(f, strict=True))
        photo = next(r for r in rows if r['record_type'] == 'material')
        assert photo['record_type'] == 'material' and photo['category'] == 'photo'
        assert photo['captured_at_utc'] == photo['created_at_utc'] == ''
        assert photo['imported_at_utc'] == '2021-01-01T00:00:00.000Z'
        assert photo['observed_at_utc'] == '2021-01-01T00:00:00.000Z'
        assert photo['original_observed_at_utc'] == '2020-01-01T00:00:00.000Z'
        assert photo['longitude'] == '-76.99' and photo['original_longitude'] == '-77.0'
        assert photo['location_source'] == 'operatorEntered' and photo['original_location_source'] == 'photoEXIF'
        assert photo['horizontal_accuracy_m'] == '2.0' and photo['altitude_m'] == ''
        assert len(json.loads(photo['geotag_json'])['corrections']) == 1
        assert len(rows) == 3 and rows[2]['parent_id'] == photo['id']
        """#)
}

@Test func kmlIndependentParserSeesClosedOrientedHolesMultiplePolygonsAndGPSPoints() throws {
    let project = AtlasProject(name: "Карта & <А>", kind: .cemetery, coordinateReference: .wgs84)
    let polygon = GeographicPolygon(vertices: [.init(longitude: 37, latitude: 55), .init(longitude: 37, latitude: 56),
        .init(longitude: 38, latitude: 56), .init(longitude: 38, latitude: 55)],
        holes: [[.init(longitude: 37.2, latitude: 55.2), .init(longitude: 37.4, latitude: 55.2),
                 .init(longitude: 37.4, latitude: 55.4), .init(longitude: 37.2, latitude: 55.4)]])
    let features = ["<script> & область", "Второй контур"].map {
        AtlasFeature(projectID: project.id, label: $0, category: .sector, geometry: .geographicPolygon(polygon), notes: "<b>не разметка</b>")
    }
    let time = Date(timeIntervalSince1970: 1_577_836_800)
    let scans = [GeographicCoordinate(longitude: -77, latitude: 38), .init(longitude: 0, latitude: 0)].map {
        ScanRecord(projectID: project.id, source: .liDAR, status: .ready, frameID: UUID(), createdAt: time,
            geoTag: .init(automaticFix: .init(coordinate: $0, altitudeMeters: 42, observedAt: time, source: .deviceLocation)))
    }
    let artifact = try AtlasExporter.export(.init(project: project, features: features, scans: scans), format: .kml)
    #expect(artifact.fileName.hasSuffix(".kml"))
    try independentlyReadExports(["map.kml": artifact.data], python: #"""
        import sys, pathlib, xml.etree.ElementTree as ET
        root = ET.parse(pathlib.Path(sys.argv[1]) / 'map.kml').getroot()
        ns = {'k': 'http://www.opengis.net/kml/2.2'}
        marks = root.findall('.//k:Placemark', ns)
        assert len(marks) == 4
        polygons = root.findall('.//k:Polygon', ns)
        assert len(polygons) == 2
        def area(p):
            return sum(a[0]*b[1] - b[0]*a[1] for a,b in zip(p,p[1:])) / 2
        for polygon in polygons:
            rings = polygon.findall('.//k:coordinates', ns)
            assert len(rings) == 2
            coords = [[tuple(map(float,t.split(','))) for t in ring.text.split()] for ring in rings]
            assert all(len(c) == 5 and c[0] == c[-1] for c in coords)
            assert all(len(p) == 2 for c in coords for p in c)
            assert area(coords[0]) > 0 and area(coords[1]) < 0
            assert abs(area(coords[0]) + area(coords[1]) - 0.96) < 1e-9
            assert coords[0][0][0] in (37,38) and coords[0][0][1] in (55,56)
        points = root.findall('.//k:Point', ns)
        assert len(points) == 2
        assert {point.find('k:coordinates', ns).text for point in points} == {'-77.0,38.0','0.0,0.0'}
        assert all(point.find('k:altitudeMode', ns).text == 'clampToGround' for point in points)
        assert root.find('.//k:script', ns) is None
        assert any('<script>' in (m.find('k:name',ns).text or '') for m in marks)
        assert len(root.findall('.//k:TimeStamp/k:when', ns)) == 2
        altitudes = root.findall('.//k:Data[@name="altitude_m"]/k:value', ns)
        assert len(altitudes) == 2 and all(a.text == '42.0' for a in altitudes)
        """#)
}

@Test func localKMLExportsOnlyRealGeotagsAndNeverTurnsMetricVerticesIntoDegrees() throws {
    let frame = UUID()
    let project = AtlasProject(name: "Local", kind: .site, coordinateReference: .localMeters(frameID: frame))
    let feature = AtlasFeature(projectID: project.id, label: "Local", category: .boundary, geometry: .metricPolygon(fixtureBoundary(frame)))
    let missing = ScanRecord(projectID: project.id, source: .liDAR, status: .ready, frameID: frame)
    #expect(throws: AtlasExportError.requiresGeographicCoordinates) {
        try AtlasExporter.export(.init(project: project, features: [feature], scans: [missing]), format: .kml)
    }
    let located = ScanRecord(projectID: project.id, source: .liDAR, status: .ready, frameID: frame,
        geoTag: .init(corrections: [.init(coordinate: .init(longitude: 0, latitude: 0), changedAt: Date())]))
    let artifact = try AtlasExporter.export(.init(project: project, features: [feature], scans: [missing, located]), format: .kml)
    #expect(artifact.warnings.contains { $0.contains("Локальные полигоны") })
    #expect(artifact.warnings.contains { $0.contains("пропущены: 1") })
    try independentlyReadExports(["map.kml": artifact.data], python: #"""
        import sys, pathlib, xml.etree.ElementTree as ET
        root = ET.parse(pathlib.Path(sys.argv[1]) / 'map.kml').getroot()
        ns = {'k': 'http://www.opengis.net/kml/2.2'}
        assert not root.findall('.//k:Polygon', ns)
        assert len(root.findall('.//k:Point', ns)) == 1
        assert root.find('.//k:Point/k:coordinates', ns).text == '0.0,0.0'
        """#)
}

@Test func newExportsValidateSchemaScopeAntimeridianAndMetadataDatesBeforePublishing() throws {
    let project = AtlasProject(name: "Safety", kind: .site, coordinateReference: .wgs84)
    var future = AtlasProjectSnapshot(project: project); future.schemaVersion = 9
    for format in [ExportFormat.svg, .csv, .kml] {
        #expect(throws: AtlasExportError.unsupportedSchema(9)) { try AtlasExporter.export(future, format: format) }
        let foreign = ScanRecord(projectID: UUID(), source: .imported, status: .ready, frameID: UUID())
        #expect(throws: AtlasExportError.entityProjectMismatch) {
            try AtlasExporter.export(.init(project: project, scans: [foreign]), format: format)
        }
    }
    let crossing = AtlasFeature(projectID: project.id, label: "Crossing", category: .boundary,
        geometry: .geographicPolygon(.init(vertices: [.init(longitude: 179, latitude: 0), .init(longitude: -179, latitude: 0),
                                                     .init(longitude: -179, latitude: 1)])))
    #expect(throws: GeometryError.antimeridianRequiresSplitting) {
        try AtlasExporter.export(.init(project: project, features: [crossing]), format: .kml)
    }
    var invalidDate = project; invalidDate.createdAt = Date(timeIntervalSince1970: .nan)
    for format in [ExportFormat.csv, .kml] {
        #expect(throws: AtlasExportError.invalidDate) { try AtlasExporter.export(.init(project: invalidDate), format: format) }
    }
}

@Test func csvGeographicGeometryNeverProducesFalseSquareMetresOrPerimeterMetres() throws {
    let project = AtlasProject(name: "Degrees", kind: .site, coordinateReference: .wgs84)
    let feature = AtlasFeature(projectID: project.id, label: "Geographic", category: .boundary,
        geometry: .geographicPolygon(.init(vertices: [.init(longitude: 10, latitude: 50), .init(longitude: 11, latitude: 50),
                                                     .init(longitude: 11, latitude: 51)])))
    let artifact = try AtlasExporter.export(.init(project: project, features: [feature]), format: .csv)
    try independentlyReadExports(["metadata.csv": artifact.data], python: #"""
        import sys, pathlib, csv, json
        with (pathlib.Path(sys.argv[1]) / 'metadata.csv').open(encoding='utf-8-sig', newline='') as f:
            feature = next(r for r in csv.DictReader(f) if r['record_type'] == 'feature')
        assert feature['coordinate_system'] == 'WGS84_degrees'
        assert feature['frame_id'] == feature['area_m2'] == feature['perimeter_m'] == ''
        assert 'geographicPolygon' in json.loads(feature['geometry_json'])
        """#)
}

@Test func offlineMaterialCSVNeedsNoServerAndRejectsBrokenAssetOwnershipOrPaths() throws {
    let projectID = UUID()
    let material = FieldMaterial(sourceEntityID: UUID(), kind: .photo)
    let emptyHash = FieldTransferDigest.sha256(Data())
    let asset = FieldAsset(materialID: material.id, relativePath: "originals/photo.jpg", mediaType: "image/jpeg",
                           byteCount: 0, sha256: emptyHash, kind: .originalPhoto)
    let artifact = try AtlasExporter.exportMaterialMetadata(projectID: projectID, projectName: "+Свои материалы",
        materials: [material], assets: [asset])
    try independentlyReadExports(["metadata.csv": artifact.data], python: #"""
        import sys, pathlib, csv, json
        with (pathlib.Path(sys.argv[1]) / 'metadata.csv').open(encoding='utf-8-sig', newline='') as f:
            rows = list(csv.DictReader(f, strict=True))
        assert len(rows) == 3
        assert rows[0]['name'].startswith("'+")
        assert json.loads(rows[0]['metadata_json'])['name'].startswith('+')
        assert all(r['created_at_utc'] == r['captured_at_utc'] == r['imported_at_utc'] == '' for r in rows)
        assert rows[2]['parent_id'] == rows[1]['id'] and rows[2]['bytes'] == '0'
        assert rows[2]['sha256'] == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        """#)
    let foreign = FieldAsset(materialID: UUID(), relativePath: "photo.jpg", mediaType: "image/jpeg",
                             byteCount: 0, sha256: emptyHash, kind: .originalPhoto)
    #expect(throws: FieldTransferError.invalidManifest) {
        try AtlasExporter.exportMaterialMetadata(projectID: projectID, projectName: "Own", materials: [material], assets: [foreign])
    }
    #expect(throws: FieldTransferError.invalidManifest) {
        try AtlasExporter.exportMaterialMetadata(projectID: projectID, projectName: "Own", materials: [material, material], assets: [asset])
    }
    let unsafe = FieldAsset(materialID: material.id, relativePath: "../photo.jpg", mediaType: "image/jpeg",
                            byteCount: 0, sha256: emptyHash, kind: .originalPhoto)
    #expect(throws: FieldTransferError.self) {
        try AtlasExporter.exportMaterialMetadata(projectID: projectID, projectName: "Own", materials: [material], assets: [unsafe])
    }
}
