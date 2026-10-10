import Foundation

/// Provenance is retained even when an operator corrects the displayed point.
public enum GeoFixSource: String, Codable, Sendable {
    case deviceLocation, photoEXIF, operatorEntered
}

/// WGS84 observation, not a transformation from AR metres to map coordinates.
public struct GeoLocationFix: Codable, Hashable, Sendable {
    public var coordinate: GeographicCoordinate
    public var altitudeMeters: Double?
    public var horizontalAccuracyMeters: Double?
    public var verticalAccuracyMeters: Double?
    public var observedAt: Date
    public var source: GeoFixSource
    public var isSimulated: Bool

    public init(coordinate: GeographicCoordinate, altitudeMeters: Double? = nil,
                horizontalAccuracyMeters: Double? = nil, verticalAccuracyMeters: Double? = nil,
                observedAt: Date, source: GeoFixSource, isSimulated: Bool = false) {
        self.coordinate = coordinate; self.altitudeMeters = altitudeMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.verticalAccuracyMeters = verticalAccuracyMeters
        self.observedAt = observedAt; self.source = source; self.isSimulated = isSimulated
    }
}

/// A nil coordinate restores the original automatic observation; it never deletes it.
public struct GeoTagCorrection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var coordinate: GeographicCoordinate?
    public var altitudeMeters: Double?
    public var estimatedAccuracyMeters: Double?
    public var note: String
    public var changedAt: Date

    public init(id: UUID = UUID(), coordinate: GeographicCoordinate?, altitudeMeters: Double? = nil,
                estimatedAccuracyMeters: Double? = nil, note: String = "", changedAt: Date = Date()) {
        self.id = id; self.coordinate = coordinate; self.altitudeMeters = altitudeMeters
        self.estimatedAccuracyMeters = estimatedAccuracyMeters
        self.note = note; self.changedAt = changedAt
    }
}

public struct GeoTag: Codable, Hashable, Sendable {
    public var automaticFix: GeoLocationFix?
    public var corrections: [GeoTagCorrection]

    public init(automaticFix: GeoLocationFix? = nil, corrections: [GeoTagCorrection] = []) {
        self.automaticFix = automaticFix; self.corrections = corrections
    }

    public var effectiveFix: GeoLocationFix? {
        guard let latest = corrections.last, let coordinate = latest.coordinate else { return automaticFix }
        return GeoLocationFix(coordinate: coordinate, altitudeMeters: latest.altitudeMeters,
                              horizontalAccuracyMeters: latest.estimatedAccuracyMeters,
                              observedAt: latest.changedAt, source: .operatorEntered)
    }
}

public enum GeoTagError: Error, LocalizedError, Equatable, Sendable {
    case invalidCoordinate, invalidAltitude, invalidAccuracy, invalidDate
    case invalidAutomaticSource, duplicateCorrectionID, invalidReset
    case automaticFixChanged, correctionHistoryChanged

    public var errorDescription: String? {
        switch self {
        case .invalidCoordinate: "Проверьте геометку: долгота должна быть от −180 до 180°, широта — от −90 до 90°, без пустых или неконечных значений."
        case .invalidAltitude: "Высота геометки должна быть конечным числом."
        case .invalidAccuracy: "Точность геометки должна быть конечным неотрицательным числом; неизвестную точность оставьте пустой."
        case .invalidDate: "У геометки указано недопустимое время наблюдения или изменения."
        case .invalidAutomaticSource: "Автоматическая геометка должна иметь источник устройства или исходного снимка."
        case .duplicateCorrectionID: "В истории геометки повторяется идентификатор изменения."
        case .invalidReset: "Возврат к автоматической геометке не должен содержать отдельную высоту или точность."
        case .automaticFixChanged: "Исходную автоматическую геометку нельзя заменить. Добавьте ручную корректировку: оригинал останется в истории."
        case .correctionHistoryChanged: "Сохранённую историю геометки нельзя удалить или переписать. Добавьте новое изменение или возврат к оригиналу."
        }
    }
}

public enum GeoTagPolicy {
    public static func validate(_ tag: GeoTag) throws {
        if let automatic = tag.automaticFix {
            guard automatic.source != .operatorEntered else { throw GeoTagError.invalidAutomaticSource }
            try validateFix(automatic)
        }
        var seen = Set<UUID>()
        for correction in tag.corrections {
            guard seen.insert(correction.id).inserted else { throw GeoTagError.duplicateCorrectionID }
            try validateDate(correction.changedAt)
            if let coordinate = correction.coordinate {
                try validateCoordinate(coordinate)
                try validateAltitude(correction.altitudeMeters)
                try validateAccuracy(correction.estimatedAccuracyMeters)
            } else if correction.altitudeMeters != nil || correction.estimatedAccuracyMeters != nil {
                throw GeoTagError.invalidReset
            }
        }
    }

    /// CLLocation reports an invalid horizontal accuracy as a negative number.
    /// Cached and future-dated observations are excluded; lack of GPS never becomes (0,0).
    public static func acceptDeviceFix(_ fix: GeoLocationFix, now: Date,
                                       maximumAge: TimeInterval = 20) -> Bool {
        guard fix.source == .deviceLocation, fix.horizontalAccuracyMeters != nil else { return false }
        return acceptableAutomatic(fix, now: now, maximumAge: maximumAge)
    }

