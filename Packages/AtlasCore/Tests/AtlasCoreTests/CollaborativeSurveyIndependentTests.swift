import Foundation
import Testing
@testable import AtlasCore

// Independent fixtures use axis-angle geometry and analytic areas. They do not
// reuse the registration solver, clipping engine or planner to form expected data.
private func independentSource(_ digit: String) -> FragmentSourceReference {
    .init(captureID: UUID(), frameID: UUID(), sourceSHA256: String(repeating: digit, count: 64))
}

private func independentRodrigues(_ point: MetricPoint3D, axis: MetricPoint3D,
                                  angle: Double, shift: MetricPoint3D) -> MetricPoint3D {
    let norm = sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
    let x = axis.x / norm, y = axis.y / norm, z = axis.z / norm
    let dot = x * point.x + y * point.y + z * point.z
    let cosine = cos(angle), sine = sin(angle), remainder = 1 - cosine
    return .init(x: point.x * cosine + (y * point.z - z * point.y) * sine + x * dot * remainder + shift.x,
                 y: point.y * cosine + (z * point.x - x * point.z) * sine + y * dot * remainder + shift.y,
                 z: point.z * cosine + (x * point.y - y * point.x) * sine + z * dot * remainder + shift.z)
}

private func independentPointDistance(_ a: MetricPoint3D, _ b: MetricPoint3D) -> Double {
    sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2))
}

private let independentFitPoints: [MetricPoint3D] = [
    .init(x: -3, y: 2, z: 1), .init(x: 4, y: -1, z: 2),
    .init(x: 1, y: 6, z: -2), .init(x: -2, y: 3, z: 7),
    .init(x: 5, y: 4, z: 3), .init(x: -4, y: -3, z: -2)
]

@Test func independentAxisAngleFixturesRecoverOffAxisRotationsAndBothCoordinateOrigins() throws {
    let source = independentSource("1"), target = independentSource("2")
    let axes: [MetricPoint3D] = [.init(x: 1, y: 2, z: -3), .init(x: -4, y: 1, z: 2)]
    for axis in axes {
        for angle in [0.0001, Double.pi / 2, Double.pi, 2.1] {
            for origin in [0.0, 200_000.0] {
                let shift = MetricPoint3D(x: 23, y: -19, z: 11)
                func mapped(_ p: MetricPoint3D) -> MetricPoint3D {
                    independentRodrigues(p, axis: axis, angle: angle, shift: shift)
                }
                let controls = independentFitPoints.map { p -> FragmentControlPointPair in
                    let observed = MetricPoint3D(x: p.x + origin, y: p.y - origin, z: p.z + origin)
                    return .init(source: observed, target: mapped(observed))
                }
                let withheld = MetricPoint3D(x: origin + 37, y: -origin - 13, z: origin + 21)
                let solved = try FragmentRegistrationSolver.solve(source: source, target: target,
                    controls: controls, checkPoints: [.init(source: withheld, target: mapped(withheld))])
                #expect(solved.quality == .meetsThresholds)
                #expect(independentPointDistance(try solved.transform.applying(to: withheld), mapped(withheld)) < 1e-7)
                let roundTrip = try solved.transform.inverse().applying(to: mapped(withheld))
                #expect(independentPointDistance(roundTrip, withheld) < 1e-7)
                try solved.validate()
            }
        }
    }
}

