import Foundation

public enum CollaborativeSurveyError: Error, LocalizedError, Equatable, Sendable {
    case invalidPlan, invalidWorkers, unsupportedBoundary, tooManyCells, revisionConflict
    case unknownCell, unknownWorker, invalidEvidence, conflictingEvidence, frameMismatch, limitExceeded
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: "План совместной съёмки повреждён или содержит недопустимые значения."
        case .invalidWorkers: "Нужны от 1 до 64 сотрудников с разными идентификаторами и непустыми именами."
        case .unsupportedBoundary: "Для распределения нужен полигон в WGS84 или одной локальной системе метров."
        case .tooManyCells: "Сетка превышает 20 000 ячеек. Увеличьте размер ячейки или разделите проект."
        case .revisionConflict: "План изменён другим участником. Загрузите последнюю версию перед правкой."
        case .unknownCell: "Ячейка отсутствует в этом плане."
        case .unknownWorker: "Сотрудник отсутствует в этом плане."
        case .invalidEvidence: "Для покрытия нужны реальные материалы, их система координат и проверяемое происхождение."
        case .conflictingEvidence: "Идентификатор подтверждения уже используется для других данных."
        case .frameMismatch: "Точка или материал относятся к другой системе координат; нужна явная привязка."
        case .limitExceeded: "Достигнут предел журнала; сохраните его и начните следующий этап."
        }
    }
}

public struct CollaborativeSurveyWorker: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public enum CollaborativeSurveyCellBoundary: String, Codable, Sendable {
    case interior, partialRequiresReview
}

/// boundsVertices is a GRID RECTANGLE, not a work polygon. Render it clipped by
/// the original exterior and holes. center is an interior representative point,
/// including for thin edge fragments whose geometric rectangle center is outside.
public struct CollaborativeSurveyCell: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let row: Int
    public let column: Int
    public let center: MetricPoint2D
    public let boundsVertices: [MetricPoint2D]
    public let boundaryStatus: CollaborativeSurveyCellBoundary
    public let estimatedWorkAreaSquareMeters: Double
    public let componentID: Int
}

public struct CollaborativeSurveyAssignment: Codable, Hashable, Sendable {
    public let cellID: String
    public let workerID: UUID
    public init(cellID: String, workerID: UUID) { self.cellID = cellID; self.workerID = workerID }
}

public struct CollaborativeSurveyAssignmentEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let revision: Int64
    public let cellIDs: [String]
    public let previousWorkerIDs: [String: UUID]
    public let workerID: UUID
    public let timestamp: Date
}

public enum CollaborativeSurveyEvidenceKind: String, Codable, Sendable {
    case gpsWalk, captureObserved, operatorVerified
}
public enum CollaborativeSurveyFootprintProvenance: String, Codable, Sendable {
    case operatorMapped, registeredCapture
}
public enum CollaborativeSurveyEvidenceQuality: String, Codable, Sendable {
    case unknown, usable, needsRescan
}
public enum CollaborativeSurveyCoverage: String, Codable, Sendable {
    case unobserved, walked, observed, verified, needsRescan
}

/// Footprints are explicit assertions in the PLAN grid frame. A capture geotag
/// does not establish a LiDAR/AR transform. Registered footprints require an
/// identified registration for different frames; operator-mapped footprints are
/// explicitly human assertions. Operator verification is a completeness review,
/// not a certification of GNSS/measurement accuracy.
public struct CollaborativeSurveyEvidence: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let workerID: UUID
    public let kind: CollaborativeSurveyEvidenceKind
    public let timestamp: Date
    public let cellIDs: [String]
    public let captureID: UUID?
    public let sourceSHA256: String?
    public let footprintProvenance: CollaborativeSurveyFootprintProvenance?
    public let sourceFrameID: UUID?
    public let registrationID: UUID?
    public let footprint: MetricPolygon?
    public let horizontalAccuracyMeters: Double?
    public let quality: CollaborativeSurveyEvidenceQuality
    public let referencedEvidenceIDs: [UUID]
    public let boundaryReviewed: Bool
    public let note: String
    public init(id: UUID = UUID(), workerID: UUID, kind: CollaborativeSurveyEvidenceKind,
                timestamp: Date, cellIDs: [String], captureID: UUID? = nil, sourceSHA256: String? = nil,
                footprintProvenance: CollaborativeSurveyFootprintProvenance? = nil, sourceFrameID: UUID? = nil,
                registrationID: UUID? = nil, footprint: MetricPolygon? = nil,
                horizontalAccuracyMeters: Double? = nil, quality: CollaborativeSurveyEvidenceQuality = .unknown,
                referencedEvidenceIDs: [UUID] = [], boundaryReviewed: Bool = false, note: String = "") {
        self.id = id; self.workerID = workerID; self.kind = kind; self.timestamp = timestamp
        self.cellIDs = cellIDs; self.captureID = captureID; self.sourceSHA256 = sourceSHA256
        self.footprintProvenance = footprintProvenance; self.sourceFrameID = sourceFrameID
        self.registrationID = registrationID; self.footprint = footprint
        self.horizontalAccuracyMeters = horizontalAccuracyMeters; self.quality = quality
        self.referencedEvidenceIDs = referencedEvidenceIDs; self.boundaryReviewed = boundaryReviewed; self.note = note
    }
}

public enum CollaborativeSurveyGuidanceStatus: String, Codable, Sendable {
    case ready, complete, unknownAccuracy, poorAccuracy, frameMismatch, headingUnavailable
    case outsideBoundary, otherWorkersSector, boundaryUncertain
}
public struct CollaborativeSurveyGuidance: Codable, Hashable, Sendable {
    public let status: CollaborativeSurveyGuidanceStatus
    public let targetCellID: String?
    public let distanceMeters: Double?
    /// East/north bearing for a projected WGS84 plan; local grid direction otherwise.
    public let bearingDegrees: Double?
    /// Only available for a heading explicitly expressed in the SAME grid.
    public let turnDegrees: Double?
    public let currentWorkerID: UUID?
    /// The straight direction does not consider fences, vegetation, holes or hazards.
    public var isTraversalRoute: Bool { false }
}

