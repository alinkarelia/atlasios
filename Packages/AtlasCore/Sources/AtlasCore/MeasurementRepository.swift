import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Local, append-history-safe measurements. Atomic writes happen before publication.
/// The file is also locked across repository instances to prevent lost updates.
public actor MeasurementRepository {
    private let fileURL: URL
    private let lockURL: URL
    private var records: [MeasurementRecord]
    private static let schemaVersion = 1
    private static let maximumBytes = 25 * 1024 * 1024
    private static let maximumRecords = 100_000

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dataURL = directory.appendingPathComponent("measurements.atlas.json", isDirectory: false)
        let mutexURL = directory.appendingPathComponent("measurements.lock", isDirectory: false)
        let loaded = try Self.withLock(at: mutexURL) { try Self.read(at: dataURL) }
        fileURL = dataURL
        lockURL = mutexURL
        records = loaded
    }

    public func measurements(projectID: UUID) -> [MeasurementRecord] {
        records.filter { $0.projectID == projectID }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Callers submit their last observed revision; immutable originals and the
    /// complete prefix of committed corrections must match the current record.
    public func save(_ submitted: MeasurementRecord) throws -> MeasurementRecord {
        try MeasurementPolicy.validate(submitted)
        let committed = try Self.withLock(at: lockURL) {
            var latest = try Self.read(at: fileURL)
            var saved = submitted
            if let index = latest.firstIndex(where: { $0.id == submitted.id }) {
                let current = latest[index]
                guard submitted.revision == current.revision else {
                    throw MeasurementError.revisionConflict(entityID: current.id,
                        expected: submitted.revision, actual: current.revision)
                }
                try MeasurementPolicy.validateTransition(from: current, to: submitted)
                guard current.revision < Int64.max else { throw MeasurementError.revisionOverflow }
                saved.revision = current.revision + 1
                latest[index] = saved
            } else {
                guard submitted.revision == 0 else { throw MeasurementError.invalidRevision }
                guard latest.count < Self.maximumRecords else { throw MeasurementError.storageLimitExceeded }
                saved.revision = 1
                latest.append(saved)
            }
            try Self.write(latest, to: fileURL)
            return (saved, latest)
        }
        records = committed.1
        return committed.0
    }

    /// Reload is explicit: a corrupt or newer file cannot quietly replace the cache.
    public func reload() throws {
        let latest = try Self.withLock(at: lockURL) { try Self.read(at: fileURL) }
        records = latest
    }

    private struct SchemaHeader: Decodable { var schemaVersion: Int }
    private struct Document: Codable {
        var schemaVersion: Int
        var records: [MeasurementRecord]
    }

    private static func read(at url: URL) throws -> [MeasurementRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MeasurementError.invalidStoredData
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw MeasurementError.storageLimitExceeded
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw MeasurementError.storageLimitExceeded }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let header: SchemaHeader
        do { header = try decoder.decode(SchemaHeader.self, from: data) }
        catch { throw MeasurementError.invalidStoredData }
        guard header.schemaVersion == schemaVersion else { throw MeasurementError.unsupportedSchema(header.schemaVersion) }
        let document: Document
        do { document = try decoder.decode(Document.self, from: data) }
        catch { throw MeasurementError.invalidStoredData }
        guard document.records.count <= maximumRecords else { throw MeasurementError.storageLimitExceeded }
        var ids = Set<UUID>()
        for record in document.records {
            guard ids.insert(record.id).inserted, record.revision > 0 else { throw MeasurementError.invalidStoredData }
            do { try MeasurementPolicy.validate(record) }
            catch { throw MeasurementError.invalidStoredData }
        }
        return document.records
    }

    private static func write(_ records: [MeasurementRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Foundation's native date number retains subseconds in immutable audit data.
        encoder.dateEncodingStrategy = .deferredToDate
        let document = Document(schemaVersion: schemaVersion,
            records: records.sorted { $0.id.uuidString < $1.id.uuidString })
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw MeasurementError.storageLimitExceeded }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }

    private static func withLock<T>(at url: URL, operation: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw MeasurementError.lockingFailed }
        defer { _ = close(descriptor) }
        // Return an actionable error if another writer owns the file; never block UI.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw MeasurementError.lockingFailed }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
