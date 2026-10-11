import AtlasCore
import SwiftUI
import UIKit

private enum FloorPlanEditor: Identifiable {
    case metadata(AtlasFloorPlan, isNew: Bool), room(AtlasFloorPlan, PlanRoom?), wall(AtlasFloorPlan, PlanWall?)
    var id: String {
        switch self {
        case .metadata(let plan, _): "plan-\(plan.id)"
        case .room(let plan, let room): "room-\(plan.id)-\(room?.id.uuidString ?? "new")"
        case .wall(let plan, let wall): "wall-\(plan.id)-\(wall?.id.uuidString ?? "new")"
        }
    }
}
private enum FloorPlanDeletion: Identifiable {
    case room(UUID), wall(UUID)
    var id: UUID { switch self { case .room(let id), .wall(let id): id } }
}
private struct PlanShareRecord: Identifiable { let id = UUID(); let url: URL }

struct FloorPlanScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @State private var plans: [AtlasFloorPlan] = []
    @State private var selectedID: UUID?
    @State private var editor: FloorPlanEditor?
    @State private var deletion: FloorPlanDeletion?
    @State private var share: PlanShareRecord?
    @State private var issue: String?
    @State private var zoom = 1.0
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @State private var isSaving = false

    private var selected: AtlasFloorPlan? { plans.first { $0.id == selectedID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let plan = selected {
                    planSelector
                    planHeader(plan)
                    PlanDrawingView(plan: plan, zoom: zoom, offset: CGSize(width: pan.width + drag.width, height: pan.height + drag.height)).frame(height: 320)
                        .background(.background, in: RoundedRectangle(cornerRadius: 20))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                            pan.width += value.translation.width
                            pan.height += value.translation.height
                        })
                        .accessibilityLabel("План: \(plan.rooms.count) комнат, \(plan.walls.count) стен. Геометрия в локальных метрах.")
                    HStack {
                        Button("Уменьшить", systemImage: "minus.magnifyingglass") { zoom = max(0.5, zoom / 1.25) }.labelStyle(.iconOnly)
                        Slider(value: $zoom, in: 0.5...4).accessibilityLabel("Масштаб плана")
                        Button("Увеличить", systemImage: "plus.magnifyingglass") { zoom = min(4, zoom * 1.25) }.labelStyle(.iconOnly)
                        Button("Вписать") { zoom = 1; pan = .zero }
                    }
                    .buttonStyle(.borderless)
                    editingActions(plan)
                    roomsSection(plan)
                    wallsSection(plan)
                    exportActions(plan)
                } else {
                    ContentUnavailableView("Пока нет обмеров", systemImage: "square.split.2x2", description: Text("Сохраните RoomPlan после съёмки или создайте план по контрольным размерам."))
                    AtlasPrimaryButton(title: "Создать локальный обмер", systemImage: "plus") { createPlan() }
                }
            }.padding(20)
        }
        .background(Color.atlasCanvas)
        .navigationTitle("Планы здания")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.atlasBlue)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Новый обмер", systemImage: "plus") { createPlan() }.labelStyle(.iconOnly)
            }
        }
        .task { await reload() }
        .sheet(item: $editor) { item in
            switch item {
            case .metadata(let plan, let isNew):
                PlanMetadataEditor(plan: plan, isNew: isNew, geographicProject: project.coordinateReference == .wgs84, projectFrameID: project.coordinateReference.frameID) { try await persist($0) }
            case .room(let plan, let room):
                PlanRoomEditor(plan: plan, initial: room) { room in
                    var updated = plan
                    if let index = updated.rooms.firstIndex(where: { $0.id == room.id }) { updated.rooms[index] = room }
                    else { updated.rooms.append(room) }
                    try await persist(updated)
                }
            case .wall(let plan, let wall):
                PlanWallEditor(plan: plan, initial: wall) { wall in
                    var updated = plan
                    if let index = updated.walls.firstIndex(where: { $0.id == wall.id }) { updated.walls[index] = wall }
                    else { updated.walls.append(wall) }
                    try await persist(updated)
                }
            }
        }
        .sheet(item: $share) { PlanSharingController(url: $0.url) }
        .onChange(of: selectedID) { _, _ in zoom = 1; pan = .zero }
        .alert("План", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("Понятно") { issue = nil }
        } message: { Text(issue ?? "") }
        .confirmationDialog("Удалить элемент плана?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { Task { await deleteElement() } }
            Button("Отмена", role: .cancel) { deletion = nil }
        }
        .disabled(isSaving)
    }

    private var planSelector: some View {
        Picker("Обмер", selection: $selectedID) {
            ForEach(plans) { Text($0.name).tag(Optional($0.id)) }
        }.pickerStyle(.menu)
    }
    private func planHeader(_ plan: AtlasFloorPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(plan.name).font(.title2.bold()).foregroundStyle(Color.atlasInk)
                Spacer()
                Button("Настройки", systemImage: "slider.horizontal.3") { editor = .metadata(plan, isNew: false) }.labelStyle(.iconOnly)
            }
            Text("Отдельный локальный обмер · Метры · Этаж \(plan.floorIndex)")
                .font(.caption).foregroundStyle(Color.atlasMuted)
            HStack {
                Label("\(plan.rooms.count) комнат", systemImage: "square.split.2x2")
                Spacer()
                Text("\(totalArea(plan).formatted(.number.precision(.fractionLength(2)))) м²").fontWeight(.semibold)
            }.font(.subheadline).foregroundStyle(Color.atlasInk)
            Text("Сумма площадей контуров комнат. Пересечения между комнатами не вычитаются. Геопривязка не заявляется.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }
    }
    private func editingActions(_ plan: AtlasFloorPlan) -> some View {
        HStack(spacing: 12) {
            Button("Комната", systemImage: "plus.square") { editor = .room(plan, nil) }
                .frame(maxWidth: .infinity)
            Button("Стена", systemImage: "line.diagonal") { editor = .wall(plan, nil) }
                .frame(maxWidth: .infinity)
        }.buttonStyle(.bordered).font(.subheadline.weight(.medium))
    }
    private func roomsSection(_ plan: AtlasFloorPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AtlasSectionLabel(title: "Комнаты")
            if plan.rooms.isEmpty { Text("Добавьте контур комнаты по измеренным размерам.").font(.subheadline).foregroundStyle(Color.atlasMuted) }
            ForEach(plan.rooms) { room in
                HStack {
                    Button { editor = .room(plan, room) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(room.name).font(.headline).foregroundStyle(Color.atlasInk)
                            Text("\((try? PolygonGeometry.area(of: room.boundary))?.formatted(.number.precision(.fractionLength(2))) ?? "—") м² · \(room.boundary.vertices.count) вершин")
                                .font(.caption).foregroundStyle(Color.atlasMuted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button("Удалить комнату", systemImage: "trash", role: .destructive) { deletion = .room(room.id) }.labelStyle(.iconOnly)
                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private func wallsSection(_ plan: AtlasFloorPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AtlasSectionLabel(title: "Стены")
            if plan.walls.isEmpty { Text("Линии стен и контуры комнат редактируются отдельно.").font(.subheadline).foregroundStyle(Color.atlasMuted) }
            ForEach(Array(plan.walls.enumerated()), id: \.element.id) { index, wall in
                HStack {
                    Button { editor = .wall(plan, wall) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Стена \(index + 1)").font(.headline).foregroundStyle(Color.atlasInk)
                            Text("\(hypot(wall.end.x - wall.start.x, wall.end.y - wall.start.y).formatted(.number.precision(.fractionLength(2)))) м" + (wall.heightMeters.map { " · высота \($0.formatted(.number.precision(.fractionLength(2)))) м" } ?? ""))
                                .font(.caption).foregroundStyle(Color.atlasMuted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button("Удалить стену", systemImage: "trash", role: .destructive) { deletion = .wall(wall.id) }.labelStyle(.iconOnly)
                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private func exportActions(_ plan: AtlasFloorPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AtlasSectionLabel(title: "Передать результат")
            HStack {
                Button("DXF", systemImage: "square.and.arrow.up") { export(plan, pdf: false) }
                Button("SVG", systemImage: "doc.text.image") { export(plan, pdf: false, format: .svg) }
                Spacer()
                Button("PDF", systemImage: "doc.richtext") { export(plan, pdf: true) }
            }.buttonStyle(.bordered)
            Text("Экспортируется выбранный обмер в собственной локальной системе. DXF и SVG сохраняют метры; PDF — обзорный план с ведомостью.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }
    }
    private func createPlan() {
        let frame = UUID()
        editor = .metadata(AtlasFloorPlan(projectID: project.id, frameID: frame, name: "Новый обмер"), isNew: true)
    }
    private func totalArea(_ plan: AtlasFloorPlan) -> Double { plan.rooms.reduce(0) { $0 + ((try? PolygonGeometry.area(of: $1.boundary)) ?? 0) } }
    private func reload() async {
        plans = await model.plans(in: project)
        if !plans.contains(where: { $0.id == selectedID }) { selectedID = plans.first?.id }
    }
    private func persist(_ plan: AtlasFloorPlan) async throws {
        try PolygonGeometry.validate(plan, in: .localMeters(frameID: plan.frameID))
        guard let saved = await model.savePlan(plan) else { throw PlanEditingError.message(model.issue ?? "Не удалось сохранить обмер.") }
        if let index = plans.firstIndex(where: { $0.id == saved.id }) { plans[index] = saved }
        else { plans.append(saved) }
        selectedID = saved.id
    }
    private func deleteElement() async {
        guard var plan = selected, let deletion else { return }
        isSaving = true
        defer { isSaving = false; self.deletion = nil }
        switch deletion {
        case .room(let id): plan.rooms.removeAll { $0.id == id }
        case .wall(let id): plan.walls.removeAll { $0.id == id }
        }
        do { try await persist(plan) } catch { issue = error.localizedDescription }
    }
    private func export(_ plan: AtlasFloorPlan, pdf: Bool, format: ExportFormat = .dxf) {
        do {
            let directory = model.directory.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url: URL
            if pdf { url = try PlanPDFExporter.export(plan, directory: directory) }
            else {
                let artifact = try AtlasExporter.exportFloorPlan(plan, format: format)
                url = directory.appendingPathComponent(artifact.fileName)
                try artifact.data.write(to: url, options: .atomic)
            }
            share = PlanShareRecord(url: url)
        } catch { issue = error.localizedDescription }
    }
}

private struct PlanDrawingView: View {
    let plan: AtlasFloorPlan
    let zoom: Double
    let offset: CGSize
    var body: some View {
        Canvas { context, size in
            let viewport = PlanViewport(plan: plan, rect: CGRect(origin: .zero, size: size), zoom: zoom, offset: offset)
            let step = pow(10, floor(log10(max(viewport.extent / 12, 0.1))))
            let range = Int(ceil(viewport.extent / step)) + 2
            if range < 100 {
                for index in -range...range {
                    let offset = Double(index) * step
                    var grid = Path()
                    grid.move(to: viewport.point(.init(x: viewport.center.x + offset, y: viewport.center.y - viewport.extent)))
                    grid.addLine(to: viewport.point(.init(x: viewport.center.x + offset, y: viewport.center.y + viewport.extent)))
                    grid.move(to: viewport.point(.init(x: viewport.center.x - viewport.extent, y: viewport.center.y + offset)))
                    grid.addLine(to: viewport.point(.init(x: viewport.center.x + viewport.extent, y: viewport.center.y + offset)))
                    context.stroke(grid, with: .color(Color.atlasLine.opacity(0.22)), lineWidth: 0.5)
                }
            }
            for room in plan.rooms {
                var path = Path()
                for ring in [room.boundary.vertices] + room.boundary.holes {
                    guard let first = ring.first else { continue }
                    path.move(to: viewport.point(first))
                    for point in ring.dropFirst() { path.addLine(to: viewport.point(point)) }
                    path.closeSubpath()
                }
                context.fill(path, with: .color(Color.atlasBlue.opacity(0.06)), style: FillStyle(eoFill: true))
                context.stroke(path, with: .color(.atlasBlue), lineWidth: 1.5)
                let center = PlanViewport.labelPoint(room.boundary)
                let area = (try? PolygonGeometry.area(of: room.boundary)) ?? 0
                context.draw(Text("\(room.name)\n\(area.formatted(.number.precision(.fractionLength(2)))) м²").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.atlasInk), at: viewport.point(center))
            }
            for wall in plan.walls {
                var path = Path()
                path.move(to: viewport.point(wall.start)); path.addLine(to: viewport.point(wall.end))
                context.stroke(path, with: .color(.atlasInk), lineWidth: max(2, min(12, CGFloat(wall.thicknessMeters ?? 0.05) * viewport.scale)))
            }
        }
    }
}

private struct PlanSharingController: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
