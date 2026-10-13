import Foundation

public enum FragmentRegistrationError: String, Error, LocalizedError, Sendable {
    case invalidReference, invalidCoordinate, unsupportedUnit, missingFrame, sameFrame
    case insufficientControls, degenerateControls, unsupportedEvidence, invalidPolicy
    case invalidTransform, invalidRegistry, missingCandidate, qualityRejected, invalidDecision, revisionConflict
    public var errorDescription: String? {
        switch self {
        case .invalidReference: "У фрагмента должны быть неизменяемые идентификаторы, версия и SHA-256 оригинала."
        case .invalidCoordinate: "Контрольные точки должны содержать конечные координаты в допустимых локальных метрах."
        case .unsupportedUnit: "Для привязки нужны явно объявленные метры."
        case .missingFrame: "Система координат или исходный фрагмент не зарегистрированы."
        case .sameFrame: "Привязка требует двух разных систем координат."
        case .insufficientControls: "Нужны минимум три соответствующие контрольные точки."
        case .degenerateControls: "Контрольные точки слишком близки или лежат почти на одной прямой."
        case .unsupportedEvidence: "GPS сам по себе не подтверждает точную привязку локальных LiDAR-фрагментов."
        case .invalidPolicy: "Порог контроля привязки некорректен."
        case .invalidTransform: "Допустимы только поворот и перенос без масштаба или отражения."
        case .invalidRegistry: "Документ привязки или его история некорректны."
        case .missingCandidate: "Предложение привязки не найдено."
        case .qualityRejected: "Отклонения контрольных точек превышают заданные пороги."
        case .invalidDecision: "Подтверждение требует оператора, даты и причины."
        case .revisionConflict: "Документ изменился. Обновите его перед сохранением решения."
        }
    }
}

public enum FragmentCoordinateUnit: String, Codable, Hashable, Sendable { case meters, centimeters, unknown }

/// A registration refers to exact original bytes and their original local frame.
/// Replacing a capture requires a new registry entry, never silently reusing its transform.
public struct FragmentSourceReference: Codable, Hashable, Sendable {
    public let captureID: UUID
    public let frameID: UUID
    public let sourceSHA256: String
    public let sourceVersion: Int64
    public let unit: FragmentCoordinateUnit
    public init(captureID: UUID, frameID: UUID, sourceSHA256: String, sourceVersion: Int64 = 1,
                unit: FragmentCoordinateUnit = .meters) {
        self.captureID = captureID; self.frameID = frameID; self.sourceSHA256 = sourceSHA256
        self.sourceVersion = sourceVersion; self.unit = unit
    }
    public func validate() throws {
        guard sourceVersion > 0, sourceSHA256.utf8.count == 64,
              sourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw FragmentRegistrationError.invalidReference
        }
        guard unit == .meters else { throw FragmentRegistrationError.unsupportedUnit }
    }
}

public enum FragmentControlEvidence: String, Codable, Hashable, Sendable {
    case physicalMarker, operatorMatchedPoint, gpsOnly
}

public struct FragmentControlPointPair: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let source: MetricPoint3D
    public let target: MetricPoint3D
    public let evidence: FragmentControlEvidence
    public init(id: UUID = UUID(), source: MetricPoint3D, target: MetricPoint3D,
                evidence: FragmentControlEvidence = .physicalMarker) {
        self.id = id; self.source = source; self.target = target; self.evidence = evidence
    }
}

