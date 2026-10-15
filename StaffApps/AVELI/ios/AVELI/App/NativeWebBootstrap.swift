import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Redeem outside WebKit: a first navigation from about:blank can carry Origin:null.
/// Only server-created, scoped cookies enter the nonpersistent website store.
enum NativeWebBootstrap {
    static let origin = URL(string: "https://archiverf.ru")!
    static let endpoint = URL(string: "https://archiverf.ru/aveli/api/auth/native-web-session")!
    static let startURL = URL(string: "https://archiverf.ru/aveli/connect")!
    static let retryMessage = "Не удалось открыть рабочий экран. Нажмите «Продолжить работу»."

    static func request(ticket: String) throws -> URLRequest {
        guard ticket.hasPrefix("nswt_"), ticket.count == 48,
              ticket.dropFirst(5).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw NativeWebBootstrapError.invalidResponse
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ticket": ticket])
        return request
    }

    static func cookies(from response: HTTPURLResponse) throws -> [HTTPCookie] {
        guard response.url == endpoint, response.statusCode == 303,
              response.value(forHTTPHeaderField: "Location") == "/aveli/connect" else {
            throw NativeWebBootstrapError.invalidResponse
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let name = item.key as? String, let value = item.value as? String { result[name] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: endpoint)
        let allowed = ["__Host-aveli_native", "__Host-aveli_csrf", "__Secure-aveli-session"]
        guard cookies.allSatisfy({ cookie in
            allowed.contains(cookie.name) && cookie.domain == origin.host && cookie.isSecure &&
            (cookie.name == "__Secure-aveli-session" ? cookie.path == "/aveli/" : cookie.path == "/")
        }),
        cookies.filter({ $0.name == "__Host-aveli_native" }).count == 1,
        cookies.filter({ $0.name == "__Host-aveli_csrf" }).count == 1,
        let native = cookies.first(where: { $0.name == "__Host-aveli_native" }), native.isHTTPOnly,
        let csrf = cookies.first(where: { $0.name == "__Host-aveli_csrf" }), !csrf.isHTTPOnly,
        [native, csrf].allSatisfy({ cookie in
            cookie.value.count == 43 && cookie.value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }) else { throw NativeWebBootstrapError.invalidResponse }
        return cookies
    }

    /// Main documents must be successful HTML, never an API JSON/error page.
    static func documentError(status: Int, mimeType: String?) -> String? {
        guard (200...299).contains(status), mimeType?.lowercased() == "text/html" else { return retryMessage }
        return nil
    }

    #if canImport(WebKit)
    @MainActor
    static func install(_ cookies: [HTTPCookie], into store: WKHTTPCookieStore) async {
        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }
    #endif
}

enum NativeWebBootstrapError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { NativeWebBootstrap.retryMessage }
}
