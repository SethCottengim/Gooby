import CoreGraphics
import Foundation

/// Pure rain simulation (no AppKit): drops fall from above the top edge and land
/// on the water surface, where they produce splashes. Coordinates are y-up
/// (0 = screen bottom), matching layer coordinates in the rain view.
struct DrizzleModel {
    struct Drop: Equatable {
        var x: CGFloat
        var y: CGFloat          // bottom (head) of the streak
        var speed: CGFloat      // pt/s, downward
        var length: CGFloat
        var opacity: Double
    }

    struct Splash: Equatable {
        var x: CGFloat
        var y: CGFloat
        var age: TimeInterval
    }

    /// Light but clearly visible drizzle.
    static let dropsPerSecond: Double = 75
    static let speedRange: ClosedRange<CGFloat> = 700...950
    static let lengthRange: ClosedRange<CGFloat> = 14...22
    static let opacityRange: ClosedRange<Double> = 0.55...0.75
    /// Slight wind: x drift per unit of fall.
    static let slant: CGFloat = 0.08
    static let splashLifetime: TimeInterval = 0.35
    static let maxDrops = 240

    private(set) var drops: [Drop] = []
    private(set) var splashes: [Splash] = []
    private var spawnDebt: Double = 0
    private var rng: SeededGenerator

    init(seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) {
        rng = SeededGenerator(seed: seed)
    }

    /// Flat-surface convenience.
    mutating func step(_ dt: TimeInterval, width: CGFloat, height: CGFloat, floorY: CGFloat, raining: Bool) {
        step(dt, width: width, height: height, floor: { _ in floorY }, raining: raining)
    }

    /// Advances the rain. New drops spawn only while `raining`; drops already in
    /// the air keep falling and land on `floor(x)` (the possibly tilted water surface).
    mutating func step(_ dt: TimeInterval, width: CGFloat, height: CGFloat, floor: (CGFloat) -> CGFloat, raining: Bool) {
        guard dt > 0, width > 0, height > 0 else { return }

        // Age splashes.
        splashes = splashes.compactMap { s in
            var s = s
            s.age += dt
            return s.age < Self.splashLifetime ? s : nil
        }

        // Move drops; land them on the surface.
        var kept: [Drop] = []
        kept.reserveCapacity(drops.count)
        for var d in drops {
            let fall = d.speed * CGFloat(dt)
            d.y -= fall
            d.x -= fall * Self.slant
            let surface = floor(d.x)
            if d.y <= surface {
                if d.x >= 0 && d.x <= width { splashes.append(Splash(x: d.x, y: surface, age: 0)) }
            } else {
                kept.append(d)
            }
        }
        drops = kept

        // Spawn new drops above the top edge.
        guard raining else { spawnDebt = 0; return }
        spawnDebt += Self.dropsPerSecond * dt
        while spawnDebt >= 1, drops.count < Self.maxDrops {
            spawnDebt -= 1
            let length = CGFloat.random(in: Self.lengthRange, using: &rng)
            drops.append(Drop(
                x: CGFloat.random(in: 0...(width * 1.08), using: &rng),   // extra to the right for the slant
                y: height + CGFloat.random(in: 0...60, using: &rng) + length,
                speed: CGFloat.random(in: Self.speedRange, using: &rng),
                length: length,
                opacity: Double.random(in: Self.opacityRange, using: &rng)
            ))
        }
        if drops.count >= Self.maxDrops { spawnDebt = 0 }
    }

    mutating func clear() {
        drops.removeAll()
        splashes.removeAll()
        spawnDebt = 0
    }
}

/// Small deterministic generator so tests are repeatable (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
