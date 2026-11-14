import AppKit

/// Borderless, transparent panel that can never become key or main,
/// so the app the user is typing into keeps keyboard focus (design §2.5).
final class NonActivatingGoobyPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // Accept clicks for the hover close control. The panel still never becomes
        // key or main, so keyboard focus stays with the other app. Fully transparent
        // canvas pixels still let clicks fall through to the window behind.
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = false
        // Gooby's app is never active, so the panel must not hide on deactivation.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        // Follow Terminal onto any desktop (Space), including a full-screen Terminal.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Peeking puts half the panel past the screen edge on purpose; macOS must not push it back.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
