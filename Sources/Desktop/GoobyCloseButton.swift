import SwiftUI

/// Tiny code-drawn close circle shown at the canvas top-right on hover.
/// Lives in Desktop/ (host controls), not Character/, so the character stays control-free.
struct GoobyCloseButton: View {
    static let diameter: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(GoobyVisualMetrics.closeControl))
                ForEach([45.0, -45.0], id: \.self) { angle in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 9, height: 2)
                        .rotationEffect(.degrees(angle))
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quit Gooby")
    }
}

/// Hover state fed by the AppKit tracking area (works while Gooby's app is inactive).
@MainActor
final class GoobyControlsState: ObservableObject {
    @Published private(set) var isHovering = false
    /// True during the rain easter egg: the close control hides (no easy escape).
    @Published private(set) var stormActive = false
    /// Peeking around this screen edge (no Claude chat in front), or nil beside a chat.
    @Published private(set) var peekEdge: PeekEdge?
    /// Where the peeking eyes look (-1...1 each; y down).
    @Published private(set) var gaze: CGVector = .zero
    /// Turning into the peek during the Gooby Glide there: edge and progress 0...1.
    @Published private(set) var peekMorph: PeekMorph?
    /// The peek was reached by gliding (already in place: no slide-out on appear).
    private(set) var peekArrivedByGlide = false
    /// Called for every click on Gooby's body (not the close control) beside a chat.
    var onCharacterClick: (@MainActor () -> Void)?
    /// Double-click while peeking: hide until a Claude chat is in front again.
    var onPeekDoubleClick: (@MainActor () -> Void)?
    /// The user started / finished dragging Gooby (dropped at this panel origin).
    var onDragBegan: (@MainActor () -> Void)?
    var onDragEnded: (@MainActor (CGPoint) -> Void)?

    func setPeekEdge(_ value: PeekEdge?) {
        if peekEdge != value { peekEdge = value }
    }

    func setPeekMorph(_ value: PeekMorph?) {
        if peekMorph != value { peekMorph = value }
    }

    func setPeekEdge(_ value: PeekEdge?, arrivedByGlide: Bool) {
        peekArrivedByGlide = arrivedByGlide
        setPeekEdge(value)
    }

    func setGaze(_ value: CGVector) {
        if abs(gaze.dx - value.dx) > 0.01 || abs(gaze.dy - value.dy) > 0.01 { gaze = value }
    }

    func setHovering(_ value: Bool) {
        if isHovering != value { isHovering = value }
    }

    func setStormActive(_ value: Bool) {
        if stormActive != value { stormActive = value }
    }

    var showsCloseControl: Bool { isHovering && !stormActive && peekEdge == nil }
}

/// Character plus hover-revealed close control, in the fixed 136 × 136 pt canvas.
/// The close circle does not bob, so it stays an easy, stationary target.
struct GoobyRootView: View {
    let model: GoobyAnimationModel
    @ObservedObject var controls: GoobyControlsState
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let edge = controls.peekEdge {
                    GoobyPeekContainer(model: model, controls: controls, edge: edge)
                        .transition(.opacity)
                } else if let morph = controls.peekMorph {
                    // Mid Gooby Glide: turning into the peek, driven frame by frame.
                    GoobyMorphContainer(model: model, morph: morph)
                } else {
                    GoobyCharacterView(model: model)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion || controls.peekArrivedByGlide ? nil : .easeInOut(duration: 0.25),
                       value: controls.peekEdge)
            GoobyCloseButton(action: onClose)
                .opacity(controls.showsCloseControl ? 1 : 0)
                .allowsHitTesting(controls.showsCloseControl)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: controls.showsCloseControl)
        }
        .frame(width: GoobyVisualMetrics.canvasSize.width, height: GoobyVisualMetrics.canvasSize.height)
    }
}

/// The peek pose at on-screen size, blinking like the normal pose. Slides out from
/// behind the edge when it appears (instant with Reduce Motion).
struct GoobyPeekContainer: View {
    @ObservedObject var model: GoobyAnimationModel
    @ObservedObject var controls: GoobyControlsState
    let edge: PeekEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal: CGFloat = 0

    var body: some View {
        let m = GoobyVisualMetrics.self
        GoobyMorphView(edge: edge, progress: 1, eyeOpenness: model.eyeOpenness, gaze: controls.gaze, reveal: reveal)
            .scaleEffect(m.displayScale)
            .frame(width: m.canvasSize.width, height: m.canvasSize.height)
            .onAppear {
                if reduceMotion || controls.peekArrivedByGlide {
                    reveal = 1
                } else {
                    // Same graceful ease as the glide: gentle start, soft landing.
                    withAnimation(.timingCurve(0.42, 0, 0.18, 1, duration: m.peekRevealDuration)) { reveal = 1 }
                }
            }
    }
}

/// Turning into the peek: which edge and how far (0 standing … 1 peeking).
struct PeekMorph: Equatable, Sendable {
    let edge: PeekEdge
    let progress: CGFloat
}

/// The morph at on-screen size, still bobbing (fading out) and blinking.
struct GoobyMorphContainer: View {
    @ObservedObject var model: GoobyAnimationModel
    let morph: PeekMorph

    var body: some View {
        let m = GoobyVisualMetrics.self
        TimelineView(.animation(paused: model.mode != .normal)) { context in
            GoobyMorphView(edge: morph.edge, progress: morph.progress, eyeOpenness: model.eyeOpenness,
                           bob: model.bobOffset(at: context.date))
        }
        .scaleEffect(m.displayScale)
        .frame(width: m.canvasSize.width, height: m.canvasSize.height)
    }
}
