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
}
