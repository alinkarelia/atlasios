import Foundation
import Testing
@testable import AtlasCore

private let registrationDate = Date(timeIntervalSince1970: 1_790_000_000)
private let registrationPoints = [MetricPoint3D(x: 0, y: 0, z: 0), .init(x: 2, y: 0, z: 0),
    .init(x: 0, y: 3, z: 0), .init(x: 0, y: 0, z: 4), .init(x: 1, y: 2, z: 3)]
private func registrationSource(_ digit: Character = "a", frame: UUID = UUID()) -> FragmentSourceReference {
    .init(captureID: UUID(), frameID: frame, sourceSHA256: String(repeating: String(digit), count: 64))
}
private func registrationPairs(_ points: [MetricPoint3D] = Array(registrationPoints.prefix(4)),
                               map: (MetricPoint3D) -> MetricPoint3D) -> [FragmentControlPointPair] {
    points.map { .init(source: $0, target: map($0)) }
}
private func cyclicRotation(_ p: MetricPoint3D) -> MetricPoint3D { .init(x: p.z + 10, y: p.x - 4, z: p.y + 7) }
private func shifted(_ p: MetricPoint3D, x: Double = 5, y: Double = -2, z: Double = 3) -> MetricPoint3D {
    .init(x: p.x + x, y: p.y + y, z: p.z + z)
}
private func expectPoint(_ actual: MetricPoint3D, _ expected: MetricPoint3D, tolerance: Double = 1e-8) {
    #expect(abs(actual.x - expected.x) < tolerance)
    #expect(abs(actual.y - expected.y) < tolerance)
    #expect(abs(actual.z - expected.z) < tolerance)
}
private func candidate(_ map: (MetricPoint3D) -> MetricPoint3D = cyclicRotation,
                       controls: [MetricPoint3D] = Array(registrationPoints.prefix(4)),
                       check: MetricPoint3D = registrationPoints[4]) throws -> FragmentRegistrationCandidate {
    try FragmentRegistrationSolver.solve(source: registrationSource(), target: registrationSource("b"),
        controls: registrationPairs(controls, map: map), checkPoints: registrationPairs([check], map: map), at: registrationDate)
}
private func addRegistration(_ registry: inout FragmentRegistrationRegistry, source: FragmentSourceReference,
                             target: FragmentSourceReference, map: (MetricPoint3D) -> MetricPoint3D) throws -> UUID {
    let id = try registry.propose(source: source, target: target, controls: registrationPairs(map: map),
        checkPoints: registrationPairs([registrationPoints[4]], map: map), at: registrationDate, expectedRevision: registry.revision)
    try registry.decide(registrationID: id, state: .approved, operatorID: UUID(), reason: "Независимая контрольная точка проверена",
                        at: registrationDate, expectedRevision: registry.revision)
    return id
}