public struct CollaborativeSurveyPlan: Identifiable, Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let projectID: UUID
    public private(set) var revision: Int64
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public let coordinateReference: CoordinateReference
    public let sourceBoundary: FeatureGeometry
    public let sourceBoundarySHA256: String
    public let gridFrameID: UUID
    public let projection: LocalWGS84Projection?
    public let boundary: MetricPolygon
    public let cellSizeMeters: Double
    public let cells: [CollaborativeSurveyCell]
    public let workers: [CollaborativeSurveyWorker]
    public private(set) var assignments: [CollaborativeSurveyAssignment]
    public private(set) var evidence: [CollaborativeSurveyEvidence]
    public private(set) var assignmentHistory: [CollaborativeSurveyAssignmentEvent]
    public let warnings: [String]

    fileprivate init(id: UUID, projectID: UUID, createdAt: Date, sourceBoundary: FeatureGeometry,
                     sourceBoundarySHA256: String, boundary: MetricPolygon, projection: LocalWGS84Projection?,
                     cellSizeMeters: Double, cells: [CollaborativeSurveyCell], workers: [CollaborativeSurveyWorker],
                     assignments: [CollaborativeSurveyAssignment]) {
        schemaVersion = 1; self.id = id; self.projectID = projectID; revision = 0
        self.createdAt = createdAt; updatedAt = createdAt
        coordinateReference = sourceBoundary.coordinateReference; self.sourceBoundary = sourceBoundary
        self.sourceBoundarySHA256 = sourceBoundarySHA256; gridFrameID = boundary.frameID
        self.projection = projection; self.boundary = boundary; self.cellSizeMeters = cellSizeMeters
        self.cells = cells; self.workers = workers; self.assignments = assignments
        evidence = []; assignmentHistory = []
        warnings = ["Распределение по площади приблизительное: сложность объектов и доступность могут различаться.",
                    "Пройденный GPS-трек не означает, что поверхность снята.",
                    "Стрелка показывает направление, а не безопасный маршрут; границы участков не запрещают переход.",
                    "Сетка и позиция телефона не являются кадастровым или геодезическим обмером.",
                    "Ячейки на краю и у внутренних контуров требуют отдельной проверки; независимые AR-сессии автоматически не совмещены."]
    }

    public var estimatedWorkAreaSquareMeters: Double { cells.reduce(0) { $0 + $1.estimatedWorkAreaSquareMeters } }
    public var componentCount: Int { Set(cells.map(\.componentID)).count }
    public var partialCellCount: Int { cells.filter { $0.boundaryStatus == .partialRequiresReview }.count }
    public var workersWithoutAssignments: [UUID] {
        let active = Set(assignments.map(\.workerID)); return workers.map(\.id).filter { !active.contains($0) }
    }

    public func project(_ coordinate: GeographicCoordinate) throws -> MetricPoint2D {
        guard coordinateReference == .wgs84, let projection else { throw CollaborativeSurveyError.frameMismatch }
        return try projection.project(coordinate)
    }

    public func coverage(for cellID: String) -> CollaborativeSurveyCoverage {
        coverageByCell()[cellID] ?? .unobserved
    }
    public func coverageIndex() -> [String: CollaborativeSurveyCoverage] { coverageByCell() }
    public func coverageByCell() -> [String: CollaborativeSurveyCoverage] {
        var walked = Set<String>(), observed = Set<String>()
        var rescans = [String: Set<UUID>](), verified = Set<String>(), resolved = [String: Set<UUID>]()
        for item in evidence {
            for cellID in item.cellIDs {
                switch item.kind {
                case .gpsWalk: walked.insert(cellID)
                case .captureObserved:
                    observed.insert(cellID)
                    if item.quality == .needsRescan { rescans[cellID, default: []].insert(item.id) }
                case .operatorVerified:
                    verified.insert(cellID)
                    resolved[cellID, default: []].formUnion(item.referencedEvidenceIDs)
                }
            }
        }
        var result = [String: CollaborativeSurveyCoverage]()
        for cellID in walked { result[cellID] = .walked }
        for cellID in observed { result[cellID] = .observed }
        for cellID in verified { result[cellID] = .verified }
        for (cellID, requests) in rescans where !requests.isSubset(of: resolved[cellID] ?? []) { result[cellID] = .needsRescan }
        return result
    }

    /// Chooses a work point, not a pedestrian route. Other workers' assignments
    /// remain outside this target list. Observed cells still require human review
    /// and are not silently treated as completed.
    public func nearestUncoveredTarget(workerID: UUID, from point: MetricPoint2D) -> CollaborativeSurveyCell? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let owned = Set(assignments.filter { $0.workerID == workerID }.map(\.cellID))
        let coverage = coverageByCell()
        return cells.filter { owned.contains($0.id) && coverage[$0.id] != .verified }
            .min {
                let a = hypot($0.center.x - point.x, $0.center.y - point.y)
                let b = hypot($1.center.x - point.x, $1.center.y - point.y)
                return a == b ? $0.id < $1.id : a < b
            }
    }

    public func guidance(workerID: UUID, position: MetricPoint2D, frameID: UUID,
                         horizontalAccuracyMeters: Double?, headingInGridDegrees: Double? = nil,
                         maximumAccuracyMeters: Double = 10) -> CollaborativeSurveyGuidance {
        func result(_ status: CollaborativeSurveyGuidanceStatus, target: CollaborativeSurveyCell? = nil,
                    distance: Double? = nil, bearing: Double? = nil, turn: Double? = nil,
                    owner: UUID? = nil) -> CollaborativeSurveyGuidance {
            .init(status: status, targetCellID: target?.id, distanceMeters: distance,
                  bearingDegrees: bearing, turnDegrees: turn, currentWorkerID: owner)
        }
        guard frameID == gridFrameID, position.x.isFinite, position.y.isFinite,
              workers.contains(where: { $0.id == workerID }) else { return result(.frameMismatch) }
        guard let accuracy = horizontalAccuracyMeters, accuracy.isFinite, accuracy >= 0 else { return result(.unknownAccuracy) }
        guard maximumAccuracyMeters.isFinite, maximumAccuracyMeters > 0, accuracy <= maximumAccuracyMeters else { return result(.poorAccuracy) }
        guard let target = nearestUncoveredTarget(workerID: workerID, from: position) else { return result(.complete) }
        let distance = hypot(target.center.x - position.x, target.center.y - position.y)
        let bearing = Self.normalized(atan2(target.center.x - position.x, target.center.y - position.y) * 180 / .pi)
        let turn = headingInGridDegrees.flatMap { heading -> Double? in
            guard heading.isFinite, (0..<360).contains(heading) else { return nil }
            let value = Self.normalized(bearing - heading); return value > 180 ? value - 360 : value
        }
        let current = cells.first { Self.insideRectangle(position, $0.boundsVertices) && CollaborativeSurveyPlanner.contains(position, in: boundary) }
        let owner = current.flatMap { cell in assignments.first(where: { $0.cellID == cell.id })?.workerID }
        let uncertain = distanceToSectorBoundary(position, owner: owner) <= accuracy
        let status: CollaborativeSurveyGuidanceStatus
        if uncertain { status = .boundaryUncertain }
        else if !CollaborativeSurveyPlanner.contains(position, in: boundary) { status = .outsideBoundary }
        else if let owner, owner != workerID { status = .otherWorkersSector }
        else if turn == nil { status = .headingUnavailable }
        else { status = .ready }
        return result(status, target: target, distance: distance, bearing: bearing,
                      turn: uncertain ? nil : turn, owner: uncertain ? nil : owner)
    }

    public mutating func reassign(cellIDs: [String], to workerID: UUID,
                                 expectedRevision: Int64, at timestamp: Date = Date()) throws {
        guard expectedRevision == revision else { throw CollaborativeSurveyError.revisionConflict }
        guard workers.contains(where: { $0.id == workerID }) else { throw CollaborativeSurveyError.unknownWorker }
        guard !cellIDs.isEmpty, Set(cellIDs).count == cellIDs.count, timestamp.timeIntervalSince1970.isFinite else { throw CollaborativeSurveyError.invalidPlan }
        let known = Set(cells.map(\.id)); guard cellIDs.allSatisfy(known.contains) else { throw CollaborativeSurveyError.unknownCell }
        let requestedIDs = Set(cellIDs)
        let changed = assignments.filter { requestedIDs.contains($0.cellID) && $0.workerID != workerID }
        guard !changed.isEmpty else { return }
        guard assignmentHistory.count < 2_000, assignmentHistory.reduce(0, { $0 + $1.cellIDs.count }) + changed.count <= 100_000,
              revision < Int64.max else { throw CollaborativeSurveyError.limitExceeded }
        let previous = Dictionary(uniqueKeysWithValues: changed.map { ($0.cellID, $0.workerID) })
        let changedIDs = Set(changed.map(\.cellID))
        assignments = assignments.map { changedIDs.contains($0.cellID) ? .init(cellID: $0.cellID, workerID: workerID) : $0 }
        revision += 1; updatedAt = timestamp
        assignmentHistory.append(.init(id: UUID(), revision: revision, cellIDs: changed.map(\.cellID),
                                       previousWorkerIDs: previous, workerID: workerID, timestamp: timestamp))
    }

    public mutating func recordEvidence(_ item: CollaborativeSurveyEvidence, expectedRevision: Int64) throws {
        if let existing = evidence.first(where: { $0.id == item.id }) {
            guard existing == item else { throw CollaborativeSurveyError.conflictingEvidence }; return
        }
        guard expectedRevision == revision else { throw CollaborativeSurveyError.revisionConflict }
        guard evidence.count < 10_000, revision < Int64.max else { throw CollaborativeSurveyError.limitExceeded }
        let vertices = evidence.reduce(0) { $0 + ($1.footprint.map { $0.vertices.count + $0.holes.reduce(0, { $0 + $1.count }) } ?? 0) }
        let additional = item.footprint.map { $0.vertices.count + $0.holes.reduce(0, { $0 + $1.count }) } ?? 0
        guard vertices + additional <= 100_000 else { throw CollaborativeSurveyError.limitExceeded }
        try validateEvidence(item, cellMap: Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) }),
                             preceding: Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) }))
        evidence.append(item); revision += 1; updatedAt = item.timestamp
    }

    public func validate() throws {
        guard schemaVersion == 1, revision >= 0, revision == Int64(evidence.count + assignmentHistory.count),
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              cells.count > 0, cells.count <= CollaborativeSurveyPlanner.maximumCells,
              evidence.count <= 10_000, assignmentHistory.count <= 2_000,
              assignmentHistory.reduce(0, { $0 + $1.cellIDs.count }) <= 100_000,
              cellSizeMeters.isFinite, cellSizeMeters >= 1, cellSizeMeters <= 500,
              sourceBoundary.coordinateReference == coordinateReference, boundary.frameID == gridFrameID,
              sourceBoundarySHA256 == (try CollaborativeSurveyPlanner.boundaryDigest(sourceBoundary)),
              Set(cells.map(\.id)).count == cells.count else { throw CollaborativeSurveyError.invalidPlan }
        try CollaborativeSurveyPlanner.validateWorkers(workers)
        try PolygonGeometry.validate(sourceBoundary, in: coordinateReference); try PolygonGeometry.validate(boundary)
        switch sourceBoundary {
        case let .metricPolygon(original):
            guard projection == nil, original == boundary else { throw CollaborativeSurveyError.invalidPlan }
        case let .geographicPolygon(original):
            guard let projection, projection.anchor == original.vertices.first,
                  try original.vertices.map({ try projection.project($0) }) == boundary.vertices,
                  try original.holes.map({ try $0.map({ try projection.project($0) }) }) == boundary.holes else { throw CollaborativeSurveyError.invalidPlan }
        default: throw CollaborativeSurveyError.unsupportedBoundary
        }
        let cellIDs = Set(cells.map(\.id)), workerIDs = Set(workers.map(\.id))
        guard assignments.count == cells.count, Set(assignments.map(\.cellID)) == cellIDs,
              assignments.allSatisfy({ workerIDs.contains($0.workerID) }),
              cells.allSatisfy({ $0.row >= 0 && $0.column >= 0 && $0.id == "r\($0.row)c\($0.column)" &&
                  $0.boundsVertices.count == 4 && $0.estimatedWorkAreaSquareMeters.isFinite &&
                  $0.estimatedWorkAreaSquareMeters > 0 && $0.estimatedWorkAreaSquareMeters <= cellSizeMeters * cellSizeMeters * (1 + 1e-8) &&
                  Self.insideRectangle($0.center, $0.boundsVertices) && CollaborativeSurveyPlanner.contains($0.center, in: boundary) }) else { throw CollaborativeSurveyError.invalidPlan }
        let canonical = try CollaborativeSurveyPlanner.create(projectID: projectID, boundary: sourceBoundary, workers: workers,
                                                              cellSizeMeters: cellSizeMeters, planID: id, createdAt: createdAt)
        guard canonical.cells == cells, evidence.reduce(0, { $0 + ($1.footprint.map { $0.vertices.count + $0.holes.reduce(0, { $0 + $1.count }) } ?? 0) }) <= 100_000 else { throw CollaborativeSurveyError.invalidPlan }
        var auditedOwners = Dictionary(uniqueKeysWithValues: canonical.assignments.map { ($0.cellID, $0.workerID) })
        var previousAssignmentRevision: Int64 = 0
        for change in assignmentHistory {
            guard change.revision > previousAssignmentRevision, change.revision <= revision,
                  Set(change.cellIDs).count == change.cellIDs.count, !change.cellIDs.isEmpty,
                  Set(change.previousWorkerIDs.keys) == Set(change.cellIDs),
                  change.cellIDs.allSatisfy({ auditedOwners[$0] == change.previousWorkerIDs[$0] && auditedOwners[$0] != change.workerID }) else {
                throw CollaborativeSurveyError.invalidPlan
            }
            for cellID in change.cellIDs { auditedOwners[cellID] = change.workerID }
            previousAssignmentRevision = change.revision
        }
        guard assignments.allSatisfy({ auditedOwners[$0.cellID] == $0.workerID }), canonical.warnings == warnings else {
            throw CollaborativeSurveyError.invalidPlan
        }
        let cellMap = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) })
        var preceding = [UUID: CollaborativeSurveyEvidence]()
        for item in evidence { try validateEvidence(item, cellMap: cellMap, preceding: preceding); preceding[item.id] = item }
        guard Set(evidence.map(\.id)).count == evidence.count,
              Set(assignmentHistory.map(\.id)).count == assignmentHistory.count,
              assignmentHistory.allSatisfy({ $0.revision > 0 && $0.revision <= revision &&
                  workerIDs.contains($0.workerID) && !$0.cellIDs.isEmpty && Set($0.cellIDs).count == $0.cellIDs.count &&
                  Set($0.previousWorkerIDs.keys) == Set($0.cellIDs) && $0.cellIDs.allSatisfy(cellIDs.contains) &&
                  $0.previousWorkerIDs.values.allSatisfy(workerIDs.contains) && $0.timestamp.timeIntervalSince1970.isFinite }) else { throw CollaborativeSurveyError.invalidPlan }
    }

    /// Journals permit a single append/reassignment, never a wholesale replacement
    /// of original geometry, another worker's capture history or a source frame.
    public func validateTransition(from previous: CollaborativeSurveyPlan) throws {
        try validate(); try previous.validate()
        if self == previous { return }
        guard id == previous.id, projectID == previous.projectID,
              revision == previous.revision + 1, schemaVersion == previous.schemaVersion,
              createdAt == previous.createdAt, coordinateReference == previous.coordinateReference,
              sourceBoundary == previous.sourceBoundary, sourceBoundarySHA256 == previous.sourceBoundarySHA256,
              gridFrameID == previous.gridFrameID, projection == previous.projection, boundary == previous.boundary,
              cellSizeMeters == previous.cellSizeMeters, cells == previous.cells, workers == previous.workers,
              warnings == previous.warnings else { throw CollaborativeSurveyError.revisionConflict }
        if evidence.count == previous.evidence.count + 1 {
            guard Array(evidence.dropLast()) == previous.evidence, assignments == previous.assignments,
                  assignmentHistory == previous.assignmentHistory, updatedAt == evidence.last?.timestamp else { throw CollaborativeSurveyError.invalidPlan }
        } else {
            guard evidence == previous.evidence, assignmentHistory.count == previous.assignmentHistory.count + 1,
                  Array(assignmentHistory.dropLast()) == previous.assignmentHistory, let change = assignmentHistory.last,
                  change.revision == revision, updatedAt == change.timestamp else { throw CollaborativeSurveyError.invalidPlan }
            var simulated = previous
            try simulated.reassign(cellIDs: change.cellIDs, to: change.workerID,
                                   expectedRevision: previous.revision, at: change.timestamp)
            guard simulated.assignments == assignments,
                  simulated.assignmentHistory.last?.previousWorkerIDs == change.previousWorkerIDs else { throw CollaborativeSurveyError.invalidPlan }
        }
    }

    /// Evidence-only reconciliation for offline copies of the SAME allocation.
    /// Local prefix/order is retained. Remote dependency order is honored; event
    /// UUID reuse with a different hash/payload and assignment divergence fail.
    @discardableResult
    public mutating func mergeEvidence(from other: CollaborativeSurveyPlan, expectedRevision: Int64) throws -> Int {
        guard expectedRevision == revision else { throw CollaborativeSurveyError.revisionConflict }
        try validate(); try other.validate(); try requireSameAllocation(as: other)
        var known = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        var pending = [CollaborativeSurveyEvidence]()
        for item in other.evidence {
            if let existing = known[item.id] {
                guard existing == item else { throw CollaborativeSurveyError.conflictingEvidence }
            } else { pending.append(item) }
        }
        guard evidence.count + pending.count <= 10_000 else { throw CollaborativeSurveyError.limitExceeded }
        let count = pending.count
        var candidate = self
        while !pending.isEmpty {
            guard let index = pending.firstIndex(where: { $0.referencedEvidenceIDs.allSatisfy { known[$0] != nil } }) else {
                throw CollaborativeSurveyError.invalidEvidence
            }
            let item = pending.remove(at: index)
            try candidate.recordEvidence(item, expectedRevision: candidate.revision); known[item.id] = item
        }
        try candidate.validate(); self = candidate; return count
    }

    /// Allows a store to accept a reviewed evidence-only merge atomically, while
    /// refusing edits to an existing event, the allocation, frame or geometry.
    public func validateEvidenceMerge(from previous: CollaborativeSurveyPlan) throws {
        try validate(); try previous.validate(); try requireSameAllocation(as: previous)
        guard evidence.count >= previous.evidence.count,
              Array(evidence.prefix(previous.evidence.count)) == previous.evidence,
              revision == previous.revision + Int64(evidence.count - previous.evidence.count),
              evidence.count == previous.evidence.count ? updatedAt == previous.updatedAt : updatedAt == evidence.last?.timestamp else {
            throw CollaborativeSurveyError.invalidPlan
        }
    }

    private func requireSameAllocation(as other: CollaborativeSurveyPlan) throws {
        guard id == other.id, projectID == other.projectID, schemaVersion == other.schemaVersion,
              createdAt == other.createdAt, coordinateReference == other.coordinateReference,
              sourceBoundary == other.sourceBoundary, sourceBoundarySHA256 == other.sourceBoundarySHA256,
              gridFrameID == other.gridFrameID, projection == other.projection, boundary == other.boundary,
              cellSizeMeters == other.cellSizeMeters, cells == other.cells, workers == other.workers,
              assignments == other.assignments, assignmentHistory == other.assignmentHistory, warnings == other.warnings else {
            throw CollaborativeSurveyError.revisionConflict
        }
    }

    private func validateEvidence(_ item: CollaborativeSurveyEvidence, cellMap: [String: CollaborativeSurveyCell],
                                  preceding: [UUID: CollaborativeSurveyEvidence]) throws {
        guard workers.contains(where: { $0.id == item.workerID }), item.timestamp.timeIntervalSince1970.isFinite,
              !item.cellIDs.isEmpty, item.cellIDs.count <= 256, Set(item.cellIDs).count == item.cellIDs.count,
              item.note.utf8.count <= 4_096, item.referencedEvidenceIDs.count <= 256,
              Set(item.referencedEvidenceIDs).count == item.referencedEvidenceIDs.count,
              item.horizontalAccuracyMeters == nil || (item.horizontalAccuracyMeters!.isFinite && item.horizontalAccuracyMeters! >= 0) else { throw CollaborativeSurveyError.invalidEvidence }
        guard item.cellIDs.allSatisfy({ cellMap[$0] != nil }) else { throw CollaborativeSurveyError.unknownCell }
        switch item.kind {
        case .gpsWalk:
            guard item.captureID == nil, item.sourceSHA256 == nil, item.footprintProvenance == nil, item.footprint == nil, item.sourceFrameID == nil,
                  item.registrationID == nil, item.referencedEvidenceIDs.isEmpty, !item.boundaryReviewed,
                  item.quality == .unknown else { throw CollaborativeSurveyError.invalidEvidence }
        case .captureObserved:
            guard item.captureID != nil, let digest = item.sourceSHA256, FieldTransferDigest.isSHA256(digest),
                  let provenance = item.footprintProvenance, let footprint = item.footprint, footprint.frameID == gridFrameID,
                  item.referencedEvidenceIDs.isEmpty, !item.boundaryReviewed else { throw CollaborativeSurveyError.invalidEvidence }
            switch provenance {
            case .operatorMapped:
                guard item.registrationID == nil else { throw CollaborativeSurveyError.invalidEvidence }
            case .registeredCapture:
                guard let sourceFrame = item.sourceFrameID, sourceFrame == gridFrameID || item.registrationID != nil else { throw CollaborativeSurveyError.invalidEvidence }
            }
            try PolygonGeometry.validate(footprint)
            guard footprint.vertices.count + footprint.holes.reduce(0, { $0 + $1.count }) <= 512,
                  item.cellIDs.allSatisfy({ id in
                      guard let cell = cellMap[id] else { return false }
                      return CollaborativeSurveyPlanner.contains(cell.center, in: footprint)
                  }) else { throw CollaborativeSurveyError.invalidEvidence }
        case .operatorVerified:
            guard item.captureID == nil, item.sourceSHA256 == nil, item.footprintProvenance == nil, item.sourceFrameID == nil, item.registrationID == nil, item.footprint == nil,
                  item.quality == .usable, !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.referencedEvidenceIDs.isEmpty else { throw CollaborativeSurveyError.invalidEvidence }
            let references = item.referencedEvidenceIDs.compactMap { preceding[$0] }
            guard references.count == item.referencedEvidenceIDs.count,
                  references.allSatisfy({ $0.kind == .captureObserved && ($0.quality == .usable || $0.quality == .needsRescan) }),
                  item.cellIDs.allSatisfy({ id in references.contains(where: { $0.cellIDs.contains(id) && $0.quality == .usable }) }),
                  item.boundaryReviewed || item.cellIDs.allSatisfy({ cellMap[$0]?.boundaryStatus == .interior }) else { throw CollaborativeSurveyError.invalidEvidence }
        }
    }

    private func distanceToSectorBoundary(_ point: MetricPoint2D, owner: UUID?) -> Double {
        var result = CollaborativeSurveyPlanner.distanceToBoundary(point, polygon: boundary)
        let owners = Dictionary(uniqueKeysWithValues: assignments.map { ($0.cellID, $0.workerID) })
        for cell in cells {
            guard owners[cell.id] != owner else { continue }
            for index in cell.boundsVertices.indices {
                result = min(result, CollaborativeSurveyPlanner.segmentDistance(point, cell.boundsVertices[index], cell.boundsVertices[(index + 1) % 4]))
            }
        }
        return result
    }
    private static func normalized(_ value: Double) -> Double { let result = value.truncatingRemainder(dividingBy: 360); return result < 0 ? result + 360 : result }
    fileprivate static func insideRectangle(_ point: MetricPoint2D, _ rectangle: [MetricPoint2D]) -> Bool {
        guard rectangle.count == 4 else { return false }
        return point.x >= rectangle[0].x && point.x <= rectangle[2].x && point.y >= rectangle[0].y && point.y <= rectangle[2].y
    }
}

