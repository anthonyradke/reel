import XCTest
@testable import ReelCore

final class CommandTests: XCTestCase {
    func link(_ s: String) -> Command? { Command.fromLink(URL(string: s)!) }

    func testLinksOpenSettingsAndTheIndicator() {
        XCTAssertEqual(link("reel://settings"), .openSettings)
        XCTAssertEqual(link("reel://preferences"), .openSettings)
        XCTAssertEqual(link("reel://show-indicator"), .showIndicator)
        XCTAssertEqual(link("reel://indicator/"), .showIndicator)
        XCTAssertEqual(link("REEL://Settings"), .openSettings)
    }

    func testLinksCannotMoveWindowsOrStopTheEngine() {
        for name in ["focus-right", "move-to-3", "move-left", "cycle-width", "full-width", "pin-left",
                     "toggle-float", "send-to-next-display", "retile", "stop", "start", "toggle",
                     "scroll:200", "stack-left", "pop-out", "move/left"] {
            XCTAssertNil(link("reel://\(name)"), name)
        }
        // Every command a link may run is in the short allowed list.
        let allowed = (Command.all + [.start, .scroll(100)]).filter(\.allowedFromLink)
        XCTAssertEqual(Set(allowed), [.openSettings, .showIndicator])
    }

    func testLinksNeedTheReelScheme() {
        XCTAssertNil(link("https://example.com/settings"))
        XCTAssertNil(link("reel://"))
        XCTAssertNil(link("reel://nonsense"))
    }
}
