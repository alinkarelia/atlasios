import Foundation
import SwiftUI
import Security
import AtlasCore

struct RemoteUser: Codable, Identifiable, Sendable {
    var id: UUID
    var email: String
    var displayName: String
}
struct RemoteOrganization: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var plan: String
    var role: String?
}
struct RemoteProject: Codable, Identifiable, Sendable {
    var id: UUID
    var organizationID: UUID
    var name: String
    var kind: String
    var revision: Int
    var coordinateReference: CoordinateReference? = nil
    var notes: String? = nil
    var createdAt: String? = nil
    var updatedAt: String? = nil
}
struct RemoteMember: Codable, Identifiable, Sendable {
    var userID: UUID
    var displayName: String
    var email: String?
    var role: String
    var id: UUID { userID }
}
private struct SessionResponse: Codable, Sendable {
    var token: String
    var expiresAt: String
    var user: RemoteUser
}
private struct StoredTeamSession: Codable, Sendable {
    var baseURL: URL
    var session: SessionResponse
    var runtime: StaffRuntimeCredentials
    var shareWithTask: Bool
    var shareOriginals: Bool
    var organizationID: UUID? = nil
    var assignmentEpoch: Int? = nil
}
private struct StoredStaffConnection: Codable, Sendable {
    var account: StaffAccountSession
    var runtime: StoredTeamSession?
    var runtimeRejected: Bool
    init(account: StaffAccountSession, runtime: StoredTeamSession?, runtimeRejected: Bool = false) {
        self.account = account; self.runtime = runtime; self.runtimeRejected = runtimeRejected
    }
    private enum CodingKeys: String, CodingKey { case account, runtime, runtimeRejected }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        account = try values.decode(StaffAccountSession.self, forKey: .account)
        runtime = try values.decodeIfPresent(StoredTeamSession.self, forKey: .runtime)
        runtimeRejected = try values.decodeIfPresent(Bool.self, forKey: .runtimeRejected) ?? false
    }
}
private struct OrganizationsResponse: Decodable { var organizations: [RemoteOrganization] }
private struct ProjectsResponse: Decodable { var projects: [RemoteProject] }
private struct MembersResponse: Decodable { var members: [RemoteMember] }
private struct APIErrorResponse: Decodable {
    struct Detail: Decodable { var code: String; var message: String }
    var error: Detail
}
private struct CloudFeaturePayload: Codable, Equatable {
    var label: String
    var category: FeatureCategory
    var geometry: FeatureGeometry
    var attributes: [String: String]
    var notes: String
    var reviewStatus: String
}
private struct CloudFeatureOperation: Codable {
    var operationID: UUID
    var entity = "feature"
    var action = "upsert"
    var id: UUID
    var baseRevision: Int64
    var data: CloudFeaturePayload
}
private struct PushRequest: Codable { var operations: [CloudFeatureOperation] }
private struct PushResponse: Decodable {
    struct Result: Decodable { var operationID: UUID; var status: String; var revision: Int64?; var code: String?; var message: String? }
    var results: [Result]
}
private struct PublicationState: Codable {
    var revisions: [String: Int64] = [:]
    var pending: [String: CloudFeatureOperation] = [:]
    var confirmedPayloads: [String: CloudFeaturePayload] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey { case revisions, pending, confirmedPayloads }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revisions = try values.decodeIfPresent([String: Int64].self, forKey: .revisions) ?? [:]
        pending = try values.decodeIfPresent([String: CloudFeatureOperation].self, forKey: .pending) ?? [:]
        confirmedPayloads = try values.decodeIfPresent([String: CloudFeaturePayload].self, forKey: .confirmedPayloads) ?? [:]
    }
}

private struct TeamRequestContext: Sendable {
    let baseURL: URL
    let token: String
    let userID: UUID
    let generation: UInt64
}

enum TeamError: LocalizedError {
    case invalidURL, notConnected, runtimeExpired, keychain(OSStatus), rejected(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Укажите HTTPS-адрес сервера без логина, пароля или параметров в ссылке."
        case .notConnected: "Войдите в «Семейный архив» и выберите подключение для отправки."
        case .runtimeExpired: "Рабочее подключение истекло или отозвано. Обновите подключение перед отправкой."
        case let .keychain(status): "Не удалось сохранить защищённую сессию (\(status))."
        case let .rejected(message): message
        }
    }
}

