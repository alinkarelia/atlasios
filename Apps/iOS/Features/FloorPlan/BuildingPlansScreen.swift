import AtlasCore
import SwiftUI

private enum BuildingCatalogEditor: Identifiable {
    case building(String), floor(BuildingPlanFloorRecord, isNew: Bool)
    case apartment(BuildingPlanApartment, isNew: Bool), plan(AtlasFloorPlan, UUID?, isNew: Bool)
    var id: String {
        switch self {
        case .building: "building"
        case .floor(let floor, _): "floor-\(floor.floorIndex)"
        case .apartment(let apartment, _): "apartment-\(apartment.id)"
        case .plan(let plan, _, _): "plan-\(plan.id)"
        }
    }
}

private enum BuildingCatalogDeletion: Identifiable {
    case floor(Int), apartment(BuildingPlanApartment)
    var id: String {
        switch self { case .floor(let index): "floor-\(index)"; case .apartment(let apartment): "apartment-\(apartment.id)" }
    }
}

/// Project → real floorIndex → optional apartment → saved plan → room contours.
/// Apartment assignment changes the catalog only; coordinate frames stay intact.
struct BuildingPlansScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    private let store: BuildingPlanIndexStore
    @State private var index: BuildingPlanIndex
    @State private var plans: [AtlasFloorPlan] = []
    @State private var scans: [ScanRecord] = []
    @State private var editor: BuildingCatalogEditor?
    @State private var deletion: BuildingCatalogDeletion?
    @State private var issue: String?
    @State private var loading = true
    @State private var catalogAvailable = false
    @State private var busy = false

    init(model: AtlasAppModel, project: AtlasProject) {
        self.model = model; self.project = project
        store = BuildingPlanIndexStore(directory: model.directory, projectID: project.id)
        _index = State(initialValue: BuildingPlanIndex(projectID: project.id))
    }

    private var floorIndices: [Int] {
        Set(plans.map(\.floorIndex) + index.floors.map(\.floorIndex) + index.apartments.map(\.floorIndex)).sorted(by: >)
    }
    private var frameCount: Int { Set(plans.map(\.frameID)).count }
    private var staleAssociations: Int {
        index.associations.filter { link in
            !plans.contains { $0.id == link.planID && $0.floorIndex == link.floorIndex }
        }.count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header
                if loading { ProgressView("Загружаем обмеры…").frame(maxWidth: .infinity).padding(30) }
                else {
                    if !catalogAvailable {
                        Text("Каталог квартир недоступен. Обмеры можно открыть отдельно. Повторите загрузку, чтобы восстановить доступ к группировке.")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    }
                    if staleAssociations > 0 {
                        Label("\(staleAssociations) связей требуют проверки: обмер перенесён на другой этаж или отсутствует в этом проекте. Назначьте квартиру заново в настройках обмера.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if floorIndices.isEmpty { emptyState }
                    else { ForEach(floorIndices, id: \.self) { floorCard($0) } }
                    coordinateNotice
                    NavigationLink {
                        FloorPlanScreen(model: model, project: project)
                    } label: {
                        Label("Редактор комнат, стен и экспорта", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(AtlasSecondaryButtonStyle()).accessibilityIdentifier("building.editor")
                }
            }.padding(20)
        }
        .background(Color.atlasCanvas)
        .accessibilityIdentifier("building.catalog")
        .foregroundStyle(Color.atlasInk)
        .navigationTitle("Здание и этажи")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.atlasAccent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Новый этаж", systemImage: "square.stack.3d.up") { newFloor() }
                    Button("Новый обмер", systemImage: "plus.square") { newPlan(floorIndex: floorIndices.first ?? 0) }
                    Button("Название здания", systemImage: "pencil") { editor = .building(index.buildingName ?? project.name) }
                } label: { Label("Добавить", systemImage: "plus").labelStyle(.iconOnly) }
                .disabled(!catalogAvailable || busy)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $editor, onDismiss: { Task { await reload() } }) { item in editorView(item) }
        .alert("Каталог здания", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("Понятно") { issue = nil }
        } message: { Text(issue ?? "") }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button("Удалить из каталога", role: .destructive) { Task { await removeCatalogItem() } }
            Button("Отмена", role: .cancel) { deletion = nil }
        } message: {
            Text("Удаление квартиры снимает её связи с обмерами. Сами обмеры, комнаты и исходные сканы сохраняются.")
        }
        .disabled(busy)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ОБЪЕКТ / ОБМЕРЫ").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Color.atlasAccent)
                    Text(index.buildingName ?? project.name).font(.title.bold())
                }
                Spacer()
                Image(systemName: "building.2").font(.title).foregroundStyle(Color.atlasAccent)
            }
            HStack(spacing: 18) {
                metric("Этажи", value: "\(floorIndices.count)")
                metric("Квартиры / зоны", value: "\(index.apartments.count)")
                metric("Обмеры", value: "\(plans.count)")
            }
            Text("От комнаты и квартиры до дома: структура объекта хранится вместе с проектом и работает без сети.")
                .font(.subheadline).foregroundStyle(Color.atlasMuted)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(Color.atlasMuted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            AtlasEmptyState(title: "Соберите структуру здания", message: "Создайте этажи и квартиры заранее. Сохранённые RoomPlan-обмеры появятся на своих этажах; каждый можно назначить квартире или общей зоне.", symbol: "building.2")
            Button("Добавить первый этаж", systemImage: "plus") { newFloor() }
                .buttonStyle(AtlasPrimaryButtonStyle()).disabled(!catalogAvailable)
        }
    }

    private var coordinateNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(frameCount > 1 ? "Не совмещены: \(frameCount) систем координат" : "Координаты исходных обмеров", systemImage: "viewfinder")
                .font(.subheadline.weight(.semibold))
            Text("Этаж и квартира — организационные связи. Они не перемещают геометрию. В обзоре рядом отображаются только обмеры с одним сохранённым frameID; это не подтверждает точность их фактического совмещения. Независимые системы показаны отдельно.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
            Text("Площадь — сумма валидных контуров комнат с вычетом отверстий. Пересечения и повторные съёмки не вычитаются; сумма не является площадью здания по нормативу.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }.padding(16).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private func floorCard(_ floorIndex: Int) -> some View {
        let floorPlans = plans.filter { $0.floorIndex == floorIndex }
        let apartments = index.apartments.filter { $0.floorIndex == floorIndex }
        let unassigned = floorPlans.filter { index.apartment(for: $0.id, floorIndex: floorIndex) == nil }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(index.floorName(floorIndex)).font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("building.floor.\(floorIndex)")
                    Text("Номер этажа: \(floorIndex) · \(floorPlans.count) обмеров · \(areaLabel(floorPlans))")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
                Spacer()
                Menu {
                    Button("Название этажа", systemImage: "pencil") {
                        editor = .floor(.init(floorIndex: floorIndex, name: index.floorName(floorIndex)), isNew: false)
                    }
                    Button("Квартира или зона", systemImage: "plus.rectangle.on.rectangle") {
                        editor = .apartment(.init(floorIndex: floorIndex, label: ""), isNew: true)
                    }
                    Button("Новый обмер", systemImage: "plus.square") { newPlan(floorIndex: floorIndex) }
                    if floorPlans.isEmpty && apartments.isEmpty {
                        Button("Удалить пустой этаж", systemImage: "trash", role: .destructive) { deletion = .floor(floorIndex) }
                    }
                } label: { Label("Настройки этажа", systemImage: "ellipsis").labelStyle(.iconOnly).padding(8) }
                .disabled(!catalogAvailable)
            }
            ForEach(apartments) { apartment in
                apartmentGroup(apartment, plans: floorPlans.filter { index.apartment(for: $0.id, floorIndex: floorIndex)?.id == apartment.id })
            }
            if !unassigned.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Без квартиры / общие обмеры").font(.subheadline.weight(.semibold)).foregroundStyle(Color.atlasMuted)
                    ForEach(unassigned) { planRow($0) }
                }
            }
            if floorPlans.isEmpty && apartments.isEmpty {
                Text("Этаж пока пуст. Добавьте квартиру, зону или локальный обмер.").font(.subheadline).foregroundStyle(Color.atlasMuted)
            }
            if !floorPlans.isEmpty {
                NavigationLink {
                    BuildingFloorOverviewScreen(title: index.floorName(floorIndex), plans: floorPlans, scans: scans)
                } label: {
                    Label("Обзор этажа · \(Set(floorPlans.map(\.frameID)).count) групп координат", systemImage: "square.3.layers.3d")
                        .font(.subheadline.weight(.medium))
                }.accessibilityIdentifier("building.floorOverview.\(floorIndex)")
            }
        }.padding(18).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 22))
    }

    private func apartmentGroup(_ apartment: BuildingPlanApartment, plans: [AtlasFloorPlan]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(apartment.label, systemImage: "door.left.hand.closed").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("building.apartment.\(apartment.id.uuidString)")
                Spacer()
                Menu {
                    Button("Изменить", systemImage: "pencil") { editor = .apartment(apartment, isNew: false) }
                    Button("Новый обмер", systemImage: "plus.square") { newPlan(floorIndex: apartment.floorIndex, apartmentID: apartment.id) }
                    Button("Удалить квартиру", systemImage: "trash", role: .destructive) { deletion = .apartment(apartment) }
                } label: { Label("Настройки квартиры", systemImage: "ellipsis").labelStyle(.iconOnly).padding(6) }
                .disabled(!catalogAvailable)
            }
            if plans.isEmpty { Text("Назначьте существующий обмер или создайте новый.").font(.caption).foregroundStyle(Color.atlasMuted) }
            else {
                Text("\(plans.reduce(0) { $0 + $1.rooms.count }) комнат · \(areaLabel(plans))")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
                ForEach(plans) { planRow($0) }
            }
        }.padding(14).background(Color.atlasCanvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
    }

    private func planRow(_ plan: AtlasFloorPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                NavigationLink {
                    FloorPlanScreen(model: model, project: project, initialPlanID: plan.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.atlasInk)
                        Text("\(plan.rooms.count) комнат · \(plan.walls.count) стен · \(areaLabel([plan]))")
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                        Text("Система \(plan.frameID.uuidString.prefix(8)) · \(sourceLabel(plan.frameID))")
                            .font(.caption2).foregroundStyle(Color.atlasMuted)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("building.plan.\(plan.id.uuidString)")
                Spacer()
                Button("Изменить этаж и квартиру", systemImage: "slider.horizontal.3") {
                    editor = .plan(plan, index.apartment(for: plan.id, floorIndex: plan.floorIndex)?.id, isNew: false)
                }.labelStyle(.iconOnly).disabled(!catalogAvailable)
            }
            if !plan.rooms.isEmpty {
                DisclosureGroup("Комнаты") {
                    ForEach(plan.rooms) { room in
                        HStack {
                            Text(room.name)
                            Spacer()
                            Text((try? PolygonGeometry.area(of: room.boundary)).map { $0.formatted(.number.precision(.fractionLength(2))) + " м²" } ?? "Контур требует проверки")
                                .foregroundStyle(Color.atlasMuted)
                        }.font(.caption).padding(.vertical, 3)
                    }
                }.font(.caption)
            }
        }
    }

    private func sourceLabel(_ frameID: UUID) -> String {
        let matches = scans.filter { $0.frameID == frameID }
        if matches.contains(where: { $0.source == .roomPlan }) { return "сохранённый RoomPlan" }
        if matches.contains(where: { $0.source == .liDAR }) { return "сохранённая LiDAR-съёмка" }
        return "локальная система; источник не подтверждён сканом"
    }

    private func areaLabel(_ values: [AtlasFloorPlan]) -> String {
        let rooms = values.flatMap(\.rooms)
        let areas = rooms.compactMap { try? PolygonGeometry.area(of: $0.boundary) }
        let area = areas.reduce(0, +).formatted(.number.precision(.fractionLength(2))) + " м²"
        return areas.count == rooms.count ? area : area + " · \(rooms.count - areas.count) контуров требуют проверки"
    }

    @ViewBuilder private func editorView(_ item: BuildingCatalogEditor) -> some View {
        switch item {
        case .building(let name):
            BuildingCatalogNameForm(title: "Название здания", initial: name) { value in index = try await store.renameBuilding(value) }
        case .floor(let floor, let isNew):
            BuildingCatalogFloorForm(initial: floor, isNew: isNew, occupiedIndices: floorIndices) { value in index = try await store.saveFloor(value) }
        case .apartment(let apartment, let isNew):
            BuildingCatalogApartmentForm(initial: apartment, isNew: isNew) { value in index = try await store.saveApartment(value) }
        case .plan(let plan, let apartmentID, let isNew):
            BuildingCatalogPlanForm(initial: plan, apartmentID: apartmentID, isNew: isNew, apartments: index.apartments) { draft, assignment in
                try await savePlan(draft, apartmentID: assignment)
            }
        }
    }

    private var deletionTitle: String {
        switch deletion { case .floor(let value): "Удалить пустой этаж \(value)?"; case .apartment(let apartment): "Удалить «\(apartment.label)»?"; case nil: "Удалить запись?" }
    }

    private func newFloor() {
        let used = Set(floorIndices)
        let next = (0...500).first { !used.contains($0) } ?? 0
        editor = .floor(.init(floorIndex: next, name: "Этаж \(next)"), isNew: true)
    }
    private func newPlan(floorIndex: Int, apartmentID: UUID? = nil) {
        editor = .plan(.init(projectID: project.id, frameID: UUID(), name: "Новый обмер", floorIndex: floorIndex), apartmentID, isNew: true)
    }
    private func reload() async {
        plans = await model.plans(in: project)
        scans = await model.scans(in: project)
        do { index = try await store.load(); catalogAvailable = true }
        catch { catalogAvailable = false; issue = error.localizedDescription }
        loading = false
    }
    private func savePlan(_ draft: AtlasFloorPlan, apartmentID: UUID?) async throws {
        guard draft.projectID == project.id else { throw BuildingPlanIndexError.invalid("Обмер относится к другому проекту.") }
        guard let saved = await model.savePlan(draft) else { throw BuildingPlanIndexError.invalid(model.issue ?? "Обмер не сохранён.") }
        if let position = plans.firstIndex(where: { $0.id == saved.id }) { plans[position] = saved }
        else { plans.append(saved) }
        do { index = try await store.assign(planID: saved.id, apartmentID: apartmentID, floorIndex: saved.floorIndex) }
        catch { issue = "Обмер «\(saved.name)» сохранён, но связь с квартирой не записана: \(error.localizedDescription). Откройте настройки обмера и назначьте квартиру снова." }
    }
    private func removeCatalogItem() async {
        guard let deletion else { return }
        busy = true
        defer { busy = false; self.deletion = nil }
        do {
            switch deletion {
            case .apartment(let apartment): index = try await store.deleteApartment(apartment.id)
            case .floor(let floorIndex):
                let current = await model.plans(in: project)
                guard !current.contains(where: { $0.floorIndex == floorIndex }) else { throw BuildingPlanIndexError.invalid("На этаже есть обмеры. Перенесите их перед удалением этажа.") }
                index = try await store.deleteFloor(floorIndex)
            }
        } catch { issue = error.localizedDescription }
    }
}