/// Deterministic bounded planning, not a trained classifier or a global AR map.
/// Four-neighbour graph links are admitted only if their interior-point segment
/// stays inside the original polygon, including holes. A greedy balanced flood
/// yields contiguous sector parts; separate graph components are explicit.
public enum CollaborativeSurveyPlanner {
    public static let maximumCells = 20_000
    public static let maximumWorkers = 64
    public static func create(projectID: UUID, boundary sourceBoundary: FeatureGeometry,
                              workers: [CollaborativeSurveyWorker], cellSizeMeters: Double,
                              planID: UUID = UUID(), createdAt: Date = Date()) throws -> CollaborativeSurveyPlan {
        try validateWorkers(workers)
        guard cellSizeMeters.isFinite, (1...500).contains(cellSizeMeters), createdAt.timeIntervalSince1970.isFinite else { throw CollaborativeSurveyError.invalidPlan }
        let boundary: MetricPolygon, projection: LocalWGS84Projection?
        switch sourceBoundary {
        case let .metricPolygon(polygon): boundary = polygon; projection = nil
        case let .geographicPolygon(polygon):
            try PolygonGeometry.validate(polygon)
            let local = try LocalWGS84Projection(anchor: polygon.vertices[0]); projection = local
            boundary = try MetricPolygon(frameID: planID, vertices: polygon.vertices.map { try local.project($0) },
                                         holes: polygon.holes.map { try $0.map { try local.project($0) } })
        default: throw CollaborativeSurveyError.unsupportedBoundary
        }
        try PolygonGeometry.validate(boundary)
        let minX = boundary.vertices.map(\.x).min()!, maxX = boundary.vertices.map(\.x).max()!
        let minY = boundary.vertices.map(\.y).min()!, maxY = boundary.vertices.map(\.y).max()!
        let columnsValue = ceil((maxX - minX) / cellSizeMeters), rowsValue = ceil((maxY - minY) / cellSizeMeters)
        guard columnsValue.isFinite, rowsValue.isFinite, columnsValue > 0, rowsValue > 0,
              columnsValue <= Double(maximumCells), rowsValue <= Double(maximumCells),
              columnsValue * rowsValue <= Double(maximumCells) else { throw CollaborativeSurveyError.tooManyCells }
        let columns = Int(columnsValue), rows = Int(rowsValue)
        var drafts = [CellDraft](), lookup = [String: Int]()
        for row in 0..<rows {
            for column in 0..<columns {
                let x = minX + Double(column) * cellSizeMeters, y = minY + Double(row) * cellSizeMeters
                let rectangle = [MetricPoint2D(x: x, y: y), .init(x: x + cellSizeMeters, y: y),
                                 .init(x: x + cellSizeMeters, y: y + cellSizeMeters), .init(x: x, y: y + cellSizeMeters)]
                let area = intersectionArea(boundary, rectangle: rectangle)
                guard area > 1e-10 else { continue }
                guard let center = representativePoint(boundary, rectangle: rectangle) else { throw CollaborativeSurveyError.invalidPlan }
                let partial = ([boundary.vertices] + boundary.holes).contains { ring in
                    ring.indices.contains { edgePassesRectangleInterior(ring[$0], ring[($0 + 1) % ring.count], rectangle) }
                }
                let id = "r\(row)c\(column)"; lookup[id] = drafts.count
                drafts.append(.init(id: id, row: row, column: column, center: center, rectangle: rectangle,
                                    area: min(area, cellSizeMeters * cellSizeMeters), partial: partial))
            }
        }
        guard !drafts.isEmpty else { throw CollaborativeSurveyError.invalidPlan }
        var adjacency = [[Int]](repeating: [], count: drafts.count)
        for index in drafts.indices {
            let cell = drafts[index]
            for (row, column) in [(cell.row, cell.column + 1), (cell.row + 1, cell.column)] {
                if let other = lookup["r\(row)c\(column)"], segmentInside(cell.center, drafts[other].center, polygon: boundary) {
                    adjacency[index].append(other); adjacency[other].append(index)
                }
            }
        }
        var componentIDs = [Int](repeating: -1, count: drafts.count), components = [[Int]]()
        for start in drafts.indices where componentIDs[start] == -1 {
            let componentID = components.count; var queue = [start], cursor = 0; componentIDs[start] = componentID
            while cursor < queue.count {
                let index = queue[cursor]; cursor += 1
                for next in adjacency[index] where componentIDs[next] == -1 { componentIDs[next] = componentID; queue.append(next) }
            }
            components.append(queue.sorted())
        }
        let owners = partition(drafts: drafts, components: components, adjacency: adjacency, workerCount: workers.count)
        let cells = drafts.indices.map { index in
            let item = drafts[index]
            return CollaborativeSurveyCell(id: item.id, row: item.row, column: item.column, center: item.center,
                                           boundsVertices: item.rectangle, boundaryStatus: item.partial ? .partialRequiresReview : .interior,
                                           estimatedWorkAreaSquareMeters: item.area, componentID: componentIDs[index])
        }
        return CollaborativeSurveyPlan(id: planID, projectID: projectID, createdAt: createdAt, sourceBoundary: sourceBoundary,
                                       sourceBoundarySHA256: try boundaryDigest(sourceBoundary), boundary: boundary, projection: projection,
                                       cellSizeMeters: cellSizeMeters, cells: cells, workers: workers,
                                       assignments: drafts.indices.map { .init(cellID: drafts[$0].id, workerID: workers[owners[$0]].id) })
    }

