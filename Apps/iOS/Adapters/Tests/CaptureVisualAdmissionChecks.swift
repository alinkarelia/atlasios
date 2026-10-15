import Foundation

private enum CheckError: Error { case failed }
@MainActor
private final class Barrier {
    var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}

@main
struct CaptureVisualAdmissionChecks {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let bytes = Data("accepted-original-checkpoint".utf8)
        var passed = 0
        // Force the actual production persist→admission→render boundary to
        // resume after invalidation; test observable scene and durable bytes.
        for transition in ["remove", "pause", "reset", "background", "interruption", "relocalizing"] {
            var admission = CaptureVisualAdmission(); let anchor = UUID()
            admission.activate(); admission.observe(anchorID:anchor)
            let ticket = admission.issue(anchorID:anchor)!
            let barrier = Barrier(); var entities = Set<UUID>()
            let path = root.appendingPathComponent(transition)
            let task = Task { @MainActor in
                try await CaptureVisualCommit.persist(write:{
                    await barrier.wait(); try bytes.write(to:path,options:.atomic)
                },canPresent:{admission.admits(ticket)},present:{entities.insert(anchor)})
            }
            while !barrier.started { await Task.yield() }
            if transition == "remove" { admission.remove(anchorID:anchor) }
            else if transition == "reset" { admission.reset() }
            else { admission.suspend() }
            // A new normal frame cannot reopen a previous epoch's completion.
            admission.activate(); barrier.release(); try await task.value
            precondition(entities.isEmpty, "Late overlay reappeared after \(transition)")
            let retained = try Data(contentsOf:path)
            precondition(retained == bytes, "Accepted original was lost")
            passed += 1
        }
        do {
            var admission = CaptureVisualAdmission(); let id = UUID()
            admission.activate(); admission.observe(anchorID:id); let old = admission.issue(anchorID:id)!
            admission.remove(anchorID:id); admission.observe(anchorID:id); let current = admission.issue(anchorID:id)!
            var visible: CaptureVisualAdmission.Ticket?
            try await CaptureVisualCommit.persist(write:{},canPresent:{admission.admits(current)},present:{visible=current})
            try await CaptureVisualCommit.persist(write:{},canPresent:{admission.admits(old)},present:{visible=old})
            precondition(visible == current, "Old completion replaced a current anchor revision")
            passed += 1
        }
        do {
            var admission = CaptureVisualAdmission(); let id = UUID()
            admission.activate(); admission.observe(anchorID:id); let ticket = admission.issue(anchorID:id)!
            var shown = false
            do {
                try await CaptureVisualCommit.persist(write:{throw CheckError.failed},canPresent:{admission.admits(ticket)},present:{shown=true})
                preconditionFailure("Failed persistence unexpectedly succeeded")
            } catch CheckError.failed { }
            precondition(!shown, "Uncommitted geometry was displayed")
            passed += 1
        }
        do {
            var admission = CaptureVisualAdmission(); let id=UUID()
            admission.activate(); admission.observe(anchorID:id); let ticket=admission.issue(anchorID:id)!
            var shown=false; let file=root.appendingPathComponent("valid")
            try await CaptureVisualCommit.persist(write:{try bytes.write(to:file)},canPresent:{admission.admits(ticket)},present:{shown=true})
            let retained = try Data(contentsOf:file)
            precondition(shown && retained == bytes, "Valid LiDAR overlay or original disabled")
            passed += 1
        }
        print("Capture visual commit boundary: \(passed) scenarios passed; no device camera claim")
    }
}
