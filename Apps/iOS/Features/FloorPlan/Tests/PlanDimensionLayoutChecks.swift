#if ATLAS_PLAN_DIMENSION_CHECKS
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@main
struct PlanDimensionLayoutChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func main() throws {
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw Failure(description: message) }
            checks += 1
        }
        let start = CGPoint(x: 120, y: 120)
        for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 4) {
            let end = CGPoint(x: start.x + cos(angle) * 180, y: start.y + sin(angle) * 180)
            let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let normal = CGPoint(x: -sin(angle), y: cos(angle))
            for stroke: CGFloat in [2, 10, 12] {
                for size in [CGSize(width: 36, height: 12), CGSize(width: 80, height: 12)] {
                    let center = PlanDimensionLabelLayout.floor(start: start, end: end, textSize: size, wallLineWidth: stroke, minimumOffset: 13)!
                    let projectedRadius = abs(normal.x) * size.width / 2 + abs(normal.y) * size.height / 2
                    let distance = (center.x - midpoint.x) * normal.x + (center.y - midpoint.y) * normal.y
                    try require(distance - projectedRadius - stroke / 2 >= 4 - 0.00001,
                            "A floor unit must clear the wall stroke for horizontal, vertical and diagonal edges")
                    let toward = CGPoint(x: midpoint.x - normal.x * 50, y: midpoint.y - normal.y * 50)
                    let placement = PlanDimensionLabelLayout.wall(start: start, end: end, textSize: size, wallLineWidth: stroke, toward: toward)!
                    let wallDistance = abs((placement.center.x - midpoint.x) * normal.x + (placement.center.y - midpoint.y) * normal.y)
                    try require(wallDistance - size.height / 2 - stroke / 2 >= 4 - 0.00001,
                            "Rotated height markers must clear the full wall stroke")
                    try require(abs(placement.rotationRadians) <= .pi / 2 + 0.00001,
                            "Wall dimensions must remain upright")
                    try require((placement.center.x - midpoint.x) * (toward.x - midpoint.x)
                            + (placement.center.y - midpoint.y) * (toward.y - midpoint.y) > 0,
                            "The wall annotation must be on the chosen inner side")
                    for label in [PlanDimensionLabelLayout.Placement(center: center, rotationRadians: 0), placement] {
                        let guides = PlanDimensionLabelLayout.guides(start: start, end: end, label: label, textSize: size, wallLineWidth: stroke)!
                        let line = guides.dimensionLine
                        try require(abs(hypot(line.end.x - line.start.x, line.end.y - line.start.y) - 180) < 0.00001,
                                "CAD dimension lines must retain the exact endpoint distance in screen space")
                        for (endpoint, original) in [(line.start, start), (line.end, end)] {
                            try require(abs((endpoint.x - original.x) * cos(angle) + (endpoint.y - original.y) * sin(angle)) < 0.00001,
                                    "Dimension endpoints must project from their corresponding observed endpoints")
                        }
                        for (tick, endpoint) in zip(guides.endpointTicks, [line.start, line.end]) {
                            try require(hypot((tick.start.x + tick.end.x) / 2 - endpoint.x,
                                              (tick.start.y + tick.end.y) / 2 - endpoint.y) < 0.00001,
                                    "Endpoint ticks must mark exactly the projected endpoint, never the label center")
                        }
                        let rotation = label.rotationRadians
                        let cosine = CGFloat(cos(rotation)), sine = CGFloat(sin(rotation))
                        let widthProjection = abs(normal.x * cosine + normal.y * sine) * size.width / 2
                        let heightProjection = abs(-normal.x * sine + normal.y * cosine) * size.height / 2
                        let extent = widthProjection + heightProjection
                        let lineDistance = abs((line.start.x - start.x) * normal.x + (line.start.y - start.y) * normal.y)
                        let labelDistance = abs((label.center.x - midpoint.x) * normal.x + (label.center.y - midpoint.y) * normal.y)
                        try require(labelDistance - extent - lineDistance >= 2 - 0.00001,
                                "CAD guide lines must clear the complete rotated or horizontal text bounding box")
                        try require(guides.extensionLines.count == 2 && guides.endpointTicks.count == 2,
                                "Every nonzero observed edge must have two true extensions and two endpoint ticks")
                    }
                }
            }
        }
        try require(PlanDimensionLabelLayout.floor(start: start, end: start, textSize: .zero, wallLineWidth: 12, minimumOffset: 13) == nil,
                "Zero-length edges must not create an invalid placement")
        try require(PlanDimensionLabelLayout.wall(start: start, end: start, textSize: .zero, wallLineWidth: 12, toward: .zero) == nil,
                "Zero-length walls must not create an invalid rotation")
        try require(13 - 36.0 / 2 < 12.0 / 2, "The old vertical-floor offset reproduces the reported overpaint")
        try require(PlanDimensionLabelLayout.guides(start: start, end: start, label: .init(center: .zero, rotationRadians: 0), textSize: .zero, wallLineWidth: 12) == nil,
                "Zero observed lengths must not create fabricated dimension guides")
        try require(PlanDimensionLabelLayout.guides(start: start, end: CGPoint(x: 200, y: 120), label: .init(center: CGPoint(x: 160, y: 120), rotationRadians: 0), textSize: CGSize(width: 40, height: 12), wallLineWidth: 12) == nil,
                "A label on the wall cannot create a guide through its text")
        try require(PlanDimensionLabelLayout.guides(start: start, end: CGPoint(x: 200, y: 120), label: .init(center: CGPoint(x: 160, y: 150), rotationRadians: .nan), textSize: CGSize(width: 40, height: 12), wallLineWidth: 12) == nil,
                "Nonfinite annotation rotations are rejected")

        let ring = [CGPoint(x: 64, y: 214), CGPoint(x: 264, y: 214), CGPoint(x: 264, y: 64), CGPoint(x: 64, y: 64)]
        let fixtureBounds = CGRect(x: 64, y: 64, width: 200, height: 150)
        for points in [ring, Array(ring.reversed())] {
            for isHole in [false, true] {
                let sign = PlanDimensionLabelLayout.floorNormalSign(ring: points, isHole: isHole)
                for index in points.indices {
                    let center = PlanDimensionLabelLayout.floor(start: points[index], end: points[(index + 1) % points.count], textSize: CGSize(width: 36, height: 12), wallLineWidth: 12, minimumOffset: 13, normalSign: sign)!
                    try require(fixtureBounds.contains(center) == isHole,
                            "Both winding orders must put outer labels outside the floor, and hole labels in the hole")
                    try require(CGRect(x: 0, y: 0, width: 328, height: 278).contains(CGRect(x: center.x - 18, y: center.y - 6, width: 36, height: 12)),
                            "The full fixture label must fit the existing 64-point inset")
                }
            }
        }
        print("Plan dimension labels: \(checks) checks passed")
    }
}
#endif
