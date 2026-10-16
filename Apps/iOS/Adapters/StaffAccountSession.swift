import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AtlasCore

/// Website identifiers remain opaque strings. They are never substituted for
/// the UUIDs returned by the field-data adapter's /v1/me and /v1/projects.
struct StaffAccountUser: Codable, Sendable {
    let id: String
    let displayName: String
    let email: String

    private enum CodingKeys: String, CodingKey { case id, displayName = "display_name", name, email }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
            ?? values.decodeIfPresent(String.self, forKey: .name) ?? email
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(email, forKey: .email)
    }
}

struct StaffAccountTask: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let workspaceID: String?
    let workspaceTitle: String?
    private enum CodingKeys: String, CodingKey {
        case id, title, workspaceID = "workspace_id", workspaceTitle = "workspace_title"
    }
}

struct StaffAccountContext: Codable, Sendable {
    let clientID: String
    let user: StaffAccountUser
    let tasks: [StaffAccountTask]
    let expiresAt: String
    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id", user, tasks, expiresAt = "expires_at"
    }

    func validated(accountExpiresAt: Date, now: Date = Date()) throws {
        guard clientID == StaffIdentityPolicy.clientID,
              !user.id.isEmpty, tasks.count <= 2_000,
              Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 512 && !$0.title.isEmpty }),
              try StaffIdentityPolicy.parseUTCDate(expiresAt) > now else {
            throw StaffAccountError.invalidResponse
        }
        guard accountExpiresAt > now else { throw StaffAccountError.accountExpired }
    }
}

struct StaffAccountCredentials: Codable, Sendable {
    let accessToken: String
    let tokenType: String
    let expiresAt: String
    let expiresIn: Int
    let clientID: String
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", tokenType = "token_type", expiresAt = "expires_at"
        case expiresIn = "expires_in", clientID = "client_id"
    }
    var expiry: Date? { try? StaffIdentityPolicy.parseUTCDate(expiresAt) }
    func validated(now: Date = Date()) throws {
        guard clientID == StaffIdentityPolicy.clientID, tokenType.lowercased() == "bearer",
              expiresIn > 0, expiresIn <= 86_400, let expiry,
              expiry.timeIntervalSince(now) <= 86_400 + 60 else { throw StaffAccountError.invalidResponse }
        try StaffIdentityPolicy.validateAccountToken(accessToken, expiresAt: expiry, now: now)
    }
}

struct StaffRuntimeCredentials: Codable, Sendable {
    let clientID: String
    let baseURL: String
    let accessToken: String
    let tokenType: String
    let expiresAt: String
    let expiresIn: Int
    let workspaceID: String
    let taskID: String
    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id", baseURL = "base_url", accessToken = "access_token"
        case tokenType = "token_type", expiresAt = "expires_at", expiresIn = "expires_in"
        case workspaceID = "workspace_id", taskID = "task_id"
    }
    var expiry: Date? { try? StaffIdentityPolicy.parseUTCDate(expiresAt) }
    func validated(accountExpiresAt: Date, taskID: String, now: Date = Date()) throws -> URL {
        guard clientID == StaffIdentityPolicy.clientID, tokenType.lowercased() == "bearer",
              self.taskID == taskID, !workspaceID.isEmpty, expiresIn > 0,
              expiresIn <= 86_400, let expiry else { throw StaffAccountError.invalidResponse }
        try StaffIdentityPolicy.validateRuntimeToken(accessToken, expiresAt: expiry,
            accountExpiresAt: accountExpiresAt, now: now)
        return try StaffIdentityPolicy.trustedRuntimeBaseURL(baseURL)
    }
}

struct StaffAccountSession: Codable, Sendable {
    var credentials: StaffAccountCredentials
    var context: StaffAccountContext
}

enum StaffAccountError: LocalizedError, Sendable {
    case invalidResponse, cancelled, browserUnavailable, accountExpired
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Сайт вернул неподтверждённые данные подключения. Попробуйте войти снова."
        case .cancelled: "Вход отменён. Локальная съёмка доступна без входа."
        case .browserUnavailable: "Не удалось открыть защищённое окно входа. Вернитесь в приложение и повторите."
        case .accountExpired: "Сессия сайта истекла. Войдите в «Семейный архив» снова."
        case .http(401): "Сессия сайта истекла или отозвана. Войдите снова."
        case .http(403): "Сайт не разрешил это действие. Проверьте доступ к выбранному проекту или заданию; локальные инструменты доступны полностью."
        case .http(429): "Слишком много запросов. Повторите вход немного позже."
        case let .http(status) where status >= 500: "Сайт временно недоступен. Исходники остаются на iPhone."
        case .http: "Сайт не подтвердил подключение. Повторите попытку."
        }
    }
}

/// API credentials go exclusively to the pinned website origin. Redirects are
/// disabled by TeamHTTP; neither account nor runtime secrets reach another host.
struct StaffAccountAPI: Sendable {
    let session: URLSession
    init(session: URLSession = TeamHTTP.session) { self.session = session }

    func exchange(code: String, verifier: String) async throws -> StaffAccountCredentials {
        try await json(path: "oauth/token", method: "POST",
            body: JSONEncoder().encode(StaffCodeExchangeRequest(code: code, codeVerifier: verifier)))
    }
    func context(accountToken: String) async throws -> StaffAccountContext {
        try await json(path: "account/context", token: accountToken,
            query: [URLQueryItem(name: "client_id", value: StaffIdentityPolicy.clientID)])
    }
    func runtime(accountToken: String, taskID: String, shareWithTask: Bool,
                 shareOriginals: Bool) async throws -> StaffRuntimeCredentials {
        try await json(path: "account/runtime", method: "POST", token: accountToken,
            body: JSONEncoder().encode(StaffRuntimeRequest(taskID: taskID,
                shareWithTask: shareWithTask, shareOriginals: shareOriginals)))
    }
    func logout(accountToken: String) async throws {
        _ = try await execute(path: "account/logout", method: "POST", token: accountToken,
            body: JSONEncoder().encode(StaffLogoutRequest()))
    }
    private func json<Value: Decodable>(path: String, method: String = "GET", token: String? = nil,
                                        body: Data? = nil, query: [URLQueryItem] = []) async throws -> Value {
        let data = try await execute(path: path, method: method, token: token, body: body, query: query)
        return try JSONDecoder().decode(Value.self, from: data)
    }
    private func execute(path: String, method: String, token: String?, body: Data?,
                         query: [URLQueryItem] = []) async throws -> Data {
        let url = try StaffIdentityPolicy.nativeURL(relativePath: path, queryItems: query)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token {
            try StaffIdentityPolicy.validateAccountTokenFormat(token)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw StaffAccountError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw StaffAccountError.http(http.statusCode) }
        guard data.count <= 4 * 1_024 * 1_024 else { throw StaffAccountError.invalidResponse }
        return data
    }
}