@MainActor
final class TeamService: ObservableObject {
    @Published private(set) var user: RemoteUser?
    @Published private(set) var accountUser: StaffAccountUser?
    @Published private(set) var availableTasks: [StaffAccountTask] = []
    @Published private(set) var accountExpiresAt: Date?
    @Published private(set) var selectedTaskID: String?
    @Published private(set) var runtimeExpiresAt: Date?
    @Published private(set) var cloudLocationRequired = false
    @Published private(set) var cloudLocationAllowed = false
    let workLocation = StaffWorkLocation()
    @Published private(set) var organizations: [RemoteOrganization] = []
    @Published private(set) var projects: [RemoteProject] = []
    @Published private(set) var members: [RemoteMember] = []
    @Published private(set) var busy = false
    @Published var issue: String?
    @Published private(set) var publicationMessage: String?
    @Published var selectedOrganizationID: UUID? {
        didSet {
            if oldValue != selectedOrganizationID {
                projects = []; members = []; publicationMessage = nil
                if stored != nil {
                    stored?.organizationID = selectedOrganizationID
                    try? persistConnection()
                }
            }
        }
    }
    private var stored: StoredTeamSession?
    private var accountSession: StaffAccountSession?
    private var sessionGeneration: UInt64 = 0
    private var accountGeneration: UInt64 = 0
    private var runtimeWasRejected = false
    private let keychainKey = "family-archive-account-v1"
    private let api = StaffAccountAPI()
    private let webAuthenticator = StaffWebAuthenticator()
    private let publicationURL: URL

    init() {
        publicationURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atlas/team-publication-v1.json")
        workLocation.changed = { [weak self] in self?.updateCloudWorkGate() }
        // Prototype passwords/tokens cannot be migrated into website accounts.
        Self.keychainDelete(key: "atlas-team-session-v1")
        if let data = Self.keychainRead(key: keychainKey),
           let saved = try? JSONDecoder().decode(StoredStaffConnection.self, from: data),
           (try? saved.account.credentials.validated()) != nil,
           let expiry = saved.account.credentials.expiry,
           (try? saved.account.context.validated(accountExpiresAt: expiry)) != nil {
            installAccount(saved.account)
            if let runtime = saved.runtime,
               saved.account.context.tasks.contains(where: {
                   $0.id == runtime.runtime.taskID && $0.assignmentEpoch == runtime.assignmentEpoch
                   && ($0.expectedWorkspaceID == nil || $0.expectedWorkspaceID == runtime.runtime.workspaceID)
               }),
               runtime.baseURL.absoluteString == StaffIdentityPolicy.dataBaseURL.absoluteString,
               runtime.runtime.clientID == StaffIdentityPolicy.clientID,
               runtime.runtime.tokenType.lowercased() == "bearer",
               runtime.session.token == runtime.runtime.accessToken,
               runtime.session.expiresAt == runtime.runtime.expiresAt,
               (try? StaffIdentityPolicy.validateRuntimeTokenFormat(runtime.runtime.accessToken)) != nil,
               !runtime.runtime.workspaceID.isEmpty,
               let runtimeExpiry = runtime.runtime.expiry, runtimeExpiry <= expiry,
               (try? StaffIdentityPolicy.trustedRuntimeBaseURL(runtime.runtime.baseURL)) == runtime.baseURL {
                // A just-expired runtime is retained only for its explicit task
                // and sharing choice. transferContext rejects its expired token.
                stored = runtime; runtimeWasRejected = saved.runtimeRejected; user = runtime.session.user
                selectedTaskID = runtime.runtime.taskID
                runtimeExpiresAt = runtime.runtime.expiry
                selectedOrganizationID = runtime.organizationID
            }
        } else { Self.keychainDelete(key: keychainKey) }
    }

    var accountSignedIn: Bool { accountSession != nil && (accountExpiresAt ?? .distantPast) > Date() }
    var connected: Bool { accountSignedIn }
    var runtimeReady: Bool {
        guard runtimeTokenValid, selectedOrganizationID != nil, allowsCloudWorkNow else { return false }
        return true
    }
    private var runtimeTokenValid: Bool {
        guard !runtimeWasRejected, accountSignedIn, let stored, let expiry = accountExpiresAt else { return false }
        return (try? stored.runtime.validated(accountExpiresAt: expiry, taskID: stored.runtime.taskID)) != nil
    }
    var serverAddress: String { StaffIdentityPolicy.dataBaseURL.absoluteString }
    var selectedOrganization: RemoteOrganization? { organizations.first { $0.id == selectedOrganizationID } }
    var selectedTask: StaffAccountTask? { availableTasks.first { $0.id == selectedTaskID } }
    var runtimeSharing: (withTask: Bool, originals: Bool)? {
        stored.map { ($0.shareWithTask, $0.shareOriginals) }
    }

