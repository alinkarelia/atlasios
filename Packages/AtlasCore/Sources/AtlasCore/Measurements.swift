import Foundation

/// AR world coordinates in metres. Y is vertical; X/Z form the ground plane.
/// A point only has meaning together with its AR session's frame ID.
public struct MetricPoint3D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}

public enum MeasurementKind: String, Codable, CaseIterable, Sendable {
    case distance, horizontalDistance, verticalDistance
}

/// Describes what a scalar means; `kind` independently records how it was calculated.
/// A length or width can therefore be a direct 3D distance or a horizontal projection.
public enum MeasurementRole: String, Codable, CaseIterable, Sendable {
    case distance, length, width, height, surfaceHeight, thickness

    public var symbol: String {
        switch self {
        case .distance: "D"
        case .length: "L"
        case .width: "W"
        case .height: "H"
        case .surfaceHeight: "Hₛ"
        case .thickness: "T"
        }
    }
}

/// A cabinet door is an operator-identified target, never inferred from a storage box.
public enum MeasurementTarget: String, Codable, CaseIterable, Sendable {
    case unspecified, room, wall, floor, ceiling, door, window, openPassage, cabinetDoor
}

public enum MeasurementSamplePosition: String, Codable, CaseIterable, Sendable {
    case unspecified, lower, middle, upper, left, center, right, custom
}

/// Width/height alone cannot say whether points describe a clear passage, leaf,
/// outer frame, or a detector's bounding extent. Unknown remains explicit.
public enum MeasurementDefinition: String, Codable, CaseIterable, Sendable {
    case unspecified, reportedBounds, clearOpening, doorLeaf, outerFrame, structuralDimension
}

/// Context belongs to the original observation. Repeated observations retain their own
/// points, dates and correction histories; a profile does not replace them with an average.
public struct MeasurementContext: Codable, Hashable, Sendable {
    public var role: MeasurementRole
    public var target: MeasurementTarget
    public var targetID: UUID?
    public var profileID: UUID?
    public var position: MeasurementSamplePosition
    public var positionNote: String
    public var definition: MeasurementDefinition?
    public var effectiveDefinition: MeasurementDefinition { definition ?? .unspecified }

    public init(role: MeasurementRole = .distance, target: MeasurementTarget = .unspecified,
                targetID: UUID? = nil, profileID: UUID? = nil,
                position: MeasurementSamplePosition = .unspecified, positionNote: String = "",
                definition: MeasurementDefinition? = nil) {
        self.role = role; self.target = target; self.targetID = targetID; self.profileID = profileID
        self.position = position; self.positionNote = positionNote
        self.definition = definition
    }
}

public enum MeasurementCoordinateBasis: String, Codable, Sendable {
    /// Gravity-aligned ARKit coordinates: Y up, X/Z horizontal, metres.
    case arKitYUp
}

public enum MeasurementSource: String, Codable, CaseIterable, Sendable {
    case arRaycast, manualReference
    /// A laser instrument reading entered by the operator; no device connection is implied.
    case laserReference
}

/// ARKit's tracking state is diagnostic context, not a numerical accuracy guarantee.
public enum MeasurementTrackingQuality: String, Codable, Sendable {
    case normal, limited, unavailable
}

public enum MeasurementSurfaceEvidence: String, Codable, Sendable {
    case existingPlaneGeometry, estimatedPlane
}

public enum MeasurementCorrectionSource: String, Codable, CaseIterable, Sendable {
    case operatorEntered, manualReference, laserReference
}

/// Nil metres restore the unchanged original observation. Old edits remain visible.
public struct MeasurementCorrection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var meters: Double?
    public var source: MeasurementCorrectionSource
    public var note: String
    public var changedAt: Date
    public init(id: UUID = UUID(), meters: Double?, source: MeasurementCorrectionSource = .operatorEntered,
                note: String, changedAt: Date = Date()) {
        self.id = id; self.meters = meters; self.source = source; self.note = note; self.changedAt = changedAt
    }
}

