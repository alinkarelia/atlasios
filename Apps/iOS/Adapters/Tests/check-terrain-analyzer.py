#!/usr/bin/env python3
"""Exercise production mesh-to-terrain sampling with independent byte fixtures.

Only Apple file-protection/AR presentation are omitted. The actual sampler,
checkpoint shape, core point type and errors are extracted, not reimplemented.
"""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
native = (ROOT / "Apps/iOS/Adapters/CemeteryTerrainAnalyzer.swift").read_text()
core = (ROOT / "Packages/AtlasCore/Sources/AtlasCore/TerrainSurvey.swift").read_text()
fence = (ROOT / "Packages/AtlasCore/Sources/AtlasCore/FenceDetection.swift").read_text()

def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    cursor, depth = opening + 1, 1
    while depth:
        if source[cursor] == "{": depth += 1
        elif source[cursor] == "}": depth -= 1
        cursor += 1
    return source[start:cursor]

point = declaration(core,"public struct TerrainPoint:")
errors = declaration(core,"public enum TerrainSurveyError:")
checkpoint = declaration(native,"private struct Checkpoint:").replace("private struct", "struct", 1)
sampler = declaration(native,"private func surfaceSamples(").replace("private func", "func", 1)
vertical = declaration(native,"private func verticalSamples(").replace("private func", "func", 1)
spatial = declaration(native,"private func spatialSamples(").replace("private func", "func", 1)
fence_class = declaration(fence,"public enum FenceSurfaceClassification:")
fence_input = declaration(fence,"public struct FenceTriangle:")