    func signInToFamilyArchive() async {
        guard !busy else { return }
        accountGeneration &+= 1
        workLocation.reset(reason: "logout")
        sessionGeneration &+= 1
        let generation = sessionGeneration
        busy = true; issue = nil
        var mintedToken: String?
        defer { if sessionGeneration == generation { busy = false } }
        do {
            let pkce = try StaffIdentityPolicy.makePKCE(verifier: StaffWebAuthenticator.secureRandom(),
                state: StaffWebAuthenticator.secureRandom())
            let callback = try await webAuthenticator.authorize(pkce.authorizationURL)
            guard generation == sessionGeneration else { throw CancellationError() }
            let code = try StaffIdentityPolicy.validateCallback(callback, expectedState: pkce.state)
            let credentials = try await api.exchange(code: code, verifier: pkce.verifier)
            mintedToken = credentials.accessToken
            try credentials.validated()
            guard generation == sessionGeneration, let expiry = credentials.expiry else { throw CancellationError() }
            let accountContext = try await api.context(accountToken: credentials.accessToken)
            try accountContext.validated(accountExpiresAt: expiry)
            guard generation == sessionGeneration else { throw CancellationError() }
            let account = StaffAccountSession(credentials: credentials, context: accountContext)
            try Self.keychainSave(JSONEncoder().encode(StoredStaffConnection(account: account, runtime: nil)), key: keychainKey)
            clearRuntime()
            installAccount(account)
            mintedToken = nil
        } catch {
            if let mintedToken { Task { try? await api.logout(accountToken: mintedToken) } }
            if generation == sessionGeneration, !(error is CancellationError) { issue = error.localizedDescription }
        }
    }

    /// Login succeeds with zero assignments. A task is needed only when the
    /// operator explicitly prepares a server transfer.
    func refresh() async {
        guard accountSignedIn, !busy else { return }
        let generation = sessionGeneration
        busy = true; issue = nil
        defer { if sessionGeneration == generation { busy = false } }
        do {
            try await refreshAccountContext(generation: generation)
            if runtimeTokenValid, allowsCloudWorkNow { try await fetchOrganizations(context()) }
        } catch {
            if generation == sessionGeneration { handleAccountError(error); issue = error.localizedDescription }
        }
    }

    func prepareRuntime(taskID: String, shareWithTask: Bool, shareOriginals: Bool) async throws {
        guard !busy else { throw TeamError.rejected("Дождитесь завершения подключения.") }
        guard accountSignedIn, let account = accountSession, let expiry = account.credentials.expiry else {
            throw StaffAccountError.accountExpired
        }
        // Invalidate old in-flight requests before changing destination or
        // disclosure choices. Old queued bytes remain bound to their own scope.
        let renewingSameBinding = stored.map {
            $0.runtime.taskID == taskID && $0.shareWithTask == shareWithTask && $0.shareOriginals == shareOriginals
        } ?? false
        sessionGeneration &+= 1
        let generation = sessionGeneration
        busy = true; issue = nil
        if renewingSameBinding {
            // Keep only the task/consent binding for retry after network failure;
            // this bearer is unusable until the server issues a new one.
            runtimeWasRejected = true
        } else { clearRuntime() }
        try? persistConnection()
        defer { if sessionGeneration == generation { busy = false } }
        do {
            try await refreshAccountContext(generation: generation)
            guard let task = availableTasks.first(where: { $0.id == taskID }) else {
                throw TeamError.rejected("Задание больше недоступно. Обновите список или обратитесь к руководителю.")
            }
            try requireCloudWorkLocation()
            let credentials = try await api.runtime(accountToken: account.credentials.accessToken,
                taskID: taskID, shareWithTask: shareWithTask, shareOriginals: shareOriginals)
            let baseURL = try credentials.validated(accountExpiresAt: min(expiry, accountExpiresAt ?? expiry), taskID: taskID)
            if let expectedWorkspace = task.expectedWorkspaceID, expectedWorkspace != credentials.workspaceID {
                throw StaffAccountError.invalidResponse
            }
            guard generation == sessionGeneration else { throw CancellationError() }
            struct Me: Decodable { let user: RemoteUser }
            let me: Me = try await request(base: baseURL, path: "v1/me", token: credentials.accessToken,
                generation: generation)
            guard generation == sessionGeneration, accountSignedIn else { throw CancellationError() }
            let value = StoredTeamSession(baseURL: baseURL,
                session: SessionResponse(token: credentials.accessToken, expiresAt: credentials.expiresAt, user: me.user),
                runtime: credentials, shareWithTask: shareWithTask, shareOriginals: shareOriginals,
                organizationID: selectedOrganizationID, assignmentEpoch: task.assignmentEpoch)
            stored = value; runtimeWasRejected = false; user = me.user
            selectedTaskID = taskID; runtimeExpiresAt = credentials.expiry
            try persistConnection()
            try await fetchOrganizations(context())
        } catch {
            if generation == sessionGeneration {
                if renewingSameBinding { runtimeWasRejected = true }
                else { clearRuntime() }
                try? persistConnection()
                handleAccountError(error)
                issue = error.localizedDescription
            }
            throw error
        }
    }

