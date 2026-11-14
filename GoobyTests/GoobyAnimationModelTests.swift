import XCTest
@testable import Gooby

/// Records every requested sleep. Returns instantly for the first `instantCalls`
/// requests, then parks until cancelled, so tests never wait on real blink timers.
final class RecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [TimeInterval] = []
    private let instantCalls: Int

    init(instantCalls: Int) { self.instantCalls = instantCalls }

    var durations: [TimeInterval] { lock.withLock { _durations } }

    var sleeper: GoobyAnimationModel.Sleeper {
        { [self] seconds in
            let count = lock.withLock { _durations.append(seconds); return _durations.count }
            if count > instantCalls {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
    }
}

@MainActor
final class GoobyAnimationModelTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Condition not met in time", file: file, line: line)
    }

    // MARK: Pure math

    func testBobOffsetAtKnownPhases() {
        let f = GoobyAnimationModel.bobOffset(elapsed:)
        XCTAssertEqual(f(0), 0, accuracy: 1e-9)
        XCTAssertEqual(f(0.8), 4, accuracy: 1e-9)
        XCTAssertEqual(f(1.6), 0, accuracy: 1e-9)
        XCTAssertEqual(f(2.4), -4, accuracy: 1e-9)
        XCTAssertEqual(f(3.2), 0, accuracy: 1e-9)
        XCTAssertEqual(f(4.0), 4, accuracy: 1e-9, "Periodic")
    }

    func testBobOffsetNeverExceedsAmplitude() {
        for i in 0...10_000 {
            let value = GoobyAnimationModel.bobOffset(elapsed: Double(i) * 0.00137)
            XCTAssertLessThanOrEqual(abs(value), 4 + 1e-9)
        }
    }

    func testBoundedIntervalClamps() {
        let b = GoobyAnimationModel.boundedInterval
        XCTAssertEqual(b(0), 4.8)
        XCTAssertEqual(b(4.8), 4.8)
        XCTAssertEqual(b(7.3), 7.3)
        XCTAssertEqual(b(9.6), 9.6)
        XCTAssertEqual(b(60), 9.6)
        XCTAssertEqual(b(.nan), 4.8)
        XCTAssertEqual(b(.infinity), 4.8)
    }

    func testDefaultIntervalSourceIsBoundedAndNonuniform() {
        let samples = (0..<500).map { _ in Double.random(in: GoobyVisualMetrics.blinkIntervalRange) }
        XCTAssertTrue(samples.allSatisfy { (4.8...9.6).contains($0) })
        XCTAssertGreaterThan(Set(samples).count, 1)
    }

    // MARK: State transitions

    func testBobIsZeroUnlessNormal() {
        let start = Date(timeIntervalSince1970: 1000)
        let model = GoobyAnimationModel(sleeper: RecordingSleeper(instantCalls: 0).sleeper, now: { start })
        XCTAssertEqual(model.bobOffset(at: start.addingTimeInterval(0.8)), 0)
        model.setMode(.normal)
        XCTAssertEqual(model.bobOffset(at: start.addingTimeInterval(0.8)), 4, accuracy: 1e-9)
        model.setMode(.reduced)
        XCTAssertEqual(model.bobOffset(at: start.addingTimeInterval(0.8)), 0)
        model.stop()
    }

    func testBlinkSequenceTiming() async {
        let rec = RecordingSleeper(instantCalls: 3)
        let model = GoobyAnimationModel(intervalSource: { 5.5 }, sleeper: rec.sleeper)
        model.setMode(.normal)
        // interval, close+hold, open, then parks on the next interval.
        await waitUntil { rec.durations.count == 4 }
        let d = rec.durations
        XCTAssertEqual(d[0], 5.5)
        XCTAssertEqual(d[1], 0.090 + 0.050, accuracy: 1e-12)
        XCTAssertEqual(d[2], 0.140, accuracy: 1e-12)
        XCTAssertEqual(d[3], 5.5)
        XCTAssertEqual(model.eyeOpenness, 1, "Eyes reopen after a blink")
        model.stop()
    }

    func testFirstBlinkIntervalIsClampedToNinePointSix() async {
        let rec = RecordingSleeper(instantCalls: 0)
        let model = GoobyAnimationModel(intervalSource: { 42 }, sleeper: rec.sleeper)
        model.setMode(.normal)
        await waitUntil { rec.durations.count == 1 }
        XCTAssertEqual(rec.durations.first, 9.6)
        model.stop()
    }

    func testEyesCloseDuringBlink() async {
        // Park during the close+hold sleep so the closed state is observable.
        let rec = RecordingSleeper(instantCalls: 1)
        let model = GoobyAnimationModel(intervalSource: { 5 }, sleeper: rec.sleeper)
        model.setMode(.normal)
        await waitUntil { rec.durations.count == 2 }
        XCTAssertEqual(model.eyeOpenness, 0)
        model.stop()
    }

    func testReducedMotionMidBlinkCancelsAndOpensEyes() async {
        let rec = RecordingSleeper(instantCalls: 1)
        let model = GoobyAnimationModel(intervalSource: { 5 }, sleeper: rec.sleeper)
        model.setMode(.normal)
        await waitUntil { model.eyeOpenness == 0 }
        model.setMode(.reduced)
        XCTAssertEqual(model.eyeOpenness, 1)
        XCTAssertFalse(model.hasActiveBlinkTask)
        XCTAssertNil(model.motionStart)
        // Give the cancelled task time to unwind; it must not close the eyes again.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.eyeOpenness, 1)
        XCTAssertEqual(rec.durations.count, 2)
    }

    func testNoDuplicateBlinkScheduling() async {
        let rec = RecordingSleeper(instantCalls: 0)
        let model = GoobyAnimationModel(intervalSource: { 5 }, sleeper: rec.sleeper)
        model.setMode(.normal)
        model.setMode(.normal)
        XCTAssertEqual(model.blinkTaskGeneration, 1)
        await waitUntil { rec.durations.count == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(rec.durations.count, 1, "Only one scheduler is waiting")

        model.setMode(.reduced)
        model.setMode(.normal)
        XCTAssertEqual(model.blinkTaskGeneration, 2)
        XCTAssertTrue(model.hasActiveBlinkTask)
        await waitUntil { rec.durations.count == 2 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(rec.durations.count, 2, "Fresh interval only, no leftover scheduler")
        model.stop()
        XCTAssertFalse(model.hasActiveBlinkTask)
        XCTAssertNil(model.mode)
    }

    func testMotionPreferenceMapping() {
        XCTAssertEqual(MotionPreferenceAdapter.mode(reduceMotion: true), .reduced)
        XCTAssertEqual(MotionPreferenceAdapter.mode(reduceMotion: false), .normal)
    }
}
