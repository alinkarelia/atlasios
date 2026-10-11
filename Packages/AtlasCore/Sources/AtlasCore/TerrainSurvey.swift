import Foundation

public struct TerrainPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var z: Double
    public var height: Double
    public init(x: Double, z: Double, height: Double) { self.x = x; self.z = z; self.height = height }
}

public struct TerrainMeshBatch: Codable, Sendable {
    public var frameID: UUID
    public var anchorID: UUID
    public var captureID: UUID
    public var points: [TerrainPoint]
    public init(frameID: UUID, anchorID: UUID, captureID: UUID, points: [TerrainPoint]) {
        self.frameID = frameID; self.anchorID = anchorID; self.captureID = captureID; self.points = points
    }
}

public enum TerrainSurveyError: Error, LocalizedError, Equatable, Sendable {
    case invalidData, frameMismatch, insufficientControls, shortBaseline, registrationResidual, insufficientSurface
    public var errorDescription: String? {
        switch self {
        case .invalidData: "Некорректные или слишком большие данные рельефа."
        case .frameMismatch: "Фрагменты имеют разные локальные координаты. Анализируйте их отдельно."
        case .insufficientControls: "Нужны минимум две пары контрольных точек: координаты в сетке и на карте."
        case .shortBaseline: "Расстояние между контрольными точками должно быть не менее 3 м."
        case .registrationResidual: "Контрольные точки не согласуются: проверьте пары и исходные координаты."
        case .insufficientSurface: "Мало измеренной поверхности. Покажите LiDAR больше земли вокруг интересующего участка."
        }
    }
}

public struct TerrainControlPoint: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var frameID: UUID
    public var local: MetricPoint2D
    public var geographic: GeographicCoordinate
    public var accuracyMeters: Double?
    public init(id: UUID = UUID(), frameID: UUID, local: MetricPoint2D, geographic: GeographicCoordinate, accuracyMeters: Double? = nil) {
        self.id = id; self.frameID = frameID; self.local = local; self.geographic = geographic; self.accuracyMeters = accuracyMeters
    }
}

/// A rigid metre-to-metre registration. GPS attached to a capture is never a
/// control pair and never implicitly sets this transform.
public struct TerrainRegistration: Codable, Hashable, Sendable {
    public var frameID: UUID
    public var origin: GeographicCoordinate
    public var cosine: Double
    public var sine: Double
    public var eastOffset: Double
    public var northOffset: Double
    public var rmsResidualMeters: Double
    public var maximumResidualMeters: Double
    public var positionalUncertaintyMeters: Double?
    public var controls: [TerrainControlPoint]
    public var warnings: [String]
    public var approvedAt: Date?
    private static let earthRadius = 6_378_137.0

