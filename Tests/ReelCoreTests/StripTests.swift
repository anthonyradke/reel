import CoreGraphics
import XCTest
@testable import ReelCore

final class StripTests: XCTestCase {
    var config = Config()

    override func setUp() {
        config = Config()
        config.gap = 10
        config.outerGap = 10
    }

    func ctx(width: Double = 1020, height: Double = 800) -> LayoutContext {
        LayoutContext(area: CGRect(x: 0, y: 0, width: width, height: height), config: config)
    }

    func strip(_ ids: [WindowID], width: Double = 0.5) -> Strip {
        var s = Strip()
        for id in ids { s.insert(id, width: .proportion(width), at: .rightOfFocused, focus: true) }
        return s
    }

    func testNewWindowsOpenRightOfFocusAndKeepWidths() {
        var s = strip([1, 2, 3])
        XCTAssertEqual(s.columns.map { $0.windows }, [[1], [2], [3]])
        _ = s.focusColumn(0)
        s.insert(4, width: .proportion(0.5), at: .rightOfFocused, focus: true)
        XCTAssertEqual(s.columns.map { $0.windows }, [[1], [4], [2], [3]])
        XCTAssertEqual(s.focused, 1)
        let geo = StripGeometry(strip: s, context: ctx())
        // Every column is still half the viewport: (1000 + 10) * 0.5 - 10.
        XCTAssertEqual(Set(geo.widths), [495])
    }

    func testTwoHalvesFillTheScreen() {
        let s = strip([1, 2])
        let r = Layout.compute(s, context: ctx())
        XCTAssertEqual(r.placements[0].frame, CGRect(x: 10, y: 10, width: 495, height: 780))
        XCTAssertEqual(r.placements[1].frame, CGRect(x: 515, y: 10, width: 495, height: 780))
    }

    func testBackgroundWindowDoesNotStealFocus() {
        var s = strip([1, 2])
        _ = s.focusColumn(0)
        s.insert(3, width: .proportion(0.5), at: .end, focus: false)
        XCTAssertEqual(s.focusedWindow, 1)
    }

    func testRemoveFocusesLeftNeighbour() {
        var s = strip([1, 2, 3])
        _ = s.focusColumn(1)
        s.remove(2)
        XCTAssertEqual(s.focusedWindow, 1)
        s.remove(1)
        XCTAssertEqual(s.focusedWindow, 3)
        s.remove(3)
        XCTAssertNil(s.focusedWindow)
        XCTAssertEqual(s.focused, -1)
    }

    func testScrollNeverModeShowsFocusedMinimally() {
        var s = strip([1, 2, 3, 4])
        let geo = StripGeometry(strip: s, context: ctx())
        _ = s.focusColumn(3)
        let off = geo.offset(toShow: 3, from: 0, previous: 0, mode: .never)
        // Column 3 starts at 3 * 505 = 1515 and is 495 wide; the viewport is 1000 wide.
        XCTAssertEqual(off, 1515 + 495 - 1000)
        XCTAssertEqual(geo.offset(toShow: 0, from: off, previous: 3, mode: .never), 0)
    }

    func testCenterAlways() {
        let s = strip([1, 2, 3])
        let geo = StripGeometry(strip: s, context: ctx())
        XCTAssertEqual(geo.offset(toShow: 1, from: 0, previous: nil, mode: .always), 505 + 247.5 - 500)
    }

    func testCenterOnOverflowCentresWhenBothDontFit() {
        var s = strip([1, 2, 3])
        s.columns[0].width = .proportion(0.75)
        s.columns[1].width = .proportion(0.75)
        let geo = StripGeometry(strip: s, context: ctx())
        let o = geo.offset(toShow: 1, from: 0, previous: 0, mode: .onOverflow)
        XCTAssertEqual(o, geo.clampOffset(geo.starts[1] + geo.widths[1] / 2 - 500))
    }

    func testOffscreenColumnsAreHidden() {
        var s = strip([1, 2, 3, 4])
        s.viewOffset = 0
        let r = Layout.compute(s, context: ctx())
        XCTAssertTrue(r.placements[0].visible)
        XCTAssertTrue(r.placements[1].visible)
        XCTAssertFalse(r.placements[2].visible)
        XCTAssertEqual(r.placements[2].hiddenSide, .right)
    }

    func testNeighbourDisplaySnapsFlush() {
        var s = strip([1, 2, 3])
        s.columns[0].width = .proportion(0.7)
        var c = ctx()
        c.neighborRight = true
        let r = Layout.compute(s, context: c)
        // Column 2 starts at 10 + 0.7 col + gap and would hang over the right edge by less than half.
        let p = r.placements[1]
        if p.visible {
            XCTAssertLessThanOrEqual(p.frame.maxX, 1010)
        }
    }

