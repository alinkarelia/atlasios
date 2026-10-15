import Foundation
import SwiftUI
import Combine
import UIKit
@preconcurrency import RealityKit
import AtlasCore

/// Apple's ObjectCaptureSession owns the camera, object bounds and scan-pass
/// guidance. Atlas owns durable originals and distinguishes them from a model.
@MainActor
final class ObjectCaptureAdapter: ObservableObject {
    enum State: Equatable {
        case idle, preparing, ready, detecting, capturing, finishing
        case datasetReady, reconstructing, modelReady, unavailable, failed
    }
    @Published private(set) var state: State
    @Published private(set) var session: ObjectCaptureSession?
    @Published private(set) var shotCount = 0
    @Published private(set) var maximumShots = 0
    @Published private(set) var passCompleted = false
    @Published private(set) var isPaused = false
    @Published private(set) var canRequestShot = false
    @Published private(set) var feedback: [String] = []
    @Published private(set) var trackingMessage = "Наведите камеру на неподвижный объект"
    @Published private(set) var errorMessage: String?
    @Published private(set) var warningMessage: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var processingStage = "Подготовка снимков"
    @Published private(set) var manifest: ObjectCaptureManifest?
    @Published private(set) var manifestURL: URL?
    @Published private(set) var modelURL: URL?
    @Published private(set) var savedRevision = 0
    private var captureRoot: URL?
    private var writer: ObjectCaptureDatasetWriter?
    private var observations: [Task<Void, Never>] = []
    private var finishTask: Task<Void, Never>?
    private var finishingLifetime: Task<Void, Never>?
    private var reconstructionTask: Task<Void, Never>?
    private var reconstructionCancellation: ObjectPhotogrammetryCancellation?
    private var generation = UUID()
    private var latestLocation: GeoLocationFix?
    private var pendingCheckpoint: Task<Void, Never>?
    private var lastCheckpointAt = Date.distantPast

    static var isSupported: Bool { ObjectCaptureSession.isSupported }
    static var canReconstruct: Bool { PhotogrammetrySession.isSupported }
    var hasLiveCapture: Bool {
        [.preparing, .ready, .detecting, .capturing, .finishing].contains(state)
    }
    var canBuildModel: Bool {
        (state == .datasetReady || state == .modelReady) && Self.canReconstruct &&
        (manifest?.images.count ?? 0) >= 10
    }
    var imageCount: Int { hasLiveCapture ? shotCount : (manifest?.images.count ?? shotCount) }

    init() { state = Self.isSupported ? .idle : .unavailable }

