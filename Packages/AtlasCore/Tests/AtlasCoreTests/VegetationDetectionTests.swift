import Foundation
import Testing
@testable import AtlasCore

/// Deliberately unlabeled mesh fixtures: a connected sampled trunk and ellipsoid
/// crown, or a low ellipsoid. The detector sees only coordinates and AR labels.
private func vegetationEllipsoid(frame: UUID, anchor: UUID, x: Double = 0, z: Double = 0,
                                 centerHeight: Double, radius: Double, verticalRadius: Double,
                                 classification: FenceSurfaceClassification = .unknown) -> [FenceTriangle] {
    let latitudes = 12, longitudes = 16
    func point(_ latitude: Int, _ longitude: Int) -> TerrainPoint {
        let theta = Double(latitude) * .pi / Double(latitudes)
        let phi = Double(longitude) * 2 * .pi / Double(longitudes)
        return .init(x:x+radius*sin(theta)*cos(phi), z:z+radius*sin(theta)*sin(phi),
                     height:centerHeight+verticalRadius*cos(theta))
    }
    var faces: [FenceTriangle] = []
    for latitude in 0..<latitudes {
        for longitude in 0..<longitudes {
            let a=point(latitude,longitude), b=point(latitude,longitude+1)
            let c=point(latitude+1,longitude+1), d=point(latitude+1,longitude)
            faces.append(.init(frameID:frame,anchorID:anchor,a:a,b:b,c:c,classification:classification))
            faces.append(.init(frameID:frame,anchorID:anchor,a:a,b:c,c:d,classification:classification))
        }
    }
    return faces
}

private func vegetationCylinder(frame: UUID, anchor: UUID, x: Double = 0, z: Double = 0,
                                height: Double, radius: Double) -> [FenceTriangle] {
    let layers = Int(ceil(height/0.3)), sides = 12
    func point(_ layer: Int, _ side: Int) -> TerrainPoint {
        let phi = Double(side)*2 * .pi/Double(sides)
        return .init(x:x+radius*cos(phi),z:z+radius*sin(phi),height:Double(layer)*height/Double(layers))
    }
    var faces: [FenceTriangle] = []
    for layer in 0..<layers {
        for side in 0..<sides {
            let a=point(layer,side), b=point(layer,side+1), c=point(layer+1,side+1), d=point(layer+1,side)
            faces.append(.init(frameID:frame,anchorID:anchor,a:a,b:b,c:c))
            faces.append(.init(frameID:frame,anchorID:anchor,a:a,b:c,c:d))
        }
    }
    return faces
}

private func vegetationTree(frame: UUID, anchor: UUID = UUID(), x: Double = 0, z: Double = 0) -> [FenceTriangle] {
    vegetationCylinder(frame:frame,anchor:anchor,x:x,z:z,height:1.8,radius:0.1)
    + vegetationEllipsoid(frame:frame,anchor:anchor,x:x,z:z,centerHeight:2.2,radius:0.8,verticalRadius:0.8)
}

@Test func treeShapeRequiresObservedStemAndCrownAndCarriesCounterEvidence() throws {
    let frame=UUID(), anchor=UUID()
    let results = try VegetationDetection.proposals(from:vegetationTree(frame:frame,anchor:anchor,x:8,z:-4),frameID:frame)
    let proposal = try #require(results.first)
    #expect(results.count == 1 && proposal.kind == .treeLike && proposal.frameID == frame)
    #expect(abs(proposal.center.x-8)<0.02 && abs(proposal.center.y+4)<0.02)
    #expect(proposal.heightSpanMeters>2.7 && proposal.heightSpanMeters<=3)
    #expect(proposal.canopyWidthMeters>1.5 && proposal.canopyDepthMeters>1.5)
    #expect(proposal.observedSurfaceArea>1 && proposal.sourceAnchorIDs == [anchor])
    #expect(proposal.evidence.contains("оператора"))
    #expect(proposal.counterEvidence.contains { $0.contains("Столб") })
    #expect(proposal.counterEvidence.contains { $0.contains("Вероятность") })
    let barePole = vegetationCylinder(frame:frame,anchor:anchor,height:3,radius:0.1)
    #expect(try VegetationDetection.proposals(from:barePole,frameID:frame).isEmpty)
    let canopyAlone = vegetationEllipsoid(frame:frame,anchor:anchor,centerHeight:2.2,radius:0.8,verticalRadius:0.8)
    #expect(try VegetationDetection.proposals(from:canopyAlone,frameID:frame).allSatisfy { $0.kind != .treeLike })
}