@Test func fragmentRegistrationRecoversIndependentFull3DRotationAndTranslation() throws {
    let solved = try candidate()
    #expect(solved.quality == .meetsThresholds)
    #expect(solved.rmsResidualMeters < 1e-8)
    #expect(try #require(solved.checkRMSResidualMeters) < 1e-8)
    let expected = [0.0, 0, 1, 1, 0, 0, 0, 1, 0]
    for (actual, required) in zip(solved.transform.rotation, expected) { #expect(abs(actual - required) < 1e-8) }
    expectPoint(solved.transform.translation, .init(x: 10, y: -4, z: 7))
    expectPoint(try solved.transform.applying(to: .init(x: 7, y: -2, z: 0.5)), .init(x: 10.5, y: 3, z: 5))
    try solved.validate()
}

@Test func fragmentRegistrationThreeNoncollinearPlanarControlsRecoverRigidTransform() throws {
    let solved = try candidate(controls: Array(registrationPoints.prefix(3)))
    #expect(solved.quality == .meetsThresholds)
    expectPoint(try solved.transform.applying(to: registrationPoints[4]), cyclicRotation(registrationPoints[4]))
}

@Test func fragmentRegistrationHandlesExact180DegreeRotation() throws {
    let solved = try candidate { .init(x: -$0.x + 10, y: $0.y + 2, z: -$0.z - 8) }
    #expect(solved.quality == .meetsThresholds)
    expectPoint(try solved.transform.applying(to: .init(x: 3, y: 4, z: 5)), .init(x: 7, y: 6, z: -13))
    #expect(abs(solved.transform.rotation[0] + 1) < 1e-8)
    #expect(abs(solved.transform.rotation[4] - 1) < 1e-8)
    #expect(abs(solved.transform.rotation[8] + 1) < 1e-8)
}

@Test func fragmentRegistrationRecoversArbitraryEulerRotationIndependentOfTransformApplication() throws {
    let yaw = 0.61, pitch = -0.37, roll = 0.23
    func mapped(_ p: MetricPoint3D) -> MetricPoint3D {
        let rollY = cos(roll) * p.y - sin(roll) * p.z, rollZ = sin(roll) * p.y + cos(roll) * p.z
        let pitchX = cos(pitch) * p.x + sin(pitch) * rollZ, pitchZ = -sin(pitch) * p.x + cos(pitch) * rollZ
        return .init(x: cos(yaw) * pitchX - sin(yaw) * rollY + 100,
                     y: sin(yaw) * pitchX + cos(yaw) * rollY - 50, z: pitchZ + 2)
    }
    let solved = try candidate(mapped)
    expectPoint(try solved.transform.applying(to: .init(x: 12, y: -0.5, z: 8)), mapped(.init(x: 12, y: -0.5, z: 8)))
    #expect(solved.quality == .meetsThresholds)
}

@Test func fragmentRegistrationInverseAndCompositionUseSourceToTargetOrder() throws {
    let first = try candidate().transform
    let inverse = try first.inverse(), point = MetricPoint3D(x: 8, y: 2, z: -3)
    expectPoint(try inverse.applying(to: first.applying(to: point)), point)
    let next = FragmentRigidTransform(rotation: [0, -1, 0, 1, 0, 0, 0, 0, 1], translation: .init(x: -3, y: 2, z: 8))
    let composed = try first.followed(by: next)
    expectPoint(try composed.applying(to: point), .init(x: -7, y: 9, z: 17))
    try composed.validate()
}

@Test func fragmentRegistrationRejectsCollinearCoincidentAndShortBaselines() throws {
    let inputs: [[MetricPoint3D]] = [
        [.init(x: 1, y: 1, z: 1), .init(x: 1, y: 1, z: 1), .init(x: 1, y: 1, z: 1)],
        [.init(x: 0, y: 0, z: 0), .init(x: 2, y: 2, z: 2), .init(x: 4, y: 4, z: 4)],
        [.init(x: 0, y: 0, z: 0), .init(x: 0.01, y: 0, z: 0), .init(x: 0, y: 0.01, z: 0)],
        [.init(x: 0, y: 0, z: 0), .init(x: 1, y: 0, z: 0), .init(x: 2, y: 0.000_001, z: 0)]]
    for points in inputs {
        #expect(throws: FragmentRegistrationError.degenerateControls) { try candidate(controls: points) }
    }
}

@Test func fragmentRegistrationRejectsTooFewControlsAndDegenerateTarget() throws {
    #expect(throws: FragmentRegistrationError.insufficientControls) { try candidate(controls: Array(registrationPoints.prefix(2))) }
    #expect(throws: FragmentRegistrationError.degenerateControls) { try candidate { .init(x: $0.x + $0.y + $0.z, y: 0, z: 0) } }
}

@Test func fragmentRegistrationRejectsUnknownUnitsInvalidHashesAndSameFrame() throws {
    let good = registrationSource(), other = registrationSource("b")
    let pairs = registrationPairs(map: cyclicRotation)
    for unit in [FragmentCoordinateUnit.unknown, .centimeters] {
        let bad = FragmentSourceReference(captureID: good.captureID, frameID: good.frameID, sourceSHA256: good.sourceSHA256, unit: unit)
        #expect(throws: FragmentRegistrationError.unsupportedUnit) { try FragmentRegistrationSolver.solve(source: bad, target: other, controls: pairs) }
    }
    let bad = FragmentSourceReference(captureID: good.captureID, frameID: good.frameID, sourceSHA256: "not-a-hash")
    #expect(throws: FragmentRegistrationError.invalidReference) { try FragmentRegistrationSolver.solve(source: bad, target: other, controls: pairs) }
    #expect(throws: FragmentRegistrationError.sameFrame) {
        try FragmentRegistrationSolver.solve(source: good, target: registrationSource("b", frame: good.frameID), controls: pairs)
    }
}