public struct FragmentRegistrationPolicy: Codable, Hashable, Sendable {
    public let maximumResidualMeters: Double
    public let maximumRMSMeters: Double
    public let minimumControlSpanMeters: Double
    public let minimumTriangleSine: Double
    public let maximumCheckResidualMeters: Double
    public let maximumCheckRMSMeters: Double
    public let minimumIndependentCheckPoints: Int
    public init(maximumResidualMeters: Double = 0.10, maximumRMSMeters: Double = 0.05,
                minimumControlSpanMeters: Double = 0.25, minimumTriangleSine: Double = 0.01,
                maximumCheckResidualMeters: Double = 0.15, maximumCheckRMSMeters: Double = 0.10,
                minimumIndependentCheckPoints: Int = 1) {
        self.maximumResidualMeters = maximumResidualMeters; self.maximumRMSMeters = maximumRMSMeters
        self.minimumControlSpanMeters = minimumControlSpanMeters; self.minimumTriangleSine = minimumTriangleSine
        self.maximumCheckResidualMeters = maximumCheckResidualMeters; self.maximumCheckRMSMeters = maximumCheckRMSMeters
        self.minimumIndependentCheckPoints = minimumIndependentCheckPoints
    }
    public func validate() throws {
        guard maximumResidualMeters.isFinite, maximumRMSMeters.isFinite,
              minimumControlSpanMeters.isFinite, minimumTriangleSine.isFinite,
              maximumResidualMeters > 0, maximumResidualMeters <= 10,
              maximumRMSMeters > 0, maximumRMSMeters <= maximumResidualMeters,
              minimumControlSpanMeters >= 0.01, minimumControlSpanMeters <= 1_000,
              minimumTriangleSine >= 0.000_001, minimumTriangleSine <= 1,
              maximumCheckResidualMeters.isFinite, maximumCheckRMSMeters.isFinite,
              maximumCheckResidualMeters > 0, maximumCheckResidualMeters <= 10,
              maximumCheckRMSMeters > 0, maximumCheckRMSMeters <= maximumCheckResidualMeters,
              (1...32).contains(minimumIndependentCheckPoints) else {
            throw FragmentRegistrationError.invalidPolicy
        }
    }
}

/// Only use gravity constraints when BOTH source axes have known physical up.
/// Unknown imported model axes must not silently be treated as iPhone Y-up.
public struct FragmentGravityConstraint: Codable, Hashable, Sendable {
    public let sourceUp: MetricPoint3D
    public let targetUp: MetricPoint3D
    public let maximumDeviationDegrees: Double
    public init(sourceUp: MetricPoint3D, targetUp: MetricPoint3D, maximumDeviationDegrees: Double = 5) {
        self.sourceUp = sourceUp; self.targetUp = targetUp; self.maximumDeviationDegrees = maximumDeviationDegrees
    }
    public static let iPhoneYUp = Self(sourceUp: .init(x: 0, y: 1, z: 0), targetUp: .init(x: 0, y: 1, z: 0))
    public func validate() throws {
        try FragmentRegistrationMath.validate(sourceUp); try FragmentRegistrationMath.validate(targetUp)
        guard abs(FragmentRegistrationMath.norm(sourceUp) - 1) < 1e-6,
              abs(FragmentRegistrationMath.norm(targetUp) - 1) < 1e-6,
              maximumDeviationDegrees.isFinite, maximumDeviationDegrees > 0, maximumDeviationDegrees <= 30 else {
            throw FragmentRegistrationError.invalidPolicy
        }
    }
}

/// ROW-MAJOR rotation; target = R * source + translation. Coordinates remain in metres.
public struct FragmentRigidTransform: Codable, Hashable, Sendable {
    public let rotation: [Double]
    public let translation: MetricPoint3D
    public init(rotation: [Double], translation: MetricPoint3D) {
        self.rotation = rotation; self.translation = translation
    }
    public static let identity = Self(rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1], translation: .init(x: 0, y: 0, z: 0))
    public func validate() throws {
        guard rotation.count == 9, rotation.allSatisfy(\.isFinite) else { throw FragmentRegistrationError.invalidTransform }
        try FragmentRegistrationMath.validate(translation)
        for row in 0..<3 {
            for other in 0..<3 {
                var dot = 0.0
                for column in 0..<3 { dot += rotation[row * 3 + column] * rotation[other * 3 + column] }
                guard abs(dot - (row == other ? 1 : 0)) <= 1e-8 else { throw FragmentRegistrationError.invalidTransform }
            }
        }
        let r = rotation
        let determinant = r[0] * (r[4] * r[8] - r[5] * r[7]) - r[1] * (r[3] * r[8] - r[5] * r[6]) + r[2] * (r[3] * r[7] - r[4] * r[6])
        guard abs(determinant - 1) <= 1e-8 else { throw FragmentRegistrationError.invalidTransform }
    }
    public func applying(to point: MetricPoint3D) throws -> MetricPoint3D {
        try validate(); try FragmentRegistrationMath.validate(point)
        let result = unchecked(point)
        try FragmentRegistrationMath.validate(result)
        return result
    }
    public func inverse() throws -> Self {
        try validate()
        let r = rotation, transpose = [r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]]
        let inverseRotation = Self(rotation: transpose, translation: .init(x: 0, y: 0, z: 0))
        let value = inverseRotation.unchecked(FragmentRegistrationMath.multiply(translation, -1))
        let result = Self(rotation: transpose, translation: value); try result.validate(); return result
    }
    /// The result applies this transform first, then `next`.
    public func followed(by next: Self) throws -> Self {
        try validate(); try next.validate()
        var r = [Double](repeating: 0, count: 9)
        for row in 0..<3 { for column in 0..<3 { for k in 0..<3 {
            r[row * 3 + column] += next.rotation[row * 3 + k] * rotation[k * 3 + column]
        } } }
        let result = Self(rotation: r, translation: next.unchecked(translation)); try result.validate(); return result
    }
    fileprivate func unchecked(_ point: MetricPoint3D) -> MetricPoint3D {
        let r = rotation
        return .init(x: r[0] * point.x + r[1] * point.y + r[2] * point.z + translation.x,
                     y: r[3] * point.x + r[4] * point.y + r[5] * point.z + translation.y,
                     z: r[6] * point.x + r[7] * point.y + r[8] * point.z + translation.z)
    }
}

