import Foundation
import Testing
@testable import AtlasCore

/// Parse the actual exchanged files with Python's independent JSON/XML/CSV readers.
/// DXF checks below consume group codes and entity records, not exporter helpers.
private func readGeometryExports(_ files: [String: Data], python: String) throws {
    #if os(Linux) || os(macOS)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terraview-geometry-export-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", python, directory.path]
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #endif
}

@Test func geographicPointAndLineExportsHaveActualGeometryTypesAndOpenCoordinates() throws {
    let project = AtlasProject(name: "Geometry", kind: .cemetery, coordinateReference: .wgs84)
    let first = GeographicCoordinate(longitude: 37.5, latitude: 55.5)
    let line = GeographicPolyline(vertices: [first, .init(longitude: 37.5001, latitude: 55.5), .init(longitude: 37.5001, latitude: 55.5001)])
    let point = AtlasFeature(projectID: project.id, label: "Entrance <A> & B", category: .entrance,
                             geometry: .geographicPoint(first), attributes: ["access": "public"], notes: "safe <text>")
    let fence = AtlasFeature(projectID: project.id, label: "Fence", category: .fence, geometry: .geographicPolyline(line))
    let polygon = GeographicPolygon(vertices: [.init(longitude: 37.5, latitude: 55.5), .init(longitude: 37.501, latitude: 55.5),
        .init(longitude: 37.501, latitude: 55.501), .init(longitude: 37.5, latitude: 55.501)],
        holes: [[.init(longitude: 37.5002, latitude: 55.5002), .init(longitude: 37.5004, latitude: 55.5002),
                 .init(longitude: 37.5004, latitude: 55.5004), .init(longitude: 37.5002, latitude: 55.5004)]])
    let cemetery = AtlasFeature(projectID: project.id, label: "Cemetery", category: .cemetery, geometry: .geographicPolygon(polygon))
    let snapshot = AtlasProjectSnapshot(project: project, features: [point, fence, cemetery])
    let geoJSON = try AtlasExporter.export(snapshot, format: .geoJSON)
    let kml = try AtlasExporter.export(snapshot, format: .kml)
    try readGeometryExports(["geometry.geojson": geoJSON.data, "geometry.kml": kml.data], python: #"""
        import sys, pathlib, json, xml.etree.ElementTree as ET
        path = pathlib.Path(sys.argv[1])
        collection = json.loads((path / 'geometry.geojson').read_text())
        assert collection['type'] == 'FeatureCollection'
        features = {f['properties']['category']: f for f in collection['features']}
        point = features['entrance']['geometry']
        line = features['fence']['geometry']
        polygon = features['cemetery']['geometry']
        assert point == {'type': 'Point', 'coordinates': [37.5, 55.5]}
        assert line == {'type': 'LineString', 'coordinates': [[37.5,55.5],[37.5001,55.5],[37.5001,55.5001]]}
        assert line['coordinates'][0] != line['coordinates'][-1]
        assert polygon['type'] == 'Polygon' and len(polygon['coordinates']) == 2
        assert all(len(r) == 5 and r[0] == r[-1] for r in polygon['coordinates'])
        ns = {'k': 'http://www.opengis.net/kml/2.2'}
        root = ET.parse(path / 'geometry.kml').getroot()
        marks = root.findall('.//k:Placemark', ns)
        assert len(marks) == 3
        points = root.findall('.//k:Point', ns)
        lines = root.findall('.//k:LineString', ns)
        polygons = root.findall('.//k:Polygon', ns)
        assert len(points) == len(lines) == len(polygons) == 1
        assert tuple(map(float, points[0].find('k:coordinates',ns).text.split(','))) == (37.5,55.5)
        coordinates = [tuple(map(float,p.split(','))) for p in lines[0].find('k:coordinates',ns).text.split()]
        assert coordinates == [(37.5,55.5),(37.5001,55.5),(37.5001,55.5001)]
        assert lines[0].find('k:altitudeMode',ns).text == 'clampToGround'
        assert len(polygons[0].findall('k:innerBoundaryIs',ns)) == 1
        assert root.find('.//k:script',ns) is None
        assert marks[0].find('k:name',ns).text == 'Entrance <A> & B'
        geometry = marks[0].find('k:ExtendedData/k:Data[@name="geometry_json"]/k:value',ns).text
        assert 'geographicPoint' in json.loads(geometry)
        """#)
}

@Test func localPointAndPolylineDXFAndSVGUseOpenEntitiesWithoutInventingArea() throws {
    let frame = UUID()
    let project = AtlasProject(name: "Local", kind: .site, coordinateReference: .localMeters(frameID: frame))
    let point = AtlasFeature(projectID: project.id, label: "Bin", category: .wasteBin,
                             geometry: .metricPoint(frameID: frame, point: .init(x: -2, y: 3)))
    let road = AtlasFeature(projectID: project.id, label: "Road", category: .road,
        geometry: .metricPolyline(.init(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 3, y: 4), .init(x: 6, y: 4)])))
    let snapshot = AtlasProjectSnapshot(project: project, features: [point, road])
    let dxf = try AtlasExporter.export(snapshot, format: .dxf)
    let svg = try AtlasExporter.export(snapshot, format: .svg)
    try readGeometryExports(["geometry.dxf": dxf.data, "geometry.svg": svg.data], python: #"""
        import sys, pathlib, xml.etree.ElementTree as ET
        path = pathlib.Path(sys.argv[1])
        lines = (path / 'geometry.dxf').read_text().splitlines()
        assert len(lines) % 2 == 0
        pairs = [(int(c),v) for c,v in zip(lines[::2],lines[1::2])]
        assert any(c == 9 and v == '$INSUNITS' and pairs[i+1] == (70,'6') for i,(c,v) in enumerate(pairs[:-1]))
        start = next(i for i,p in enumerate(pairs) if p == (2,'ENTITIES')) + 1
        entities, current = [], []
        for code,value in pairs[start:]:
            if code == 0:
                if current: entities.append(current)
                if value == 'ENDSEC': break
                current = [(code,value)]
            else: current.append((code,value))
        point = next(e for e in entities if e[0] == (0,'POINT'))
        pointValues = dict(point)
        assert pointValues[8] == 'FEATURE_WASTEBIN'
        assert [float(pointValues[k]) for k in (10,20,30)] == [-2,3,0]
        line = next(e for e in entities if e[0] == (0,'LWPOLYLINE'))
        assert (70,'0') in line and (90,'3') in line and (8,'FEATURE_ROAD') in line
        xs,ys = [float(v) for c,v in line if c==10], [float(v) for c,v in line if c==20]
        assert list(zip(xs,ys)) == [(0,0),(3,4),(6,4)]
        assert len([e for e in entities if e[0] == (0,'LWPOLYLINE')]) == 1
        ns = {'s': 'http://www.w3.org/2000/svg'}
        root = ET.parse(path / 'geometry.svg').getroot()
        circle = root.find('.//s:circle',ns)
        assert [float(circle.attrib[k]) for k in ('cx','cy')] == [-2,-3]
        line = root.find('.//s:polyline',ns)
        assert line.attrib['fill'] == 'none'
        assert [tuple(map(float,p.split(','))) for p in line.attrib['points'].split()] == [(0,0),(3,-4),(6,-4)]
        assert not root.findall('.//s:path',ns) and not root.findall('.//s:polygon',ns)
        bounds = [float(v) for v in root.attrib['viewBox'].split()]
        assert bounds[0] < -2 and bounds[0]+bounds[2] > 6
        assert bounds[1] < -4 and bounds[1]+bounds[3] > 0
        assert {g.attrib['data-category'] for g in root.findall('.//s:g',ns)} == {'road','wasteBin'}
        """#)
}

@Test func pointAndLineCSVPreserveGeometryUnitsLengthsAndUnknownSourceDates() throws {
    let frame = UUID()
    let local = AtlasProject(name: "Local", kind: .site, coordinateReference: .localMeters(frameID: frame))
    let bin = AtlasFeature(projectID: local.id, label: "Bin", category: .wasteBin,
                           geometry: .metricPoint(frameID: frame, point: .init(x: -2, y: 3)))
    let road = AtlasFeature(projectID: local.id, label: "Road", category: .road,
        geometry: .metricPolyline(.init(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 3, y: 4), .init(x: 6, y: 4)])))
    let geographic = AtlasProject(name: "WGS84", kind: .cemetery, coordinateReference: .wgs84)
    let entrance = AtlasFeature(projectID: geographic.id, label: "Entrance", category: .entrance,
                               geometry: .geographicPoint(.init(longitude: 37.5, latitude: 55.5)))
    let fence = AtlasFeature(projectID: geographic.id, label: "Fence", category: .fence,
        geometry: .geographicPolyline(.init(vertices: [.init(longitude: 37.5, latitude: 55.5), .init(longitude: 37.5001, latitude: 55.5),
                                                       .init(longitude: 37.5001, latitude: 55.5001)])))
    let metricCSV = try AtlasExporter.export(.init(project: local, features: [bin, road]), format: .csv)
    let geographicCSV = try AtlasExporter.export(.init(project: geographic, features: [entrance, fence]), format: .csv)
    try readGeometryExports(["metric.csv": metricCSV.data, "geographic.csv": geographicCSV.data], python: #"""
        import sys, pathlib, csv, json
        path = pathlib.Path(sys.argv[1])
        def read(name):
            with (path / name).open(encoding='utf-8-sig',newline='') as f:
                return {r['category']: r for r in csv.DictReader(f,strict=True) if r['record_type'] == 'feature'}
        local, geographic = read('metric.csv'), read('geographic.csv')
        point, road = local['wasteBin'], local['road']
        assert point['geometry_type'] == 'Point' and point['coordinate_system'] == 'local_metres'
        assert float(point['x_m']) == -2 and float(point['y_m']) == 3
        assert 'metricPoint' in json.loads(point['geometry_json'])
        assert road['geometry_type'] == 'LineString' and float(road['length_m']) == 8
        assert road['length_method'] == 'local_planar_metres'
        assert 'metricPolyline' in json.loads(road['geometry_json'])
        assert road['frame_id'] == point['frame_id'] and point['frame_id']
        entrance, fence = geographic['entrance'], geographic['fence']
        assert entrance['coordinate_system'] == fence['coordinate_system'] == 'WGS84_degrees'
        assert float(entrance['longitude']) == 37.5 and float(entrance['latitude']) == 55.5
        assert entrance['frame_id'] == fence['frame_id'] == ''
        assert fence['geometry_type'] == 'LineString'
        # One 0.0001-degree east segment at 55.5N plus one north segment is about 17.4m.
        assert 17 < float(fence['length_m']) < 18
        assert fence['length_method'] == 'WGS84_local_tangent_approximation'
        assert len(json.loads(fence['geometry_json'])['geographicPolyline']['_0']['vertices']) == 3
        for row in [point,road,entrance,fence]:
            assert row['area_m2'] == row['perimeter_m'] == ''
            assert row['created_at_utc'] == row['captured_at_utc'] == ''
            assert row['metadata_json']
        assert point['length_m'] == entrance['length_m'] == ''
        """#)
}

@Test func longGeographicPolylineCSVRetainsSourceEvenWhenLocalMetricLengthIsUnavailable() throws {
    let project = AtlasProject(name: "Long route", kind: .site, coordinateReference: .wgs84)
    let feature = AtlasFeature(projectID: project.id, label: "Route", category: .road,
        geometry: .geographicPolyline(.init(vertices: [.init(longitude: 0, latitude: 0), .init(longitude: 1, latitude: 0)])))
    let artifact = try AtlasExporter.export(.init(project: project, features: [feature]), format: .csv)
    #expect(artifact.warnings.contains { $0.contains(feature.id.uuidString) && $0.contains("не рассчитана") })
    try readGeometryExports(["route.csv": artifact.data], python: #"""
        import sys, pathlib, csv, json
        with (pathlib.Path(sys.argv[1]) / 'route.csv').open(encoding='utf-8-sig',newline='') as f:
            row = next(r for r in csv.DictReader(f) if r['record_type'] == 'feature')
        assert row['length_m'] == row['length_method'] == ''
        line = json.loads(row['geometry_json'])['geographicPolyline']['_0']['vertices']
        assert line == [{'longitude':0,'latitude':0},{'longitude':1,'latitude':0}]
        """#)
}

@Test func newGeometryExportsValidateFrameAndCoordinatesBeforeWritingEveryFormat() throws {
    let frame = UUID()
    let project = AtlasProject(name: "Frames", kind: .site, coordinateReference: .localMeters(frameID: frame))
    let foreign = AtlasFeature(projectID: project.id, label: "Other frame", category: .entrance,
                              geometry: .metricPoint(frameID: UUID(), point: .init(x: 0, y: 0)))
    let invalid = AtlasFeature(projectID: project.id, label: "NaN", category: .wasteBin,
                              geometry: .metricPoint(frameID: frame, point: .init(x: .nan, y: 0)))
    let short = AtlasFeature(projectID: project.id, label: "Not a line", category: .fence,
        geometry: .metricPolyline(.init(frameID: frame, vertices: [.init(x: 0, y: 0)])))
    for format in ExportFormat.allCases {
        #expect(throws: GeometryError.coordinateFrameMismatch) {
            try AtlasExporter.export(.init(project: project, features: [foreign]), format: format)
        }
        #expect(throws: GeometryError.nonFiniteCoordinate) {
            try AtlasExporter.export(.init(project: project, features: [invalid]), format: format)
        }
        #expect(throws: GeometryError.self) {
            try AtlasExporter.export(.init(project: project, features: [short]), format: format)
        }
    }
    let geographic = AtlasProject(name: "GPS", kind: .site, coordinateReference: .wgs84)
    let outOfRange = AtlasFeature(projectID: geographic.id, label: "Invalid", category: .entrance,
                                 geometry: .geographicPoint(.init(longitude: 181, latitude: 0)))
    let crossing = AtlasFeature(projectID: geographic.id, label: "Split required", category: .road,
        geometry: .geographicPolyline(.init(vertices: [.init(longitude: 179, latitude: 0), .init(longitude: -179, latitude: 0)])))
    for format in ExportFormat.allCases {
        #expect(throws: GeometryError.geographicCoordinateOutOfRange) {
            try AtlasExporter.export(.init(project: geographic, features: [outOfRange]), format: format)
        }
        #expect(throws: GeometryError.antimeridianRequiresSplitting) {
            try AtlasExporter.export(.init(project: geographic, features: [crossing]), format: format)
        }
    }
}

@Test func JSONSnapshotRetainsRealPointPolylineAndLegacyPolygonPayloadsAtSchemaOne() throws {
    let frame = UUID()
    let project = AtlasProject(name: "Roundtrip", kind: .cemetery, coordinateReference: .localMeters(frameID: frame))
    let geometries: [FeatureGeometry] = [
        .metricPoint(frameID: frame, point: .init(x: 1, y: 2)),
        .metricPolyline(.init(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 3, y: 4)])),
        .metricPolygon(.init(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 2, y: 0), .init(x: 2, y: 2)]))
    ]
    let features = geometries.map { AtlasFeature(projectID: project.id, label: "Geometry", category: .other, geometry: $0) }
    let snapshot = AtlasProjectSnapshot(project: project, features: features)
    let artifact = try AtlasExporter.export(snapshot, format: .projectJSON)
    let decoded = try AtlasJSON.decode(AtlasProjectSnapshot.self, from: artifact.data)
    #expect(decoded.schemaVersion == 1)
    #expect(decoded.features.map(\.geometry) == geometries)
    try readGeometryExports(["project.json": artifact.data], python: #"""
        import sys, pathlib, json
        snapshot = json.loads((pathlib.Path(sys.argv[1]) / 'project.json').read_text())
        assert snapshot['schemaVersion'] == 1
        point, line, polygon = [f['geometry'] for f in snapshot['features']]
        assert set(point) == {'metricPoint'} and point['metricPoint']['point'] == {'x':1,'y':2}
        assert set(line) == {'metricPolyline'} and len(line['metricPolyline']['_0']['vertices']) == 2
        assert set(polygon) == {'metricPolygon'} and len(polygon['metricPolygon']['_0']['vertices']) == 3
        assert polygon['metricPolygon']['_0']['holes'] == []
        """#)
}
