import AtlasCore
import Combine
import Foundation
import StoreKit

struct PurchaseConfiguration: Sendable {
    let tiersByProductID: [String: PlanTier]

    init(tiersByProductID: [String: PlanTier]) {
        self.tiersByProductID = tiersByProductID
    }

    static let production = PurchaseConfiguration(tiersByProductID: [
        "com.atlasfield.pro.monthly": .pro,
        "com.atlasfield.pro.yearly": .pro,
        "com.atlasfield.business3.monthly": .business,
        "com.atlasfield.business3.yearly": .business,
        "com.atlasfield.business10.monthly": .business,
        "com.atlasfield.business10.yearly": .business
    ])
}

/// Actual StoreKit products and signed transactions only. Server-backed rights
/// are delivered through the sink; unavailable products never produce a grant.
@MainActor
final class PurchaseService: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var state: VerifiedPurchaseState = .unknown
    @Published private(set) var snapshot: EntitlementSnapshot = .free(verifiedAt: .distantPast)
    @Published private(set) var lastIssue: String?
    @Published private(set) var isBusy = false

    private let client: StoreKitClient
    private let config: PurchaseConfiguration
    private var evidenceSink: (any StoreKitEvidenceSink)?
    private var appAccountToken: UUID?
    private var updateTask: Task<Void, Never>?
    private var entitlementGeneration: UInt64 = 0
    private var accountGeneration: UInt64 = 0

    init(
        config: PurchaseConfiguration = .production,
        evidenceSink: (any StoreKitEvidenceSink)? = nil,
        appAccountToken: UUID? = nil
    ) {
        client = StoreKitClient(config: config)
        self.config = config
        self.evidenceSink = appAccountToken == nil ? nil : evidenceSink
        self.appAccountToken = appAccountToken
    }

    deinit { updateTask?.cancel() }

    func tier(for product: Product) -> PlanTier? { config.tiersByProductID[product.id] }

    /// Call after authenticating the real application account, and again with
    /// nil values at logout. Changing credentials/sink, even for the same user,
    /// invalidates all prior server responses. The StoreKit observer stays alive.
    func configureAccount(userID: UUID?, evidenceSink: (any StoreKitEvidenceSink)?) async {
        accountGeneration &+= 1
        entitlementGeneration &+= 1
        appAccountToken = userID
        self.evidenceSink = userID == nil ? nil : evidenceSink
        snapshot = .free(verifiedAt: Date(), accountID: userID)
        state = .unknown
        lastIssue = nil
        // Personal rights follow signed Apple transactions. Organization rights
        // require a matching appAccountToken and this account's authenticated sink.
        await refreshEntitlements()
    }

    func startup() async {
        if updateTask == nil {
            let client = self.client
            updateTask = Task { [weak self] in
                for await update in await client.updates() {
                    guard !Task.isCancelled, let self else { return }
                    await self.handle(update)
                    if case .revoked = update { await self.refreshEntitlements() }
                    if case .expired = update { await self.refreshEntitlements() }
                }
            }
        }
        let accountVersion = accountGeneration
        do {
            products = try await client.loadProducts()
            if accountVersion == accountGeneration {
                lastIssue = products.isEmpty ? "Подписки пока недоступны в App Store." : nil
            }
        } catch {
            products = []
            if accountVersion == accountGeneration {
                lastIssue = "Не удалось загрузить подписки: \(error.localizedDescription)"
            }
        }
        // This still reads signed cached entitlements when the product request
        // cannot reach the store. No account/backend is required for local tools.
        await refreshEntitlements()
    }

    func buy(_ product: Product) async -> PurchaseOutcome {
        guard !isBusy else { return .unavailable(reason: "Другая операция покупки уже выполняется.") }
        guard products.contains(where: { $0.id == product.id }) else {
            return .unavailable(reason: "Этот продукт недоступен в App Store.")
        }
        isBusy = true
        let accountVersion = accountGeneration
        let purchaseAccountToken = appAccountToken
        defer { isBusy = false }
        do {
            let outcome = try await client.buy(productID: product.id, appAccountToken: purchaseAccountToken)
            guard accountVersion == accountGeneration else {
                // A purchase started before an account switch still belongs to
                // its original signed token. Re-read local rights in the new
                // context without delivering it to the previous sink.
                await refreshEntitlements()
                return outcome
            }
            switch outcome {
            case .completed(let evidence):
                await handle(.verified(evidence))
            case .pending:
                state = .pending(productID: product.id)
            case .failed(let message):
                lastIssue = message
            case .unavailable(let reason):
                lastIssue = reason
            case .cancelled:
                break
            }
            return outcome
        } catch {
            let message = "Покупка не завершена: \(error.localizedDescription)"
            if accountVersion == accountGeneration { lastIssue = message }
            return .failed(message: message)
        }
    }

    /// Call only from the user's Restore Purchases action: sync may prompt for
    /// Apple Account authentication. Startup relies on automatic StoreKit restore.
    func restore() async {
        guard !isBusy else { return }
        isBusy = true
        let accountVersion = accountGeneration
        defer { isBusy = false }
        do {
            try await client.restore()
            await refreshEntitlements()
        } catch {
            if accountVersion == accountGeneration {
                lastIssue = "Не удалось восстановить покупки: \(error.localizedDescription)"
            }
        }
    }

    private func refreshEntitlements() async {
        let accountVersion = accountGeneration
        let entitlementVersion = entitlementGeneration
        let states = await client.currentEntitlements()
        guard accountVersion == accountGeneration, entitlementVersion == entitlementGeneration else { return }
        let now = Date()
        let active = states.compactMap { candidate -> VerifiedPurchaseEvidence? in
            guard case .verified(let evidence) = candidate else { return nil }
            let status = evidence.localSnapshot(now: now).status
            return status == .active || status == .billingGrace ? evidence : nil
        }.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return rank(lhs.tier) > rank(rhs.tier) }
            return lhs.purchasedAt > rhs.purchasedAt
        }
        if let best = active.first {
            await handle(.verified(best))
        } else if let failed = states.first(where: {
            if case .verificationFailed = $0 { return true }
            return false
        }) {
            entitlementGeneration &+= 1
            state = failed
            snapshot = .free(verifiedAt: now, accountID: appAccountToken)
        } else {
            entitlementGeneration &+= 1
            snapshot = .free(verifiedAt: now, accountID: appAccountToken)
            state = products.isEmpty
                ? .unavailable(message: lastIssue ?? "Подписки недоступны.") : .notPurchased
        }
    }

    private func handle(_ update: VerifiedPurchaseState) async {
        switch update {
        case .verified(let evidence), .expired(let evidence), .revoked(let evidence):
            entitlementGeneration &+= 1
            let generation = entitlementGeneration
            let accountVersion = accountGeneration
            let local = evidence.localSnapshot(now: Date())
            snapshot = local
            if local.status == .revoked {
                state = .revoked(evidence)
            } else if local.status == .expired {
                state = .expired(evidence)
            } else {
                state = .verified(evidence)
            }
            if let evidenceSink, let accountID = appAccountToken {
                // A signed transaction cannot be reassigned on login. Legacy
                // anonymous/mismatched purchases retain local rights only; the
                // server independently enforces the same signed-token binding.
                guard evidence.appAccountToken == accountID else {
                    lastIssue = evidence.appAccountToken == nil
                        ? "Локальная подписка доступна. Покупка не привязана к аккаунту для серверных прав."
                        : "Локальная подписка доступна. Серверные права связаны с другим аккаунтом приложения."
                    await client.finishDeliveredSubscription(transactionID: evidence.transactionID)
                    return
                }
                do {
                    let serverSnapshot = try await evidenceSink.acceptedStoreKitGrant(evidence)
                    guard generation == entitlementGeneration, accountVersion == accountGeneration,
                          appAccountToken == accountID else {
                        await client.finishDeliveredSubscription(transactionID: evidence.transactionID)
                        return
                    }
                    guard serverSnapshot.source == .serverVerified else {
                        lastIssue = "Сервер не подтвердил права организации. Локальные инструменты сохранены."
                        await client.finishDeliveredSubscription(transactionID: evidence.transactionID)
                        return
                    }
                    snapshot = serverSnapshot
                    lastIssue = nil
                } catch {
                    // A backend outage must not retract a real signed local grant.
                    if generation == entitlementGeneration, accountVersion == accountGeneration {
                        lastIssue = "Локальная подписка проверена. Права облака ожидают связи с сервером."
                    }
                }
            }
            await client.finishDeliveredSubscription(transactionID: evidence.transactionID)
        case .verificationFailed(_, let message):
            state = update
            lastIssue = message
        default:
            state = update
        }
    }

    private func rank(_ tier: PlanTier) -> Int {
        switch tier {
        case .free: 0
        case .pro: 1
        case .business: 2
        case .enterprise: 3
        }
    }
}

