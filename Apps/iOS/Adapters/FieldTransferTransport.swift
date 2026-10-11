import Foundation
import AtlasCore

/// Refusing redirects keeps the bearer on the configured server. The app never
/// accepts a download URL supplied by a manifest or a response.
private final class TeamNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum TeamHTTP {
    private static let delegate = TeamNoRedirectDelegate()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()
}

struct TeamTransferContext: Sendable {
    let baseURL: URL
    let userID: UUID
    let organizationID: UUID
    let generation: UInt64
    private let token: String

    init(baseURL: URL, token: String, userID: UUID, organizationID: UUID, generation: UInt64) {
        self.baseURL = baseURL; self.token = token; self.userID = userID
        self.organizationID = organizationID; self.generation = generation
    }
    var scope: FieldTransferScope {
        FieldTransferScope(serverOrigin: baseURL.absoluteString, userID: userID, organizationID: organizationID)
    }
    func matchesToken(_ value: String?) -> Bool { token == value }

    func request(path: String, method: String = "GET", body: Data? = nil,
                 query: [URLQueryItem] = [], contentType: String = "application/json") throws -> URLRequest {
        guard !path.hasPrefix("/"), !path.contains(".."), !path.contains("://"),
              var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw FieldTransportError.invalidResponse
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.scheme == baseURL.scheme, url.host == baseURL.host,
              url.port == baseURL.port, url.user == nil, url.password == nil else {
            throw FieldTransportError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }
}

struct RemoteFieldAuthor: Codable, Hashable, Sendable {
    var userID: UUID
    var displayName: String
}
struct RemoteFieldAssetProgress: Codable, Hashable, Sendable {
    var id: UUID
    var byteCount: Int64
    var uploadedBytes: Int64
    var verified: Bool
}
struct RemoteFieldMaterial: Codable, Identifiable, Sendable {
    var captureID: UUID
    var projectID: UUID
    var state: String
    var author: RemoteFieldAuthor
    var receivedAt: Date
    var completedAt: Date?
    var manifest: FieldTransferManifest
    var assets: [RemoteFieldAssetProgress]
    var chunkSize: Int
    var id: UUID { captureID }
}
struct DownloadedFieldMaterial: Sendable {
    var material: RemoteFieldMaterial
    /// A verified package folder, separate from the project's live originals.
    var directory: URL
    var snapshot: AtlasProjectSnapshot
}
struct RemoteProjectContents: Sendable {
    var project: AtlasProject
    var features: [AtlasFeature]
    var materials: [RemoteFieldMaterial]
}

enum FieldTransportError: LocalizedError, Sendable {
    case invalidResponse, failed(status: Int, message: String), manifestConflict(String), alteredOriginal, incomplete, tooLarge
    var retryable: Bool {
        switch self {
        case let .failed(status, _): status == 408 || status == 409 || status == 422 || status == 429 || status >= 500
        default: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Сервер вернул неподтверждённый результат передачи."
        case let .failed(_, message), let .manifestConflict(message): message
        case .alteredOriginal: "Файл изменился после подготовки. Исходник сохранён; подготовьте новую версию отправки."
        case .incomplete: "Сервер ещё не подтвердил целостность всех файлов."
        case .tooLarge: "Материалы превышают допустимый размер передачи. Разделите работу на несколько проектов."
        }
    }
}

actor FieldTransferTransport {
    static let maximumChunk = 1_048_576
    private let team: TeamService
    init(team: TeamService) { self.team = team }

    func initialize(_ manifest: FieldTransferManifest, context: TeamTransferContext) async throws -> RemoteFieldMaterial {
        let value: RemoteFieldMaterial = try await json(path: path(manifest.projectID), method: "POST",
            body: FieldTransferJSON.encode(manifest), context: context)
        try validate(value, expected: manifest)
        return value
    }
    func status(_ manifest: FieldTransferManifest, context: TeamTransferContext) async throws -> RemoteFieldMaterial {
        let value: RemoteFieldMaterial = try await json(path: path(manifest.projectID, manifest.id), context: context)
        try validate(value, expected: manifest)
        return value
    }
    func upload(_ data: Data, asset: FieldAsset, manifest: FieldTransferManifest,
                offset: Int64, context: TeamTransferContext) async throws -> RemoteFieldAssetProgress {
        guard !data.isEmpty, data.count <= Self.maximumChunk, offset >= 0,
              offset + Int64(data.count) <= asset.byteCount else { throw FieldTransportError.invalidResponse }
        let value: RemoteFieldAssetProgress = try await json(
            path: path(manifest.projectID, manifest.id) + "/assets/" + asset.id.uuidString,
            method: "PUT", body: data, query: [URLQueryItem(name: "offset", value: String(offset))],
            contentType: "application/octet-stream", context: context)
        guard value.id == asset.id, value.byteCount == asset.byteCount,
              value.uploadedBytes >= offset + Int64(data.count), value.uploadedBytes <= asset.byteCount,
              !value.verified || value.uploadedBytes == asset.byteCount else { throw FieldTransportError.invalidResponse }
        return value
    }
    func finalize(_ manifest: FieldTransferManifest, context: TeamTransferContext) async throws -> RemoteFieldMaterial {
        let value: RemoteFieldMaterial = try await json(path: path(manifest.projectID, manifest.id) + "/finalize",
            method: "POST", body: Data("{}".utf8), context: context)
        try validate(value, expected: manifest)
        guard value.state == "complete", value.completedAt != nil,
              value.assets.allSatisfy({ $0.verified && $0.uploadedBytes == $0.byteCount }) else {
            throw FieldTransportError.incomplete
        }
        return value
    }
    func list(projectID: UUID, context: TeamTransferContext) async throws -> [RemoteFieldMaterial] {
        struct Page: Decodable, Sendable {
            let materials: [RemoteFieldMaterial]; let hasMore: Bool; let nextOffset: Int?
        }
        var offset = 0, result: [RemoteFieldMaterial] = []
        repeat {
            let page: Page = try await json(path: path(projectID),
                query: [URLQueryItem(name: "limit", value: "2"), URLQueryItem(name: "offset", value: String(offset))], context: context)
            for value in page.materials {
                try validate(value, expected: value.manifest)
                guard value.projectID == projectID, value.state == "complete" else { throw FieldTransportError.invalidResponse }
                result.append(value)
            }
            guard result.count <= 2_000 else { throw FieldTransportError.tooLarge }
            if !page.hasMore { break }
            guard let next = page.nextOffset, next > offset else { throw FieldTransportError.invalidResponse }
            offset = next
        } while true
        return result
    }
    func downloadChunk(material: RemoteFieldMaterial, asset: FieldAsset, offset: Int64,
                       context: TeamTransferContext) async throws -> Data {
        guard material.state == "complete", offset >= 0, offset < asset.byteCount else { throw FieldTransportError.incomplete }
        let length = min(Int64(Self.maximumChunk), asset.byteCount - offset)
        let request = try context.request(path: path(material.projectID, material.captureID) + "/assets/" + asset.id.uuidString,
            query: [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "length", value: String(length))])
        let (data, http) = try await execute(request, context: context)
        guard data.count == Int(length), http.value(forHTTPHeaderField: "X-Asset-SHA256") == asset.sha256,
              http.value(forHTTPHeaderField: "X-Asset-Byte-Count") == String(asset.byteCount),
              http.value(forHTTPHeaderField: "X-Asset-Offset") == String(offset) else { throw FieldTransportError.invalidResponse }
        return data
    }
    private func path(_ projectID: UUID, _ captureID: UUID? = nil) -> String {
        "v1/projects/" + projectID.uuidString + "/materials" + (captureID.map { "/" + $0.uuidString } ?? "")
    }
    private func validate(_ value: RemoteFieldMaterial, expected: FieldTransferManifest) throws {
        guard value.captureID == expected.id, value.projectID == expected.projectID,
              value.manifest == expected, ["incomplete", "complete"].contains(value.state),
              value.chunkSize > 0, value.chunkSize <= Self.maximumChunk,
              value.assets.count == expected.assets.count,
              Set(value.assets.map(\.id)).count == value.assets.count else { throw FieldTransportError.invalidResponse }
        for asset in expected.assets {
            guard let progress = value.assets.first(where: { $0.id == asset.id }),
                  progress.byteCount == asset.byteCount, progress.uploadedBytes >= 0,
                  progress.uploadedBytes <= asset.byteCount,
                  !progress.verified || progress.uploadedBytes == asset.byteCount else { throw FieldTransportError.invalidResponse }
        }
    }
    private func json<Response: Decodable & Sendable>(path: String, method: String = "GET", body: Data? = nil,
                  query: [URLQueryItem] = [], contentType: String = "application/json",
                  context: TeamTransferContext) async throws -> Response {
        let request = try context.request(path: path, method: method, body: body, query: query, contentType: contentType)
        let (data, _) = try await execute(request, context: context)
        guard data.count <= 4 * 1_024 * 1_024 else { throw FieldTransportError.tooLarge }
        return try FieldTransferJSON.decode(Response.self, from: data)
    }
    private func execute(_ request: URLRequest, context: TeamTransferContext) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        try await team.requireCurrentTransfer(context)
        let (data, response) = try await TeamHTTP.session.data(for: request)
        try Task.checkCancellation()
        try await team.requireCurrentTransfer(context)
        guard let http = response as? HTTPURLResponse else { throw FieldTransportError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct APIError: Decodable { struct Detail: Decodable { let code: String; let message: String }; let error: Detail }
            let detail = try? JSONDecoder().decode(APIError.self, from: data).error
            let descriptions = ["unauthorized": "Сессия закончилась. Войдите в рабочий аккаунт снова.",
                "forbidden": "У вашей роли нет доступа к передаче материалов этого проекта.",
                "not_found": "Общий проект или материалы не найдены.",
                "manifest_conflict": "На сервере уже есть другая версия этой отправки. Исходники сохранены.",
                "manifest_mismatch": "На сервере уже есть другая версия этой отправки. Исходники сохранены.",
                "invalid_digest": "Контрольная сумма файла не совпала. Повторите передачу.",
                "hash_mismatch": "Контрольная сумма не совпала. Файл остаётся на устройстве; повторите передачу.",
                "offset_conflict": "Позиция загрузки изменилась. Повторите отправку для сверки с сервером.",
                "asset_restarted": "Сервер начал приём файла заново. Повторите отправку.",
                "chunk_mismatch": "Принятый фрагмент отличается. Исходник сохранён; повторите передачу.",
                "package_complete": "Комплект уже принят полностью.",
                "incomplete_package": "Сервер ещё не получил все файлы комплекта.",
                "storage_limit": "Хранилище команды заполнено. Исходники остаются на iPhone."]
            let message = detail.map { descriptions[$0.code] ?? $0.message } ?? "Сервер не подтвердил передачу (\(http.statusCode))."
            if detail?.code == "manifest_mismatch" || detail?.code == "manifest_conflict" {
                throw FieldTransportError.manifestConflict(message)
            }
            throw FieldTransportError.failed(status: http.statusCode, message: message)
        }
        return (data, http)
    }
}