    func start(project: AtlasProject, directory: URL, captureOperator: FieldCaptureOperator? = nil) async {
        guard StaffWorkAccess.allowed(projectID:project.id) else { errorMessage = StaffAccessError.needsLocation.localizedDescription; return }
        guard [.idle, .datasetReady, .modelReady, .failed].contains(state), Self.isSupported,
              !Task.isCancelled else { return }
        stopObserving()
        let ticket = UUID(); generation = ticket
        state = .preparing; errorMessage = nil; warningMessage = nil
        manifestURL = nil; modelURL = nil; manifest = nil
        shotCount = 0; passCompleted = false; isPaused = false; progress = 0
        lastCheckpointAt = .distantPast; pendingCheckpoint = nil
        do {
            try await CaptureCoordinator.requireCameraAccess()
            guard ticket == generation, !Task.isCancelled else { state = .idle; return }
            let id = UUID()
            let root = directory.appendingPathComponent("Projects/\(project.id.uuidString)/Captures/Object-\(id.uuidString)",
                                                        isDirectory: true)
            let device = FieldCaptureDevice(model: UIDevice.current.model,
                osVersion: UIDevice.current.systemVersion,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
            var metadata = ObjectCaptureManifest(id: id, projectID: project.id, projectName: project.name,
                frameID: UUID(), createdAt: Date(), captureOperator: captureOperator,
                device: device, timeZoneIdentifier: TimeZone.current.identifier,
                utcOffsetSeconds: TimeZone.current.secondsFromGMT())
            if let fix = latestLocation, GeoTagPolicy.acceptDeviceFix(fix, now: Date()) {
                metadata.geoTag = GeoTag(automaticFix: fix)
                metadata.locationObservations = [fix]
            }
            let datasetWriter = ObjectCaptureDatasetWriter(root: root, managedRoot: directory)
            try await datasetWriter.create(metadata)
            guard generation == ticket, !Task.isCancelled else { state = .idle; return }
            writer = datasetWriter; captureRoot = root; manifest = metadata
            guard StaffWorkAccess.allowed(projectID:project.id) else { throw StaffAccessError.needsLocation }
            let capture = ObjectCaptureSession()
            session = capture
            maximumShots = capture.maximumNumberOfInputImages
            observe(capture, ticket: ticket)
            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = root.appendingPathComponent("Checkpoints", isDirectory: true)
            configuration.isOverCaptureEnabled = false
            capture.start(imagesDirectory: root.appendingPathComponent("Images", isDirectory: true),
                          configuration: configuration)
        } catch {
            guard generation == ticket else { return }
            state = .failed; errorMessage = error.localizedDescription
        }
    }

    func detectObject() {
        guard state == .ready, let session else { return }
        if !session.startDetecting() { errorMessage = "Не удалось найти объект. Добавьте света и держите его целиком в кадре." }
        else { errorMessage = nil }
    }
    func resetDetection() { _ = session?.resetDetection(); errorMessage = nil }
    func beginCapture() {
        guard StaffWorkAccess.allowed(projectID:manifest?.projectID) else { errorMessage = StaffAccessError.needsLocation.localizedDescription; return }
        guard state == .detecting, let session else { return }
        errorMessage = nil; session.startCapturing()
    }
    func togglePause() {
        guard state == .capturing, let session else { return }
        if session.isPaused {
            guard StaffWorkAccess.allowed(projectID:manifest?.projectID) else { errorMessage = StaffAccessError.needsLocation.localizedDescription; return }
            session.resume()
        } else { session.pause() }
    }
    func nextPass() {
        guard StaffWorkAccess.allowed(projectID:manifest?.projectID) else { return }
        guard state == .capturing, let session else { return }
        if session.isPaused { session.resume() }
        session.beginNewScanPass()
        passCompleted = false
    }
    func takeExtraShot() {
        guard StaffWorkAccess.allowed(projectID:manifest?.projectID) else { return }
        guard state == .capturing, !isPaused, session?.canRequestImageCapture == true else { return }
        session?.requestImageCapture()
    }
    func finishCapture() {
        guard state == .capturing, let session else { return }
        state = .finishing
        // A parent navigation change can remove the SwiftUI observer. Retain
        // this adapter until the framework closes its files and metadata is
        // committed; the ordinary close button already waits on savedRevision.
        finishingLifetime = Task { [self] in
            if Self.isTerminal(session.state) {
                captureStateChanged(session.state, ticket: generation)
            } else {
                for await value in session.stateUpdates {
                    if Self.isTerminal(value) {
                        captureStateChanged(value, ticket: generation); break
                    }
                }
            }
            if let finishTask { await finishTask.value }
            finishingLifetime = nil
        }
        if session.isPaused { session.resume() }
        session.finish()
    }

    func updateLocation(_ fix: GeoLocationFix?) {
        latestLocation = fix
        guard hasLiveCapture, state != .finishing, let fix,
              GeoTagPolicy.acceptDeviceFix(fix, now: Date()), var metadata = manifest else { return }
        if let chosen = GeoTagPolicy.bestAutomatic(current: metadata.geoTag?.automaticFix,
                                                  candidate: fix, now: Date()) {
            metadata.geoTag = GeoTag(automaticFix: chosen)
        }
        if metadata.locationObservations.last != fix {
            // At most one history point every three seconds; all points retain
            // their own observation time and simulated-source flag.
            if let previous = metadata.locationObservations.last,
               fix.observedAt.timeIntervalSince(previous.observedAt) < 3 {
                metadata.locationObservations[metadata.locationObservations.count - 1] = fix
            } else if metadata.locationObservations.count < 2_048 {
                metadata.locationObservations.append(fix)
            }
        }
        manifest = metadata
        checkpointIfNeeded()
    }

    /// Permission dialogs also deactivate the scene, so only actual live
    /// capture is paused. Processing is cancelled when the app backgrounds.
    func suspend(background: Bool) {
        if state == .capturing { session?.pause() }
        if background, state == .reconstructing { cancelReconstruction() }
    }
    func cancelUnusedPreview() {
        guard state == .ready || state == .detecting || state == .preparing else { return }
        generation = UUID(); session?.cancel(); session = nil; stopObserving()
        state = .idle
    }
    func suspendForDismissal() {
        if state == .capturing { finishCapture() }
        else if state == .ready || state == .detecting || state == .preparing { cancelUnusedPreview() }
        if state == .reconstructing { cancelReconstruction() }
    }

    func buildModel() {
        guard canBuildModel, let root = captureRoot, let writer, var metadata = manifest else { return }
        guard metadata.images.count <= PhotogrammetrySession.limits.maximumNumberOfInputImages else {
            errorMessage = "Снимков больше, чем поддерживает обработка на этом устройстве. Все оригиналы сохранены."; return
        }
        state = .reconstructing; progress = 0; errorMessage = nil
        processingStage = "Подготовка снимков"
        metadata.modelStatus = "reconstructing"; manifest = metadata
        let ticket = generation
        let cancellation = ObjectPhotogrammetryCancellation()
        reconstructionCancellation = cancellation
        let temporary = root.appendingPathComponent("reconstruction-\(UUID().uuidString).usdz")
        reconstructionTask = Task { [weak self] in
            do {
                try await writer.save(metadata)
                let completed = try await ObjectPhotogrammetryWorker.reconstruct(
                    images: root.appendingPathComponent("Images", isDirectory: true),
                    checkpoints: root.appendingPathComponent("Checkpoints", isDirectory: true),
                    output: temporary, cancellation: cancellation) { [weak self] event in
                        await self?.receive(event, ticket: ticket)
                    }
                try Task.checkCancellation()
                guard let self, self.generation == ticket else { return }
                let finalMetadata = self.manifest ?? metadata
                let saved = try await writer.commitModel(from: completed, manifest: finalMetadata)
                guard self.generation == ticket else { return }
                self.manifest = saved
                self.modelURL = root.appendingPathComponent("object.usdz")
                self.state = .modelReady; self.progress = 1
                self.manifestURL = root.appendingPathComponent("manifest.json")
                self.savedRevision += 1
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                metadata.modelStatus = cancelled ? "cancelled" : "failed"
                metadata.warnings.append(cancelled
                    ? "Model reconstruction was cancelled; original images are retained."
                    : "Native model reconstruction failed: \(error.localizedDescription)")
                try? await writer.save(metadata)
                guard let self, self.generation == ticket else { return }
                self.manifest = metadata; self.state = .datasetReady
                self.errorMessage = cancelled ? nil : error.localizedDescription
                self.warningMessage = cancelled ? "Обработка остановлена. Исходные снимки сохранены; можно повторить." : nil
                self.savedRevision += 1
            }
            guard let self, self.generation == ticket else { return }
            self.reconstructionCancellation = nil; self.reconstructionTask = nil
        }
    }
    func cancelReconstruction() {
        reconstructionCancellation?.cancel()
        reconstructionTask?.cancel()
    }

    static func recoverIncompleteCapture(at directory: URL) async throws -> URL {
        let writer = ObjectCaptureDatasetWriter(root: directory, managedRoot: directory
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent())
        return try await writer.recoverDataset()
    }

    private func receive(_ event: ObjectPhotogrammetryEvent, ticket: UUID) {
        guard generation == ticket, state == .reconstructing else { return }
        switch event {
        case .progress(let value): progress = min(1, max(0, value))
        case .stage(let title): processingStage = title
        case .warning(let warning):
            warningMessage = warning
            if var metadata = manifest, !metadata.warnings.contains(warning), metadata.warnings.count < 64 {
                metadata.warnings.append(warning); manifest = metadata
            }
        }
    }

    private func observe(_ capture: ObjectCaptureSession, ticket: UUID) {
        observations = [
            Task { [weak self] in
                for await value in capture.stateUpdates {
                    guard !Task.isCancelled, let self, self.generation == ticket else { return }
                    self.captureStateChanged(value, ticket: ticket)
                }
            },
            Task { [weak self] in
                for await value in capture.numberOfShotsTakenUpdates {
                    guard !Task.isCancelled, let self, self.generation == ticket else { return }
                    self.shotCount = value
                    self.checkpointIfNeeded()
                }
            },
            Task { [weak self] in
                for await value in capture.feedbackUpdates {
                    guard !Task.isCancelled, let self, self.generation == ticket else { return }
                    self.feedback = value.map(Self.feedbackText).sorted()
                }
            },
            Task { [weak self] in
                for await value in capture.userCompletedScanPassUpdates {
                    guard !Task.isCancelled, let self, self.generation == ticket else { return }
                    self.passCompleted = value
                }
            },
            Task { [weak self] in
                for await value in capture.isPausedUpdates {
                    guard !Task.isCancelled, let self, self.generation == ticket else { return }
                    self.isPaused = value
                }
            },
            Task { [weak self] in
                for await value in capture.canRequestImageCaptureUpdates {
                    guard !Task.isCancelled, let self, self.generation == ticket else { return }
                    self.canRequestShot = value
                }
            },
            Task { [weak self] in
                // Tracking has no Sendable SDK conformance. Read it and turn
                // it into UI text entirely on this actor; only sleep crosses
                // an async boundary. No unchecked SDK conformance is added.
                while !Task.isCancelled {
                    guard let self, self.generation == ticket else { return }
                    self.trackingMessage = Self.trackingText(capture.cameraTracking)
                    do { try await Task.sleep(for: .milliseconds(250)) }
                    catch { return }
                }
            }
        ]
    }
    private func stopObserving() { observations.forEach { $0.cancel() }; observations.removeAll() }

    private func checkpointIfNeeded() {
        guard [.ready, .detecting, .capturing].contains(state), let writer, let metadata = manifest,
              Date().timeIntervalSince(lastCheckpointAt) >= 5 else { return }
        lastCheckpointAt = Date()
        let previous = pendingCheckpoint
        let ticket = generation
        pendingCheckpoint = Task { [weak self] in
            if let previous { await previous.value }
            do { try await writer.save(metadata) }
            catch {
                guard let self, self.generation == ticket else { return }
                self.warningMessage = "Не удалось обновить паспорт съёмки: \(error.localizedDescription)"
            }
        }
    }

    private func captureStateChanged(_ value: ObjectCaptureSession.CaptureState, ticket: UUID) {
        switch value {
        case .initializing: state = .preparing
        case .ready: state = .ready
        case .detecting: state = .detecting
        case .capturing: state = .capturing
        case .finishing: state = .finishing
        case .completed: saveDataset(ticket: ticket, failure: nil)
        case .failed(let error): saveDataset(ticket: ticket, failure: error.localizedDescription)
        @unknown default:
            errorMessage = "Система вернула неизвестное состояние съёмки. Сохраните снимки и повторите."
        }
    }
    private func saveDataset(ticket: UUID, failure: String?) {
        guard finishTask == nil, state != .datasetReady && state != .modelReady else { return }
        guard let writer, var metadata = manifest, let root = captureRoot else {
            state = .failed; errorMessage = failure; return
        }
        state = .finishing; stopObserving(); session = nil
        metadata.endedAt = Date()
        metadata.modelStatus = Self.canReconstruct ? "captured" : "unsupported"
        if let failure { metadata.warnings.append("Capture stopped: \(failure)") }
        let checkpoint = pendingCheckpoint
        finishTask = Task { [weak self] in
            if let checkpoint { await checkpoint.value }
            do {
                let saved = try await writer.completeDataset(metadata)
                guard let self, self.generation == ticket else { return }
                self.manifest = saved; self.state = .datasetReady
                self.manifestURL = root.appendingPathComponent("manifest.json")
                self.errorMessage = failure
                self.savedRevision += 1
            } catch {
                metadata.status = "failed"
                metadata.warnings.append("Dataset metadata could not be finalized: \(error.localizedDescription)")
                try? await writer.save(metadata)
                guard let self, self.generation == ticket else { return }
                self.manifest = metadata; self.state = .failed; self.errorMessage = error.localizedDescription
            }
            self?.finishTask = nil
        }
    }
    private static func feedbackText(_ value: ObjectCaptureSession.Feedback) -> String {
        if #available(iOS 17.4, *), value == .objectNotDetected {
            return "Объект не распознан. Покажите его целиком и добавьте света."
        }
        return switch value {
        case .objectTooClose: "Отойдите чуть дальше"
        case .objectTooFar: "Подойдите ближе к объекту"
        case .movingTooFast: "Двигайтесь медленнее"
        case .environmentLowLight: "Добавьте света: кадры могут получиться смазанными"
        case .environmentTooDark: "Слишком темно для съёмки"
        case .outOfFieldOfView: "Держите весь объект в кадре"
        case .objectNotFlippable: "Оставьте объект неподвижным, измените высоту камеры"
        case .overCapturing: "Этот ракурс уже снят; перейдите к другой стороне"
        default: "Следуйте подсказкам камеры"
        }
    }
    private static func isTerminal(_ value: ObjectCaptureSession.CaptureState) -> Bool {
        switch value { case .completed, .failed: true; default: false }
    }
    private static func trackingText(_ value: ObjectCaptureSession.Tracking) -> String {
        switch value {
        case .normal: "Положение камеры отслеживается"
        case .notAvailable: "Ожидаем отслеживание камеры"
        case .limited(let reason):
            switch reason {
            case .initializing: "Камера определяет положение"
            case .relocalizing: "Вернитесь к уже снятой стороне объекта"
            case .excessiveMotion: "Остановите резкое движение камеры"
            case .insufficientFeatures: "Покажите фактурную поверхность при хорошем свете"
            @unknown default: "Отслеживание ограничено"
            }
        @unknown default: "Проверяем отслеживание камеры"
        }
    }
}

