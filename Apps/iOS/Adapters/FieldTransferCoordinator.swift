import Foundation
import SwiftUI
import UIKit
import Darwin
import Network
import Combine
import AtlasCore

@MainActor
final class FieldTransferCoordinator: ObservableObject {
    @Published private(set) var records: [FieldTransferRecord] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var isSending = false
    @Published private(set) var network: TransferNetwork = .offline
    @Published private(set) var issue: String?
    private let team: TeamService
    private let queue: FieldTransferQueue?
    private let assembler: FieldTransferAssembler
    private let transport: FieldTransferTransport
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.atlasfield.transfer.network")
    private var subscriptions = Set<AnyCancellable>()
    private var worker: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var renewalID: UUID?
    private var renewalScope: FieldTransferScope?
    private var renewalRetryAt: Date?
    private var renewalFailures = 0
    private var renewalBlockedScope: FieldTransferScope?
    private var blockedRuntimeGeneration: UInt64?
    private var observedScope: FieldTransferScope?
    private var activePackageID: UUID?
    private var active = true
    private var generation: UInt64 = 0
    private var preparingProjects = Set<UUID>()
    private var displayedProjectID: UUID?
    private var lastProgressReport = Date.distantPast
    private var pendingPreparations: [UUID: (AtlasProjectSnapshot, URL, FieldTransferScope)] = [:]
    private let offlineScope = FieldTransferScope(serverOrigin: "https://local.atlas.invalid",
        userID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        organizationID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)

