import Foundation
import Combine
import CoreLocation
import AtlasCore

private struct SurveyCheckpoint: Codable, Sendable {
    let version: Int
    let projectID: UUID
    let session: CemeterySurveySession
}

private enum SurveyCheckpointError: LocalizedError {
    case tooLarge
    var errorDescription: String? {
        "GPS-журнал превышает 16 МБ. Запись остановлена; предыдущее сохранение осталось без изменений."
    }
}

@MainActor
private final class SurveyWeakReference<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Serialized, atomic checkpoints retain the raw journal; display geometry is not the journal.
private actor SurveyCheckpointStore {
    static let maximumCheckpointBytes = 16 * 1_024 * 1_024
    let projectID: UUID
    let directory: URL
    private var loaded = false
    private var current: CemeterySurveySession?

    init(projectID: UUID, directory: URL) { self.projectID = projectID; self.directory = directory }
    private var activeURL: URL { directory.appendingPathComponent(projectID.uuidString + ".json") }

    func load() throws -> CemeterySurveySession? {
        if loaded { return current }
        guard FileManager.default.fileExists(atPath: activeURL.path) else { loaded = true; return nil }
        let size = try activeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumCheckpointBytes else { throw SurveyCheckpointError.tooLarge }
        let checkpoint = try JSONDecoder().decode(SurveyCheckpoint.self, from: Data(contentsOf: activeURL))
        guard checkpoint.version == 1, checkpoint.projectID == projectID else { throw CemeterySurveyError.invalidCheckpoint }
        try checkpoint.session.validateCheckpoint()
        current = checkpoint.session; loaded = true
        return current
    }

    func save(_ session: CemeterySurveySession, generation _: UInt64, replacing previous: CemeterySurveySession? = nil) throws {
        if let saved = try load() {
            if saved.id != session.id {
                // A new track replaces exactly the stopped session the operator reviewed.
                guard previous == saved, saved.state == .stopped, session.state == .recording, session.journal.isEmpty else {
                    throw CemeterySurveyError.invalidCheckpoint
                }
            } else {
                // A delayed screen/checkpoint cannot truncate or fork a raw journal.
                if session.journal.count < saved.journal.count { return }
                guard Array(session.journal.prefix(saved.journal.count)) == saved.journal else {
                    throw CemeterySurveyError.invalidCheckpoint
                }
            }
        } else if previous != nil { throw CemeterySurveyError.invalidCheckpoint }
        let checkpoint = SurveyCheckpoint(version: 1, projectID: projectID, session: session)
        let data = try JSONEncoder().encode(checkpoint)
        guard data.count <= Self.maximumCheckpointBytes else { throw SurveyCheckpointError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: activeURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        current = session; loaded = true
    }

    func archive(_ session: CemeterySurveySession) throws {
        let url = directory.appendingPathComponent(projectID.uuidString + "-" + session.id.uuidString + ".json")
        // An existing archive is immutable and must describe the same complete journal.
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumCheckpointBytes else { throw SurveyCheckpointError.tooLarge }
            let saved = try JSONDecoder().decode(SurveyCheckpoint.self, from: Data(contentsOf: url))
            guard saved.projectID == projectID, saved.session == session else { throw CemeterySurveyError.invalidCheckpoint }
            return
        }
        let data = try JSONEncoder().encode(SurveyCheckpoint(version: 1, projectID: projectID, session: session))
        guard data.count <= Self.maximumCheckpointBytes else { throw SurveyCheckpointError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

/// Only foreground WGS84 observations. No AR-to-map alignment or centimetre accuracy is implied.
@MainActor
final class SurveyLocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    private static var services: [String: SurveyWeakReference<SurveyLocationService>] = [:]
    private static var stores: [String: SurveyWeakReference<SurveyCheckpointStore>] = [:]

    static func shared(projectID: UUID, draftDirectory: URL) -> SurveyLocationService {
        let key = draftDirectory.standardizedFileURL.appendingPathComponent(projectID.uuidString).path
        if let existing = services[key]?.value { return existing }
        services = services.filter { $0.value.value != nil }
        let created = SurveyLocationService(projectID: projectID, draftDirectory: draftDirectory)
        services[key] = SurveyWeakReference(created)
        return created
    }
    @Published private(set) var session: CemeterySurveySession? { didSet { updateJournalSummary() } }
    @Published private(set) var segments: [CemeterySurveySegment] = []
    @Published private(set) var acceptedCount = 0
    @Published private(set) var rejectedCount = 0
    @Published private(set) var fix: GeoLocationFix?
    @Published private(set) var issue: String?
    @Published private(set) var statusMessage = "Положение запрашивается по кнопке"
    @Published private(set) var storageMessage = "Исходный GPS-журнал сохраняется на iPhone"
    @Published private(set) var recenterRequested = false
    @Published private(set) var hasLocationActivity = false
    @Published private(set) var now = Date()
    @Published private(set) var restoring = false
    @Published private(set) var starting = false
    @Published private(set) var confirmingBoundary = false

    var isRecording: Bool { session?.state == .recording }
    var canStart: Bool { !restoreFailed && !restoring && !starting && !confirmingBoundary && (session == nil || session?.state == .stopped) }
    var elapsed: TimeInterval { (try? session?.activeDuration(at: now)) ?? 0 }
    var canOpenSettings: Bool {
        manager.authorizationStatus == .denied || !servicesEnabled || manager.accuracyAuthorization == .reducedAccuracy
    }
    var lastRejection: String? {
        guard let reason = lastRejectionReason else { return nil }
        switch reason {
        case .invalidCoordinate: return "Некорректные координаты"
        case .invalidAccuracy, .invalidAltitude: return "Некорректные данные датчика"
        case .stale: return "Устаревшая точка"
        case .future, .outOfOrder: return "Нарушен порядок времени"
        case .insufficientAccuracy: return "Точность хуже 10 м"
        case .simulated: return "Программно заданное положение"
        case .paused: return "Съёмка на паузе"
        case .stopped: return "Съёмка завершена"
        case .jump: return "Скачок координат"
        }
    }

    private let manager = CLLocationManager()
    private let store: SurveyCheckpointStore
    private var clock: AnyCancellable?
    private var authorizationTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var locateTimeout: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var authorizationGeneration = UUID()
    private var permissionRequested = false
    private var servicesEnabled = true
    private var restored = false
    private var restoreFailed = false
    private var visibilityGeneration = UUID()
    private var lastRejectionReason: CemeterySurveyRejection?

    init(projectID: UUID, draftDirectory: URL) {
        let key = draftDirectory.standardizedFileURL.appendingPathComponent(projectID.uuidString).path
        if let existing = Self.stores[key]?.value { store = existing }
        else {
            Self.stores = Self.stores.filter { $0.value.value != nil }
            let created = SurveyCheckpointStore(projectID: projectID, directory: draftDirectory)
            Self.stores[key] = SurveyWeakReference(created); store = created
        }
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 1
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
    }

    func restoreDraft() async {
        guard !restored, !restoring else { return }
        restoring = true
        defer { restoring = false; restored = true }
        do {
            guard var restoredSession = try await store.load() else { return }
            // A terminated foreground session cannot resume across an unseen route.
            if restoredSession.state == .recording {
                // The interval since the last durable observation is unobserved, not recording time.
                let interruption = restoredSession.journal.last.map { entry -> Date in
                    switch entry {
                    case let .observation(value): value.receivedAt
                    case let .paused(value), let .resumed(value), let .stopped(value): value
                    case let .boundaryConfirmed(value): value.confirmedAt
                    }
                } ?? restoredSession.startedAt
                do { try restoredSession.pause(at: interruption) }
                catch CemeterySurveyError.capacityReached { try restoredSession.stop(at: interruption) }
            }
            session = restoredSession
            now = Date()
            generation += 1
            try await store.save(restoredSession, generation: generation)
            storageMessage = "GPS-черновик восстановлен. Продолжение — только вручную."
        } catch {
            restoreFailed = true
            issue = "GPS-черновик не открыт: \(error.localizedDescription) Исходный файл сохранён без изменений."
            storageMessage = "Не удалось проверить GPS-черновик"
        }
    }

    func start() async {
        guard canStart else { return }
        starting = true
        let visibility = visibilityGeneration
        defer { starting = false }
        do {
            let previous = session
            if let previous {
                generation += 1
                try await store.save(previous, generation: generation)
                try await store.archive(previous)
            }
            guard visibilityGeneration == visibility else { return }
            let created = try CemeterySurveySession()
            generation += 1
            try await store.save(created, generation: generation, replacing: previous)
            session = created; issue = nil; now = Date()
            storageMessage = "GPS-журнал сохранён на iPhone"
            guard visibilityGeneration == visibility else { pause(); return }
            activateLocation()
        } catch { issue = error.localizedDescription }
    }

    func pause() {
        guard var current = session, current.state == .recording else { return }
        do { try current.pause(); session = current }
        catch { haltOnJournalError(error, current: &current) }
        stopSensor(); checkpoint(immediately: true)
    }

    func resume() {
        guard !starting, !confirmingBoundary, var current = session, current.state == .paused else { return }
        do { try current.resume(); session = current; issue = nil; activateLocation(); checkpoint(immediately: true) }
        catch { haltOnJournalError(error, current: &current) }
    }

    func stop() {
        guard !confirmingBoundary, var current = session, current.state != .stopped else { return }
        do { try current.stop(); session = current }
        catch { issue = error.localizedDescription }
        stopSensor(); checkpoint(immediately: true)
    }

    func locate() {
        issue = nil; recenterRequested = true; fix = nil
        activateLocation()
        locateTimeout?.cancel()
        locateTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.recenterRequested else { return }
            self.recenterRequested = false
            self.issue = "Не удалось получить свежее положение. Выйдите на открытое место и попробуйте снова."
            if !self.isRecording { self.stopSensor() }
        }
    }

    func didRecenter() {
        recenterRequested = false; locateTimeout?.cancel(); locateTimeout = nil
        if !isRecording { stopSensor() }
    }

    func leaveScreen() {
        visibilityGeneration = UUID()
        if isRecording { pause() } else { stopSensor(); checkpoint(immediately: true) }
        fix = nil; clock?.cancel(); clock = nil
        recenterRequested = false; locateTimeout?.cancel(); locateTimeout = nil
    }

    func makeLine(segmentID: UUID) throws -> GeographicPolyline {
        guard let session else { throw CemeterySurveyError.segmentNotFound }
        return try session.makePolyline(segmentID: segmentID)
    }

    func confirmBoundary(segmentID: UUID) async throws -> CemeterySurveyBoundary {
        guard !starting, !confirmingBoundary, var current = session, current.state != .recording else { throw CemeterySurveyError.invalidState }
        confirmingBoundary = true
        defer { confirmingBoundary = false }
        let boundary = try current.confirmBoundary(segmentID: segmentID)
        // Persist the explicit confirmation before handing geometry to a card.
        generation += 1
        try await store.save(current, generation: generation)
        session = current
        storageMessage = "Подтверждение контура сохранено вместе с исходным журналом"
        return boundary
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined { permissionRequested = false }
        guard hasLocationActivity else { return }
        applyAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard hasLocationActivity else { return }
        let received = Date()
        var current = session
        for location in locations {
            let coordinate = GeographicCoordinate(longitude: location.coordinate.longitude, latitude: location.coordinate.latitude)
            let verticalValid = location.verticalAccuracy.isFinite && location.verticalAccuracy >= 0
            let altitude = verticalValid && location.altitude.isFinite ? location.altitude : nil
            let simulated = location.sourceInformation?.isSimulatedBySoftware ?? false
            let observed = GeoLocationFix(coordinate: coordinate, altitudeMeters: altitude,
                horizontalAccuracyMeters: location.horizontalAccuracy,
                verticalAccuracyMeters: verticalValid ? location.verticalAccuracy : nil,
                observedAt: location.timestamp, source: .deviceLocation, isSimulated: simulated)
            if GeoTagPolicy.acceptDeviceFix(observed, now: received, maximumAge: 5) { fix = observed }
            if var journal = current, journal.state == .recording {
                let sample = CemeterySurveySample(coordinate: coordinate, capturedAt: location.timestamp,
                    horizontalAccuracyMeters: location.horizontalAccuracy, altitudeMeters: altitude, isSimulated: simulated)
                do { try journal.record(sample, receivedAt: received); current = journal }
                catch {
                    haltOnJournalError(error, current: &journal)
                    current = journal; break
                }
            }
        }
        session = current; now = received; updateStatus()
        if isRecording || current?.state == .stopped { checkpoint(immediately: false) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard hasLocationActivity else { return }
        issue = "GPS временно недоступен. \(error.localizedDescription)"
        if isRecording { pause() }
        else { stopSensor() }
        statusMessage = "Положение недоступно — маршрут не соединяется через пропуск"
    }

    private func activateLocation() {
        hasLocationActivity = true; now = Date()
        if clock == nil {
            clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        }
        authorizationGeneration = UUID()
        let ticket = authorizationGeneration
        authorizationTask?.cancel()
        authorizationTask = Task { [weak self] in
            let enabled = await Task.detached(priority: .utility) { CLLocationManager.locationServicesEnabled() }.value
            guard !Task.isCancelled, let self, self.hasLocationActivity, self.authorizationGeneration == ticket else { return }
            self.servicesEnabled = enabled; self.applyAuthorization()
        }
        statusMessage = "Определяем свежее положение…"
    }

    private func applyAuthorization() {
        guard servicesEnabled else {
            issue = "Службы геолокации выключены. Включите их в настройках iPhone."
            if isRecording { pause() } else { stopSensor() }; return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            if !permissionRequested { permissionRequested = true; manager.requestWhenInUseAuthorization() }
            statusMessage = "Разрешите геолокацию при использовании приложения"
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation(); updateStatus()
        case .denied, .restricted:
            issue = "Доступ к геолокации закрыт. Разрешите его в настройках или задайте координаты вручную."
            if isRecording { pause() } else { stopSensor() }
        @unknown default:
            issue = "Геолокация недоступна"
            if isRecording { pause() } else { stopSensor() }
        }
    }

    private func stopSensor() {
        manager.stopUpdatingLocation(); hasLocationActivity = false
        authorizationGeneration = UUID(); authorizationTask?.cancel(); authorizationTask = nil
        // A displayed position expires even after a one-shot recenter has stopped the sensor.
        if fix == nil { clock?.cancel(); clock = nil }
        permissionRequested = false; now = Date()
        recenterRequested = false; locateTimeout?.cancel(); locateTimeout = nil
    }

    private func tick() {
        now = Date()
        if let fix, !GeoTagPolicy.acceptDeviceFix(fix, now: now, maximumAge: 5) { self.fix = nil }
        updateStatus()
        if !hasLocationActivity && fix == nil { clock?.cancel(); clock = nil }
    }

    private func updateStatus() {
        if let fix, let accuracy = fix.horizontalAccuracyMeters {
            let prefix = fix.isSimulated ? "Тестовое положение" : (manager.accuracyAuthorization == .reducedAccuracy ? "Приблизительное положение" : "Положение")
            statusMessage = prefix + " · ±" + accuracy.formatted(.number.precision(.fractionLength(1))) + " м"
        } else if hasLocationActivity { statusMessage = "Ожидаем свежий GPS-сигнал…" }
        else if session?.state == .paused { statusMessage = "Пауза. Продолжение создаст отдельный отрезок." }
        else if session?.state == .stopped { statusMessage = "GPS-съёмка завершена. Проверьте отдельные отрезки." }
    }

    private func updateJournalSummary() {
        let observations = session?.observations ?? []
        acceptedCount = observations.reduce(0) { $0 + ($1.decision.status == .accepted ? 1 : 0) }
        rejectedCount = observations.count - acceptedCount
        lastRejectionReason = observations.last?.decision.rejectionReason
        segments = session?.segments ?? []
    }

    private func haltOnJournalError(_ error: Error, current: inout CemeterySurveySession) {
        try? current.stop()
        session = current; issue = error.localizedDescription
        stopSensor(); checkpoint(immediately: true)
    }

    private func checkpoint(immediately: Bool) {
        checkpointTask?.cancel()
        guard let snapshot = session else { return }
        generation += 1
        let ticket = generation, store = store
        storageMessage = "Сохраняем исходный GPS-журнал…"
        checkpointTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            do {
                try await store.save(snapshot, generation: ticket)
                guard let self, self.generation == ticket else { return }
                self.storageMessage = "GPS-журнал сохранён на iPhone"
            } catch {
                guard let self, self.generation == ticket else { return }
                self.issue = "GPS-журнал не сохранён: \(error.localizedDescription)"
                self.storageMessage = "Ошибка записи GPS-журнала"
                // Stop collecting rather than imply raw observations are durably stored.
                if self.isRecording { self.pause() }
            }
        }
    }
}