    /// No refresh_token endpoint exists. Reissue the scoped runtime through the
    /// still-valid account session, retaining the operator's explicit choices.
    func renewRuntimeIfNeeded() async throws {
        guard accountSignedIn else { throw StaffAccountError.accountExpired }
        try requireCloudWorkLocation()
        guard let stored else { throw TeamError.rejected("Выберите задание и подключите отправку материалов.") }
        if !runtimeWasRejected, let expiry = stored.runtime.expiry, expiry.timeIntervalSinceNow > 60,
           let accountExpiry = accountExpiresAt,
           (try? stored.runtime.validated(accountExpiresAt: accountExpiry, taskID: stored.runtime.taskID)) != nil {
            return
        }
        try await prepareRuntime(taskID: stored.runtime.taskID, shareWithTask: stored.shareWithTask,
            shareOriginals: stored.shareOriginals)
    }

    private func refreshAccountContext(generation: UInt64) async throws {
        guard let account = accountSession, let expiry = account.credentials.expiry else {
            throw StaffAccountError.accountExpired
        }
        try account.credentials.validated()
        let value = try await api.context(accountToken: account.credentials.accessToken)
        guard generation == sessionGeneration else { throw CancellationError() }
        try value.validated(accountExpiresAt: expiry)
        guard value.user.id == account.context.user.id else { throw StaffAccountError.invalidResponse }
        let selectedEpoch = stored?.assignmentEpoch
        let selectedWorkspace = stored?.runtime.workspaceID
        installAccount(StaffAccountSession(credentials: account.credentials, context: value))
        if let selectedTaskID, !value.tasks.contains(where: {
            $0.id == selectedTaskID && $0.assignmentEpoch == selectedEpoch
                && ($0.expectedWorkspaceID == nil || $0.expectedWorkspaceID == selectedWorkspace)
        }) { clearRuntime() }
        try persistConnection()
    }

    private func installAccount(_ value: StaffAccountSession) {
        accountSession = value; accountUser = value.context.user
        let contextExpiry = try? StaffIdentityPolicy.parseUTCDate(value.context.expiresAt)
        accountExpiresAt = [value.credentials.expiry, contextExpiry].compactMap { $0 }.min()
        availableTasks = value.context.tasks
        cloudLocationRequired = value.context.permissions?.locationRequired == true
        configureWorkLocation(value)
        if !cloudLocationRequired, workLocation.active { workLocation.stop(reason: "off_duty") }
        updateCloudWorkGate()
    }

    private var allowsCloudWorkNow: Bool {
        StaffWorkLocationPolicy.allowsCloud(
            requirement: StaffWorkLocationRequirement(locationRequired: accountSession?.context.permissions?.locationRequired),
            accountAuthorized: accountSignedIn, accountExpiresAt: accountExpiresAt ?? .distantPast,
            lease: workLocation.lease)
    }
    private func updateCloudWorkGate() {
        let allowed = allowsCloudWorkNow
        if cloudLocationAllowed != allowed { cloudLocationAllowed = allowed }
    }
    /// Applies only to server runtime/data requests. Never call this from local
    /// capture, tools, editing, export, staging or durable queue-consent paths.
    func requireCloudWorkLocation() throws {
        updateCloudWorkGate()
        guard accountSignedIn else { throw StaffAccountError.accountExpired }
        guard allowsCloudWorkNow else { throw StaffAccountError.workLocationRequired }
    }
    func startCloudWorkLocation() {
        guard accountSignedIn, cloudLocationRequired else { return }
        workLocation.start()
        updateCloudWorkGate()
    }
    func pauseCloudWorkLocation() {
        workLocation.stop(reason: "off_duty")
        updateCloudWorkGate()
    }
    func setCloudWorkForeground(_ foreground: Bool) {
        workLocation.setForeground(foreground)
        updateCloudWorkGate()
    }
    private func configureWorkLocation(_ value: StaffAccountSession) {
        let identity = value.context.user.id, account = value.credentials, generation = accountGeneration
        workLocation.configure(accountID: identity, generation: generation,
            expiresAt: accountExpiresAt ?? .distantPast) { [weak self] payload, stop in
                guard let self else { throw StaffAccountError.accountExpired }
                if stop == nil {
                    guard self.accountGeneration == generation, self.accountSignedIn,
                          self.accountSession?.credentials.accessToken == account.accessToken,
                          self.cloudLocationRequired else { throw CancellationError() }
                }
                try account.validated()
                do {
                    let response: StaffLocationResponse
                    if let stop, payload == nil {
                        response = try await self.api.stopLocation(accountToken: account.accessToken, payload: stop)
                    } else if let payload, stop == nil {
                        response = try await self.api.location(accountToken: account.accessToken, payload: payload)
                    } else { throw StaffAccountError.invalidResponse }
                    if stop == nil {
                        guard self.accountGeneration == generation,
                              self.accountSession?.credentials.accessToken == account.accessToken,
                              self.accountSignedIn, self.cloudLocationRequired else { throw CancellationError() }
                    }
                    return response
                } catch {
                    if self.accountGeneration == generation,
                       self.accountSession?.credentials.accessToken == account.accessToken {
                        self.handleAccountError(error)
                    }
                    throw error
                }
            }
    }
    private func clearRuntime() {
        stored = nil; runtimeWasRejected = false; user = nil; organizations = []; projects = []; members = []
        selectedOrganizationID = nil; selectedTaskID = nil; runtimeExpiresAt = nil
        publicationMessage = nil
    }
    private func persistConnection() throws {
        guard let accountSession else { Self.keychainDelete(key: keychainKey); return }
        try Self.keychainSave(JSONEncoder().encode(StoredStaffConnection(account: accountSession, runtime: stored, runtimeRejected: runtimeWasRejected)), key: keychainKey)
    }
    private func handleAccountError(_ error: Error) {
        if case StaffAccountError.http(401) = error {
            workLocation.reset(reason: "logout")
            accountGeneration &+= 1; sessionGeneration &+= 1
            clearRuntime(); accountSession = nil; accountUser = nil; availableTasks = []; accountExpiresAt = nil
            cloudLocationRequired = false
            Self.keychainDelete(key: keychainKey)
            busy = false; updateCloudWorkGate()
        } else if case StaffAccountError.http(403) = error {
            // Revoke only this cloud operation, keeping the website account and
            // every local tool usable. A server denial never starts new GPS.
            workLocation.stop(reason: "off_duty")
            runtimeWasRejected = true; try? persistConnection()
            updateCloudWorkGate()
        }
    }

