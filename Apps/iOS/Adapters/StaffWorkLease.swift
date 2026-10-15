import Foundation

/// A server acknowledgement is a short foreground lease, never permanent
/// permission. Pure inputs make expiry, background and simulated-fix behavior
/// testable without pretending Simulator provides a physical GPS observation.
struct StaffWorkLease: Sendable {
    var permissionAuthorized: Bool
    var foreground: Bool
    var active: Bool
    var acknowledged: Bool
    var expiresAt: Date
    var observedAt: Date?
    var simulatedBySoftware: Bool
    func allowsWork(at now: Date) -> Bool {
        guard permissionAuthorized, foreground, active, acknowledged, expiresAt > now,
              !simulatedBySoftware, let observedAt else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age >= -30 && age < 90
    }
}
