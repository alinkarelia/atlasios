#!/usr/bin/env python3
"""Семейный архив: Живая память — execute the production Swift auth/URL contract."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = "\n".join((root / 'AVELI/App' / name).read_text() for name in ['NativeAuthContract.swift', 'URLPolicy.swift', 'NativeWebBootstrap.swift'])
tests = r'''
var count = 0
func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
check(NativeAuthContract.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC7636 S256")
let state = String(repeating: "S", count: 43), code = "nsc_" + String(repeating: "A", count: 43)
let callback = "archiverf-aveli://oauth/callback?code=" + code + "&state=" + state
check(NativeAuthContract.code(from: URL(string: callback)!, expectedState: state) == code, "exact callback")
for bad in [callback + "&code=" + code, callback + "&state=" + state, callback + "#fragment", callback + "&extra=1", callback.replacingOccurrences(of: "oauth/", with: "wrong/"), callback.replacingOccurrences(of: "archiverf-aveli:", with: "https:"), callback.replacingOccurrences(of: "nsc_", with: "nsa_"), callback.replacingOccurrences(of: "state=" + state, with: "state=other"), callback.replacingOccurrences(of: "/callback?", with: "/callback/?")] {
    check(NativeAuthContract.code(from: URL(string: bad)!, expectedState: state) == nil, "reject malformed callback")
}
check(NativeAuthContract.valid("nsa_" + String(repeating: "a", count: 43), prefix: "nsa_"), "account format")
check(!NativeAuthContract.valid(String(repeating: "a", count: 43), prefix: "nsa_"), "bare runtime is not account")
check(!NativeAuthContract.valid("nswt_" + String(repeating: "a", count: 42), prefix: "nswt_"), "ticket entropy length")
let policy = URLPolicy()
for path in ["/aveli/connect", "/aveli/mail", "/aveli/api/auth/native-web-session", "/aveli/api/mail/download/id"] {
    check(policy.destination(for: URL(string: "https://archiverf.ru" + path)!) == .application, "trusted working route")
}
for url in ["http://127.0.0.1:19473/", "http://archiverf.ru/aveli/connect", "https://archiverf.ru.evil.invalid/aveli/connect", "https://user:secret@archiverf.ru/aveli/connect", "https://archiverf.ru:444/aveli/connect", "file:///aveli/connect", "https://archiverf.ru/aveli/", "https://archiverf.ru/aveli/index.html"] {
    check(policy.destination(for: URL(string: url)!) == .blocked, "reject origin/prototype")
}
check(policy.destination(for: URL(string: "https://archiverf.ru/#help")!) == .external, "site opens externally")
check(policy.isApplicationBlobURL(URL(string: "blob:https://archiverf.ru/123")!, sourceURL: URL(string: "https://archiverf.ru/aveli/mail")!), "trusted blob attachment")
check(!policy.isApplicationBlobURL(URL(string: "blob:https://evil.invalid/123")!, sourceURL: URL(string: "https://archiverf.ru/aveli/mail")!), "external blob blocked")
check(!policy.isApplicationBlobURL(URL(string: "blob:https://archiverf.ru/123")!, sourceURL: URL(string: "https://archiverf.ru/aveli/")!), "prototype blob blocked")
check(policy.permitsMediaOrigin(scheme: "https", host: "archiverf.ru", port: 443), "media origin")
check(!policy.permitsMediaOrigin(scheme: "http", host: "archiverf.ru", port: 80), "insecure media blocked")

let ticket = "nswt_" + String(repeating: "A", count: 43)
let bootstrap = try NativeWebBootstrap.request(ticket: ticket)
check(bootstrap.url == NativeWebBootstrap.endpoint && bootstrap.httpMethod == "POST", "ticket is POST to exact origin")
check(bootstrap.url?.query == nil && bootstrap.value(forHTTPHeaderField: "Authorization") == nil, "no credential in URL or WebKit bearer")
check(bootstrap.value(forHTTPHeaderField: "Origin") == nil && bootstrap.value(forHTTPHeaderField: "Sec-Fetch-Site") == nil, "native request has no document origin")
check((try JSONSerialization.jsonObject(with: bootstrap.httpBody!)) as? [String: String] == ["ticket": ticket], "only ticket in POST body")
check((try? NativeWebBootstrap.request(ticket: "nsa_" + String(repeating: "A", count: 43))) == nil, "account bearer cannot redeem")
let cookieHeaders = ["Location": "/aveli/connect", "Set-Cookie": "__Secure-aveli-session=; Path=/aveli/; HttpOnly; SameSite=Strict; Max-Age=0; Secure, __Host-aveli_native=" + String(repeating: "N", count: 43) + "; Path=/; HttpOnly; SameSite=Lax; Max-Age=3600; Secure, __Host-aveli_csrf=" + String(repeating: "C", count: 43) + "; Path=/; SameSite=Lax; Max-Age=3600; Secure"]
let bootstrapResponse = HTTPURLResponse(url: NativeWebBootstrap.endpoint, statusCode: 303, httpVersion: nil, headerFields: cookieHeaders)!
let bootstrapCookies = try NativeWebBootstrap.cookies(from: bootstrapResponse)
check(bootstrapCookies.first { $0.name == "__Host-aveli_native" }?.isHTTPOnly == true, "server HTTP-only native cookie preserved")
check(bootstrapCookies.first { $0.name == "__Host-aveli_csrf" }?.isHTTPOnly == false, "CSRF cookie remains readable")
check((try? NativeWebBootstrap.cookies(from: HTTPURLResponse(url: NativeWebBootstrap.endpoint, statusCode: 403, httpVersion: nil, headerFields: cookieHeaders)!)) == nil, "cross_site JSON response cannot become session")
var foreignHeaders = cookieHeaders; foreignHeaders["Location"] = "https://evil.invalid/"
check((try? NativeWebBootstrap.cookies(from: HTTPURLResponse(url: NativeWebBootstrap.endpoint, statusCode: 303, httpVersion: nil, headerFields: foreignHeaders)!)) == nil, "no redirect outside exact application start")
check((try? NativeWebBootstrap.cookies(from: HTTPURLResponse(url: URL(string: "https://evil.invalid/")!, statusCode: 303, httpVersion: nil, headerFields: cookieHeaders)!)) == nil, "no cookies from foreign endpoint")
check(NativeWebBootstrap.documentError(status: 403, mimeType: "application/json") != nil, "HTTP error is native retry UI")
check(NativeWebBootstrap.documentError(status: 200, mimeType: "application/json") != nil, "raw API JSON is never a main document")
check(NativeWebBootstrap.documentError(status: 200, mimeType: "text/html") == nil, "HTML working screen allowed")
print("Семейный архив: Живая память — AVELI native contract: \(count) passed")
'''
with tempfile.TemporaryDirectory(prefix='aveli-swift-contract-') as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(source + tests)
    subprocess.run(['xcrun', 'swift', str(path)], check=True)