    func loadOrganization(_ organization: RemoteOrganization) async {
        guard !busy else { return }
        let generation = sessionGeneration
        busy = true; issue = nil
        defer { if sessionGeneration == generation { busy = false } }
        do {
            let context = try context()
            let values: ProjectsResponse = try await request(context: context, path: "v1/projects")
            let people: MembersResponse = try await request(context: context, path: "v1/organizations/\(organization.id.uuidString)/members")
            try requireCurrent(context, organizationID: organization.id)
            projects = values.projects.filter { $0.organizationID == organization.id }
            members = people.members
        } catch {
            if sessionGeneration == generation, selectedOrganizationID == organization.id { issue = error.localizedDescription }
        }
    }

    /// Sends a verified snapshot of metadata. Raw files, floor plans and automatic
    /// two-way merging are not silently described as synchronized by this action.
    func publish(_ snapshot: AtlasProjectSnapshot, to organization: RemoteOrganization) async {
        guard !busy else { return }
        let generation = sessionGeneration
        busy = true; issue = nil; publicationMessage = nil
        defer { if sessionGeneration == generation { busy = false } }
        do {
            let context = try context()
            try requireCurrent(context, organizationID: organization.id)
            let list: ProjectsResponse = try await request(context: context, path: "v1/projects")
            if let existing = list.projects.first(where: { $0.id == snapshot.project.id }) {
                guard existing.organizationID == organization.id else { throw TeamError.rejected("Проект уже принадлежит другому рабочему пространству.") }
            } else {
                struct Create: Encodable {
                    var id: UUID; var organizationID: UUID; var name: String; var kind: ProjectKind
                    var coordinateReference: CoordinateReference; var notes: String
                }
                let payload = Create(id: snapshot.project.id, organizationID: organization.id,
                    name: snapshot.project.name, kind: snapshot.project.kind,
                    coordinateReference: snapshot.project.coordinateReference, notes: snapshot.project.notes)
                let _: RemoteProject = try await request(context: context, path: "v1/projects", method: "POST", body: JSONEncoder().encode(payload))
            }
            var state: PublicationState
            if FileManager.default.fileExists(atPath: publicationURL.path) {
                state = try JSONDecoder().decode(PublicationState.self, from: Data(contentsOf: publicationURL))
            } else { state = PublicationState() }
            var accepted = 0, conflicts = 0, unchanged = 0
            for feature in snapshot.features {
                try requireCurrent(context, organizationID: organization.id)
                let key = context.baseURL.absoluteString + "|" + context.userID.uuidString + "|" + organization.id.uuidString + "|" + feature.id.uuidString
                // Replay the original immutable operation before sending a newer
                // local revision. The previous response may have been lost after
                // the server committed it; a new operation ID would then conflict.
                let older = state.pending.keys.filter { $0.hasPrefix(key + "|") }.sorted {
                    let lhs = Int64($0.split(separator: "|").last.map(String.init) ?? "") ?? 0
                    let rhs = Int64($1.split(separator: "|").last.map(String.init) ?? "") ?? 0
                    return lhs < rhs
                }
                var blocked = false
                for pendingKey in older {
                    guard let operation = state.pending[pendingKey] else { continue }
                    let result = try await push(operation, projectID: snapshot.project.id, context: context)
                    try requireCurrent(context, organizationID: organization.id)
                    if result.status == "applied", let revision = result.revision {
                        state.revisions[key] = max(state.revisions[key] ?? 0, revision)
                        state.confirmedPayloads[key] = operation.data
                        state.pending.removeValue(forKey: pendingKey)
                        try persistPublication(state)
                        accepted += 1
                    } else {
                        conflicts += 1; blocked = true
                        issue = result.message ?? "Ранее переданная версия требует разбора. Новые изменения сохранены на устройстве."
                        break
                    }
                }
                guard !blocked else { continue }
                let payload = CloudFeaturePayload(label: feature.label, category: feature.category, geometry: feature.geometry,
                    attributes: feature.attributes, notes: feature.notes,
                    reviewStatus: feature.reviewStatus == .reviewed ? "needsReview" : feature.reviewStatus.rawValue)
                // Compare actual content as well as tracking server revisions:
                // restoring a local backup may reuse an old revision number.
                if state.confirmedPayloads[key] == payload { unchanged += 1; continue }
                let pendingKey = key + "|" + String(feature.revision)
                let operation = CloudFeatureOperation(operationID: UUID(), id: feature.id,
                    baseRevision: state.revisions[key] ?? 0, data: payload)
                state.pending[pendingKey] = operation
                try persistPublication(state)
                let result = try await push(operation, projectID: snapshot.project.id, context: context)
                try requireCurrent(context, organizationID: organization.id)
                if result.status == "applied", let revision = result.revision {
                    state.revisions[key] = max(state.revisions[key] ?? 0, revision)
                    state.confirmedPayloads[key] = operation.data
                    state.pending.removeValue(forKey: pendingKey)
                    try persistPublication(state)
                    accepted += 1
                } else {
                    conflicts += 1
                    if result.status == "rejected" { issue = result.message ?? "Сервер отклонил объект." }
                }
            }
            try requireCurrent(context, organizationID: organization.id)
            publicationMessage = "Подтверждено операций: \(accepted). Без изменений: \(unchanged). Требуют разбора: \(conflicts). Файлы съёмки и планы остались на устройстве."
            let values: ProjectsResponse = try await request(context: context, path: "v1/projects")
            try requireCurrent(context, organizationID: organization.id)
            projects = values.projects.filter { $0.organizationID == organization.id }
        } catch {
            if sessionGeneration == generation, selectedOrganizationID == organization.id { issue = error.localizedDescription }
        }
    }

