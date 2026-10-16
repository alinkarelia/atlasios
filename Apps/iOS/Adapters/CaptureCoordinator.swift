import Foundation
import SwiftUI
import Combine
import AVFoundation
import UIKit
import Metal
import CoreVideo
import AtlasCore
@preconcurrency import ARKit
@preconcurrency import RealityKit
import simd
import Darwin

/// Coordinates a local LiDAR session. Mesh files are durable checkpoints, not a
/// promise of a watertight reconstruction, survey accuracy, or GPS registration.
@MainActor
final class CaptureCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case ready, preparing, recording, paused, interrupted, exporting, saved, unavailable
    }

    @Published private(set) var state: State = .ready
    @Published private(set) var trackingMessage = "Готов к съёмке"
    @Published private(set) var isTrackingNormal = false
    @Published private(set) var isCameraReady = false
    @Published private(set) var cameraStatus = "Камера откроется после разрешения доступа"
    @Published private(set) var cameraFrameCount = 0
    /// Real AR plane boundaries projected into the visible camera viewport.
    @Published private(set) var detectedPlaneOutlines: [[CGPoint]] = []
    @Published private(set) var overlayTriangleCount = 0
    @Published private(set) var overlayAnchorCount = 0
    @Published private(set) var surfaceDistanceMeters: Double?
    @Published private(set) var scanGuidance = "Покажите стену или предмет с расстояния 0,5–3 м"
    @Published private(set) var guidanceNeedsAttention = false
    @Published var showRecordedSurfaces = true {
        didSet { recordedSurfaceRoot?.isEnabled = showRecordedSurfaces }
    }
    @Published private(set) var anchorCount = 0
    @Published private(set) var triangleCount = 0
    @Published private(set) var observedSurfaceArea: Double = 0
    @Published private(set) var segmentCount = 0
    @Published private(set) var lastCheckpoint: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var overlayIssue: String?
    @Published private(set) var availableDiskBytes: Int64 = 0
    @Published private(set) var captureDirectory: URL?
    @Published private(set) var videoEnabled = false
    @Published private(set) var videoIsRecording = false
    @Published private(set) var videoStatus = "Видео выключено"
    @Published private(set) var videoIssue: String?
    @Published private(set) var fragmentElapsedSeconds: TimeInterval = 0
    @Published private(set) var currentFragmentID: UUID?

    // State objects can coexist, but only the visible mode allocates a camera
    // renderer. Suspending another mode must never create a second AR session.
    private var cameraView: ARView?
    var arView: ARView {
        if let cameraView { return cameraView }
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session.delegateQueue = .main
        // The debug mesh draws every diagonal and cannot communicate coverage.
        // Our own depth-tested, unlit surfaces appear only after disk commit.
        view.debugOptions = []
        view.environment.sceneUnderstanding.options.remove(.occlusion)
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        cameraView = view
        return view
    }
    var currentFrameID: UUID? { manifest?.segments.last?.frameID }
    var currentGeoTag: GeoTag? { manifest?.segments.last?.geoTag }
    struct EvidenceCameraTicket {
        let runID: UUID
        let segmentID: UUID
        let frameID: UUID
    }
    var evidenceCameraTicket: EvidenceCameraTicket? {
        guard let runID = cameraLifecycle.currentRunID, let segment = manifest?.segments.last,
              let timestamp = cameraView?.session.currentFrame?.timestamp else { return nil }
        let ticket = EvidenceCameraTicket(runID: runID, segmentID: segment.id, frameID: segment.frameID)
        return acceptsEvidenceFrame(timestamp: timestamp, ticket: ticket) ? ticket : nil
    }
    func acceptsEvidenceFrame(timestamp: TimeInterval, ticket: EvidenceCameraTicket) -> Bool {
        guard state == .recording, isCameraReady, !isPreviewing,
              UIApplication.shared.applicationState == .active, cameraView?.window != nil,
              let segment = manifest?.segments.last, segment.endedAt == nil,
              segment.id == ticket.segmentID, segment.frameID == ticket.frameID else { return false }
        return cameraLifecycle.acceptsEvidenceFrame(runID: ticket.runID, segmentID: ticket.segmentID,
            timestamp: timestamp, now: ProcessInfo.processInfo.systemUptime)
    }
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    private var manifest: LiDARCaptureManifest?
    private var writer: MeshCheckpointWriter?
    private var pendingWrite: Task<Void, Never>?
    private var snapshots: [UUID: MeshCheckpoint] = [:]
    private var lastSnapshotTimes: [UUID: TimeInterval] = [:]
    private var lastHealthCheck: TimeInterval = 0
    private var needsNewFrame = false
    private var checkpointError: String?
    private var startGeneration = UUID()
    private var observers = Set<AnyCancellable>()
    private var latestLocationFix: GeoLocationFix?
    private var isPreviewing = false
    private var isPreparingPreview = false
    private var isResuming = false
    private var fragmentClock = CaptureFragmentActiveClock()
    private var fragmentMinimumTimestamp: TimeInterval?
    private var cameraWatchdog: Task<Void, Never>?
    private var lastFrameAt: TimeInterval?
    private var receivedFrameCount = 0
    private var lastFramePublication: TimeInterval = 0
    private var hadStableTracking = false
    private let meshProcessor = MeshCheckpointProcessor()
    private var meshTasks: [UUID: Task<Void, Never>] = [:]
    private var meshGeneration = UUID()
    private var totalTriangles = 0
    private var totalSurfaceArea: Double = 0
    private var lastMetricPublication: TimeInterval = 0
    private struct PlaneBoundary {
        var points: [SIMD3<Float>]
        var firstSeen: TimeInterval
        var lastUpdated: TimeInterval
        var isCeiling: Bool
    }
    private var planeBoundaries: [UUID: PlaneBoundary] = [:]
    private var lastOutlinePublication: TimeInterval = 0
    private var recordedSurfaceRoot: AnchorEntity?
    private struct SurfaceOverlay {
        var entity: Entity
        var fills: [ModelEntity]
        var center: SIMD3<Float>
        var triangleCount: Int
        var updatedAt: TimeInterval
    }
    private var surfaceOverlays: [UUID: SurfaceOverlay] = [:]
    private var lastGuidancePublication: TimeInterval = 0
    private var previousCameraPose: (position: SIMD3<Float>, forward: SIMD3<Float>, time: TimeInterval)?
    private var motionWarningUntil: TimeInterval = 0
    private var lastGeometryAt: TimeInterval = 0
    private var lastSurfaceBiasPublication: TimeInterval = 0
    private var videoRecorder: CaptureVideoRecorder?
    private var videoFinishTasks: [UUID: Task<CaptureVideoResult, Never>] = [:]
    private var cameraLifecycle = CaptureCameraLifecycle()
    private var cameraDelegate: CaptureSessionDelegate?

    override init() {
        super.init()
        // Only the raw Metal-buffer copy occurs on the main delegate queue.
        // Geometry transforms and surface-area calculation run on an actor.
        if !Self.isSupported {
            state = .unavailable
            trackingMessage = "Для 3D-съёмки нужен iPhone или iPad с LiDAR"
            cameraStatus = trackingMessage
        }
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pause(reason: "Память устройства заканчивается. Сохраните этот фрагмент.")
                }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupt(reason: "Съёмка приостановлена при выходе из приложения") }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendForDismissal() }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    if ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .serious {
                        self?.pause(reason: "Устройство нагрелось. Дайте ему остыть; фрагмент сохранён.")
                    }
                }
            }.store(in: &observers)
    }

    /// A visible camera preview has no writer and stores no scan geometry.
    /// Starting a scan resets its own independent, durable coordinate frame.
    func preparePreview() async {
        guard Self.isSupported, state == .ready || state == .saved,
              !isPreviewing, !isPreparingPreview, !Task.isCancelled else { return }
        let ticket = UUID(); startGeneration = ticket
        isPreparingPreview = true
        cameraStatus = "Открываем камеру…"
        errorMessage = nil
        // A cancelled request must not clear a newer request's guard.
        defer { if startGeneration == ticket { isPreparingPreview = false } }
        do {
            try await Self.requireCameraAccess()
            guard ticket == startGeneration, !Task.isCancelled else { return }
            let view = arView
            try await Self.waitForCameraPresentation(view)
            guard ticket == startGeneration, !Task.isCancelled else { return }
            let config = ARWorldTrackingConfiguration()
            config.worldAlignment = .gravity
            config.environmentTexturing = .none
            config.planeDetection = [.horizontal, .vertical]
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
            isPreviewing = true
            resetCameraReadiness(clearRecordedSurfaces: true)
            runCamera(view, configuration: config, mode: .preview,
                      options: [.resetTracking, .removeExistingAnchors])
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
        stopCameraPresentation()
        isCameraReady = false
        cameraStatus = "Камера остановлена"
    }

    /// Selection is explicit and fixed before a scan starts. Video shares the
    /// AR camera; enabling it never creates another camera session.
    func setVideoEnabled(_ enabled: Bool) {
        guard state == .ready || state == .saved ||
              ((state == .paused || state == .interrupted) && needsNewFrame && videoRecorder == nil) else { return }
        videoEnabled = enabled
        videoIssue = nil
        videoStatus = enabled ? "Видео начнётся вместе с LiDAR" : "Видео выключено"
    }

    var canChangeVideoSelection: Bool {
        state == .ready || state == .saved ||
            ((state == .paused || state == .interrupted) && needsNewFrame && videoRecorder == nil)
    }

    var fragmentRecommendation: CaptureFragmentPolicy.Recommendation? {
        guard state == .recording else { return nil }
        return fragmentClock.recommendation(availableDiskBytes: availableDiskBytes)
    }

    func deferFragmentRecommendation(for activeSeconds: TimeInterval = CaptureFragmentPolicy.recommendationDeferralSeconds) {
        fragmentClock.deferRecommendation(for: activeSeconds)
        fragmentElapsedSeconds = fragmentClock.elapsedSeconds
    }

    private func resetFragmentClock(id: UUID?) {
        fragmentClock.reset(); fragmentElapsedSeconds = 0; currentFragmentID = id
        fragmentMinimumTimestamp = id == nil ? nil : ProcessInfo.processInfo.systemUptime
    }

    static func continuableCaptures(in outputDirectory: URL, projectID: UUID) async -> [CaptureContinuationRecord] {
        await CaptureContinuationStore().records(in: outputDirectory, projectID: projectID)
    }

    /// Reopening loads existing originals without starting the camera. Explicit
    /// resume creates a new independent origin; yesterday's mesh is not joined.
    func restoreForContinuation(at manifestURL: URL, projectID: UUID, outputDirectory: URL) async throws {
        guard state == .ready || state == .saved else { throw CaptureError.operationInProgress }
        guard Self.isSupported else { throw CaptureError.lidarUnsupported }
        guard manifestURL.lastPathComponent == "manifest.json" else { throw CaptureContinuationPolicy.ValidationError.invalid }
        suspendPreview()
        let previousState = state
        let generation = UUID(); startGeneration = generation
        state = .preparing
        let directory = manifestURL.deletingLastPathComponent()
        let restoredWriter = MeshCheckpointWriter(root: directory)
        do {
            var restored = try await restoredWriter.loadForContinuation(projectID: projectID, outputDirectory: outputDirectory)
            guard generation == startGeneration, !Task.isCancelled else { throw CancellationError() }
            for index in restored.segments.indices where restored.segments[index].endedAt == nil {
                restored.segments[index].endedAt = CaptureContinuationPolicy.conservativeEnd(
                    startedAt: restored.segments[index].startedAt, lastSavedAt: restored.updatedAt)
                restored.segments[index].endReason = "reopenedWithIndependentARFrame"
            }
            let notice = "Reopened capture: each continuation uses a new independent AR frame and requires operator alignment. An unclosed prior segment ends conservatively at its last manifest timestamp, not at reopening."
            if !restored.notes.contains(notice) { restored.notes.append(notice) }
            manifest = restored; writer = restoredWriter; captureDirectory = directory
            videoFinishTasks.removeAll(); videoRecorder = nil; videoIsRecording = false; videoIssue = nil
            snapshots.removeAll(); lastSnapshotTimes.removeAll(); meshGeneration = UUID()
            totalTriangles = 0; totalSurfaceArea = 0; lastMetricPublication = 0
            pendingWrite = nil; checkpointError = nil; lastCheckpoint = nil
            anchorCount = 0; triangleCount = 0; observedSurfaceArea = 0
            segmentCount = restored.segments.count; needsNewFrame = true
            resetFragmentClock(id: nil)
            resetCameraReadiness(clearRecordedSurfaces: true)
            errorMessage = nil; state = .paused
            cameraStatus = "Готово к продолжению. Нажмите «Продолжить»"
            trackingMessage = "Продолжение создаст отдельный фрагмент. Для общего плана нужно совмещение"
            videoStatus = videoEnabled ? "Видео начнётся в новом фрагменте" : "Видео выключено"
        } catch {
            if generation == startGeneration { state = previousState }
            throw error
        }
    }

    func start(projectID: UUID, projectName: String, outputDirectory: URL) async {
        guard state == .ready || state == .saved else { return }
        guard !Task.isCancelled else { return }
        guard Self.isSupported else { state = .unavailable; return }
        suspendPreview()
        let generation = UUID()
        startGeneration = generation
        state = .preparing
        cameraStatus = "Подготавливаем LiDAR и локальное сохранение…"
        errorMessage = nil
        do {
            try await Self.requireCameraAccess()
            guard startGeneration == generation else { return }
            guard !Task.isCancelled else { state = .ready; return }
            let view = arView
            try await Self.waitForCameraPresentation(view)
            guard startGeneration == generation, !Task.isCancelled else { return }
            let health = try Self.preflight(at: outputDirectory)
            availableDiskBytes = health.diskBytes
            let captureID = UUID()
            let directory = outputDirectory.appendingPathComponent("lidar-\(captureID.uuidString)", isDirectory: true)
            let segment = CaptureSegment(id: UUID(), frameID: UUID(), startedAt: Date(), endedAt: nil,
                endReason: nil, geoTag: freshAutomaticTag())
            let newManifest = LiDARCaptureManifest(id: captureID, projectID: projectID, projectName: projectName,
                createdAt: Date(), updatedAt: Date(), status: "recording", segments: [segment],
                deviceModel: UIDevice.current.model, operatingSystem: UIDevice.current.systemVersion,
                availableDiskAtStart: health.diskBytes, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                completedAssets: [], notes: Self.coordinateNotes)
            let newWriter = MeshCheckpointWriter(root: directory)
            try await newWriter.create(manifest: newManifest)
            guard !Task.isCancelled, startGeneration == generation else {
                // Capture has not run yet; this folder contains no source data.
                try? FileManager.default.removeItem(at: directory)
                if startGeneration == generation { state = .ready }
                return
            }
            manifest = newManifest
            writer = newWriter
            captureDirectory = directory
            videoFinishTasks.removeAll()
            videoRecorder = nil; videoIsRecording = false
            snapshots.removeAll()
            lastSnapshotTimes.removeAll()
            meshGeneration = UUID()
            totalTriangles = 0; totalSurfaceArea = 0; lastMetricPublication = 0
            pendingWrite = nil
            checkpointError = nil
            anchorCount = 0; triangleCount = 0; observedSurfaceArea = 0
            segmentCount = 1
            resetFragmentClock(id: segment.id)
            needsNewFrame = false
            isPreviewing = false
            resetCameraReadiness(clearRecordedSurfaces: true)
            state = .recording
            beginSegmentVideo()
            runCamera(view, configuration: configuration(), mode: .recording(segmentID: segment.id),
                      options: [.resetTracking, .removeExistingAnchors])
            beginCameraWatchdog()
            // Permission/GPS may finish while the camera and files prepare.
            updateAutomaticLocation(latestLocationFix)
            trackingMessage = "Медленно обойдите объект со всех сторон"
        } catch {
            guard startGeneration == generation else { return }
            errorMessage = error.localizedDescription
            state = .ready
        }
    }

    /// Updates only the active segment. Closed segments keep their own fix and
    /// are never assigned a later location from a different AR origin.
    func updateAutomaticLocation(_ fix: GeoLocationFix?) {
        latestLocationFix = fix
        guard state == .recording, let fix, var current = manifest,
              !current.segments.isEmpty else { return }
        let index = current.segments.count - 1
        guard current.segments[index].endedAt == nil,
              let chosen = GeoTagPolicy.bestAutomatic(current: current.segments[index].geoTag?.automaticFix,
                  candidate: fix, now: Date()) else { return }
        guard chosen != current.segments[index].geoTag?.automaticFix else { return }
        current.segments[index].geoTag = GeoTag(automaticFix: chosen)
        manifest = current
        updateManifest(status: current.status)
    }

    private func freshAutomaticTag() -> GeoTag? {
        guard let fix = latestLocationFix, GeoTagPolicy.acceptDeviceFix(fix, now: Date()) else { return nil }
        return GeoTag(automaticFix: fix)
    }

    func pause(reason: String? = nil) {
        guard state == .recording else { return }
        stopCameraPresentation()
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        fragmentClock.pause()
        fragmentElapsedSeconds = fragmentClock.elapsedSeconds
        state = .paused
        isCameraReady = false
        cameraStatus = "Камера на паузе"
        isTrackingNormal = false
        trackingMessage = reason ?? "Пауза. Фрагмент остаётся в локальных координатах"
        if videoEnabled {
            // One movie belongs to one uninterrupted AR origin. A resumed
            // movie starts a new segment instead of overwriting or joining.
            closeVideo(reason: reason ?? "userPaused")
            needsNewFrame = true
            closeCurrentSegment(reason: reason ?? "userPaused")
            trackingMessage = reason ?? "Пауза. Продолжение начнёт отдельный фрагмент с видео"
        }
        updateManifest(status: "paused")
        checkpointAll()
    }

    func resume() async {
        guard !isResuming, state == .paused || state == .interrupted, var current = manifest, let writer else { return }
        guard Self.isSupported else { errorMessage = CaptureError.lidarUnsupported.localizedDescription; return }
        isResuming = true
        defer { isResuming = false }
        let generation = UUID(); startGeneration = generation
        var provisionalSegmentID: UUID?
        var runOptions: ARSession.RunOptions = []
        do {
            try await Self.requireCameraAccess()
            guard generation == startGeneration, !Task.isCancelled else { return }
            let view = arView
            try await Self.waitForCameraPresentation(view)
            guard generation == startGeneration, !Task.isCancelled else { return }
            if let directory = captureDirectory { availableDiskBytes = try Self.preflight(at: directory).diskBytes }
            if needsNewFrame {
                for task in Array(meshTasks.values) { await task.value }
                if let pendingWrite { await pendingWrite.value }
                guard generation == startGeneration, !Task.isCancelled,
                      state == .paused || state == .interrupted else { return }
                if let checkpointError { throw CaptureError.checkpointFailed(checkpointError) }
                guard current.segments.count < 256 else { throw CaptureError.segmentLimit }
                let newSegment = CaptureSegment(id: UUID(), frameID: UUID(), startedAt: Date(), endedAt: nil,
                    endReason: nil, geoTag: freshAutomaticTag())
                provisionalSegmentID = newSegment.id
                current.segments.append(newSegment)
                current.status = "recording"; current.updatedAt = Date()
                manifest = current
                try await writer.saveManifest(current)
                guard generation == startGeneration, !Task.isCancelled,
                      state == .paused || state == .interrupted,
                      UIApplication.shared.applicationState == .active else {
                    await closeUnstartedSegment(newSegment.id, writer: writer)
                    return
                }
                snapshots.removeAll(); lastSnapshotTimes.removeAll()
                clearSurfaceOverlays()
                meshGeneration = UUID()
                totalTriangles = 0; totalSurfaceArea = 0; lastMetricPublication = 0
                anchorCount = 0; triangleCount = 0; observedSurfaceArea = 0
                segmentCount = current.segments.count
                resetFragmentClock(id: newSegment.id)
                runOptions = [.resetTracking, .removeExistingAnchors]
                provisionalSegmentID = nil
                trackingMessage = "Новый фрагмент. Его координаты требуют отдельного совмещения"
            } else {
                fragmentMinimumTimestamp = ProcessInfo.processInfo.systemUptime
                trackingMessage = "Восстановление трекинга"
            }
            needsNewFrame = false
            errorMessage = nil
            resetCameraReadiness()
            state = .recording
            beginSegmentVideo()
            guard let segment = manifest?.segments.last else { throw CaptureError.noCapture }
            runCamera(view, configuration: configuration(), mode: .recording(segmentID: segment.id), options: runOptions)
            beginCameraWatchdog()
            updateAutomaticLocation(latestLocationFix)
            updateManifest(status: "recording")
        } catch {
            if let provisionalSegmentID { await closeUnstartedSegment(provisionalSegmentID, writer: writer) }
            if generation == startGeneration { errorMessage = error.localizedDescription }
        }
    }

    private func closeUnstartedSegment(_ id: UUID, writer: MeshCheckpointWriter) async {
        guard var current = manifest, let index = current.segments.firstIndex(where: { $0.id == id }),
              current.segments[index].endedAt == nil else { return }
        current.segments[index].endedAt = current.segments[index].startedAt
        current.segments[index].endReason = "cancelledBeforeCameraRun"
        current.status = state == .interrupted ? "interrupted" : "paused"
        current.updatedAt = Date(); manifest = current
        if let pendingWrite { await pendingWrite.value }
        guard state == .paused || state == .interrupted, let latest = manifest,
              latest.id == current.id,
              latest.segments.first(where: { $0.id == id })?.endReason == "cancelledBeforeCameraRun" else { return }
        do { try await writer.saveManifest(latest) }
        catch { errorMessage = error.localizedDescription }
    }

    /// Flushes current mesh checkpoints and exports every independent segment.
    /// Multiple AR origins are deliberately not welded into a misleading model.
    func finish() async throws -> URL {
        guard state != .exporting else { throw CaptureError.operationInProgress }
        updateAutomaticLocation(latestLocationFix)
        guard let writer, var current = manifest, let directory = captureDirectory else {
            throw CaptureError.noCapture
        }
        // A concurrent pending resume must not run its camera after Save.
        startGeneration = UUID()
        stopCameraPresentation()
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        fragmentClock.pause()
        fragmentElapsedSeconds = fragmentClock.elapsedSeconds
        closeVideo(reason: "userFinished")
        needsNewFrame = true
        if !current.segments.isEmpty && current.segments[current.segments.count - 1].endedAt == nil {
            current.segments[current.segments.count - 1].endedAt = Date()
            current.segments[current.segments.count - 1].endReason = "userFinished"
        }
        manifest = current
        state = .exporting
        isCameraReady = false
        cameraStatus = "Сохраняем модель"
        isTrackingNormal = false
        for task in Array(meshTasks.values) { await task.value }
        let videoResults = await finalizedVideoResults()
        for result in videoResults where !result.completed {
            let notice = "Video segment \(result.identity.segmentID.uuidString): \(result.failure ?? "not completed"). Partial source files are retained."
            if !current.notes.contains(notice) { current.notes.append(notice) }
        }
        publishMeshMetrics(force: true)
        checkpointAll()
        if let pendingWrite { await pendingWrite.value }
        if let checkpointError {
            state = .paused
            throw CaptureError.checkpointFailed(checkpointError)
        }
        if !current.segments.isEmpty && current.segments[current.segments.count - 1].endedAt == nil {
            current.segments[current.segments.count - 1].endedAt = Date()
            current.segments[current.segments.count - 1].endReason = "userFinished"
        }
        current.status = "exporting"; current.updatedAt = Date()
        manifest = current
        do {
            let finished = try await writer.finalize(current)
            manifest = finished
            state = .saved
            trackingMessage = "Сохранено на устройстве"
            return directory.appendingPathComponent("manifest.json")
        } catch {
            state = .paused
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func suspendForDismissal() {
        cancelPendingStart()
        if state == .recording { interrupt(reason: "Приложение свернуто. Сохранён отдельный фрагмент") }
        suspendPreview()
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        stopCameraPresentation()
        isCameraReady = false
    }

    func cancelPendingStart() {
        // Preparation can still be awaiting an iOS permission sheet while the
        // scan state is ready. Invalidate that ticket and stop any preview too.
        suspendPreview()
        startGeneration = UUID()
        isPreparingPreview = false
        if state == .preparing { state = .ready; trackingMessage = "Подготовка отменена" }
    }

    /// A caller can offer recovery for a manifest whose status is not `ready`.
    /// Recovery reads only committed mesh files; incomplete temp files are ignored.
    static func recoverIncompleteCapture(at directory: URL) async throws -> URL {
        let writer = MeshCheckpointWriter(root: directory)
        let manifest = try await writer.loadManifest()
        _ = try await writer.finalize(manifest)
        return directory.appendingPathComponent("manifest.json")
    }

    private func configuration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            ? .meshWithClassification : .mesh
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        return config
    }

    private func interrupt(reason: String) {
        guard state == .recording || state == .paused else { return }
        stopCameraPresentation()
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        fragmentClock.pause()
        fragmentElapsedSeconds = fragmentClock.elapsedSeconds
        closeVideo(reason: reason)
        state = .interrupted
        isCameraReady = false
        cameraStatus = reason
        isTrackingNormal = false
        needsNewFrame = true
        trackingMessage = reason
        closeCurrentSegment(reason: reason)
        updateManifest(status: "interrupted")
        checkpointAll()
    }

    fileprivate func session(_ session: ARSession, didAdd anchors: [ARAnchor], runID: UUID) {
        guard acceptsSessionCallback(session, runID: runID), cameraLifecycle.acceptsAnchors(runID: runID) else { return }
        updatePlaneBoundaries(anchors)
        consume(anchors)
    }
    fileprivate func session(_ session: ARSession, didUpdate anchors: [ARAnchor], runID: UUID) {
        guard acceptsSessionCallback(session, runID: runID), cameraLifecycle.acceptsAnchors(runID: runID) else { return }
        updatePlaneBoundaries(anchors)
        consume(anchors)
    }
    fileprivate func session(_ session: ARSession, didRemove anchors: [ARAnchor], runID: UUID) {
        guard acceptsSessionCallback(session, runID: runID), cameraLifecycle.acceptsAnchors(runID: runID) else { return }
        for anchor in anchors {
            cameraLifecycle.removeAnchor(anchor.identifier)
            planeBoundaries[anchor.identifier] = nil
            if let removed = surfaceOverlays.removeValue(forKey: anchor.identifier) {
                removed.entity.removeFromParent()
            }
        }
        publishOverlayMetrics()
    }

    private func updatePlaneBoundaries(_ anchors: [ARAnchor]) {
        guard state == .recording || isPreviewing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for anchor in anchors {
            guard let plane = anchor as? ARPlaneAnchor,
                  planeBoundaries[plane.identifier] != nil || planeBoundaries.count < 24 else { continue }
            let previous = planeBoundaries[plane.identifier]
            guard previous == nil || now - (previous?.lastUpdated ?? 0) >= 0.4 else { continue }
            // Swift exposes the Objective-C pointer/count pair as an array.
            // Read it once; repeatedly accessing the overlay can copy buffers.
            let boundary = plane.geometry.boundaryVertices
            let count = boundary.count
            // Joining sparsely sampled corners across a detailed concave
            // boundary would invent diagonals. Prefer fills for complex planes.
            guard count >= 3, count <= LiDAROverlayGeometry.maximumBoundaryVertices else {
                planeBoundaries[plane.identifier] = nil; continue
            }
            let samples = count
            var points = [SIMD3<Float>]()
            points.reserveCapacity(samples)
            var isFiniteBoundary = true
            for sample in 0..<samples {
                let local = boundary[sample]
                let world = plane.transform * SIMD4(local.x, local.y, local.z, 1)
                let point = SIMD3(world.x, world.y, world.z)
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                    isFiniteBoundary = false; break
                }
                points.append(point)
            }
            planeBoundaries[plane.identifier] = isFiniteBoundary && points.count >= 3
                ? PlaneBoundary(points: points, firstSeen: previous?.firstSeen ?? now,
                    lastUpdated: now, isCeiling: plane.classification == .ceiling) : nil
        }
    }

    private func projectPlaneOutlines(now: TimeInterval) {
        guard now - lastOutlinePublication >= 0.25, let view = cameraView,
              let camera = view.session.currentFrame?.camera,
              view.bounds.width > 1, view.bounds.height > 1 else { return }
        lastOutlinePublication = now
        let cameraPosition = SIMD3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
        let worldToCamera = simd_inverse(camera.transform)
        let viewport = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
        // Only the three closest stable borders are useful guidance. Ceilings
        // remain visible as filled recorded surfaces, without a line spiderweb.
        let candidates = planeBoundaries.values.filter {
            !$0.isCeiling && now - $0.firstSeen >= 0.8 &&
                !($0.points.allSatisfy { $0.y > cameraPosition.y + 0.6 })
        }.sorted {
            simd_distance($0.points[0], cameraPosition) < simd_distance($1.points[0], cameraPosition)
        }.prefix(3)
        var outlines = [[CGPoint]]()
        for boundary in candidates {
            let cameraPoints = boundary.points.map { point -> SIMD3<Float> in
                let value = worldToCamera * SIMD4(point.x, point.y, point.z, 1)
                return SIMD3(value.x, value.y, value.z)
            }
            for (a, b) in LiDAROverlayGeometry.clipCameraBoundary(cameraPoints) {
                guard simd_length(a) <= 6, simd_length(b) <= 6 else { continue }
                let worldA = camera.transform * SIMD4(a.x, a.y, a.z, 1)
                let worldB = camera.transform * SIMD4(b.x, b.y, b.z, 1)
                guard let pa = view.project(SIMD3(worldA.x, worldA.y, worldA.z)),
                      let pb = view.project(SIMD3(worldB.x, worldB.y, worldB.z)),
                      let clipped = LiDAROverlayGeometry.clipScreenLine(
                        from: SIMD2(Float(pa.x), Float(pa.y)), to: SIMD2(Float(pb.x), Float(pb.y)), viewport: viewport) else { continue }
                let first = CGPoint(x: CGFloat(clipped.0.x), y: CGFloat(clipped.0.y))
                let second = CGPoint(x: CGFloat(clipped.1.x), y: CGFloat(clipped.1.y))
                guard hypot(first.x - second.x, first.y - second.y) >= 8 else { continue }
                outlines.append([first, second])
            }
        }
        if outlines != detectedPlaneOutlines { detectedPlaneOutlines = outlines }
    }

    fileprivate func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera, runID: UUID) {
        guard acceptsSessionCallback(session, runID: runID), cameraLifecycle.acceptsAnchors(runID: runID),
              state == .recording || isPreviewing else { return }
        switch camera.trackingState {
        case .normal:
            isTrackingNormal = true
            hadStableTracking = true
            trackingMessage = "Трекинг стабилен · медленно обойдите объект"
        case .notAvailable:
            isTrackingNormal = false
            // Initial ARKit startup can report notAvailable before initializing.
            // Pausing here used to prevent the first camera frame altogether.
            if hadStableTracking, state == .recording {
                interrupt(reason: "Трекинг потерян. Продолжение создаст отдельный фрагмент")
            } else { trackingMessage = "Запускаем трекинг. Плавно двигайте телефон" }
        case let .limited(reason):
            isTrackingNormal = false
            switch reason {
            case .initializing: trackingMessage = "Плавно двигайте телефон для начала трекинга"
            case .excessiveMotion: trackingMessage = "Двигайтесь медленнее"
            case .insufficientFeatures: trackingMessage = "Добавьте света и наведите на фактурную поверхность"
            case .relocalizing: trackingMessage = "Восстановление позиции. Пока не перемещайтесь далеко"
            @unknown default: trackingMessage = "Трекинг ограничен; проверьте условия съёмки"
            }
        }
    }

    fileprivate func sessionWasInterrupted(_ session: ARSession, runID: UUID) {
        guard acceptsSessionCallback(session, runID: runID) else { return }
        if isPreviewing {
            suspendPreview()
            let message = "Камера прервана. Повторите запуск предпросмотра"
            errorMessage = message; cameraStatus = message
        }
        interrupt(reason: "Камера прервала съёмку. Данные фрагмента сохранены")
    }
    fileprivate func sessionInterruptionEnded(_ session: ARSession, runID: UUID) {
        guard acceptsSessionCallback(session, runID: runID) else { return }
        if state == .interrupted { trackingMessage = "Можно продолжить отдельным фрагментом или завершить" }
    }
    fileprivate func session(_ session: ARSession, didFailWithError error: Error, runID: UUID) {
        guard acceptsSessionCallback(session, runID: runID) else { return }
        if isPreviewing { suspendPreview() }
        interrupt(reason: "Ошибка AR-сессии; завершённые части сохранены")
        errorMessage = error.localizedDescription
        cameraStatus = error.localizedDescription
    }

    fileprivate func session(_ session: ARSession, didUpdate frame: ARFrame, runID: UUID) {
        guard acceptsSessionCallback(session, runID: runID),
              UIApplication.shared.applicationState == .active,
              state == .recording || isPreviewing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A cached frame must never mark a frozen/black session as ready.
        guard cameraLifecycle.acceptFrame(runID: runID, timestamp: frame.timestamp, now: now) else { return }
        if receivedFrameCount == 0 {
            self.session(session, cameraDidChangeTrackingState: frame.camera, runID: runID)
        }
        lastFrameAt = now
        receivedFrameCount += 1
        if state == .recording, let fragmentMinimumTimestamp, frame.timestamp >= fragmentMinimumTimestamp {
            fragmentClock.observe(arTimestamp: frame.timestamp)
        }
        if state == .recording, let videoRecorder {
            let transform = frame.camera.transform, intrinsics = frame.camera.intrinsics
            let orientation: UIInterfaceOrientation
            switch videoRecorder.identity.orientation {
            case .portrait: orientation = .portrait
            case .portraitUpsideDown: orientation = .portraitUpsideDown
            case .landscapeLeft: orientation = .landscapeLeft
            case .landscapeRight: orientation = .landscapeRight
            }
            let width = CVPixelBufferGetWidth(frame.capturedImage), height = CVPixelBufferGetHeight(frame.capturedImage)
            let portrait = orientation == .portrait || orientation == .portraitUpsideDown
            let display = frame.displayTransform(for: orientation,
                viewportSize: CGSize(width: portrait ? height : width, height: portrait ? width : height))
            let tracking: String
            switch frame.camera.trackingState {
            case .normal: tracking = "normal"
            case .notAvailable: tracking = "unavailable"
            case .limited: tracking = "limited"
            }
            let descriptor = CaptureVideoFrameDescriptor(arTimestamp: frame.timestamp,
                observedAt: Date().addingTimeInterval(frame.timestamp - now),
                cameraTransform: (0..<4).flatMap { column in (0..<4).map { transform[column][$0] } },
                intrinsics: (0..<3).flatMap { column in (0..<3).map { intrinsics[column][$0] } },
                trackingState: tracking,
                normalizedImageToDisplayTransform: [Float(display.a), Float(display.b), Float(display.c),
                    Float(display.d), Float(display.tx), Float(display.ty)])
            videoRecorder.offer(image: frame.capturedImage, descriptor: descriptor)
        }
        projectPlaneOutlines(now: now)
        updateSurfaceBias(camera: frame.camera, now: now)
        updateScanGuidance(frame, now: now)
        if !isCameraReady {
            isCameraReady = true
            cameraStatus = "Камера работает"
        }
        if now - lastFramePublication > 0.5 {
            cameraFrameCount = receivedFrameCount
            if state == .recording { fragmentElapsedSeconds = fragmentClock.elapsedSeconds }
            lastFramePublication = now
        }
        guard state == .recording, frame.timestamp - lastHealthCheck > 8 else { return }
        lastHealthCheck = frame.timestamp
        guard let directory = captureDirectory else { return }
        do { availableDiskBytes = try Self.preflight(at: directory).diskBytes }
        catch { pause(reason: error.localizedDescription) }
    }

    private func runCamera(_ view: ARView, configuration: ARWorldTrackingConfiguration,
                           mode: CaptureCameraLifecycle.Mode, options: ARSession.RunOptions) {
        // Every run has a separate delegate ticket, including same-origin
        // resume. Queued callbacks and completed disk writes from an older run
        // cannot repopulate this run's transient RealityKit/Canvas overlays.
        cameraLifecycle.stop()
        clearSurfaceOverlays()
        let runID = cameraLifecycle.begin(mode, at: ProcessInfo.processInfo.systemUptime)
        let delegate = CaptureSessionDelegate(owner: self, runID: runID)
        cameraDelegate = delegate
        view.session.delegate = delegate
        view.session.run(configuration, options: options)
    }

    private func stopCameraPresentation() {
        cameraLifecycle.stop()
        cameraView?.session.delegate = nil
        cameraDelegate = nil
        cameraView?.session.pause()
        // Keep snapshots and pending writes: these are source material, not
        // transient camera overlays. Only the live visualization is discarded.
        clearSurfaceOverlays()
        planeBoundaries.removeAll(); detectedPlaneOutlines = []
        isCameraReady = false; isTrackingNormal = false
        surfaceDistanceMeters = nil
    }

    private func acceptsSessionCallback(_ session: ARSession, runID: UUID) -> Bool {
        cameraView?.session === session && cameraLifecycle.acceptsCallback(runID: runID)
    }

    private func resetCameraReadiness(clearRecordedSurfaces: Bool = false) {
        cameraWatchdog?.cancel(); cameraWatchdog = nil
        lastFrameAt = nil; receivedFrameCount = 0; lastFramePublication = 0
        cameraFrameCount = 0; isCameraReady = false; isTrackingNormal = false
        hadStableTracking = false; lastHealthCheck = 0
        planeBoundaries.removeAll(); detectedPlaneOutlines = []; lastOutlinePublication = 0
        if clearRecordedSurfaces { clearSurfaceOverlays() }
        surfaceDistanceMeters = nil; lastGuidancePublication = 0; previousCameraPose = nil
        motionWarningUntil = 0; lastGeometryAt = 0; guidanceNeedsAttention = false
        scanGuidance = "Покажите стену или предмет с расстояния 0,5–3 м"
        cameraStatus = "Ожидаем изображение с камеры…"
    }

    private func updateScanGuidance(_ frame: ARFrame, now: TimeInterval) {
        let transform = frame.camera.transform
        let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = SIMD3(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
        if let previous = previousCameraPose {
            let interval = now - previous.time
            if interval > 0.01, interval < 0.5 {
                let speed = simd_distance(position, previous.position) / Float(interval)
                let cosine = min(1, max(-1, simd_dot(forward, previous.forward)))
                let turnRate = acos(cosine) / Float(interval)
                if speed > 0.65 || turnRate > 1.2 { motionWarningUntil = now + 1.2 }
            }
        }
        previousCameraPose = (position, forward, now)
        guard now - lastGuidancePublication >= 0.5 else { return }
        lastGuidancePublication = now
        surfaceDistanceMeters = Self.centerDepth(frame.smoothedSceneDepth ?? frame.sceneDepth)
        var attention = false
        let guidance: String
        if !isTrackingNormal {
            guidance = trackingMessage; attention = true
        } else if motionWarningUntil > now {
            guidance = "Медленнее: ведите телефон плавно, без резких поворотов"; attention = true
        } else if let distance = surfaceDistanceMeters, distance < 0.35 {
            guidance = "Отойдите немного: поверхность слишком близко"; attention = true
        } else if let distance = surfaceDistanceMeters, distance > 4 {
            guidance = "Подойдите ближе: для деталей держите 0,5–3 м"; attention = true
        } else if let light = frame.lightEstimate?.ambientIntensity, light < 300 {
            guidance = "Добавьте света: камере нужны видимые детали"; attention = true
        } else if state == .recording, lastGeometryAt > 0, now - lastGeometryAt > 4 {
            guidance = "Сетка пока не обновляется. Сместитесь и покажите соседнюю поверхность"; attention = true
        } else if state == .recording, lastCheckpoint != nil {
            guidance = "Заливка — записанная сетка. Медленно покажите участки без заливки"
        } else if state == .recording {
            guidance = "Запись идёт. Медленно покажите пол, стены и затем потолок"
        } else {
            guidance = "Наведите на объект и нажмите запись. Предпросмотр ещё не сохраняет сетку"
        }
        if scanGuidance != guidance { scanGuidance = guidance }
        if guidanceNeedsAttention != attention { guidanceNeedsAttention = attention }
    }

    /// A bounded 5×5 central sample measures the reticle surface, not a guessed
    /// room dimension. Low-confidence depth is excluded when ARKit provides it.
    private static func centerDepth(_ depth: ARDepthData?) -> Double? {
        guard let depth else { return nil }
        let map = depth.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        guard width >= 5, height >= 5, rowBytes >= width * 4 else { return nil }
        let confidence = depth.confidenceMap
        var confidenceAddress: UnsafeMutableRawPointer?
        var confidenceRowBytes = 0
        var confidenceLocked = false
        if let confidence,
           CVPixelBufferGetWidth(confidence) == width, CVPixelBufferGetHeight(confidence) == height,
           CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess {
            confidenceLocked = true
            confidenceAddress = CVPixelBufferGetBaseAddress(confidence)
            confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer { if confidenceLocked, let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
        var values = [Float](); values.reserveCapacity(25)
        for y in (height / 2 - 2)...(height / 2 + 2) {
            for x in (width / 2 - 2)...(width / 2 + 2) {
                if let confidenceAddress, confidenceRowBytes >= width,
                   confidenceAddress.load(fromByteOffset: y * confidenceRowBytes + x, as: UInt8.self) == 0 { continue }
                let value = address.load(fromByteOffset: y * rowBytes + x * 4, as: Float.self)
                if value.isFinite, value >= 0.1, value <= 8 { values.append(value) }
            }
        }
        guard values.count >= 5 else { return nil }
        values.sort()
        return Double(values[values.count / 2])
    }

    private func clearSurfaceOverlays() {
        if let root = recordedSurfaceRoot { cameraView?.scene.removeAnchor(root) }
        recordedSurfaceRoot = nil; surfaceOverlays.removeAll()
        lastSurfaceBiasPublication = 0
        overlayTriangleCount = 0; overlayAnchorCount = 0; overlayIssue = nil
    }

    private func publishOverlayMetrics() {
        let triangles = surfaceOverlays.values.reduce(0) { $0 + $1.triangleCount }
        if overlayTriangleCount != triangles { overlayTriangleCount = triangles }
        if overlayAnchorCount != surfaceOverlays.count { overlayAnchorCount = surfaceOverlays.count }
    }

    /// Updating tiny fill translations avoids stale depth bias when the
    /// operator walks around a surface without a new AR mesh checkpoint.
    /// Mesh resources and persisted world coordinates remain untouched.
    private func updateSurfaceBias(camera: ARCamera, now: TimeInterval) {
        guard now - lastSurfaceBiasPublication >= 0.1, showRecordedSurfaces else { return }
        lastSurfaceBiasPublication = now
        let position = camera.transform.columns.3
        let cameraPosition = SIMD3(position.x, position.y, position.z)
        for overlay in surfaceOverlays.values {
            let bias = LiDAROverlayGeometry.cameraFacingBias(from: overlay.center, toward: cameraPosition)
            for fill in overlay.fills { fill.position = bias }
        }
    }

    /// Visualization is deliberately bounded independently of source storage.
    /// It never deletes or decimates the durable OBJ/checkpoint geometry.
    private func showCommittedSurface(_ overlay: MeshSurfaceOverlay, anchorID: UUID, runID: UUID,
                                      segmentID: UUID, permit: UUID) {
        guard state == .recording, !isPreviewing,
              cameraLifecycle.acceptsSurface(runID: runID, segmentID: segmentID, anchorID: anchorID, permit: permit),
              manifest?.segments.last?.id == segmentID,
              let view = cameraView, view.window != nil,
              UIApplication.shared.applicationState == .active, !overlay.groups.isEmpty else { return }
        let position = view.session.currentFrame?.camera.transform.columns.3 ?? SIMD4<Float>(0, 0, 0, 1)
        let camera = SIMD3(position.x, position.y, position.z)
        guard simd_distance(overlay.center, camera) < 6 else { return }
        let parent: AnchorEntity
        if let root = recordedSurfaceRoot { parent = root }
        else {
            parent = AnchorEntity(world: SIMD3<Float>.zero)
            parent.isEnabled = showRecordedSurfaces
            view.scene.addAnchor(parent); recordedSurfaceRoot = parent
        }
        do {
            let container = Entity()
            var fills = [ModelEntity]()
            for group in overlay.groups {
                var descriptor = MeshDescriptor(name: "Recorded LiDAR surface")
                descriptor.positions = MeshBuffers.Positions(group.positions)
                descriptor.primitives = .triangles(group.indices)
                let mesh = try MeshResource.generate(from: [descriptor])
                var material = UnlitMaterial()
                let color: UIColor
                switch group.classification {
                case .ceiling: color = UIColor(red: 0.45, green: 0.72, blue: 1, alpha: 1)
                case .floor: color = UIColor(red: 0.15, green: 0.95, blue: 0.78, alpha: 1)
                case .other: color = UIColor(red: 0.83, green: 1, blue: 0.24, alpha: 1)
                }
                material.color = .init(tint: color)
                material.blending = .transparent(opacity: .init(floatLiteral: 0.55))
                // A local depth mask prevents farther recorded walls showing
                // through foreground surfaces. The translucent color sits 3 mm
                // toward the camera to avoid coincident-depth flicker. Neither
                // derivative transform is used by persistence/export.
                container.addChild(ModelEntity(mesh: mesh, materials: [OcclusionMaterial()]))
                let fill = ModelEntity(mesh: mesh, materials: [material])
                fill.position = LiDAROverlayGeometry.cameraFacingBias(from: overlay.center, toward: camera)
                container.addChild(fill)
                fills.append(fill)
            }
            surfaceOverlays.removeValue(forKey: anchorID)?.entity.removeFromParent()
            parent.addChild(container)
            surfaceOverlays[anchorID] = SurfaceOverlay(entity: container, fills: fills, center: overlay.center,
                triangleCount: overlay.triangleCount, updatedAt: ProcessInfo.processInfo.systemUptime)
            // Nearby surfaces explain the current view; distant geometry remains
            // on disk and can return when ARKit updates that anchor again.
            while surfaceOverlays.count > 36 || surfaceOverlays.values.reduce(0, { $0 + $1.triangleCount }) > 160_000 {
                guard let farthest = surfaceOverlays.filter({ $0.key != anchorID }).max(by: {
                    simd_distance($0.value.center, camera) < simd_distance($1.value.center, camera)
                }) else { break }
                surfaceOverlays.removeValue(forKey: farthest.key)?.entity.removeFromParent()
            }
            publishOverlayMetrics(); overlayIssue = nil
        } catch {
            overlayIssue = "Заливка временно недоступна. Исходная сетка записана: \(error.localizedDescription)"
        }
    }

    private func beginCameraWatchdog() {
        cameraWatchdog?.cancel()
        let ticket = startGeneration
        let startedAt = ProcessInfo.processInfo.systemUptime
        cameraWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.startGeneration == ticket,
                      self.state == .recording || self.isPreviewing else { return }
                guard UIApplication.shared.applicationState == .active else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                let stalled = self.lastFrameAt.map { now - $0 > 5 } ?? (now - startedAt > 8)
                guard stalled else { continue }
                let message = CaptureError.cameraNoFrames.localizedDescription
                self.errorMessage = message
                self.cameraStatus = message
                if self.state == .recording { self.interrupt(reason: message) }
                else { self.suspendPreview(); self.cameraStatus = message }
                return
            }
        }
    }

    private func consume(_ anchors: [ARAnchor]) {
        guard state == .recording, isTrackingNormal,
              let segment = manifest?.segments.last, let writer,
              let runID = cameraLifecycle.currentRunID,
              cameraLifecycle.acceptsRecordedSurface(runID: runID, segmentID: segment.id) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let ticket = meshGeneration
        for anchor in anchors {
            guard meshTasks.count < CaptureCameraLifecycle.maximumPendingSurfaces, let mesh = anchor as? ARMeshAnchor,
                  meshTasks[mesh.identifier] == nil else { continue }
            let interval: TimeInterval = ProcessInfo.processInfo.thermalState == .fair ? 1.5 : 0.75
            guard now - (lastSnapshotTimes[mesh.identifier] ?? -interval) >= interval,
                  let raw = MeshBufferSnapshot.copy(mesh, segmentID: segment.id),
                  let permit = cameraLifecycle.beginSurface(runID: runID, segmentID: segment.id, anchorID: mesh.identifier) else { continue }
            lastSnapshotTimes[mesh.identifier] = now
            let identifier = mesh.identifier
            let processor = meshProcessor
            meshTasks[identifier] = Task { @MainActor [weak self] in
                defer {
                    self?.cameraLifecycle.finishSurface(anchorID: identifier, permit: permit)
                    self?.meshTasks[identifier] = nil
                }
                guard let snapshot = await processor.process(raw), let self,
                      self.meshGeneration == ticket else { return }
                let overlay = await processor.surfaceOverlay(snapshot, classifications: snapshot.classifications,
                    floorCode: UInt8(ARMeshClassification.floor.rawValue), ceilingCode: UInt8(ARMeshClassification.ceiling.rawValue))
                guard self.meshGeneration == ticket else { return }
                let previousSnapshot = self.snapshots.updateValue(snapshot, forKey: identifier)
                self.totalTriangles += snapshot.triangleCount - (previousSnapshot?.triangleCount ?? 0)
                self.totalSurfaceArea += snapshot.areaSquareMeters - (previousSnapshot?.areaSquareMeters ?? 0)
                self.publishMeshMetrics()
                let previous = self.pendingWrite
                let save = Task { @MainActor [weak self] in
                    if let previous { await previous.value }
                    do {
                        try await writer.persist(snapshot)
                        if let self, self.meshGeneration == ticket {
                            self.lastGeometryAt = ProcessInfo.processInfo.systemUptime
                            self.showCommittedSurface(overlay, anchorID: identifier, runID: runID,
                                                      segmentID: segment.id, permit: permit)
                        }
                        if let self, self.meshGeneration == ticket,
                           self.lastCheckpoint.map({ snapshot.updatedAt.timeIntervalSince($0) >= 1 }) ?? true {
                            self.lastCheckpoint = snapshot.updatedAt
                        }
                    } catch {
                        self?.checkpointError = error.localizedDescription
                        self?.errorMessage = "Не удалось записать фрагмент: \(error.localizedDescription)"
                        self?.pause(reason: "Ошибка записи. Освободите место и повторите сохранение")
                    }
                }
                self.pendingWrite = save
                // The four-task limit includes file I/O: mesh processing cannot
                // build an unbounded backlog of encoded checkpoints in RAM.
                await save.value
            }
        }
    }

    private func publishMeshMetrics(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastMetricPublication > 0.35 else { return }
        lastMetricPublication = now
        if anchorCount != snapshots.count { anchorCount = snapshots.count }
        if triangleCount != totalTriangles { triangleCount = totalTriangles }
        let area = max(0, totalSurfaceArea)
        if observedSurfaceArea != area { observedSurfaceArea = area }
    }

    private func updateManifest(status: String) {
        guard var current = manifest, let writer else { return }
        current.status = status; current.updatedAt = Date(); manifest = current
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            if let previous { await previous.value }
            do { try await writer.saveManifest(current) }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }

    private func checkpointAll() {
        guard let writer else { return }
        let currentSnapshots = Array(snapshots.values)
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            if let previous { await previous.value }
            do {
                for snapshot in currentSnapshots { try await writer.persist(snapshot) }
                self?.checkpointError = nil
                self?.lastCheckpoint = Date()
            } catch {
                self?.checkpointError = error.localizedDescription
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func beginSegmentVideo() {
        guard videoEnabled, videoRecorder == nil, let current = manifest,
              let segment = current.segments.last, let directory = captureDirectory else { return }
        let orientation: CaptureVideoOrientation
        switch cameraView?.window?.windowScene?.interfaceOrientation ?? .portrait {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        default: orientation = .portrait
        }
        let identity = CaptureVideoIdentity(captureID: current.id, projectID: current.projectID,
            segmentID: segment.id, frameID: segment.frameID, startedAt: segment.startedAt, orientation: orientation)
        videoStatus = "Ожидаем первый кадр для видео…"
        videoIssue = nil
        videoIsRecording = false
        videoRecorder = CaptureVideoRecorder(identity: identity,
            directory: directory.appendingPathComponent("segments/\(segment.id.uuidString)", isDirectory: true)) { [weak self] message, recording in
                Task { @MainActor [weak self] in
                    guard let self, self.manifest?.id == identity.captureID,
                          self.manifest?.segments.last?.id == identity.segmentID else { return }
                    guard !recording || (self.state == .recording && self.videoRecorder?.identity == identity) else { return }
                    self.videoStatus = message; self.videoIsRecording = recording
                    if message.hasPrefix("Видео не") {
                        self.videoIssue = message
                        self.closeVideo(reason: "videoEncoderFailure")
                    }
                }
            }
    }

    private func closeVideo(reason: String) {
        guard let recorder = videoRecorder else { return }
        videoRecorder = nil; videoIsRecording = false
        videoStatus = "Завершаем видеофайл…"
        let segmentID = recorder.identity.segmentID
        let backgroundLease = CaptureVideoBackgroundLease()
        videoFinishTasks[segmentID] = Task {
            let result = await recorder.finish(reason: reason)
            backgroundLease.end()
            return result
        }
    }

    private func closeCurrentSegment(reason: String) {
        guard var current = manifest, !current.segments.isEmpty else { return }
        let index = current.segments.count - 1
        if current.segments[index].endedAt == nil {
            current.segments[index].endedAt = Date()
            current.segments[index].endReason = reason
            manifest = current
        }
    }

    private func finalizedVideoResults() async -> [CaptureVideoResult] {
        var results: [CaptureVideoResult] = []
        for task in Array(videoFinishTasks.values) { results.append(await task.value) }
        return results
    }

    static func requireCameraAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CaptureError.cameraPermission }
        default: throw CaptureError.cameraPermission
        }
    }

    /// Permission sheets can dismiss before UIKit marks the scene active. Also
    /// wait for SwiftUI to attach and size its renderer instead of running a
    /// camera against a zero-sized, invisible view.
    static func waitForCameraPresentation(_ view: UIView) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if UIApplication.shared.applicationState == .active,
               view.window != nil, view.bounds.width > 1, view.bounds.height > 1 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        if UIApplication.shared.applicationState != .active { throw CaptureError.appInactive }
        throw CaptureError.cameraViewNotReady
    }

    static func preflight(at directory: URL) throws -> (diskBytes: Int64, residentBytes: UInt64) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard available > 512 * 1_024 * 1_024 else { throw CaptureError.lowDisk }
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .critical && thermal != .serious else { throw CaptureError.overheated }
        let resident = residentMemoryBytes()
        // This conservative guard is an early pause, not an estimate of free RAM.
        let budget = max(UInt64(512 * 1_024 * 1_024), ProcessInfo.processInfo.physicalMemory / 4)
        guard resident < budget else { throw CaptureError.lowMemory }
        return (available, resident)
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private static let coordinateNotes = [
        "ARKit right-handed gravity-aligned coordinates; metres; Y is vertical.",
        "Every reset creates an independent local frame. Segment files are not registered with one another.",
        "Optional GeoTag is the operator's device location at observedAt. It does not georegister the AR origin or imply RTK accuracy.",
        "Optional per-segment H.264 video stores the same AR camera imagery with sampled source poses; it is not raw depth or a textured mesh.",
        "No textures, raw depth frames, or watertight reconstruction are implied.",
        "Mesh surface area describes observed triangles; it is not a coverage percentage or survey accuracy."
    ]
}

