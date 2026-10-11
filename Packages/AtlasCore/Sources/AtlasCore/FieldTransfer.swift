import Foundation

/// Delivery preference is independent of the permitted network. Manual is the
/// default, including after an app upgrade: preparing a package is not consent
/// to publish it to an organization.
public enum UploadPolicy: String, Codable, CaseIterable, Sendable { case manual, automatic }

public struct FieldTransferSettings: Codable, Hashable, Sendable {
    public var policy: UploadPolicy
    public var wifiOnly: Bool
    public init(policy: UploadPolicy = .manual, wifiOnly: Bool = true) {
        self.policy = policy; self.wifiOnly = wifiOnly
    }
}

public enum TransferNetwork: String, Codable, Sendable { case offline, wifi, cellular, other }
public enum FieldMaterialKind: String, Codable, CaseIterable, Sendable {
    case photo, mesh, floorPlan, feature, measurement, project
}
public enum FieldAssetKind: String, Codable, CaseIterable, Sendable {
    case originalPhoto, mesh, roomPlan, metadata, floorPlan, feature, measurement, projectSnapshot, preview, other
}

public struct FieldCaptureDevice: Codable, Hashable, Sendable {
    public let model: String
    public let osVersion: String
    public let appVersion: String
    public init(model: String, osVersion: String, appVersion: String) {
        self.model = model; self.osVersion = osVersion; self.appVersion = appVersion
    }
}

/// A source entity can appear in a later package when its metadata is corrected.
/// Missing original capture times stay nil; package preparation never supplies
/// an invented capture time. Geographic observations do not georeference an AR frame.
public struct FieldMaterial: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sourceEntityID: UUID
    public let kind: FieldMaterialKind
    public let capturedAt: Date?
    public let endedAt: Date?
    public let importedAt: Date?
    public let frameID: UUID?
    public let geoTag: GeoTag?
    public init(id: UUID = UUID(), sourceEntityID: UUID, kind: FieldMaterialKind,
                capturedAt: Date? = nil, endedAt: Date? = nil, importedAt: Date? = nil,
                frameID: UUID? = nil, geoTag: GeoTag? = nil) {
        self.id = id; self.sourceEntityID = sourceEntityID; self.kind = kind
        self.capturedAt = capturedAt; self.endedAt = endedAt; self.importedAt = importedAt
        self.frameID = frameID; self.geoTag = geoTag
    }
}

/// The path addresses an immutable file snapshot inside the project's managed
/// root. Hashes describe the actual bytes, including original EXIF metadata.
public struct FieldAsset: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let materialID: UUID
    public let relativePath: String
    public let mediaType: String
    public let byteCount: Int64
    public let sha256: String
    public let kind: FieldAssetKind
    public init(id: UUID = UUID(), materialID: UUID, relativePath: String, mediaType: String,
                byteCount: Int64, sha256: String, kind: FieldAssetKind) {
        self.id = id; self.materialID = materialID; self.relativePath = relativePath
        self.mediaType = mediaType; self.byteCount = byteCount; self.sha256 = sha256; self.kind = kind
    }
}

