import Foundation

/// Device-fitted bounds for dynamic speculative drafting. The loopback server
/// adapts the actual draft length per verification round (--spec-draft-dynamic);
/// these values only set the ceiling and drafter floor appropriate for the
/// hardware, so small phones never over-commit while Macs get full headroom.
enum SpeculativeAutoTune {
    static var deviceDraftCap: Int {
        var cap: Int
        #if os(macOS)
        cap = 8
        #else
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if ramGB >= 7.5 {
            cap = 6
        } else if ramGB >= 5.5 {
            cap = 4
        } else {
            cap = 3
        }
        #endif
        let thermal = ProcessInfo.processInfo.thermalState
        if ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious {
            cap = min(cap, 2)
        }
        if thermal == .critical {
            cap = 1
        }
        return cap
    }

    // Auto-tuned MTP only drafts when the leading token has at least 70%
    // probability across the full vocabulary.
    static let pMin = 0.7
}
