import Foundation
import Testing
@testable import AtlasCore

private let teamEpoch = Date(timeIntervalSince1970: 1_800_000_000)
private let teamFrame = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
private let teamProject = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
private let teamPlanID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
private func teamWorkers(_ count: Int) -> [CollaborativeSurveyWorker] {
    (0..<count).map { .init(id: UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", $0 + 1))!, name: "Сотрудник \($0 + 1)") }
}
private func teamBoundary(_ points: [(Double, Double)], holes: [[(Double, Double)]] = []) -> FeatureGeometry {
    .metricPolygon(.init(frameID: teamFrame, vertices: points.map { .init(x: $0.0, y: $0.1) }, holes: holes.map { $0.map { .init(x: $0.0, y: $0.1) } }))
}
private func teamPlan(_ boundary: FeatureGeometry? = nil, workers: Int = 5, size: Double = 10) throws -> CollaborativeSurveyPlan {
    try CollaborativeSurveyPlanner.create(projectID: teamProject, boundary: boundary ?? teamBoundary([(0, 0), (100, 0), (100, 100), (0, 100)]),
        workers: teamWorkers(workers), cellSizeMeters: size, planID: teamPlanID, createdAt: teamEpoch)
}
private func teamCapture(_ plan: CollaborativeSurveyPlan, cellIDs: [String], worker: Int = 0,
                         quality: CollaborativeSurveyEvidenceQuality = .usable, sourceFrame: UUID? = nil,
                         registration: UUID? = nil, footprint: MetricPolygon? = nil,
                         provenance: CollaborativeSurveyFootprintProvenance = .operatorMapped) -> CollaborativeSurveyEvidence {
    .init(workerID: plan.workers[worker].id, kind: .captureObserved, timestamp: teamEpoch,
          cellIDs: cellIDs, captureID: UUID(), sourceSHA256: FieldTransferDigest.sha256(Data("actual fixture material".utf8)),
          footprintProvenance: provenance, sourceFrameID: sourceFrame,
          registrationID: registration, footprint: footprint ?? plan.boundary, quality: quality)
}

@Test func collaborativeSurveyDeterministicallyBalancesConnectedSectorParts() throws {
    let plan = try teamPlan()
    #expect(plan == (try teamPlan()))
    #expect(plan.cells.count == 100 && plan.componentCount == 1)
    #expect(plan.estimatedWorkAreaSquareMeters == 10_000)
    let counts = plan.workers.map { worker in plan.assignments.filter { $0.workerID == worker.id }.count }
    #expect((counts.max() ?? 0) - (counts.min() ?? 0) <= 5)
    for worker in plan.workers {
        let cells = plan.cells.filter { cell in plan.assignments.contains { $0.cellID == cell.id && $0.workerID == worker.id } }
        var reached = Set([try #require(cells.first).id]), changed = true
        while changed {
            changed = false
            for cell in cells where !reached.contains(cell.id) {
                if cells.contains(where: { reached.contains($0.id) && abs($0.row - cell.row) + abs($0.column - cell.column) == 1 }) {
                    reached.insert(cell.id); changed = true
                }
            }
        }
        #expect(reached.count == cells.count)
    }
    try plan.validate()
}

@Test func collaborativeSurveyConcaveOutlineAndHolesExcludeNonWorkArea() throws {
    let plan = try teamPlan(teamBoundary([(0, 0), (30, 0), (30, 10), (10, 10), (10, 30), (0, 30)],
        holes: [[(2, 2), (8, 2), (8, 8), (2, 8)]]), workers: 2)
    #expect(plan.cells.count == 5)
    #expect(abs(plan.estimatedWorkAreaSquareMeters - 464) < 1e-9)
    #expect(plan.cells.allSatisfy { CollaborativeSurveyPlanner.contains($0.center, in: plan.boundary) })
    #expect(plan.cells.first { $0.id == "r0c0" }?.boundaryStatus == .partialRequiresReview)
    #expect(!plan.cells.contains { $0.row > 0 && $0.column > 0 })
    try plan.validate()
}

@Test func collaborativeSurveyNarrowEdgeSliversAreRetainedForReview() throws {
    let plan = try teamPlan(teamBoundary([(0, 0), (30, 0), (30, 0.01), (0, 0.01)]), workers: 2)
    #expect(plan.cells.count == 3 && plan.partialCellCount == 3)
    #expect(abs(plan.estimatedWorkAreaSquareMeters - 0.3) < 1e-12)
    #expect(plan.cells.allSatisfy { $0.center.y > 0 && $0.center.y < 0.01 })
    try plan.validate()
}

@Test func collaborativeSurveyDisconnectedRepresentativesDoNotInventPassage() throws {
    let plan = try teamPlan(teamBoundary([(0, 0), (10, 0), (10, 8), (20, 8), (20, 0), (30, 0),
                                        (30, 20), (20, 20), (20, 9), (10, 9), (10, 20), (0, 20)]), workers: 3)
    #expect(plan.componentCount > 1)
    #expect(abs(plan.estimatedWorkAreaSquareMeters - 410) < 1e-9)
    #expect(plan.assignments.count == plan.cells.count)
    try plan.validate()
}

@Test func collaborativeSurveyReassignmentKeepsAuditAndCAS() throws {
    var plan = try teamPlan(); let original = plan
    let assignment = plan.assignments[0], other = try #require(plan.workers.first { $0.id != assignment.workerID })
    try plan.reassign(cellIDs: [assignment.cellID], to: other.id, expectedRevision: 0, at: teamEpoch.addingTimeInterval(1))
    #expect(plan.revision == 1)
    #expect(plan.assignmentHistory[0].previousWorkerIDs[assignment.cellID] == assignment.workerID)
    try plan.validateTransition(from: original)
    #expect(throws: CollaborativeSurveyError.revisionConflict) {
        try plan.reassign(cellIDs: [assignment.cellID], to: assignment.workerID, expectedRevision: 0)
    }
    try plan.reassign(cellIDs: [assignment.cellID], to: assignment.workerID, expectedRevision: 1)
    #expect(plan.assignments == original.assignments && plan.assignmentHistory.count == 2)
    try plan.validate()
}

@Test func collaborativeSurveyGPSWalkNeverConfirmsCaptureCompleteness() throws {
    var plan = try teamPlan(); let cell = plan.cells[0]
    let walk = CollaborativeSurveyEvidence(workerID: plan.workers[0].id, kind: .gpsWalk, timestamp: teamEpoch,
        cellIDs: [cell.id], horizontalAccuracyMeters: 8)
    try plan.recordEvidence(walk, expectedRevision: 0)
    #expect(plan.coverage(for: cell.id) == .walked)
    #expect(plan.nearestUncoveredTarget(workerID: plan.assignments[0].workerID, from: cell.center)?.id == cell.id)
    let falseReview = CollaborativeSurveyEvidence(workerID: plan.workers[0].id, kind: .operatorVerified,
        timestamp: teamEpoch, cellIDs: [cell.id], quality: .usable, referencedEvidenceIDs: [walk.id], note: "Прошёл")
    #expect(throws: CollaborativeSurveyError.invalidEvidence) { try plan.recordEvidence(falseReview, expectedRevision: 1) }
}

@Test func collaborativeSurveyOverlapPreservesBothWorkersAndRetryIsIdempotent() throws {
    var plan = try teamPlan(); let cell = plan.cells[0]
    let a = teamCapture(plan, cellIDs: [cell.id], worker: 0), b = teamCapture(plan, cellIDs: [cell.id], worker: 1)
    try plan.recordEvidence(a, expectedRevision: 0); let baseline = plan
    try plan.recordEvidence(a, expectedRevision: 0)
    #expect(plan == baseline)
    try plan.recordEvidence(b, expectedRevision: 1)
    #expect(plan.evidence.map(\.workerID) == [a.workerID, b.workerID])
    #expect(plan.evidence.map(\.sourceSHA256) == [a.sourceSHA256, b.sourceSHA256])
    #expect(plan.coverage(for: cell.id) == .observed)
    try plan.validateTransition(from: baseline)
}

@Test func collaborativeSurveyMissingHashAndInventedRegistrationAreRejected() throws {
    var plan = try teamPlan(); let cell = plan.cells[0]
    let noHash = CollaborativeSurveyEvidence(workerID: plan.workers[0].id, kind: .captureObserved, timestamp: teamEpoch,
        cellIDs: [cell.id], captureID: UUID(), footprintProvenance: .operatorMapped, footprint: plan.boundary)
    #expect(throws: CollaborativeSurveyError.invalidEvidence) { try plan.recordEvidence(noHash, expectedRevision: 0) }
    let fakeRegistration = teamCapture(plan, cellIDs: [cell.id], registration: UUID())
    #expect(throws: CollaborativeSurveyError.invalidEvidence) { try plan.recordEvidence(fakeRegistration, expectedRevision: 0) }
    let differentFrame = teamCapture(plan, cellIDs: [cell.id], sourceFrame: UUID(), provenance: .registeredCapture)
    #expect(throws: CollaborativeSurveyError.invalidEvidence) { try plan.recordEvidence(differentFrame, expectedRevision: 0) }
    let registered = teamCapture(plan, cellIDs: [cell.id], sourceFrame: UUID(), registration: UUID(), provenance: .registeredCapture)
    try plan.recordEvidence(registered, expectedRevision: 0)
    #expect(plan.evidence[0].horizontalAccuracyMeters == nil)
    #expect(plan.evidence[0].sourceFrameID != plan.gridFrameID)
}

@Test func collaborativeSurveyFootprintInHoleCannotMarkFilledCellObserved() throws {
    var plan = try teamPlan(teamBoundary([(0, 0), (20, 0), (20, 20), (0, 20)], holes: [[(2, 2), (8, 2), (8, 8), (2, 8)]]), workers: 1)
    let footprint = MetricPolygon(frameID: plan.gridFrameID, vertices: [.init(x: 3, y: 3), .init(x: 7, y: 3), .init(x: 7, y: 7), .init(x: 3, y: 7)])
    #expect(throws: CollaborativeSurveyError.invalidEvidence) {
        try plan.recordEvidence(teamCapture(plan, cellIDs: ["r0c0"], footprint: footprint), expectedRevision: 0)
    }
    #expect(plan.coverage(for: "r0c0") == .unobserved)
}

@Test func collaborativeSurveyPartialReviewAndOutstandingRescanRemainExplicit() throws {
    var plan = try teamPlan(teamBoundary([(0, 0), (11, 0), (11, 10), (0, 10)]), workers: 1)
    let cell = try #require(plan.cells.first { $0.boundaryStatus == .partialRequiresReview })
    let capture = teamCapture(plan, cellIDs: [cell.id]); try plan.recordEvidence(capture, expectedRevision: 0)
    let unchecked = CollaborativeSurveyEvidence(workerID: plan.workers[0].id, kind: .operatorVerified, timestamp: teamEpoch,
        cellIDs: [cell.id], quality: .usable, referencedEvidenceIDs: [capture.id], note: "Проверено")
    #expect(throws: CollaborativeSurveyError.invalidEvidence) { try plan.recordEvidence(unchecked, expectedRevision: 1) }
    let checked = CollaborativeSurveyEvidence(workerID: plan.workers[0].id, kind: .operatorVerified, timestamp: teamEpoch,
        cellIDs: [cell.id], quality: .usable, referencedEvidenceIDs: [capture.id], boundaryReviewed: true, note: "Края проверены")
    try plan.recordEvidence(checked, expectedRevision: 1)
    #expect(plan.coverage(for: cell.id) == .verified)
    let rescan = teamCapture(plan, cellIDs: [cell.id], quality: .needsRescan)
    try plan.recordEvidence(rescan, expectedRevision: 2)
    try plan.recordEvidence(teamCapture(plan, cellIDs: [cell.id], quality: .unknown), expectedRevision: 3)
    #expect(plan.coverage(for: cell.id) == .needsRescan)
    let resolution = CollaborativeSurveyEvidence(workerID: plan.workers[0].id, kind: .operatorVerified, timestamp: teamEpoch,
        cellIDs: [cell.id], quality: .usable, referencedEvidenceIDs: [capture.id, rescan.id], boundaryReviewed: true, note: "Повторная проверка устранила пробел")
    try plan.recordEvidence(resolution, expectedRevision: 4)
    #expect(plan.coverage(for: cell.id) == .verified)
    try plan.validate()
}

@Test func collaborativeSurveyUnknownAccuracyAndFrameDoNotProducePreciseArrow() throws {
    let plan = try teamPlan(), point = MetricPoint2D(x: 5, y: 5), worker = plan.assignments[0].workerID
    let unknown = plan.guidance(workerID: worker, position: point, frameID: plan.gridFrameID, horizontalAccuracyMeters: nil)
    #expect(unknown.status == .unknownAccuracy && unknown.bearingDegrees == nil)
    let poor = plan.guidance(workerID: worker, position: point, frameID: plan.gridFrameID, horizontalAccuracyMeters: 25)
    #expect(poor.status == .poorAccuracy && poor.turnDegrees == nil)
    let frame = plan.guidance(workerID: worker, position: point, frameID: UUID(), horizontalAccuracyMeters: 1)
    #expect(frame.status == .frameMismatch && frame.distanceMeters == nil)
    #expect(!unknown.isTraversalRoute && !poor.isTraversalRoute && !frame.isTraversalRoute)
}

@Test func collaborativeSurveyBoundaryUncertaintyDoesNotAccuseDefiniteTrespass() throws {
    let plan = try teamPlan(workers: 2)
    let uncertain = plan.guidance(workerID: plan.assignments[0].workerID, position: .init(x: 5, y: 0.3),
        frameID: plan.gridFrameID, horizontalAccuracyMeters: 2, headingInGridDegrees: 0)
    #expect(uncertain.status == .boundaryUncertain && uncertain.currentWorkerID == nil && uncertain.turnDegrees == nil)
    #expect(!uncertain.isTraversalRoute)
}

@Test func collaborativeSurveyCapacityAndUnknownAssignmentsAreBounded() throws {
    #expect(throws: CollaborativeSurveyError.tooManyCells) { _ = try teamPlan(teamBoundary([(0, 0), (1_000, 0), (1_000, 1_000), (0, 1_000)]), size: 1) }
    #expect(throws: CollaborativeSurveyError.invalidWorkers) { _ = try teamPlan(workers: 65) }
    var plan = try teamPlan()
    #expect(throws: CollaborativeSurveyError.unknownWorker) { try plan.reassign(cellIDs: [plan.cells[0].id], to: UUID(), expectedRevision: 0) }
    #expect(throws: CollaborativeSurveyError.unknownCell) { try plan.reassign(cellIDs: ["missing"], to: plan.workers[0].id, expectedRevision: 0) }
}

@Test func collaborativeSurveyWGS84PreservesOriginalAndDoesNotGeolocateIndependentAR() throws {
    let original = GeographicPolygon(vertices: [.init(longitude: 30, latitude: 60), .init(longitude: 30.001, latitude: 60),
        .init(longitude: 30.001, latitude: 60.001), .init(longitude: 30, latitude: 60.001)])
    let plan = try teamPlan(.geographicPolygon(original), workers: 2, size: 20)
    #expect(plan.coordinateReference == .wgs84 && plan.sourceBoundary == .geographicPolygon(original))
    #expect(plan.gridFrameID == plan.id)
    #expect(try plan.project(original.vertices[0]) == .init(x: 0, y: 0))
    #expect(plan.estimatedWorkAreaSquareMeters > 6_000 && plan.estimatedWorkAreaSquareMeters < 6_500)
    #expect(throws: GeographicMetricError.projectionExtentExceeded) { _ = try plan.project(.init(longitude: 31, latitude: 60)) }
    #expect(throws: CollaborativeSurveyError.frameMismatch) { _ = try teamPlan().project(original.vertices[0]) }
    try plan.validate()
    #expect(try JSONDecoder().decode(CollaborativeSurveyPlan.self, from: JSONEncoder().encode(plan)) == plan)
}

@Test func collaborativeSurveyImportedGridCannotFakeAreaOrEraseHistory() throws {
    let plan = try teamPlan()
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
    var cells = try #require(json["cells"] as? [[String: Any]]); cells[0]["estimatedWorkAreaSquareMeters"] = 1; json["cells"] = cells
    let tampered = try JSONDecoder().decode(CollaborativeSurveyPlan.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(throws: CollaborativeSurveyError.invalidPlan) { try tampered.validate() }
    var newer = plan; try newer.recordEvidence(teamCapture(plan, cellIDs: [plan.cells[0].id]), expectedRevision: 0)
    #expect(throws: CollaborativeSurveyError.revisionConflict) { try plan.validateTransition(from: newer) }
    #expect(newer.sourceBoundarySHA256 == plan.sourceBoundarySHA256)
}

@Test func collaborativeSurveyFiveOfflineBranchesMergeCaptureFactsWithoutLastWriterWins() throws {
    let original = try teamPlan(); var branches = [CollaborativeSurveyPlan]()
    for worker in 0..<5 {
        var branch = original
        try branch.recordEvidence(teamCapture(branch, cellIDs: [branch.cells[worker].id], worker: worker), expectedRevision: 0)
        branches.append(branch)
    }
    var merged = original
    for branch in branches { #expect(try merged.mergeEvidence(from: branch, expectedRevision: merged.revision) == 1) }
    #expect(merged.evidence.count == 5 && merged.revision == 5)
    #expect(Set(merged.evidence.map(\.workerID)).count == 5)
    try merged.validateEvidenceMerge(from: original)
    #expect(try merged.mergeEvidence(from: branches[0], expectedRevision: merged.revision) == 0)
    var reversed = original
    for branch in branches.reversed() { try reversed.mergeEvidence(from: branch, expectedRevision: reversed.revision) }
    #expect(merged.coverageIndex() == reversed.coverageIndex())
    #expect(merged.assignments == reversed.assignments)
}

@Test func collaborativeSurveyMergeReferencesFollowObservedCaptureAndAllocationConflictsRemainExplicit() throws {
    let original = try teamPlan(); var a = original, b = original
    let captured = teamCapture(b, cellIDs: [b.cells[0].id]); try b.recordEvidence(captured, expectedRevision: 0)
    let reviewed = CollaborativeSurveyEvidence(workerID: b.workers[0].id, kind: .operatorVerified, timestamp: teamEpoch,
        cellIDs: captured.cellIDs, quality: .usable, referencedEvidenceIDs: [captured.id], note: "Проверено")
    try b.recordEvidence(reviewed, expectedRevision: 1)
    #expect(try a.mergeEvidence(from: b, expectedRevision: 0) == 2)
    #expect(a.evidence.map(\.id) == [captured.id, reviewed.id])
    #expect(a.coverage(for: captured.cellIDs[0]) == .verified)
    var divergent = original
    try divergent.reassign(cellIDs: [divergent.assignments[0].cellID], to: divergent.workers[1].id, expectedRevision: 0)
    #expect(throws: CollaborativeSurveyError.revisionConflict) { try a.mergeEvidence(from: divergent, expectedRevision: a.revision) }
    #expect(a.evidence.count == 2)
}

@Test func collaborativeSurveyConflictingOfflineEventHashCannotOverwriteOrPartiallyMerge() throws {
    let original = try teamPlan(); var local = original, remote = original
    let observed = teamCapture(original, cellIDs: [original.cells[0].id])
    try local.recordEvidence(observed, expectedRevision: 0)
    let differentHash = CollaborativeSurveyEvidence(id: observed.id, workerID: observed.workerID, kind: observed.kind,
        timestamp: observed.timestamp, cellIDs: observed.cellIDs, captureID: observed.captureID,
        sourceSHA256: FieldTransferDigest.sha256(Data("changed material".utf8)), footprintProvenance: .operatorMapped,
        footprint: observed.footprint, quality: .usable)
    try remote.recordEvidence(teamCapture(remote, cellIDs: [remote.cells[1].id]), expectedRevision: 0)
    try remote.recordEvidence(differentHash, expectedRevision: 1)
    let before = local
    #expect(throws: CollaborativeSurveyError.conflictingEvidence) { try local.mergeEvidence(from: remote, expectedRevision: local.revision) }
    #expect(local == before)
}

@Test func collaborativeSurveyDecodedAssignmentCannotBypassItsAuditEvent() throws {
    let original = try teamPlan()
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    var assignments = try #require(json["assignments"] as? [[String: Any]])
    let owner = original.assignments[0].workerID, different = try #require(original.workers.first { $0.id != owner })
    assignments[0]["workerID"] = different.id.uuidString; json["assignments"] = assignments
    let tampered = try JSONDecoder().decode(CollaborativeSurveyPlan.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(throws: CollaborativeSurveyError.invalidPlan) { try tampered.validate() }
}

@Test func collaborativeSurveyRescanCoverageIsIndependentOfOfflineMergeArrivalOrder() throws {
    let original = try teamPlan(); var good = original, bad = original
    try good.recordEvidence(teamCapture(good, cellIDs: [good.cells[0].id], quality: .unknown), expectedRevision: 0)
    try bad.recordEvidence(teamCapture(bad, cellIDs: [bad.cells[0].id], quality: .needsRescan), expectedRevision: 0)
    var goodFirst = original, badFirst = original
    try goodFirst.mergeEvidence(from: good, expectedRevision: 0); try goodFirst.mergeEvidence(from: bad, expectedRevision: 1)
    try badFirst.mergeEvidence(from: bad, expectedRevision: 0); try badFirst.mergeEvidence(from: good, expectedRevision: 1)
    #expect(goodFirst.coverageIndex() == badFirst.coverageIndex())
    #expect(goodFirst.coverage(for: original.cells[0].id) == .needsRescan)
}