@Test func fragmentRegistrationRejectsNonfiniteOutOfRangeAndGPSOnlyControls() throws {
    for x in [Double.nan, .infinity, 1_000_001] {
        var pairs = registrationPairs(map: cyclicRotation)
        pairs[0] = .init(source: .init(x: x, y: 0, z: 0), target: .init(x: 0, y: 0, z: 0))
        #expect(throws: FragmentRegistrationError.invalidCoordinate) {
            try FragmentRegistrationSolver.solve(source: registrationSource(), target: registrationSource("b"), controls: pairs)
        }
    }
    var pairs = registrationPairs(map: cyclicRotation)
    pairs[0] = .init(source: pairs[0].source, target: pairs[0].target, evidence: .gpsOnly)
    #expect(throws: FragmentRegistrationError.unsupportedEvidence) {
        try FragmentRegistrationSolver.solve(source: registrationSource(), target: registrationSource("b"), controls: pairs)
    }
}

@Test func fragmentRegistrationNeverFitsScaleOrReflection() throws {
    let scaled = try candidate { .init(x: $0.x * 2 + 10, y: $0.y * 2 - 4, z: $0.z * 2 + 7) }
    let mirrored = try candidate { .init(x: -$0.x + 10, y: $0.y - 4, z: $0.z + 7) }
    for solved in [scaled, mirrored] {
        #expect(solved.quality == .requiresReview)
        #expect(solved.maximumResidualMeters > solved.policy.maximumResidualMeters)
        try solved.transform.validate() // Both best fits are proper SO(3), never a reflection or scale.
        try solved.validate()
    }
    #expect(throws: FragmentRegistrationError.invalidTransform) {
        try FragmentRigidTransform(rotation: [-1, 0, 0, 0, 1, 0, 0, 0, 1], translation: .init(x: 0, y: 0, z: 0)).validate()
    }
}

@Test func fragmentRegistrationCheckPointIsHeldOutAndDetectsIndependentMismatch() throws {
    let source = registrationSource(), target = registrationSource("b"), controls = registrationPairs(map: cyclicRotation)
    let check = FragmentControlPointPair(source: registrationPoints[4], target: .init(x: 30, y: 40, z: 50))
    let bad = try FragmentRegistrationSolver.solve(source: source, target: target, controls: controls, checkPoints: [check])
    let noCheck = try FragmentRegistrationSolver.solve(source: source, target: target, controls: controls)
    #expect(bad.transform == noCheck.transform)
    #expect(bad.rmsResidualMeters < 1e-8)
    #expect(try #require(bad.maximumCheckResidualMeters) > 10)
    #expect(bad.quality == .requiresReview)
    #expect(noCheck.quality == .requiresReview)
    #expect(noCheck.checkRMSResidualMeters == nil)
}

