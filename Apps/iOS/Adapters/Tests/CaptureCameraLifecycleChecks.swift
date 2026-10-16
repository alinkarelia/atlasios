import Foundation

@main
struct CaptureCameraLifecycleChecks {
    static func main() {
        var lifecycle = CaptureCameraLifecycle()
        let segment = UUID(), nextSegment = UUID()
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }

        let preview = lifecycle.begin(.preview, at: 100)
        expect(lifecycle.acceptsCallback(runID: preview), "Current preview delegates are admitted")
        expect(!lifecycle.acceptsAnchors(runID: preview), "Cached anchors cannot draw before a fresh camera frame")
        expect(!lifecycle.acceptFrame(runID: preview, timestamp: 99.99, now: 100.01), "A recent frame from before reset is stale")
        expect(!lifecycle.acceptFrame(runID: preview, timestamp: 100.5, now: 100.1), "Future timestamps cannot revive a camera")
        expect(!lifecycle.acceptFrame(runID: preview, timestamp: .nan, now: 100.1), "Nonfinite camera time is rejected")
        expect(lifecycle.acceptFrame(runID: preview, timestamp: 100.05, now: 100.1), "Fresh current-run frame unlocks preview")
        expect(lifecycle.acceptsAnchors(runID: preview), "Fresh preview can show detected plane guidance")
        expect(!lifecycle.acceptsRecordedSurface(runID: preview, segmentID: segment), "Preview never paints committed mesh")
        expect(!lifecycle.acceptFrame(runID: preview, timestamp: 100.05, now: 100.2), "Duplicated callbacks do not count as new camera frames")
        expect(!lifecycle.acceptFrame(runID: preview, timestamp: 100.04, now: 100.2), "Out-of-order callbacks are rejected")

        let recording = lifecycle.begin(.recording(segmentID: segment), at: 101)
        expect(!lifecycle.acceptsCallback(runID: preview), "A queued preview delegate cannot enter recording")
        expect(!lifecycle.acceptsRecordedSurface(runID: recording, segmentID: segment), "Recording also waits for its own camera frame")
        expect(!lifecycle.acceptsEvidenceFrame(runID: recording, segmentID: segment, timestamp: 101.05, now: 101.1), "Fast photo tap before first accepted frame cannot reuse a cached image")
        expect(!lifecycle.acceptFrame(runID: preview, timestamp: 101.1, now: 101.2), "An old delegate cannot authorize a new run")
        expect(lifecycle.acceptFrame(runID: recording, timestamp: 101.1, now: 101.2), "Real recording frame is admitted")
        expect(lifecycle.acceptsRecordedSurface(runID: recording, segmentID: segment), "Current segment disk commit may paint")
        expect(!lifecycle.acceptsRecordedSurface(runID: recording, segmentID: nextSegment), "Other AR origins cannot paint this segment")
        expect(lifecycle.acceptsEvidenceFrame(runID: recording, segmentID: segment, timestamp: 101.1, now: 101.2), "Current-run camera image can be copied without advancing the frame delegate clock")
        expect(lifecycle.acceptsEvidenceFrame(runID: recording, segmentID: segment, timestamp: 101.15, now: 101.2), "New currentFrame may arrive before its delegate callback")
        expect(!lifecycle.acceptsEvidenceFrame(runID: recording, segmentID: segment, timestamp: 100.95, now: 101.2), "Photo cannot use previous preview frame")
        expect(!lifecycle.acceptsEvidenceFrame(runID: recording, segmentID: segment, timestamp: 101.05, now: 101.2), "Photo cannot go backward from the latest admitted frame")
        expect(!lifecycle.acceptsEvidenceFrame(runID: recording, segmentID: nextSegment, timestamp: 101.15, now: 101.2), "Photo frameID cannot be borrowed from another segment")
        expect(!lifecycle.acceptsEvidenceFrame(runID: recording, segmentID: segment, timestamp: 101.15, now: 103), "Frozen currentFrame cannot become new evidence")
        expect(!lifecycle.acceptsEvidenceFrame(runID: recording, segmentID: segment, timestamp: .infinity, now: 101.2), "Nonfinite photo time fails closed")

