import Foundation
import Testing
@testable import AtlasCore

private let staffVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
private let staffState = "cD4n_zAj9dX76uc5SQa_8tsrsllJHsa8XRlcP7QExzM"
private let staffNow = Date(timeIntervalSince1970: 1_792_152_000)
private let staffRuntimeToken = String(repeating: "R", count: 43)

@Test func staffIdentityPKCES256MatchesRFC7636AndRegisteredWebsiteFlow() throws {
    let request = try StaffIdentityPolicy.makePKCE(verifier: staffVerifier, state: staffState)
    #expect(request.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(!request.challenge.contains("="))
    let url = try #require(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false))
    #expect(url.scheme == "https")
    #expect(url.host == "archiverf.ru")
    #expect(url.path == "/native/authorize")
    let values = Dictionary(uniqueKeysWithValues: try #require(url.queryItems).map { ($0.name, $0.value ?? "") })
    #expect(values.count == 6)
    #expect(values["response_type"] == "code")
    #expect(values["client_id"] == "atlas")
    #expect(values["redirect_uri"] == "archiverf-atlas://oauth/callback")
    #expect(values["code_challenge_method"] == "S256")
    #expect(values["state"] == staffState)
    #expect(!request.authorizationURL.absoluteString.contains(staffVerifier))
}

@Test(arguments: [String(repeating: "a", count: 42), String(repeating: "a", count: 129),
                  String(repeating: "é", count: 43), String(repeating: "a", count: 42) + "+",
                  String(repeating: "a", count: 42) + "\n", String(repeating: "a", count: 42) + "="])
func staffIdentityRejectsNonRFC7636Verifier(_ verifier: String) {
    #expect(throws: StaffIdentityError.invalidVerifier) { try StaffIdentityPolicy.makePKCE(verifier: verifier, state: staffState) }
}

@Test func staffIdentityAllowsRFCVerifierBoundsAndRejectsWeakOrInjectedState() throws {
    for length in [43, 128] {
        _ = try StaffIdentityPolicy.makePKCE(verifier: String(repeating: "~", count: length), state: staffState)
    }
    for state in ["", "predictable", String(repeating: "s", count: 257), staffState + "&code=attacker", staffState + "\n"] {
        #expect(throws: StaffIdentityError.invalidState) { try StaffIdentityPolicy.makePKCE(verifier: staffVerifier, state: state) }
    }
}

@Test func staffIdentityAcceptsOnlyMatchingCallbackAndNeverReturnsUntrustedErrorText() throws {
    let valid = try #require(URL(string: "archiverf-atlas://oauth/callback?code=one-time-code_123&state=" + staffState))
    #expect(try StaffIdentityPolicy.validateCallback(valid, expectedState: staffState) == "one-time-code_123")
    let mismatch = try #require(URL(string: "archiverf-atlas://oauth/callback?code=private-code&state=" + String(repeating: "x", count: 43)))
    #expect(throws: StaffIdentityError.stateMismatch) { try StaffIdentityPolicy.validateCallback(mismatch, expectedState: staffState) }
    let denied = try #require(URL(string: "archiverf-atlas://oauth/callback?error=access_denied&error_description=PRIVATE_SECRET&state=" + staffState))
    #expect(throws: StaffIdentityError.authorizationDenied) { try StaffIdentityPolicy.validateCallback(denied, expectedState: staffState) }
    #expect(!StaffIdentityError.authorizationDenied.localizedDescription.contains("PRIVATE_SECRET"))
}

@Test func staffIdentityOpaqueAuthorizationCodeSurvivesURLEncodingAndJSONWithoutInventingFields() throws {
    let code = "opaque+/=._~%\"\\code"
    var callback = URLComponents(url: StaffIdentityPolicy.callbackURL, resolvingAgainstBaseURL: false)!
    callback.queryItems = [.init(name: "code", value: code), .init(name: "state", value: staffState)]
    let accepted = try StaffIdentityPolicy.validateCallback(try #require(callback.url), expectedState: staffState)
    #expect(accepted == code)
    let request = try StaffCodeExchangeRequest(code: accepted, codeVerifier: staffVerifier)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String])
    #expect(object["code"] == code)
    #expect(object.count == 4)
}

@Test(arguments: [
    "https://oauth/callback?code=x&state=STATE",
    "archiverf-atlas://attacker/callback?code=x&state=STATE",
    "archiverf-atlas://oauth.evil/callback?code=x&state=STATE",
    "archiverf-atlas://user@oauth/callback?code=x&state=STATE",
    "archiverf-atlas://oauth:443/callback?code=x&state=STATE",
    "archiverf-atlas://oauth/callback/extra?code=x&state=STATE",
    "archiverf-atlas://oauth/%63allback?code=x&state=STATE",
    "archiverf-atlas://oauth/callback?code=x&state=STATE#fragment",
    "archiverf-atlas://oauth/callback?code=x&code=second&state=STATE",
    "archiverf-atlas://oauth/callback?code=x&state=STATE&state=STATE",
    "archiverf-atlas://oauth/callback?code=x&state=STATE&redirect_uri=https://evil.test",
    "archiverf-atlas://oauth/callback?code=x&error=denied&state=STATE",
    "archiverf-atlas://oauth/callback?code=x&error_description=secret&state=STATE",
    "archiverf-atlas://oauth/callback?code=&state=STATE",
    "archiverf-atlas://oauth/callback?code=header%0D%0Ainjection&state=STATE",
    "archiverf-atlas://oauth/callback?code=x",
    "archiverf-atlas://oauth/callback?code=x&state=STATE%00"
])
func staffIdentityRejectsForgedAmbiguousOrMalformedCallbacks(_ template: String) throws {
    let callback = try #require(URL(string: template.replacingOccurrences(of: "STATE", with: staffState)))
    #expect(throws: (any Error).self) { try StaffIdentityPolicy.validateCallback(callback, expectedState: staffState) }
}

