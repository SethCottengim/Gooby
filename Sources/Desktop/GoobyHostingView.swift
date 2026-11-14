import AppKit
import SwiftUI

/// Hosting view that reports hover through an always-active tracking area and
/// accepts the first click, so the close control works without Gooby ever
/// becoming active or key.
final class GoobyHostingView: NSHostingView<GoobyRootView> {
    let controls: GoobyControlsState
    private var hoverArea: NSTrackingArea?

    init(rootView: GoobyRootView, controls: GoobyControlsState) {
        self.controls = controls
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: GoobyRootView) { fatalError("Use init(rootView:controls:)") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    static let trackingOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]

    var hoverTrackingArea: NSTrackingArea? { hoverArea }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: Self.trackingOptions, owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        controls.setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controls.setHovering(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A press becomes a drag after moving this far (points); less is a click.
    static let dragThreshold: CGFloat = 3

    /// A peeking press: where it started, for dragging up/down the edge.
    private var press: (cursor: CGPoint, origin: CGPoint)?
    private var dragging = false

    /// Beside a chat: clicks only (they count toward the rain); Gooby can't be dragged there.
    /// Peeking: drag Gooby up or down along its edge; a double-click hides it.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        press = nil
        dragging = false
        if controls.peekEdge != nil {
            if event.clickCount >= 2 {
                controls.onPeekDoubleClick?()
            } else {
                press = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
            }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if !Self.isOnCloseControl(point, in: bounds, isFlipped: isFlipped, closeShown: controls.showsCloseControl) {
            controls.onCharacterClick?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        guard let press, controls.peekEdge != nil, let window else { return }
        let cursor = NSEvent.mouseLocation
        if !dragging {
            guard Self.isDrag(from: press.cursor, to: cursor) else { return }
            dragging = true
            controls.onDragBegan?()
        }
        let lane = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .infinite
        window.setFrameOrigin(Self.peekDraggedOrigin(start: press.origin, from: press.cursor, to: cursor,
                                                     height: window.frame.height, lane: lane))
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { press = nil; dragging = false }
        if dragging, let window { controls.onDragEnded?(window.frame.origin) }
    }

    static func isDrag(from start: CGPoint, to now: CGPoint) -> Bool {
        let dx = now.x - start.x, dy = now.y - start.y
        return dx * dx + dy * dy >= dragThreshold * dragThreshold
    }

    /// Peeking Gooby slides straight up or down its edge, following the cursor directly
    /// (it should feel held), never above the menu bar or into the Dock area.
    static func peekDraggedOrigin(start: CGPoint, from cursor: CGPoint, to now: CGPoint,
                                  height: CGFloat, lane: CGRect) -> CGPoint {
        let y = start.y + now.y - cursor.y
        let hi = lane.maxY - height
        return CGPoint(x: start.x, y: hi < lane.minY ? lane.minY : min(max(y, lane.minY), hi))
    }

    /// The close control occupies the top-right square of the canvas.
    static func isOnCloseControl(_ p: CGPoint, in bounds: CGRect, isFlipped: Bool, closeShown: Bool) -> Bool {
        guard closeShown else { return false }
        let d = GoobyCloseButton.diameter
        let yFromTop = isFlipped ? p.y - bounds.minY : bounds.maxY - p.y
        return p.x >= bounds.maxX - d && yFromTop <= d
    }
}
