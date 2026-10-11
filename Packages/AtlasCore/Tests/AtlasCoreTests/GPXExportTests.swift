import Foundation
import Testing
@testable import AtlasCore

private func inspectGPX(_ artifact: ExportArtifact, python: String) throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gpx")
    try artifact.data.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", "import xml.etree.ElementTree as E, json, sys\nr=E.parse(sys.argv[1]).getroot()\nn={'g':'http://www.topografix.com/GPX/1/1','tv':'urn:terraview:field-survey:1'}\nassert r.tag=='{http://www.topografix.com/GPX/1/1}gpx'\nassert r.attrib=={'version':'1.1','creator':'TerraView'}\n" + python, file.path]
    let pipe = Pipe(); process.standardError = pipe; process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "Independent GPX parsing failed: \(output)")
}

@Test func gpxKeepsRealGeographicWaypointsOpenLinesAndSeparateOuterAndHoleBoundaries() throws {
    let project = AtlasProject(name: "Кладбище <А> & Б", kind: .cemetery, coordinateReference: .wgs84)
    let unknown = AtlasFeature(projectID: project.id, label: "Неизвестное", category: .grave,
        geometry: .geographicPoint(.init(longitude: 37, latitude: 55)),
        attributes: ["grave.identityStatus": "unknown", "grave.persons": "[]", "survey.status": "confirmed"])
    let line = AtlasFeature(projectID: project.id, label: "Ограда", category: .fence,
        geometry: .geographicPolyline(.init(vertices: [.init(longitude: 37, latitude: 55), .init(longitude: 37.001, latitude: 55)])))
    let ring = GeographicPolygon(vertices: [.init(longitude: 37, latitude: 55), .init(longitude: 37.002, latitude: 55),
        .init(longitude: 37.002, latitude: 55.002), .init(longitude: 37, latitude: 55.002)],
        holes: [[.init(longitude: 37.0005, latitude: 55.0005), .init(longitude: 37.001, latitude: 55.0005),
                 .init(longitude: 37.001, latitude: 55.001), .init(longitude: 37.0005, latitude: 55.001)]])
    let cemetery = AtlasFeature(projectID: project.id, label: "Кладбище", category: .cemetery, geometry: .geographicPolygon(ring))
    let artifact = try AtlasExporter.export(.init(project: project, features: [unknown, line, cemetery]), format: .gpx)
    try inspectGPX(artifact, python: """
        assert r.find('g:metadata/g:name',n).text == 'Кладбище <А> & Б'
        w=r.findall('g:wpt',n); assert len(w)==1 and w[0].attrib=={'lat':'55.0','lon':'37.0'}
        assert w[0].find('g:time',n) is None
        f=json.loads(w[0].find('g:extensions/tv:feature_json',n).text)
        assert f['attributes']['grave.persons']=='[]' and f['attributes']['grave.identityStatus']=='unknown'
        tracks=r.findall('g:trk',n); assert len(tracks)==3
        pts=tracks[0].findall('g:trkseg/g:trkpt',n)
        assert len(pts)==2 and pts[0].attrib!=pts[-1].attrib
        assert [t.find('g:type',n).text for t in tracks]==['open_line','exterior_boundary','hole_boundary']
        for t in tracks[1:]:
            p=t.findall('g:trkseg/g:trkpt',n)
            assert len(p)==5 and p[0].attrib==p[-1].attrib
        assert all(p.find('g:time',n) is None for p in r.findall('.//g:trkpt',n))
        """)
}

@Test func gpxSurveyNeverBridgesPauseOrRejectedGPSAndRetainsRawRejectedProvenance() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var session = try CemeterySurveySession(startedAt: start)
    func sample(_ seconds: Double, _ longitude: Double, accuracy: Double = 2) -> CemeterySurveySample {
        .init(coordinate: .init(longitude: longitude, latitude: 0), capturedAt: start.addingTimeInterval(seconds),
              horizontalAccuracyMeters: accuracy, altitudeMeters: 120)
    }
    try session.record(sample(0, 0), receivedAt: start)
    try session.record(sample(1, 0.00001), receivedAt: start.addingTimeInterval(1))
    try session.pause(at: start.addingTimeInterval(2))
    try session.record(sample(3, 0.00002), receivedAt: start.addingTimeInterval(3))
    try session.resume(at: start.addingTimeInterval(4))
    try session.record(sample(5, 0.00003), receivedAt: start.addingTimeInterval(5))
    try session.record(sample(6, 0.00004, accuracy: 40), receivedAt: start.addingTimeInterval(6))
    try session.record(sample(7, 0.00005), receivedAt: start.addingTimeInterval(7))
    try session.stop(at: start.addingTimeInterval(8))
    let artifact = try AtlasExporter.exportSurveyTrack(session, name: "Обход & запись")
    try inspectGPX(artifact, python: """
        tracks=r.findall('g:trk',n); assert len(tracks)==3
        assert [len(t.findall('g:trkseg/g:trkpt',n)) for t in tracks]==[2,1,1]
        pts=r.findall('.//g:trkpt',n); assert len(pts)==4
        assert [p.find('g:time',n).text for p in pts]==['2027-01-15T08:00:00.000Z','2027-01-15T08:00:01.000Z','2027-01-15T08:00:05.000Z','2027-01-15T08:00:07.000Z']
        assert all(p.find('g:ele',n) is None for p in pts)
        assert all(p.find('g:extensions/tv:horizontal_accuracy_m',n).text=='2.0' for p in pts)
        rejected=json.loads(r.find('g:metadata/g:extensions/tv:rejected_observations_json',n).text)
        assert [v['decision']['rejectionReason'] for v in rejected]==['paused','insufficientAccuracy']
        assert rejected[1]['sample']['horizontalAccuracyMeters']==40
        assert r.find('g:metadata/g:extensions/tv:state',n).text=='stopped'
        """)
}

@Test func gpxLocalFrameExportsOnlyExistingGPSAndNeverLocalCoordinatesOrUnknownTimes() throws {
    let frame = UUID()
    let project = AtlasProject(name: "Локальный", kind: .cemetery, coordinateReference: .localMeters(frameID: frame))
    let feature = AtlasFeature(projectID: project.id, label: "Ограда", category: .fence,
        geometry: .metricPolyline(.init(frameID: frame, vertices: [.init(x: 1000, y: 1000), .init(x: 2000, y: 2000)])))
    #expect(throws: AtlasExportError.requiresGeographicCoordinates) { try AtlasExporter.export(.init(project: project, features: [feature]), format: .gpx) }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let scan = ScanRecord(projectID: project.id, source: .liDAR, status: .ready, frameID: frame,
                          geoTag: GeoTag(corrections: [.init(coordinate: .init(longitude: 37, latitude: 55), changedAt: date)]))
    let artifact = try AtlasExporter.export(.init(project: project, features: [feature], scans: [scan]), format: .gpx)
    #expect(artifact.warnings.contains { $0.contains("Локальные объекты") })
    try inspectGPX(artifact, python: """
        assert not r.findall('g:trk',n)
        w=r.findall('g:wpt',n); assert len(w)==1 and w[0].attrib=={'lat':'55.0','lon':'37.0'}
        assert w[0].find('g:extensions/tv:location_source',n).text=='operatorEntered'
        assert w[0].find('g:extensions/tv:horizontal_accuracy_m',n) is None
        """)
}
