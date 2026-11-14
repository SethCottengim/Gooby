import XCTest
@testable import Gooby

final class StaticPlacementPolicyTests: XCTestCase {
    let size = CGSize(width: 136, height: 136)
    let policy = StaticPlacementPolicy()

    func testBottomRightOfUsableVisibleFrame() {
        let frame = CGRect(x: 0, y: 25, width: 1512, height: 920)
        let origin = policy.origin(for: size, visibleFrame: frame)
        XCTAssertEqual(origin, CGPoint(x: 1512 - 24 - 136, y: 25 + 24))
        XCTAssertTrue(frame.contains(CGRect(origin: origin, size: size)))
    }

    func testSecondaryScreenWithNegativeOrigin() {
        let frame = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let origin = policy.origin(for: size, visibleFrame: frame)
        XCTAssertEqual(origin, CGPoint(x: -24 - 136, y: -200 + 24))
    }

    func testTooSmallFrameCentersInsteadOfOverflowing() {
        let frame = CGRect(x: 100, y: 100, width: 150, height: 150)
        XCTAssertEqual(policy.origin(for: size, visibleFrame: frame), CGPoint(x: 107, y: 107))
    }

    func testNoScreenFallsBackToCentered() {
        XCTAssertEqual(policy.origin(for: size, visibleFrame: nil), CGPoint(x: 720 - 68, y: 450 - 68))
    }

    func testDegenerateFrameFallsBackToCentered() {
        XCTAssertEqual(policy.origin(for: size, visibleFrame: .zero), CGPoint(x: 652, y: 382))
        XCTAssertEqual(policy.origin(for: size, visibleFrame: .null), CGPoint(x: 652, y: 382))
    }
}
