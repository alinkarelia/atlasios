import AtlasCore
import UIKit

@MainActor
enum PlanPDFExporter {
    static func export(_ plan: AtlasFloorPlan, directory: URL, showDimensions: Bool = true) throws -> URL {
        try PolygonGeometry.validate(plan, in: .localMeters(frameID: plan.frameID))
        let quantities = PlanQuantities.summary(of: plan)
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { pdf in
            var pageNumber = 0
            var y: CGFloat = 0
            @MainActor func beginPage(_ title: String) {
                pdf.beginPage(); pageNumber += 1
                drawText(title, rect: CGRect(x: 42, y: 38, width: 511, height: 52), font: .systemFont(ofSize: 22, weight: .bold))
                drawText("TerraView · \(plan.name) · Этаж \(plan.floorIndex)", rect: CGRect(x: 42, y: 93, width: 511, height: 35), font: .systemFont(ofSize: 11))
                drawText("Отдельный локальный обмер · Метры · Ревизия \(plan.revision)", rect: CGRect(x: 42, y: 780, width: 470, height: 18), font: .systemFont(ofSize: 9), color: .gray)
                drawText("\(pageNumber)", rect: CGRect(x: 522, y: 780, width: 30, height: 18), font: .systemFont(ofSize: 9), color: .gray)
                y = 138
            }
            beginPage("План обмера")
            let drawingRect = CGRect(x: 42, y: 145, width: 511, height: 440)
            UIColor(white: 0.98, alpha: 1).setFill()
            UIBezierPath(roundedRect: drawingRect, cornerRadius: 12).fill()
            pdf.cgContext.saveGState()
            pdf.cgContext.clip(to: drawingRect)
            let viewport = PlanViewport(plan: plan, rect: drawingRect, inset: 64)
            for room in plan.rooms {
                let path = UIBezierPath()
                path.usesEvenOddFillRule = true
                for ring in [room.boundary.vertices] + room.boundary.holes {
                    guard let first = ring.first else { continue }
                    path.move(to: viewport.point(first))
                    for point in ring.dropFirst() { path.addLine(to: viewport.point(point)) }
                    path.close()
                }
                UIColor.systemBlue.withAlphaComponent(0.07).setFill(); path.fill()
                UIColor.systemBlue.setStroke(); path.lineWidth = 1; path.stroke()
                let center = viewport.point(PlanViewport.labelPoint(room.boundary))
                let area = (try? PolygonGeometry.area(of: room.boundary)) ?? 0
                drawText("\(room.name)\n\(number(area)) м²", rect: CGRect(x: center.x - 60, y: center.y - 15, width: 120, height: 40), font: .systemFont(ofSize: 8, weight: .medium), alignment: .center)
            }
            let maximumWallWidth = plan.walls.map { max(1.5, min(10, CGFloat($0.thicknessMeters ?? 0.05) * viewport.scale)) }.max() ?? 1
            for wall in plan.walls {
                let path = UIBezierPath()
                path.move(to: viewport.point(wall.start)); path.addLine(to: viewport.point(wall.end))
                path.lineWidth = max(1.5, min(10, CGFloat(wall.thicknessMeters ?? 0.05) * viewport.scale))
                UIColor.black.setStroke(); path.stroke()
            }
            if showDimensions {
                for room in plan.rooms {
                    let edges = EmptyRoomRingGeometry.edges(outer: room.boundary.vertices.map { .init(x: $0.x, y: 0, z: $0.y) }, holes: room.boundary.holes.map { ring in ring.map { .init(x: $0.x, y: 0, z: $0.y) } })
                    let normalSigns = ([room.boundary.vertices] + room.boundary.holes).enumerated().map {
                        PlanDimensionLabelLayout.floorNormalSign(ring: $0.element.map { viewport.point($0) }, isHole: $0.offset > 0)
                    }
                    for edge in edges {
                        let a = viewport.point(.init(x: edge.start.x, y: edge.start.z)), b = viewport.point(.init(x: edge.end.x, y: edge.end.z))
                        let text = "\(edge.holeIndex == nil ? "L " : "Отв. · L ")\(number(edge.length)) м"
                        let font = UIFont.systemFont(ofSize: 7, weight: .medium)
                        let textSize = dimensionTextSize(text, font: font)
                        if let center = PlanDimensionLabelLayout.floor(start: a, end: b, textSize: textSize, wallLineWidth: maximumWallWidth, minimumOffset: 10, normalSign: normalSigns[edge.holeIndex.map { $0 + 1 } ?? 0]) {
                            if let guides = PlanDimensionLabelLayout.guides(start: a, end: b, label: .init(center: center, rotationRadians: 0), textSize: textSize, wallLineWidth: maximumWallWidth, tickLength: 5) {
                                drawGuides(guides, in: pdf.cgContext)
                            }
                            drawText(text, rect: CGRect(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2, width: textSize.width, height: textSize.height), font: font, alignment: .center)
                        }
                    }
                }
                for wall in plan.walls {
                    let a = viewport.point(wall.start), b = viewport.point(wall.end)
                    let height = wall.heightMeters.flatMap { $0.isFinite && $0 > 0 ? " · H \(number($0)) м" : nil } ?? " · H ?"
                    let text = "L \(number(hypot(wall.end.x - wall.start.x, wall.end.y - wall.start.y))) м\(height)"
                    let font = UIFont.systemFont(ofSize: 7)
                    let textSize = dimensionTextSize(text, font: font)
                    let width = max(1.5, min(10, CGFloat(wall.thicknessMeters ?? 0.05) * viewport.scale))
                    if let placement = PlanDimensionLabelLayout.wall(start: a, end: b, textSize: textSize, wallLineWidth: width, toward: viewport.point(viewport.center)) {
                        if let guides = PlanDimensionLabelLayout.guides(start: a, end: b, label: placement, textSize: textSize, wallLineWidth: width, tickLength: 5) {
                            drawGuides(guides, in: pdf.cgContext)
                        }
                        pdf.cgContext.saveGState()
                        pdf.cgContext.translateBy(x: placement.center.x, y: placement.center.y)
                        pdf.cgContext.rotate(by: CGFloat(placement.rotationRadians))
                        drawText(text, rect: CGRect(x: -textSize.width / 2, y: -textSize.height / 2, width: textSize.width, height: textSize.height), font: font, alignment: .center)
                        pdf.cgContext.restoreGState()
                    }
                }
            }
            pdf.cgContext.restoreGState()
            drawText("Пол · до отверстий: \(areaText(quantities.floorGrossSquareMeters)) · без отверстий: \(areaText(quantities.floorNetSquareMeters))\nСтены · известная площадь одной стороны: \(areaText(quantities.wallGrossSquareMeters)) · прямоугольная модель\nУчтено: \(quantities.measuredRoomCount)/\(quantities.roomCount) контуров, \(quantities.measuredWallCount)/\(quantities.wallCount) стен; без H: \(quantities.unknownHeightWallCount). Площадь после вычета проёмов неизвестна.\n\(heightRangeText(plan))", rect: CGRect(x: 42, y: 603, width: 511, height: 78), font: .systemFont(ofSize: 9, weight: .medium))
            drawText("\(quantities.aggregationNote)\nОбзор без печатного масштаба и геопривязки. L — длина стороны; H — скалярная высота стены; W — её известная толщина.\nСистема: \(plan.frameID.uuidString)\nСоздано: \(Date().formatted(date: .abbreviated, time: .shortened))", rect: CGRect(x: 42, y: 690, width: 511, height: 70), font: .systemFont(ofSize: 8), color: .gray)

            beginPage("Ведомость помещений")
            if plan.rooms.isEmpty {
                drawText("Комнаты не добавлены.", rect: CGRect(x: 42, y: y, width: 511, height: 30), font: .systemFont(ofSize: 11))
                y += 42
            }
            for room in plan.rooms {
                if y + 66 > 748 { beginPage("Ведомость помещений — продолжение") }
                let area = (try? PolygonGeometry.area(of: room.boundary)) ?? 0
                let perimeter = (try? PolygonGeometry.perimeter(of: room.boundary)) ?? 0
                drawText(room.name, rect: CGRect(x: 42, y: y, width: 330, height: 34), font: .systemFont(ofSize: 11, weight: .medium))
                drawText("\(number(area)) м²", rect: CGRect(x: 385, y: y, width: 168, height: 24), font: .systemFont(ofSize: 11), alignment: .right)
                drawText("Периметр: \(number(perimeter)) м · Вершин: \(room.boundary.vertices.count) · Отверстий: \(room.boundary.holes.count)", rect: CGRect(x: 42, y: y + 35, width: 511, height: 23), font: .systemFont(ofSize: 9), color: .gray)
                y += 66
            }
            if y + 70 > 748 { beginPage("Ведомость стен") }
            else {
                y += 12
                drawText("Стены", rect: CGRect(x: 42, y: y, width: 511, height: 25), font: .systemFont(ofSize: 16, weight: .bold))
                y += 35
            }
            if plan.walls.isEmpty {
                drawText("Стены не добавлены.", rect: CGRect(x: 42, y: y, width: 511, height: 30), font: .systemFont(ofSize: 11))
            }
            for (index, wall) in plan.walls.enumerated() {
                if y + 70 > 748 { beginPage("Ведомость стен — продолжение") }
                let length = hypot(wall.end.x - wall.start.x, wall.end.y - wall.start.y)
                drawText("Стена \(index + 1) · L \(number(length)) м · H \(wall.heightMeters.map { number($0) + " м" } ?? "не измерена") · W \(wall.thicknessMeters.map { number($0) + " м" } ?? "не измерена")", rect: CGRect(x: 42, y: y, width: 511, height: 24), font: .systemFont(ofSize: 10))
                drawText("Площадь одной стороны: \(areaText(try? PlanQuantities.wallGrossArea(of: wall))) · прямоугольная модель · вычет проёмов неизвестен", rect: CGRect(x: 42, y: y + 24, width: 511, height: 22), font: .systemFont(ofSize: 9))
                drawText("Начало (\(number(wall.start.x)); \(number(wall.start.y))) · Конец (\(number(wall.end.x)); \(number(wall.end.y))) м", rect: CGRect(x: 42, y: y + 47, width: 511, height: 20), font: .systemFont(ofSize: 9), color: .gray)
                y += 70
            }
        }
        let url = directory.appendingPathComponent("TerraView-plan-\(plan.id.uuidString.prefix(8).lowercased()).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }
    private static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
    private static func areaText(_ value: Double?) -> String { value.map { number($0) + " м²" } ?? "не измерена" }
    private static func heightRangeText(_ plan: AtlasFloorPlan) -> String {
        var identifiers = Set<UUID>()
        let heights = plan.walls.compactMap { wall -> Double? in
            guard identifiers.insert(wall.id).inserted, (try? PlanQuantities.wallGrossArea(of: wall)) != nil else { return nil }
            return wall.heightMeters
        }
        guard let minimum = heights.min(), let maximum = heights.max() else { return "H стен не измерена; высота потолка не определена." }
        let range = minimum == maximum ? number(minimum) : number(minimum) + "–" + number(maximum)
        return "H отдельных стен: \(range) м; общая высота потолка не определена."
    }
    private static func drawGuides(_ guides: PlanDimensionLabelLayout.DimensionGuides, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(UIColor.darkGray.cgColor)
        context.setLineWidth(0.5)
        for segment in guides.extensionLines {
            context.move(to: segment.start); context.addLine(to: segment.end)
        }
        context.strokePath()
        context.setLineWidth(0.8)
        for segment in [guides.dimensionLine] + guides.endpointTicks {
            context.move(to: segment.start); context.addLine(to: segment.end)
        }
        context.strokePath()
        context.restoreGState()
    }
    private static func dimensionTextSize(_ text: String, font: UIFont) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width) + 2, height: ceil(size.height) + 2)
    }
    private static func drawText(_ text: String, rect: CGRect, font: UIFont, color: UIColor = .black, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment; paragraph.lineBreakMode = .byWordWrapping
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
