import CoreGraphics
import Foundation

/// One display: its full frame and the part windows may use (minus menu bar and Dock).
struct ScreenInfo: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
}

/// Remembers the peek height the user dragged Gooby to, across launches, as a fraction of
/// the screen's usable height (0 = bottom, 1 = top), so it still fits on another display
/// or after a resolution change.
protocol PeekHeightStoring: AnyObject {
    var fraction: Double? { get set }
}

final class UserDefaultsPeekHeight: PeekHeightStoring {
    static let key = "peekHeightFraction"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var fraction: Double? {
        get { defaults.object(forKey: Self.key) == nil ? nil : defaults.double(forKey: Self.key) }
        set {
            if let newValue { defaults.set(min(1, max(0, newValue)), forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
        }
    }
}

final class InMemoryPeekHeight: PeekHeightStoring {
    var fraction: Double?
    init(_ fraction: Double? = nil) { self.fraction = fraction }
}

/// Where Gooby peeks from when no Claude chat is in front (AppKit coordinates).
enum PeekPlacement {
    /// Panel origin y → 0...1 of the usable height (and back).
    static func fraction(ofOriginY y: CGFloat, height: CGFloat, in visible: CGRect) -> Double {
        let span = visible.height - height
        guard span > 0 else { return 0 }
        return Double(min(1, max(0, (y - visible.minY) / span)))
    }

    static func originY(forFraction f: Double, height: CGFloat, in visible: CGRect) -> CGFloat {
        visible.minY + CGFloat(min(1, max(0, f))) * max(0, visible.height - height)
    }

    static func screen(containing point: CGPoint, in screens: [ScreenInfo]) -> ScreenInfo? {
        screens.first(where: { $0.frame.contains(point) }) ?? screens.first
    }

    /// The panel sits half past a side edge of the screen Gooby was last on (the screen
    /// edge hides that part; nothing is clipped), at about the same height. Picks the nearer side, but never the Dock's side (the Dock would
    /// cover Gooby when it appears) or a side that touches another display (no "wall" there).
    static func place(canvas: CGSize, near point: CGPoint, screens: [ScreenInfo]) -> (origin: CGPoint, edge: PeekEdge)? {
        guard let screen = screen(containing: point, in: screens) else { return nil }
        let v = screen.visibleFrame
        var candidates: [PeekEdge] = [.left, .right]
        if let dock = dockSide(screen) { candidates.removeAll { $0 == dock } }
        candidates.removeAll { touchesAnotherScreen($0, of: screen, screens: screens) }
        if candidates.isEmpty { candidates = [.left, .right].filter { $0 != dockSide(screen) } }
        if candidates.isEmpty { candidates = [.right] }
        let edge = candidates.count == 1 ? candidates[0] : (point.x >= v.midX ? .right : .left)
        let m = GoobyVisualMetrics.self
        let x = edge == .right ? v.maxX - m.peekRightEdgeInset : v.minX + m.peekLeftEdgeOffset
        let y = clamp(point.y - canvas.height / 2, v.minY, v.maxY - canvas.height)
        return (CGPoint(x: x, y: y), edge)
    }

    /// The Dock's side when it's on the left or right (visible frame inset there); nil for the bottom.
    static func dockSide(_ s: ScreenInfo) -> PeekEdge? {
        if s.visibleFrame.minX > s.frame.minX + 1 { return .left }
        if s.visibleFrame.maxX < s.frame.maxX - 1 { return .right }
        return nil
    }

    static func touchesAnotherScreen(_ edge: PeekEdge, of s: ScreenInfo, screens: [ScreenInfo]) -> Bool {
        screens.contains { other in
            guard other != s else { return false }
            let x = edge == .right ? s.frame.maxX : s.frame.minX
            let otherX = edge == .right ? other.frame.minX : other.frame.maxX
            let overlapsVertically = other.frame.minY < s.frame.maxY && other.frame.maxY > s.frame.minY
            return abs(x - otherX) < 1 && overlapsVertically
        }
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        hi < lo ? lo : min(max(v, lo), hi)
    }
}