public enum FragmentRegistrationQuality: String, Codable, Hashable, Sendable { case meetsThresholds, requiresReview }
public enum FragmentRegistrationState: String, Codable, Hashable, Sendable { case candidate, approved, rejected }
public struct FragmentControlResidual: Codable, Hashable, Sendable {
    public let controlID: UUID
    public let distanceMeters: Double
}

public struct FragmentRegistrationCandidate: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let source: FragmentSourceReference
    public let target: FragmentSourceReference
    public let controls: [FragmentControlPointPair]
    public let checkPoints: [FragmentControlPointPair]
    public let gravityConstraint: FragmentGravityConstraint?
    public let policy: FragmentRegistrationPolicy
    public let createdAt: Date
    public let transform: FragmentRigidTransform
    public let residuals: [FragmentControlResidual]
    public let rmsResidualMeters: Double
    public let maximumResidualMeters: Double
    public let checkResiduals: [FragmentControlResidual]
    public let checkRMSResidualMeters: Double?
    public let maximumCheckResidualMeters: Double?
    public let gravityDeviationDegrees: Double?
    public let quality: FragmentRegistrationQuality
    public func validate() throws {
        let replay = try FragmentRegistrationSolver.solve(source: source, target: target, controls: controls,
            checkPoints: checkPoints, gravityConstraint: gravityConstraint, policy: policy, at: createdAt, id: id)
        try transform.validate()
        guard quality == replay.quality, residuals.count == replay.residuals.count,
              abs(rmsResidualMeters - replay.rmsResidualMeters) < 1e-8,
              abs(maximumResidualMeters - replay.maximumResidualMeters) < 1e-8,
              FragmentRegistrationMath.near(checkRMSResidualMeters, replay.checkRMSResidualMeters),
              FragmentRegistrationMath.near(maximumCheckResidualMeters, replay.maximumCheckResidualMeters),
              FragmentRegistrationMath.near(gravityDeviationDegrees, replay.gravityDeviationDegrees),
              checkResiduals.count == replay.checkResiduals.count,
              FragmentRegistrationMath.transformDistance(transform, replay.transform).translation < 1e-7,
              FragmentRegistrationMath.transformDistance(transform, replay.transform).rotationDegrees < 0.000_01 else {
            throw FragmentRegistrationError.invalidRegistry
        }
        for (stored, actual) in zip(residuals + checkResiduals, replay.residuals + replay.checkResiduals) {
            guard stored.controlID == actual.controlID, stored.distanceMeters.isFinite,
                  abs(stored.distanceMeters - actual.distanceMeters) < 1e-8 else { throw FragmentRegistrationError.invalidRegistry }
        }
    }
}

