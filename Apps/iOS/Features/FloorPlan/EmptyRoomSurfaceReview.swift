import Foundation

enum EmptyRoomReviewRole: String, Codable, CaseIterable, Sendable {
    case wall, floor, roomDoor, window, openPassage, cabinetDoor, unknown
    var title: String {
        switch self {
        case .wall: "Стена"; case .floor: "Пол"; case .roomDoor: "Дверь помещения"
        case .window: "Окно"; case .openPassage: "Открытый проход"
        case .cabinetDoor: "Дверца шкафа · вручную"; case .unknown: "Не определено"
        }
    }
    var symbol: String {
        switch self {
        case .wall: "S"; case .floor: "F"; case .roomDoor: "D"
        case .window: "W"; case .openPassage: "P"; case .cabinetDoor: "K"; case .unknown: "?"
        }
    }
    static func reported(_ kind: EmptyRoomSurfaceKind) -> Self {
        switch kind { case .wall: .wall; case .floor: .floor; case .door: .roomDoor; case .window: .window; case .opening: .openPassage }
    }
}

enum EmptyRoomDimensionMeaning: String, Codable, CaseIterable, Sendable {
    case reportedBounds, clearOpening, doorLeaf, outerFrame, manualControl
    var title: String {
        switch self {
        case .reportedBounds: "Габарит RoomPlan · не проверен"
        case .clearOpening: "Чистый проём · контрольный обмер"
        case .doorLeaf: "Полотно / дверца · контрольный обмер"
        case .outerFrame: "Наружная рама · контрольный обмер"
        case .manualControl: "Ручной контрольный размер"
        }
    }
}

/// A frozen link to a real saved measurement. Different AR frames stay different;
/// these scalar controls never relocate a RoomPlan surface or alter its raw mesh.
struct EmptyRoomControlObservation: Codable, Equatable, Sendable, Identifiable {
    var measurementID: UUID
    var measurementRevision: Int64
    var label: String
    var source: String
    var kind: String
    var role: String
    var definition: String?
    var position: String
    var positionNote: String
    var profileID: UUID?
    var originalTargetID: UUID?
    var originalTarget: String?
    var frameID: UUID?
    var start: EmptyRoomPoint?
    var end: EmptyRoomPoint?
    var originalMeters: Double
    var effectiveMeters: Double
    var observedAt: Date
    var rawMeasurementJSON: String?
    var id: UUID { measurementID }
}

struct EmptyRoomReviewEvent: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var targetID: UUID
    var sourceSurfaceID: UUID?
    var label: String
    var role: EmptyRoomReviewRole
    var semanticVerified: Bool
    var dimensionMeaning: EmptyRoomDimensionMeaning
    var openingCoverageComplete = false
    var openingGeometryVerified: Bool?
    var note: String
    var observation: EmptyRoomControlObservation?
}

/// Append-only operator decisions. Source fields bind every event to one immutable
/// RoomPlan capture; corrections leave all earlier decisions and measurements intact.
struct EmptyRoomSurfaceReview: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var projectID: UUID
    var captureID: UUID
    var sourceRoomID: UUID
    var frameID: UUID
    var sourceRoomJSONSHA256: String
    var revision: Int64 = 0
    var updatedAt: Date
    var events: [EmptyRoomReviewEvent] = []

    init(source: EmptyRoomDocument) {
        projectID = source.projectID; captureID = source.captureID
        sourceRoomID = source.sourceRoomID; frameID = source.frameID
        sourceRoomJSONSHA256 = source.sourceRoomJSONSHA256
        updatedAt = source.capturedAt
    }
    func latest(for targetID: UUID) -> EmptyRoomReviewEvent? { events.last { $0.targetID == targetID } }
    var manualTargetIDs: [UUID] {
        var seen = Set<UUID>()
        return events.filter { $0.sourceSurfaceID == nil && seen.insert($0.targetID).inserted }.map(\.targetID)
    }
    func controls(for targetID: UUID) -> [EmptyRoomControlObservation] {
        var latest: [UUID: EmptyRoomControlObservation] = [:]
        for event in events where event.targetID == targetID {
            if let observation = event.observation { latest[observation.measurementID] = observation }
        }
        return latest.values.sorted { ($0.observedAt, $0.measurementID.uuidString) < ($1.observedAt, $1.measurementID.uuidString) }
    }
}

