import Foundation

/// The website owns staff identity. Its account bearer must never be sent to the
/// material API; only a separately scoped, expiring runtime bearer belongs there.
public enum StaffIdentityPolicy {
    public static let clientID = "atlas"
    public static let origin = URL(string: "https://archiverf.ru")!
    public static let callbackURL = URL(string: "archiverf-atlas://oauth/callback")!
    public static let dataBaseURL = URL(string: "https://archiverf.ru/atlas/")!
    public static let maximumAccountLifetime: TimeInterval = 86_400

    /// Randomness comes from the caller's OS cryptographic random generator.
    /// This function validates RFC 7636 syntax and applies S256, never plain PKCE.
    public static func makePKCE(verifier: String, state: String) throws -> StaffPKCERequest {
        try validateVerifier(verifier)
        try validateState(state)
        let hex = Array(FieldTransferDigest.sha256(Data(verifier.utf8)).utf8)
        func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
        let digest = Data(stride(from: 0, to: hex.count, by: 2).map { (nibble(hex[$0]) << 4) | nibble(hex[$0 + 1]) })
        let challenge = digest.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.path = "/native/authorize"
        components.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: callbackURL.absoluteString), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components.url else { throw StaffIdentityError.untrustedURL }
        return StaffPKCERequest(authorizationURL: url, verifier: verifier, state: state, challenge: challenge)
    }

    /// Accepts only our exact registered callback route, one state and one code.
    /// Errors contain no callback, authorization code, verifier or bearer value.
    public static func validateCallback(_ url: URL, expectedState: String) throws -> String {
        try validateState(expectedState)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == callbackURL.scheme, components.host == callbackURL.host,
              components.percentEncodedPath == "/callback", components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil else { throw StaffIdentityError.invalidCallback }
        let items = components.queryItems ?? []
        let allowed = Set(["code", "state", "error", "error_description"])
        guard items.allSatisfy({ allowed.contains($0.name) }), Set(items.map(\.name)).count == items.count,
              let suppliedState = items.first(where: { $0.name == "state" })?.value,
              isUnreserved(suppliedState, minimum: 32, maximum: 256) else { throw StaffIdentityError.invalidCallback }
        guard equalState(suppliedState, expectedState) else { throw StaffIdentityError.stateMismatch }
        if items.contains(where: { $0.name == "error" }) {
            guard !items.contains(where: { $0.name == "code" }) else { throw StaffIdentityError.invalidCallback }
            throw StaffIdentityError.authorizationDenied
        }
        guard !items.contains(where: { $0.name == "error_description" }),
              let code = items.first(where: { $0.name == "code" })?.value else { throw StaffIdentityError.invalidCode }
        try validateCode(code)
        return code
    }

    /// A runtime response cannot redirect bearer-bearing requests to another
    /// host, userinfo URL, port, API prefix, query or fragment.
    public static func trustedRuntimeBaseURL(_ value: String) throws -> URL {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: value), trustedOrigin(components),
              components.query == nil, components.fragment == nil,
              ["/atlas", "/atlas/"].contains(components.percentEncodedPath) else { throw StaffIdentityError.untrustedURL }
        return dataBaseURL
    }

    /// Path arguments are relative, already structural ASCII paths. Query
    /// parameters belong in queryItems and are encoded independently of the path.
    public static func dataURL(baseURL: URL, relativePath: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let base = try trustedRuntimeBaseURL(baseURL.absoluteString)
        let segments = try pathSegments(relativePath)
        guard segments.first == "v1", segments.count > 1 else { throw StaffIdentityError.invalidPath }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/atlas/" + relativePath
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let result = components.url else { throw StaffIdentityError.invalidPath }
        return result
    }

    public static func nativeURL(relativePath: String, queryItems: [URLQueryItem] = []) throws -> URL {
        _ = try pathSegments(relativePath)
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.path = "/api/native/" + relativePath
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let result = components.url else { throw StaffIdentityError.invalidPath }
        return result
    }

    public static func validateAccountToken(_ token: String, expiresAt: Date, now: Date = Date()) throws {
        try validateAccountTokenFormat(token)
        try validateFutureExpiry(expiresAt, now: now)
        // A small allowance accommodates receipt time and ordinary clock skew;
        // it does not extend the server's actual expiry used below.
        guard expiresAt.timeIntervalSince(now) <= maximumAccountLifetime + 60 else { throw StaffIdentityError.invalidExpiry }
    }

    public static func validateRuntimeToken(_ token: String, expiresAt: Date, accountExpiresAt: Date,
                                            now: Date = Date()) throws {
        try validateRuntimeTokenFormat(token)
        try validateFutureExpiry(expiresAt, now: now)
        try validateFutureExpiry(accountExpiresAt, now: now)
        guard expiresAt <= accountExpiresAt, accountExpiresAt.timeIntervalSince(now) <= maximumAccountLifetime + 60 else {
            throw StaffIdentityError.invalidExpiry
        }
    }

    /// Format checks may inspect an expired Keychain entry before renewal; they
    /// do not imply authorization. Network use additionally requires the dated
    /// validation above and the server remains the authority on revocation.
    public static func validateAccountTokenFormat(_ token: String) throws {
        guard token.hasPrefix("nsa_"), isHeaderSafeOpaque(token, minimum: 5, maximum: 4_096) else {
            throw StaffIdentityError.invalidAccountToken
        }
    }

    public static func validateRuntimeTokenFormat(_ token: String) throws {
        guard !token.hasPrefix("nsa_"), isHeaderSafeOpaque(token, minimum: 43, maximum: 43) else {
            throw StaffIdentityError.invalidRuntimeToken
        }
    }

    /// The native contract sends an explicit UTC ISO-8601 timestamp, not the
    /// Unix milliseconds used by material manifests or Foundation's 2001 epoch.
    public static func parseUTCDate(_ value: String) throws -> Date {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|\\+00:00)$",
                          options: .regularExpression) != nil else { throw StaffIdentityError.invalidDate }
        let canonical = value.hasSuffix("+00:00") ? String(value.dropLast(6)) + "Z" : value
        let format = ISO8601DateFormatter()
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsed = format.date(from: canonical)
        format.formatOptions = [.withInternetDateTime]
        if parsed == nil { parsed = format.date(from: canonical) }
        guard let parsed, parsed.timeIntervalSince1970.isFinite,
              format.string(from: parsed).prefix(19) == value.prefix(19) else { throw StaffIdentityError.invalidDate }
        return parsed
    }

    fileprivate static func validateVerifier(_ verifier: String) throws {
        guard isUnreserved(verifier, minimum: 43, maximum: 128) else { throw StaffIdentityError.invalidVerifier }
    }

    fileprivate static func validateCode(_ code: String) throws {
        // Authorization codes are opaque OAuth VSCHAR strings, not necessarily
        // base64url. JSONEncoder escapes their bytes; controls remain forbidden.
        guard !code.isEmpty, code.utf8.count <= 2_048, code.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw StaffIdentityError.invalidCode
        }
    }

    private static func validateState(_ state: String) throws {
        guard isUnreserved(state, minimum: 32, maximum: 256) else { throw StaffIdentityError.invalidState }
    }

    private static func trustedOrigin(_ components: URLComponents) -> Bool {
        components.scheme?.lowercased() == "https" && components.host?.lowercased() == "archiverf.ru"
            && components.user == nil && components.password == nil && (components.port == nil || components.port == 443)
    }

    private static func pathSegments(_ path: String) throws -> [Substring] {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              path.utf8.allSatisfy({ asciiUnreserved($0) || $0 == 47 }) else { throw StaffIdentityError.invalidPath }
        return segments
    }

    private static func validateFutureExpiry(_ date: Date, now: Date) throws {
        guard date.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite else { throw StaffIdentityError.invalidExpiry }
        guard date > now else { throw StaffIdentityError.expiredSession }
    }

    private static func asciiUnreserved(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte)
    }

    private static func isUnreserved(_ value: String, minimum: Int, maximum: Int) -> Bool {
        (minimum...maximum).contains(value.utf8.count) && value.utf8.allSatisfy(asciiUnreserved)
    }

    private static func isHeaderSafeOpaque(_ value: String, minimum: Int, maximum: Int) -> Bool {
        (minimum...maximum).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func equalState(_ supplied: String, _ expected: String) -> Bool {
        let left = Array(supplied.utf8), right = Array(expected.utf8)
        var difference = UInt(left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            difference |= UInt((index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0))
        }
        return difference == 0
    }
}