private struct BuildingCatalogFormShell<Content: View>: View {
    let title: String
    let save: () async throws -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form { content() }
                .scrollContentBackground(.hidden).background(Color.atlasCanvas)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if busy { ProgressView() }
                        else {
                            Button("Сохранить") {
                                busy = true
                                Task {
                                    defer { busy = false }
                                    do { try await save(); dismiss() }
                                    catch { issue = error.localizedDescription }
                                }
                            }.fontWeight(.semibold)
                        }
                    }
                }
                .disabled(busy).interactiveDismissDisabled(busy)
                .alert("Проверьте данные", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                    Button("Понятно") { issue = nil }
                } message: { Text(issue ?? "") }
        }.tint(.atlasAccent)
    }
}

private struct BuildingCatalogNameForm: View {
    let title: String
    @State private var name: String
    let save: (String) async throws -> Void
    init(title: String, initial: String, save: @escaping (String) async throws -> Void) {
        self.title = title; self.save = save; _name = State(initialValue: initial)
    }
    var body: some View {
        BuildingCatalogFormShell(title: title, save: { try await save(name) }) {
            Section("Здание") { TextField("Название или адрес", text: $name) }
            Section { Text("Название используется в локальном каталоге этого проекта.").font(.caption).foregroundStyle(Color.atlasMuted) }
        }
    }
}

