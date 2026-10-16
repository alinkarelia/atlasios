import Foundation
import Testing
@testable import AtlasCore

private let workLocationNow = Date(timeIntervalSince1970: 1_792_152_000)
private let workLocationAccountExpiry = workLocationNow.addingTimeInterval(3_600)

private func acknowledgedWorkLocation() -> StaffWorkLocationLease {
    StaffWorkLocationLease(permissionAuthorized: true, foreground: true, active: true, acknowledged: true,
        expiresAt: workLocationNow.addingTimeInterval(60), observedAt: workLocationNow,
        simulatedBySoftware: false)
}

private func cloudWorkAllowed(_ lease: StaffWorkLocationLease?, now: Date = workLocationNow,
                             authorized: Bool = true, accountExpiry: Date = workLocationAccountExpiry) -> Bool {
    StaffWorkLocationPolicy.allowsCloud(requirement: .required, accountAuthorized: authorized,
        accountExpiresAt: accountExpiry, lease: lease, at: now)
}

@Test func staffWorkLocationDeclaredPolicyKeepsLocationIndependentOfAccountAuthorization() {
    #expect(StaffWorkLocationRequirement(locationRequired: nil) == .undeclared)
    #expect(StaffWorkLocationRequirement(locationRequired: false) == .notRequired)
    #expect(StaffWorkLocationRequirement(locationRequired: true) == .required)
    // No native GPS object, permission request or lease is necessary when the
    // legacy context has not declared a location prerequisite.
    #expect(StaffWorkLocationPolicy.allowsCloud(requirement: .undeclared, accountAuthorized: true,
        accountExpiresAt: workLocationAccountExpiry, lease: nil, at: workLocationNow))
    #expect(!StaffWorkLocationPolicy.allowsCloud(requirement: .undeclared, accountAuthorized: false,
        accountExpiresAt: workLocationAccountExpiry, lease: nil, at: workLocationNow))
    #expect(StaffWorkLocationPolicy.allowsCloud(requirement: .notRequired, accountAuthorized: true,
        accountExpiresAt: workLocationAccountExpiry, lease: nil, at: workLocationNow))
    #expect(!StaffWorkLocationPolicy.allowsCloud(requirement: .notRequired, accountAuthorized: false,
        accountExpiresAt: workLocationAccountExpiry, lease: acknowledgedWorkLocation(), at: workLocationNow))
    #expect(!StaffWorkLocationPolicy.allowsCloud(requirement: .notRequired, accountAuthorized: true,
        accountExpiresAt: workLocationNow, lease: nil, at: workLocationNow))
}

@Test func staffWorkLocationRequiredCloudNeedsCurrentRealAcknowledgedForegroundFix() {
    #expect(cloudWorkAllowed(acknowledgedWorkLocation()))
    #expect(!cloudWorkAllowed(nil))
    var lease = acknowledgedWorkLocation()
    lease.permissionAuthorized = false
    #expect(!cloudWorkAllowed(lease))
    lease = acknowledgedWorkLocation(); lease.acknowledged = false
    #expect(!cloudWorkAllowed(lease))
    lease = acknowledgedWorkLocation(); lease.simulatedBySoftware = true
    #expect(!cloudWorkAllowed(lease))
    lease = acknowledgedWorkLocation(); lease.observedAt = nil
    #expect(!cloudWorkAllowed(lease))
}

@Test func staffWorkLocationFixAgePreservesProtocolBoundariesWithoutInventedAccuracyThreshold() {
    var lease = acknowledgedWorkLocation()
    lease.observedAt = workLocationNow.addingTimeInterval(-89.999)
    #expect(cloudWorkAllowed(lease))
    lease.observedAt = workLocationNow.addingTimeInterval(-90)
    #expect(!cloudWorkAllowed(lease))
    lease.observedAt = workLocationNow.addingTimeInterval(-900)
    #expect(!cloudWorkAllowed(lease))
    lease.observedAt = workLocationNow.addingTimeInterval(30)
    #expect(cloudWorkAllowed(lease))
    lease.observedAt = workLocationNow.addingTimeInterval(30.001)
    #expect(!cloudWorkAllowed(lease))
}

@Test func staffWorkLocationStopBackgroundAndRevocationCannotReuseStillDatedAcknowledgement() {
    let acknowledged = acknowledgedWorkLocation()
    var stopped = acknowledged
    stopped.active = false
    #expect(!cloudWorkAllowed(stopped))
    var background = acknowledged
    background.foreground = false
    #expect(!cloudWorkAllowed(background))
    var invalidatedGeneration = acknowledged
    invalidatedGeneration.acknowledged = false
    #expect(!cloudWorkAllowed(invalidatedGeneration))
    #expect(!cloudWorkAllowed(acknowledged, authorized: false))
    #expect(!cloudWorkAllowed(acknowledged, accountExpiry: workLocationNow))
}

@Test func staffWorkLocationCloudExpiresAtEarlierOfServerLeaseAndAccount() {
    var lease = acknowledgedWorkLocation()
    lease.expiresAt = workLocationNow
    #expect(!cloudWorkAllowed(lease))
    lease.expiresAt = workLocationNow.addingTimeInterval(-1)
    #expect(!cloudWorkAllowed(lease))
    lease.expiresAt = workLocationAccountExpiry.addingTimeInterval(1)
    #expect(cloudWorkAllowed(lease))
    lease.expiresAt = workLocationAccountExpiry
    #expect(cloudWorkAllowed(lease))
    // A server lease need not be syntactically capped, but it never extends
    // the account's validity, even while the acknowledged fix stays fresh.
    lease = acknowledgedWorkLocation()
    #expect(cloudWorkAllowed(lease, now: workLocationNow.addingTimeInterval(29),
        accountExpiry: workLocationNow.addingTimeInterval(30)))
    #expect(!cloudWorkAllowed(lease, now: workLocationNow.addingTimeInterval(30),
        accountExpiry: workLocationNow.addingTimeInterval(30)))
    // The client does not invent a new lease from a recent local GPS timestamp.
    lease = acknowledgedWorkLocation()
    lease.observedAt = workLocationNow.addingTimeInterval(60)
    #expect(!cloudWorkAllowed(lease, now: workLocationNow.addingTimeInterval(60)))
}

@Test func staffWorkLocationRejectsNonfiniteTimesAndUsesActualUTCExpiry() throws {
    var lease = acknowledgedWorkLocation()
    lease.expiresAt = Date(timeIntervalSince1970: .nan)
    #expect(!cloudWorkAllowed(lease))
    lease = acknowledgedWorkLocation(); lease.observedAt = Date(timeIntervalSince1970: .infinity)
    #expect(!cloudWorkAllowed(lease))
    #expect(!cloudWorkAllowed(acknowledgedWorkLocation(), now: Date(timeIntervalSince1970: .nan)))
    #expect(!cloudWorkAllowed(acknowledgedWorkLocation(), accountExpiry: Date(timeIntervalSince1970: .infinity)))
    lease = acknowledgedWorkLocation()
    lease.expiresAt = try StaffIdentityPolicy.parseUTCDate("2026-10-16T12:01:00+00:00")
    #expect(cloudWorkAllowed(lease, now: workLocationNow.addingTimeInterval(59)))
    #expect(!cloudWorkAllowed(lease, now: workLocationNow.addingTimeInterval(60)))
}