public struct MeasurementRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var label: String
    public var kind: MeasurementKind
    public var source: MeasurementSource
    public var originalMeters: Double
    public var frameID: UUID?
    public var start: MetricPoint3D?
    public var end: MetricPoint3D?
    public var trackingQuality: MeasurementTrackingQuality?
    /// Empty means unavailable; otherwise start/end each retain their raycast source.
    public var surfaceEvidence: [MeasurementSurfaceEvidence]
    public var createdAt: Date
    public var corrections: [MeasurementCorrection]
    public var revision: Int64
    /// Nil preserves the semantics and decoding of older records.
    public var context: MeasurementContext?

    public init(id: UUID = UUID(), projectID: UUID, label: String = "Обмер", kind: MeasurementKind = .distance,
                source: MeasurementSource, originalMeters: Double, frameID: UUID? = nil,
                start: MetricPoint3D? = nil, end: MetricPoint3D? = nil,
                trackingQuality: MeasurementTrackingQuality? = nil, createdAt: Date = Date(),
                corrections: [MeasurementCorrection] = [], revision: Int64 = 0,
                surfaceEvidence: [MeasurementSurfaceEvidence] = [], context: MeasurementContext? = nil) {
        self.id = id; self.projectID = projectID; self.label = label; self.kind = kind; self.source = source
        self.originalMeters = originalMeters; self.frameID = frameID; self.start = start; self.end = end
        self.trackingQuality = trackingQuality; self.createdAt = createdAt
        self.surfaceEvidence = surfaceEvidence
        self.corrections = corrections; self.revision = revision
        self.context = context
    }

    public var effectiveMeters: Double { corrections.last?.meters ?? originalMeters }
    public var hasManualCorrection: Bool { corrections.last?.meters != nil }
    public var coordinateBasis: MeasurementCoordinateBasis? { source == .arRaycast ? .arKitYUp : nil }
    public var notation: String { (context?.role ?? (kind == .verticalDistance ? .height : .distance)).symbol }

    /// Freeze the observed raycast points and tracking context before saving.
    public static func arRaycast(projectID: UUID, label: String = "Обмер", kind: MeasurementKind = .distance,
                                 frameID: UUID, start: MetricPoint3D, end: MetricPoint3D,
                                 trackingQuality: MeasurementTrackingQuality,
                                 createdAt: Date = Date(),
                                 surfaceEvidence: [MeasurementSurfaceEvidence] = [],
                                 context: MeasurementContext? = nil) throws -> MeasurementRecord {
        let record = MeasurementRecord(projectID: projectID, label: label, kind: kind, source: .arRaycast,
            originalMeters: try MeasurementGeometry.value(kind: kind, from: start, to: end),
            frameID: frameID, start: start, end: end, trackingQuality: trackingQuality, createdAt: createdAt,
            surfaceEvidence: surfaceEvidence, context: context)
        try MeasurementPolicy.validate(record)
        return record
    }
}

/// A gravity-based inclinometer sample. Degrees are never stored as metre distances.
public struct LevelReading: Codable, Hashable, Sendable {
    public var pitchDegrees: Double
    public var rollDegrees: Double
    public var observedAt: Date
    public init(pitchDegrees: Double, rollDegrees: Double, observedAt: Date = Date()) {
        self.pitchDegrees = pitchDegrees; self.rollDegrees = rollDegrees; self.observedAt = observedAt
    }
    public func validate() throws {
        guard pitchDegrees.isFinite, rollDegrees.isFinite,
              (-180...180).contains(pitchDegrees), (-180...180).contains(rollDegrees) else {
            throw MeasurementError.invalidOrientation
        }
        guard observedAt.timeIntervalSinceReferenceDate.isFinite else { throw MeasurementError.invalidDate }
    }
}