public struct StaffPKCERequest: Sendable {
    public let authorizationURL: URL
    public let verifier: String
    public let state: String
    public let challenge: String
}

/// Exactly the four fields accepted by the current website, without grant_type.
public struct StaffCodeExchangeRequest: Encodable, Sendable {
    public let clientID = StaffIdentityPolicy.clientID
    public let code: String
    public let redirectURI = StaffIdentityPolicy.callbackURL.absoluteString
    public let codeVerifier: String

    public init(code: String, codeVerifier: String) throws {
        try StaffIdentityPolicy.validateVerifier(codeVerifier)
        try StaffIdentityPolicy.validateCode(code)
        self.code = code; self.codeVerifier = codeVerifier
    }
    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id", code, redirectURI = "redirect_uri", codeVerifier = "code_verifier"
    }
}

public struct StaffRuntimeRequest: Encodable, Sendable {
    public let clientID = StaffIdentityPolicy.clientID
    public let taskID: String
    public let shareWithTask: Bool
    public let shareOriginals: Bool

    public init(taskID: String, shareWithTask: Bool = false, shareOriginals: Bool = false) throws {
        guard !taskID.isEmpty, taskID == taskID.trimmingCharacters(in: .whitespacesAndNewlines),
              taskID.utf8.count <= 512, !taskID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw StaffIdentityError.invalidTask
        }
        self.taskID = taskID; self.shareWithTask = shareWithTask; self.shareOriginals = shareOriginals
    }
    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id", taskID = "task_id", shareWithTask = "share_with_task", shareOriginals = "share_originals"
    }
}

public struct StaffLogoutRequest: Encodable, Sendable {
    public let clientID = StaffIdentityPolicy.clientID
    public init() {}
    private enum CodingKeys: String, CodingKey { case clientID = "client_id" }
}

public enum StaffIdentityError: Error, Equatable, Sendable, LocalizedError {
    case invalidVerifier, invalidState, invalidCallback, stateMismatch, authorizationDenied, invalidCode
    case untrustedURL, invalidPath, invalidAccountToken, invalidRuntimeToken, invalidExpiry, expiredSession, invalidDate, invalidTask

    public var errorDescription: String? {
        switch self {
        case .invalidVerifier, .invalidState: "Не удалось подготовить защищённый вход. Начните вход заново."
        case .invalidCallback, .stateMismatch, .invalidCode: "Ответ входа не соответствует текущему запросу. Начните вход заново."
        case .authorizationDenied: "Вход на сайте не был подтверждён."
        case .untrustedURL, .invalidPath: "Адрес подключения не соответствует серверу «Семейного архива»."
        case .invalidAccountToken, .invalidRuntimeToken, .invalidExpiry, .invalidDate: "Сервер вернул некорректные параметры сессии."
        case .expiredSession: "Сессия истекла. Войдите в «Семейный архив» ещё раз."
        case .invalidTask: "Выберите доступное рабочее задание."
        }
    }
}
