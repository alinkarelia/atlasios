import SwiftUI
import MapKit
import AtlasCore

enum MapDraftKind {
    case point, polyline, polygon
    var minimum: Int { switch self { case .point: 1; case .polyline: 2; case .polygon: 3 } }
    var instruction: String {
        switch self {
        case .point: "Коснитесь места объекта на карте"
        case .polyline: "Добавьте точки линии по порядку"
        case .polygon: "Добавьте углы границы по порядку"
        }
    }
}

struct MapFeatureEditorRequest: Identifiable {
    let id = UUID()
    let feature: AtlasFeature?
    let isNew: Bool
    var geoTag: GeoTag? = nil
}

enum SurveyMapStyle {
    static func color(_ category: FeatureCategory) -> Color {
        switch category {
        case .cemetery: .atlasBlue
        case .grave: .cyan
        case .sector: .purple
        case .path, .road: .orange
        case .entrance: .green
        case .wasteBin: .mint
        case .wasteDump: .red
        case .fence, .boundary: .yellow
        case .building: .pink
        case .other: .gray
        }
    }
    static func symbol(_ category: FeatureCategory) -> String {
        switch category {
        case .cemetery: "square.dashed"
        case .grave: "mappin"
        case .sector: "square.grid.2x2"
        case .path: "figure.walk"
        case .road: "road.lanes"
        case .entrance: "door.left.hand.open"
        case .wasteBin: "trash"
        case .wasteDump: "exclamationmark.triangle"
        case .fence: "line.3.horizontal"
        case .boundary: "point.3.connected.trianglepath.dotted"
        case .building: "building.2"
        case .other: "circle"
        }
    }
    static func coordinate(_ value: GeographicCoordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude)
    }
    static func polygon(_ polygon: GeographicPolygon) -> MKPolygon {
        let coordinates = polygon.vertices.map(coordinate)
        let holes = polygon.holes.map { ring in
            let points = ring.map(coordinate)
            return MKPolygon(coordinates: points, count: points.count)
        }
        return MKPolygon(coordinates: coordinates, count: coordinates.count, interiorPolygons: holes)
    }
    static func cemeteryID(_ feature: AtlasFeature) -> UUID? {
        (feature.attributes["cemeteryID"] ?? feature.attributes["parentCemeteryID"]).flatMap(UUID.init(uuidString:))
    }
    static func metricPoints(_ geometry: FeatureGeometry) -> [MetricPoint2D] {
        switch geometry {
        case let .metricPoint(_, point): [point]
        case let .metricPolyline(line): line.vertices
        case let .metricPolygon(polygon): polygon.vertices
        default: []
        }
    }
    static func metricHit(_ point: MetricPoint2D, feature: AtlasFeature, tolerance: Double) -> Bool {
        switch feature.geometry {
        case let .metricPoint(_, vertex): return hypot(point.x - vertex.x, point.y - vertex.y) <= tolerance
        case let .metricPolyline(line): return distance(point, line: line.vertices) <= tolerance
        case let .metricPolygon(polygon):
            return contains(point, ring: polygon.vertices) && !polygon.holes.contains { contains(point, ring: $0) }
        default: return false
        }
    }
    private static func distance(_ point: MetricPoint2D, line: [MetricPoint2D]) -> Double {
        guard line.count > 1 else { return .infinity }
        return (1..<line.count).reduce(Double.infinity) { nearest, index in
            let a = line[index - 1], b = line[index], dx = b.x - a.x, dy = b.y - a.y
            let squared = dx * dx + dy * dy
            let t = squared > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / squared)) : 0
            return min(nearest, hypot(point.x - a.x - t * dx, point.y - a.y - t * dy))
        }
    }
    private static func contains(_ point: MetricPoint2D, ring: [MetricPoint2D]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false, previous = ring.count - 1
        for index in ring.indices {
            let a = ring[index], b = ring[previous]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            previous = index
        }
        return inside
    }
}

