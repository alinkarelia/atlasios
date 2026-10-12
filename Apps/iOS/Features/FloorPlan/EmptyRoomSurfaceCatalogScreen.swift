import AtlasCore
import SwiftUI

private struct EmptyRoomCatalogEditorRoute: Identifiable {
    var id: UUID
    var source: EmptyRoomSurface?
}

@MainActor
struct EmptyRoomSurfaceCatalogScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    let document: EmptyRoomDocument
    let directory: URL
    let onSaved: @MainActor (EmptyRoomSurfaceReview) async -> Void
    @State private var review: EmptyRoomSurfaceReview
    @State private var measurements: [MeasurementRecord] = []
    @State private var editor: EmptyRoomCatalogEditorRoute?
    @State private var issue: String?
    @State private var journalAvailable = false
    @Environment(\.dismiss) private var dismiss

    init(model: AtlasAppModel, project: AtlasProject, document: EmptyRoomDocument, directory: URL,
         review: EmptyRoomSurfaceReview, onSaved: @escaping @MainActor (EmptyRoomSurfaceReview) async -> Void) {
        self.model = model; self.project = project; self.document = document; self.directory = directory
        self.onSaved = onSaved; _review = State(initialValue: review)
    }

    var body: some View {
        List {
            Section {
                Text("D — дверь помещения · W — окно · P — открытый проход · K — дверца шкафа, указанная оператором.")
                Text("Исходная классификация RoomPlan и габариты остаются в JSON. Решения специалиста и контрольные обмеры записываются отдельно; они не перестраивают 3D-модель.")
                Text("W×H — габарит поверхности. Это не гарантия ширины светового прохода или размера полотна. Hₛ — высота вдоль наклонной поверхности, H — вертикальный размер.")
            }.font(.caption).foregroundStyle(Color.atlasMuted)
            Section("Проёмы RoomPlan") {
                let openings = document.surfaces.filter { [.door, .window, .opening].contains($0.kind) }
                if openings.isEmpty { Text("Проёмы не распознаны; это не подтверждает их отсутствие.") }
                ForEach(openings) { surface in sourceRow(surface); measureLink(id: surface.id, role: review.latest(for: surface.id)?.role ?? .reported(surface.kind)) }
            }
            Section("Стены и пол") {
                ForEach(document.surfaces.filter { $0.kind == .wall || $0.kind == .floor }) { surface in sourceRow(surface); measureLink(id: surface.id, role: review.latest(for: surface.id)?.role ?? .reported(surface.kind)) }
            }
            Section("Ручные наблюдения") {
                if review.manualTargetIDs.isEmpty { Text("Дверцы шкафа RoomPlan отдельно не измеряет. Добавьте наблюдение и свяжите реальные контрольные обмеры.").font(.caption) }
                ForEach(review.manualTargetIDs, id: \.self) { id in
                    if let decision = review.latest(for: id) {
                        Button { editor = .init(id: id, source: nil) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(decision.role.symbol) · \(decision.label)").font(.headline)
                                Text("Вручную · \(review.controls(for: id).count) контрольных обмеров · Геометрия на модели не назначена")
                                    .font(.caption).foregroundStyle(Color.atlasMuted)
                                controls(id)
                            }.padding(.vertical, 4)
                        }.buttonStyle(.borderless).accessibilityIdentifier("emptyRoom.manualTarget.\(id.uuidString)")
                        measureLink(id: id, role: decision.role)
                    }
                }
                Button("Добавить дверцу / ручной объект", systemImage: "plus") { editor = .init(id: UUID(), source: nil) }
                    .buttonStyle(.borderless).accessibilityIdentifier("emptyRoom.addManualTarget")
                NavigationLink("Снять контрольный обмер", systemImage: "ruler") {
                    MeasurementToolsScreen(model: model, project: project)
                }
            }
            Section("История решений · \(review.events.count)") {
                ForEach(review.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(event.role.symbol) · \(event.label)").font(.subheadline.weight(.medium))
                        Text("\(event.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(event.semanticVerified ? "Классификация проверена оператором" : "Не проверено")")
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                        if !event.note.isEmpty { Text(event.note).font(.caption) }
                        if let control = event.observation {
                            Text("\(EmptyRoomReviewPresentation.notation(control.role)) \(EmptyRoomReviewPresentation.controlNumber(control.effectiveMeters)) м · \(EmptyRoomReviewPresentation.position(control.position)) · обмер \(control.measurementID.uuidString.prefix(8)), рев. \(control.measurementRevision)")
                                .font(.caption)
                        }
                    }.padding(.vertical, 3)
                }
            }
            Section { ShareLink(item: directory.appendingPathComponent(EmptyRoomSurfaceReviewPolicy.fileName)) { Label("Выгрузить журнал JSON", systemImage: "square.and.arrow.up") } }
        }
        .disabled(!journalAvailable)
        .navigationTitle("Поверхности и проёмы")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() }.disabled(false).accessibilityIdentifier("emptyRoom.catalog.close") } }
        .tint(.atlasAccent)
        .task {
            do {
                review = try await EmptyRoomSurfaceReviewStore(directory: directory, source: document).load()
                journalAvailable = true
            } catch { journalAvailable = false; issue = error.localizedDescription }
            measurements = await model.measurements(in: project)
        }
        .sheet(item: $editor) { route in
            EmptyRoomSurfaceReviewEditor(targetID: route.id, source: route.source,
                previous: review.latest(for: route.id), controls: review.controls(for: route.id), measurements: measurements) { event in
                let store = EmptyRoomSurfaceReviewStore(directory: directory, source: document)
                let next = try await store.append(event, expectedRevision: review.revision)
                review = next
                await onSaved(next)
            }
        }
        .alert("Проверка поверхности", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("Понятно") { issue = nil }
        } message: { Text(issue ?? "") }
    }
    private func measureLink(id: UUID, role: EmptyRoomReviewRole) -> some View {
        let target: MeasurementTarget
        let definition: MeasurementDefinition
        switch role {
        case .wall: target = .wall; definition = .structuralDimension
        case .floor: target = .floor; definition = .structuralDimension
        case .roomDoor: target = .door; definition = .clearOpening
        case .window: target = .window; definition = .clearOpening
        case .openPassage: target = .openPassage; definition = .clearOpening
        case .cabinetDoor: target = .cabinetDoor; definition = .doorLeaf
        case .unknown: target = .unspecified; definition = .unspecified
        }
        let context = MeasurementContext(role: .width, target: target, targetID: id, profileID: UUID(), definition: definition)
        return NavigationLink("Обмерить \(role.symbol) · \(id.uuidString.prefix(8))", systemImage: "ruler") {
            MeasurementToolsScreen(model: model, project: project, initialContext: context)
        }.accessibilityIdentifier("emptyRoom.measure.\(id.uuidString)")
    }

    private func sourceRow(_ surface: EmptyRoomSurface) -> some View {
        let decision = review.latest(for: surface.id)
        let role = decision?.role ?? .reported(surface.kind)
        return Button { editor = .init(id: surface.id, source: surface) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(role.symbol) · \(decision?.label ?? surface.title) · \(surface.id.uuidString.prefix(8))").font(.headline)
                if surface.kind == .floor {
                    Text("Проекция контура: \(EmptyRoomReviewPresentation.number(surface.floorAreaSquareMeters > 0 ? surface.floorAreaSquareMeters : nil)) м² · Отверстия отдельно не обследованы")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                } else {
                    Text("Габарит RoomPlan: W \(EmptyRoomReviewPresentation.number(surface.widthMeters)) × Hₛ \(EmptyRoomReviewPresentation.number(surface.heightMeters)) м")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
                Text("Источник: \(surface.title) · \(surface.confidence.title) уверенность классификации · \(decision?.semanticVerified == true ? "Тип проверен оператором" : "Не проверено")")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
                if let parent = surface.parentID { Text("Родительская поверхность: \(parent.uuidString.prefix(8))").font(.caption2).foregroundStyle(Color.atlasMuted) }
                controls(surface.id)
            }.padding(.vertical, 4)
        }.buttonStyle(.borderless).accessibilityIdentifier("emptyRoom.surface.\(surface.id.uuidString)")
    }
    @ViewBuilder private func controls(_ targetID: UUID) -> some View {
        let values = review.controls(for: targetID)
        ForEach(EmptyRoomReviewPresentation.ranges(values), id: \.self) { Text($0).font(.caption.weight(.medium)) }
        ForEach(values) { value in
            Text("\(EmptyRoomReviewPresentation.notation(value.role)) \(EmptyRoomReviewPresentation.controlNumber(value.effectiveMeters)) м · \(EmptyRoomReviewPresentation.position(value.position))\(value.positionNote.isEmpty ? "" : " · \(value.positionNote)") · \(EmptyRoomReviewPresentation.definition(value.definition))")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }
    }
}

