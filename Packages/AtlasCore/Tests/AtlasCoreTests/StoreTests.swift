import Foundation
import Testing
import CSQLite
@testable import AtlasCore

private func temporaryDatabase() throws -> (directory: URL, path: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("project.sqlite").path)
}

private func feature(for project: AtlasProject) -> AtlasFeature {
    let frame = project.coordinateReference.frameID!
    let polygon = MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 6), .init(x: 0, y: 6)])
    return AtlasFeature(projectID: project.id, label: "Участок 12", category: .grave, geometry: .metricPolygon(polygon),
                        attributes: ["section": "А", "record": "12"], reviewStatus: .reviewed)
}

private func executeSQL(path: String, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(path, &database) == SQLITE_OK, let database else { throw AtlasStoreError.invalidRecord("Test DB cannot open") }
    defer { sqlite3_close(database) }
    let code = sqlite3_exec(database, sql, nil, nil, nil)
    guard code == SQLITE_OK else { throw AtlasStoreError.database(code: code, message: String(cString: sqlite3_errmsg(database))) }
}

@Test func savedProjectFeatureAndPlanSurviveReopening() async throws {
    let temporary = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: temporary.directory) }
    let store = try AtlasStore(path: temporary.path)
    let project = try await store.saveProject(AtlasProject(name: "Некрополь", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID())))
    let savedFeature = try await store.saveFeature(feature(for: project))
    guard case let .metricPolygon(boundary) = savedFeature.geometry else { return }
    let plan = try await store.saveFloorPlan(AtlasFloorPlan(projectID: project.id, frameID: boundary.frameID,
                                                          rooms: [.init(name: "Зал", boundary: boundary)]))
    let reopened = try AtlasStore(path: temporary.path)
    let snapshot = try await reopened.snapshot(projectID: project.id)
    #expect(snapshot.features == [savedFeature])
    #expect(snapshot.floorPlans == [plan])
    #expect(snapshot.project.name == "Некрополь")
    #expect(try await reopened.pendingOutbox().count == 3)
    #expect(try PolygonGeometry.area(of: snapshot.floorPlans[0].rooms[0].boundary) == 24)
}

@Test func staleEditsAndInvalidCoordinatesCannotOverwriteSavedGeometry() async throws {
    let temporary = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: temporary.directory) }
    let store = try AtlasStore(path: temporary.path)
    let project = try await store.saveProject(AtlasProject(name: "Test", kind: .site, coordinateReference: .localMeters(frameID: UUID())))
    let original = try await store.saveFeature(feature(for: project))
    var changed = original
    changed.notes = "Updated"
    let saved = try await store.saveFeature(changed)
    await #expect(throws: AtlasStoreError.revisionConflict(entityID: original.id, expected: 1, actual: 2)) {
        try await store.saveFeature(original)
    }
    var invalid = saved
    if case var .metricPolygon(polygon) = invalid.geometry {
        polygon.frameID = UUID()
        invalid.geometry = .metricPolygon(polygon)
    }
    await #expect(throws: GeometryError.coordinateFrameMismatch) { try await store.saveFeature(invalid) }
    #expect(try await store.features(projectID: project.id) == [saved])
    #expect(try await store.pendingOutbox().count == 3)
}

@Test func failedOutboxWriteRollsBackTheEntityWrite() async throws {
    let temporary = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: temporary.directory) }
    let store = try AtlasStore(path: temporary.path)
    let project = try await store.saveProject(AtlasProject(name: "Test", kind: .cemetery, coordinateReference: .localMeters(frameID: UUID())))
    try executeSQL(path: temporary.path, "CREATE TRIGGER reject_outbox BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'simulated outbox failure'); END;")
    await #expect(throws: AtlasStoreError.self) { try await store.saveFeature(feature(for: project)) }
    #expect(try await store.features(projectID: project.id).isEmpty)
    #expect(try await store.pendingOutbox().count == 1)
}

@Test func migrationPreservesVersionOneProjectAndAddsDurableOutbox() async throws {
    let temporary = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: temporary.directory) }
    let project = AtlasProject(name: "Legacy", kind: .site, coordinateReference: .localMeters(frameID: UUID()), revision: 1)
    let payload = try AtlasJSON.encode(project).map { String(format: "%02x", $0) }.joined()
    try executeSQL(path: temporary.path, """
        CREATE TABLE projects(id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE features(id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), revision INTEGER NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE floor_plans(id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), revision INTEGER NOT NULL, payload BLOB NOT NULL);
        CREATE TABLE scans(id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), revision INTEGER NOT NULL, payload BLOB NOT NULL);
        INSERT INTO projects VALUES ('\(project.id.uuidString)', 1, X'\(payload)');
        PRAGMA user_version = 1;
        """)
    let store = try AtlasStore(path: temporary.path)
    #expect(try await store.project(id: project.id)?.name == "Legacy")
    #expect(try await store.pendingOutbox().isEmpty)
    _ = try await store.saveFeature(feature(for: project))
    #expect(try await store.pendingOutbox().count == 1)
    let reopened = try AtlasStore(path: temporary.path)
    #expect(try await reopened.features(projectID: project.id).count == 1)
}

@Test func unknownFutureSchemaIsRejected() throws {
    let temporary = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: temporary.directory) }
    try executeSQL(path: temporary.path, "PRAGMA user_version = 999")
    #expect(throws: AtlasStoreError.unsupportedSchema(999)) { _ = try AtlasStore(path: temporary.path) }
}

