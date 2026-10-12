import Foundation

/// Screen-space annotations: text must clear the whole wall stroke, not just
/// its centerline. This changes annotation positions, never the metric geometry.
enum PlanDimensionLabelLayout {
    struct Placement {
        let center: CGPoint
        let rotationRadians: Double
    }

    static func floorNormalSign(ring: [CGPoint], isHole: Bool) -> CGFloat {
        guard let origin = ring.first else { return 1 }
        let twiceArea = ring.indices.reduce(CGFloat.zero) { area, index in
            let a = ring[index], b = ring[(index + 1) % ring.count]
            return area + (a.x - origin.x) * (b.y - origin.y) - (b.x - origin.x) * (a.y - origin.y)
        }
        let outside: CGFloat = twiceArea <= 0 ? 1 : -1
        return isHole ? -outside : outside
    }

    static func floor(start: CGPoint, end: CGPoint, textSize: CGSize,
                      wallLineWidth: CGFloat, minimumOffset: CGFloat, normalSign: CGFloat = 1, gap: CGFloat = 4) -> CGPoint? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length.isFinite, length > 0 else { return nil }
        let nx = -dy / length * normalSign, ny = dx / length * normalSign
        let textExtent = abs(nx) * textSize.width / 2 + abs(ny) * textSize.height / 2
        let distance = max(minimumOffset, textExtent + wallLineWidth / 2 + gap)
        return CGPoint(x: (start.x + end.x) / 2 + nx * distance,
                       y: (start.y + end.y) / 2 + ny * distance)
    }

    static func wall(start: CGPoint, end: CGPoint, textSize: CGSize,
                     wallLineWidth: CGFloat, toward: CGPoint, gap: CGFloat = 4) -> Placement? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length.isFinite, length > 0 else { return nil }
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let nx = -dy / length, ny = dx / length
        let side: CGFloat = (toward.x - midpoint.x) * nx + (toward.y - midpoint.y) * ny >= 0 ? 1 : -1
        let distance = textSize.height / 2 + wallLineWidth / 2 + gap
        var angle = atan2(Double(dy), Double(dx))
        if angle > .pi / 2 { angle -= .pi }
        if angle < -.pi / 2 { angle += .pi }
        return Placement(center: CGPoint(x: midpoint.x + nx * side * distance,
                                         y: midpoint.y + ny * side * distance),
                         rotationRadians: angle)
    }
}