@Test func fragmentRegistrationRejectsReusedControlAsIndependentCheck() throws {
    let controls = registrationPairs(map: cyclicRotation)
    let reused = FragmentControlPointPair(source: controls[0].source, target: controls[0].target)
    #expect(throws: FragmentRegistrationError.invalidRegistry) {
        try FragmentRegistrationSolver.solve(source: registrationSource(), target: registrationSource("b"), controls: controls, checkPoints: [reused])
    }
    #expect(throws: FragmentRegistrationError.invalidRegistry) {
        try FragmentRegistrationSolver.solve(source: registrationSource(), target: registrationSource("b"), controls: controls, checkPoints: [controls[0]])
    }
}

@Test func fragmentRegistrationGravityGateRejectsPerfectButUpsideDownPlanarFit() throws {
    let map: (MetricPoint3D) -> MetricPoint3D = { .init(x: $0.x, y: -$0.y, z: -$0.z) }
    let solved = try FragmentRegistrationSolver.solve(source: registrationSource(), target: registrationSource("b"),
        controls: registrationPairs(map: map), checkPoints: registrationPairs([registrationPoints[4]], map: map), gravityConstraint: .iPhoneYUp)
    #expect(solved.rmsResidualMeters < 1e-8)
    #expect(abs(try #require(solved.gravityDeviationDegrees) - 180) < 1e-8)
    #expect(solved.quality == .requiresReview)
    let upright = try FragmentRegistrationSolver.solve(source: registrationSource(), target: registrationSource("b"),
        controls: registrationPairs(map: { shifted($0) }), checkPoints: registrationPairs([registrationPoints[4]], map: { shifted($0) }), gravityConstraint: .iPhoneYUp)
    #expect(upright.quality == .meetsThresholds)
}

@Test func fragmentRegistrationLargeCommonOffsetDoesNotChangeFitAccuracy() throws {
    let offset = 100_000.0
    let points: [MetricPoint3D] = registrationPoints.map { .init(x: $0.x + offset, y: $0.y - offset, z: $0.z + offset) }
    let solved = try candidate(cyclicRotation, controls: Array(points.prefix(4)), check: points[4])
    #expect(solved.quality == .meetsThresholds)
    expectPoint(try solved.transform.applying(to: points[4]), cyclicRotation(points[4]), tolerance: 1e-7)
}

@Test func fragmentRegistrationRegistryKeepsCandidatesUnplacedUntilOperatorApproval() throws {
    let anchor = registrationSource(), other = registrationSource("b")
    var registry = try FragmentRegistrationRegistry(projectID: UUID(), anchor: anchor)
    try registry.addFragment(other, expectedRevision: registry.revision)
    let id = try registry.propose(source: other, target: anchor, controls: registrationPairs(map: cyclicRotation),
        checkPoints: registrationPairs([registrationPoints[4]], map: cyclicRotation), at: registrationDate, expectedRevision: registry.revision)
    let pending = try registry.assemblyReadiness()
    #expect(pending.placements[0].status == .registered)
    #expect(pending.placements[1].status == .disconnected)
    #expect(pending.placements[1].transformToProject == nil)
    #expect(pending.pendingRegistrationIDs == [id])
    #expect(!pending.readyForAlignedDerivative)
    let original = registry
    try registry.decide(registrationID: id, state: .approved, operatorID: UUID(), reason: "Проверено", at: registrationDate, expectedRevision: registry.revision)
    try registry.validateTransition(from: original)
    let accepted = try registry.assemblyReadiness()
    #expect(accepted.readyForAlignedDerivative)
    expectPoint(try #require(accepted.placements[1].transformToProject).applying(to: registrationPoints[4]), cyclicRotation(registrationPoints[4]))
    #expect(registry.registrations[0].candidate == original.registrations[0].candidate)
}

@Test func fragmentRegistrationRegistryCannotApproveMissingIndependentCheckOrBadQuality() throws {
    let anchor = registrationSource(), other = registrationSource("b")
    var registry = try FragmentRegistrationRegistry(projectID: UUID(), anchor: anchor)
    try registry.addFragment(other, expectedRevision: registry.revision)
    let id = try registry.propose(source: other, target: anchor, controls: registrationPairs(map: cyclicRotation),
        at: registrationDate, expectedRevision: registry.revision)
    #expect(throws: FragmentRegistrationError.qualityRejected) {
        try registry.decide(registrationID: id, state: .approved, operatorID: UUID(), reason: "Проверено", at: registrationDate, expectedRevision: registry.revision)
    }
    #expect(registry.registrations[0].state == .candidate)
    try registry.decide(registrationID: id, state: .rejected, operatorID: UUID(), reason: "Нет независимой проверки", at: registrationDate, expectedRevision: registry.revision)
    #expect(registry.registrations[0].decisions.count == 1)
}