/// Immutable, versioned package. The server derives the uploader's identity
/// from authentication; client-supplied metadata is never used as that identity.
public struct FieldTransferManifest: Identifiable, Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let projectID: UUID
    public let title: String
    public let createdAt: Date
    public let timeZoneIdentifier: String
    public let utcOffsetSeconds: Int
    public let device: FieldCaptureDevice?
    public let materials: [FieldMaterial]
    public let assets: [FieldAsset]
    public init(id: UUID = UUID(), projectID: UUID, title: String, createdAt: Date = Date(),
                timeZoneIdentifier: String = TimeZone.current.identifier,
                utcOffsetSeconds: Int = TimeZone.current.secondsFromGMT(),
                device: FieldCaptureDevice? = nil, materials: [FieldMaterial], assets: [FieldAsset]) {
        self.schemaVersion = 1; self.id = id; self.projectID = projectID; self.title = title
        self.createdAt = createdAt; self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetSeconds = utcOffsetSeconds; self.device = device
        self.materials = materials; self.assets = assets
    }

    public var totalBytes: Int64 { assets.reduce(0) { $0 + $1.byteCount } }

    public func validate() throws {
        guard schemaVersion == 1 else { throw FieldTransferError.unsupportedSchema(schemaVersion) }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 240,
              Self.validDate(createdAt), timeZoneIdentifier.utf16.count <= 100, TimeZone(identifier: timeZoneIdentifier) != nil,
              abs(Int64(utcOffsetSeconds)) <= 64_800,
              !materials.isEmpty, materials.count <= 1_000,
              !assets.isEmpty, assets.count <= 2_048 else { throw FieldTransferError.invalidManifest }
        if let device {
            guard [device.model, device.osVersion, device.appVersion].allSatisfy({ !$0.isEmpty && $0.utf16.count <= 160 }) else {
                throw FieldTransferError.invalidManifest
            }
        }
        var materialIDs = Set<UUID>()
        for material in materials {
            guard materialIDs.insert(material.id).inserted,
                  [material.capturedAt, material.endedAt, material.importedAt].compactMap({ $0 }).allSatisfy(Self.validDate),
                  material.endedAt == nil || material.capturedAt != nil else { throw FieldTransferError.invalidManifest }
            if let start = material.capturedAt, let end = material.endedAt, end < start { throw FieldTransferError.invalidManifest }
            if let geoTag = material.geoTag {
                guard geoTag.corrections.count <= 1_000,
                      geoTag.automaticFix.map({ Self.validDate($0.observedAt) }) ?? true,
                      geoTag.corrections.allSatisfy({ Self.validDate($0.changedAt) && $0.note.utf16.count <= 4_096 }) else {
                    throw FieldTransferError.invalidManifest
                }
                try GeoTagPolicy.validate(geoTag)
            }
        }
        var assetIDs = Set<UUID>(), paths = Set<String>()
        var bytes: Int64 = 0
        for asset in assets {
            try FieldTransferPaths.validate(relativePath: asset.relativePath)
            guard assetIDs.insert(asset.id).inserted, paths.insert(asset.relativePath).inserted,
                  materialIDs.contains(asset.materialID), asset.byteCount >= 0, asset.byteCount <= 536_870_912,
                  Self.validMediaType(asset.mediaType), FieldTransferDigest.isSHA256(asset.sha256),
                  asset.byteCount != 0 || asset.sha256 == FieldTransferDigest.sha256(Data()) else {
                throw FieldTransferError.invalidManifest
            }
            bytes += asset.byteCount
            guard bytes <= 1_073_741_824 else { throw FieldTransferError.invalidManifest }
        }
        guard try FieldTransferJSON.encode(self).count <= 1_048_576 else { throw FieldTransferError.invalidManifest }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && abs(date.timeIntervalSince1970) <= 8_640_000_000_000
    }

    private static func validMediaType(_ value: String) -> Bool {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        let permitted = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&^_.+-".utf8)
        return value.utf8.count <= 100 && pieces.count == 2 && pieces.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { permitted.contains($0) }
        }
    }
}

/// Authentication tokens never enter the durable queue. A transfer can only be
/// selected by the exact server, account and organization it was prepared for.
public struct FieldTransferScope: Codable, Hashable, Sendable {
    public let serverOrigin: String
    public let userID: UUID
    public let organizationID: UUID
    public init(serverOrigin: String, userID: UUID, organizationID: UUID) {
        var components = URLComponents(string: serverOrigin.trimmingCharacters(in: .whitespacesAndNewlines))
        let scheme = components?.scheme?.lowercased(), host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        if components?.port == 443 && components?.scheme == "https" { components?.port = nil }
        if components?.port == 80 && components?.scheme == "http" { components?.port = nil }
        if var path = components?.path {
            while path.hasSuffix("/") { path.removeLast() }
            components?.path = path
        }
        self.serverOrigin = components?.string ?? serverOrigin
        self.userID = userID; self.organizationID = organizationID
    }

