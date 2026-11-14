import Foundation

/// Pure, time-stepped state of the rain easter egg. Water level is a fraction of
/// the screen height (0 = empty, 1 = covered). No AppKit; fully testable.
///
/// Timeline: rain + water rising over 270 s → full for 10 s → drain over 10 s → idle.
/// Trolling: clicks on Gooby bail a tiny amount; another 9-click streak fakes a stop
/// (rain off, water drains 3 s) and then the storm returns 1.25× faster.
/// Safety: draining always begins by 290 s, so a storm always ends within 300 s.
/// `stop()` (the fail-safe) ends everything immediately.
struct StormModel: Equatable {
    enum Phase: Equatable {
        case idle
        case rising
        case fakeOut(remaining: TimeInterval)
        case full(remaining: TimeInterval)
        case draining(ratePerSecond: Double)
    }

    static let riseDuration: TimeInterval = 270
    static let holdDuration: TimeInterval = 10
    static let drainDuration: TimeInterval = 10
    static let fakeOutDuration: TimeInterval = 3
    /// Fraction of the screen drained per second during a fake-out (3 s → 12%).
    static let fakeOutDrainRate: Double = 0.04
    static let fakeOutSpeedup: Double = 1.25
    /// Draining starts no later than this, so the storm ends by 300 s.
    static let hardCap: TimeInterval = 290
    /// Points removed per bail click.
    static let bailPoints: Double = 2
    /// Tolerance for floating-point drift when crossing thresholds.
    static let epsilon: Double = 1e-9

    private(set) var phase: Phase = .idle
    private(set) var level: Double = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var riseRate: Double = 1 / riseDuration
    private(set) var fakeOuts = 0
    let screenHeight: Double

    init(screenHeight: Double) {
        self.screenHeight = max(screenHeight, 1)
    }

    var isActive: Bool { phase != .idle }

    /// Rain falls while the water rises and while the screen is full.
    var isRaining: Bool {
        switch phase {
        case .rising, .full: return true
        case .idle, .fakeOut, .draining: return false
        }
    }

    mutating func start() {
        guard phase == .idle else { return }
        phase = .rising
        level = 0
        elapsed = 0
        riseRate = 1 / Self.riseDuration
        fakeOuts = 0
    }

    /// Fail-safe: everything ends immediately.
    mutating func stop() {
        phase = .idle
        level = 0
        elapsed = 0
        riseRate = 1 / Self.riseDuration
    }

    /// A click on Gooby while the water rises: removes a pathetic 2 pt.
    mutating func bail() {
        guard phase == .rising else { return }
        level = max(0, level - Self.bailPoints / screenHeight)
    }

    /// The "stop" streak during a storm: a lie.
    mutating func fakeOut() {
        guard phase == .rising else { return }
        phase = .fakeOut(remaining: Self.fakeOutDuration)
        fakeOuts += 1
    }

    mutating func tick(_ dt: TimeInterval) {
        guard dt > 0, phase != .idle else { return }
        elapsed += dt

        switch phase {
        case .idle:
            return
        case .rising:
            level = min(1, level + riseRate * dt)
            if level >= 1 - Self.epsilon {
                level = 1
                phase = .full(remaining: Self.holdDuration)
            }
        case .fakeOut(let remaining):
            level = max(0, level - Self.fakeOutDrainRate * dt)
            let left = remaining - dt
            if left <= Self.epsilon {
                phase = .rising
                riseRate *= Self.fakeOutSpeedup
            } else {
                phase = .fakeOut(remaining: left)
            }
        case .full(let remaining):
            let left = remaining - dt
            phase = left <= Self.epsilon ? .draining(ratePerSecond: level / Self.drainDuration) : .full(remaining: left)
        case .draining(let rate):
            level = max(0, level - rate * dt)
            if level <= Self.epsilon { stop() }
            return
        }

        // Safety cap: whatever is happening, start draining by 290 s.
        if elapsed >= Self.hardCap {
            phase = .draining(ratePerSecond: max(level, 0.0001) / Self.drainDuration)
        }
    }
}