    public static func fit(frameID: UUID, controls: [TerrainControlPoint], maximumResidualMeters: Double = 2.5) throws -> Self {
        guard controls.count >= 2, controls.count <= 32 else { throw TerrainSurveyError.insufficientControls }
        guard controls.allSatisfy({ $0.frameID == frameID }) else { throw TerrainSurveyError.frameMismatch }
        guard maximumResidualMeters.isFinite, maximumResidualMeters > 0,
              controls.allSatisfy({ $0.local.x.isFinite && $0.local.y.isFinite && abs($0.local.x) < 10_000 && abs($0.local.y) < 10_000 &&
                  $0.geographic.longitude.isFinite && $0.geographic.latitude.isFinite && abs($0.geographic.longitude) <= 180 && abs($0.geographic.latitude) < 85 &&
                  ($0.accuracyMeters == nil || ($0.accuracyMeters!.isFinite && $0.accuracyMeters! > 0)) }) else { throw TerrainSurveyError.invalidData }
        let origin = controls[0].geographic
        let factor = earthRadius * .pi / 180
        let longitudeFactor = factor * cos(origin.latitude * .pi / 180)
        guard controls.allSatisfy({ abs($0.geographic.longitude - origin.longitude) < 0.1 && abs($0.geographic.latitude - origin.latitude) < 0.1 }) else { throw TerrainSurveyError.invalidData }
        let pairs = controls.map { ($0.local, MetricPoint2D(x: ($0.geographic.longitude - origin.longitude) * longitudeFactor, y: ($0.geographic.latitude - origin.latitude) * factor)) }
        let n = Double(pairs.count)
        let a = MetricPoint2D(x: pairs.reduce(0) { $0 + $1.0.x } / n, y: pairs.reduce(0) { $0 + $1.0.y } / n)
        let b = MetricPoint2D(x: pairs.reduce(0) { $0 + $1.1.x } / n, y: pairs.reduce(0) { $0 + $1.1.y } / n)
        var dot = 0.0, cross = 0.0, baseline = 0.0
        for pair in pairs {
            let x = pair.0.x - a.x, y = pair.0.y - a.y, e = pair.1.x - b.x, north = pair.1.y - b.y
            dot += x * e + y * north; cross += x * north - y * e
            baseline = max(baseline, hypot(x, y) * 2)
        }
        guard baseline >= 3, hypot(dot, cross) > 1e-8 else { throw TerrainSurveyError.shortBaseline }
        let angle = atan2(cross, dot), c = cos(angle), s = sin(angle)
        let east = b.x - c * a.x + s * a.y, north = b.y - s * a.x - c * a.y
        let errors = pairs.map { hypot(c * $0.0.x - s * $0.0.y + east - $0.1.x, s * $0.0.x + c * $0.0.y + north - $0.1.y) }
        let rms = sqrt(errors.reduce(0) { $0 + $1 * $1 } / n), maximum = errors.max() ?? 0
        guard maximum <= maximumResidualMeters else { throw TerrainSurveyError.registrationResidual }
        var warnings = [String]()
        if controls.count == 2 { warnings.append("Две точки задают положение, но слабо проверяют ошибки. Добавьте третью независимую точку.") }
        if baseline < 10 { warnings.append("Короткая база контрольных точек увеличивает ошибку направления.") }
        let accuracy = controls.compactMap(\.accuracyMeters)
        if accuracy.count != controls.count { warnings.append("Точность части контрольных координат неизвестна. Это не геодезическая привязка.") }
        if controls.count >= 3 {
            let p = controls[0].local
            var maximumArea = 0.0
            for q in controls.dropFirst() {
                for r in controls.dropFirst() {
                    let first = (q.local.x-p.x)*(r.local.y-p.y)
                    let second = (q.local.y-p.y)*(r.local.x-p.x)
                    maximumArea = max(maximumArea,abs(first-second))
                }
            }
            if maximumArea < 2 { warnings.append("Контрольные точки почти на одной линии. Для проверки выберите точку в стороне.") }
        }
        return Self(frameID: frameID, origin: origin, cosine: c, sine: s, eastOffset: east, northOffset: north,
            rmsResidualMeters: rms, maximumResidualMeters: maximum, positionalUncertaintyMeters: accuracy.count == controls.count ? (accuracy.max() ?? 0) + maximum : nil,
            controls: controls, warnings: warnings, approvedAt: nil)
    }

    public func coordinate(for point: MetricPoint2D, frameID: UUID) throws -> GeographicCoordinate {
        guard frameID == self.frameID else { throw TerrainSurveyError.frameMismatch }
        guard point.x.isFinite, point.y.isFinite, abs(point.x) < 10_000, abs(point.y) < 10_000 else { throw TerrainSurveyError.invalidData }
        let factor = Self.earthRadius * .pi / 180
        let longitude = origin.longitude + (cosine * point.x - sine * point.y + eastOffset) / (factor * cos(origin.latitude * .pi / 180))
        let latitude = origin.latitude + (sine * point.x + cosine * point.y + northOffset) / factor
        guard abs(longitude) <= 180, abs(latitude) < 85 else { throw TerrainSurveyError.invalidData }
        return GeographicCoordinate(longitude: longitude, latitude: latitude)
    }
}

public struct TerrainCell: Identifiable, Codable, Hashable, Sendable {
    public var column: Int
    public var row: Int
    public var height: Double
    public var residual: Double
    public var sampleCount: Int
    public var verticalSpread: Double
    public var id: String { "\(column):\(row)" }
    public func center(cellSize: Double) -> MetricPoint2D { MetricPoint2D(x: (Double(column)+0.5)*cellSize, y: (Double(row)+0.5)*cellSize) }
}

public enum TerrainCandidateKind: String, Codable, CaseIterable, Sendable { case raisedSurface, depression, linearObstacle, fenceLikeStructure }
public enum TerrainCandidateState: String, Codable, Sendable { case proposed, confirmed, rejected }

public struct TerrainCandidate: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var frameID: UUID
    public var kind: TerrainCandidateKind
    public var center: MetricPoint2D
    public var boundary: [MetricPoint2D]
    public var heightDifference: Double
    public var lengthMeters: Double
    public var widthMeters: Double
    public var observedArea: Double
    /// No calibrated LiDAR accuracy is invented from a geometric heuristic.
    public var verticalUncertaintyMeters: Double?
    public var verticalSpreadMeters: Double
    public var evidence: String
    public var state: TerrainCandidateState
    public var reviewedAt: Date?
    public var confirmedFeatureID: UUID?
    public var confirmedCategory: FeatureCategory? = nil
    public var lineVertices: [MetricPoint2D]? = nil
}

