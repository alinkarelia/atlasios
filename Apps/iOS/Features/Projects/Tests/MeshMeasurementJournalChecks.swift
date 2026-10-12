import AtlasCore
import Foundation

private struct JournalCheckFailure: Error { let message: String }

@main private enum MeshMeasurementJournalChecks {
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("atlas-model-measurements-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw JournalCheckFailure(message: message) }; checks += 1
        }
        func rejects(_ message: String, _ operation: () async throws -> Void) async throws {
            var rejected = false
            do { try await operation() } catch { rejected = true }
            try check(rejected, message)
        }
        let project = UUID(), otherProject = UUID(), frame = UUID(), profile = UUID()
        let projectRoot = root.appendingPathComponent(project.uuidString), otherRoot = root.appendingPathComponent(otherProject.uuidString)
        try manager.createDirectory(at: projectRoot, withIntermediateDirectories: false)
        try manager.createDirectory(at: otherRoot, withIntermediateDirectories: false)
        let directory = projectRoot.appendingPathComponent("ModelMeasurements")
        let source = root.appendingPathComponent("mesh.obj")
        let original = Data(("# Atlas ARKit mesh. metres. Y up. local frame " + frame.uuidString + "\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n").utf8)
        try original.write(to: source)
        let evidence = try MeshDimensionSource.inspect(source, atlasOBJ: true)
        try check(evidence.sha256 == FieldTransferDigest.sha256(original), "Exact source bytes bind the journal")
        try check(evidence.frameID == frame && evidence.metresKnown && evidence.gravityYKnown, "Valid Atlas header supplies frame/metres/gravity")
        let unknown = root.appendingPathComponent("room.usdz")
        try Data("foreign model".utf8).write(to: unknown)
        let unknownEvidence = try MeshDimensionSource.inspect(unknown, atlasOBJ: false)
        try check(!unknownEvidence.metresKnown && !unknownEvidence.gravityYKnown && unknownEvidence.frameID == nil, "Filename alone cannot declare units or gravity")
        let malformed = root.appendingPathComponent("malformed.obj")
        try Data("# Atlas ARKit mesh. metres. Y up. local frame invalid\n".utf8).write(to: malformed)
        try check(!MeshDimensionSource.inspect(malformed, atlasOBJ: true).metresKnown, "Malformed frame cannot certify metres")
        let journal = MeshMeasurementJournal(directory: directory, projectID: project)
        let stale = MeshMeasurementJournal(directory: directory, projectID: project)
        let initially = try await journal.load(source: evidence.sha256)
        _ = try await stale.load(source: evidence.sha256)
        try check(initially.isEmpty, "New project journal is empty")
        func reading(projectID: UUID? = project, kind: MeasurementKind = .verticalDistance, role: MeasurementRole = .height,
                     value: Double = 4, position: MeasurementSamplePosition = .lower, gravity: Bool = true, unit: String = "m") -> MeshDimensionObservation {
            .init(sourceSHA256: evidence.sha256, projectID: projectID, frameID: frame, start: [10, 20, 30], end: [13, 24, 30], kind: kind,
                context: .init(role: role, target: .door, targetID: profile, profileID: profile, position: position, definition: .clearOpening),
                value: value, unit: unit, gravityYKnown: gravity)
        }
        let a = reading()
        let rows = try await journal.append(a)
        try check(rows.count == 1 && rows[0].start == a.start && rows[0].end == a.end, "Vertical reading retains offset original A/B")
        try check(rows[0].value == 4 && rows[0].context.role == .height, "Height uses gravity delta, not 5m sloped diagonal")
        let file = try await journal.verifiedExportFile(source: evidence.sha256)
        let firstBytes = try Data(contentsOf: file)
        try await rejects("Stale viewer cannot overwrite another saved reading") { _ = try await stale.append(reading(position: .upper)) }
        try check(try Data(contentsOf: file) == firstBytes, "CAS rejection preserves durable history")
        _ = try await journal.append(reading(position: .upper))
        let reopened = MeshMeasurementJournal(directory: directory, projectID: project)
        let restored = try await reopened.load(source: evidence.sha256)
        try check(restored.count == 2 && Set(restored.map(\.id)).count == 2, "Repeated positions reopen as independent readings")
        try check(restored.map { $0.context.position } == [.lower, .upper], "Lower/upper positions remain separate")
        let foreign = MeshMeasurementJournal(directory: otherRoot.appendingPathComponent("ModelMeasurements"), projectID: otherProject)
        let foreignRows = try await foreign.load(source: evidence.sha256)
        try check(foreignRows.isEmpty, "Identical mesh bytes in another project cannot expose readings")
        try await rejects("Cross-project observation rejects") { _ = try await journal.append(reading(projectID: otherProject)) }
        try await rejects("Incorrect vertical value rejects") { _ = try await journal.append(reading(value: 5)) }
        try await rejects("Unconfirmed model Y cannot be physical height") { _ = try await journal.append(reading(gravity: false, unit: "model-unit")) }
        try await rejects("Surface height cannot silently use gravity projection") { _ = try await journal.append(reading(role: .surfaceHeight)) }
        try await rejects("Unscoped viewer cannot persist a journal") {
            _ = try await MeshMeasurementJournal(directory: nil, projectID: nil).load(source: evidence.sha256)
        }
        let savedBytes = try Data(contentsOf: file)
        var envelope = try JSONSerialization.jsonObject(with: savedBytes) as! [String: Any]
        envelope["projectID"] = otherProject.uuidString
        try JSONSerialization.data(withJSONObject: envelope).write(to: file, options: .atomic)
        try await rejects("Altered envelope scope cannot export") { _ = try await journal.verifiedExportFile(source: evidence.sha256) }
        try savedBytes.write(to: file, options: .atomic)
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: projectRoot)
        try await rejects("Redirected project path cannot load or write another project") {
            _ = try await MeshMeasurementJournal(directory: alias.appendingPathComponent("ModelMeasurements"), projectID: project).load(source: evidence.sha256)
        }
        try manager.removeItem(at: file)
        try manager.createSymbolicLink(at: file, withDestinationURL: source)
        try await rejects("Journal file symlink rejects") { _ = try await journal.load(source: evidence.sha256) }
        try check(try Data(contentsOf: source) == original, "Every failure preserves original mesh bytes")
        print("Mesh measurement journal: \(checks) checks passed")
    }
}
