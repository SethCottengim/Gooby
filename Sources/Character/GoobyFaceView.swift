import SwiftUI

/// Gooby's puffy body and face, drawn in body-local coordinates (bodySize frame).
/// The 3D "clay" look comes from layered gradients and soft rims — no images.
struct GoobyFaceView: View {
    let eyeOpenness: CGFloat
    /// Where the face sits across the body (fraction of width). Peeking turns it toward the screen.
    var faceCenterX: CGFloat = GoobyVisualMetrics.faceCenterX
    var eyeHalfSpacing: CGFloat = GoobyVisualMetrics.eyeHalfSpacing
    /// Where the eyes look: each component in -1...1 (x right, y down). Zero = straight ahead.
    var gaze: CGVector = .zero
    var showsMouth = true

    var body: some View {
        let m = GoobyVisualMetrics.self
        let size = m.bodySize
        let shape = GoobyBodyShape()
        ZStack {
            // Base form: lit top band → interior → shaded underside (reference rows).
            shape.fill(LinearGradient(stops: [
                .init(color: Color(m.bodyTop), location: 0),
                .init(color: Color(m.bodyBase), location: 0.3),
                .init(color: Color(m.bodyBase), location: 0.66),
                .init(color: Color(m.bodyBottom), location: 0.93),
                .init(color: Color(m.bodyDark), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            // Light from the left edge, fading by ~25% of the width.
            shape.fill(LinearGradient(stops: [
                .init(color: Color(m.bodyLight).opacity(0.85), location: 0),
                .init(color: Color(m.bodyLight).opacity(0), location: 0.25),
            ], startPoint: .leading, endPoint: .trailing))
            // Right side slightly shaded; darkest toward the bottom-right.
            shape.fill(LinearGradient(stops: [
                .init(color: Color(m.bodyDark).opacity(0), location: 0.6),
                .init(color: Color(m.bodyDark).opacity(0.45), location: 1),
            ], startPoint: UnitPoint(x: 0.3, y: 0.3), endPoint: UnitPoint(x: 1, y: 1)))
            // Top-left corner sheen.
            shape.fill(RadialGradient(
                colors: [Color.white.opacity(0.28), Color.white.opacity(0)],
                center: UnitPoint(x: 0.08, y: 0.08), startRadius: 0, endRadius: size.width * 0.32
            ))
            // Soft inner rim so the edge reads as rounded.
            shape.strokeBorder(Color(m.bodyDark).opacity(0.35), lineWidth: 6)
                .blur(radius: 4)
                .offset(x: 1.5, y: 2.5)
                .mask(shape)

            ForEach([-1.0, 1.0] as [CGFloat], id: \.self) { side in
                GoobyEyeView(openness: eyeOpenness)
                    .position(x: (faceCenterX + side * eyeHalfSpacing) * size.width + gaze.dx * m.gazeShift,
                              y: m.eyeY * size.height + gaze.dy * m.gazeShift)
            }
            if showsMouth {
                GoobySmileShape(centerX: faceCenterX)
                    .stroke(Color(m.feature), style: StrokeStyle(lineWidth: m.mouthLineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The smile: a shallow curve between two corner ticks — ")" on the left and
/// "(" on the right — that rise above the joins and kick outward below them.
struct GoobySmileShape: Shape {
    var centerX: CGFloat = GoobyVisualMetrics.mouthCenter.x

    func path(in rect: CGRect) -> Path {
        let m = GoobyVisualMetrics.self
        let cx = centerX * rect.width
        let cy = m.mouthCenter.y * rect.height
        let half = m.mouthWidth / 2
        var p = Path()
        p.move(to: CGPoint(x: cx - half, y: cy))
        p.addQuadCurve(to: CGPoint(x: cx + half, y: cy), control: CGPoint(x: cx, y: cy + 2 * m.mouthDepth))
        for side in [-1.0, 1.0] as [CGFloat] {
            let join = CGPoint(x: cx + side * half, y: cy)
            let top = CGPoint(x: join.x + side * m.mouthTickTopOut, y: cy - m.mouthTickRise)
            let bottom = CGPoint(x: join.x + side * m.mouthTickBottomOut, y: cy + m.mouthTickDrop)
            // Control point chosen so the tick's midpoint passes through the join.
            let control = CGPoint(x: 2 * join.x - (top.x + bottom.x) / 2, y: 2 * join.y - (top.y + bottom.y) / 2)
            p.move(to: top)
            p.addQuadCurve(to: bottom, control: control)
        }
        return p
    }
}

/// Superellipse "pillow" body: |x/a|^n + |y/b|^n = 1, with a rounder exponent on the
/// bottom half (y grows down). Both halves meet at the widest point. Insettable for rim strokes.
struct GoobyBodyShape: InsettableShape {
    var exponent: CGFloat = GoobyVisualMetrics.bodySuperellipseExponent
    var bottomExponent: CGFloat = GoobyVisualMetrics.bodyBottomSuperellipseExponent
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }
        let a = r.width / 2, b = r.height / 2
        let samples = 240
        var p = Path()
        for i in 0..<samples {
            let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
            let n = sin(t) > 0 ? bottomExponent : exponent
            let point = CGPoint(x: r.midX + a * Self.signedPow(cos(t), 2 / n),
                                y: r.midY + b * Self.signedPow(sin(t), 2 / n))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> GoobyBodyShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    static func signedPow(_ v: CGFloat, _ e: CGFloat) -> CGFloat {
        v < 0 ? -pow(-v, e) : pow(v, e)
    }
}
