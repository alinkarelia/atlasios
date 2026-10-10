import Combine
import CoreLocation
import Foundation
import UIKit

/// A compass bearing is independent of an AR scan origin. It is never silently
/// applied as georegistration or substituted for a missing GNSS position.
@MainActor
final class CompassService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    struct Reading {
        let degrees: Double
        let accuracyDegrees: Double
        let observedAt: Date
        let isTrueNorth: Bool
    }
    @Published private(set) var reading: Reading?
    @Published private(set) var issue: String?
    @Published private(set) var running = false
    private let manager = CLLocationManager()
    private var location: CLLocation?
    private var screenOrientation: UIDeviceOrientation?
    private var appliedOrientation = UIDeviceOrientation.unknown
    private var subscriptions = Set<AnyCancellable>()
    var isSupported: Bool { CLLocationManager.headingAvailable() }

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 1
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateOrientation() }
            }.store(in: &subscriptions)
    }

    func start() {
        guard !running, UIApplication.shared.applicationState == .active else { return }
        guard isSupported else { issue = "Магнитометр недоступен на этом устройстве."; return }
        running = true; reading = nil; location = nil; issue = nil
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateOrientation(); manager.startUpdatingHeading()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.startUpdatingLocation()
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: issue = "Геопозиция отключена: компас показывает магнитный север."
        }
    }

    func stop() {
        let wasRunning = running
        manager.stopUpdatingHeading(); manager.stopUpdatingLocation()
        running = false; reading = nil; location = nil
        if wasRunning { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard running else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: self.manager.startUpdatingLocation(); issue = nil
        case .denied, .restricted:
            self.manager.stopUpdatingLocation(); location = nil
            reading = nil
            issue = "Геопозиция отключена: компас показывает магнитный север."
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard running else { return }
        location = locations.last(where: { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy.isFinite &&
            $0.coordinate.latitude.isFinite && $0.coordinate.longitude.isFinite &&
            (-90...90).contains($0.coordinate.latitude) && (-180...180).contains($0.coordinate.longitude) &&
            (-5...20).contains(Date().timeIntervalSince($0.timestamp)) })
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard running else { return }
        let age = Date().timeIntervalSince(heading.timestamp)
        guard heading.headingAccuracy.isFinite, heading.headingAccuracy >= 0, (-5...5).contains(age),
              heading.magneticHeading.isFinite, (0..<360).contains(heading.magneticHeading) else {
            reading = nil; issue = "Компас не откалиброван. Уберите телефон от металла и магнитов."; return
        }
        let freshLocation = location.map { (-5...20).contains(Date().timeIntervalSince($0.timestamp)) } ?? false
        let trueNorth = freshLocation && heading.trueHeading.isFinite && (0..<360).contains(heading.trueHeading)
        reading = Reading(degrees: trueNorth ? heading.trueHeading : heading.magneticHeading,
            accuracyDegrees: heading.headingAccuracy, observedAt: heading.timestamp, isTrueNorth: trueNorth)
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse { issue = nil }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard running else { return }
        location = nil
        // Never leave a previously true-north reading visible after its location
        // failed; the next heading update can provide a magnetic reading.
        reading = nil; issue = "Геопозиция недоступна. Ожидается магнитный азимут: \(error.localizedDescription)"
    }

    func setInterfaceOrientation(_ interface: UIInterfaceOrientation) {
        guard let actual = SensorScreenOrientation.deviceOrientation(for: interface) else { return }
        screenOrientation = actual; updateOrientation()
    }

    private func updateOrientation() {
        let orientation = screenOrientation ?? UIDevice.current.orientation
        guard orientation != appliedOrientation else { return }
        switch orientation {
        case .portrait: manager.headingOrientation = .portrait
        case .portraitUpsideDown: manager.headingOrientation = .portraitUpsideDown
        case .landscapeLeft: manager.headingOrientation = .landscapeLeft
        case .landscapeRight: manager.headingOrientation = .landscapeRight
        default: return
        }
        appliedOrientation = orientation; reading = nil
    }
}
