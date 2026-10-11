import Foundation

public enum CemeteryAttribute {
    public static let cemeteryID = "cemeteryID"
    public static let legacyParentCemeteryID = "parentCemeteryID"
    public static let persons = "grave.persons"
    public static let signs = "grave.signs"
    public static let condition = "grave.condition"
    public static let inscriptionDraft = "grave.inscriptionDraft"
    public static let photoIDs = "grave.photoIDs"
    public static let identityStatus = "grave.identityStatus"
    public static let burialType = "grave.type"
    public static let hasRoof = "grave.hasRoof"
    public static let warContext = "grave.warContext"
    public static let warContextSource = "grave.warContextSource"
    public static let complexID = "grave.complexID"
    public static let sitePhotoIDs = "survey.photoIDs"
    public static let status = "survey.status"
    public static let removedAt = "survey.removedAt"
}

/// Partial, uncertain and historical dates remain the operator's original text.
/// A transcription such as “18??” must never become an invented exact date.
public struct BurialPerson: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var fullName: String
    public var birthText: String
    public var deathText: String
    public var notes: String
    public init(id: UUID = UUID(), fullName: String, birthText: String = "", deathText: String = "", notes: String = "") {
        self.id = id; self.fullName = fullName; self.birthText = birthText; self.deathText = deathText; self.notes = notes
    }
}

public enum BurialVisibleSign: String, Codable, CaseIterable, Sendable {
    case mound, cross, monument, fence, slab, noVisibleMarker, other
}

/// Confirmation that a burial exists does not establish the person's identity.
public enum BurialIdentityStatus: String, Codable, CaseIterable, Sendable { case unknown, partial, identified }

public enum BurialType: String, Codable, CaseIterable, Sendable {
    case unknown, individual, family, mass, mausoleum, crypt, memorial
}

public enum BurialMetadataError: Error, LocalizedError, Equatable, Sendable {
    case malformedAttribute(String)
    case conflictingCemeteryIDs
    case oversizedAttribute(String)
    case duplicatePersonID
    case duplicatePhotoID
    case incompatibleFeature

    public var errorDescription: String? {
        switch self {
        case let .malformedAttribute(key): "Карточка содержит повреждённое поле «\(key)». Исходные данные сохранены; проверьте их перед изменением."
        case .conflictingCemeteryIDs: "В карточке указаны два разных родительских кладбища. Сначала исправьте связь."
        case let .oversizedAttribute(key): "Поле «\(key)» слишком длинное для карточки. Сократите текст или перенесите подробности в заметки."
        case .duplicatePersonID: "У людей в карточке должны быть разные идентификаторы."
        case .duplicatePhotoID: "Одна фотография указана в карточке несколько раз."
        case .incompatibleFeature: "Данные захоронения можно сохранить только в карточке захоронения."
        }
    }
}

/// The existing attributes schema remains readable by older Atlas archives.
/// Updating a card touches only these typed fields; independent provenance stays intact.
public struct BurialMetadata: Codable, Hashable, Sendable {
    public var cemeteryID: UUID?
    public var people: [BurialPerson]
    public var visibleSigns: [BurialVisibleSign]
    public var condition: String
    public var inscriptionDraft: String
    public var photoIDs: [UUID]
    public var identityStatus: BurialIdentityStatus
    public var burialType: BurialType
    public var hasRoof: Bool?
    /// Operator text and evidence source, not an automatic legal or historical classification.
    public var warContext: String
    public var warContextSource: String
    public var complexID: UUID?

    public init(cemeteryID: UUID? = nil, people: [BurialPerson] = [], visibleSigns: [BurialVisibleSign] = [],
                condition: String = "", inscriptionDraft: String = "", photoIDs: [UUID] = [], identityStatus: BurialIdentityStatus = .unknown,
                burialType: BurialType = .unknown, hasRoof: Bool? = nil, warContext: String = "", warContextSource: String = "", complexID: UUID? = nil) {
        self.cemeteryID = cemeteryID; self.people = people; self.visibleSigns = visibleSigns
        self.condition = condition; self.inscriptionDraft = inscriptionDraft; self.photoIDs = photoIDs
        self.identityStatus = identityStatus
        self.burialType = burialType; self.hasRoof = hasRoof; self.warContext = warContext
        self.warContextSource = warContextSource; self.complexID = complexID
    }