public struct TerrainSurvey: Identifiable, Codable, Sendable {
    public var schemaVersion = 1
    public var id: UUID
    public var projectID: UUID
    public var cemeteryID: UUID
    public var frameID: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var sourceCaptureIDs: [UUID]
    public var cellSize: Double
    public var referenceHeight: Double
    public var cells: [TerrainCell]
    public var candidates: [TerrainCandidate]
    public var registration: TerrainRegistration?
    public var warnings: [String]
    public init(id: UUID = UUID(), projectID: UUID, cemeteryID: UUID, frameID: UUID, sourceCaptureIDs: [UUID], cellSize: Double = 0.25, referenceHeight: Double = 0, cells: [TerrainCell] = [], candidates: [TerrainCandidate] = [], registration: TerrainRegistration? = nil) {
        self.id = id; self.projectID = projectID; self.cemeteryID = cemeteryID; self.frameID = frameID; self.sourceCaptureIDs = sourceCaptureIDs
        self.createdAt = Date(); self.updatedAt = Date(); self.cellSize = cellSize; self.referenceHeight = referenceHeight; self.cells = cells; self.candidates = candidates; self.registration = registration
        warnings = ["Рельеф показывает только видимую поверхность. Корни, камни, растительность и канавы тоже создают аномалии; это не обнаружение захоронений."]
    }

    /// Check persisted coordinates before they can reach map or canvas APIs.
    public func validate() throws {
        guard schemaVersion == 1,cellSize.isFinite,(0.1...1).contains(cellSize),referenceHeight.isFinite,
              cells.count <= 20_000,candidates.count <= 10_000,sourceCaptureIDs.count <= 512,
              Set(cells.map(\.id)).count == cells.count,Set(candidates.map(\.id)).count == candidates.count else { throw TerrainSurveyError.invalidData }
        for cell in cells {
            guard (-20_000...20_000).contains(cell.column),(-20_000...20_000).contains(cell.row),cell.height.isFinite,cell.residual.isFinite,
                  cell.verticalSpread.isFinite,cell.verticalSpread >= 0,(1...24).contains(cell.sampleCount) else { throw TerrainSurveyError.invalidData }
        }
        func valid(_ point:MetricPoint2D) -> Bool { point.x.isFinite && point.y.isFinite && abs(point.x) < 2_000 && abs(point.y) < 2_000 }
        for candidate in candidates {
            guard candidate.frameID == frameID else { throw TerrainSurveyError.frameMismatch }
            guard valid(candidate.center),candidate.boundary.count <= 64,candidate.boundary.allSatisfy(valid),
                  candidate.heightDifference.isFinite,candidate.lengthMeters.isFinite,candidate.lengthMeters >= 0,
                  candidate.widthMeters.isFinite,candidate.widthMeters >= 0,candidate.observedArea.isFinite,candidate.observedArea >= 0,
                  candidate.verticalSpreadMeters.isFinite,candidate.verticalSpreadMeters >= 0,
                  candidate.verticalUncertaintyMeters.map({$0.isFinite && $0 >= 0}) != false else { throw TerrainSurveyError.invalidData }
            if let line = candidate.lineVertices { guard (2...64).contains(line.count),line.allSatisfy(valid) else { throw TerrainSurveyError.invalidData } }
        }
        if let registration {
            guard registration.frameID == frameID,registration.controls.allSatisfy({$0.frameID == frameID}) else { throw TerrainSurveyError.frameMismatch }
            guard registration.cosine.isFinite,registration.sine.isFinite,abs(registration.cosine*registration.cosine+registration.sine*registration.sine-1) < 0.0001,
                  registration.eastOffset.isFinite,registration.northOffset.isFinite,registration.rmsResidualMeters.isFinite,registration.rmsResidualMeters >= 0,
                  registration.maximumResidualMeters.isFinite,registration.maximumResidualMeters >= 0,
                  registration.origin.latitude.isFinite,abs(registration.origin.latitude) < 85,registration.origin.longitude.isFinite,abs(registration.origin.longitude) <= 180,
                  (2...32).contains(registration.controls.count),registration.positionalUncertaintyMeters.map({$0.isFinite && $0 >= 0}) != false else { throw TerrainSurveyError.invalidData }
        }
    }
}

