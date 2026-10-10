import Combine
import Foundation

struct BusinessClient: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var contact = ""
    var phone = ""
    var email = ""
    var notes = ""
    var createdAt = Date()
}

enum WorkOrderStatus: String, Codable, CaseIterable, Identifiable {
    case planned, active, review, completed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .planned: "Запланирован"
        case .active: "В работе"
        case .review: "На проверке"
        case .completed: "Завершён"
        }
    }
}

struct BusinessWorkOrder: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = ""
    var clientID: UUID?
    var address = ""
    var notes = ""
    var status: WorkOrderStatus = .planned
    var dueDate: Date?
    var createdAt = Date()
}

struct BusinessTask: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = ""
    var workOrderID: UUID?
    var notes = ""
    var dueDate: Date?
    var isCompleted = false
    var createdAt = Date()
}

struct QuoteLine: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = ""
    var quantity = 1
    /// Integer minor currency units avoid accumulated floating-point errors.
    var unitPriceMinor: Int64 = 0
    var totalMinor: Int64 { unitPriceMinor * Int64(quantity) }
}

enum QuoteCurrency: String, Codable, CaseIterable, Identifiable {
    case rub = "RUB", eur = "EUR", usd = "USD"
    var id: String { rawValue }
    var title: String { rawValue }
}

struct BusinessQuote: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = ""
    var clientID: UUID?
    var currency: QuoteCurrency = .rub
    var lines: [QuoteLine] = []
    var notes = ""
    var createdAt = Date()
    var totalMinor: Int64 { lines.reduce(0) { $0 + $1.totalMinor } }
    var formattedTotal: String { Self.money(totalMinor, currency: currency) }

    static func money(_ minor: Int64, currency: QuoteCurrency) -> String {
        money(Decimal(minor) / 100, currency: currency)
    }

    static func money(_ amount: Decimal, currency: QuoteCurrency) -> String {
        amount.formatted(.currency(code: currency.rawValue))
    }

    static func priceMinor(from text: String) -> Int64? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              value >= 0, value <= 1_000_000_000 else { return nil }
        let scaled = value * 100
        var input = scaled
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard rounded == scaled else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

private struct BusinessArchive: Codable {
    // Version 2 stores Date's exact reference-time value instead of ISO seconds.
    var schemaVersion = 2
    var clients: [BusinessClient] = []
    var workOrders: [BusinessWorkOrder] = []
    var tasks: [BusinessTask] = []
    var quotes: [BusinessQuote] = []
}

enum BusinessStoreError: LocalizedError {
    case invalid(String)
    case newerVersion
    case linkedClient
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .newerVersion: "Эти бизнес-данные созданы более новой версией приложения. Обновите ATLAS; файл сохранён без изменений."
        case .linkedClient: "Клиент связан с заказами или сметами. Сначала измените клиента в этих записях."
        }
    }
}

/// Local business workspace. A failed disk write never publishes an unsaved change.
@MainActor
final class BusinessStore: ObservableObject {
    @Published private(set) var clients: [BusinessClient] = []
    @Published private(set) var workOrders: [BusinessWorkOrder] = []
    @Published private(set) var tasks: [BusinessTask] = []
    @Published private(set) var quotes: [BusinessQuote] = []
    @Published var lastIssue: String?

