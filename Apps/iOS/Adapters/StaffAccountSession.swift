import Foundation
import Combine
import CryptoKit
import Security
import AuthenticationServices
import UIKit

@MainActor
final class StaffAccountSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var context: StaffAccountContext?
    @Published private(set) var busy = false
    @Published private(set) var issue: String?
    @Published private(set) var workAllowed = false
    @Published private(set) var selectedTaskID: String?
    @Published private(set) var runtimeExpiresAt: Date = .distantPast
    @Published private(set) var contextVerified = false
    @Published private(set) var workingSessionActive = false
    let location = StaffWorkLocation()
    var workChanged: (() -> Void)?
    private let team: TeamService
    private let bindingURL: URL
    private var account: StaffAccountToken?
    private var authBrowser: ASWebAuthenticationSession?
    private var authCompletion: StaffBrowserCompletion?
    private var generation = UUID()
    private var runtimeWorkspaceID: String?
    private var bindings: [String: Binding] = [:]
    private var bindingsReadable = true
    private struct Binding: Codable { let accountID: String; let taskID: String; let workspaceID: String }

    init(team: TeamService, directory: URL) {
        self.team = team; bindingURL = directory.appendingPathComponent("staff-project-bindings-v1.json")
        super.init()
        if FileManager.default.fileExists(atPath:bindingURL.path) {
            if let bytes = try? Data(contentsOf:bindingURL), let saved = try? JSONDecoder().decode([String:Binding].self,from:bytes) { bindings = saved }
            else { bindingsReadable = false; issue = "Не удалось прочитать связи заданий. Исходники сохранены; обратитесь к руководителю." }
        }
        location.changed = { [weak self] in self?.updateWorkGate() }
        team.workAuthorization = { [weak self] in self?.canTransfer() == true }
        team.projectAuthorization = { [weak self] project in self?.canTransfer(projectID:project) == true }
        team.onAccessDenied = { [weak self] in self?.revoke() }
        StaffWorkAccess.permission = { [weak self] project in self?.canWork(projectID:project) == true }
    }
    var hasAccount: Bool { account != nil }
    var authenticated: Bool { account?.valid == true && contextVerified && context != nil }
    // An assignment authorizes a server transfer, not entry into the app.
    // Existing local projects and exports remain reachable without one.
    var canOpenApplication: Bool { authenticated }
    var selectedTask: StaffAccountContext.Assignment? { context?.tasks.first { $0.id == selectedTaskID } }
    var allowedProjectIDs: Set<UUID> {
        Set(bindings.compactMap { id, binding in bindingMatches(binding) ? UUID(uuidString:id) : nil })
    }
    func canWork(projectID: UUID? = nil) -> Bool {
        guard authenticated, location.canWork else { return false }
        // The chief may create and capture a local project before assigning it.
        // This does not mint a runtime credential or change an existing binding.
        if context?.user.isChief == true { return true }
        return canTransfer(projectID:projectID)
    }
    func canTransfer(projectID: UUID? = nil) -> Bool {
        guard authenticated, let task = selectedTask, task.projectID == runtimeWorkspaceID, team.connected, runtimeExpiresAt > Date(), location.canWork else { return false }
        if let projectID { return bindings[projectID.uuidString].map(bindingMatches) == true }
        return true
    }
    func projectIsBound(_ projectID: UUID) -> Bool { bindings[projectID.uuidString].map(bindingMatches) == true }
    func bindProject(_ projectID: UUID) throws {
        guard bindingsReadable else { throw StaffAccessError.wrongProject }
        guard authenticated, let task = selectedTask, let workspace = runtimeWorkspaceID, let accountID = context?.user.id else {
            throw StaffAccessError.needsTask
        }
        if let existing = bindings[projectID.uuidString] {
            guard bindingMatches(existing) else { throw StaffAccessError.wrongProject }
            return
        }
        var next = bindings; next[projectID.uuidString] = Binding(accountID:accountID, taskID:task.id, workspaceID:workspace)
        try JSONEncoder().encode(next).write(to:bindingURL, options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        bindings = next; updateWorkGate()
    }
    private func bindingMatches(_ binding: Binding) -> Bool {
        binding.accountID == context?.user.id && binding.taskID == selectedTaskID && binding.workspaceID == runtimeWorkspaceID
    }
    func restore() async {
        #if DEBUG && targetEnvironment(simulator)
        // This fixture exercises the production root gate, without the broad
        // local-tools bypass, real credentials, HTTP, or a fake GPS grant.
        if StaffWorkAccess.diagnosticChiefWithoutTasks {
            account = StaffAccountToken(accessToken:"nsa_" + String(repeating:"f",count:43), tokenType:"Bearer",
                expiresAt:"2100-01-01T00:00:00Z",expiresIn:86_400,clientID:"atlas")
            context = StaffAccountContext(clientID:"atlas",sessionID:"simulator-chief-without-tasks",
                expiresAt:"2100-01-01T00:00:00Z",user:.init(id:"simulator-chief",name:"Главный · UI-проверка",isChief:true),
                projects:[],tasks:[],permissions:.init(locationRequired:true))
            contextVerified = true; updateWorkGate(); return
        }
        #endif
        guard let data = StaffKeychain.read(), let token = try? JSONDecoder().decode(StaffAccountToken.self, from:data), token.valid else {
            StaffKeychain.remove(); return
        }
        account = token; configureLocationSender(token, ticket:generation)
        await refresh()
    }
    func signIn() async {
        guard !busy else { return }
        let ticket = UUID(); generation = ticket; busy = true; issue = nil
        contextVerified = false; workingSessionActive = false; location.stop(reason:"user_stop")
        team.clearRuntime(); selectedTaskID = nil; runtimeWorkspaceID = nil; runtimeExpiresAt = .distantPast; updateWorkGate()
        defer { if generation == ticket { busy = false; authBrowser = nil; authCompletion = nil } }
        do {
            let verifier = try Self.random(); let state = try Self.random()
            let challenge = Data(SHA256.hash(data:Data(verifier.utf8))).base64URL
            let url = try StaffIdentityPolicy.authorizeURL(state:state, challenge:challenge)
            let callback: URL = try await withCheckedThrowingContinuation { continuation in
                let completion = StaffBrowserCompletion(continuation)
                authCompletion = completion
                let browser = ASWebAuthenticationSession(url:url, callbackURLScheme:StaffIdentityPolicy.callbackScheme) { url, error in
                    if let url { completion.finish(.success(url)) }
                    else { completion.finish(.failure(StaffAccessError.cancelled)) }
                }
                browser.presentationContextProvider = self; browser.prefersEphemeralWebBrowserSession = false
                authBrowser = browser
                if !browser.start() { completion.finish(.failure(StaffAccessError.cancelled)) }
            }
            try Task.checkCancellation()
            guard ticket == generation else { throw CancellationError() }
            authCompletion = nil
            let code = try StaffIdentityPolicy.code(from:callback, state:state)
            let body = try JSONEncoder().encode(["client_id":"atlas", "code":code, "redirect_uri":StaffIdentityPolicy.redirect, "code_verifier":verifier])
            let token: StaffAccountToken = try await StaffAccountAPI.request("api/native/oauth/token",method:"POST",body:body)
            try Task.checkCancellation()
            guard ticket == generation, token.valid else { throw StaffAccessError.invalidResponse }
            try StaffKeychain.save(JSONEncoder().encode(token))
            team.clearRuntime(); account = token; configureLocationSender(token, ticket:ticket); selectedTaskID = nil; runtimeWorkspaceID = nil; runtimeExpiresAt = .distantPast
            try await fetchContext(ticket:ticket)
        } catch {
            if ticket == generation { issue = error.localizedDescription; handleAccessError(error) }
        }
    }
    func refresh() async {
        guard account?.valid == true, !busy else { return }
        let ticket = generation; busy = true; issue = nil
        defer { if ticket == generation { busy = false } }
        do { try await fetchContext(ticket:ticket) }
        catch {
            guard ticket == generation else { return }
            contextVerified = false; team.clearRuntime(); runtimeExpiresAt = .distantPast
            location.stop(reason:"user_stop"); issue = error.localizedDescription; handleAccessError(error); updateWorkGate()
        }
    }
    private func fetchContext(ticket: UUID) async throws {
        guard let account, account.valid else { throw StaffAccessError.expired }
        let result: StaffAccountContext = try await StaffAccountAPI.request("api/native/account/context?client_id=atlas",token:account.accessToken)
        guard ticket == generation, result.clientID == "atlas", result.permissions.locationRequired,
              (StaffIdentityPolicy.date(result.expiresAt) ?? .distantPast) > Date() else { throw StaffAccessError.invalidResponse }
        let priorEpoch = selectedTask?.assignmentEpoch
        context = result; contextVerified = true
        if let selectedTaskID, !result.tasks.contains(where:{$0.id == selectedTaskID && $0.assignmentEpoch == priorEpoch}) {
            self.selectedTaskID = nil; runtimeWorkspaceID = nil; runtimeExpiresAt = .distantPast; team.clearRuntime()
        }
        if workingSessionActive { location.start() }
        updateWorkGate()
    }
    func selectTask(_ taskID: String) async {
        guard !busy, authenticated, let task = context?.tasks.first(where:{$0.id == taskID}), let account else { return }
        let ticket = generation; busy = true; issue = nil
        // The previous task cannot keep transferring while its replacement is pending.
        team.clearRuntime(); selectedTaskID = nil; runtimeWorkspaceID = nil; runtimeExpiresAt = .distantPast; updateWorkGate()
        defer { if ticket == generation { busy = false } }
        do {
            struct Selection: Encodable { let client_id = "atlas"; let task_id: String; let share_with_task = true; let share_originals = true }
            let result: StaffRuntimeSession = try await StaffAccountAPI.request("api/native/account/runtime",method:"POST",
                body:JSONEncoder().encode(Selection(task_id:taskID)),token:account.accessToken)
            guard ticket == generation, result.clientID == "atlas", result.baseURL == StaffIdentityPolicy.runtimeOrigin,
                  result.tokenType == "Bearer", result.taskID == taskID, result.workspaceID == task.projectID,
                  StaffIdentityPolicy.validRuntimeToken(result.accessToken), let expiry = StaffIdentityPolicy.date(result.expiresAt), expiry > Date() else {
                throw StaffAccessError.invalidResponse
            }
            try team.installRuntime(result)
            selectedTaskID = taskID; runtimeWorkspaceID = result.workspaceID; runtimeExpiresAt = expiry
            team.allowedProjectIDs = { [weak self] in self?.allowedProjectIDs ?? [] }
            updateWorkGate()
        } catch {
            if ticket == generation { issue = error.localizedDescription; handleAccessError(error); updateWorkGate() }
        }
    }
    func startWorkSession() { workingSessionActive = true; location.start(); updateWorkGate() }
    func pauseWorkSession() { workingSessionActive = false; location.stop(reason:"off_duty"); updateWorkGate() }
    func setForeground(_ foreground: Bool) {
        if foreground && !StaffWorkAccess.diagnosticChiefWithoutTasks { contextVerified = false }
        location.setForeground(foreground)
        if foreground, account?.valid == true, !StaffWorkAccess.diagnosticChiefWithoutTasks { Task { await refresh() } }
        updateWorkGate()
    }
    func signOut() {
        let previous = account; let ticket = generation
        location.stop(reason:"logout")
        revoke(message:nil)
        if let previous {
            Task {
                struct OK: Decodable, Sendable { let ok: Bool }
                let _: OK? = try? await StaffAccountAPI.request("api/native/account/logout",method:"POST",
                    body:Data("{\"client_id\":\"atlas\"}".utf8),token:previous.accessToken)
                _ = ticket // Captured logout never mutates a newer local login.
            }
        }
    }
    func revoke(message: String? = "Рабочая сессия завершена. Войдите снова.") {
        generation = UUID(); authCompletion?.finish(.failure(StaffAccessError.cancelled)); authCompletion = nil
        authBrowser?.cancel(); authBrowser = nil; busy = false
        account = nil; context = nil; contextVerified = false; selectedTaskID = nil; workingSessionActive = false
        runtimeWorkspaceID = nil; runtimeExpiresAt = .distantPast; StaffKeychain.remove(); team.clearRuntime()
        location.stop(reason:"logout"); location.send = nil; issue = message; updateWorkGate()
    }
    private func configureLocationSender(_ token: StaffAccountToken, ticket: UUID) {
        // A stop queued before logout keeps that exact account credential; it
        // cannot stop the location lease of a newer login on the same device.
        location.send = { [weak self] data, stopping in
            guard let self else { throw StaffAccessError.expired }
            return try await self.sendLocation(data, stopping:stopping, account:token, ticket:ticket)
        }
    }
    private func sendLocation(_ data: Data, stopping: Bool, account: StaffAccountToken, ticket: UUID) async throws -> StaffLocationResponse {
        guard account.valid, stopping || ticket == generation else { throw StaffAccessError.expired }
        do {
            let value: StaffLocationResponse = try await StaffAccountAPI.request(stopping ? "api/native/account/location/stop" : "api/native/account/location",
                method:"POST",body:data,token:account.accessToken)
            guard stopping || ticket == generation else { throw CancellationError() }
            return value
        } catch {
            if ticket == generation { handleAccessError(error) }
            throw error
        }
    }
    private func handleAccessError(_ error: Error) {
        if let staff = error as? StaffAccessError {
            switch staff { case .denied,.expired: revoke(message:staff.localizedDescription); default:break }
        }
    }
    private func updateWorkGate() {
        let allowed = canWork(); let was = workAllowed; workAllowed = allowed
        if was != allowed { workChanged?() }
        // Also refresh compact status when accuracy/permission changed.
        objectWillChange.send()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw StaffAccessError.invalidResponse }
        return Data(bytes).base64URL
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where:{$0.activationState == .foregroundActive})?.windows.first(where:{$0.isKeyWindow}) ?? ASPresentationAnchor()
    }
}
private extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
}
