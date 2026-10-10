import AtlasCore
import SwiftUI

enum PlanEditingError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}

private enum PlanNumber {
    static func text(_ value: Double?) -> String {
        value.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
    }
    static func parse(_ text: String, title: String, positive: Bool = false) throws -> Double {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: "^-?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Double(normalized), value.isFinite, abs(value) <= 1_000_000,
              !positive || value > 0 else {
            throw PlanEditingError.message("\(title): укажите \(positive ? "положительное число" : "число"); допустимая величина до 1 000 000.")
        }
        return value
    }
}

private struct PlanFormShell<Content: View>: View {
    let title: String
    let save: () async throws -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var issue: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form { content() }
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
                                    catch {
                                        if let geometry = error as? GeometryError {
                                            switch geometry {
                                            case .tooFewVertices: issue = "У контура должно быть хотя бы три вершины."
                                            case .selfIntersection: issue = "Контур пересекает сам себя. Проверьте порядок вершин."
                                            case .duplicateVertex: issue = "В контуре повторяются вершины."
                                            case .degenerateRing: issue = "Площадь контура должна быть больше нуля."
                                            case .holeOutsideExterior, .intersectingRings, .overlappingHoles: issue = "Проверьте отверстия: они должны лежать внутри контура и не пересекаться."
                                            case .invalidWall: issue = "Концы стены должны различаться; высота и толщина должны быть положительными."
                                            default: issue = "Геометрия обмера некорректна. Проверьте координаты."
                                            }
                                        } else { issue = error.localizedDescription }
                                    }
                                }
                            }.fontWeight(.semibold)
                        }
                    }
                }
                .disabled(busy)
                .interactiveDismissDisabled(busy)
                .alert("Проверьте обмер", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                    Button("Понятно") { issue = nil }
                } message: { Text(issue ?? "") }
        }.tint(.atlasBlue)
    }
}

struct PlanMetadataEditor: View {
    @State private var draft: AtlasFloorPlan
    @State private var separateFrameConfirmed = false
    @State private var useProjectFrame = false
    let isNew: Bool
    let geographicProject: Bool
    let projectFrameID: UUID?
    let save: (AtlasFloorPlan) async throws -> Void
    init(plan: AtlasFloorPlan, isNew: Bool, geographicProject: Bool, projectFrameID: UUID?, save: @escaping (AtlasFloorPlan) async throws -> Void) {
        _draft = State(initialValue: plan)
        self.isNew = isNew; self.geographicProject = geographicProject; self.projectFrameID = projectFrameID; self.save = save
    }
    var body: some View {
        PlanFormShell(title: isNew ? "Новый обмер" : "Настройки обмера", save: {
            var updated = draft
            updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !updated.name.isEmpty else { throw PlanEditingError.message("Укажите название обмера.") }
            guard !isNew || !geographicProject || separateFrameConfirmed else {
                throw PlanEditingError.message("Подтвердите создание отдельной локальной системы координат.")
            }
            if isNew, useProjectFrame, let projectFrameID { updated.frameID = projectFrameID }
            try await save(updated)
        }) {
            Section("План") {
                TextField("Название", text: $draft.name)
                Stepper("Этаж: \(draft.floorIndex)", value: $draft.floorIndex, in: -100...500)
            }
            Section("Координаты") {
                Label("Отдельный локальный обмер", systemImage: "ruler")
                Text("Единицы — метры. Редактор не выполняет геопривязку и не объединяет независимые съёмки автоматически.")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
                Text("Система: \((useProjectFrame ? (projectFrameID ?? draft.frameID) : draft.frameID).uuidString.prefix(8))").font(.caption.monospaced()).foregroundStyle(Color.atlasMuted)
                if isNew, projectFrameID != nil {
                    Toggle("Координаты проекта", isOn: $useProjectFrame)
                    Text("По умолчанию создаётся новая система. Включайте эту опцию только если вводите размеры и положение в уже проверенных координатах проекта.")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
                if isNew && geographicProject {
                    Text("Проект хранит долготу и широту. Новый обмер получит собственную систему в метрах; его координаты не считаются GPS-положением.")
                        .font(.subheadline)
                    Toggle("Создать отдельную локальную систему", isOn: $separateFrameConfirmed)
                }
            }
        }
    }
}

private struct PlanPointDraft: Identifiable {
    var id = UUID()
    var x = ""
    var y = ""
    init() {}
    init(_ point: MetricPoint2D) { x = PlanNumber.text(point.x); y = PlanNumber.text(point.y) }
    func point() throws -> MetricPoint2D {
        try .init(x: PlanNumber.parse(x, title: "Координата X"), y: PlanNumber.parse(y, title: "Координата Y"))
    }
}
private struct PlanRingDraft: Identifiable {
    var id = UUID()
    var isHole: Bool
    var vertices: [PlanPointDraft]
}

struct PlanRoomEditor: View {
    let plan: AtlasFloorPlan
    let save: (PlanRoom) async throws -> Void
    private let roomID: UUID
    @State private var name: String
    @State private var rectangle: Bool
    @State private var originX = "0"
    @State private var originY = "0"
    @State private var width = ""
    @State private var length = ""
    @State private var angle = "0"
    @State private var rings: [PlanRingDraft]
    init(plan: AtlasFloorPlan, initial: PlanRoom?, save: @escaping (PlanRoom) async throws -> Void) {
        self.plan = plan; self.save = save; roomID = initial?.id ?? UUID()
        _name = State(initialValue: initial?.name ?? "")
        _rectangle = State(initialValue: initial == nil)
        let exterior = initial?.boundary.vertices.map(PlanPointDraft.init) ?? [PlanPointDraft(), PlanPointDraft(), PlanPointDraft()]
        var initialRings = [PlanRingDraft(isHole: false, vertices: exterior)]
        initialRings += initial?.boundary.holes.map { PlanRingDraft(isHole: true, vertices: $0.map(PlanPointDraft.init)) } ?? []
        _rings = State(initialValue: initialRings)
    }
    var body: some View {
        PlanFormShell(title: "Контур комнаты", save: persist) {
            Section("Комната") {
                TextField("Название", text: $name)
                Toggle("Задать прямоугольником", isOn: $rectangle)
            }
            if rectangle {
                Section("Размеры и положение") {
                    numberField("Ширина, м", text: $width)
                    numberField("Длина, м", text: $length)
                    numberField("Начало X, м", text: $originX)
                    numberField("Начало Y, м", text: $originY)
                    numberField("Поворот, градусы", text: $angle)
                    Text("При сохранении создаются четыре вершины по введённым размерам. Существующий контур и отверстия будут заменены.")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
            } else {
                ForEach($rings) { $ring in
                    Section(ring.isHole ? "Отверстие" : "Внешний контур") {
                        ForEach($ring.vertices) { $point in
                            HStack {
                                TextField("X, м", text: $point.x).keyboardType(.numbersAndPunctuation)
                                Divider()
                                TextField("Y, м", text: $point.y).keyboardType(.numbersAndPunctuation)
                            }.font(.body.monospaced())
                        }
                        .onDelete { ring.vertices.remove(atOffsets: $0) }
                        Button("Добавить вершину", systemImage: "plus") { ring.vertices.append(PlanPointDraft()) }
                        if ring.isHole {
                            Button("Удалить отверстие", role: .destructive) { rings.removeAll { $0.id == ring.id } }
                        }
                    }
                }
                Section {
                    Button("Добавить отверстие", systemImage: "plus.square.dashed") {
                        rings.append(PlanRingDraft(isHole: true, vertices: [PlanPointDraft(), PlanPointDraft(), PlanPointDraft()]))
                    }
                    Text("Введите вершины по порядку обхода. Повторять первую вершину в конце не нужно. Смахните строку влево, чтобы удалить вершину.")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
            }
        }
    }
    private func numberField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).keyboardType(.numbersAndPunctuation)
    }
    private func persist() async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlanEditingError.message("Укажите название комнаты.") }
        let boundary: MetricPolygon
        if rectangle {
            let x = try PlanNumber.parse(originX, title: "Начало X")
            let y = try PlanNumber.parse(originY, title: "Начало Y")
            let w = try PlanNumber.parse(width, title: "Ширина", positive: true)
            let h = try PlanNumber.parse(length, title: "Длина", positive: true)
            let radians = try PlanNumber.parse(angle, title: "Поворот") * .pi / 180
            let vertices = [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)].map { a, b in
                MetricPoint2D(x: x + a * cos(radians) - b * sin(radians), y: y + a * sin(radians) + b * cos(radians))
            }
            boundary = MetricPolygon(frameID: plan.frameID, vertices: vertices)
        } else {
            guard let exterior = rings.first else { throw PlanEditingError.message("Добавьте внешний контур.") }
            boundary = try MetricPolygon(frameID: plan.frameID, vertices: exterior.vertices.map { try $0.point() }, holes: rings.dropFirst().map { try $0.vertices.map { try $0.point() } })
        }
        try PolygonGeometry.validate(boundary)
        try await save(PlanRoom(id: roomID, name: trimmed, boundary: boundary))
    }
}

