#if ATLAS_EMPTY_ROOM_CHECKS
import Foundation

@main
struct EmptyRoomGeometryChecks {
    struct Failure: Error, CustomStringConvertible { var description: String }
    static func main() throws {
        var passed = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw Failure(description: label) }; passed += 1
        }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
        func reject(_ label: String, _ action: () throws -> Void) throws {
            do { try action() } catch { passed += 1; return }
            throw Failure(description: "Expected rejection: " + label)
        }
        let identity = EmptyRoomTransform(columns: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])
        let transform = EmptyRoomTransform(columns: [0,0,-1,0, 0,1,0,0, 1,0,0,0, 10,3,20,1])
        let floorID = UUID()
        let outer: [EmptyRoomPoint] = [.init(x: 0,y: 0,z: 0), .init(x: 4,y: 0,z: 0), .init(x: 4,y: 0,z: 3), .init(x: 0,y: 0,z: 3)]
        let floor = EmptyRoomSurface(id: floorID, parentID: nil, kind: .floor, widthMeters: nil, heightMeters: nil,
            thicknessMeters: nil, transform: transform, polygonCorners: outer + [outer[0]], isCurved: false, confidence: .medium)
        try check(identity.isValid && transform.isValid, "Rigid affine transforms are accepted")
        try check(floor.floorWorldRing.count == 4, "Explicit closing vertex is normalized once")
        try check(floor.dimensions.count == 4, "Actual closed floor has four edges without a duplicate dimension")
        try check(close(floor.floorAreaSquareMeters, 12), "Rotated and translated 4x3 polygon retains 12 square metres")
        try check(floor.dimensions.map(\.valueMeters) == [4,3,4,3], "Floor lengths derive from transformed observed vertices")
        try check(floor.dimensions[0].start == .init(x: 10,y: 3,z: 20), "RoomPlan local corners transform to the shared native frame")
        try check(floor.dimensions.last?.end == floor.dimensions.first?.start, "Floor closes in the world frame")
        try check(Set(floor.dimensions.map(\.id)).count == 4 && floor.dimensions.allSatisfy { $0.sourceID == floorID }, "Dimensions retain unique stable source IDs")
        try check(floor.dimensions.allSatisfy { $0.confidence == .medium }, "Classification confidence survives measurement derivation")

        let wall = EmptyRoomSurface(id: UUID(), parentID: nil, kind: .wall, widthMeters: 4, heightMeters: 2.5,
            thicknessMeters: 0.12, transform: transform, polygonCorners: [], isCurved: false, confidence: .high)
        try check(wall.dimensions.count == 2, "Individual wall length and height are available")
        try check(close(wall.dimensions[0].valueMeters, 4) && close(wall.dimensions[1].valueMeters, 2.5), "Rotation does not invent wall dimensions")
        try check(wall.dimensions[0].start == .init(x: 10,y: 1.75,z: 22), "Wall width sits on its actual transformed lower edge")
        try check(wall.dimensions[1].end == .init(x: 10,y: 4.25,z: 22), "Wall height ends at its own transformed top")
        let parentID = wall.id
        let opening = EmptyRoomSurface(id: UUID(), parentID: parentID, kind: .opening, widthMeters: 1.2, heightMeters: 2.1,
            thicknessMeters: nil, transform: transform, polygonCorners: [], isCurved: false, confidence: .low)
        try check(opening.parentID == parentID && opening.dimensions.count == 2, "Opening annotations preserve wall association")
        try check(close(opening.dimensions[0].valueMeters,1.2) && close(opening.dimensions[1].valueMeters,2.1), "Opening width and height come from native dimensions")
        try check(close(opening.dimensions[0].start.y, 1.95) && close(opening.dimensions[1].end.y,4.05), "Opening coordinates use its own transform, not wall coordinates")
        for kind in [EmptyRoomSurfaceKind.window, .door] {
            var surface = opening; surface.kind = kind
            try check(surface.dimensions.count == 2 && surface.dimensions.first?.title.hasPrefix(surface.title) == true, "Windows and doors have named width/height annotations")
        }
        var curved = wall; curved.isCurved = true
        try check(curved.dimensions.first?.title.contains("габарит") == true, "Curved wall width is explicitly a bounding span, never an invented arc length")
        var missingHeight = wall; missingHeight.heightMeters = nil
        try check(missingHeight.dimensions.count == 1 && missingHeight.dimensions.allSatisfy { !$0.title.contains("высота") }, "Unavailable height never creates a ceiling or a height value")
        var missingFloor = floor; missingFloor.polygonCorners = []
        try check(missingFloor.dimensions.isEmpty && missingFloor.floorAreaSquareMeters == 0, "Missing floor polygon is never replaced by a rectangle")
        var invalidTransform = identity; invalidTransform.columns[15] = 0
        try check(!invalidTransform.isValid && invalidTransform.point(outer[0]) == nil, "Invalid homogeneous transform is rejected")
        var invalidFloor = floor; invalidFloor.polygonCorners[0].x = .nan
        try check(invalidFloor.floorWorldRing.isEmpty && invalidFloor.dimensions.isEmpty, "Nonfinite floor corner produces no fake measurements")
        try check(EmptyRoomTransform(columns: [1,2,3]).point(outer[0]) == nil, "Truncated transform is rejected without indexing out of bounds")
        let large: [EmptyRoomPoint] = [.init(x: 0,y: 0,z: 0),.init(x: 10,y: 0,z: 0),.init(x: 10,y: 0,z: 8),.init(x: 0,y: 0,z: 8)]
        let hole: [EmptyRoomPoint] = [.init(x: 2,y: 0,z: 2),.init(x: 4,y: 0,z: 2),.init(x: 4,y: 0,z: 4),.init(x: 2,y: 0,z: 4)]
        let holeEdges = EmptyRoomRingGeometry.edges(outer: large + [large[0]], holes: [hole + [hole[0]]])
        try check(holeEdges.count == 8 && holeEdges.filter { $0.holeIndex == 0 }.count == 4, "Floor-plan holes close independently, without invented bridge segments")
        try check(close(EmptyRoomRingGeometry.area(outer: large, holes: [hole]),76), "Real hole area is subtracted from floor area")
        try check(close(EmptyRoomRingGeometry.area(outer: large.reversed(), holes: [hole.reversed()]),76), "Ring winding does not invert area")
        try check(holeEdges.filter { $0.holeIndex != nil }.allSatisfy { close($0.length,2) }, "Hole dimensions use only their own ring")
        try check(EmptyRoomRingGeometry.edges(outer: Array(outer.prefix(2))).isEmpty, "Incomplete two-point floor produces no fake boundary")
        var repeated = outer; repeated.insert(outer[0], at: 1)
        try check(EmptyRoomRingGeometry.edges(outer: repeated).count == 4, "Zero-length duplicate edges do not create dimension labels")
        let remoteTiny: [EmptyRoomPoint] = [.init(x: 900_000,y: 0,z: 900_000),.init(x: 900_000.02,y: 0,z: 900_000),.init(x: 900_000.02,y: 0,z: 900_000.03),.init(x: 900_000,y: 0,z: 900_000.03)]
        try check(abs(EmptyRoomRingGeometry.area(outer: remoteTiny) - 0.0006) < 0.000000001, "Small contours far from origin avoid catastrophic area cancellation")

        let storageID = UUID(), clutterID = UUID()
        let root: [String: Any] = ["identifier": UUID().uuidString, "objects": [
            ["identifier": storageID.uuidString, "category": ["storage": [:]], "futureObjectKey": ["observed": true]],
            ["identifier": clutterID.uuidString, "category": ["chair": [:]]]],
            "walls": [["identifier": wall.id.uuidString, "futureCurve": ["radius": 2.2]]],
            "floors": [["polygonCorners": [[0,0,0],[4,0,0],[4,0,3]]]],
            "windows": [1,2], "doors": [3], "openings": [4], "futureRootKey": ["confidence": "medium"]]
        let source = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let original = source
        let kept = try EmptyRoomJSONFilter.filter(source, retaining: [storageID])
        let keptRoot = try JSONSerialization.jsonObject(with: kept) as! [String: Any]
        let keptObjects = keptRoot["objects"] as! [[String: Any]]
        try check(source == original, "Filtering never mutates original byte Data")
        try check(keptObjects.count == 1 && keptObjects[0]["identifier"] as? String == storageID.uuidString, "Only explicitly selected native storage ID is retained")
        try check((keptObjects[0]["futureObjectKey"] as? [String: Bool])?["observed"] == true, "Unknown retained object fields remain intact")
        for key in ["identifier", "walls", "floors", "windows", "doors", "openings", "futureRootKey"] {
            let a = try JSONSerialization.data(withJSONObject: [key: root[key]!], options: [.sortedKeys])
            let b = try JSONSerialization.data(withJSONObject: [key: keptRoot[key]!], options: [.sortedKeys])
            try check(a == b, "Filtering preserves structural/future field " + key)
        }
        let removedRoot = try JSONSerialization.jsonObject(with: EmptyRoomJSONFilter.filter(source, retaining: [])) as! [String: Any]
        try check((removedRoot["objects"] as? [Any])?.isEmpty == true, "Default clean mode removes all clutter and storage")
        try reject("Unknown retained UUID") { _ = try EmptyRoomJSONFilter.filter(source, retaining: [UUID()]) }
        try reject("Missing objects field") { _ = try EmptyRoomJSONFilter.filter(Data("{\"walls\":[]}".utf8), retaining: []) }
        try reject("Unknown objects encoding") { _ = try EmptyRoomJSONFilter.filter(Data("{\"objects\":{}}".utf8), retaining: []) }
        try reject("Unknown identifier encoding") { _ = try EmptyRoomJSONFilter.filter(Data("{\"objects\":[{\"identifier\":42}]}".utf8), retaining: []) }
        try reject("Invalid UUID") { _ = try EmptyRoomJSONFilter.filter(Data("{\"objects\":[{\"identifier\":\"wrong\"}]}".utf8), retaining: []) }
        let duplicate = try JSONSerialization.data(withJSONObject: ["objects": [["identifier": storageID.uuidString],["identifier": storageID.uuidString]]])
        try reject("Duplicate IDs") { _ = try EmptyRoomJSONFilter.filter(duplicate, retaining: [storageID]) }
        try reject("Non-object root") { _ = try EmptyRoomJSONFilter.filter(Data("[]".utf8), retaining: []) }
        let empty = try EmptyRoomJSONFilter.filter(Data("{\"objects\":[],\"walls\":[]}".utf8), retaining: [])
        try check((try JSONSerialization.jsonObject(with: empty) as? [String: Any])?["walls"] != nil, "Native empty object list preserves its other fields")

        let projectID = UUID(), frameID = UUID()
        let document = EmptyRoomDocument(sourceRoomID: UUID(), captureID: UUID(), projectID: projectID, frameID: frameID,
            capturedAt: Date(timeIntervalSince1970: 12345), sourceRoomJSONSHA256: String(repeating: "a", count: 64), story: 2,
            keepStorage: false, removedObjectCount: 2, surfaces: [floor,wall,opening], storage: [], notices: ["Review required"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(EmptyRoomDocument.self, from: encoder.encode(document))
        try check(roundTrip.frameID == frameID && roundTrip.projectID == projectID && roundTrip.story == 2, "Portable sidecar keeps frame/project/floor provenance")
        try check(roundTrip.ceilingObserved == false && roundTrip.reviewStatus == "semanticDraftRequiresReview", "Sidecar cannot claim an observed ceiling or reviewed accuracy")
        try check(roundTrip.sourceRoomJSONSHA256 == document.sourceRoomJSONSHA256 && roundTrip.units == "metres", "Sidecar keeps source identity and explicit units")
        try check(roundTrip.dimensions.count == 8 && close(roundTrip.floorAreaSquareMeters,12), "Round-trip derives measurements from preserved geometry")
        try check(roundTrip.uncertainSurfaceCount == 2, "Confidence count reflects actual medium/low surfaces")
        try check(roundTrip.floorAreaPolicy.contains("projection") && roundTrip.floorAreaPolicy.contains("without overlap"), "Area provenance does not claim true sloped surface area or a union of rooms")
        print("EmptyRoom geometry/source filtering: \(passed) checks passed")
    }
}
#endif