    /// Bootstrap preserves the server's UUID and real coordinate reference.
    /// This method does not silently replace an existing local project.
    func sharedProject(_ remote: RemoteProject) async throws -> AtlasProject {
        let transfer = try transferContext()
        guard remote.organizationID == transfer.organizationID else { throw TeamError.rejected("Выберите рабочее пространство этого проекта.") }
        let context = try self.context()
        let detail: RemoteProject = try await request(context: context, path: "v1/projects/\(remote.id.uuidString)")
        try requireCurrentTransfer(transfer)
        guard detail.id == remote.id, detail.organizationID == transfer.organizationID,
              let reference = detail.coordinateReference, let kind = ProjectKind(rawValue: detail.kind),
              let createdAt = detail.createdAt.flatMap(Self.serverDate),
              let updatedAt = detail.updatedAt.flatMap(Self.serverDate) else {
            throw TeamError.rejected("Сервер не подтвердил паспорт общего проекта.")
        }
        return AtlasProject(id: detail.id, name: detail.name, kind: kind, coordinateReference: reference,
            notes: detail.notes ?? "", createdAt: createdAt, updatedAt: updatedAt, revision: Int64(detail.revision))
    }

    /// Read-only baseline; callers decide whether importing would overwrite a
    /// local edit. Every page is checked against the original account/workspace.
    func sharedFeatures(projectID: UUID) async throws -> [AtlasFeature] {
        struct Page: Decodable { var features: [AtlasFeature]; var hasMore: Bool; var nextOffset: Int }
        let transfer = try transferContext()
        let context = try self.context()
        var offset = 0, features: [AtlasFeature] = []
        while true {
            try requireCurrentTransfer(transfer)
            let response: Page = try await request(context: context,
                path: "v1/projects/\(projectID.uuidString)/features?limit=20&offset=\(offset)")
            try requireCurrentTransfer(transfer)
            guard response.features.allSatisfy({ $0.projectID == projectID }) else { throw FieldTransportError.invalidResponse }
            features.append(contentsOf: response.features)
            guard features.count <= 10_000 else { throw FieldTransportError.tooLarge }
            if !response.hasMore { return features }
            guard response.nextOffset > offset else { throw FieldTransportError.invalidResponse }
            offset = response.nextOffset
        }
    }

