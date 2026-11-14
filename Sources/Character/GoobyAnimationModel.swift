import Foundation
import SwiftUI

enum GoobyMotionMode: Equatable, Sendable {
    case normal
    case reduced
}

/// In-memory blink state and bounded blink scheduling (design §2.4).
/// Owns at most one blink task at a time.
@MainActor
final class GoobyAnimationModel: ObservableObject {
    typealias IntervalSource = () -> TimeInterval
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    /// 1 = fully open, 0 = fully closed.
    @Published private(set) var eyeOpenness: CGFloat = 1
    @Published private(set) var mode: GoobyMotionMode?
    /// Start of the current normal-motion bob cycle; nil while reduced or stopped.
    private(set) var motionStart: Date?

    private let intervalSource: IntervalSource
    private let sleeper: Sleeper
    private let now: () -> Date
    private var blinkTask: Task<Void, Never>?
    /// Increments every time a new blink task is created; used to detect duplicates.
    private(set) var blinkTaskGeneration = 0

    var hasActiveBlinkTask: Bool { blinkTask != nil }

    init(
        intervalSource: @escaping IntervalSource = {
            Double.random(in: GoobyVisualMetrics.blinkIntervalRange)
        },
        sleeper: @escaping Sleeper = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.intervalSource = intervalSource
        self.sleeper = sleeper
        self.now = now
    }

    // MARK: Pure calculations

    /// Clamps any sampled interval into the inclusive 4.8–9.6 s range.
    nonisolated static func boundedInterval(_ raw: TimeInterval) -> TimeInterval {
        let range = GoobyVisualMetrics.blinkIntervalRange
        guard raw.isFinite else { return range.lowerBound }
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    /// Smooth sine bob: 0 at t = 0, ±4 pt peaks, 3.2 s period.
    nonisolated static func bobOffset(elapsed: TimeInterval) -> CGFloat {
        let phase = (elapsed / GoobyVisualMetrics.bobPeriod) * 2 * .pi
        return GoobyVisualMetrics.bobAmplitude * CGFloat(sin(phase))
    }

    /// Current bob offset for a given render time; 0 unless in normal motion.
    func bobOffset(at date: Date) -> CGFloat {
        guard mode == .normal, let motionStart else { return 0 }
        return Self.bobOffset(elapsed: date.timeIntervalSince(motionStart))
    }

    // MARK: Mode transitions

    func setMode(_ newMode: GoobyMotionMode) {
        guard newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .normal:
            motionStart = now()
            startBlinkTask()
        case .reduced:
            cancelBlinkTask()
            motionStart = nil
            eyeOpenness = 1  // immediate, no animation
        }
    }

    /// Cancels all motion; used on termination.
    func stop() {
        cancelBlinkTask()
        motionStart = nil
        mode = nil
        eyeOpenness = 1
    }

    // MARK: Blink scheduling

    private func startBlinkTask() {
        cancelBlinkTask()
        blinkTaskGeneration += 1
        let generation = blinkTaskGeneration
        blinkTask = Task { [weak self] in
            await self?.runBlinkLoop(generation: generation)
        }
    }

    private func cancelBlinkTask() {
        blinkTask?.cancel()
        blinkTask = nil
    }

    private func runBlinkLoop(generation: Int) async {
        let m = GoobyVisualMetrics.self
        do {
            while !Task.isCancelled {
                try await sleeper(Self.boundedInterval(intervalSource()))
                guard isCurrent(generation) else { return }
                withAnimation(.easeIn(duration: m.blinkCloseDuration)) { eyeOpenness = 0 }
                try await sleeper(m.blinkCloseDuration + m.blinkHoldDuration)
                guard isCurrent(generation) else { return }
                withAnimation(.easeOut(duration: m.blinkOpenDuration)) { eyeOpenness = 1 }
                try await sleeper(m.blinkOpenDuration)
            }
        } catch {
            // Cancelled: the canceller is responsible for resetting eye state.
        }
        if isCurrent(generation) { blinkTask = nil }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && mode == .normal && generation == blinkTaskGeneration
    }
}