@Test func lowVolumetricShapeIsOnlyAShrubInspectionPromptWithUnknownIdentity() throws {
    let frame=UUID(), anchor=UUID()
    let input = vegetationEllipsoid(frame:frame,anchor:anchor,x:3,z:5,centerHeight:0.45,radius:0.6,verticalRadius:0.45)
    let proposals = try VegetationDetection.proposals(from:input,frameID:frame)
    let proposal = try #require(proposals.first)
    #expect(proposals.count == 1 && proposal.kind == .shrubLike)
    #expect(abs(proposal.center.x-3)<0.02 && abs(proposal.center.y-5)<0.02)
    // Nearly horizontal end-cap faces are excluded with ground/ceilings. The
    // reported span describes the retained observation, not the complete plant.
    #expect(proposal.heightSpanMeters>0.75 && proposal.heightSpanMeters<=0.9)
    #expect(proposal.canopyWidthMeters>1.1 && proposal.canopyDepthMeters>1.1)
    #expect(proposal.counterEvidence.contains { $0.contains("Камни") })
}

@Test func vegetationExcludesKnownSurfacesPlanarFencesFloorsAndDisconnectedNoise() throws {
    let frame=UUID(), anchor=UUID()
    for classification: FenceSurfaceClassification in [.wall,.other] {
        let faces=vegetationEllipsoid(frame:frame,anchor:anchor,centerHeight:0.45,radius:0.6,verticalRadius:0.45,
                                      classification:classification)
        #expect(try VegetationDetection.proposals(from:faces,frameID:frame).isEmpty)
    }
    var fence: [FenceTriangle] = []
    for column in 0..<12 {
        for row in 0..<3 {
            let x=Double(column)*0.25, h=Double(row)*0.25
            let a=TerrainPoint(x:x,z:0,height:h),b=TerrainPoint(x:x+0.25,z:0,height:h)
            let c=TerrainPoint(x:x+0.25,z:0,height:h+0.25),d=TerrainPoint(x:x,z:0,height:h+0.25)
            fence.append(.init(frameID:frame,anchorID:anchor,a:a,b:b,c:c))
            fence.append(.init(frameID:frame,anchorID:anchor,a:a,b:c,c:d))
        }
    }
    #expect(try VegetationDetection.proposals(from:fence,frameID:frame).isEmpty)
    let floor=FenceTriangle(frameID:frame,anchorID:anchor,a:.init(x:0,z:0,height:0),
                            b:.init(x:0.5,z:0,height:0),c:.init(x:0,z:0.5,height:0))
    #expect(try VegetationDetection.proposals(from:Array(repeating:floor,count:100),frameID:frame).isEmpty)
    let noise=(0..<100).map { index in
        let x=Double(index)*2
        return FenceTriangle(frameID:frame,anchorID:anchor,a:.init(x:x,z:0,height:0),
            b:.init(x:x+0.1,z:0,height:0),c:.init(x:x,z:0.1,height:0.1))
    }
    #expect(try VegetationDetection.proposals(from:noise,frameID:frame).isEmpty)
}

@Test func duplicateMeshGeometryCannotMultiplyEvidenceOrOverrideKnownWallClassification() throws {
    let frame=UUID(), anchor=UUID(), input=vegetationTree(frame:frame)
    let first=try #require(VegetationDetection.proposals(from:input,frameID:frame).first)
    let repeated=try #require(VegetationDetection.proposals(from:input+input.reversed(),frameID:frame).first)
    #expect(first.id == repeated.id && first.center == repeated.center)
    #expect(first.observedSurfaceArea == repeated.observedSurfaceArea)
    let shrub=vegetationEllipsoid(frame:frame,anchor:anchor,centerHeight:0.45,radius:0.6,verticalRadius:0.45)
    let walls=vegetationEllipsoid(frame:frame,anchor:UUID(),centerHeight:0.45,radius:0.6,verticalRadius:0.45,classification:.wall)
    #expect(try VegetationDetection.proposals(from:shrub+walls,frameID:frame).isEmpty)
}

