import Foundation
import Combine
import CoreLocation
import UIKit
import AtlasCore

/// GNSS/compass guidance is independent of scan registration and never marks
/// a visited cell as scanned. A bearing is not a pedestrian route.
@MainActor
final class CollaborativeGuidanceService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    struct Fix: Sendable {
        let coordinate: GeographicCoordinate
        let accuracyMeters: Double
        let capturedAt: Date
    }
    struct Direction: Sendable {
        let distanceMeters: Double
        let trueBearingDegrees: Double
        let relativeDegrees: Double?
    }
    @Published private(set) var fix: Fix?
    @Published private(set) var issue: String?
    @Published private(set) var running = false
    @Published private(set) var now = Date()
    let compass = CompassService()
    private let manager = CLLocationManager()
    private var clock: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = false
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }.store(in: &subscriptions)
        compass.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    var usableFix: Fix? {
        guard let fix, (-2...8).contains(now.timeIntervalSince(fix.capturedAt)), fix.accuracyMeters <= 25 else { return nil }
        return fix
    }
    var usableHeading: CompassService.Reading? {
        guard let reading = compass.reading, reading.isTrueNorth,
              reading.accuracyDegrees <= 20,
              (-2...5).contains(now.timeIntervalSince(reading.observedAt)) else { return nil }
        return reading
    }

    func start() {
        guard !running, UIApplication.shared.applicationState == .active else { return }
        running = true; fix = nil; issue = nil; now = Date()
        clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] value in
            MainActor.assumeIsolated { self?.now = value }
        }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: activate()
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .restricted, .denied: issue = "Разрешите геопозицию для направления к участку. План остаётся доступен без GPS."
        @unknown default: issue = "Геопозиция недоступна."
        }
    }
    private func activate() {
        guard running else { return }
        manager.startUpdatingLocation(); compass.start()
    }
    func stop() {
        manager.stopUpdatingLocation(); compass.stop(); clock?.cancel(); clock = nil
        running = false; fix = nil; now = Date()
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard running else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: issue = nil; activate()
        case .restricted, .denied:
            self.manager.stopUpdatingLocation(); compass.stop(); fix = nil
            issue = "Геопозиция отключена. Стрелка скрыта; карта и задания сохранены."
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard running else { return }
        now = Date()
        guard let location = locations.last(where: {
            $0.coordinate.latitude.isFinite && $0.coordinate.longitude.isFinite &&
            (-90...90).contains($0.coordinate.latitude) && (-180...180).contains($0.coordinate.longitude) &&
            $0.horizontalAccuracy.isFinite && $0.horizontalAccuracy >= 0 &&
            (-2...8).contains(now.timeIntervalSince($0.timestamp)) &&
            !($0.sourceInformation?.isSimulatedBySoftware ?? false)
        }) else { fix = nil; issue = "Ожидаем свежую геопозицию. Устаревшие и имитированные фиксы не используются."; return }
        fix = Fix(coordinate: GeographicCoordinate(longitude: location.coordinate.longitude, latitude: location.coordinate.latitude),
                  accuracyMeters: location.horizontalAccuracy, capturedAt: location.timestamp)
        issue = location.horizontalAccuracy <= 25 ? nil : "GPS сообщает погрешность больше 25 м: направление и предупреждения о границе временно скрыты."
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        fix = nil; issue = "GPS недоступен: \(error.localizedDescription)"
    }
    func direction(to target: GeographicCoordinate) -> Direction? {
        guard let current = usableFix, target.latitude.isFinite, target.longitude.isFinite,
              (-90...90).contains(target.latitude), (-180...180).contains(target.longitude) else { return nil }
        let a = current.coordinate.latitude * .pi / 180, b = target.latitude * .pi / 180
        let longitude = (target.longitude - current.coordinate.longitude) * .pi / 180
        let y = sin(longitude) * cos(b)
        let x = cos(a) * sin(b) - sin(a) * cos(b) * cos(longitude)
        let bearing = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let distance = CLLocation(latitude: current.coordinate.latitude, longitude: current.coordinate.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        let relative = usableHeading.map { heading -> Double in
            var angle = bearing - heading.degrees
            if angle > 180 { angle -= 360 }
            if angle < -180 { angle += 360 }
            return angle
        }
        return Direction(distanceMeters: distance, trueBearingDegrees: bearing, relativeDegrees: relative)
    }

    /// Convert the true-north heading at the phone into the plan's east/north
    /// tangent grid. A raw magnetic bearing is never used as an AR transform.
    func headingInGrid(_ projection: LocalWGS84Projection) -> Double? {
        guard let fix = usableFix, let heading = usableHeading else { return nil }
        let latitude = fix.coordinate.latitude * .pi / 180
        let longitude = fix.coordinate.longitude * .pi / 180
        let bearing = heading.degrees * .pi / 180, angle = 10 / 6_371_008.8
        let nextLatitude = asin(sin(latitude) * cos(angle) + cos(latitude) * sin(angle) * cos(bearing))
        let nextLongitude = longitude + atan2(sin(bearing) * sin(angle) * cos(latitude),
                                             cos(angle) - sin(latitude) * sin(nextLatitude))
        let normalizedLongitude = ((nextLongitude * 180 / .pi + 540).truncatingRemainder(dividingBy: 360)) - 180
        guard let a = try? projection.project(fix.coordinate),
              let b = try? projection.project(.init(longitude: normalizedLongitude, latitude: nextLatitude * 180 / .pi)) else { return nil }
        return (atan2(b.x - a.x, b.y - a.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}