public enum FragmentRegistrationSolver {
    public static func solve(source: FragmentSourceReference, target: FragmentSourceReference,
                             controls: [FragmentControlPointPair], checkPoints: [FragmentControlPointPair] = [],
                             gravityConstraint: FragmentGravityConstraint? = nil, policy: FragmentRegistrationPolicy = .init(),
                             at: Date = Date(), id: UUID = UUID()) throws -> FragmentRegistrationCandidate {
        try source.validate(); try target.validate(); try policy.validate(); try gravityConstraint?.validate()
        guard source.frameID != target.frameID, source.captureID != target.captureID else { throw FragmentRegistrationError.sameFrame }
        guard controls.count >= 3, controls.count <= 2_048 else { throw FragmentRegistrationError.insufficientControls }
        let allPoints = controls + checkPoints
        guard checkPoints.count <= 2_048, at.timeIntervalSinceReferenceDate.isFinite,
              Set(allPoints.map(\.id)).count == allPoints.count else { throw FragmentRegistrationError.invalidRegistry }
        for pair in allPoints {
            guard pair.evidence != .gpsOnly else { throw FragmentRegistrationError.unsupportedEvidence }
            try FragmentRegistrationMath.validate(pair.source); try FragmentRegistrationMath.validate(pair.target)
        }
        guard Set(controls.map(\.source)).count == controls.count,
              Set(controls.map(\.target)).count == controls.count else { throw FragmentRegistrationError.degenerateControls }
        guard Set(checkPoints.map(\.source)).count == checkPoints.count,
              Set(checkPoints.map(\.target)).count == checkPoints.count else { throw FragmentRegistrationError.invalidRegistry }
        for check in checkPoints {
            guard !controls.contains(where: {
                FragmentRegistrationMath.norm(FragmentRegistrationMath.subtract(check.source, $0.source)) < 1e-6 ||
                FragmentRegistrationMath.norm(FragmentRegistrationMath.subtract(check.target, $0.target)) < 1e-6
            }) else { throw FragmentRegistrationError.invalidRegistry }
        }
        let sourcePoints = controls.map(\.source), targetPoints = controls.map(\.target)
        try FragmentRegistrationMath.validateSpread(sourcePoints, policy: policy)
        try FragmentRegistrationMath.validateSpread(targetPoints, policy: policy)
        let sourceCenter = FragmentRegistrationMath.center(sourcePoints), targetCenter = FragmentRegistrationMath.center(targetPoints)
        var covariance = [Double](repeating: 0, count: 9)
        for pair in controls {
            let p = FragmentRegistrationMath.components(FragmentRegistrationMath.subtract(pair.source, sourceCenter))
            let q = FragmentRegistrationMath.components(FragmentRegistrationMath.subtract(pair.target, targetCenter))
            for row in 0..<3 { for column in 0..<3 { covariance[row * 3 + column] += p[row] * q[column] } }
        }
        let s = covariance, trace = s[0] + s[4] + s[8]
        let horn = [trace, s[5] - s[7], s[6] - s[2], s[1] - s[3],
                    s[5] - s[7], s[0] - s[4] - s[8], s[1] + s[3], s[2] + s[6],
                    s[6] - s[2], s[1] + s[3], -s[0] + s[4] - s[8], s[5] + s[7],
                    s[1] - s[3], s[2] + s[6], s[5] + s[7], -s[0] - s[4] + s[8]]
        let quaternion = try FragmentRegistrationMath.largestEigenvector(horn)
        let w = quaternion[0], x = quaternion[1], y = quaternion[2], z = quaternion[3]
        let rotation = [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
                        2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
                        2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]
        let noTranslation = FragmentRigidTransform(rotation: rotation, translation: .init(x: 0, y: 0, z: 0))
        let translation = FragmentRegistrationMath.subtract(targetCenter, noTranslation.unchecked(sourceCenter))
        let transform = FragmentRigidTransform(rotation: rotation, translation: translation); try transform.validate()
        var sum = 0.0, maximum = 0.0
        let residuals = try controls.map { pair -> FragmentControlResidual in
            let transformed = try transform.applying(to: pair.source)
            let distance = FragmentRegistrationMath.norm(FragmentRegistrationMath.subtract(transformed, pair.target))
            sum += distance * distance; maximum = max(maximum, distance)
            return .init(controlID: pair.id, distanceMeters: distance)
        }
        let rms = sqrt(sum / Double(controls.count))
        var checkSum = 0.0, checkMaximum = 0.0
        let checkResiduals = try checkPoints.map { pair -> FragmentControlResidual in
            let distance = FragmentRegistrationMath.norm(FragmentRegistrationMath.subtract(try transform.applying(to: pair.source), pair.target))
            checkSum += distance * distance; checkMaximum = max(checkMaximum, distance)
            return .init(controlID: pair.id, distanceMeters: distance)
        }
        let checkRMS = checkPoints.isEmpty ? nil : sqrt(checkSum / Double(checkPoints.count))
        let gravityDeviation: Double? = gravityConstraint.map { constraint in
            let rotatedUp = noTranslation.unchecked(constraint.sourceUp)
            let dot = rotatedUp.x * constraint.targetUp.x + rotatedUp.y * constraint.targetUp.y + rotatedUp.z * constraint.targetUp.z
            return acos(min(1, max(-1, dot))) * 180 / .pi
        }
        let gravityPassed = gravityConstraint == nil || gravityDeviation! <= gravityConstraint!.maximumDeviationDegrees
        let qualified = maximum <= policy.maximumResidualMeters && rms <= policy.maximumRMSMeters &&
            checkPoints.count >= policy.minimumIndependentCheckPoints && checkMaximum <= policy.maximumCheckResidualMeters &&
            (checkRMS ?? .infinity) <= policy.maximumCheckRMSMeters && gravityPassed
        return .init(id: id, source: source, target: target, controls: controls, checkPoints: checkPoints, gravityConstraint: gravityConstraint,
                     policy: policy, createdAt: at, transform: transform, residuals: residuals, rmsResidualMeters: rms,
                     maximumResidualMeters: maximum, checkResiduals: checkResiduals, checkRMSResidualMeters: checkRMS,
                     maximumCheckResidualMeters: checkPoints.isEmpty ? nil : checkMaximum,
                     gravityDeviationDegrees: gravityDeviation, quality: qualified ? .meetsThresholds : .requiresReview)
    }
}

