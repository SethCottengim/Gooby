import XCTest
@testable import Gooby

final class TerminalPlacementTests: XCTestCase {
    let size = CGSize(width: 136, height: 136)
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)   // visible frame

    func testCGToAppKitConversion() {
        let cg = CGRect(x: 531, y: 422, width: 860, height: 535)
        XCTAssertEqual(TerminalRelativePlacement.appKitRect(fromCGBounds: cg, primaryScreenHeight: 982),
                       CGRect(x: 531, y: 982 - 957, width: 860, height: 535))
    }

    func testOutsideRightBottomAligned() {
        let term = CGRect(x: 300, y: 200, width: 800, height: 500)
        XCTAssertEqual(TerminalRelativePlacement.origin(goobySize: size, terminal: term, screens: [screen]), CGPoint(x: 1100, y: 200))
    }

    func testFlipsLeftWhenNoRoomOnRight() {
        let term = CGRect(x: 600, y: 200, width: 900, height: 500)
        XCTAssertEqual(TerminalRelativePlacement.origin(goobySize: size, terminal: term, screens: [screen]), CGPoint(x: 464, y: 200))
    }

    func testInsideCornerWhenTerminalFillsWidth() {
        let term = CGRect(x: 0, y: 0, width: 1512, height: 944)
        XCTAssertEqual(TerminalRelativePlacement.origin(goobySize: size, terminal: term, screens: [screen]), CGPoint(x: 1376, y: 0))
    }

    func testYClampedWhenTerminalBottomIsBelowScreen() {
        let term = CGRect(x: 100, y: -300, width: 600, height: 500)
        XCTAssertEqual(TerminalRelativePlacement.origin(goobySize: size, terminal: term, screens: [screen]).y, 0)
    }

    func testPicksScreenWithMostOverlap() {
        let external = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
        let term = CGRect(x: 2000, y: 100, width: 800, height: 600)
        XCTAssertEqual(TerminalRelativePlacement.origin(goobySize: size, terminal: term, screens: [screen, external]), CGPoint(x: 2800, y: 100))
        XCTAssertEqual(TerminalRelativePlacement.bestScreen(for: CGRect(x: 9000, y: 9000, width: 10, height: 10), among: [screen, external]), screen)
    }
}

final class TerminalWindowLocatorTests: XCTestCase {
    func w(_ pid: pid_t, _ layer: Int = 0, _ r: CGRect, alpha: Double = 1) -> WindowSnapshot {
        WindowSnapshot(ownerPID: pid, layer: layer, bounds: r, alpha: alpha)
    }

    func testPicksFrontmostUsableTerminalWindow() {
        let windows = [
            w(99, 25, CGRect(x: 0, y: 0, width: 1512, height: 24)),     // menu bar-ish, other app
            w(7, 0, CGRect(x: 10, y: 10, width: 120, height: 40)),       // too small (tooltip)
            w(7, 0, CGRect(x: 5, y: 5, width: 500, height: 300), alpha: 0),
            w(7, 0, CGRect(x: 531, y: 422, width: 860, height: 535)),     // front Terminal window
            w(7, 0, CGRect(x: 0, y: 0, width: 900, height: 600)),         // behind
        ]
        XCTAssertEqual(TerminalWindowLocator.frontTerminalWindow(frontmostBundleID: "com.apple.Terminal", frontmostPID: 7, windows: windows),
                       CGRect(x: 531, y: 422, width: 860, height: 535))
    }

    func testNilWhenTerminalNotFrontmostOrHasNoWindow() {
        let windows = [w(7, 0, CGRect(x: 0, y: 0, width: 900, height: 600))]
        XCTAssertNil(TerminalWindowLocator.frontTerminalWindow(frontmostBundleID: "com.microsoft.VSCode", frontmostPID: 7, windows: windows))
        XCTAssertNil(TerminalWindowLocator.frontTerminalWindow(frontmostBundleID: nil, frontmostPID: nil, windows: windows))
        XCTAssertNil(TerminalWindowLocator.frontTerminalWindow(frontmostBundleID: "com.apple.Terminal", frontmostPID: 8, windows: windows))
    }

    func testLiveSourceNeverReadsTitlesOrPixels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
            for token in ["kCGWindowName", "CGWindowListCreateImage", "ScreenCaptureKit", "SCStream", "AXUIElement"] {
                XCTAssertFalse(code.contains(token), "\(url.lastPathComponent) uses \(token)")
            }
        }
    }
}

@MainActor
final class FakePresenter: GoobyPresenter {
    var events: [String] = []
    var glides: [Bool] = []
    var projects: [String?] = []
    func present(at origin: CGPoint, animated: Bool) {
        events.append("present \(Int(origin.x)),\(Int(origin.y))")
        glides.append(animated)
    }
    func conceal() { events.append("conceal") }
    func showProject(_ name: String?) { projects.append(name) }
    func peek(at origin: CGPoint, edge: PeekEdge, animated: Bool) {
        events.append("peek \(edge.rawValue) \(Int(origin.x)),\(Int(origin.y))")
        glides.append(animated)
    }
}

@MainActor
final class TerminalFollowerTests: XCTestCase {
    var front: (String?, pid_t?) = ("com.apple.Terminal", 7)
    var windows: [WindowSnapshot] = []
    var windowQueries = 0

