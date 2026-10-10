import Foundation
import XCTest
@testable import AtlasCore

final class CommerceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testCancelledAccessNeverLocksBaselineDataTools() {
        var snapshot = EntitlementSnapshot.free(verifiedAt: now)
        snapshot.status = .revoked
        snapshot.capabilities = []
        for capability in Capability.baseline {
            XCTAssertEqual(CommercePolicy.decision(for: capability, snapshot: snapshot, now: now), .allowed)
        }
    }

    func testStoreKitGrantCannotAuthorizeBusinessOrCloud() {
        var snapshot = evidence(expiry: now.addingTimeInterval(60)).localSnapshot(now: now)
        snapshot.capabilities.formUnion([.cloudProcessing, .teamManagement])
        XCTAssertEqual(CommercePolicy.decision(for: .advancedPlans, snapshot: snapshot, now: now), .allowed)
        XCTAssertEqual(CommercePolicy.decision(for: .cloudProcessing, snapshot: snapshot, now: now), .requiresConnection)
        XCTAssertEqual(CommercePolicy.decision(for: .teamManagement, snapshot: snapshot, now: now), .requiresConnection)
    }

    func testExpiredVerifiedEvidenceDoesNotUnlockPaidTools() {
        let snapshot = evidence(expiry: now).localSnapshot(now: now)
        XCTAssertEqual(snapshot.status, .expired)
        XCTAssertEqual(CommercePolicy.decision(for: .advancedPlans, snapshot: snapshot, now: now), .requiresPlan)
        XCTAssertEqual(CommercePolicy.decision(for: .exportOwnData, snapshot: snapshot, now: now), .allowed)
    }

    func testVerifiedGracePeriodRemainsUsableUntilItsDeadline() {
        let evidence = evidence(expiry: now.addingTimeInterval(-60), grace: now.addingTimeInterval(60))
        let snapshot = evidence.localSnapshot(now: now)
        XCTAssertEqual(snapshot.status, .billingGrace)
        XCTAssertEqual(CommercePolicy.decision(for: .advancedPlans, snapshot: snapshot, now: now), .allowed)
        XCTAssertEqual(CommercePolicy.decision(for: .advancedPlans, snapshot: snapshot,
                                              now: now.addingTimeInterval(60)), .requiresPlan)
    }

    func testRevokedOrSupersededEvidenceNeverCreatesActiveGrant() {
        XCTAssertEqual(evidence(expiry: now.addingTimeInterval(60), revoked: now).localSnapshot(now: now).status, .revoked)
        XCTAssertEqual(evidence(expiry: now.addingTimeInterval(60), upgraded: true).localSnapshot(now: now).status, .expired)
        XCTAssertEqual(evidence(expiry: nil).localSnapshot(now: now).status, .expired)
    }

    func testServerSnapshotStillRequiresAuthorizationAndExpiredLeaseRequiresConnection() {
        let snapshot = EntitlementSnapshot(
            tier: .business, scope: .organization(UUID()), source: .serverVerified,
            status: .active, capabilities: [.teamManagement, .advancedPlans],
            validUntil: now.addingTimeInterval(600), offlineValidUntil: now.addingTimeInterval(60),
            verifiedAt: now
        )
        XCTAssertEqual(CommercePolicy.decision(for: .teamManagement, snapshot: snapshot, now: now), .serverAuthorizationRequired)
        XCTAssertEqual(CommercePolicy.decision(for: .advancedPlans, snapshot: snapshot,
                                              now: now.addingTimeInterval(60)), .requiresConnection)
    }

    func testCapabilityGrantIsExplicitAndSnapshotRoundTrips() throws {
        let snapshot = EntitlementSnapshot(
            tier: .enterprise, scope: .organization(UUID()), source: .serverVerified,
            status: .active, capabilities: [.advancedPlans], verifiedAt: now,
            revision: 8, quotas: .init(editorSeats: 10, cloudStorageBytes: 1_000_000_000, computeCredits: 90)
        )
        XCTAssertEqual(CommercePolicy.decision(for: .enterpriseIntegrations, snapshot: snapshot, now: now), .requiresPlan)
        XCTAssertEqual(try JSONDecoder().decode(EntitlementSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    private func evidence(expiry: Date?, grace: Date? = nil, revoked: Date? = nil,
                          upgraded: Bool = false) -> VerifiedPurchaseEvidence {
        .init(productID: "test.pro.monthly", tier: .pro, transactionID: "101",
              originalTransactionID: "100", purchasedAt: now.addingTimeInterval(-100),
              expiresAt: expiry, graceExpiresAt: grace, revokedAt: revoked,
              isUpgraded: upgraded, environment: .sandbox, signedTransactionJWS: "test-fixture-not-a-real-signature")
    }
}
