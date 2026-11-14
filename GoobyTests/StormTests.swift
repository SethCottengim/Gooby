import AppKit
import XCTest
@testable import Gooby

final class ClickStreakDetectorTests: XCTestCase {
    func testNineQuickClicksTrigger() {
        var d = ClickStreakDetector()
        for i in 0..<8 { XCTAssertFalse(d.register(at: Double(i) * 0.5)) }
        XCTAssertTrue(d.register(at: 8 * 0.5))
        XCTAssertEqual(d.count, 0, "Resets after triggering")
    }

    func testPauseLongerThanGapRestarts() {
        var d = ClickStreakDetector()
        for i in 0..<8 { _ = d.register(at: Double(i) * 0.3) }
        XCTAssertFalse(d.register(at: 7 * 0.3 + 0.61), "0.61 s gap breaks the streak")
        XCTAssertEqual(d.count, 1)
    }

    func testExactlyMaxGapStillCounts() {
        var d = ClickStreakDetector()
        var triggered = false
        for i in 0..<9 { triggered = d.register(at: Double(i) * 0.6) }
        XCTAssertTrue(triggered)
    }

    func testClockGoingBackwardsRestarts() {
        var d = ClickStreakDetector()
        _ = d.register(at: 10); _ = d.register(at: 10.2)
        _ = d.register(at: 5)
        XCTAssertEqual(d.count, 1)
    }
}

final class StormModelTests: XCTestCase {
    func run(_ m: inout StormModel, seconds: Double, step: Double = 0.1) {
        var t = 0.0
        while t < seconds - 1e-9 { m.tick(step); t += step }
    }

    func testFullTimelineRiseHoldDrain() {
        var m = StormModel(screenHeight: 982)
        XCTAssertFalse(m.isActive)
        m.start()
        XCTAssertTrue(m.isRaining)
        run(&m, seconds: 135)
        XCTAssertEqual(m.level, 0.5, accuracy: 0.001, "Half full at 2 min 15 s")
        run(&m, seconds: 135)
        XCTAssertEqual(m.level, 1, accuracy: 1e-9, "Full at 4 min 30 s")
        if case .full = m.phase {} else { XCTFail("Expected full, got \(m.phase)") }
        XCTAssertTrue(m.isRaining)
        run(&m, seconds: 10.05)
        if case .draining = m.phase {} else { XCTFail("Expected draining after 10 s hold, got \(m.phase)") }
        XCTAssertFalse(m.isRaining)
        run(&m, seconds: 10.2)
        XCTAssertFalse(m.isActive, "Ends after the 10 s drain")
        XCTAssertEqual(m.level, 0)
    }

    func testBailRemovesTwoPointsOnlyWhileRising() {
        var m = StormModel(screenHeight: 1000)
        m.start()
        run(&m, seconds: 27)                      // 10% full
        let before = m.level
        m.bail()
        XCTAssertEqual(before - m.level, 0.002, accuracy: 1e-9)
        var idle = StormModel(screenHeight: 1000)
        idle.bail()
        XCTAssertEqual(idle.level, 0)
    }

    func testFakeOutDrainsThenReturnsFaster() {
        var m = StormModel(screenHeight: 1000)
        m.start()
        run(&m, seconds: 54)                       // 20%
        m.fakeOut()
        XCTAssertFalse(m.isRaining, "Rain stops: looks like it worked")
        run(&m, seconds: 2.9)
        XCTAssertLessThan(m.level, 0.2)
        run(&m, seconds: 0.2)
        XCTAssertEqual(m.phase, .rising, "...then it comes back")
        XCTAssertTrue(m.isRaining)
        XCTAssertEqual(m.riseRate, 1.25 / 270, accuracy: 1e-12)
        XCTAssertEqual(m.fakeOuts, 1)
    }

    /// Endless bailing and fake-outs still can't keep the storm going past 300 s.
    func testHardCapAlwaysEndsWithinFiveMinutes() {
        var m = StormModel(screenHeight: 900)
        m.start()
        var t = 0.0
        while m.isActive && t < 400 {
            m.bail()
            if Int(t * 10) % 40 == 0 { m.fakeOut() }
            m.tick(0.1); t += 0.1
        }
        XCTAssertFalse(m.isActive)
        XCTAssertLessThanOrEqual(t, 300.01)
    }