struct PlanWallEditor: View {
    let plan: AtlasFloorPlan
    let save: (PlanWall) async throws -> Void
    private let wallID: UUID
    @State private var start: PlanPointDraft
    @State private var end: PlanPointDraft
    @State private var height: String
    @State private var thickness: String
    init(plan: AtlasFloorPlan, initial: PlanWall?, save: @escaping (PlanWall) async throws -> Void) {
        self.plan = plan; self.save = save; wallID = initial?.id ?? UUID()
        _start = State(initialValue: initial.map { PlanPointDraft($0.start) } ?? PlanPointDraft())
        _end = State(initialValue: initial.map { PlanPointDraft($0.end) } ?? PlanPointDraft())
        _height = State(initialValue: PlanNumber.text(initial?.heightMeters))
        _thickness = State(initialValue: PlanNumber.text(initial?.thicknessMeters))
    }
    var body: some View {
        PlanFormShell(title: "Стена", save: persist) {
            Section("Начало, метры") {
                TextField("X", text: $start.x).keyboardType(.numbersAndPunctuation)
                TextField("Y", text: $start.y).keyboardType(.numbersAndPunctuation)
            }
            Section("Конец, метры") {
                TextField("X", text: $end.x).keyboardType(.numbersAndPunctuation)
                TextField("Y", text: $end.y).keyboardType(.numbersAndPunctuation)
            }
            Section("Размеры, необязательно") {
                TextField("Высота, м", text: $height).keyboardType(.decimalPad)
                TextField("Толщина, м", text: $thickness).keyboardType(.decimalPad)
                Text("Пустое поле означает, что размер не указан. Линии стен и контуры комнат сохраняются отдельно.")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
            }
        }
    }
    private func persist() async throws {
        let wall = try PlanWall(id: wallID, start: start.point(), end: end.point(),
                                heightMeters: height.trimmingCharacters(in: .whitespaces).isEmpty ? nil : PlanNumber.parse(height, title: "Высота", positive: true),
                                thicknessMeters: thickness.trimmingCharacters(in: .whitespaces).isEmpty ? nil : PlanNumber.parse(thickness, title: "Толщина", positive: true))
        var validationPlan = plan
        validationPlan.walls = [wall]
        validationPlan.rooms = []
        try PolygonGeometry.validate(validationPlan, in: .localMeters(frameID: plan.frameID))
        try await save(wall)
    }
}
