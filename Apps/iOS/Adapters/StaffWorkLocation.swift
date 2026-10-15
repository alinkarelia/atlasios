import Foundation
import Combine
import CoreLocation

struct StaffLocationResponse: Decodable, Sendable {
    struct Location: Decodable, Sendable {
        let deviceID: String; let sequence: Int; let expiresAt: String?; let fresh: Bool; let workAllowed: Bool
        enum CodingKeys: String, CodingKey { case sequence, fresh, deviceID = "device_id", expiresAt = "expires_at", workAllowed = "work_allowed" }
    }
    let ok: Bool; let locationRequired: Bool; let workAllowed: Bool; let reasonCode: String; let location: Location
    enum CodingKeys: String, CodingKey { case ok, location, locationRequired = "location_required", workAllowed = "work_allowed", reasonCode = "reason_code" }
}

/// Own installation, visible foreground only. Capture geotags remain separate
/// original observations and never stand in for an acknowledged work heartbeat.
@MainActor
final class StaffWorkLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var message = "Для работы разрешите геолокацию"
    @Published private(set) var acknowledged = false
    @Published private(set) var active = false
    @Published private(set) var reducedAccuracy = false
    var send: ((Data, Bool) async throws -> StaffLocationResponse)?
    var changed: (() -> Void)?
    private let manager = CLLocationManager()
    private let deviceID: String
    private var lastFix: CLLocation?
    private var lastSent = Date.distantPast
    private var expiresAt = Date.distantPast
    private var foreground = false
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    private var sending = false
    private var sequence: Int

    override init() {
        let defaults = UserDefaults.standard
        let key = "atlas-staff-installation-v1"
        if let saved = defaults.string(forKey: key), UUID(uuidString: saved) != nil { deviceID = saved }
        else { deviceID = UUID().uuidString; defaults.set(deviceID, forKey: key) }
        sequence = max(0, defaults.integer(forKey: "atlas-staff-location-sequence-v1"))
        super.init()
        manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone; manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false; manager.allowsBackgroundLocationUpdates = false
    }

    var authorized: Bool { [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) }
    var canWork: Bool {
        StaffWorkLease(permissionAuthorized:authorized, foreground:foreground, active:active,
            acknowledged:acknowledged, expiresAt:expiresAt, observedAt:lastFix?.timestamp,
            simulatedBySoftware:lastFix?.sourceInformation?.isSimulatedBySoftware == true).allowsWork(at:Date())
    }
    func requestPermission() { manager.requestWhenInUseAuthorization() }
    func setForeground(_ value: Bool) {
        foreground = value
        if value && active { start() }
        else if !value { stop(reason: "background", retainWorkChoice: true) }
    }
    func start() {
        guard foreground else { return }
        active = true
        guard authorized else {
            acknowledged = false; message = "Разрешите геолокацию в настройках iOS"; changed?()
            if manager.authorizationStatus == .notDetermined { requestPermission() }
            return
        }
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        message = "Получаем текущее рабочее положение…"; manager.startUpdatingLocation()
        if timer == nil {
            timer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, self.foreground, self.active else { return }
                    if !self.canWork { self.acknowledged = false; self.changed?() }
                    if Date().timeIntervalSince(self.lastSent) >= 30 { await self.publish() }
                }
            }
        }
        Task { await publish() }
    }
    func stop(reason: String = "off_duty", retainWorkChoice: Bool = false) {
        generation = UUID(); timer?.cancel(); timer = nil; manager.stopUpdatingLocation()
        if !retainWorkChoice { active = false }
        lastFix = nil; acknowledged = false; expiresAt = .distantPast
        message = retainWorkChoice ? "Геолокация остановлена вне активного экрана" : "Работа приостановлена"
        changed?()
        guard let send, let seq = nextSequence() else { return }
        let data = try? JSONSerialization.data(withJSONObject: ["client_id":"atlas", "device_id":deviceID,
            "sequence":seq, "reason":reason])
        guard let data else { return }
        // A late pre-stop acknowledgement cannot reopen this installation gate.
        Task { _ = try? await send(data, true) }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        if !authorized { stop(reason: "permission_denied", retainWorkChoice: true) }
        else if foreground && active { start() }
        changed?()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, foreground, authorized, let fix = locations.last,
              fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 100_000,
              CLLocationCoordinate2DIsValid(fix.coordinate), Date().timeIntervalSince(fix.timestamp) < 90,
              Date().timeIntervalSince(fix.timestamp) >= -30 else { return }
        lastFix = fix
        if Date().timeIntervalSince(lastSent) >= 30 { Task { await publish() } }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        acknowledged = false; message = "Положение пока недоступно. Исходники сохранены."; changed?()
        if (error as? CLError)?.code == .denied { stop(reason: "permission_denied", retainWorkChoice: true) }
    }
    private func nextSequence() -> Int? {
        guard sequence < 9_007_199_254_740_991 else { return nil }
        sequence += 1; UserDefaults.standard.set(sequence, forKey: "atlas-staff-location-sequence-v1"); return sequence
    }
    private func publish() async {
        guard active, foreground, authorized, !sending, let send, let fix = lastFix,
              Date().timeIntervalSince(lastSent) >= 5, Date().timeIntervalSince(fix.timestamp) < 90,
              let seq = nextSequence() else { return }
        let ticket = generation; sending = true; lastSent = Date()
        defer { sending = false }
        do {
            let payload: [String: Any] = ["client_id":"atlas", "device_id":deviceID, "sequence":seq,
                "permission":"authorized", "accuracy_authorization":reducedAccuracy ? "reduced" : "full",
                "foreground":true, "work_active":true, "observed_at":ISO8601DateFormatter().string(from:fix.timestamp),
                "latitude":fix.coordinate.latitude, "longitude":fix.coordinate.longitude, "accuracy_m":fix.horizontalAccuracy,
                "is_simulated_by_software":fix.sourceInformation?.isSimulatedBySoftware ?? false]
            let response = try await send(JSONSerialization.data(withJSONObject:payload), false)
            guard ticket == generation, active, foreground, authorized else { return }
            guard response.ok, response.locationRequired, response.location.deviceID == deviceID, response.location.sequence == seq else { throw StaffAccessError.invalidResponse }
            expiresAt = response.location.expiresAt.flatMap(StaffIdentityPolicy.date) ?? .distantPast
            acknowledged = response.workAllowed && response.location.workAllowed && response.location.fresh
            if acknowledged {
                message = reducedAccuracy ? "Рабочая геолокация · приблизительное положение" : "Рабочая геолокация включена"
            } else { message = response.reasonCode == "simulated_location" ? "Проверочное положение не открывает рабочий доступ" : "Ожидаем подтверждения текущего положения" }
        } catch {
            guard ticket == generation else { return }
            acknowledged = false; message = "Не удалось подтвердить рабочее положение. Исходники сохранены."
        }
        changed?()
    }
}