tests = r'''
@main struct Checks {
    static func main() async throws {
        let reader = Reader()
        func positions(_ points: [[Float]]) -> Data {
            var result = Data()
            for point in points {
                for value in point {
                    var bits = value.bitPattern.littleEndian
                    withUnsafeBytes(of:&bits) { result.append(contentsOf:$0) }
                }
            }
            return result
        }
        func indices(_ values:[UInt32]) -> Data {
            var result = Data()
            for value in values {
                var bits = value.littleEndian
                withUnsafeBytes(of:&bits) { result.append(contentsOf:$0) }
            }
            return result
        }
        func mesh(_ points:[[Float]] = [[0,2,0],[0.2,2,0],[0,2,0.2]],face:[UInt32] = [0,1,2],classification:UInt8? = nil) -> Reader.Checkpoint {
            .init(anchorID:UUID(),segmentID:UUID(),vertexCount:points.count,triangleCount:1,positions:positions(points),indices:indices(face),classifications:classification.map { Data([$0]) })
        }
        var count = 0
        func expect(_ condition:Bool,_ title:String) {
            guard condition else { fatalError("Terrain sampler: \(title)") }; count += 1
        }
        let flat = try await reader.surfaceSamples(mesh(classification:2))
        expect(flat.count == 4,"floor emits measured vertices and triangle centroid")
        expect(flat.allSatisfy { $0.height == 2 },"AR Y is height, not horizontal north")
        expect(abs(flat[1].x-0.2)<1e-7 && flat[1].z == 0,"AR X preserved")
        expect(abs(flat[2].z-0.2)<1e-7 && flat[2].x == 0,"AR Z preserved")
        expect(abs(flat[3].x-(0.2/3))<1e-7 && abs(flat[3].z-(0.2/3))<1e-7,"centroid from actual source triangle")
        let unknown = try await reader.surfaceSamples(mesh())
        expect(unknown.count == 4,"unclassified horizontal ground can be reviewed")
        for code:UInt8 in [1,3,4,5,6,7] {
            let ignored = try await reader.surfaceSamples(mesh(classification:code))
            expect(ignored.isEmpty,"wall/ceiling/furniture labels are not ground/grave labels")
        }
        let wall = try await reader.surfaceSamples(mesh([[0,0,0],[0,0.2,0],[0,0,0.2]],classification:2))
        expect(wall.isEmpty,"normal rejects vertical face even with floor label")
        let long = try await reader.surfaceSamples(mesh([[0,0,0],[3,0,0],[0,0,3]]))
        expect(long.isEmpty,"long edges cannot fabricate observed terrain spans")
        let degenerate = try await reader.surfaceSamples(mesh([[0,0,0],[0,0,0],[0,0,0]]))
        expect(degenerate.isEmpty,"zero-area geometry contributes no cells")
        do { _ = try await reader.surfaceSamples(mesh(face:[0,1,3])); fatalError("out-of-range index accepted") }
        catch TerrainSurveyError.invalidData { count += 1 }
        do { _ = try await reader.surfaceSamples(mesh([[Float.nan,0,0],[0.2,0,0],[0,0,0.2]])); fatalError("nonfinite point accepted") }
        catch TerrainSurveyError.invalidData { count += 1 }
        let frame = UUID()
        let standing = mesh([[0,0,0],[0.4,0,0],[0,0.8,0]])
        let fence = try await reader.verticalSamples(standing,frameID:frame,faceBudget:100)
        expect(fence.count == 1,"real vertical triple reaches review detector")
        expect(fence[0].frameID == frame && fence[0].anchorID == standing.anchorID,"source frame and anchor are retained")
        expect(fence[0].a.height == 0 && abs(fence[0].c.height-0.8)<1e-7,"vertical source heights are retained")
        expect(fence[0].classification == .unknown,"unknown means unknown, not confirmed fence")
        let knownWall = try await reader.verticalSamples(mesh([[0,0,0],[0.4,0,0],[0,0.8,0]],classification:1),frameID:frame,faceBudget:100)
        expect(knownWall.count == 1 && knownWall[0].classification == .wall,"known wall label reaches detector exclusion intact")
        for code:UInt8 in [2,3,4,5,6,7] {
            let ignored = try await reader.verticalSamples(mesh([[0,0,0],[0.4,0,0],[0,0.8,0]],classification:code),frameID:frame,faceBudget:100)
            expect(ignored.isEmpty,"floor/ceiling/furniture is not fence input")
        }
        let horizontal = try await reader.verticalSamples(mesh(),frameID:frame,faceBudget:100)
        expect(horizontal.isEmpty,"horizontal ground cannot turn into a vertical fence")
        let longVertical = try await reader.verticalSamples(mesh([[0,0,0],[0,3,0],[0.5,0,0]]),frameID:frame,faceBudget:100)
        expect(longVertical.isEmpty,"long vertical triangle cannot fabricate a structure")
        do { _ = try await reader.verticalSamples(mesh([[0,0,0],[0.4,0,0],[0,0.8,0]],face:[0,1,3]),frameID:frame,faceBudget:100); fatalError("vertical bad index accepted") }
        catch TerrainSurveyError.invalidData { count += 1 }
        var repeated = standing; repeated.triangleCount = 1_000; repeated.indices = indices(Array(repeating:[UInt32(0),1,2],count:1_000).flatMap{$0})
        let bounded = try await reader.verticalSamples(repeated,frameID:frame,faceBudget:17)
        expect(bounded.count <= 17,"whole-survey allocation can bound per-anchor vertical samples")
        let boundedGround = try await reader.surfaceSamples({ var item = mesh(); item.triangleCount = repeated.triangleCount; item.indices = repeated.indices; return item }(),faceBudget:17)
        expect(boundedGround.count <= 17*4,"whole-survey allocation can bound per-anchor ground samples")
        let canopy = try await reader.spatialSamples(mesh(),frameID:frame,faceBudget:17)
        expect(canopy.count == 1,"actual horizontal unknown canopy faces remain available to 3D shape review")
        expect(canopy[0].frameID == frame && canopy[0].classification == .unknown,"3D sampling retains local frame without plant semantic claims")
        let trunk = try await reader.spatialSamples(standing,frameID:frame,faceBudget:17)
        expect(trunk.count == 1,"vertical observed stem faces remain available beside canopy geometry")
        let labelledWall = try await reader.spatialSamples(mesh(classification:1),frameID:frame,faceBudget:17)
        expect(labelledWall.count == 1 && labelledWall[0].classification == .wall,"native wall labels stay excluded by vegetation heuristic")
        for code:UInt8 in [2,3,4,5,6,7] {
            let ignored = try await reader.spatialSamples(mesh(classification:code),frameID:frame,faceBudget:17)
            expect(ignored.isEmpty,"known floor/ceiling/furniture never becomes plant input")
        }
        let boundedSpatial = try await reader.spatialSamples(repeated,frameID:frame,faceBudget:17)
        expect(boundedSpatial.count <= 17,"whole-survey spatial canopy allocation remains bounded")
        let largeSpatial = try await reader.spatialSamples(mesh([[0,0,0],[0,1.5,0],[0.5,0,0]]),frameID:frame,faceBudget:17)
        expect(largeSpatial.isEmpty,"long mesh spans do not fabricate tree crown surfaces")
        print("Terrain mesh sampler regression: \(count) checks passed")
    }
}
'''
compiler = ["xcrun", "swiftc"] if platform.system() == "Darwin" else [os.environ.get("ATLAS_SWIFTC") or shutil.which("swiftc") or "swiftc"]
with tempfile.TemporaryDirectory(prefix="terraview-terrain-sampler-") as directory:
    folder = Path(directory)
    source = folder / "TerrainSampler.swift"
    executable = folder / "check"
    source.write_text("import Foundation\n" + point + "\n" + errors + "\n" + fence_class + "\n" + fence_input + "\nactor Reader {\n" + checkpoint + "\n" + sampler + "\n" + vertical + "\n" + spatial + "\n}\n" + tests)
    subprocess.run(compiler + ["-swift-version","6","-strict-concurrency=complete","-parse-as-library",str(source),"-o",str(executable)],check=True)
    subprocess.run([str(executable)],check=True)
