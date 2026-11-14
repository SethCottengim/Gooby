import AppKit
import SwiftUI

/// The hover tag: the project of the Claude chat Gooby sits beside, e.g. "pixel-farm".
struct GoobyNameTagView: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(GoobyVisualMetrics.closeControl).opacity(0.92)))
            .fixedSize()
            .padding(2)
    }
}

/// A tiny label panel above Gooby, shown on hover. It never takes mouse events, so
/// hovering Gooby isn't interrupted, and never takes focus.
@MainActor
final class GoobyNameTag {
    nonisolated static let gap: CGFloat = 2
    static let maxNameLength = 28

    private var panel: NonActivatingGoobyPanel?
    /// The tag's own panel (so callers can tell it apart from other child windows).
    var window: NSWindow? { panel }

    func show(_ name: String, above gooby: NSPanel) {
        let label = name.count > Self.maxNameLength ? String(name.prefix(Self.maxNameLength - 1)) + "…" : name
        let panel = self.panel ?? {
            let p = NonActivatingGoobyPanel(contentRect: .zero)
            p.ignoresMouseEvents = true
            self.panel = p
            return p
        }()
        let hosting = NSHostingView(rootView: GoobyNameTagView(name: label))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.level = gooby.level
        panel.setFrameOrigin(Self.origin(tag: size, gooby: gooby.frame, screen: gooby.screen?.visibleFrame))
        if panel.parent !== gooby {
            panel.parent?.removeChildWindow(panel)
            gooby.addChildWindow(panel, ordered: .above)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Centered just above Gooby's canvas, kept on screen.
    nonisolated static func origin(tag: CGSize, gooby: CGRect, screen: CGRect?) -> CGPoint {
        var x = gooby.midX - tag.width / 2
        var y = gooby.maxY + gap
        if let screen {
            x = min(max(x, screen.minX), screen.maxX - tag.width)
            y = min(y, screen.maxY - tag.height)
        }
        return CGPoint(x: x, y: y)
    }
}
