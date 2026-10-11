import Foundation
import Testing
@testable import AtlasCore

private func terrainBatch(frame: UUID, raised: Double? = nil, tree: Bool = false, slope: Bool = false, shift: Double = 0) -> TerrainMeshBatch {
    var points = [TerrainPoint]()
    for x in 0..<24 {
        for z in 0..<24 {
            let px = (Double(x)+0.5)*0.25, pz = (Double(z)+0.5)*0.25
            let anomalous = tree ? (x == 10 && z == 10) : (8...15).contains(x) && (10...13).contains(z)
            let height = shift + (slope ? px*0.08+pz*0.03 : 0) + (anomalous ? raised ?? 0 : 0)
            points.append(.init(x:px,z:pz,height:height))
        }
    }
    return .init(frameID:frame,anchorID:UUID(),captureID:UUID(),points:points)
}

@Test func terrainPlanesAndSlopesNeverBecomeBurialProposals() throws {
    let frame = UUID()
    for slope in [false,true] {
        let result = try TerrainAnalysis.analyze([terrainBatch(frame:frame,slope:slope)],projectID:UUID(),cemeteryID:UUID(),frameID:frame)
        #expect(result.candidates.isEmpty)
        #expect(result.cells.count == 576)
        #expect(result.cells.allSatisfy { abs($0.residual) < 1e-6 })
        #expect(result.registration == nil)
    }
}

@Test func visibleMoundsAndDepressionsRemainHumanReviewAnomalies() throws {
    let frame = UUID(), project = UUID(), cemetery = UUID()
    for difference in [0.3,-0.25] {
        let result = try TerrainAnalysis.analyze([terrainBatch(frame:frame,raised:difference)],projectID:project,cemeteryID:cemetery,frameID:frame)
        #expect(result.candidates.count == 1)
        let candidate = try #require(result.candidates.first)
        #expect(candidate.kind == (difference > 0 ? .raisedSurface : .depression))
        #expect(candidate.state == .proposed && candidate.reviewedAt == nil)
        #expect(candidate.frameID == frame)
        #expect(abs(candidate.heightDifference-difference) < 0.04)
        #expect(candidate.lengthMeters >= 1.7 && candidate.widthMeters >= 0.8)
        #expect(candidate.evidence.contains("корни"))
        #expect(!candidate.evidence.contains("могила"))
    }
}

@Test func isolatedSmallObstacleAndAbsentGroundContextHaveNoProposal() throws {
    let frame = UUID()
    let small = try TerrainAnalysis.analyze([terrainBatch(frame:frame,raised:0.5,tree:true)],projectID:UUID(),cemeteryID:UUID(),frameID:frame)
    #expect(small.candidates.isEmpty)
    let onlyRaised = terrainBatch(frame:frame,raised:0.3).points.filter { $0.height > 0 }
    let noContext = try TerrainAnalysis.analyze([.init(frameID:frame,anchorID:UUID(),captureID:UUID(),points:onlyRaised)],projectID:UUID(),cemeteryID:UUID(),frameID:frame)
    #expect(noContext.candidates.isEmpty)
    #expect(noContext.cells.count == onlyRaised.count)
}

@Test func sparseCoverageDoesNotInterpolateUnobservedCells() throws {
    let frame = UUID()
    let points = (0..<16).map { TerrainPoint(x:Double($0)*0.5,z:0,height:0) }
    let result = try TerrainAnalysis.analyze([.init(frameID:frame,anchorID:UUID(),captureID:UUID(),points:points)],projectID:UUID(),cemeteryID:UUID(),frameID:frame)
    #expect(result.cells.count == 16)
    #expect(result.cells.allSatisfy { $0.column % 2 == 0 })
    #expect(result.candidates.isEmpty)
}

