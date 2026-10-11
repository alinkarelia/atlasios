#if ATLAS_BUILDING_INDEX_CHECKS
import Foundation

@main
struct BuildingPlanIndexChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("building-index-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID()
        let store = BuildingPlanIndexStore(directory: root, projectID: projectID)
        let file = store.fileURL
        var passed = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CheckFailure(message) }
            passed += 1
        }
        func rejects(_ message: String, _ action: () async throws -> Void) async throws {
            do { try await action() }
            catch { passed += 1; return }
            throw CheckFailure("Expected rejection: " + message)
        }
        func preserve(_ message: String, _ action: () async throws -> Void) async throws {
            let before = try Data(contentsOf: file)
            try await rejects(message, action)
            try check(try Data(contentsOf: file) == before, message + " keeps the existing file")
        }

        var snapshot = try await store.load()
        try check(snapshot.projectID == projectID && snapshot.revision == 0 && snapshot.floors.isEmpty, "Missing catalog starts empty for its project")
        try check(!FileManager.default.fileExists(atPath: file.path), "Read-only load creates no files")
        try check(file.path.hasSuffix("Projects/\(projectID.uuidString)/Captures/Design/plan-associations.json"), "Sidecar is in project capture directory for packaging")
        snapshot = try await store.renameBuilding("  Дом на Садовой  ")
        try check(snapshot.buildingName == "Дом на Садовой" && snapshot.revision == 1, "Building title is trimmed and versioned")
        snapshot = try await store.saveFloor(.init(floorIndex: -1, name: "Цоколь"))
        snapshot = try await store.saveFloor(.init(floorIndex: 2, name: "Жилой этаж"))
        try check(snapshot.floors.map(\.floorIndex) == [-1, 2], "Floors preserve signed actual indices")
        snapshot = try await store.saveFloor(.init(floorIndex: 2, name: "Второй этаж"))
        try check(snapshot.floors.count == 2 && snapshot.floorName(2) == "Второй этаж", "Renaming floor updates its exact key")
        try check(snapshot.floorName(0) == "Этаж 0", "Implicit plan floors get a deterministic label")

        let first = BuildingPlanApartment(floorIndex: 2, label: "Квартира 12")
        let second = BuildingPlanApartment(floorIndex: 2, label: "Квартира 13")
        let otherFloor = BuildingPlanApartment(floorIndex: -1, label: "Квартира 12")
        snapshot = try await store.saveApartment(first)
        snapshot = try await store.saveApartment(second)
        snapshot = try await store.saveApartment(otherFloor)
        try check(snapshot.apartments.count == 3, "Same apartment label is allowed on a different floor")
        try await preserve("Case insensitive apartment duplicates") { _ = try await store.saveApartment(.init(floorIndex: 2, label: "  квартира 12  ")) }
        try await preserve("Invalid floor") { _ = try await store.saveFloor(.init(floorIndex: 501, name: "Invalid")) }
        try await preserve("Invalid apartment floor") { _ = try await store.saveApartment(.init(floorIndex: -101, label: "Invalid")) }
        try await preserve("Blank name") { _ = try await store.renameBuilding(" \n ") }
        try await preserve("Control characters") { _ = try await store.saveApartment(.init(floorIndex: 2, label: "Квартира\n14")) }
        try await preserve("Long names") { _ = try await store.renameBuilding(String(repeating: "x", count: 201)) }

        let planA = UUID(), planB = UUID(), planC = UUID()
        snapshot = try await store.assign(planID: planA, apartmentID: first.id, floorIndex: 2)
        snapshot = try await store.assign(planID: planB, apartmentID: first.id, floorIndex: 2)
        snapshot = try await store.assign(planID: planC, apartmentID: second.id, floorIndex: 2)
        try check(snapshot.apartment(for: planA, floorIndex: 2)?.id == first.id && snapshot.apartment(for: planB, floorIndex: 2)?.id == first.id, "Multiple exact plan IDs can belong to one apartment")
        try check(snapshot.apartment(for: UUID(), floorIndex: 2) == nil, "Unrelated plan ID cannot inherit a link by array position")
        try check(snapshot.apartment(for: planA, floorIndex: -1) == nil, "Moved plan does not silently retain a wrong-floor apartment")
        try await preserve("Wrong-floor assignment") { _ = try await store.assign(planID: planA, apartmentID: otherFloor.id, floorIndex: 2) }
        try await preserve("Unknown apartment") { _ = try await store.assign(planID: planA, apartmentID: UUID(), floorIndex: 2) }
        var moved = first; moved.floorIndex = 3
        try await preserve("Move occupied apartment") { _ = try await store.saveApartment(moved) }
        try await preserve("Remove occupied floor") { _ = try await store.deleteFloor(2) }
        var renamed = first; renamed.label = "Квартира 12А"
        snapshot = try await store.saveApartment(renamed)
        try check(snapshot.apartment(for: planA, floorIndex: 2)?.label == "Квартира 12А", "Renaming apartment keeps exact plan links")
        snapshot = try await store.assign(planID: planB, apartmentID: second.id, floorIndex: 2)
        try check(snapshot.associations.count == 3 && snapshot.apartment(for: planB, floorIndex: 2)?.id == second.id, "Reassign replaces one link rather than duplicating it")
        snapshot = try await store.assign(planID: planC, apartmentID: nil, floorIndex: 2)
        try check(snapshot.associations.count == 2 && snapshot.apartment(for: planC, floorIndex: 2) == nil, "Unassign removes only the selected plan link")

        let reopened = BuildingPlanIndexStore(directory: root, projectID: projectID)
        let reloaded = try await reopened.load()
        try check(reloaded.buildingName == snapshot.buildingName && reloaded.associations == snapshot.associations && reloaded.apartments == snapshot.apartments && reloaded.revision == snapshot.revision, "Reload preserves the versioned catalog")
        snapshot = try await reopened.deleteApartment(first.id)
        try check(!snapshot.apartments.contains { $0.id == first.id } && snapshot.apartment(for: planA, floorIndex: 2) == nil && snapshot.apartment(for: planB, floorIndex: 2)?.id == second.id, "Delete apartment removes only its organizational links")
        snapshot = try await store.renameBuilding("Обновлённый дом")
        try check(!snapshot.apartments.contains { $0.id == first.id }, "Mutation reloads file and preserves changes made by another store instance")
        snapshot = try await store.deleteApartment(second.id)
        snapshot = try await store.deleteFloor(2)
        try check(!snapshot.floors.contains { $0.floorIndex == 2 }, "Empty floor metadata can be removed")
        let revisionBeforeConcurrentEdits = snapshot.revision
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<20 {
                group.addTask {
                    let worker = BuildingPlanIndexStore(directory: root, projectID: projectID)
                    _ = try await worker.saveApartment(.init(floorIndex: 3, label: "Параллельная квартира \(value)"))
                }
            }
            try await group.waitForAll()
        }
        snapshot = try await store.load()
        try check(snapshot.apartments.filter { $0.floorIndex == 3 }.count == 20, "Concurrent actor instances preserve every catalog edit")
        try check(snapshot.revision == revisionBeforeConcurrentEdits + 20, "Concurrent saves each advance the persisted revision")
        let validData = try Data(contentsOf: file)
        var json = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
        json["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
        try await preserve("Unknown schema version") { _ = try await store.renameBuilding("Would overwrite") }
        json["schemaVersion"] = 1
        json["projectID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
        try await preserve("Wrong project in sidecar") { _ = try await store.renameBuilding("Would overwrite") }
        try Data("not JSON".utf8).write(to: file, options: .atomic)
        try await preserve("Corrupt JSON") { _ = try await store.saveFloor(.init(floorIndex: 0, name: "Would overwrite")) }
        try validData.write(to: file, options: .atomic)
        json = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
        json["associations"] = [["planID": planA.uuidString, "apartmentID": UUID().uuidString, "floorIndex": -1]]
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
        try await preserve("Dangling apartment link") { _ = try await store.renameBuilding("Would overwrite") }
        try validData.write(to: file, options: .atomic)
        let backupFile = root.appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: file, to: backupFile)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try await rejects("Directory at file path cannot be overwritten") { _ = try await store.renameBuilding("Would overwrite") }
        var isDirectory: ObjCBool = false
        try check(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue, "IO failure preserves destination directory")
        print("BuildingPlanIndex: \(passed) checks passed")
    }
}

private struct CheckFailure: Error { let message: String; init(_ message: String) { self.message = message } }
#endif