/// Screen-space hit testing uses a fixed touch target at every camera scale.
/// Lines remain open, and polygon holes never become filled selectable areas.
enum SurveyMapHitTest {
    static func geographic(_ point: CGPoint, feature: AtlasFeature,
                           project: (GeographicCoordinate) -> CGPoint?) -> Bool {
        func ring(_ coordinates: [GeographicCoordinate]) -> [CGPoint]? {
            let points = coordinates.compactMap(project)
            return points.count == coordinates.count && points.allSatisfy { $0.x.isFinite && $0.y.isFinite } ? points : nil
        }
        switch feature.geometry {
        case let .geographicPoint(coordinate):
            guard let vertex = project(coordinate) else { return false }
            return hypot(point.x - vertex.x, point.y - vertex.y) <= 22
        case let .geographicPolyline(line):
            guard let points = ring(line.vertices) else { return false }
            return distance(point, line: points, closed: false) <= 14
        case let .geographicPolygon(polygon):
            guard let outer = ring(polygon.vertices) else { return false }
            var holes: [[CGPoint]] = []
            for coordinates in polygon.holes {
                guard let hole = ring(coordinates) else { return false }
                holes.append(hole)
            }
            if holes.contains(where: { contains(point, ring: $0) }) { return false }
            if distance(point, line: outer, closed: true) <= 6 { return true }
            if holes.contains(where: { distance(point, line: $0, closed: true) <= 6 }) { return true }
            return contains(point, ring: outer)
        default: return false
        }
    }

    /// Broad areas are drawn first; a grave/point wins over its cemetery on tap.
    static func layer(_ feature: AtlasFeature) -> Int {
        if case .geographicPoint = feature.geometry { return 0 }
        if case .metricPoint = feature.geometry { return 0 }
        switch feature.category {
        case .grave: return 1
        case .road, .path, .fence: return 2
        case .sector, .boundary: return 4
        case .cemetery: return 5
        default: return 3
        }
    }
    static func drawingOrder(_ features: [AtlasFeature]) -> [AtlasFeature] {
        features.enumerated().sorted {
            let left = layer($0.element), right = layer($1.element)
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }
    private static func distance(_ point: CGPoint, line: [CGPoint], closed: Bool) -> CGFloat {
        guard line.count > 1 else { return .infinity }
        let edgeCount = closed ? line.count : line.count - 1
        return (0..<edgeCount).reduce(CGFloat.infinity) { nearest, index in
            let a = line[index], b = line[(index + 1) % line.count]
            let dx = b.x - a.x, dy = b.y - a.y, squared = dx * dx + dy * dy
            let t = squared > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / squared)) : 0
            return min(nearest, hypot(point.x - a.x - t * dx, point.y - a.y - t * dy))
        }
    }
    private static func contains(_ point: CGPoint, ring: [CGPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false, previous = ring.count - 1
        for index in ring.indices {
            let a = ring[index], b = ring[previous]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            previous = index
        }
        return inside
    }
}

struct SurveyGeographicViewport {
    let center: GeographicCoordinate
    let latitudeSpan: Double
    let longitudeSpan: Double
}

struct SurveyMapRenderPlan {
    var features: [AtlasFeature] = []
    var prominentIDs: Set<UUID> = []
    var matchingCount = 0
    var isLimited: Bool { matchingCount > features.count }
}

/// Bounds are rebuilt only when records/layers change, never on GPS clock ticks.
/// Camera changes scan these small cached bounds instead of reprojecting every vertex.
struct SurveyGeographicIndex {
    private struct Entry {
        let feature: AtlasFeature
        let south: Double, north: Double, west: Double, east: Double
        func intersects(_ viewport: SurveyGeographicViewport) -> Bool {
            let latitudeHalf = min(180, viewport.latitudeSpan * 0.55)
            guard north >= viewport.center.latitude - latitudeHalf,
                  south <= viewport.center.latitude + latitudeHalf else { return false }
            let longitudeHalf = min(180, viewport.longitudeSpan * 0.55)
            if longitudeHalf >= 180 { return true }
            let low = viewport.center.longitude - longitudeHalf, high = viewport.center.longitude + longitudeHalf
            if low < -180 { return east >= low + 360 || west <= high }
            if high > 180 { return east >= low || west <= high - 360 }
            return east >= low && west <= high
        }
        func distance(to viewport: SurveyGeographicViewport?) -> Double {
            guard let viewport else { return 0 }
            let latitude = (south + north) / 2
            let longitude = (west + east) / 2
            let delta = abs(longitude - viewport.center.longitude)
            return hypot((latitude - viewport.center.latitude) / max(viewport.latitudeSpan, 0.000_001),
                         min(delta, 360 - delta) / max(viewport.longitudeSpan, 0.000_001))
        }
    }
    private var entries: [Entry] = []