    func makeFollower(_ presenter: FakePresenter) -> TerminalFollower {
        TerminalFollower(presenter: presenter, environment: .init(
            frontmost: { [unowned self] in (self.front.0, self.front.1) },
            windows: { [unowned self] in self.windowQueries += 1; return self.windows },
            screens: { [CGRect(x: 0, y: 0, width: 1512, height: 944)] },
            primaryScreenHeight: { 982 }
        ))
    }

    func terminal(x: CGFloat, y: CGFloat) -> WindowSnapshot {
        WindowSnapshot(ownerPID: 7, layer: 0, bounds: CGRect(x: x, y: y, width: 800, height: 500), alpha: 1)
    }

    func testFollowsMovesAndIgnoresJitter() {
        let p = FakePresenter(); let f = makeFollower(p)
        windows = [terminal(x: 100, y: 200)]           // AppKit y = 982 - 700 = 282
        f.tick()
        windows = [terminal(x: 100.2, y: 200.3)]       // sub-threshold jitter
        f.tick()
        windows = [terminal(x: 150, y: 200)]
        f.tick()
        XCTAssertEqual(p.events, ["present 900,282", "present 950,282"])
        XCTAssertTrue(f.isPresented)
    }

    func testHidesWhenAnotherAppIsFrontAndReturns() {
        let p = FakePresenter(); let f = makeFollower(p)
        windows = [terminal(x: 100, y: 200)]
        f.tick()
        front = ("com.microsoft.VSCode", 9)
        let queriesBefore = windowQueries
        f.tick(); f.tick()
        XCTAssertEqual(windowQueries, queriesBefore, "No window query while Terminal isn't in front")
        front = ("com.apple.Terminal", 7)
        f.tick()
        XCTAssertEqual(p.events, ["present 900,282", "conceal", "present 900,282"])
    }

    func testHidesWhenTerminalHasNoWindowsAndStaysHiddenAtLaunchWithoutTerminal() {
        let p = FakePresenter(); let f = makeFollower(p)
        front = ("com.apple.finder", 3)
        f.tick()
        XCTAssertEqual(p.events, [], "Never shown, so nothing to conceal")
        front = ("com.apple.Terminal", 7); windows = [terminal(x: 100, y: 200)]
        f.tick()
        windows = []
        f.tick()
        XCTAssertEqual(p.events, ["present 900,282", "conceal"])
        XCTAssertFalse(f.isPresented)
    }

    func testStartStopIsIdempotent() {
        let p = FakePresenter(); let f = makeFollower(p)
        windows = [terminal(x: 100, y: 200)]
        f.start(); f.start()
        XCTAssertEqual(p.events.count, 1)
        f.stop(); f.stop()
    }
}

@MainActor
final class GoobyPresenterHostTests: XCTestCase {
    func testPresentConcealWithoutAnimation() throws {
        let host = GoobyWindowHost(visibleFrame: { nil }, onClose: {}, reduceMotion: { true })
        let panel = host.prepare()
        XCTAssertFalse(panel.isVisible, "prepare() creates the panel hidden")
        host.present(at: CGPoint(x: 400, y: 300))
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 400, y: 300))
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertFalse(panel.isKeyWindow)
        host.present(at: CGPoint(x: 420, y: 300))
        XCTAssertEqual(panel.frame.origin.x, 420)
        host.conceal()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(host.panel === panel, "Hiding keeps the single panel")
        host.tearDown()
    }

    func testPanelJoinsAllSpaces() {
        let panel = NonActivatingGoobyPanel(contentRect: .zero)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        panel.close()
    }
}

@MainActor
final class ClaudeAwareFollowerTests: XCTestCase {
    var front: (String?, pid_t?) = ("com.apple.Terminal", 7)
    var windows: [WindowSnapshot] = []
    var tab: FrontTabStatus = .claude(project: "pixel-farm")
    var askedWithWindow: [Int?] = []

    func makeFollower(_ p: FakePresenter) -> TerminalFollower {
        TerminalFollower(presenter: p, environment: .init(
            frontmost: { [unowned self] in (self.front.0, self.front.1) },
            windows: { [unowned self] in self.windows },
            screens: { [CGRect(x: 0, y: 0, width: 1512, height: 944)] },
            primaryScreenHeight: { 982 },
            frontTab: { [unowned self] key in self.askedWithWindow.append(key); return self.tab }
        ))
    }

    func window(_ number: Int, x: CGFloat) -> WindowSnapshot {
        WindowSnapshot(ownerPID: 7, layer: 0, bounds: CGRect(x: x, y: 200, width: 800, height: 500), alpha: 1, number: number)
    }

    func testOnlyClaudeTabsGetGooby() {
        let p = FakePresenter(); let f = makeFollower(p)
        windows = [window(11, x: 100)]
        f.tick()
        XCTAssertEqual(p.events, ["present 900,282"])
        XCTAssertEqual(p.projects, ["pixel-farm"])
        XCTAssertEqual(askedWithWindow.last, 11, "Front window number passed for sampling")
        tab = .notClaude // e.g. switched to a plain shell tab
        f.tick()
        XCTAssertEqual(p.events, ["present 900,282", "conceal"])
        tab = .unknown // permission denied: old behavior
        f.tick()
        XCTAssertEqual(p.events.last, "present 900,282")
    }

