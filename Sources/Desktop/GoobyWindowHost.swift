import AppKit
import Combine
import SwiftUI

/// Owns exactly one companion panel hosting exactly one Gooby.
/// Shows it with orderFrontRegardless() and never activates the app or makes
/// the panel key/main.
@MainActor
final class GoobyWindowHost {
    let model: GoobyAnimationModel
    private(set) var panel: NonActivatingGoobyPanel?
    private let placement: PlacementPolicy
    private let visibleFrame: @MainActor () -> CGRect?
    private let onClose: @MainActor () -> Void
    let controls = GoobyControlsState()
    private(set) var wantsVisible = false
    /// 0.15 s fade; skipped when macOS reduce motion is on.
    private let reduceMotion: @MainActor () -> Bool
    static let fadeDuration: TimeInterval = 0.15
    /// Gliding to another window (product owner: smooth and graceful, easing into place):
    /// a gentle start, fastest mid-way, then a long soft settle. 2.4% of the way at 10% of
    /// the time, 78% at half, the last 30% of the time covers only the final 6%.
    nonisolated static let glideCurve = EaseCurve(x1: 0.42, y1: 0.0, x2: 0.18, y2: 1.0)
    /// Short hops take about 0.65 s; a trip across the screen up to 1.1 s.
    nonisolated static let minGlideDuration: TimeInterval = 0.65
    nonisolated static let maxGlideDuration: TimeInterval = 1.1
    nonisolated static let glideDistanceForMax: CGFloat = 1200

    nonisolated static func glideDuration(distance: CGFloat) -> TimeInterval {
        let k = min(1, max(0, distance / glideDistanceForMax))
        return minGlideDuration + (maxGlideDuration - minGlideDuration) * Double(k)
    }
    static let glideFrameInterval: TimeInterval = 1.0 / 120.0
    /// While a glide runs, small follow-up moves (window still settling) retarget it smoothly.
    static let retargetDuration: TimeInterval = 0.3
    private(set) var isGliding = false
    private var glideTimer: Timer?
    /// Gooby Gliding toward a peek spot, turning into the peek on the way.
    private(set) var pendingPeek: PeekEdge?
    /// Each glide that turns Gooby (into or out of the peek) gets an id; stale frames are ignored.
    private var turnID = 0
    /// Eyes follow the cursor while peeking (30 Hz, smoothed); off otherwise.
    private var gazeTimer: Timer?
    static let gazeInterval: TimeInterval = 1.0 / 30.0
    /// Cursor this far from the eyes (points) or more: look fully toward it.
    nonisolated static let gazeFullDistance: CGFloat = 90
    static let gazeSmoothing: CGFloat = 0.3
    private let nameTag = GoobyNameTag()
    private(set) var project: String?
    private var hoverWatch: AnyCancellable?

