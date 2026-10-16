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
    let projectID: String?
    let assignmentEpoch: Int?
    var expectedWorkspaceID: String? { projectID ?? workspaceID }
    private enum CodingKeys: String, CodingKey {
        case id, title, workspaceID = "workspace_id", workspaceTitle = "workspace_title"
        case projectID = "project_id", assignmentEpoch = "assignment_epoch"
    }
}

struct StaffAccountPermissions: Codable, Sendable {
    let locationRequired: Bool?
    private enum CodingKeys: String, CodingKey { case locationRequired = "location_required" }
}

struct StaffAccountContext: Codable, Sendable {
    let clientID: String
    let user: StaffAccountUser
    let tasks: [StaffAccountTask]
    let expiresAt: String
    let permissions: StaffAccountPermissions?
    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id", user, tasks, expiresAt = "expires_at", permissions
    }

    func validated(accountExpiresAt: Date, now: Date = Date()) throws {
        guard clientID == StaffIdentityPolicy.clientID,
              !user.id.isEmpty, tasks.count <= 2_000,
              Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 512 && !$0.title.isEmpty
                  && ($0.assignmentEpoch.map { $0 >= 0 && $0 <= 9_007_199_254_740_991 } ?? true)
                  && ($0.projectID == nil || $0.workspaceID == nil || $0.projectID == $0.workspaceID) }),
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
    case invalidResponse, cancelled, browserUnavailable, accountExpired, workLocationRequired
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Сайт вернул неподтверждённые данные подключения. Попробуйте войти снова."
        case .cancelled: "Вход отменён. Локальная съёмка доступна без входа."
        case .browserUnavailable: "Не удалось открыть защищённое окно входа. Вернитесь в приложение и повторите."
        case .accountExpired: "Сессия сайта истекла. Войдите в «Семейный архив» снова."
        case .workLocationRequired: "Сайт требует подтверждённое рабочее положение для серверной передачи. Включите рабочую геопередачу или дождитесь её подтверждения. Локальные инструменты доступны полностью."
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
    func location(accountToken: String, payload: StaffLocationRequest) async throws -> StaffLocationResponse {
        try payload.validate()
        return try await json(path: "account/location", method: "POST", token: accountToken,
            body: JSONEncoder().encode(payload))
    }
    func stopLocation(accountToken: String, payload: StaffLocationStopRequest) async throws -> StaffLocationResponse {
        try payload.validate()
        return try await json(path: "account/location/stop", method: "POST", token: accountToken,
            body: JSONEncoder().encode(payload))
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


/// Exact location payload documented by the existing website integration branch.
/// These observations authorize cloud access only; capture geotags stay separate.
struct StaffLocationRequest: Encodable, Sendable {
    let clientID = StaffIdentityPolicy.clientID
    let deviceID: String
    let sequence: Int
    let permission = "authorized"
    let accuracyAuthorization: String
    let foreground = true
    let workActive = true
    let observedAt: String
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
    let simulatedBySoftware: Bool
    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id", deviceID = "device_id", sequence, permission
        case accuracyAuthorization = "accuracy_authorization", foreground, workActive = "work_active"
        case observedAt = "observed_at", latitude, longitude, accuracyMeters = "accuracy_m"
        case simulatedBySoftware = "is_simulated_by_software"
    }
    func validate(at now: Date = Date()) throws {
        let observed = try StaffIdentityPolicy.parseUTCDate(observedAt)
        guard UUID(uuidString: deviceID) != nil, (1...9_007_199_254_740_991).contains(sequence),
              ["full", "reduced"].contains(accuracyAuthorization), !simulatedBySoftware,
              latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              accuracyMeters.isFinite, (0...100_000).contains(accuracyMeters),
              now.timeIntervalSince(observed) < StaffWorkLocationPolicy.maximumFixAge,
              now.timeIntervalSince(observed) >= -StaffWorkLocationPolicy.maximumFutureSkew else {
            throw StaffAccountError.invalidResponse
        }
    }
}

struct StaffLocationStopRequest: Encodable, Sendable {
    let clientID = StaffIdentityPolicy.clientID
    let deviceID: String
    let sequence: Int
    let reason: String
    private enum CodingKeys: String, CodingKey { case clientID = "client_id", deviceID = "device_id", sequence, reason }
    func validate() throws {
        guard UUID(uuidString: deviceID) != nil, (1...9_007_199_254_740_991).contains(sequence),
              ["off_duty", "background", "permission_denied", "user_stop", "logout"].contains(reason) else {
            throw StaffAccountError.invalidResponse
        }
    }
}

struct StaffLocationResponse: Decodable, Sendable {
    struct Location: Decodable, Sendable {
        let deviceID: String
        let sequence: Int
        let expiresAt: String?
        let fresh: Bool
        let workAllowed: Bool
        private enum CodingKeys: String, CodingKey {
            case deviceID = "device_id", sequence, expiresAt = "expires_at", fresh, workAllowed = "work_allowed"
        }
    }
    let ok: Bool
    let locationRequired: Bool
    let workAllowed: Bool
    let reasonCode: String
    let location: Location
    private enum CodingKeys: String, CodingKey {
        case ok, locationRequired = "location_required", workAllowed = "work_allowed", reasonCode = "reason_code", location
    }
}