/// ARSession retains its own callback scheduling. A fresh forwarding delegate
/// gives each run an immutable admission ticket rather than consulting a mutable
/// "currently recording" flag when an older callback finally reaches main.
@MainActor
private final class CaptureSessionDelegate: NSObject, @preconcurrency ARSessionDelegate {
    private weak var owner: CaptureCoordinator?
    private let runID: UUID

    init(owner: CaptureCoordinator, runID: UUID) {
        self.owner = owner; self.runID = runID
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        owner?.session(session, didAdd: anchors, runID: runID)
    }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        owner?.session(session, didUpdate: anchors, runID: runID)
    }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        owner?.session(session, didRemove: anchors, runID: runID)
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        owner?.session(session, didUpdate: frame, runID: runID)
    }
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        owner?.session(session, cameraDidChangeTrackingState: camera, runID: runID)
    }
    func sessionWasInterrupted(_ session: ARSession) {
        owner?.sessionWasInterrupted(session, runID: runID)
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        owner?.sessionInterruptionEnded(session, runID: runID)
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        owner?.session(session, didFailWithError: error, runID: runID)
    }
}

enum CaptureError: LocalizedError {
    case cameraPermission, lowDisk, lowMemory, overheated, noCapture, noSurfaces, invalidCheckpoint
    case checkpointFailed(String)
    case operationInProgress, cameraViewNotReady, cameraNoFrames, appInactive
    case lidarUnsupported, segmentLimit
    var errorDescription: String? {
        switch self {
        case .cameraPermission: "Разрешите доступ к камере в настройках iOS."
        case .lowDisk: "Для безопасной съёмки нужно не менее 512 МБ свободного места."
        case .lowMemory: "Приложение использует много памяти. Сохраните фрагмент и начните следующий."
        case .overheated: "Устройство нагрелось. Дайте ему остыть перед съёмкой."
        case .noCapture: "Сначала начните съёмку."
        case .noSurfaces: "Поверхности ещё не получены. Снимите фактурный объект при хорошем освещении."
        case .invalidCheckpoint: "Повреждён файл геометрии. Сохранившиеся фрагменты остаются на устройстве."
        case let .checkpointFailed(message): "Не удалось сохранить последние данные: \(message)"
        case .operationInProgress: "Дождитесь завершения текущего сохранения."
        case .cameraViewNotReady: "Экран камеры ещё не готов. Вернитесь к съёмке и повторите запуск."
        case .cameraNoFrames: "Камера не передаёт изображение. Закройте другие приложения с камерой и повторите запуск."
        case .appInactive: "Вернитесь в приложение и повторите запуск камеры."
        case .lidarUnsupported: "Продолжить 3D-съёмку можно на устройстве с LiDAR."
        case .segmentLimit: "В съёмке уже 256 фрагментов. Сохраните её и начните новую съёмку."
        }
    }
}

