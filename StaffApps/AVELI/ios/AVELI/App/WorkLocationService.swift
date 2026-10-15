import Combine
import CoreLocation
import Foundation

struct WorkLocationReply: Decodable {
    struct Status: Decodable { let expiresAt: String?
        enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" } }
    let ok: Bool
    let workAllowed: Bool
    let reasonCode: String?
    let location: Status
    enum CodingKeys: String, CodingKey { case ok, location; case workAllowed = "work_allowed"; case reasonCode = "reason_code" }
}

/// Visible, foreground-only work heartbeat. Coordinates are never persisted.
@MainActor
final class WorkLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var workAllowed = false
    @Published private(set) var message = "Для работы нужна геолокация при открытом приложении."
    @Published private(set) var reducedAccuracy = false
    var onGateChanged: ((Bool) -> Void)?
    var onAuthorityFailure: ((Error) -> Void)?
    private let manager = CLLocationManager()
    private let api: NativeAPI
    private let deviceID: String
    private var token: String?
    private var fix: CLLocation?
    private var timer: Timer?
    private var expiry: Date?
    private var lastSent: Date?
    private var sending = false
    private var generation = 0
    private var foreground = false
    private var sequence: Int
    init(api: NativeAPI) {
        self.api = api
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "aveli.installation-id")
        deviceID = saved ?? UUID().uuidString
        defaults.set(deviceID, forKey: "aveli.installation-id")
        sequence = max(0, defaults.integer(forKey: "aveli.location-sequence"))
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
    }
    private func nextSequence() -> Int {
        sequence += 1
        UserDefaults.standard.set(sequence, forKey: "aveli.location-sequence")
        return sequence
    }
    private var permission: String {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not_determined"
        }
    }
    private func gate(_ allowed: Bool) {
        guard workAllowed != allowed else { return }
        workAllowed = allowed
        onGateChanged?(allowed)
    }
    func requestPermission() { manager.requestWhenInUseAuthorization() }
    func begin(token: String) {
        generation += 1
        self.token = token
        foreground = true
        sending = false
        expiry = nil
        lastSent = nil
        fix = nil
        gate(false)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let expiry = self.expiry, expiry <= Date() { self.message = "Геолокация устарела. Обновляем подключение."; self.gate(false) }
                if self.lastSent == nil || Date().timeIntervalSince(self.lastSent!) >= 30 { await self.heartbeat() }
            }
        }
        updatePermission()
    }
    private func updatePermission() {
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        guard token != nil, foreground else { return }
        if permission == "authorized", CLLocationManager.locationServicesEnabled() {
            message = "Определяем местоположение…"
            manager.startUpdatingLocation()
        } else if permission == "not_determined" {
            message = "Разрешите геолокацию для начала работы."
            gate(false)
            manager.stopUpdatingLocation()
        } else {
            message = permission == "not_determined" ? "Разрешите геолокацию для начала работы." : "Геолокация отключена. Работа приостановлена."
            gate(false)
            manager.stopUpdatingLocation()
            fix = nil
            stop(reason: "permission_denied")
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { updatePermission() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard token != nil, foreground, permission == "authorized", let value = locations.last,
              value.horizontalAccuracy >= 0, value.timestamp.timeIntervalSinceNow >= -120,
              value.timestamp.timeIntervalSinceNow <= 30 else { return }
        fix = value
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        if lastSent == nil || !workAllowed && Date().timeIntervalSince(lastSent!) >= 5 { Task { await heartbeat() } }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = "Не удалось определить местоположение. Работа приостановлена."
        gate(false)
        fix = nil
        stop(reason: "accuracy_unavailable")
    }
    private func heartbeat() async {
        guard foreground, let token, !sending, permission == "authorized" else { return }
        if let lastSent, Date().timeIntervalSince(lastSent) < 5 { return }
        let epoch = generation
        sending = true
        lastSent = Date()
        let current = fix.flatMap { $0.timestamp.timeIntervalSinceNow >= -120 && $0.timestamp.timeIntervalSinceNow <= 30 ? $0 : nil }
        let payload: [String: Any] = ["client_id": "aveli", "device_id": deviceID, "sequence": nextSequence(),
            "permission": permission, "accuracy_authorization": reducedAccuracy ? "reduced" : "full",
            "foreground": true, "work_active": true, "observed_at": current.map { NativeDate.string($0.timestamp) } as Any? ?? NSNull(),
            "latitude": current.map { $0.coordinate.latitude } as Any? ?? NSNull(),
            "longitude": current.map { $0.coordinate.longitude } as Any? ?? NSNull(),
            "accuracy_m": current.map { $0.horizontalAccuracy } as Any? ?? NSNull(),
            "is_simulated_by_software": current?.sourceInformation?.isSimulatedBySoftware ?? false]
        do {
            let reply: WorkLocationReply = try await api.post("/api/native/account/location", token: token, json: payload)
            guard epoch == generation, self.token == token, foreground else { return }
            expiry = reply.location.expiresAt.flatMap(NativeDate.parse)
            let allowed = reply.ok && reply.workAllowed && expiry.map { $0 > Date() } == true
            message = current?.sourceInformation?.isSimulatedBySoftware == true ? "Тестовая геолокация не подтверждает работу." : allowed ? (reducedAccuracy ? "Геолокация: приблизительно" : "Геолокация включена во время работы") : "Местоположение не подтверждено. Работа приостановлена."
            gate(allowed)
        } catch {
            guard epoch == generation else { return }
            message = "Не удалось подтвердить геолокацию. Работа приостановлена."
            gate(false)
            if let error = error as? NativeAPIError, [401, 403, 409].contains(error.status ?? 0) { onAuthorityFailure?(error) }
        }
        if epoch == generation { sending = false }
    }
    func stop(reason: String) {
        generation += 1
        foreground = false
        timer?.invalidate()
        timer = nil
        manager.stopUpdatingLocation()
        fix = nil
        expiry = nil
        lastSent = nil
        gate(false)
        guard let current = token else { return }
        token = nil
        let payload: [String: Any] = ["client_id": "aveli", "device_id": deviceID, "sequence": nextSequence(), "reason": reason]
        Task {
            let _: NativeOK? = try? await api.post("/api/native/account/location/stop", token: current, json: payload)
        }
    }
}
