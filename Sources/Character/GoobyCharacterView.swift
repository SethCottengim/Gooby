import SwiftUI

/// Gooby in a stable transparent canvas. Only the drawing offset moves; the
/// canvas (and therefore the panel) never resizes or repositions.
struct GoobyCharacterView: View {
    @ObservedObject var model: GoobyAnimationModel

    var body: some View {
        let m = GoobyVisualMetrics.self
        TimelineView(.animation(paused: model.mode != .normal)) { context in
            let offset = model.bobOffset(at: context.date)
            ZStack {
                GoobyGroundShadow(bobOffset: offset)
                GoobyFigureView(eyeOpenness: model.eyeOpenness)
                    .offset(y: offset)
            }
        }
        .frame(width: m.designCanvasSize.width, height: m.designCanvasSize.height)
        // Draw in design points, then shrink to the on-screen canvas.
        .scaleEffect(m.displayScale)
        .frame(width: m.canvasSize.width, height: m.canvasSize.height)
        .modifier(MotionPreferenceAdapter(model: model))
    }
}

/// Arms and legs behind the body, body + face, feet in front — in canvas coordinates.
struct GoobyFigureView: View {
    let eyeOpenness: CGFloat

    var body: some View {
        let m = GoobyVisualMetrics.self
        let b = m.bodyRect
        ZStack(alignment: .topLeading) {
            GoobyLimbStroke(path: GoobyLimbs.arms(body: b))
            GoobyLimbStroke(path: GoobyLimbs.legs(body: b))
            GoobyFaceView(eyeOpenness: eyeOpenness)
                .position(x: b.midX, y: b.midY)
            GoobyLimbStroke(path: GoobyLimbs.feet(body: b))
        }
        .frame(width: m.designCanvasSize.width, height: m.designCanvasSize.height)
    }
}

/// Soft contact shadow; it shrinks and fades a little as Gooby rises.
struct GoobyGroundShadow: View {
    let bobOffset: CGFloat

    var body: some View {
        let m = GoobyVisualMetrics.self
        let b = m.bodyRect
        let lift = -bobOffset / m.bobAmplitude          // +1 at the top of the bob
        Ellipse()
            .fill(Color.black.opacity(m.groundShadowOpacity * (1 - 0.25 * lift)))
            .frame(width: m.groundShadowSize.width, height: m.groundShadowSize.height)
            .scaleEffect(1 - 0.06 * lift)
            .blur(radius: 2.5)
            .position(x: b.midX, y: b.maxY + 1.5)
            .frame(width: m.designCanvasSize.width, height: m.designCanvasSize.height)
    }
}

/// Rounded limb stroke with a subtle top-left sheen so it reads as a tube.
struct GoobyLimbStroke: View {
    let path: Path

    var body: some View {
        let m = GoobyVisualMetrics.self
        let style = StrokeStyle(lineWidth: m.limbLineWidth, lineCap: .round, lineJoin: .round)
        ZStack {
            path.stroke(Color(m.limbDark), style: style)
            path.stroke(Color(m.limb), style: StrokeStyle(lineWidth: m.limbLineWidth * 0.8, lineCap: .round, lineJoin: .round))
                .offset(x: -0.3, y: -0.3)
            path.stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
                .offset(x: -0.7, y: -0.7)
        }
    }
}

enum GoobyLimbs {
    static func arms(body b: CGRect) -> Path {
        let m = GoobyVisualMetrics.self
        let y = b.minY + m.armAttachY * b.height
        var p = Path()
        p.move(to: CGPoint(x: b.minX + 4, y: y))
        p.addLine(to: CGPoint(x: b.minX - m.armReach.width, y: y + m.armReach.height))
        p.move(to: CGPoint(x: b.maxX - 4, y: y))
        p.addLine(to: CGPoint(x: b.maxX + m.armReach.width, y: y + m.armReach.height))
        return p
    }

    static func heel(_ fx: CGFloat, body b: CGRect) -> CGPoint {
        CGPoint(x: b.minX + fx * b.width, y: b.maxY + GoobyVisualMetrics.legHeelDrop)
    }

    /// Diagonal legs from under the body down-right to each heel (drawn behind the body).
    static func legs(body b: CGRect) -> Path {
        let m = GoobyVisualMetrics.self
        var p = Path()
        for fx in m.legXs {
            let heel = heel(fx, body: b)
            p.move(to: CGPoint(x: heel.x - m.legReach.width, y: heel.y - m.legReach.height))
            p.addLine(to: heel)
        }
        return p
    }

    /// Short upright feet rising from each heel (drawn in front of the body).
    static func feet(body b: CGRect) -> Path {
        let m = GoobyVisualMetrics.self
        var p = Path()
        for fx in m.legXs {
            let heel = heel(fx, body: b)
            p.move(to: heel)
            p.addLine(to: CGPoint(x: heel.x, y: heel.y - m.footLength))
        }
        return p
    }
}
