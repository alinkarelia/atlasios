import AtlasCore
import Foundation

enum EmptyRoomReviewCoreAdapter {
    static func snapshot(_ record: MeasurementRecord) throws -> EmptyRoomControlObservation {
        try MeasurementPolicy.validate(record)
        guard record.revision > 0, record.effectiveMeters > 0 else { throw EmptyRoomReviewError.invalid("Сначала сохраните положительный контрольный обмер в журнале инструментов.") }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let raw = try encoder.encode(record)
        guard let json = String(data: raw, encoding: .utf8), raw.count <= 256 * 1_024 else { throw EmptyRoomReviewError.invalid("История контрольного обмера слишком велика для ссылки журнала; исходник сохранён в проекте.") }
        func point(_ point: MetricPoint3D?) -> EmptyRoomPoint? { point.map { .init(x: $0.x, y: $0.y, z: $0.z) } }
        return .init(measurementID: record.id, measurementRevision: record.revision, label: record.label,
            source: record.source.rawValue, kind: record.kind.rawValue,
            role: record.context?.role.rawValue ?? (record.kind == .verticalDistance ? "height" : "distance"),
            definition: record.context?.effectiveDefinition.rawValue ?? "unspecified",
            position: record.context?.position.rawValue ?? "unspecified", positionNote: record.context?.positionNote ?? "",
            profileID: record.context?.profileID, originalTargetID: record.context?.targetID, originalTarget: record.context?.target.rawValue,
            frameID: record.frameID, start: point(record.start), end: point(record.end),
            originalMeters: record.originalMeters, effectiveMeters: record.effectiveMeters,
            observedAt: Date(timeIntervalSince1970: floor(record.createdAt.timeIntervalSince1970)),
            rawMeasurementJSON: json)
    }
}
