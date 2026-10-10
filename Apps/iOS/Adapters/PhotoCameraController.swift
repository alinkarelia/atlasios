import Foundation
import Combine
import SwiftUI
import UIKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

/// Photo mode has a real camera session independent of LiDAR and RoomPlan.
/// Only the visible preview uses it; stop() cancels pending photos and releases
/// the camera before a different capture mode starts.
@MainActor
final class PhotoCameraController: NSObject, ObservableObject {
    enum State: Equatable { case idle, preparing, ready, capturing, interrupted, unavailable }
    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var isReady = false

    var session: AVCaptureSession { worker.session }
    private let worker = PhotoSessionWorker()
    private weak var preview: PhotoPreviewUIView?
    private var generation = UUID()
    private var watchdog: Task<Void, Never>?
    private var backgroundObserver: AnyCancellable?

    override init() {
        super.init()
        backgroundObserver = NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
    }

    func prepare() async {
        guard state != .preparing, state != .ready, state != .capturing, !Task.isCancelled else { return }
        let ticket = UUID(); generation = ticket
        state = .preparing; errorMessage = nil; isReady = false
        do {
            try await CaptureCoordinator.requireCameraAccess()
            try Task.checkCancellation()
            guard generation == ticket else { return }
            let view = try await waitForPreview()
            try await CaptureCoordinator.waitForCameraPresentation(view)
            guard generation == ticket else { return }
            try Task.checkCancellation()
            // Also cover startRunning() itself: it can wait on camera services.
            // The timeout lives on the UI actor and never blocks behind that
            // AVFoundation operation on the serial camera queue.
            watchdog = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard let self, self.generation == ticket, !self.isReady else { return }
                self.fail(PhotoCameraError.previewTimeout.localizedDescription)
            }
            try await worker.start(onFirstFrame: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == ticket, self.state == .preparing else { return }
                    self.watchdog?.cancel(); self.watchdog = nil
                    self.isReady = true; self.state = .ready
                }
            }, onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == ticket else { return }
                    self.fail(message)
                }
            })
            // A newer prepare() owns the same serial worker. An old completion
            // must not enqueue a stop against that newer camera session.
            guard generation == ticket else { return }
            try Task.checkCancellation()
            // startRunning() alone never labels the preview ready; the actual
            // first frame callback above is the only transition to .ready.
        } catch {
            guard generation == ticket else { return }
            if error is CancellationError { stop() }
            else { fail(error.localizedDescription) }
        }
    }

    func takePhoto() async throws -> Data {
        guard state == .ready, isReady, UIApplication.shared.applicationState == .active else {
            throw PhotoCameraError.notReady
        }
        let ticket = generation
        let photoID = UUID()
        let rotation = Self.rotationAngle(for: preview?.window?.windowScene?.interfaceOrientation ?? .portrait)
        state = .capturing; errorMessage = nil
        do {
            let data = try await withTaskCancellationHandler {
                try await worker.takePhoto(id: photoID, rotationAngle: rotation)
            } onCancel: { [worker] in
                worker.cancelPhoto(id: photoID)
            }
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            state = .ready
            return data
        } catch {
            if generation == ticket {
                state = isReady ? .ready : .interrupted
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            throw error
        }
    }

    func stop() {
        generation = UUID()
        watchdog?.cancel(); watchdog = nil
        worker.stop()
        isReady = false; state = .idle
    }

    fileprivate func attachPreview(_ view: PhotoPreviewUIView) {
        preview = view
        if view.previewLayer.session !== worker.session { view.previewLayer.session = worker.session }
    }

    private func waitForPreview() async throws -> PhotoPreviewUIView {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let preview { return preview }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PhotoCameraError.previewTimeout
    }

    private func fail(_ message: String) {
        generation = UUID()
        watchdog?.cancel(); watchdog = nil
        worker.stop()
        isReady = false; state = .interrupted; errorMessage = message
    }

    fileprivate static func rotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portrait: 90
        case .portraitUpsideDown: 270
        case .landscapeLeft: 180
        case .landscapeRight: 0
        default: 90
        }
    }
}

struct PhotoCameraPreview: UIViewRepresentable {
    let controller: PhotoCameraController
    func makeUIView(context: Context) -> PhotoPreviewUIView {
        let view = PhotoPreviewUIView()
        controller.attachPreview(view)
        return view
    }
    func updateUIView(_ uiView: PhotoPreviewUIView, context: Context) {
        controller.attachPreview(uiView)
        uiView.updateOrientation()
    }
}

final class PhotoPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() { super.didMoveToWindow(); updateOrientation() }
    override func layoutSubviews() { super.layoutSubviews(); updateOrientation() }
    func updateOrientation() {
        guard let connection = previewLayer.connection else { return }
        let angle = PhotoCameraController.rotationAngle(for: window?.windowScene?.interfaceOrientation ?? .portrait)
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }
}

