import Foundation

public enum FenceSurfaceClassification: String, Codable, Sendable { case unknown, wall, other }

public struct FenceTriangle: Codable, Hashable, Sendable {
    public var frameID: UUID
    public var anchorID: UUID
    public var a: TerrainPoint
    public var b: TerrainPoint
    public var c: TerrainPoint
    public var classification: FenceSurfaceClassification
    public init(frameID: UUID, anchorID: UUID, a: TerrainPoint, b: TerrainPoint, c: TerrainPoint,
                classification: FenceSurfaceClassification = .unknown) {
        self.frameID = frameID; self.anchorID = anchorID; self.a = a; self.b = b; self.c = c
        self.classification = classification
    }
}

/// A measured, sparse vertical surface that merits inspection. This is neither
/// a semantic fence classification nor a calibrated probability or map position.
public struct FenceProposal: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let frameID: UUID
    public let line: MetricPolyline
    public let heightSpanMeters: Double
    /// Sum of deduplicated source triangle areas, not an enclosed ground area.
    public let observedSurfaceArea: Double
    public let sourceAnchorIDs: [UUID]
    public let evidence: String
}

public enum FenceDetectionError: Error, LocalizedError, Equatable, Sendable {
    case invalidData, frameMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidData: "Данные вертикальных поверхностей повреждены или превышают ограничение анализа."
        case .frameMismatch: "Вертикальные поверхности относятся к разным локальным сессиям. Анализируйте их отдельно."
        }
    }
}

/// Conservative geometry only: unknown vertical faces, sparse support, small
/// cross-line thickness and bounded height span. Classified walls, solid panels,
/// floor surfaces and isolated blocks are excluded. Stone/solid fences may be
/// missed and remain available for manual surveying. Maximum work is bounded by
/// 20,000 input triangles, occupancy-cell traversal and per-component sorting.
public enum FenceDetection {
    public static let maximumTriangles = 20_000
    public static let maximumProposals = 128

    public static func proposals(from triangles: [FenceTriangle], frameID: UUID) throws -> [FenceProposal] {
        guard triangles.count <= maximumTriangles else { throw FenceDetectionError.invalidData }
        var faces: [FaceKey: Face] = [:]
        for triangle in triangles {
            guard triangle.frameID == frameID else { throw FenceDetectionError.frameMismatch }
            let points = [triangle.a, triangle.b, triangle.c]
            guard points.allSatisfy({ $0.x.isFinite && $0.z.isFinite && $0.height.isFinite
                && abs($0.x) < 2_000 && abs($0.z) < 2_000 && abs($0.height) < 1_000 }) else { throw FenceDetectionError.invalidData }
            let ordered = points.sorted(by: order)
            let key = FaceKey(a: ordered[0], b: ordered[1], c: ordered[2])
            if var existing = faces[key] {
                existing.anchors.insert(triangle.anchorID)
                existing.excluded = existing.excluded || triangle.classification != .unknown
                faces[key] = existing
            } else {
                faces[key] = Face(triangle: triangle, anchors: [triangle.anchorID], excluded: triangle.classification != .unknown)
            }
        }
        var cells: [Cell: [Face]] = [:]
        for face in faces.values where !face.excluded {
            let t = face.triangle, a = t.a, b = t.b, c = t.c
            let ux = b.x-a.x, uy = b.height-a.height, uz = b.z-a.z
            let vx = c.x-a.x, vy = c.height-a.height, vz = c.z-a.z
            let nx = uy*vz-uz*vy, ny = uz*vx-ux*vz, nz = ux*vy-uy*vx
            let magnitude = sqrt(nx*nx+ny*ny+nz*nz)
            let longest = max(distance(a,b), distance(a,c), distance(b,c))
            guard magnitude > 1e-8, abs(ny)/magnitude <= 0.25, longest <= 1.2 else { continue }
            var angle = atan2(nz,nx)
            if angle < 0 { angle += .pi }
            let orientation = Int(floor((angle + .pi/24) / (.pi/12))) % 12
            let centerX = (a.x+b.x+c.x)/3, centerZ = (a.z+b.z+c.z)/3
            let cell = Cell(x: Int(floor(centerX/0.5)), z: Int(floor(centerZ/0.5)), orientation: orientation)
            cells[cell, default: []].append(face)
        }
        var visited = Set<Cell>(), results = [FenceProposal]()
        let keys = cells.keys.sorted { ($0.orientation,$0.x,$0.z) < ($1.orientation,$1.x,$1.z) }
        for start in keys where !visited.contains(start) {
            var pending = [start], component = [Face](); visited.insert(start)
            while let cell = pending.popLast() {
                component.append(contentsOf: cells[cell] ?? [])
                for x in -1...1 { for z in -1...1 {
                    let neighbor = Cell(x:cell.x+x,z:cell.z+z,orientation:cell.orientation)
                    if cells[neighbor] != nil, visited.insert(neighbor).inserted { pending.append(neighbor) }
                }}
            }
            if let proposal = makeProposal(component, frameID: frameID) { results.append(proposal) }
        }
        let unique = Dictionary(results.map { ($0.id,$0) }, uniquingKeysWith: { first, _ in first })
        return unique.values.sorted {
            let a = try? PolygonGeometry.length(of:$0.line), b = try? PolygonGeometry.length(of:$1.line)
            return a == b ? $0.id.uuidString < $1.id.uuidString : (a ?? 0) > (b ?? 0)
        }.prefix(maximumProposals).map { $0 }
    }