@Test func terrainReviewAndDedupSurviveRepeatedUpdatesAndHeightOffset() throws {
    let frame = UUID(), project = UUID(), cemetery = UUID(), batch = terrainBatch(frame:frame,raised:0.3)
    var first = try TerrainAnalysis.analyze([batch],projectID:project,cemeteryID:cemetery,frameID:frame)
    first.candidates[0].state = .rejected; first.candidates[0].reviewedAt = Date()
    let duplicate = try TerrainAnalysis.analyze([batch,batch],projectID:project,cemeteryID:cemetery,frameID:frame,previous:first)
    #expect(duplicate.candidates.count == 1)
    #expect(duplicate.candidates[0].id == first.candidates[0].id)
    #expect(duplicate.candidates[0].state == .rejected)
    let translated = try TerrainAnalysis.analyze([terrainBatch(frame:frame,raised:0.3,shift:4)],projectID:project,cemeteryID:cemetery,frameID:frame,previous:first)
    #expect(translated.candidates.count == 1)
    #expect(abs(translated.candidates[0].heightDifference-first.candidates[0].heightDifference) < 1e-8)
    #expect(translated.candidates[0].center == first.candidates[0].center)
    let restored = try JSONDecoder().decode(TerrainSurvey.self,from:JSONEncoder().encode(translated))
    #expect(restored.candidates[0].state == .rejected)
}

@Test func terrainInvalidCoordinatesAndIndependentARFramesAreRejected() {
    let frame = UUID()
    #expect(throws:TerrainSurveyError.frameMismatch) {
        try TerrainAnalysis.analyze([terrainBatch(frame:UUID())],projectID:UUID(),cemeteryID:UUID(),frameID:frame)
    }
    #expect(throws:TerrainSurveyError.invalidData) {
        try TerrainAnalysis.analyze([.init(frameID:frame,anchorID:UUID(),captureID:UUID(),points:[.init(x:.nan,z:0,height:0)])],projectID:UUID(),cemeteryID:UUID(),frameID:frame)
    }
}

@Test func aSplitVisibleSurfaceNeverReusesOneCandidateIDTwice() throws {
    let frame = UUID(),project = UUID(),cemetery = UUID()
    func batch(split:Bool) -> TerrainMeshBatch {
        var points = [TerrainPoint]()
        for x in 0..<32 {
            for z in 0..<32 {
                let raised = (10...18).contains(x) && (12...14).contains(z) && (!split || x != 14)
                points.append(.init(x:(Double(x)+0.5)*0.25,z:(Double(z)+0.5)*0.25,height:raised ? 0.3 : 0))
            }
        }
        return .init(frameID:frame,anchorID:UUID(),captureID:UUID(),points:points)
    }
    let original = try TerrainAnalysis.analyze([batch(split:false)],projectID:project,cemeteryID:cemetery,frameID:frame)
    #expect(original.candidates.count == 1)
    let split = try TerrainAnalysis.analyze([batch(split:true)],projectID:project,cemeteryID:cemetery,frameID:frame,previous:original)
    #expect(split.candidates.count == 2)
    #expect(Set(split.candidates.map(\.id)).count == 2)
    #expect(split.candidates.filter { $0.id == original.candidates[0].id }.count == 1)
}

@Test func terrainRotationAndSelectedHeightReferenceKeepActualAnomalies() throws {
    let frame = UUID(), project = UUID(), cemetery = UUID(), batch = terrainBatch(frame:frame,raised:0.3)
    let first = try TerrainAnalysis.analyze([batch],projectID:project,cemeteryID:cemetery,frameID:frame,referenceHeight:5)
    var rotated = batch
    rotated.points = batch.points.map { .init(x:-$0.z,z:$0.x,height:$0.height) }
    let result = try TerrainAnalysis.analyze([rotated],projectID:project,cemeteryID:cemetery,frameID:frame)
    #expect(result.candidates.count == 1)
    #expect(abs(result.candidates[0].center.x+first.candidates[0].center.y) < 1e-8)
    #expect(abs(result.candidates[0].center.y-first.candidates[0].center.x) < 1e-8)
    #expect(abs(result.candidates[0].lengthMeters-first.candidates[0].lengthMeters) < 1e-8)
    #expect(abs(first.cells[0].height+5) < 1e-8)
    let updated = try TerrainAnalysis.analyze([batch],projectID:project,cemeteryID:cemetery,frameID:frame,previous:first)
    #expect(updated.referenceHeight == 5)
    #expect(throws:TerrainSurveyError.frameMismatch) {
        try TerrainAnalysis.analyze([batch],projectID:project,cemeteryID:UUID(),frameID:frame,previous:first)
    }
}