private struct CaptureSegment: Codable, Sendable {
    var id: UUID
    var frameID: UUID
    var startedAt: Date
    var endedAt: Date?
    var endReason: String?
    var geoTag: GeoTag?
}

private struct LiDARCaptureManifest: Codable, Sendable {
    var schemaVersion = 1
    var source = "ARKit.sceneReconstruction"
    var id: UUID
    var projectID: UUID
    var projectName: String
    var createdAt: Date
    var updatedAt: Date
    var status: String
    var segments: [CaptureSegment]
    var deviceModel: String
    var operatingSystem: String
    var availableDiskAtStart: Int64
    var physicalMemoryBytes: UInt64
    var completedAssets: [String]
    var notes: [String]
}

private struct MeshCheckpoint: Codable, Sendable {
    var anchorID: UUID
    var segmentID: UUID
    var updatedAt: Date
    var vertexCount: Int
    var triangleCount: Int
    /// IEEE-754 Float32 XYZ, transformed into this segment's local AR world.
    var positions: Data
    /// UInt32 little-endian triangle indices, zero based.
    var indices: Data
    var areaSquareMeters: Double
    /// Optional original ARMeshClassification bytes, one per source triangle.
    /// Older checkpoints without semantic labels remain readable.
    var classifications: Data? = nil

}

