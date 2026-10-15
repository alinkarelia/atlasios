#!/usr/bin/env python3
"""Exercise the production local-entry/capture/server-transfer rules in Swift.

Only account/GPS/runtime inputs are fixtures. Admission and binding methods are
extracted verbatim from StaffAccountSession, not reimplemented in the test.
No real credentials, server, location manager or physical camera is used.
"""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import tempfile

ADAPTERS = Path(__file__).resolve().parent.parent
production = (ADAPTERS / "StaffAccountSession.swift").read_text()


def declaration(signature: str) -> str:
    start = production.index(signature)
    opening = production.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (production[end] == "{") - (production[end] == "}")
        end += 1
    return production[start:end]


SWIFT = r'''
import Foundation

struct FixtureContext {
    struct User { let id: String; let isChief: Bool }
    struct Assignment { let id: String; let projectID: String }
    let user: User; let tasks: [Assignment]
}
final class FixtureLocation { var canWork = false }
final class FixtureTeam { var connected = false }
@MainActor final class AccountHarness {
    var authenticated = true
    var context: FixtureContext?
    var selectedTaskID: String?
    var runtimeWorkspaceID: String?
    var runtimeExpiresAt = Date.distantPast
    let location = FixtureLocation(); let team = FixtureTeam()
    struct Binding { let accountID: String; let taskID: String; let workspaceID: String }
    var bindings: [String: Binding] = [:]
    var selectedTask: FixtureContext.Assignment? { context?.tasks.first { $0.id == selectedTaskID } }
    //__ENTRY__
    //__WORK__
    //__TRANSFER__
    //__BOUND__
    //__MATCH__
}
@main struct Checks {
    @MainActor static func main() {
        let session = AccountHarness(), project = UUID(), otherProject = UUID()
        var scenarios = 0
        session.context = .init(user:.init(id:"chief",isChief:true),tasks:[])
        precondition(session.canOpenApplication, "Chief without assignments was locked out")
        precondition(!session.canWork() && !session.canTransfer(), "Missing GPS admitted new work")
        scenarios += 1
        session.location.canWork = true
        precondition(session.canWork() && session.canWork(projectID:project), "Chief needs an assignment for local capture")
        precondition(!session.canTransfer() && !session.canTransfer(projectID:project), "Chief local capture fabricated upload access")
        scenarios += 1
        session.context = .init(user:.init(id:"staff",isChief:false),tasks:[])
        precondition(session.canOpenApplication, "Staff without assignments cannot browse local projects")
        precondition(!session.canWork() && !session.canTransfer(), "Unassigned staff admitted new capture/upload")
        scenarios += 1
        session.context = .init(user:.init(id:"staff",isChief:false),tasks:[.init(id:"task",projectID:"workspace")])
        session.selectedTaskID = "task"; session.runtimeWorkspaceID = "workspace"
        session.runtimeExpiresAt = Date.distantFuture; session.team.connected = true
        session.bindings[project.uuidString] = .init(accountID:"staff",taskID:"task",workspaceID:"workspace")
        precondition(session.canWork(projectID:project) && session.canTransfer(projectID:project))
        precondition(!session.canWork(projectID:otherProject) && !session.canTransfer(projectID:otherProject))
        scenarios += 1
        for binding in [
            AccountHarness.Binding(accountID:"another-user",taskID:"task",workspaceID:"workspace"),
            AccountHarness.Binding(accountID:"staff",taskID:"another-task",workspaceID:"workspace"),
            AccountHarness.Binding(accountID:"staff",taskID:"task",workspaceID:"another-workspace")
        ] {
            session.bindings[project.uuidString] = binding
            precondition(!session.canTransfer(projectID:project) && !session.projectIsBound(project), "Cross-scope upload admitted")
        }
        scenarios += 1
        session.bindings[project.uuidString] = .init(accountID:"staff",taskID:"task",workspaceID:"workspace")
        session.runtimeExpiresAt = Date.distantPast
        precondition(session.canOpenApplication && !session.canWork() && !session.canTransfer(), "Expired task locked local navigation or permitted upload")
        scenarios += 1
        session.context = .init(user:.init(id:"chief",isChief:true),tasks:[])
        session.location.canWork = false
        precondition(session.canOpenApplication && !session.canWork() && !session.canTransfer(), "GPS denial locked navigation or allowed capture")
        scenarios += 1
        session.location.canWork = true; session.authenticated = false
        precondition(!session.canOpenApplication && !session.canWork() && !session.canTransfer(), "Revoked account retained access")
        scenarios += 1
        print("Actual staff entry/capture/transfer policy: \(scenarios) controlled scenarios passed; no live account/GPS claim")
    }
}
'''
for placeholder, signature in [
    ("//__ENTRY__", "var canOpenApplication:"),
    ("//__WORK__", "func canWork("),
    ("//__TRANSFER__", "func canTransfer("),
    ("//__BOUND__", "func projectIsBound("),
    ("//__MATCH__", "private func bindingMatches("),
]:
    SWIFT = SWIFT.replace(placeholder, declaration(signature))

# The tested upload rule must actually be wired to server operations, while
# capture adapters use the separate tested local-work rule.
assert "team.workAuthorization = { [weak self] in self?.canTransfer() == true }" in production
assert "team.projectAuthorization = { [weak self] project in self?.canTransfer(projectID:project) == true }" in production
assert "StaffWorkAccess.permission = { [weak self] project in self?.canWork(projectID:project) == true }" in production
compiler = os.environ.get("ATLAS_SWIFTC") or shutil.which("swiftc")
if not compiler:
    raise SystemExit("Swift compiler required. No native policy test was run.")
with tempfile.TemporaryDirectory() as directory:
    source = Path(directory) / "ActualStaffEntryPolicy.swift"
    binary = Path(directory) / "staff-entry-policy"
    source.write_text(SWIFT)
    subprocess.run([compiler, "-swift-version", "6", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
print("Production StaffAccountSession SHA-256:", hashlib.sha256(production.encode()).hexdigest())