    private static func serverDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    func signOut() async {
        let token = accountSession?.credentials.accessToken
        workLocation.reset(reason: "logout")
        accountGeneration &+= 1; sessionGeneration &+= 1
        webAuthenticator.cancel()
        Self.keychainDelete(key: keychainKey)
        clearRuntime(); accountSession = nil; accountUser = nil; availableTasks = []; accountExpiresAt = nil
        cloudLocationRequired = false
        busy = false; issue = nil; publicationMessage = nil
        updateCloudWorkGate()
        if let token {
            // Local logout is immediate. Revoke the captured website session;
            // a late response cannot mutate a newly signed-in account.
            Task { try? await api.logout(accountToken: token) }
        }
    }

    /// Identity and destination only, for reading preferences and staging local
    /// originals while the runtime expires. It is never a network credential.
    var transferScope: FieldTransferScope? {
        guard accountSignedIn, let stored, let organizationID = selectedOrganizationID else { return nil }
        let scope = FieldTransferScope(serverOrigin: stored.baseURL.absoluteString,
            userID: stored.session.user.id, organizationID: organizationID,
            destination: FieldTransferDestination(workspaceID: stored.runtime.workspaceID,
                taskID: stored.runtime.taskID, shareWithTask: stored.shareWithTask, shareOriginals: stored.shareOriginals))
        guard (try? scope.validate()) != nil else { return nil }
        return scope
    }

    func requireCurrentScope(_ scope: FieldTransferScope) throws {
        guard transferScope == scope else { throw CancellationError() }
    }

    /// A fixed destination binds every queued package to its original workspace.
    /// The bearer stays private to the request context and never becomes UI text.
    func transferContext() throws -> TeamTransferContext {
        guard !runtimeWasRejected, let stored, let organizationID = selectedOrganizationID,
              accountSignedIn, let expiry = accountExpiresAt else { throw TeamError.notConnected }
        _ = try stored.runtime.validated(accountExpiresAt: expiry, taskID: stored.runtime.taskID)
        try requireCloudWorkLocation()
        return TeamTransferContext(baseURL: stored.baseURL, token: stored.session.token,
            userID: stored.session.user.id, organizationID: organizationID, generation: sessionGeneration,
            destination: FieldTransferDestination(workspaceID: stored.runtime.workspaceID,
                taskID: stored.runtime.taskID, shareWithTask: stored.shareWithTask, shareOriginals: stored.shareOriginals))
    }

    func requireCurrentTransfer(_ context: TeamTransferContext) throws {
        guard !runtimeWasRejected, accountSignedIn, (runtimeExpiresAt ?? .distantPast) > Date(),
              context.generation == sessionGeneration, context.baseURL == stored?.baseURL,
              context.userID == stored?.session.user.id, context.organizationID == selectedOrganizationID,
              context.matchesToken(stored?.session.token),
              context.destination == stored.map({ FieldTransferDestination(workspaceID: $0.runtime.workspaceID,
                taskID: $0.runtime.taskID, shareWithTask: $0.shareWithTask, shareOriginals: $0.shareOriginals) }) else { throw CancellationError() }
        try requireCloudWorkLocation()
    }

    /// A data bearer may be revoked while its nominal expiry is still future.
    /// Keep the website account and task choice, but never retry this bearer.
    func rejectRuntime(_ context: TeamTransferContext) {
        guard context.generation == sessionGeneration, context.baseURL == stored?.baseURL,
              context.userID == stored?.session.user.id, context.matchesToken(stored?.session.token) else { return }
        runtimeWasRejected = true
        try? persistConnection()
        issue = "Рабочее подключение истекло или отозвано. Обновите подключение выбранного задания."
    }

    /// Creates the shared project with the same UUID; an existing project in a
    /// different organization cannot receive this local project's materials.
    func ensureTransferProject(_ snapshot: AtlasProjectSnapshot, context: TeamTransferContext) async throws {
        try requireCurrentTransfer(context)
        let current = try self.context()
        let list: ProjectsResponse = try await request(context: current, path: "v1/projects")
        try requireCurrentTransfer(context)
        if let existing = list.projects.first(where: { $0.id == snapshot.project.id }) {
            guard existing.organizationID == context.organizationID else {
                throw TeamError.rejected("Проект относится к другому рабочему пространству.")
            }
            guard existing.coordinateReference == snapshot.project.coordinateReference,
                  existing.kind == snapshot.project.kind.rawValue else {
                throw TeamError.rejected("Паспорт проекта на сервере отличается от локального. Сверьте систему координат; исходники сохранены.")
            }
            return
        }
        struct Create: Encodable {
            let id: UUID; let organizationID: UUID; let name: String; let kind: ProjectKind
            let coordinateReference: CoordinateReference; let notes: String
        }
        let body = Create(id: snapshot.project.id, organizationID: context.organizationID,
            name: snapshot.project.name, kind: snapshot.project.kind,
            coordinateReference: snapshot.project.coordinateReference, notes: snapshot.project.notes)
        let _: RemoteProject = try await request(context: current, path: "v1/projects", method: "POST",
            body: JSONEncoder().encode(body))
        try requireCurrentTransfer(context)
        let updated: ProjectsResponse = try await request(context: current, path: "v1/projects")
        try requireCurrentTransfer(context)
        projects = updated.projects.filter { $0.organizationID == context.organizationID }
    }

