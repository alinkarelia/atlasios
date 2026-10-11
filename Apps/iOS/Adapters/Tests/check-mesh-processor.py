#!/usr/bin/env python3
"""Compile and exercise the actual capture checkpoint processor, independently.

ARKit buffer reads remain Apple-SDK/device work. This harness extracts the
Sendable raw-byte processor itself, without duplicating its transform algorithm.
macOS uses Apple simd; Linux supplies only standard cross/norm vector primitives.
"""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "Apps/iOS/Adapters/CaptureCoordinator.swift"
source = SOURCE.read_text()
start = source.index("private struct MeshCheckpoint: Codable, Sendable")
end = source.index("/// Serial actor owns all disk operations.", start)
processor = source[start:end]
# Omit only the ARKit/Metal reader; run the production Data conversion actor.
start = processor.index("    @MainActor static func copy(")
end = processor.index("{", start) + 1
depth = 1
while depth:
    if processor[end] == "{":
        depth += 1
    elif processor[end] == "}":
        depth -= 1
    end += 1
processor = processor[:start] + processor[end:]
overlay_geometry = (ROOT / "Apps/iOS/Adapters/LiDAROverlayGeometry.swift").read_text()

if platform.system() == "Darwin":
    imports = "import Foundation\nimport simd\n"
    compiler = ["xcrun", "swiftc"]
else:
    # The Swift standard library supports SIMD vectors. These two elementary
    # primitives replace the unavailable Linux simd module; no checkpoint or
    # transform implementation is copied here.
    imports = """import Foundation
func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x)
}
func simd_length(_ v: SIMD3<Float>) -> Float { sqrt(v.x*v.x+v.y*v.y+v.z*v.z) }
"""
    executable = os.environ.get("ATLAS_SWIFTC") or shutil.which("swiftc")
    if not executable:
        raise SystemExit("Swift 6 compiler required; set ATLAS_SWIFTC to its path.")
    compiler = [executable]

