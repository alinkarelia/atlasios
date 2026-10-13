import Foundation
import AtlasCore

enum FragmentAssemblyError: String, Error, LocalizedError, Sendable {
    case invalidDocument, invalidPath, changedSource, missingDocument, revisionConflict, limit, unresolved, existingOutput
    var errorDescription: String? {
        switch self {
        case .invalidDocument: "Журнал сборки не прошёл проверку проекта, оригиналов или истории привязки."
        case .invalidPath: "Сборка работает только с управляемыми оригиналами этого проекта; ссылки и посторонние пути запрещены."
        case .changedSource: "Оригинал изменился после привязки. Прежняя матрица не будет применена к новым байтам."
        case .missingDocument: "Сначала выберите опорный фрагмент и создайте журнал сборки."
        case .revisionConflict: "Журнал уже изменён. Откройте последнюю версию; прежний файл сохранён."
        case .limit: "Предел локальной сборки достигнут: журнал 8 МБ, 128 оригиналов; производная OBJ 64 МБ, 400 000 вершин и 600 000 треугольников. Большие оригиналы сохранены отдельно."
        case .unresolved: "Выбранные фрагменты должны иметь подтверждённые непротиворечивые привязки к общей опоре."
        case .existingOutput: "Папка результата уже существует. Выберите новую папку, чтобы сохранить прежние файлы."
        }
    }
}

struct FragmentAssemblySourceBinding: Codable, Hashable, Sendable {
    let source: FragmentSourceReference
    let relativePath: String
    let byteCount: Int64
    let capturedAt: Date
    let gravityAlignedYUp: Bool
}

struct FragmentAssemblyDocument: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let projectID: UUID
    var registry: FragmentRegistrationRegistry
    var sourceBindings: [FragmentAssemblySourceBinding]
    var currentSHA256: String { (try? FieldTransferDigest.sha256(Self.canonical(self))) ?? "" }
    static func canonical<T: Encodable>(_ document: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }
    func validate() throws {
        try registry.validate()
        guard schemaVersion == 1, projectID == registry.projectID,
              !sourceBindings.isEmpty, sourceBindings.count <= 128,
              sourceBindings.map(\.source) == registry.fragments,
              Set(sourceBindings.map(\.relativePath)).count == sourceBindings.count else { throw FragmentAssemblyError.invalidDocument }
        let prefix = "Projects/\(projectID.uuidString)/Captures/"
        for binding in sourceBindings {
            try binding.source.validate(); try FieldTransferPaths.validate(relativePath: binding.relativePath)
            guard binding.relativePath.hasPrefix(prefix), binding.relativePath.lowercased().hasSuffix(".obj"),
                  !binding.relativePath.hasPrefix(prefix + "Collaboration/"),
                  binding.byteCount > 0, binding.byteCount <= 64 * 1_024 * 1_024,
                  binding.capturedAt.timeIntervalSinceReferenceDate.isFinite, binding.gravityAlignedYUp else {
                throw FragmentAssemblyError.invalidDocument
            }
        }
        // This native store only binds gravity-aligned ARKit OBJ originals.
        // An import with unknown axes may use Core separately, but cannot strip
        // the physical-up gate and still be approved as a native Y-up assembly.
        for record in registry.registrations where record.state == .approved {
            guard let gravity = record.candidate.gravityConstraint,
                  gravity.sourceUp == MetricPoint3D(x: 0, y: 1, z: 0),
                  gravity.targetUp == MetricPoint3D(x: 0, y: 1, z: 0), gravity.maximumDeviationDegrees <= 5 else {
                throw FragmentAssemblyError.invalidDocument
            }
        }
    }
    func validateTransition(from old: Self) throws {
        try old.validate(); try validate(); try registry.validateTransition(from: old.registry)
        guard schemaVersion == old.schemaVersion, projectID == old.projectID,
              Array(sourceBindings.prefix(old.sourceBindings.count)) == old.sourceBindings else { throw FragmentAssemblyError.invalidDocument }
    }
}