private actor StoreKitClient {
    private let config: PurchaseConfiguration
    private var loadedProducts: [String: Product] = [:]
    private var deliveredTransactions: [String: Transaction] = [:]

    init(config: PurchaseConfiguration) { self.config = config }

    func loadProducts() async throws -> [Product] {
        let products = try await Product.products(for: Array(config.tiersByProductID.keys))
            .filter { $0.type == .autoRenewable }
            .sorted { $0.id < $1.id }
        loadedProducts = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        return products
    }

    func buy(productID: String, appAccountToken: UUID?) async throws -> PurchaseOutcome {
        guard let product = loadedProducts[productID] else {
            return .unavailable(reason: "Продукт не загружен из App Store.")
        }
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken { options.insert(.appAccountToken(appAccountToken)) }
        switch try await product.purchase(options: options) {
        case .success(let result):
            guard let state = await verifiedState(result) else {
                return .failed(message: "Получена транзакция неизвестного продукта.")
            }
            if case .verified(let evidence) = state { return .completed(evidence) }
            if case .verificationFailed(_, let message) = state { return .failed(message: message) }
            return .failed(message: "Транзакция не предоставляет действующую подписку.")
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .failed(message: "App Store вернул неизвестное состояние покупки.")
        }
    }

    func restore() async throws { try await AppStore.sync() }

    func currentEntitlements() async -> [VerifiedPurchaseState] {
        var states: [VerifiedPurchaseState] = []
        for await result in Transaction.currentEntitlements {
            if let state = await verifiedState(result) { states.append(state) }
        }
        return states
    }

    func updates() -> AsyncStream<VerifiedPurchaseState> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    if let state = await self.verifiedState(result) { continuation.yield(state) }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func finishDeliveredSubscription(transactionID: String) async {
        guard let transaction = deliveredTransactions.removeValue(forKey: transactionID),
              transaction.productType == .autoRenewable else { return }
        // Only subscriptions are configured. Future consumable products must be
        // finished after backend ledger acceptance, never merely local delivery.
        await transaction.finish()
    }

    private func verifiedState(_ result: VerificationResult<Transaction>) async -> VerifiedPurchaseState? {
        switch result {
        case .unverified(let transaction, let error):
            guard config.tiersByProductID[transaction.productID] != nil else { return nil }
            return .verificationFailed(productID: transaction.productID,
                                       message: "Подпись покупки не подтверждена: \(error.localizedDescription)")
        case .verified(let transaction):
            guard let tier = config.tiersByProductID[transaction.productID],
                  transaction.productType == .autoRenewable else { return nil }
            var graceExpiresAt: Date?
            if let groupID = transaction.subscriptionGroupID,
               let statuses = try? await Product.SubscriptionInfo.status(for: groupID) {
                for status in statuses where status.state == .inGracePeriod {
                    if case .verified(let statusTransaction) = status.transaction,
                       statusTransaction.originalID == transaction.originalID,
                       case .verified(let renewalInfo) = status.renewalInfo {
                        graceExpiresAt = renewalInfo.gracePeriodExpirationDate
                    }
                }
            }
            let evidence = VerifiedPurchaseEvidence(
                productID: transaction.productID, tier: tier,
                transactionID: String(transaction.id), originalTransactionID: String(transaction.originalID),
                appAccountToken: transaction.appAccountToken, purchasedAt: transaction.purchaseDate,
                expiresAt: transaction.expirationDate, graceExpiresAt: graceExpiresAt,
                revokedAt: transaction.revocationDate, isUpgraded: transaction.isUpgraded,
                environment: environment(transaction.environment), signedTransactionJWS: result.jwsRepresentation
            )
            deliveredTransactions[evidence.transactionID] = transaction
            switch evidence.localSnapshot(now: Date()).status {
            case .revoked: return .revoked(evidence)
            case .expired: return .expired(evidence)
            default: return .verified(evidence)
            }
        }
    }

    private func environment(_ value: AppStore.Environment) -> StoreKitEnvironment {
        switch value {
        case .production: .production
        case .sandbox: .sandbox
        case .xcode: .xcode
        default: .unknown
        }
    }
}