    init(
        model: GoobyAnimationModel = GoobyAnimationModel(),
        placement: PlacementPolicy = StaticPlacementPolicy(),
        visibleFrame: @escaping @MainActor () -> CGRect? = {
            (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        },
        onClose: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) },
        reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.reduceMotion = reduceMotion
        self.model = model
        self.onClose = onClose
        self.placement = placement
        self.visibleFrame = visibleFrame
    }

    /// Creates the panel (hidden) if needed.
    @discardableResult
    func prepare() -> NonActivatingGoobyPanel {
        if let panel { return panel }
        let size = GoobyVisualMetrics.canvasSize
        let origin = placement.origin(for: size, visibleFrame: visibleFrame())
        let panel = NonActivatingGoobyPanel(contentRect: NSRect(origin: origin, size: size))
        let root = GoobyRootView(model: model, controls: controls, onClose: { [weak self] in self?.requestClose() })
        let hosting = GoobyHostingView(rootView: root, controls: controls)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        self.panel = panel
        hoverWatch = controls.$isHovering.removeDuplicates().sink { [weak self] hovering in
            MainActor.assumeIsolated { self?.updateNameTag(hovering: hovering) }
        }
        return panel
    }

    /// Shows the panel at its static placement.
    func show() {
        let panel = prepare()
        wantsVisible = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// During the rain easter egg Gooby sits above the water and hides the close control.
    func setStormMode(_ on: Bool) {
        controls.setStormActive(on)
        panel?.level = on ? StormLevels.gooby : .floating
    }

    /// Called by the hover close control. Quits Gooby (default) via the injected handler.
    func requestClose() {
        onClose()
    }

    /// Shows the project tag while hovering, unless Gooby is hidden, it's the storm, or
    /// an offer bubble (another child window) is up.
    private func updateNameTag(hovering: Bool) {
        let otherChildren = (panel?.childWindows ?? []).filter { $0 !== nameTag.window }
        guard hovering, let panel, panel.isVisible, wantsVisible, let project, !controls.stormActive,
              otherChildren.isEmpty else {
            nameTag.hide()
            return
        }
        nameTag.show(project, above: panel)
    }

    func tearDown() {
        stopGlide()
        stopGaze()
        nameTag.hide()
        hoverWatch = nil
        wantsVisible = false
        model.stop()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, completion: (@MainActor () -> Void)? = nil) {
        if reduceMotion() {
            panel.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }
}

extension GoobyWindowHost: GoobyPresenter {
    /// Beside a chat. Coming from the peek (or mid-turn), the mirror of the trip out: one
    /// Gooby Glide that turns back upright while sliding out from behind the edge.
    func present(at origin: CGPoint, animated: Bool) {
        pendingPeek = nil
        turnID += 1
        let id = turnID
        // How turned Gooby is right now (1 = peeking, mid-turn value, or 0 = upright).
        let (edge, base): (PeekEdge?, CGFloat) = {
            if let m = controls.peekMorph { return (m.edge, m.progress) }
            if let e = controls.peekEdge { return (e, 1) }
            return (nil, 0)
        }()
        controls.setPeekEdge(nil, arrivedByGlide: false)
        stopGaze()
        let travels = animated && (panel?.isVisible ?? false) && wantsVisible && !reduceMotion()
            && panel?.frame.origin != origin
        guard let edge, base > 0, travels else {
            controls.setPeekMorph(nil)
            move(to: origin, animated: animated)
            return
        }
        controls.setPeekMorph(PeekMorph(edge: edge, progress: base))
        move(to: origin, animated: true, onFrame: { [weak self] t in
            guard let self, self.turnID == id else { return }
            self.controls.setPeekMorph(PeekMorph(edge: edge, progress: base * (1 - Self.returnProgress(glideProgress: t))))
        }, arrived: { [weak self] in
            guard let self, self.turnID == id else { return }
            self.controls.setPeekMorph(nil)
        })
    }

    /// Already peeking: slide along the edge. Otherwise one Gooby Glide to the spot that
    /// turns into the peek on the way (whole at first, peeking on arrival; no pause).
    func peek(at origin: CGPoint, edge: PeekEdge, animated: Bool) {
        nameTag.hide()
        if controls.peekEdge == edge {
            move(to: origin, animated: animated)
            return
        }
        let travels = animated && (panel?.isVisible ?? false) && wantsVisible && !reduceMotion()
            && panel?.frame.origin != origin
        guard travels else {
            pendingPeek = nil
            controls.setPeekMorph(nil)
            controls.setPeekEdge(edge, arrivedByGlide: false) // slides out from behind the edge
            move(to: origin, animated: animated)
            startGaze()
            return
        }
        turnID += 1
        let id = turnID
        // Changing course mid-turn continues from the current pose (no snap back to upright).
        let base = controls.peekMorph.map { $0.edge == edge ? $0.progress : 0 } ?? 0
        pendingPeek = edge
        controls.setPeekEdge(nil, arrivedByGlide: false)
        controls.setPeekMorph(PeekMorph(edge: edge, progress: base))
        move(to: origin, animated: true, onFrame: { [weak self] t in
            guard let self, self.turnID == id, self.pendingPeek == edge else { return }
            self.controls.setPeekMorph(PeekMorph(edge: edge, progress: base + (1 - base) * Self.morphProgress(glideProgress: t)))
        }, arrived: { [weak self] in
            guard let self, self.turnID == id, self.pendingPeek == edge else { return }
            self.pendingPeek = nil
            self.controls.setPeekEdge(edge, arrivedByGlide: true) // same pose as the morph at 1
            self.controls.setPeekMorph(nil)
            self.startGaze()
        })
    }

    /// Leaving the peek: fully upright by `peekMorphReturnEnd` of the glide (smoothstep).
    nonisolated static func returnProgress(glideProgress t: Double) -> CGFloat {
        let x = max(0, min(1, t / GoobyVisualMetrics.peekMorphReturnEnd))
        return CGFloat(x * x * (3 - 2 * x))
    }

    /// Turning starts part-way through the glide and finishes exactly on arrival, smoothly.
    nonisolated static func morphProgress(glideProgress t: Double) -> CGFloat {
        let start = GoobyVisualMetrics.peekMorphStart
        let x = max(0, min(1, (t - start) / (1 - start)))
        return CGFloat(x * x * (3 - 2 * x)) // smoothstep
    }

    private func move(to origin: CGPoint, animated: Bool, onFrame: (@MainActor (Double) -> Void)? = nil,
                      arrived: (@MainActor () -> Void)? = nil) {
        let panel = prepare()
        let visible = panel.isVisible && wantsVisible
        if visible && (animated || isGliding) && !reduceMotion() {
            let from = panel.frame.origin
            let distance = ((origin.x - from.x) * (origin.x - from.x) + (origin.y - from.y) * (origin.y - from.y)).squareRoot()
            glide(panel, to: origin, duration: animated ? Self.glideDuration(distance: distance) : Self.retargetDuration,
                  onFrame: onFrame, arrived: arrived)
        } else {
            stopGlide()
            panel.setFrameOrigin(origin)
        }
        guard !visible else { return }
        wantsVisible = true
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        fade(panel, to: 1)
    }

    private func startGaze() {
        guard gazeTimer == nil else { return }
        let timer = Timer(timeInterval: Self.gazeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGaze() }
        }
        RunLoop.main.add(timer, forMode: .common)
        gazeTimer = timer
        updateGaze()
    }

    private func stopGaze() {
        gazeTimer?.invalidate()
        gazeTimer = nil
        controls.setGaze(.zero)
    }

    /// Looks from the peeking eyes toward the cursor (NSEvent.mouseLocation: no permission).
    private func updateGaze() {
        guard let panel, let edge = controls.peekEdge else { return }
        let target = Self.gaze(from: Self.peekEyePoint(panel: panel.frame, edge: edge), to: NSEvent.mouseLocation)
        let k = reduceMotion() ? 1 : Self.gazeSmoothing
        let current = controls.gaze
        controls.setGaze(CGVector(dx: current.dx + (target.dx - current.dx) * k,
                                  dy: current.dy + (target.dy - current.dy) * k))
    }

    /// Where the peeking eyes are on screen (AppKit coordinates): the turned head sits at
    /// the canvas center; the eyes are `eyeY` of the way from the top of the head.
    nonisolated static func peekEyePoint(panel: CGRect, edge: PeekEdge) -> CGPoint {
        let m = GoobyVisualMetrics.self
        let a = m.peekAcrossOnScreen
        let depth = m.eyeY * a
        let x = edge == .right ? panel.midX - a / 2 + depth : panel.midX + a / 2 - depth
        return CGPoint(x: x, y: panel.midY)
    }

    /// Unit-ish look direction toward `cursor` (x right, y DOWN for drawing); weaker when close.
    nonisolated static func gaze(from eye: CGPoint, to cursor: CGPoint) -> CGVector {
        let dx = cursor.x - eye.x, dy = cursor.y - eye.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return .zero }
        let strength = min(1, length / gazeFullDistance)
        return CGVector(dx: dx / length * strength, dy: -dy / length * strength)
    }

    func showProject(_ name: String?) {
        project = name
        updateNameTag(hovering: controls.isHovering)
    }

    /// Moves the panel smoothly with its own frame timer (macOS doesn't animate
    /// `animator().setFrameOrigin` for windows). Starts from wherever Gooby is now,
    /// so a new target mid-glide simply bends the path; child windows move along.
    private func glide(_ panel: NSPanel, to origin: CGPoint, duration: TimeInterval,
                       onFrame: (@MainActor (Double) -> Void)? = nil,
                       arrived: (@MainActor () -> Void)? = nil) {
        stopGlide()
        let start = panel.frame.origin
        guard start != origin else { return }
        let began = Date()
        isGliding = true
        nameTag.hide() // re-shown on the next hover
        let timer = Timer(timeInterval: Self.glideFrameInterval, repeats: true) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let panel else { self.stopGlide(); return }
                let progress = min(1, Date().timeIntervalSince(began) / duration)
                let k = Self.glideCurve.value(at: progress)
                panel.setFrameOrigin(CGPoint(x: start.x + (origin.x - start.x) * k,
                                             y: start.y + (origin.y - start.y) * k))
                onFrame?(progress)
                if progress >= 1 {
                    panel.setFrameOrigin(origin) // land exactly
                    self.stopGlide()
                    arrived?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
    }

    /// The user grabbed Gooby: stop any glide so the drag is in full control.
    func cancelGlide() {
        stopGlide()
        pendingPeek = nil
        controls.setPeekMorph(nil)
    }

    private func stopGlide() {
        glideTimer?.invalidate()
        glideTimer = nil
        isGliding = false
    }

    func conceal() {
        guard let panel, wantsVisible else { return }
        nameTag.hide()
        stopGlide()
        stopGaze()
        pendingPeek = nil
        controls.setPeekMorph(nil)
        wantsVisible = false
        fade(panel, to: 0) { [weak self] in
            // A present() during the fade wins.
            guard let self, !self.wantsVisible else { return }
            self.panel?.orderOut(nil)
        }
    }
}

/// A CSS-style cubic-bezier easing curve from (0,0) to (1,1): value(at: t) for t in 0...1.
struct EaseCurve: Equatable, Sendable {
    let x1: Double, y1: Double, x2: Double, y2: Double

    func value(at t: Double) -> Double {
        let t = min(max(t, 0), 1)
        if t == 0 || t == 1 { return t }
        // Solve x(s) = t for the bezier parameter s (Newton, then bisection fallback).
        var s = t
        for _ in 0..<8 {
            let dx = bezierDerivative(s, x1, x2)
            guard abs(dx) > 1e-6 else { break }
            let next = s - (bezier(s, x1, x2) - t) / dx
            if abs(next - s) < 1e-7 { s = next; break }
            s = min(max(next, 0), 1)
        }
        if abs(bezier(s, x1, x2) - t) > 1e-4 {
            var lo = 0.0, hi = 1.0
            for _ in 0..<40 {
                s = (lo + hi) / 2
                if bezier(s, x1, x2) < t { lo = s } else { hi = s }
            }
        }
        return bezier(s, y1, y2)
    }

    private func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
    }

    private func bezierDerivative(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * p1 + 6 * u * s * (p2 - p1) + 3 * s * s * (1 - p2)
    }
}
