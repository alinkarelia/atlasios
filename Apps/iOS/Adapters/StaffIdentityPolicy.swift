import Foundation

/// Fixed first-party destinations are independent of a server response or a
/// user-entered address. No account bearer is ever accepted in a callback URL.
enum StaffIdentityPolicy {
    static let origin = URL(string: "https://archiverf.ru")!
    static let runtimeOrigin = URL(string: "https://archiverf.ru/atlas/")!
    static let clientID = "atlas"
    static let redirect = "archiverf-atlas://oauth/callback"
    static let callbackScheme = "archiverf-atlas"

    static func authorizeURL(state: String, challenge: String) throws -> URL {
        guard validOpaque(state), validPKCE(challenge) else { throw StaffAccessError.invalidResponse }
        var url = URLComponents(url: origin.appendingPathComponent("native/authorize"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")]
        guard let result = url.url else { throw StaffAccessError.invalidResponse }
        return result
    }

    static func code(from callback: URL, state: String) throws -> String {
        guard callback.absoluteString.count <= 4096,
              let url = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              url.scheme == callbackScheme, url.host == "oauth", url.percentEncodedPath == "/callback",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = url.queryItems else { throw StaffAccessError.invalidCallback }
        let names = items.map(\.name)
        guard Set(names).count == names.count, Set(names).isSubset(of: ["code", "state", "error"]),
              items.first(where: { $0.name == "state" })?.value == state else { throw StaffAccessError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw StaffAccessError.cancelled }
        guard let code = items.first(where: { $0.name == "code" })?.value, validOpaque(code) else {
            throw StaffAccessError.invalidCallback
        }
        return code
    }

    static func validOpaque(_ value: String) -> Bool {
        (24...512).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "_" || $0 == "-"
        }
    }
    static func validAccountToken(_ value: String) -> Bool {
        value.hasPrefix("nsa_") && value.utf8.count == 47 && validOpaque(value)
    }
    static func validRuntimeToken(_ value: String) -> Bool { value.utf8.count == 43 && validOpaque(value) }
    static func validPKCE(_ value: String) -> Bool { value.utf8.count == 43 && validOpaque(value) }
    static func date(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum StaffAccessError: LocalizedError, Sendable {
    case invalidResponse, invalidCallback, cancelled, expired, denied, network, needsLocation, needsTask, wrongProject
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Сайт не подтвердил рабочую сессию. Повторите вход."
        case .invalidCallback: "Ответ входа не относится к этому запросу. Начните вход заново."
        case .cancelled: "Вход отменён."
        case .expired: "Рабочая сессия закончилась. Войдите снова."
        case .denied: "Рабочий доступ отозван или недоступен. Обратитесь к руководителю."
        case .network: "Не удалось связаться с сайтом. Исходные записи сохранены на устройстве."
        case .needsLocation: "Для работы разрешите геолокацию и дождитесь текущего положения."
        case .needsTask: "Выберите предоставленное задание."
        case .wrongProject: "Этот локальный проект связан с другим заданием. Создайте отдельный проект; исходники сохранены."
        }
    }
}

/// This gate also protects adapters reached through deep navigation. Saving or
/// exporting already accepted originals does not require a live work lease.
@MainActor
enum StaffWorkAccess {
    static var permission: (UUID?) -> Bool = { _ in false }
    static var diagnosticChiefWithoutTasks: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--uitest-staff-chief-no-tasks")
        #else
        false
        #endif
    }
    static var diagnosticFixtures: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--uitest-local-fixtures")
        #else
        false
        #endif
    }
    static func allowed(projectID: UUID? = nil) -> Bool { diagnosticFixtures || permission(projectID) }
    static func require(projectID: UUID? = nil) throws {
        guard allowed(projectID: projectID) else { throw StaffAccessError.needsLocation }
    }
}
