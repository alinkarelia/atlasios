import Foundation
import Testing
@testable import AtlasCore

private func fencePosts(frame: UUID, anchor: UUID = UUID(), shift: Double = 0, angle: Double = 0,
                        classification: FenceSurfaceClassification = .unknown, positions: [Double]? = nil) -> [FenceTriangle] {
    func point(_ x: Double, _ height: Double) -> TerrainPoint {
        .init(x:(x+shift)*cos(angle),z:(x+shift)*sin(angle),height:height)
    }
    return (positions ?? (0...10).map { Double($0)*0.4 }).flatMap { x in
        let a = point(x-0.03,0), b = point(x+0.03,0), c = point(x+0.03,0.8), d = point(x-0.03,0.8)
        return [FenceTriangle(frameID:frame,anchorID:anchor,a:a,b:b,c:c,classification:classification),
                FenceTriangle(frameID:frame,anchorID:anchor,a:a,b:c,c:d,classification:classification)]
    }
}

private func solidWall(frame: UUID, height: Double = 1) -> [FenceTriangle] {
    let anchor = UUID(), rows = Int(ceil(height/0.5))
    return (0..<10).flatMap { column in (0..<rows).flatMap { row in
        let x = Double(column)*0.4, h = Double(row)*0.5
        let a = TerrainPoint(x:x,z:0,height:h), b = TerrainPoint(x:x+0.4,z:0,height:h)
        let c = TerrainPoint(x:x+0.4,z:0,height:min(height,h+0.5)), d = TerrainPoint(x:x,z:0,height:min(height,h+0.5))
        return [FenceTriangle(frameID:frame,anchorID:anchor,a:a,b:b,c:c),FenceTriangle(frameID:frame,anchorID:anchor,a:a,b:c,c:d)]
    }}
}

@Test func sparseVerticalPostsProduceAnOpenMetricInspectionLineWithUnknownAccuracy() throws {
    let frame = UUID(), anchor = UUID()
    let result = try FenceDetection.proposals(from:fencePosts(frame:frame,anchor:anchor),frameID:frame)
    let proposal = try #require(result.first)
    #expect(result.count == 1 && proposal.line.frameID == frame && proposal.line.vertices.count == 2)
    #expect(abs(try PolygonGeometry.length(of:proposal.line)-4.06) < 1e-8)
    #expect(proposal.heightSpanMeters == 0.8)
    #expect(proposal.sourceAnchorIDs == [anchor])
    #expect(proposal.observedSurfaceArea > 0 && proposal.observedSurfaceArea < 1)
    #expect(proposal.evidence.contains("оператор"))
}

@Test func fenceDetectorRejectsKnownWallsSolidPanelsFloorsTallStructuresAndIsolatedBlocks() throws {
    let frame = UUID()
    #expect(try FenceDetection.proposals(from:fencePosts(frame:frame,classification:.wall),frameID:frame).isEmpty)
    #expect(try FenceDetection.proposals(from:fencePosts(frame:frame,classification:.other),frameID:frame).isEmpty)
    #expect(try FenceDetection.proposals(from:solidWall(frame:frame),frameID:frame).isEmpty)
    #expect(try FenceDetection.proposals(from:solidWall(frame:frame,height:3),frameID:frame).isEmpty)
    let floor = FenceTriangle(frameID:frame,anchorID:UUID(),a:.init(x:0,z:0,height:0),b:.init(x:1,z:0,height:0),c:.init(x:0,z:1,height:0))
    #expect(try FenceDetection.proposals(from:[floor],frameID:frame).isEmpty)
    #expect(try FenceDetection.proposals(from:fencePosts(frame:frame,positions:[0,0.1,0.2,0.3]),frameID:frame).isEmpty)
}

@Test func fenceDetectorKeepsUnobservedGapSeparateAndHandlesRotatedObservedSurfaces() throws {
    let frame = UUID()
    let first: [Double] = (0...5).map { Double($0)*0.4 }
    let second: [Double] = (0...5).map { 6.0+Double($0)*0.4 }
    let positions = first+second
    let split = try FenceDetection.proposals(from:fencePosts(frame:frame,positions:positions),frameID:frame)
    #expect(split.count == 2)
    #expect(split.allSatisfy { (try? PolygonGeometry.length(of:$0.line)) ?? 10 < 2.1 })
    let rotated = try FenceDetection.proposals(from:fencePosts(frame:frame,angle:.pi/4),frameID:frame)
    let line = try #require(rotated.first?.line)
    #expect(abs(try PolygonGeometry.length(of:line)-4.06) < 1e-8)
}