private enum ObjectPhotogrammetryEvent: Sendable {
    case progress(Double), stage(String), warning(String)
}

/// RealityKit's legacy session has no Sendable declaration. Its lifecycle and
/// output iterator stay in one nonisolated async operation. The sole cross-task
/// operation is its cancellation API, protected together with installation by a
/// lock; no SDK output or model entity is sent to the UI actor.
private final class ObjectPhotogrammetryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var session: PhotogrammetrySession?
    private var cancelled = false
    func install(_ session: PhotogrammetrySession) {
        lock.lock(); defer { lock.unlock() }
        self.session = session
        if cancelled { session.cancel() }
    }
    func clear() { lock.lock(); session = nil; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; session?.cancel(); lock.unlock() }
}

private enum ObjectPhotogrammetryWorker {
    nonisolated static func reconstruct(images: URL, checkpoints: URL, output: URL,
        cancellation: ObjectPhotogrammetryCancellation,
        update: @escaping @Sendable (ObjectPhotogrammetryEvent) async -> Void) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard PhotogrammetrySession.isSupported else { throw ObjectCaptureStorageError.invalidModel }
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = checkpoints
            configuration.sampleOrdering = .sequential
            let session = try PhotogrammetrySession(input: images, configuration: configuration)
            cancellation.install(session)
            defer { cancellation.clear() }
            try Task.checkCancellation()
            try session.process(requests: [.modelFile(url: output, detail: .reduced)])
            if Task.isCancelled { session.cancel() }
            var receivedModel: URL?
            for try await event in session.outputs {
                try Task.checkCancellation()
                switch event {
                case .requestProgress(_, let fraction): await update(.progress(fraction))
                case .requestProgressInfo(_, let info):
                    if let stage = info.processingStage { await update(.stage(stageText(stage))) }
                case .requestComplete(_, let result):
                    if case .modelFile(let actual) = result {
                        guard actual.standardizedFileURL.resolvingSymlinksInPath().path ==
                              output.standardizedFileURL.resolvingSymlinksInPath().path else {
                            throw ObjectCaptureStorageError.invalidModel
                        }
                        receivedModel = actual
                    }
                case .processingComplete:
                    guard let receivedModel else { throw ObjectCaptureStorageError.invalidModel }
                    return receivedModel
                case .processingCancelled: throw CancellationError()
                case .requestError(_, let error): throw error
                case .invalidSample(let id, _): await update(.warning("Снимок №\(id) не подходит для реконструкции; оригинал сохранён."))
                case .skippedSample(let id): await update(.warning("Обработка пропустила снимок №\(id); оригинал сохранён."))
                case .automaticDownsampling: await update(.warning("Система уменьшила рабочее разрешение; оригиналы сохранены."))
                case .stitchingIncomplete: await update(.warning("Часть ракурсов не удалось совместить. Проверьте модель перед измерениями."))
                case .inputComplete: break
                @unknown default: break
                }
            }
            throw ObjectCaptureStorageError.invalidModel
        } onCancel: { cancellation.cancel() }
    }
    private nonisolated static func stageText(_ value: PhotogrammetrySession.Output.ProcessingStage) -> String {
        switch value {
        case .preProcessing: "Подготовка снимков"
        case .imageAlignment: "Совмещение ракурсов"
        case .pointCloudGeneration: "Восстановление точек"
        case .meshGeneration: "Построение поверхности"
        case .textureMapping: "Наложение текстур"
        case .optimization: "Оптимизация модели"
        @unknown default: "Обработка снимков"
        }
    }
}