@Test func vegetationInputIsBoundedAndRejectsForeignFramesAndNonfiniteOrExtremeCoordinates() throws {
    let frame=UUID(), input=vegetationTree(frame:frame)
    #expect(throws:VegetationDetectionError.frameMismatch) {
        try VegetationDetection.proposals(from:input,frameID:UUID())
    }
    var damaged=input[0];damaged.a.height = .infinity
    #expect(throws:VegetationDetectionError.invalidData) {
        try VegetationDetection.proposals(from:[damaged],frameID:frame)
    }
    damaged=input[0];damaged.a.x=2_001
    #expect(throws:VegetationDetectionError.invalidData) {
        try VegetationDetection.proposals(from:[damaged],frameID:frame)
    }
    #expect(throws:VegetationDetectionError.invalidData) {
        try VegetationDetection.proposals(from:Array(repeating:input[0],count:VegetationDetection.maximumTriangles+1),frameID:frame)
    }
}

@Test func vegetationRedetectionPreservesRejectedAndConfirmedOperatorDecisions() throws {
    let frame=UUID(), input=vegetationTree(frame:frame)
    let original=try VegetationDetection.proposals(from:input,frameID:frame)
    let shifted=try VegetationDetection.proposals(from:vegetationTree(frame:frame,x:0.2),frameID:frame)
    var survey=TerrainSurvey(projectID:UUID(),cemeteryID:UUID(),frameID:frame,sourceCaptureIDs:[])
    survey=try survey.includingVegetationProposals(original)
    #expect(survey.candidates.count == 1 && survey.candidates[0].kind == .treeLikeStructure)
    #expect(survey.candidates[0].state == .proposed && survey.candidates[0].confirmedCategory == nil)
    #expect(survey.candidates[0].boundary.isEmpty && survey.candidates[0].verticalUncertaintyMeters == nil)
    let changed=try survey.includingVegetationProposals(shifted)
    #expect(changed.candidates.count == 1 && changed.candidates[0].id == survey.candidates[0].id)
    #expect(changed.candidates[0].center != survey.candidates[0].center)
    survey.candidates[0].state = .rejected
    let rejected=try survey.includingVegetationProposals(shifted)
    #expect(rejected.candidates == survey.candidates)
    survey.candidates[0].state = .confirmed
    survey.candidates[0].confirmedFeatureID=UUID();survey.candidates[0].confirmedCategory = .tree
    let confirmed=try survey.includingVegetationProposals(shifted)
    #expect(confirmed.candidates == survey.candidates)
}

@Test func oldPolygonFeatureAndNewVegetationPointsRetainCodableGeometryWithoutInventedArea() throws {
    // Hand-authored schema-1 payload; old unlabeled polygon case and category
    // must remain readable after additive vegetation enum expansion.
    let legacy = Data(#"""
    {"id":"10000000-0000-0000-0000-000000000001","projectID":"10000000-0000-0000-0000-000000000002",
     "label":"Legacy grave","category":"grave","geometry":{"metricPolygon":{"_0":{
       "frameID":"10000000-0000-0000-0000-000000000003","vertices":[{"x":0,"y":0},{"x":2,"y":0},{"x":2,"y":1},{"x":0,"y":1}],"holes":[]}}},
     "attributes":{},"notes":"","reviewStatus":"draft","revision":1}
    """#.utf8)
    let old=try FieldTransferJSON.decode(AtlasFeature.self,from:legacy)
    #expect(old.category == .grave)
    if case .metricPolygon(let polygon)=old.geometry { #expect(try PolygonGeometry.area(of:polygon)==2) }
    else { Issue.record("Legacy polygon geometry changed") }
    let point = Data(#"""
    {"id":"10000000-0000-0000-0000-000000000004","projectID":"10000000-0000-0000-0000-000000000002",
     "label":"Tree reviewed","category":"tree","geometry":{"metricPoint":{
       "frameID":"10000000-0000-0000-0000-000000000003","point":{"x":4,"y":5}}},
     "attributes":{"survey.status":"confirmed"},"notes":"","reviewStatus":"reviewed","revision":1}
    """#.utf8)
    let tree=try FieldTransferJSON.decode(AtlasFeature.self,from:point)
    #expect(tree.category == .tree)
    #expect(tree.geometry == .metricPoint(frameID:UUID(uuidString:"10000000-0000-0000-0000-000000000003")!,point:.init(x:4,y:5)))
    #expect(try FieldTransferJSON.decode(AtlasFeature.self,from:FieldTransferJSON.encode(tree))==tree)
}