@Test func duplicateTrianglesDoNotInflateCoverageAndInputOrderKeepsProposalIdentity() throws {
    let frame = UUID(), input = fencePosts(frame:frame)
    let first = try FenceDetection.proposals(from:input,frameID:frame)
    let repeated = try FenceDetection.proposals(from:input+input.reversed(),frameID:frame)
    #expect(first.count == 1 && repeated.count == 1)
    #expect(first[0].id == repeated[0].id && first[0].line == repeated[0].line)
    #expect(abs(first[0].observedSurfaceArea-repeated[0].observedSurfaceArea) < 1e-12)
}

@Test func corruptLargeOrForeignFrameTrianglesCannotEnterFenceAnalysis() throws {
    let frame = UUID(), triangles = fencePosts(frame:frame)
    #expect(throws:FenceDetectionError.frameMismatch) { try FenceDetection.proposals(from:triangles,frameID:UUID()) }
    var malformed = triangles[0]; malformed.a.x = .nan
    #expect(throws:FenceDetectionError.invalidData) { try FenceDetection.proposals(from:[malformed],frameID:frame) }
    #expect(throws:FenceDetectionError.invalidData) {
        try FenceDetection.proposals(from:Array(repeating:triangles[0],count:20_001),frameID:frame)
    }
}

@Test func redetectionDoesNotRestoreRejectedFenceOrRewriteConfirmedFeatureGeometry() throws {
    let frame = UUID()
    let proposals = try FenceDetection.proposals(from:fencePosts(frame:frame),frameID:frame)
    var terrain = TerrainSurvey(projectID:UUID(),cemeteryID:UUID(),frameID:frame,sourceCaptureIDs:[],cells:[],candidates:[])
    terrain = try terrain.includingFenceProposals(proposals)
    #expect(terrain.candidates.count == 1 && terrain.candidates[0].state == .proposed)
    #expect(terrain.candidates[0].boundary.isEmpty && terrain.candidates[0].confirmedCategory == nil)
    #expect(terrain.candidates[0].verticalUncertaintyMeters == nil && terrain.cells.isEmpty)
    let original = terrain.candidates[0]
    let shifted = try FenceDetection.proposals(from:fencePosts(frame:frame,shift:0.2),frameID:frame)
    terrain.candidates[0].state = .rejected
    let rejected = try terrain.includingFenceProposals(shifted)
    #expect(rejected.candidates.count == 1 && rejected.candidates[0].state == .rejected)
    #expect(rejected.candidates[0].id == original.id && rejected.candidates[0].lineVertices == original.lineVertices)
    terrain.candidates[0].state = .confirmed; terrain.candidates[0].confirmedFeatureID = UUID(); terrain.candidates[0].confirmedCategory = .fence
    let confirmed = try terrain.includingFenceProposals(shifted)
    #expect(confirmed.candidates.count == 1 && confirmed.candidates[0].state == .confirmed)
    #expect(confirmed.candidates[0].confirmedFeatureID == terrain.candidates[0].confirmedFeatureID)
    #expect(confirmed.candidates[0].lineVertices == original.lineVertices)
}

@Test func proposedFenceRedetectionRetainsStableCandidateIDWhileUpdatingItsLocalLine() throws {
    let frame = UUID(), terrain = TerrainSurvey(projectID:UUID(),cemeteryID:UUID(),frameID:frame,sourceCaptureIDs:[],cells:[],candidates:[])
    let old = try terrain.includingFenceProposals(FenceDetection.proposals(from:fencePosts(frame:frame),frameID:frame))
    let new = try old.includingFenceProposals(FenceDetection.proposals(from:fencePosts(frame:frame,shift:0.2),frameID:frame))
    #expect(new.candidates.count == 1 && new.candidates[0].id == old.candidates[0].id)
    #expect(new.candidates[0].state == .proposed && new.candidates[0].lineVertices != old.candidates[0].lineVertices)
}