    private func fetchOrganizations(_ context: TeamRequestContext) async throws {
        let response: OrganizationsResponse = try await request(context: context, path: "v1/organizations")
        try requireCurrent(context)
        organizations = response.organizations
        if !organizations.contains(where: { $0.id == selectedOrganizationID }) {
            selectedOrganizationID = organizations.first?.id
        }
    }

    private func context() throws -> TeamRequestContext {
        guard !runtimeWasRejected, accountSignedIn, let stored, let expiry = accountExpiresAt else { throw TeamError.notConnected }
        _ = try stored.runtime.validated(accountExpiresAt: expiry, taskID: stored.runtime.taskID)
        try requireCloudWorkLocation()
        return TeamRequestContext(baseURL: stored.baseURL, token: stored.session.token,
            userID: stored.session.user.id, generation: sessionGeneration)
    }

    private func requireCurrent(_ context: TeamRequestContext, organizationID: UUID? = nil) throws {
        guard !runtimeWasRejected, accountSignedIn, (runtimeExpiresAt ?? .distantPast) > Date(),
              context.generation == sessionGeneration,
              stored?.session.token == context.token, stored?.session.user.id == context.userID,
              organizationID == nil || selectedOrganizationID == organizationID else { throw CancellationError() }
        try requireCloudWorkLocation()
    }

    private func push(_ operation: CloudFeatureOperation, projectID: UUID, context: TeamRequestContext) async throws -> PushResponse.Result {
        let response: PushResponse = try await request(context: context,
            path: "v1/projects/\(projectID.uuidString)/sync/push", method: "POST",
            body: JSONEncoder().encode(PushRequest(operations: [operation])))
        guard response.results.count == 1, let result = response.results.first,
              result.operationID == operation.operationID else {
            throw TeamError.rejected("Сервер не подтвердил передачу этого объекта.")
        }
        return result
    }

    private func request<Response: Decodable>(context: TeamRequestContext, path: String, method: String = "GET", body: Data? = nil) async throws -> Response {
        try requireCurrent(context)
        return try await request(base: context.baseURL, path: path, method: method,
            body: body, token: context.token, generation: context.generation)
    }

    private func request<Response: Decodable>(base: URL, path: String, method: String = "GET", body: Data? = nil, token: String?, generation: UInt64) async throws -> Response {
        guard generation == sessionGeneration else { throw CancellationError() }
        try requireCloudWorkLocation()
        let split = path.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [URLQueryItem] = []
        if split.count == 2 {
            var components = URLComponents(); components.percentEncodedQuery = split[1]
            query = components.queryItems ?? []
        }
        let url = try StaffIdentityPolicy.dataURL(baseURL: base, relativePath: split[0], queryItems: query)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await TeamHTTP.session.data(for: request)
        guard generation == sessionGeneration else { throw CancellationError() }
        try requireCloudWorkLocation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                runtimeWasRejected = true
                try? persistConnection()
                let message = "Рабочее подключение истекло или отозвано. Обновите подключение выбранного задания."
                issue = message
                throw TeamError.runtimeExpired
            }
            if (response as? HTTPURLResponse)?.statusCode == 403 { throw StaffAccountError.http(403) }
            if let error = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                let descriptions = ["invalid_credentials": "Почта или пароль не совпали.",
                    "forbidden": "У вашей роли нет разрешения на это действие.",
                    "account_not_found": "Участнику нужно сначала зарегистрироваться на этом сервере.",
                    "unauthorized": "Сессия закончилась. Войдите снова.",
                    "billing_not_configured": "Подтверждение подписок на сервере ещё не подключено."]
                throw TeamError.rejected(descriptions[error.error.code] ?? error.error.message)
            }
            throw TeamError.rejected("Сервер не подтвердил запрос.")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func persistPublication(_ state: PublicationState) throws {
        try FileManager.default.createDirectory(at: publicationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: publicationURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func validatedURL(_ text: String) throws -> URL {
        try StaffIdentityPolicy.trustedRuntimeBaseURL(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func keychainRead(key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.atlasfield.session", kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    private static func keychainSave(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.atlasfield.session", kSecAttrAccount as String: key]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw TeamError.keychain(update) }
        var add = query; add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw TeamError.keychain(status) }
    }
    private static func keychainDelete(key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.atlasfield.session", kSecAttrAccount as String: key] as CFDictionary)
    }
}
