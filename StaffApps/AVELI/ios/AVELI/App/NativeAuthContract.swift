import CryptoKit
import Foundation

/// Shared production parser; the macOS unit runner exercises these exact functions.
enum NativeAuthContract {
    static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func sameState(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func code(from callback: URL, expectedState: String) -> String? {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), parts.scheme == "archiverf-aveli",
              parts.host == "oauth", parts.path == "/callback", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, let pairs = parts.queryItems, pairs.count == 2,
              pairs.filter({ $0.name == "code" }).count == 1, pairs.filter({ $0.name == "state" }).count == 1,
              let state = pairs.first(where: { $0.name == "state" })?.value, sameState(expectedState, state),
              let code = pairs.first(where: { $0.name == "code" })?.value, valid(code, prefix: "nsc_") else { return nil }
        return code
    }
    static func valid(_ value: String, prefix: String) -> Bool {
        value.utf8.count == prefix.utf8.count + 43 && value.range(of: "^" + prefix + "[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
    }
}
