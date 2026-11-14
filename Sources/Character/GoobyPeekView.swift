import SwiftUI

/// Which screen edge Gooby peeks around.
enum PeekEdge: String, Equatable, Sendable {
    case left
    case right
}

/// Gooby from standing (progress 0) to peeking (progress 1), as one continuous shape so a
/// Gooby Glide can turn into the peek on the way, with no pause or jump at the end.
///
/// Peeking (product owner's sketch, 2026-11-13): turned 90° so the top of the head faces
/// into the screen, smaller, with only the top slice showing (rounded top + eyes).
/// Gooby is never clipped: it stays whole in its canvas, and the panel glides half past
/// the screen edge, so the real screen edge hides the rest ("behind the screen").
/// Right edge: turned -90° (top points left). Left edge: +90° (top points right); not
/// mirrored, so the slightly off-center face never flips.
struct GoobyMorphView: View {
    let edge: PeekEdge
    /// 0 = standing whole, 1 = peeking.
    let progress: CGFloat
    let eyeOpenness: CGFloat
    /// Screen look direction while peeking (x right, y down), each -1...1.
    var gaze: CGVector = .zero
    /// Standing bob offset (design points); fades out as Gooby turns.
    var bob: CGFloat = 0
    /// Peek only: 0 = fully behind the edge, 1 = peeking (fade-in when there was no glide).
    var reveal: CGFloat = 1

    var body: some View {
        let m = GoobyVisualMetrics.self
        let p = max(0, min(1, progress))
        let canvas = m.designCanvasSize
        let b = m.bodyRect
        let standing = CGPoint(x: b.midX, y: b.midY)
        let target = Self.peekCenter(edge: edge, reveal: reveal)
        // (No clipping: the window's own bounds are big enough for every step of the turn.)
        let scale = 1 + (m.peekScale - 1) * p
        let angle = (edge == .right ? -90.0 : 90.0) * Double(p)
        let anchor = UnitPoint(x: standing.x / canvas.width, y: standing.y / canvas.height)
        let limbs = Double(max(0, 1 - p * 1.8)) // arms, legs, shadow fade early
        ZStack {
            GoobyGroundShadow(bobOffset: 0).opacity(limbs)
            ZStack(alignment: .topLeading) {
                GoobyLimbStroke(path: GoobyLimbs.arms(body: b)).opacity(limbs)
                GoobyLimbStroke(path: GoobyLimbs.legs(body: b)).opacity(limbs)
                GoobyFaceView(eyeOpenness: eyeOpenness,
                              gaze: Self.localGaze(CGVector(dx: gaze.dx * p, dy: gaze.dy * p), edge: edge),
                              showsMouth: p < 0.5)
                    .position(x: b.midX, y: b.midY)
                GoobyLimbStroke(path: GoobyLimbs.feet(body: b)).opacity(limbs)
            }
            .frame(width: canvas.width, height: canvas.height)
            .offset(y: bob * (1 - p))
            .scaleEffect(scale, anchor: anchor)
            .rotationEffect(.degrees(angle), anchor: anchor)
            .offset(x: (target.x - standing.x) * p, y: (target.y - standing.y) * p)
        }
        .frame(width: canvas.width, height: canvas.height)
    }

    /// Body center when peeking: the canvas center (the panel's position does the rest).
    /// `reveal` < 1 tucks the head toward the screen edge, i.e. further behind it.
    static func peekCenter(edge: PeekEdge, reveal: CGFloat = 1) -> CGPoint {
        let m = GoobyVisualMetrics.self
        let canvas = m.designCanvasSize
        let shown = m.bodySize.height * m.peekScale * m.peekVisibleFraction
        let tuck = shown * (1 - max(0, min(1, reveal)))
        return CGPoint(x: canvas.width / 2 + (edge == .right ? tuck : -tuck), y: canvas.height / 2)
    }

    /// Screen look direction → the turned face's own axes.
    /// -90° (right edge): face +x → screen up, +y → screen right.
    /// +90° (left edge): face +x → screen down, +y → screen left.
    nonisolated static func localGaze(_ g: CGVector, edge: PeekEdge) -> CGVector {
        edge == .right ? CGVector(dx: -g.dy, dy: g.dx) : CGVector(dx: g.dy, dy: -g.dx)
    }
}

/// The finished peek: the morph at 1.
typealias GoobyPeekView = GoobyMorphView