private struct BuildingCatalogFloorForm: View {
    @State private var floor: BuildingPlanFloorRecord
    let isNew: Bool
    let occupiedIndices: [Int]
    let save: (BuildingPlanFloorRecord) async throws -> Void
    init(initial: BuildingPlanFloorRecord, isNew: Bool, occupiedIndices: [Int], save: @escaping (BuildingPlanFloorRecord) async throws -> Void) {
        _floor = State(initialValue: initial); self.isNew = isNew; self.occupiedIndices = occupiedIndices; self.save = save
    }
    var body: some View {
        BuildingCatalogFormShell(title: isNew ? "Новый этаж" : "Название этажа", save: {
            guard !isNew || !occupiedIndices.contains(floor.floorIndex) else { throw BuildingPlanIndexError.invalid("Такой этаж уже есть. Измените номер или откройте его настройки.") }
            try await save(floor)
        }) {
            Section("Этаж") {
                TextField("Название, например «Цоколь»", text: $floor.name)
                if isNew { Stepper("Номер: \(floor.floorIndex)", value: $floor.floorIndex, in: -100...500) }
                else { Text("Номер: \(floor.floorIndex)") }
            }
            Section { Text("Номер хранится в каждом обмере. Чтобы перенести обмер на другой этаж, откройте настройки этого обмера.").font(.caption).foregroundStyle(Color.atlasMuted) }
        }
    }
}