    private static func makeProposal(_ faces: [Face], frameID: UUID) -> FenceProposal? {
        guard faces.count >= 6 else { return nil }
        let points = Set(faces.flatMap { [$0.triangle.a,$0.triangle.b,$0.triangle.c] }).sorted(by:order)
        guard let origin = points.first, points.count >= 8 else { return nil }
        let n = Double(points.count)
        let x = origin.x + points.reduce(0) { $0 + $1.x-origin.x }/n
        let z = origin.z + points.reduce(0) { $0 + $1.z-origin.z }/n
        var xx = 0.0, zz = 0.0, xz = 0.0
        for p in points { let dx = p.x-x, dz = p.z-z; xx += dx*dx; zz += dz*dz; xz += dx*dz }
        let angle = 0.5*atan2(2*xz,xx-zz), ux = cos(angle), uz = sin(angle)
        func along(_ p: TerrainPoint) -> Double { (p.x-x)*ux+(p.z-z)*uz }
        let distances = points.map(along)
        let crossDistances = points.map { -($0.x-x)*uz+($0.z-z)*ux }
        let low = distances.min()!, high = distances.max()!, length = high-low
        let width = crossDistances.max()!-crossDistances.min()!
        let vertical = points.map(\.height), span = vertical.max()!-vertical.min()!
        guard length >= 1.5, length <= 100, width <= 0.25, length >= width*8, span >= 0.35, span <= 2.4 else { return nil }
        var area = 0.0
        var intervals = [(Double,Double)]()
        for face in faces {
            let t = face.triangle, a = t.a, b = t.b, c = t.c
            let ux = b.x-a.x, uy = b.height-a.height, uz = b.z-a.z
            let vx = c.x-a.x, vy = c.height-a.height, vz = c.z-a.z
            let nx = uy*vz-uz*vy, ny = uz*vx-ux*vz, nz = ux*vy-uy*vx
            area += sqrt(nx*nx+ny*ny+nz*nz)/2
            let values = [along(a),along(b),along(c)]
            intervals.append((values.min()!,values.max()!))
        }
        // Do not promote a continuous low wall or solid side of a large block.
        guard area/(length*span) < 0.65 else { return nil }
        intervals.sort { $0.0 < $1.0 }
        var coveredUntil = intervals[0].1
        for interval in intervals.dropFirst() {
            guard interval.0-coveredUntil <= 0.65 else { return nil }
            coveredUntil = max(coveredUntil,interval.1)
        }
        let endpoints = [MetricPoint2D(x:x+low*ux,y:z+low*uz),MetricPoint2D(x:x+high*ux,y:z+high*uz)]
        let anchors = Set(faces.flatMap { $0.anchors }).sorted { $0.uuidString < $1.uuidString }
        let identity = frameID.uuidString + endpoints.map { "|\(Int(($0.x*4).rounded())),\(Int(($0.y*4).rounded()))" }.joined()
        let digest = FieldTransferDigest.sha256(Data(identity.utf8)), hex = Array(digest.prefix(32))
        let uuid = String(hex[0..<8])+"-"+String(hex[8..<12])+"-5"+String(hex[13..<16])+"-a"+String(hex[17..<20])+"-"+String(hex[20..<32])
        guard let id = UUID(uuidString:uuid) else { return nil }
        return FenceProposal(id:id,frameID:frameID,line:.init(frameID:frameID,vertices:endpoints),heightSpanMeters:span,
            observedSurfaceArea:area,sourceAnchorIDs:anchors,
            evidence:"Разреженная узкая вертикальная поверхность в исходной сетке. Возможная линия ограждения; назначение определяет оператор. Высота — наблюдаемый диапазон, точность и основание на земле не установлены.")
    }

