import Foundation
import Combine
import CoreLocation
import AtlasCore

/// Explicit foreground staff location for a server-declared cloud policy.
/// It never enables or disables capture, measurement, editing, export or local
/// queue writes. No location manager request starts on account restoration.
@MainActor
final class StaffWorkLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    typealias Sender = @MainActor @Sendable (StaffLocationRequest?, StaffLocationStopRequest?) async throws -> StaffLocationResponse

    @Published private(set) var message = "Рабочая геопередача выключена"
    @Published private(set) var active = false
    @Published private(set) var foreground = false
    @Published private(set) var acknowledged = false
    @Published private(set) var reducedAccuracy = false
    @Published private(set) var leaseExpiresAt: Date?
    var changed: (() -> Void)?

    private let manager = CLLocationManager()
    private let deviceID: String
    private var sequence: Int
    private var accountID: String?
    private var accountGeneration: UInt64?
    private var accountExpiresAt = Date.distantPast
    private var sender: Sender?
    private var latestFix: CLLocation?
    private var acknowledgedFix: CLLocation?
    private var lastSent = Date.distantPast
    private var generation = UUID()
    private var requestID: UUID?
    private var requestTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    override init() {
        let defaults = UserDefaults.standard
        let installationKey = "atlas-staff-installation-v1"
        if let value = defaults.string(forKey: installationKey), UUID(uuidString: value) != nil { deviceID = value }
        else { let value = UUID().uuidString; deviceID = value; defaults.set(value, forKey: installationKey) }
        let saved = defaults.integer(forKey: "atlas-staff-location-sequence-v1")
        sequence = max(0, min(saved, 9_007_199_254_740_991))
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
    }

    var authorized: Bool { [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) }
    var lease: StaffWorkLocationLease {
        StaffWorkLocationLease(permissionAuthorized: authorized, foreground: foreground, active: active,
            acknowledged: acknowledged, expiresAt: leaseExpiresAt ?? .distantPast,
            observedAt: acknowledgedFix?.timestamp,
            simulatedBySoftware: acknowledgedFix?.sourceInformation?.isSimulatedBySoftware == true)
    }
    var canTransfer: Bool {
        StaffWorkLocationPolicy.allowsCloud(requirement: .required,
            accountAuthorized: accountID != nil, accountExpiresAt: accountExpiresAt, lease: lease)
    }

    /// The sender captures one exact account credential. Its generation is
    /// distinct from runtime renewal, which must not restart or redirect GPS.
    func configure(accountID: String, generation: UInt64, expiresAt: Date, sender: @escaping Sender) {
        if self.accountID != accountID || accountGeneration != generation {
            reset(reason: "logout")
            self.accountID = accountID; accountGeneration = generation
        }
        self.accountExpiresAt = expiresAt; self.sender = sender
        changed?()
    }

    func start() {
        guard accountID != nil, sender != nil, accountExpiresAt > Date() else { return }
        active = true
        guard foreground else {
            message = "Рабочая геопередача начнётся после возвращения в приложение"
            changed?(); return
        }
        startAcquiring(requestPermission: true)
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if !value {
            if active { stop(reason: "background", retainChoice: true) }
            else { manager.stopUpdatingLocation(); clearAcknowledgement() }
        } else if active {
            // This is a continuation of the operator's visible Start choice,
            // not an implicit start merely because a user signed in.
            startAcquiring(requestPermission: false)
        }
        changed?()
    }

    func stop(reason: String = "off_duty", retainChoice: Bool = false) {
        let hadWork = active || acknowledged || requestTask != nil
        generation = UUID(); requestTask?.cancel(); requestTask = nil; requestID = nil
        timer?.cancel(); timer = nil
        manager.stopUpdatingLocation()
        if !retainChoice { active = false }
        latestFix = nil; clearAcknowledgement()
        message = retainChoice ? "Геопередача приостановлена вне активного приложения" : "Геопередача на iPhone остановлена"
        changed?()
        guard hadWork, let sender, let sequence = nextSequence() else { return }
        let binding = accountGeneration, identity = accountID, ticket = generation
        let payload = StaffLocationStopRequest(deviceID: deviceID, sequence: sequence, reason: reason)
        // Fire-and-forget revocation uses the captured account. A late result
        // can update status only for this same stopped generation, never reopen
        // a lease or stop a later account's local acquisition.
        Task { [weak self] in
            do {
                let response = try await sender(nil, payload)
                guard let self, self.generation == ticket, self.accountID == identity,
                      self.accountGeneration == binding else { return }
                guard response.ok, response.location.deviceID == self.deviceID,
                      response.location.sequence == sequence, !response.workAllowed,
                      !response.location.workAllowed else { throw StaffAccountError.invalidResponse }
                self.message = retainChoice ? "Геопередача приостановлена; сайт подтвердил остановку" : "Геопередача остановлена; сайт подтвердил остановку"
                self.changed?()
            } catch {
                guard let self, self.generation == ticket, self.accountID == identity,
                      self.accountGeneration == binding else { return }
                self.message = retainChoice ? "Геопередача приостановлена на iPhone; сайт пока не подтвердил остановку" : "Геопередача на iPhone остановлена; сайт пока не подтвердил остановку"
                self.changed?()
            }
        }
    }

    func reset(reason: String = "logout") {
        stop(reason: reason)
        sender = nil; accountID = nil; accountGeneration = nil; accountExpiresAt = .distantPast
        changed?()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        if !authorized {
            if active { stop(reason: "permission_denied", retainChoice: true) }
            else { clearAcknowledgement() }
        } else if foreground && active { startAcquiring(requestPermission: false) }
        changed?()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, foreground, authorized, accountID != nil, accountExpiresAt > Date(), let fix = locations.last else { return }
        guard valid(fix, at: Date()), fix.sourceInformation?.isSimulatedBySoftware != true else {
            clearAcknowledgement()
            message = fix.sourceInformation?.isSimulatedBySoftware == true
                ? "Проверочное положение не открывает серверную передачу"
                : "Ожидаем свежее положение; локальная съёмка доступна"
            changed?(); return
        }
        latestFix = fix
        if Date().timeIntervalSince(lastSent) >= 30 { schedulePublish() }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        clearAcknowledgement()
        message = "Рабочее положение пока недоступно. Локальная съёмка доступна."
        changed?()
        if (error as? CLError)?.code == .denied { stop(reason: "permission_denied", retainChoice: true) }
    }

    private func startAcquiring(requestPermission: Bool) {
        guard active, foreground, accountID != nil, accountExpiresAt > Date() else { return }
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        guard authorized else {
            clearAcknowledgement()
            message = "Для рабочей геопередачи разрешите геолокацию в настройках iOS"
            if requestPermission && manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            changed?(); return
        }
        message = "Получаем рабочее положение для подтверждения сайтом…"
        manager.startUpdatingLocation()
        if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, self.active, self.foreground else { return }
                    guard self.accountExpiresAt > Date() else { self.reset(reason: "logout"); return }
                    if self.acknowledged && !self.canTransfer {
                        self.clearAcknowledgement()
                        self.message = "Подтверждение положения истекло; ожидаем новое. Локальные инструменты доступны."
                        self.changed?()
                    }
                    if Date().timeIntervalSince(self.lastSent) >= 30 { self.schedulePublish() }
                }
            }
        }
        changed?()
        schedulePublish()
    }
    private func schedulePublish() {
        guard requestTask == nil, active, foreground, authorized, let fix = latestFix,
              valid(fix, at: Date()), fix.sourceInformation?.isSimulatedBySoftware != true,
              Date().timeIntervalSince(lastSent) >= 5 else { return }
        let id = UUID(); requestID = id
        requestTask = Task { [weak self] in
            guard let self else { return }
            await self.publish(fix: fix)
            if self.requestID == id { self.requestID = nil; self.requestTask = nil }
        }
    }
    private func publish(fix: CLLocation) async {
        guard active, foreground, authorized, accountExpiresAt > Date(), let sender,
              valid(fix, at: Date()), fix.sourceInformation?.isSimulatedBySoftware != true,
              let sequence = nextSequence() else { return }
        let ticket = generation, identity = accountID, binding = accountGeneration
        lastSent = Date()
        let observedAt = ISO8601DateFormatter().string(from: fix.timestamp)
        let payload = StaffLocationRequest(deviceID: deviceID, sequence: sequence,
            accuracyAuthorization: reducedAccuracy ? "reduced" : "full", observedAt: observedAt,
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            accuracyMeters: fix.horizontalAccuracy, simulatedBySoftware: false)
        do {
            let response = try await sender(payload, nil)
            try Task.checkCancellation()
            guard ticket == generation, identity == accountID, binding == accountGeneration,
                  active, foreground, authorized, accountExpiresAt > Date() else { return }
            guard response.ok, response.locationRequired, response.location.deviceID == deviceID,
                  response.location.sequence == sequence else { throw StaffAccountError.invalidResponse }
            let expiry = try response.location.expiresAt.map(StaffIdentityPolicy.parseUTCDate)
            let allowed = response.workAllowed && response.location.workAllowed && response.location.fresh
            if allowed, let expiry, expiry > Date(), valid(fix, at: Date()) {
                acknowledgedFix = fix
                leaseExpiresAt = min(expiry, accountExpiresAt)
                acknowledged = true
                message = reducedAccuracy ? "Сайт подтвердил рабочее положение · приблизительная точность" : "Сайт подтвердил рабочее положение"
            } else {
                clearAcknowledgement()
                message = response.reasonCode == "simulated_location"
                    ? "Проверочное положение не открывает серверную передачу" : "Сайт пока не подтвердил рабочее положение"
            }
        } catch {
            guard ticket == generation, identity == accountID, binding == accountGeneration else { return }
            clearAcknowledgement()
            message = "Не удалось подтвердить рабочее положение. Локальные инструменты доступны."
        }
        changed?()
    }
    private func clearAcknowledgement() {
        acknowledged = false; acknowledgedFix = nil; leaseExpiresAt = nil
    }
    private func valid(_ fix: CLLocation, at now: Date) -> Bool {
        let age = now.timeIntervalSince(fix.timestamp)
        return CLLocationCoordinate2DIsValid(fix.coordinate) && fix.horizontalAccuracy.isFinite
            && (0...100_000).contains(fix.horizontalAccuracy)
            && age.isFinite && age >= -StaffWorkLocationPolicy.maximumFutureSkew && age < StaffWorkLocationPolicy.maximumFixAge
    }
    private func nextSequence() -> Int? {
        guard sequence < 9_007_199_254_740_991 else {
            clearAcknowledgement(); message = "Не удалось создать номер подтверждения. Обратитесь в поддержку."; changed?(); return nil
        }
        sequence += 1
        UserDefaults.standard.set(sequence, forKey: "atlas-staff-location-sequence-v1")
        return sequence
    }
}
