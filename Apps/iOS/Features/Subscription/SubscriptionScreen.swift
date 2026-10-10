import AtlasCore
import StoreKit
import SwiftUI

private enum BillingPeriod: String, CaseIterable, Identifiable {
    case monthly = "Месяц", yearly = "Год"
    var id: String { rawValue }
    func contains(_ product: Product) -> Bool {
        guard let period = product.subscription?.subscriptionPeriod else { return false }
        switch self {
        case .monthly: return period.unit == .month
        case .yearly: return period.unit == .year
        }
    }
}

struct SubscriptionScreen: View {
    @ObservedObject var purchases: PurchaseService
    @State private var period: BillingPeriod = .yearly
    @State private var resultMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                currentPlan
                comparison
                VStack(alignment: .leading, spacing: 16) {
                    Text("Подписки").font(.title2.bold()).foregroundStyle(Color.atlasInk)
                    Text("Цена и условия загружаются из App Store для вашего региона.")
                        .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    Picker("Период оплаты", selection: $period) {
                        ForEach(BillingPeriod.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if visibleProducts.isEmpty {
                        unavailableProducts
                    } else {
                        ForEach(visibleProducts) { product in productCard(product) }
                    }
                }
                if let issue = purchases.lastIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(Color.orange)
                }
                accountActions
                subscriptionTerms
            }.padding(20)
        }
        .background(Color.atlasCanvas)
        .navigationTitle("Тарифы")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.atlasBlue)
        .refreshable { await purchases.startup() }
        .alert("Подписка", isPresented: Binding(
            get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } }
        )) { Button("Понятно") { resultMessage = nil } } message: { Text(resultMessage ?? "") }
    }

    private var visibleProducts: [Product] {
        purchases.products.filter { period.contains($0) }.sorted {
            if purchases.tier(for: $0) != purchases.tier(for: $1) {
                return rank(purchases.tier(for: $0)) < rank(purchases.tier(for: $1))
            }
            return $0.price < $1.price
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.largeTitle).foregroundStyle(Color.atlasBlue)
            Text("Расти вместе\nс задачами.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(Color.atlasInk)
                .fixedSize(horizontal: false, vertical: true)
            Text("От полевого обследования до процессов компании.")
                .font(.body).foregroundStyle(Color.atlasMuted)
        }
    }

    private var currentPlan: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: currentSymbol).font(.title2).foregroundStyle(Color.atlasBlue)
            VStack(alignment: .leading, spacing: 7) {
                Text("Ваш тариф · \(tierTitle(purchases.snapshot.tier))")
                    .font(.headline).foregroundStyle(Color.atlasInk)
                Text(stateDescription).font(.subheadline).foregroundStyle(Color.atlasMuted)
                if let date = purchases.snapshot.validUntil, purchases.snapshot.status == .active || purchases.snapshot.status == .billingGrace {
                    Text("Права подтверждены до \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
            }
            Spacer(minLength: 0)
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var currentSymbol: String {
        switch purchases.snapshot.status {
        case .active, .billingGrace: "checkmark.seal.fill"
        case .expired, .revoked: "clock"
        default: "person.crop.circle"
        }
    }

    private var stateDescription: String {
        switch purchases.state {
        case .unknown: "Проверяем покупки. Локальные данные доступны."
        case .notPurchased: "Базовые полевые инструменты и собственные данные доступны."
        case .unavailable: "App Store недоступен. Сохранённые данные остаются на устройстве."
        case .pending: "Покупка ожидает подтверждения App Store."
        case .verificationFailed: "Подпись покупки не подтверждена. Попробуйте восстановление."
        case .expired: "Подписка завершилась. Доступ к собственным данным сохранён."
        case .revoked: "App Store отозвал подписку. Доступ к собственным данным сохранён."
        case .verified:
            purchases.snapshot.source == .serverVerified
                ? "Подписка и права аккаунта подтверждены."
                : "Подписка подтверждена Apple. Командные права проверяются сервером отдельно."
        }
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Free · Pro · Business").font(.headline).foregroundStyle(Color.atlasInk)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 15) {
                GridRow {
                    Text("Возможности")
                    Text("Free")
                    Text("Pro")
                    Text("Business")
                }.font(.caption.weight(.semibold)).foregroundStyle(Color.atlasMuted)
                comparisonRow("Съёмка и локальные проекты", free: "✓", pro: "✓", business: "✓")
                comparisonRow("Полигоны и экспорт данных", free: "✓", pro: "✓", business: "✓")
                comparisonRow("Локальные заказы и сметы", free: "✓", pro: "✓", business: "✓")
                Divider().gridCellColumns(4)
                comparisonRow("Подписка", free: "—", pro: "Личная", business: "Для бизнеса")
                comparisonRow("Права организации¹", free: "—", pro: "—", business: "Сервер")
            }
            Text("¹ Командная работа требует подключённого сервера, аккаунта и подтверждённых прав организации. Облачная обработка и расширенные инструменты будут подключаться по мере готовности; локальное рабочее пространство уже доступно.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }
        .padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func comparisonRow(_ title: String, free: String, pro: String, business: String) -> some View {
        GridRow {
            Text(title).font(.caption).foregroundStyle(Color.atlasInk)
            Text(free).font(.caption.weight(.medium)).foregroundStyle(Color.atlasBlue)
            Text(pro).font(.caption.weight(.medium)).foregroundStyle(Color.atlasBlue)
            Text(business).font(.caption.weight(.medium)).foregroundStyle(Color.atlasBlue)
        }
    }

    private var unavailableProducts: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Подписки пока недоступны", systemImage: "cart")
                .font(.headline).foregroundStyle(Color.atlasInk)
            Text(purchases.products.isEmpty
                 ? "App Store не вернул продукты. Купить подписку можно после их подключения в магазине."
                 : "Для выбранного периода магазин не вернул продукты. Выберите другой период.")
                .font(.subheadline).foregroundStyle(Color.atlasMuted)
            Button("Обновить доступность", systemImage: "arrow.clockwise") {
                Task { await purchases.startup() }
            }.disabled(purchases.isBusy)
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func productCard(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(product.displayName).font(.title3.bold()).foregroundStyle(Color.atlasInk)
                    Text(tierTitle(purchases.tier(for: product) ?? .free))
                        .font(.caption.weight(.medium)).foregroundStyle(Color.atlasBlue)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(product.displayPrice).font(.title2.bold()).foregroundStyle(Color.atlasInk)
                    Text(periodLabel(product)).font(.caption).foregroundStyle(Color.atlasMuted)
                }
            }
            if !product.description.isEmpty {
                Text(product.description).font(.subheadline).foregroundStyle(Color.atlasMuted)
            }
            AtlasPrimaryButton(title: purchases.isBusy ? "Операция App Store…" : "Оформить подписку", systemImage: "arrow.right") {
                Task {
                    let result = await purchases.buy(product)
                    switch result {
                    case .completed:
                        resultMessage = "Покупка подтверждена App Store. Права аккаунта обновлены."
                    case .pending:
                        resultMessage = "Покупка ожидает подтверждения. Права обновятся после решения App Store."
                    case .cancelled: break
                    case .unavailable(let reason): resultMessage = reason
                    case .failed(let message): resultMessage = message
                    }
                }
            }.disabled(purchases.isBusy)
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var accountActions: some View {
        VStack(spacing: 16) {
            Button("Восстановить покупки") {
                Task { await purchases.restore() }
            }.disabled(purchases.isBusy)
            if purchases.isBusy { ProgressView().accessibilityLabel("Операция App Store") }
            Link("Управлять подпиской Apple", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
        }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
    }

    private var subscriptionTerms: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Оплата через Apple Account. Подписка продлевается автоматически по условиям App Store. Управлять продлением и отменить подписку можно в настройках Apple Account.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
            Link("Стандартные условия Apple (EULA)", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                .font(.caption)
        }
    }

    private func tierTitle(_ tier: PlanTier) -> String {
        switch tier {
        case .free: "Free"
        case .pro: "Pro"
        case .business: "Business"
        case .enterprise: "Enterprise"
        }
    }

    private func rank(_ tier: PlanTier?) -> Int {
        switch tier {
        case .free: 0
        case .pro: 1
        case .business: 2
        case .enterprise: 3
        case nil: 4
        }
    }

    private func periodLabel(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        let name: String
        switch period.unit {
        case .day: name = "дн."
        case .week: name = "нед."
        case .month: name = "мес."
        case .year: name = "год"
        @unknown default: name = "период"
        }
        return "за \(period.value) \(name)"
    }
}
