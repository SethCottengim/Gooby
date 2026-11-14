import XCTest
@testable import Gooby

final class SingleInstanceTests: XCTestCase {
    typealias I = GoobyApplicationDelegate.InstanceInfo
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testAloneDoesNotYield() {
        let me = I(pid: 50, launchDate: t0)
        XCTAssertFalse(GoobyApplicationDelegate.shouldYield(current: me, others: []))
        XCTAssertFalse(GoobyApplicationDelegate.shouldYield(current: me, others: [me]), "Self is ignored")
    }

    func testNewerLaunchYieldsToOlder() {
        let older = I(pid: 90, launchDate: t0)
        let newer = I(pid: 40, launchDate: t0.addingTimeInterval(5))
        XCTAssertTrue(GoobyApplicationDelegate.shouldYield(current: newer, others: [older, newer]))
        XCTAssertFalse(GoobyApplicationDelegate.shouldYield(current: older, others: [older, newer]))
    }

    func testSimultaneousLaunchKeepsExactlyOne() {
        let a = I(pid: 10, launchDate: t0), b = I(pid: 11, launchDate: t0)
        let all = [a, b]
        let survivors = all.filter { !GoobyApplicationDelegate.shouldYield(current: $0, others: all) }
        XCTAssertEqual(survivors, [a])
    }

    func testMissingLaunchDatesFallBackToPid() {
        let a = I(pid: 10, launchDate: nil), b = I(pid: 11, launchDate: t0)
        let all = [a, b]
        XCTAssertEqual(all.filter { !GoobyApplicationDelegate.shouldYield(current: $0, others: all) }, [a])
    }
}