@Test func independentNoisyFitReportsHeldOutErrorWithoutRefittingIt() throws {
    let source = independentSource("3"), target = independentSource("4")
    func mapped(_ p: MetricPoint3D) -> MetricPoint3D {
        independentRodrigues(p, axis: .init(x: 2, y: -3, z: 4), angle: 0.87,
                             shift: .init(x: 130, y: -70, z: 12))
    }
    let controls = independentFitPoints.enumerated().map { index, point -> FragmentControlPointPair in
        var measured = mapped(point)
        measured.x += index.isMultiple(of: 2) ? 0.003 : -0.003
        measured.y += index.isMultiple(of: 3) ? 0.002 : -0.001
        return .init(source: point, target: measured)
    }
    let withheld = MetricPoint3D(x: 31, y: -11, z: 43), good = mapped(withheld)
    let candidate = try FragmentRegistrationSolver.solve(source: source, target: target,
        controls: controls, checkPoints: [.init(source: withheld, target: good)])
    let bad = try FragmentRegistrationSolver.solve(source: source, target: target,
        controls: controls, checkPoints: [.init(source: withheld, target: .init(x: good.x + 0.8, y: good.y, z: good.z))])
    #expect(candidate.quality == .meetsThresholds)
    #expect(candidate.rmsResidualMeters > 0.001 && candidate.rmsResidualMeters < 0.005)
    #expect(candidate.transform == bad.transform)
    #expect(candidate.residuals == bad.residuals)
    #expect(bad.quality == .requiresReview)
    #expect(try #require(bad.maximumCheckResidualMeters) > 0.7)
}

@Test func independentNoncommutingChainUsesTheActualSourceToProjectDirection() throws {
    let anchor = independentSource("5"), middle = independentSource("6"), leaf = independentSource("7")
    var registry = try FragmentRegistrationRegistry(projectID: UUID(), anchor: anchor)
    try registry.addFragment(middle, expectedRevision: registry.revision)
    try registry.addFragment(leaf, expectedRevision: registry.revision)
    func middleToAnchor(_ p: MetricPoint3D) -> MetricPoint3D {
        independentRodrigues(p, axis: .init(x: 1, y: 2, z: 0), angle: 0.7, shift: .init(x: 10, y: -4, z: 7))
    }
    func leafToMiddle(_ p: MetricPoint3D) -> MetricPoint3D {
        independentRodrigues(p, axis: .init(x: 0, y: -1, z: 3), angle: -1.2, shift: .init(x: -3, y: 5, z: 2))
    }
    let at = Date(timeIntervalSince1970: 1_790_000_000)
    func approve(_ source: FragmentSourceReference, _ target: FragmentSourceReference,
                 map: (MetricPoint3D) -> MetricPoint3D) throws {
        let check = MetricPoint3D(x: 9, y: -5, z: 13)
        let id = try registry.propose(source: source, target: target,
            controls: independentFitPoints.map { .init(source: $0, target: map($0)) },
            checkPoints: [.init(source: check, target: map(check))], at: at, expectedRevision: registry.revision)
        try registry.decide(registrationID: id, state: .approved, operatorID: UUID(),
                            reason: "Independent physical-marker fixture", at: at, expectedRevision: registry.revision)
    }
    try approve(middle, anchor, map: middleToAnchor)
    try approve(leaf, middle, map: leafToMiddle)
    let readiness = try registry.assemblyReadiness()
    #expect(readiness.readyForAlignedDerivative)
    let placement = try #require(readiness.placements.first { $0.source == leaf })
    let transform = try #require(placement.transformToProject)
    let original = MetricPoint3D(x: 8, y: -7, z: 12)
    let expected = middleToAnchor(leafToMiddle(original))
    let reversed = leafToMiddle(middleToAnchor(original))
    #expect(independentPointDistance(expected, reversed) > 1)
    #expect(independentPointDistance(try transform.applying(to: original), expected) < 1e-8)
    #expect(placement.registrationPath.count == 2)
}