public enum MeasurementError: Error, LocalizedError, Equatable, Sendable {
    case invalidPoint, invalidDistance, invalidLabel, invalidDate, invalidOrientation
    case invalidARObservation, inconsistentOriginalDistance, unexpectedARMetadata
    case invalidCorrectionNote, duplicateCorrectionID, originalChanged, historyChanged
    case invalidReference, invalidRevision, revisionOverflow
    case invalidContext, incompatibleHeightProjection, incompatibleSurfaceHeightProjection
    case incompatibleProfile, duplicateProfileObservation
    case revisionConflict(entityID: UUID, expected: Int64, actual: Int64)
    case unsupportedSchema(Int), invalidStoredData, storageLimitExceeded, lockingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPoint: "Координаты обмера должны быть конечными числами в локальной системе съёмки."
        case .invalidDistance: "Размер должен быть конечным неотрицательным числом в метрах."
        case .invalidLabel: "Введите название обмера длиной не более 200 символов."
        case .invalidDate: "У обмера указано недопустимое время."
        case .invalidOrientation: "Уровень должен содержать конечные углы от −180 до 180°."
        case .invalidARObservation: "У AR-обмера отсутствуют исходные точки, система координат или состояние отслеживания."
        case .inconsistentOriginalDistance: "Исходный размер не совпадает с сохранёнными точками AR."
        case .unexpectedARMetadata: "Ручной контрольный размер не должен содержать точки или состояние AR-съёмки."
        case .invalidCorrectionNote: "Укажите причину изменения размера длиной не более 2000 символов."
        case .duplicateCorrectionID: "В истории обмера повторяется идентификатор изменения."
        case .originalChanged: "Исходный обмер нельзя заменить. Добавьте ручную корректировку с причиной."
        case .historyChanged: "Сохранённую историю обмера нельзя удалить или переписать. Добавьте новое изменение."
        case .invalidReference: "Контрольный размер должен быть конечным положительным числом в метрах."
        case .invalidRevision: "У нового обмера указана недопустимая версия."
        case .revisionOverflow: "Не удалось увеличить версию обмера."
        case .invalidContext: "Укажите описание точки обмера длиной до 500 символов; для произвольной позиции описание обязательно."
        case .incompatibleHeightProjection: "Высота AR-обмера должна измеряться по вертикали Y, а не по наклонной линии между точками."
        case .incompatibleSurfaceHeightProjection: "Высота вдоль поверхности должна сохранять прямое 3D-расстояние между точками без вертикальной или горизонтальной проекции."
        case .incompatibleProfile: "Диапазон размеров доступен для обмеров одного объекта и профиля с одинаковым типом размера."
        case .duplicateProfileObservation: "Один и тот же обмер нельзя дважды включить в диапазон размеров."
        case .revisionConflict: "Этот обмер уже изменён. Обновите список и повторите редактирование."
        case .unsupportedSchema: "Формат обмеров новее этой версии приложения. Обновите Atlas; исходный файл сохранён."
        case .invalidStoredData: "Файл обмеров повреждён. Исходный файл сохранён для восстановления."
        case .storageLimitExceeded: "Локальное хранилище обмеров достигло допустимого размера. Экспортируйте данные."
        case .lockingFailed: "Не удалось получить доступ к хранилищу обмеров. Повторите сохранение."
        }
    }
}

public enum MeasurementGeometry {
    public static func distance(from start: MetricPoint3D, to end: MetricPoint3D) throws -> Double {
        try validate(start); try validate(end)
        return hypot(hypot(end.x - start.x, end.y - start.y), end.z - start.z)
    }
    public static func horizontalDistance(from start: MetricPoint3D, to end: MetricPoint3D) throws -> Double {
        try validate(start); try validate(end)
        return hypot(end.x - start.x, end.z - start.z)
    }
    public static func verticalDistance(from start: MetricPoint3D, to end: MetricPoint3D) throws -> Double {
        try validate(start); try validate(end)
        return abs(end.y - start.y)
    }
    public static func value(kind: MeasurementKind, from start: MetricPoint3D, to end: MetricPoint3D) throws -> Double {
        switch kind {
        case .distance: try distance(from: start, to: end)
        case .horizontalDistance: try horizontalDistance(from: start, to: end)
        case .verticalDistance: try verticalDistance(from: start, to: end)
        }
    }
    public static func validate(_ point: MetricPoint3D) throws {
        let limit = 1_000_000.0
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
              abs(point.x) <= limit, abs(point.y) <= limit, abs(point.z) <= limit else {
            throw MeasurementError.invalidPoint
        }
    }
}

public struct MeasurementComparisonResult: Codable, Hashable, Sendable {
    public let measuredMeters: Double
    public let referenceMeters: Double
    public let deltaMeters: Double
    public let relativeDifferencePercent: Double
}

/// A discrepancy against an operator-supplied control, not a survey accuracy claim
/// and not a calibration of the AR session or of other measurements.
public enum MeasurementComparison {
    public static func compare(measuredMeters: Double, referenceMeters: Double) throws -> MeasurementComparisonResult {
        try MeasurementPolicy.validateMeters(measuredMeters)
        guard referenceMeters.isFinite, referenceMeters > 0, referenceMeters <= 4_000_000 else {
            throw MeasurementError.invalidReference
        }
        let delta = measuredMeters - referenceMeters
        let percent = delta / referenceMeters * 100
        guard percent.isFinite else { throw MeasurementError.invalidReference }
        return MeasurementComparisonResult(measuredMeters: measuredMeters, referenceMeters: referenceMeters,
                                          deltaMeters: delta, relativeDifferencePercent: percent)
    }
}

