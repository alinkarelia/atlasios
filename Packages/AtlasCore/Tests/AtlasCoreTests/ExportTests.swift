import Foundation
import Testing
@testable import AtlasCore

@Test func localMetersCannotMasqueradeAsGeoJSON() throws {
    let project = AtlasProject(name: "Local", kind: .site, coordinateReference: .localMeters(frameID: UUID()))
    #expect(throws: AtlasExportError.requiresGeographicCoordinates) {
        try AtlasExporter.export(AtlasProjectSnapshot(project: project), format: .geoJSON)
    }
}

@Test func genuineGeoJSONUsesLongitudeLatitudeClosedRingsAndStableIDs() throws {
    let project = AtlasProject(name: "Map", kind: .cemetery, coordinateReference: .wgs84)
    // Clockwise input must become RFC 7946 exterior orientation.
    let polygon = GeographicPolygon(vertices: [.init(longitude: 37, latitude: 55), .init(longitude: 37, latitude: 55.001),
                                               .init(longitude: 37.001, latitude: 55.001), .init(longitude: 37.001, latitude: 55)])
    let feature = AtlasFeature(projectID: project.id, label: "Сектор А", category: .sector, geometry: .geographicPolygon(polygon),
                               attributes: ["register": "12"])
    let artifact = try AtlasExporter.export(.init(project: project, features: [feature]), format: .geoJSON)
    let document = try #require(JSONSerialization.jsonObject(with: artifact.data) as? [String: Any])
    #expect(document["type"] as? String == "FeatureCollection")
    #expect(document["crs"] == nil)
    let features = try #require(document["features"] as? [[String: Any]])
    #expect(features[0]["id"] as? String == feature.id.uuidString)
    let geometry = try #require(features[0]["geometry"] as? [String: Any])
    let rings = try #require(geometry["coordinates"] as? [[[Double]]])
    #expect(rings[0].count == 5)
    #expect(rings[0].first == rings[0].last)
    #expect(rings[0][0][0] >= 37 && rings[0][0][0] <= 37.001)
    #expect(rings[0][0][1] >= 55 && rings[0][0][1] <= 55.001)
    #expect(PolygonGeometry.signedArea(rings[0].dropLast().map { .init(x: $0[0], y: $0[1]) }) > 0)
}

@Test func dxfDefinesMetersAndPreservesHolesWallsAndSafeText() throws {
    let frame = UUID()
    let project = AtlasProject(name: "Plan", kind: .building, coordinateReference: .localMeters(frameID: frame))
    let polygon = MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 6), .init(x: 0, y: 6)],
                                holes: [[.init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 2, y: 2), .init(x: 1, y: 2)]])
    let feature = AtlasFeature(projectID: project.id, label: "Участок\n0\nEOF", category: .grave, geometry: .metricPolygon(polygon))
    let plan = AtlasFloorPlan(projectID: project.id, frameID: frame, walls: [.init(start: .init(x: 0, y: 0), end: .init(x: 4, y: 0))])
    let artifact = try AtlasExporter.export(.init(project: project, features: [feature], floorPlans: [plan]), format: .dxf)
    let text = try #require(String(data: artifact.data, encoding: .utf8))
    #expect(text.contains("9\n$INSUNITS\n70\n6\n"))
    #expect(text.components(separatedBy: "0\nLWPOLYLINE\n").count - 1 == 2)
    #expect(text.contains("FEATURE_GRAVE_HOLES"))
    #expect(text.contains("0\nLINE\n"))
    #expect(text.contains("\\U+0423"))
    #expect(text.components(separatedBy: "0\nEOF\n").count - 1 == 1)
}

@Test func snapshotJSONIsRoundTrippableAndDoesNotClaimToIncludeSourceFiles() throws {
    let frame = UUID()
    let project = AtlasProject(name: "JSON", kind: .building, coordinateReference: .localMeters(frameID: frame))
    let scan = ScanRecord(projectID: project.id, source: .roomPlan, status: .captured, frameID: frame,
                          assets: [.init(relativePath: "scans/room.json", kind: .roomPlanJSON, byteCount: 400)])
    let snapshot = AtlasProjectSnapshot(project: project, scans: [scan])
    let artifact = try AtlasExporter.export(snapshot, format: .projectJSON)
    let decoded = try AtlasJSON.decode(AtlasProjectSnapshot.self, from: artifact.data)
    #expect(decoded.project.id == project.id)
    #expect(decoded.scans[0].assets[0].relativePath == "scans/room.json")
    #expect(!artifact.warnings.isEmpty)
    #expect(artifact.fileName.hasSuffix(".atlas.json"))
}

@Test func individualFloorPlanExportKeepsSessionCoordinatesWithoutFalseAlignment() throws {
    let sessionFrame = UUID()
    let boundary = MetricPolygon(frameID: sessionFrame, vertices: [.init(x: -10, y: 7), .init(x: -6, y: 7),
                                                                 .init(x: -6, y: 13), .init(x: -10, y: 13)])
    let plan = AtlasFloorPlan(projectID: UUID(), frameID: sessionFrame, rooms: [.init(name: "Room", boundary: boundary)])
    let artifact = try AtlasExporter.exportFloorPlan(plan)
    let text = try #require(String(data: artifact.data, encoding: .utf8))
    #expect(text.contains("10\n-10.0\n20\n7.0\n"))
    #expect(text.contains("9\n$INSUNITS\n70\n6\n"))
    #expect(!artifact.warnings.isEmpty)
}
