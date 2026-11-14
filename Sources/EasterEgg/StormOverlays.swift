import AppKit
import QuartzCore

/// Window levels during a storm, bottom to top: water, Gooby, rain. All sit above
/// the Dock and menu bar so the storm covers the whole screen.
enum StormLevels {
    static let water = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let gooby = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    static let rain = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
}

/// Borderless, transparent, never-key overlay panel.
final class StormOverlayPanel: NSPanel {
    init(frame: NSRect, level: NSWindow.Level, clickThrough: Bool) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = clickThrough
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the drizzle from `DrizzleModel`: blue-gray streaks (visible on light and
/// dark backgrounds) and small splash rings where drops hit the water surface.
/// The rain window is full-screen and click-through; drops stop at the waterline.
final class RainView: NSView {
    static let dropWidth: CGFloat = 1.6
    private(set) var model = DrizzleModel()
    private let dropsLayer = CAShapeLayer()
    private let splashLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        dropsLayer.fillColor = nil
        dropsLayer.strokeColor = CGColor(srgbRed: 0.42, green: 0.58, blue: 0.78, alpha: 0.7)
        dropsLayer.lineWidth = Self.dropWidth
        dropsLayer.lineCap = .round
        // A faint light edge keeps drops readable on dark backgrounds too.
        dropsLayer.shadowColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        dropsLayer.shadowOpacity = 0.35
        dropsLayer.shadowRadius = 0.8
        dropsLayer.shadowOffset = .zero
        splashLayer.fillColor = nil
        splashLayer.strokeColor = CGColor(srgbRed: 0.85, green: 0.93, blue: 1, alpha: 0.8)
        splashLayer.lineWidth = 1.1
        layer?.addSublayer(dropsLayer)
        layer?.addSublayer(splashLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    /// Advances and redraws the rain. `floor(x)` is the water surface in view coordinates (y-up).
    func step(_ dt: TimeInterval, floor: (CGFloat) -> CGFloat, raining: Bool) {
        model.step(dt, width: bounds.width, height: bounds.height, floor: floor, raining: raining)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropsLayer.frame = bounds
        splashLayer.frame = bounds
        let drops = CGMutablePath()
        for d in model.drops {
            let top = d.y + d.length
            let tailX = d.x + d.length * DrizzleModel.slant
            drops.move(to: CGPoint(x: tailX, y: max(top, floor(tailX))))
            drops.addLine(to: CGPoint(x: d.x, y: max(d.y, floor(d.x))))
        }
        dropsLayer.path = drops
        let splashes = CGMutablePath()
        for sp in model.splashes {
            let t = CGFloat(sp.age / DrizzleModel.splashLifetime)        // 0 → 1
            let w = 3 + 9 * t, h = 1 + 2 * t
            splashes.addEllipse(in: CGRect(x: sp.x - w / 2, y: sp.y - h / 2 + 1, width: w, height: h))
        }
        splashLayer.path = splashes
        CATransaction.commit()
    }

    func clear() {
        model.clear()
        dropsLayer.path = nil
        splashLayer.path = nil
    }
}

/// Draws the water as one smooth vector shape: a 99% opaque vertical gradient (deep
/// at the bottom, lighter toward the surface) clipped to the surface curve, plus a
/// light line along the surface. Above the surface the window is fully transparent,
/// and the window itself is trimmed to the highest point of the water.
final class WaterView: NSView {
    static let opacity: CGFloat = 0.99
    private let fill = CAGradientLayer()
    private let shape = CAShapeLayer()
    private let surfaceLine = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.colors = [CGColor(srgbRed: 0.09, green: 0.23, blue: 0.44, alpha: Self.opacity),
                       CGColor(srgbRed: 0.2, green: 0.44, blue: 0.69, alpha: Self.opacity)]
        fill.startPoint = CGPoint(x: 0.5, y: 0)   // y-up: bottom → top
        fill.endPoint = CGPoint(x: 0.5, y: 1)
        fill.mask = shape
        layer?.addSublayer(fill)
        surfaceLine.fillColor = nil
        surfaceLine.strokeColor = CGColor(srgbRed: 0.62, green: 0.82, blue: 0.97, alpha: 0.9)
        surfaceLine.lineWidth = 2
        surfaceLine.lineJoin = .round
        layer?.addSublayer(surfaceLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    /// Redraws the water for the surface heights `surface(x)` (pt, y-up, view coordinates).
    func update(width: CGFloat, step: CGFloat = 6, surface: (CGFloat) -> CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        shape.frame = bounds
        surfaceLine.frame = bounds
        let body = CGMutablePath()
        let line = CGMutablePath()
        body.move(to: CGPoint(x: 0, y: 0))
        var x: CGFloat = 0
        var first = true
        while true {
            let p = CGPoint(x: x, y: min(bounds.maxY, max(0, surface(x))))
            body.addLine(to: p)
            if first { line.move(to: p); first = false } else { line.addLine(to: p) }
            if x >= width { break }
            x = min(width, x + step)
        }
        body.addLine(to: CGPoint(x: width, y: 0))
        body.closeSubpath()
        shape.path = body
        surfaceLine.path = line
        CATransaction.commit()
    }
}