    func testGlidesOnlyWhenSwitchingWindowsNotWhileDraggingOne() {
        let p = FakePresenter(); let f = makeFollower(p)
        windows = [window(11, x: 100)]
        f.tick()                                   // first appearance: fade in, no glide
        windows = [window(11, x: 160)]
        f.tick()                                   // same window dragged: follow at once
        windows = [window(22, x: 300), window(11, x: 160)]
        f.tick()                                   // another Claude window in front: glide
        windows = [window(22, x: 320), window(11, x: 160)]
        f.tick()                                   // that window dragged: at once again
        XCTAssertEqual(p.glides, [false, false, true, false])
    }

    func testProjectChangeWithoutMoveUpdatesTag() {
        let p = FakePresenter(); let f = makeFollower(p)
        windows = [window(11, x: 100)]
        f.tick()
        tab = .claude(project: "Gooby") // other tab of the same window, same position
        f.tick()
        XCTAssertEqual(p.projects, ["pixel-farm", "Gooby"])
        XCTAssertEqual(p.events.count, 1, "No move needed")
    }
}

final class FakeSessions: ClaudeSessionSource, @unchecked Sendable {
    var list: [ClaudeSession] = []
    var calls = 0
    func sessions() -> [ClaudeSession] { calls += 1; return list }
}

@MainActor
final class FakeFrontTab: FrontTabReading {
    var answer: Result<String?, FrontTabError> = .success("ttys002")
    var calls = 0
    func frontTabTTY() -> Result<String?, FrontTabError> { calls += 1; return answer }
}

@MainActor
final class ClaudePresenceTests: XCTestCase {
    var now = Date(timeIntervalSince1970: 1_000)

    func testStatusFromSessionsAndFrontTab() {
        let s = FakeSessions(); let t = FakeFrontTab()
        let home = NSHomeDirectory()
        s.list = [ClaudeSession(tty: "ttys002", pid: 1, cwd: home)]
        let presence = ClaudePresence(sessions: s, frontTab: t, clock: { [unowned self] in self.now })
        XCTAssertEqual(presence.status(frontWindowKey: 5), .claude(project: "~"))
        t.answer = .success("ttys009")
        now += 2
        XCTAssertEqual(presence.status(frontWindowKey: 5), .notClaude, "Front tab has no Claude")
        t.answer = .success(nil)
        now += 2
        XCTAssertEqual(presence.status(frontWindowKey: 5), .notClaude, "No windows")
    }

    func testSamplesSlowlyButAtOnceOnWindowSwitch() {
        let s = FakeSessions(); let t = FakeFrontTab()
        s.list = [ClaudeSession(tty: "ttys002", pid: 1, cwd: nil)]
        let presence = ClaudePresence(sessions: s, frontTab: t, clock: { [unowned self] in self.now })
        for _ in 0..<30 { _ = presence.status(frontWindowKey: 5) } // one second of ticks
        XCTAssertEqual(t.calls, 1, "Terminal asked once, not 30 times")
        _ = presence.status(frontWindowKey: 6)
        XCTAssertEqual(t.calls, 2, "Window switch asks right away")
        now += ClaudePresence.refreshInterval
        _ = presence.status(frontWindowKey: 6)
        XCTAssertEqual(t.calls, 3)
    }

    func testDeniedFallsBackAndRetriesRarely() {
        let s = FakeSessions(); let t = FakeFrontTab()
        s.list = [ClaudeSession(tty: "ttys002", pid: 1, cwd: nil)]
        t.answer = .failure(.denied)
        let presence = ClaudePresence(sessions: s, frontTab: t, clock: { [unowned self] in self.now })
        XCTAssertEqual(presence.status(frontWindowKey: 5), .unknown, "Some Claude runs: old behavior")
        now += 5
        _ = presence.status(frontWindowKey: 5)
        XCTAssertEqual(t.calls, 1, "Not asked again right away after a denial")
        s.list = []
        now += 1
        XCTAssertEqual(presence.status(frontWindowKey: 5), .notClaude, "No Claude at all: hide")
        now += ClaudePresence.deniedRetryInterval
        t.answer = .success("ttys002")
        s.list = [ClaudeSession(tty: "ttys002", pid: 1, cwd: nil)]
        XCTAssertEqual(presence.status(frontWindowKey: 5), .claude(project: nil), "Asks again later")
    }

    func testProjectNames() {
        let home = "/Users/me"
        let yes: (String) -> Bool = { _ in true }
        XCTAssertEqual(ProjectName.of(cwd: "/Users/me", home: home, exists: yes), "~")
        XCTAssertEqual(ProjectName.of(cwd: "/Users/me/Gitlab/pixel-farm/", home: home, exists: yes), "pixel-farm")
        XCTAssertNil(ProjectName.of(cwd: "/Users/me/deleted", home: home, exists: { _ in false }), "Deleted folder")
        XCTAssertNil(ProjectName.of(cwd: nil, home: home, exists: yes))
        XCTAssertNil(ProjectName.of(cwd: "/", home: home, exists: yes))
    }