@Test func outboxRetryKeepsIdentityAndAcknowledgementIsIdempotent() async throws {
    let store = try AtlasStore(path: ":memory:")
    _ = try await store.saveProject(AtlasProject(name: "Test", kind: .site, coordinateReference: .wgs84))
    let first = try await store.pendingOutbox()
    #expect(try await store.pendingOutbox() == first)
    try await store.acknowledgeOutbox(eventIDs: first.map(\.id))
    try await store.acknowledgeOutbox(eventIDs: first.map(\.id))
    #expect(try await store.pendingOutbox().isEmpty)
}

@Test func consistentBackupContainsCommittedEntitiesAndOutbox() async throws {
    let temporary = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: temporary.directory) }
    let store = try AtlasStore(path: temporary.path)
    let project = try await store.saveProject(AtlasProject(name: "Backup", kind: .site, coordinateReference: .localMeters(frameID: UUID())))
    _ = try await store.saveFeature(feature(for: project))
    let backupPath = temporary.directory.appendingPathComponent("backup.sqlite").path
    try await store.backupDatabase(to: backupPath)
    let backup = try AtlasStore(path: backupPath)
    #expect(try await backup.features(projectID: project.id).count == 1)
    #expect(try await backup.pendingOutbox().count == 2)
}

@Test func scanManifestRejectsPathTraversalAndKeepsInterruptedCapture() async throws {
    let store = try AtlasStore(path: ":memory:")
    let frame = UUID()
    let project = try await store.saveProject(AtlasProject(name: "Capture", kind: .building, coordinateReference: .localMeters(frameID: frame)))
    var scan = ScanRecord(projectID: project.id, source: .roomPlan, status: .interrupted, frameID: frame,
                          assets: [.init(relativePath: "../other-project/data.json", kind: .roomPlanJSON, byteCount: 12)])
    await #expect(throws: AtlasStoreError.invalidAssetPath("../other-project/data.json")) { try await store.saveScan(scan) }
    scan.assets[0].relativePath = "scans/room.json"
    let saved = try await store.saveScan(scan)
    #expect(try await store.scans(projectID: project.id) == [saved])
    #expect(saved.status == .interrupted)
}

@Test func saveReturnsExactPersistedDatesAcrossAdversarialSubsecondTimestamps() async throws {
    let temporary = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: temporary.directory) }
    let store = try AtlasStore(path: temporary.path)
    let frame = UUID()
    var projects: [AtlasProject] = []
    var scans: [ScanRecord] = []

    // Adjacent Double values expose epoch conversion/multiplication rounding
    // deterministically, including modern dates, past dates and far-future dates.
    for base: TimeInterval in [-0.125, 400_000_000, 789_123_456, 4_000_000_000] {
        var timestamp = base
        for offset in 1...16 {
            timestamp = timestamp.nextUp
            let created = Date(timeIntervalSinceReferenceDate: timestamp)
            var project = try await store.saveProject(AtlasProject(name: "Date \(base)-\(offset)", kind: .site,
                coordinateReference: .localMeters(frameID: frame), createdAt: created, updatedAt: created))
            #expect(try await store.project(id: project.id) == project)
            // Updating a canonical returned value must retain exact identity too.
            project.notes = "Second revision"
            project = try await store.saveProject(project)
            #expect(project.revision == 2)
            #expect(try await store.project(id: project.id) == project)
            projects.append(project)

            var scan = try await store.saveScan(ScanRecord(projectID: project.id, source: .liDAR,
                status: .interrupted, frameID: frame, createdAt: created))
            #expect(try await store.scans(projectID: project.id) == [scan])
            scan.status = .ready
            scan = try await store.saveScan(scan)
            #expect(scan.revision == 2)
            #expect(try await store.scans(projectID: project.id) == [scan])
            scans.append(scan)
        }
    }

    #expect(projects.count == 64)
    let reopened = try AtlasStore(path: temporary.path)
    for (project, scan) in zip(projects, scans) {
        #expect(try await reopened.project(id: project.id) == project)
        #expect(try await reopened.scans(projectID: project.id) == [scan])
        let snapshot = try await reopened.snapshot(projectID: project.id)
        #expect(snapshot.project == project)
        #expect(snapshot.scans == [scan])
    }
}

@Test func independentRoomPlanFrameIsPreservedInsideTheProject() async throws {
    let store = try AtlasStore(path: ":memory:")
    let projectFrame = UUID(), sessionFrame = UUID()
    let project = try await store.saveProject(AtlasProject(name: "House", kind: .building, coordinateReference: .localMeters(frameID: projectFrame)))
    let boundary = MetricPolygon(frameID: sessionFrame, vertices: [.init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 6), .init(x: 0, y: 6)])
    let plan = try await store.saveFloorPlan(AtlasFloorPlan(projectID: project.id, frameID: sessionFrame,
                                                          rooms: [.init(name: "Room", boundary: boundary)]))
    #expect(plan.frameID == sessionFrame)
    let snapshot = try await store.snapshot(projectID: project.id)
    #expect(snapshot.project.coordinateReference.frameID == projectFrame)
    #expect(snapshot.floorPlans[0].frameID != projectFrame)
    #expect(throws: GeometryError.coordinateFrameMismatch) { try AtlasExporter.export(snapshot, format: .dxf) }
    #expect(try AtlasExporter.export(snapshot, format: .projectJSON).data.count > 0)
    #expect(try AtlasExporter.exportFloorPlan(plan).fileName.contains("-plan-"))
}