    func testCycleWidth() {
        var s = strip([1])
        let presets = [1.0 / 3, 0.5, 2.0 / 3]
        _ = s.cycleWidth(presets: presets, forward: true, viewportWidth: 1000, gap: 10)
        XCTAssertEqual(s.columns[0].width, .proportion(2.0 / 3))
        _ = s.cycleWidth(presets: presets, forward: true, viewportWidth: 1000, gap: 10)
        XCTAssertEqual(s.columns[0].width, .proportion(1.0 / 3))
        _ = s.cycleWidth(presets: presets, forward: false, viewportWidth: 1000, gap: 10)
        XCTAssertEqual(s.columns[0].width, .proportion(2.0 / 3))
    }

    func testFullWidthToggleRemembers() {
        var s = strip([1])
        _ = s.toggleFullWidth()
        XCTAssertEqual(s.columns[0].width, .proportion(1))
        _ = s.toggleFullWidth()
        XCTAssertEqual(s.columns[0].width, .proportion(0.5))
    }

    func testStackAndPopOut() {
        var s = strip([1, 2, 3])
        _ = s.focusColumn(1)
        XCTAssertTrue(s.stackInto(.left))
        XCTAssertEqual(s.columns.map { $0.windows }, [[1, 2], [3]])
        XCTAssertEqual(s.focusedWindow, 2)
        XCTAssertTrue(s.focusVertical(-1))
        XCTAssertEqual(s.focusedWindow, 1)
        XCTAssertTrue(s.moveInStack(by: 1))
        XCTAssertEqual(s.columns[0].windows, [2, 1])
        XCTAssertTrue(s.popOut(.right))
        XCTAssertEqual(s.columns.map { $0.windows }, [[2], [1], [3]])
        XCTAssertEqual(s.focusedWindow, 1)
        XCTAssertTrue(s.stackInto(.right))
        XCTAssertEqual(s.columns.map { $0.windows }, [[2], [3, 1]])
        XCTAssertTrue(s.popOut(.left))
        XCTAssertEqual(s.columns.map { $0.windows }, [[2], [1], [3]])
    }

    func testStackLayoutAndHeights() {
        var s = strip([1, 2])
        _ = s.stackInto(.left)
        let r = Layout.compute(s, context: ctx())
        XCTAssertEqual(r.placements[0].frame.height, 385)
        XCTAssertEqual(r.placements[1].frame.minY, 405)
        XCTAssertTrue(s.resizeHeight(by: 0.1))
        let r2 = Layout.compute(s, context: ctx())
        XCTAssertGreaterThan(r2.placements[1].frame.height, r2.placements[0].frame.height)
        XCTAssertTrue(s.equalizeHeights())
        XCTAssertEqual(s.columns[0].weights, [1, 1])
    }

    func testTabbedColumnShowsOneWindow() {
        var s = strip([1, 2])
        _ = s.stackInto(.left)
        _ = s.toggleTabbed()
        let r = Layout.compute(s, context: ctx())
        XCTAssertEqual(r.placements.filter(\.visible).map(\.id), [2])
        XCTAssertEqual(r.tabBars.count, 1)
        XCTAssertEqual(r.tabBars[0].windows, [1, 2])
    }

    func testPinAndUnpin() {
        var s = strip([1, 2, 3])
        _ = s.focusColumn(1)
        XCTAssertTrue(s.togglePin(.left))
        XCTAssertEqual(s.pinned[.left]?.windows, [2])
        XCTAssertEqual(s.columns.map { $0.windows }, [[1], [3]])
        XCTAssertEqual(s.focusedWindow, 2)
        let geo = StripGeometry(strip: s, context: ctx())
        XCTAssertEqual(geo.pinnedFrames[.left]?.minX, 10)
        XCTAssertGreaterThan(geo.viewportMinX, 10)
        // Leaving the pin goes back to where focus was on the strip.
        XCTAssertTrue(s.focusRight())
        XCTAssertEqual(s.focusedWindow, 3)
        XCTAssertTrue(s.focusLeft())
        XCTAssertEqual(s.focusedWindow, 1)
        XCTAssertTrue(s.focusLeft())
        XCTAssertEqual(s.focusedWindow, 2)
        XCTAssertTrue(s.togglePin(.left))
        XCTAssertNil(s.pinned[.left])
        XCTAssertEqual(s.columns.map { $0.windows }, [[2], [1], [3]])
    }

