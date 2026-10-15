import Foundation

@main
struct StaffIdentityChecks {
    static func main() async throws {
        let state = String(repeating:"s",count:43), challenge = String(repeating:"c",count:43)
        let code = "nsc_" + String(repeating:"a",count:43)
        let authorization = try StaffIdentityPolicy.authorizeURL(state:state,challenge:challenge)
        let url = URLComponents(url:authorization,resolvingAgainstBaseURL:false)!
        let query = Dictionary(uniqueKeysWithValues:url.queryItems!.map { ($0.name,$0.value!) })
        precondition(url.scheme == "https" && url.host == "archiverf.ru" && url.path == "/native/authorize")
        precondition(query["redirect_uri"] == "archiverf-atlas://oauth/callback" && query["client_id"] == "atlas")
        precondition(query["code_challenge_method"] == "S256" && query["code_challenge"] == challenge)
        let callback = "archiverf-atlas://oauth/callback?state=\(state)&code=\(code)"
        let accepted = try StaffIdentityPolicy.code(from:URL(string:callback)!,state:state)
        precondition(accepted == code, "Current nsc_ code was rejected")
        var rejected = 0
        for invalid in [
            callback.replacingOccurrences(of:"state=\(state)",with:"state=wrong"),
            callback + "&state=\(state)", callback + "&access_token=nsa_secret",
            callback + "#fragment", callback.replacingOccurrences(of:"//oauth/",with:"//user@oauth/"),
            callback.replacingOccurrences(of:"//oauth/",with:"//oauth:443/"),
            callback.replacingOccurrences(of:"//oauth/",with:"//other/"),
            callback.replacingOccurrences(of:"archiverf-atlas:",with:"https:"),
            callback.replacingOccurrences(of:"/callback?",with:"/%63allback?"),
            callback.replacingOccurrences(of:"/callback?",with:"/callback/extra?")
        ] {
            do { _ = try StaffIdentityPolicy.code(from:URL(string:invalid)!,state:state); preconditionFailure("Unsafe callback accepted") }
            catch { rejected += 1 }
        }
        precondition(rejected == 10)
        precondition(StaffIdentityPolicy.validAccountToken("nsa_"+String(repeating:"t",count:43)))
        precondition(!StaffIdentityPolicy.validRuntimeToken("nsa_"+String(repeating:"t",count:43)))
        precondition(StaffIdentityPolicy.validRuntimeToken(String(repeating:"t",count:43)))
        let doubleCallback: URL = try await withCheckedThrowingContinuation { browser in
            let finish = StaffBrowserCompletion(browser)
            finish.finish(.success(URL(string:callback)!))
            finish.finish(.failure(StaffAccessError.cancelled))
            finish.finish(.success(authorization))
        }
        precondition(doubleCallback.absoluteString == callback, "Browser completion was replaced")
        let now = Date(timeIntervalSince1970:1_800_000_000)
        let valid = StaffWorkLease(permissionAuthorized:true,foreground:true,active:true,acknowledged:true,
            expiresAt:now.addingTimeInterval(90),observedAt:now,simulatedBySoftware:false)
        precondition(valid.allowsWork(at:now))
        precondition(!valid.allowsWork(at:now.addingTimeInterval(90)), "Expired work heartbeat reopened")
        var denied = valid; denied.permissionAuthorized = false
        var background = valid; background.foreground = false
        var paused = valid; paused.active = false
        var unconfirmed = valid; unconfirmed.acknowledged = false
        var stale = valid; stale.observedAt = now.addingTimeInterval(-90)
        var future = valid; future.observedAt = now.addingTimeInterval(31)
        var simulated = valid; simulated.simulatedBySoftware = true
        var missing = valid; missing.observedAt = nil
        for closed in [denied,background,paused,unconfirmed,stale,future,simulated,missing] {
            precondition(!closed.allowsWork(at:now), "Invalid work condition admitted new work")
        }
        print("Staff identity callback, one-shot completion and foreground work lease checks passed; no live account/GPS claim")
    }
}