public struct FragmentRegistrationDecision: Codable, Hashable, Sendable {
    public let revision: Int64
    public let state: FragmentRegistrationState
    public let operatorID: UUID
    public let decidedAt: Date
    public let reason: String
}
public struct FragmentRegistrationRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { candidate.id }
    public let candidate: FragmentRegistrationCandidate
    public fileprivate(set) var decisions: [FragmentRegistrationDecision]
    public var state: FragmentRegistrationState { decisions.last?.state ?? .candidate }
}

public enum FragmentAssemblyStatus: String, Codable, Hashable, Sendable { case registered, disconnected, ambiguous }
public struct FragmentAssemblyPlacement: Codable, Hashable, Sendable {
    public let source: FragmentSourceReference
    public let projectFrameID: UUID
    public let status: FragmentAssemblyStatus
    public let transformToProject: FragmentRigidTransform?
    public let registrationPath: [UUID]
}
public struct FragmentCycleConflict: Codable, Hashable, Sendable {
    public let registrationID: UUID
    public let translationDifferenceMeters: Double
    public let rotationDifferenceDegrees: Double
}
/// Readiness is for a separately labelled aligned derivative, not proof of coverage,
/// mesh fusion, an orthophoto, or centimetre accuracy away from control points.
public struct FragmentAssemblyReadiness: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let projectID: UUID
    public let projectFrameID: UUID
    public let registryRevision: Int64
    public let maximumCycleTranslationMeters: Double
    public let maximumCycleRotationDegrees: Double
    public let placements: [FragmentAssemblyPlacement]
    public let pendingRegistrationIDs: [UUID]
    public let conflicts: [FragmentCycleConflict]
    public var readyForAlignedDerivative: Bool { !placements.isEmpty && placements.allSatisfy { $0.status == .registered } && conflicts.isEmpty }
}

