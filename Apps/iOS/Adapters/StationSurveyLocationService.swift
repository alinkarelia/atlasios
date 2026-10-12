import Foundation
import Combine
import CoreLocation
import AtlasCore

@MainActor
final class StationSurveyLocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    private final class Weak { weak var value: StationSurveyLocationService?; init(_ value: StationSurveyLocationService) { self.value = value } }
    private static var instances: [String: Weak] = [:]
    static func shared(project: AtlasProject, directory: URL) -> StationSurveyLocationService {
        let key = directory.standardizedFileURL.appendingPathComponent(project.id.uuidString).path
        if let existing = instances[key]?.value { return existing }
        instances = instances.filter { $0.value.value != nil }
        let service = StationSurveyLocationService(project: project, directory: directory)
        instances[key] = Weak(service); return service
    }
    @Published private(set) var document: StationSurvey
    @Published private(set) var activeStationID: UUID?
    @Published private(set) var elapsed = 0.0
    @Published private(set) var issue: String?
    @Published private(set) var storageMessage = "Открываем точечную съёмку…"
    @Published private(set) var ready = false
    @Published private(set) var saving = false
    @Published private(set) var starting = false
    private let manager = CLLocationManager()
    private let store: StationSurveyStore
    private var clock: AnyCancellable?
    private var completion: Task<Void, Never>?
    private var checkpoint: Task<Void, Never>?
    private var checkpointGeneration: UUID?
    private var dirty = false
    private var loaded = false
    private var waitingStationID: UUID?
    private var startGeneration: UUID?
    private var persistenceIssue: String?
    private var persistenceWaiters: [CheckedContinuation<Bool, Never>] = []
    var activeAttempt: StationSurveyAttempt? { document.stations.first { $0.id == activeStationID }?.attempts.last }
    var isCollecting: Bool { activeStationID != nil }

    private init(project: AtlasProject, directory: URL) {
        document = StationSurvey(projectID: project.id, coordinateReference: project.coordinateReference)
        store = StationSurveyStore(projectID: project.id, reference: project.coordinateReference, directory: directory)
        super.init()
        manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone; manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false; manager.allowsBackgroundLocationUpdates = false
    }
    func restore() async {
        guard !loaded else { return }; loaded = true
        do {
            if var saved = try await store.load() {
                for station in saved.stations where station.attempts.last?.state == .collecting {
                    try saved.finishGPS(stationID: station.id, cancelled: true)
                }
                document = saved
            }
            ready = true; dirty = true; await persist()
        } catch { issue = "Съёмка не открыта: \(error.localizedDescription). Исходный файл не изменён."; ready = false; loaded = false }
    }
    @discardableResult func addStation() async -> UUID? {
        guard ready, !isCollecting, !starting else { return nil }
        do { let id = try document.addStation(); dirty = true; return await persist() ? id : nil }
        catch { issue = error.localizedDescription; return nil }
    }
    func enter(stationID: UUID, position: FeatureGeometry, reason: String) async -> Bool {
        guard ready, !isCollecting, !starting else { return false }
        do { try document.enter(stationID: stationID, position: position, reason: reason); dirty = true; return await persist() }
        catch { issue = error.localizedDescription; return false }
    }
    func include(stationID: UUID, value: Bool) async {
        guard ready, !isCollecting, !starting else { return }
        do { try document.include(stationID: stationID, value: value); dirty = true; await persist() }
        catch { issue = error.localizedDescription }
    }
    func start(stationID: UUID) async {
        guard ready, !isCollecting, !starting else { return }
        guard document.coordinateReference == .wgs84 else { issue = StationSurveyError.localGPS.localizedDescription; return }
        let generation = UUID(); startGeneration = generation; starting = true
        defer { if startGeneration == generation { starting = false } }
        switch manager.authorizationStatus {
        case .notDetermined: waitingStationID = stationID; manager.requestWhenInUseAuthorization(); return
        case .denied, .restricted: issue = "Разрешите геолокацию в настройках iPhone."; return
        default: break
        }
        let enabled = await Task.detached(priority: .utility) { CLLocationManager.locationServicesEnabled() }.value
        guard startGeneration == generation, ready, !isCollecting else { return }
        guard enabled else { issue = "Службы геолокации выключены."; return }
        issue = nil
        do {
            _ = try document.beginGPS(stationID: stationID); activeStationID = stationID; elapsed = 0
            dirty = true
            guard await persist() else { await finish(cancelled: true); return }
            guard startGeneration == generation, activeStationID == stationID else { return }
            activate()
        } catch { issue = error.localizedDescription }
    }
    private func activate() {
        guard isCollecting else { return }
        manager.startUpdatingLocation()
        clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let attempt = self.activeAttempt else { return }
                self.elapsed = max(0, Date().timeIntervalSince(attempt.startedAt))
            }
        }
        completion?.cancel()
        completion = Task { [weak self] in
            guard let self, let attempt = self.activeAttempt else { return }
            let remaining = max(0, StationSurveyAttempt.durationSeconds - Date().timeIntervalSince(attempt.startedAt))
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            await self.finish()
        }
    }
    func finish(cancelled: Bool = false) async {
        guard let id = activeStationID else { return }
        manager.stopUpdatingLocation(); clock?.cancel(); clock = nil
        completion?.cancel(); completion = nil; checkpoint?.cancel(); checkpoint = nil; checkpointGeneration = nil
        activeStationID = nil
        do { try document.finishGPS(stationID: id, cancelled: cancelled); dirty = true; await persist() }
        catch { issue = error.localizedDescription }
    }
    func leave() { startGeneration = nil; starting = false; waitingStationID = nil; Task { await finish(cancelled: true) } }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if let pending = waitingStationID, manager.authorizationStatus != .notDetermined {
            let generation = startGeneration
            waitingStationID = nil
            Task { guard generation != nil, startGeneration == generation else { return }; await start(stationID: pending) }
            return
        }
        guard isCollecting else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: activate()
        case .denied, .restricted: issue = "Геолокация недоступна. Наблюдение отменено, исходные точки сохранены."; leave()
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let id = activeStationID else { return }
        let received = Date()
        for location in locations {
            let sample = CemeterySurveySample(coordinate: GeographicCoordinate(longitude: location.coordinate.longitude, latitude: location.coordinate.latitude),
                capturedAt: location.timestamp, horizontalAccuracyMeters: location.horizontalAccuracy,
                altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
                isSimulated: location.sourceInformation?.isSimulatedBySoftware ?? false)
            do {
                try document.updateGPS(stationID: id, sample: sample, receivedAt: received); dirty = true
                storageMessage = "Новые GPS-фиксы ожидают записи на iPhone"
            }
            catch { issue = error.localizedDescription; leave(); break }
        }
        guard checkpoint == nil else { return }
        let generation = UUID(); checkpointGeneration = generation
        checkpoint = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await self?.persist()
            if self?.checkpointGeneration == generation { self?.checkpoint = nil; self?.checkpointGeneration = nil }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        issue = "GPS недоступен: \(error.localizedDescription)"; leave()
    }
    @discardableResult func persist() async -> Bool {
        guard ready else { return false }
        if saving { return await withCheckedContinuation { persistenceWaiters.append($0) } }
        saving = true
        var successful = false
        defer {
            saving = false
            let waiters = persistenceWaiters; persistenceWaiters = []
            for waiter in waiters { waiter.resume(returning: successful) }
        }
        do {
            while dirty {
                dirty = false
                let snapshot = document
                let saved = try await store.save(snapshot)
                document.revision = saved.revision
            }
            storageMessage = "Точки и исходные наблюдения сохранены на iPhone"
            if issue == persistenceIssue { issue = nil }
            persistenceIssue = nil; successful = true
            return true
        } catch {
            dirty = true; persistenceIssue = "Съёмка не сохранена: \(error.localizedDescription)"; issue = persistenceIssue
            storageMessage = "Ошибка записи — предыдущий файл сохранён"
            if let id = activeStationID {
                manager.stopUpdatingLocation(); clock?.cancel(); completion?.cancel()
                try? document.finishGPS(stationID: id, cancelled: true)
                activeStationID = nil
            }
            return false
        }
    }
}
