import Foundation
import Combine
import CoreLocation
import AtlasCore

/// Foreground-only positioning for capture metadata. A fix identifies where
/// the operator was at its timestamp; it does not register an AR mesh in WGS84.
@MainActor
final class LocationCaptureService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    enum Status: Equatable {
        case stopped, requestingPermission, locating, available, reducedAccuracy
        case stale, denied, restricted, servicesDisabled, temporarilyUnavailable
    }

    @Published private(set) var currentFix: GeoLocationFix?
    @Published private(set) var status: Status = .stopped
    @Published private(set) var statusMessage = "Геометка будет получена во время съёмки"
    @Published private(set) var isActive = false
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    var canOpenSettings: Bool { status == .denied || status == .servicesDisabled || status == .reducedAccuracy }

    private let manager: CLLocationManager
    private var latestAcceptedFix: GeoLocationFix?
    private var transientError = false
    private var clock: AnyCancellable?
    private var requestedPermission = false
    private var servicesEnabled = true
    private var serviceCheckGeneration = UUID()
    private var serviceCheck: Task<Void, Never>?

    override init() {
        manager = CLLocationManager()
        super.init()
        // Like ARSession in CaptureCoordinator, the delegate is installed on
        // the main run loop. CLLocation objects never cross actor boundaries.
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        // Camera activity is already bounded by screen/scene lifecycle. Keep
        // foreground fixes fresh even when the operator scans while stationary.
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
        authorizationStatus = manager.authorizationStatus
    }

    func start() {
        guard !isActive else { startAuthorizedUpdates(); return }
        isActive = true
        transientError = false
        clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshStatus() } }
        startAuthorizedUpdates()
    }

    func stop() {
        manager.stopUpdatingLocation()
        serviceCheckGeneration = UUID()
        serviceCheck?.cancel(); serviceCheck = nil
        clock?.cancel(); clock = nil
        isActive = false
        // "Allow Once" can expire while the same capture view survives. A new
        // foreground collection session must be allowed to request permission.
        requestedPermission = false
        // No location from a previous screen is offered to a new capture.
        latestAcceptedFix = nil; currentFix = nil
        status = .stopped
        statusMessage = "Получение геометки остановлено"
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus != .notDetermined { requestedPermission = false }
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            manager.stopUpdatingLocation()
            latestAcceptedFix = nil; currentFix = nil
        }
        guard isActive else { return }
        startAuthorizedUpdates()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isActive else { return }
        let now = Date()
        for location in locations {
            // Negative accuracy means an invalid CoreLocation measurement.
            // Invalid altitude/vertical accuracy are omitted, not made zero.
            guard CLLocationCoordinate2DIsValid(location.coordinate),
                  location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0 else { continue }
            let verticalValid = location.verticalAccuracy.isFinite && location.verticalAccuracy >= 0
            let fix = GeoLocationFix(
                coordinate: GeographicCoordinate(longitude: location.coordinate.longitude,
                                                  latitude: location.coordinate.latitude),
                altitudeMeters: verticalValid && location.altitude.isFinite ? location.altitude : nil,
                horizontalAccuracyMeters: location.horizontalAccuracy,
                verticalAccuracyMeters: verticalValid ? location.verticalAccuracy : nil,
                observedAt: location.timestamp, source: .deviceLocation,
                isSimulated: location.sourceInformation?.isSimulatedBySoftware ?? false)
            guard GeoTagPolicy.acceptDeviceFix(fix, now: now) else { continue }
            latestAcceptedFix = GeoTagPolicy.bestAutomatic(current: latestAcceptedFix, candidate: fix, now: now)
            transientError = false
        }
        refreshStatus(now: now)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isActive else { return }
        transientError = true
        refreshStatus()
    }

    private func startAuthorizedUpdates() {
        authorizationStatus = manager.authorizationStatus
        let generation = UUID()
        serviceCheckGeneration = generation
        serviceCheck?.cancel()
        // The system-wide query may perform synchronous IPC. Keep it off the
        // camera/UI actor, and cache the answer rather than querying every tick.
        serviceCheck = Task { [weak self] in
            let enabled = await Task.detached(priority: .utility) {
                CLLocationManager.locationServicesEnabled()
            }.value
            guard !Task.isCancelled, let self, self.isActive,
                  self.serviceCheckGeneration == generation else { return }
            self.servicesEnabled = enabled
            self.applyAuthorizedUpdates()
        }
        refreshStatus()
    }

    private func applyAuthorizedUpdates() {
        authorizationStatus = manager.authorizationStatus
        guard servicesEnabled else {
            manager.stopUpdatingLocation()
            refreshStatus(); return
        }
        switch authorizationStatus {
        case .notDetermined:
            if !requestedPermission {
                requestedPermission = true
                manager.requestWhenInUseAuthorization()
            }
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            latestAcceptedFix = nil; currentFix = nil
        @unknown default:
            manager.stopUpdatingLocation()
            latestAcceptedFix = nil; currentFix = nil
        }
        refreshStatus()
    }

    private func refreshStatus(now: Date = Date()) {
        guard isActive else { return }
        authorizationStatus = manager.authorizationStatus
        guard servicesEnabled else {
            currentFix = nil; status = .servicesDisabled
            statusMessage = "Геолокация выключена. Съёмка продолжится без автоматической метки."
            return
        }
        switch authorizationStatus {
        case .notDetermined:
            currentFix = nil; status = .requestingPermission
            statusMessage = "Ожидаем разрешение геолокации. Съёмка доступна без него."
            return
        case .denied:
            currentFix = nil; status = .denied
            statusMessage = "Доступ к геолокации закрыт. Геометку можно добавить вручную."
            return
        case .restricted:
            currentFix = nil; status = .restricted
            statusMessage = "Геолокация ограничена настройками устройства. Геометка доступна вручную."
            return
        case .authorizedWhenInUse, .authorizedAlways: break
        @unknown default:
            currentFix = nil; status = .temporarilyUnavailable
            statusMessage = "Геолокация недоступна. Съёмка продолжится без метки."
            return
        }
        if let fix = latestAcceptedFix, GeoTagPolicy.acceptDeviceFix(fix, now: now) {
            currentFix = fix
            let accuracy = fix.horizontalAccuracyMeters.map { "±\($0.formatted(.number.precision(.fractionLength(1)))) м" } ?? "точность неизвестна"
            if fix.isSimulated {
                status = .available
                statusMessage = "Тестовое положение · \(accuracy)"
            } else if manager.accuracyAuthorization == .reducedAccuracy {
                status = .reducedAccuracy
                statusMessage = "Приблизительное положение · \(accuracy)"
            } else {
                status = .available
                statusMessage = "Геометка автоматически · \(accuracy)"
            }
        } else {
            currentFix = nil
            if latestAcceptedFix != nil {
                status = .stale
                statusMessage = "Обновляем положение: предыдущая точка старше 20 секунд."
            } else if transientError {
                status = .temporarilyUnavailable
                statusMessage = "Положение временно недоступно. Съёмка продолжится."
            } else {
                status = manager.accuracyAuthorization == .reducedAccuracy ? .reducedAccuracy : .locating
                statusMessage = "Определяем положение. Геометка появится автоматически."
            }
        }
    }
}
