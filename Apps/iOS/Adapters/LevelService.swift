import Combine
import Foundation
import UIKit
@preconcurrency import CoreMotion
import simd

/// Gravity comes from Core Motion's accelerometer/gyroscope fusion. Zero is a
/// session-only operator reference, not a claim that the surface is horizontal.
@MainActor
final class LevelService: ObservableObject {
    struct Reading {
        let pitchDegrees: Double
        let rollDegrees: Double
        let inclinationDegrees: Double
        let observedAt: Date
        let usesOperatorZero: Bool
    }
    @Published private(set) var reading: Reading?
    @Published private(set) var issue: String?
    @Published private(set) var running = false
    @Published private(set) var calibrated = false
    var isSupported: Bool { motion.isDeviceMotionAvailable }

    private let motion = CMMotionManager()
    private var gravity: SIMD3<Double>?
    private var gravityObservedAt: Date?
    private var zeroGravity: SIMD3<Double>?
    private var orientation = UIDeviceOrientation.portrait
    private var screenOrientation: UIDeviceOrientation?
    private var generation = UUID()
    private var subscriptions = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }.store(in: &subscriptions)
    }

    func start() {
        guard !running else { return }
        guard motion.isDeviceMotionAvailable else { issue = "Датчики движения недоступны на этом устройстве."; return }
        guard UIApplication.shared.applicationState == .active else { return }
        let ticket = UUID(); generation = ticket; running = true; issue = nil; reading = nil
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        motion.deviceMotionUpdateInterval = 0.05
        // Arbitrary yaw avoids magnetometer interference; gravity and gyro are
        // sufficient for pitch/roll and an inclinometer.
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, error in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == ticket else { return }
                if let error { self.issue = error.localizedDescription; self.stop(); return }
                guard let data else { return }
                let age = ProcessInfo.processInfo.systemUptime - data.timestamp
                guard age.isFinite, (-0.1...0.5).contains(age) else { self.reading = nil; return }
                let vector = SIMD3(data.gravity.x, data.gravity.y, data.gravity.z)
                guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite, simd_length(vector) > 0.5 else { return }
                self.gravity = simd_normalize(vector)
                self.gravityObservedAt = Date().addingTimeInterval(-max(0, age))
                let current = self.screenOrientation ?? UIDevice.current.orientation
                if [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].contains(current) { self.orientation = current }
                self.publishReading()
            }
        }
    }

    func stop() {
        let wasRunning = running
        generation = UUID(); motion.stopDeviceMotionUpdates(); running = false
        if wasRunning { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        gravity = nil; gravityObservedAt = nil; reading = nil
    }

    func calibrateZero() {
        guard running, let gravity, let reading, Date().timeIntervalSince(reading.observedAt) < 0.5 else { return }
        zeroGravity = gravity; calibrated = true; publishReading()
    }

    func restoreHorizontal() { zeroGravity = nil; calibrated = false; publishReading() }

    func setInterfaceOrientation(_ interface: UIInterfaceOrientation) {
        guard let actual = SensorScreenOrientation.deviceOrientation(for: interface) else { return }
        screenOrientation = actual; orientation = actual
        publishReading()
    }

    private func axes(_ vector: SIMD3<Double>) -> (x: Double, y: Double, z: Double) {
        switch orientation {
        case .portraitUpsideDown: (-vector.x, -vector.y, vector.z)
        case .landscapeLeft: (-vector.y, vector.x, vector.z)
        case .landscapeRight: (vector.y, -vector.x, vector.z)
        default: (vector.x, vector.y, vector.z)
        }
    }

    private func publishReading() {
        guard running, let gravity, let observedAt = gravityObservedAt else { return }
        let a = axes(gravity)
        let pitch = atan2(a.y, abs(a.z)) * 180 / .pi
        let roll = atan2(a.x, abs(a.z)) * 180 / .pi
        var visiblePitch = pitch; var visibleRoll = roll
        let tilt: Double
        if let zeroGravity {
            let zero = axes(zeroGravity)
            visiblePitch = pitch - atan2(zero.y, abs(zero.z)) * 180 / .pi
            visibleRoll = roll - atan2(zero.x, abs(zero.z)) * 180 / .pi
            tilt = acos(min(1, max(-1, simd_dot(gravity, zeroGravity)))) * 180 / .pi
        } else {
            tilt = atan2(hypot(a.x, a.y), abs(a.z)) * 180 / .pi
        }
        reading = Reading(pitchDegrees: visiblePitch, rollDegrees: visibleRoll,
            inclinationDegrees: tilt, observedAt: observedAt, usesOperatorZero: calibrated)
    }
}

/// UIKit names the two landscape interface rotations opposite to UIDevice's
/// physical rotations. The actual view's scene also works with rotation lock,
/// a face-up phone, and multiple iPad windows.
enum SensorScreenOrientation {
    static func deviceOrientation(for interface: UIInterfaceOrientation) -> UIDeviceOrientation? {
        switch interface {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }
}
