#!/usr/bin/env python3
"""Compile the production live-overlay helper and run geometry regressions.

These cases exercise camera-crossing ceilings, disconnected outline pieces,
viewport edges and source-face preservation. They do not reproduce the clipper
or touch capture/export meshes. ARKit/RealityKit rendering needs Apple CI/device
verification separately.
"""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "Apps/iOS/Adapters/LiDAROverlayGeometry.swift"
if platform.system() == "Darwin":
    compiler = ["xcrun", "swiftc"]
else:
    swiftc = os.environ.get("ATLAS_SWIFTC") or shutil.which("swiftc")
    if not swiftc:
        raise SystemExit("Swift 6 compiler required; set ATLAS_SWIFTC to its path.")
    compiler = [swiftc]

TESTS = r'''
import Foundation

@main struct Checks {
    static func main() {
        typealias Geometry = LiDAROverlayGeometry
        var count = 0
        func expect(_ result: Bool, _ title: String) {
            guard result else { fatalError("LiDAR overlay regression: \(title)") }
            count += 1
        }
        func close(_ a: Float, _ b: Float, tolerance: Float = 0.00001) -> Bool { abs(a - b) <= tolerance }
        func contains(_ polygon: [SIMD3<Float>], _ point: SIMD3<Float>) -> Bool {
            polygon.contains { close($0.x, point.x) && close($0.y, point.y) && close($0.z, point.z) }
        }
        func screenArea(_ polygon: [SIMD2<Float>]) -> Float {
            guard polygon.count >= 3 else { return 0 }
            return polygon.indices.reduce(0) { value, index in
                let first = polygon[index], second = polygon[(index + 1) % polygon.count]
                return value + first.x * second.y - first.y * second.x
            } / 2
        }
        let center = SIMD3<Float>(2,3,4)
        let frontBias = Geometry.cameraFacingBias(from:center,toward:SIMD3(2,3,6))
        let backBias = Geometry.cameraFacingBias(from:center,toward:SIMD3(2,3,2))
        let sideBias = Geometry.cameraFacingBias(from:center,toward:SIMD3(4,3,4))
        expect(frontBias == SIMD3(0,0,0.003) && backBias == SIMD3(0,0,-0.003),
               "display bias reverses when the operator walks behind the object")
        expect(sideBias == SIMD3(0.003,0,0), "display bias follows the camera around the object's side")
        let diagonalBias = Geometry.cameraFacingBias(from:center,toward:SIMD3(5,7,4))
        let diagonalLength = sqrt(diagonalBias.x * diagonalBias.x + diagonalBias.y * diagonalBias.y + diagonalBias.z * diagonalBias.z)
        expect(close(diagonalLength,0.003,tolerance:0.00000001) && close(diagonalBias.x,0.0018,tolerance:0.00000001)
               && close(diagonalBias.y,0.0024,tolerance:0.00000001),
               "oblique camera direction keeps the same three-millimeter displacement")
        expect(Geometry.cameraFacingBias(from:center,toward:center) == .zero
               && Geometry.cameraFacingBias(from:.zero,toward:SIMD3(0.009,0,0)) == .zero,
               "coincident and sub-centimeter camera positions have no unstable bias")
        expect(Geometry.cameraFacingBias(from:.zero,toward:SIMD3(0.01,0,0)) == SIMD3(0.003,0,0),
               "a camera exactly one centimeter away remains a valid float32 direction")
        expect(Geometry.cameraFacingBias(from:center,toward:SIMD3(.nan,0,0)) == .zero
               && Geometry.cameraFacingBias(from:SIMD3(0,.infinity,0),toward:center) == .zero,
               "nonfinite geometry cannot enter display offset calculations")
        expect(Geometry.cameraFacingBias(from:center,toward:SIMD3(2,3,6),distance:-0.001) == .zero
               && Geometry.cameraFacingBias(from:center,toward:SIMD3(2,3,6),distance:0.011) == .zero
               && Geometry.cameraFacingBias(from:center,toward:SIMD3(2,3,6),distance:.nan) == .zero,
               "negative, oversized and nonfinite offset distances are rejected")
        expect(Geometry.cameraFacingBias(from:center,toward:SIMD3(2,3,6),distance:0) == .zero
               && Geometry.cameraFacingBias(from:center,toward:SIMD3(2,3,6),distance:0.01) == SIMD3(0,0,0.01),
               "allowed offset boundaries remain zero and exactly ten millimeters")
        let visible: [SIMD3<Float>] = [SIMD3(-1,-1,-1), SIMD3(1,-1,-1), SIMD3(1,1,-1), SIMD3(-1,1,-1)]
        expect(Geometry.clipCameraPolygon(visible) == visible, "a visible front-facing plane is unchanged")
        expect(Geometry.clipCameraPolygon(visible.map { SIMD3($0.x,$0.y,1) }).isEmpty,
               "a plane behind the camera is invisible")
        expect(Geometry.clipCameraPolygon(visible.map { SIMD3($0.x,$0.y,-0.05) }).isEmpty,
               "a plane between the camera and near plane is invisible")
        let crossing: [SIMD3<Float>] = [SIMD3(-1,-1,-1), SIMD3(1,-1,-1), SIMD3(1,1,1), SIMD3(-1,1,1)]
        let clipped = Geometry.clipCameraPolygon(crossing)
        expect(clipped.count == 4, "a camera-crossing ceiling is bounded before projection")
        expect(contains(clipped,SIMD3(-1,-0.12,-0.12)) && contains(clipped,SIMD3(1,-0.12,-0.12)),
               "near-plane intersections match known ceiling coordinates")
        expect(clipped.allSatisfy { $0.z <= -0.12 && $0.x.isFinite && $0.y.isFinite },
               "no behind-camera point survives camera clipping")
        let clippedXY = clipped.map { SIMD2($0.x,$0.y) }
        expect(close(screenArea(clippedXY), 1.76), "clipping preserves ceiling winding and area")
        let reversed = Geometry.clipCameraPolygon(Array(crossing.reversed()))
        expect(close(screenArea(reversed.map { SIMD2($0.x,$0.y) }), -1.76), "clockwise winding remains clockwise")
        expect(Geometry.clipCameraPolygon(crossing,near:0.5).allSatisfy { $0.z <= -0.5 },
               "configured near distance is respected")
        let touching: [SIMD3<Float>] = [SIMD3(0,0,-0.12), SIMD3(1,0,0.12), SIMD3(0,1,0.12)]
        expect(Geometry.clipCameraPolygon(touching).isEmpty, "a lone near-plane contact never produces a filled polygon")
        let crossingTriangle: [SIMD3<Float>] = [SIMD3(-1,0,-1),SIMD3(1,0,-1),SIMD3(0,1,1)]
        let triangleClip = Geometry.clipCameraPolygon(crossingTriangle)
        expect(triangleClip.count == 4 && contains(triangleClip,SIMD3(-0.56,0.44,-0.12))
               && contains(triangleClip,SIMD3(0.56,0.44,-0.12)),
               "a partly behind-camera triangle keeps both exact near-plane intersections")
        let repeatedCorner = [visible[0],visible[1],visible[1],visible[2],visible[3],visible[0]]
        expect(Geometry.clipCameraPolygon(repeatedCorner) == visible,
               "duplicate adjoining and closing vertices are removed before drawing")

        let concave: [SIMD3<Float>] = [SIMD3(-3,0,-2), SIMD3(-1,0,-2), SIMD3(-1,0,1), SIMD3(1,0,1),
                                      SIMD3(1,0,-2), SIMD3(3,0,-2), SIMD3(3,0,2), SIMD3(-3,0,2)]
        let segments = Geometry.clipCameraBoundary(concave)
        expect(segments.count == 6, "a concave boundary yields its six visible original edge pieces")
        expect(segments.allSatisfy { $0.0.z <= -0.12 && $0.1.z <= -0.12 },
               "all independent outline segments are in front of the near plane")
        expect(segments.allSatisfy { !close($0.0.z,-0.12) || !close($0.1.z,-0.12) },
               "no artificial near-plane connection is drawn between disconnected outline pieces")
        expect(Geometry.clipCameraBoundary(visible).count == 4, "a fully visible polygon preserves its four original edges")
        expect(Geometry.clipCameraBoundary(visible.map { SIMD3($0.x,$0.y,1) }).isEmpty,
               "all-behind-camera outlines produce no segments")
        var invalid = visible; invalid[1].x = .nan
        expect(Geometry.clipCameraPolygon(invalid).isEmpty && Geometry.clipCameraBoundary(invalid).isEmpty,
               "nonfinite camera coordinates are rejected")
        expect(Geometry.clipCameraPolygon(Array(repeating: SIMD3<Float>(0,0,-1), count:33)).isEmpty,
               "source plane boundaries are bounded to 32 vertices")
        expect(Geometry.clipCameraPolygon(visible,near:0).isEmpty && Geometry.clipCameraBoundary(visible,near:.infinity).isEmpty,
               "invalid near distances do not reach projection")

        let viewport = SIMD2<Float>(390,844)
        let oversized: [SIMD2<Float>] = [SIMD2(-100_000,-100_000),SIMD2(100_000,-100_000),
                                        SIMD2(100_000,100_000),SIMD2(-100_000,100_000)]
        let clippedScreen = Geometry.clipScreenPolygon(oversized,viewport:viewport)
        expect(clippedScreen.count == 4 && close(screenArea(clippedScreen),390 * 844,tolerance:0.05),
               "an enormous projected ceiling is clipped to the exact screen rectangle")
        expect(clippedScreen.allSatisfy { $0.x >= 0 && $0.x <= 390 && $0.y >= 0 && $0.y <= 844 },
               "every clipped polygon vertex is inside the viewport")
        expect(Geometry.clipScreenPolygon(Array(oversized.reversed()),viewport:viewport).count == 4,
               "clockwise polygon still clips to four corners")
        expect(screenArea(Geometry.clipScreenPolygon(Array(oversized.reversed()),viewport:viewport)) < 0,
               "screen clipping preserves winding")
        let offscreen: [SIMD2<Float>] = [SIMD2(-4,10),SIMD2(-2,20),SIMD2(-2,30)]
        expect(Geometry.clipScreenPolygon(offscreen,viewport:viewport).isEmpty,"an offscreen polygon has no visible fill")
        expect(Geometry.clipScreenPolygon([SIMD2(0,0),SIMD2(1,1),SIMD2(2,2)],viewport:viewport).isEmpty,
               "zero-area screen fills are suppressed")
        expect(Geometry.clipScreenPolygon([SIMD2(.infinity,0),SIMD2(1,1),SIMD2(2,0)],viewport:viewport).isEmpty,
               "nonfinite screen fill coordinates are rejected")
        expect(Geometry.clipScreenPolygon(oversized,viewport:SIMD2(0,844)).isEmpty,
               "zero-size viewports are rejected")
        expect(Geometry.clipScreenPolygon(oversized,viewport:SIMD2(.infinity,844)).isEmpty,
               "nonfinite viewport dimensions are rejected")
        let horizontal = Geometry.clipScreenLine(from:SIMD2(-100_000,422),to:SIMD2(100_000,422),viewport:viewport)
        expect(horizontal?.0 == SIMD2(0,422) && horizontal?.1 == SIMD2(390,422),
               "a giant horizontal ceiling edge is bounded to exact viewport endpoints")
        let vertical = Geometry.clipScreenLine(from:SIMD2(195,-100),to:SIMD2(195,1000),viewport:viewport)
        expect(vertical?.0 == SIMD2(195,0) && vertical?.1 == SIMD2(195,844),
               "vertical edges clip without dividing by a horizontal zero")
        let diagonal = Geometry.clipScreenLine(from:SIMD2(-10,-10),to:SIMD2(400,400),viewport:viewport)
        expect(diagonal?.0 == SIMD2(0,0) && diagonal?.1 == SIMD2(390,390),"diagonal clipping uses actual intersections")
        expect(Geometry.clipScreenLine(from:SIMD2(-1,0),to:SIMD2(-1,800),viewport:viewport) == nil,
               "parallel edges outside the viewport never draw")
        expect(Geometry.clipScreenLine(from:SIMD2(1,1),to:SIMD2(1,1),viewport:viewport) == nil,
               "zero-length lines never draw")
        expect(Geometry.clipScreenLine(from:SIMD2(.nan,1),to:SIMD2(1,1),viewport:viewport) == nil,
               "invalid projected lines never draw")
        let reverseHorizontal = Geometry.clipScreenLine(from:SIMD2(100_000,422),to:SIMD2(-100_000,422),viewport:viewport)
        expect(reverseHorizontal?.0 == SIMD2(390,422) && reverseHorizontal?.1 == SIMD2(0,422),
               "line clipping preserves traversal direction")
        let extreme = Geometry.clipScreenLine(from:SIMD2(-Float.greatestFiniteMagnitude,422),
                                             to:SIMD2(Float.greatestFiniteMagnitude,422),viewport:viewport)
        expect(extreme == nil || (extreme!.0.x >= 0 && extreme!.0.x <= 390 && extreme!.1.x >= 0 && extreme!.1.x <= 390
                                  && extreme!.0.y == 422 && extreme!.1.y == 422),
               "extreme finite projection values never escape the viewport or become NaN")

        let vertices: [SIMD3<Float>] = [SIMD3(0,0,0),SIMD3(0.3,0,0),SIMD3(0,0.4,0),SIMD3(0.6,0,0),
                                       SIMD3(2,0,0),SIMD3(.nan,0,0)]
        let faces: [UInt32] = [0,1,2, 0,0,1, 0,1,3, 0,1,4, 0,1,5, 0,1,99, 2,1,0]
        let filtered = Geometry.filteredTriangles(vertices:vertices,indices:faces)
        expect(filtered.count == 2, "repeated, collinear, long, nonfinite and invalid faces are visual outliers")
        expect(filtered.map(\.sourceFaceIndex) == [0,6], "accepted faces retain their original classification-buffer indices")
        expect(filtered.map(\.indices) == [SIMD3(0,1,2),SIMD3(2,1,0)],"whole original triplets and both windings are preserved")
        expect(Geometry.filteredTriangles(vertices:vertices,indices:[0,1,2,0]).isEmpty,
               "incomplete index triplets never become triangles")
        expect(Geometry.filteredTriangles(vertices:vertices,indices:[0,1,2],triangleBudget:0).isEmpty,
               "disabled overlay has no allocation work")
        expect(Geometry.filteredTriangles(vertices:vertices,indices:[0,1,2],maxEdgeLength:0.49).isEmpty,
               "longest edge is tested, including the diagonal")
        expect(Geometry.filteredTriangles(vertices:vertices,indices:[0,1,2],maxEdgeLength:0.5).count == 1,
               "a triangle exactly on the visual edge limit remains valid")
        let repeated: [UInt32] = Array(repeating:[UInt32(0),UInt32(1),UInt32(2)],count:128).flatMap { $0 }
        let sampled = Geometry.filteredTriangles(vertices:vertices,indices:repeated,triangleBudget:7)
        expect(sampled.count == 7 && sampled.first?.sourceFaceIndex == 0 && sampled.last?.sourceFaceIndex == 127,
               "sampling spans the full source mesh rather than favoring the first faces")
        expect(Set(sampled.map(\.sourceFaceIndex)).count == 7 && sampled.allSatisfy { $0.indices == SIMD3(0,1,2) },
               "face sampling cannot create mixed-index triangles")
        let manyFaces: [UInt32] = Array(repeating:[UInt32(0),UInt32(1),UInt32(2)],count:64_010).flatMap { $0 }
        let bounded = Geometry.filteredTriangles(vertices:vertices,indices:manyFaces,triangleBudget:Int.max)
        expect(bounded.count == 32_000 && bounded.last?.sourceFaceIndex == 64_009,
               "absolute visual triangle budget is enforced even for oversized caller requests")
        expect(Geometry.filteredTriangles(vertices:vertices,indices:[0,1,2],maxEdgeLength:.nan).isEmpty,
               "a nonfinite edge policy does not permit invalid overlays")
        print("LiDAR overlay regression: \(count) checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="terraview-lidar-overlay-") as directory:
    root = Path(directory)
    harness = root / "LiDAROverlayChecks.swift"
    executable = root / "lidar-overlay-check"
    harness.write_text(TESTS)
    subprocess.run(compiler + ["-swift-version", "6", "-strict-concurrency=complete",
        "-parse-as-library", str(SOURCE), str(harness), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