public enum MeasurementPolicy {
    public static func validate(_ record: MeasurementRecord) throws {
        guard !record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.label.count <= 200 else {
            throw MeasurementError.invalidLabel
        }
        try validateMeters(record.originalMeters)
        try validateDate(record.createdAt)
        guard record.revision >= 0 else { throw MeasurementError.invalidRevision }
        if let context = record.context {
            guard context.positionNote.count <= 500,
                  context.position != .custom || !context.positionNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeasurementError.invalidContext
            }
            if record.source == .arRaycast, context.role == .height, record.kind != .verticalDistance {
                throw MeasurementError.incompatibleHeightProjection
            }
            if record.source == .arRaycast, context.role == .surfaceHeight, record.kind != .distance {
                throw MeasurementError.incompatibleSurfaceHeightProjection
            }
        }
        if record.source == .arRaycast {
            guard record.frameID != nil, let start = record.start, let end = record.end,
                  record.trackingQuality != nil else { throw MeasurementError.invalidARObservation }
            guard record.surfaceEvidence.isEmpty || record.surfaceEvidence.count == 2 else {
                throw MeasurementError.invalidARObservation
            }
            let derived = try MeasurementGeometry.value(kind: record.kind, from: start, to: end)
            guard abs(derived - record.originalMeters) <= max(1e-6, derived * 1e-6) else {
                throw MeasurementError.inconsistentOriginalDistance
            }
        } else if record.start != nil || record.end != nil || record.frameID != nil || record.trackingQuality != nil
                    || !record.surfaceEvidence.isEmpty {
            throw MeasurementError.unexpectedARMetadata
        }
        var seen = Set<UUID>()
        for correction in record.corrections {
            guard seen.insert(correction.id).inserted else { throw MeasurementError.duplicateCorrectionID }
            if let meters = correction.meters { try validateMeters(meters) }
            try validateDate(correction.changedAt)
            guard !correction.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  correction.note.count <= 2000 else { throw MeasurementError.invalidCorrectionNote }
        }
    }

    public static func validateTransition(from old: MeasurementRecord, to new: MeasurementRecord) throws {
        try validate(new)
        guard new.id == old.id, new.projectID == old.projectID, new.kind == old.kind, new.source == old.source,
              new.originalMeters == old.originalMeters, new.frameID == old.frameID,
              new.start == old.start, new.end == old.end, new.trackingQuality == old.trackingQuality,
              new.surfaceEvidence == old.surfaceEvidence,
              new.context == old.context,
              new.createdAt == old.createdAt else { throw MeasurementError.originalChanged }
        guard new.corrections.count >= old.corrections.count,
              Array(new.corrections.prefix(old.corrections.count)) == old.corrections else {
            throw MeasurementError.historyChanged
        }
    }

    public static func validateMeters(_ meters: Double) throws {
        guard meters.isFinite, meters >= 0, meters <= 4_000_000 else { throw MeasurementError.invalidDistance }
    }
    private static func validateDate(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw MeasurementError.invalidDate }
    }
}

public enum PlanMeasurementDimension: String, Codable, CaseIterable, Sendable {
    case wallLength, wallHeight, wallThickness
}

/// The source record/revision remain identifiable after a scalar control is applied.
/// This is neither registration of AR coordinates nor a correction of the whole plan.
public struct PlanMeasurementApplication: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var measurementID: UUID
    public var measurementRevision: Int64
    public var wallID: UUID
    public var dimension: PlanMeasurementDimension
    public var previousMeters: Double?
    public var appliedMeters: Double
    public var appliedAt: Date
    public init(id: UUID = UUID(), measurementID: UUID, measurementRevision: Int64, wallID: UUID,
                dimension: PlanMeasurementDimension, previousMeters: Double?, appliedMeters: Double,
                appliedAt: Date = Date()) {
        self.id = id; self.measurementID = measurementID; self.measurementRevision = measurementRevision
        self.wallID = wallID; self.dimension = dimension; self.previousMeters = previousMeters
        self.appliedMeters = appliedMeters; self.appliedAt = appliedAt
    }
}

