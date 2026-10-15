#!/usr/bin/env python3
"""Exercise actual production account-bound sender/stop/task methods.

Only browser/CoreLocation/HTTP edges are fixtures. The production closures,
generation comparisons, task selection and deferred stop are extracted verbatim;
the test does not reimplement their admission rules or contact a real account.
"""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ADAPTERS = HERE.parent
account = (ADAPTERS / "StaffAccountSession.swift").read_text()
location = (ADAPTERS / "StaffWorkLocation.swift").read_text()


def method(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


SWIFT = r'''
import Foundation

struct StaffAccountToken: Sendable { let accessToken: String; var valid: Bool { true } }
struct StaffLocationResponse: Decodable, Sendable { let workAllowed: Bool }
struct StaffRuntimeSession: Decodable, Sendable {
    let clientID: String; let baseURL: URL; let tokenType: String; let taskID: String
    let workspaceID: String; let accessToken: String; let expiresAt: String
}
struct FixtureContext {
    struct Assignment { let id: String; let projectID: String }
    let tasks: [Assignment]
}
@MainActor final class FixtureManager { func stopUpdatingLocation() {} }
@MainActor final class FixtureTeam {
    var taskID: String?; var generation = 0
    var allowedProjectIDs: () -> Set<UUID> = { [] }
    func clearRuntime() { generation += 1; taskID = nil }
    func installRuntime(_ runtime: StaffRuntimeSession) throws { taskID = runtime.taskID }
}
@MainActor enum StaffAccountAPI {
    struct Request { let path: String; let token: String; let data: Data? }
    static var requests: [Request] = []
    static var hold = false
    static var failure: StaffAccessError?
    static var pending: CheckedContinuation<StaffLocationResponse, Error>?
    static func reset() { precondition(pending == nil); requests = []; hold = false; failure = nil }
    static func request<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data? = nil,
                                                token: String? = nil) async throws -> T {
        requests.append(.init(path:path,token:token ?? "",data:body))
        if path == "api/native/account/runtime" {
            return StaffRuntimeSession(clientID:"atlas",baseURL:StaffIdentityPolicy.runtimeOrigin,
                tokenType:"Bearer",taskID:"task-a",workspaceID:"workspace-a",
                accessToken:String(repeating:"r",count:43),expiresAt:"2100-01-01T00:00:00Z") as! T
        }
        let result: StaffLocationResponse
        if hold { result = try await withCheckedThrowingContinuation { pending = $0 } }
        else if let failure { throw failure }
        else { result = .init(workAllowed:true) }
        return result as! T
    }
    static func reply(_ result: Result<StaffLocationResponse, Error>) {
        let waiter = pending; pending = nil; waiter?.resume(with:result)
    }
}
@MainActor final class LocationHarness {
    var generation = UUID(); var timer: Task<Void,Never>?; let manager = FixtureManager()
    var active = true; var lastFix: Date? = Date(); var acknowledged = true
    var expiresAt = Date.distantFuture; var message = ""; var changed: (() -> Void)?
    var send: ((Data,Bool) async throws -> StaffLocationResponse)?
    var sequence = 0; let deviceID = "fixture-installation"
    private func nextSequence() -> Int? { sequence += 1; return sequence }
    //__STOP__
}
@MainActor final class AccountHarness {
    var generation = UUID(); var account: StaffAccountToken?
    let location = LocationHarness(); let team = FixtureTeam()
    var busy = false; var issue: String?; var selectedTaskID: String?
    var runtimeWorkspaceID: String?; var runtimeExpiresAt = Date.distantPast
    var context: FixtureContext? = .init(tasks:[.init(id:"task-a",projectID:"workspace-a")])
    var authenticated: Bool { account != nil }
    var allowedProjectIDs: Set<UUID> { [] }
    var currentAccessErrors = 0
    func updateWorkGate() {}
    func handleAccessError(_ error: Error) { currentAccessErrors += 1; account = nil }
    func replaceAccount(_ value: String?) {
        generation = UUID(); account = value.map { StaffAccountToken(accessToken:$0) }
        if let account { configureLocationSender(account,ticket:generation) }
        else { location.send = nil }
    }
    //__CONFIGURE__
    //__SEND__
    //__SELECT__
}
@main struct Checks {
    @MainActor static func drain() async { for _ in 0..<30 { await Task.yield() } }
    @MainActor static func waitForRequest() async {
        for _ in 0..<1_000 {
            if !StaffAccountAPI.requests.isEmpty { return }
            await Task.yield()
        }
        preconditionFailure("Deferred captured stop never reached fixture transport")
    }
    @MainActor static func main() async throws {
        let oldToken = "nsa_" + String(repeating:"a",count:43)
        let newToken = "nsa_" + String(repeating:"b",count:43)
        var passed = 0
        do {
            StaffAccountAPI.reset(); let session = AccountHarness(); session.replaceAccount(oldToken)
            let identity = session.generation
            await session.selectTask("task-a")
            precondition(session.selectedTaskID == "task-a" && session.team.taskID == "task-a")
            precondition(session.generation == identity, "Selecting a task invalidated the account heartbeat sender")
            let send = session.location.send!
            let first = try await send(Data("first-heartbeat".utf8),false)
            let renewed = try await send(Data("renewed-heartbeat".utf8),false)
            precondition(first.workAllowed && renewed.workAllowed && StaffAccountAPI.requests.count == 3)
            precondition(StaffAccountAPI.requests.allSatisfy { $0.token == oldToken })
            passed += 1
        }
        do {
            StaffAccountAPI.reset(); StaffAccountAPI.failure = .denied
            let session = AccountHarness(); session.replaceAccount(oldToken)
            session.location.stop(reason:"off_duty")
            precondition(!session.location.acknowledged && !session.location.active, "Local stop waited for HTTP")
            session.replaceAccount(newToken)
            session.location.acknowledged = true // New login's independent, current work state.
            await waitForRequest(); await drain()
            precondition(StaffAccountAPI.requests[0].token == oldToken, "Old stop used a newer login credential")
            let body = try JSONSerialization.jsonObject(with:StaffAccountAPI.requests[0].data!) as! [String:Any]
            precondition(body["reason"] as? String == "off_duty" && body["sequence"] as? Int == 1)
            precondition(session.account?.accessToken == newToken && session.location.acknowledged && session.currentAccessErrors == 0,
                         "Old stop denial revoked or changed a new login")
            passed += 1
        }
        do {
            StaffAccountAPI.reset(); StaffAccountAPI.hold = true
            let session = AccountHarness(); session.replaceAccount(oldToken); let send = session.location.send!
            let inFlight = Task { try await send(Data(),false) }
            await waitForRequest()
            session.replaceAccount(newToken)
            StaffAccountAPI.reply(.success(.init(workAllowed:true)))
            do { _ = try await inFlight.value; preconditionFailure("Old heartbeat response entered new login") }
            catch { }
            precondition(session.account?.accessToken == newToken && session.currentAccessErrors == 0)
            precondition(StaffAccountAPI.requests[0].token == oldToken)
            passed += 1
        }
        print("Actual account-bound location sender/stop/task methods: \(passed) controlled scenarios passed; no live account/GPS claim")
    }
}
'''
SWIFT = SWIFT.replace("//__STOP__", method(location, "func stop(reason:"))
SWIFT = SWIFT.replace("//__CONFIGURE__", method(account, "private func configureLocationSender("))
SWIFT = SWIFT.replace("//__SEND__", method(account, "private func sendLocation("))
SWIFT = SWIFT.replace("//__SELECT__", method(account, "func selectTask("))
compiler = os.environ.get("ATLAS_SWIFTC") or shutil.which("swiftc")
if not compiler:
    raise SystemExit("Swift 6 compiler required; set ATLAS_SWIFTC to its path. No native test was run.")
with tempfile.TemporaryDirectory() as directory:
    source = Path(directory) / "ActualStaffLocationChecks.swift"
    source.write_text(SWIFT)
    binary = Path(directory) / "staff-location-session-checks"
    subprocess.run([compiler, "-swift-version", "6", str(ADAPTERS / "StaffIdentityPolicy.swift"),
                    str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
print("Production StaffAccountSession SHA-256:", hashlib.sha256(account.encode()).hexdigest())