    func testMoveColumns() {
        var s = strip([1, 2, 3])
        _ = s.focusColumn(0)
        XCTAssertTrue(s.moveColumn(by: 1))
        XCTAssertEqual(s.columns.map { $0.windows }, [[2], [1], [3]])
        XCTAssertTrue(s.moveColumn(to: 2))
        XCTAssertEqual(s.columns.map { $0.windows }, [[2], [3], [1]])
        XCTAssertFalse(s.moveColumn(by: 1))
        XCTAssertTrue(s.reorderColumn(from: 0, to: 2))
        XCTAssertEqual(s.columns.map { $0.windows }, [[3], [1], [2]])
        XCTAssertEqual(s.focusedWindow, 1)
    }

    func testMinWidthWidensSpacing() {
        let s = strip([1, 2])
        var c = ctx()
        c.minWidths[1] = 700
        let geo = StripGeometry(strip: s, context: c)
        XCTAssertEqual(geo.starts[1], 710)
    }

    func testKeepOriginalHeight() {
        config.keepOriginalHeight = true
        let s = strip([1])
        var c = ctx()
        c.originalHeights[1] = 300
        let r = Layout.compute(s, context: c)
        XCTAssertEqual(r.placements[0].frame.height, 300)
        XCTAssertEqual(r.placements[0].frame.minY, 10)
    }

    func testSnapColumn() {
        let s = strip([1, 2, 3, 4])
        let geo = StripGeometry(strip: s, context: ctx())
        XCTAssertEqual(geo.snapColumn(forOffset: 480, mode: .never), 1)
        XCTAssertEqual(geo.snapColumn(forOffset: 20, mode: .never), 0)
    }

    func testSpringSettles() {
        var sp = Spring(0)
        sp.target = 100
        var t = 0.0
        while sp.step(1.0 / 120) { t += 1.0 / 120 }
        XCTAssertEqual(sp.value, 100)
        XCTAssertLessThan(t, 1)
    }

    func testCommandNamesRoundTrip() {
        for c in Command.all {
            XCTAssertEqual(Command(name: c.name), c, c.name)
        }
        XCTAssertEqual(Command(name: "scroll:-120"), .scroll(-120))
        // Everything the URL scheme and reelctl document has to parse.
        for name in ["start", "stop", "toggle", "settings", "retile", "show-indicator", "send-to-next-display", "next-display"] {
            XCTAssertNotNil(Command(name: name), name)
        }
    }

    func testConfigDecodesOldFiles() throws {
        let json = #"{"gap": 4, "centerMode": "always"}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(c.gap, 4)
        XCTAssertEqual(c.centerMode, .always)
        XCTAssertEqual(c.bindings, Config.defaultBindings)
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    func testStripCodableWithPins() throws {
        var s = strip([1, 2, 3])
        _ = s.togglePin(.right)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Strip.self, from: data)
        XCTAssertEqual(back, s)
    }

    /// Whatever the strip looks like and wherever it's scrolled, no two windows on screen overlap,
    /// none hangs onto a neighbouring display, and every visible window stays inside the display.
    func testVisibleWindowsNeverOverlap() {
        var rng = SystemRandomNumberGenerator()
        let widths = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.8, 1]
        for _ in 0..<2000 {
            var s = Strip()
            let n = Int.random(in: 1...7, using: &rng)
            var id: WindowID = 1
            for _ in 0..<n {
                s.insert(id, width: .proportion(widths.randomElement(using: &rng)!), at: .end, focus: true)
                id += 1
                if Bool.random(using: &rng), Int.random(in: 0...3, using: &rng) == 0 { _ = s.stackInto(.left) }
            }
            _ = s.focusColumn(Int.random(in: 0..<s.columns.count, using: &rng))
            if s.columns.count > 2, Int.random(in: 0...2, using: &rng) == 0 { _ = s.togglePin(.left) }
            if s.columns.count > 2, Int.random(in: 0...2, using: &rng) == 0 { _ = s.togglePin(.right) }
            var c = ctx()
            c.neighborLeft = Bool.random(using: &rng)
            c.neighborRight = Bool.random(using: &rng)
            let geo = StripGeometry(strip: s, context: c)
            s.viewOffset = Double.random(in: -300...(geo.totalWidth + 300), using: &rng)
            let r = Layout.compute(s, context: c)
            let shown = r.placements.filter(\.visible).map(\.frame)
            for (a, fa) in shown.enumerated() {
                for fb in shown[(a + 1)...] {
                    let i = fa.intersection(fb)
                    XCTAssertTrue(i.isNull || i.width < 1 || i.height < 1, "overlap \(fa) \(fb) in \(s)")
                }
                if c.neighborLeft { XCTAssertGreaterThanOrEqual(fa.minX, -0.5, "hangs left: \(fa)") }
                if c.neighborRight { XCTAssertLessThanOrEqual(fa.maxX, 1020.5, "hangs right: \(fa)") }
                XCTAssertTrue(fa.maxX > 0 && fa.minX < 1020, "visible but off screen: \(fa)")
            }
        }
    }
}