    func testStopEndsImmediatelyFromAnyPhase() {
        var m = StormModel(screenHeight: 900)
        m.start(); run(&m, seconds: 100)
        m.stop()
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(m.level, 0)
        XCTAssertFalse(m.isRaining)
    }
}

@MainActor
final class StormControllerTests: XCTestCase {
    var now: TimeInterval = 1000

    func makeController() -> (StormController, GoobyWindowHost, TerminalFollower) {
        let host = GoobyWindowHost(visibleFrame: { nil }, onClose: {}, reduceMotion: { true })
        host.show()
        let follower = TerminalFollower(presenter: host, environment: .init(
            frontmost: { (nil, nil) }, windows: { [] },
            screens: { [CGRect(x: 0, y: 0, width: 1512, height: 944)] }, primaryScreenHeight: { 982 }))
        let storm = StormController(host: host, follower: follower, clock: { [unowned self] in self.now })
        return (storm, host, follower)
    }

    func clickNine(_ storm: StormController) {
        for _ in 0..<9 { storm.handleCharacterClick(); now += 0.3 }
    }

    func testNineClicksStartStormWithFailSafeArmed() throws {
        let (storm, host, _) = makeController()
        defer { storm.stop(); host.tearDown() }
        for _ in 0..<8 { storm.handleCharacterClick(); now += 0.3 }
        XCTAssertFalse(storm.isActive)
        storm.handleCharacterClick()
        XCTAssertTrue(storm.isActive)
        XCTAssertTrue(storm.isFailSafeArmed, "⌃⌥⌘ Esc registered")
        XCTAssertTrue(host.controls.stormActive)
        XCTAssertFalse(host.controls.showsCloseControl, "✕ hidden even while hovering")
        XCTAssertEqual(host.panel?.level, StormLevels.gooby)
        let rain = try XCTUnwrap(storm.rainPanel), water = try XCTUnwrap(storm.waterPanel)
        XCTAssertTrue(rain.ignoresMouseEvents, "Rain never blocks clicks")
        XCTAssertFalse(water.ignoresMouseEvents, "Water swallows clicks")
        XCTAssertFalse(rain.canBecomeKey); XCTAssertFalse(water.canBecomeKey)
        XCTAssertLessThan(water.level.rawValue, StormLevels.gooby.rawValue)
        XCTAssertLessThan(StormLevels.gooby.rawValue, rain.level.rawValue)
        XCTAssertGreaterThan(water.level.rawValue, NSWindow.Level.statusBar.rawValue, "Covers Dock and menu bar")
    }

    func testFailSafeHotKeyPathStopsEverythingImmediately() throws {
        let (storm, host, _) = makeController()
        defer { host.tearDown() }
        clickNine(storm)
        for _ in 0..<(60 * 20) { storm.advance(by: 1.0 / 60) }   // a pool has formed
        XCTAssertTrue(try XCTUnwrap(storm.waterPanel).isVisible)
        let water = try XCTUnwrap(storm.waterPanel), rain = try XCTUnwrap(storm.rainPanel)
        FailSafeHotKey.fireForTesting()           // same action the shortcut runs
        XCTAssertFalse(storm.isActive)
        XCTAssertFalse(water.isVisible); XCTAssertFalse(rain.isVisible)
        XCTAssertNil(storm.waterPanel); XCTAssertNil(storm.rainPanel)
        XCTAssertFalse(storm.isFailSafeArmed, "Shortcut released after the storm")
        XCTAssertFalse(host.controls.stormActive)
        XCTAssertEqual(host.panel?.level, .floating)
    }

