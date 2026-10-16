import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AtlasCore

// Only this standalone executable supplies its own networking fixture. The iOS
// target uses TeamHTTP's redirect-refusing ephemeral session instead.
enum TeamHTTP { static let session = URLSession.shared }

private final class RequestFixtures: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    static let shared = RequestFixtures()
    private let lock = NSLock()
    private var handlers: [Handler] = []
    func append(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers.append(handler)
    }
    func response(for request: URLRequest) throws -> (Int, Data) {
        lock.lock()
        guard !handlers.isEmpty else { lock.unlock(); throw CheckError.failed("Unexpected request") }
        let handler = handlers.removeFirst()
        lock.unlock()
        return try handler(request)
    }
    func isEmpty() -> Bool { lock.lock(); defer { lock.unlock() }; return handlers.isEmpty }
}
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try RequestFixtures.shared.response(for: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private enum CheckError: Error { case failed(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckError.failed(message) }
}
private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    guard let body = request.httpBody,
          let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        throw CheckError.failed("Missing JSON body")
    }
    return json
}
private func data(_ text: String) -> Data { Data(text.utf8) }

/// Checks the actual client request construction with fixture responses, not a
/// duplicate implementation or a claim of authenticated production connectivity.
@main struct StaffAccountAPIChecks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = StaffAccountAPI(session: session)
        let fixtures = RequestFixtures.shared
        let now = Date(), accountExpiry = now.addingTimeInterval(3_600), runtimeExpiry = now.addingTimeInterval(1_800)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let accountISO = formatter.string(from: accountExpiry), runtimeISO = formatter.string(from: runtimeExpiry)
        let accountToken = "nsa_fixture_account_not_a_real_secret"
        let runtimeToken = String(repeating: "R", count: 43)
        let verifier = String(repeating: "v", count: 43)
        let opaqueTask = "task-site-42", opaqueWorkspace = "workspace-site-7"
        let tokenJSON = "{\"access_token\":\"\(accountToken)\",\"token_type\":\"Bearer\",\"expires_at\":\"\(accountISO)\",\"expires_in\":3600,\"client_id\":\"atlas\"}"
        fixtures.append { request in
            try check(request.url?.absoluteString == "https://archiverf.ru/api/native/oauth/token", "Exchange must use pinned native endpoint")
            try check(request.httpMethod == "POST", "Exchange must POST")
            try check(request.value(forHTTPHeaderField: "Authorization") == nil, "Exchange must not leak a previous bearer")
            try check(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Exchange requires JSON")
            let body = try jsonBody(request)
            try check(Set(body.keys) == Set(["client_id", "code", "redirect_uri", "code_verifier"]), "Exchange must send exactly four contract fields")
            try check(body["client_id"] as? String == "atlas" && body["redirect_uri"] as? String == "archiverf-atlas://oauth/callback", "Exchange uses registered client and callback")
            try check(body["code"] as? String == "opaque+/=code" && body["code_verifier"] as? String == verifier, "Opaque code and verifier must survive JSON encoding")
            return (200, data(tokenJSON))
        }
        let credentials = try await api.exchange(code: "opaque+/=code", verifier: verifier)
        try credentials.validated(now: now)
        try check(credentials.accessToken == accountToken, "Account bearer must remain distinct")
        print("CHECK account exchange: exact four fields and opaque values")

        let emptyContextJSON = "{\"client_id\":\"atlas\",\"user\":{\"id\":\"website-person-9\",\"display_name\":\"Operator\",\"email\":\"operator@example.invalid\"},\"projects\":[],\"tasks\":[],\"permissions\":{\"irrelevant_future_field\":true},\"session_id\":\"website-session-3\",\"expires_at\":\"\(accountISO)\"}"
        fixtures.append { request in
            try check(request.url?.absoluteString == "https://archiverf.ru/api/native/account/context?client_id=atlas", "Context requires registered client query")
            try check(request.httpMethod == "GET" && request.httpBody == nil, "Context must GET without password body")
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + accountToken, "Context requires account bearer")
            return (200, data(emptyContextJSON))
        }
        let empty = try await api.context(accountToken: accountToken)
        try empty.validated(accountExpiresAt: accountExpiry, now: now)
        try check(empty.tasks.isEmpty && empty.user.id == "website-person-9", "No tasks must still allow website account login; IDs stay opaque")
        print("CHECK account context: empty assignments remain a valid login")

        fixtures.append { request in
            try check(request.url?.absoluteString == "https://archiverf.ru/api/native/account/runtime", "Runtime uses native endpoint")
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + accountToken, "Runtime issuance requires account bearer")
            let body = try jsonBody(request)
            try check(Set(body.keys) == Set(["client_id", "task_id", "share_with_task", "share_originals"]), "Runtime request must have exact fields")
            try check(body["task_id"] as? String == opaqueTask, "Website task ID must not become a UUID")
            try check(body["share_with_task"] as? Bool == false && body["share_originals"] as? Bool == false, "Sharing consent must be explicit and preserved")
            return (200, data("{\"client_id\":\"atlas\",\"base_url\":\"https://archiverf.ru/atlas/\",\"access_token\":\"\(runtimeToken)\",\"token_type\":\"Bearer\",\"expires_at\":\"\(runtimeISO)\",\"expires_in\":1800,\"context\":{},\"workspace_id\":\"\(opaqueWorkspace)\",\"task_id\":\"\(opaqueTask)\"}"))
        }
        let runtime = try await api.runtime(accountToken: accountToken, taskID: opaqueTask,
            shareWithTask: false, shareOriginals: false)
        let base = try runtime.validated(accountExpiresAt: accountExpiry, taskID: opaqueTask, now: now)
        try check(base.absoluteString == "https://archiverf.ru/atlas/" && runtime.accessToken != accountToken, "Scoped runtime must keep path prefix and separate bearer")
        print("CHECK runtime issuance: opaque task IDs and private sharing choices")

        fixtures.append { request in
            try check(request.url?.absoluteString == "https://archiverf.ru/api/native/account/logout", "Logout must revoke website account session")
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + accountToken, "Logout requires account bearer")
            let body = try jsonBody(request)
            try check(Set(body.keys) == Set(["client_id"]) && body["client_id"] as? String == "atlas", "Logout exact client field")
            return (204, Data())
        }
        try await api.logout(accountToken: accountToken)
        print("CHECK logout: website revocation without a fabricated refresh route")

        for status in [401, 403] {
            fixtures.append { _ in (status, data("{\"error\":\"fixture sensitive details must not become UI text\"}")) }
            do {
                _ = try await api.context(accountToken: accountToken)
                throw CheckError.failed("HTTP rejection must not be accepted")
            } catch StaffAccountError.http(let actual) {
                try check(actual == status, "Authentication and permission failures must stay distinct")
                try check(!StaffAccountError.http(actual).localizedDescription.contains("fixture sensitive"), "Server errors must not expose response details")
            }
        }
        print("CHECK failures: distinct 401 / 403 and redacted UI descriptions")

        do {
            _ = try StaffIdentityPolicy.trustedRuntimeBaseURL("https://other.invalid/atlas/")
            throw CheckError.failed("Unexpected runtime origin accepted")
        } catch StaffIdentityError.untrustedURL {}
        do {
            _ = try await api.context(accountToken: runtimeToken)
            throw CheckError.failed("Runtime bearer must never reach account routes")
        } catch StaffIdentityError.invalidAccountToken {}
        print("CHECK bearer boundary: runtime token rejected before account request")
        try check(fixtures.isEmpty(), "All expected requests must actually execute")
        print("PASS family archive account API: 8 scenarios (fixture transport; no production login claim)")
    }
}