private struct MeshSurfaceOverlay: Sendable {
    enum Classification: Sendable { case floor, ceiling, other }
    struct Group: Sendable {
        var classification: Classification
        var positions: [SIMD3<Float>]
        var indices: [UInt32]
    }
    var groups: [Group]
    var center: SIMD3<Float>
    var triangleCount: Int
}

/// Raw bytes leave ARKit immediately; no ARMeshAnchor or MTLBuffer crosses
/// executors. Copying is bounded per anchor; CPU geometry work happens below.
private struct MeshBufferSnapshot: Sendable {
    let anchorID: UUID
    let segmentID: UUID
    let updatedAt: Date
    let vertexCount: Int
    let vertexStride: Int
    let vertices: Data
    let triangleCount: Int
    let bytesPerIndex: Int
    let faces: Data
    let transform: [Float]
    var classifications: Data? = nil

    @MainActor static func copy(_ anchor: ARMeshAnchor, segmentID: UUID) -> Self? {
        let source = anchor.geometry.vertices
        let faces = anchor.geometry.faces
        guard source.format == .float3, source.count > 0,
              source.count <= 500_000, source.componentsPerVector == 3,
              source.stride >= 12, source.offset >= 0,
              source.offset + (source.count - 1) * source.stride + 12 <= source.buffer.length,
              faces.indexCountPerPrimitive == 3, faces.count > 0, faces.count <= 1_000_000,
              faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4,
              faces.count * 3 * faces.bytesPerIndex <= faces.buffer.length else { return nil }
        let vertexBytes = (source.count - 1) * source.stride + 12
        guard vertexBytes <= 32 * 1_024 * 1_024 else { return nil }
        let matrix = anchor.transform
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        var result = Self(anchorID: anchor.identifier, segmentID: segmentID, updatedAt: Date(),
            vertexCount: source.count, vertexStride: source.stride,
            vertices: Data(bytes: source.buffer.contents().advanced(by: source.offset), count: vertexBytes),
            triangleCount: faces.count, bytesPerIndex: faces.bytesPerIndex,
            faces: Data(bytes: faces.buffer.contents(), count: faces.count * 3 * faces.bytesPerIndex),
            transform: columns.flatMap { [$0.x, $0.y, $0.z, $0.w] })
        if let classification = anchor.geometry.classification,
           classification.format == .uchar, classification.componentsPerVector == 1,
           classification.count >= faces.count, classification.stride == 1,
           classification.offset >= 0, classification.offset + faces.count <= classification.buffer.length {
            result.classifications = Data(bytes: classification.buffer.contents().advanced(by: classification.offset), count: faces.count)
        }
        return result
    }
}

