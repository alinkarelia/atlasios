#if ATLAS_BUSINESS_CHECKS
import Foundation

/// Headless checks exercise the actual store and JSON writer. On Linux, run
/// checks.sh with a no-op Combine shim; observation and iOS file protection still
/// require native tests. The test entry point is excluded from app builds.
@main
@MainActor
struct BusinessStoreChecks {
    private static var passedChecks = 0
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("business-checks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BusinessStore(directory: directory)
        try check(store.clients.isEmpty && store.tasks.isEmpty && store.quotes.isEmpty, "Workspace starts empty")

        for (text, expected) in [("0", Int64(0)), ("12,34", 1234), ("12.34", 1234), (" 0.01 ", 1), ("1000000000", 100_000_000_000)] {
            try check(BusinessQuote.priceMinor(from: text) == expected, "Exact price: \(text)")
        }
        for text in ["", "-1", "1.001", "1,2,3", "1abc", "NaN", "1e4", "1000000000.01", "1 000", "."] {
            try check(BusinessQuote.priceMinor(from: text) == nil, "Reject malformed price: \(text)")
        }

        var client = BusinessClient()
        client.name = "  Проверочный заказчик  "
        client.email = "client@example.test"
        try store.saveClient(client)
        try check(store.clients.first?.name == "Проверочный заказчик", "Trim client name")

        var order = BusinessWorkOrder()
        order.title = "Обмер дома"
        order.clientID = client.id
        try store.saveWorkOrder(order)
        var task = BusinessTask()
        task.title = "Проверить контрольные размеры"
        task.workOrderID = order.id
        try store.saveTask(task)
        try store.toggleTask(task)
        try check(store.completedTasks == 1, "Completion comes from actual task")

        var quote = BusinessQuote()
        quote.title = "Обмер"
        quote.clientID = client.id
        quote.lines = [QuoteLine(title: "Обмер", quantity: 3, unitPriceMinor: 12_345)]
        try store.saveQuote(quote)
        try check(store.quotes.first?.totalMinor == 37_035, "Exact integer quote total")
        var euro = BusinessQuote()
        euro.title = "Вторая валюта"
        euro.currency = .eur
        euro.lines = [QuoteLine(title: "Работа", quantity: 1, unitPriceMinor: 100)]
        try store.saveQuote(euro)
        try check(store.quoteTotals.count == 2, "Different currencies are not summed")
        try check(store.quoteTotals.first(where: { $0.currency == .rub })?.amount == Decimal(string: "370.35"), "Decimal dashboard total")

        try rejects("Linked client is protected") { try store.deleteClient(client.id) }
        try check(store.clients.count == 1, "Failed deletion preserves client")
        let reloaded = try BusinessStore(directory: directory)
        try check(reloaded.clients.map(\.id) == store.clients.map(\.id) && reloaded.clients.first?.email == client.email,
                  "Restart reloads clients and contacts")
        try check(reloaded.quotes == store.quotes && reloaded.tasks == store.tasks,
                  "Restart reloads quote lines, dates and completion")
        try check(reloaded.clients == store.clients, "Date precision survives restart")
        let backup = try store.exportBackup()
        defer { try? FileManager.default.removeItem(at: backup) }
        let backupObject = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any]
        try check(backupObject?["schemaVersion"] as? Int == 2, "Versioned export")

        try store.deleteWorkOrder(order.id)
        try check(store.workOrders.isEmpty && store.tasks.first?.workOrderID == nil, "Order removal preserves and unlinks tasks")
        var invalid = quote
        invalid.lines[0].quantity = Int.max
        try rejects("Reject overflowing quantity") { try store.saveQuote(invalid) }
        invalid = quote
        invalid.lines[0].unitPriceMinor = Int64.max
        try rejects("Reject overflowing price") { try store.saveQuote(invalid) }
        try check(store.quotes.first(where: { $0.id == quote.id })?.totalMinor == 37_035, "Invalid edit preserves original")

        // A directory at the destination reliably makes an atomic file write fail,
        // including when tests run as a privileged user.
        let archive = directory.appendingPathComponent("business-v1.json")
        let original = try Data(contentsOf: archive)
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        var unsaved = BusinessClient()
        unsaved.name = "Не должен появиться"
        try rejects("Disk failure") { try store.saveClient(unsaved) }
        try check(store.clients.count == 1 && store.lastIssue != nil, "Disk failure never publishes unsaved record")
        try FileManager.default.removeItem(at: archive)
        try original.write(to: archive, options: .atomic)
        try store.saveClient(unsaved)
        try check(store.clients.count == 2 && store.lastIssue == nil, "Successful save clears disk error")

        var legacy = backupObject ?? [:]
        legacy["schemaVersion"] = 1
        let legacyFormatter = ISO8601DateFormatter()
        for key in ["clients", "workOrders", "tasks", "quotes"] {
            var records = legacy[key] as? [[String: Any]] ?? []
            for index in records.indices {
                for dateKey in ["createdAt", "dueDate"] {
                    if let seconds = records[index][dateKey] as? Double {
                        records[index][dateKey] = legacyFormatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
                    }
                }
            }
            legacy[key] = records
        }
        try JSONSerialization.data(withJSONObject: legacy).write(to: archive, options: .atomic)
        let migrated = try BusinessStore(directory: directory)
        try check(migrated.quotes.first(where: { $0.id == quote.id })?.totalMinor == 37_035, "Legacy ISO schema loads")
        try migrated.saveClient(client)
        let migratedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any]
        try check(migratedObject?["schemaVersion"] as? Int == 2, "Legacy schema migrates only after successful save")

        var future = backupObject ?? [:]
        future["schemaVersion"] = 999
        let unsupported = try JSONSerialization.data(withJSONObject: future)
        try unsupported.write(to: archive, options: .atomic)
        try rejects("Unsupported schema") { _ = try BusinessStore(directory: directory) }
        try check(try Data(contentsOf: archive) == unsupported, "Unknown schema is not overwritten")
        let corrupt = Data("invalid JSON".utf8)
        try corrupt.write(to: archive, options: .atomic)
        try rejects("Corrupt archive") { _ = try BusinessStore(directory: directory) }
        try check(try Data(contentsOf: archive) == corrupt, "Corrupt file is not overwritten")
        print("BusinessStore: \(passedChecks) checks passed (headless Foundation; native observation and protection pending).")
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(message: message) }
        passedChecks += 1
    }
    static func rejects(_ message: String, action: () throws -> Void) throws {
        do { try action() } catch { passedChecks += 1; return }
        throw CheckFailure(message: "Expected rejection: \(message)")
    }
    struct CheckFailure: Error { let message: String }
}
#endif