@Test func independentPlanarMirrorNeedsAnOutOfPlaneCheckAndCannotBecomeApproved() throws {
    let source = independentSource("8"), anchor = independentSource("9")
    let ground: [MetricPoint3D] = [.init(x: 0, y: 0, z: 0), .init(x: 4, y: 0, z: 0), .init(x: 0, y: 0, z: 6)]
    func reflected(_ p: MetricPoint3D) -> MetricPoint3D { .init(x: -p.x, y: p.y, z: p.z) }
    let check = MetricPoint3D(x: 2, y: 3, z: 2)
    let candidate = try FragmentRegistrationSolver.solve(source: source, target: anchor,
        controls: ground.map { .init(source: $0, target: reflected($0)) },
        checkPoints: [.init(source: check, target: reflected(check))])
    #expect(candidate.rmsResidualMeters < 1e-8)
    #expect(try #require(candidate.maximumCheckResidualMeters) > 5.9)
    #expect(candidate.quality == .requiresReview)
    try candidate.transform.validate() // The fit stays SO(3); it never emits an improper reflection.
}

private func independentWorkers(_ count: Int = 2) -> [CollaborativeSurveyWorker] {
    (0..<count).map { .init(name: "Operator \($0 + 1)") }
}

private func independentRectangle(frame: UUID, x: Double, y: Double,
                                  width: Double, height: Double) -> MetricPolygon {
    .init(frameID: frame, vertices: [.init(x: x, y: y), .init(x: x + width, y: y),
        .init(x: x + width, y: y + height), .init(x: x, y: y + height)])
}

@Test func independentGridConservesAnalyticAreaWithHolesSliversWindingAndTranslation() throws {
    let frame = UUID(), workers = independentWorkers(5), project = UUID()
    for origin in [0.0, 80_000.0] {
        let outer = independentRectangle(frame: frame, x: origin, y: -origin, width: 7.3, height: 5.1)
        let hole = independentRectangle(frame: frame, x: origin + 2.1, y: -origin + 1.1, width: 2.7, height: 1.1)
        for reverse in [false, true] {
            let polygon = MetricPolygon(frameID: frame, vertices: reverse ? Array(outer.vertices.reversed()) : outer.vertices,
                holes: [reverse ? Array(hole.vertices.reversed()) : hole.vertices])
            let plan = try CollaborativeSurveyPlanner.create(projectID: project, boundary: .metricPolygon(polygon),
                workers: workers, cellSizeMeters: 2)
            #expect(abs(plan.estimatedWorkAreaSquareMeters - 34.26) < 1e-7)
            #expect(plan.partialCellCount > 0)
            #expect(Set(plan.assignments.map(\.cellID)) == Set(plan.cells.map(\.id)))
            #expect(plan.assignments.count == plan.cells.count)
            for cell in plan.cells {
                let x = cell.center.x - origin, y = cell.center.y + origin
                #expect(x >= 0 && x <= 7.3 && y >= 0 && y <= 5.1)
                #expect(!(x >= 2.1 && x <= 4.8 && y >= 1.1 && y <= 2.2))
                #expect(cell.estimatedWorkAreaSquareMeters > 0 && cell.estimatedWorkAreaSquareMeters <= 4)
            }
            try plan.validate()
        }
    }
    // The grid rectangle centers all lie outside this 2 mm strip. Losing
    // center-less slivers would silently drop every original survey cell.
    let strip = independentRectangle(frame: frame, x: 0, y: 0, width: 15, height: 0.002)
    let thin = try CollaborativeSurveyPlanner.create(projectID: project, boundary: .metricPolygon(strip),
        workers: workers, cellSizeMeters: 5)
    #expect(thin.cells.count == 3)
    #expect(abs(thin.estimatedWorkAreaSquareMeters - 0.03) < 1e-10)
    #expect(thin.cells.allSatisfy { $0.center.y > 0 && $0.center.y < 0.002 && $0.boundaryStatus == .partialRequiresReview })
    #expect(thin.workersWithoutAssignments.count == 2)
}

