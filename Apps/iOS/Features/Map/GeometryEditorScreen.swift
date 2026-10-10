import SwiftUI
import MapKit
import AtlasCore

struct GeometryEditorScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @State private var features: [AtlasFeature] = []
    @State private var editing: AtlasFeature?
    @State private var showCreate = false
    @State private var draw = false
    @State private var metricDraft: [MetricPoint2D] = []
    @State private var geographicDraft: [GeographicCoordinate] = []
    @State private var zoom = 1.0
    @State private var newLabel = ""
    @State private var saving = false
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if case .wgs84 = project.coordinateReference {
                    geographicMap
                } else {
                    MetricPlotCanvas(features: features, draft: metricDraft, zoom: zoom, selectedID: editing?.id,
                        onTap: { point in
                            if draw { metricDraft.append(point) }
                            else { editing = hitFeature(point) }
                        })
                }
                Text(draw ? "Добавьте углы участка" : coordinateLabel)
                    .font(.caption.weight(.semibold)).padding(10)
                    .background(.regularMaterial, in: Capsule()).padding(14)
            }.frame(minHeight: 260, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                if draw {
                    HStack {
                        Text("Вершин: \(metricDraft.count + geographicDraft.count)").font(.headline)
                        Spacer()
                        Button("Отменить угол", systemImage: "arrow.uturn.backward") {
                            if !metricDraft.isEmpty { metricDraft.removeLast() }
                            if !geographicDraft.isEmpty { geographicDraft.removeLast() }
                        }.labelStyle(.iconOnly)
                    }
                    TextField("Номер или название участка", text: $newLabel).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Отмена") { resetDraft() }
                        Spacer()
                        Button("Сохранить полигон") { Task { await saveDrawn() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(saving || newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || metricDraft.count + geographicDraft.count < 3)
                    }
                } else {
                    HStack {
                        AtlasSectionLabel(title: "Участки · \(features.count)")
                        Spacer()
                        Menu {
                            Button("Нарисовать на плане", systemImage: "pencil.tip") { draw = true }
                            Button("Ввести координаты", systemImage: "number") { showCreate = true }
                        } label: { Label("Добавить", systemImage: "plus") }
                    }
                    if features.isEmpty {
                        Text("Добавьте углы касанием или введите точные координаты. Границы подтверждает специалист.")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(features) { feature in
                                    Button { editing = feature } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(feature.label).font(.subheadline.bold())
                                            Text(areaText(feature)).font(.caption).foregroundStyle(Color.atlasMuted)
                                        }.padding(12).background(Color.atlasCanvas, in: RoundedRectangle(cornerRadius: 12))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if case .localMeters = project.coordinateReference {
                        HStack {
                            Image(systemName: "minus.magnifyingglass")
                            Slider(value: $zoom, in: 1...4).accessibilityLabel("Масштаб локального плана")
                            Image(systemName: "plus.magnifyingglass")
                        }.foregroundStyle(Color.atlasMuted)
                    }
                }
            }.padding(18).background(Color(uiColor: .systemBackground))
        }
        .navigationTitle(project.name).navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .sheet(isPresented: $showCreate) {
            FeatureEditScreen(model: model, project: project, feature: nil) { Task { await refresh() } }
        }
        .sheet(item: $editing) { feature in
            FeatureEditScreen(model: model, project: project, feature: feature) { Task { await refresh() } }
        }
    }
    private var coordinateLabel: String {
        switch project.coordinateReference { case .wgs84: "WGS84 · границы на карте"; case .localMeters: "Локальная система · метры" }
    }
    private var geographicMap: some View {
        MapReader { proxy in
            Map {
                ForEach(features) { feature in
                    if case let .geographicPolygon(polygon) = feature.geometry {
                        MapPolygon(mapPolygon(polygon))
                            .foregroundStyle(Color.atlasBlue.opacity(0.17)).stroke(Color.atlasBlue, lineWidth: 2)
                    }
                }
                if geographicDraft.count > 1 {
                    MapPolyline(coordinates: geographicDraft.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                        .stroke(Color.orange, lineWidth: 3)
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture(coordinateSpace: .local) { point in
                guard draw, let coordinate = proxy.convert(point, from: .local) else { return }
                geographicDraft.append(GeographicCoordinate(longitude: coordinate.longitude, latitude: coordinate.latitude))
            }
        }
    }
    private func mapPolygon(_ polygon: GeographicPolygon) -> MKPolygon {
        let coordinates = polygon.vertices.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let holes = polygon.holes.map { ring in
            let points = ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            return MKPolygon(coordinates: points, count: points.count)
        }
        return MKPolygon(coordinates: coordinates, count: coordinates.count, interiorPolygons: holes)
    }
    private func refresh() async { features = await model.features(in: project) }
    private func areaText(_ feature: AtlasFeature) -> String {
        if case let .metricPolygon(polygon) = feature.geometry, let area = try? PolygonGeometry.area(of: polygon) {
            return area.formatted(.number.precision(.fractionLength(1))) + " м²"
        }
        return "Географический полигон"
    }
    private func hitFeature(_ point: MetricPoint2D) -> AtlasFeature? {
        features.first { feature in
            guard case let .metricPolygon(polygon) = feature.geometry else { return false }
            return contains(point, ring: polygon.vertices) && !polygon.holes.contains { contains(point, ring: $0) }
        }
    }
    private func contains(_ point: MetricPoint2D, ring points: [MetricPoint2D]) -> Bool {
            var inside = false
            guard points.count >= 3 else { return false }
            var j = points.count - 1
            for i in points.indices {
                let a = points[i], b = points[j]
                if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                j = i
            }
            return inside
    }
    private func saveDrawn() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let geometry: FeatureGeometry
        switch project.coordinateReference {
        case let .localMeters(frameID): geometry = .metricPolygon(MetricPolygon(frameID: frameID, vertices: metricDraft))
        case .wgs84: geometry = .geographicPolygon(GeographicPolygon(vertices: geographicDraft))
        }
        if await model.saveFeature(AtlasFeature(projectID: project.id, label: newLabel, category: .grave, geometry: geometry,
            attributes: ["boundaryBasis": "digitized", "accuracyBasis": "unknown"])) != nil {
            resetDraft(); await refresh()
        }
    }
    private func resetDraft() { draw = false; metricDraft = []; geographicDraft = []; newLabel = "" }
}

private struct MetricPlotCanvas: View {
    let features: [AtlasFeature]
    let draft: [MetricPoint2D]
    let zoom: Double
    let selectedID: UUID?
    let onTap: (MetricPoint2D) -> Void
    private var points: [MetricPoint2D] {
        features.flatMap { feature -> [MetricPoint2D] in
            guard case let .metricPolygon(polygon) = feature.geometry else { return [] }
            return polygon.vertices
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let transform = PlotTransform(points: points, size: geometry.size, zoom: zoom)
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.atlasCanvas))
                for feature in features {
                    guard case let .metricPolygon(polygon) = feature.geometry else { continue }
                    var path = polygonPath(polygon.vertices, transform: transform, closed: true)
                    for ring in polygon.holes { path.addPath(polygonPath(ring, transform: transform, closed: true)) }
                    context.fill(path, with: .color(Color.atlasBlue.opacity(0.12)), style: FillStyle(eoFill: true))
                    context.stroke(path, with: .color(feature.id == selectedID ? .orange : .atlasBlue), lineWidth: 2)
                    if !polygon.vertices.isEmpty {
                        let center = MetricPoint2D(x: polygon.vertices.map(\.x).reduce(0, +) / Double(polygon.vertices.count),
                            y: polygon.vertices.map(\.y).reduce(0, +) / Double(polygon.vertices.count))
                        context.draw(Text(feature.label).font(.caption.weight(.medium)).foregroundStyle(Color.atlasInk), at: transform.screen(center))
                    }
                }
                context.stroke(polygonPath(draft, transform: transform, closed: false), with: .color(.orange), lineWidth: 3)
                for point in draft {
                    let screen = transform.screen(point)
                    context.fill(Path(ellipseIn: CGRect(x: screen.x - 5, y: screen.y - 5, width: 10, height: 10)), with: .color(.orange))
                }
                context.draw(Text("\(Int(transform.visibleWidth.rounded())) м по ширине").font(.caption).foregroundStyle(Color.atlasMuted),
                    at: CGPoint(x: size.width / 2, y: size.height - 16))
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in onTap(transform.metric(point)) }
            .accessibilityLabel("Редактор полигонов в локальных метрах. Точные вершины доступны в карточке объекта.")
        }
    }
    private func polygonPath(_ points: [MetricPoint2D], transform: PlotTransform, closed: Bool) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: transform.screen(first))
            for point in points.dropFirst() { path.addLine(to: transform.screen(point)) }
            if closed { path.closeSubpath() }
        }
    }
}

struct PlotTransform {
    let minX: Double
    let minY: Double
    let scale: Double
    let height: Double
    let visibleWidth: Double
    init(points: [MetricPoint2D], size: CGSize, zoom: Double = 1) {
        let lowerX = points.map(\.x).min() ?? 0, upperX = points.map(\.x).max() ?? 16
        let lowerY = points.map(\.y).min() ?? 0, upperY = points.map(\.y).max() ?? 16
        minX = lowerX - 2; minY = lowerY - 2
        height = Double(size.height)
        scale = max(0.000_001, min(Double(size.width) / max(upperX - lowerX + 4, 8), Double(size.height) / max(upperY - lowerY + 4, 8))) * zoom
        visibleWidth = Double(size.width) / scale
    }
    func screen(_ point: MetricPoint2D) -> CGPoint { CGPoint(x: (point.x - minX) * scale, y: height - (point.y - minY) * scale) }
    func metric(_ point: CGPoint) -> MetricPoint2D { MetricPoint2D(x: Double(point.x) / scale + minX, y: (height - Double(point.y)) / scale + minY) }
}