@Test func staffIdentityRetainsAtlasPrefixAndEncodesQueryValuesWithoutChangingRoute() throws {
    let base = try StaffIdentityPolicy.trustedRuntimeBaseURL("https://archiverf.ru/atlas/")
    let url = try StaffIdentityPolicy.dataURL(baseURL: base, relativePath: "v1/projects/902bbdf7-3901-4d41-a803-d202b952a727/materials",
                                             queryItems: [.init(name: "cursor", value: "opaque/with?url=https://evil.test&offset=100")])
    #expect(url.host == "archiverf.ru")
    #expect(url.path == "/atlas/v1/projects/902bbdf7-3901-4d41-a803-d202b952a727/materials")
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count == 1)
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "opaque/with?url=https://evil.test&offset=100")
    #expect(try StaffIdentityPolicy.trustedRuntimeBaseURL("https://archiverf.ru:443/atlas") == base)
    #expect(try StaffIdentityPolicy.nativeURL(relativePath: "account/context", queryItems: [.init(name: "client_id", value: "atlas")]).absoluteString
            == "https://archiverf.ru/api/native/account/context?client_id=atlas")
}

@Test(arguments: ["http://archiverf.ru/atlas/", "https://archiverf.ru.evil.test/atlas/", "https://evil.test/atlas/",
                  "https://archiverf.ru@evil.test/atlas/", "https://user@archiverf.ru/atlas/", "https://archiverf.ru:8443/atlas/",
                  "https://archiverf.ru/", "https://archiverf.ru/atlas/v1/", "https://archiverf.ru/%61tlas/",
                  "https://archiverf.ru/atlas//", "https://archiverf.ru/atlas/../api/", "https://archiverf.ru/atlas/?token=secret",
                  "https://archiverf.ru/atlas/#fragment", " https://archiverf.ru/atlas/", "https://archiverf.ru./atlas/"])
func staffIdentityRejectsRuntimeBaseURLExfiltrationAndPrefixConfusion(_ value: String) {
    #expect(throws: StaffIdentityError.untrustedURL) { try StaffIdentityPolicy.trustedRuntimeBaseURL(value) }
}

@Test(arguments: ["/v1/projects", "//evil.test/v1/projects", "https://evil.test/v1/projects", "v1/../api/native/context",
                  "v1/%2e%2e/api/native/context", "v1/%252e%252e/api", "v1/projects?access_token=secret",
                  "v1/projects#fragment", "v1\\projects", "v1//projects", "v1/projects/", "atlas/v1/projects", "projects", "v1"])
func staffIdentityRejectsTraversalAbsoluteAndAmbiguousDataPaths(_ path: String) {
    #expect(throws: StaffIdentityError.invalidPath) {
        try StaffIdentityPolicy.dataURL(baseURL: StaffIdentityPolicy.dataBaseURL, relativePath: path)
    }
}

@Test func staffIdentityExchangeAndRuntimeBodiesMatchActualWebsiteWithoutOAuthExtras() throws {
    let encoder = JSONEncoder()
    let exchange = try StaffCodeExchangeRequest(code: "one-use-code", codeVerifier: staffVerifier)
    let json = try #require(JSONSerialization.jsonObject(with: encoder.encode(exchange)) as? [String: Any])
    #expect(Set(json.keys) == Set(["client_id", "code", "redirect_uri", "code_verifier"]))
    #expect(json["client_id"] as? String == "atlas")
    #expect(json["redirect_uri"] as? String == "archiverf-atlas://oauth/callback")
    #expect(json["code_verifier"] as? String == staffVerifier)
    let runtime = try StaffRuntimeRequest(taskID: "website-task-0007")
    let body = try #require(JSONSerialization.jsonObject(with: encoder.encode(runtime)) as? [String: Any])
    #expect(Set(body.keys) == Set(["client_id", "task_id", "share_with_task", "share_originals"]))
    #expect(body["task_id"] as? String == "website-task-0007")
    #expect(body["share_with_task"] as? Bool == false)
    #expect(body["share_originals"] as? Bool == false)
    let optedIn = try StaffRuntimeRequest(taskID: "website-task-0007", shareWithTask: true, shareOriginals: true)
    let optedInBody = try #require(JSONSerialization.jsonObject(with: encoder.encode(optedIn)) as? [String: Any])
    #expect(optedInBody["share_with_task"] as? Bool == true)
    #expect(optedInBody["share_originals"] as? Bool == true)
    let logout = try #require(JSONSerialization.jsonObject(with: encoder.encode(StaffLogoutRequest())) as? [String: String])
    #expect(logout == ["client_id": "atlas"])
    #expect(throws: StaffIdentityError.invalidTask) { try StaffRuntimeRequest(taskID: "") }
    #expect(throws: StaffIdentityError.invalidTask) { try StaffRuntimeRequest(taskID: "forged\ntask") }
}

