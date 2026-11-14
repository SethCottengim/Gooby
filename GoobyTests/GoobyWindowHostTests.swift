import AppKit
import SwiftUI
import XCTest
@testable import Gooby

@MainActor
final class GoobyWindowHostTests: XCTestCase {
    func testShowCreatesOnePanelHostingOneCharacter() throws {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let host = GoobyWindowHost(visibleFrame: { frame })
        XCTAssertNil(host.panel)

        host.show()
        let panel = try XCTUnwrap(host.panel)
        XCTAssertTrue(panel.contentView is GoobyHostingView)
        XCTAssertEqual(panel.frame.size, GoobyVisualMetrics.canvasSize)
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 1000 - 24 - GoobyVisualMetrics.canvasSize.width, y: 24))
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)

        host.show()
        XCTAssertTrue(host.panel === panel, "A second show() must not create another panel")

        host.tearDown()
        XCTAssertNil(host.panel)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(host.model.mode)
    }

    func testNoScreenUsesCenteredFallback() throws {
        let host = GoobyWindowHost(visibleFrame: { nil })
        host.show()
        XCTAssertEqual(try XCTUnwrap(host.panel).frame.origin, CGPoint(x: 720 - GoobyVisualMetrics.canvasSize.width / 2, y: 450 - GoobyVisualMetrics.canvasSize.height / 2))
        host.tearDown()
    }

    func testCloseControlCallsInjectedHandlerOnly() {
        var closes = 0
        let host = GoobyWindowHost(visibleFrame: { nil }, onClose: { closes += 1 })
        host.show()
        host.requestClose()
        XCTAssertEqual(closes, 1)
        host.tearDown()
    }

    func testHoverTrackingIsAlwaysActiveAndRevealsClose() throws {
        let host = GoobyWindowHost(visibleFrame: { nil }, onClose: {})
        host.show()
        let view = try XCTUnwrap(host.panel?.contentView as? GoobyHostingView)
        view.updateTrackingAreas()
        let area = try XCTUnwrap(view.hoverTrackingArea)
        XCTAssertTrue(area.options.contains(.activeAlways), "Hover must work while Gooby's app is inactive")
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(view.acceptsFirstMouse(for: nil), "First click must hit the close control")

        XCTAssertFalse(host.controls.isHovering)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseEntered(with: event)
        XCTAssertTrue(host.controls.isHovering)
        view.mouseExited(with: event)
        XCTAssertFalse(host.controls.isHovering)
        host.tearDown()
    }

    /// Source inspection: focus-stealing calls must not exist anywhere in the app.
    func testAppSourcesNeverCallActivationHelpers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
        let forbidden = [".activate(", "activate(ignoringOtherApps", "makeKeyAndOrderFront", "makeKeyWindow", "makeMainWindow"]
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(url.lastPathComponent) calls \(token)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 5)
    }
}
