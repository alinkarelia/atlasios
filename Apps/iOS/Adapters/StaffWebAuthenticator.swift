import Foundation
import AuthenticationServices
import Security
import UIKit
import AtlasCore

/// The website owns the password form and session cookies. TerraView only sees
/// a one-use authorization code protected by PKCE and an unpredictable state.
@MainActor
final class StaffWebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var browser: ASWebAuthenticationSession?
    private var attemptID: UUID?
    private var continuation: CheckedContinuation<URL, Error>?
    private weak var anchor: UIWindow?

    func authorize(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        cancel()
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw StaffAccountError.browserUnavailable
        }
        anchor = window
        let attemptID = UUID()
        self.attemptID = attemptID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    self.complete(.failure(CancellationError()), attemptID: attemptID)
                    return
                }
                let browser = ASWebAuthenticationSession(url: url,
                    callbackURLScheme: StaffIdentityPolicy.callbackURL.scheme) { [weak self] callback, error in
                    Task { @MainActor in
                        if let callback { self?.complete(.success(callback), attemptID: attemptID) }
                        else if let error = error as? ASWebAuthenticationSessionError,
                                error.code == .canceledLogin { self?.complete(.failure(StaffAccountError.cancelled), attemptID: attemptID) }
                        else { self?.complete(.failure(StaffAccountError.browserUnavailable), attemptID: attemptID) }
                    }
                }
                browser.presentationContextProvider = self
                // Reuse the site's existing login; the OS still presents the
                // account confirmation. No password is captured by this app.
                browser.prefersEphemeralWebBrowserSession = false
                self.browser = browser
                if !browser.start() { self.complete(.failure(StaffAccountError.browserUnavailable), attemptID: attemptID) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(attemptID: attemptID) }
        }
    }
    func cancel() {
        guard let attemptID else { return }
        cancel(attemptID: attemptID)
    }
    private func cancel(attemptID: UUID) {
        guard self.attemptID == attemptID else { return }
        let previous = browser
        complete(.failure(StaffAccountError.cancelled), attemptID: attemptID)
        previous?.cancel()
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
    private func complete(_ result: Result<URL, Error>, attemptID: UUID) {
        guard self.attemptID == attemptID, let continuation else { return }
        self.attemptID = nil; self.continuation = nil; browser = nil
        continuation.resume(with: result)
    }

    static func secureRandom() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StaffAccountError.browserUnavailable
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