@Test func staffIdentityAccountAndRuntimeTokensCannotBeInterchangedOrOutliveAccount() throws {
    let accountExpiry = staffNow.addingTimeInterval(86_400), runtimeExpiry = staffNow.addingTimeInterval(3_600)
    try StaffIdentityPolicy.validateAccountToken("nsa_privateAccountBearer", expiresAt: accountExpiry, now: staffNow)
    try StaffIdentityPolicy.validateRuntimeToken(staffRuntimeToken, expiresAt: runtimeExpiry, accountExpiresAt: accountExpiry, now: staffNow)
    try StaffIdentityPolicy.validateRuntimeTokenFormat("+/=" + String(repeating: "r", count: 40))
    try StaffIdentityPolicy.validateAccountTokenFormat("nsa_opaque+/=token")
    for malformed in ["nsa_", "nsa_bad token", "nsa_bad\ttoken", "nsa_bad\r\nInjected:token", "nsa_é"] {
        #expect(throws: StaffIdentityError.invalidAccountToken) { try StaffIdentityPolicy.validateAccountTokenFormat(malformed) }
    }
    for malformed in [String(repeating: "a", count: 42), String(repeating: "a", count: 44),
                      String(repeating: "a", count: 42) + " ", String(repeating: "a", count: 42) + "\u{7f}"] {
        #expect(throws: StaffIdentityError.invalidRuntimeToken) { try StaffIdentityPolicy.validateRuntimeTokenFormat(malformed) }
    }
    #expect(throws: StaffIdentityError.invalidAccountToken) {
        try StaffIdentityPolicy.validateAccountToken(staffRuntimeToken, expiresAt: accountExpiry, now: staffNow)
    }
    #expect(throws: StaffIdentityError.invalidRuntimeToken) {
        try StaffIdentityPolicy.validateRuntimeToken("nsa_" + String(repeating: "a", count: 39), expiresAt: runtimeExpiry,
                                                    accountExpiresAt: accountExpiry, now: staffNow)
    }
    #expect(throws: StaffIdentityError.invalidRuntimeToken) {
        try StaffIdentityPolicy.validateRuntimeToken(staffRuntimeToken + "\n", expiresAt: runtimeExpiry,
                                                    accountExpiresAt: accountExpiry, now: staffNow)
    }
    #expect(throws: StaffIdentityError.invalidExpiry) {
        try StaffIdentityPolicy.validateRuntimeToken(staffRuntimeToken, expiresAt: accountExpiry.addingTimeInterval(1),
                                                    accountExpiresAt: accountExpiry, now: staffNow)
    }
    #expect(throws: StaffIdentityError.expiredSession) {
        try StaffIdentityPolicy.validateRuntimeToken(staffRuntimeToken, expiresAt: staffNow,
                                                    accountExpiresAt: accountExpiry, now: staffNow)
    }
    #expect(throws: StaffIdentityError.invalidExpiry) {
        try StaffIdentityPolicy.validateAccountToken("nsa_account", expiresAt: staffNow.addingTimeInterval(172_800), now: staffNow)
    }
    #expect(throws: StaffIdentityError.invalidExpiry) {
        try StaffIdentityPolicy.validateAccountToken("nsa_account", expiresAt: Date(timeIntervalSince1970: .nan), now: staffNow)
    }
}

@Test func staffIdentityUTCExpiryParserDoesNotConfuseMaterialMillisOrReferenceEpoch() throws {
    let whole = try StaffIdentityPolicy.parseUTCDate("2026-10-16T12:00:00Z")
    let precise = try StaffIdentityPolicy.parseUTCDate("2026-10-16T12:00:00.125Z")
    #expect(try StaffIdentityPolicy.parseUTCDate("2026-10-16T12:00:00+00:00") == whole)
    #expect(try StaffIdentityPolicy.parseUTCDate("2026-10-16T12:00:00.125+00:00") == precise)
    #expect(abs(whole.timeIntervalSince1970 - 1_792_152_000) < 0.001)
    #expect(abs(precise.timeIntervalSince(whole) - 0.125) < 0.001)
    for invalid in ["1792152000000", "2026-10-16", "2026-10-16T12:00:00", "2026-10-16T12:00:00+03:00",
                    "2026-10-16T12:00:00-00:00", "2026-10-16T12:00:00ZjunkZ", "2026-02-30T12:00:00Z", "2026-10-16T25:00:00Z"] {
        #expect(throws: StaffIdentityError.invalidDate) { try StaffIdentityPolicy.parseUTCDate(invalid) }
    }
}