    func testRainFillsBucketOnScheduleAndGoobyFloats() throws {
        let (storm, host, _) = makeController()
        defer { storm.stop(); host.tearDown() }
        clickNine(storm)
        for _ in 0..<(60 * 60) { storm.advance(by: 1.0 / 60) }      // 60 s of storm
        XCTAssertEqual(storm.visibleWaterArea / storm.targetWaterArea, 1, accuracy: 0.03, "Fills on schedule")
        let water = try XCTUnwrap(storm.waterPanel)
        XCTAssertTrue(water.isVisible)
        XCTAssertGreaterThan(storm.waterTopHeight, 20)
        XCTAssertLessThanOrEqual(water.frame.height, storm.waterTopHeight + 5,
                                 "Water window trimmed to the water: nothing above it can block clicks")
        let floated = try XCTUnwrap(storm.adjustGoobyOrigin(CGPoint(x: 400, y: 0)))
        XCTAssertGreaterThan(floated.y, 0, "Gooby lifted by the water")
        XCTAssertNotNil(storm.adjustGoobyOrigin(nil), "Gooby stays visible even without Terminal in front")
    }

    func testTiltingPoursWaterToTheLowerSide() throws {
        let (storm, host, _) = makeController()
        defer { storm.stop(); host.tearDown() }
        clickNine(storm)
        for _ in 0..<(60 * 40) { storm.advance(by: 1.0 / 60) }      // build a pool
        func rightShare() throws -> Float {
            let h = try XCTUnwrap(storm.water).h
            let half = h.count / 2
            return h[half...].reduce(0, +) / max(h.reduce(0, +), 1)
        }
        XCTAssertEqual(try rightShare(), 0.5, accuracy: 0.08, "Level: even")
        let r = 30.0 * .pi / 180                                      // right side 30° lower
        for _ in 0..<50 { storm.ingest(AccelSample(x: sin(r), y: 0, z: -cos(r))) }
        for _ in 0..<(60 * 4) { storm.advance(by: 1.0 / 60) }
        XCTAssertGreaterThan(try rightShare(), 0.7, "Water poured to the lower (right) side")
    }

    func testStormEndsOnItsOwn() {
        let (storm, host, _) = makeController()
        defer { host.tearDown() }
        clickNine(storm)
        for _ in 0..<620 { storm.advance(by: 0.5) }    // 310 s in coarse steps
        XCTAssertFalse(storm.isActive)
        XCTAssertNil(storm.waterPanel)
        XCTAssertFalse(storm.isFailSafeArmed)
    }

    func testClicksDuringStormBailAndFakeOut() {
        let (storm, host, _) = makeController()
        defer { storm.stop(); host.tearDown() }
        clickNine(storm)
        storm.advance(by: 60)
        let level = storm.model!.level
        now += 5
        storm.handleCharacterClick()
        XCTAssertLessThan(storm.model!.level, level, "A click bails a little")
        now += 5
        clickNine(storm)
        if case .fakeOut = storm.model!.phase {} else { XCTFail("9 clicks during the storm should fake out") }
    }
}

@MainActor
final class CloseControlHitTests: XCTestCase {
    func testCloseCornerExcludedFromCharacterClicks() {
        let b = CGRect(x: 0, y: 0, width: 112, height: 102)
        XCTAssertTrue(GoobyHostingView.isOnCloseControl(CGPoint(x: 105, y: 97), in: b, isFlipped: false, closeShown: true))
        XCTAssertFalse(GoobyHostingView.isOnCloseControl(CGPoint(x: 105, y: 97), in: b, isFlipped: false, closeShown: false))
        XCTAssertFalse(GoobyHostingView.isOnCloseControl(CGPoint(x: 56, y: 50), in: b, isFlipped: false, closeShown: true))
        XCTAssertTrue(GoobyHostingView.isOnCloseControl(CGPoint(x: 105, y: 5), in: b, isFlipped: true, closeShown: true))
    }
}

final class DrizzleModelTests: XCTestCase {
    func runRain(_ m: inout DrizzleModel, seconds: Double, floor: CGFloat = 0, raining: Bool = true) {
        var t = 0.0
        while t < seconds - 1e-9 { m.step(1.0 / 60, width: 1728, height: 1117, floorY: floor, raining: raining); t += 1.0 / 60 }
    }

