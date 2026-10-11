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
    private var activePackageID: UUID?
    private var active = true
    private var generation: UInt64 = 0
    private var preparingProjects = Set<UUID>()
    private var displayedProjectID: UUID?
    private var lastProgressReport = Date.distantPast
    private var pendingPreparations: [UUID: (AtlasProjectSnapshot, URL, TeamTransferContext)] = [:]
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
    }

    var connectionHint: String {
        guard team.connected, team.selectedOrganizationID != nil else {
            return "Команда не подключена. Исходники доступны на устройстве; выберите рабочее пространство для отправки."
        }
        switch network {
        case .offline: return "Нет сети. Очередь сохранена и продолжится после подключения при открытом Atlas."
        case .wifi: return "Подключён Wi-Fi."
        case .cellular: return "Мобильная сеть. Комплекты с ограничением Wi-Fi ожидают подключения."
        case .other: return "Подключена сеть. Комплекты с ограничением Wi-Fi ожидают Wi-Fi."
        }
    }
    func projectRecords(projectID: UUID) -> [FieldTransferRecord] {
        guard let context = try? team.transferContext() else { return [] }
        return records.filter { $0.manifest.projectID == projectID && $0.scope == context.scope }
    }
    func settings(projectID: UUID) async -> FieldTransferSettings {
        guard let queue else { return FieldTransferSettings() }
        let scope = (try? team.transferContext().scope) ?? offlineScope
        do { return try await queue.settings(projectID: projectID, scope: scope) }
        catch { issue = error.localizedDescription; return FieldTransferSettings() }
    }
    func setSettings(_ value: FieldTransferSettings, projectID: UUID) async {
        guard let queue else { return }
        let scope = (try? team.transferContext().scope) ?? offlineScope
        do {
            try await queue.setSettings(value, projectID: projectID, scope: scope)
            // Applying a new restriction cancels an in-flight chunk before the
            // next one, including switching automatic delivery back to manual.
            generation &+= 1; worker?.cancel(); retryTimer?.cancel()
            await refresh(); resume()
        } catch { issue = error.localizedDescription }
    }
    func refresh(projectID: UUID? = nil) async {
        if let projectID { displayedProjectID = projectID }
        guard let queue else { return }
        guard let context = try? team.transferContext() else { records = []; return }
        do {
            let values = try await queue.records(projectID: displayedProjectID, scope: context.scope, limit: 100)
            try team.requireCurrentTransfer(context)
            records = values
        } catch is CancellationError { records = [] }
        catch { issue = error.localizedDescription }
    }

    /// Called after a durable local save. There is no network requirement for
    /// saving a capture, and preparing a manual package never starts an upload.
    @discardableResult
    func prepare(snapshot: AtlasProjectSnapshot, assetDirectory: URL) async -> Bool {
        guard let queue, let context = try? team.transferContext() else { return false }
        guard preparingProjects.insert(snapshot.project.id).inserted else {
            pendingPreparations[snapshot.project.id] = (snapshot, assetDirectory, context)
            return false
        }
        isPreparing = true
        defer {
            preparingProjects.remove(snapshot.project.id); isPreparing = !preparingProjects.isEmpty
            if let pending = pendingPreparations.removeValue(forKey: snapshot.project.id) {
                Task { [weak self] in
                    guard let self else { return }
                    do { try self.team.requireCurrentTransfer(pending.2) }
                    catch { return }
                    _ = await self.prepare(snapshot: pending.0, assetDirectory: pending.1)
                }
            }
        }
        do {
            let existing = try await queue.records(projectID: snapshot.project.id, scope: context.scope,
                limit: FieldTransferQueue.maximumRecords)
            let prepared = try await assembler.prepare(snapshot: snapshot, assetDirectory: assetDirectory,
                scope: context.scope, device: Self.device(), previous: existing.map(\.manifest))
            try Task.checkCancellation(); try team.requireCurrentTransfer(context)
            for package in prepared {
                try Task.checkCancellation()
                _ = try await queue.register(manifest: package.manifest, scope: context.scope)
            }
            let skipped = snapshot.scans.filter { $0.status != .ready }.count
            if skipped > 0 {
                issue = "В очередь вошли завершённые материалы. Незавершённых съёмок: \(skipped). Завершите или восстановите их для отправки."
            } else { issue = nil }
            await refresh(); resume()
            return true
        } catch is CancellationError { return false }
        catch { issue = error.localizedDescription; return false }
    }
    func send(projectID: UUID) async {
        guard let queue else { return }
        do {
            let context = try team.transferContext()
            try await queue.requestSend(projectID: projectID, scope: context.scope)
            try team.requireCurrentTransfer(context)
            issue = nil; await refresh(); resume()
        } catch { issue = error.localizedDescription }
    }
    func requestSend(projectID: UUID) async { await send(projectID: projectID) }

    func retry(id: UUID) async {
        guard let queue else { return }
        do {
            let context = try team.transferContext()
            guard let record = try await queue.record(id: id), record.scope == context.scope else { throw FieldTransferError.invalidScope }
            try await queue.requestSend(projectID: record.manifest.projectID, scope: context.scope, transferIDs: [id])
            try team.requireCurrentTransfer(context)
            await refresh(); resume()
        } catch { issue = error.localizedDescription }
    }
    func pause(id: UUID) async {
        guard let queue else { return }
        do {
            let context = try team.transferContext()
            guard let record = try await queue.record(id: id), record.scope == context.scope else { throw FieldTransferError.invalidScope }
            _ = try await queue.pause(id: id)
            if activePackageID == id { generation &+= 1; worker?.cancel() }
            await refresh()
        } catch { issue = error.localizedDescription }
    }
    func sceneBecameActive() { active = true; resume() }
    func sceneBecameInactive() {
        active = false; generation &+= 1; worker?.cancel(); retryTimer?.cancel()
    }
    func authenticationChanged() async {
        generation &+= 1; worker?.cancel(); retryTimer?.cancel()
        pendingPreparations = [:]; records = []; await refresh(); resume()
    }
    func deliveryPassport(snapshot: AtlasProjectSnapshot, assetDirectory: URL) async throws -> Data {
        let preparedBy = team.user.map { FieldCaptureOperator(userID: $0.id, displayName: $0.displayName) }
        return try await assembler.deliveryPassport(snapshot: snapshot, assetDirectory: assetDirectory,
            device: Self.device(), preparedBy: preparedBy)
    }

    func remoteMaterials(projectID: UUID) async throws -> [RemoteFieldMaterial] {
        let context = try team.transferContext()
        let values = try await transport.list(projectID: projectID, context: context)
        try team.requireCurrentTransfer(context)
        return values
    }
    func download(material: RemoteFieldMaterial, to assetDirectory: URL) async throws -> DownloadedFieldMaterial {
        // The supplied root is accepted for API symmetry; this assembler owns
        // its managed package directory and never writes over live originals.
        _ = assetDirectory
        let context = try team.transferContext()
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
        network = value; generation &+= 1; worker?.cancel(); retryTimer?.cancel(); resume()
    }
    private func resume() {
        guard active, worker == nil, network != .offline, let queue,
              let context = try? team.transferContext() else { return }
        retryTimer?.cancel(); retryTimer = nil
        let runGeneration = generation
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(context: context, queue: queue, generation: runGeneration)
            self.worker = nil; self.isSending = false; self.activePackageID = nil
            await self.refresh()
            if self.active, self.network != .offline,
               let pending = try? await queue.pending(scope: context.scope, network: self.network,
                   now: Date().addingTimeInterval(301), limit: 1), !pending.isEmpty {
                self.scheduleRetry()
            }
        }
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
                if error is CancellationError || Task.isCancelled {
                    _ = try? await queue.markFailed(id: record.id,
                        message: "Передача приостановлена. Подтверждённые данные сохранены; продолжим при подходящих условиях.", retryable: true)
                } else if let failure = error as? FieldTransportError {
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
