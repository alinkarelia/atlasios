import AtlasCore
import AVFoundation
import Combine
import Foundation
import UIKit
import QuartzCore
@preconcurrency import ARKit
@preconcurrency import RealityKit
import simd

/// Two world-space observations from one AR origin. An interrupted origin is
/// discarded rather than joined to a newly localised one.
@MainActor
final class MeasurementCoordinator: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    enum State: Equatable { case idle, preparing, running, interrupted, unavailable }
    struct Point: Equatable {
        let position: SIMD3<Float>
        let surface: MeasurementSurfaceEvidence
        var metric: MetricPoint3D { .init(x: Double(position.x), y: Double(position.y), z: Double(position.z)) }
        var surfaceTitle: String { surface == .existingPlaneGeometry ? "Обнаруженная поверхность" : "Предполагаемая плоскость" }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var first: Point?
    @Published private(set) var second: Point?
    @Published private(set) var target: Point?
    @Published private(set) var trackingNormal = false
    @Published private(set) var isCameraReady = false
    @Published private(set) var message = "Наведите камеру на поверхность"
    @Published private(set) var issue: String?
    @Published private(set) var frameID = UUID()
    private var cameraView: ARView?
    var arView: ARView {
        if let cameraView { return cameraView }
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session.delegate = self
        // Session callbacks remain on the main queue; ARFrame and Metal-backed
        // geometry never cross actor boundaries.
        view.session.delegateQueue = .main
        cameraView = view
        return view
    }
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    static var usesLiDAR: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }
    static var usesSceneDepth: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    private var generation = UUID()
    private var lastFrameReceived: Date?
    private var lastPreviewTimestamp: TimeInterval = 0
    private var geometryAnchor: AnchorEntity?
    private var subscriptions = Set<AnyCancellable>()
    private var wasTrackingNormal = false
    private var watchdog: Task<Void, Never>?

    override init() {
        super.init()
        if !Self.isSupported { state = .unavailable; message = "AR недоступна на этом устройстве. Введите контрольный размер вручную." }
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    // The first camera permission sheet is temporarily inactive.
                    // Preserve that request; actual background/disappear still
                    // cancels its generation and prevents a late camera start.
                    guard self?.state != .preparing else { return }
                    self?.stop()
                }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }.store(in: &subscriptions)
    }

    func start() async {
        guard Self.isSupported else { state = .unavailable; return }
        guard state != .preparing, state != .running, !Task.isCancelled else { return }
        let ticket = UUID(); generation = ticket
        state = .preparing; issue = nil
        do {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: break
            case .notDetermined:
                guard await AVCaptureDevice.requestAccess(for: .video) else { throw MeasurementCameraError.denied }
            default: throw MeasurementCameraError.denied
            }
            try Task.checkCancellation()
            guard ticket == generation else { return }
            let view = arView
            // iOS can return permission while the scene is still inactive.
            // Also require an attached, sized renderer before starting ARKit.
            try await CaptureCoordinator.waitForCameraPresentation(view)
            try Task.checkCancellation()
            guard ticket == generation else { return }
            discardDraft()
            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.horizontal, .vertical]
            if Self.usesLiDAR { configuration.sceneReconstruction = .mesh }
            if Self.usesSceneDepth { configuration.frameSemantics.insert(.sceneDepth) }
            state = .running
            view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            message = "Медленно двигайте телефон, чтобы обнаружить поверхности"
            startCameraWatchdog(ticket: ticket)
        } catch {
            guard ticket == generation else { return }
            if error is CancellationError { stop() }
            else { state = .idle; issue = error.localizedDescription; message = error.localizedDescription }
        }
    }

    func stop() {
        generation = UUID()
        watchdog?.cancel(); watchdog = nil
        cameraView?.session.pause()
        discardDraft()
        if state != .unavailable { state = .idle }
        message = "AR остановлена. Следующий обмер начнёт новую систему координат."
    }

    func clearPoints() {
        first = nil; second = nil
        removeGeometry()
        message = trackingNormal ? "Наведите прицел на первую точку" : "Дождитесь устойчивого трекинга"
    }

    var canCapturePoint: Bool {
        guard state == .running, trackingNormal, second == nil,
              let received = lastFrameReceived, Date().timeIntervalSince(received) < 0.75 else { return false }
        return target != nil
    }

    func capturePoint() {
        guard state == .running, trackingNormal, second == nil,
              let received = lastFrameReceived, Date().timeIntervalSince(received) < 0.75,
              let frame = arView.session.currentFrame, Self.isFresh(frame), case .normal = frame.camera.trackingState,
              let point = raycastCenter() else {
            target = nil; message = "Точка не найдена. Нужны видимая поверхность и устойчивый трекинг."; return
        }
        if first == nil { first = point; message = "Первая точка сохранена. Наведите на вторую." }
        else { second = point; message = "Две точки готовы. Проверьте результат перед сохранением." }
        rebuildGeometry()
    }

    func record(projectID: UUID, label: String, kind: MeasurementKind) throws -> MeasurementRecord {
        guard let first, let second else { throw MeasurementCameraError.missingPoints }
        return try MeasurementRecord.arRaycast(projectID: projectID, label: label, kind: kind,
            frameID: frameID, start: first.metric, end: second.metric, trackingQuality: .normal,
            surfaceEvidence: [first.surface, second.surface])
    }

    func meters(kind: MeasurementKind, includeLiveTarget: Bool = true) -> Double? {
        guard let first, let end = second ?? (includeLiveTarget && trackingNormal ? target : nil) else { return nil }
        switch kind {
        case .distance: return try? MeasurementGeometry.distance(from: first.metric, to: end.metric)
        case .horizontalDistance: return try? MeasurementGeometry.horizontalDistance(from: first.metric, to: end.metric)
        case .verticalDistance: return try? MeasurementGeometry.verticalDistance(from: first.metric, to: end.metric)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard state == .running else { return }
        guard Self.isFresh(frame) else {
            lastFrameReceived = nil; target = nil; trackingNormal = false
            message = "Кадр камеры устарел. Дождитесь обновления трекинга."
            return
        }
        lastFrameReceived = Date()
        if !isCameraReady { isCameraReady = true }
        // Preserve the full frame rate for tracking, but publish projected
        // points/instructions at most 12.5 times a second.
        guard frame.timestamp - lastPreviewTimestamp >= 0.08 else { return }
        lastPreviewTimestamp = frame.timestamp
        updateTracking(frame.camera.trackingState)
        guard state == .running, trackingNormal, second == nil else { return }
        target = raycastCenter()
        if first == nil {
            let instruction = target.map { "\($0.surfaceTitle). Можно поставить первую точку." } ?? "Наведите прицел на фактурную поверхность"
            if instruction != message { message = instruction }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard state == .running else { return }
        updateTracking(camera.trackingState)
    }
    func sessionWasInterrupted(_ session: ARSession) { interrupt("Сессия прервана. Несохранённые точки сброшены; начните новый обмер.") }
    func session(_ session: ARSession, didFailWithError error: Error) {
        issue = error.localizedDescription
        interrupt("Ошибка AR. Несохранённые точки сброшены; перезапустите обмер.")
    }

    private func updateTracking(_ tracking: ARCamera.TrackingState) {
        switch tracking {
        case .normal:
            if !trackingNormal { trackingNormal = true }
            wasTrackingNormal = true
        case .notAvailable:
            if wasTrackingNormal { interrupt("Трекинг потерян. Точки сброшены; перезапустите обмер.") }
            else { trackingNormal = false; target = nil; message = "Трекинг пока недоступен" }
        case .limited(let reason):
            if wasTrackingNormal {
                interrupt("Трекинг ограничен. Чтобы не смешивать координаты, точки сброшены. Перезапустите обмер.")
            } else {
                trackingNormal = false; target = nil
                switch reason {
                case .initializing: message = "Плавно двигайте телефон для начала трекинга"
                case .excessiveMotion: message = "Двигайтесь медленнее"
                case .insufficientFeatures: message = "Добавьте света и наведите на фактурную поверхность"
                case .relocalizing: message = "Восстановление позиции. Точки пока недоступны."
                @unknown default: message = "Дождитесь устойчивого трекинга"
                }
            }
        }
    }

    private func interrupt(_ reason: String) {
        guard state == .running || state == .preparing else { return }
        generation = UUID()
        watchdog?.cancel(); watchdog = nil
        cameraView?.session.pause(); discardDraft()
        state = .interrupted; message = reason
    }

    private func discardDraft() {
        frameID = UUID(); first = nil; second = nil; target = nil
        trackingNormal = false; wasTrackingNormal = false; isCameraReady = false
        lastFrameReceived = nil; lastPreviewTimestamp = 0
        removeGeometry()
    }

    private func raycastCenter() -> Point? {
        guard arView.bounds.width > 1, arView.bounds.height > 1 else { return nil }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        for (surface, target) in [(MeasurementSurfaceEvidence.existingPlaneGeometry, ARRaycastQuery.Target.existingPlaneGeometry),
                                  (.estimatedPlane, ARRaycastQuery.Target.estimatedPlane)] {
            guard let query = arView.makeRaycastQuery(from: center, allowing: target, alignment: .any),
                  let hit = arView.session.raycast(query).first else { continue }
            let column = hit.worldTransform.columns.3
            let position = SIMD3(column.x, column.y, column.z)
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { continue }
            return Point(position: position, surface: surface)
        }
        return nil
    }

    private static func isFresh(_ frame: ARFrame) -> Bool {
        let age = CACurrentMediaTime() - frame.timestamp
        return age.isFinite && (-0.1...0.5).contains(age)
    }

    private func removeGeometry() {
        if let geometryAnchor { cameraView?.scene.removeAnchor(geometryAnchor) }
        geometryAnchor = nil
    }

    private func startCameraWatchdog(ticket: UUID) {
        watchdog?.cancel()
        let startedAt = Date()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == ticket, self.state == .running else { return }
                let now = Date()
                let stalled = self.lastFrameReceived.map { now.timeIntervalSince($0) > 5 }
                    ?? (now.timeIntervalSince(startedAt) > 8)
                if stalled {
                    let reason = "Кадры камеры не поступают. Проверьте разрешение камеры и перезапустите обмер."
                    self.issue = reason
                    self.interrupt(reason)
                    return
                }
            }
        }
    }

    private func rebuildGeometry() {
        removeGeometry()
        let anchor = AnchorEntity(world: SIMD3<Float>.zero)
        let material = SimpleMaterial(color: UIColor(red: 0.85, green: 1, blue: 0.24, alpha: 1), isMetallic: false)
        for point in [first, second].compactMap({ $0 }) {
            let sphere = ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [material])
            sphere.position = point.position; anchor.addChild(sphere)
        }
        if let first, let second {
            let delta = second.position - first.position
            let length = simd_length(delta)
            if length > 0.0001, length.isFinite {
                // A box line is available on the iOS 17 deployment target;
                // newer procedural primitive APIs are deliberately avoided.
                let line = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.005, length, 0.005)), materials: [material])
                line.position = (first.position + second.position) / 2
                line.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
                anchor.addChild(line)
            }
        }
        arView.scene.addAnchor(anchor); geometryAnchor = anchor
    }
}

private enum MeasurementCameraError: LocalizedError {
    case denied, missingPoints
    var errorDescription: String? {
        switch self {
        case .denied: "Разрешите камеру в настройках iOS или введите размер вручную."
        case .missingPoints: "Сначала поставьте две точки одного обмера."
        }
    }
}
