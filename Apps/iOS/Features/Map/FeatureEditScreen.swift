import SwiftUI
import AtlasCore

private struct MetricVertexDraft: Identifiable {
    let id = UUID()
    var point: MetricPoint2D
}

private struct GeographicVertexDraft: Identifiable {
    let id = UUID()
    var coordinate: GeographicCoordinate
}

extension FeatureCategory {
    var title: String {
        switch self {
        case .grave: "Могила"
        case .sector: "Сектор"
        case .path: "Дорожка"
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
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var category: FeatureCategory
    @State private var metric: [MetricVertexDraft]
    @State private var geographic: [GeographicVertexDraft]
    @State private var notes: String
    @State private var sector: String
    @State private var inscription: String
    @State private var boundaryBasis: String
    @State private var reviewStatus: ReviewStatus
    @State private var width = 2.4
    @State private var length = 3.6
    @State private var saving = false
    @State private var localIssue: String?

    init(model: AtlasAppModel, project: AtlasProject, feature: AtlasFeature?, onSaved: @escaping () -> Void) {
        self.model = model; self.project = project; self.feature = feature; self.onSaved = onSaved
        _label = State(initialValue: feature?.label ?? "")
        _category = State(initialValue: feature?.category ?? .grave)
        _notes = State(initialValue: feature?.notes ?? "")
        _sector = State(initialValue: feature?.attributes["sector"] ?? "")
        _inscription = State(initialValue: feature?.attributes["inscriptionDraft"] ?? "")
        _boundaryBasis = State(initialValue: feature?.attributes["boundaryBasis"] ?? "digitized")
        _reviewStatus = State(initialValue: feature?.reviewStatus ?? .draft)
        if case let .metricPolygon(polygon) = feature?.geometry {
            _metric = State(initialValue: polygon.vertices.map { MetricVertexDraft(point: $0) })
        }
        else { _metric = State(initialValue: []) }
        if case let .geographicPolygon(polygon) = feature?.geometry {
            _geographic = State(initialValue: polygon.vertices.map { GeographicVertexDraft(coordinate: $0) })
        }
        else { _geographic = State(initialValue: []) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Объект") {
                    TextField("Номер или название", text: $label)
                    Picker("Тип", selection: $category) {
                        ForEach(FeatureCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Сектор / ряд", text: $sector)
                }
                Section {
                    if case .localMeters = project.coordinateReference {
                        ForEach($metric) { $vertex in
                            let vertexID = vertex.id
                            let ordinal = (metric.firstIndex(where: { $0.id == vertexID }) ?? 0) + 1
                            HStack {
                                Text("\(ordinal)").foregroundStyle(Color.atlasMuted).frame(width: 24)
                                TextField("X", value: $vertex.point.x, format: .number).keyboardType(.numbersAndPunctuation)
                                    .accessibilityLabel("X вершины \(ordinal), метры")
                                TextField("Y", value: $vertex.point.y, format: .number).keyboardType(.numbersAndPunctuation)
                                    .accessibilityLabel("Y вершины \(ordinal), метры")
                                Button("Удалить", systemImage: "minus.circle", role: .destructive) {
                                    metric.removeAll { $0.id == vertexID }
                                }.labelStyle(.iconOnly)
                            }
                        }
                        Button("Добавить вершину", systemImage: "plus") {
                            metric.append(MetricVertexDraft(point: MetricPoint2D(x: 0, y: 0)))
                        }
                        if feature == nil {
                            HStack {
                                TextField("Ширина, м", value: $width, format: .number).keyboardType(.decimalPad)
                                TextField("Длина, м", value: $length, format: .number).keyboardType(.decimalPad)
                            }
                            Button("Создать прямоугольник по размерам") {
                                guard width.isFinite, length.isFinite, width > 0, length > 0 else {
                                    localIssue = "Длина и ширина должны быть больше нуля."; return
                                }
                                metric = [MetricPoint2D(x: 0, y: 0), MetricPoint2D(x: width, y: 0),
                                    MetricPoint2D(x: width, y: length), MetricPoint2D(x: 0, y: length)]
                                    .map { MetricVertexDraft(point: $0) }
                            }
                        }
                        if let frame = project.coordinateReference.frameID,
                           let area = try? PolygonGeometry.area(of: MetricPolygon(frameID: frame, vertices: metric.map(\.point), holes: metricHoles)) {
                            LabeledContent("Площадь проекции", value: area.formatted(.number.precision(.fractionLength(2))) + " м²")
                        }
                    } else {
                        ForEach($geographic) { $vertex in
                            let vertexID = vertex.id
                            let ordinal = (geographic.firstIndex(where: { $0.id == vertexID }) ?? 0) + 1
                            VStack(alignment: .leading) {
                                Text("Вершина \(ordinal)").font(.caption).foregroundStyle(Color.atlasMuted)
                                TextField("Долгота", value: $vertex.coordinate.longitude, format: .number.precision(.fractionLength(8)))
                                    .keyboardType(.numbersAndPunctuation)
                                TextField("Широта", value: $vertex.coordinate.latitude, format: .number.precision(.fractionLength(8)))
                                    .keyboardType(.numbersAndPunctuation)
                                Button("Удалить вершину", role: .destructive) {
                                    geographic.removeAll { $0.id == vertexID }
                                }
                            }
                        }
                        Button("Добавить вершину") {
                            geographic.append(GeographicVertexDraft(coordinate: GeographicCoordinate(longitude: 0, latitude: 0)))
                        }
                    }
                } header: { Text("Границы") } footer: { Text("Минимум три разные вершины. Самопересечения не сохраняются. При редактировании существующие отверстия сохраняются.") }
                Section {
                    Picker("Источник границы", selection: $boundaryBasis) {
                        Text("Разметка специалистом").tag("digitized")
                        Text("Документ / реестр").tag("document")
                        Text("Физическая ограда").tag("physicalFence")
                        Text("Предположение").tag("estimated")
                    }
                    Picker("Проверка", selection: $reviewStatus) {
                        Text("Черновик").tag(ReviewStatus.draft)
                        Text("Нужна проверка").tag(ReviewStatus.needsReview)
                        Text("Проверено специалистом").tag(ReviewStatus.reviewed)
                    }
                    Text("Проверка карточки не подтверждает сантиметровую точность координат.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                } header: { Text("Происхождение и качество") }
                Section {
                    TextField("Текст надписи для сверки", text: $inscription, axis: .vertical).lineLimit(3...8)
                } header: { Text("Надпись") } footer: { Text("Текст — наблюдение. Запись о погребении подтверждается реестром отдельно.") }
                Section("Примечания") { TextField("Заметки специалиста", text: $notes, axis: .vertical).lineLimit(3...8) }
            }
            .navigationTitle(feature == nil ? "Новый полигон" : "Карточка объекта")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await save() } }
                        .disabled(saving || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Проверьте данные", isPresented: Binding(get: { localIssue != nil }, set: { if !$0 { localIssue = nil } })) {
                Button("Понятно", role: .cancel) { localIssue = nil }
            } message: { Text(localIssue ?? "") }
        }
    }

    private var metricHoles: [[MetricPoint2D]] {
        if case let .metricPolygon(old) = feature?.geometry { return old.holes }
        return []
    }

    private var geographicHoles: [[GeographicCoordinate]] {
        if case let .geographicPolygon(old) = feature?.geometry { return old.holes }
        return []
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let geometry: FeatureGeometry
        switch project.coordinateReference {
        case let .localMeters(frame):
            geometry = .metricPolygon(MetricPolygon(frameID: frame, vertices: metric.map(\.point), holes: metricHoles))
        case .wgs84:
            geometry = .geographicPolygon(GeographicPolygon(vertices: geographic.map(\.coordinate), holes: geographicHoles))
        }
        var attributes = feature?.attributes ?? [:]
        attributes["sector"] = sector; attributes["inscriptionDraft"] = inscription
        attributes["boundaryBasis"] = boundaryBasis
        if attributes["accuracyBasis"] == nil { attributes["accuracyBasis"] = "unknown" }
        let value = AtlasFeature(id: feature?.id ?? UUID(), projectID: project.id, label: label,
            category: category, geometry: geometry, attributes: attributes, notes: notes,
            reviewStatus: reviewStatus, revision: feature?.revision ?? 0)
        if await model.saveFeature(value) != nil { onSaved(); dismiss() }
        else { localIssue = model.issue ?? "Не удалось сохранить полигон."; model.issue = nil }
    }
}