/// Append-only sources and decisions. Backend authorization must independently
/// verify operator identity; a Codable UUID alone is not authentication.
public struct FragmentRegistrationRegistry: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let projectID: UUID
    public let projectFrameID: UUID
    public let anchor: FragmentSourceReference
    public private(set) var fragments: [FragmentSourceReference]
    public private(set) var registrations: [FragmentRegistrationRecord]
    public private(set) var revision: Int64
    public init(projectID: UUID, anchor: FragmentSourceReference) throws {
        try anchor.validate()
        schemaVersion = 1; self.projectID = projectID; projectFrameID = anchor.frameID; self.anchor = anchor
        fragments = [anchor]; registrations = []; revision = 0
    }
    public mutating func addFragment(_ reference: FragmentSourceReference, expectedRevision: Int64) throws {
        try requireRevision(expectedRevision); try reference.validate()
        guard fragments.count < 512, !fragments.contains(where: { $0.captureID == reference.captureID || $0.frameID == reference.frameID }) else {
            throw FragmentRegistrationError.invalidReference
        }
        fragments.append(reference); revision += 1
    }
    @discardableResult public mutating func propose(source: FragmentSourceReference, target: FragmentSourceReference,
                                                    controls: [FragmentControlPointPair], checkPoints: [FragmentControlPointPair] = [],
                                                    gravityConstraint: FragmentGravityConstraint? = nil, policy: FragmentRegistrationPolicy = .init(),
                                                    at: Date = Date(), expectedRevision: Int64) throws -> UUID {
        try requireRevision(expectedRevision)
        guard fragments.contains(source), fragments.contains(target) else { throw FragmentRegistrationError.missingFrame }
        guard registrations.count < 1_024 else { throw FragmentRegistrationError.invalidRegistry }
        let candidate = try FragmentRegistrationSolver.solve(source: source, target: target, controls: controls,
            checkPoints: checkPoints, gravityConstraint: gravityConstraint, policy: policy, at: at)
        registrations.append(.init(candidate: candidate, decisions: [])); revision += 1; return candidate.id
    }
    public mutating func decide(registrationID: UUID, state: FragmentRegistrationState, operatorID: UUID,
                                reason: String, at: Date = Date(), expectedRevision: Int64) throws {
        try requireRevision(expectedRevision)
        guard let index = registrations.firstIndex(where: { $0.id == registrationID }) else { throw FragmentRegistrationError.missingCandidate }
        let record = registrations[index]
        guard state != .candidate, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reason.utf8.count <= 4_096, at.timeIntervalSinceReferenceDate.isFinite, at >= record.candidate.createdAt,
              at >= (record.decisions.last?.decidedAt ?? record.candidate.createdAt), record.decisions.count < 128 else {
            throw FragmentRegistrationError.invalidDecision
        }
        guard state != .approved || record.candidate.quality == .meetsThresholds else { throw FragmentRegistrationError.qualityRejected }
        registrations[index].decisions.append(.init(revision: Int64(record.decisions.count + 1), state: state,
                                                    operatorID: operatorID, decidedAt: at, reason: reason))
        revision += 1
    }
    public func validate() throws {
        try anchor.validate()
        guard schemaVersion == 1, projectFrameID == anchor.frameID, fragments.first == anchor,
              !fragments.isEmpty, fragments.count <= 512, registrations.count <= 1_024,
              Set(fragments.map(\.captureID)).count == fragments.count,
              Set(fragments.map(\.frameID)).count == fragments.count,
              Set(registrations.map(\.id)).count == registrations.count,
              revision == Int64(fragments.count - 1 + registrations.count + registrations.reduce(0) { $0 + $1.decisions.count }) else {
            throw FragmentRegistrationError.invalidRegistry
        }
        for source in fragments { try source.validate() }
        for record in registrations {
            guard fragments.contains(record.candidate.source), fragments.contains(record.candidate.target), record.decisions.count <= 128 else {
                throw FragmentRegistrationError.missingFrame
            }
            try record.candidate.validate()
            var previous = record.candidate.createdAt
            for (index, decision) in record.decisions.enumerated() {
                guard decision.revision == Int64(index + 1), decision.state != .candidate,
                      decision.state != .approved || record.candidate.quality == .meetsThresholds,
                      !decision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      decision.reason.utf8.count <= 4_096, decision.decidedAt.timeIntervalSinceReferenceDate.isFinite,
                      decision.decidedAt >= previous else { throw FragmentRegistrationError.invalidDecision }
                previous = decision.decidedAt
            }
        }
    }
    public func validateTransition(from original: Self) throws {
        try original.validate(); try validate()
        guard schemaVersion == original.schemaVersion, projectID == original.projectID, anchor == original.anchor,
              projectFrameID == original.projectFrameID, revision >= original.revision,
              Array(fragments.prefix(original.fragments.count)) == original.fragments,
              registrations.count >= original.registrations.count else { throw FragmentRegistrationError.invalidRegistry }
        for (old, next) in zip(original.registrations, registrations) {
            guard old.candidate == next.candidate, Array(next.decisions.prefix(old.decisions.count)) == old.decisions else {
                throw FragmentRegistrationError.invalidRegistry
            }
        }
    }
    private func requireRevision(_ expected: Int64) throws {
        guard expected == revision else { throw FragmentRegistrationError.revisionConflict }
        try validate()
    }

    public func assemblyReadiness(maximumCycleTranslationMeters: Double = 0.15,
                                   maximumCycleRotationDegrees: Double = 1) throws -> FragmentAssemblyReadiness {
        try validate()
        guard maximumCycleTranslationMeters.isFinite, maximumCycleRotationDegrees.isFinite,
              maximumCycleTranslationMeters > 0, maximumCycleTranslationMeters <= 10,
              maximumCycleRotationDegrees > 0, maximumCycleRotationDegrees <= 30 else { throw FragmentRegistrationError.invalidPolicy }
        struct Edge { let other: UUID; let otherToNode: FragmentRigidTransform; let registrationID: UUID }
        var adjacency: [UUID: [Edge]] = [:]
        for reference in fragments { adjacency[reference.frameID] = [] }
        for record in registrations.filter({ $0.state == .approved }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let candidate = record.candidate
            adjacency[candidate.source.frameID, default: []].append(.init(other: candidate.target.frameID, otherToNode: try candidate.transform.inverse(), registrationID: record.id))
            adjacency[candidate.target.frameID, default: []].append(.init(other: candidate.source.frameID, otherToNode: candidate.transform, registrationID: record.id))
        }
        var visited = Set<UUID>(), placements: [UUID: FragmentAssemblyPlacement] = [:], conflictsByID: [UUID: FragmentCycleConflict] = [:]
        let orderedRoots = [anchor.frameID] + fragments.map(\.frameID).filter { $0 != anchor.frameID }.sorted { $0.uuidString < $1.uuidString }
        for root in orderedRoots where !visited.contains(root) {
            var transforms = [root: FragmentRigidTransform.identity], paths: [UUID: [UUID]] = [root: []]
            var queue = [root], index = 0, componentConflicts = Set<UUID>()
            while index < queue.count {
                let frame = queue[index]; index += 1; visited.insert(frame)
                let known = transforms[frame]!
                for edge in adjacency[frame, default: []] {
                    let proposed = try edge.otherToNode.followed(by: known)
                    if let existing = transforms[edge.other] {
                        let difference = FragmentRegistrationMath.transformDistance(existing, proposed)
                        if difference.translation > maximumCycleTranslationMeters || difference.rotationDegrees > maximumCycleRotationDegrees {
                            componentConflicts.insert(edge.registrationID)
                            let previous = conflictsByID[edge.registrationID]
                            conflictsByID[edge.registrationID] = .init(registrationID: edge.registrationID,
                                translationDifferenceMeters: max(previous?.translationDifferenceMeters ?? 0, difference.translation),
                                rotationDifferenceDegrees: max(previous?.rotationDifferenceDegrees ?? 0, difference.rotationDegrees))
                        }
                    } else {
                        transforms[edge.other] = proposed; paths[edge.other] = paths[frame, default: []] + [edge.registrationID]; queue.append(edge.other)
                    }
                }
            }
            let status: FragmentAssemblyStatus = !componentConflicts.isEmpty ? .ambiguous : root == anchor.frameID ? .registered : .disconnected
            for frame in queue {
                let reference = fragments.first { $0.frameID == frame }!
                placements[frame] = .init(source: reference, projectFrameID: projectFrameID, status: status,
                    transformToProject: status == .registered ? transforms[frame] : nil,
                    registrationPath: status == .registered ? paths[frame, default: []] : [])
            }
        }
        return .init(schemaVersion: 1, projectID: projectID, projectFrameID: projectFrameID, registryRevision: revision,
                     maximumCycleTranslationMeters: maximumCycleTranslationMeters, maximumCycleRotationDegrees: maximumCycleRotationDegrees,
                     placements: fragments.map { placements[$0.frameID]! },
                     pendingRegistrationIDs: registrations.filter { $0.state == .candidate }.map(\.id).sorted { $0.uuidString < $1.uuidString },
                     conflicts: conflictsByID.values.sorted { $0.registrationID.uuidString < $1.registrationID.uuidString })
    }
}

