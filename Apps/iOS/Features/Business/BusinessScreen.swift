import SwiftUI
import UIKit

private enum BusinessSection: String, CaseIterable, Identifiable {
    case orders = "Заказы", tasks = "Задачи", clients = "Клиенты", quotes = "Сметы"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .orders: "briefcase"
        case .tasks: "checklist"
        case .clients: "person.2"
        case .quotes: "doc.text"
        }
    }
    var addTitle: String {
        switch self {
        case .orders: "Создать заказ"
        case .tasks: "Добавить задачу"
        case .clients: "Добавить клиента"
        case .quotes: "Создать смету"
        }
    }
}

private enum BusinessEditor: Identifiable {
    case client(BusinessClient), order(BusinessWorkOrder), task(BusinessTask), quote(BusinessQuote)
    var id: String {
        switch self {
        case .client(let value): "client-\(value.id)"
        case .order(let value): "order-\(value.id)"
        case .task(let value): "task-\(value.id)"
        case .quote(let value): "quote-\(value.id)"
        }
    }
}

private struct BusinessBackup: Identifiable { let id = UUID(); let url: URL }

struct BusinessScreen: View {
    @ObservedObject var store: BusinessStore
    @State private var section: BusinessSection = .orders
    @State private var query = ""
    @State private var editor: BusinessEditor?
    @State private var pendingDelete: BusinessEditor?
    @State private var backup: BusinessBackup?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    workspaceHeader
                    if let issue = store.lastIssue { issueBanner(issue) }
                    overview
                    Picker("Раздел бизнеса", selection: $section) {
                        ForEach(BusinessSection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    records
                }
                .padding(20)
            }
            .background(Color.atlasCanvas)
            .navigationTitle("Бизнес")
            .searchable(text: $query, prompt: "Поиск в текущем разделе")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Резервная копия JSON", systemImage: "square.and.arrow.up") { exportBackup() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(section.addTitle, systemImage: "plus") { createRecord() }
                        .labelStyle(.iconOnly)
                }
            }
            .sheet(item: $editor) { selection in
                switch selection {
                case .client(let value): ClientEditor(store: store, initial: value)
                case .order(let value): WorkOrderEditor(store: store, initial: value)
                case .task(let value): TaskEditor(store: store, initial: value)
                case .quote(let value): QuoteEditor(store: store, initial: value)
                }
            }
            .sheet(item: $backup) { BusinessShareSheet(url: $0.url) }
            .confirmationDialog("Удалить запись?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { deletePendingRecord() }
                Button("Отмена", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("Удаление сохраняется на устройстве. Задачи удалённого заказа останутся без привязки.")
            }
        }
        .tint(.atlasBlue)
    }

    private var workspaceHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "briefcase.fill")
                .font(.title2).foregroundStyle(Color.atlasBlue)
                .frame(width: 52, height: 52)
                .background(Color.atlasBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 7) {
                Text("Рабочее пространство").font(.headline).foregroundStyle(Color.atlasInk)
                Text("Заказы, клиенты и расчёты под рукой.")
                    .font(.subheadline).foregroundStyle(Color.atlasMuted)
                Label("На устройстве", systemImage: "iphone")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.atlasBlue)
            }
            Spacer(minLength: 0)
        }
    }

    private var overview: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                statistic(title: "Активные заказы", value: "\(store.activeOrders)", icon: "briefcase")
                statistic(title: "Задачи выполнены", value: "\(store.completedTasks) / \(store.tasks.count)", icon: "checkmark.circle")
            }
            if store.overdueTasks > 0 {
                Label("Просроченных задач: \(store.overdueTasks)", systemImage: "clock.badge.exclamationmark")
                    .font(.subheadline).foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !store.quotes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Суммы черновиков смет").font(.caption).foregroundStyle(Color.atlasMuted)
                    ForEach(store.quoteTotals, id: \.currency) { total in
                        Text(BusinessQuote.money(total.amount, currency: total.currency))
                            .font(.title3.weight(.semibold)).foregroundStyle(Color.atlasInk)
                    }
                    Text("Расчёт по сохранённым позициям. Это не выручка.")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private func statistic(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.atlasBlue)
            Text(value).font(.system(.title, design: .rounded, weight: .semibold)).foregroundStyle(Color.atlasInk)
            Text(title).font(.caption).foregroundStyle(Color.atlasMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var records: some View {
        switch section {
        case .orders:
            let values = store.workOrders.filter { matches([$0.title, $0.address, store.clientName($0.clientID) ?? ""]) }
            if values.isEmpty { emptyState("Заказы", detail: "Создайте первый заказ: объект, клиент, срок и этап работ.") }
            else {
                LazyVStack(spacing: 12) {
                    ForEach(values) { value in
                        recordCard(.order(value), title: value.title, subtitle: store.clientName(value.clientID) ?? "Без клиента", symbol: "briefcase", footer: value.address) {
                            HStack {
                                Text(value.status.title).font(.caption.weight(.medium)).foregroundStyle(value.status == .completed ? Color.green : Color.atlasBlue)
                                Spacer()
                                if let date = value.dueDate { Text(date, style: .date).font(.caption).foregroundStyle(Color.atlasMuted) }
                            }
                        }
                    }
                }
            }
        case .tasks:
            let values = store.tasks.filter { matches([$0.title, $0.notes, store.orderName($0.workOrderID) ?? ""]) }
            if values.isEmpty { emptyState("Задачи", detail: "Запланируйте съёмку, проверку или передачу результата.") }
            else {
                LazyVStack(spacing: 12) {
                    ForEach(values) { value in
                        HStack(alignment: .top, spacing: 14) {
                            Button {
                                perform { try store.toggleTask(value) }
                            } label: {
                                Image(systemName: value.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(value.isCompleted ? Color.green : Color.atlasMuted)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(value.isCompleted ? "Вернуть задачу в работу" : "Завершить задачу")
                            Button { editor = .task(value) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(value.title).font(.headline).strikethrough(value.isCompleted)
                                        .foregroundStyle(Color.atlasInk)
                                    if let name = store.orderName(value.workOrderID) { Text(name).font(.subheadline).foregroundStyle(Color.atlasMuted) }
                                    if let date = value.dueDate { Text(date, style: .date).font(.caption).foregroundStyle(Color.atlasMuted) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            recordMenu(.task(value))
                        }
                        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
        case .clients:
            let values = store.clients.filter { matches([$0.name, $0.contact, $0.email, $0.phone]) }
            if values.isEmpty { emptyState("Клиенты", detail: "Сохраните контакт заказчика и привяжите его к работам.") }
            else {
                LazyVStack(spacing: 12) {
                    ForEach(values) { value in
                        recordCard(.client(value), title: value.name, subtitle: value.contact, symbol: "person.crop.circle", footer: value.email.isEmpty ? value.phone : value.email) {
                            Text("Заказов: \(store.workOrders.filter { $0.clientID == value.id }.count)")
                                .font(.caption).foregroundStyle(Color.atlasMuted)
                        }
                    }
                }
            }
        case .quotes:
            let values = store.quotes.filter { matches([$0.title, store.clientName($0.clientID) ?? ""]) }
            if values.isEmpty { emptyState("Сметы", detail: "Добавьте работы, количество и цену. Итог рассчитывается автоматически.") }
            else {
                LazyVStack(spacing: 12) {
                    ForEach(values) { value in
                        recordCard(.quote(value), title: value.title, subtitle: store.clientName(value.clientID) ?? "Без клиента", symbol: "doc.text", footer: "Черновик · \(value.lines.count) поз.") {
                            Text(value.formattedTotal).font(.title3.weight(.semibold)).foregroundStyle(Color.atlasBlue)
                        }
                    }
                }
            }
        }
    }

    private func recordCard<Footer: View>(_ record: BusinessEditor, title: String, subtitle: String, symbol: String, footer: String, @ViewBuilder extra: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Button { editor = record } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol).font(.title3).foregroundStyle(Color.atlasBlue)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(title).font(.headline).foregroundStyle(Color.atlasInk)
                            if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(Color.atlasMuted) }
                            if !footer.isEmpty { Text(footer).font(.caption).foregroundStyle(Color.atlasMuted) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.buttonStyle(.plain)
                recordMenu(record)
            }
            extra()
        }
        .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func recordMenu(_ record: BusinessEditor) -> some View {
        Menu {
            Button("Изменить", systemImage: "pencil") { editor = record }
            Button("Удалить", systemImage: "trash", role: .destructive) { pendingDelete = record }
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Color.atlasMuted)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("Действия с записью")
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 18) {
            ContentUnavailableView(query.isEmpty ? "Пока нет записей" : "Ничего не найдено", systemImage: query.isEmpty ? section.symbol : "magnifyingglass", description: Text(query.isEmpty ? detail : "Попробуйте другой запрос."))
            if query.isEmpty {
                AtlasPrimaryButton(title: section.addTitle, systemImage: "plus") { createRecord() }
            }
        }.padding(.vertical, 10)
    }

    private func issueBanner(_ text: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.orange)
            Text(text).font(.subheadline)
            Spacer()
            Button("Закрыть", systemImage: "xmark") { store.lastIssue = nil }.labelStyle(.iconOnly)
        }.padding(16).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func matches(_ strings: [String]) -> Bool {
        query.isEmpty || strings.contains { $0.localizedStandardContains(query) }
    }

    private func createRecord() {
        switch section {
        case .orders: editor = .order(BusinessWorkOrder())
        case .tasks: editor = .task(BusinessTask())
        case .clients: editor = .client(BusinessClient())
        case .quotes: editor = .quote(BusinessQuote())
        }
    }

    private func deletePendingRecord() {
        guard let value = pendingDelete else { return }
        perform {
            switch value {
            case .client(let item): try store.deleteClient(item.id)
            case .order(let item): try store.deleteWorkOrder(item.id)
            case .task(let item): try store.deleteTask(item.id)
            case .quote(let item): try store.deleteQuote(item.id)
            }
        }
        pendingDelete = nil
    }

    private func exportBackup() { perform { backup = BusinessBackup(url: try store.exportBackup()) } }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { store.lastIssue = error.localizedDescription }
    }
}

private struct BusinessShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