/// The unchecked boundary is limited to AVFoundation's session owner. Every
/// mutable field and all configuration/start/stop/capture calls live on queue.
/// UIKit only assigns the session reference to its native preview layer.
private final class PhotoSessionWorker: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.atlasfield.photo-session", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let frames = AVCaptureVideoDataOutput()
    private var configured = false
    private var onFirstFrame: (@Sendable () -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var pending: [UUID: PendingPhoto] = [:]
    private struct PendingPhoto {
        let delegate: PhotoFileDelegate
        let continuation: CheckedContinuation<Data, any Error>
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start(onFirstFrame: @escaping @Sendable () -> Void,
               onFailure: @escaping @Sendable (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try configure()
                    self.onFirstFrame = onFirstFrame
                    self.onFailure = onFailure
                    // First-frame detection has no image processing or UI work.
                    frames.setSampleBufferDelegate(self, queue: queue)
                    if !session.isRunning { session.startRunning() }
                    guard session.isRunning else { throw PhotoCameraError.notReady }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            onFirstFrame = nil; onFailure = nil
            frames.setSampleBufferDelegate(nil, queue: nil)
            for request in pending.values { request.continuation.resume(throwing: CancellationError()) }
            pending.removeAll()
            if session.isRunning { session.stopRunning() }
        }
    }

    func takePhoto(id: UUID, rotationAngle: CGFloat) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning, pending.isEmpty else {
                    continuation.resume(throwing: PhotoCameraError.notReady); return
                }
                if let connection = photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.photoQualityPrioritization = .balanced
                let delegate = PhotoFileDelegate { [weak self] result in
                    guard let self else { return }
                    self.queue.async { self.finishPhoto(id: id, result: result) }
                }
                pending[id] = PendingPhoto(delegate: delegate, continuation: continuation)
                photoOutput.capturePhoto(with: settings, delegate: delegate)
                queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                    self?.finishPhoto(id: id, result: .failure(.photoTimeout))
                }
            }
        }
    }

    func cancelPhoto(id: UUID) {
        queue.async { [self] in
            guard let request = pending.removeValue(forKey: id) else { return }
            request.continuation.resume(throwing: CancellationError())
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard CMSampleBufferDataIsReady(sampleBuffer), let callback = onFirstFrame else { return }
        onFirstFrame = nil
        // Remove delivery after the first valid frame. The live preview remains
        // native, without a continuous full-resolution video buffer consumer.
        queue.async { [weak self] in
            guard let self, self.onFirstFrame == nil else { return }
            self.frames.setSampleBufferDelegate(nil, queue: nil)
        }
        callback()
    }

    private func finishPhoto(id: UUID, result: Result<Data, PhotoCameraError>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let request = pending.removeValue(forKey: id) else { return }
        switch result {
        case .success(let data): request.continuation.resume(returning: data)
        case .failure(let error): request.continuation.resume(throwing: error)
        }
    }

    private func configure() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !configured else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw PhotoCameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        guard session.canAddInput(input) else { throw PhotoCameraError.configuration }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else {
            session.removeInput(input); throw PhotoCameraError.configuration
        }
        session.addOutput(photoOutput)
        guard session.canAddOutput(frames) else {
            session.removeOutput(photoOutput); session.removeInput(input)
            throw PhotoCameraError.configuration
        }
        session.addOutput(frames)
        photoOutput.maxPhotoQualityPrioritization = .balanced
        frames.alwaysDiscardsLateVideoFrames = true
        frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        configured = true
        installObservers()
    }

    private func installObservers() {
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
                let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                    ?? "Камера прервана другой задачей. Вернитесь в приложение и перезапустите камеру."
                guard let self else { return }
                self.queue.async { self.onFailure?(detail) }
            })
        }
    }
}

/// AVFoundation owns these callback threads. Only immutable encoded Data and a
/// typed error leave this delegate; the native AVCapturePhoto never crosses an
/// executor. A lock protects callbacks that AVFoundation may deliver separately.
private final class PhotoFileDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, PhotoCameraError>?
    private let completion: @Sendable (Result<Data, PhotoCameraError>) -> Void
    init(completion: @escaping @Sendable (Result<Data, PhotoCameraError>) -> Void) {
        self.completion = completion
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: (any Error)?) {
        let value: Result<Data, PhotoCameraError>
        if let error { value = .failure(.capture(error.localizedDescription)) }
        else if let data = photo.fileDataRepresentation(), !data.isEmpty { value = .success(data) }
        else { value = .failure(.invalidPhoto) }
        lock.lock(); result = value; lock.unlock()
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: (any Error)?) {
        lock.lock(); let stored = result; lock.unlock()
        if let error { completion(.failure(.capture(error.localizedDescription))) }
        else { completion(stored ?? .failure(.invalidPhoto)) }
    }
}

private enum PhotoCameraError: LocalizedError, Sendable {
    case noCamera, configuration, notReady, previewTimeout, photoTimeout, invalidPhoto, capture(String)
    var errorDescription: String? {
        switch self {
        case .noCamera: "Задняя камера недоступна на этом устройстве. Можно импортировать фото из галереи."
        case .configuration: "Не удалось настроить фотокамеру. Закройте другие приложения с камерой и повторите."
        case .notReady: "Дождитесь изображения с камеры перед снимком."
        case .previewTimeout: "Изображение с камеры не поступило. Проверьте разрешение камеры и нажмите «Перезапустить»."
        case .photoTimeout: "Камера не завершила снимок. Попробуйте ещё раз."
        case .invalidPhoto: "Камера не вернула исходный файл фотографии. Повторите снимок."
        case .capture(let message): "Не удалось сделать снимок: \(message)"
        }
    }
}
