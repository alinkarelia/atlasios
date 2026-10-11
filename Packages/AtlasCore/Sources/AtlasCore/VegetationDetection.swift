import Foundation

public enum VegetationProposalKind: String, Codable, Sendable { case treeLike, shrubLike }

/// Geometry-only inspection prompt. Shape cannot establish a plant's identity:
/// poles, sculptures, stones and incomplete scans remain counter-evidence.
public struct VegetationProposal: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let frameID: UUID
    public let kind: VegetationProposalKind
    public let center: MetricPoint2D
    public let heightSpanMeters: Double
    public let canopyWidthMeters: Double
    public let canopyDepthMeters: Double
    /// Sum of deduplicated observed triangle areas, not a unioned footprint.
    public let observedSurfaceArea: Double
    public let sourceAnchorIDs: [UUID]
    public let evidence: String
    public let counterEvidence: [String]
}

public enum VegetationDetectionError: Error, LocalizedError, Equatable, Sendable {
    case invalidData, frameMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidData: "Данные объёмных поверхностей повреждены или превышают ограничение анализа."
        case .frameMismatch: "Поверхности относятся к разным локальным сессиям. Анализируйте их отдельно."
        }
    }
}

/// Bounded shape heuristics on real, full-3D unknown mesh faces. Tree prompts
/// require both a narrow vertically sampled lower stem and a broad nonplanar
/// upper crown. Shrub prompts require a low, thick, irregular volume. Known wall
/// and other classified surfaces are excluded; no ML species classification,
/// measured probability, ground datum or survey accuracy is inferred.
public enum VegetationDetection {
    public static let maximumTriangles = 20_000
    public static let maximumProposals = 128

