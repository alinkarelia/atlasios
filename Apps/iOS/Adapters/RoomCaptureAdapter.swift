import Foundation
import SwiftUI
import Combine
import UIKit
@preconcurrency import RoomPlan
@preconcurrency import ARKit
import AtlasCore
import simd

/// RoomPlan delegate payloads are encoded on the callback's queue before Data
/// crosses to the main actor. CapturedRoom is never sent between executors.
@MainActor
final class RoomCaptureAdapter: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    enum State: Equatable { case ready, preparing, recording, processing, captured, exporting, saved, unavailable }

    @Published private(set) var state: State = .ready
    @Published private(set) var instruction = "Обойдите помещение, показывая стены и проёмы"
    @Published private(set) var wallCount = 0
    @Published private(set) var openingCount = 0
    @Published private(set) var isCameraReady = false
    @Published private(set) var cameraStatus = "Камера откроется при начале обмера"
    @Published private(set) var cameraFrameCount = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var captureDirectory: URL?
    @Published private(set) var frameID = UUID()
    @Published private(set) var hasCheckpoint = false
    @Published private(set) var planNotice: String?
    var currentGeoTag: GeoTag? { manifest?.geoTag }

    private var cameraView: RoomCaptureView?
    var captureView: RoomCaptureView {
        if let cameraView { return cameraView }
        let view = RoomCaptureView(frame: .zero)
        view.delegate = self
        view.captureSession.delegate = self
        cameraView = view
        return view
    }
    static var isSupported: Bool { RoomCaptureSession.isSupported }
    private var capturedRoom: CapturedRoom?
    private var roomJSON: Data?
    private var manifest: RoomManifest?
    private var writer: RoomCheckpointWriter?
    private var pendingWrite: Task<Void, Never>?
    private var lastCheckpointTime = Date.distantPast
    private var lastHealthCheck = Date.distantPast
    private var observers = Set<AnyCancellable>()
    private var startGeneration = UUID()
    private var latestLocationFix: GeoLocationFix?
    private var cameraWatchdog: Task<Void, Never>?
    private var lastFrameTimestamp: TimeInterval?
    private var lastFrameAt: TimeInterval?
    private let updateGate = RoomUpdateGate()
    private var isPreviewing = false
    private var isPreparingPreview = false

    // RoomCaptureViewDelegate inherits NSCoding. This delegate owns a live
    // camera session; recovery uses committed room files, never an archived
    // adapter that could restore hardware activity or transient actor state.
    nonisolated required init?(coder: NSCoder) { return nil }
    nonisolated func encode(with coder: NSCoder) {}

    override init() {
        super.init()
        if !Self.isSupported {
            state = .unavailable
            cameraStatus = "RoomPlan нужен совместимый iPhone или iPad с LiDAR"
        }
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop(reason: "Съёмка прервана. Полученный черновик будет сохранён.") }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendForDismissal() }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop(reason: "Мало памяти. Завершаем текущую комнату.") }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                        self?.stop(reason: "Устройство нагрелось. Завершаем текущую комнату.")
                    }
                }
            }.store(in: &observers)
    }

    /// Preview runs the shared AR camera only. RoomPlan semantic capture and
    /// durable files start exclusively when the operator presses Start.
    func preparePreview() async {
        guard Self.isSupported, state == .ready || state == .saved,
              !isPreviewing, !isPreparingPreview, !Task.isCancelled else { return }
        let ticket = UUID(); startGeneration = ticket
        isPreparingPreview = true
        cameraStatus = "Открываем камеру…"
        errorMessage = nil
        defer { if startGeneration == ticket { isPreparingPreview = false } }
        do {
            try await CaptureCoordinator.requireCameraAccess()
            guard ticket == startGeneration, !Task.isCancelled else { return }
            let view = captureView
            try await CaptureCoordinator.waitForCameraPresentation(view)
            guard ticket == startGeneration, !Task.isCancelled else { return }
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.environmentTexturing = .none
            configuration.planeDetection = [.horizontal, .vertical]
            resetCameraReadiness()
            isPreviewing = true
            view.captureSession.arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            beginCameraWatchdog()
        } catch {
            guard ticket == startGeneration else { return }
            errorMessage = error.localizedDescription
            cameraStatus = error.localizedDescription
        }
    }

    func suspendPreview() {
        guard isPreviewing || isPreparingPreview else { return }
        startGeneration = UUID()
        isPreviewing = false; isPreparingPreview = false
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        cameraView?.captureSession.arSession.pause()
        isCameraReady = false
        cameraStatus = "Камера остановлена"
    }

    /// This scan has its own local origin. Reusing a project's UUID would not
    /// establish physical registration, even when both coordinate units are m.
    func start(projectID: UUID, projectName: String, outputDirectory: URL) async {
        guard state == .ready || state == .saved else { return }
        guard !Task.isCancelled else { return }
        guard Self.isSupported else { state = .unavailable; return }
        suspendPreview()
        let generation = UUID()
        startGeneration = generation
        updateGate.reset(generation)
        state = .preparing
        cameraStatus = "Открываем камеру…"
        errorMessage = nil
        do {
            try await CaptureCoordinator.requireCameraAccess()
            guard startGeneration == generation else { return }
            guard !Task.isCancelled else { state = .ready; return }
            let view = captureView
            try await CaptureCoordinator.waitForCameraPresentation(view)
            guard startGeneration == generation, !Task.isCancelled else { return }
            _ = try CaptureCoordinator.preflight(at: outputDirectory)
            let id = UUID()
            let directory = outputDirectory.appendingPathComponent("room-\(id.uuidString)", isDirectory: true)
            let newFrame = UUID()
            let metadata = RoomManifest(id: id, projectID: projectID, projectName: projectName, frameID: newFrame,
                createdAt: Date(), status: "recording", completedAssets: [], geoTag: freshAutomaticTag(),
                notes: ["Local RoomPlan/ARKit coordinate frame; metres; Y up.",
                        "Atlas plan maps AR X,Z onto its X,Y. Device GeoTag marks operator position only, not AR/GPS or cross-scan registration.",
                        "Curved walls stay in the RoomPlan source; a straight PlanWall does not approximate them."])
            let newWriter = RoomCheckpointWriter(root: directory)
            try await newWriter.create(metadata)
            guard !Task.isCancelled, startGeneration == generation else {
                try? FileManager.default.removeItem(at: directory)
                if startGeneration == generation { state = .ready }
                return
            }
            writer = newWriter; manifest = metadata; captureDirectory = directory; frameID = newFrame
            capturedRoom = nil; roomJSON = nil; wallCount = 0; openingCount = 0
            hasCheckpoint = false; planNotice = nil; pendingWrite = nil
            lastCheckpointTime = .distantPast; lastHealthCheck = .distantPast
            isPreviewing = false; isPreparingPreview = false
            resetCameraReadiness()
            // The preview's AR origin is not a saved room's coordinate frame.
            // Reset the shared camera before enabling RoomPlan semantic capture.
            let resetConfiguration = ARWorldTrackingConfiguration()
            resetConfiguration.worldAlignment = .gravity
            view.captureSession.arSession.run(resetConfiguration, options: [.resetTracking, .removeExistingAnchors])
            state = .recording
            view.captureSession.run(configuration: RoomCaptureSession.Configuration())
            beginCameraWatchdog()
            updateAutomaticLocation(latestLocationFix)
            instruction = "Медленно обойдите комнату, включая двери и окна"
        } catch {
            guard startGeneration == generation else { return }
            errorMessage = error.localizedDescription; state = .ready
            cameraStatus = error.localizedDescription
        }
    }

    /// Location is frozen when the room stops recording. Processing callbacks
    /// and recovery never replace it with the operator's later position.
    func updateAutomaticLocation(_ fix: GeoLocationFix?) {
        latestLocationFix = fix
        guard state == .recording, let fix, var current = manifest, let writer,
              let chosen = GeoTagPolicy.bestAutomatic(current: current.geoTag?.automaticFix,
                  candidate: fix, now: Date()) else { return }
        guard chosen != current.geoTag?.automaticFix else { return }
        current.geoTag = GeoTag(automaticFix: chosen)
        manifest = current
        let previous = pendingWrite
        let ticket = startGeneration
        pendingWrite = Task { [weak self] in
            if let previous { await previous.value }
            do { try await writer.saveManifest(current) }
            catch {
                guard let self, self.startGeneration == ticket else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func freshAutomaticTag() -> GeoTag? {
        guard let fix = latestLocationFix, GeoTagPolicy.acceptDeviceFix(fix, now: Date()) else { return nil }
        return GeoTag(automaticFix: fix)
    }

    /// RoomPlan stops and processes this room; it does not offer a misleading
    /// pause/resume across tracking resets. Another room starts a separate scan.
    func stop(reason: String? = nil) {
        guard state == .recording else { return }
        updateAutomaticLocation(latestLocationFix)
        state = .processing
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        isCameraReady = false
        cameraStatus = "Обрабатываем помещение"
        instruction = reason ?? "Строим редактируемый черновик помещения"
        cameraView?.captureSession.stop(pauseARSession: true)
    }

    func suspendForDismissal() {
        cancelPendingStart()
        stop(reason: "Сохраняем полученную комнату")
        suspendPreview()
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        cameraView?.captureSession.arSession.pause()
        isCameraReady = false
    }

    func cancelPendingStart() {
        guard state == .preparing else { return }
        startGeneration = UUID()
        updateGate.reset(startGeneration)
        state = .ready; instruction = "Подготовка отменена"
    }

    /// Restores a committed semantic checkpoint after a crash. The resulting
    /// draft is explicitly marked as recovered and still needs human review.
    static func recoverIncompleteCapture(at directory: URL) async throws -> URL {
        try await RoomCheckpointWriter(root: directory).recoverCheckpoint()
    }

    func export() async throws -> URL {
        guard state != .exporting else { throw CaptureError.operationInProgress }
        guard let data = roomJSON, let writer, var metadata = manifest, let directory = captureDirectory else {
            throw RoomCaptureError.noRoom
        }
        let previousState = state
        state = .exporting
        if let pendingWrite { await pendingWrite.value }
        metadata.status = "exporting"
        do {
            metadata = try await writer.export(roomJSON: data, metadata: metadata)
            manifest = metadata
            state = .saved
            instruction = "План и модель сохранены на устройстве"
            return directory.appendingPathComponent("manifest.json")
        } catch { state = previousState; errorMessage = error.localizedDescription; throw error }
    }

    func structuralSnapshot(keepStorage: Bool) throws -> EmptyRoomDocument {
        guard let room = capturedRoom, let source = roomJSON, let metadata = manifest else { throw RoomCaptureError.noRoom }
        return try EmptyRoomNativeDocument.make(room: room, source: source, captureID: metadata.id,
            projectID: metadata.projectID, frameID: metadata.frameID, capturedAt: metadata.createdAt, keepStorage: keepStorage)
    }

    /// A derivative of the same capture, never a replacement for its observed
    /// room.json / room-data.json and never an independently registered frame.
    func exportStructuralRoom(keepStorage: Bool) async throws -> EmptyRoomExport {
        guard state != .exporting else { throw CaptureError.operationInProgress }
        if state != .saved { _ = try await export() }
        guard let source = roomJSON, let writer, let metadata = manifest else { throw RoomCaptureError.noRoom }
        let previous = state; state = .exporting
        do {
            let (updated, result) = try await writer.exportStructuralRoom(source: source, metadata: metadata, keepStorage: keepStorage)
            manifest = updated; state = .saved
            instruction = "Чистая структурная модель сохранена. Проверьте черновик перед проектированием."
            return result
        } catch { state = previous; errorMessage = error.localizedDescription; throw error }
    }

    func saveStructuralPresentation(_ result: EmptyRoomExport, png: Data, pdf: Data) async throws -> URL {
        guard state == .saved, let writer, let metadata = manifest,
              result.document.captureID == metadata.id else { throw RoomCaptureError.noRoom }
        state = .exporting
        do {
            let updated = try await writer.savePresentation(result: result, metadata: metadata, png: png, pdf: pdf)
            manifest = updated; state = .saved
            return result.manifestURL
        } catch { state = .saved; errorMessage = error.localizedDescription; throw error }
    }

    func savedStructuralRoom(keepStorage: Bool) async throws -> EmptyRoomExport? {
        guard state == .saved, let source = roomJSON, let writer, let metadata = manifest else { return nil }
        return try await writer.savedStructuralRoom(source: source, metadata: metadata, keepStorage: keepStorage)
    }

    /// Registers a legacy derivative's review journal before the UI can append
    /// an operator decision. Existing malformed journals are retained for review.
    func ensureStructuralReview(_ result: EmptyRoomExport) async throws -> URL {
        guard state == .saved, let writer, let metadata = manifest,
              result.document.captureID == metadata.id else { throw RoomCaptureError.noRoom }
        state = .exporting
        do {
            manifest = try await writer.ensureStructuralReview(result: result, metadata: metadata)
            state = .saved
            return result.manifestURL
        } catch { state = .saved; errorMessage = error.localizedDescription; throw error }
    }

    /// Explicitly reopens a durable RoomPlan source; no camera session starts.
    func loadSavedRoom(at directory: URL, projectID: UUID) async throws {
        guard state != .recording, state != .processing, state != .exporting, state != .preparing else { throw CaptureError.operationInProgress }
        suspendPreview()
        let previous = state; state = .exporting
        let reader = RoomCheckpointWriter(root: directory)
        do {
            let (metadata, source) = try await reader.savedSource(projectID: projectID)
            let decoded = try JSONDecoder().decode(CapturedRoom.self, from: source)
            writer = reader; manifest = metadata; roomJSON = source; capturedRoom = decoded
            captureDirectory = directory; frameID = metadata.frameID; hasCheckpoint = true
            wallCount = decoded.walls.count; openingCount = decoded.windows.count + decoded.doors.count + decoded.openings.count
            state = metadata.status == "ready" ? .saved : .captured
            errorMessage = nil; instruction = "Открыт исходный обмер. Его файлы не изменяются при очистке."
        } catch { state = previous; errorMessage = error.localizedDescription; throw error }
    }

    static func savedRooms(in directory: URL, projectID: UUID) async throws -> SavedEmptyRoomListing {
        try await RoomCheckpointWriter(root: directory).savedRooms(projectID: projectID)
    }

    /// Exports a draft into its true room-local frame. The caller must register
    /// it before mixing it with a project's existing geometry or WGS84 data.
    func asFloorPlan(projectID: UUID, frameID: UUID) -> AtlasFloorPlan? {
        guard let room = capturedRoom, frameID == self.frameID else { return nil }
        let walls = room.walls.compactMap { wall -> PlanWall? in
            guard wall.curve == nil, wall.dimensions.x > 0 else { return nil }
            let start = wall.transform * SIMD4<Float>(-wall.dimensions.x / 2, 0, 0, 1)
            let end = wall.transform * SIMD4<Float>(wall.dimensions.x / 2, 0, 0, 1)
            let vertical = wall.transform.columns.1
            let hasGravityHeight = abs(vertical.x) < 0.001 && abs(vertical.z) < 0.001 && abs(abs(vertical.y) - 1) < 0.001
            return PlanWall(id: wall.identifier,
                start: MetricPoint2D(x: Double(start.x), y: Double(start.z)),
                end: MetricPoint2D(x: Double(end.x), y: Double(end.z)),
                heightMeters: wall.dimensions.y > 0 && hasGravityHeight ? Double(wall.dimensions.y) : nil,
                thicknessMeters: wall.dimensions.z > 0.001 ? Double(wall.dimensions.z) : nil)
        }
        let rooms = room.floors.enumerated().compactMap { index, floor -> PlanRoom? in
            let points = floor.polygonCorners.map { corner -> MetricPoint2D in
                let world = floor.transform * SIMD4<Float>(corner.x, corner.y, corner.z, 1)
                return MetricPoint2D(x: Double(world.x), y: Double(world.z))
            }
            var vertices = points
            if vertices.count > 1, vertices.first == vertices.last { vertices.removeLast() }
            guard vertices.count >= 3 else { return nil }
            return PlanRoom(id: floor.identifier, name: "Помещение \(index + 1)",
                            boundary: MetricPolygon(frameID: frameID, vertices: vertices))
        }
        guard !walls.isEmpty || !rooms.isEmpty else { return nil }
        return AtlasFloorPlan(projectID: projectID, frameID: frameID, name: "Обмер RoomPlan",
                              floorIndex: room.story, rooms: rooms, walls: walls)
    }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        let failure = error?.localizedDescription
        let data = try? JSONEncoder().encode(roomDataForProcessing)
        let ticket = updateGate.ticket()
        Task { @MainActor [weak self] in
            guard let self, self.startGeneration == ticket else { return }
            if let data { self.persistRawRoomData(data) }
            if let failure { self.errorMessage = failure }
        }
        // Partial raw data stays available even when post-processing fails.
        return failure == nil
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        let failure = error?.localizedDescription
        let data = try? JSONEncoder().encode(processedResult)
        let ticket = updateGate.ticket()
        Task { @MainActor [weak self] in
            guard let self, self.startGeneration == ticket else { return }
            if let failure { self.errorMessage = failure }
            if let data { self.receiveRoom(data, processed: true) }
            else { self.processingFailed(failure ?? "Не удалось сохранить результат RoomPlan") }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) { sendUpdate(room) }
    nonisolated func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) { sendUpdate(room) }
    nonisolated func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) { sendUpdate(room) }
    nonisolated func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom) { sendUpdate(room) }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        let raw = try? JSONEncoder().encode(data)
        let failure = error?.localizedDescription
        let ticket = updateGate.ticket()
        Task { @MainActor [weak self] in
            guard let self, self.startGeneration == ticket else { return }
            if let raw { self.persistRawRoomData(raw) }
            if let failure { self.processingFailed(failure) }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text: String
        switch instruction {
        case .normal: text = "Обойдите все стены и проёмы"
        case .moveCloseToWall: text = "Подойдите ближе к стене"
        case .moveAwayFromWall: text = "Отойдите немного от стены"
        case .slowDown: text = "Двигайте телефон медленнее"
        case .turnOnLight: text = "Добавьте освещения"
        case .lowTexture: text = "Покажите фактурные поверхности и углы"
        @unknown default: text = "Продолжайте плавно осматривать помещение"
        }
        Task { @MainActor [weak self] in
            if self?.state == .recording { self?.instruction = text }
        }
    }

    private nonisolated func sendUpdate(_ room: CapturedRoom) {
        // Throttle before Codable work, rather than after expensive encoding
        // and decoding on every semantic update from RoomPlan.
        guard let ticket = updateGate.acceptUpdate(),
              let data = try? JSONEncoder().encode(room) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.startGeneration == ticket else { return }
            self.receiveRoom(data, processed: false)
        }
    }

    private func resetCameraReadiness() {
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        lastFrameTimestamp = nil; lastFrameAt = nil
        isCameraReady = false; cameraFrameCount = 0
        cameraStatus = "Ожидаем изображение с камеры…"
    }

    private func beginCameraWatchdog() {
        cameraWatchdog?.cancel()
        let ticket = startGeneration
        let startedAt = ProcessInfo.processInfo.systemUptime
        cameraWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.startGeneration == ticket,
                      self.state == .recording || self.isPreviewing else { return }
                guard UIApplication.shared.applicationState == .active else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                if let frame = self.cameraView?.captureSession.arSession.currentFrame,
                   now - frame.timestamp < 1.5, frame.timestamp != self.lastFrameTimestamp {
                    self.lastFrameTimestamp = frame.timestamp
                    self.lastFrameAt = now
                    // Number of sampled fresh frames, not the camera's FPS.
                    self.cameraFrameCount += 1
                    if !self.isCameraReady {
                        self.isCameraReady = true
                        self.cameraStatus = "Камера работает"
                    }
                }
                let stalled = self.lastFrameAt.map { now - $0 > 5 } ?? (now - startedAt > 8)
                guard stalled else { continue }
                let message = CaptureError.cameraNoFrames.localizedDescription
                self.errorMessage = message
                if self.state == .recording {
                    self.stop(reason: message)
                    // Raw/semantic checkpoints survive even when camera startup
                    // fails. Never leave the operator stuck on a black recording.
                    self.processingFailed(message)
                } else { self.suspendPreview() }
                self.cameraStatus = message
                return
            }
        }
    }

    private func receiveRoom(_ data: Data, processed: Bool) {
        guard processed || state == .recording || state == .processing else { return }
        guard let room = try? JSONDecoder().decode(CapturedRoom.self, from: data) else { return }
        capturedRoom = room; roomJSON = data
        let newWallCount = room.walls.count
        let newOpeningCount = room.doors.count + room.windows.count + room.openings.count
        if wallCount != newWallCount { wallCount = newWallCount }
        if openingCount != newOpeningCount { openingCount = newOpeningCount }
        if room.walls.contains(where: { $0.curve != nil }) {
            planNotice = "Криволинейные стены сохранены в 3D и исходном JSON. Редактор прямых стен их не заменяет."
        }
        if processed {
            cameraWatchdog?.cancel(); cameraWatchdog = nil
            isCameraReady = false
            state = .captured; instruction = "Проверьте результат и сохраните"
        }
        guard let writer else { return }
        let now = Date()
        if now.timeIntervalSince(lastHealthCheck) > 8, state == .recording, let directory = captureDirectory {
            lastHealthCheck = now
            do { _ = try CaptureCoordinator.preflight(at: directory) }
            catch { stop(reason: error.localizedDescription) }
        }
        guard processed || now.timeIntervalSince(lastCheckpointTime) > 0.75 else { return }
        lastCheckpointTime = now
        let previous = pendingWrite
        let ticket = startGeneration
        pendingWrite = Task { [weak self] in
            if let previous { await previous.value }
            do {
                try await writer.checkpoint(data)
                if self?.startGeneration == ticket { self?.hasCheckpoint = true }
            } catch {
                guard let self, self.startGeneration == ticket else { return }
                self.errorMessage = error.localizedDescription
                self.stop(reason: "Ошибка записи. Завершаем комнату.")
            }
        }
    }

    private func persistRawRoomData(_ data: Data) {
        guard let writer else { return }
        let previous = pendingWrite
        let ticket = startGeneration
        pendingWrite = Task { [weak self] in
            if let previous { await previous.value }
            do { try await writer.persistRaw(data) }
            catch {
                guard let self, self.startGeneration == ticket else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func processingFailed(_ message: String) {
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        cameraView?.captureSession.arSession.pause()
        isCameraReady = false
        errorMessage = "RoomPlan: \(message). Полученные данные остаются на устройстве."
        state = roomJSON == nil ? .ready : .captured
        instruction = "Доступный черновик требует ручной проверки"
    }
}

enum RoomCaptureError: LocalizedError {
    case noRoom
    var errorDescription: String? { "RoomPlan ещё не получил помещение для экспорта." }
}

private struct RoomManifest: Codable, Sendable {
    var schemaVersion = 1
    var source = "RoomPlan"
    var id: UUID
    var projectID: UUID
    var projectName: String
    var frameID: UUID
    var createdAt: Date
    var status: String
    var completedAssets: [String]
    var geoTag: GeoTag?
    var notes: [String]
}

private actor RoomCheckpointWriter {
    let root: URL
    init(root: URL) { self.root = root }

    func create(_ manifest: RoomManifest) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try saveManifest(manifest)
    }
    func checkpoint(_ data: Data) throws {
        try data.write(to: root.appendingPathComponent("room.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func persistRaw(_ data: Data) throws {
        try data.write(to: root.appendingPathComponent("room-data.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func export(roomJSON: Data, metadata: RoomManifest) throws -> RoomManifest {
        try checkpoint(roomJSON)
        try saveManifest(metadata)
        let room = try JSONDecoder().decode(CapturedRoom.self, from: roomJSON)
        let temporary = root.appendingPathComponent("room-export-\(UUID().uuidString).usdz")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try room.export(to: temporary, exportOptions: .parametric)
        let destination = root.appendingPathComponent("room.usdz")
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        var finished = metadata; finished.status = "ready"
        finished.completedAssets = ["room.json", "room.usdz"]
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("room-data.json").path) {
            finished.completedAssets.append("room-data.json")
        }
        finished.completedAssets += metadata.completedAssets.filter {
            $0.hasPrefix("empty-room/") && FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        try saveManifest(finished)
        return finished
    }

    func savedSource(projectID: UUID) throws -> (RoomManifest, Data) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RoomManifest.self, from: boundedManifest(root.appendingPathComponent("manifest.json")))
        guard metadata.schemaVersion == 1, metadata.source == "RoomPlan" else { throw EmptyRoomError.unsupportedSchema }
        guard metadata.projectID == projectID else { throw EmptyRoomError.wrongProject }
        let sourceURL = root.appendingPathComponent("room.json")
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else { throw EmptyRoomError.noSource }
        guard size <= 32 * 1024 * 1024 else { throw EmptyRoomError.sourceLimit }
        return (metadata, try Data(contentsOf: sourceURL))
    }

    func savedRooms(projectID: UUID) throws -> SavedEmptyRoomListing {
        guard FileManager.default.fileExists(atPath: root.path) else { return .init(rooms: [], issues: []) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var result: [SavedEmptyRoomSource] = []
        var issues: [String] = []
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
        for directory in directories where directory.lastPathComponent.hasPrefix("room-") {
            do {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let metadata = try decoder.decode(RoomManifest.self, from: boundedManifest(directory.appendingPathComponent("manifest.json")))
            guard metadata.source == "RoomPlan", metadata.projectID == projectID else { continue }
            guard metadata.schemaVersion == 1 else { throw EmptyRoomError.unsupportedSchema }
            guard directory.lastPathComponent == "room-\(metadata.id.uuidString)",
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent("room.json").path) else { throw EmptyRoomError.noSource }
            result.append(.init(id: metadata.id, directory: directory, createdAt: metadata.createdAt, name: metadata.projectName))
            } catch { issues.append("\(directory.lastPathComponent): \(error.localizedDescription)") }
        }
        return .init(rooms: result.sorted { $0.createdAt > $1.createdAt }, issues: issues)
    }

    private func boundedManifest(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1024 * 1024 else { throw EmptyRoomError.unsupportedSchema }
        return try Data(contentsOf: url)
    }

    func exportStructuralRoom(source: Data, metadata: RoomManifest, keepStorage: Bool) throws -> (RoomManifest, EmptyRoomExport) {
        let original = try JSONDecoder().decode(CapturedRoom.self, from: source)
        var document = try EmptyRoomNativeDocument.make(room: original, source: source, captureID: metadata.id,
            projectID: metadata.projectID, frameID: metadata.frameID, capturedAt: metadata.createdAt, keepStorage: keepStorage)
        let retainedIDs = Set(document.storage.map(\.id))
        let filtered = try EmptyRoomJSONFilter.filter(source, retaining: retainedIDs)
        let clean = try JSONDecoder().decode(CapturedRoom.self, from: filtered)
        guard Set(clean.objects.map(\.identifier)) == retainedIDs,
              clean.identifier == original.identifier,
              Set(clean.walls.map(\.identifier)) == Set(original.walls.map(\.identifier)),
              Set(clean.floors.map(\.identifier)) == Set(original.floors.map(\.identifier)),
              Set(clean.windows.map(\.identifier)) == Set(original.windows.map(\.identifier)),
              Set(clean.doors.map(\.identifier)) == Set(original.doors.map(\.identifier)),
              Set(clean.openings.map(\.identifier)) == Set(original.openings.map(\.identifier)) else { throw EmptyRoomError.unsupportedSchema }
        let exportID = UUID()
        let relative = "empty-room/\(exportID.uuidString)"
        let stage = root.appendingPathComponent(".empty-room-stage-\(exportID.uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try filtered.write(to: stage.appendingPathComponent("structural-room.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try clean.export(to: stage.appendingPathComponent("structural-room.usdz"), exportOptions: .mesh)
        try Task.checkCancellation()
        var hasOBJ = false
        do {
            let mesh = try OBJPreviewLoader.load(stage.appendingPathComponent("structural-room.usdz"))
            try EmptyRoomOBJWriter.write(mesh, to: stage.appendingPathComponent("structural-room.obj"), frameID: metadata.frameID)
            hasOBJ = true
        } catch is CancellationError { throw CancellationError() }
        catch {
            document.objExportIssue = "OBJ не создан: \(error.localizedDescription). Нативный USDZ сохранён без ограничения предпросмотра."
            try? FileManager.default.removeItem(at: stage.appendingPathComponent("structural-room.obj"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: stage.appendingPathComponent("dimensions.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try encoder.encode(EmptyRoomSurfaceReview(source: document)).write(to: stage.appendingPathComponent(EmptyRoomSurfaceReviewPolicy.fileName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: stage, to: destination)
        var updated = metadata; updated.status = "ready"
        var assets = ["structural-room.json", "structural-room.usdz", "dimensions.json", EmptyRoomSurfaceReviewPolicy.fileName]
        if hasOBJ { assets.append("structural-room.obj") }
        updated.completedAssets += assets.map { "\(relative)/\($0)" }
        updated.notes = Array(Set(updated.notes + ["Clean RoomPlan derivatives preserve this capture's local frame and immutable originals. Semantic draft requires independent review; ceilings are not inferred."])).sorted()
        do { try saveManifest(updated) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return (updated, .init(manifestURL: root.appendingPathComponent("manifest.json"), documentURL: destination.appendingPathComponent("dimensions.json"),
            usdzURL: destination.appendingPathComponent("structural-room.usdz"), objURL: hasOBJ ? destination.appendingPathComponent("structural-room.obj") : nil, document: document))
    }

    func savedStructuralRoom(source: Data, metadata: RoomManifest, keepStorage: Bool) throws -> EmptyRoomExport? {
        let expectedHash = FieldTransferDigest.sha256(source)
        let roomID = try JSONDecoder().decode(CapturedRoom.self, from: source).identifier
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let candidates = metadata.completedAssets.filter { $0.hasPrefix("empty-room/") && $0.hasSuffix("/dimensions.json") }
        guard candidates.count <= 2_000 else { throw EmptyRoomError.sourceLimit }
        var exports: [(EmptyRoomExport, Date)] = []
        for relative in candidates {
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "empty-room", UUID(uuidString: String(parts[1])) != nil,
                  parts[2] == "dimensions.json" else { throw EmptyRoomError.unsupportedSchema }
            let folder = root.appendingPathComponent("empty-room", isDirectory: true).appendingPathComponent(String(parts[1]), isDirectory: true)
            try validateStructuralFolder(folder)
            let documentURL = folder.appendingPathComponent("dimensions.json")
            let values = try documentURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes > 0, bytes <= 4 * 1_024 * 1_024 else { throw EmptyRoomError.unsupportedSchema }
            let document = try decoder.decode(EmptyRoomDocument.self, from: Data(contentsOf: documentURL))
            guard document.projectID == metadata.projectID, document.captureID == metadata.id,
                  document.frameID == metadata.frameID, document.sourceRoomID == roomID,
                  document.sourceRoomJSONSHA256 == expectedHash else { throw EmptyRoomError.wrongProject }
            guard document.keepStorage == keepStorage else { continue }
            try EmptyRoomSurfaceReviewPolicy.validate(EmptyRoomSurfaceReview(source: document), source: document)
            let usdz = folder.appendingPathComponent("structural-room.usdz")
            let modelValues = try usdz.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard modelValues.isRegularFile == true, modelValues.isSymbolicLink != true,
                  (modelValues.fileSize ?? 0) > 0 else { throw EmptyRoomError.noSource }
            let obj = folder.appendingPathComponent("structural-room.obj")
            let objValues = try? obj.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let objURL = objValues?.isRegularFile == true && objValues?.isSymbolicLink != true && (objValues?.fileSize ?? 0) > 0 ? obj : nil
            exports.append((.init(manifestURL: root.appendingPathComponent("manifest.json"), documentURL: documentURL,
                usdzURL: usdz, objURL: objURL, document: document), values.contentModificationDate ?? .distantPast))
        }
        return exports.sorted { ($0.1, $0.0.documentURL.path) > ($1.1, $1.0.documentURL.path) }.first?.0
    }

    func ensureStructuralReview(result: EmptyRoomExport, metadata: RoomManifest) throws -> RoomManifest {
        let folder = result.documentURL.deletingLastPathComponent()
        try validateStructuralFolder(folder)
        guard result.document.projectID == metadata.projectID, result.document.captureID == metadata.id,
              result.document.frameID == metadata.frameID else { throw EmptyRoomError.wrongProject }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var updated = try decoder.decode(RoomManifest.self, from: boundedManifest(root.appendingPathComponent("manifest.json")))
        guard updated.id == metadata.id, updated.projectID == metadata.projectID, updated.frameID == metadata.frameID else { throw EmptyRoomError.wrongProject }
        let url = folder.appendingPathComponent(EmptyRoomSurfaceReviewPolicy.fileName)
        let existed = FileManager.default.fileExists(atPath: url.path)
        if existed {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes >= 0, bytes <= EmptyRoomSurfaceReviewPolicy.maximumFileBytes else { throw EmptyRoomError.unsupportedSchema }
        } else {
            let review = EmptyRoomSurfaceReview(source: result.document)
            try EmptyRoomSurfaceReviewPolicy.validate(review, source: result.document)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(review).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let relative = "empty-room/\(folder.lastPathComponent)/\(EmptyRoomSurfaceReviewPolicy.fileName)"
        if !updated.completedAssets.contains(relative) { updated.completedAssets.append(relative) }
        do { try saveManifest(updated) }
        catch { if !existed { try? FileManager.default.removeItem(at: url) }; throw error }
        return updated
    }

    private func validateStructuralFolder(_ folder: URL) throws {
        let collection = root.appendingPathComponent("empty-room", isDirectory: true)
        guard folder.isFileURL, UUID(uuidString: folder.lastPathComponent) != nil,
              folder.deletingLastPathComponent().standardizedFileURL == collection.standardizedFileURL else { throw EmptyRoomError.invalidGeometry }
        for directory in [collection, folder] {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw EmptyRoomError.invalidGeometry }
        }
    }

    func savePresentation(result: EmptyRoomExport, metadata: RoomManifest, png: Data, pdf: Data) throws -> RoomManifest {
        let folder = result.documentURL.deletingLastPathComponent()
        let id = folder.lastPathComponent
        guard UUID(uuidString: id) != nil,
              folder.deletingLastPathComponent() == root.appendingPathComponent("empty-room", isDirectory: true),
              png.count <= 32 * 1024 * 1024, pdf.count <= 64 * 1024 * 1024,
              png.starts(with: [137, 80, 78, 71]), pdf.starts(with: Data("%PDF".utf8)) else { throw EmptyRoomError.invalidGeometry }
        try png.write(to: folder.appendingPathComponent("model.png"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try pdf.write(to: folder.appendingPathComponent("measurements.pdf"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var updated = metadata
        let paths = ["empty-room/\(id)/model.png", "empty-room/\(id)/measurements.pdf"]
        updated.completedAssets = Array(Set(updated.completedAssets + paths)).sorted()
        try saveManifest(updated)
        return updated
    }
    func recoverCheckpoint() throws -> URL {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var metadata = try decoder.decode(RoomManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let roomURL = root.appendingPathComponent("room.json")
        guard FileManager.default.fileExists(atPath: roomURL.path) else { throw RoomCaptureError.noRoom }
        if metadata.status != "ready" {
            metadata.notes.append("Recovered from the last committed semantic checkpoint; draft requires independent validation.")
        }
        _ = try export(roomJSON: Data(contentsOf: roomURL), metadata: metadata)
        return root.appendingPathComponent("manifest.json")
    }
    func saveManifest(_ metadata: RoomManifest) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: root.appendingPathComponent("manifest.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// A callback-queue throttle. Only primitive timestamps and generation tickets
/// are protected here; RoomPlan payloads never cross executors unencoded.
private final class RoomUpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var lastUpdate: TimeInterval = -.infinity

    func reset(_ generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation; lastUpdate = -.infinity
    }

    func ticket() -> UUID {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func acceptUpdate() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUpdate >= 0.5 else { return nil }
        lastUpdate = now
        return generation
    }
}
