#!/usr/bin/env python3
"""Семейный архив: Живая память — execute the production Swift auth/URL contract."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = "\n".join((root / 'AVELI/App' / name).read_text() for name in ['NativeAuthContract.swift', 'URLPolicy.swift'])
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
print("Семейный архив: Живая память — AVELI native contract: \(count) passed")
'''
with tempfile.TemporaryDirectory(prefix='aveli-swift-contract-') as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(source + tests)
    subprocess.run(['xcrun', 'swift', str(path)], check=True)