private func control(frame: UUID, x: Double, z: Double, east: Double, north: Double, accuracy: Double? = 0.1) -> TerrainControlPoint {
    let factor = 6_378_137.0*Double.pi/180
    return .init(frameID:frame,local:.init(x:x,y:z),geographic:.init(longitude:33+east/(factor*cos(60*Double.pi/180)),latitude:60+north/factor),accuracyMeters:accuracy)
}

@Test func explicitControlRegistrationRotatesMetersAndReportsAccuracy() throws {
    let frame = UUID()
    let controls = [control(frame:frame,x:0,z:0,east:0,north:0),control(frame:frame,x:10,z:0,east:0,north:10),control(frame:frame,x:0,z:10,east:-10,north:0)]
    let registration = try TerrainRegistration.fit(frameID:frame,controls:controls)
    #expect(abs(registration.cosine) < 1e-8 && abs(registration.sine-1) < 1e-8)
    #expect(registration.rmsResidualMeters < 1e-7)
    #expect(registration.approvedAt == nil)
    #expect(registration.positionalUncertaintyMeters != nil)
    let point = try registration.coordinate(for:.init(x:4,y:3),frameID:frame)
    let expected = control(frame:frame,x:0,z:0,east:-3,north:4).geographic
    #expect(abs(point.longitude-expected.longitude) < 1e-10)
    #expect(abs(point.latitude-expected.latitude) < 1e-10)
    #expect(throws:TerrainSurveyError.frameMismatch) { try registration.coordinate(for:.init(x:0,y:0),frameID:UUID()) }
}

@Test func controlsRejectOutliersScaleDistortionAndShortBaseline() {
    let frame = UUID()
    #expect(throws:TerrainSurveyError.registrationResidual) {
        try TerrainRegistration.fit(frameID:frame,controls:[control(frame:frame,x:0,z:0,east:0,north:0),control(frame:frame,x:10,z:0,east:10,north:0),control(frame:frame,x:0,z:10,east:20,north:10)])
    }
    #expect(throws:TerrainSurveyError.registrationResidual) {
        try TerrainRegistration.fit(frameID:frame,controls:[control(frame:frame,x:0,z:0,east:0,north:0),control(frame:frame,x:10,z:0,east:20,north:0)])
    }
    #expect(throws:TerrainSurveyError.shortBaseline) {
        try TerrainRegistration.fit(frameID:frame,controls:[control(frame:frame,x:0,z:0,east:0,north:0),control(frame:frame,x:1,z:0,east:1,north:0)])
    }
}

@Test func twoUnknownAccuracyControlsWarnAndNeverAutoApprove() throws {
    let frame = UUID()
    let registration = try TerrainRegistration.fit(frameID:frame,controls:[control(frame:frame,x:0,z:0,east:0,north:0,accuracy:nil),control(frame:frame,x:10,z:0,east:10,north:0,accuracy:nil)])
    #expect(registration.approvedAt == nil)
    #expect(registration.positionalUncertaintyMeters == nil)
    #expect(registration.warnings.count >= 2)
}

@Test func persistedTerrainRejectsInvalidCanvasCoordinatesAndFrameProvenance() throws {
    let frame = UUID()
    var survey = try TerrainAnalysis.analyze([terrainBatch(frame:frame,raised:0.3)],projectID:UUID(),cemeteryID:UUID(),frameID:frame)
    try survey.validate()
    var invalid = survey; invalid.cells[0].column = Int.min
    #expect(throws:TerrainSurveyError.invalidData) { try invalid.validate() }
    invalid = survey; invalid.cells[0].height = .nan
    #expect(throws:TerrainSurveyError.invalidData) { try invalid.validate() }
    invalid = survey; invalid.candidates.append(invalid.candidates[0])
    #expect(throws:TerrainSurveyError.invalidData) { try invalid.validate() }
    invalid = survey; invalid.candidates[0].frameID = UUID()
    #expect(throws:TerrainSurveyError.frameMismatch) { try invalid.validate() }
    survey.candidates[0].lineVertices = [.init(x:0,y:0),.init(x:.infinity,y:1)]
    #expect(throws:TerrainSurveyError.invalidData) { try survey.validate() }
}