enum EmptyRoomReviewError: LocalizedError {
    case invalid(String), conflict
    var errorDescription: String? {
        switch self {
        case .invalid(let text): text
        case .conflict: "Журнал уже изменён. Обновите список и повторите сохранение; прежние записи сохранены."
        }
    }
}

enum EmptyRoomSurfaceReviewPolicy {
    static let fileName = "surface-review.json"
    static let maximumFileBytes = 4 * 1_024 * 1_024

    static func decode(_ data: Data, source: EmptyRoomDocument) throws -> EmptyRoomSurfaceReview {
        guard data.count <= maximumFileBytes else { throw EmptyRoomReviewError.invalid("Журнал проверки превышает 4 МБ. Исходный файл сохранён.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let review = try decoder.decode(EmptyRoomSurfaceReview.self, from: data)
        try validate(review, source: source)
        return review
    }

    static func validate(_ review: EmptyRoomSurfaceReview, source: EmptyRoomDocument) throws {
        guard source.schemaVersion == 1, Set(source.surfaces.map(\.id)).count == source.surfaces.count,
              source.surfaces.allSatisfy({ $0.transform.isValid && $0.polygonCorners.allSatisfy(\.isFinite) }),
              review.schemaVersion == 1, review.projectID == source.projectID,
              review.captureID == source.captureID, review.sourceRoomID == source.sourceRoomID,
              review.frameID == source.frameID, review.sourceRoomJSONSHA256 == source.sourceRoomJSONSHA256,
              review.sourceRoomJSONSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              review.revision == Int64(review.events.count), review.events.count <= 10_000,
              review.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              Set(review.events.map(\.id)).count == review.events.count else {
            throw EmptyRoomReviewError.invalid("Журнал относится к другому исходнику, проекту или системе координат либо имеет неверную версию. Исходный файл сохранён.")
        }
        let surfaces = Dictionary(uniqueKeysWithValues: source.surfaces.map { ($0.id, $0) })
        var origins: [UUID: UUID] = [:]
        var manualTargets = Set<UUID>()
        var observations: [UUID: EmptyRoomControlObservation] = [:]
        var previousDate: Date?
        for event in review.events {
            guard event.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  validText(event.label, maximum: 200, required: true),
                  validText(event.note, maximum: 2_000, required: event.semanticVerified),
                  !event.semanticVerified || event.role != .unknown else {
                throw EmptyRoomReviewError.invalid("Укажите название и причину проверки; неверный тип или дата решения.")
            }
            if let previousDate, event.createdAt < previousDate { throw EmptyRoomReviewError.invalid("История решений имеет неверный порядок дат.") }
            previousDate = event.createdAt
            guard event.dimensionMeaning != .clearOpening || [.roomDoor, .window, .openPassage].contains(event.role),
                  event.dimensionMeaning != .doorLeaf || [.roomDoor, .cabinetDoor].contains(event.role),
                  event.dimensionMeaning != .outerFrame || [.roomDoor, .window].contains(event.role) else {
                throw EmptyRoomReviewError.invalid("Смысл размера не соответствует типу объекта: проём, полотно и рама измеряются отдельно.")
            }
            if let sourceID = event.sourceSurfaceID {
                guard sourceID == event.targetID, let surface = surfaces[sourceID] else {
                    throw EmptyRoomReviewError.invalid("Поверхность журнала отсутствует в исходном RoomPlan.")
                }
                guard !event.openingCoverageComplete || (surface.kind == .wall && event.role == .wall && event.semanticVerified) else {
                    throw EmptyRoomReviewError.invalid("Полноту обследования проёмов можно подтвердить только для исходной стены.")
                }
                guard event.openingGeometryVerified != true || ([.door, .window, .opening].contains(surface.kind)
                    && [.roomDoor, .window, .openPassage].contains(event.role) && event.semanticVerified && event.dimensionMeaning == .clearOpening) else {
                    throw EmptyRoomReviewError.invalid("Проверку контура проёма нельзя заменить проверкой типа или размером дверного полотна.")
                }
                if manualTargets.contains(event.targetID) { throw EmptyRoomReviewError.invalid("Ручной объект нельзя заменить исходной поверхностью.") }
                if let existing = origins[event.targetID], existing != sourceID {
                    throw EmptyRoomReviewError.invalid("Нельзя изменить исходную поверхность объекта.")
                }
                origins[event.targetID] = sourceID
            } else {
                guard surfaces[event.targetID] == nil, origins[event.targetID] == nil, !event.openingCoverageComplete, event.openingGeometryVerified != true,
                      [.roomDoor, .window, .openPassage, .cabinetDoor, .unknown].contains(event.role) else {
                    throw EmptyRoomReviewError.invalid("Ручное наблюдение не должно подменять исходную поверхность или объявлять обследованную стену.")
                }
                manualTargets.insert(event.targetID)
            }
            if let observation = event.observation {
                try validate(observation)
                if let prior = observations[observation.measurementID] {
                    guard observation.measurementRevision > prior.measurementRevision,
                          observation.originalMeters == prior.originalMeters,
                          observation.frameID == prior.frameID, observation.start == prior.start, observation.end == prior.end,
                          observation.kind == prior.kind, observation.source == prior.source,
                          observation.role == prior.role, observation.profileID == prior.profileID,
                          observation.originalTargetID == prior.originalTargetID,
                          (observation.originalTarget ?? "unspecified") == (prior.originalTarget ?? "unspecified"),
                          (observation.definition ?? "unspecified") == (prior.definition ?? "unspecified"),
                          observation.position == prior.position, observation.positionNote == prior.positionNote,
                          observation.observedAt == prior.observedAt else {
                        throw EmptyRoomReviewError.invalid("Повторный обмер должен сохранять исходное наблюдение и ссылаться на новую ревизию; прошлые версии остаются в журнале.")
                    }
                }
                observations[observation.measurementID] = observation
            }
        }
        if let previousDate, review.updatedAt < previousDate { throw EmptyRoomReviewError.invalid("Дата журнала предшествует последнему решению.") }
    }

    private static func validText(_ value: String, maximum: Int, required: Bool) -> Bool {
        value.count <= maximum && (!required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.subtracting(.newlines).contains($0) }
    }
    private static func validate(_ observation: EmptyRoomControlObservation) throws {
        guard observation.measurementRevision >= 0,
              validText(observation.label, maximum: 200, required: true),
              validText(observation.positionNote, maximum: 500, required: observation.position == "custom"),
              ["arRaycast", "manualReference", "laserReference"].contains(observation.source),
              ["distance", "horizontalDistance", "verticalDistance"].contains(observation.kind),
              ["distance", "length", "width", "height", "surfaceHeight", "thickness"].contains(observation.role),
              ["unspecified", "reportedBounds", "clearOpening", "doorLeaf", "outerFrame", "structuralDimension"].contains(observation.definition ?? "unspecified"),
              ["unspecified", "room", "wall", "floor", "ceiling", "door", "window", "openPassage", "cabinetDoor"].contains(observation.originalTarget ?? "unspecified"),
              ["unspecified", "lower", "middle", "upper", "left", "center", "right", "custom"].contains(observation.position),
              observation.originalMeters.isFinite, observation.effectiveMeters.isFinite,
              observation.originalMeters > 0, observation.originalMeters <= 4_000_000,
              observation.effectiveMeters > 0, observation.effectiveMeters <= 4_000_000,
              observation.observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw EmptyRoomReviewError.invalid("Контрольный обмер содержит неверное значение, позицию или источник.")
        }
        if observation.source == "arRaycast" {
            guard observation.frameID != nil, let start = observation.start, let end = observation.end,
                  start.isFinite, end.isFinite,
                  observation.role != "height" || observation.kind == "verticalDistance",
                  observation.role != "surfaceHeight" || observation.kind == "distance" else {
                throw EmptyRoomReviewError.invalid("AR-обмер должен сохранять исходные точки и систему; высота измеряется по вертикали.")
            }
            let measured: Double
            switch observation.kind {
            case "verticalDistance": measured = abs(end.y - start.y)
            case "horizontalDistance": measured = hypot(end.x - start.x, end.z - start.z)
            default: measured = start.distance(to: end)
            }
            guard abs(measured - observation.originalMeters) <= max(0.00001, measured * 0.00000001) else {
                throw EmptyRoomReviewError.invalid("Исходное значение AR-обмера не соответствует сохранённым точкам.")
            }
        } else if observation.frameID != nil || observation.start != nil || observation.end != nil {
            throw EmptyRoomReviewError.invalid("Ручной контрольный размер не содержит координат AR.")
        }
        if let json = observation.rawMeasurementJSON {
            guard json.utf8.count <= 256 * 1_024, let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String, UUID(uuidString: id) == observation.measurementID,
                  let revision = object["revision"] as? Int64, revision == observation.measurementRevision else {
                throw EmptyRoomReviewError.invalid("Полный исходный контрольный обмер не соответствует ссылке журнала.")
            }
        }
    }
}

actor EmptyRoomSurfaceReviewStore {
    nonisolated let fileURL: URL
    private let source: EmptyRoomDocument
    private static let documentLock = NSRecursiveLock()

    init(directory: URL, source: EmptyRoomDocument) {
        fileURL = directory.appendingPathComponent(EmptyRoomSurfaceReviewPolicy.fileName)
        self.source = source
    }

    func load() throws -> EmptyRoomSurfaceReview {
        Self.documentLock.lock(); defer { Self.documentLock.unlock() }
        try validateLocation(requireFile: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return EmptyRoomSurfaceReview(source: source) }
        try validateLocation(requireFile: true)
        return try EmptyRoomSurfaceReviewPolicy.decode(Data(contentsOf: fileURL), source: source)
    }

    func append(_ event: EmptyRoomReviewEvent, expectedRevision: Int64) throws -> EmptyRoomSurfaceReview {
        Self.documentLock.lock(); defer { Self.documentLock.unlock() }
        var review = try load()
        guard review.revision == expectedRevision else { throw EmptyRoomReviewError.conflict }
        let (revision, overflow) = review.revision.addingReportingOverflow(1)
        guard !overflow else { throw EmptyRoomReviewError.invalid("Счётчик версий журнала исчерпан.") }
        review.events.append(event); review.revision = revision; review.updatedAt = event.createdAt
        try EmptyRoomSurfaceReviewPolicy.validate(review, source: source)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(review)
        guard data.count <= EmptyRoomSurfaceReviewPolicy.maximumFileBytes else { throw EmptyRoomReviewError.invalid("Журнал достиг 4 МБ. Изменение не сохранено.") }
        // The capture writer must register/create the sidecar first, including
        // legacy derivatives. This store never silently creates an unlisted asset.
        try validateLocation(requireFile: true)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
        return review
    }

    private func validateLocation(requireFile: Bool) throws {
        let folder = fileURL.deletingLastPathComponent().standardizedFileURL
        let collection = folder.deletingLastPathComponent()
        let capture = collection.deletingLastPathComponent()
        guard fileURL.isFileURL, fileURL.lastPathComponent == EmptyRoomSurfaceReviewPolicy.fileName,
              UUID(uuidString: folder.lastPathComponent) != nil, collection.lastPathComponent == "empty-room",
              capture.lastPathComponent == "room-\(source.captureID.uuidString)" else {
            throw EmptyRoomReviewError.invalid("Журнал должен находиться в своём управляемом каталоге RoomPlan.")
        }
        let root = capture.resolvingSymlinksInPath().path
        for directory in [capture, collection, folder] {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let canonical = directory.resolvingSymlinksInPath().path
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  canonical == root || canonical.hasPrefix(root + "/") else {
                throw EmptyRoomReviewError.invalid("Каталог журнала не является обычным управляемым каталогом.")
            }
        }
        if requireFile || FileManager.default.fileExists(atPath: fileURL.path) {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes > 0, bytes <= EmptyRoomSurfaceReviewPolicy.maximumFileBytes,
                  fileURL.resolvingSymlinksInPath().deletingLastPathComponent().path == folder.resolvingSymlinksInPath().path else {
                throw EmptyRoomReviewError.invalid("Журнал не является обычным непустым файлом до 4 МБ. Исходник не изменён.")
            }
        }
    }
}