    private static func distance(_ a: TerrainPoint, _ b: TerrainPoint) -> Double {
        sqrt(pow(a.x-b.x,2)+pow(a.z-b.z,2)+pow(a.height-b.height,2))
    }
    private static func order(_ a: TerrainPoint, _ b: TerrainPoint) -> Bool { (a.x,a.z,a.height) < (b.x,b.z,b.height) }
    private struct Cell: Hashable { var x:Int; var z:Int; var orientation:Int }
    private struct FaceKey: Hashable { var a:TerrainPoint; var b:TerrainPoint; var c:TerrainPoint }
    private struct Face { var triangle:FenceTriangle; var anchors:Set<UUID>; var excluded:Bool }
}

extension TerrainSurvey {
    /// Match nearby proposals to existing decisions. Re-analysis never restores a
    /// rejected candidate, changes a confirmed feature, or creates a polygon.
    public func includingFenceProposals(_ proposals: [FenceProposal]) throws -> TerrainSurvey {
        try validate()
        guard proposals.count <= FenceDetection.maximumProposals, proposals.allSatisfy({ $0.frameID == frameID && $0.line.frameID == frameID }) else { throw FenceDetectionError.frameMismatch }
        var result = self, matched = Set<UUID>()
        for proposal in proposals {
            try PolygonGeometry.validate(proposal.line)
            guard proposal.line.vertices.count == 2, proposal.heightSpanMeters.isFinite, (0.35...2.4).contains(proposal.heightSpanMeters),
                  proposal.observedSurfaceArea.isFinite, proposal.observedSurfaceArea > 0 else { throw FenceDetectionError.invalidData }
            let a = proposal.line.vertices[0], b = proposal.line.vertices[1]
            let center = MetricPoint2D(x:(a.x+b.x)/2,y:(a.y+b.y)/2)
            let existing = result.candidates.indices.first { index in
                let candidate = result.candidates[index]
                guard candidate.kind == .fenceLikeStructure, candidate.frameID == frameID, !matched.contains(candidate.id),
                      let old = candidate.lineVertices, old.count == 2 else { return false }
                let oldCenter = MetricPoint2D(x:(old[0].x+old[1].x)/2,y:(old[0].y+old[1].y)/2)
                let dx = b.x-a.x, dy = b.y-a.y, ox = old[1].x-old[0].x, oy = old[1].y-old[0].y
                let norm = hypot(dx,dy)*hypot(ox,oy)
                return norm > 0 && abs((dx*ox+dy*oy)/norm) >= 0.96 && hypot(center.x-oldCenter.x,center.y-oldCenter.y) <= 0.75
            }
            if let existing {
                matched.insert(result.candidates[existing].id)
                if result.candidates[existing].state != .proposed { continue }
                result.candidates[existing].center = center
                result.candidates[existing].lineVertices = proposal.line.vertices
                result.candidates[existing].heightDifference = proposal.heightSpanMeters
                result.candidates[existing].lengthMeters = try PolygonGeometry.length(of:proposal.line)
                result.candidates[existing].observedArea = proposal.observedSurfaceArea
                result.candidates[existing].evidence = proposal.evidence
            } else {
                var candidate = TerrainCandidate(id:proposal.id,frameID:frameID,kind:.fenceLikeStructure,center:center,boundary:[],
                    heightDifference:proposal.heightSpanMeters,lengthMeters:try PolygonGeometry.length(of:proposal.line),widthMeters:0,
                    observedArea:proposal.observedSurfaceArea,verticalUncertaintyMeters:nil,verticalSpreadMeters:proposal.heightSpanMeters,
                    evidence:proposal.evidence,state:.proposed,reviewedAt:nil,confirmedFeatureID:nil)
                candidate.lineVertices = proposal.line.vertices
                result.candidates.append(candidate); matched.insert(candidate.id)
            }
        }
        guard result.candidates.count <= 10_000 else { throw FenceDetectionError.invalidData }
        try result.validate()
        return result
    }
}