/// Local actor serialization plus an expected canonical SHA provides CAS.
/// SHA values identify content, not a server signature or an authenticated user.
actor FragmentAssemblyStore {
    static let maximumBytes = 8 * 1_024 * 1_024
    private static let mutationLock = NSLock()
    let projectID: UUID
    let assetDirectory: URL
    init(projectID: UUID, assetDirectory: URL) { self.projectID = projectID; self.assetDirectory = assetDirectory }
    var fileURL: URL { assetDirectory.appendingPathComponent("Projects/\(projectID.uuidString)/Captures/Collaboration/\(projectID.uuidString).assembly.json") }
    func load() throws -> FragmentAssemblyDocument? {
        try FragmentAssemblySourceVerifier.checkManagedPath(fileURL, root: assetDirectory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw FragmentAssemblyError.invalidPath }
        guard let size = values.fileSize, size > 0, size <= Self.maximumBytes else { throw FragmentAssemblyError.limit }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maximumBytes else { throw FragmentAssemblyError.limit }
        let document = try JSONDecoder().decode(FragmentAssemblyDocument.self, from: data)
        try document.validate()
        guard document.projectID == projectID else { throw FragmentAssemblyError.invalidDocument }
        return document
    }
    func bootstrap(scans: [ScanRecord], anchorCaptureID: UUID) throws -> FragmentAssemblyDocument {
        try Self.mutationLock.withLock {
        guard try load() == nil else { throw FragmentAssemblyError.revisionConflict }
        guard !scans.isEmpty, scans.count <= 128, Set(scans.map(\.id)).count == scans.count,
              let anchorScan = scans.first(where: { $0.id == anchorCaptureID }) else { throw FragmentAssemblyError.invalidDocument }
        let ordered = [anchorScan] + scans.filter { $0.id != anchorCaptureID }.sorted { $0.id.uuidString < $1.id.uuidString }
        let bindings = try ordered.map { try FragmentAssemblySourceVerifier.bind(scan: $0, projectID: projectID, root: assetDirectory) }
        var registry = try FragmentRegistrationRegistry(projectID: projectID, anchor: bindings[0].source)
        for binding in bindings.dropFirst() { try registry.addFragment(binding.source, expectedRevision: registry.revision) }
        let document = FragmentAssemblyDocument(schemaVersion: 1, projectID: projectID, registry: registry, sourceBindings: bindings)
        try write(document); return document
        }
    }
    func registerSource(scan: ScanRecord, expectedSHA256: String) throws -> FragmentAssemblyDocument {
        try Self.mutationLock.withLock {
        guard var document = try load() else { throw FragmentAssemblyError.missingDocument }
        guard document.currentSHA256 == expectedSHA256 else { throw FragmentAssemblyError.revisionConflict }
        guard document.sourceBindings.count < 128 else { throw FragmentAssemblyError.limit }
        let previous = document
        let binding = try FragmentAssemblySourceVerifier.bind(scan: scan, projectID: projectID, root: assetDirectory)
        try document.registry.addFragment(binding.source, expectedRevision: document.registry.revision)
        document.sourceBindings.append(binding)
        try document.validateTransition(from: previous); try write(document); return document
        }
    }
    func saveRegistry(_ registry: FragmentRegistrationRegistry, expectedSHA256: String) throws -> FragmentAssemblyDocument {
        try Self.mutationLock.withLock {
        guard var document = try load() else { throw FragmentAssemblyError.missingDocument }
        guard document.currentSHA256 == expectedSHA256 else { throw FragmentAssemblyError.revisionConflict }
        let previous = document; document.registry = registry
        guard registry.fragments == previous.registry.fragments else { throw FragmentAssemblyError.invalidDocument }
        try document.validateTransition(from: previous)
        // Re-read source hashes before persisting decisions, not only during final export.
        for binding in document.sourceBindings { _ = try FragmentAssemblySourceVerifier.verify(binding, projectID: projectID, root: assetDirectory) }
        try write(document); return document
        }
    }
    private func write(_ document: FragmentAssemblyDocument) throws {
        try document.validate()
        guard document.projectID == projectID else { throw FragmentAssemblyError.invalidDocument }
        let data = try FragmentAssemblyDocument.canonical(document)
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw FragmentAssemblyError.limit }
        try FragmentAssemblySourceVerifier.checkManagedPath(fileURL, root: assetDirectory)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FragmentAssemblySourceVerifier.checkManagedPath(fileURL, root: assetDirectory)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

enum FragmentAssemblySourceVerifier {
    static func bind(scan: ScanRecord, projectID: UUID, root: URL) throws -> FragmentAssemblySourceBinding {
        guard scan.projectID == projectID, scan.source == .liDAR, scan.status == .ready,
              scan.revision >= 0, scan.revision < Int64.max else { throw FragmentAssemblyError.invalidDocument }
        let meshes = scan.assets.filter { $0.kind == .mesh && $0.relativePath.lowercased().hasSuffix(".obj") }
        guard meshes.count == 1 else { throw FragmentAssemblyError.invalidDocument }
        let asset = meshes[0]
        let url = try resolve(asset.relativePath, projectID: projectID, root: root)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 64 * 1_024 * 1_024,
              Int64(size) == asset.byteCount else { throw FragmentAssemblyError.changedSource }
        let hash = try hashFile(url)
        guard asset.sha256 == nil || asset.sha256 == hash else { throw FragmentAssemblyError.changedSource }
        try verifyHeader(url, frameID: scan.frameID)
        let binding = FragmentAssemblySourceBinding(source: .init(captureID: scan.id, frameID: scan.frameID,
            sourceSHA256: hash, sourceVersion: scan.revision + 1), relativePath: asset.relativePath,
            byteCount: Int64(size), capturedAt: scan.createdAt, gravityAlignedYUp: true)
        _ = try verify(binding, projectID: projectID, root: root); return binding
    }
    @discardableResult static func verify(_ binding: FragmentAssemblySourceBinding, projectID: UUID, root: URL) throws -> URL {
        try binding.source.validate()
        let url = try resolve(binding.relativePath, projectID: projectID, root: root)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 64 * 1_024 * 1_024,
              Int64(size) == binding.byteCount, try hashFile(url) == binding.source.sourceSHA256 else { throw FragmentAssemblyError.changedSource }
        try verifyHeader(url, frameID: binding.source.frameID); return url
    }
    static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = FieldTransferDigest.Stream(), bytes = 0
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation(); bytes += chunk.count
            guard bytes <= 64 * 1_024 * 1_024 else { throw FragmentAssemblyError.limit }
            hash.update(chunk)
        }
        return hash.finalize()
    }
    static func resolve(_ path: String, projectID: UUID, root: URL) throws -> URL {
        try FieldTransferPaths.validate(relativePath: path)
        let prefix = "Projects/\(projectID.uuidString)/Captures/"
        guard path.hasPrefix(prefix), !path.hasPrefix(prefix + "Collaboration/"), path.lowercased().hasSuffix(".obj") else { throw FragmentAssemblyError.invalidPath }
        let url = root.appendingPathComponent(path)
        try checkManagedPath(url, root: root); return url
    }
    static func checkManagedPath(_ url: URL, root: URL) throws {
        guard url.isFileURL, root.isFileURL else { throw FragmentAssemblyError.invalidPath }
        let base = root.standardizedFileURL, destination = url.standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard destination.path.hasPrefix(prefix), destination.resolvingSymlinksInPath().path.hasPrefix(base.resolvingSymlinksInPath().path + "/") else {
            throw FragmentAssemblyError.invalidPath
        }
        let relative = String(destination.path.dropFirst(prefix.count))
        try FieldTransferPaths.validate(relativePath: relative)
        var current = base
        for part in relative.split(separator: "/") {
            current.appendPathComponent(String(part))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw FragmentAssemblyError.invalidPath }
        }
    }
    private static func verifyHeader(_ url: URL, frameID: UUID) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 256) ?? Data()
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        guard line == "# Atlas ARKit mesh. metres. Y up. local frame \(frameID.uuidString)" else { throw FragmentAssemblyError.invalidDocument }
    }
}