@MainActor
private struct EmptyRoomSurfaceReviewEditor: View {
    let targetID: UUID
    let source: EmptyRoomSurface?
    let controls: [EmptyRoomControlObservation]
    let measurements: [MeasurementRecord]
    let save: (EmptyRoomReviewEvent) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var role: EmptyRoomReviewRole
    @State private var verified: Bool
    @State private var meaning: EmptyRoomDimensionMeaning
    @State private var coverage: Bool
    @State private var geometryVerified: Bool
    @State private var note = ""
    @State private var measurementID: UUID?
    @State private var saving = false
    @State private var issue: String?
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case label, note }

    init(targetID: UUID, source: EmptyRoomSurface?, previous: EmptyRoomReviewEvent?, controls: [EmptyRoomControlObservation],
         measurements: [MeasurementRecord], save: @escaping (EmptyRoomReviewEvent) async throws -> Void) {
        self.targetID = targetID; self.source = source; self.controls = controls; self.measurements = measurements; self.save = save
        _label = State(initialValue: previous?.label ?? source?.title ?? "Дверца шкафа")
        _role = State(initialValue: previous?.role ?? source.map { .reported($0.kind) } ?? .cabinetDoor)
        _verified = State(initialValue: previous?.semanticVerified ?? false)
        _meaning = State(initialValue: previous?.dimensionMeaning ?? (source == nil ? .manualControl : .reportedBounds))
        _coverage = State(initialValue: previous?.openingCoverageComplete ?? false)
        _geometryVerified = State(initialValue: previous?.openingGeometryVerified ?? false)
    }
    private var roles: [EmptyRoomReviewRole] {
        if source?.kind == .wall { return [.wall, .unknown] }
        if source?.kind == .floor { return [.floor, .unknown] }
        return [.roomDoor, .window, .openPassage, .cabinetDoor, .unknown]
    }
    private var eligibleMeasurements: [MeasurementRecord] {
        measurements.filter { record in
            guard record.revision > 0, record.effectiveMeters > 0,
                  record.context?.targetID == nil || record.context?.targetID == targetID,
                  !controls.contains(where: { $0.measurementID == record.id && $0.measurementRevision >= record.revision }) else { return false }
            let target = record.context?.target ?? .unspecified
            if target == .unspecified { return true }
            switch role {
            case .wall: return target == .wall
            case .floor: return target == .floor
            case .roomDoor: return target == .door
            case .window: return target == .window
            case .openPassage: return target == .openPassage
            case .cabinetDoor: return target == .cabinetDoor
            case .unknown: return false
            }
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Объект") {
                    TextField("Название", text: $label).focused($focusedField, equals: .label).accessibilityIdentifier("emptyRoom.review.label")
                    Picker("Тип", selection: $role) { ForEach(roles, id: \.self) { Text("\($0.symbol) · \($0.title)").tag($0) } }
                        .accessibilityIdentifier("emptyRoom.review.role")
                    Toggle("Классификация проверена мной", isOn: $verified).accessibilityIdentifier("emptyRoom.review.verified")
                    Text("Это решение о типе объекта. Оно не подтверждает сантиметровую точность и не исправляет исходную геометрию.").font(.caption)
                }
                if let source {
                    Section("Исходник RoomPlan · без изменений") {
                        Text("\(source.title) · \(source.confidence.title) уверенность классификации").accessibilityIdentifier("emptyRoom.source.classification")
                        Text("W \(EmptyRoomReviewPresentation.number(source.widthMeters)) × Hₛ \(EmptyRoomReviewPresentation.number(source.heightMeters)) м · габариты").accessibilityIdentifier("emptyRoom.source.bounds")
                        Text(source.id.uuidString).font(.caption.monospaced())
                    }
                } else {
                    Section { Text("Ручной объект не получает положение или контур из bounding box шкафа. Его размеры — только связанные контрольные обмеры.").font(.caption) }
                }
                Section("Смысл контрольного размера") {
                    Picker("Измерялось", selection: $meaning) { ForEach(EmptyRoomDimensionMeaning.allCases, id: \.self) { Text($0.title).tag($0) } }
                        .accessibilityIdentifier("emptyRoom.review.meaning")
                    Picker("Связать сохранённый обмер", selection: $measurementID) {
                        Text("Без нового обмера").tag(Optional<UUID>.none)
                        ForEach(eligibleMeasurements) { record in
                            Text("\(record.notation) \(EmptyRoomReviewPresentation.controlNumber(record.effectiveMeters)) м · \(record.label) · \(EmptyRoomReviewPresentation.position(record.context?.position.rawValue ?? "unspecified"))")
                                .tag(Optional(record.id))
                        }
                    }.accessibilityIdentifier("emptyRoom.review.measurement")
                    if let record = eligibleMeasurements.first(where: { $0.id == measurementID }) {
                        Text("Определение исходного обмера: \(EmptyRoomReviewPresentation.definition(record.context?.effectiveDefinition.rawValue))").font(.caption)
                        Text("\(record.frameID.map { "AR-система \($0.uuidString.prefix(8)); координаты не совмещаются с RoomPlan автоматически." } ?? "Ручной размер без координат AR.") История поправок и оригинал сохраняются в журнале.").font(.caption)
                    }
                    if eligibleMeasurements.isEmpty { Text("Подходящих новых обмеров нет. Сохраните W/H, тип объекта и позиции в инструментах, затем вернитесь в каталог.").font(.caption) }
                    Text("Нижний, средний и верхний обмеры сохраняются отдельно. Диапазон строится только внутри одного профиля с одинаковыми ролью, проекцией и смыслом размера.").font(.caption)
                }
                if source?.kind == .wall && role == .wall {
                    Section("Площадь стены за вычетом проёмов") {
                        Toggle("Все проёмы этой стены обследованы", isOn: $coverage)
                            .disabled(!verified)
                        Text("Подтверждайте после проверки всей стены. Площадь после вычета рассчитывается только при известной родительской стене, проверенном типе и настоящем контуре каждого проёма в плоскости стены. W×H вместо контура не вычитается.").font(.caption)
                    }
                }
                if let source, [.door, .window, .opening].contains(source.kind), [.roomDoor, .window, .openPassage].contains(role) {
                    Section("Геометрия проёма") {
                        Toggle("Исходный контур проёма проверен", isOn: $geometryVerified)
                            .disabled(!verified || meaning != .clearOpening)
                        Text("Подтверждайте только после проверки формы и положения контура в системе RoomPlan. Одна проверка типа и отдельный размер W/H не исправляют контур и не подтверждают площадь проёма.").font(.caption)
                    }
                }
                Section("Причина / место обмера") {
                    TextField("Что проверено и где", text: $note, axis: .vertical).lineLimit(3...8)
                        .focused($focusedField, equals: .note).accessibilityIdentifier("emptyRoom.review.note")
                    Text("Каждое сохранение добавляет решение в историю. Предыдущие записи не удаляются.").font(.caption)
                }
            }
            .pickerStyle(.menu)
            .navigationTitle("Проверить поверхность")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Сохранить") { Task { await commit() } }.accessibilityIdentifier("emptyRoom.review.save") }
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Готово") { focusedField = nil }.accessibilityIdentifier("emptyRoom.review.keyboardDone") }
            }
            .disabled(saving).interactiveDismissDisabled(saving)
            .onChange(of: role) { _, _ in measurementID = nil; geometryVerified = false; if role != .wall { coverage = false } }
            .onChange(of: meaning) { _, _ in geometryVerified = false }
            .onChange(of: measurementID) { _, _ in geometryVerified = false }
            .onChange(of: verified) { _, value in if !value { coverage = false; geometryVerified = false } }
            .alert("Проверка поверхности", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("Понятно") { issue = nil }
            } message: { Text(issue ?? "") }
        }.tint(.atlasAccent)
    }
    private func commit() async {
        guard !saving else { return }
        saving = true; defer { saving = false }
        do {
            let record = eligibleMeasurements.first { $0.id == measurementID }
            if measurementID != nil && record == nil { throw EmptyRoomReviewError.invalid("Выбранный обмер недоступен. Обновите журнал.") }
            let observation = try record.map { try EmptyRoomReviewCoreAdapter.snapshot($0) }
            let event = EmptyRoomReviewEvent(targetID: targetID, sourceSurfaceID: source?.id,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines), role: role,
                semanticVerified: verified, dimensionMeaning: meaning, openingCoverageComplete: coverage,
                openingGeometryVerified: geometryVerified,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines), observation: observation)
            try await save(event); dismiss()
        } catch { issue = error.localizedDescription }
    }
}