private struct BuildingCatalogApartmentForm: View {
    @State private var apartment: BuildingPlanApartment
    let isNew: Bool
    let save: (BuildingPlanApartment) async throws -> Void
    init(initial: BuildingPlanApartment, isNew: Bool, save: @escaping (BuildingPlanApartment) async throws -> Void) {
        _apartment = State(initialValue: initial); self.isNew = isNew; self.save = save
    }
    var body: some View {
        BuildingCatalogFormShell(title: isNew ? "Квартира или зона" : "Настройки квартиры", save: { try await save(apartment) }) {
            Section("Помещение") {
                TextField("Квартира 12, секция А, общий коридор…", text: $apartment.label)
                Stepper("Этаж: \(apartment.floorIndex)", value: $apartment.floorIndex, in: -100...500)
            }
            Section { Text("В одну квартиру можно назначить несколько обмеров. Это группировка документов; независимые съёмки сохраняют свои координаты.").font(.caption).foregroundStyle(Color.atlasMuted) }
        }
    }
}

private struct BuildingCatalogPlanForm: View {
    @State private var plan: AtlasFloorPlan
    @State private var apartmentID: UUID?
    let isNew: Bool
    let apartments: [BuildingPlanApartment]
    let save: (AtlasFloorPlan, UUID?) async throws -> Void
    init(initial: AtlasFloorPlan, apartmentID: UUID?, isNew: Bool, apartments: [BuildingPlanApartment], save: @escaping (AtlasFloorPlan, UUID?) async throws -> Void) {
        _plan = State(initialValue: initial); _apartmentID = State(initialValue: apartmentID)
        self.isNew = isNew; self.apartments = apartments; self.save = save
    }
    var body: some View {
        BuildingCatalogFormShell(title: isNew ? "Новый локальный обмер" : "Этаж и квартира обмера", save: {
            var draft = plan
            draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.name.isEmpty, draft.name.count <= 160 else { throw BuildingPlanIndexError.invalid("Введите название обмера от 1 до 160 символов.") }
            try await save(draft, apartmentID)
        }) {
            Section("Обмер") {
                TextField("Название обмера", text: $plan.name)
                Stepper("Этаж: \(plan.floorIndex)", value: $plan.floorIndex, in: -100...500)
                Picker("Квартира / зона", selection: $apartmentID) {
                    Text("Без квартиры / общий обмер").tag(Optional<UUID>.none)
                    ForEach(apartments.filter { $0.floorIndex == plan.floorIndex }) { Text($0.label).tag(Optional($0.id)) }
                }
            }
            Section("Координаты") {
                Text("Система: \(plan.frameID.uuidString)").font(.caption.monospaced())
                Text(isNew ? "Новый обмер создаётся пустым в отдельной локальной системе в метрах. После сохранения добавьте комнаты и стены в редакторе." : "Название, этаж и квартира не меняют координаты, размеры или положение комнат. Совмещение независимых съёмок здесь не выполняется.")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
            }
        }
        .onChange(of: plan.floorIndex) { _, newValue in
            if !apartments.contains(where: { $0.id == apartmentID && $0.floorIndex == newValue }) { apartmentID = nil }
        }
    }
}

