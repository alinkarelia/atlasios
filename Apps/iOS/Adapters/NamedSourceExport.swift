import Foundation
#if !ATLAS_SOURCE_EXPORT_CHECKS
import AtlasCore
#endif

enum NamedSourceExportError: Error, LocalizedError, Equatable {
    case unsafePath, invalidSource, tooLarge, sourceChanged, insufficientStorage

    var errorDescription: String? {
        switch self {
        case .unsafePath: "Файл находится вне папки съёмок или путь содержит символическую ссылку."
        case .invalidSource: "Для отправки нужен завершённый обычный файл исходника."
        case .tooLarge: "Выбрано слишком много материалов или превышен допустимый объём."
        case .sourceChanged: "Исходник изменился во время подготовки. Дождитесь завершения съёмки и повторите отправку."
        case .insufficientStorage: "Недостаточно места для безопасной подготовки копии. Исходник сохранён."
        }
    }
}

/// Off-main preparation of readable names for FINALIZED immutable originals.
/// Hardlinks retain bytes without duplicating large videos/models. A later
/// in-place edit of a hardlinked original would also edit its alias: callers
/// must only pass closed capture files, never active recording/checkpoint files.
/// `captureRoot` is the project's full Captures directory, not a scan subfolder.
actor NamedSourceExport {
    static let maximumFiles = 512
    static let maximumFileBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    static let maximumTotalBytes: Int64 = 16 * 1_024 * 1_024 * 1_024

    func prepareResult(sources: [URL], captureRoot: URL, projectName: String, projectID: UUID,
                       sourceID: UUID, capturedAt: Date?, manifestURL: URL? = nil) async throws -> NamedSourceExportResult {
        try Task.checkCancellation()
        guard !sources.isEmpty, sources.count <= Self.maximumFiles else { throw NamedSourceExportError.tooLarge }
        try validateURL(captureRoot)
        let requestedRoot = captureRoot.standardizedFileURL
        guard try fileType(requestedRoot) == .typeDirectory else { throw NamedSourceExportError.unsafePath }
        let root = requestedRoot.resolvingSymlinksInPath()
        let context = try manifestURL.map { url -> ShareContext in
            let file = try validatedSource(url, requestedRoot: requestedRoot, root: root)
            let originalSnapshot = try snapshot(file)
            guard originalSnapshot.size <= 2 * 1_024 * 1_024 else { throw NamedSourceExportError.tooLarge }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let header = try decoder.decode(ShareHeader.self, from: Data(contentsOf: file))
            guard try snapshot(file) == originalSnapshot else { throw NamedSourceExportError.sourceChanged }
            guard header.schemaVersion == 1, header.id == sourceID, header.projectID == projectID,
                  header.status == "ready", (header.completedAssets?.count ?? 0) <= 2_048,
                  (header.segments?.count ?? 0) <= 256 else { throw NamedSourceExportError.invalidSource }
            let segments = header.segments ?? []
            guard Set(segments.map(\.id)).count == segments.count,
                  Set(segments.map(\.frameID)).count == segments.count else { throw NamedSourceExportError.invalidSource }
            return ShareContext(url: file, root: file.deletingLastPathComponent(), header: header, snapshot: originalSnapshot)
        }
        var inputs: [PreparedSource] = [], seen = Set<String>(), total: Int64 = 0
        for source in sources {
            let file = try validatedSource(source, requestedRoot: requestedRoot, root: root)
            guard seen.insert(file.path).inserted else { continue }
            let value = try snapshot(file)
            guard value.size <= Self.maximumFileBytes, total <= Self.maximumTotalBytes - value.size else {
                throw NamedSourceExportError.tooLarge
            }
            total += value.size
            if let context {
                guard file.path.hasPrefix(context.root.path + "/") else { throw NamedSourceExportError.unsafePath }
                if file == context.url, value != context.snapshot { throw NamedSourceExportError.sourceChanged }
                let relative = String(file.path.dropFirst(context.root.path.count + 1))
                guard file == context.url || context.header.completedAssets?.contains(relative) == true else {
                    throw NamedSourceExportError.invalidSource
                }
            }
            inputs.append(PreparedSource(url: file, snapshot: value, filename: ""))
        }
        var owned: [OwnedAlias] = [], aliases: [URL] = [], entries: [CaptureShareIndex.File] = []
        var manifestAlias: URL?
        do {
            for item in inputs {
                try Task.checkCancellation()
                try requireUnchanged(item, requestedRoot: requestedRoot, root: root)
                let relative = String(item.url.path.dropFirst(root.path.count + 1))
                let local = context.map { String(item.url.path.dropFirst($0.root.path.count + 1)) }
                let components = local?.split(separator: "/").map(String.init) ?? []
                let segment = components.count >= 3 && components[0] == "segments"
                    ? context?.header.segments?.first { $0.id.uuidString.lowercased() == components[1].lowercased() } : nil
                if components.first == "segments", segment == nil { throw NamedSourceExportError.invalidSource }
                let originalTime = segment?.startedAt ?? context?.header.createdAt ?? capturedAt
                let alias = try await prepare(sources: [item.url], captureRoot: root, projectName: projectName,
                    projectID: projectID, sourceID: segment?.id ?? sourceID, capturedAt: originalTime)[0]
                let aliasSnapshot = try snapshot(alias)
                owned.append(OwnedAlias(url: alias, inode: aliasSnapshot.inode, device: aliasSnapshot.device))
                aliases.append(alias)
                let hash = try streamingHash(alias, byteCount: item.snapshot.size)
                try requireUnchanged(item, requestedRoot: requestedRoot, root: root)
                if aliasSnapshot.inode != item.snapshot.inode || aliasSnapshot.device != item.snapshot.device {
                    guard try streamingHash(item.url, byteCount: item.snapshot.size) == hash else {
                        throw NamedSourceExportError.sourceChanged
                    }
                }
                entries.append(CaptureShareIndex.File(aliasFileName: alias.lastPathComponent,
                    originalRelativePath: relative, originalCaptureRelativePath: local,
                    projectID: projectID, captureID: sourceID, sourceID: segment?.id ?? sourceID,
                    segmentID: segment?.id, frameID: segment?.frameID ?? context?.header.frameID,
                    capturedAt: originalTime, byteCount: item.snapshot.size, sha256: hash))
                if item.url == context?.url { manifestAlias = alias }
            }
            for input in inputs {
                try Task.checkCancellation()
                try requireUnchanged(input, requestedRoot: requestedRoot, root: root)
            }
            if let context, try snapshot(context.url) != context.snapshot { throw NamedSourceExportError.sourceChanged }
            let exportedAt = Date(), exportID = UUID()
            let index = CaptureShareIndex(id: exportID, projectID: projectID, captureID: sourceID,
                exportedAt: exportedAt, files: entries)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(index)
            guard data.count <= 2 * 1_024 * 1_024 else { throw NamedSourceExportError.tooLarge }
            let output = root.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true)
            guard try fileType(output) == .typeDirectory, output.resolvingSymlinksInPath().path == output.path else {
                throw NamedSourceExportError.unsafePath
            }
            let temporary = output.appendingPathComponent(".capture-share-index-" + exportID.uuidString + ".partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            let destination = output.appendingPathComponent(try ExportFileNaming.project(projectName: projectName,
                projectID: projectID, role: "capture-index", exportedAt: exportedAt, fileExtension: "json", exportID: exportID))
            try Task.checkCancellation()
            guard try optionalFileType(destination) == nil else { throw NamedSourceExportError.unsafePath }
            let identity = try snapshot(temporary)
            try FileManager.default.moveItem(at: temporary, to: destination)
            owned.append(OwnedAlias(url: destination, inode: identity.inode, device: identity.device))
            for input in inputs { try requireUnchanged(input, requestedRoot: requestedRoot, root: root) }
            if let context, try snapshot(context.url) != context.snapshot { throw NamedSourceExportError.sourceChanged }
            try Task.checkCancellation()
            return NamedSourceExportResult(files: aliases, indexURL: destination, manifestAliasURL: manifestAlias)
        } catch {
            for alias in owned {
                if let current = try? snapshot(alias.url), current.inode == alias.inode, current.device == alias.device {
                    try? FileManager.default.removeItem(at: alias.url)
                }
            }
            throw error
        }
    }

    func prepare(sources: [URL], captureRoot: URL, projectName: String, projectID: UUID,
                 sourceID: UUID, capturedAt: Date?) async throws -> [URL] {
        try Task.checkCancellation()
        guard sources.count <= Self.maximumFiles else { throw NamedSourceExportError.tooLarge }
        guard !sources.isEmpty else { return [] }
        let manager = FileManager.default
        try validateURL(captureRoot)
        let requestedRoot = captureRoot.standardizedFileURL
        guard try fileType(requestedRoot) == .typeDirectory else { throw NamedSourceExportError.unsafePath }
        let root = requestedRoot.resolvingSymlinksInPath()
        let output = root.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true)
        guard output.path != root.path, !output.path.hasPrefix(root.path + "/") else {
            throw NamedSourceExportError.unsafePath
        }
        let exportedAt = Date()
        var prepared: [PreparedSource] = [], seen = Set<String>(), total: Int64 = 0
        for source in sources {
            try Task.checkCancellation()
            let file = try validatedSource(source, requestedRoot: requestedRoot, root: root)
            guard seen.insert(file.path).inserted else { continue }
            let snapshot = try snapshot(file)
            guard snapshot.size <= Self.maximumFileBytes, total <= Self.maximumTotalBytes - snapshot.size else {
                throw NamedSourceExportError.tooLarge
            }
            total += snapshot.size
            let filename = try ExportFileNaming.source(projectName: projectName, projectID: projectID,
                role: role(for: file.pathExtension), sourceID: sourceID, capturedAt: capturedAt,
                exportedAt: exportedAt, fileExtension: file.pathExtension)
            prepared.append(PreparedSource(url: file, snapshot: snapshot, filename: filename))
        }
        // Reject a redirected destination before creating any aliases.
        if let type = try optionalFileType(output) {
            guard type == .typeDirectory else { throw NamedSourceExportError.unsafePath }
        } else {
            try manager.createDirectory(at: output, withIntermediateDirectories: false)
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: output.path)
            #endif
        }
        let staging = output.appendingPathComponent(".named-source-" + UUID().uuidString + ".partial", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        var created: [OwnedAlias] = []
        do {
            for item in prepared {
                try Task.checkCancellation()
                try requireUnchanged(item, requestedRoot: requestedRoot, root: root)
                guard try fileType(output) == .typeDirectory,
                      output.resolvingSymlinksInPath().path == output.path else { throw NamedSourceExportError.unsafePath }
                let temporary = staging.appendingPathComponent(item.filename)
                do {
                    try manager.linkItem(at: item.url, to: temporary)
                } catch {
                    // The private staging directory is owned by this request.
                    // It cannot overwrite any previously shared export.
                    if try optionalFileType(temporary) != nil { throw error }
                    try requireCopySpace(size: item.snapshot.size, directory: output)
                    try Task.checkCancellation()
                    try manager.copyItem(at: item.url, to: temporary)
                }
                try requireUnchanged(item, requestedRoot: requestedRoot, root: root)
                let temporarySnapshot = try snapshot(temporary)
                guard temporarySnapshot.size == item.snapshot.size else { throw NamedSourceExportError.sourceChanged }
                let destination = output.appendingPathComponent(item.filename)
                guard try optionalFileType(destination) == nil else { throw NamedSourceExportError.unsafePath }
                try manager.moveItem(at: temporary, to: destination)
                created.append(OwnedAlias(url: destination, inode: temporarySnapshot.inode, device: temporarySnapshot.device))
                try requireUnchanged(item, requestedRoot: requestedRoot, root: root)
            }
            // Earlier files can change while later files are copied. Check the
            // entire batch once more before returning any shareable URLs.
            for item in prepared {
                try Task.checkCancellation()
                try requireUnchanged(item, requestedRoot: requestedRoot, root: root)
            }
            try Task.checkCancellation()
            return created.map(\.url)
        } catch {
            // Only unlink this request's known file identities. Existing exports
            // and originals are retained, even when source validation fails.
            for alias in created {
                if let current = try? snapshot(alias.url), current.inode == alias.inode, current.device == alias.device {
                    try? manager.removeItem(at: alias.url)
                }
            }
            throw error
        }
    }

    private func validateURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.contains("\0"),
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
            throw NamedSourceExportError.unsafePath
        }
    }

    private func validatedSource(_ url: URL, requestedRoot: URL, root: URL) throws -> URL {
        try validateURL(url)
        let source = url.standardizedFileURL
        let rawPrefix = requestedRoot.path + "/", canonicalPrefix = root.path + "/"
        let relative: String
        if source.path.hasPrefix(rawPrefix) { relative = String(source.path.dropFirst(rawPrefix.count)) }
        else if source.path.hasPrefix(canonicalPrefix) { relative = String(source.path.dropFirst(canonicalPrefix.count)) }
        else { throw NamedSourceExportError.unsafePath }
        var file = root
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { throw NamedSourceExportError.unsafePath }
        for (index, component) in components.enumerated() {
            guard !component.isEmpty, component != ".", component != ".." else { throw NamedSourceExportError.unsafePath }
            file.appendPathComponent(String(component))
            let type = try fileType(file)
            if type == .typeSymbolicLink { throw NamedSourceExportError.unsafePath }
            if index < components.count - 1, type != .typeDirectory { throw NamedSourceExportError.unsafePath }
        }
        guard file.resolvingSymlinksInPath().path == file.path else { throw NamedSourceExportError.unsafePath }
        return file
    }

    private func requireUnchanged(_ source: PreparedSource, requestedRoot: URL, root: URL) throws {
        let current = try validatedSource(source.url, requestedRoot: requestedRoot, root: root)
        guard try snapshot(current) == source.snapshot else { throw NamedSourceExportError.sourceChanged }
    }

    private func fileType(_ file: URL) throws -> FileAttributeType {
        guard let value = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType else {
            throw NamedSourceExportError.invalidSource
        }
        return value
    }

    private func optionalFileType(_ file: URL) throws -> FileAttributeType? {
        do { return try fileType(file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }

    private func snapshot(_ file: URL) throws -> SourceSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else { throw NamedSourceExportError.invalidSource }
        return SourceSnapshot(size: size.int64Value, modified: modified, inode: inode.uint64Value, device: device.uint64Value)
    }

    private func requireCopySpace(size: Int64, directory: URL) throws {
        let reserve: Int64 = 256 * 1_024 * 1_024
        guard let space = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber,
              space.int64Value >= size + reserve else { throw NamedSourceExportError.insufficientStorage }
    }

    private func streamingHash(_ file: URL, byteCount: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var stream = FieldTransferDigest.Stream(), read: Int64 = 0
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            try Task.checkCancellation()
            read += Int64(data.count)
            guard read <= byteCount else { throw NamedSourceExportError.sourceChanged }
            stream.update(data)
        }
        guard read == byteCount else { throw NamedSourceExportError.sourceChanged }
        return stream.finalize()
    }

    private func role(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mov", "mp4", "m4v": "video"
        case "jpg", "jpeg", "heic", "png", "tif", "tiff": "photo"
        case "obj", "ply", "stl", "usdz", "las", "laz": "model"
        case "json": "metadata"
        default: "source"
        }
    }

    private struct SourceSnapshot: Equatable, Sendable {
        let size: Int64; let modified: Date; let inode: UInt64; let device: UInt64
    }
    private struct PreparedSource: Sendable { let url: URL; let snapshot: SourceSnapshot; let filename: String }
    private struct OwnedAlias: Sendable { let url: URL; let inode: UInt64; let device: UInt64 }
    private struct ShareHeader: Decodable {
        struct Segment: Decodable { let id: UUID; let frameID: UUID; let startedAt: Date }
        let schemaVersion: Int; let id: UUID; let projectID: UUID; let status: String
        let createdAt: Date?; let frameID: UUID?; let segments: [Segment]?; let completedAssets: [String]?
    }
    private struct ShareContext { let url: URL; let root: URL; let header: ShareHeader; let snapshot: SourceSnapshot }
}
