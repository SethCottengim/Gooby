import AppKit
import XCTest
@testable import Gooby

@MainActor
final class NonActivatingGoobyPanelTests: XCTestCase {
    func testPanelCannotTakeFocusButAcceptsClicksForCloseControl() {
        let panel = NonActivatingGoobyPanel(contentRect: NSRect(x: 0, y: 0, width: 136, height: 136))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.ignoresMouseEvents, "Needed for the hover close control")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless) || panel.styleMask == [.nonactivatingPanel])
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hidesOnDeactivate)
        panel.close()
    }
}