    public func validate() throws {
        guard let components = URLComponents(string: serverOrigin), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw FieldTransferError.invalidScope
        }
    }

    public var key: String {
        FieldTransferDigest.sha256(Data((serverOrigin + "|" + userID.uuidString.lowercased() + "|" + organizationID.uuidString.lowercased()).utf8))
    }
}

public enum FieldTransferState: String, Codable, CaseIterable, Sendable {
    case ready, queued, uploading, waiting, failed, conflict, paused, completed
}

public struct FieldTransferRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let scope: FieldTransferScope
    public let manifest: FieldTransferManifest
    public let manifestSHA256: String
    public var state: FieldTransferState
    public var explicitlyRequested: Bool
    public var queuedAt: Date?
    public var uploadedBytesByAsset: [UUID: Int64]
    public var attemptCount: Int
    public var nextRetryAt: Date?
    public var lastError: String?
    public var completedAt: Date?
    public var serverReceiptID: String?
    public var totalBytes: Int64 { manifest.totalBytes }
    public var uploadedBytes: Int64 { uploadedBytesByAsset.values.reduce(0, +) }
    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(uploadedBytes) / Double(totalBytes)) : (state == .completed ? 1 : 0)
    }
}

public enum FieldTransferError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int), invalidManifest, invalidScope, invalidAssetPath(String)
    case missingAsset(String), assetChanged(String), immutableManifest, transferNotFound(UUID)
    case invalidTransition, invalidOffset, incompleteAssets, queueCapacity
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "Пакет создан более новой версией Atlas. Обновите приложение."
        case .invalidManifest: "Проверьте состав пакета: данные, размеры файлов или связи материалов недопустимы."
        case .invalidScope: "Не удалось определить сервер, аккаунт и организацию для отправки."
        case .invalidAssetPath: "Файл находится за пределами папки проекта или имеет недопустимый путь."
        case .missingAsset: "Исходный файл не найден. Локальный проект сохранён; проверьте его материалы."
        case .assetChanged: "Файл изменился после подготовки пакета. Подготовьте новую версию; исходники сохранены."
        case .immutableManifest: "Этот пакет уже существует с другим содержимым. Подготовьте новую версию пакета."
        case .transferNotFound: "Пакет не найден в очереди отправки."
        case .invalidTransition: "Состояние отправки изменилось. Обновите список пакетов."
        case .invalidOffset: "Сервер сообщил недопустимый объём принятых данных."
        case .incompleteAssets: "Сервер ещё не подтвердил получение всех файлов."
        case .queueCapacity: "Очередь отправки заполнена. Уберите завершённые пакеты из списка. Исходники останутся в проекте."
        }
    }
}

public enum FieldTransferJSON {
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
            guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else {
                throw FieldTransferError.invalidManifest
            }
            var container = encoder.singleValueContainer()
            try container.encode(Int64(milliseconds))
        }
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

public enum FieldTransferPaths {
    public static func validate(relativePath: String) throws {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, relativePath.utf8.count <= 1_024,
              !relativePath.hasPrefix("/"), !relativePath.contains("\\"), !relativePath.contains(":"),
              !relativePath.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FieldTransferError.invalidAssetPath(relativePath)
        }
    }

    /// Resolves symlinks before checking containment. Files outside the root
    /// cannot become upload sources via a symlink inside a project.
    public static func resolve(relativePath: String, root: URL) throws -> URL {
        try validate(relativePath: relativePath)
        guard root.isFileURL else { throw FieldTransferError.invalidAssetPath(relativePath) }
        let directory = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = directory.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard candidate.path.hasPrefix(prefix) else { throw FieldTransferError.invalidAssetPath(relativePath) }
        return candidate
    }

    public static func verify(asset: FieldAsset, root: URL) throws -> URL {
        let url = try resolve(relativePath: asset.relativePath, root: root)
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
        catch { throw FieldTransferError.missingAsset(asset.relativePath) }
        guard values.isRegularFile == true, let size = values.fileSize else { throw FieldTransferError.missingAsset(asset.relativePath) }
        guard Int64(size) == asset.byteCount, try FieldTransferDigest.sha256(fileURL: url) == asset.sha256 else {
            throw FieldTransferError.assetChanged(asset.relativePath)
        }
        return url
    }
}