    init(team: TeamService, directory: URL) {
        self.team = team
        assembler = FieldTransferAssembler(directory: directory)
        transport = FieldTransferTransport(team: team)
        do { queue = try FieldTransferQueue(path: directory.appendingPathComponent("field-transfers.sqlite").path) }
        catch { queue = nil; issue = "Очередь отправки недоступна: \(error.localizedDescription). Исходники сохранены." }
        monitor.pathUpdateHandler = { [weak self] path in
            let value: TransferNetwork = path.status != .satisfied ? .offline :
                (path.usesInterfaceType(.wifi) ? .wifi : (path.usesInterfaceType(.cellular) ? .cellular : .other))
            Task { @MainActor [weak self] in self?.networkChanged(value) }
        }
        monitor.start(queue: monitorQueue)
        team.$user.map { $0?.id }.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.authenticationChanged() }
        }.store(in: &subscriptions)
        team.$selectedOrganizationID.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.authenticationChanged() }
        }.store(in: &subscriptions)
        team.$busy.removeDuplicates().sink { [weak self] busy in
            guard !busy else { return }
            Task { @MainActor [weak self] in self?.resume() }
        }.store(in: &subscriptions)
    }

    var connectionHint: String {
        guard team.transferScope != nil else {
            return "Исходники доступны на устройстве. Выберите подключение для серверной передачи; локальные инструменты работают без него."
        }
        if renewalTask != nil { return "Обновляем защищённое подключение. Очередь и подтверждённые фрагменты сохранены." }
        if renewalBlockedScope == team.transferScope {
            return "Для продолжения обновите подключение или войдите на сайт снова. Очередь и исходники сохранены."
        }
        switch network {
        case .offline: return "Нет сети. Очередь сохранена и продолжится после подключения при открытом TerraView."
        case .wifi: return "Подключён Wi-Fi."
        case .cellular: return "Мобильная сеть. Комплекты с ограничением Wi-Fi ожидают подключения."
        case .other: return "Подключена сеть. Комплекты с ограничением Wi-Fi ожидают Wi-Fi."
        }
    }
    func projectRecords(projectID: UUID) -> [FieldTransferRecord] {
        guard let scope = team.transferScope else { return [] }
        return records.filter { $0.manifest.projectID == projectID && $0.scope == scope }
    }
    func settings(projectID: UUID) async -> FieldTransferSettings {
        guard let queue else { return FieldTransferSettings() }
        let scope = team.transferScope ?? offlineScope
        do {
            let value = try await queue.settings(projectID: projectID, scope: scope)
            guard (team.transferScope ?? offlineScope) == scope else { return FieldTransferSettings() }
            return value
        } catch { issue = error.localizedDescription; return FieldTransferSettings() }
    }
    func setSettings(_ value: FieldTransferSettings, projectID: UUID) async {
        guard let queue else { return }
        let scope = team.transferScope ?? offlineScope
        do {
            try await queue.setSettings(value, projectID: projectID, scope: scope)
            guard (team.transferScope ?? offlineScope) == scope else { return }
            // The durable setting belongs to the captured destination even if
            // the operator switches accounts while SQLite finishes its write.
            generation &+= 1; worker?.cancel(); retryTimer?.cancel()
            await refresh(); resume()
        } catch { issue = error.localizedDescription }
    }
    func refresh(projectID: UUID? = nil) async {
        if let projectID { displayedProjectID = projectID }
        guard let queue else { return }
        guard let scope = team.transferScope else { records = []; return }
        do {
            let values = try await queue.records(projectID: displayedProjectID, scope: scope, limit: 100)
            try team.requireCurrentScope(scope)
            records = values
        } catch is CancellationError { records = [] }
        catch { issue = error.localizedDescription }
    }

    /// A network context is obtained only after renewal, then checked against
    /// the identity and sharing destination captured before the first await.
    func renewConnection(expectedScope scope: FieldTransferScope) async throws -> TeamTransferContext {
        try Task.checkCancellation(); try team.requireCurrentScope(scope)
        guard active else { throw CancellationError() }
        // Automatic renewal has its own task, never the upload worker. An
        // explicit action can wait for it without cancelling its own login.
        if let renewalTask { await renewalTask.value }
        try Task.checkCancellation(); try team.requireCurrentScope(scope)
        guard active else { throw CancellationError() }
        if network == .offline, (try? team.transferContext()) == nil { throw URLError(.notConnectedToInternet) }
        renewalBlockedScope = nil; blockedRuntimeGeneration = nil; renewalRetryAt = nil; renewalFailures = 0
        try await team.renewRuntimeIfNeeded()
        try Task.checkCancellation(); try team.requireCurrentScope(scope)
        guard active else { throw CancellationError() }
        let context = try team.transferContext()
        guard context.scope == scope else { throw CancellationError() }
        return context
    }

    /// Called after a durable local save. Local staging needs destination
    /// metadata, never a valid network token or a successful server request.
    @discardableResult
    func prepare(snapshot: AtlasProjectSnapshot, assetDirectory: URL,
                 expectedContext: TeamTransferContext? = nil, expectedScope: FieldTransferScope? = nil) async -> Bool {
        guard let queue, let scope = expectedScope ?? expectedContext?.scope ?? team.transferScope else { return false }
        do { try Task.checkCancellation(); try team.requireCurrentScope(scope) }
        catch { return false }
        guard preparingProjects.insert(snapshot.project.id).inserted else {
            pendingPreparations[snapshot.project.id] = (snapshot, assetDirectory, scope)
            return false
        }
        isPreparing = true
        defer {
            preparingProjects.remove(snapshot.project.id); isPreparing = !preparingProjects.isEmpty
            if let pending = pendingPreparations.removeValue(forKey: snapshot.project.id) {
                Task { [weak self] in
                    guard let self else { return }
                    do { try self.team.requireCurrentScope(pending.2) }
                    catch { return }
                    _ = await self.prepare(snapshot: pending.0, assetDirectory: pending.1, expectedScope: pending.2)
                }
            }
        }
        do {
            let existing = try await queue.records(projectID: snapshot.project.id, scope: scope,
                limit: FieldTransferQueue.maximumRecords)
            try Task.checkCancellation(); try team.requireCurrentScope(scope)
            let prepared = try await assembler.prepare(snapshot: snapshot, assetDirectory: assetDirectory,
                scope: scope, device: Self.device(), previous: existing.map(\.manifest))
            try Task.checkCancellation(); try team.requireCurrentScope(scope)
            for package in prepared {
                try Task.checkCancellation(); try team.requireCurrentScope(scope)
                _ = try await queue.register(manifest: package.manifest, scope: scope)
            }
            try Task.checkCancellation(); try team.requireCurrentScope(scope)
            let skipped = snapshot.scans.filter { $0.status != .ready }.count
            if skipped > 0 {
                issue = "В очередь вошли завершённые материалы. Незавершённых съёмок: \(skipped). Завершите или восстановите их для отправки."
            } else { issue = nil }
            await refresh(); resume()
            return true
        } catch is CancellationError { return false }
        catch { issue = error.localizedDescription; return false }
    }
    /// Operator consent is a local durable queue write. It must survive being
    /// offline with an expired runtime; only the worker needs a fresh bearer.
    func send(projectID: UUID, expectedContext: TeamTransferContext? = nil,
              expectedScope: FieldTransferScope? = nil) async {
        guard let queue, let scope = expectedScope ?? expectedContext?.scope ?? team.transferScope else { return }
        do {
            try Task.checkCancellation(); try team.requireCurrentScope(scope)
            try await queue.requestSend(projectID: projectID, scope: scope)
            try Task.checkCancellation(); try team.requireCurrentScope(scope)
            allowExplicitRetry(scope: scope)
            issue = nil; await refresh(); resume()
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }
    func requestSend(projectID: UUID, expectedContext: TeamTransferContext? = nil,
                     expectedScope: FieldTransferScope? = nil) async {
        await send(projectID: projectID, expectedContext: expectedContext, expectedScope: expectedScope)
    }

    func retry(id: UUID) async {
        guard let queue, let scope = team.transferScope else { return }
        do {
            try Task.checkCancellation(); try team.requireCurrentScope(scope)
            guard let record = try await queue.record(id: id), record.scope == scope else { throw FieldTransferError.invalidScope }
            try Task.checkCancellation(); try team.requireCurrentScope(scope)
            try await queue.requestSend(projectID: record.manifest.projectID, scope: scope, transferIDs: [id])
            try Task.checkCancellation(); try team.requireCurrentScope(scope)
            allowExplicitRetry(scope: scope)
            issue = nil; await refresh(); resume()
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }
    private func allowExplicitRetry(scope: FieldTransferScope) {
        guard team.transferScope == scope else { return }
        renewalBlockedScope = nil; blockedRuntimeGeneration = nil
        renewalRetryAt = nil; renewalFailures = 0
    }
    func pause(id: UUID) async {
        guard let queue, let scope = team.transferScope else { return }
        do {
            guard let record = try await queue.record(id: id), record.scope == scope else { throw FieldTransferError.invalidScope }
            try team.requireCurrentScope(scope)
            _ = try await queue.pause(id: id)
            if activePackageID == id { generation &+= 1; worker?.cancel() }
            await refresh()
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }
    func sceneBecameActive() { active = true; resume() }
    func sceneBecameInactive() {
        active = false; generation &+= 1; worker?.cancel(); retryTimer?.cancel(); renewalTask?.cancel()
    }
    func authenticationChanged() async {
        let scope = team.transferScope
        generation &+= 1; worker?.cancel(); retryTimer?.cancel()
        if renewalScope != scope { renewalTask?.cancel() }
        if observedScope != scope {
            observedScope = scope
            renewalBlockedScope = nil; blockedRuntimeGeneration = nil; renewalRetryAt = nil; renewalFailures = 0
        }
        if let scope { pendingPreparations = pendingPreparations.filter { $0.value.2 == scope } }
        else { pendingPreparations = [:] }
        records = []; await refresh(); resume()
    }
    func deliveryPassport(snapshot: AtlasProjectSnapshot, assetDirectory: URL) async throws -> Data {
        let preparedBy = team.user.map { FieldCaptureOperator(userID: $0.id, displayName: $0.displayName) }
        return try await assembler.deliveryPassport(snapshot: snapshot, assetDirectory: assetDirectory,
            device: Self.device(), preparedBy: preparedBy)
    }

    func remoteMaterials(projectID: UUID) async throws -> [RemoteFieldMaterial] {
        guard let scope = team.transferScope else { throw TeamError.notConnected }
        let context = try await renewConnection(expectedScope: scope)
        let values = try await transport.list(projectID: projectID, context: context)
        try team.requireCurrentTransfer(context)
        return values
    }
    func download(material: RemoteFieldMaterial, to assetDirectory: URL) async throws -> DownloadedFieldMaterial {
        // The supplied root is accepted for API symmetry; this assembler owns
        // its managed package directory and never writes over live originals.
        _ = assetDirectory
        guard let scope = team.transferScope else { throw TeamError.notConnected }
        let context = try await renewConnection(expectedScope: scope)
        try material.manifest.validate()
        let runGeneration = generation
        for asset in material.manifest.assets {
            try checkRun(context, generation: runGeneration)
            var offset = try await assembler.downloadOffset(asset: asset, packageID: material.captureID, scope: context.scope)
            while offset < asset.byteCount {
                try checkRun(context, generation: runGeneration)
                let data = try await transport.downloadChunk(material: material, asset: asset, offset: offset, context: context)
                try checkRun(context, generation: runGeneration)
                try await assembler.appendDownload(data, asset: asset, packageID: material.captureID, scope: context.scope, offset: offset)
                offset += Int64(data.count)
            }
            if asset.byteCount == 0 {
                try await assembler.appendDownload(Data(), asset: asset, packageID: material.captureID, scope: context.scope, offset: 0)
            }
            try await assembler.completeDownload(asset: asset, packageID: material.captureID, scope: context.scope)
        }
        try team.requireCurrentTransfer(context)
        return try await assembler.downloaded(material: material, scope: context.scope)
    }

    private func networkChanged(_ value: TransferNetwork) {
        guard network != value else { return }
        network = value; generation &+= 1; worker?.cancel(); retryTimer?.cancel()
        if value == .offline { renewalTask?.cancel() }
        resume()
    }
    private func resume() {
        guard active, worker == nil, renewalTask == nil, network != .offline, let queue,
              let scope = team.transferScope else { return }
        if renewalBlockedScope == scope {
            if let current = try? team.transferContext(), current.generation != blockedRuntimeGeneration {
                // The operator established a new runtime after the rejection.
                renewalBlockedScope = nil; blockedRuntimeGeneration = nil
            } else { return }
        }
        if let retryAt = renewalRetryAt, retryAt > Date() { scheduleRetry(); return }
        guard let context = try? team.transferContext() else {
            guard renewalBlockedScope != scope else { return }
            if team.busy { return } // The busy publisher wakes us when it clears.
            startRenewal(scope: scope, queue: queue)
            return
        }
        retryTimer?.cancel(); retryTimer = nil
        let runGeneration = generation
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(context: context, queue: queue, generation: runGeneration)
            self.worker = nil; self.isSending = false; self.activePackageID = nil
            await self.refresh()
            guard self.active, self.network != .offline, self.worker == nil,
                  let scope = self.team.transferScope,
                  let pending = try? await queue.pending(scope: scope, network: self.network,
                      now: Date().addingTimeInterval(301), limit: 1), !pending.isEmpty,
                  self.team.transferScope == scope, self.active, self.network != .offline,
                  self.worker == nil else { return }
            self.scheduleRetry()
        }
    }

    /// Renewing outside `worker` prevents auth publishers from cancelling the
    /// refresh operation that a cancelled upload would otherwise be awaiting.
    private func startRenewal(scope: FieldTransferScope, queue: FieldTransferQueue) {
        let id = UUID()
        renewalID = id; renewalScope = scope
        renewalTask = Task { [weak self] in
            guard let self else { return }
            var retry = false
            var succeeded = false
            var interrupted = false
            do {
                try Task.checkCancellation(); try self.team.requireCurrentScope(scope)
                guard self.active, self.network != .offline else { throw CancellationError() }
                let pending = try await queue.pending(scope: scope, network: self.network,
                    now: Date().addingTimeInterval(301), limit: 1)
                try Task.checkCancellation(); try self.team.requireCurrentScope(scope)
                guard !pending.isEmpty else { throw CancellationError() }
                try await self.team.renewRuntimeIfNeeded()
                try Task.checkCancellation(); try self.team.requireCurrentScope(scope)
                let context = try self.team.transferContext()
                guard context.scope == scope, self.active, self.network != .offline else { throw CancellationError() }
                self.renewalFailures = 0; self.renewalRetryAt = nil; self.issue = nil
                succeeded = true
            } catch is CancellationError {
                // A rapid return to the foreground must wake work after the
                // cancelled network call actually unwinds, not before it.
                interrupted = Task.isCancelled
            } catch {
                if self.team.transferScope == scope {
                    self.issue = error.localizedDescription
                    if self.isTransientRenewal(error) {
                        self.renewalFailures = min(self.renewalFailures + 1, 6)
                        self.renewalRetryAt = Date().addingTimeInterval(min(60, pow(2, Double(self.renewalFailures))))
                        retry = true
                    } else {
                        // No automatic login, permission bypass, or repeated
                        // 401/403 requests. An explicit operator retry may renew.
                        self.renewalBlockedScope = scope
                        self.blockedRuntimeGeneration = (try? self.team.transferContext())?.generation
                    }
                }
            }
            guard self.renewalID == id else { return }
            self.renewalTask = nil; self.renewalID = nil; self.renewalScope = nil
            await self.refresh()
            if succeeded || interrupted { self.resume() }
            else if retry, self.active, self.network != .offline { self.scheduleRetry() }
        }
    }
    private func isTransientRenewal(_ error: Error) -> Bool {
        if let value = error as? URLError {
            return value.code != .cancelled && value.code != .userAuthenticationRequired
        }
        if case let StaffAccountError.http(status) = error {
            return status == 408 || status == 429 || status >= 500
        }
        return false
    }
    private func scheduleRetry() {
        retryTimer?.cancel()
        // Queue backoff is checked by claimNext; this short timer does not run
        // when Atlas is inactive, offline, or unauthenticated.
        retryTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.active else { return }
            self.retryTimer = nil; self.resume()
        }
    }
    private func run(context: TeamTransferContext, queue: FieldTransferQueue, generation runGeneration: UInt64) async {
        while active, runGeneration == generation, !Task.isCancelled {
            let record: FieldTransferRecord
            do {
                try team.requireCurrentTransfer(context)
                guard let next = try await queue.claimNext(scope: context.scope, network: network) else { return }
                record = next
            } catch { if !(error is CancellationError) { issue = error.localizedDescription }; return }
            isSending = true; activePackageID = record.id; await refresh()
            do {
                try checkRun(context, generation: runGeneration)
                let snapshot = try await assembler.snapshot(for: record.manifest)
                try await team.ensureTransferProject(snapshot, context: context)
                try checkRun(context, generation: runGeneration)
                var status = try await transport.initialize(record.manifest, context: context)
                for progress in status.assets {
                    _ = try await queue.reconcileAcknowledgedOffset(id: record.id, assetID: progress.id, offset: progress.uploadedBytes)
                }
                if status.state != "complete" {
                    for asset in record.manifest.assets {
                        try checkRun(context, generation: runGeneration)
                        try await assembler.verify(asset: asset)
                        var offset = status.assets.first(where: { $0.id == asset.id })?.uploadedBytes ?? 0
                        while offset < asset.byteCount {
                            try checkRun(context, generation: runGeneration)
                            let data = try await assembler.readChunk(asset: asset, offset: offset, length: status.chunkSize)
                            let progress = try await transport.upload(data, asset: asset, manifest: record.manifest,
                                offset: offset, context: context)
                            try checkRun(context, generation: runGeneration)
                            _ = try await queue.recordAcknowledgedOffset(id: record.id, assetID: asset.id, offset: progress.uploadedBytes)
                            offset = progress.uploadedBytes
                            await reportProgress(id: record.id, context: context)
                        }
                    }
                    try checkRun(context, generation: runGeneration)
                    status = try await transport.finalize(record.manifest, context: context)
                }
                try checkRun(context, generation: runGeneration)
                guard let completedAt = status.completedAt, status.assets.allSatisfy(\.verified) else { throw FieldTransportError.incomplete }
                for progress in status.assets {
                    _ = try await queue.reconcileAcknowledgedOffset(id: record.id, assetID: progress.id, offset: progress.uploadedBytes)
                }
                _ = try await queue.markCompleted(id: record.id, serverReceiptID: status.captureID.uuidString, completedAt: completedAt)
                issue = nil
            } catch {
                if case StaffAccountError.http(403) = error {
                    renewalBlockedScope = context.scope; blockedRuntimeGeneration = context.generation
                }
                if case TeamError.runtimeExpired = error {
                    renewalBlockedScope = context.scope; blockedRuntimeGeneration = context.generation
                }
                if error is CancellationError || Task.isCancelled {
                    _ = try? await queue.markFailed(id: record.id,
                        message: "Передача приостановлена. Подтверждённые данные сохранены; продолжим при подходящих условиях.", retryable: true)
                } else if let failure = error as? FieldTransportError {
                    if case let .failed(status, _) = failure, status == 401 || status == 403 {
                        renewalBlockedScope = context.scope
                        blockedRuntimeGeneration = context.generation
                    }
                    if case let .manifestConflict(message) = failure {
                        _ = try? await queue.markConflict(id: record.id, message: message)
                    } else {
                        _ = try? await queue.markFailed(id: record.id, message: failure.localizedDescription, retryable: failure.retryable)
                    }
                    issue = failure.localizedDescription
                } else {
                    let retryable = (error as? URLError) != nil
                    _ = try? await queue.markFailed(id: record.id, message: error.localizedDescription, retryable: retryable)
                    issue = error.localizedDescription
                }
            }
            await refresh(); activePackageID = nil
            if renewalBlockedScope == context.scope { return }
        }
    }
    private func reportProgress(id: UUID, context: TeamTransferContext) async {
        guard Date().timeIntervalSince(lastProgressReport) >= 0.25, let queue else { return }
        do {
            guard let record = try await queue.record(id: id) else { return }
            try team.requireCurrentTransfer(context)
            if let index = records.firstIndex(where: { $0.id == id }) { records[index] = record }
            else if displayedProjectID == nil || displayedProjectID == record.manifest.projectID { records.insert(record, at: 0) }
            lastProgressReport = Date()
        } catch { }
    }

    private func checkRun(_ context: TeamTransferContext, generation value: UInt64) throws {
        try Task.checkCancellation(); try team.requireCurrentTransfer(context)
        guard active, value == generation else { throw CancellationError() }
    }
    private static func device() -> FieldCaptureDevice {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var system = utsname()
        uname(&system)
        let identifier = withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.bindMemory(to: UInt8.self).prefix { $0 != 0 }, as: UTF8.self)
        }
        return FieldCaptureDevice(model: UIDevice.current.model + " · " + identifier,
            osVersion: UIDevice.current.systemVersion, appVersion: version + " (" + build + ")")
    }
}