    fileprivate static func boundaryDigest(_ boundary: FeatureGeometry) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return FieldTransferDigest.sha256(try encoder.encode(boundary))
    }
    fileprivate static func validateWorkers(_ workers: [CollaborativeSurveyWorker]) throws {
        guard !workers.isEmpty, workers.count <= maximumWorkers, Set(workers.map(\.id)).count == workers.count,
              workers.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf8.count <= 240 }) else { throw CollaborativeSurveyError.invalidWorkers }
    }
    private struct CellDraft {
        let id: String; let row: Int; let column: Int; let center: MetricPoint2D
        let rectangle: [MetricPoint2D]; let area: Double; let partial: Bool
    }
    private static func partition(drafts: [CellDraft], components: [[Int]], adjacency: [[Int]], workerCount: Int) -> [Int] {
        var owners = [Int](repeating: -1, count: drafts.count), loads = [Double](repeating: 0, count: workerCount)
        let ordered = components.sorted { a, b in
            let x = a.reduce(0) { $0 + drafts[$1].area }, y = b.reduce(0) { $0 + drafts[$1].area }
            return x == y ? a[0] < b[0] : x > y
        }
        for component in ordered {
            let active = (0..<workerCount).sorted { loads[$0] == loads[$1] ? $0 < $1 : loads[$0] < loads[$1] }.prefix(min(workerCount, component.count))
            var seeds = [Int](), frontiers = [[Int]](repeating: [], count: workerCount), heads = [Int](repeating: 0, count: workerCount)
            for worker in active {
                let seed: Int
                if seeds.isEmpty { seed = component[0] }
                else {
                    seed = component.filter { !seeds.contains($0) }.max { a, b in
                        let x = seeds.map { hypot(drafts[a].center.x - drafts[$0].center.x, drafts[a].center.y - drafts[$0].center.y) }.min()!
                        let y = seeds.map { hypot(drafts[b].center.x - drafts[$0].center.x, drafts[b].center.y - drafts[$0].center.y) }.min()!
                        return x == y ? a > b : x < y
                    }!
                }
                seeds.append(seed); owners[seed] = worker; loads[worker] += drafts[seed].area; frontiers[worker] = adjacency[seed]
            }
            var remaining = component.count - seeds.count
            while remaining > 0 {
                let sorted = active.sorted { loads[$0] == loads[$1] ? $0 < $1 : loads[$0] < loads[$1] }
                var advanced = false
                for worker in sorted {
                    while heads[worker] < frontiers[worker].count && owners[frontiers[worker][heads[worker]]] != -1 { heads[worker] += 1 }
                    guard heads[worker] < frontiers[worker].count else { continue }
                    let index = frontiers[worker][heads[worker]]; heads[worker] += 1
                    owners[index] = worker; loads[worker] += drafts[index].area
                    frontiers[worker].append(contentsOf: adjacency[index]); remaining -= 1; advanced = true; break
                }
                // Every nonempty connected component has an initial seed. This
                // fallback cannot occur for a correctly built adjacency graph.
                if !advanced { break }
            }
        }
        return owners
    }

    public static func contains(_ point: MetricPoint2D, in polygon: MetricPolygon) -> Bool {
        insideRing(point, polygon.vertices) && !polygon.holes.contains { insideRing(point, $0) }
    }
    private static func insideRing(_ point: MetricPoint2D, _ ring: [MetricPoint2D]) -> Bool {
        guard ring.count >= 3 else { return false }; var result = false
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            if segmentDistance(point, a, b) <= 1e-9 { return true }
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
        }
        return result
    }
    fileprivate static func intersectionArea(_ polygon: MetricPolygon, rectangle: [MetricPoint2D]) -> Double {
        let exterior = abs(PolygonGeometry.signedArea(clip(polygon.vertices, rectangle)))
        let holes = polygon.holes.reduce(0) { $0 + abs(PolygonGeometry.signedArea(clip($1, rectangle))) }
        return max(0, exterior - holes)
    }
    /// Clipped concave rings may have zero-area connecting edges between pieces.
    /// They are used ONLY for area integration, never exposed as a work polygon.
    private static func clip(_ ring: [MetricPoint2D], _ rectangle: [MetricPoint2D]) -> [MetricPoint2D] {
        guard rectangle.count == 4 else { return [] }; var result = ring
        for side in 0..<4 {
            let input = result; result = []; guard !input.isEmpty else { break }
            func inside(_ point: MetricPoint2D) -> Bool {
                switch side { case 0: point.x >= rectangle[0].x; case 1: point.x <= rectangle[2].x
                case 2: point.y >= rectangle[0].y; default: point.y <= rectangle[2].y }
            }
            func intersection(_ a: MetricPoint2D, _ b: MetricPoint2D) -> MetricPoint2D {
                if side < 2 {
                    let x = side == 0 ? rectangle[0].x : rectangle[2].x
                    let fraction = (x - a.x) / (b.x - a.x)
                    return .init(x: x, y: a.y + fraction * (b.y - a.y))
                }
                let y = side == 2 ? rectangle[0].y : rectangle[2].y
                let fraction = (y - a.y) / (b.y - a.y)
                return .init(x: a.x + fraction * (b.x - a.x), y: y)
            }
            for index in input.indices {
                let a = input[(index + input.count - 1) % input.count], b = input[index]
                if inside(b) { if !inside(a) { result.append(intersection(a, b)) }; result.append(b) }
                else if inside(a) { result.append(intersection(a, b)) }
            }
        }
        return result
    }
    private static func representativePoint(_ polygon: MetricPolygon, rectangle: [MetricPoint2D]) -> MetricPoint2D? {
        let center = MetricPoint2D(x: (rectangle[0].x + rectangle[2].x) / 2, y: (rectangle[0].y + rectangle[2].y) / 2)
        if contains(center, in: polygon), distanceToBoundary(center, polygon: polygon) > 1e-9 { return center }
        let rings = [polygon.vertices] + polygon.holes
        var levels = [rectangle[0].y, rectangle[2].y]
        for ring in rings {
            levels.append(contentsOf: clip(ring, rectangle).map(\.y))
        }
        levels = Array(Set(levels.filter { $0.isFinite && $0 >= rectangle[0].y && $0 <= rectangle[2].y })).sorted()
        var best: MetricPoint2D?, width = -Double.infinity
        for index in 1..<levels.count where levels[index] > levels[index - 1] {
            let y = (levels[index] + levels[index - 1]) / 2; var crossings = [rectangle[0].x, rectangle[2].x]
            for ring in rings {
                for edge in ring.indices {
                    let a = ring[edge], b = ring[(edge + 1) % ring.count]
                    if (a.y > y) != (b.y > y) {
                        let x = a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)
                        if x > rectangle[0].x && x < rectangle[2].x { crossings.append(x) }
                    }
                }
            }
            crossings.sort()
            for pair in 1..<crossings.count {
                let point = MetricPoint2D(x: (crossings[pair] + crossings[pair - 1]) / 2, y: y)
                let span = crossings[pair] - crossings[pair - 1]
                if span > width, contains(point, in: polygon), distanceToBoundary(point, polygon: polygon) > 1e-9 { width = span; best = point }
            }
        }
        return best
    }
    private static func edgePassesRectangleInterior(_ a: MetricPoint2D, _ b: MetricPoint2D, _ rectangle: [MetricPoint2D]) -> Bool {
        var lower = 0.0, upper = 1.0
        for (origin, delta, minimum, maximum) in [(a.x, b.x - a.x, rectangle[0].x, rectangle[2].x),
                                                   (a.y, b.y - a.y, rectangle[0].y, rectangle[2].y)] {
            if delta == 0 { if origin < minimum || origin > maximum { return false }; continue }
            let first = (minimum - origin) / delta, second = (maximum - origin) / delta
            lower = max(lower, min(first, second)); upper = min(upper, max(first, second))
            if upper <= lower { return false }
        }
        let fraction = (lower + upper) / 2
        let x = a.x + fraction * (b.x - a.x), y = a.y + fraction * (b.y - a.y)
        return x > rectangle[0].x && x < rectangle[2].x && y > rectangle[0].y && y < rectangle[2].y
    }
    private static func segmentInside(_ a: MetricPoint2D, _ b: MetricPoint2D, polygon: MetricPolygon) -> Bool {
        var fractions = [0.0, 1.0]; let dx = b.x - a.x, dy = b.y - a.y
        for ring in [polygon.vertices] + polygon.holes {
            for index in ring.indices {
                let c = ring[index], d = ring[(index + 1) % ring.count], ex = d.x - c.x, ey = d.y - c.y
                let denominator = dx * ey - dy * ex
                if abs(denominator) < 1e-14 { continue }
                let qx = c.x - a.x, qy = c.y - a.y
                let t = (qx * ey - qy * ex) / denominator, u = (qx * dy - qy * dx) / denominator
                if t > 0 && t < 1 && u >= 0 && u <= 1 { fractions.append(t) }
            }
        }
        fractions.sort()
        return (1..<fractions.count).allSatisfy { index in
            let t = (fractions[index] + fractions[index - 1]) / 2
            return contains(.init(x: a.x + t * dx, y: a.y + t * dy), in: polygon)
        }
    }
    fileprivate static func segmentDistance(_ p: MetricPoint2D, _ a: MetricPoint2D, _ b: MetricPoint2D) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, square = dx * dx + dy * dy
        let t = square > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / square)) : 0
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
    fileprivate static func distanceToBoundary(_ point: MetricPoint2D, polygon: MetricPolygon) -> Double {
        ([polygon.vertices] + polygon.holes).reduce(Double.infinity) { minimum, ring in
            ring.indices.reduce(minimum) { min($0, segmentDistance(point, ring[$1], ring[($1 + 1) % ring.count])) }
        }
    }
}
