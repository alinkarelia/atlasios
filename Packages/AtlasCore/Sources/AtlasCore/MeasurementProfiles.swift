import Foundation

/// The actual A/B observations and the endpoints of a projected dimension are distinct.
/// In a vertical dimension, B can be away from A horizontally; its offset is not height.
public struct MeasurementDimensionEndpoints: Codable, Hashable, Sendable {
    public let sourceStart: MetricPoint3D
    public let sourceEnd: MetricPoint3D
    public let start: MetricPoint3D
    public let end: MetricPoint3D
    public var startLabel: String { "A" }
    public var endLabel: String { "B" }
}

extension MeasurementGeometry {
    public static func dimensionEndpoints(kind: MeasurementKind, from start: MetricPoint3D,
                                          to end: MetricPoint3D) throws -> MeasurementDimensionEndpoints {
        try validate(start); try validate(end)
        let projected: MetricPoint3D
        switch kind {
        case .distance: projected = end
        case .horizontalDistance: projected = .init(x: end.x, y: start.y, z: end.z)
        case .verticalDistance: projected = .init(x: start.x, y: end.y, z: start.z)
        }
        return .init(sourceStart: start, sourceEnd: end, start: start, end: projected)
    }
}

public struct MeasurementProfileSummary: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let context: MeasurementContext
    public let kind: MeasurementKind
    public let minimumMeters: Double
    public let maximumMeters: Double
    public let spreadMeters: Double
    public let frameIDs: [UUID]
    /// Numeric readings of an explicitly identified target remain comparable across
    /// sessions. Their spatial positions can only be compared within one AR frame.
    public let coordinateComparisonAvailable: Bool
    /// Original observations and all scalar corrections remain separately identifiable.
    public let observations: [MeasurementRecord]
    public var count: Int { observations.count }
    public var unit: String { "m" }
}

public enum MeasurementProfile {
    public static func summarize(_ records: [MeasurementRecord]) throws -> MeasurementProfileSummary {
        guard !records.isEmpty, records.count <= 10_000, let first = records.first,
              let context = first.context, context.profileID != nil || context.targetID != nil else {
            throw MeasurementError.incompatibleProfile
        }
        var seen = Set<UUID>()
        for record in records {
            try MeasurementPolicy.validate(record)
            guard seen.insert(record.id).inserted else { throw MeasurementError.duplicateProfileObservation }
            guard record.projectID == first.projectID, record.kind == first.kind,
                  let candidate = record.context, candidate.role == context.role,
                  candidate.target == context.target, candidate.targetID == context.targetID,
                  candidate.profileID == context.profileID,
                  candidate.effectiveDefinition == context.effectiveDefinition else { throw MeasurementError.incompatibleProfile }
        }
        let observations = records.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let minimum = observations.map(\.effectiveMeters).min()!
        let maximum = observations.map(\.effectiveMeters).max()!
        let frames = Set(observations.compactMap(\.frameID)).sorted { $0.uuidString < $1.uuidString }
        let comparable = frames.count == 1 && observations.allSatisfy {
            $0.source == .arRaycast && $0.frameID == frames[0] && $0.start != nil && $0.end != nil
        }
        let groupContext = MeasurementContext(role: context.role, target: context.target,
            targetID: context.targetID, profileID: context.profileID, definition: context.definition)
        return .init(projectID: first.projectID, context: groupContext, kind: first.kind,
                     minimumMeters: minimum, maximumMeters: maximum, spreadMeters: maximum - minimum,
                     frameIDs: frames, coordinateComparisonAvailable: comparable, observations: observations)
    }
}
