import Foundation

public enum PlanTier: String, Codable, CaseIterable, Sendable {
    case free, pro, business, enterprise
}

public enum Capability: String, Codable, CaseIterable, Hashable, Sendable {
    case captureLiDAR, editGeometry, measure, exportOwnData
    case advancedPlans, localBatchProcessing
    case cloudUpload, cloudProcessing, teamManagement, businessWorkflow, enterpriseIntegrations

    public static let baseline: Set<Capability> = [
        .captureLiDAR, .editGeometry, .measure, .exportOwnData
    ]

    public var requiresServerAuthorization: Bool {
        switch self {
        case .cloudUpload, .cloudProcessing, .teamManagement, .businessWorkflow, .enterpriseIntegrations:
            true
        default:
            false
        }
    }
}

public enum EntitlementScope: Codable, Equatable, Sendable {
    case personal(accountID: UUID?)
    case organization(UUID)
}

/// These describe evidence used by the app. They are never authentication claims
/// that a server may trust when supplied by a client.
public enum EntitlementSource: String, Codable, Sendable {
    case baseline, storeKitVerified, serverVerified
}

public enum EntitlementStatus: String, Codable, Sendable {
    case free, unknown, active, billingGrace, expired, revoked
}

public struct CommerceQuotas: Codable, Equatable, Sendable {
    public var editorSeats: Int?
    public var cloudStorageBytes: Int64?
    public var computeCredits: Int?

    public init(editorSeats: Int? = nil, cloudStorageBytes: Int64? = nil, computeCredits: Int? = nil) {
        self.editorSeats = editorSeats
        self.cloudStorageBytes = cloudStorageBytes
        self.computeCredits = computeCredits
    }
}

public struct EntitlementSnapshot: Codable, Equatable, Sendable {
    public var tier: PlanTier
    public var scope: EntitlementScope
    public var source: EntitlementSource
    public var status: EntitlementStatus
    public var capabilities: Set<Capability>
    public var validUntil: Date?
    public var offlineValidUntil: Date?
    public var verifiedAt: Date
    public var revision: UInt64
    public var quotas: CommerceQuotas

    public init(
        tier: PlanTier, scope: EntitlementScope, source: EntitlementSource,
        status: EntitlementStatus, capabilities: Set<Capability>,
        validUntil: Date? = nil, offlineValidUntil: Date? = nil,
        verifiedAt: Date, revision: UInt64 = 0, quotas: CommerceQuotas = .init()
    ) {
        self.tier = tier
        self.scope = scope
        self.source = source
        self.status = status
        self.capabilities = capabilities
        self.validUntil = validUntil
        self.offlineValidUntil = offlineValidUntil
        self.verifiedAt = verifiedAt
        self.revision = revision
        self.quotas = quotas
    }

    public static func free(verifiedAt: Date, accountID: UUID? = nil) -> Self {
        .init(tier: .free, scope: .personal(accountID: accountID), source: .baseline,
              status: .free, capabilities: Capability.baseline, verifiedAt: verifiedAt)
    }
}

public enum CommerceDecision: String, Codable, Sendable {
    case allowed, requiresPlan, requiresConnection, serverAuthorizationRequired
}

/// A presentation/local-feature policy. Ownership and project RBAC are separate.
/// Every server operation must independently check account, membership, current
/// entitlements and quotas; no value in this policy authorizes a server request.
public enum CommercePolicy {
    public static func decision(
        for capability: Capability, snapshot: EntitlementSnapshot, now: Date
    ) -> CommerceDecision {
        if Capability.baseline.contains(capability) { return .allowed }
        guard snapshot.capabilities.contains(capability) else { return .requiresPlan }
        guard snapshot.status == .active || snapshot.status == .billingGrace else {
            return .requiresPlan
        }
        if let expiration = snapshot.validUntil, expiration <= now { return .requiresPlan }
        if snapshot.source == .baseline { return .requiresPlan }

        // A signed StoreKit transaction covers personal local tools, never team
        // membership or a consumable/cloud balance.
        if capability.requiresServerAuthorization {
            guard snapshot.source == .serverVerified else { return .requiresConnection }
            if let lease = snapshot.offlineValidUntil, lease <= now { return .requiresConnection }
            return .serverAuthorizationRequired
        }
        if snapshot.source == .serverVerified,
           let lease = snapshot.offlineValidUntil, lease <= now {
            return .requiresConnection
        }
        return .allowed
    }
}