private struct BuildingFloorOverviewScreen: View {
    let title: String
    let plans: [AtlasFloorPlan]
    let scans: [ScanRecord]
    private var frames: [UUID] { Set(plans.map(\.frameID)).sorted { $0.uuidString < $1.uuidString } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if frames.count > 1 {
                    Label("Не совмещены: \(frames.count) систем координат", systemImage: "exclamationmark.triangle")
                        .font(.headline).foregroundStyle(.orange)
                }
                Text("Каждая карточка использует одну сохранённую систему координат. Квартиры и этажи не задают трансформации. Повторные контуры могут перекрываться; проверьте исходные измерения.")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
                ForEach(frames, id: \.self) { frame in
                    let group = plans.filter { $0.frameID == frame }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Система \(frame.uuidString.prefix(8))").font(.headline)
                        BuildingCoordinatePreview(plans: group).frame(height: 260)
                            .background(Color.atlasCanvas, in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel("Обзор \(group.count) обмеров в одной сохранённой локальной системе координат")
                        Text(group.map(\.name).joined(separator: " · ")).font(.subheadline)
                        Text(scans.contains { $0.frameID == frame } ? "Источник: сохранённая съёмка с этим frameID. Фактическое совмещение требует проверки." : "Источник: сохранённые координаты обмеров. Съёмка с этим frameID в проекте не найдена.")
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                        if group.reduce(0, { $0 + $1.rooms.count }) > 300 || group.reduce(0, { $0 + $1.walls.count }) > 2_000 {
                            Text("Обзор ограничен 300 комнатами и 2 000 стенами. Полная геометрия остаётся в обмерах.").font(.caption).foregroundStyle(Color.atlasMuted)
                        }
                    }.padding(16).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 20))
                }
            }.padding(20)
        }.background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