        let anchor = UUID()
        let removedPermit = lifecycle.beginSurface(runID: recording, segmentID: segment, anchorID: anchor)!
        expect(lifecycle.acceptsSurface(runID: recording, segmentID: segment, anchorID: anchor, permit: removedPermit), "In-flight current anchor may paint after disk commit")
        expect(lifecycle.beginSurface(runID: recording, segmentID: segment, anchorID: anchor) == nil, "One anchor cannot have two outstanding render permits")
        lifecycle.removeAnchor(anchor)
        expect(!lifecycle.acceptsSurface(runID: recording, segmentID: segment, anchorID: anchor, permit: removedPermit), "AR removal blocks the same-run late disk commit")
        let newPermit = lifecycle.beginSurface(runID: recording, segmentID: segment, anchorID: anchor)!
        expect(newPermit != removedPermit, "A legitimate later update gets a new identity")
        expect(!lifecycle.acceptsSurface(runID: recording, segmentID: segment, anchorID: anchor, permit: removedPermit), "Old work cannot borrow the re-added anchor's admission")
        lifecycle.finishSurface(anchorID: anchor, permit: removedPermit)
        expect(lifecycle.acceptsSurface(runID: recording, segmentID: segment, anchorID: anchor, permit: newPermit), "Old completion cannot revoke new same-ID work")
        lifecycle.finishSurface(anchorID: anchor, permit: newPermit)
        expect(!lifecycle.acceptsSurface(runID: recording, segmentID: segment, anchorID: anchor, permit: newPermit), "Completed permit is not retained")
        var pending: [(UUID, UUID)] = []
        for _ in 0..<CaptureCameraLifecycle.maximumPendingSurfaces {
            let id = UUID()
            pending.append((id, lifecycle.beginSurface(runID: recording, segmentID: segment, anchorID: id)!))
        }
        expect(lifecycle.beginSurface(runID: recording, segmentID: segment, anchorID: UUID()) == nil, "Outstanding surface admission is bounded independently of source history")
        for (id, permit) in pending { lifecycle.finishSurface(anchorID: id, permit: permit) }
        var churnAccepted = true
        for _ in 0..<1_024 {
            let id = UUID()
            guard let permit = lifecycle.beginSurface(runID: recording, segmentID: segment, anchorID: id) else {
                churnAccepted = false; break
            }
            lifecycle.removeAnchor(id)
            lifecycle.finishSurface(anchorID: id, permit: permit)
        }
        expect(churnAccepted, "Removed-anchor history does not accumulate tombstones or exhaust permits")

        let stoppedAnchor = UUID()
        let stoppedPermit = lifecycle.beginSurface(runID: recording, segmentID: segment, anchorID: stoppedAnchor)!

        // These all end presentation without cancelling source disk work. The
        // same token check is made after writer.persist returns in production.
        for reason in ["pause", "finish", "background", "dismiss", "interruption", "failure"] {
            lifecycle.stop()
            expect(!lifecycle.acceptsRecordedSurface(runID: recording, segmentID: segment), "Late disk completion after \(reason) cannot paint")
            expect(!lifecycle.acceptsSurface(runID: recording, segmentID: segment, anchorID: stoppedAnchor, permit: stoppedPermit), "Stopped render permit after \(reason) is revoked")
            expect(!lifecycle.acceptsCallback(runID: recording), "Late AR callbacks after \(reason) cannot mutate UI")
            expect(!lifecycle.acceptsEvidenceFrame(runID: recording, segmentID: segment, timestamp: 101.15, now: 101.2), "Queued photo action after \(reason) cannot capture stale session image")
        }

        let resumed = lifecycle.begin(.recording(segmentID: segment), at: 105)
        expect(lifecycle.acceptFrame(runID: resumed, timestamp: 105.1, now: 105.2), "Same-origin resume receives a fresh frame")
        expect(!lifecycle.acceptsRecordedSurface(runID: recording, segmentID: segment), "Old commit cannot paint even after same-origin resume")
        expect(!lifecycle.acceptsEvidenceFrame(runID: recording, segmentID: segment, timestamp: 105.1, now: 105.2), "Queued photo action cannot silently move into resumed recording")
        expect(lifecycle.acceptsRecordedSurface(runID: resumed, segmentID: segment), "New same-origin commit may paint")
        expect(!lifecycle.acceptsSurface(runID: resumed, segmentID: segment, anchorID: stoppedAnchor, permit: stoppedPermit), "Stopped anchor permit cannot survive a same-origin resume")
        let nextPreview = lifecycle.begin(.preview, at: 106)
        expect(lifecycle.acceptFrame(runID: nextPreview, timestamp: 106.1, now: 106.2), "Next screen preview starts independently")
        expect(!lifecycle.acceptsRecordedSurface(runID: resumed, segmentID: segment), "Old segment never paints reopened preview")
        expect(!lifecycle.acceptsRecordedSurface(runID: nextPreview, segmentID: segment), "New preview itself has no coverage fill")
        expect(lifecycle.beginSurface(runID: nextPreview, segmentID: segment, anchorID: anchor) == nil, "Preview cannot issue surface permits")
        expect(!lifecycle.acceptFrame(runID: nextPreview, timestamp: 106.2, now: 108), "Delayed camera callbacks cannot pass watchdog freshness")
        let invalid = lifecycle.begin(.preview, at: .infinity)
        expect(!lifecycle.acceptsCallback(runID: invalid), "Invalid reset time fails closed")
        print("Capture camera lifecycle checks passed: \(checks) (run identity, fresh frames, preview isolation, late callback/commit rejection across pause, finish, background, dismissal and interruption).")
    }
}
