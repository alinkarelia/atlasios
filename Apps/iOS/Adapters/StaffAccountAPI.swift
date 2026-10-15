import Foundation
import Security

struct StaffAccountToken: Codable, Sendable {
    let accessToken: String
    let tokenType: String
    let expiresAt: String
    let expiresIn: Int
    let clientID: String
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", tokenType = "token_type", expiresAt = "expires_at"
        case expiresIn = "expires_in", clientID = "client_id"
    }
    var valid: Bool {
        clientID == StaffIdentityPolicy.clientID && tokenType == "Bearer" && StaffIdentityPolicy.validAccountToken(accessToken) && (StaffIdentityPolicy.date(expiresAt) ?? .distantPast) > Date()
    }
}
struct StaffAccountContext: Decodable, Sendable {
    struct User: Decodable, Sendable { let id: String; let name: String; let isChief: Bool
        enum CodingKeys: String, CodingKey { case id, name, isChief = "is_chief" } }
    struct Project: Decodable, Identifiable, Sendable { let id: String; let title: String; let role: String }
    struct Assignment: Decodable, Identifiable, Sendable {
        let id: String; let projectID: String; let title: String; let status: String; let assignmentEpoch: Int
        enum CodingKeys: String, CodingKey { case id, title, status, projectID = "project_id", assignmentEpoch = "assignment_epoch" }
    }
    struct Permissions: Decodable, Sendable { let locationRequired: Bool
        enum CodingKeys: String, CodingKey { case locationRequired = "location_required" } }
    let clientID: String; let sessionID: String; let expiresAt: String
    let user: User; let projects: [Project]; let tasks: [Assignment]; let permissions: Permissions
    enum CodingKeys: String, CodingKey { case user, projects, tasks, permissions, clientID = "client_id", sessionID = "session_id", expiresAt = "expires_at" }
}
struct StaffRuntimeSession: Decodable, Sendable {
    struct Context: Decodable, Sendable {
        struct Organization: Decodable, Sendable { let id: UUID; let name: String; let role: String }
        struct ProjectGrant: Decodable, Sendable { let id: UUID; let organizationID: UUID; let role: String }
        let user: RemoteUser; let organization: Organization
        let projects: [ProjectGrant]; let members: [RemoteMember]
    }
    let clientID: String; let baseURL: URL; let accessToken: String; let tokenType: String
    let expiresAt: String; let expiresIn: Int; let workspaceID: String; let taskID: String; let context: Context
    enum CodingKeys: String, CodingKey {
        case context, clientID = "client_id", baseURL = "base_url", accessToken = "access_token", tokenType = "token_type"
        case expiresAt = "expires_at", expiresIn = "expires_in", workspaceID = "workspace_id", taskID = "task_id"
    }
}

/// Ephemeral, no cookies/cache/redirects: an API bearer stays on the fixed site.
enum StaffAccountAPI {
    static func request<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data? = nil,
                                                token: String? = nil, response: T.Type = T.self) async throws -> T {
        guard path.hasPrefix("api/native/"), !path.contains(".."), !path.contains("://"),
              var url = URLComponents(url: StaffIdentityPolicy.origin.appendingPathComponent(path.components(separatedBy: "?")[0]), resolvingAgainstBaseURL: false) else {
            throw StaffAccessError.invalidResponse
        }
        if let query = path.split(separator: "?", maxSplits: 1).dropFirst().first { url.percentEncodedQuery = String(query) }
        guard let target = url.url, target.scheme == "https", target.host == "archiverf.ru", target.port == nil,
              target.user == nil, target.password == nil, target.fragment == nil else { throw StaffAccessError.invalidResponse }
        var request = URLRequest(url: target); request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = 25; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await TeamHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 2 * 1_024 * 1_024 else { throw StaffAccessError.invalidResponse }
        if http.statusCode == 401 { throw StaffAccessError.expired }
        if http.statusCode == 403 { throw StaffAccessError.denied }
        guard (200..<300).contains(http.statusCode) else { throw StaffAccessError.invalidResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum StaffKeychain {
    private static let service = "com.atlasfield.staff-account"
    private static let account = "atlas-account-v1"
    static func read() -> Data? {
        var query = base; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }
    static func save(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StaffAccessError.invalidResponse }
        var item = base; attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StaffAccessError.invalidResponse }
    }
    static func remove() { SecItemDelete(base as CFDictionary) }
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}