@Test func fragmentRegistrationRegistryComposesChainsAndLeavesDisconnectedFragmentsUnresolved() throws {
    let a = registrationSource(), b = registrationSource("b"), c = registrationSource("c"), isolated = registrationSource("d")
    var registry = try FragmentRegistrationRegistry(projectID: UUID(), anchor: a)
    for reference in [b, c, isolated] { try registry.addFragment(reference, expectedRevision: registry.revision) }
    let first = try addRegistration(&registry, source: b, target: a, map: cyclicRotation)
    let second = try addRegistration(&registry, source: c, target: b, map: { shifted($0) })
    let report = try registry.assemblyReadiness(), placement = report.placements[2]
    #expect(placement.status == .registered)
    #expect(placement.registrationPath == [first, second])
    expectPoint(try #require(placement.transformToProject).applying(to: .init(x: 1, y: 2, z: 3)), .init(x: 16, y: 2, z: 7))
    #expect(report.placements[3].status == .disconnected)
    #expect(!report.readyForAlignedDerivative)
}

@Test func fragmentRegistrationRegistryAcceptsConsistentCycleAndRejectsConflictingMosaic() throws {
    let a = registrationSource(), b = registrationSource("b"), c = registrationSource("c")
    var registry = try FragmentRegistrationRegistry(projectID: UUID(), anchor: a)
    for reference in [b, c] { try registry.addFragment(reference, expectedRevision: registry.revision) }
    _ = try addRegistration(&registry, source: b, target: a, map: { shifted($0, x: 5, y: 0, z: 0) })
    _ = try addRegistration(&registry, source: c, target: b, map: { shifted($0, x: 3, y: 0, z: 0) })
    let direct = try addRegistration(&registry, source: c, target: a, map: { shifted($0, x: 8, y: 0, z: 0) })
    #expect(try registry.assemblyReadiness().readyForAlignedDerivative)
    try registry.decide(registrationID: direct, state: .rejected, operatorID: UUID(), reason: "Повторная привязка", at: registrationDate, expectedRevision: registry.revision)
    _ = try addRegistration(&registry, source: c, target: a, map: { shifted($0, x: 9, y: 0, z: 0) })
    let conflicted = try registry.assemblyReadiness()
    #expect(!conflicted.readyForAlignedDerivative)
    #expect(!conflicted.conflicts.isEmpty)
    #expect(conflicted.placements.allSatisfy { $0.status == .ambiguous && $0.transformToProject == nil })
    #expect(conflicted.conflicts.contains { abs($0.translationDifferenceMeters - 1) < 1e-8 })
}

@Test func fragmentRegistrationRegistryDetectsRotationCycleConflict() throws {
    let a = registrationSource(), b = registrationSource("b")
    var registry = try FragmentRegistrationRegistry(projectID: UUID(), anchor: a)
    try registry.addFragment(b, expectedRevision: registry.revision)
    _ = try addRegistration(&registry, source: b, target: a, map: { $0 })
    _ = try addRegistration(&registry, source: b, target: a, map: { .init(x: -$0.y, y: $0.x, z: $0.z) })
    let report = try registry.assemblyReadiness()
    #expect(report.placements.allSatisfy { $0.status == .ambiguous })
    #expect(report.conflicts.contains { abs($0.rotationDifferenceDegrees - 90) < 1e-8 })
}

@Test func fragmentRegistrationRegistryRejectsMissingFramesStaleRevisionAndEmptyDecision() throws {
    let anchor = registrationSource(), other = registrationSource("b")
    var registry = try FragmentRegistrationRegistry(projectID: UUID(), anchor: anchor)
    #expect(throws: FragmentRegistrationError.missingFrame) {
        try registry.propose(source: other, target: anchor, controls: registrationPairs(map: cyclicRotation), expectedRevision: registry.revision)
    }
    try registry.addFragment(other, expectedRevision: 0)
    #expect(throws: FragmentRegistrationError.revisionConflict) { try registry.addFragment(registrationSource("c"), expectedRevision: 0) }
    let id = try registry.propose(source: other, target: anchor, controls: registrationPairs(map: cyclicRotation),
        checkPoints: registrationPairs([registrationPoints[4]], map: cyclicRotation), at: registrationDate, expectedRevision: registry.revision)
    #expect(throws: FragmentRegistrationError.invalidDecision) {
        try registry.decide(registrationID: id, state: .approved, operatorID: UUID(), reason: "   ", expectedRevision: registry.revision)
    }
}

