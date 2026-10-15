import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class NativeSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var authentication: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<URL, Error>?
    private var attempt: UUID?
    private let api: NativeAPI
    init(api: NativeAPI) { self.api = api }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NativeAPIError.local("Не удалось подготовить защищённый вход.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func signIn() async throws -> NativeCredential {
        guard authentication == nil else { throw NativeAPIError.local("Вход уже открыт.") }
        let state = try Self.random(), verifier = try Self.random()
        let challenge = NativeAuthContract.challenge(verifier)
        var start = URLComponents(string: "https://archiverf.ru/native/authorize")!
        start.queryItems = [URLQueryItem(name: "client_id", value: "aveli"), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: AppConfiguration.callback), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256")]
        let id = UUID()
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            attempt = id
            let session = ASWebAuthenticationSession(url: start.url!, callbackURLScheme: "archiverf-aveli") { [weak self] url, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let url { self.finish(id, result: .success(url)) }
                    else { self.finish(id, result: .failure(NativeAPIError.local(error is ASWebAuthenticationSessionError ? "Вход отменён." : "Не удалось открыть вход через сайт."))) }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authentication = session
            if !session.start() { finish(id, result: .failure(NativeAPIError.local("Не удалось открыть защищённый вход."))) }
        }
        guard let code = NativeAuthContract.code(from: callback, expectedState: state) else { throw NativeAPIError.local("Ответ входа не подтверждён. Повторите вход.") }
        struct Token: Decodable { let access_token: String; let token_type: String; let expires_at: String; let expires_in: Int; let client_id: String }
        let token: Token = try await api.post("/api/native/oauth/token", token: nil, json: ["client_id": "aveli", "code": code, "redirect_uri": AppConfiguration.callback, "code_verifier": verifier])
        guard token.client_id == "aveli", token.token_type == "Bearer", token.expires_in > 0, token.expires_in <= 86400,
              NativeAuthContract.valid(token.access_token, prefix: "nsa_"),
              let expiry = NativeDate.parse(token.expires_at), expiry > Date(), expiry.timeIntervalSinceNow <= 86430 else { throw NativeAPIError.local("Сайт не подтвердил сессию приложения.") }
        return NativeCredential(accessToken: token.access_token, expiresAt: expiry)
    }
    private func finish(_ id: UUID, result: Result<URL, Error>) {
        guard attempt == id, let continuation = pending else { return }
        pending = nil
        attempt = nil
        authentication = nil
        continuation.resume(with: result)
    }
    func cancel() {
        let session = authentication
        if let id = attempt { finish(id, result: .failure(NativeAPIError.local("Вход отменён."))) }
        session?.cancel()
    }
}
