import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Screen-space annotations: text must clear the whole wall stroke, not just
/// its centerline. This changes annotation positions, never the metric geometry.
enum PlanDimensionLabelLayout {
    struct Placement {
        let center: CGPoint
        let rotationRadians: Double
    }

    struct Segment {
        let start: CGPoint
        let end: CGPoint
    }

    struct DimensionGuides {
        let dimensionLine: Segment
        let extensionLines: [Segment]
        let endpointTicks: [Segment]
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

    /// CAD guides terminate at projections of the real endpoints. The parallel
    /// dimension line sits between the wall stroke and the label, leaving its
    /// bounding box clear. Scalar wall heights never create a fabricated 2D axis.
    static func guides(start: CGPoint, end: CGPoint, label: Placement, textSize: CGSize,
                       wallLineWidth: CGFloat, tickLength: CGFloat = 6) -> DimensionGuides? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length.isFinite, length > 0, textSize.width.isFinite, textSize.height.isFinite,
              textSize.width >= 0, textSize.height >= 0, wallLineWidth.isFinite,
              wallLineWidth >= 0, tickLength.isFinite, tickLength > 0,
              label.center.x.isFinite, label.center.y.isFinite, label.rotationRadians.isFinite else { return nil }
        let tx = dx / length, ty = dy / length, nx = -ty, ny = tx
        let midpoint = CGPoint(x: start.x / 2 + end.x / 2, y: start.y / 2 + end.y / 2)
        let labelDistance = (label.center.x - midpoint.x) * nx + (label.center.y - midpoint.y) * ny
        let side: CGFloat = labelDistance >= 0 ? 1 : -1
        let cosine = CGFloat(cos(label.rotationRadians)), sine = CGFloat(sin(label.rotationRadians))
        let normalExtent = abs(nx * cosine + ny * sine) * textSize.width / 2
            + abs(-nx * sine + ny * cosine) * textSize.height / 2
        let offset = abs(labelDistance) - normalExtent - 2
        guard offset.isFinite, offset >= wallLineWidth / 2 + 1 else { return nil }
        func shifted(_ point: CGPoint, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: point.x + nx * side * distance, y: point.y + ny * side * distance)
        }
        let a = shifted(start, offset), b = shifted(end, offset)
        let extensionStart = wallLineWidth / 2 + 1
        let extensions = [Segment(start: shifted(start, extensionStart), end: shifted(start, offset + 4)),
                          Segment(start: shifted(end, extensionStart), end: shifted(end, offset + 4))]
        // Diagonal ticks distinguish exact endpoints from a decorative outline.
        let tick = tickLength / (2 * sqrt(2))
        let tickDX = (tx + nx) * tick, tickDY = (ty + ny) * tick
        let ticks = [a, b].map { point in
            Segment(start: CGPoint(x: point.x - tickDX, y: point.y - tickDY),
                    end: CGPoint(x: point.x + tickDX, y: point.y + tickDY))
        }
        return DimensionGuides(dimensionLine: Segment(start: a, end: b), extensionLines: extensions, endpointTicks: ticks)
    }
}

