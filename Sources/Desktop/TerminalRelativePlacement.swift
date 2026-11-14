import CoreGraphics

/// Pure placement math for following the Terminal window.
enum TerminalRelativePlacement {
    /// Converts Core Graphics global bounds (top-left origin, y down) into AppKit
    /// screen coordinates (bottom-left origin of the primary screen, y up).
    static func appKitRect(fromCGBounds r: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Gooby's panel origin (AppKit coordinates), bottom-aligned with the terminal:
    /// 1. just outside the right edge; 2. else just outside the left edge;
    /// 3. else inside the terminal's bottom-right corner (e.g. full-screen terminal).
    /// The result always stays inside the chosen screen's visible frame.
    static func origin(goobySize size: CGSize, terminal: CGRect, screens: [CGRect]) -> CGPoint {
        let screen = bestScreen(for: terminal, among: screens)
        let y = clamp(terminal.minY, screen.minY, screen.maxY - size.height)

        if terminal.maxX + size.width <= screen.maxX {
            return CGPoint(x: terminal.maxX, y: y)
        }
        if terminal.minX - size.width >= screen.minX {
            return CGPoint(x: terminal.minX - size.width, y: y)
        }
        let x = clamp(terminal.maxX - size.width, screen.minX, screen.maxX - size.width)
        return CGPoint(x: x, y: y)
    }

    /// Screen with the largest overlap; falls back to the first screen, then the terminal itself.
    static func bestScreen(for terminal: CGRect, among screens: [CGRect]) -> CGRect {
        let scored = screens.map { ($0, area($0.intersection(terminal))) }
        if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        return screens.first ?? terminal
    }

    private static func area(_ r: CGRect) -> CGFloat {
        r.isNull ? 0 : r.width * r.height
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        hi < lo ? lo : min(max(v, lo), hi)
    }
}
