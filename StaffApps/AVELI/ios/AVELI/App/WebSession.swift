import Combine
import Foundation
import Network
import UIKit
import WebKit

@MainActor
final class WebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
    @Published var lightPreference = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var isOnline = true
    @Published var canGoBack = false
    @Published var hasLoadedPage = false
    @Published var issue: String?
    @Published var externalURL: URL?
    @Published var downloadedFile: DownloadedFile?
    @Published private(set) var isSignedIn = false
    @Published private(set) var accountName = ""
    @Published private(set) var busy = false
    @Published private(set) var clearingWebData = false
    private var webResetID: UUID?
    @Published private var authorityReady = false
    let configuration: AppConfiguration
    let webView: WKWebView
    let location: WorkLocationService
    var workAllowed: Bool { isSignedIn && authorityReady && active && isOnline && location.workAllowed }
    private let api: NativeAPI
    private let signInService: NativeSignIn
    private var credential: NativeCredential?
    private var active = true
    private var wantsWork = false
    private var epoch = 0
    private var authEpoch = 0
    private var bootstrapID: UUID?
    private var bootstrapping: Bool { bootstrapID != nil }
    private var authorizationFingerprint = ""
    private var observations: [NSKeyValueObservation] = []
    private var subscriptions = Set<AnyCancellable>()
    private let network = NWPathMonitor()
    private var trustedTap = Date.distantPast
    private var downloadDirectory: URL?

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        let api = NativeAPI()
        self.api = api
        signInService = NativeSignIn(api: api)
        location = WorkLocationService(api: api)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = "AVELI-iOS/1.0.4"
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        config.userContentController.add(WeakNativeMessageHandler(self), name: "aveliNativeState")
        config.userContentController.add(AppearanceMessageHandler(session: self), name: "aveliAppearance")
        config.userContentController.addUserScript(WKUserScript(source: AppearanceMessageHandler.observerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)
        observations = [webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            Task { @MainActor [weak self] in self?.progress = view.estimatedProgress }
        }, webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            Task { @MainActor [weak self] in self?.canGoBack = view.canGoBack }
        }]
        location.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        location.onGateChanged = { [weak self] allowed in
            guard let self else { return }
            if allowed { Task { await self.openWork() } }
            else { self.pauseWebContent() }
        }
        location.onAuthorityFailure = { [weak self] error in self?.authorityFailed(error) }
        network.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.isOnline != online
                self.isOnline = online
                if !online { self.pauseWebContent(); self.location.stop(reason: "accuracy_unavailable"); self.issue = "Нет соединения. Работа приостановлена." }
                else if changed && self.active && self.wantsWork { await self.beginWork() }
            }
        }
        network.start(queue: DispatchQueue(label: "ru.archiverf.aveli.network"))
        Task { await restore() }
    }
    @objc private func tapped() { if workAllowed { trustedTap = Date() } }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    private func fingerprint(_ context: NativeAccountContext) -> String {
        context.user.id + ":" + String(context.user.isChief) + ":" + context.projects.map { $0.id + ":" + $0.role }.sorted().joined(separator: ";")
            + ":" + context.tasks.map { $0.id + ":" + $0.projectID + ":" + $0.status + ":" + String($0.assignmentEpoch) }.sorted().joined(separator: ";")
    }
    private func restore() async {
        let currentAuth = authEpoch
        do {
            guard let value = try NativeCredentialStore.load(), value.expiresAt > Date() else { NativeCredentialStore.delete(); return }
            credential = value
            isSignedIn = true
            let context = try await api.context(value.accessToken)
            guard currentAuth == authEpoch else { return }
            isSignedIn = true
            accountName = context.user.name
            authorizationFingerprint = fingerprint(context)
            if active && isOnline { await beginWork() }
        } catch { if currentAuth == authEpoch { authorityFailed(error) } }
    }
    func signIn() {
        guard !busy, !clearingWebData else { return }
        authEpoch += 1
        let currentAuth = authEpoch
        busy = true
        issue = nil
        Task {
            defer { if currentAuth == authEpoch { busy = false } }
            do {
                let value = try await signInService.signIn()
                guard currentAuth == authEpoch else { return }
                let context = try await api.context(value.accessToken)
                guard currentAuth == authEpoch else { return }
                try NativeCredentialStore.save(value)
                credential = value
                accountName = context.user.name
                isSignedIn = true
                authorizationFingerprint = fingerprint(context)
                wantsWork = true
                await beginWork()
            } catch { if currentAuth == authEpoch { issue = error.localizedDescription } }
        }
    }
    func beginWork() async {
        guard wantsWork, !clearingWebData, !bootstrapping, active, isOnline, let credential else { return }
        guard credential.expiresAt > Date() else { logout(); issue = "Сессия завершена. Войдите снова."; return }
        issue = nil
        authorityReady = false
        pauseWebContent()
        let current = epoch
        let currentAuth = authEpoch
        do {
            let context = try await api.context(credential.accessToken)
            guard current == epoch, currentAuth == authEpoch, self.credential?.accessToken == credential.accessToken, active, wantsWork else { return }
            let next = fingerprint(context)
            if next != authorizationFingerprint { clearWebContent(); authorizationFingerprint = next }
            accountName = context.user.name
            isSignedIn = true
            authorityReady = true
            location.begin(token: credential.accessToken)
            location.requestPermission()
        } catch { if current == epoch, currentAuth == authEpoch, self.credential?.accessToken == credential.accessToken { authorityFailed(error) } }
    }
    private func openWork() async {
        guard !clearingWebData, workAllowed, !bootstrapping, let credential else { return }
        if hasLoadedPage && configuration.policy.isApplicationURL(webView.url) {
            webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
            webView.evaluateJavaScript("window.dispatchEvent(new Event('aveli:native-resume'))", completionHandler: nil)
            return
        }
        let requestID = UUID()
        bootstrapID = requestID
        let current = epoch
        let currentAuth = authEpoch
        defer { if bootstrapID == requestID { bootstrapID = nil } }
        do {
            let ticket = try await api.webTicket(credential.accessToken)
            guard current == epoch, currentAuth == authEpoch, self.credential?.accessToken == credential.accessToken, bootstrapID == requestID, workAllowed else { return }
            let cookies = try await api.webSessionCookies(ticket)
            guard current == epoch, currentAuth == authEpoch, self.credential?.accessToken == credential.accessToken, bootstrapID == requestID, workAllowed else { return }
            await NativeWebBootstrap.install(cookies, into: webView.configuration.websiteDataStore.httpCookieStore)
            guard current == epoch, currentAuth == authEpoch, self.credential?.accessToken == credential.accessToken, bootstrapID == requestID, workAllowed else { return }
            isLoading = true
            issue = nil
            webView.load(URLRequest(url: NativeWebBootstrap.startURL, cachePolicy: .reloadIgnoringLocalCacheData))
        } catch { if current == epoch, currentAuth == authEpoch, self.credential?.accessToken == credential.accessToken, bootstrapID == requestID { authorityFailed(error) } }
    }
    private func pauseWebContent() {
        epoch += 1
        bootstrapID = nil
        webView.stopLoading()
        webView.setAllMediaPlaybackSuspended(true)
        if configuration.policy.isApplicationURL(webView.url) { webView.evaluateJavaScript("window.dispatchEvent(new Event('pagehide'))", completionHandler: nil) }
        isLoading = false
    }
    private func clearWebContent() {
        pauseWebContent()
        hasLoadedPage = false
        webView.loadHTMLString("", baseURL: nil)
    }
    func suspend() {
        active = false
        pauseWebContent()
        location.stop(reason: "background")
    }
    func resume() {
        active = true
        if wantsWork && isSignedIn { Task { await beginWork() } }
    }
    func retry() {
        guard isSignedIn else { return }
        wantsWork = true
        Task { await beginWork() }
    }
    func stopWork() {
        wantsWork = false
        pauseWebContent()
        location.stop(reason: "user_stop")
    }
    func logout() {
        authEpoch += 1
        busy = false
        wantsWork = false
        signInService.cancel()
        let old = credential
        credential = nil
        authorityReady = false
        isSignedIn = false
        accountName = ""
        NativeCredentialStore.delete()
        clearWebContent()
        let resetID = UUID()
        webResetID = resetID
        clearingWebData = true
        webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.webResetID == resetID else { return }
                self.webResetID = nil
                self.clearingWebData = false
            }
        }
        if let directory = downloadDirectory { try? FileManager.default.removeItem(at: directory) }
        downloadDirectory = nil
        downloadedFile = nil
        location.stop(reason: "logout")
        Task {
            if let old { let _: NativeOK? = try? await api.post("/api/native/account/logout", token: old.accessToken, json: ["client_id": "aveli"]) }
        }
    }
    private func authorityFailed(_ error: Error) {
        authorityReady = false
        pauseWebContent()
        issue = error.localizedDescription
        if (error as? NativeAPIError)?.status == 401 { logout(); issue = "Сессия завершена. Войдите снова." }
        else { location.stop(reason: "accuracy_unavailable") }
    }
    func receiveAppearance(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView,
              configuration.policy.isApplicationURL(message.frameInfo.request.url),
              configuration.policy.permitsMediaOrigin(scheme: message.frameInfo.securityOrigin.protocol, host: message.frameInfo.securityOrigin.host, port: message.frameInfo.securityOrigin.port),
              let value = message.body as? String, value == "light" || value == "dark" else { return }
        lightPreference = value == "light"
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "aveliNativeState", message.frameInfo.isMainFrame, message.webView === webView,
              configuration.policy.isApplicationURL(message.frameInfo.request.url),
              configuration.policy.permitsMediaOrigin(scheme: message.frameInfo.securityOrigin.protocol, host: message.frameInfo.securityOrigin.host, port: message.frameInfo.securityOrigin.port),
              let value = message.body as? String else { return }
        if value == "logout" { logout() }
        else if value == "session-expired" { clearWebContent(); issue = "Подключение рабочего экрана завершено. Нажмите «Продолжить работу»." }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if navigationAction.shouldPerformDownload {
            decisionHandler(workAllowed && (configuration.policy.isApplicationURL(url) || configuration.policy.isApplicationBlobURL(url, sourceURL: webView.url)) ? .download : .cancel)
            return
        }
        switch configuration.policy.destination(for: url) {
        case .application: decisionHandler(workAllowed ? .allow : .cancel)
        case .external:
            if navigationAction.navigationType == .linkActivated { externalURL = url }
            decisionHandler(.cancel)
        case .blocked: decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.response.url?.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard workAllowed, configuration.policy.isApplicationURL(navigationResponse.response.url) || configuration.policy.isApplicationBlobURL(navigationResponse.response.url ?? URL(string: "about:blank")!, sourceURL: webView.url) else { decisionHandler(.cancel); return }
        let workingDocument = ["/aveli/connect", "/aveli/mail"].contains(navigationResponse.response.url?.path ?? "")
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse,
           (workingDocument || http.statusCode >= 400 || http.mimeType?.lowercased() == "application/json"),
           let message = NativeWebBootstrap.documentError(status: http.statusCode, mimeType: http.mimeType) {
            hasLoadedPage = false
            isLoading = false
            issue = message
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard workAllowed, ["/aveli/connect", "/aveli/mail"].contains(webView.url?.path ?? ""), configuration.policy.isApplicationURL(webView.url) else { return }
        isLoading = false
        hasLoadedPage = true
        issue = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        isLoading = false
        issue = "Не удалось открыть рабочее пространство. Проверьте соединение."
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { hasLoadedPage = false; issue = "Рабочий экран остановлен. Продолжите работу заново." }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let trusted = workAllowed && frame.isMainFrame && configuration.policy.isApplicationURL(webView.url)
            && configuration.policy.permitsMediaOrigin(scheme: origin.protocol, host: origin.host, port: origin.port)
            && Date().timeIntervalSince(trustedTap) < 10
        decisionHandler(trusted ? .prompt : .deny)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard workAllowed, configuration.policy.isApplicationURL(response.url) || configuration.policy.isApplicationBlobURL(response.url ?? URL(string: "about:blank")!, sourceURL: webView.url) else { completionHandler(nil); return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aveli-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); downloadDirectory = folder
            let name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
            completionHandler(folder.appendingPathComponent(name.isEmpty ? "Материал" : name))
        } catch { completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard workAllowed, let directory = downloadDirectory, let file = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first else { return }
        downloadedFile = DownloadedFile(url: file)
    }
}

@MainActor
private final class WeakNativeMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebSession?
    init(_ target: WebSession) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(userContentController, didReceive: message) }
}