    /// Select only fresh automatic observations, prefer known/lower uncertainty,
    /// then a newer timestamp. The caller freezes the chosen observation at capture save.
    public static func bestAutomatic(current: GeoLocationFix?, candidate: GeoLocationFix,
                                     now: Date, maximumAge: TimeInterval = 20) -> GeoLocationFix? {
        let validCurrent = current.flatMap { acceptableAutomatic($0, now: now, maximumAge: maximumAge) ? $0 : nil }
        guard acceptableAutomatic(candidate, now: now, maximumAge: maximumAge) else { return validCurrent }
        guard let validCurrent else { return candidate }
        let oldAccuracy = validCurrent.horizontalAccuracyMeters ?? .infinity
        let newAccuracy = candidate.horizontalAccuracyMeters ?? .infinity
        if newAccuracy < oldAccuracy { return candidate }
        if newAccuracy == oldAccuracy, candidate.observedAt > validCurrent.observedAt { return candidate }
        return validCurrent
    }

    /// Saving edits may add history, never replace an existing automatic observation
    /// or remove/change a previously committed correction.
    public static func validateTransition(from old: GeoTag?, to new: GeoTag?) throws {
        if let new { try validate(new) }
        guard let old else { return }
        if let original = old.automaticFix, new?.automaticFix != original {
            throw GeoTagError.automaticFixChanged
        }
        let newCorrections = new?.corrections ?? []
        guard newCorrections.count >= old.corrections.count,
              Array(newCorrections.prefix(old.corrections.count)) == old.corrections else {
            throw GeoTagError.correctionHistoryChanged
        }
    }

    private static func acceptableAutomatic(_ fix: GeoLocationFix, now: Date, maximumAge: TimeInterval) -> Bool {
        guard fix.source != .operatorEntered, maximumAge.isFinite, maximumAge >= 0,
              now.timeIntervalSinceReferenceDate.isFinite,
              fix.source != .deviceLocation || fix.horizontalAccuracyMeters != nil else { return false }
        do { try validateFix(fix) } catch { return false }
        let age = now.timeIntervalSince(fix.observedAt)
        return age.isFinite && age >= -5 && age <= maximumAge
    }

    private static func validateFix(_ fix: GeoLocationFix) throws {
        try validateCoordinate(fix.coordinate)
        try validateAltitude(fix.altitudeMeters)
        try validateAccuracy(fix.horizontalAccuracyMeters)
        try validateAccuracy(fix.verticalAccuracyMeters)
        try validateDate(fix.observedAt)
    }

    private static func validateCoordinate(_ coordinate: GeographicCoordinate) throws {
        guard coordinate.longitude.isFinite, coordinate.latitude.isFinite,
              (-180...180).contains(coordinate.longitude), (-90...90).contains(coordinate.latitude) else {
            throw GeoTagError.invalidCoordinate
        }
    }

    private static func validateAltitude(_ altitude: Double?) throws {
        if let altitude, !altitude.isFinite { throw GeoTagError.invalidAltitude }
    }

    private static func validateAccuracy(_ accuracy: Double?) throws {
        if let accuracy, !accuracy.isFinite || accuracy < 0 { throw GeoTagError.invalidAccuracy }
    }

    private static func validateDate(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw GeoTagError.invalidDate }
    }
}

public extension AtlasExporter {
    /// Export geographic observation points even when all scanned surfaces remain
    /// in independent local metric frames. This does not register mesh vertices.
    static func exportGeotags(_ snapshot: AtlasProjectSnapshot) throws -> ExportArtifact {
        guard snapshot.schemaVersion == 1 else { throw AtlasExportError.unsupportedSchema(snapshot.schemaVersion) }
        var features: [GeoTagPointFeature] = []
        var missing = 0
        for scan in snapshot.scans {
            guard scan.projectID == snapshot.project.id else { throw AtlasExportError.entityProjectMismatch }
            guard let tag = scan.geoTag else { missing += 1; continue }
            try GeoTagPolicy.validate(tag)
            guard let effective = tag.effectiveFix else { missing += 1; continue }
            features.append(GeoTagPointFeature(id: scan.id.uuidString,
                geometry: .init(coordinates: [effective.coordinate.longitude, effective.coordinate.latitude]),
                properties: .init(projectID: scan.projectID.uuidString, scanSource: scan.source.rawValue,
                    scanStatus: scan.status.rawValue, frameID: scan.frameID.uuidString, revision: scan.revision,
                    effectiveFix: effective, originalFix: tag.automaticFix, corrections: tag.corrections)))
        }
        var warnings = ["Геометки обозначают положение съёмок. Локальные 3D-модели и планы не преобразованы в WGS84."]
        if missing > 0 { warnings.append("Съёмки без геометки пропущены: \(missing).") }
        return ExportArtifact(fileName: "atlas-\(snapshot.project.id.uuidString.prefix(8).lowercased())-geotags.geojson",
            contentType: "application/geo+json",
            data: try AtlasJSON.encode(GeoTagPointCollection(features: features), pretty: true), warnings: warnings)
    }
}

private struct GeoTagPointCollection: Encodable {
    let type = "FeatureCollection"
    let features: [GeoTagPointFeature]
}
private struct GeoTagPointFeature: Encodable {
    let type = "Feature"
    let id: String
    let geometry: GeoTagPointGeometry
    let properties: GeoTagPointProperties
}
private struct GeoTagPointGeometry: Encodable {
    let type = "Point"
    let coordinates: [Double]
}
private struct GeoTagPointProperties: Encodable {
    let projectID: String
    let scanSource: String
    let scanStatus: String
    let frameID: String
    let revision: Int64
    let effectiveFix: GeoLocationFix
    let originalFix: GeoLocationFix?
    let corrections: [GeoTagCorrection]
}
