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
    case invalidURL, notConnected, keychain(OSStatus), rejected(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Укажите HTTPS-адрес сервера без логина, пароля или параметров в ссылке."
        case .notConnected: "Подключитесь к серверу организации."
        case let .keychain(status): "Не удалось сохранить защищённую сессию (\(status))."
        case let .rejected(message): message
        }
    }
}

@MainActor
final class TeamService: ObservableObject {
    @Published private(set) var user: RemoteUser?
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
            }
        }
    }
    private var stored: StoredTeamSession?
    private var sessionGeneration: UInt64 = 0
    private let keychainKey = "atlas-team-session-v1"
    private let publicationURL: URL

    init() {
        publicationURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atlas/team-publication-v1.json")
        if let data = Self.keychainRead(key: keychainKey), let value = try? JSONDecoder().decode(StoredTeamSession.self, from: data) {
            stored = value; user = value.session.user
        }
    }

    var connected: Bool { stored != nil }
    var serverAddress: String { stored?.baseURL.absoluteString ?? "" }
    var selectedOrganization: RemoteOrganization? { organizations.first { $0.id == selectedOrganizationID } }

    func purchaseSink() -> (any StoreKitEvidenceSink)? {
        guard let stored, let organizationID = selectedOrganizationID else { return nil }
        return TeamPurchaseSink(baseURL: stored.baseURL, token: stored.session.token,
            userID: stored.session.user.id, organizationID: organizationID)
    }

    func authenticate(server: String, email: String, password: String, displayName: String?, organizationName: String?) async {
        guard !busy else { return }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        busy = true; issue = nil
        defer { if sessionGeneration == generation { busy = false } }
        do {
            let baseURL = try Self.validatedURL(server)
            var body = ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password]
            let registering = displayName != nil
            if let displayName { body["displayName"] = displayName }
            if let organizationName { body["organizationName"] = organizationName }
            let response: SessionResponse = try await request(base: baseURL,
                path: registering ? "v1/auth/register" : "v1/auth/login", method: "POST",
                body: JSONEncoder().encode(body), token: nil, generation: generation)
            let value = StoredTeamSession(baseURL: baseURL, session: response)
            try Self.keychainSave(JSONEncoder().encode(value), key: keychainKey)
            stored = value; user = response.user
            organizations = []; projects = []; members = []; selectedOrganizationID = nil
            publicationMessage = nil
            try await fetchOrganizations(context())
        } catch { if sessionGeneration == generation { issue = error.localizedDescription } }
    }

    func refresh() async {
        guard connected, !busy else { return }
        let generation = sessionGeneration
        busy = true; issue = nil
        defer { if sessionGeneration == generation { busy = false } }
        do { try await fetchOrganizations(context()) }
        catch { if sessionGeneration == generation { issue = error.localizedDescription } }
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

    func addMember(email: String, role: String, organization: RemoteOrganization) async {
        guard !busy else { return }
        let generation = sessionGeneration
        busy = true; issue = nil
        do {
            let context = try context()
            try requireCurrent(context, organizationID: organization.id)
            let _: RemoteMember = try await request(context: context,
                path: "v1/organizations/\(organization.id.uuidString)/members", method: "POST",
                body: JSONEncoder().encode(["email": email, "role": role]))
        } catch {
            if sessionGeneration == generation, selectedOrganizationID == organization.id { issue = error.localizedDescription }
        }
        guard sessionGeneration == generation else { return }
        busy = false
        if selectedOrganizationID == organization.id { await loadOrganization(organization) }
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
        let previous = stored
        sessionGeneration &+= 1
        Self.keychainDelete(key: keychainKey)
        stored = nil; user = nil; organizations = []; projects = []; members = []
        selectedOrganizationID = nil
        busy = false; issue = nil; publicationMessage = nil
        if let previous {
            // Local logout and entitlement clearing never wait for connectivity.
            // Revocation uses the captured token and cannot touch a newer login.
            Task {
                var request = URLRequest(url: previous.baseURL.appendingPathComponent("v1/auth/logout"))
                request.httpMethod = "POST"; request.timeoutInterval = 10
                request.setValue("Bearer \(previous.session.token)", forHTTPHeaderField: "Authorization")
                _ = try? await TeamHTTP.session.data(for: request)
            }
        }
    }

    /// A fixed destination binds every queued package to its original workspace.
    /// The bearer stays private to the request context and never becomes UI text.
    func transferContext() throws -> TeamTransferContext {
        guard let stored, let organizationID = selectedOrganizationID else { throw TeamError.notConnected }
        return TeamTransferContext(baseURL: stored.baseURL, token: stored.session.token,
            userID: stored.session.user.id, organizationID: organizationID, generation: sessionGeneration)
    }

    func requireCurrentTransfer(_ context: TeamTransferContext) throws {
        guard context.generation == sessionGeneration, context.baseURL == stored?.baseURL,
              context.userID == stored?.session.user.id, context.organizationID == selectedOrganizationID,
              context.matchesToken(stored?.session.token) else { throw CancellationError() }
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
        guard let stored else { throw TeamError.notConnected }
        return TeamRequestContext(baseURL: stored.baseURL, token: stored.session.token,
            userID: stored.session.user.id, generation: sessionGeneration)
    }

    private func requireCurrent(_ context: TeamRequestContext, organizationID: UUID? = nil) throws {
        guard context.generation == sessionGeneration,
              stored?.session.token == context.token, stored?.session.user.id == context.userID,
              organizationID == nil || selectedOrganizationID == organizationID else { throw CancellationError() }
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
        let split = path.split(separator: "?", maxSplits: 1).map(String.init)
        guard var components = URLComponents(url: base.appendingPathComponent(split[0]), resolvingAgainstBaseURL: false) else { throw TeamError.invalidURL }
        if split.count == 2 { components.percentEncodedQuery = split[1] }
        guard let url = components.url else { throw TeamError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await TeamHTTP.session.data(for: request)
        guard generation == sessionGeneration else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
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
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { throw TeamError.invalidURL }
        return url
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

/// Authentication context is immutable: an old in-flight purchase never moves
/// to a different account or organization when the user switches workspaces.
private struct TeamPurchaseSink: StoreKitEvidenceSink {
    let baseURL: URL
    let token: String
    let userID: UUID
    let organizationID: UUID

    func acceptedStoreKitGrant(_ evidence: VerifiedPurchaseEvidence) async throws -> EntitlementSnapshot {
        guard evidence.appAccountToken == userID else { throw TeamError.rejected("Покупка принадлежит другому аккаунту.") }
        struct Payload: Encodable { var signedTransaction: String }
        struct Response: Decodable { var verifiedEntitlement: EntitlementSnapshot? }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/organizations/\(organizationID.uuidString)/billing/apple/verify"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(signedTransaction: evidence.signedTransactionJWS))
        let (data, response) = try await TeamHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TeamError.rejected("Сервер не подтвердил командную подписку. Персональные права Apple доступны независимо.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid server date")
            }
            return date
        }
        guard let entitlement = try decoder.decode(Response.self, from: data).verifiedEntitlement,
              entitlement.source == .serverVerified, entitlement.scope == .organization(organizationID) else {
            throw TeamError.rejected("Сервер не подтвердил права выбранной организации.")
        }
        return entitlement
    }
}
