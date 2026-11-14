import CoreGraphics
import Foundation

/// sRGB color stored as plain components so the metrics stay framework-free.
struct GoobyRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }
}

/// Immutable visual and motion contract for Gooby.
/// Character v2 (2026-11-10): soft 3D-look "clay" Gooby matching the product
/// owner's reference image — puffy rounded body, dot eyes, curled smile,
/// stick arms, and sitting stick legs (no cheeks: the face stays flat). All code-drawn. Positions and
/// colors measured from the reference image.
enum GoobyVisualMetrics {
    // Canvas (transparent). Room for arms, legs, ground shadow, and ±4 pt bob.
    /// All character geometry below is in *design points* inside this canvas.
    static let designCanvasSize = CGSize(width: 160, height: 144)
    /// On-screen size relative to the design (0.7 = 30% smaller; product owner, 2026-11-11).
    static let displayScale: CGFloat = 0.7
    /// On-screen panel / canvas size: the scaled design rounded up to even whole points,
    /// so centered and edge placements land on whole points too (112 × 102 pt).
    static var canvasSize: CGSize {
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.up) * 2 }
        return CGSize(width: even(designCanvasSize.width * displayScale),
                      height: even(designCanvasSize.height * displayScale))
    }

    // Body: a "pillow" superellipse |x/a|^n + |y/b|^n = 1 measured from the reference
    // (984 × 890 px → 1.106 aspect). The top fits n ≈ 5.5; the bottom sits flat and
    // wide (side-by-side comparison), so it uses a slightly squarer n.
    static let bodySize = CGSize(width: 106, height: 96)
    static let bodySuperellipseExponent: CGFloat = 5.5
    static let bodyBottomSuperellipseExponent: CGFloat = 6.5
    /// Body center offset from canvas center (negative = up), leaving room for legs + shadow.
    static let bodyCenterOffsetY: CGFloat = -6

    // Palette measured from the reference (5 × 5 grid of the body, 2400 × 1792 px image).
    static let bodyBaseHex: UInt32 = 0x6FA6C8      // interior
    static let bodyTopHex: UInt32 = 0x85BAD5       // lit top band
    static let bodyBottomHex: UInt32 = 0x568CB5    // shaded underside
    static let bodyLightHex: UInt32 = 0x94C3DC     // lit left edge
    static let bodyDarkHex: UInt32 = 0x5188B3      // bottom-right, darkest
    static let limbHex: UInt32 = 0x7FB3D3
    static let limbDarkHex: UInt32 = 0x5A90BA
    static let featureHex: UInt32 = 0x161616       // eyes and mouth
    static let closeControlHex: UInt32 = 0x2C4B61

    // Face (fractions of body size from the body's top-left). The reference face is
    // turned slightly: it is centered at 56.7% of the body width, not 50%.
    static let faceCenterX: CGFloat = 0.567
    static let eyeSize = CGSize(width: 4.3, height: 4.4)
    static let eyeHalfSpacing: CGFloat = 0.158
    static let eyeY: CGFloat = 0.432
    static var eyeCenters: [CGPoint] {
        [CGPoint(x: faceCenterX - eyeHalfSpacing, y: eyeY), CGPoint(x: faceCenterX + eyeHalfSpacing, y: eyeY)]
    }
    /// Where the smile meets the corner ticks (center between the two joins).
    static var mouthCenter: CGPoint { CGPoint(x: faceCenterX, y: 0.546) }
    /// Join-to-join width of the smile (reference: 135 px of a 980 px body).
    static let mouthWidth: CGFloat = 14.6
    static let mouthDepth: CGFloat = 1.6
    static let mouthLineWidth: CGFloat = 1.4
    /// Corner ticks: ")" on the left and "(" on the right, crossing the smile ends.
    static let mouthTickRise: CGFloat = 4.1
    static let mouthTickDrop: CGFloat = 3.2
    static let mouthTickTopOut: CGFloat = 1.3
    static let mouthTickBottomOut: CGFloat = 3.0

    // Limbs
    static let limbLineWidth: CGFloat = 3.4
    /// Arm attaches at this fraction of body height and angles down-outward.
    static let armAttachY: CGFloat = 0.57
    /// Arms hang steeply: ~10 pt out, ~20 pt down (side-by-side with the reference).
    static let armReach = CGSize(width: 9.5, height: 20)
    /// Legs (as in the reference, sitting with legs stretched toward the viewer):
    /// - the leg is a diagonal that emerges from under the body and slants down-right
    ///   to the heel (drawn behind the body, so its top end is hidden);
    /// - the foot points straight up from the heel, in front of the body.
    /// The reference foot is as long as the leg (~9 pt each); the foot is shortened
    /// here so the two parts read clearly (product owner, 2026-11-11).
    /// `legXs` are the heel x positions, fractions of body width.
    static let legXs: [CGFloat] = [0.435, 0.738]
    static let legHeelDrop: CGFloat = 4.6
    static let legReach = CGSize(width: 6.7, height: 6.1)
    static let footLength: CGFloat = 5

    // Ground shadow
    /// Tight contact shadow directly under the body (not a wide blur below the legs).
    static let groundShadowSize = CGSize(width: 100, height: 6)
    static let groundShadowOpacity: Double = 0.28

    // Motion
    static let bobAmplitude: CGFloat = 4
    static let bobPeriod: TimeInterval = 3.2
    static let blinkIntervalRange: ClosedRange<TimeInterval> = 4.8...9.6
    static let blinkCloseDuration: TimeInterval = 0.090
    static let blinkHoldDuration: TimeInterval = 0.050
    static let blinkOpenDuration: TimeInterval = 0.140

    // Peeking (product owner's sketch, 2026-11-13): when no Claude chat is in front,
    // Gooby turns 90° and peeks from behind a side edge: top of the head and eyes only.
    /// Size while peeking, relative to normal.
    static let peekScale: CGFloat = 0.82
    /// Fraction of the head's height that shows past the edge (eyes sit at 0.432).
    static let peekVisibleFraction: CGFloat = 0.5
    /// Sliding out from behind the edge when peeking starts.
    static let peekRevealDuration: TimeInterval = 0.7
    /// Peek geometry on screen (points). Gooby is never clipped: the panel itself glides
    /// half past the screen edge and the screen edge hides the rest (product owner).
    /// The turned head's size across the edge direction.
    static var peekAcrossOnScreen: CGFloat { bodySize.height * peekScale * displayScale }
    /// How much of it shows on screen.
    static var peekShownOnScreen: CGFloat { peekAcrossOnScreen * peekVisibleFraction }
    /// From the panel's left side to the screen edge, when peeking from the right edge
    /// (the turned head sits at the canvas center, its top facing left).
    static var peekRightEdgeInset: CGFloat { canvasSize.width / 2 - peekAcrossOnScreen / 2 + peekShownOnScreen }
    /// From the screen edge to the panel's left side, when peeking from the left edge (negative: past it).
    static var peekLeftEdgeOffset: CGFloat { peekShownOnScreen - canvasSize.width / 2 - peekAcrossOnScreen / 2 }

    /// How far the eyes move toward the cursor (design points at full gaze). More than a real
    /// eye would (product owner: "say the head is moving"), while the peeking head stays still.
    /// Eyes sit 41.5 design pt from the top of the head and 48 pt shows, so 5 pt keeps them
    /// on screen except when the cursor is in the few points between them and the edge.
    static let gazeShift: CGFloat = 5
    /// During the Gooby Glide to the peek spot, Gooby turns into the peek over the last
    /// part of the trip (fraction of the glide's time when turning starts).
    static let peekMorphStart: Double = 0.4
    /// Leaving the peek, the mirror: upright again by this fraction of the glide's time.
    static let peekMorphReturnEnd: Double = 0.6

    static var bodyBase: GoobyRGB { GoobyRGB(hex: bodyBaseHex) }
    static var bodyTop: GoobyRGB { GoobyRGB(hex: bodyTopHex) }
    static var bodyBottom: GoobyRGB { GoobyRGB(hex: bodyBottomHex) }
    static var bodyLight: GoobyRGB { GoobyRGB(hex: bodyLightHex) }
    static var bodyDark: GoobyRGB { GoobyRGB(hex: bodyDarkHex) }
    static var limb: GoobyRGB { GoobyRGB(hex: limbHex) }
    static var limbDark: GoobyRGB { GoobyRGB(hex: limbDarkHex) }
    static var feature: GoobyRGB { GoobyRGB(hex: featureHex) }
    static var closeControl: GoobyRGB { GoobyRGB(hex: closeControlHex) }

    /// Body rect inside the canvas (top-left origin, y down).
    static var bodyRect: CGRect {
        CGRect(
            x: (designCanvasSize.width - bodySize.width) / 2,
            y: (designCanvasSize.height - bodySize.height) / 2 + bodyCenterOffsetY,
            width: bodySize.width,
            height: bodySize.height
        )
    }

    /// Full drawn extent (body + arms + legs), before bobbing.
    static var characterBounds: CGRect {
        let b = bodyRect
        let legBottom = b.maxY + legHeelDrop
        return CGRect(x: b.minX - armReach.width - limbLineWidth / 2,
                      y: b.minY,
                      width: b.width + 2 * (armReach.width + limbLineWidth / 2),
                      height: legBottom + limbLineWidth / 2 - b.minY)
    }
}