private actor MeshCheckpointProcessor {
    func surfaceOverlay(_ checkpoint: MeshCheckpoint, classifications: Data?, floorCode: UInt8, ceilingCode: UInt8) -> MeshSurfaceOverlay {
        let points: [SIMD3<Float>] = checkpoint.positions.withUnsafeBytes { bytes in
            (0..<checkpoint.vertexCount).map { index in
                let offset = index * 12
                return SIMD3(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))),
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))),
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self))))
            }
        }
        let indices: [UInt32] = checkpoint.indices.withUnsafeBytes { bytes in
            (0..<(checkpoint.triangleCount * 3)).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        let triangles = LiDAROverlayGeometry.filteredTriangles(vertices: points, indices: indices,
            triangleBudget: 8_000, maxEdgeLength: 0.75)
        var byClass = [[Int]](repeating: [], count: 3)
        for triangle in triangles {
            let classification = classifications.flatMap { data in triangle.sourceFaceIndex < data.count ? data[triangle.sourceFaceIndex] : nil }
            let group = classification == floorCode ? 0 : classification == ceilingCode ? 1 : 2
            byClass[group].append(contentsOf: [Int(triangle.indices.x), Int(triangle.indices.y), Int(triangle.indices.z)])
        }
        var groups = [MeshSurfaceOverlay.Group]()
        var minimum = SIMD3<Float>(repeating: .infinity), maximum = SIMD3<Float>(repeating: -.infinity)
        for (index, original) in byClass.enumerated() where !original.isEmpty {
            var positions = [SIMD3<Float>](), compactIndices = [UInt32](), remapping = [Int: UInt32]()
            positions.reserveCapacity(min(original.count, points.count)); compactIndices.reserveCapacity(original.count)
            for oldIndex in original {
                if let existing = remapping[oldIndex] { compactIndices.append(existing); continue }
                let next = UInt32(positions.count), point = points[oldIndex]
                remapping[oldIndex] = next; positions.append(point); compactIndices.append(next)
                minimum = SIMD3(min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
                maximum = SIMD3(max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
            }
            groups.append(.init(classification: index == 0 ? .floor : index == 1 ? .ceiling : .other,
                positions: positions, indices: compactIndices))
        }
        let center = groups.isEmpty ? SIMD3<Float>.zero : (minimum + maximum) * 0.5
        return .init(groups: groups, center: center, triangleCount: triangles.count)
    }

    func process(_ raw: MeshBufferSnapshot) -> MeshCheckpoint? {
        guard raw.vertexCount > 0, raw.vertexCount <= 500_000,
              raw.vertexStride >= 12, raw.vertexStride <= 256,
              raw.vertices.count >= (raw.vertexCount - 1) * raw.vertexStride + 12,
              raw.triangleCount > 0, raw.triangleCount <= 1_000_000,
              raw.bytesPerIndex == 2 || raw.bytesPerIndex == 4,
              raw.faces.count == raw.triangleCount * 3 * raw.bytesPerIndex,
              raw.transform.count == 16, raw.transform.allSatisfy(\.isFinite) else { return nil }
        var points = [SIMD3<Float>]()
        points.reserveCapacity(raw.vertexCount)
        var positions = Data(capacity: raw.vertexCount * 12)
        let m = raw.transform
        let validVertices = raw.vertices.withUnsafeBytes { bytes -> Bool in
            for index in 0..<raw.vertexCount {
                let offset = index * raw.vertexStride
                let x = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let y = bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                let z = bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                let point = SIMD3<Float>(m[0] * x + m[4] * y + m[8] * z + m[12],
                    m[1] * x + m[5] * y + m[9] * z + m[13],
                    m[2] * x + m[6] * y + m[10] * z + m[14])
                guard point.x.isFinite && point.y.isFinite && point.z.isFinite else { return false }
                points.append(point)
                for value in [point.x, point.y, point.z] {
                    var bits = value.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { positions.append(contentsOf: $0) }
                }
            }
            return true
        }
        guard validVertices else { return nil }
        var indices = Data(capacity: raw.triangleCount * 12)
        var area: Double = 0
        let validFaces = raw.faces.withUnsafeBytes { bytes -> Bool in
            for face in 0..<raw.triangleCount {
                var triangle = SIMD3<UInt32>(repeating: 0)
                for corner in 0..<3 {
                    let offset = (face * 3 + corner) * raw.bytesPerIndex
                    let value = raw.bytesPerIndex == 2
                        ? UInt32(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        : bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    guard Int(value) < points.count else { return false }
                    triangle[corner] = value
                    var encoded = value.littleEndian
                    withUnsafeBytes(of: &encoded) { indices.append(contentsOf: $0) }
                }
                let cross = simd_cross(points[Int(triangle.y)] - points[Int(triangle.x)],
                    points[Int(triangle.z)] - points[Int(triangle.x)])
                area += Double(simd_length(cross)) * 0.5
            }
            return area.isFinite
        }
        guard validFaces else { return nil }
        var result = MeshCheckpoint(anchorID: raw.anchorID, segmentID: raw.segmentID, updatedAt: raw.updatedAt,
            vertexCount: raw.vertexCount, triangleCount: raw.triangleCount,
            positions: positions, indices: indices, areaSquareMeters: area)
        if let classifications = raw.classifications, classifications.count == raw.triangleCount {
            result.classifications = classifications
        }
        return result
    }
}

/// Serial actor owns all disk operations. Temporary files and atomic renames
/// ensure a crash leaves the previous completed checkpoint readable.
private actor MeshCheckpointWriter {
    let root: URL
    init(root: URL) { self.root = root }

    func create(manifest: LiDARCaptureManifest) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try saveManifest(manifest)
    }

    func persist(_ snapshot: MeshCheckpoint) throws {
        let directory = root.appendingPathComponent("segments/\(snapshot.segmentID.uuidString)/meshes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(snapshot.anchorID.uuidString).mesh.json")
        try encoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func saveManifest(_ manifest: LiDARCaptureManifest) throws {
        try encoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"),
                                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadManifest() throws -> LiDARCaptureManifest {
        let url = root.appendingPathComponent("manifest.json")
        _ = try CaptureContinuationPolicy.requireFile(url, maximumBytes: 2 * 1_024 * 1_024)
        return try decoder().decode(LiDARCaptureManifest.self, from: Data(contentsOf: url))
    }

    func loadForContinuation(projectID: UUID, outputDirectory: URL) throws -> LiDARCaptureManifest {
        _ = try CaptureContinuationPolicy.validate(at: root.appendingPathComponent("manifest.json"),
            projectID: projectID, outputDirectory: outputDirectory)
        return try loadManifest()
    }

    func finalize(_ input: LiDARCaptureManifest) throws -> LiDARCaptureManifest {
        var result = input
        result.status = "exporting"; result.updatedAt = Date()
        try saveManifest(result)
        var assets = [String]()
        var hasGeometry = false
        var hasVideo = false
        for segment in result.segments {
            let relative = "segments/\(segment.id.uuidString)"
            let directory = root.appendingPathComponent(relative, isDirectory: true)
            let movie = directory.appendingPathComponent("video.mov")
            let sidecar = directory.appendingPathComponent("video.json")
            if FileManager.default.fileExists(atPath: movie.path), FileManager.default.fileExists(atPath: sidecar.path),
               let sidecarSize = try sidecar.resourceValues(forKeys: [.fileSizeKey]).fileSize, sidecarSize <= 16 * 1_024 * 1_024,
               let metadata = try? decoder().decode(CaptureVideoDocument.self, from: Data(contentsOf: sidecar)),
               metadata.isCompleted, metadata.identity.captureID == result.id, metadata.identity.projectID == result.projectID,
               metadata.identity.segmentID == segment.id, metadata.identity.frameID == segment.frameID,
               (try movie.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 {
                assets.append("\(relative)/video.mov"); assets.append("\(relative)/video.json")
                hasVideo = true
            }
            let modelPath = "\(relative)/model.obj"
            if result.completedAssets.contains(modelPath) {
                // Continuation appends independent sources. A completed model
                // from an older day is never regenerated or replaced.
                _ = try CaptureContinuationPolicy.requireFile(directory.appendingPathComponent("model.obj"), maximumBytes: nil)
                assets.append(modelPath); hasGeometry = true
                continue
            }
            let meshes = directory.appendingPathComponent("meshes", isDirectory: true)
            guard FileManager.default.fileExists(atPath: meshes.path) else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: meshes, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".mesh.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else { continue }
            try exportOBJ(from: files, to: directory.appendingPathComponent("model.obj"), frameID: segment.frameID)
            assets.append(modelPath)
            hasGeometry = true
        }
        guard hasGeometry || hasVideo else { throw CaptureError.noSurfaces }
        result.completedAssets = assets
        result.status = "ready"; result.updatedAt = Date()
        try saveManifest(result)
        return result
    }

    private func exportOBJ(from files: [URL], to url: URL, frameID: UUID) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".export-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temp.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: temp)
        var succeeded = false
        defer { try? handle.close(); if !succeeded { try? FileManager.default.removeItem(at: temp) } }
        try handle.write(contentsOf: Data("# Atlas ARKit mesh. metres. Y up. local frame \(frameID.uuidString)\n# Untextured measured surface; not a watertight model.\n".utf8))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var vertexOffset = 1
        for file in files {
            let mesh = try decoder.decode(MeshCheckpoint.self, from: Data(contentsOf: file))
            guard mesh.positions.count == mesh.vertexCount * 12, mesh.indices.count == mesh.triangleCount * 12 else {
                throw CaptureError.invalidCheckpoint
            }
            try handle.write(contentsOf: Data("o anchor_\(mesh.anchorID.uuidString.replacingOccurrences(of: "-", with: "_"))\n".utf8))
            // Stream bounded chunks instead of assembling one enormous string.
            var lines = ""
            for vertex in 0..<mesh.vertexCount {
                let xyz: [Float] = mesh.positions.withUnsafeBytes { bytes in
                    (0..<3).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: vertex * 12 + $0 * 4, as: UInt32.self))) }
                }
                lines += "v \(xyz[0]) \(xyz[1]) \(xyz[2])\n"
                if lines.utf8.count > 64_000 { try handle.write(contentsOf: Data(lines.utf8)); lines.removeAll(keepingCapacity: true) }
            }
            if !lines.isEmpty { try handle.write(contentsOf: Data(lines.utf8)); lines.removeAll(keepingCapacity: true) }
            for face in 0..<mesh.triangleCount {
                let values: [Int] = mesh.indices.withUnsafeBytes { bytes in
                    (0..<3).map { Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: face * 12 + $0 * 4, as: UInt32.self))) }
                }
                guard values.allSatisfy({ $0 < mesh.vertexCount }) else { throw CaptureError.invalidCheckpoint }
                lines += "f \(values[0] + vertexOffset) \(values[1] + vertexOffset) \(values[2] + vertexOffset)\n"
                if lines.utf8.count > 64_000 { try handle.write(contentsOf: Data(lines.utf8)); lines.removeAll(keepingCapacity: true) }
            }
            if !lines.isEmpty { try handle.write(contentsOf: Data(lines.utf8)) }
            vertexOffset += mesh.vertexCount
        }
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: url) }
        succeeded = true
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// iOS grants a short completion window when the user locks or leaves the app.
/// This protects sealing the two queued video frames, not background filming.
@MainActor
private final class CaptureVideoBackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Finish field video") { [weak self] in
            Task { @MainActor [weak self] in self?.end() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        let task = identifier; identifier = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}