    func testSteadyDrizzleIsVisibleButLight() {
        var m = DrizzleModel(seed: 42)
        runRain(&m, seconds: 4)
        // ~75 drops/s × ~1.4 s fall time ≈ 100 on screen: visible, not a downpour.
        XCTAssertGreaterThan(m.drops.count, 60)
        XCTAssertLessThan(m.drops.count, 160)
        XCTAssertTrue(m.drops.allSatisfy { DrizzleModel.opacityRange.contains($0.opacity) })
        XCTAssertGreaterThanOrEqual(DrizzleModel.opacityRange.lowerBound, 0.5, "Drops must be clearly visible")
    }

    func testDropsLandOnWaterSurfaceAndSplash() {
        var m = DrizzleModel(seed: 7)
        let surface: CGFloat = 400
        runRain(&m, seconds: 3, floor: surface)
        XCTAssertTrue(m.drops.allSatisfy { $0.y > surface }, "No drop falls into the water")
        XCTAssertFalse(m.splashes.isEmpty, "Landing drops splash on the surface")
        XCTAssertTrue(m.splashes.allSatisfy { $0.y == surface && $0.age < DrizzleModel.splashLifetime })
    }

    func testStoppingRainLetsAirborneDropsFinish() {
        var m = DrizzleModel(seed: 3)
        runRain(&m, seconds: 2)
        let airborne = m.drops.count
        XCTAssertGreaterThan(airborne, 0)
        m.step(1.0 / 60, width: 1728, height: 1117, floorY: 0, raining: false)
        XCTAssertGreaterThan(m.drops.count, 0, "Drops don't vanish mid-air")
        runRain(&m, seconds: 2.5, raining: false)
        XCTAssertTrue(m.drops.isEmpty, "Then the sky clears")
    }

    func testSameSeedIsDeterministic() {
        var a = DrizzleModel(seed: 99), b = DrizzleModel(seed: 99)
        runRain(&a, seconds: 1); runRain(&b, seconds: 1)
        XCTAssertEqual(a.drops, b.drops)
    }

    @MainActor
    func testWaterIsNinetyNinePercentOpaque() {
        XCTAssertEqual(WaterView.opacity, 0.99)
    }
}


final class AccelerometerDecodeTests: XCTestCase {
    /// A real report captured from this MacBook lying flat (Mac16,7, macOS 26.7.1).
    let flatReport: [UInt8] = [0x28, 0x41, 0, 0, 0, 0, 0x79, 0x02, 0, 0, 0x2d, 0xfd, 0xff, 0xff,
                               0x50, 0x02, 0xff, 0xff, 0x80, 0x94, 0x20, 0x00]

    func testDecodesRealFlatReport() throws {
        let s = try XCTUnwrap(AccelReportDecoder.decode(flatReport))
        XCTAssertEqual(s.x, 633.0 / 65536, accuracy: 1e-12)
        XCTAssertEqual(s.y, -723.0 / 65536, accuracy: 1e-12)
        XCTAssertEqual(s.z, -64944.0 / 65536, accuracy: 1e-12, "≈ -0.991 g: gravity straight down when flat")
        XCTAssertEqual(TiltInput.roll(of: s), 0, accuracy: 0.02, "Flat laptop ≈ level")
    }

    func testRejectsShortReports() {
        XCTAssertNil(AccelReportDecoder.decode(Array(flatReport.prefix(21))))
    }
}

final class TiltInputTests: XCTestCase {
    func tilted(_ degrees: Double) -> AccelSample {
        let r = degrees * .pi / 180
        return AccelSample(x: sin(r), y: 0, z: -cos(r))
    }

    func testLevelMeansStraightDown() {
        XCTAssertEqual(TiltInput().screenGravity, SIMD2(0, -TiltInput.gravityStrength), "No samples yet")
        var t = TiltInput()
        for _ in 0..<50 { t.ingest(tilted(0)) }
        XCTAssertEqual(t.screenGravity.x, 0, accuracy: 1)
        XCTAssertEqual(t.screenGravity.y, -TiltInput.gravityStrength, accuracy: 1)
    }

