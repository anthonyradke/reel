import XCTest
@testable import ReelCore

final class SpacesTests: XCTestCase {
    // Two displays with separate Spaces: A shows Space 10, B shows Space 20.
    let separate = SpaceMap.activeKeys(displays: ["A", "B"], perDisplay: ["A": 10, "B": 20], shared: nil)
    // "Displays have separate Spaces" off: macOS reports one Space for both.
    let shared = SpaceMap.activeKeys(displays: ["A", "B"], perDisplay: [:], shared: 5)

    func testActiveKeys() {
        XCTAssertEqual(separate["A"], StripKey(display: "A", space: 10))
        XCTAssertEqual(separate["B"], StripKey(display: "B", space: 20))
        XCTAssertEqual(shared["A"], StripKey(display: "A", space: 5))
        XCTAssertEqual(shared["B"], StripKey(display: "B", space: 5))
        // No SkyLight at all: every display on Space 0, still one strip each.
        let none = SpaceMap.activeKeys(displays: ["A", "B"], perDisplay: [:], shared: nil)
        XCTAssertEqual(Set(none.values), [StripKey(display: "A", space: 0), StripKey(display: "B", space: 0)])
    }

    func testSharedSpaceKeepsWindowsOnTheirOwnDisplay() {
        for _ in 0..<20 {
            XCTAssertEqual(SpaceMap.key(forWindowOn: "B", space: 5, active: shared), shared["B"])
            XCTAssertEqual(SpaceMap.key(forWindowOn: "A", space: 5, active: shared), shared["A"])
        }
    }

    func testWindowOnAnotherDisplaysSpaceGoesThere() {
        // Mostly on A, but Mission Control put it on B's current Space.
        XCTAssertEqual(SpaceMap.key(forWindowOn: "A", space: 20, active: separate), separate["B"])
        // A Space nobody is showing keeps the window on its display's strip for that Space.
        XCTAssertEqual(SpaceMap.key(forWindowOn: "A", space: 99, active: separate), StripKey(display: "A", space: 99))
    }

    func testReassignmentWithSharedSpaceDoesNotTrapOrMove() {
        // Used to build a [space: key] dictionary with uniqueKeysWithValues, which traps when two
        // displays report the same Space.
        XCTAssertNil(SpaceMap.reassignment(of: shared["B"]!, windowSpace: 5, active: shared))
        let none = SpaceMap.activeKeys(displays: ["A", "B", "C"], perDisplay: [:], shared: nil)
        XCTAssertNil(SpaceMap.reassignment(of: none["C"]!, windowSpace: 0, active: none))
    }

    func testReassignmentFollowsMissionControlMoves() {
        let onA = separate["A"]!
        XCTAssertNil(SpaceMap.reassignment(of: onA, windowSpace: 10, active: separate))
        XCTAssertEqual(SpaceMap.reassignment(of: onA, windowSpace: 20, active: separate), separate["B"])
        // Moved to a Space that isn't on screen: stays until that Space is shown.
        XCTAssertNil(SpaceMap.reassignment(of: onA, windowSpace: 30, active: separate))
        // A strip for a Space that is now hidden moves its window to its own display's current one.
        let old = StripKey(display: "A", space: 30)
        XCTAssertEqual(SpaceMap.reassignment(of: old, windowSpace: 10, active: separate), separate["A"])
    }

    func testStripKeyCodableMatchesSessionFiles() throws {
        let json = #"{"display":"ABC","space":42}"#
        let k = try JSONDecoder().decode(StripKey.self, from: Data(json.utf8))
        XCTAssertEqual(k, StripKey(display: "ABC", space: 42))
    }
}
