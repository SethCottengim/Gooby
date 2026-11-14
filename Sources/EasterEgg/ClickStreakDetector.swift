import Foundation

/// Detects "N clicks in a row": every click must come within `maxGap` seconds of
/// the previous one; a longer pause restarts the count.
struct ClickStreakDetector {
    static let requiredClicks = 9
    static let maxGap: TimeInterval = 0.6

    private(set) var count = 0
    private var lastClick: TimeInterval?

    /// Registers a click at `time` (seconds, monotonic). Returns true on the click
    /// that completes the streak; the count then resets.
    mutating func register(at time: TimeInterval) -> Bool {
        // Small tolerance so a gap of exactly 0.6 s still counts despite rounding.
        if let last = lastClick, time - last <= Self.maxGap + 1e-9, time >= last {
            count += 1
        } else {
            count = 1
        }
        lastClick = time
        if count >= Self.requiredClicks {
            reset()
            return true
        }
        return false
    }

    mutating func reset() {
        count = 0
        lastClick = nil
    }
}
