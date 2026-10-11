import AtlasCore
import Foundation

/// Fits the actual metric geometry; the transform never assigns GPS coordinates.
struct PlanViewport {
    let rect: CGRect
    let center: MetricPoint2D
    let extent: Double
    let scale: CGFloat
    init(plan: AtlasFloorPlan, rect: CGRect, zoom: Double = 1, offset: CGSize = .zero, inset: CGFloat = 32) {
        self.rect = rect.offsetBy(dx: offset.width, dy: offset.height)
        let points = plan.rooms.flatMap { $0.boundary.vertices + $0.boundary.holes.flatMap { $0 } }
            + plan.walls.flatMap { [$0.start, $0.end] }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1
        center = MetricPoint2D(x: minX / 2 + maxX / 2, y: minY / 2 + maxY / 2)
        let width = max(1, maxX - minX), height = max(1, maxY - minY)
        extent = max(width, height)
        scale = min(max(1, rect.width - inset * 2) / CGFloat(width), max(1, rect.height - inset * 2) / CGFloat(height)) * CGFloat(zoom)
    }
    func point(_ point: MetricPoint2D) -> CGPoint {
        CGPoint(x: rect.midX + CGFloat(point.x - center.x) * scale,
                y: rect.midY - CGFloat(point.y - center.y) * scale)
    }
    static func labelPoint(_ polygon: MetricPolygon) -> MetricPoint2D {
        let rings = [polygon.vertices] + polygon.holes
        let ys = Array(Set(rings.flatMap { $0.map(\.y) })).sorted()
        var best: MetricPoint2D?
        var widest = 0.0
        // A horizontal line between adjacent vertex heights never runs through a
        // vertex. Even-odd intersection pairs are inside the room, excluding holes.
        for index in ys.indices.dropLast() {
            let y = ys[index] / 2 + ys[index + 1] / 2
            var intersections: [Double] = []
            for ring in rings {
                for edge in ring.indices {
                    let a = ring[edge], b = ring[(edge + 1) % ring.count]
                    if (a.y > y) != (b.y > y) {
                        intersections.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
                    }
                }
            }
            intersections.sort()
            for edge in stride(from: 0, to: intersections.count - 1, by: 2) {
                let width = intersections[edge + 1] - intersections[edge]
                if width > widest {
                    widest = width
                    best = .init(x: intersections[edge] / 2 + intersections[edge + 1] / 2, y: y)
                }
            }
        }
        return best ?? polygon.vertices.first ?? .init(x: 0, y: 0)
    }
}

