import AtlasCore
import SwiftUI

/// Viewport projections of real source endpoints and the selected dimension.
/// The connector shows the horizontal offset excluded from a gravity height.
struct MeasurementDimensionOverlay: Equatable {
    var pointA: CGPoint? = nil
    var pointB: CGPoint? = nil
    var dimensionA: CGPoint? = nil
    var dimensionB: CGPoint? = nil
    var label: String
    var preview: Bool
}

struct MeasurementDimensionDrawing: View {
    let overlay: MeasurementDimensionOverlay
    var body: some View {
        Canvas { context, size in
            if let a = overlay.dimensionA, let b = overlay.dimensionB {
                var line = Path(); line.move(to: a); line.addLine(to: b)
                context.stroke(line, with: .color(.atlasAccent), style: StrokeStyle(lineWidth: 2, dash: overlay.preview ? [5, 4] : []))
                let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
                let normal = length > 1 ? CGSize(width: -dy / length, height: dx / length) : CGSize(width: 1, height: 0)
                for endpoint in [a, b] {
                    var tick = Path()
                    tick.move(to: CGPoint(x: endpoint.x - normal.width * 8, y: endpoint.y - normal.height * 8))
                    tick.addLine(to: CGPoint(x: endpoint.x + normal.width * 8, y: endpoint.y + normal.height * 8))
                    context.stroke(tick, with: .color(.atlasAccent), lineWidth: 2)
                }
                if let sourceB = overlay.pointB, hypot(sourceB.x - b.x, sourceB.y - b.y) > 2 {
                    var guide = Path(); guide.move(to: b); guide.addLine(to: sourceB)
                    context.stroke(guide, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    if let sourceA = overlay.pointA {
                        var slope = Path(); slope.move(to: sourceA); slope.addLine(to: sourceB)
                        context.stroke(slope, with: .color(.white.opacity(0.65)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                    }
                }
                let width = min(CGFloat(overlay.label.count) * 7 + 20, max(40, size.width - 16))
                let center = CGPoint(x: min(max(width / 2 + 4, (a.x + b.x) / 2 + normal.width * 18), size.width - width / 2 - 4),
                                     y: min(max(16, (a.y + b.y) / 2 + normal.height * 18), size.height - 16))
                context.fill(Path(roundedRect: CGRect(x: center.x - width / 2, y: center.y - 13, width: width, height: 26), cornerRadius: 8), with: .color(.atlasAccent))
                context.draw(Text(overlay.label).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(.atlasAccentInk), at: center)
            }
            for (name, point) in [("A", overlay.pointA), ("B", overlay.pointB)] {
                guard let point, point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { continue }
                let circle = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                context.fill(circle, with: .color(.atlasAccent)); context.stroke(circle, with: .color(.black), lineWidth: 2)
                let center = CGPoint(x: min(max(12, point.x + 15), size.width - 12), y: min(max(12, point.y - 15), size.height - 12))
                context.fill(Path(roundedRect: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20), cornerRadius: 5), with: .color(.black.opacity(0.8)))
                context.draw(Text(name).font(.system(size: 12, weight: .bold)).foregroundColor(.white), at: center)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension MeasurementRole {
    var fieldMeasurementTitle: String {
        switch self { case .distance: "D · расстояние"; case .length: "L · длина"; case .width: "W · ширина"; case .height: "H · по вертикали"; case .surfaceHeight: "Hₛ · вдоль поверхности"; case .thickness: "T · толщина" }
    }
}
extension MeasurementTarget {
    var fieldMeasurementTitle: String {
        switch self {
        case .unspecified: "Не задан"; case .room: "Помещение"; case .wall: "Стена"; case .floor: "Пол"; case .ceiling: "Потолок"
        case .door: "Дверной проём"; case .window: "Оконный проём"; case .openPassage: "Открытый проход"; case .cabinetDoor: "Дверца шкафа"
        }
    }
}
extension MeasurementSamplePosition {
    var fieldMeasurementTitle: String {
        switch self { case .unspecified: "Не задано"; case .lower: "Снизу"; case .middle: "Посередине"; case .upper: "Сверху"; case .left: "Слева"; case .center: "В центре"; case .right: "Справа"; case .custom: "Другое место" }
    }
}

extension MeasurementDefinition {
    var fieldMeasurementTitle: String {
        switch self { case .unspecified: "Границы не уточнены"; case .reportedBounds: "Габарит источника"; case .clearOpening: "Световой проход"; case .doorLeaf: "Дверное полотно"; case .outerFrame: "Внешняя рама"; case .structuralDimension: "Строительный размер" }
    }
}