    public init(attributes: [String: String]) throws {
        let current = try Self.readUUID(attributes[CemeteryAttribute.cemeteryID], key: CemeteryAttribute.cemeteryID)
        let legacy = try Self.readUUID(attributes[CemeteryAttribute.legacyParentCemeteryID], key: CemeteryAttribute.legacyParentCemeteryID)
        if let current, let legacy, current != legacy { throw BurialMetadataError.conflictingCemeteryIDs }
        cemeteryID = current ?? legacy
        people = try Self.decode([BurialPerson].self, from: attributes, key: CemeteryAttribute.persons) ?? []
        visibleSigns = try Self.decode([BurialVisibleSign].self, from: attributes, key: CemeteryAttribute.signs) ?? []
        photoIDs = try Self.decode([UUID].self, from: attributes, key: CemeteryAttribute.photoIDs) ?? []
        condition = attributes[CemeteryAttribute.condition] ?? ""
        inscriptionDraft = attributes[CemeteryAttribute.inscriptionDraft] ?? ""
        if let raw = attributes[CemeteryAttribute.identityStatus] {
            guard let status = BurialIdentityStatus(rawValue: raw) else { throw BurialMetadataError.malformedAttribute(CemeteryAttribute.identityStatus) }
            identityStatus = status
        } else { identityStatus = .unknown }
        if let raw = attributes[CemeteryAttribute.burialType] {
            guard let type = BurialType(rawValue: raw) else { throw BurialMetadataError.malformedAttribute(CemeteryAttribute.burialType) }
            burialType = type
        } else { burialType = .unknown }
        if let raw = attributes[CemeteryAttribute.hasRoof] {
            guard raw == "true" || raw == "false" else { throw BurialMetadataError.malformedAttribute(CemeteryAttribute.hasRoof) }
            hasRoof = raw == "true"
        } else { hasRoof = nil }
        warContext = attributes[CemeteryAttribute.warContext] ?? ""
        warContextSource = attributes[CemeteryAttribute.warContextSource] ?? ""
        complexID = try Self.readUUID(attributes[CemeteryAttribute.complexID], key: CemeteryAttribute.complexID)
        try validate()
    }

    public func validate() throws {
        guard Set(people.map(\.id)).count == people.count else { throw BurialMetadataError.duplicatePersonID }
        guard Set(photoIDs).count == photoIDs.count else { throw BurialMetadataError.duplicatePhotoID }
        guard people.count <= 8 else { throw BurialMetadataError.oversizedAttribute(CemeteryAttribute.persons) }
        guard photoIDs.count <= 48 else { throw BurialMetadataError.oversizedAttribute(CemeteryAttribute.photoIDs) }
        for person in people {
            guard person.fullName.count <= 512, person.birthText.count <= 120, person.deathText.count <= 120,
                  person.notes.count <= 512 else { throw BurialMetadataError.oversizedAttribute(CemeteryAttribute.persons) }
        }
        _ = try Self.encoded(people, key: CemeteryAttribute.persons)
        _ = try Self.encoded(photoIDs, key: CemeteryAttribute.photoIDs)
        for (key, value) in [(CemeteryAttribute.condition, condition), (CemeteryAttribute.inscriptionDraft, inscriptionDraft),
                             (CemeteryAttribute.warContext, warContext), (CemeteryAttribute.warContextSource, warContextSource)] {
            try Self.validateText(value, key: key)
        }
    }

    public func applying(to feature: AtlasFeature) throws -> AtlasFeature {
        guard feature.category == .grave else { throw BurialMetadataError.incompatibleFeature }
        try validate()
        var result = feature
        result.attributes[CemeteryAttribute.cemeteryID] = cemeteryID?.uuidString
        result.attributes.removeValue(forKey: CemeteryAttribute.legacyParentCemeteryID)
        result.attributes[CemeteryAttribute.persons] = try Self.encoded(people, key: CemeteryAttribute.persons)
        let signs = Set(visibleSigns.map(\.rawValue)).sorted()
        result.attributes[CemeteryAttribute.signs] = try Self.encoded(signs, key: CemeteryAttribute.signs)
        result.attributes[CemeteryAttribute.condition] = condition
        result.attributes[CemeteryAttribute.inscriptionDraft] = inscriptionDraft
        result.attributes[CemeteryAttribute.photoIDs] = try Self.encoded(photoIDs, key: CemeteryAttribute.photoIDs)
        result.attributes[CemeteryAttribute.identityStatus] = identityStatus.rawValue
        result.attributes[CemeteryAttribute.burialType] = burialType.rawValue
        result.attributes[CemeteryAttribute.hasRoof] = hasRoof.map { $0 ? "true" : "false" }
        result.attributes[CemeteryAttribute.warContext] = warContext
        result.attributes[CemeteryAttribute.warContextSource] = warContextSource
        result.attributes[CemeteryAttribute.complexID] = complexID?.uuidString
        return result
    }

