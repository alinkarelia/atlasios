import Foundation
import CSQLite

public enum AtlasStoreError: Error, LocalizedError, Equatable, Sendable {
    case database(code: Int32, message: String)
    case unsupportedSchema(Int)
    case projectNotFound(UUID)
    case revisionConflict(entityID: UUID, expected: Int64, actual: Int64)
    case coordinateReferenceInUse
    case invalidRecord(String)
    case invalidAssetPath(String)

    public var errorDescription: String? {
        switch self {
        case let .database(code, _) where code == SQLITE_FULL: "Недостаточно свободного места. Освободите память устройства и повторите сохранение."
        case .database: "Не удалось записать данные проекта. Предыдущее сохранённое состояние доступно; повторите операцию."
        case .unsupportedSchema: "Этот проект создан более новой версией Atlas. Обновите приложение перед открытием."
        case .projectNotFound: "Проект не найден. Вернитесь к списку проектов и откройте его заново."
        case .revisionConflict: "Объект изменился после открытия карточки. Обновите данные перед сохранением."
        case .coordinateReferenceInUse: "В проекте уже есть геометрия. Смена системы координат требует преобразования существующих объектов."
        case let .invalidRecord(message): "Данные не удалось сохранить: \(message)."
        case .invalidAssetPath: "Путь к исходному файлу выходит за пределы проекта или имеет недопустимый формат."
        }
    }
}

