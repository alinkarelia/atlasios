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
    public static let schemaVersion = 2
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

    @discardableResult
    public func saveFeature(_ incoming: AtlasFeature) throws -> AtlasFeature {
        try database.transaction {
            let project = try requireProject(incoming.projectID)
            try PolygonGeometry.validate(incoming.geometry, in: project.coordinateReference)
            let existing: AtlasFeature? = try record("features", id: incoming.id)
            guard existing == nil || existing?.projectID == incoming.projectID else {
                throw AtlasStoreError.invalidRecord("перенос объекта в другой проект требует отдельного импорта")
            }
            var saved = incoming
            saved.revision = try nextRevision(id: saved.id, expected: incoming.revision, existing: existing?.revision)
            let payload = try AtlasJSON.encode(saved)
            try write("features", id: saved.id, projectID: saved.projectID, revision: saved.revision, payload: payload)
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