private struct BuildingCoordinatePreview: View {
    let plans: [AtlasFloorPlan]
    var body: some View {
        Canvas { context, size in
            // Defensive guard: even a mistaken caller cannot overlay distinct frames.
            guard Set(plans.map(\.frameID)).count == 1 else { return }
            let rooms = Array(plans.flatMap(\.rooms).prefix(300))
            let walls = Array(plans.flatMap(\.walls).prefix(2_000))
            let points = (rooms.flatMap { $0.boundary.vertices + $0.boundary.holes.flatMap { $0 } } + walls.flatMap { [$0.start, $0.end] })
                .filter { $0.x.isFinite && $0.y.isFinite }
            guard let first = points.first else { return }
            let minX = points.reduce(first.x) { min($0, $1.x) }, maxX = points.reduce(first.x) { max($0, $1.x) }
            let minY = points.reduce(first.y) { min($0, $1.y) }, maxY = points.reduce(first.y) { max($0, $1.y) }
            let scale = min(max(1, size.width - 32) / max(maxX - minX, 1), max(1, size.height - 32) / max(maxY - minY, 1))
            let centerX = minX / 2 + maxX / 2, centerY = minY / 2 + maxY / 2
            func point(_ value: MetricPoint2D) -> CGPoint {
                CGPoint(x: size.width / 2 + (value.x - centerX) * scale, y: size.height / 2 - (value.y - centerY) * scale)
            }
            for room in rooms {
                guard (try? PolygonGeometry.validate(room.boundary)) != nil else { continue }
                var path = Path()
                for ring in [room.boundary.vertices] + room.boundary.holes {
                    guard let first = ring.first else { continue }
                    path.move(to: point(first))
                    for vertex in ring.dropFirst() { path.addLine(to: point(vertex)) }
                    path.closeSubpath()
                }
                context.fill(path, with: .color(Color.atlasAccent.opacity(0.12)), style: FillStyle(eoFill: true))
                context.stroke(path, with: .color(Color.atlasAccent), lineWidth: 1.5)
            }
            for wall in walls where wall.start.x.isFinite && wall.start.y.isFinite && wall.end.x.isFinite && wall.end.y.isFinite {
                var path = Path(); path.move(to: point(wall.start)); path.addLine(to: point(wall.end))
                context.stroke(path, with: .color(Color.atlasInk.opacity(0.8)), lineWidth: 2)
            }
        }
        .overlay {
            if plans.allSatisfy({ $0.rooms.isEmpty && $0.walls.isEmpty }) {
                Text("В обмерах пока нет геометрии").font(.caption).foregroundStyle(Color.atlasMuted)
            }
        }
    }
}