@Test func independentConcaveCellPreservesAreaAndItsTargetIsStrictlyInside() throws {
    let frame = UUID(), workers = independentWorkers(1)
    let triangle = MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 0, y: 10)])
    let triangular = try CollaborativeSurveyPlanner.create(projectID: UUID(), boundary: .metricPolygon(triangle),
        workers: workers, cellSizeMeters: 10)
    let representative = try #require(triangular.cells.first).center
    #expect(representative.x > 0 && representative.y > 0 && representative.x + representative.y < 10)
    #expect(abs(triangular.estimatedWorkAreaSquareMeters - 50) < 1e-10)
    let uShape = MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 10, y: 0),
        .init(x: 10, y: 10), .init(x: 8, y: 10), .init(x: 8, y: 2), .init(x: 2, y: 2),
        .init(x: 2, y: 10), .init(x: 0, y: 10)])
    for size in [1.0, 3.0, 10.0] {
        let plan = try CollaborativeSurveyPlanner.create(projectID: UUID(), boundary: .metricPolygon(uShape),
            workers: workers, cellSizeMeters: size)
        #expect(abs(plan.estimatedWorkAreaSquareMeters - 52) < 1e-9)
        #expect(plan.cells.allSatisfy {
            let p = $0.center
            return p.y <= 2 || p.x <= 2 || p.x >= 8
        })
        try plan.validate()
    }
}

@Test func independentGuidanceWithUncertaintyCannotAccuseAnotherWorkerOrInventARoute() throws {
    let workers = independentWorkers(2), frame = UUID()
    let polygon = independentRectangle(frame: frame, x: 0, y: 0, width: 20, height: 10)
    let plan = try CollaborativeSurveyPlanner.create(projectID: UUID(), boundary: .metricPolygon(polygon),
        workers: workers, cellSizeMeters: 2)
    let owners = Dictionary(uniqueKeysWithValues: plan.assignments.map { ($0.cellID, $0.workerID) })
    let seam = try #require(plan.cells.compactMap { left -> (CollaborativeSurveyCell, CollaborativeSurveyCell)? in
        guard let right = plan.cells.first(where: { $0.row == left.row && $0.column == left.column + 1 }),
              owners[left.id] != owners[right.id] else { return nil }
        return (left, right)
    }.first)
    let position = MetricPoint2D(x: seam.0.boundsVertices[1].x + 0.05, y: seam.0.center.y)
    let guidance = plan.guidance(workerID: workers[0].id, position: position, frameID: frame,
        horizontalAccuracyMeters: 0.2, headingInGridDegrees: 0)
    #expect(guidance.status == .boundaryUncertain)
    #expect(guidance.currentWorkerID == nil && guidance.turnDegrees == nil)
    #expect(!guidance.isTraversalRoute)
    #expect(plan.guidance(workerID: workers[0].id, position: position, frameID: frame,
        horizontalAccuracyMeters: nil).status == .unknownAccuracy)
    let poor = plan.guidance(workerID: workers[0].id, position: position, frameID: frame,
        horizontalAccuracyMeters: 50, headingInGridDegrees: 0)
    #expect(poor.status == .poorAccuracy && poor.targetCellID == nil && poor.turnDegrees == nil)
    #expect(plan.guidance(workerID: workers[0].id, position: position, frameID: UUID(),
        horizontalAccuracyMeters: 1).status == .frameMismatch)
}

