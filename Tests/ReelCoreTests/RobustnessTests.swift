import XCTest
@testable import ReelCore

final class RobustnessTests: XCTestCase {
    func strip(_ ids: [WindowID]) -> Strip {
        var s = Strip()
        for id in ids { s.insert(id, width: .proportion(0.5), at: .rightOfFocused, focus: true) }
        return s
    }

    /// A pinned stack whose bottom window closes used to keep its row index past the end, and
    /// popping out of it after unpinning crashed.
    func testClosingTheActiveWindowOfAPinnedStack() {
        var s = strip([1, 2, 3, 4])
        _ = s.focusColumn(1)
        XCTAssertTrue(s.stackInto(.left))
        _ = s.focusColumn(1)
        XCTAssertTrue(s.stackInto(.left))
        // Column 0 is now [1, 2, 3] with 3 active.
        XCTAssertEqual(s.columns[0].windows, [1, 2, 3])
        XCTAssertEqual(s.columns[0].active, 2)
        _ = s.focusColumn(0)
        XCTAssertTrue(s.togglePin(.left))
        XCTAssertTrue(s.remove(3))
        XCTAssertEqual(s.pinned[.left]?.windows, [1, 2])
        XCTAssertEqual(s.pinned[.left]?.active, 1)
        XCTAssertEqual(s.focusedWindow, 2)
        XCTAssertTrue(s.togglePin(.left))
        XCTAssertTrue(s.popOut(.right))
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2], [4]])
    }

    func testRemovingARowAboveTheActiveOneInAPin() {
        var s = strip([1, 2, 3])
        _ = s.focusColumn(1)
        _ = s.stackInto(.left)   // [1, 2], 3
        _ = s.focusColumn(0)
        _ = s.togglePin(.right)
        XCTAssertEqual(s.pinned[.right]?.activeWindow, 2)
        XCTAssertTrue(s.remove(1))
        XCTAssertEqual(s.pinned[.right]?.windows, [2])
        XCTAssertEqual(s.focusedWindow, 2)
    }

    func testConfigClampsValuesThatBreakTheEngine() throws {
        let json = #"{"gap":-20,"outerGap":5000,"springResponse":0,"widthStep":-0.1,"defaultWidth":0,"swipeFingers":7,"tabBarHeight":2,"dimAmount":3}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.gap, 0)
        XCTAssertEqual(c.outerGap, 200)
        XCTAssertGreaterThan(c.springResponse, 0)
        XCTAssertGreaterThan(c.widthStep, 0)
        XCTAssertGreaterThan(c.defaultWidth, 0)
        XCTAssertEqual(c.swipeFingers, 4)
        XCTAssertEqual(c.tabBarHeight, 10)
        XCTAssertEqual(c.dimAmount, 1)
        // A spring at the lowest allowed stiffness still comes to rest.
        var spring = Spring(0, omega: c.springResponse)
        spring.target = 500
        var steps = 0
        while spring.step(1.0 / 60) { steps += 1; if steps > 10_000 { break } }
        XCTAssertLessThan(steps, 10_000)
    }

    func testConfigKeepsValuesInTheSlidersRanges() throws {
        var c = Config()
        c.gap = 48; c.outerGap = 0; c.springResponse = 10; c.widthStep = 0.05; c.pinnedWidth = 0.6
        c.swipeFingers = 0
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }
}