    func testTTYNameAndLiveScanDoNotCrash() {
        XCTAssertNil(LibprocClaudeSessions.ttyName(0))
        XCTAssertNil(LibprocClaudeSessions.ttyName(UInt32.max))
        for session in LibprocClaudeSessions().sessions() {
            XCTAssertTrue(session.tty.hasPrefix("tty"), "Only sessions with a terminal: \(session.tty)")
        }
    }

    func testNameTagSitsAboveGoobyOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let tag = CGSize(width: 80, height: 18)
        XCTAssertEqual(GoobyNameTag.origin(tag: tag, gooby: CGRect(x: 400, y: 100, width: 112, height: 102), screen: screen),
                       CGPoint(x: 416, y: 204))
        XCTAssertEqual(GoobyNameTag.origin(tag: tag, gooby: CGRect(x: 950, y: 790, width: 112, height: 102), screen: screen),
                       CGPoint(x: 920, y: 782), "Kept on screen")
    }
}

@MainActor
final class GoobyGlideTests: XCTestCase {
    /// Lets real AppKit animations run.
    func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testGlideReallyMovesThePanel() {
        let host = GoobyWindowHost(visibleFrame: { nil }, onClose: {}, reduceMotion: { false })
        let panel = host.prepare()
        host.present(at: CGPoint(x: 200, y: 200), animated: false)
        spin(0.3) // fade-in
        host.present(at: CGPoint(x: 600, y: 300), animated: true)
        spin(0.2)
        let mid = panel.frame.origin
        XCTAssertNotEqual(mid, CGPoint(x: 600, y: 300), "Still on its way (not a snap)")
        XCTAssertNotEqual(mid, CGPoint(x: 200, y: 200), "Already moving")
        spin(GoobyWindowHost.maxGlideDuration + 0.3)
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 600, y: 300), "Arrives")
        XCTAssertFalse(host.isGliding)
        host.tearDown()
    }

    func testDirectMoveDuringGlideStillArrivesAtNewestTarget() {
        let host = GoobyWindowHost(visibleFrame: { nil }, onClose: {}, reduceMotion: { false })
        let panel = host.prepare()
        host.present(at: CGPoint(x: 200, y: 200), animated: false)
        spin(0.3)
        host.present(at: CGPoint(x: 600, y: 300), animated: true)
        spin(0.1)
        host.present(at: CGPoint(x: 650, y: 300), animated: false) // window still settling
        spin(GoobyWindowHost.maxGlideDuration + 0.3)
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 650, y: 300))
        host.tearDown()
    }
}

final class EaseCurveTests: XCTestCase {
    func testEaseOutCurve() {
        let c = GoobyWindowHost.glideCurve
        XCTAssertEqual(c.value(at: 0), 0)
        XCTAssertEqual(c.value(at: 1), 1)
        XCTAssertLessThan(c.value(at: 0.1), 0.05, "Gentle start, not a dart")
        XCTAssertGreaterThan(c.value(at: 0.5), 0.7, "Most of the way by half time…")
        XCTAssertGreaterThan(c.value(at: 0.7), 0.9, "…then a long soft settle")
        XCTAssertLessThan(c.value(at: 0.9), 1, "Still easing in near the end")
        var last = 0.0
        for i in 1...100 {
            let v = c.value(at: Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, last - 1e-9, "Never moves backward")
            XCTAssertLessThanOrEqual(v, 1 + 1e-9, "Never overshoots")
            last = v
        }
        let linear = EaseCurve(x1: 0, y1: 0, x2: 1, y2: 1)
        XCTAssertEqual(linear.value(at: 0.3), 0.3, accuracy: 1e-4)
    }
}

final class PeekPlacementTests: XCTestCase {
    let canvas = CGSize(width: 112, height: 102)
    // 1512 × 982 laptop, menu bar 33 pt, Dock at the bottom (visible frame starts at y 70).
    let laptop = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))

    func testNearestSideAtAboutTheSameHeight() {
        let right = PeekPlacement.place(canvas: canvas, near: CGPoint(x: 1300, y: 400), screens: [laptop])
        XCTAssertEqual(right?.edge, .right)
        XCTAssertEqual(right?.origin, CGPoint(x: 1456, y: 349), "Half the panel past the edge")
        let left = PeekPlacement.place(canvas: canvas, near: CGPoint(x: 200, y: 20), screens: [laptop])
        XCTAssertEqual(left?.edge, .left)
        XCTAssertEqual(left?.origin, CGPoint(x: -56, y: 70), "Half past the left edge, kept above the Dock")
    }

    func testNeverTheDocksSide() {
        let dockRight = ScreenInfo(frame: laptop.frame, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 949))
        XCTAssertEqual(PeekPlacement.dockSide(dockRight), .right)
        XCTAssertEqual(PeekPlacement.place(canvas: canvas, near: CGPoint(x: 1400, y: 400), screens: [dockRight])?.edge, .left)
        XCTAssertNil(PeekPlacement.dockSide(laptop), "Bottom Dock doesn't block a side")
    }

    func testNeverAnEdgeSharedWithAnotherDisplay() {
        let external = ScreenInfo(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1047))
        let spot = PeekPlacement.place(canvas: canvas, near: CGPoint(x: 1450, y: 400), screens: [laptop, external])
        XCTAssertEqual(spot?.edge, .left, "Right edge of the laptop touches the external display")
        XCTAssertTrue(PeekPlacement.touchesAnotherScreen(.right, of: laptop, screens: [laptop, external]))
        XCTAssertFalse(PeekPlacement.touchesAnotherScreen(.left, of: laptop, screens: [laptop, external]))
        XCTAssertNil(PeekPlacement.place(canvas: canvas, near: .zero, screens: []))
    }
}