    public static func proposals(from triangles: [FenceTriangle], frameID: UUID) throws -> [VegetationProposal] {
        guard triangles.count <= maximumTriangles else { throw VegetationDetectionError.invalidData }
        var raw: [FaceKey: Face] = [:]
        for triangle in triangles {
            guard triangle.frameID == frameID else { throw VegetationDetectionError.frameMismatch }
            let p = [triangle.a,triangle.b,triangle.c]
            guard p.allSatisfy({ $0.x.isFinite && $0.z.isFinite && $0.height.isFinite && abs($0.x)<2_000
                && abs($0.z)<2_000 && abs($0.height)<1_000 }) else { throw VegetationDetectionError.invalidData }
            let s = p.sorted(by:order), key = FaceKey(a:s[0],b:s[1],c:s[2])
            if var previous = raw[key] {
                previous.anchors.insert(triangle.anchorID); previous.excluded = previous.excluded || triangle.classification != .unknown
                raw[key] = previous
            } else { raw[key] = Face(triangle:triangle,anchors:[triangle.anchorID],excluded:triangle.classification != .unknown) }
        }
        var cells: [Cell:[Face]] = [:]
        for face in raw.values where !face.excluded {
            let a = face.triangle.a, b = face.triangle.b, c = face.triangle.c, normal = cross(a,b,c)
            let magnitude = sqrt(normal.0*normal.0+normal.1*normal.1+normal.2*normal.2)
            // Flat ground/ceilings cannot connect unrelated plants into a scene-wide cluster.
            guard magnitude > 1e-8, abs(normal.1)/magnitude < 0.95,
                  max(distance(a,b),distance(a,c),distance(b,c)) <= 1.2 else { continue }
            let cell = Cell(x:Int(floor((a.x+b.x+c.x)/1.5)),z:Int(floor((a.z+b.z+c.z)/1.5)),
                            h:Int(floor((a.height+b.height+c.height)/1.5)))
            cells[cell,default:[]].append(face)
        }
        var visited = Set<Cell>(), results = [VegetationProposal]()
        let starts = cells.keys.sorted { ($0.x,$0.z,$0.h)<($1.x,$1.z,$1.h) }
        for start in starts where !visited.contains(start) {
            var pending = [start], faces = [Face](); visited.insert(start)
            while let cell = pending.popLast() {
                faces.append(contentsOf:cells[cell] ?? [])
                for x in -1...1 { for z in -1...1 { for h in -1...1 {
                    let key = Cell(x:cell.x+x,z:cell.z+z,h:cell.h+h)
                    if cells[key] != nil,visited.insert(key).inserted { pending.append(key) }
                }}}
            }
            if let proposal = inspect(faces,frameID:frameID) { results.append(proposal) }
        }
        let unique = Dictionary(results.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
        return unique.values.sorted { $0.id.uuidString<$1.id.uuidString }.prefix(maximumProposals).map { $0 }
    }

    private static func inspect(_ faces: [Face], frameID: UUID) -> VegetationProposal? {
        guard faces.count>=18 else { return nil }
        let points = Set(faces.flatMap { [$0.triangle.a,$0.triangle.b,$0.triangle.c] }).sorted(by:order)
        guard points.count>=24,let low = points.map(\.height).min(),let high = points.map(\.height).max() else { return nil }
        let span = high-low
        guard span>=0.35,span<=15 else { return nil }
        let spread = horizontal(points)
        guard spread.major<=8,spread.minor>=0.35 else { return nil }
        // A small set of planar sides (walls, boxes, fences) is insufficient.
        let orientations = Set(faces.compactMap { face -> Int? in
            let n = cross(face.triangle.a,face.triangle.b,face.triangle.c), horizontal = hypot(n.0,n.2)
            guard horizontal>1e-8 else { return nil }
            var angle = atan2(n.2,n.0); if angle<0 { angle += .pi }
            return Int(floor((angle + .pi/24)/(.pi/12)))%12
        })
        guard orientations.count>=4 else { return nil }
        let kind: VegetationProposalKind, center: MetricPoint2D, crown: Spread, description: String
        if span>=2.4 {
            let stem = points.filter { $0.height<=low+min(1,span*0.4) }
            let upper = points.filter { $0.height>=low+max(0.8,span*0.35) }
            guard stem.count>=12,upper.count>=18 else { return nil }
            let base = horizontal(stem), top = horizontal(upper)
            let stemSpan = (stem.map(\.height).max() ?? low)-low
            let levels = Set(stem.map { Int(floor(($0.height-low)/0.2)) })
            let crownSpan = (upper.map(\.height).max() ?? low)-(upper.map(\.height).min() ?? low)
            guard base.major<=0.7,base.minor<=0.7,stemSpan>=0.45,levels.count>=3,
                  top.major>=1,top.minor>=0.6,top.major>=base.major*2,crownSpan>=0.5 else { return nil }
            kind = .treeLike; center = base.center; crown = top
            description = "Наблюдается узкая нижняя часть и широкая неплоская верхняя часть. Возможная древесная растительность; требуется осмотр оператора."
        } else {
            guard span<=1.8,spread.major>=0.5,spread.major<=3,spread.minor>=0.4,
                  spread.minor/spread.major>=0.4 else { return nil }
            kind = .shrubLike; center = spread.center; crown = spread
            description = "Наблюдается низкий объёмный объект с разными направлениями граней. Возможный кустарник; требуется осмотр оператора."
        }
        // Canonical order avoids changing observed area due to hash-table/input order.
        let sortedFaces = faces.sorted { lhs,rhs in
            let left = [lhs.triangle.a,lhs.triangle.b,lhs.triangle.c].sorted(by:order)
            let right = [rhs.triangle.a,rhs.triangle.b,rhs.triangle.c].sorted(by:order)
            for index in 0..<3 where left[index] != right[index] { return order(left[index],right[index]) }
            return false
        }
        let area = sortedFaces.reduce(0.0) { sum,face in let n = cross(face.triangle.a,face.triangle.b,face.triangle.c)
            return sum+sqrt(n.0*n.0+n.1*n.1+n.2*n.2)/2 }
        let anchors = Set(faces.flatMap { $0.anchors }).sorted { $0.uuidString<$1.uuidString }
        let identity = "vegetation|\(frameID.uuidString)|\(kind.rawValue)|\(Int((center.x*2).rounded())),\(Int((center.y*2).rounded()))"
        let hex = Array(FieldTransferDigest.sha256(Data(identity.utf8)).prefix(32))
        let text = String(hex[0..<8])+"-"+String(hex[8..<12])+"-5"+String(hex[13..<16])+"-a"+String(hex[17..<20])+"-"+String(hex[20..<32])
        guard let id = UUID(uuidString:text) else { return nil }
        return VegetationProposal(id:id,frameID:frameID,kind:kind,center:center,heightSpanMeters:span,canopyWidthMeters:crown.major,
            canopyDepthMeters:crown.minor,observedSurfaceArea:area,sourceAnchorIDs:anchors,evidence:description,
            counterEvidence:[kind == .treeLike ? "Столб с навесом или скульптура могут иметь похожую форму." : "Камни, памятники и другие объёмные предметы могут иметь похожую форму.",
                "Листва, порода и биологический вид не распознаны. Вероятность и точность классификации не измерены.",
                "Основание и вершина могут быть сняты не полностью. Размеры относятся к наблюдаемой части, а не к полной высоте растения."])
    }

    private static func horizontal(_ points: [TerrainPoint]) -> Spread {
        let origin = points[0], n = Double(points.count)
        let x = origin.x+points.reduce(0) { $0+$1.x-origin.x }/n, z = origin.z+points.reduce(0) { $0+$1.z-origin.z }/n
        var xx = 0.0,zz = 0.0,xz = 0.0
        for p in points { let a=p.x-x,b=p.z-z; xx+=a*a;zz+=b*b;xz+=a*b }
        let angle = 0.5*atan2(2*xz,xx-zz),c=cos(angle),s=sin(angle)
        let major = points.map { ($0.x-x)*c+($0.z-z)*s },minor = points.map { -($0.x-x)*s+($0.z-z)*c }
        return Spread(center:.init(x:x,y:z),major:major.max()!-major.min()!,minor:minor.max()!-minor.min()!)
    }
    private static func cross(_ a:TerrainPoint,_ b:TerrainPoint,_ c:TerrainPoint)->(Double,Double,Double) {
        let x=b.x-a.x,y=b.height-a.height,z=b.z-a.z,u=c.x-a.x,v=c.height-a.height,w=c.z-a.z
        return (y*w-z*v,z*u-x*w,x*v-y*u)
    }
    private static func distance(_ a:TerrainPoint,_ b:TerrainPoint)->Double { sqrt(pow(a.x-b.x,2)+pow(a.z-b.z,2)+pow(a.height-b.height,2)) }
    private static func order(_ a:TerrainPoint,_ b:TerrainPoint)->Bool { (a.x,a.z,a.height)<(b.x,b.z,b.height) }
    private struct FaceKey:Hashable { var a:TerrainPoint;var b:TerrainPoint;var c:TerrainPoint }
    private struct Face { var triangle:FenceTriangle;var anchors:Set<UUID>;var excluded:Bool }
    private struct Cell:Hashable { var x:Int;var z:Int;var h:Int }
    private struct Spread { var center:MetricPoint2D;var major:Double;var minor:Double }
}

extension TerrainSurvey {
    public func includingVegetationProposals(_ proposals: [VegetationProposal]) throws -> TerrainSurvey {
        try validate()
        guard proposals.count<=VegetationDetection.maximumProposals else { throw VegetationDetectionError.invalidData }
        var result = self,matched = Set<UUID>()
        for proposal in proposals {
            guard proposal.frameID==frameID else { throw VegetationDetectionError.frameMismatch }
            guard proposal.center.x.isFinite,proposal.center.y.isFinite,abs(proposal.center.x)<2_000,abs(proposal.center.y)<2_000,
                  proposal.heightSpanMeters.isFinite,(0.35...15).contains(proposal.heightSpanMeters),proposal.canopyWidthMeters.isFinite,
                  proposal.canopyDepthMeters.isFinite,proposal.canopyWidthMeters>=0.5,proposal.canopyWidthMeters<=8,
                  proposal.canopyDepthMeters>=0.35,proposal.canopyDepthMeters<=8,proposal.observedSurfaceArea.isFinite,
                  proposal.observedSurfaceArea>0,proposal.sourceAnchorIDs.count<=VegetationDetection.maximumTriangles,
                  !proposal.sourceAnchorIDs.isEmpty,Set(proposal.sourceAnchorIDs).count==proposal.sourceAnchorIDs.count,
                  proposal.evidence.utf16.count<=2_048,proposal.counterEvidence.count<=16,
                  proposal.counterEvidence.allSatisfy({$0.utf16.count<=2_048}) else { throw VegetationDetectionError.invalidData }
            switch proposal.kind {
            case .treeLike:
                guard proposal.heightSpanMeters>=2.4,proposal.canopyWidthMeters>=1,proposal.canopyDepthMeters>=0.6 else {
                    throw VegetationDetectionError.invalidData
                }
            case .shrubLike:
                guard proposal.heightSpanMeters<=1.8,proposal.canopyWidthMeters<=3,proposal.canopyDepthMeters>=0.4,
                      proposal.canopyDepthMeters/proposal.canopyWidthMeters>=0.4 else { throw VegetationDetectionError.invalidData }
            }
            let kind:TerrainCandidateKind = proposal.kind == .treeLike ? .treeLikeStructure : .shrubLikeStructure
            let index = result.candidates.indices.first { index in let old=result.candidates[index]
                return old.kind==kind && old.frameID==frameID && !matched.contains(old.id)
                    && hypot(old.center.x-proposal.center.x,old.center.y-proposal.center.y)<=0.75 }
            if let index {
                matched.insert(result.candidates[index].id)
                if result.candidates[index].state != .proposed { continue }
                result.candidates[index].center = proposal.center
                result.candidates[index].heightDifference = proposal.heightSpanMeters
                result.candidates[index].lengthMeters = proposal.canopyWidthMeters
                result.candidates[index].widthMeters = proposal.canopyDepthMeters
                result.candidates[index].observedArea = proposal.observedSurfaceArea
                result.candidates[index].evidence = proposal.evidence+" "+proposal.counterEvidence.joined(separator:" ")
            } else {
                result.candidates.append(TerrainCandidate(id:proposal.id,frameID:frameID,kind:kind,center:proposal.center,boundary:[],
                    heightDifference:proposal.heightSpanMeters,lengthMeters:proposal.canopyWidthMeters,widthMeters:proposal.canopyDepthMeters,
                    observedArea:proposal.observedSurfaceArea,verticalUncertaintyMeters:nil,verticalSpreadMeters:proposal.heightSpanMeters,
                    evidence:proposal.evidence+" "+proposal.counterEvidence.joined(separator:" "),state:.proposed,reviewedAt:nil,confirmedFeatureID:nil))
                matched.insert(proposal.id)
            }
        }
        guard result.candidates.count<=10_000 else { throw VegetationDetectionError.invalidData }
        try result.validate();return result
    }
}