    init(features: [AtlasFeature] = []) {
        entries = features.compactMap { feature in
            let vertices: [GeographicCoordinate]
            switch feature.geometry {
            case let .geographicPoint(point): vertices = [point]
            case let .geographicPolyline(line): vertices = line.vertices
            case let .geographicPolygon(polygon): vertices = polygon.vertices
            default: return nil
            }
            guard let first = vertices.first else { return nil }
            var south = first.latitude, north = first.latitude, west = first.longitude, east = first.longitude
            for vertex in vertices.dropFirst() {
                south = min(south, vertex.latitude); north = max(north, vertex.latitude)
                west = min(west, vertex.longitude); east = max(east, vertex.longitude)
            }
            return Entry(feature: feature, south: south, north: north, west: west, east: east)
        }
    }
    var fittedViewport: SurveyGeographicViewport? {
        guard let first = entries.first else { return nil }
        let south = entries.reduce(first.south) { min($0, $1.south) }, north = entries.reduce(first.north) { max($0, $1.north) }
        let west = entries.reduce(first.west) { min($0, $1.west) }, east = entries.reduce(first.east) { max($0, $1.east) }
        return SurveyGeographicViewport(center: GeographicCoordinate(longitude: (west + east) / 2, latitude: (south + north) / 2),
            latitudeSpan: min(180, max(0.000_3, (north - south) * 1.2)), longitudeSpan: min(360, max(0.000_3, (east - west) * 1.2)))
    }
    func plan(in viewport: SurveyGeographicViewport?, featureLimit: Int = 400, prominentLimit: Int = 80) -> SurveyMapRenderPlan {
        let matches = entries.enumerated().filter { viewport.map($0.element.intersects) ?? true }
        // Keep the enclosing territory and the objects closest to the viewport
        // centre when zoomed out. The limit is disclosed; zooming reveals the rest.
        let selected = matches.sorted {
            let leftTerritory = $0.element.feature.category == .cemetery, rightTerritory = $1.element.feature.category == .cemetery
            if leftTerritory != rightTerritory { return leftTerritory }
            let left = $0.element.distance(to: viewport), right = $1.element.distance(to: viewport)
            return left == right ? $0.offset < $1.offset : left < right
        }.prefix(max(0, featureLimit)).map(\.element.feature)
        let prominent = selected.sorted { SurveyMapHitTest.layer($0) < SurveyMapHitTest.layer($1) }
            .prefix(max(0, prominentLimit)).map(\.id)
        return SurveyMapRenderPlan(features: SurveyMapHitTest.drawingOrder(selected), prominentIDs: Set(prominent), matchingCount: matches.count)
    }
}