/// The single owner of the SQLite connection. Every entity update and its outbox event
/// commit together; callers must retain the returned revision before editing again.
/// Date-bearing records are decoded from their committed payload, matching later reads
/// even when the compatible millisecond JSON format rounds a Date's Double value.
public actor AtlasStore {
    public static let schemaVersion = 4
    private let database: SQLiteDatabase

    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = FULL")
        try database.execute("PRAGMA busy_timeout = 5000")
        try Self.migrate(database)
    }

    public func projects() throws -> [AtlasProject] {
        try records("projects").sorted { $0.updatedAt > $1.updatedAt }
    }

    public func project(id: UUID) throws -> AtlasProject? { try record("projects", id: id) }

    @discardableResult
    public func saveProject(_ incoming: AtlasProject) throws -> AtlasProject {
        guard !incoming.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AtlasStoreError.invalidRecord("название проекта не должно быть пустым")
        }
        return try database.transaction {
            let existing: AtlasProject? = try record("projects", id: incoming.id)
            if let existing, existing.coordinateReference != incoming.coordinateReference {
                let count = try database.query("SELECT (SELECT count(*) FROM features WHERE project_id = ?) + (SELECT count(*) FROM floor_plans WHERE project_id = ?) + (SELECT count(*) FROM scans WHERE project_id = ?)",
                                               [.text(incoming.id.uuidString), .text(incoming.id.uuidString), .text(incoming.id.uuidString)]).first?.first?.integer ?? 0
                guard count == 0 else { throw AtlasStoreError.coordinateReferenceInUse }
            }
            var saved = incoming
            saved.revision = try nextRevision(id: incoming.id, expected: incoming.revision, existing: existing?.revision)
            saved.updatedAt = Date()
            let payload = try AtlasJSON.encode(saved)
            let persisted = try AtlasJSON.decode(AtlasProject.self, from: payload)
            try write("projects", id: saved.id, projectID: nil, revision: saved.revision, payload: payload)
            try enqueue(entityID: saved.id, projectID: saved.id, kind: .project, base: incoming.revision, revision: saved.revision, payload: payload)
            return persisted
        }
    }

    public func features(projectID: UUID) throws -> [AtlasFeature] { try records("features", projectID: projectID) }

    /// Retain operator edits after delivery acknowledgement, including rejected
    /// candidates and reversible removals. Results are chronological and bounded.
    public func featureHistory(featureID: UUID, projectID: UUID, limit: Int = 100, beforeRevision: Int64? = nil) throws -> [AtlasFeature] {
        guard (1...100).contains(limit) else { throw AtlasStoreError.invalidRecord("история ограничена 100 версиями за запрос") }
        if let beforeRevision, beforeRevision < 1 { throw AtlasStoreError.invalidRecord("курсор истории должен содержать положительную версию") }
        _ = try requireProject(projectID)
        var values: [SQLValue] = [.text(featureID.uuidString), .text(projectID.uuidString)]
        let cursor = beforeRevision == nil ? "" : " AND revision < ?"
        if let beforeRevision { values.append(.integer(beforeRevision)) }
        values.append(.integer(Int64(limit)))
        let rows = try database.query("SELECT payload FROM feature_revisions WHERE feature_id = ? AND project_id = ?" + cursor + " ORDER BY revision DESC LIMIT ?", values)
        return try rows.reversed().map { try AtlasJSON.decode(AtlasFeature.self, from: $0[0].data) }
    }

    @discardableResult
    public func saveFeature(_ incoming: AtlasFeature) throws -> AtlasFeature {
        try database.transaction {
            let project = try requireProject(incoming.projectID)
            try PolygonGeometry.validate(incoming.geometry, in: project.coordinateReference)
            try validateFeatureMetadata(incoming)
            let existing: AtlasFeature? = try record("features", id: incoming.id)
            guard existing == nil || existing?.projectID == incoming.projectID else {
                throw AtlasStoreError.invalidRecord("перенос объекта в другой проект требует отдельного импорта")
            }
            var saved = incoming
            saved.revision = try nextRevision(id: saved.id, expected: incoming.revision, existing: existing?.revision)
            let payload = try AtlasJSON.encode(saved)
            try write("features", id: saved.id, projectID: saved.projectID, revision: saved.revision, payload: payload)
            try database.execute("DELETE FROM cemetery_feature_links WHERE child_id = ?", [.text(saved.id.uuidString)])
            for parentID in try cemeteryParents(saved.attributes) {
                try database.execute("INSERT INTO cemetery_feature_links(child_id, parent_id, project_id) VALUES (?, ?, ?)",
                                     [.text(saved.id.uuidString), .text(parentID.uuidString), .text(saved.projectID.uuidString)])
            }
            try database.execute("INSERT INTO feature_revisions(feature_id, project_id, revision, payload) VALUES (?, ?, ?, ?)",
                                 [.text(saved.id.uuidString), .text(saved.projectID.uuidString), .integer(saved.revision), .blob(payload)])
            try enqueue(entityID: saved.id, projectID: saved.projectID, kind: .feature, base: incoming.revision, revision: saved.revision, payload: payload)
            return saved
        }
    }

    public func floorPlans(projectID: UUID) throws -> [AtlasFloorPlan] { try records("floor_plans", projectID: projectID) }

    @discardableResult
    public func saveFloorPlan(_ incoming: AtlasFloorPlan) throws -> AtlasFloorPlan {
        try database.transaction {
            _ = try requireProject(incoming.projectID)
            // Each RoomPlan session has its own origin. Alignment is a separate operation.
            try PolygonGeometry.validate(incoming, in: .localMeters(frameID: incoming.frameID))
            let existing: AtlasFloorPlan? = try record("floor_plans", id: incoming.id)
            guard existing == nil || existing?.projectID == incoming.projectID else {
                throw AtlasStoreError.invalidRecord("нельзя изменить принадлежность обмера к проекту")
            }
            try MeasurementPlanControl.validateApplications(incoming)
            if let existing { try MeasurementPlanControl.validateTransition(from: existing, to: incoming) }
            var saved = incoming
            saved.revision = try nextRevision(id: saved.id, expected: incoming.revision, existing: existing?.revision)
            let payload = try AtlasJSON.encode(saved)
            let persisted = try AtlasJSON.decode(AtlasFloorPlan.self, from: payload)
            try write("floor_plans", id: saved.id, projectID: saved.projectID, revision: saved.revision, payload: payload)
            try enqueue(entityID: saved.id, projectID: saved.projectID, kind: .floorPlan, base: incoming.revision, revision: saved.revision, payload: payload)
            return persisted
        }
    }

    public func scans(projectID: UUID) throws -> [ScanRecord] { try records("scans", projectID: projectID) }

    @discardableResult
    public func saveScan(_ incoming: ScanRecord) throws -> ScanRecord {
        try database.transaction {
            _ = try requireProject(incoming.projectID)
            if let tag = incoming.geoTag { try GeoTagPolicy.validate(tag) }
            for asset in incoming.assets {
                let parts = asset.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                guard !asset.relativePath.isEmpty, !asset.relativePath.hasPrefix("/"),
                      !asset.relativePath.contains("\\"), !asset.relativePath.contains("\0"),
                      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), asset.byteCount >= 0 else {
                    throw AtlasStoreError.invalidAssetPath(asset.relativePath)
                }
            }
            let existing: ScanRecord? = try record("scans", id: incoming.id)
            guard existing == nil || existing?.projectID == incoming.projectID else {
                throw AtlasStoreError.invalidRecord("нельзя изменить принадлежность скана к проекту")
            }
            var saved = incoming
            saved.revision = try nextRevision(id: saved.id, expected: incoming.revision, existing: existing?.revision)
            if let existing {
                try GeoTagPolicy.validateTransition(from: existing.geoTag, to: incoming.geoTag)
            }
            let payload = try AtlasJSON.encode(saved)
            let persisted = try AtlasJSON.decode(ScanRecord.self, from: payload)
            try write("scans", id: saved.id, projectID: saved.projectID, revision: saved.revision, payload: payload)
            try enqueue(entityID: saved.id, projectID: saved.projectID, kind: .scan, base: incoming.revision, revision: saved.revision, payload: payload)
            return persisted
        }
    }

    /// The read transaction makes the export internally consistent even with other DB connections.
    public func snapshot(projectID: UUID) throws -> AtlasProjectSnapshot {
        try database.transaction {
            try AtlasProjectSnapshot(project: requireProject(projectID), features: features(projectID: projectID),
                                     floorPlans: floorPlans(projectID: projectID), scans: scans(projectID: projectID))
        }
    }

    public func pendingOutbox(limit: Int = 100) throws -> [OutboxEvent] {
        guard limit > 0 else { return [] }
        return try database.query("SELECT payload FROM outbox ORDER BY sequence LIMIT ?", [.integer(Int64(min(limit, 10_000)))])
            .map { try AtlasJSON.decode(OutboxEvent.self, from: $0[0].data) }
    }

    /// Acknowledge only after a server accepts the same event ID. Calling this twice is safe.
    public func acknowledgeOutbox(eventIDs: [UUID]) throws {
        try database.transaction {
            for id in eventIDs { try database.execute("DELETE FROM outbox WHERE event_id = ?", [.text(id.uuidString)]) }
        }
    }

    /// A consistent SQLite backup. Asset files must be copied separately using their manifest.
    public func backupDatabase(to path: String) throws {
        let destination = try SQLiteDatabase(path: path)
        guard let backup = sqlite3_backup_init(destination.handle, "main", database.handle, "main") else {
            throw destination.failure()
        }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw destination.failure() }
    }

    private func requireProject(_ id: UUID) throws -> AtlasProject {
        guard let result: AtlasProject = try record("projects", id: id) else { throw AtlasStoreError.projectNotFound(id) }
        return result
    }

    private func nextRevision(id: UUID, expected: Int64, existing: Int64?) throws -> Int64 {
        let actual = existing ?? 0
        guard expected == actual else { throw AtlasStoreError.revisionConflict(entityID: id, expected: expected, actual: actual) }
        guard actual < Int64.max, actual >= 0 else { throw AtlasStoreError.invalidRecord("номер версии вышел за допустимый диапазон") }
        return actual + 1
    }

    private func record<T: Decodable>(_ table: String, id: UUID) throws -> T? {
        guard let row = try database.query("SELECT payload FROM \(table) WHERE id = ?", [.text(id.uuidString)]).first else { return nil }
        return try AtlasJSON.decode(T.self, from: row[0].data)
    }

    private func records<T: Decodable>(_ table: String, projectID: UUID? = nil) throws -> [T] {
        let sql = projectID == nil ? "SELECT payload FROM \(table) ORDER BY rowid" : "SELECT payload FROM \(table) WHERE project_id = ? ORDER BY rowid"
        return try database.query(sql, projectID.map { [.text($0.uuidString)] } ?? [])
            .map { try AtlasJSON.decode(T.self, from: $0[0].data) }
    }

    private func write(_ table: String, id: UUID, projectID: UUID?, revision: Int64, payload: Data) throws {
        if let projectID {
            try database.execute("INSERT INTO \(table)(id, project_id, revision, payload) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision, payload=excluded.payload",
                                 [.text(id.uuidString), .text(projectID.uuidString), .integer(revision), .blob(payload)])
        } else {
            try database.execute("INSERT INTO projects(id, revision, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision, payload=excluded.payload",
                                 [.text(id.uuidString), .integer(revision), .blob(payload)])
        }
    }

    private func enqueue(entityID: UUID, projectID: UUID, kind: SyncEntityKind, base: Int64, revision: Int64, payload: Data) throws {
        let event = OutboxEvent(entityID: entityID, projectID: projectID, entityKind: kind, baseRevision: base, revision: revision, payload: payload)
        try database.execute("INSERT INTO outbox(event_id, payload) VALUES (?, ?)", [.text(event.id.uuidString), .blob(try AtlasJSON.encode(event))])
    }

    private func validateFeatureMetadata(_ feature: AtlasFeature) throws {
        guard !feature.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              feature.label.utf16.count <= 160, feature.notes.utf16.count <= 4096,
              feature.attributes.count <= 64 else { throw AtlasStoreError.invalidRecord("название, заметки или атрибуты объекта превышают допустимый размер") }
        for (key, value) in feature.attributes {
            guard !key.isEmpty, key.utf16.count <= 80, value.utf16.count <= 2048,
                  !["__proto__", "constructor", "prototype"].contains(key) else {
                throw AtlasStoreError.invalidRecord("недопустимое имя или размер атрибута объекта")
            }
        }
        for parentID in try cemeteryParents(feature.attributes) {
            guard parentID != feature.id else {
                throw AtlasStoreError.invalidRecord("родительское кладбище должно иметь корректный отдельный идентификатор")
            }
            // A partial archive may carry an unresolved parent, but an existing
            // parent may never point into a different project or object category.
            if let parent: AtlasFeature = try record("features", id: parentID) {
                guard parent.projectID == feature.projectID, parent.category == .cemetery else {
                    throw AtlasStoreError.invalidRecord("родительское кладбище относится к другому проекту или типу объекта")
                }
            }
        }
        let incompatibleChildren = try database.query("SELECT count(*) FROM cemetery_feature_links WHERE parent_id = ? AND child_id <> ? AND (project_id <> ? OR ? <> 'cemetery')",
                                                       [.text(feature.id.uuidString), .text(feature.id.uuidString), .text(feature.projectID.uuidString), .text(feature.category.rawValue)]).first?.first?.integer ?? 0
        guard incompatibleChildren == 0 else {
            throw AtlasStoreError.invalidRecord("объекты уже ссылаются на это кладбище: нельзя менять его тип или создавать родителя в другом проекте")
        }
    }

    private func cemeteryParents(_ attributes: [String:String]) throws -> Set<UUID> {
        var parents = Set<UUID>()
        for key in [CemeteryAttribute.cemeteryID,CemeteryAttribute.legacyParentCemeteryID] {
            if let text = attributes[key] {
                guard let parent = UUID(uuidString:text) else { throw AtlasStoreError.invalidRecord("недопустимый идентификатор родительского кладбища") }
                parents.insert(parent)
            }
        }
        guard parents.count <= 1 else { throw AtlasStoreError.invalidRecord("карточка ссылается на два разных родительских кладбища") }
        return parents
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        let version = Int(try database.query("PRAGMA user_version").first?.first?.integer ?? 0)
        guard version <= schemaVersion else { throw AtlasStoreError.unsupportedSchema(version) }
        if version < 1 {
            try database.transaction {
                try database.execute("CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL, payload BLOB NOT NULL)")
                for table in ["features", "floor_plans", "scans"] {
                    try database.execute("CREATE TABLE \(table) (id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, revision INTEGER NOT NULL, payload BLOB NOT NULL)")
                    try database.execute("CREATE INDEX \(table)_project ON \(table)(project_id)")
                }
                try database.execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try database.transaction {
                try database.execute("CREATE TABLE outbox (sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT UNIQUE NOT NULL, payload BLOB NOT NULL)")
                try database.execute("PRAGMA user_version = 2")
            }
        }
        if version < 3 {
            try database.transaction {
                try database.execute("CREATE TABLE feature_revisions (feature_id TEXT NOT NULL REFERENCES features(id) ON DELETE CASCADE, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, revision INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(feature_id, revision))")
                try database.execute("CREATE INDEX feature_revisions_project ON feature_revisions(project_id)")
                try database.execute("INSERT INTO feature_revisions(feature_id, project_id, revision, payload) SELECT id, project_id, revision, payload FROM features")
                try database.execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try database.transaction {
                try database.execute("CREATE TABLE cemetery_feature_links (child_id TEXT NOT NULL REFERENCES features(id) ON DELETE CASCADE, parent_id TEXT NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, PRIMARY KEY(child_id, parent_id))")
                try database.execute("CREATE INDEX cemetery_feature_links_parent ON cemetery_feature_links(parent_id)")
                // Existing records remain byte-for-byte unchanged. Seed each valid
                // canonical/legacy reference, even if an older card was ambiguous;
                // later edits must explicitly repair it before changing a parent.
                var cursor: String?
                while true {
                    let rows = try database.query("SELECT id, project_id, payload FROM features" + (cursor == nil ? "" : " WHERE id > ?") + " ORDER BY id LIMIT 32",
                                                  cursor.map { [.text($0)] } ?? [])
                    if rows.isEmpty { break }
                    for row in rows {
                        guard case let .text(childID) = row[0], case let .text(projectID) = row[1] else {
                            throw AtlasStoreError.invalidRecord("повреждённый идентификатор сохранённой карточки")
                        }
                        cursor = childID
                        guard let feature = try? AtlasJSON.decode(AtlasFeature.self, from:row[2].data) else { continue }
                        let parents = Set([CemeteryAttribute.cemeteryID,CemeteryAttribute.legacyParentCemeteryID].compactMap {
                            feature.attributes[$0].flatMap(UUID.init(uuidString:))
                        })
                        for parent in parents {
                            try database.execute("INSERT OR IGNORE INTO cemetery_feature_links(child_id,parent_id,project_id) VALUES (?, ?, ?)",
                                                 [.text(childID),.text(parent.uuidString),.text(projectID)])
                        }
                    }
                }
                try database.execute("PRAGMA user_version = 4")
            }
        }
    }
}

enum AtlasJSON {
    static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

enum SQLValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
    var integer: Int64? { if case let .integer(value) = self { return value }; return nil }
    var data: Data { if case let .blob(value) = self { return value }; return Data() }
}

/// A database pointer is confined to its owning actor. FULLMUTEX and close_v2
/// also make teardown safe for the project store and independent transfer queue.
final class SQLiteDatabase: @unchecked Sendable {
    let handle: OpaquePointer

    init(path: String) throws {
        var pointer: OpaquePointer?
        let code = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open SQLite database"
            if let pointer { sqlite3_close_v2(pointer) }
            throw AtlasStoreError.database(code: code, message: message)
        }
        handle = pointer
    }
    deinit { sqlite3_close_v2(handle) }
    func failure() -> AtlasStoreError { .database(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle))) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws { _ = try query(sql, values) }

    func query(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let code: Int32
            switch value {
            case let .text(value): code = sqlite3_bind_text(statement, index, value, -1, transient)
            case let .integer(value): code = sqlite3_bind_int64(statement, index, value)
            case let .real(value): code = sqlite3_bind_double(statement, index, value)
            case let .blob(value): code = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw failure() }
        }
        var rows: [[SQLValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw failure() }
            var row: [SQLValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, column) { row.append(.text(String(cString: text))) }
                    else { row.append(.null) }
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column) { row.append(.blob(Data(bytes: bytes, count: length))) }
                    else { row.append(.blob(Data())) }
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
    }
}
