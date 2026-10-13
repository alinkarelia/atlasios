import Foundation
import AtlasCore

/// Portable checks exercise the real durable store and exchanged bytes. These
/// synthetic documents do not establish physical camera/GNSS accuracy.
enum CollaborativeSurveyStoreChecks {
    static func run() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String = "Collaborative store check failed") { precondition(condition, message); checks += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terraview-team-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID(), frame = UUID(), feature = UUID()
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let workers = (1...5).map { CollaborativeSurveyWorker(name: "Worker \($0)") }
        let boundary = MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 40, y: 0), .init(x: 40, y: 40), .init(x: 0, y: 40)],
                                     holes: [[.init(x: 12, y: 12), .init(x: 18, y: 12), .init(x: 18, y: 18), .init(x: 12, y: 18)]])
        let plan = try CollaborativeSurveyPlanner.create(projectID: project, boundary: .metricPolygon(boundary), workers: workers, cellSizeMeters: 10, createdAt: date)
        let baseline = try CollaborativeSurveyStoredPlan(plan: plan, sourceFeatureID: feature, sourceFeatureRevision: 7,
                                                        projectName: "Shared test", projectKind: .cemetery)
        let directory = root.appendingPathComponent("Collaboration", isDirectory: true)
        let store = CollaborativeSurveyStore(projectID: project, reference: .localMeters(frameID: frame), directory: directory)
        let otherStore = CollaborativeSurveyStore(projectID: project, reference: .localMeters(frameID: frame), directory: directory)
        let saved = try await store.save(baseline, expectedSHA256: nil)
        check(saved == baseline)
        check(try await otherStore.load() == baseline)
        let encoded = try await store.exchangeData(baseline)
        check(try CollaborativeSurveyStore.decodeExchange(encoded, expectedProjectID: project) == baseline)
        check(baseline.plan.sourceBoundary == .metricPolygon(boundary) && baseline.plan.workers.count == 5)

        let cell = plan.cells.first { $0.boundaryStatus == .interior }!
        let bytesA = Data("source A: synthetic adapter fixture".utf8)
        let bytesB = Data("source B: synthetic adapter fixture".utf8)
        let sourceA = root.appendingPathComponent("source-a.bin"), sourceB = root.appendingPathComponent("source-b.bin")
        try bytesA.write(to: sourceA); try bytesB.write(to: sourceB)
        let shaA = try FieldTransferDigest.sha256(fileURL: sourceA), shaB = try FieldTransferDigest.sha256(fileURL: sourceB)
        let eventA = CollaborativeSurveyEvidence(workerID: workers[0].id, kind: .captureObserved, timestamp: date.addingTimeInterval(1),
            cellIDs: [cell.id], captureID: UUID(), sourceSHA256: shaA, footprintProvenance: .operatorMapped,
            footprint: MetricPolygon(frameID: frame, vertices: cell.boundsVertices), quality: .usable, note: "Manual mapped test fixture A")
        let eventB = CollaborativeSurveyEvidence(workerID: workers[1].id, kind: .captureObserved, timestamp: date.addingTimeInterval(2),
            cellIDs: [cell.id], captureID: UUID(), sourceSHA256: shaB, footprintProvenance: .operatorMapped,
            footprint: MetricPolygon(frameID: frame, vertices: cell.boundsVertices), quality: .needsRescan, note: "Manual mapped test fixture B")
        func adding(_ event: CollaborativeSurveyEvidence, to document: CollaborativeSurveyStoredPlan) throws -> CollaborativeSurveyStoredPlan {
            var result = document; var next = result.plan; try next.recordEvidence(event, expectedRevision: next.revision); try result.append(next); return result
        }
        let branchA = try adding(eventA, to: baseline), branchB = try adding(eventB, to: baseline)
        _ = try await store.save(branchA, expectedSHA256: baseline.currentSHA256)
        do { _ = try await otherStore.save(branchB, expectedSHA256: baseline.currentSHA256); preconditionFailure("Stale writer replaced source A") }
        catch CollaborativeSurveyStoreError.revisionConflict { }
        let exchangeB = try CollaborativeSurveyStoredPlan.canonical(CollaborativeSurveyExchange(document: branchB))
        let preview = try await otherStore.previewExchange(exchangeB, expectedSHA256: branchA.currentSHA256)
        check(preview.additionalEvidenceCount == 1)
        check(try await store.load() == branchA, "Preview must not write")
        let merged = try await otherStore.acceptImport(preview, expectedSHA256: branchA.currentSHA256)
        check(merged.plan.evidence.map(\.id) == [eventA.id, eventB.id])
        check(merged.plan.coverage(for: cell.id) == .needsRescan && merged.plan.revision == 2)
        check(try await store.importExchange(exchangeB, expectedSHA256: merged.currentSHA256) == merged)

        var object = try JSONSerialization.jsonObject(with: exchangeB) as! [String: Any]
        object["documentSHA256"] = String(repeating: "0", count: 64)
        let tampered = try JSONSerialization.data(withJSONObject: object)
        do { _ = try CollaborativeSurveyStore.decodeExchange(tampered); preconditionFailure("Tampered checksum accepted") }
        catch CollaborativeSurveyStoreError.invalidDocument { }
        do { _ = try CollaborativeSurveyStore.decodeExchange(exchangeB, expectedProjectID: UUID()); preconditionFailure("Foreign project accepted") }
        catch CollaborativeSurveyStoreError.invalidDocument { }

        let alteredA = CollaborativeSurveyEvidence(id: eventA.id, workerID: eventA.workerID, kind: eventA.kind,
            timestamp: eventA.timestamp, cellIDs: eventA.cellIDs, captureID: eventA.captureID, sourceSHA256: eventA.sourceSHA256,
            footprintProvenance: eventA.footprintProvenance, footprint: eventA.footprint, quality: eventA.quality, note: "Changed same event ID")
        let conflicting = try adding(alteredA, to: baseline)
        let conflictingBytes = try CollaborativeSurveyStoredPlan.canonical(CollaborativeSurveyExchange(document: conflicting))
        do { _ = try await store.previewExchange(conflictingBytes, expectedSHA256: merged.currentSHA256); preconditionFailure("Conflicting event accepted") }
        catch CollaborativeSurveyError.conflictingEvidence { }
        check(try await store.load() == merged)

        var allocationBranch = baseline
        var allocation = baseline.plan
        let originalOwner = allocation.assignments.first { $0.cellID == cell.id }!.workerID
        let newOwner = workers.first { $0.id != originalOwner }!.id
        try allocation.reassign(cellIDs: [cell.id], to: newOwner, expectedRevision: allocation.revision, at: date.addingTimeInterval(3))
        try allocationBranch.append(allocation)
        let allocationBytes = try CollaborativeSurveyStoredPlan.canonical(CollaborativeSurveyExchange(document: allocationBranch))
        do { _ = try await store.previewExchange(allocationBytes, expectedSHA256: merged.currentSHA256); preconditionFailure("Divergent assignment accepted") }
        catch { check(try await store.load() == merged) }

        let verification = CollaborativeSurveyEvidence(workerID: workers[0].id, kind: .operatorVerified, timestamp: date.addingTimeInterval(4),
            cellIDs: [cell.id], quality: .usable, referencedEvidenceIDs: [eventA.id, eventB.id], note: "Inspected usable source and resolved issue B")
        var advanced = try adding(verification, to: merged)
        var advancedPlan = advanced.plan
        try advancedPlan.reassign(cellIDs: [cell.id], to: newOwner, expectedRevision: advancedPlan.revision, at: date.addingTimeInterval(5))
        try advanced.append(advancedPlan)
        let advancedBytes = try CollaborativeSurveyStoredPlan.canonical(CollaborativeSurveyExchange(document: advanced))
        let advancedPreview = try await store.previewExchange(advancedBytes, expectedSHA256: merged.currentSHA256)
        let imported = try await store.acceptImport(advancedPreview, expectedSHA256: merged.currentSHA256)
        check(imported == advanced && imported.plan.coverage(for: cell.id) == .verified)
        check(try await otherStore.load() == imported)

        let oversized = Data(repeating: 32, count: CollaborativeSurveyStore.maximumBytes + 1)
        do { _ = try await store.importExchange(oversized, expectedSHA256: imported.currentSHA256); preconditionFailure("Oversized import accepted") }
        catch CollaborativeSurveyStoreError.tooLarge { }
        check(try await store.load() == imported)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let unsafe = CollaborativeSurveyStore(projectID: project, reference: .localMeters(frameID: frame), directory: link)
        do { _ = try await unsafe.save(baseline, expectedSHA256: nil); preconditionFailure("Symlink write accepted") }
        catch CollaborativeSurveyStoreError.invalidPath { }
        check(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

        let raceDirectory = root.appendingPathComponent("Race", isDirectory: true)
        let raceA = CollaborativeSurveyStore(projectID: project, reference: .localMeters(frameID: frame), directory: raceDirectory)
        let raceB = CollaborativeSurveyStore(projectID: project, reference: .localMeters(frameID: frame), directory: raceDirectory)
        _ = try await raceA.save(baseline, expectedSHA256: nil)
        func attempt(_ store: CollaborativeSurveyStore, _ value: CollaborativeSurveyStoredPlan) async -> Bool {
            do { _ = try await store.save(value, expectedSHA256: baseline.currentSHA256); return true }
            catch { return false }
        }
        async let acceptedA = attempt(raceA, branchA)
        async let acceptedB = attempt(raceB, branchB)
        let outcomes = await [acceptedA, acceptedB]
        check(outcomes.filter { $0 }.count == 1, "Two actor instances must not both replace the same revision")
        print("Collaborative survey store checks passed: \(checks) (durable reopen, project/hash identity, offline evidence merge and dedup, preview without writing, assignment conflict, source-event conflict, multi-operation fast-forward, rescan review, oversize rejection, symlink rejection, concurrent CAS).")
    }
}
