#if ATLAS_EMPTY_ROOM_REVIEW_CHECKS
import Foundation

@main
struct EmptyRoomSurfaceReviewChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() async throws {
        var passed = 0
        func check(_ condition: Bool, _ message: String) throws { guard condition else { throw Failure(description: message) }; passed += 1 }
        func reject(_ message: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { passed += 1; return }; throw Failure(description: message)
        }
        func rejectAsync(_ message: String, _ operation: () async throws -> Void) async throws {
            do { try await operation() } catch { passed += 1; return }; throw Failure(description: message)
        }
        func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.000001 } ?? false }
        let wallID = UUID(), doorID = UUID(), captureID = UUID()
        let identity = EmptyRoomTransform(columns: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])
        var wallTransform = identity; wallTransform.columns[13] = 1.5
        var doorTransform = identity; doorTransform.columns[13] = 1
        let wall = EmptyRoomSurface(id: wallID, parentID: nil, kind: .wall, widthMeters: 4, heightMeters: 3,
            thicknessMeters: nil, transform: wallTransform,
            polygonCorners: [.init(x: -2,y: -1.5,z: 0), .init(x: 2,y: -1.5,z: 0), .init(x: 2,y: 1.5,z: 0), .init(x: -2,y: 1.5,z: 0)], isCurved: false, confidence: .high)
        let door = EmptyRoomSurface(id: doorID, parentID: wallID, kind: .door, widthMeters: 1, heightMeters: 2,
            thicknessMeters: nil, transform: doorTransform,
            polygonCorners: [.init(x: -0.5,y: -1,z: 0), .init(x: 0.5,y: -1,z: 0), .init(x: 0.5,y: 1,z: 0), .init(x: -0.5,y: 1,z: 0)], isCurved: false, confidence: .medium)
        let floor = EmptyRoomSurface(id: UUID(), parentID: nil, kind: .floor, widthMeters: nil, heightMeters: nil,
            thicknessMeters: nil, transform: identity,
            polygonCorners: [.init(x: 0,y: 0,z: 0), .init(x: 4,y: 0,z: 0), .init(x: 4,y: 0,z: 3), .init(x: 0,y: 0,z: 3)], isCurved: false, confidence: .high)
        let source = EmptyRoomDocument(sourceRoomID: UUID(), captureID: captureID, projectID: UUID(), frameID: UUID(),
            capturedAt: Date(timeIntervalSince1970: 1_000), sourceRoomJSONSHA256: String(repeating: "a", count: 64),
            story: 1, keepStorage: false, removedObjectCount: 0, surfaces: [wall, door, floor], storage: [], notices: [])
        var review = EmptyRoomSurfaceReview(source: source)
        let wallEvent = EmptyRoomReviewEvent(createdAt: Date(timeIntervalSince1970: 1_001), targetID: wallID, sourceSurfaceID: wallID,
            label: "Стена", role: .wall, semanticVerified: true, dimensionMeaning: .reportedBounds, openingCoverageComplete: true, note: "Вся стена проверена", observation: nil)
        let doorEvent = EmptyRoomReviewEvent(createdAt: Date(timeIntervalSince1970: 1_002), targetID: doorID, sourceSurfaceID: doorID,
            label: "Дверь", role: .roomDoor, semanticVerified: true, dimensionMeaning: .clearOpening, openingGeometryVerified: true, note: "Контур светового проёма проверен", observation: nil)
        review.events = [wallEvent, doorEvent]; review.revision = 2; review.updatedAt = doorEvent.createdAt
        try EmptyRoomSurfaceReviewPolicy.validate(review, source: source)
        let quantity = EmptyRoomQuantities.summary(source, review: review)
        try check(close(quantity.floorGrossSquareMeters, 12), "Floor gross is the actual horizontal contour projection")
        try check(quantity.floorNetSquareMeters == nil, "RoomPlan has no explicit hole inventory; floor net stays unknown")
        try check(close(quantity.wallGrossSquareMeters, 12) && close(quantity.wallNetSquareMeters, 10), "A verified contained 1x2 bottom-touching door subtracts exactly 2m2 from a 4x3 wall")
        try check(close(quantity.walls[0].openingSquareMeters, 2), "Door area has an actual parent and polygon, not only bounding dimensions")
        try check(quantity.unknownWallCount == 0 && quantity.unknownNetWallCount == 0, "Known counts derive from supplied wall geometry")
        try check(EmptyRoomQuantities.summary(source, review: nil).wallNetSquareMeters == nil, "Unverified opening coverage cannot become net area")
        var noCoverage = review; noCoverage.events[0].openingCoverageComplete = false
        try check(EmptyRoomQuantities.summary(source, review: noCoverage).wallNetSquareMeters == nil, "Confirmed opening role alone does not prove complete wall coverage")
        var changed = source; changed.surfaces[1].polygonCorners = []
        try check(EmptyRoomQuantities.summary(changed, review: review).wallNetSquareMeters == nil, "W x H bounding box is not a measured arched opening polygon")
        changed = source; changed.surfaces[1].parentID = nil
        try check(EmptyRoomQuantities.summary(changed, review: review).wallNetSquareMeters == nil, "An unparented opening cannot be assigned to a guessed wall")
        changed = source; changed.surfaces[1].transform.columns[14] = 0.02
        try check(EmptyRoomQuantities.summary(changed, review: review).wallNetSquareMeters == nil, "An opening outside the actual wall plane is not deducted")
        changed = source; changed.surfaces[1].transform.columns[12] = 4
        try check(EmptyRoomQuantities.summary(changed, review: review).wallNetSquareMeters == nil, "An opening outside wall bounds is not deducted")
        changed = source; var duplicate = door; duplicate.id = UUID(); changed.surfaces.append(duplicate)
        var overlapped = review; var duplicateEvent = doorEvent; duplicateEvent.id = UUID(); duplicateEvent.targetID = duplicate.id; duplicateEvent.sourceSurfaceID = duplicate.id
        overlapped.events.append(duplicateEvent); overlapped.revision = 3
        try check(EmptyRoomQuantities.summary(changed, review: overlapped).wallNetSquareMeters == nil, "Overlapping openings never inflate deduction")
        changed = source; changed.surfaces[0].isCurved = true
        try check(EmptyRoomQuantities.summary(changed, review: review).wallGrossSquareMeters == nil, "Curved-wall envelope is not an invented arc area")
        changed = source; changed.surfaces[0].heightMeters = nil; changed.surfaces[0].polygonCorners = []
        let missing = EmptyRoomQuantities.summary(changed, review: nil)
        try check(missing.wallGrossSquareMeters == nil && missing.unknownWallCount == 1, "Unknown height/contour stays unknown instead of zero square metres")
        changed = source; changed.surfaces = []
        try check(EmptyRoomQuantities.summary(changed, review: nil).floorGrossSquareMeters == nil && EmptyRoomQuantities.summary(changed, review: nil).wallGrossSquareMeters == nil, "No surveyed planes never produce fabricated area totals")
        changed.storage = [.init(id: UUID(), widthMeters: 2, heightMeters: 3, depthMeters: 0.6, transform: identity, confidence: .high)]
        try check(EmptyRoomReviewPresentation.dimensions(changed, review: nil).isEmpty, "A storage box never creates a cabinet-door leaf dimension")
        try check(EmptyRoomReviewRole.reported(.door).symbol == "D" && EmptyRoomReviewRole.reported(.window).symbol == "W" && EmptyRoomReviewRole.reported(.opening).symbol == "P" && EmptyRoomReviewRole.cabinetDoor.symbol == "K", "Door/window/passage/manual cabinet roles remain distinct")
        changed = source; let sine = sqrt(0.5); changed.surfaces[1].transform.columns = [1,0,0,0, 0,sine,sine,0, 0,-sine,sine,0, 0,1,0,1]
        try check(EmptyRoomReviewPresentation.dimensions(changed, review: nil).contains { $0.sourceID == doorID && $0.title.contains("Hₛ") }, "Tilted native height is along-surface Hs, not gravity H")
        let labels = EmptyRoomReviewPresentation.dimensions(source, review: nil)
        try check(labels.contains { $0.title.hasPrefix("D?") } && !labels.contains { $0.title.hasPrefix("K") }, "Native classification stays unverified and storage is not relabelled a door")
        for key in 0..<5 {
            var invalid = review
            switch key { case 0: invalid.projectID = UUID(); case 1: invalid.captureID = UUID(); case 2: invalid.frameID = UUID(); case 3: invalid.sourceRoomID = UUID(); default: invalid.sourceRoomJSONSHA256 = String(repeating: "b", count: 64) }
            try reject("A foreign source binding must be rejected") { try EmptyRoomSurfaceReviewPolicy.validate(invalid, source: source) }
        }
        changed = source; changed.surfaces.append(wall)
        try reject("Duplicate source IDs must fail without a Dictionary trap") { try EmptyRoomSurfaceReviewPolicy.validate(review, source: changed) }
        var bad = review; bad.events[1].id = bad.events[0].id
        try reject("Duplicate event IDs must fail") { try EmptyRoomSurfaceReviewPolicy.validate(bad, source: source) }
        bad = review; bad.events[1].role = .cabinetDoor
        try reject("Cabinet leaf cannot masquerade as clear wall passage") { try EmptyRoomSurfaceReviewPolicy.validate(bad, source: source) }
        bad = review; bad.events[0].semanticVerified = false
        try reject("Unverified wall cannot assert complete opening coverage") { try EmptyRoomSurfaceReviewPolicy.validate(bad, source: source) }
        bad = review; bad.revision = 9
        try reject("Journal revision must match immutable event history") { try EmptyRoomSurfaceReviewPolicy.validate(bad, source: source) }
        let profileID = UUID()
        func control(_ value: Double, position: String) -> EmptyRoomControlObservation {
            .init(measurementID: UUID(), measurementRevision: 1, label: "Световой проход", source: "manualReference", kind: "distance", role: "width", definition: "clearOpening", position: position, positionNote: "", profileID: profileID, frameID: nil, start: nil, end: nil, originalMeters: value, effectiveMeters: value, observedAt: Date(timeIntervalSince1970: 1_000), rawMeasurementJSON: nil)
        }
        let lower = control(0.9, position: "lower"), upper = control(0.85, position: "upper")
        var linked = review
        var firstControl = doorEvent; firstControl.id = UUID(); firstControl.createdAt = Date(timeIntervalSince1970: 1_003); firstControl.observation = lower
        var corrected = lower; corrected.measurementRevision = 2; corrected.effectiveMeters = 0.88; corrected.label = "Поправленный обмер"
        var correctionEvent = doorEvent; correctionEvent.id = UUID(); correctionEvent.createdAt = Date(timeIntervalSince1970: 1_004); correctionEvent.observation = corrected
        linked.events += [firstControl, correctionEvent]; linked.revision = 4; linked.updatedAt = correctionEvent.createdAt
        try EmptyRoomSurfaceReviewPolicy.validate(linked, source: source)
        try check(linked.events[2].observation?.effectiveMeters == 0.9, "A scalar correction preserves the original observation in immutable history")
        try check(linked.controls(for: doorID).first?.effectiveMeters == 0.88, "Latest corrected scalar remains usable without changing original context")
        for field in 0..<6 {
            var forged = linked
            switch field {
            case 0: forged.events[3].observation?.originalTargetID = doorID
            case 1: forged.events[3].observation?.profileID = UUID()
            case 2: forged.events[3].observation?.role = "height"
            case 3: forged.events[3].observation?.definition = "doorLeaf"
            case 4: forged.events[3].observation?.position = "upper"
            default: forged.events[3].observation?.positionNote = "Другая точка"
            }
            try reject("A higher scalar revision must not rewrite physical target, profile, role, definition or position") { try EmptyRoomSurfaceReviewPolicy.validate(forged, source: source) }
        }
        var other = control(2, position: "middle"); other.role = "surfaceHeight"
        let ranges = EmptyRoomReviewPresentation.ranges([lower, upper, other])
        try check(ranges.count == 1 && ranges[0].contains("2 точек"), "Only the two compatible widths form a range; Hs is not mixed in")
        var leaf = control(0.8, position: "middle"); leaf.definition = "doorLeaf"
        try check(EmptyRoomReviewPresentation.ranges([lower, leaf]).isEmpty, "Clear passage and leaf widths must not be merged")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("room-review-checks-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let capture = workspace.appendingPathComponent("room-\(captureID.uuidString)", isDirectory: true)
        let directory = capture.appendingPathComponent("empty-room", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("Immutable raw RoomPlan test bytes".utf8)
        let originalURL = capture.appendingPathComponent("room.json"); try original.write(to: originalURL)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let file = directory.appendingPathComponent(EmptyRoomSurfaceReviewPolicy.fileName)
        let store = EmptyRoomSurfaceReviewStore(directory: directory, source: source)
        try await rejectAsync("An unregistered asset must not be silently created") { _ = try await store.append(wallEvent, expectedRevision: 0) }
        try encoder.encode(EmptyRoomSurfaceReview(source: source)).write(to: file, options: .atomic)
        let saved = try await store.append(wallEvent, expectedRevision: 0)
        try check(saved.events.count == 1 && saved.revision == 1, "Actual atomic append preserves the real event and revision")
        let persisted = try await EmptyRoomSurfaceReviewStore(directory: directory, source: source).load()
        try check(persisted.events == saved.events && persisted.revision == 1, "A separate actor reloads the exact persisted history")
        let before = try Data(contentsOf: file)
        try await rejectAsync("A stale writer must fail instead of losing events") { _ = try await store.append(doorEvent, expectedRevision: 0) }
        try check(try Data(contentsOf: file) == before, "Conflict leaves the registered journal byte-for-byte intact")
        _ = try await store.append(doorEvent, expectedRevision: 1)
        try check(try await store.load().events.first == wallEvent, "Appending never overwrites an earlier decision")
        try check(try Data(contentsOf: originalURL) == original, "All operator edits leave raw room.json unchanged")
        let broken = Data("broken-json".utf8); try broken.write(to: file)
        try await rejectAsync("Malformed journal must not be reset") { _ = try await store.load() }
        try await rejectAsync("Malformed history cannot be overwritten by append") { _ = try await store.append(wallEvent, expectedRevision: 0) }
        try check(try Data(contentsOf: file) == broken, "Malformed journal is retained for recovery")
        try Data().write(to: file)
        try await rejectAsync("An empty journal is not a healthy document") { _ = try await store.load() }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: originalURL)
        try await rejectAsync("A source-file alias must be rejected") { _ = try await store.load() }
        try check(try Data(contentsOf: originalURL) == original, "Rejected symlink cannot clobber raw source")
        let invalidDirectory = workspace.appendingPathComponent("unmanaged", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        try await rejectAsync("The review must remain in its capture/derivative directory") { _ = try await EmptyRoomSurfaceReviewStore(directory: invalidDirectory, source: source).load() }
        print("EmptyRoom review/quantities: \(passed) checks passed")
    }
}
#endif