@Test func independentWalkAndOffsiteMaterialNeverBecomeVerifiedSurveyCoverage() throws {
    let worker = independentWorkers(1)[0], frame = UUID(), at = Date(timeIntervalSince1970: 1_790_000_000)
    let triangle = MetricPolygon(frameID: frame, vertices: [.init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 0, y: 10)])
    var plan = try CollaborativeSurveyPlanner.create(projectID: UUID(), boundary: .metricPolygon(triangle),
        workers: [worker], cellSizeMeters: 10)
    let cell = try #require(plan.cells.first)
    let walk = CollaborativeSurveyEvidence(workerID: worker.id, kind: .gpsWalk, timestamp: at, cellIDs: [cell.id])
    try plan.recordEvidence(walk, expectedRevision: plan.revision)
    #expect(plan.coverage(for: cell.id) == .walked)
    let offsite = independentRectangle(frame: frame, x: 8, y: 8, width: 1, height: 1)
    let unrelated = CollaborativeSurveyEvidence(workerID: worker.id, kind: .captureObserved, timestamp: at,
        cellIDs: [cell.id], captureID: UUID(), sourceSHA256: String(repeating: "a", count: 64),
        footprintProvenance: .registeredCapture, sourceFrameID: frame, footprint: offsite, quality: .usable)
    #expect(throws: CollaborativeSurveyError.invalidEvidence) { try plan.recordEvidence(unrelated, expectedRevision: plan.revision) }
    #expect(plan.evidence.count == 1 && plan.coverage(for: cell.id) == .walked)
    let falseVerification = CollaborativeSurveyEvidence(workerID: worker.id, kind: .operatorVerified, timestamp: at,
        cellIDs: [cell.id], quality: .usable, referencedEvidenceIDs: [walk.id], boundaryReviewed: true, note: "Walk is not imagery")
    #expect(throws: CollaborativeSurveyError.invalidEvidence) { try plan.recordEvidence(falseVerification, expectedRevision: plan.revision) }
    let capture = CollaborativeSurveyEvidence(workerID: worker.id, kind: .captureObserved, timestamp: at,
        cellIDs: [cell.id], captureID: UUID(), sourceSHA256: String(repeating: "b", count: 64),
        footprintProvenance: .registeredCapture, sourceFrameID: frame, footprint: triangle, quality: .usable)
    try plan.recordEvidence(capture, expectedRevision: plan.revision)
    #expect(plan.coverage(for: cell.id) == .observed)
    let withoutEdgeReview = CollaborativeSurveyEvidence(workerID: worker.id, kind: .operatorVerified, timestamp: at,
        cellIDs: [cell.id], quality: .usable, referencedEvidenceIDs: [capture.id], note: "Edge not reviewed")
    #expect(throws: CollaborativeSurveyError.invalidEvidence) { try plan.recordEvidence(withoutEdgeReview, expectedRevision: plan.revision) }
    let reviewed = CollaborativeSurveyEvidence(workerID: worker.id, kind: .operatorVerified, timestamp: at,
        cellIDs: [cell.id], quality: .usable, referencedEvidenceIDs: [capture.id], boundaryReviewed: true, note: "All clipped edge portions reviewed")
    try plan.recordEvidence(reviewed, expectedRevision: plan.revision)
    #expect(plan.coverage(for: cell.id) == .verified)
}

@Test func independentDecodedGridCannotChangeItsAreaComponentOrBoundsBehindTheOriginalBoundary() throws {
    let frame = UUID(), polygon = independentRectangle(frame: frame, x: 0, y: 0, width: 20, height: 10)
    let original = try CollaborativeSurveyPlanner.create(projectID: UUID(), boundary: .metricPolygon(polygon),
        workers: independentWorkers(), cellSizeMeters: 2)
    let data = try JSONEncoder().encode(original)
    let pristine = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for alteration in ["area", "component", "bounds"] {
        var document = pristine
        var cells = try #require(document["cells"] as? [[String: Any]])
        switch alteration {
        case "area": cells[0]["estimatedWorkAreaSquareMeters"] = 1.0
        case "component": cells[0]["componentID"] = 99
        default:
            var corners = try #require(cells[0]["boundsVertices"] as? [[String: Any]])
            corners[0]["x"] = -1.0
            cells[0]["boundsVertices"] = corners
        }
        document["cells"] = cells
        let tampered = try JSONDecoder().decode(CollaborativeSurveyPlan.self,
            from: JSONSerialization.data(withJSONObject: document))
        #expect(throws: CollaborativeSurveyError.invalidPlan) { try tampered.validate() }
    }
    let restored = try JSONDecoder().decode(CollaborativeSurveyPlan.self, from: data)
    try restored.validate()
    #expect(restored.cells == original.cells)
}
