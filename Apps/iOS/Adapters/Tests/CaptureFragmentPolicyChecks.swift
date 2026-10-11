import Foundation

@main
struct CaptureFragmentPolicyChecks {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        let roomy: Int64 = 10_000_000_000
        check(CaptureFragmentPolicy.durationThresholdSeconds == 600, "Exactly ten active minutes")
        check(CaptureFragmentPolicy.lowStorageThresholdBytes == 2_000_000_000, "Storage units are explicit decimal GB")
        check(CaptureFragmentPolicy.recommendation(activeSeconds: 599.999, availableDiskBytes: roomy) == nil, "No premature duration proposal")
        check(CaptureFragmentPolicy.recommendation(activeSeconds: 600, availableDiskBytes: roomy) == .duration, "Ten-minute boundary proposes saving")
        check(CaptureFragmentPolicy.recommendation(activeSeconds: 0, availableDiskBytes: 2_000_000_000) == nil, "Exactly2GB does not cross below threshold")
        check(CaptureFragmentPolicy.recommendation(activeSeconds: 0, availableDiskBytes: 1_999_999_999) == .lowStorage, "One byte below2GB proposes saving")
        check(CaptureFragmentPolicy.recommendation(activeSeconds: 600, availableDiskBytes: 1_999_999_999) == .lowStorage, "Low disk takes priority over duration")
        check(CaptureFragmentPolicy.recommendation(activeSeconds: 600, availableDiskBytes: -1) == .duration, "Unknown disk amount is not fabricated into low storage")
        check(CaptureFragmentPolicy.recommendation(activeSeconds: .nan, availableDiskBytes: roomy) == nil, "Invalid duration cannot create a timed proposal")
        check(CaptureFragmentPolicy.recommendation(activeSeconds: -.infinity, availableDiskBytes: 100) == .lowStorage, "Known low storage still has priority")
        check(CaptureFragmentPolicy.estimatedVideoBytes(activeSeconds: 600) == 450_000_000, "Ten minutes at average6Mbps estimate450MB of video")
        check(CaptureFragmentPolicy.estimatedVideoBytes(activeSeconds: 0) == 0, "No active time has no estimated video")
        for duration: Double in [-1, .nan, .infinity, .greatestFiniteMagnitude] {
            check(CaptureFragmentPolicy.estimatedVideoBytes(activeSeconds: duration) == nil, "Invalid or overflowing estimate is rejected")
        }
        var clock = CaptureFragmentActiveClock()
        clock.observe(arTimestamp: 100)
        check(clock.elapsedSeconds == 0, "First observed frame begins a monotonic interval")
        clock.observe(arTimestamp: 100.5); clock.observe(arTimestamp: 101)
        check(clock.elapsedSeconds == 1, "Frame cadence does not alter elapsed time")
        for timestamp: Double in [101, 100.9, .nan, .infinity, -1] { clock.observe(arTimestamp: timestamp) }
        check(clock.elapsedSeconds == 1, "Repeated, backward and invalid frames cannot add or reset duration")
        clock.observe(arTimestamp: 102)
        check(clock.elapsedSeconds == 2, "A valid frame follows corrupt input without timeline loss")
        clock.pause(); clock.observe(arTimestamp: 86_500)
        check(clock.elapsedSeconds == 2, "An overnight pause contributes no active time")
        clock.observe(arTimestamp: 86_501)
        check(clock.elapsedSeconds == 3, "Same-origin resumption retains previous active seconds")
        clock.reset(); clock.observe(arTimestamp: 86_502); clock.observe(arTimestamp: 87_102)
        check(clock.elapsedSeconds == 600 && clock.recommendation(availableDiskBytes: roomy) == .duration, "New origin begins an independent ten-minute clock")
        clock.deferRecommendation()
        check(clock.recommendation(availableDiskBytes: roomy) == nil && clock.recommendation(availableDiskBytes: 10) == nil,
              "Operator can postpone soft proposals while hard coordinator reserves remain independent")
        clock.observe(arTimestamp: 87_401.999)
        check(clock.recommendation(availableDiskBytes: roomy) == nil, "Default deferral lasts five active minutes")
        clock.pause(); clock.observe(arTimestamp: 200_000)
        check(clock.recommendation(availableDiskBytes: roomy) == nil, "Pause does not consume active-time deferral")
        clock.observe(arTimestamp: 200_000.0011)
        check(clock.recommendation(availableDiskBytes: roomy) == .duration, "Proposal returns at active deferral boundary")
        clock.deferRecommendation(for: .nan)
        check(clock.recommendation(availableDiskBytes: roomy) == .duration, "Corrupt deferral cannot hide a proposal indefinitely")
        clock.reset(); clock.observe(arTimestamp: 300_000)
        check(clock.elapsedSeconds == 0 && clock.recommendation(availableDiskBytes: roomy) == nil, "New fragment clears previous duration and deferral")
        check(clock.recommendation(availableDiskBytes: 1_999_999_999) == .lowStorage, "Fresh fragments still observe available storage")
        check(CaptureVideoDocument.targetVideoBitrateBitsPerSecond == 6_000_000 && CaptureVideoDocument.targetVideoFramesPerSecond == 15,
              "Estimate and native encoder share explicit video targets")
        print("Fragment proposal policy and active AR clock: \(count) boundaries, pause gaps, origin resets, resource priority, deferral and bitrate-estimate checks passed.")
    }
}