@MainActor
final class PeekingFollowerTests: XCTestCase {
    var front: (String?, pid_t?) = ("com.apple.Terminal", 7)
    var windows: [WindowSnapshot] = [WindowSnapshot(ownerPID: 7, layer: 0, bounds: CGRect(x: 100, y: 200, width: 800, height: 500), alpha: 1, number: 11)]
    var tab: FrontTabStatus = .claude(project: "Gooby")

    func makeFollower(_ p: FakePresenter) -> TerminalFollower {
        TerminalFollower(presenter: p, environment: .init(
            frontmost: { [unowned self] in (self.front.0, self.front.1) },
            windows: { [unowned self] in self.windows },
            screens: { [CGRect(x: 0, y: 0, width: 1512, height: 944)] },
            primaryScreenHeight: { 982 },
            frontTab: { [unowned self] _ in self.tab }
        ), peeksWhenAway: true)
    }

    func testPeeksWhenAwayAndGlidesBack() {
        let p = FakePresenter(); let f = makeFollower(p)
        f.tick()                                   // beside the Claude chat
        front = ("com.google.Chrome", 9)
        f.tick(); f.tick()                         // another app: peek once (no repeat)
        XCTAssertEqual(f.peeking, .right)
        front = ("com.apple.Terminal", 7)
        f.tick()                                   // back to the chat: glide
        XCTAssertEqual(p.events, ["present 900,282", "peek right 1456,282", "present 900,282"])
        XCTAssertEqual(p.glides, [false, true, true])
        XCTAssertNil(f.peeking)
    }

    func testPlainShellTabAlsoPeeks() {
        let p = FakePresenter(); let f = makeFollower(p)
        f.tick()
        tab = .notClaude
        f.tick()
        XCTAssertEqual(p.events.last, "peek right 1456,282")
    }

    func testDoubleClickHidesUntilAClaudeChatIsInFront() {
        let p = FakePresenter(); let f = makeFollower(p)
        f.tick()
        front = ("com.google.Chrome", 9)
        f.tick()
        f.hideUntilClaudeReturns()
        XCTAssertEqual(p.events.last, "conceal")
        front = ("com.apple.finder", 3)
        f.tick()                                   // another non-Claude app: still hidden
        XCTAssertEqual(p.events.last, "conceal")
        XCTAssertTrue(f.hiddenByUser)
        front = ("com.apple.Terminal", 7)
        f.tick()                                   // Claude chat in front: back, and hiding ends
        XCTAssertEqual(p.events.last, "present 900,282")
        XCTAssertFalse(f.hiddenByUser)
        front = ("com.google.Chrome", 9)
        f.tick()                                   // away again: peeks again
        XCTAssertEqual(p.events.last, "peek right 1456,282")
    }

    func testDoubleClickOnlyCountsWhilePeeking() {
        let p = FakePresenter(); let f = makeFollower(p)
        f.tick()
        f.hideUntilClaudeReturns()                 // beside a chat: ignored (clicks are for the rain)
        XCTAssertFalse(f.hiddenByUser)
        XCTAssertEqual(p.events, ["present 900,282"])
    }

    func testFirstLaunchAwayPeeksWithoutGliding() {
        let p = FakePresenter(); let f = makeFollower(p)
        front = ("com.google.Chrome", 9)
        f.tick()
        XCTAssertEqual(p.glides, [false], "Fades in at the edge")
        XCTAssertEqual(p.events.first?.hasPrefix("peek right"), true)
    }
}

final class GazeTests: XCTestCase {
    func testLooksTowardTheCursorWeakerWhenClose() {
        let eye = CGPoint(x: 100, y: 100)
        let far = GoobyWindowHost.gaze(from: eye, to: CGPoint(x: 100, y: 600))
        XCTAssertEqual(far.dx, 0, accuracy: 1e-6)
        XCTAssertEqual(far.dy, -1, accuracy: 1e-6, "Cursor above (AppKit y up) = look up (drawing y down)")
        let near = GoobyWindowHost.gaze(from: eye, to: CGPoint(x: 145, y: 100))
        XCTAssertEqual(near.dx, 0.5, accuracy: 1e-6, "45 pt away: half strength")
        XCTAssertEqual(GoobyWindowHost.gaze(from: eye, to: eye), .zero)
        // Peeking at the right edge of a 1512-wide screen: panel at x 1456 (half past the edge).
        let rightEdge = GoobyWindowHost.peekEyePoint(panel: CGRect(x: 1456, y: 300, width: 112, height: 102), edge: .right)
        XCTAssertLessThan(rightEdge.x, 1512, "Eyes on screen…")
        XCTAssertGreaterThan(rightEdge.x, 1504, "…just inside the edge")
        XCTAssertEqual(rightEdge.y, 351)
        let leftEdge = GoobyWindowHost.peekEyePoint(panel: CGRect(x: -56, y: 300, width: 112, height: 102), edge: .left)
        XCTAssertGreaterThan(leftEdge.x, 0)
        XCTAssertLessThan(leftEdge.x, 8)
    }

