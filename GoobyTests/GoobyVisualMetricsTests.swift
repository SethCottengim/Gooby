import XCTest
@testable import Gooby

final class GoobyVisualMetricsTests: XCTestCase {
    typealias M = GoobyVisualMetrics

    func testCanvasAndBodyGeometry() {
        XCTAssertEqual(M.designCanvasSize, CGSize(width: 160, height: 144))
        XCTAssertEqual(M.displayScale, 0.7)
        XCTAssertEqual(M.canvasSize, CGSize(width: 112, height: 102), "30% smaller, rounded up to even whole points")
        XCTAssertEqual(M.bodySize, CGSize(width: 106, height: 96))
        XCTAssertGreaterThan(M.bodySize.width, M.bodySize.height, "Reference body is slightly wider than tall")
        XCTAssertEqual(M.bodySize.width / M.bodySize.height, 1.106, accuracy: 0.01, "Reference aspect")
        XCTAssertEqual(M.bodySuperellipseExponent, 5.5)
        XCTAssertEqual(M.bodyRect, CGRect(x: 27, y: 18, width: 106, height: 96))
    }

    /// Arms, legs, shadow and a full ±4 pt bob must stay inside the canvas, and the
    /// top-right 18 pt close-control corner must stay clear of the figure.
    func testFigureFitsCanvasThroughoutBob() {
        let canvas = CGRect(origin: .zero, size: M.designCanvasSize)
        let figure = M.characterBounds
        for dy in [-M.bobAmplitude, 0, M.bobAmplitude] {
            XCTAssertTrue(canvas.contains(figure.offsetBy(dx: 0, dy: dy)), "Clipped at bob \(dy)")
        }
        let shadowBottom = M.bodyRect.maxY + M.legHeelDrop + 1 + M.groundShadowSize.height / 2
        XCTAssertLessThanOrEqual(shadowBottom, canvas.maxY)
        let closeSide: CGFloat = 15 / M.displayScale   // 15 pt on-screen close control, in design points
        let closeCorner = CGRect(x: canvas.maxX - closeSide, y: 0, width: closeSide, height: closeSide)
        XCTAssertFalse(closeCorner.intersects(M.bodyRect.offsetBy(dx: 0, dy: -M.bobAmplitude)))
    }

    func testPaletteFromReference() {
        XCTAssertEqual(M.bodyBaseHex, 0x6FA6C8)
        XCTAssertEqual(M.bodyTopHex, 0x85BAD5)
        XCTAssertEqual(M.bodyLightHex, 0x94C3DC)
        XCTAssertEqual(M.bodyDarkHex, 0x5188B3)
        XCTAssertEqual(M.featureHex, 0x161616)
        func luma(_ c: GoobyRGB) -> Double { 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue }
        // Lit left edge > top band > interior > underside > darkest corner.
        XCTAssertGreaterThan(luma(M.bodyLight), luma(M.bodyTop))
        XCTAssertGreaterThan(luma(M.bodyTop), luma(M.bodyBase))
        XCTAssertGreaterThan(luma(M.bodyBase), luma(M.bodyBottom))
        XCTAssertGreaterThan(luma(M.bodyBottom), luma(M.bodyDark))
    }

    /// Feature positions measured from the reference (fractions of the body box).
    func testFaceMatchesReferenceMeasurements() {
        XCTAssertEqual(M.eyeCenters[0].x, 0.409, accuracy: 0.002)
        XCTAssertEqual(M.eyeCenters[1].x, 0.725, accuracy: 0.002)
        XCTAssertEqual(M.eyeCenters[0].y, 0.432, accuracy: 0.002)
        XCTAssertEqual(M.mouthCenter.x, 0.567, accuracy: 0.002)
        XCTAssertEqual(M.mouthCenter.y, 0.546, accuracy: 0.002)
        // Mouth bounding box incl. ticks ≈ 188 px of 980 px = 20.3 pt wide.
        XCTAssertEqual(M.mouthWidth + 2 * M.mouthTickBottomOut, 20.3, accuracy: 0.5)
        for p in M.eyeCenters + [M.mouthCenter] {
            XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y))
        }
    }

    func testBodyShapeIsSuperellipse() {
        let rect = CGRect(x: 0, y: 0, width: 106, height: 96)
        let path = GoobyBodyShape().path(in: rect)
        XCTAssertEqual(path.boundingRect.width, 106, accuracy: 0.01)
        XCTAssertEqual(path.boundingRect.height, 96, accuracy: 0.01)
        let a: CGFloat = 53, b: CGFloat = 48
        // Top half (y < center) uses n = 5.5; bottom half uses the rounder n = 4.2.
        for (n, dir) in [(M.bodySuperellipseExponent, CGFloat(-1)), (M.bodyBottomSuperellipseExponent, CGFloat(1))] {
            let k = pow(0.5, 1 / n)   // curve point on the 45° parameter diagonal
            XCTAssertTrue(path.contains(CGPoint(x: 53 + a * k * 0.98, y: 48 + dir * b * k * 0.98)), "n=\(n)")
            XCTAssertFalse(path.contains(CGPoint(x: 53 + a * k * 1.02, y: 48 + dir * b * k * 1.02)), "n=\(n)")
        }
        // Reference: the bottom sits flat and wide — at least as wide as the top at the same inset.
        func width(atY y: CGFloat) -> CGFloat {
            let xs = stride(from: 0.0, through: 106.0, by: 0.25).filter { path.contains(CGPoint(x: $0, y: y)) }
            return xs.max()! - xs.min()!
        }
        XCTAssertGreaterThanOrEqual(width(atY: 96 - 0.05 * 96), width(atY: 0.05 * 96))
        XCTAssertFalse(path.contains(CGPoint(x: 105.5, y: 95.5)), "Extreme corner stays empty")
        XCTAssertEqual(GoobyBodyShape().inset(by: 3).path(in: rect).boundingRect.width, 100, accuracy: 0.01)
    }

    /// Leg slants from under the body to the heel; the shorter foot points straight up.
    @MainActor
    func testLegsAndFeetReadDistinctly() {
        let legLength = hypot(M.legReach.width, M.legReach.height)
        XCTAssertLessThan(M.footLength, legLength * 0.65, "Foot clearly shorter than the leg")
        let b = M.bodyRect
        for fx in M.legXs {
            let heel = GoobyLimbs.heel(fx, body: b)
            XCTAssertGreaterThan(heel.y, b.maxY, "Heel sits below the body")
            XCTAssertLessThan(heel.y - M.legReach.height, b.maxY, "Leg starts under the body edge")
        }
        XCTAssertFalse(GoobyLimbs.legs(body: b).isEmpty)
        XCTAssertFalse(GoobyLimbs.feet(body: b).isEmpty)
    }

    func testMotionConstants() {
        XCTAssertEqual(M.bobAmplitude, 4)
        XCTAssertEqual(M.bobPeriod, 3.2)
        XCTAssertEqual(M.blinkIntervalRange, 4.8...9.6)
        XCTAssertEqual(M.blinkCloseDuration, 0.090)
        XCTAssertEqual(M.blinkHoldDuration, 0.050)
        XCTAssertEqual(M.blinkOpenDuration, 0.140)
    }

    /// Gooby stays fully code-drawn: no raster images or text in the character.
    func testCharacterIsCodeDrawn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/Character")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
            for token in ["Image(", "NSImage", "Text(", "Label("] {
                XCTAssertFalse(code.contains(token), "\(file.lastPathComponent) contains \(token)")
            }
        }
    }
}