public enum PlanMeasurementError: Error, LocalizedError, Equatable, Sendable {
    case projectMismatch, wallNotFound, zeroLengthWall, incompatibleDimension
    case nonpositiveDimension, unsavedMeasurement, invalidApplication, applicationHistoryChanged
    public var errorDescription: String? {
        switch self {
        case .projectMismatch: "Контрольный размер и план должны относиться к одному проекту."
        case .wallNotFound: "Выбранная стена отсутствует в плане. Обновите план."
        case .zeroLengthWall: "У стены нет конечной ненулевой линии: направление изменения длины неизвестно."
        case .incompatibleDimension: "Тип обмера не соответствует размеру стены: вертикальный — для высоты, горизонтальный — для длины или толщины."
        case .nonpositiveDimension: "Размер стены должен быть конечным положительным числом в метрах."
        case .unsavedMeasurement: "Сначала сохраните контрольный обмер в проекте."
        case .invalidApplication: "В истории применения контрольных размеров содержится недопустимая запись."
        case .applicationHistoryChanged: "Историю применения контрольных размеров нельзя удалить или переписать."
        }
    }
}

public enum MeasurementPlanControl {
    public static func applying(measurement: MeasurementRecord, to plan: AtlasFloorPlan, wallID: UUID,
                                dimension: PlanMeasurementDimension, now: Date = Date()) throws -> AtlasFloorPlan {
        try MeasurementPolicy.validate(measurement)
        guard measurement.revision > 0 else { throw PlanMeasurementError.unsavedMeasurement }
        guard measurement.projectID == plan.projectID else { throw PlanMeasurementError.projectMismatch }
        guard let index = plan.walls.firstIndex(where: { $0.id == wallID }) else { throw PlanMeasurementError.wallNotFound }
        guard (measurement.kind != .verticalDistance || dimension == .wallHeight),
              (measurement.kind != .horizontalDistance || dimension != .wallHeight) else {
            throw PlanMeasurementError.incompatibleDimension
        }
        if let role = measurement.context?.role {
            guard role != .surfaceHeight,
                  (role != .height || dimension == .wallHeight),
                  (role != .thickness || dimension == .wallThickness),
                  (role != .length && role != .width || dimension != .wallHeight) else {
                throw PlanMeasurementError.incompatibleDimension
            }
        }
        let value = measurement.effectiveMeters
        guard value.isFinite, value > 0, dimension != .wallLength || value > 1e-9 else {
            throw PlanMeasurementError.nonpositiveDimension
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw PlanMeasurementError.invalidApplication }
        var updated = plan
        let current = plan.walls[index]
        let previous: Double?
        switch dimension {
        case .wallLength:
            let dx = current.end.x - current.start.x, dy = current.end.y - current.start.y
            let length = hypot(dx, dy)
            guard current.start.x.isFinite, current.start.y.isFinite, current.end.x.isFinite,
                  current.end.y.isFinite, length.isFinite, length > 1e-9 else {
                throw PlanMeasurementError.zeroLengthWall
            }
            previous = length
            updated.walls[index].end = .init(x: current.start.x + dx / length * value,
                                             y: current.start.y + dy / length * value)
        case .wallHeight:
            previous = current.heightMeters
            updated.walls[index].heightMeters = value
        case .wallThickness:
            previous = current.thicknessMeters
            updated.walls[index].thicknessMeters = value
        }
        var applications = plan.measurementApplications ?? []
        applications.append(.init(measurementID: measurement.id, measurementRevision: measurement.revision,
            wallID: wallID, dimension: dimension, previousMeters: previous, appliedMeters: value, appliedAt: now))
        updated.measurementApplications = applications
        try validateApplications(updated)
        try PolygonGeometry.validate(updated, in: .localMeters(frameID: updated.frameID))
        return updated
    }

    /// Historical wall IDs may no longer be present after a later manual wall removal.
    public static func validateApplications(_ plan: AtlasFloorPlan) throws {
        var ids = Set<UUID>()
        for application in plan.measurementApplications ?? [] {
            guard ids.insert(application.id).inserted, application.measurementRevision > 0,
                  application.appliedMeters.isFinite, application.appliedMeters > 0,
                  application.appliedMeters <= 4_000_000,
                  application.appliedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw PlanMeasurementError.invalidApplication
            }
            if let previous = application.previousMeters, !previous.isFinite || previous < 0 {
                throw PlanMeasurementError.invalidApplication
            }
        }
    }

    public static func validateTransition(from old: AtlasFloorPlan, to new: AtlasFloorPlan) throws {
        try validateApplications(new)
        let before = old.measurementApplications ?? [], after = new.measurementApplications ?? []
        guard after.count >= before.count, Array(after.prefix(before.count)) == before else {
            throw PlanMeasurementError.applicationHistoryChanged
        }
    }
}