    func testRotatedFaceLooksTheRightWay() {
        // Right edge, head turned -90°: looking left (into the screen) = toward the top of the head.
        XCTAssertEqual(GoobyPeekView.localGaze(CGVector(dx: -1, dy: 0), edge: .right), CGVector(dx: 0, dy: -1))
        // Looking up on screen = toward the face's own -x.
        XCTAssertEqual(GoobyPeekView.localGaze(CGVector(dx: 0, dy: -1), edge: .right), CGVector(dx: 1, dy: 0))
        // Left edge is mirrored: looking right (into the screen) = toward the top of the head too.
        XCTAssertEqual(GoobyPeekView.localGaze(CGVector(dx: 1, dy: 0), edge: .left), CGVector(dx: 0, dy: -1))
    }
}

final class GlideDurationTests: XCTestCase {
    func testLongerTripsTakeLongerWithinBounds() {
        XCTAssertEqual(GoobyWindowHost.glideDuration(distance: 0), GoobyWindowHost.minGlideDuration)
        XCTAssertEqual(GoobyWindowHost.glideDuration(distance: 600), 0.875, accuracy: 1e-9)
        XCTAssertEqual(GoobyWindowHost.glideDuration(distance: 5000), GoobyWindowHost.maxGlideDuration)
    }
}

@MainActor
final class PeekArrivalTests: XCTestCase {
    func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testOneGlideTurnsIntoThePeekWithoutAPause() {
        let host = GoobyWindowHost(visibleFrame: { nil }, onClose: {}, reduceMotion: { false })
        let panel = host.prepare()
        host.present(at: CGPoint(x: 600, y: 300), animated: false)
        spin(0.3)
        host.peek(at: CGPoint(x: 1400, y: 300), edge: .right, animated: true)
        let trip = GoobyWindowHost.glideDuration(distance: 800)
        spin(trip * 0.25)
        XCTAssertNil(host.controls.peekEdge, "Not peeking yet")
        XCTAssertEqual(host.controls.peekMorph?.progress, 0, "Whole for the first part of the glide")
        spin(trip * 0.45)
        let mid = host.controls.peekMorph?.progress ?? 0
        XCTAssertGreaterThan(mid, 0, "Turning on the way…")
        XCTAssertLessThan(mid, 1)
        spin(trip * 0.3 + 0.15)
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 1400, y: 300))
        XCTAssertEqual(host.controls.peekEdge, .right, "…peeking the moment it arrives")
        XCTAssertNil(host.controls.peekMorph)
        XCTAssertTrue(host.controls.peekArrivedByGlide, "No extra slide-out afterwards")
        XCTAssertNil(host.pendingPeek)
        host.tearDown()
    }

    func testMorphTimingStartsPartWayAndFinishesOnArrival() {
        XCTAssertEqual(GoobyWindowHost.morphProgress(glideProgress: 0), 0)
        XCTAssertEqual(GoobyWindowHost.morphProgress(glideProgress: GoobyVisualMetrics.peekMorphStart), 0)
        XCTAssertEqual(GoobyWindowHost.morphProgress(glideProgress: 0.7), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GoobyWindowHost.morphProgress(glideProgress: 1), 1)
    }

    func testClaudeChatBackMidGlideCancelsThePeek() {
        let host = GoobyWindowHost(visibleFrame: { nil }, onClose: {}, reduceMotion: { false })
        host.prepare()
        host.present(at: CGPoint(x: 600, y: 300), animated: false)
        spin(0.3)
        host.peek(at: CGPoint(x: 1400, y: 300), edge: .right, animated: true)
        spin(0.5)
        let before = host.controls.peekMorph?.progress ?? 0
        host.present(at: CGPoint(x: 600, y: 300), animated: true) // back to the chat
        XCTAssertLessThanOrEqual(host.controls.peekMorph?.progress ?? 0, before, "Turns back from where it was (no snap)")
        spin(GoobyWindowHost.maxGlideDuration + 0.3)
        XCTAssertNil(host.controls.peekEdge)
        XCTAssertNil(host.controls.peekMorph)
        XCTAssertNil(host.pendingPeek)
        host.tearDown()
    }

    func testReduceMotionPeeksAtOnce() {
        let host = GoobyWindowHost(visibleFrame: { nil }, onClose: {}, reduceMotion: { true })
        host.prepare()
        host.present(at: CGPoint(x: 600, y: 300), animated: false)
        host.peek(at: CGPoint(x: 1400, y: 300), edge: .right, animated: true)
        XCTAssertEqual(host.controls.peekEdge, .right)
        host.tearDown()
    }
}