@Test func fragmentRegistrationSourceHashChangeAndHistoryRewritesCannotReuseOldAlignment() throws {
    let anchor = registrationSource(), other = registrationSource("b")
    var registry = try FragmentRegistrationRegistry(projectID: UUID(), anchor: anchor)
    try registry.addFragment(other, expectedRevision: registry.revision)
    _ = try addRegistration(&registry, source: other, target: anchor, map: cyclicRotation)
    let data = try JSONEncoder().encode(registry)
    #expect(try JSONDecoder().decode(FragmentRegistrationRegistry.self, from: data) == registry)
    var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var fragments = try #require(document["fragments"] as? [[String: Any]])
    fragments[1]["sourceSHA256"] = String(repeating: "c", count: 64); document["fragments"] = fragments
    let changed = try JSONDecoder().decode(FragmentRegistrationRegistry.self, from: JSONSerialization.data(withJSONObject: document))
    #expect(throws: FragmentRegistrationError.missingFrame) { try changed.validate() }
    document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var records = try #require(document["registrations"] as? [[String: Any]])
    var decisions = try #require(records[0]["decisions"] as? [[String: Any]])
    decisions[0]["reason"] = "Переписано"; records[0]["decisions"] = decisions; document["registrations"] = records
    let rewritten = try JSONDecoder().decode(FragmentRegistrationRegistry.self, from: JSONSerialization.data(withJSONObject: document))
    try rewritten.validate()
    #expect(throws: FragmentRegistrationError.invalidRegistry) { try rewritten.validateTransition(from: registry) }
}

@Test func fragmentRegistrationCandidateRejectsTamperedResidualAndMatrix() throws {
    let solved = try candidate(), data = try JSONEncoder().encode(solved)
    var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    document["rmsResidualMeters"] = 1.0
    let bad = try JSONDecoder().decode(FragmentRegistrationCandidate.self, from: JSONSerialization.data(withJSONObject: document))
    #expect(throws: FragmentRegistrationError.invalidRegistry) { try bad.validate() }
    document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var transform = try #require(document["transform"] as? [String: Any])
    transform["rotation"] = [1.0, 0, 0, 0, 1, 0, 0, 0, -1]; document["transform"] = transform
    let mirrored = try JSONDecoder().decode(FragmentRegistrationCandidate.self, from: JSONSerialization.data(withJSONObject: document))
    #expect(throws: FragmentRegistrationError.invalidTransform) { try mirrored.validate() }
}