public enum TerrainAnalysis {
    /// Cell samples are observed geometry only. No empty cell is synthesized.
    public static func analyze(_ batches: [TerrainMeshBatch], projectID: UUID, cemeteryID: UUID, frameID: UUID, cellSize: Double = 0.25, referenceHeight: Double? = nil, previous: TerrainSurvey? = nil) throws -> TerrainSurvey {
        guard batches.count <= 512, cellSize.isFinite, (0.1...1).contains(cellSize), referenceHeight?.isFinite != false else { throw TerrainSurveyError.invalidData }
        guard batches.allSatisfy({ $0.frameID == frameID }),
              previous == nil || (previous?.frameID == frameID && previous?.projectID == projectID && previous?.cemeteryID == cemeteryID) else { throw TerrainSurveyError.frameMismatch }
        var samples = [String: (Int, Int, [Double])]()
        for batch in batches {
            try Task.checkCancellation()
            guard batch.points.count <= 100_000 else { throw TerrainSurveyError.invalidData }
            for point in batch.points {
                guard point.x.isFinite, point.z.isFinite, point.height.isFinite, abs(point.x) < 2_000, abs(point.z) < 2_000, abs(point.height) < 1_000 else { throw TerrainSurveyError.invalidData }
                let x = Int(floor(point.x/cellSize)), z = Int(floor(point.z/cellSize)), key = "\(x):\(z)"
                if samples[key] == nil {
                    guard samples.count < 20_000 else { continue }
                    samples[key] = (x,z,[])
                }
                if samples[key]!.2.count < 24 { samples[key]!.2.append(point.height) }
            }
        }
        guard samples.count >= 12 else { throw TerrainSurveyError.insufficientSurface }
        var cells = [TerrainCell]()
        for value in samples.values {
            let sorted = value.2.sorted()
            let representative = sorted[max(0,(sorted.count-1)/4)]
            let spread = (sorted.last ?? representative)-(sorted.first ?? representative)
            cells.append(TerrainCell(column:value.0,row:value.1,height:representative,residual:0,sampleCount:sorted.count,verticalSpread:spread))
        }
        cells.sort { $0.column == $1.column ? $0.row < $1.row : $0.column < $1.column }
        let heights = cells.map(\.height).sorted(), reference = referenceHeight ?? previous?.referenceHeight ?? heights[heights.count/2]
        let plane = fitPlane(cells, cellSize: cellSize)
        for index in cells.indices {
            let p = cells[index].center(cellSize: cellSize)
            cells[index].residual = cells[index].height - (plane.0*p.x+plane.1*p.y+plane.2)
            cells[index].height -= reference
        }
        let candidates = propose(cells, cellSize: cellSize, frameID: frameID, previous: previous?.candidates ?? [])
        var result = TerrainSurvey(id: previous?.id ?? UUID(), projectID: projectID, cemeteryID: cemeteryID, frameID: frameID,
            sourceCaptureIDs: Array(Set(batches.map(\.captureID))).sorted { $0.uuidString < $1.uuidString }, cellSize: cellSize, referenceHeight: reference,
            cells: cells, candidates: candidates, registration: previous?.registration)
        if let previous { result.createdAt = previous.createdAt }
        if cells.count == 20_000 { result.warnings.append("Достигнут предел 20 000 измеренных ячеек. Разделите большой участок на фрагменты.") }
        return result
    }

    private static func fitPlane(_ cells: [TerrainCell], cellSize: Double) -> (Double, Double, Double) {
        var coefficients = (0.0,0.0,cells.map(\.height).sorted()[cells.count/2])
        for _ in 0..<6 {
            var matrix = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
            for cell in cells {
                let p = cell.center(cellSize: cellSize), v = [p.x,p.y,1.0]
                let residual = abs(cell.height - (coefficients.0*p.x+coefficients.1*p.y+coefficients.2))
                let weight = min(1, 0.08/max(residual,1e-8))
                for row in 0..<3 {
                    for column in 0..<3 { matrix[row][column] += weight*v[row]*v[column] }
                    matrix[row][3] += weight*v[row]*cell.height
                }
            }
            var valid = true
            for pivot in 0..<3 {
                let best = (pivot..<3).max { abs(matrix[$0][pivot]) < abs(matrix[$1][pivot]) }!
                matrix.swapAt(pivot,best)
                let scale = matrix[pivot][pivot]
                guard abs(scale) > 1e-9 else { valid = false; break }
                for column in pivot..<4 { matrix[pivot][column] /= scale }
                for row in 0..<3 where row != pivot {
                    let factor = matrix[row][pivot]
                    for column in pivot..<4 { matrix[row][column] -= factor*matrix[pivot][column] }
                }
            }
            if valid { coefficients = (matrix[0][3],matrix[1][3],matrix[2][3]) }
        }
        return coefficients
    }

