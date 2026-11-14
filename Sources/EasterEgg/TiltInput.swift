import Foundation

/// Turns accelerometer samples into on-screen gravity for the fluid (pure, testable).
///
/// - Roll (one side of the laptop lower) rotates gravity on screen, so water pours
///   toward the lower side — up to fully sideways at 90°.
/// - Sudden moves (shakes, bumps) add a short extra kick, throwing the water around.
/// Direction confirmed live on 2026-11-11: positive roll = right side lower.
struct TiltInput: Equatable {
    /// Gravity strength on screen (pt/s²); tuned for a lively but readable slosh.
    static let gravityStrength: Float = 2600
    /// Extra acceleration per g of sudden movement (pt/s² per g).
    static let shakeStrength: Float = 9000
    /// Low-pass for gravity at 100 Hz samples (~0.07 s time constant).
    static let filter: Double = 0.15
    /// Ignore sensor noise (≈ 0.01 g).
    static let deadZone: Double = 0.03

    private(set) var gravity: AccelSample?
    private(set) var jolt = AccelSample(x: 0, y: 0, z: 0)

    static func roll(of g: AccelSample) -> Double {
        atan2(g.x, (g.y * g.y + g.z * g.z).squareRoot())
    }

    mutating func ingest(_ sample: AccelSample) {
        guard let g = gravity else { gravity = sample; return }
        let a = Self.filter
        let filtered = AccelSample(x: g.x + a * (sample.x - g.x), y: g.y + a * (sample.y - g.y), z: g.z + a * (sample.z - g.z))
        gravity = filtered
        func dz(_ v: Double) -> Double { abs(v) < Self.deadZone ? 0 : v }
        jolt = AccelSample(x: dz(sample.x - filtered.x), y: dz(sample.y - filtered.y), z: dz(sample.z - filtered.z))
    }

    /// Gravity for the fluid in screen axes (x right, y up), pt/s². Level, no
    /// sensor, or no samples yet: straight down.
    var screenGravity: SIMD2<Float> {
        guard let g = gravity else { return SIMD2(0, -Self.gravityStrength) }
        let roll = Self.roll(of: g)
        let down = SIMD2<Float>(Float(sin(roll)), Float(-cos(roll))) * Self.gravityStrength
        let kick = SIMD2<Float>(Float(jolt.x), Float(jolt.z)) * Self.shakeStrength
        return down + kick
    }
}