    func testRollRotatesGravityTowardLowerSide() {
        var t = TiltInput()
        for _ in 0..<200 { t.ingest(tilted(30)) }
        XCTAssertEqual(t.screenGravity.x, TiltInput.gravityStrength * 0.5, accuracy: 5, "sin 30° toward the right")
        var side = TiltInput()
        for _ in 0..<200 { side.ingest(tilted(-90)) }
        XCTAssertEqual(side.screenGravity.x, -TiltInput.gravityStrength, accuracy: 5, "On its side: fully sideways")
    }

    func testShakeKicksAndNoiseDoesNot() {
        var t = TiltInput()
        for i in 0..<100 { t.ingest(AccelSample(x: i % 2 == 0 ? 0.01 : -0.01, y: 0, z: -1)) }
        XCTAssertEqual(t.jolt, AccelSample(x: 0, y: 0, z: 0), "Sensor noise ignored")
        t.ingest(AccelSample(x: 0.8, y: 0, z: -1))
        XCTAssertGreaterThan(t.screenGravity.x, 3000, "A sharp shove throws the water")
    }
}

final class ShallowWaterSimTests: XCTestCase {
    let g: Float = 2600

    func testConservesWaterExactly() {
        var sim = ShallowWaterSim(width: 1728, height: 1117)
        sim.addVolumeEvenly(1728 * 1117 * 0.4)
        let v0 = sim.volume
        for i in 0..<600 { sim.step(1.0 / 60, gravity: SIMD2(i % 120 < 60 ? 2000 : -2000, -g)) }
        XCTAssertEqual(sim.volume / v0, 1, accuracy: 1e-4)
        XCTAssertTrue(sim.h.allSatisfy { $0 >= 0 && $0.isFinite }, "No negative or invalid heights")
    }

    func testSloshSettlesWithoutBouncing() {
        var sim = ShallowWaterSim(width: 1728, height: 1117)
        sim.addVolumeEvenly(1728 * 1117 * 0.4)
        for _ in 0..<12 { sim.step(1.0 / 60, gravity: SIMD2(9000, -g)) }     // a hard shove
        func roughness() -> Float {
            let m = sim.h.reduce(0, +) / Float(sim.h.count)
            return (sim.h.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(sim.h.count)).squareRoot()
        }
        let start = roughness()
        for _ in 0..<(60 * 6) { sim.step(1.0 / 60, gravity: SIMD2(0, -g)) }
        XCTAssertLessThan(roughness(), start * 0.1, "Calms down within ~6 s")
    }

    func testTiltSettlesAtTheMatchingSlope() {
        var sim = ShallowWaterSim(width: 1728, height: 1117)
        sim.addVolumeEvenly(1728 * 1117 * 0.4)
        let r: Float = 25 * .pi / 180
        for _ in 0..<(60 * 8) { sim.step(1.0 / 60, gravity: SIMD2(g * sin(r), -g * cos(r))) }
        let slope = (sim.surface(atX: 1728 * 0.75) - sim.surface(atX: 1728 * 0.25)) / (1728 * 0.5)
        XCTAssertEqual(slope, tan(r), accuracy: 0.03, "Surface stays level in the real world")
    }

    func testLittleWaterPoursIntoTheLowCorner() {
        var sim = ShallowWaterSim(width: 1728, height: 1117)
        sim.addVolumeEvenly(1728 * 1117 * 0.08)
        for _ in 0..<(60 * 6) { sim.step(1.0 / 60, gravity: SIMD2(g * sin(0.6), -g * cos(0.6))) }
        XCTAssertLessThan(sim.h.first!, 1, "High side runs dry")
        XCTAssertGreaterThan(sim.h.last!, 300)
    }

    func testAddAndRemoveAccounting() {
        var sim = ShallowWaterSim(width: 800, height: 600)
        sim.addVolume(1000, atX: 400)
        XCTAssertEqual(sim.volume, 1000, accuracy: 0.01)
        XCTAssertGreaterThan(sim.surface(atX: 400), sim.surface(atX: 100), "A local bump where the drop lands")
        sim.removeVolume(250)
        XCTAssertEqual(sim.volume, 750, accuracy: 0.01)
        sim.removeVolume(10_000)
        XCTAssertEqual(sim.volume, 0, accuracy: 0.01)
    }
}