private enum FragmentRegistrationMath {
    static func near(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) { case (nil, nil): true; case let (a?, b?): a.isFinite && b.isFinite && abs(a - b) < 1e-8; default: false }
    }
    static func components(_ p: MetricPoint3D) -> [Double] { [p.x, p.y, p.z] }
    static func validate(_ p: MetricPoint3D) throws {
        guard components(p).allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw FragmentRegistrationError.invalidCoordinate }
    }
    static func subtract(_ a: MetricPoint3D, _ b: MetricPoint3D) -> MetricPoint3D { .init(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func multiply(_ a: MetricPoint3D, _ factor: Double) -> MetricPoint3D { .init(x: a.x * factor, y: a.y * factor, z: a.z * factor) }
    static func norm(_ p: MetricPoint3D) -> Double { sqrt(p.x * p.x + p.y * p.y + p.z * p.z) }
    static func center(_ points: [MetricPoint3D]) -> MetricPoint3D {
        var x = 0.0, y = 0.0, z = 0.0
        for p in points { x += p.x; y += p.y; z += p.z }
        let n = Double(points.count); return .init(x: x / n, y: y / n, z: z / n)
    }
    static func validateSpread(_ points: [MetricPoint3D], policy: FragmentRegistrationPolicy) throws {
        let centroid = center(points)
        let first = points.max { norm(subtract($0, centroid)) < norm(subtract($1, centroid)) }!
        let second = points.max { norm(subtract($0, first)) < norm(subtract($1, first)) }!
        let baseline = subtract(second, first), length = norm(baseline)
        guard length >= policy.minimumControlSpanMeters else { throw FragmentRegistrationError.degenerateControls }
        var largestSine = 0.0
        for point in points {
            let v = subtract(point, first), vLength = norm(v)
            guard vLength >= policy.minimumControlSpanMeters else { continue }
            let cross = MetricPoint3D(x: baseline.y * v.z - baseline.z * v.y,
                                      y: baseline.z * v.x - baseline.x * v.z,
                                      z: baseline.x * v.y - baseline.y * v.x)
            largestSine = max(largestSine, norm(cross) / (length * vLength))
        }
        guard largestSine >= policy.minimumTriangleSine else { throw FragmentRegistrationError.degenerateControls }
    }
    /// Jacobi diagonalization chooses the greatest algebraic eigenvalue, not
    /// the greatest absolute eigenvalue (power iteration can select the wrong rotation).
    static func largestEigenvector(_ matrix: [Double]) throws -> [Double] {
        let scale = matrix.map(abs).max() ?? 0
        guard scale.isFinite, scale > 0 else { throw FragmentRegistrationError.degenerateControls }
        var a = matrix.map { $0 / scale }, v = [Double](repeating: 0, count: 16)
        for i in 0..<4 { v[i * 4 + i] = 1 }
        for _ in 0..<100 {
            var p = 0, q = 1, largest = 0.0
            for row in 0..<4 { for column in (row + 1)..<4 {
                if abs(a[row * 4 + column]) > largest { largest = abs(a[row * 4 + column]); p = row; q = column }
            } }
            if largest < 1e-14 { break }
            let apq = a[p * 4 + q], tau = (a[q * 4 + q] - a[p * 4 + p]) / (2 * apq)
            let t = (tau >= 0 ? 1.0 : -1.0) / (abs(tau) + sqrt(1 + tau * tau))
            let c = 1 / sqrt(1 + t * t), s = t * c
            let app = a[p * 4 + p], aqq = a[q * 4 + q]
            a[p * 4 + p] = app - t * apq; a[q * 4 + q] = aqq + t * apq
            a[p * 4 + q] = 0; a[q * 4 + p] = 0
            for k in 0..<4 where k != p && k != q {
                let akp = a[k * 4 + p], akq = a[k * 4 + q]
                a[k * 4 + p] = c * akp - s * akq; a[p * 4 + k] = a[k * 4 + p]
                a[k * 4 + q] = s * akp + c * akq; a[q * 4 + k] = a[k * 4 + q]
            }
            for k in 0..<4 {
                let vkp = v[k * 4 + p], vkq = v[k * 4 + q]
                v[k * 4 + p] = c * vkp - s * vkq; v[k * 4 + q] = s * vkp + c * vkq
            }
        }
        let order = (0..<4).sorted { a[$0 * 4 + $0] > a[$1 * 4 + $1] }
        guard a[order[0] * 4 + order[0]] - a[order[1] * 4 + order[1]] > 1e-10 else { throw FragmentRegistrationError.degenerateControls }
        let result = (0..<4).map { v[$0 * 4 + order[0]] }, length = sqrt(result.reduce(0) { $0 + $1 * $1 })
        guard length.isFinite, length > 0 else { throw FragmentRegistrationError.invalidTransform }
        return result.map { $0 / length }
    }
    static func transformDistance(_ a: FragmentRigidTransform, _ b: FragmentRigidTransform) -> (translation: Double, rotationDegrees: Double) {
        let dot = zip(a.rotation, b.rotation).reduce(0.0) { $0 + $1.0 * $1.1 }
        let cosine = min(1, max(-1, (dot - 1) / 2))
        return (norm(subtract(a.translation, b.translation)), acos(cosine) * 180 / .pi)
    }
}
