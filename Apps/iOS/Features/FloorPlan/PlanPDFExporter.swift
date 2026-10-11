import AtlasCore
import UIKit

@MainActor
enum PlanPDFExporter {
    static func export(_ plan: AtlasFloorPlan, directory: URL) throws -> URL {
        try PolygonGeometry.validate(plan, in: .localMeters(frameID: plan.frameID))
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { pdf in
            var pageNumber = 0
            var y: CGFloat = 0
            @MainActor func beginPage(_ title: String) {
                pdf.beginPage(); pageNumber += 1
                drawText(title, rect: CGRect(x: 42, y: 38, width: 511, height: 52), font: .systemFont(ofSize: 22, weight: .bold))
                drawText("ATLAS · \(plan.name) · Этаж \(plan.floorIndex)", rect: CGRect(x: 42, y: 93, width: 511, height: 35), font: .systemFont(ofSize: 11))
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
            let viewport = PlanViewport(plan: plan, rect: drawingRect)
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
            for wall in plan.walls {
                let path = UIBezierPath()
                path.move(to: viewport.point(wall.start)); path.addLine(to: viewport.point(wall.end))
                path.lineWidth = max(1.5, min(10, CGFloat(wall.thicknessMeters ?? 0.05) * viewport.scale))
                UIColor.black.setStroke(); path.stroke()
            }
            pdf.cgContext.restoreGState()
            let area = plan.rooms.reduce(0) { $0 + ((try? PolygonGeometry.area(of: $1.boundary)) ?? 0) }
            drawText("Комнат: \(plan.rooms.count) · Стен: \(plan.walls.count)\nСумма площадей контуров: \(number(area)) м²", rect: CGRect(x: 42, y: 603, width: 511, height: 45), font: .systemFont(ofSize: 12, weight: .medium))
            drawText("Обзорный план без заявленного печатного масштаба. Пересечения комнат не вычитаются. Геопривязка и совмещение с другими обмерами не заявляются.\nСистема: \(plan.frameID.uuidString)\nСоздано: \(Date().formatted(date: .abbreviated, time: .shortened))", rect: CGRect(x: 42, y: 664, width: 511, height: 90), font: .systemFont(ofSize: 9), color: .gray)

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
                if y + 52 > 748 { beginPage("Ведомость стен — продолжение") }
                let length = hypot(wall.end.x - wall.start.x, wall.end.y - wall.start.y)
                drawText("Стена \(index + 1) · Длина \(number(length)) м · Высота \(wall.heightMeters.map { number($0) + " м" } ?? "не указана") · Толщина \(wall.thicknessMeters.map { number($0) + " м" } ?? "не указана")", rect: CGRect(x: 42, y: y, width: 511, height: 26), font: .systemFont(ofSize: 10))
                drawText("Начало (\(number(wall.start.x)); \(number(wall.start.y))) · Конец (\(number(wall.end.x)); \(number(wall.end.y))) м", rect: CGRect(x: 42, y: y + 27, width: 511, height: 20), font: .systemFont(ofSize: 9), color: .gray)
                y += 52
            }
        }
        let url = directory.appendingPathComponent("TerraView-plan-\(plan.id.uuidString.prefix(8).lowercased()).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }
    private static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
    private static func drawText(_ text: String, rect: CGRect, font: UIFont, color: UIColor = .black, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment; paragraph.lineBreakMode = .byWordWrapping
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
