import SwiftUI
import UniformTypeIdentifiers
import AtlasCore

struct CollaborativePlanImportScreen: View {
    @ObservedObject var model: AtlasAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selecting = false
    @State private var document: CollaborativeSurveyStoredPlan?
    @State private var exchangeData: Data?
    @State private var busy = false
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Откройте JSON плана, который передал руководитель. Все телефоны сохранят один идентификатор проекта, границу и распределение участков.")
                    Button("Выбрать план команды", systemImage: "doc.badge.arrow.up") { selecting = true }
                        .disabled(busy)
                        .accessibilityIdentifier("teamPlan.chooseFile")
                }
                if let document {
                    Section("Проверенный файл") {
                        LabeledContent("Проект", value: document.projectName ?? "Совместная съёмка")
                        LabeledContent("Участок", value: document.sourceFeatureLabel ?? "Граница совместной съёмки")
                        LabeledContent("Тип участка", value: document.sourceFeatureCategory?.title ?? "Не указан в исходном файле")
                        LabeledContent("Сотрудники", value: String(document.plan.workers.count))
                        LabeledContent("Ячейки", value: String(document.plan.cells.count))
                        LabeledContent("Версия", value: String(document.plan.revision))
                        Text("После импорта выберите себя в разделе «Участки команды и покрытие». Фото и модели передаются отдельно; этот файл содержит план и журнал покрытия.")
                            .font(.footnote).foregroundStyle(Color.atlasMuted)
                        Button("Открыть проект и импортировать", systemImage: "checkmark.circle") { Task { await accept() } }
                            .disabled(busy).accessibilityIdentifier("teamPlan.acceptImport")
                    }
                }
                if busy { ProgressView("Проверяем и сохраняем…") }
                if let issue { Section { Text(issue).foregroundStyle(.orange) } }
            }
            .scrollContentBackground(.hidden).background(Color.atlasCanvas)
            .navigationTitle("План команды").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(busy) } }
            .fileImporter(isPresented: $selecting, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): Task { await inspect(url) }
                case .failure(let error): issue = error.localizedDescription
                }
            }
        }
    }
    private func inspect(_ url: URL) async {
        guard !busy else { return }
        busy = true; issue = nil; document = nil; exchangeData = nil
        defer { busy = false }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try await Task.detached(priority: .utility) {
                let data = try CollaborativeSurveyStore.readBounded(url)
                return (try CollaborativeSurveyStore.decodeExchange(data), data)
            }.value
            document = result.0; exchangeData = result.1
        } catch { issue = error.localizedDescription }
    }
    private func accept() async {
        guard !busy, let document, let exchangeData else { return }
        busy = true; issue = nil; defer { busy = false }
        do {
            // Preview before making a database project, then compare-and-swap at save.
            let folder = model.directory.appendingPathComponent("Projects/\(document.projectID.uuidString)/Captures/Collaboration")
            let store = CollaborativeSurveyStore(projectID: document.projectID,
                reference: document.plan.coordinateReference, directory: folder)
            let current = try await store.load()
            let preview = try await store.previewExchange(exchangeData, expectedSHA256: current?.currentSHA256)
            let project = try await model.openCollaborativePlan(document)
            _ = try await store.acceptImport(preview, expectedSHA256: current?.currentSHA256)
            model.selectedProjectID = project.id
            await model.reload()
            model.fieldMaterialsDidChange(projectID: project.id)
            dismiss()
        } catch {
            issue = error.localizedDescription + " Если проект уже создан, он сохранён для повторного импорта; план команды не активирован этим действием."
        }
    }
}