    private static func readUUID(_ value: String?, key: String) throws -> UUID? {
        guard let value else { return nil }
        guard let uuid = UUID(uuidString: value) else { throw BurialMetadataError.malformedAttribute(key) }
        return uuid
    }

    private static func validateText(_ value: String, key: String) throws {
        // Match the server's UTF-16 character limit; cap bytes before allocating JSON.
        guard value.utf8.count <= 8192, value.utf16.count <= 2048 else { throw BurialMetadataError.oversizedAttribute(key) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from attributes: [String: String], key: String) throws -> T? {
        guard let value = attributes[key] else { return nil }
        try validateText(value, key: key)
        guard let data = value.data(using: .utf8), let decoded = try? AtlasJSON.decode(type, from: data) else {
            throw BurialMetadataError.malformedAttribute(key)
        }
        return decoded
    }

    private static func encoded<T: Encodable>(_ value: T, key: String) throws -> String {
        let string = String(decoding: try AtlasJSON.encode(value), as: UTF8.self)
        try validateText(string, key: key)
        return string
    }
}

public enum SurveyFeatureStatus: String, Codable, CaseIterable, Sendable { case candidate, confirmed, rejected }

/// Operator decisions are reversible and do not rewrite geometry, source photos,
/// positional uncertainty, or the feature's stable identity and stored revision.
public enum SurveyFeatureLifecycle {
    public static func status(of feature: AtlasFeature) -> SurveyFeatureStatus {
        if let raw = feature.attributes[CemeteryAttribute.status], let status = SurveyFeatureStatus(rawValue: raw) { return status }
        // Older archives may mark geometry reviewed without any observation
        // confirming burial existence. Preserve explicit decisions above, but
        // never derive a burial claim from a geometry review flag.
        if feature.category == .grave { return .candidate }
        return feature.reviewStatus == .reviewed ? .confirmed : .candidate
    }
    public static func isSoftRemoved(_ feature: AtlasFeature) -> Bool { feature.attributes[CemeteryAttribute.removedAt] != nil }
    public static func isActive(_ feature: AtlasFeature) -> Bool { !isSoftRemoved(feature) && status(of: feature) != .rejected }

    public static func confirm(_ feature: AtlasFeature, at date: Date = Date(), basis: String? = nil, operatorID: UUID? = nil) -> AtlasFeature {
        var result = feature
        result.attributes[CemeteryAttribute.status] = SurveyFeatureStatus.confirmed.rawValue
        result.attributes.removeValue(forKey: CemeteryAttribute.removedAt)
        result.attributes.removeValue(forKey: "survey.previousStatus")
        result.attributes["survey.reviewedAt"] = timestamp(date)
        result.attributes["grave.confirmedAt"] = timestamp(date)
        if let basis { result.attributes["grave.confirmationBasis"] = basis }
        if let operatorID { result.attributes["grave.confirmedBy"] = operatorID.uuidString }
        result.reviewStatus = .reviewed
        return result
    }
    public static func reject(_ feature: AtlasFeature, at date: Date = Date()) -> AtlasFeature {
        var result = feature
        if status(of: feature) != .rejected { result.attributes["survey.previousStatus"] = status(of: feature).rawValue }
        result.attributes[CemeteryAttribute.status] = SurveyFeatureStatus.rejected.rawValue
        result.attributes["survey.reviewedAt"] = timestamp(date)
        result.reviewStatus = .needsReview
        return result
    }
    public static func remove(_ feature: AtlasFeature, at date: Date = Date()) -> AtlasFeature {
        var result = feature
        result.attributes[CemeteryAttribute.removedAt] = timestamp(date)
        return result
    }
    public static func restore(_ feature: AtlasFeature, at date: Date = Date()) -> AtlasFeature {
        var result = feature
        result.attributes.removeValue(forKey: CemeteryAttribute.removedAt)
        if status(of: feature) == .rejected {
            let previous = feature.attributes["survey.previousStatus"].flatMap(SurveyFeatureStatus.init(rawValue:))
            let restored: SurveyFeatureStatus = previous == .confirmed ? .confirmed : .candidate
            result.attributes[CemeteryAttribute.status] = restored.rawValue
            result.reviewStatus = restored == .confirmed ? .reviewed : .needsReview
        }
        result.attributes.removeValue(forKey: "survey.previousStatus")
        result.attributes["survey.restoredAt"] = timestamp(date)
        return result
    }
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
