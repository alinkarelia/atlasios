import Foundation
import SwiftUI
import AtlasCore

/// Whole-site observations live on the cemetery polygon, while entrances,
/// facilities, paths and grave cards keep their own identities and geometry.
@MainActor
struct CemeterySiteScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    let cemetery: AtlasFeature
    let initialGeoTag: GeoTag?
    let isNew: Bool
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var geometry: FeatureGeometry
    @State private var address: String
    @State private var condition: String
    @State private var notes: String
    @State private var boundaryBasis: String
    @State private var reviewStatus: ReviewStatus
    @State private var children: [AtlasFeature] = []
    @State private var childToEdit: AtlasFeature?
    @State private var saving = false
    @State private var loading = true
    @State private var issue: String?
    @State private var askCancel = false
    @State private var showHistory = false
    @State private var photoIDs: [UUID]
    @State private var originalPhotoIDs: [UUID]
    @State private var photoIssue: String?
    @State private var photoBusy = false

    init(model: AtlasAppModel, project: AtlasProject, cemetery: AtlasFeature,
         initialGeoTag: GeoTag? = nil, isNew: Bool = false, onSaved: @escaping () -> Void) {
        self.model = model; self.project = project; self.cemetery = cemetery
        self.initialGeoTag = initialGeoTag; self.isNew = isNew; self.onSaved = onSaved
        _label = State(initialValue: cemetery.label); _geometry = State(initialValue: cemetery.geometry)
        _address = State(initialValue: cemetery.attributes["cemetery.address"] ?? "")
        _condition = State(initialValue: cemetery.attributes["cemetery.condition"] ?? "")
        _notes = State(initialValue: cemetery.notes)
        _boundaryBasis = State(initialValue: cemetery.attributes["boundaryBasis"] ?? "digitized")
        _reviewStatus = State(initialValue: cemetery.reviewStatus)
        var ids: [UUID] = []; var issue: String?
        if let raw = cemetery.attributes[CemeteryAttribute.sitePhotoIDs] {
            do {
                ids = try FieldTransferJSON.decode([UUID].self, from: Data(raw.utf8))
                guard ids.count <= 48, Set(ids).count == ids.count else { throw SurveyCardError.message("Список фотографий повреждён.") }
            } catch { issue = "Связи фотографий требуют проверки. Сохранение заблокировано: " + error.localizedDescription }
        }
        _photoIDs = State(initialValue: ids); _originalPhotoIDs = State(initialValue: ids); _photoIssue = State(initialValue: issue)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let photoIssue { Section("Проверьте исходные данные") { Text(photoIssue).foregroundStyle(.red) } }
                Section("Кладбище") {
                    TextField("Название", text: $label).accessibilityIdentifier("cemetery.card.name")
                    TextField("Адрес / ориентир", text: $address, axis: .vertical).lineLimit(2...4)
                    Text("Сведения об этом кладбище сохраняются отдельно от карточек отдельных захоронений.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
                SiteObjectPhotosSection(model: model, project: project, photoIDs: $photoIDs, busy: $photoBusy)
                Section("Состояние территории") {
                    TextField("Общее состояние: уход, растительность, повреждения…", text: $condition, axis: .vertical)
                        .lineLimit(3...8).accessibilityIdentifier("cemetery.card.condition")
                    TextField("Замечания специалиста по всей территории", text: $notes, axis: .vertical)
                        .lineLimit(4...12).accessibilityIdentifier("cemetery.card.notes")
                }
                Section {
                    SurveyPositionSummary(feature: cemetery, initialGeoTag: initialGeoTag)
                    SurveyBoundaryBasisPicker(selection: $boundaryBasis)
                    DisclosureGroup("Исправить границы вручную") { SurveyGeometryForm(geometry: $geometry) }
                    SurveyReviewPicker(selection: $reviewStatus)
                } header: { Text("Границы и качество") } footer: {
                    Text("Обводка, GPS-трек и физическая ограда — источники обследования. Юридические границы сверяются с документами отдельно.")
                }
                if !isNew {
                    Section("Связанные объекты") {
                        NavigationLink {
                            GeometryEditorScreen(model: model, project: project, cemeteryID: cemetery.id)
                        } label: { Label("Добавить объекты на карте", systemImage: "map") }
                        .accessibilityIdentifier("cemetery.card.map")
                        if loading { ProgressView("Читаем объекты кладбища") }
                        else {
                            LabeledContent("Активные карточки захоронений", value: "\(activeChildren.filter { $0.category == .grave }.count)")
                            LabeledContent("Входы", value: "\(activeChildren.filter { $0.category == .entrance }.count)")
                            LabeledContent("Мусорные контейнеры", value: "\(activeChildren.filter { $0.category == .wasteBin }.count)")
                            LabeledContent("Дороги и дорожки", value: "\(activeChildren.filter { $0.category == .road || $0.category == .path }.count)")
                            LabeledContent("Свалки / скопления мусора", value: "\(activeChildren.filter { $0.category == .wasteDump }.count)")
                            Text("Новые точки входов и контейнеров, линии дорог и карточки захоронений добавляются в полевом обследовании на карте этого кладбища.")
                                .font(.footnote).foregroundStyle(Color.atlasMuted)
                        }
                    }
                    facilitiesSection
                    Section("История и состояние записи") {
                        Button("История изменений", systemImage: "clock.arrow.circlepath") { showHistory = true }
                            .buttonStyle(.borderless)
                        SurveyRecordActions(feature: cemetery, disabled: saving || photoBusy || photoIssue != nil) { action in Task { await save(action: action) } }
                        Text("Изменение состояния кладбища не удаляет связанные захоронения и исходные фотографии.")
                            .font(.footnote).foregroundStyle(Color.atlasMuted)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
            .navigationTitle(isNew ? "Новое кладбище" : "Обследование кладбища")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { if changed { askCancel = true } else { dismiss() } }.disabled(saving || photoBusy)
                        .accessibilityIdentifier("cemetery.card.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await save() } }.disabled(saving || photoBusy || photoIssue != nil || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("cemetery.card.save")
                }
            }
            .interactiveDismissDisabled(changed || saving || photoBusy)
            .task { await reloadChildren() }
            .sheet(item: $childToEdit) { child in
                FeatureEditScreen(model: model, project: project, feature: child, cemetery: cemetery) {
                    Task { await reloadChildren() }; onSaved()
                }
            }
            .sheet(isPresented: $showHistory) { SurveyFeatureHistoryScreen(model: model, feature: cemetery) }
            .alert("Проверьте данные", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("Понятно", role: .cancel) { issue = nil }
            } message: { Text(issue ?? "") }
            .confirmationDialog("Закрыть без сохранения изменений?", isPresented: $askCancel, titleVisibility: .visible) {
                Button("Закрыть без сохранения", role: .destructive) { dismiss() }
                Button("Продолжить обследование", role: .cancel) { }
            }
        }
    }

    private var activeChildren: [AtlasFeature] { children.filter(SurveyFeatureLifecycle.isActive) }
    private var facilities: [AtlasFeature] {
        children.filter { [.entrance, .wasteBin, .wasteDump, .road, .path, .fence].contains($0.category) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
    private var facilitiesSection: some View {
        Section("Входы, проходы и инфраструктура") {
            if facilities.isEmpty && !loading { Text("Инфраструктура ещё не отмечена.").foregroundStyle(Color.atlasMuted) }
            ForEach(facilities) { child in
                Button { childToEdit = child } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(child.label).foregroundStyle(.primary)
                        Text(child.category.title).font(.caption).foregroundStyle(Color.atlasMuted)
                        if let width = child.attributes["survey.widthMeters"], let meters = Double(width), meters.isFinite {
                            Text("Ширина \(meters.formatted(.number.precision(.fractionLength(2)))) м · \(widthBasis(child))")
                                .font(.caption).foregroundStyle(Color.atlasMuted)
                        }
                        if !child.notes.isEmpty { Text(child.notes).font(.caption).foregroundStyle(Color.atlasMuted).lineLimit(3) }
                        if !SurveyFeatureLifecycle.isActive(child) { Text("Неактивная запись · можно восстановить").font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
        }
    }
    private func widthBasis(_ feature: AtlasFeature) -> String {
        switch feature.attributes["survey.widthBasis"] { case "measured": "измерено на месте"; case "document": "документ"; case "estimated": "оценка"; default: "источник не указан" }
    }
    private var changed: Bool {
        label != cemetery.label || geometry != cemetery.geometry || address != (cemetery.attributes["cemetery.address"] ?? "") ||
        condition != (cemetery.attributes["cemetery.condition"] ?? "") || notes != cemetery.notes ||
        boundaryBasis != (cemetery.attributes["boundaryBasis"] ?? "digitized") || reviewStatus != cemetery.reviewStatus || photoIDs != originalPhotoIDs
    }
    private func reloadChildren() async {
        let all = await model.features(in: project)
        children = all.filter { feature in
            guard feature.id != cemetery.id else { return false }
            let raw = feature.attributes[CemeteryAttribute.cemeteryID] ?? feature.attributes[CemeteryAttribute.legacyParentCemeteryID]
            return raw.flatMap(UUID.init(uuidString:)) == cemetery.id
        }
        loading = false
    }
    private func save(action: SurveyRecordAction? = nil) async {
        guard !saving, !photoBusy, photoIssue == nil else { return }
        saving = true; defer { saving = false }
        do {
            var value = cemetery
            value.label = label.trimmingCharacters(in: .whitespacesAndNewlines); value.geometry = geometry
            value.notes = notes; value.reviewStatus = reviewStatus
            value.attributes = try SurveyCardMetadata.retainingPosition(in: cemetery, changedGeometry: geometry, initialGeoTag: initialGeoTag)
            value.attributes[CemeteryAttribute.sitePhotoIDs] = String(decoding: try FieldTransferJSON.encode(photoIDs), as: UTF8.self)
            value.attributes["cemetery.address"] = address; value.attributes["cemetery.condition"] = condition
            value.attributes["boundaryBasis"] = boundaryBasis
            value.attributes["survey.savedAt"] = ISO8601DateFormatter().string(from: Date())
            if let action { value = action.applying(to: value) }
            if await model.saveFeature(value) != nil { onSaved(); dismiss() }
            else { issue = model.issue ?? "Не удалось сохранить обследование кладбища."; model.issue = nil }
        } catch { issue = error.localizedDescription }
    }
}
