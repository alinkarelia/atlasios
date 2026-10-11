import Foundation
import SwiftUI
import AtlasCore

extension FeatureCategory {
    var title: String {
        switch self {
        case .grave: "Захоронение"
        case .cemetery: "Кладбище"
        case .sector: "Сектор"
        case .path: "Дорожка"
        case .road: "Дорога"
        case .entrance: "Вход"
        case .wasteBin: "Мусорный контейнер"
        case .wasteDump: "Свалка / скопление мусора"
        case .fence: "Ограда"
        case .building: "Здание"
        case .boundary: "Граница"
        case .other: "Другой объект"
        }
    }
}

@MainActor
struct FeatureEditScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    let feature: AtlasFeature?
    let cemetery: AtlasFeature?
    let initialGeoTag: GeoTag?
    let isNew: Bool
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var featureID: UUID
    @State private var label: String
    @State private var category: FeatureCategory
    @State private var geometry: FeatureGeometry
    @State private var initialGeometry: FeatureGeometry
    @State private var notes: String
    @State private var sector: String
    @State private var widthText: String
    @State private var widthBasis: String
    @State private var boundaryBasis: String
    @State private var reviewStatus: ReviewStatus
    @State private var width = 2.4
    @State private var length = 3.6
    @State private var photoIDs: [UUID]
    @State private var originalPhotoIDs: [UUID]
    @State private var photoIssue: String?
    @State private var photoBusy = false
    @State private var askCancel = false
    @State private var saving = false
    @State private var localIssue: String?

    init(model: AtlasAppModel, project: AtlasProject, feature: AtlasFeature?, cemetery: AtlasFeature? = nil,
         initialGeoTag: GeoTag? = nil, isNew: Bool = false, onSaved: @escaping () -> Void) {
        self.model = model; self.project = project; self.feature = feature; self.cemetery = cemetery
        self.initialGeoTag = initialGeoTag; self.isNew = isNew || feature == nil; self.onSaved = onSaved
        _featureID = State(initialValue: feature?.id ?? UUID())
        _label = State(initialValue: feature?.label ?? "")
        _category = State(initialValue: feature?.category ?? .grave)
        _notes = State(initialValue: feature?.notes ?? "")
        _sector = State(initialValue: feature?.attributes["sector"] ?? "")
        _widthText = State(initialValue: feature?.attributes["survey.widthMeters"] ?? "")
        _widthBasis = State(initialValue: feature?.attributes["survey.widthBasis"] ?? "unknown")
        _boundaryBasis = State(initialValue: feature?.attributes["boundaryBasis"] ?? "digitized")
        _reviewStatus = State(initialValue: feature?.reviewStatus ?? .draft)
        let initial: FeatureGeometry
        if let feature { initial = feature.geometry }
        else { switch project.coordinateReference {
            case .localMeters(let frame): initial = .metricPolygon(MetricPolygon(frameID: frame, vertices: []))
            case .wgs84: initial = .geographicPolygon(GeographicPolygon(vertices: []))
        } }
        _geometry = State(initialValue: initial); _initialGeometry = State(initialValue: initial)
        var ids: [UUID] = []; var issue: String?
        if let raw = feature?.attributes["survey.photoIDs"] {
            do {
                ids = try FieldTransferJSON.decode([UUID].self, from: Data(raw.utf8))
                guard ids.count <= 48, Set(ids).count == ids.count else { throw SurveyCardError.message("Список фотографий объекта повреждён.") }
            } catch { issue = "Список фотографий не удалось прочитать. Сохранение заблокировано, чтобы сохранить исходные связи: " + error.localizedDescription }
        }
        _photoIDs = State(initialValue: ids); _originalPhotoIDs = State(initialValue: ids); _photoIssue = State(initialValue: issue)
    }

    var body: some View {
        if let feature, feature.category == .grave {
            BurialCardScreen(model: model, project: project, feature: feature, cemetery: cemetery,
                initialGeoTag: initialGeoTag, isNew: isNew, onSaved: onSaved)
        } else if let feature, feature.category == .cemetery {
            CemeterySiteScreen(model: model, project: project, cemetery: feature,
                initialGeoTag: initialGeoTag, isNew: isNew, onSaved: onSaved)
        } else { genericEditor }
    }

    private var genericEditor: some View {
        NavigationStack {
            Form {
                if let photoIssue { Section("Проверьте исходные данные") { Text(photoIssue).foregroundStyle(.red) } }
                Section("Объект") {
                    TextField("Номер или название", text: $label)
                    Picker("Тип", selection: $category) {
                        ForEach(FeatureCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.disabled(feature != nil)
                    if let cemetery { LabeledContent("Кладбище", value: cemetery.label) }
                    TextField("Сектор / ряд", text: $sector)
                }
                Section("Положение") {
                    SurveyPositionSummary(feature: original, initialGeoTag: initialGeoTag)
                    if feature != nil {
                        DisclosureGroup("Исправить координаты вручную") { SurveyGeometryForm(geometry: $geometry) }
                    } else {
                        SurveyGeometryForm(geometry: $geometry)
                        if case .metricPolygon = geometry {
                            HStack {
                                TextField("Ширина, м", value: $width, format: .number).keyboardType(.decimalPad)
                                TextField("Длина, м", value: $length, format: .number).keyboardType(.decimalPad)
                            }
                            Button("Прямоугольник по размерам") {
                                guard width.isFinite, length.isFinite, width > 0, length > 0,
                                      case .metricPolygon(var p) = geometry else { localIssue = "Введите положительные размеры."; return }
                                p.vertices = [.init(x: 0, y: 0), .init(x: width, y: 0), .init(x: width, y: length), .init(x: 0, y: length)]
                                geometry = .metricPolygon(p)
                            }
                        }
                    }
                }
                if category == .road || category == .path {
                    Section {
                        TextField("Ширина, м — если известна", text: $widthText).keyboardType(.decimalPad)
                        Picker("Источник ширины", selection: $widthBasis) {
                            Text("Источник не указан").tag("unknown")
                            Text("Измерена на месте").tag("measured")
                            Text("Документ").tag("document")
                            Text("Приблизительная оценка").tag("estimated")
                            if !["unknown", "measured", "document", "estimated"].contains(widthBasis) { Text(widthBasis).tag(widthBasis) }
                        }
                    } header: { Text("Проезд и проход") } footer: { Text("Пустая ширина означает, что измерение не выполнено. Линия показывает ось прохода.") }
                }
                Section("Происхождение и проверка") {
                    SurveyBoundaryBasisPicker(selection: $boundaryBasis)
                    SurveyReviewPicker(selection: $reviewStatus)
                }
                SiteObjectPhotosSection(model: model, project: project, photoIDs: $photoIDs, busy: $photoBusy)
                Section("Состояние и замечания") {
                    TextField("Замечания специалиста", text: $notes, axis: .vertical).lineLimit(3...10)
                }
                if let feature, !isNew {
                    Section { SurveyRecordActions(feature: feature, disabled: saving || photoBusy || photoIssue != nil) { action in Task { await save(action: action) } } }
                }
            }
            .scrollContentBackground(.hidden).background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
            .navigationTitle(isNew ? "Новый объект" : "Карточка объекта")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { if changed { askCancel = true } else { dismiss() } }.disabled(saving || photoBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await save() } }.disabled(saving || photoBusy || photoIssue != nil || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(changed || saving || photoBusy)
            .confirmationDialog("Закрыть без сохранения изменений?", isPresented: $askCancel, titleVisibility: .visible) {
                Button("Закрыть без сохранения", role: .destructive) { dismiss() }
                Button("Продолжить заполнение", role: .cancel) { }
            } message: { Text("Исходные фотографии остаются в проекте. Изменения карточки не будут сохранены.") }
            .alert("Проверьте данные", isPresented: Binding(get: { localIssue != nil }, set: { if !$0 { localIssue = nil } })) {
                Button("Понятно", role: .cancel) { localIssue = nil }
            } message: { Text(localIssue ?? "") }
        }
    }

    private var original: AtlasFeature {
        feature ?? AtlasFeature(id: featureID, projectID: project.id, label: label, category: category, geometry: geometry)
    }

    private var changed: Bool {
        label != (feature?.label ?? "") || category != (feature?.category ?? .grave) || geometry != initialGeometry ||
        notes != (feature?.notes ?? "") || sector != (feature?.attributes["sector"] ?? "") || photoIDs != originalPhotoIDs ||
        widthText != (feature?.attributes["survey.widthMeters"] ?? "") || widthBasis != (feature?.attributes["survey.widthBasis"] ?? "unknown") ||
        boundaryBasis != (feature?.attributes["boundaryBasis"] ?? "digitized") || reviewStatus != (feature?.reviewStatus ?? .draft)
    }

    private func save(action: SurveyRecordAction? = nil) async {
        guard !saving, !photoBusy, photoIssue == nil else { return }
        saving = true; defer { saving = false }
        do {
            var value = original
            value.label = label.trimmingCharacters(in: .whitespacesAndNewlines); value.category = category
            value.geometry = geometry; value.notes = notes; value.reviewStatus = reviewStatus
            value.attributes = try SurveyCardMetadata.retainingPosition(in: original, changedGeometry: geometry, initialGeoTag: initialGeoTag)
            if category == .grave {
                var burial = try BurialMetadata(attributes: value.attributes); burial.photoIDs = photoIDs
                value = try burial.applying(to: value)
            } else { value.attributes[CemeteryAttribute.sitePhotoIDs] = String(decoding: try FieldTransferJSON.encode(photoIDs), as: UTF8.self) }
            value.attributes["survey.savedAt"] = ISO8601DateFormatter().string(from: Date())
            value.attributes["sector"] = sector; value.attributes["boundaryBasis"] = boundaryBasis
            if let cemetery { value.attributes[CemeteryAttribute.cemeteryID] = cemetery.id.uuidString }
            if category == .road || category == .path {
                let text = widthText.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { value.attributes.removeValue(forKey: "survey.widthMeters") }
                else {
                    guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite, number > 0 else {
                        throw SurveyCardError.message("Ширина должна быть положительным числом или пустым полем.")
                    }
                    value.attributes["survey.widthMeters"] = String(number); value.attributes["survey.widthBasis"] = widthBasis
                }
            }
            if value.attributes["accuracyBasis"] == nil { value.attributes["accuracyBasis"] = "unknown" }
            if let action { value = action.applying(to: value) }
            if await model.saveFeature(value) != nil { onSaved(); dismiss() }
            else { localIssue = model.issue ?? "Не удалось сохранить объект."; model.issue = nil }
        } catch { localIssue = error.localizedDescription }
    }
}
