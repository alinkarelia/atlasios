import Foundation
import AtlasCore

enum CollaborativeSurveyStoreError: Error, LocalizedError {
    case revisionConflict, invalidDocument, tooLarge, invalidPath, staleImport
    var errorDescription: String? {
        switch self {
        case .revisionConflict: "План уже изменён или копии разошлись. Предыдущий файл сохранён. Обменяйтесь последней общей версией перед правкой."
        case .invalidDocument: "Файл совместной съёмки не прошёл проверку проекта, границы, истории или контрольной суммы."
        case .tooLarge: "План превышает 16 МБ. Предыдущий файл сохранён; продолжите отдельным этапом."
        case .invalidPath: "План должен находиться в управляемой папке проекта; ссылки и посторонние пути запрещены."
        case .staleImport: "Эта копия старее плана на iPhone. Новые данные не заменены."
        }
    }
}

struct CollaborativeSurveyRevisionStamp: Codable, Hashable, Sendable {
    let revision: Int64
    let planSHA256: String
    let parentSHA256: String?
}

/// A shared project plan, not a live server session. Device worker selection is
/// stored separately, so importing a colleague's JSON does not impersonate them.
struct CollaborativeSurveyStoredPlan: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let projectID: UUID
    let sourceFeatureID: UUID
    let sourceFeatureRevision: Int64
    let projectName: String?
    let projectKind: ProjectKind?
    /// Optional for older exchange documents. Preserve the actual source kind;
    /// a cemetery must not turn into a generic boundary on another phone.
    let sourceFeatureLabel: String?
    let sourceFeatureCategory: FeatureCategory?
    var plan: CollaborativeSurveyPlan
    var revisionStamps: [CollaborativeSurveyRevisionStamp]

    init(plan: CollaborativeSurveyPlan, sourceFeatureID: UUID, sourceFeatureRevision: Int64,
         projectName: String? = nil, projectKind: ProjectKind? = nil,
         sourceFeatureLabel: String? = nil, sourceFeatureCategory: FeatureCategory? = nil) throws {
        guard plan.revision == 0, sourceFeatureRevision >= 0 else { throw CollaborativeSurveyStoreError.invalidDocument }
        schemaVersion = 1; projectID = plan.projectID
        self.sourceFeatureID = sourceFeatureID; self.sourceFeatureRevision = sourceFeatureRevision
        self.projectName = projectName; self.projectKind = projectKind
        self.sourceFeatureLabel = sourceFeatureLabel; self.sourceFeatureCategory = sourceFeatureCategory
        self.plan = plan
        revisionStamps = [.init(revision: 0, planSHA256: try Self.digest(plan), parentSHA256: nil)]
        try validate()
    }
    var currentSHA256: String { revisionStamps.last?.planSHA256 ?? "" }
    static func digest(_ plan: CollaborativeSurveyPlan) throws -> String {
        FieldTransferDigest.sha256(try canonical(plan))
    }
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    func validate() throws {
        try plan.validate()
        guard schemaVersion == 1, projectID == plan.projectID, sourceFeatureRevision >= 0,
              projectName == nil || (projectName!.utf16.count <= 160 && !projectName!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              sourceFeatureLabel == nil || (sourceFeatureLabel!.utf16.count <= 160 && !sourceFeatureLabel!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              plan.revision <= 12_000, revisionStamps.count == Int(plan.revision) + 1,
              revisionStamps.last?.planSHA256 == (try Self.digest(plan)) else { throw CollaborativeSurveyStoreError.invalidDocument }
        for (index, stamp) in revisionStamps.enumerated() {
            guard stamp.revision == Int64(index), FieldTransferDigest.isSHA256(stamp.planSHA256),
                  stamp.parentSHA256 == (index > 0 ? revisionStamps[index - 1].planSHA256 : nil) else {
                throw CollaborativeSurveyStoreError.invalidDocument
            }
        }
    }
    mutating func append(_ next: CollaborativeSurveyPlan) throws {
        try next.validateTransition(from: plan)
        guard next != plan else { return }
        let parent = currentSHA256
        plan = next
        revisionStamps.append(.init(revision: next.revision, planSHA256: try Self.digest(next), parentSHA256: parent))
        try validate()
    }

    /// Fast-forward requires the same immutable plan and exact common history.
    /// Divergent branches are retained for a future reviewed server merge.
    func validateFastForward(from previous: Self) throws {
        try validate(); try previous.validate()
        guard schemaVersion == previous.schemaVersion, projectID == previous.projectID,
              sourceFeatureID == previous.sourceFeatureID, sourceFeatureRevision == previous.sourceFeatureRevision,
              projectName == previous.projectName, projectKind == previous.projectKind,
              sourceFeatureLabel == previous.sourceFeatureLabel, sourceFeatureCategory == previous.sourceFeatureCategory,
              plan.id == previous.plan.id, plan.revision >= previous.plan.revision,
              Array(revisionStamps.prefix(previous.revisionStamps.count)) == previous.revisionStamps else {
            throw CollaborativeSurveyStoreError.revisionConflict
        }
        if plan.revision == previous.plan.revision {
            guard self == previous else { throw CollaborativeSurveyStoreError.revisionConflict }; return
        }
        let a = plan, b = previous.plan
        guard a.schemaVersion == b.schemaVersion, a.createdAt == b.createdAt,
              a.coordinateReference == b.coordinateReference, a.sourceBoundary == b.sourceBoundary,
              a.sourceBoundarySHA256 == b.sourceBoundarySHA256, a.gridFrameID == b.gridFrameID,
              a.projection == b.projection, a.boundary == b.boundary,
              a.cellSizeMeters == b.cellSizeMeters, a.cells == b.cells, a.workers == b.workers,
              a.warnings == b.warnings,
              Array(a.evidence.prefix(b.evidence.count)) == b.evidence,
              Array(a.assignmentHistory.prefix(b.assignmentHistory.count)) == b.assignmentHistory else {
            throw CollaborativeSurveyStoreError.revisionConflict
        }
        let newAssignments = Array(a.assignmentHistory.dropFirst(b.assignmentHistory.count))
        guard newAssignments.allSatisfy({ $0.revision > b.revision }),
              Set(newAssignments.map(\.revision)).count == newAssignments.count else {
            throw CollaborativeSurveyStoreError.invalidDocument
        }
        var owners = Dictionary(uniqueKeysWithValues: a.assignments.map { ($0.cellID, $0.workerID) })
        for event in newAssignments.reversed() {
            guard event.cellIDs.allSatisfy({ owners[$0] == event.workerID }),
                  event.previousWorkerIDs.values.allSatisfy({ $0 != event.workerID }) else {
                throw CollaborativeSurveyStoreError.invalidDocument
            }
            for (cell, owner) in event.previousWorkerIDs { owners[cell] = owner }
        }
        guard owners == Dictionary(uniqueKeysWithValues: b.assignments.map { ($0.cellID, $0.workerID) }),
              a.revision - b.revision == Int64(a.evidence.count - b.evidence.count + newAssignments.count) else {
            throw CollaborativeSurveyStoreError.invalidDocument
        }
        let lastAssignment = a.assignmentHistory.last
        let latestTime = lastAssignment?.revision == a.revision ? lastAssignment?.timestamp : a.evidence.last?.timestamp
        guard a.updatedAt == latestTime else { throw CollaborativeSurveyStoreError.invalidDocument }
    }
}

struct CollaborativeSurveyExchange: Codable, Sendable {
    let schemaVersion: Int
    let document: CollaborativeSurveyStoredPlan
    let documentSHA256: String
    init(document: CollaborativeSurveyStoredPlan) throws {
        try document.validate(); schemaVersion = 1; self.document = document
        documentSHA256 = FieldTransferDigest.sha256(try CollaborativeSurveyStoredPlan.canonical(document))
    }
    func validate() throws {
        try document.validate()
        guard schemaVersion == 1,
              documentSHA256 == FieldTransferDigest.sha256(try CollaborativeSurveyStoredPlan.canonical(document)) else {
            throw CollaborativeSurveyStoreError.invalidDocument
        }
    }
}

struct CollaborativeSurveyImportPreview: Sendable {
    enum Disposition: Sendable { case newPlan, fastForward, mergeEvidence, unchanged }
    let document: CollaborativeSurveyStoredPlan
    let expectedSHA256: String?
    let additionalEvidenceCount: Int
    let disposition: Disposition
}

actor CollaborativeSurveyStore {
    static let maximumBytes = 16 * 1_024 * 1_024
    /// Screens and import entry points can own different actors. A process-wide
    /// recursive lock makes read/compare/atomic-write one transaction across
    /// those instances; no suspension occurs while it is held.
    private static let transactionLock = NSRecursiveLock()
    let projectID: UUID
    let reference: CoordinateReference
    let directory: URL
    init(projectID: UUID, reference: CoordinateReference, directory: URL) {
        self.projectID = projectID; self.reference = reference; self.directory = directory
    }
    var fileURL: URL { directory.appendingPathComponent(projectID.uuidString + ".team-plan.json") }
    func load() throws -> CollaborativeSurveyStoredPlan? {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        try checkPath()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Self.readBounded(fileURL)
        let document = try JSONDecoder().decode(CollaborativeSurveyStoredPlan.self, from: data)
        try verify(document); return document
    }
    func save(_ document: CollaborativeSurveyStoredPlan, expectedSHA256: String?) throws -> CollaborativeSurveyStoredPlan {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        try verify(document)
        let previous = try load()
        guard previous?.currentSHA256 == expectedSHA256 else { throw CollaborativeSurveyStoreError.revisionConflict }
        if let previous {
            guard document.sourceFeatureID == previous.sourceFeatureID,
                  document.sourceFeatureRevision == previous.sourceFeatureRevision,
                  document.projectName == previous.projectName, document.projectKind == previous.projectKind,
                  document.sourceFeatureLabel == previous.sourceFeatureLabel,
                  document.sourceFeatureCategory == previous.sourceFeatureCategory else { throw CollaborativeSurveyStoreError.revisionConflict }
            try document.plan.validateTransition(from: previous.plan)
            guard Array(document.revisionStamps.prefix(previous.revisionStamps.count)) == previous.revisionStamps else {
                throw CollaborativeSurveyStoreError.revisionConflict
            }
        } else {
            guard document.plan.revision == 0 else { throw CollaborativeSurveyStoreError.revisionConflict }
        }
        try write(document); return document
    }
    func importExchange(_ data: Data, expectedSHA256: String?) throws -> CollaborativeSurveyStoredPlan {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        let preview = try previewExchange(data, expectedSHA256: expectedSHA256)
        return try acceptImport(preview, expectedSHA256: expectedSHA256)
    }
    func previewExchange(_ data: Data, expectedSHA256: String?) throws -> CollaborativeSurveyImportPreview {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        let imported = try Self.decodeExchange(data, expectedProjectID: projectID)
        try verify(imported)
        let previous = try load()
        guard previous?.currentSHA256 == expectedSHA256 else { throw CollaborativeSurveyStoreError.revisionConflict }
        guard let previous else {
            return .init(document: imported, expectedSHA256: nil,
                         additionalEvidenceCount: imported.plan.evidence.count, disposition: .newPlan)
        }
        if imported == previous {
            return .init(document: previous, expectedSHA256: expectedSHA256, additionalEvidenceCount: 0, disposition: .unchanged)
        }
        guard imported.sourceFeatureID == previous.sourceFeatureID,
              imported.sourceFeatureRevision == previous.sourceFeatureRevision,
              imported.projectName == previous.projectName, imported.projectKind == previous.projectKind,
              imported.sourceFeatureLabel == previous.sourceFeatureLabel,
              imported.sourceFeatureCategory == previous.sourceFeatureCategory else {
            throw CollaborativeSurveyStoreError.revisionConflict
        }
        if imported.plan.assignments == previous.plan.assignments,
           imported.plan.assignmentHistory == previous.plan.assignmentHistory {
            var merged = previous.plan
            let added = try merged.mergeEvidence(from: imported.plan, expectedRevision: previous.plan.revision)
            var result = previous
            for item in merged.evidence.dropFirst(previous.plan.evidence.count) {
                var step = result.plan
                try step.recordEvidence(item, expectedRevision: step.revision)
                try result.append(step)
            }
            return .init(document: result, expectedSHA256: expectedSHA256, additionalEvidenceCount: added,
                         disposition: added == 0 ? .unchanged : .mergeEvidence)
        }
        guard imported.plan.revision >= previous.plan.revision else { throw CollaborativeSurveyStoreError.staleImport }
        try imported.validateFastForward(from: previous)
        return .init(document: imported, expectedSHA256: expectedSHA256,
                     additionalEvidenceCount: imported.plan.evidence.count - previous.plan.evidence.count,
                     disposition: .fastForward)
    }
    func acceptImport(_ preview: CollaborativeSurveyImportPreview, expectedSHA256: String?) throws -> CollaborativeSurveyStoredPlan {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        try verify(preview.document)
        let previous = try load()
        guard previous?.currentSHA256 == expectedSHA256, preview.expectedSHA256 == expectedSHA256 else {
            throw CollaborativeSurveyStoreError.revisionConflict
        }
        if let previous { try preview.document.validateFastForward(from: previous) }
        try write(preview.document); return preview.document
    }
    static func decodeExchange(_ data: Data, expectedProjectID: UUID? = nil) throws -> CollaborativeSurveyStoredPlan {
        guard !data.isEmpty, data.count <= maximumBytes else { throw CollaborativeSurveyStoreError.tooLarge }
        let exchange = try JSONDecoder().decode(CollaborativeSurveyExchange.self, from: data)
        try exchange.validate()
        guard expectedProjectID == nil || exchange.document.projectID == expectedProjectID else {
            throw CollaborativeSurveyStoreError.invalidDocument
        }
        return exchange.document
    }
    func exchangeData(_ document: CollaborativeSurveyStoredPlan) throws -> Data {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        try verify(document)
        guard let persisted = try load(), persisted == document else { throw CollaborativeSurveyStoreError.revisionConflict }
        let data = try CollaborativeSurveyStoredPlan.canonical(CollaborativeSurveyExchange(document: document))
        guard data.count <= Self.maximumBytes else { throw CollaborativeSurveyStoreError.tooLarge }
        return data
    }
    private func verify(_ document: CollaborativeSurveyStoredPlan) throws {
        try document.validate()
        guard document.projectID == projectID, document.plan.coordinateReference == reference else {
            throw CollaborativeSurveyStoreError.invalidDocument
        }
    }
    private func write(_ document: CollaborativeSurveyStoredPlan) throws {
        let data = try CollaborativeSurveyStoredPlan.canonical(document)
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw CollaborativeSurveyStoreError.tooLarge }
        try checkPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try checkPath()
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }
    private func checkPath() throws {
        guard directory.isFileURL, fileURL.isFileURL else { throw CollaborativeSurveyStoreError.invalidPath }
        let standardized = directory.standardizedFileURL
        guard standardized.path == standardized.resolvingSymlinksInPath().path,
              fileURL.standardizedFileURL.path == fileURL.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw CollaborativeSurveyStoreError.invalidPath
        }
        for path in [directory, fileURL] where FileManager.default.fileExists(atPath: path.path) {
            let type = try FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType
            guard type == (path == directory ? .typeDirectory : .typeRegular) else { throw CollaborativeSurveyStoreError.invalidPath }
        }
    }
    static func readBounded(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw CollaborativeSurveyStoreError.invalidPath }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0,
              bytes.int64Value <= Int64(maximumBytes) else { throw CollaborativeSurveyStoreError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw CollaborativeSurveyStoreError.tooLarge }
        }
        guard data.count == bytes.intValue else { throw CollaborativeSurveyStoreError.invalidDocument }
        return data
    }
}
