#!/usr/bin/env python3
"""Семейный архив: Живая память — real macOS WebKit first-document regression.

Runs the production cookie bridge in a fresh nonpersistent WKWebView against an
isolated HTTP fixture. The strict production HTTPS/303/cookie contract is checked
separately by check-native-contract.py; no production account or OTP is used.
"""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
COOKIE = "N" * 43
CSRF = "C" * 43
observed = {"post": False, "redirect_followed": False, "get": False}


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        valid = (self.path == "/aveli/api/auth/native-web-session" and
                 self.headers.get("Origin") is None and
                 self.headers.get("Sec-Fetch-Site") is None and
                 self.headers.get("Authorization") is None and
                 json.loads(data) == {"ticket": "nswt_" + "A" * 43})
        if not valid:
            self.send_response(403)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"code":"cross_site"}}')
            return
        observed["post"] = True
        self.send_response(303)
        self.send_header("Location", "/aveli/connect")
        self.send_header("Set-Cookie", f"aveli_fixture_native={COOKIE}; Path=/; HttpOnly; SameSite=Lax; Max-Age=3600")
        self.send_header("Set-Cookie", f"aveli_fixture_csrf={CSRF}; Path=/; SameSite=Lax; Max-Age=3600")
        self.end_headers()

    def do_GET(self):
        cookies = self.headers.get("Cookie", "")
        if self.path != "/aveli/connect" or f"aveli_fixture_native={COOKIE}" not in cookies or f"aveli_fixture_csrf={CSRF}" not in cookies:
            observed["redirect_followed"] = True
            self.send_response(403)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"code":"missing_cookie"}}')
            return
        observed["get"] = True
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(b'<!doctype html><title>AVELI fixture</title><main id="ready">ready</main>')


DRIVER = r'''
import Foundation
import AppKit
import WebKit

@MainActor
final class Probe: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var finished: CheckedContinuation<Void, Error>?
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse,
           NativeWebBootstrap.documentError(status: http.statusCode, mimeType: http.mimeType) != nil {
            decisionHandler(.cancel)
            finished?.resume(throwing: NativeWebBootstrapError.invalidResponse); finished = nil
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?.resume(); finished = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished?.resume(throwing: error); finished = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished?.resume(throwing: error); finished = nil }
    func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finished = continuation
            webView.load(URLRequest(url: url))
        }
    }
}
let app = NSApplication.shared
let deadline = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
    fputs("WebKit first-document timeout\n", stderr); exit(1)
}
Task { @MainActor in
    do {
        let fixture = URL(string: CommandLine.arguments[1])!
        let guardDelegate = NativeRedirectGuard()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
        var request = try NativeWebBootstrap.request(ticket: "nswt_" + String(repeating: "A", count: 43))
        // Only the test transport destination changes; production pins HTTPS archiverf.ru.
        request.url = fixture.appendingPathComponent("aveli/api/auth/native-web-session")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 303 else { throw NativeWebBootstrapError.invalidResponse }
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { out, item in
            if let name = item.key as? String, let value = item.value as? String { out[name] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: request.url!)
        guard cookies.count == 2 else { throw NativeWebBootstrapError.invalidResponse }
        let probe = Probe()
        await NativeWebBootstrap.install(cookies, into: probe.webView.configuration.websiteDataStore.httpCookieStore)
        try await probe.load(fixture.appendingPathComponent("aveli/connect"))
        let visible = try await probe.webView.evaluateJavaScript("document.cookie") as? String ?? ""
        let ready = try await probe.webView.evaluateJavaScript("document.getElementById('ready')?.textContent") as? String
        guard ready == "ready", visible.contains("aveli_fixture_csrf="), !visible.contains("aveli_fixture_native=") else {
            throw NativeWebBootstrapError.invalidResponse
        }
        print("Семейный архив: Живая память — actual WebKit first GET, cookie order and HttpOnly: passed")
        deadline.invalidate(); exit(0)
    } catch { fputs("WebKit bootstrap regression failed: \(error)\n", stderr); exit(1) }
}
app.run()
'''

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix="aveli-webkit-bootstrap-") as temp:
        folder = Path(temp)
        driver = folder / "main.swift"
        driver.write_text(DRIVER)
        executable = folder / "bootstrap-regression"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-framework", "WebKit", "-framework", "AppKit",
                        str(ROOT / "AVELI/App/NativeAuthContract.swift"), str(ROOT / "AVELI/App/NativeAPI.swift"),
                        str(ROOT / "AVELI/App/NativeWebBootstrap.swift"), str(driver), "-o", str(executable)], check=True)
        subprocess.run([str(executable), f"http://127.0.0.1:{server.server_port}"], check=True, timeout=55)
    assert observed == {"post": True, "redirect_followed": False, "get": True}, observed
    receipt = {"project_name": "Семейный архив: Живая память", "scope": "macOS_WebKit_nonpersistent_first_document_fixture",
               "passed": True, "real_WebKit_used": True, "actual_production_network": False, "fixture": observed}
    output = ROOT / "build/artifacts/semeynyy-arkhiv-zhivaya-pamyat-aveli-web-bootstrap-regression.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(receipt, ensure_ascii=False))
finally:
    server.shutdown()
