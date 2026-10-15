import Foundation

/// A separate SQLite/WAL database keeps packages, preferences, consent and
/// acknowledged offsets durable together. No original files are deleted here.
public actor FieldTransferQueue {
    public static let schemaVersion = 1
    public static let maximumRecords = 10_000
    private let database: SQLiteDatabase

    public init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        database = try SQLiteDatabase(path: path)
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = FULL")
        try database.execute("PRAGMA busy_timeout = 5000")
        let version = Int(try database.query("PRAGMA user_version").first?.first?.integer ?? 0)
        guard version <= Self.schemaVersion else { throw FieldTransferError.unsupportedSchema(version) }
        if version == 0 {
            try database.transaction {
                try database.execute("CREATE TABLE transfer_settings (scope_key TEXT NOT NULL, project_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(scope_key, project_id))")
                try database.execute("CREATE TABLE field_transfers (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, scope_key TEXT NOT NULL, project_id TEXT NOT NULL, state TEXT NOT NULL, payload BLOB NOT NULL)")
                try database.execute("CREATE INDEX field_transfers_scope ON field_transfers(scope_key, project_id, state)")
                try database.execute("PRAGMA user_version = 1")
            }
        }
        // A process termination is not confirmation of delivery. Preserve every
        // server-acknowledged byte and reconcile with GET status before resuming.
        try database.transaction {
            for row in try database.query("SELECT payload FROM field_transfers WHERE state = 'uploading'") {
                var record = try Self.decodeRecord(row[0].data)
                record.state = .queued; record.nextRetryAt = nil
                try Self.write(record, database: database)
            }
        }
    }

    public func settings(projectID: UUID, scope: FieldTransferScope) throws -> FieldTransferSettings {
        try scope.validate()
        guard let row = try database.query("SELECT payload FROM transfer_settings WHERE scope_key = ? AND project_id = ?", [.text(scope.key), .text(projectID.uuidString)]).first else {
            return FieldTransferSettings()
        }
        return try FieldTransferJSON.decode(FieldTransferSettings.self, from: row[0].data)
    }

    public func setSettings(_ settings: FieldTransferSettings, projectID: UUID, scope: FieldTransferScope) throws {
        try scope.validate()
        try database.transaction {
            try database.execute("INSERT INTO transfer_settings(scope_key, project_id, payload) VALUES (?, ?, ?) ON CONFLICT(scope_key, project_id) DO UPDATE SET payload = excluded.payload",
                                 [.text(scope.key), .text(projectID.uuidString), .blob(try FieldTransferJSON.encode(settings))])
            for row in try database.query("SELECT payload FROM field_transfers WHERE scope_key = ? AND project_id = ?", [.text(scope.key), .text(projectID.uuidString)]) {
                var record = try Self.decodeRecord(row[0].data)
                if settings.policy == .automatic, record.state == .ready {
                    record.state = .queued; record.queuedAt = record.queuedAt ?? Date()
                } else if settings.policy == .manual, !record.explicitlyRequested,
                          [.queued, .waiting, .uploading].contains(record.state) {
                    record.state = .ready; record.nextRetryAt = nil
                }
                try Self.write(record, database: database)
            }
        }
    }

    /// Registering the identical package twice is safe. Reusing an ID for new
    /// contents or a different destination is rejected without modifying it.
    @discardableResult
    public func register(manifest: FieldTransferManifest, scope: FieldTransferScope) throws -> FieldTransferRecord {
        try manifest.validate(); try scope.validate()
        let payload = try FieldTransferJSON.encode(manifest)
        let normalized = try FieldTransferJSON.decode(FieldTransferManifest.self, from: payload)
        let digest = FieldTransferDigest.sha256(payload)
        return try database.transaction {
            if let existing = try record(id: manifest.id) {
                guard existing.scope == scope, existing.manifestSHA256 == digest else { throw FieldTransferError.immutableManifest }
                return existing
            }
            let count = try database.query("SELECT COUNT(*) FROM field_transfers").first?.first?.integer ?? 0
            guard count < Self.maximumRecords else { throw FieldTransferError.queueCapacity }
            let preferences = try settings(projectID: manifest.projectID, scope: scope)
            let automatic = preferences.policy == .automatic
            let value = FieldTransferRecord(id: normalized.id, scope: scope, manifest: normalized, manifestSHA256: digest,
                                            state: automatic ? .queued : .ready, explicitlyRequested: false,
                                            queuedAt: automatic ? Date() : nil, uploadedBytesByAsset: [:],
                                            attemptCount: 0, nextRetryAt: nil, lastError: nil, completedAt: nil, serverReceiptID: nil)
            try database.execute("INSERT INTO field_transfers(id, scope_key, project_id, state, payload) VALUES (?, ?, ?, ?, ?)",
                                 [.text(value.id.uuidString), .text(scope.key), .text(value.manifest.projectID.uuidString), .text(value.state.rawValue), .blob(try FieldTransferJSON.encode(value))])
            return try requireRecord(id: value.id)
        }
    }

    public func record(id: UUID) throws -> FieldTransferRecord? {
        guard let row = try database.query("SELECT payload FROM field_transfers WHERE id = ?", [.text(id.uuidString)]).first else { return nil }
        return try Self.decodeRecord(row[0].data)
    }

    public func records(projectID: UUID? = nil, scope: FieldTransferScope? = nil, limit: Int = 200, offset: Int = 0) throws -> [FieldTransferRecord] {
        if let scope { try scope.validate() }
        var filters: [String] = [], values: [SQLValue] = []
        if let projectID { filters.append("project_id = ?"); values.append(.text(projectID.uuidString)) }
        if let scope { filters.append("scope_key = ?"); values.append(.text(scope.key)) }
        let clause = filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND ")
        values.append(.integer(Int64(max(0, min(limit, Self.maximumRecords)))))
        values.append(.integer(Int64(max(0, offset))))
        return try database.query("SELECT payload FROM field_transfers" + clause + " ORDER BY sequence DESC LIMIT ? OFFSET ?", values).map { try Self.decodeRecord($0[0].data) }
    }

    /// Explicit operator consent is durable and applies only to this destination.
    /// Calling it again retries failed/paused packages without duplicating them.
    public func requestSend(projectID: UUID, scope: FieldTransferScope, transferIDs: [UUID]? = nil) throws {
        try scope.validate()
        try database.transaction {
            let chosen = transferIDs.map(Set.init)
            let candidates = try records(projectID: projectID, scope: scope, limit: Self.maximumRecords)
            if let chosen, !chosen.isSubset(of: Set(candidates.map(\.id))) { throw FieldTransferError.invalidScope }
            for var record in candidates where chosen == nil || chosen!.contains(record.id) {
                guard record.state != .completed, record.state != .uploading, record.state != .conflict else { continue }
                record.explicitlyRequested = true; record.state = .queued
                record.queuedAt = record.queuedAt ?? Date(); record.nextRetryAt = nil; record.lastError = nil
                try Self.write(record, database: database)
            }
        }
    }

    public func pending(scope: FieldTransferScope, network: TransferNetwork, now: Date = Date(), limit: Int = 20,
                        allowedProjectIDs: Set<UUID>? = nil) throws -> [FieldTransferRecord] {
        try scope.validate()
        guard network != .offline, now.timeIntervalSince1970.isFinite, limit > 0 else { return [] }
        let rows = try database.query("SELECT payload FROM field_transfers WHERE scope_key = ? AND state IN ('queued', 'waiting') ORDER BY sequence", [.text(scope.key)])
        var result: [FieldTransferRecord] = []
        for row in rows {
            let record = try Self.decodeRecord(row[0].data)
            if let allowedProjectIDs, !allowedProjectIDs.contains(record.manifest.projectID) { continue }
            let preferences = try settings(projectID: record.manifest.projectID, scope: scope)
            guard record.explicitlyRequested || preferences.policy == .automatic,
                  !preferences.wifiOnly || network == .wifi,
                  record.nextRetryAt == nil || record.nextRetryAt! <= now else { continue }
            result.append(record)
            if result.count >= min(limit, Self.maximumRecords) { break }
        }
        return result
    }

    /// Claims one package atomically; multiple callers cannot start the same
    /// package concurrently. Network and preference eligibility is checked here.
    public func claimNext(scope: FieldTransferScope, network: TransferNetwork, now: Date = Date(),
                          allowedProjectIDs: Set<UUID>? = nil) throws -> FieldTransferRecord? {
        try database.transaction {
            guard var record = try pending(scope: scope, network: network, now: now, limit: 1, allowedProjectIDs: allowedProjectIDs).first else { return nil }
            record.state = .uploading; record.attemptCount = min(1_000_000, record.attemptCount + 1)
            record.nextRetryAt = nil; record.lastError = nil
            try Self.write(record, database: database)
            return try requireRecord(id: record.id)
        }
    }

    @discardableResult
    public func markUploading(id: UUID) throws -> FieldTransferRecord {
        try mutate(id: id) { record in
            guard [.queued, .waiting].contains(record.state) else { throw FieldTransferError.invalidTransition }
            record.state = .uploading; record.attemptCount = min(1_000_000, record.attemptCount + 1)
            record.nextRetryAt = nil; record.lastError = nil
        }
    }

    @discardableResult
    public func recordAcknowledgedOffset(id: UUID, assetID: UUID, offset: Int64) throws -> FieldTransferRecord {
        try updateOffset(id: id, assetID: assetID, offset: offset, allowDecrease: false)
    }

    /// Only a fresh authenticated GET status should supply this offset. A server
    /// may have lost an unfinalized chunk; resend those bytes rather than guessing.
    @discardableResult
    public func reconcileAcknowledgedOffset(id: UUID, assetID: UUID, offset: Int64) throws -> FieldTransferRecord {
        try updateOffset(id: id, assetID: assetID, offset: offset, allowDecrease: true)
    }

    @discardableResult
    public func markFailed(id: UUID, message: String, retryable: Bool, now: Date = Date()) throws -> FieldTransferRecord {
        try mutate(id: id) { record in
            guard record.state != .completed else { throw FieldTransferError.invalidTransition }
            // A late callback from a cancelled request cannot restart a paused
            // package or override the operator's newly chosen manual policy.
            guard record.state != .paused, record.state != .ready else { return }
            record.state = retryable ? .waiting : .failed
            record.lastError = String(message.prefix(1_000))
            record.nextRetryAt = retryable ? now.addingTimeInterval(min(300, pow(2, Double(min(9, max(1, record.attemptCount)))))) : nil
        }
    }

    @discardableResult
    public func markConflict(id: UUID, message: String) throws -> FieldTransferRecord {
        try mutate(id: id) { record in
            guard record.state != .completed else { throw FieldTransferError.invalidTransition }
            record.state = .conflict; record.lastError = String(message.prefix(1_000)); record.nextRetryAt = nil
        }
    }

    @discardableResult
    public func markCompleted(id: UUID, serverReceiptID: String, completedAt: Date = Date()) throws -> FieldTransferRecord {
        try mutate(id: id) { record in
            if record.state == .completed {
                guard record.serverReceiptID == serverReceiptID else { throw FieldTransferError.invalidTransition }
                return
            }
            guard record.state == .uploading, !serverReceiptID.isEmpty, serverReceiptID.count <= 240,
                  completedAt.timeIntervalSince1970.isFinite else { throw FieldTransferError.invalidTransition }
            guard record.manifest.assets.allSatisfy({ record.uploadedBytesByAsset[$0.id, default: 0] == $0.byteCount }) else {
                throw FieldTransferError.incompleteAssets
            }
            record.state = .completed; record.serverReceiptID = serverReceiptID; record.completedAt = completedAt
            record.nextRetryAt = nil; record.lastError = nil
        }
    }

    @discardableResult
    public func pause(id: UUID) throws -> FieldTransferRecord {
        try mutate(id: id) { record in
            guard record.state != .completed else { return }
            record.state = .paused; record.nextRetryAt = nil
        }
    }

    public func pauseProject(projectID: UUID, scope: FieldTransferScope) throws {
        try database.transaction {
            for var record in try records(projectID: projectID, scope: scope, limit: Self.maximumRecords) where record.state != .completed {
                record.state = .paused; record.nextRetryAt = nil
                try Self.write(record, database: database)
            }
        }
    }

    /// Removes a local queue entry only. Completed packages can be removed from
    /// the list too; this does not delete either remote material or local originals.
    public func removeQueued(id: UUID) throws {
        try database.transaction {
            guard let record = try record(id: id) else { return }
            guard record.state != .uploading else { throw FieldTransferError.invalidTransition }
            try database.execute("DELETE FROM field_transfers WHERE id = ?", [.text(id.uuidString)])
        }
    }

    private func updateOffset(id: UUID, assetID: UUID, offset: Int64, allowDecrease: Bool) throws -> FieldTransferRecord {
        try mutate(id: id) { record in
            guard record.state != .completed, let asset = record.manifest.assets.first(where: { $0.id == assetID }),
                  offset >= 0, offset <= asset.byteCount,
                  allowDecrease || offset >= record.uploadedBytesByAsset[assetID, default: 0] else { throw FieldTransferError.invalidOffset }
            record.uploadedBytesByAsset[assetID] = offset
        }
    }

    private func requireRecord(id: UUID) throws -> FieldTransferRecord {
        guard let value = try record(id: id) else { throw FieldTransferError.transferNotFound(id) }
        return value
    }

    private func mutate(id: UUID, _ mutation: (inout FieldTransferRecord) throws -> Void) throws -> FieldTransferRecord {
        try database.transaction {
            var value = try requireRecord(id: id)
            try mutation(&value)
            try Self.write(value, database: database)
            return try requireRecord(id: id)
        }
    }

    private static func write(_ record: FieldTransferRecord, database: SQLiteDatabase) throws {
        try database.execute("UPDATE field_transfers SET state = ?, payload = ? WHERE id = ?", [.text(record.state.rawValue), .blob(try FieldTransferJSON.encode(record)), .text(record.id.uuidString)])
    }

    private static func decodeRecord(_ data: Data) throws -> FieldTransferRecord {
        guard data.count <= 2_097_152 else { throw FieldTransferError.invalidManifest }
        let record = try FieldTransferJSON.decode(FieldTransferRecord.self, from: data)
        try record.manifest.validate(); try record.scope.validate()
        guard record.id == record.manifest.id, record.attemptCount >= 0,
              record.manifestSHA256 == FieldTransferDigest.sha256(try FieldTransferJSON.encode(record.manifest)),
              record.uploadedBytesByAsset.count <= record.manifest.assets.count else { throw FieldTransferError.invalidManifest }
        let sizes = Dictionary(uniqueKeysWithValues: record.manifest.assets.map { ($0.id, $0.byteCount) })
        guard record.uploadedBytesByAsset.allSatisfy({ key, offset in sizes[key].map { offset >= 0 && offset <= $0 } ?? false }) else {
            throw FieldTransferError.invalidOffset
        }
        return record
    }
}
