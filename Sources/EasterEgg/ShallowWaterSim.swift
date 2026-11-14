import Foundation

/// Continuous water surface in the screen "bucket" (pure, testable; no AppKit).
///
/// Method: 1D shallow-water equations on a staggered grid. The screen is split into
/// columns; each column has a water height `h`, and each face between columns has a
/// flow velocity `u`. Height differences push water toward lower neighbours, so waves
/// travel, reflect off the screen edges, and slosh. Tilting the laptop adds sideways
/// gravity, so water runs downhill until the surface settles at the matching slope.
/// Mass is conserved exactly (flux form with a positivity limiter); `damping` controls
/// how quickly motion dies out — water settles, it does not bounce.
/// Units: points and seconds; x right, heights measured up from the screen bottom.
struct ShallowWaterSim {
    let width: Float
    let height: Float
    let cellWidth: Float
    let columns: Int

    /// Velocity decay per second (higher = calmer, settles faster).
    var damping: Float = 0.9
    /// Smooths the velocity field a little each substep (keeps the surface glassy).
    var velocitySmoothing: Float = 0.08
    /// Courant number for adaptive substeps (stability margin).
    static let courant: Float = 0.45
    static let maxSubsteps = 24

    private(set) var h: [Float]
    /// Face velocities: u[0] and u[columns] are the bucket walls (always 0).
    private(set) var u: [Float]
    private var flux: [Float]

    init(width: Float, height: Float, cellWidth: Float = 8) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.cellWidth = cellWidth
        columns = max(2, Int((self.width / cellWidth).rounded(.up)))
        h = Array(repeating: 0, count: columns)
        u = Array(repeating: 0, count: columns + 1)
        flux = Array(repeating: 0, count: columns + 1)
    }

    // MARK: Water amount

    /// Total water area on screen (pt²).
    var volume: Float { h.reduce(0, +) * cellWidth }

    /// Adds `area` pt² of water as a small rounded bump centred at `x` (a rain drop).
    mutating func addVolume(_ area: Float, atX x: Float, spread: Float = 16) {
        guard area > 0 else { return }
        let center = x / cellWidth - 0.5
        let reach = max(1, Int((spread / cellWidth).rounded(.up)))
        let c = Int(center.rounded())
        var weights: [(Int, Float)] = []
        var total: Float = 0
        for i in max(0, c - reach)...min(columns - 1, c + reach) {
            let d = (Float(i) - center) * cellWidth / spread
            let w = max(0, 1 - d * d)
            if w > 0 { weights.append((i, w)); total += w }
        }
        if total <= 0 { h[min(max(c, 0), columns - 1)] += area / cellWidth; return }
        for (i, w) in weights { h[i] += area * (w / total) / cellWidth }
    }

    /// Adds water spread evenly across the whole width.
    mutating func addVolumeEvenly(_ area: Float) {
        guard area > 0 else { return }
        let dh = area / (Float(columns) * cellWidth)
        for i in 0..<columns { h[i] += dh }
    }

    /// Removes `area` pt² of water, proportionally from every column (keeps the shape).
    mutating func removeVolume(_ area: Float) {
        let v = volume
        guard area > 0, v > 0 else { return }
        let keep = max(0, 1 - area / v)
        for i in 0..<columns { h[i] *= keep }
    }

    mutating func removeAll() {
        for i in 0..<columns { h[i] = 0 }
        for f in 0...columns { u[f] = 0 }
    }

    // MARK: Stepping

    /// Advances by `dt` seconds. `gravity` is in screen axes (pt/s², y up), e.g. a level
    /// laptop gives (0, -2600); rolling it right-side-down gives a positive x component.
    mutating func step(_ dt: TimeInterval, gravity: SIMD2<Float>) {
        guard dt > 0 else { return }
        let dt = Float(min(dt, 0.1))
        // Effective "down" strength inside the bucket; never let it vanish or flip.
        let gDown = max(-gravity.y, 300)
        let gSide = gravity.x
        let dx = cellWidth

        var maxH: Float = 0, maxU: Float = 0
        for v in h { maxH = max(maxH, v) }
        for v in u { maxU = max(maxU, abs(v)) }
        let speed = (gDown * maxH).squareRoot() + maxU + 1
        let sub = min(Self.maxSubsteps, max(1, Int((dt * speed / (Self.courant * dx)).rounded(.up))))
        let sdt = dt / Float(sub)
        let decay = exp(-damping * sdt)
        let n = columns

        for _ in 0..<sub {
            // Momentum: pressure from height differences plus sideways gravity.
            for f in 1..<n {
                let hl = h[f - 1], hr = h[f]
                if hl <= 1e-4 && hr <= 1e-4 { u[f] = 0; continue }
                u[f] = (u[f] + sdt * (-gDown * (hr - hl) / dx + gSide)) * decay
            }
            u[0] = 0; u[n] = 0
            // Light velocity smoothing (numerical viscosity) for a glassy surface.
            if velocitySmoothing > 0 {
                var prev = u[0]
                for f in 1..<n {
                    let cur = u[f]
                    u[f] = cur + velocitySmoothing * ((prev + u[f + 1]) * 0.5 - cur)
                    prev = cur
                }
            }
            // Upwind fluxes.
            for f in 1..<n {
                flux[f] = u[f] * (u[f] > 0 ? h[f - 1] : h[f])
            }
            flux[0] = 0; flux[n] = 0
            // Positivity: a column can't send out more water than it holds.
            for i in 0..<n {
                let out = (max(flux[i + 1], 0) + max(-flux[i], 0)) * sdt / dx
                if out > h[i] && out > 0 {
                    let s = h[i] / out
                    if flux[i + 1] > 0 { flux[i + 1] *= s }
                    if flux[i] < 0 { flux[i] *= s }
                }
            }
            for i in 0..<n {
                h[i] = max(0, h[i] - sdt / dx * (flux[i + 1] - flux[i]))
            }
        }
    }

    // MARK: Queries

    /// Surface height (pt above the screen bottom) at `x`, linearly interpolated
    /// between column centres and clipped to the screen.
    func surface(atX x: Float) -> Float {
        let f = x / cellWidth - 0.5
        let i = min(max(Int(f.rounded(.down)), 0), columns - 1)
        let j = min(i + 1, columns - 1)
        let t = min(max(f - Float(i), 0), 1)
        return min(height, h[i] + (h[j] - h[i]) * t)
    }

    var maxSurface: Float { min(height, h.max() ?? 0) }
}