    private let fileURL: URL
    private var archive: BusinessArchive

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("business-v1.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let version = header?["schemaVersion"] as? Int else {
                throw BusinessStoreError.invalid("Бизнес-файл не содержит версии формата. Исходный файл сохранён.")
            }
            guard version == 1 || version == 2 else { throw BusinessStoreError.newerVersion }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = version == 1 ? .iso8601 : .deferredToDate
            var loaded = try decoder.decode(BusinessArchive.self, from: data)
            try Self.validateArchive(loaded)
            loaded.schemaVersion = 2 // migrate on the next successful atomic save
            archive = loaded
        } else {
            archive = BusinessArchive()
        }
        publish()
    }

    var activeOrders: Int { workOrders.filter { $0.status != .completed }.count }
    var completedTasks: Int { tasks.filter(\.isCompleted).count }
    var overdueTasks: Int {
        tasks.filter { !$0.isCompleted && ($0.dueDate.map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false) }.count
    }
    var quoteTotals: [(currency: QuoteCurrency, amount: Decimal)] {
        QuoteCurrency.allCases.compactMap { currency in
            let matching = quotes.filter { $0.currency == currency }
            guard !matching.isEmpty else { return nil }
            return (currency, matching.reduce(Decimal.zero) { $0 + Decimal($1.totalMinor) / 100 })
        }
    }

    func clientName(_ id: UUID?) -> String? { clients.first { $0.id == id }?.name }
    func orderName(_ id: UUID?) -> String? { workOrders.first { $0.id == id }?.title }

    func saveClient(_ draft: BusinessClient) throws {
        var client = draft
        client.name = trimmed(client.name)
        guard !client.name.isEmpty else { throw BusinessStoreError.invalid("Укажите имя или название клиента.") }
        try commit { Self.upsert(client, in: &$0.clients) }
    }

    func saveWorkOrder(_ draft: BusinessWorkOrder) throws {
        var order = draft
        order.title = trimmed(order.title)
        guard !order.title.isEmpty else { throw BusinessStoreError.invalid("Укажите название заказа.") }
        try validateClient(order.clientID)
        try commit { Self.upsert(order, in: &$0.workOrders) }
    }

    func saveTask(_ draft: BusinessTask) throws {
        var task = draft
        task.title = trimmed(task.title)
        guard !task.title.isEmpty else { throw BusinessStoreError.invalid("Укажите задачу.") }
        if let id = task.workOrderID, !workOrders.contains(where: { $0.id == id }) {
            throw BusinessStoreError.invalid("Заказ больше не существует. Выберите другой заказ.")
        }
        try commit { Self.upsert(task, in: &$0.tasks) }
    }

    func saveQuote(_ draft: BusinessQuote) throws {
        var quote = draft
        quote.title = trimmed(quote.title)
        guard !quote.title.isEmpty else { throw BusinessStoreError.invalid("Укажите название сметы.") }
        try validateClient(quote.clientID)
        guard !quote.lines.isEmpty else { throw BusinessStoreError.invalid("Добавьте хотя бы одну позицию сметы.") }
        var total: Int64 = 0
        for index in quote.lines.indices {
            quote.lines[index].title = trimmed(quote.lines[index].title)
            let line = quote.lines[index]
            guard !line.title.isEmpty, (1...1_000_000).contains(line.quantity),
                  (0...100_000_000_000).contains(line.unitPriceMinor) else {
                throw BusinessStoreError.invalid("Для каждой позиции нужны название, количество от 1 до 1 000 000 и неотрицательная цена до 1 миллиарда.")
            }
            let (lineTotal, overflow) = line.unitPriceMinor.multipliedReportingOverflow(by: Int64(line.quantity))
            let (newTotal, totalOverflow) = total.addingReportingOverflow(lineTotal)
            guard !overflow, !totalOverflow, newTotal <= 1_000_000_000_000_000 else {
                throw BusinessStoreError.invalid("Сумма сметы слишком велика.")
            }
            total = newTotal
        }
        try commit { Self.upsert(quote, in: &$0.quotes) }
    }

    func toggleTask(_ task: BusinessTask) throws {
        var updated = task
        updated.isCompleted.toggle()
        try saveTask(updated)
    }

    func deleteClient(_ id: UUID) throws {
        guard !workOrders.contains(where: { $0.clientID == id }), !quotes.contains(where: { $0.clientID == id }) else {
            throw BusinessStoreError.linkedClient
        }
        try commit { $0.clients.removeAll { $0.id == id } }
    }

    func deleteWorkOrder(_ id: UUID) throws {
        try commit { archive in
            archive.workOrders.removeAll { $0.id == id }
            for index in archive.tasks.indices where archive.tasks[index].workOrderID == id {
                archive.tasks[index].workOrderID = nil
            }
        }
    }

    func deleteTask(_ id: UUID) throws { try commit { $0.tasks.removeAll { $0.id == id } } }
    func deleteQuote(_ id: UUID) throws { try commit { $0.quotes.removeAll { $0.id == id } } }

    func exportBackup() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ATLAS-business-\(UUID().uuidString).json")
        try encoded(archive).write(to: url, options: .atomic)
        return url
    }

    private func validateClient(_ id: UUID?) throws {
        if let id, !clients.contains(where: { $0.id == id }) {
            throw BusinessStoreError.invalid("Клиент больше не существует. Выберите другого клиента.")
        }
    }

    private func commit(_ mutation: (inout BusinessArchive) -> Void) throws {
        var next = archive
        mutation(&next)
        try Self.validateArchive(next)
        do {
            try encoded(next).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            lastIssue = "Не удалось сохранить данные на устройстве: \(error.localizedDescription)"
            throw error
        }
        archive = next
        lastIssue = nil
        publish()
    }

    private func encoded(_ value: BusinessArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return try encoder.encode(value)
    }

    private func publish() {
        clients = archive.clients.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        workOrders = archive.workOrders.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        tasks = archive.tasks.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            return ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture)
        }
        quotes = archive.quotes.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func upsert<Value: Identifiable>(_ value: Value, in values: inout [Value]) where Value.ID == UUID {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
        else { values.append(value) }
    }

    private static func validateArchive(_ value: BusinessArchive) throws {
        let clientIDs = Set(value.clients.map(\.id))
        let orderIDs = Set(value.workOrders.map(\.id))
        guard clientIDs.count == value.clients.count, orderIDs.count == value.workOrders.count,
              Set(value.tasks.map(\.id)).count == value.tasks.count,
              Set(value.quotes.map(\.id)).count == value.quotes.count else {
            throw BusinessStoreError.invalid("Бизнес-файл содержит повторяющиеся идентификаторы. Исходный файл сохранён.")
        }
        guard value.workOrders.allSatisfy({ $0.clientID.map(clientIDs.contains) ?? true }),
              value.quotes.allSatisfy({ $0.clientID.map(clientIDs.contains) ?? true }),
              value.tasks.allSatisfy({ $0.workOrderID.map(orderIDs.contains) ?? true }) else {
            throw BusinessStoreError.invalid("Бизнес-файл содержит ссылки на отсутствующие записи. Исходный файл сохранён.")
        }
        for quote in value.quotes {
            guard Set(quote.lines.map(\.id)).count == quote.lines.count else {
                throw BusinessStoreError.invalid("В смете обнаружены повторяющиеся позиции.")
            }
            var total: Int64 = 0
            for line in quote.lines {
                guard (1...1_000_000).contains(line.quantity), (0...100_000_000_000).contains(line.unitPriceMinor) else {
                    throw BusinessStoreError.invalid("Бизнес-файл содержит недопустимые количества или цены. Исходный файл сохранён.")
                }
                let (next, overflow) = total.addingReportingOverflow(line.totalMinor)
                guard !overflow, next <= 1_000_000_000_000_000 else {
                    throw BusinessStoreError.invalid("Сумма сметы превышает допустимый предел.")
                }
                total = next
            }
        }
    }
}
