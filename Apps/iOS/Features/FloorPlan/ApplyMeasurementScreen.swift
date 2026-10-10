import AtlasCore
import SwiftUI

@MainActor
struct ApplyMeasurementScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    let initialMeasurementID: UUID?
    @State private var measurements: [MeasurementRecord] = []
    @State private var plans: [AtlasFloorPlan] = []
    @State private var measurementID: UUID?
    @State private var planID: UUID?
    @State private var wallID: UUID?
    @State private var dimension = PlanMeasurementDimension.wallLength
    @State private var loading = true
    @State private var saving = false
    @State private var issue: String?
    @State private var result: String?

    init(model: AtlasAppModel, project: AtlasProject, initialMeasurementID: UUID? = nil) {
        self.model = model
        self.project = project
        self.initialMeasurementID = initialMeasurementID
    }

    private var measurement: MeasurementRecord? { measurements.first { $0.id == measurementID } }
    private var plan: AtlasFloorPlan? { plans.first { $0.id == planID } }
    private var wall: PlanWall? { plan?.walls.first { $0.id == wallID } }
    private var dimensions: [PlanMeasurementDimension] {
        switch measurement?.kind {
        case .verticalDistance: [.wallHeight]
        case .horizontalDistance: [.wallLength, .wallThickness]
        default: PlanMeasurementDimension.allCases
        }
    }
    private var previousMeters: Double? {
        guard let wall else { return nil }
        switch dimension {
        case .wallLength: return hypot(wall.end.x - wall.start.x, wall.end.y - wall.start.y)
        case .wallHeight: return wall.heightMeters
        case .wallThickness: return wall.thicknessMeters
        }
    }
    private var canApply: Bool {
        !loading && !saving && measurement != nil && plan != nil && wallID != nil && applicationError == nil
    }
    private var applicationError: String? {
        guard let measurement, let plan, let wallID else { return "Выберите обмер, план и стену." }
        do {
            _ = try MeasurementPlanControl.applying(measurement: measurement, to: plan, wallID: wallID, dimension: dimension)
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        Form {
            if loading {
                ProgressView("Загружаем обмеры и планы…")
            } else if measurements.isEmpty {
                ContentUnavailableView("Нет сохранённых обмеров", systemImage: "ruler", description: Text("Сохраните AR-обмер или введите показание рулетки в журнале инструментов."))
            } else if plans.isEmpty {
                ContentUnavailableView("Нет стен для обмера", systemImage: "square.split.2x2", description: Text("Сохраните RoomPlan или создайте план со стенами в редакторе."))
            } else {
                Section("Контрольный обмер") {
                    Picker("Обмер", selection: $measurementID) {
                        ForEach(measurements) { record in
                            Text("\(record.label) · \(meters(record.effectiveMeters)) м").tag(Optional(record.id))
                        }
                    }
                    if let measurement {
                        LabeledContent("Исходное значение", value: "\(meters(measurement.originalMeters)) м")
                        LabeledContent("Применяемое значение", value: "\(meters(measurement.effectiveMeters)) м")
                        LabeledContent("Источник", value: sourceTitle(measurement.source))
                        Text("\(measurement.hasManualCorrection ? "С ручной поправкой" : "Исходный обмер") · Ревизия \(measurement.revision)")
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                    }
                }
                Section("Размер в плане") {
                    Picker("План", selection: $planID) {
                        ForEach(plans) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if let plan {
                        Picker("Стена", selection: $wallID) {
                            ForEach(Array(plan.walls.enumerated()), id: \.element.id) { index, wall in
                                Text("Стена \(index + 1) · \(meters(hypot(wall.end.x - wall.start.x, wall.end.y - wall.start.y))) м")
                                    .tag(Optional(wall.id))
                            }
                        }
                    }
                    Picker("Изменить", selection: $dimension) {
                        ForEach(dimensions, id: \.self) { Text(dimensionTitle($0)).tag($0) }
                    }
                    LabeledContent("Сейчас в плане", value: previousMeters.map { "\(meters($0)) м" } ?? "Не задано")
                    if let previousMeters, let measurement {
                        LabeledContent("Изменение", value: "\(signedMeters(measurement.effectiveMeters - previousMeters)) м")
                    }
                }
                Section {
                    if let applicationError { Text(applicationError).font(.footnote).foregroundStyle(Color.orange) }
                    Button {
                        Task { await apply() }
                    } label: {
                        if saving { HStack { ProgressView(); Text("Сохраняем план…") } }
                        else { Label("Применить размер к стене", systemImage: "checkmark.circle") }
                    }.disabled(!canApply)
                    if let result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(Color.atlasBlue) }
                } footer: {
                    Text(dimension == .wallLength
                         ? "Длина изменит конец выбранной стены вдоль её направления. После применения проверьте стыки соседних стен и контуры комнат в редакторе плана."
                         : "Размер применяется только к выбранной стене. Источник, ревизия обмера и предыдущий размер сохраняются в истории плана.")
                    Text("Передаётся только размер. AR-точки сохраняют свою систему координат и не переносятся в план автоматически.")
                }
                if let applications = plan?.measurementApplications, !applications.isEmpty {
                    Section("История применения") {
                        ForEach(applications.reversed()) { application in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(dimensionTitle(application.dimension)) · \(meters(application.appliedMeters)) м")
                                Text("Обмер \(application.measurementID.uuidString.prefix(8)) · ревизия \(application.measurementRevision)")
                                    .font(.caption).foregroundStyle(Color.atlasMuted)
                                Text(application.appliedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Color.atlasMuted)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Контроль плана")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.atlasBlue)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Обновить", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading || saving) } }
        .task { await load() }
        .onChange(of: measurementID) { _, _ in
            if !dimensions.contains(dimension) { dimension = dimensions.first ?? .wallLength }
            result = nil
        }
        .onChange(of: planID) { _, _ in wallID = plan?.walls.first?.id; result = nil }
        .onChange(of: wallID) { _, _ in result = nil }
        .onChange(of: dimension) { _, _ in result = nil }
        .disabled(saving)
        .alert("Контрольный размер", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("Понятно") { issue = nil }
        } message: { Text(issue ?? "") }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        measurements = await model.measurements(in: project)
        plans = await model.plans(in: project).filter { !$0.walls.isEmpty }
        measurementID = measurements.first { $0.id == initialMeasurementID }?.id ?? measurements.first?.id
        planID = plans.first?.id
        wallID = plan?.walls.first?.id
        dimension = dimensions.first ?? .wallLength
    }

    private func apply() async {
        guard !saving, let measurement, let plan, let wallID else { return }
        saving = true
        defer { saving = false }
        do {
            let updated = try MeasurementPlanControl.applying(measurement: measurement, to: plan, wallID: wallID, dimension: dimension)
            guard let saved = await model.savePlan(updated) else {
                issue = model.issue ?? "Не удалось сохранить план."
                return
            }
            if let index = plans.firstIndex(where: { $0.id == saved.id }) { plans[index] = saved }
            result = "Сохранено в плане «\(saved.name)» · ревизия \(saved.revision)"
        } catch { issue = error.localizedDescription }
    }

    private func meters(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(3))) }
    private func signedMeters(_ value: Double) -> String { (value > 0 ? "+" : "") + meters(value) }
    private func dimensionTitle(_ dimension: PlanMeasurementDimension) -> String {
        switch dimension { case .wallLength: "Длина стены"; case .wallHeight: "Высота стены"; case .wallThickness: "Толщина стены" }
    }
    private func sourceTitle(_ source: MeasurementSource) -> String {
        switch source { case .arRaycast: "AR-рулетка"; case .manualReference: "Ручной обмер"; case .laserReference: "Показание лазера, введённое оператором" }
    }
}