struct MetricPlotCanvas: View {
    let features: [AtlasFeature]
    let draft: [MetricPoint2D]
    let zoom: Double
    let onTap: (MetricPoint2D, Double, [AtlasFeature]) -> Void
    @State private var pan = CGSize.zero
    @GestureState private var drag = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            // Fit saved objects only. A new vertex must not move the coordinate canvas underneath the next tap.
            let offset = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
            let transform = PlotTransform(points: features.flatMap { SurveyMapStyle.metricPoints($0.geometry) }, size: geometry.size, zoom: zoom, pan: offset)
            let inViewport = SurveyMapHitTest.drawingOrder(features.filter {
                transform.intersects(SurveyMapStyle.metricPoints($0.geometry), width: Double(geometry.size.width))
            })
            let rendered = Array(inViewport.prefix(400))
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.atlasCanvas))
                for (index, feature) in rendered.enumerated() {
                    let color = SurveyMapStyle.color(feature.category)
                    let vertices = SurveyMapStyle.metricPoints(feature.geometry)
                    switch feature.geometry {
                    case let .metricPolygon(polygon):
                        var outline = path(polygon.vertices, transform: transform, closed: true)
                        for hole in polygon.holes { outline.addPath(path(hole, transform: transform, closed: true)) }
                        context.fill(outline, with: .color(color.opacity(0.14)), style: FillStyle(eoFill: true))
                        context.stroke(outline, with: .color(color), lineWidth: 2)
                    case let .metricPolyline(line):
                        context.stroke(path(line.vertices, transform: transform, closed: false), with: .color(color), lineWidth: 3)
                    case let .metricPoint(_, point):
                        let screen = transform.screen(point)
                        context.fill(Path(ellipseIn: CGRect(x: screen.x - 6, y: screen.y - 6, width: 12, height: 12)), with: .color(color))
                    default: break
                    }
                    if index < 80, let first = vertices.first {
                        let screen = transform.screen(first)
                        context.draw(Text(feature.label).font(.caption.weight(.semibold)).foregroundStyle(Color.atlasInk),
                                     at: CGPoint(x: screen.x, y: screen.y - 15), anchor: .bottom)
                    }
                }
                context.stroke(path(draft, transform: transform, closed: false), with: .color(.orange), style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                for point in draft {
                    let screen = transform.screen(point)
                    context.fill(Path(ellipseIn: CGRect(x: screen.x - 5, y: screen.y - 5, width: 10, height: 10)), with: .color(.orange))
                }
                context.draw(Text("\(Int(transform.visibleWidth.rounded())) м по ширине").font(.caption).foregroundStyle(Color.atlasMuted),
                             at: CGPoint(x: size.width / 2, y: size.height - 16))
                if inViewport.count > rendered.count {
                    context.draw(Text("Показано \(rendered.count) из \(inViewport.count) · приблизьте план").font(.caption).foregroundStyle(Color.orange),
                                 at: CGPoint(x: size.width / 2, y: size.height - 36))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { onTap(transform.metric($0), 18 / transform.scale, rendered) }
            .simultaneousGesture(DragGesture(minimumDistance: 10).updating($drag) { value, state, _ in
                state = value.translation
            }.onEnded { value in
                pan.width += value.translation.width; pan.height += value.translation.height
            })
            .accessibilityIdentifier("map.metricCanvas")
            .accessibilityLabel("План в локальных метрах. Координаты доступны в карточке объекта.")
        }
    }
    private func path(_ vertices: [MetricPoint2D], transform: PlotTransform, closed: Bool) -> Path {
        Path { path in
            guard let first = vertices.first else { return }
            path.move(to: transform.screen(first))
            for point in vertices.dropFirst() { path.addLine(to: transform.screen(point)) }
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
    let pan: CGSize
    init(points: [MetricPoint2D], size: CGSize, zoom: Double = 1, pan: CGSize = .zero) {
        let lowerX = points.map(\.x).min() ?? 0, upperX = points.map(\.x).max() ?? 16
        let lowerY = points.map(\.y).min() ?? 0, upperY = points.map(\.y).max() ?? 16
        minX = lowerX - 2; minY = lowerY - 2; height = Double(size.height)
        scale = max(0.000_001, min(Double(size.width) / max(upperX - lowerX + 4, 8), Double(size.height) / max(upperY - lowerY + 4, 8))) * zoom
        visibleWidth = Double(size.width) / scale
        self.pan = pan
    }
    func screen(_ point: MetricPoint2D) -> CGPoint { CGPoint(x: (point.x - minX) * scale + Double(pan.width), y: height - (point.y - minY) * scale + Double(pan.height)) }
    func metric(_ point: CGPoint) -> MetricPoint2D { MetricPoint2D(x: (Double(point.x) - Double(pan.width)) / scale + minX, y: (height - Double(point.y) + Double(pan.height)) / scale + minY) }
    func intersects(_ points: [MetricPoint2D], width: Double) -> Bool {
        guard let first = points.first else { return false }
        let firstScreen = screen(first)
        var left = firstScreen.x, right = firstScreen.x, top = firstScreen.y, bottom = firstScreen.y
        for point in points.dropFirst() {
            let projected = screen(point)
            left = min(left, projected.x); right = max(right, projected.x)
            top = min(top, projected.y); bottom = max(bottom, projected.y)
        }
        return right >= -24 && left <= width + 24 && bottom >= -24 && top <= height + 24
    }
}