public enum StoreKitEnvironment: String, Codable, Sendable {
    case production, sandbox, xcode, unknown
}

/// Signature verification is performed by StoreKit and repeated on the server.
/// Merely constructing or decoding this struct provides no authority.
public struct VerifiedPurchaseEvidence: Codable, Equatable, Sendable {
    public let productID: String
    public let tier: PlanTier
    public let transactionID: String
    public let originalTransactionID: String
    public let appAccountToken: UUID?
    public let purchasedAt: Date
    public let expiresAt: Date?
    public let graceExpiresAt: Date?
    public let revokedAt: Date?
    public let isUpgraded: Bool
    public let environment: StoreKitEnvironment
    public let signedTransactionJWS: String

    public init(
        productID: String, tier: PlanTier, transactionID: String,
        originalTransactionID: String, appAccountToken: UUID? = nil,
        purchasedAt: Date, expiresAt: Date? = nil, graceExpiresAt: Date? = nil,
        revokedAt: Date? = nil, isUpgraded: Bool = false,
        environment: StoreKitEnvironment, signedTransactionJWS: String
    ) {
        self.productID = productID
        self.tier = tier
        self.transactionID = transactionID
        self.originalTransactionID = originalTransactionID
        self.appAccountToken = appAccountToken
        self.purchasedAt = purchasedAt
        self.expiresAt = expiresAt
        self.graceExpiresAt = graceExpiresAt
        self.revokedAt = revokedAt
        self.isUpgraded = isUpgraded
        self.environment = environment
        self.signedTransactionJWS = signedTransactionJWS
    }

    public func localSnapshot(now: Date) -> EntitlementSnapshot {
        let deadline = graceExpiresAt ?? expiresAt
        let status: EntitlementStatus
        if revokedAt != nil {
            status = .revoked
        } else if isUpgraded || deadline.map({ $0 <= now }) != false {
            status = .expired
        } else if let expiry = expiresAt, expiry <= now, graceExpiresAt != nil {
            status = .billingGrace
        } else {
            status = .active
        }
        var capabilities = Capability.baseline
        if (status == .active || status == .billingGrace) && tier != .free {
            capabilities.formUnion([.advancedPlans, .localBatchProcessing, .cloudUpload, .cloudProcessing])
            if tier == .business || tier == .enterprise {
                capabilities.formUnion([.teamManagement, .businessWorkflow])
            }
            if tier == .enterprise { capabilities.insert(.enterpriseIntegrations) }
        }
        return .init(tier: tier, scope: .personal(accountID: appAccountToken),
                     source: .storeKitVerified, status: status, capabilities: capabilities,
                     validUntil: deadline, verifiedAt: now)
    }
}

public enum VerifiedPurchaseState: Codable, Equatable, Sendable {
    case unknown
    case unavailable(message: String)
    case notPurchased
    case pending(productID: String)
    case verified(VerifiedPurchaseEvidence)
    case expired(VerifiedPurchaseEvidence)
    case revoked(VerifiedPurchaseEvidence)
    case verificationFailed(productID: String, message: String)
}

public enum PurchaseOutcome: Codable, Equatable, Sendable {
    case completed(VerifiedPurchaseEvidence)
    case pending
    case cancelled
    case unavailable(reason: String)
    case failed(message: String)
}

/// Implementations submit JWS over an authenticated connection, and return a
/// snapshot derived from independently verified server records. Implementations
/// must be idempotent by transactionID, including renewal and startup redelivery.
public protocol StoreKitEvidenceSink: Sendable {
    func acceptedStoreKitGrant(_ evidence: VerifiedPurchaseEvidence) async throws -> EntitlementSnapshot
}