@MainActor
final class PeekPanelTests: XCTestCase {
    func testPanelMayHangHalfPastTheScreenEdge() throws {
        let panel = NonActivatingGoobyPanel(contentRect: NSRect(x: 0, y: 0, width: 112, height: 102))
        let screen = try XCTUnwrap(NSScreen.main)
        let past = NSRect(x: screen.frame.maxX - 56, y: 200, width: 112, height: 102)
        XCTAssertEqual(panel.constrainFrameRect(past, to: screen), past, "Not pushed back onto the screen")
        panel.setFrameOrigin(past.origin)
        XCTAssertEqual(panel.frame.origin, past.origin)
        panel.close()
    }

    func testPeekMathShowsHalfTheTurnedHead() {
        let m = GoobyVisualMetrics.self
        // Right edge: from the panel's left side to the screen edge = canvas half - head half + shown.
        XCTAssertEqual(m.peekRightEdgeInset, 56, accuracy: 1e-9)
        XCTAssertEqual(m.peekLeftEdgeOffset, -56, accuracy: 1e-9)
        XCTAssertEqual(m.peekShownOnScreen, 96 * 0.82 * 0.7 * 0.5, accuracy: 1e-9)
    }
}

@MainActor
final class DragTests: XCTestCase {
    var front: (String?, pid_t?) = ("com.apple.Terminal", 7)
    var windows: [WindowSnapshot] = [WindowSnapshot(ownerPID: 7, layer: 0, bounds: CGRect(x: 100, y: 200, width: 800, height: 500), alpha: 1, number: 11)]

    func makeFollower(_ p: FakePresenter) -> TerminalFollower {
        TerminalFollower(presenter: p, environment: .init(
            frontmost: { [unowned self] in (self.front.0, self.front.1) },
            windows: { [unowned self] in self.windows },
            screens: { [CGRect(x: 0, y: 0, width: 1512, height: 944)] },
            primaryScreenHeight: { 982 },
            frontTab: { _ in .claude(project: "Gooby") }
        ), peeksWhenAway: true)
    }

    func testNoDraggingBesideAChat() {
        let p = FakePresenter(); let f = makeFollower(p)
        f.tick()
        f.userDragBegan()
        XCTAssertFalse(f.isBeingDragged, "Beside a chat Gooby can't be dragged")
        f.userDragEnded(at: CGPoint(x: 300, y: 500))
        XCTAssertNil(f.userPeekFraction)
    }

    func testDraggingThePeekSetsItsHeightForLaterPeeks() {
        let p = FakePresenter(); let f = makeFollower(p)
        f.tick()
        front = ("com.google.Chrome", 9)
        f.tick()
        XCTAssertEqual(p.events.last, "peek right 1456,282")
        f.userDragBegan()
        XCTAssertTrue(f.isBeingDragged)
        f.tick()                                         // dragging: hands off
        f.userDragEnded(at: CGPoint(x: 1456, y: 600))
        f.tick()                                         // stays where dropped
        XCTAssertEqual(p.events.last, "peek right 1456,282", "No move after the drop")
        XCTAssertEqual(f.userPeekFraction ?? -1, 600.0 / 842.0, accuracy: 1e-9, "Saved as a fraction of the usable height")
        front = ("com.apple.Terminal", 7)
        f.tick()                                         // back to the chat: usual spot
        XCTAssertEqual(p.events.last, "present 900,282")
        front = ("com.google.Chrome", 9)
        f.tick()                                         // next peek: at the height the user chose
        XCTAssertEqual(p.events.last, "peek right 1456,600")
    }

    func testDragThresholdAndFollowMath() {
        XCTAssertFalse(GoobyHostingView.isDrag(from: .zero, to: CGPoint(x: 2, y: 2)), "2.8 pt: still a click")
        XCTAssertTrue(GoobyHostingView.isDrag(from: .zero, to: CGPoint(x: 3, y: 0)))
        let lane = CGRect(x: 0, y: 70, width: 1512, height: 879)
        // Straight up/down only (x fixed), following the cursor.
        XCTAssertEqual(GoobyHostingView.peekDraggedOrigin(start: CGPoint(x: 1456, y: 282), from: CGPoint(x: 1500, y: 330),
                                                          to: CGPoint(x: 1300, y: 530), height: 102, lane: lane),
                       CGPoint(x: 1456, y: 482))
        XCTAssertEqual(GoobyHostingView.peekDraggedOrigin(start: CGPoint(x: 1456, y: 282), from: CGPoint(x: 1500, y: 330),
                                                          to: CGPoint(x: 1500, y: 5000), height: 102, lane: lane).y,
                       847, "Not above the menu bar")
        XCTAssertEqual(GoobyHostingView.peekDraggedOrigin(start: CGPoint(x: 1456, y: 282), from: CGPoint(x: 1500, y: 330),
                                                          to: CGPoint(x: 1500, y: -900), height: 102, lane: lane).y,
                       70, "Not into the Dock area")
    }
}

