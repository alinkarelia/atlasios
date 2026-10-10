import SwiftUI

private struct BusinessFormShell<Content: View>: View {
    let title: String
    let save: () throws -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            Form { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") {
                            do { try save(); dismiss() }
                            catch { issue = error.localizedDescription }
                        }.fontWeight(.semibold)
                    }
                }
                .alert("Не удалось сохранить", isPresented: Binding(
                    get: { issue != nil }, set: { if !$0 { issue = nil } }
                )) { Button("Понятно") { issue = nil } } message: { Text(issue ?? "") }
        }.tint(.atlasBlue)
    }
}

struct ClientEditor: View {
    @ObservedObject var store: BusinessStore
    @State private var draft: BusinessClient
    init(store: BusinessStore, initial: BusinessClient) {
        self.store = store
        _draft = State(initialValue: initial)
    }
    var body: some View {
        BusinessFormShell(title: "Клиент", save: { try store.saveClient(draft) }) {
            Section("Заказчик") {
                TextField("Имя или название компании", text: $draft.name)
                TextField("Контактное лицо", text: $draft.contact)
            }
            Section("Контакты") {
                TextField("Телефон", text: $draft.phone).keyboardType(.phonePad)
                TextField("Email", text: $draft.email).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("Заметки") {
                TextField("Договорённости и подробности", text: $draft.notes, axis: .vertical).lineLimit(3...8)
            }
            Section {
                Label("Контакты хранятся на этом устройстве", systemImage: "iphone")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
            }
        }
    }
}

struct WorkOrderEditor: View {
    @ObservedObject var store: BusinessStore
    @State private var draft: BusinessWorkOrder
    @State private var hasDueDate: Bool
    init(store: BusinessStore, initial: BusinessWorkOrder) {
        self.store = store
        _draft = State(initialValue: initial)
        _hasDueDate = State(initialValue: initial.dueDate != nil)
    }
    var body: some View {
        BusinessFormShell(title: "Заказ", save: { try store.saveWorkOrder(draft) }) {
            Section("Объект") {
                TextField("Название заказа", text: $draft.title)
                TextField("Адрес или ориентир", text: $draft.address)
                clientPicker
            }
            Section("Работы") {
                Picker("Статус", selection: $draft.status) {
                    ForEach(WorkOrderStatus.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Срок выполнения", isOn: $hasDueDate)
                    .onChange(of: hasDueDate) { _, enabled in draft.dueDate = enabled ? (draft.dueDate ?? Date()) : nil }
                if hasDueDate {
                    DatePicker("Выполнить до", selection: Binding(
                        get: { draft.dueDate ?? Date() }, set: { draft.dueDate = $0 }
                    ), displayedComponents: .date)
                }
                TextField("Описание задания", text: $draft.notes, axis: .vertical).lineLimit(3...8)
            }
        }
    }
    private var clientPicker: some View {
        Picker("Клиент", selection: $draft.clientID) {
            Text("Без клиента").tag(Optional<UUID>.none)
            ForEach(store.clients) { Text($0.name).tag(Optional($0.id)) }
        }
    }
}

struct TaskEditor: View {
    @ObservedObject var store: BusinessStore
    @State private var draft: BusinessTask
    @State private var hasDueDate: Bool
    init(store: BusinessStore, initial: BusinessTask) {
        self.store = store
        _draft = State(initialValue: initial)
        _hasDueDate = State(initialValue: initial.dueDate != nil)
    }
    var body: some View {
        BusinessFormShell(title: "Задача", save: { try store.saveTask(draft) }) {
            Section("Задание") {
                TextField("Что нужно сделать", text: $draft.title)
                Picker("Заказ", selection: $draft.workOrderID) {
                    Text("Без привязки").tag(Optional<UUID>.none)
                    ForEach(store.workOrders) { Text($0.title).tag(Optional($0.id)) }
                }
                Toggle("Выполнена", isOn: $draft.isCompleted)
            }
            Section("Срок и подробности") {
                Toggle("Назначить срок", isOn: $hasDueDate)
                    .onChange(of: hasDueDate) { _, enabled in draft.dueDate = enabled ? (draft.dueDate ?? Date()) : nil }
                if hasDueDate {
                    DatePicker("Выполнить до", selection: Binding(
                        get: { draft.dueDate ?? Date() }, set: { draft.dueDate = $0 }
                    ), displayedComponents: .date)
                }
                TextField("Заметки", text: $draft.notes, axis: .vertical).lineLimit(3...8)
            }
        }
    }
}

private struct QuoteDraftLine: Identifiable {
    var id = UUID()
    var title = ""
    var quantity = 1
    var price = "0"

    init() {}
    init(_ line: QuoteLine) {
        id = line.id; title = line.title; quantity = line.quantity
        price = NSDecimalNumber(decimal: Decimal(line.unitPriceMinor) / 100).stringValue
    }
    func savedLine() throws -> QuoteLine {
        guard let minor = BusinessQuote.priceMinor(from: price) else {
            throw BusinessStoreError.invalid("Укажите цену числом с не более чем двумя знаками после запятой: \(title.isEmpty ? "позиция без названия" : title).")
        }
        guard (1...1_000_000).contains(quantity) else {
            throw BusinessStoreError.invalid("Количество должно быть от 1 до 1 000 000.")
        }
        return QuoteLine(id: id, title: title, quantity: quantity, unitPriceMinor: minor)
    }
}

struct QuoteEditor: View {
    @ObservedObject var store: BusinessStore
    @State private var draft: BusinessQuote
    @State private var lines: [QuoteDraftLine]
    init(store: BusinessStore, initial: BusinessQuote) {
        self.store = store
        _draft = State(initialValue: initial)
        _lines = State(initialValue: initial.lines.map(QuoteDraftLine.init))
    }
    var body: some View {
        BusinessFormShell(title: "Черновик сметы", save: save) {
            Section("Смета") {
                TextField("Название", text: $draft.title)
                Picker("Клиент", selection: $draft.clientID) {
                    Text("Без клиента").tag(Optional<UUID>.none)
                    ForEach(store.clients) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Валюта", selection: $draft.currency) {
                    ForEach(QuoteCurrency.allCases) { Text($0.title).tag($0) }
                }
            }
            ForEach($lines) { $line in
                Section {
                    TextField("Работа или услуга", text: $line.title)
                    HStack {
                        Text("Количество")
                        Spacer()
                        TextField("1", value: $line.quantity, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                    HStack {
                        Text("Цена, \(draft.currency.rawValue)")
                        Spacer()
                        TextField("0,00", text: $line.price)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .frame(maxWidth: 160)
                    }
                    if let saved = try? line.savedLine() {
                        LabeledContent("Сумма", value: BusinessQuote.money(saved.totalMinor, currency: draft.currency))
                            .foregroundStyle(Color.atlasMuted)
                    }
                    Button("Удалить позицию", role: .destructive) {
                        lines.removeAll { $0.id == line.id }
                    }
                }
            }
            Section {
                Button("Добавить позицию", systemImage: "plus") { lines.append(QuoteDraftLine()) }
            }
            Section("Итого") {
                if let total = draftTotal {
                    Text(BusinessQuote.money(total, currency: draft.currency))
                        .font(.title2.weight(.semibold)).foregroundStyle(Color.atlasBlue)
                } else {
                    Text("Проверьте количество и цены позиций.").foregroundStyle(Color.orange)
                }
                TextField("Условия и примечания", text: $draft.notes, axis: .vertical).lineLimit(2...6)
                Text("Черновик расчёта. Налоги и скидки автоматически не применяются; условия укажите в примечаниях.")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
            }
        }
    }

    private var draftTotal: Int64? {
        var total: Int64 = 0
        for line in lines {
            guard let saved = try? line.savedLine() else { return nil }
            let (next, overflow) = total.addingReportingOverflow(saved.totalMinor)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private func save() throws {
        var updated = draft
        updated.lines = try lines.map { try $0.savedLine() }
        try store.saveQuote(updated)
    }
}
