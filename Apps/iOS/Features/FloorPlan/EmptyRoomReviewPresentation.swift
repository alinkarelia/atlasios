import Foundation

enum EmptyRoomReviewPresentation {
    static func dimensions(_ document: EmptyRoomDocument, review: EmptyRoomSurfaceReview?) -> [EmptyRoomDimension] {
        var result: [EmptyRoomDimension] = []
        for surface in document.surfaces {
            let decision = review?.latest(for: surface.id)
            let role = decision?.role ?? .reported(surface.kind)
            let prefix = "\(role.symbol)\(decision?.semanticVerified == true ? "" : "?")"
            for var dimension in surface.dimensions {
                let symbol: String
                if dimension.id.hasSuffix("-height") {
                    let horizontal = hypot(dimension.end.x - dimension.start.x, dimension.end.z - dimension.start.z)
                    symbol = horizontal <= max(0.00001, dimension.valueMeters * 0.001) ? "H" : "Hₛ"
                } else { symbol = surface.kind == .wall || surface.kind == .floor ? "L" : "W" }
                dimension.title = "\(prefix) · \(symbol)"
                result.append(dimension)
            }
        }
        return result
    }

    static func number(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "Неизвестно"
    }
    static func controlNumber(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(3))) }
    static func position(_ value: String) -> String {
        switch value {
        case "lower": "Внизу"; case "middle": "Посередине"; case "upper": "Вверху"
        case "left": "Слева"; case "center": "В центре"; case "right": "Справа"
        case "custom": "Указанная точка"; default: "Позиция не указана"
        }
    }
    static func notation(_ value: String) -> String {
        switch value { case "length": "L"; case "width": "W"; case "height": "H"; case "surfaceHeight": "Hₛ"; case "thickness": "T"; default: "D" }
    }
    static func definition(_ value: String?) -> String {
        switch value {
        case "reportedBounds": "Габарит"; case "clearOpening": "Чистый проём"
        case "doorLeaf": "Полотно / дверца"; case "outerFrame": "Наружная рама"
        case "structuralDimension": "Размер конструкции"; default: "Смысл размера не указан"
        }
    }
    /// A range keeps positions/observations intact and never averages incompatible
    /// roles, definitions, projections or unnamed profiles into one room height.
    static func ranges(_ controls: [EmptyRoomControlObservation]) -> [String] {
        let grouped = Dictionary(grouping: controls.filter { $0.profileID != nil }) {
            "\($0.profileID!.uuidString)|\($0.originalTargetID?.uuidString ?? "unspecified")|\($0.originalTarget ?? "unspecified")|\($0.role)|\($0.kind)|\($0.definition ?? "unspecified")"
        }
        return grouped.keys.sorted().compactMap { key in
            guard let values = grouped[key], values.count > 1, let first = values.first,
                  let minimum = values.map(\.effectiveMeters).min(), let maximum = values.map(\.effectiveMeters).max() else { return nil }
            return "\(notation(first.role)) · \(definition(first.definition)): \(controlNumber(minimum))–\(controlNumber(maximum)) м · \(values.count) точек"
        }
    }
}