@MainActor
final class PeekHeightPersistenceTests: XCTestCase {
    func testChosenHeightSurvivesARelaunch() {
        let store = InMemoryPeekHeight()
        var front: (String?, pid_t?) = ("com.google.Chrome", 9)
        func follower() -> TerminalFollower {
            TerminalFollower(presenter: FakePresenter(), environment: .init(
                frontmost: { (front.0, front.1) },
                windows: { [] },
                screens: { [CGRect(x: 0, y: 0, width: 1512, height: 944)] },
                primaryScreenHeight: { 982 }
            ), peeksWhenAway: true, peekHeight: store)
        }
        let first = follower()
        first.tick()
        first.userDragBegan()
        first.userDragEnded(at: CGPoint(x: 1456, y: 421))
        XCTAssertEqual(store.fraction ?? -1, 0.5, accuracy: 1e-9)

        let p = FakePresenter()
        let relaunched = TerminalFollower(presenter: p, environment: .init(
            frontmost: { (front.0, front.1) },
            windows: { [] },
            screens: { [CGRect(x: 0, y: 0, width: 1512, height: 944)] },
            primaryScreenHeight: { 982 }
        ), peeksWhenAway: true, peekHeight: store)
        relaunched.tick()
        XCTAssertEqual(p.events.first, "peek right 1456,421", "Peeks at the saved height after a relaunch")
        _ = front
    }

    func testFractionFitsAnotherScreen() {
        let small = CGRect(x: 0, y: 70, width: 1512, height: 879)
        let big = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let f = PeekPlacement.fraction(ofOriginY: 70 + (879 - 102) * 0.25, height: 102, in: small)
        XCTAssertEqual(f, 0.25, accuracy: 1e-9)
        XCTAssertEqual(PeekPlacement.originY(forFraction: f, height: 102, in: big), (1415 - 102) * 0.25, accuracy: 1e-9)
        XCTAssertEqual(PeekPlacement.originY(forFraction: 7, height: 102, in: small), 70 + 879 - 102, "Clamped")
    }

    func testUserDefaultsStore() throws {
        let suite = "gooby-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPeekHeight(defaults: defaults)
        XCTAssertNil(store.fraction, "Nothing saved yet")
        store.fraction = 0.3
        XCTAssertEqual(UserDefaultsPeekHeight(defaults: defaults).fraction ?? -1, 0.3, accuracy: 1e-9)
        store.fraction = 2
        XCTAssertEqual(store.fraction, 1, "Clamped")
        store.fraction = nil
        XCTAssertNil(store.fraction)
    }
}

@MainActor
final class PeekReturnTests: XCTestCase {
    func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func peekingHost(reduceMotion: Bool = false) -> (GoobyWindowHost, NSPanel) {
        let host = GoobyWindowHost(visibleFrame: { nil }, onClose: {}, reduceMotion: { reduceMotion })
        let panel = host.prepare()
        host.peek(at: CGPoint(x: 1456, y: 300), edge: .right, animated: false) // fade in already peeking
        spin(0.3)
        return (host, panel)
    }

    func testReturnTurnsUprightWhileGlidingOut() {
        let (host, panel) = peekingHost()
        XCTAssertEqual(host.controls.peekEdge, .right)
        host.present(at: CGPoint(x: 900, y: 282), animated: true)
        XCTAssertNil(host.controls.peekEdge)
        XCTAssertEqual(host.controls.peekMorph?.progress, 1, "Starts in the peek pose, not cut in half upright")
        let trip = GoobyWindowHost.glideDuration(distance: 556)
        spin(trip * 0.3)
        let mid = host.controls.peekMorph?.progress ?? -1
        XCTAssertGreaterThan(mid, 0, "Turning back…")
        XCTAssertLessThan(mid, 1)
        spin(trip * 0.45)
        XCTAssertEqual(host.controls.peekMorph?.progress ?? 0, 0, accuracy: 1e-9, "Upright for the rest of the way")
        spin(trip * 0.25 + 0.15)
        XCTAssertNil(host.controls.peekMorph, "Plain standing Gooby on arrival")
        XCTAssertEqual(panel.frame.origin, CGPoint(x: 900, y: 282))
        host.tearDown()
    }

    func testChangingCourseMidTurnContinuesFromThePose() {
        let (host, _) = peekingHost()
        host.present(at: CGPoint(x: 900, y: 282), animated: true)
        spin(0.25)
        let partway = host.controls.peekMorph?.progress ?? -1
        XCTAssertGreaterThan(partway, 0)
        XCTAssertLessThan(partway, 1)
        host.peek(at: CGPoint(x: 1456, y: 300), edge: .right, animated: true) // away again
        XCTAssertEqual(host.controls.peekMorph?.progress ?? -1, partway, accuracy: 1e-9, "No snap back to upright")
        spin(GoobyWindowHost.maxGlideDuration + 0.3)
        XCTAssertEqual(host.controls.peekEdge, .right)
        host.tearDown()
    }

    func testReturnTimingIsTheMirror() {
        XCTAssertEqual(GoobyWindowHost.returnProgress(glideProgress: 0), 0)
        XCTAssertEqual(GoobyWindowHost.returnProgress(glideProgress: 0.3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GoobyWindowHost.returnProgress(glideProgress: GoobyVisualMetrics.peekMorphReturnEnd), 1)
        XCTAssertEqual(GoobyWindowHost.returnProgress(glideProgress: 1), 1)
    }

    func testReduceMotionReturnsAtOnce() {
        let (host, _) = peekingHost(reduceMotion: true)
        host.present(at: CGPoint(x: 900, y: 282), animated: true)
        XCTAssertNil(host.controls.peekMorph)
        XCTAssertNil(host.controls.peekEdge)
        host.tearDown()
    }
}