    private static func propose(_ cells: [TerrainCell], cellSize: Double, frameID: UUID, previous: [TerrainCandidate]) -> [TerrainCandidate] {
        let byID = Dictionary(uniqueKeysWithValues: cells.map { ($0.id,$0) })
        var visited = Set<String>(), proposals = [TerrainCandidate](), matchedPrevious = Set<UUID>()
        for seed in cells where abs(seed.residual) >= 0.12 && abs(seed.residual) <= 1.8 && seed.verticalSpread <= 0.35 {
            guard visited.insert(seed.id).inserted else { continue }
            var cluster = [seed], queue = [seed], cursor = 0
            while cursor < queue.count {
                let current = queue[cursor]; cursor += 1
                for (dx,dz) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    let key = "\(current.column+dx):\(current.row+dz)"
                    guard let neighbor = byID[key], neighbor.residual*seed.residual > 0,
                          abs(neighbor.residual) >= 0.12, abs(neighbor.residual) <= 1.8, neighbor.verticalSpread <= 0.35,
                          visited.insert(key).inserted else { continue }
                    queue.append(neighbor); cluster.append(neighbor)
                }
            }
            guard cluster.count >= 6 else { continue }
            let points = cluster.map { $0.center(cellSize: cellSize) }, n = Double(points.count)
            let center = MetricPoint2D(x: points.reduce(0) { $0+$1.x }/n, y: points.reduce(0) { $0+$1.y }/n)
            let xx = points.reduce(0) { $0+pow($1.x-center.x,2) }, zz = points.reduce(0) { $0+pow($1.y-center.y,2) }, xz = points.reduce(0) { $0+($1.x-center.x)*($1.y-center.y) }
            let angle = 0.5*atan2(2*xz,xx-zz), c = cos(angle), s = sin(angle)
            let along = points.map { ($0.x-center.x)*c+($0.y-center.y)*s }, across = points.map { -($0.x-center.x)*s+($0.y-center.y)*c }
            let length = (along.max()!-along.min()!)+cellSize, width = (across.max()!-across.min()!)+cellSize
            let area = Double(cluster.count)*cellSize*cellSize
            guard length >= 0.8, length <= 15, width >= 0.2, width <= 3.5, area/(length*width) >= 0.4 else { continue }
            let kind: TerrainCandidateKind
            if seed.residual > 0, length >= 3, width <= 0.55 { kind = .linearObstacle }
            else {
                guard length <= 5, width >= 0.55, length/width >= 1.2, abs(seed.residual) <= 0.8 else { continue }
                kind = seed.residual > 0 ? .raisedSurface : .depression
            }
            var context = 0
            for cell in cluster {
                for (dx,dz) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    if let neighbor = byID["\(cell.column+dx):\(cell.row+dz)"], abs(neighbor.residual) < 0.12 { context += 1 }
                }
            }
            guard context >= 4 else { continue }
            let boundary = [(-length/2,-width/2),(length/2,-width/2),(length/2,width/2),(-length/2,width/2)].map { u,v in MetricPoint2D(x:center.x+u*c-v*s,y:center.y+u*s+v*c) }
            let heights = cluster.map(\.residual).sorted(), difference = heights[heights.count/2]
            let spread = cluster.map(\.verticalSpread).max() ?? 0
            let old = previous.filter { !matchedPrevious.contains($0.id) && $0.kind == kind && hypot($0.center.x-center.x,$0.center.y-center.y) < max(0.6,width) }.min { hypot($0.center.x-center.x,$0.center.y-center.y) < hypot($1.center.x-center.x,$1.center.y-center.y) }
            if let old { matchedPrevious.insert(old.id) }
            var candidate = TerrainCandidate(id:old?.id ?? UUID(),frameID:frameID,kind:kind,center:center,boundary:boundary,heightDifference:difference,
                lengthMeters:length,widthMeters:width,observedArea:area,verticalUncertaintyMeters:nil,verticalSpreadMeters:spread,
                evidence:"\(cluster.count) измеренных ячеек; локальное отклонение \(Int((difference*100).rounded())) см; форма \(String(format: "%.1f × %.1f",length,width)) м. Проверить видимые причины: земля, корни, камни, растительность, конструкции.",
                state:old?.state ?? .proposed,reviewedAt:old?.reviewedAt,confirmedFeatureID:old?.confirmedFeatureID)
            candidate.confirmedCategory = old?.confirmedCategory
            proposals.append(candidate)
        }
        // Operator decisions survive a later analysis with missing coverage.
        for old in previous where (old.state != .proposed || old.kind == .fenceLikeStructure) && !proposals.contains(where: { $0.id == old.id }) { proposals.append(old) }
        return proposals
    }
}