TESTS = r'''

@main struct Checks {
    static func main() async {
        let processor = MeshCheckpointProcessor()
        let identity: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
        func vertexData(_ points: [[Float]], stride: Int) -> Data {
            var result = Data()
            for point in points {
                for value in point {
                    var bits = value.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
                }
                result.append(Data(repeating: 0xA5, count: stride-12))
            }
            return result
        }
        func faceData(_ values: [UInt32], width: Int) -> Data {
            var result = Data()
            for value in values {
                if width == 2 {
                    var encoded = UInt16(value).littleEndian
                    withUnsafeBytes(of: &encoded) { result.append(contentsOf: $0) }
                } else {
                    var encoded = value.littleEndian
                    withUnsafeBytes(of: &encoded) { result.append(contentsOf: $0) }
                }
            }
            return result
        }
        let anchorID = UUID(), segmentID = UUID(), timestamp = Date()
        func raw(points: [[Float]] = [[0,0,0],[1,0,0],[0,1,0]], stride: Int = 12,
                 faces: [UInt32] = [0,1,2], width: Int = 2, matrix: [Float]? = nil) -> MeshBufferSnapshot {
            MeshBufferSnapshot(anchorID: anchorID, segmentID: segmentID, updatedAt: timestamp,
                vertexCount: points.count, vertexStride: stride, vertices: vertexData(points,stride: stride),
                triangleCount: faces.count/3, bytesPerIndex: width, faces: faceData(faces,width: width),
                transform: matrix ?? identity)
        }
        var count = 0
        func expect(_ okay: Bool, _ title: String) {
            guard okay else { fatalError("Mesh processor regression: \(title)") }
            count += 1
        }
        for stride in [12,16,24] {
            for width in [2,4] {
                let result = await processor.process(raw(stride:stride,width:width))
                expect(result != nil,"valid strided/indexed mesh")
                guard let result else { return }
                expect(result.anchorID == anchorID && result.segmentID == segmentID && result.updatedAt == timestamp,
                       "checkpoint identity survives actor processing")
                expect(result.vertexCount == 3 && result.triangleCount == 1,"source counts")
                expect(abs(result.areaSquareMeters-0.5)<1e-7,"right triangle area")
                expect(result.positions == vertexData([[0,0,0],[1,0,0],[0,1,0]],stride:12),"canonical float32 positions")
                expect(result.indices == faceData([0,1,2],width:4),"canonical uint32 little-endian indices")
            }
        }
        let translated:[Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 3,4,5,1]
        let translation = await processor.process(raw(matrix:translated))
        expect(translation?.positions == vertexData([[3,4,5],[4,4,5],[3,5,5]],stride:12),"world translation, column-major transform")
        expect(translation?.areaSquareMeters == 0.5,"translation preserves area")
        let rotatedScaled:[Float] = [0,2,0,0, -3,0,0,0, 0,0,1,0, 3,4,5,1]
        let transformed = await processor.process(raw(matrix:rotatedScaled))
        expect(transformed?.positions == vertexData([[3,4,5],[3,6,5],[0,4,5]],stride:12),"rotation/scale/world transform")
        expect(transformed?.areaSquareMeters == 3,"non-uniform scale changes area")
        let square = await processor.process(raw(points:[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],faces:[0,1,2,0,2,3]))
        expect(square?.areaSquareMeters == 1 && square?.triangleCount == 2,"two-triangle square")
        let invalidIndex = await processor.process(raw(faces:[0,1,3]))
        expect(invalidIndex == nil,"reject out-of-range triangle index")
        let nonfinite = await processor.process(raw(points:[[Float.nan,0,0],[1,0,0],[0,1,0]]))
        expect(nonfinite == nil,"reject nonfinite vertex")
        let badMatrix = await processor.process(raw(matrix:[1,0,0]))
        expect(badMatrix == nil,"reject malformed matrix")
        var matrix = identity; matrix[12] = .infinity
        let invalidTransform = await processor.process(raw(matrix:matrix))
        expect(invalidTransform == nil,"reject nonfinite matrix")
        let short = MeshBufferSnapshot(anchorID:anchorID,segmentID:segmentID,updatedAt:timestamp,
            vertexCount:3,vertexStride:12,vertices:Data(repeating:0,count:35),triangleCount:1,bytesPerIndex:2,
            faces:faceData([0,1,2],width:2),transform:identity)
        let truncated = await processor.process(short)
        expect(truncated == nil,"reject truncated vertex bytes without unsafe read")
        // Colors are attached to original face IDs, not sampled triangle order.
        // The compact render mesh is a derivative; checkpoints retain source.
        let small = await processor.process(raw(points:[[0,0,0],[0.2,0,0],[0.2,0.2,0],[0,0.2,0]], faces:[0,1,2,0,2,3]))!
        let colored = await processor.surfaceOverlay(small, classifications:Data([2,3]), floorCode:2, ceilingCode:3)
        expect(colored.triangleCount == 2 && colored.groups.count == 2,"semantic floor and ceiling are separate overlay groups")
        expect(colored.groups[0].classification == .floor && colored.groups[1].classification == .ceiling,"classification uses original source face")
        expect(colored.groups.allSatisfy({ $0.positions.count == 3 && $0.indices == [0,1,2] }),"each overlay group compacts whole triplets")
        expect(colored.groups[1].positions == [SIMD3<Float>(0,0,0),SIMD3<Float>(0.2,0.2,0),SIMD3<Float>(0,0.2,0)],"ceiling winding and vertices preserved")
        expect(abs(colored.center.x - 0.1) < 1e-7 && abs(colored.center.y - 0.1) < 1e-7,"overlay camera-distance center")
        let unclassified = await processor.surfaceOverlay(small, classifications:nil, floorCode:2, ceilingCode:3)
        expect(unclassified.groups.count == 1 && unclassified.groups[0].classification == .other,"unclassified real mesh still visible")
        let large = await processor.process(raw())!
        let filtered = await processor.surfaceOverlay(large, classifications:Data([3]), floorCode:2, ceilingCode:3)
        expect(filtered.triangleCount == 0 && large.triangleCount == 1 && large.areaSquareMeters == 0.5,"visual outliers never change stored geometry")
        var labeled = raw(); labeled.classifications = Data([3])
        let semanticCheckpoint = await processor.process(labeled)!
        expect(semanticCheckpoint.classifications == Data([3]),"source semantic classification remains in durable checkpoint")
        let restored = try! JSONDecoder().decode(MeshCheckpoint.self, from:JSONEncoder().encode(semanticCheckpoint))
        expect(restored.classifications == Data([3]),"semantic checkpoint survives actual Codable round trip")
        var oldObject = try! JSONSerialization.jsonObject(with:JSONEncoder().encode(semanticCheckpoint)) as! [String:Any]
        oldObject.removeValue(forKey:"classifications")
        let legacy = try! JSONDecoder().decode(MeshCheckpoint.self, from:JSONSerialization.data(withJSONObject:oldObject))
        expect(legacy.classifications == nil && legacy.positions == semanticCheckpoint.positions,"legacy checkpoints without labels still decode unchanged")
        print("Mesh processor regression: \(count) checks passed")
    }
}

'''
with tempfile.TemporaryDirectory(prefix="atlas-mesh-check-") as directory:
    root = Path(directory)
    harness = root / "MeshProcessorChecks.swift"
    executable = root / "mesh-check"
    harness.write_text(imports + overlay_geometry + processor + TESTS)
    subprocess.run(compiler + ["-swift-version", "6", "-strict-concurrency=complete",
        "-parse-as-library", str(harness), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
