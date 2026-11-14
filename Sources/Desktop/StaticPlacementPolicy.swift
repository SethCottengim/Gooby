import CoreGraphics

/// Decides where the panel appears. A later terminal-relative policy can replace
/// this without touching the character (IF-GOOBY-INT-002).
protocol PlacementPolicy {
    func origin(for size: CGSize, visibleFrame: CGRect?) -> CGPoint
}

/// Screen-relative placement: bottom-right corner of the visible frame with a margin.
/// Falls back to centering when no usable screen frame exists.
struct StaticPlacementPolicy: PlacementPolicy {
    var margin: CGFloat = 24
    /// Used only when macOS reports no screen at all.
    var fallbackFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func origin(for size: CGSize, visibleFrame: CGRect?) -> CGPoint {
        guard let frame = visibleFrame, isUsable(frame) else {
            return centered(size, in: visibleFrame.flatMap { isUsable($0) ? $0 : nil } ?? fallbackFrame)
        }
        guard frame.width >= size.width + 2 * margin,
              frame.height >= size.height + 2 * margin
        else {
            return centered(size, in: frame)
        }
        return CGPoint(x: frame.maxX - margin - size.width, y: frame.minY + margin)
    }

    private func isUsable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
    }

    private func centered(_ size: CGSize, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
    }
}
