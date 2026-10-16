import Foundation

/// Only a declared server policy may introduce a client-side location check.
/// This policy is for authenticated cloud requests, never local capture, tools,
/// stored originals, export or recording an offline transfer intention.
public enum StaffWorkLocationRequirement: Sendable, Equatable {
    case undeclared
    case notRequired
    case required

    public init(locationRequired: Bool?) {
        switch locationRequired {
        case let .some(value): self = value ? .required : .notRequired
        case .none: self = .undeclared
        }
    }
}

/// Acknowledgement belongs to one account, installation, sequence and active
/// foreground generation. The native adapter must validate those identities
/// before constructing this value and discard it on stop, logout or revocation.
/// observedAt is the acknowledged fix's timestamp, not a newer unsent fix.
public struct StaffWorkLocationLease: Sendable, Equatable {
    public var permissionAuthorized: Bool
    public var foreground: Bool
    public var active: Bool
    public var acknowledged: Bool
    public var expiresAt: Date
    public var observedAt: Date?
    public var simulatedBySoftware: Bool

    public init(permissionAuthorized: Bool, foreground: Bool, active: Bool, acknowledged: Bool,
                expiresAt: Date, observedAt: Date?, simulatedBySoftware: Bool) {
        self.permissionAuthorized = permissionAuthorized; self.foreground = foreground
        self.active = active; self.acknowledged = acknowledged; self.expiresAt = expiresAt
        self.observedAt = observedAt; self.simulatedBySoftware = simulatedBySoftware
    }
}

public enum StaffWorkLocationPolicy {
    /// Limits from the existing foreground work-location protocol. They are not
    /// survey accuracy claims and do not require full/precise iOS GPS permission.
    public static let maximumFixAge: TimeInterval = 90
    public static let maximumFutureSkew: TimeInterval = 30

    /// Account authorization is explicit: a future timestamp never overrides a
    /// revoked session. The backend remains authoritative about actual rights.
    public static func allowsCloud(requirement: StaffWorkLocationRequirement,
                                   accountAuthorized: Bool, accountExpiresAt: Date,
                                   lease: StaffWorkLocationLease?, at now: Date = Date()) -> Bool {
        guard accountAuthorized, now.timeIntervalSince1970.isFinite,
              accountExpiresAt.timeIntervalSince1970.isFinite, accountExpiresAt > now else { return false }
        switch requirement {
        // A legacy context without this field does not authorize starting GPS
        // or invent a new location prerequisite. Server ACLs still apply.
        case .undeclared, .notRequired: return true
        case .required: break
        }
        guard let lease, lease.permissionAuthorized, lease.foreground, lease.active, lease.acknowledged,
              !lease.simulatedBySoftware, lease.expiresAt.timeIntervalSince1970.isFinite,
              lease.expiresAt > now,
              let observedAt = lease.observedAt, observedAt.timeIntervalSince1970.isFinite else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age >= -maximumFutureSkew && age < maximumFixAge
    }
}
