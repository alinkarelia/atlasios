import Foundation

enum NativeAPIError: LocalizedError {
    case server(Int, String), local(String)
    var errorDescription: String? { switch self { case .server(_, let text), .local(let text): return text } }
    var status: Int? { if case .server(let code, _) = self { return code }; return nil }
}
enum NativeDate {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func string(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
struct NativeAccountContext: Decodable {
    struct User: Decodable { let id: String; let name: String; let isChief: Bool
        enum CodingKeys: String, CodingKey { case id, name; case isChief = "is_chief" } }
    struct Project: Decodable, Identifiable { let id: String; let title: String; let role: String }
    struct Task: Decodable { let id: String; let projectID: String; let status: String; let assignmentEpoch: Int
        enum CodingKeys: String, CodingKey { case id, status; case projectID = "project_id"; case assignmentEpoch = "assignment_epoch" } }
    struct Permissions: Decodable { let locationRequired: Bool
        enum CodingKeys: String, CodingKey { case locationRequired = "location_required" } }
    let clientID: String
    let user: User
    let projects: [Project]
    let tasks: [Task]
    let permissions: Permissions
    enum CodingKeys: String, CodingKey { case user, projects, tasks, permissions; case clientID = "client_id" }
}
struct NativeWebTicket: Decodable {
    let ticket: String
    let expiresAt: String
    let expiresIn: Int
    let bootstrapURL: String
    enum CodingKeys: String, CodingKey { case ticket; case expiresAt = "expires_at"; case expiresIn = "expires_in"; case bootstrapURL = "bootstrap_url" }
}
struct NativeOK: Decodable { let ok: Bool }
final class NativeRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class NativeAPI {
    private let origin = URL(string: "https://archiverf.ru")!
    private let redirectGuard = NativeRedirectGuard()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 35
        return URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
    }()
    func request<T: Decodable>(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil) async throws -> T {
        guard path.hasPrefix("/api/native/"), let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme == "https", url.host == "archiverf.ru", url.port == nil, url.user == nil, url.password == nil else {
            throw NativeAPIError.local("Адрес подключения недоступен.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url, data.count <= 2 * 1024 * 1024 else { throw NativeAPIError.local("Не удалось проверить ответ сайта.") }
        guard (200...299).contains(http.statusCode) else {
            let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["detail"] as? String
            throw NativeAPIError.server(http.statusCode, String((detail ?? "Не удалось подключиться. Попробуйте снова.").prefix(400)))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func post<T: Decodable>(_ path: String, token: String?, json: [String: Any]) async throws -> T {
        try await request(path, method: "POST", token: token, body: JSONSerialization.data(withJSONObject: json))
    }
    func context(_ token: String) async throws -> NativeAccountContext {
        let value: NativeAccountContext = try await request("/api/native/account/context?client_id=aveli", token: token)
        guard value.clientID == "aveli", value.permissions.locationRequired else { throw NativeAPIError.local("Рабочие права приложения не подтверждены.") }
        return value
    }
    func webTicket(_ token: String) async throws -> NativeWebTicket {
        let value: NativeWebTicket = try await post("/api/native/account/web-ticket", token: token, json: ["client_id": "aveli"])
        guard value.bootstrapURL == "https://archiverf.ru/aveli/api/auth/native-web-session",
              value.expiresIn > 0, value.expiresIn <= 30, let expiry = NativeDate.parse(value.expiresAt), expiry > Date(),
              NativeAuthContract.valid(value.ticket, prefix: "nswt_") else { throw NativeAPIError.local("Одноразовое подключение истекло. Повторите вход.") }
        return value
    }
    func webSessionCookies(_ ticket: NativeWebTicket) async throws -> [HTTPCookie] {
        // URLSession has no document Origin/Sec-Fetch-Site. The existing redirect
        // guard keeps the 303 and its cookies here; the ticket never enters WebKit.
        let request = try NativeWebBootstrap.request(ticket: ticket.ticket)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 64 * 1024 else {
            throw NativeWebBootstrapError.invalidResponse
        }
        return try NativeWebBootstrap.cookies(from: http)
    }

}
