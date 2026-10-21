import AppKit
import ReelCore

/// One demo: a strip on a pretend display, stepped frame by frame and drawn into images.
final class Stage {
    static let fps = 25.0
    static let canvas = CGSize(width: 1200, height: 675)
    /// The pretend display, in canvas points. Windows scrolled off it are drawn faintly
    /// outside it, so the rest of the strip stays in the picture.
    static let display = CGRect(x: 230, y: 44, width: 740, height: 462)
    static let menuBar: CGFloat = 16

    var strip = Strip()
    var config = Config()
    private(set) var frames: [CGImage] = []

    private struct Motion {
        var x, y, w, h: Spring
        var alpha: Spring
    }
    private var motion: [WindowID: Motion] = [:]
    private var looks: [WindowID: Look] = [:]
    private var nextID: WindowID = 1
    private var caption: Caption?
    private var captionAge: Double = 0
    private var fingers: Double?
    private let painter = Painter()

    init() {
        config.gap = 8
        config.outerGap = 8
        config.centerMode = .never
    }

    var context: LayoutContext {
        let d = Self.display
        let area = CGRect(x: 0, y: Self.menuBar, width: d.width, height: d.height - Self.menuBar)
        return LayoutContext(area: area, displayFrame: CGRect(origin: .zero, size: d.size), config: config)
    }

    var geometry: StripGeometry { StripGeometry(strip: strip, context: context) }

    // MARK: - Script

    func open(_ windows: [(Look.Kind, ColumnWidth)], focus: Int) {
        for (kind, width) in windows {
            let id = nextID
            nextID += 1
            looks[id] = Look(kind: kind, seed: id)
            strip.insert(id, width: width, at: .end, focus: false)
        }
        strip.focused = focus
        scrollToFocus(previous: nil)
        retarget(animated: false)
    }

    func hold(_ seconds: Double) { run(seconds) }

    func say(_ text: String, hold: Double) {
        show(Caption(keys: [], text: text))
        run(hold)
    }

    /// One key press: the caption changes, the strip changes, and the windows spring to place.
    func act(_ keys: [String], _ text: String, hold: Double, _ change: (inout Strip, StripGeometry) -> Bool) {
        show(Caption(keys: keys, text: text))
        // A beat for the caption to read before anything moves.
        run(0.3)
        let previous = strip.focused
        _ = change(&strip, geometry)
        scrollToFocus(previous: previous)
        retarget(animated: true)
        run(hold)
    }

    func add(_ kind: Look.Kind, width: ColumnWidth, caption text: String, hold: Double) {
        show(Caption(keys: [], text: text))
        run(0.3)
        let id = nextID
        nextID += 1
        looks[id] = Look(kind: kind, seed: id)
        let previous = strip.focused
        strip.insert(id, width: width, at: .rightOfFocused, focus: true)
        scrollToFocus(previous: previous)
        retarget(animated: true)
        run(hold)
    }

    /// Fingers drag the strip by `points`, then let go and it settles on a column, the way the
    /// app's gesture handling does it.
    func swipe(by points: Double, over seconds: Double, caption text: String) {
        show(Caption(keys: [], text: text, trackpad: true))
        run(0.3)
        let geo = geometry
        let start = strip.viewOffset
        let n = Int(seconds * Self.fps)
        var last = start
        var velocity = 0.0
        for i in 1...n {
            // Ease in and out, like a hand.
            let t = Double(i) / Double(n)
            let e = t * t * (3 - 2 * t)
            let next = start + points * e
            velocity = (next - last) * Self.fps
            last = next
            strip.viewOffset = next
            fingers = e
            retarget(animated: false)
            frame()
        }
        fingers = nil
        let projected = Spring.projectedRest(value: strip.viewOffset, velocity: velocity * 0.3, decelerationRate: 0.994)
        if let snap = geo.snapColumn(forOffset: projected, mode: config.centerMode) {
            strip.viewOffset = geo.clampOffset(geo.starts[snap])
            strip.focused = snap
        }
        retarget(animated: true)
    }

    // MARK: - Engine

    private func show(_ c: Caption) {
        if caption != c { captionAge = 0 }
        caption = c
    }

    private func scrollToFocus(previous: Int?) {
        guard strip.columns.indices.contains(strip.focused) else { return }
        strip.viewOffset = geometry.offset(toShow: strip.focused, from: strip.viewOffset, previous: previous, mode: config.centerMode)
    }

    private func retarget(animated: Bool) {
        let result = Layout.compute(strip, context: context)
        for p in result.placements {
            let f = p.frame
            if var m = motion[p.id] {
                m.x.target = f.minX; m.y.target = f.minY; m.w.target = f.width; m.h.target = f.height
                if !animated { m.x.snap(); m.y.snap(); m.w.snap(); m.h.snap() }
                motion[p.id] = m
            } else {
                // New windows fade in where they belong while the others make room.
                var alpha = Spring(animated ? 0 : 1, omega: 14)
                alpha.target = 1
                motion[p.id] = Motion(x: Spring(f.minX), y: Spring(f.minY), w: Spring(f.width), h: Spring(f.height), alpha: alpha)
            }
        }
    }

    private func run(_ seconds: Double) {
        for _ in 0..<Int((seconds * Self.fps).rounded()) { frame() }
    }

    private func frame() {
        let dt = 1 / Self.fps
        let omega = config.springResponse
        for (id, var m) in motion {
            m.x.omega = omega; m.y.omega = omega; m.w.omega = omega; m.h.omega = omega
            m.x.step(dt); m.y.step(dt); m.w.step(dt); m.h.step(dt); m.alpha.step(dt)
            motion[id] = m
        }
        captionAge += dt
        frames.append(painter.paint(scene()))
    }

    private func scene() -> Scene {
        let result = Layout.compute(strip, context: context)
        var hidden = Set<WindowID>()
        for col in strip.columns where col.tabbed {
            for id in col.windows where id != col.activeWindow { hidden.insert(id) }
        }
        let origin = Self.display.origin
        var windows: [Scene.Window] = []
        for col in strip.columns {
            for id in col.windows where !hidden.contains(id) {
                guard let m = motion[id], let look = looks[id] else { continue }
                let rect = CGRect(x: m.x.value + origin.x, y: m.y.value + origin.y, width: m.w.value, height: m.h.value)
                windows.append(Scene.Window(rect: rect, look: look, focused: id == strip.focusedWindow, alpha: m.alpha.value))
            }
        }
        let tabs = result.tabBars.map { bar -> Scene.Tabs in
            // The bar rides along with its column's window.
            let id = bar.windows.indices.contains(bar.active) ? bar.windows[bar.active] : bar.windows[0]
            var frame = bar.frame.offsetBy(dx: origin.x, dy: origin.y)
            if let m = motion[id] { frame.origin.x = m.x.value + origin.x; frame.size.width = m.w.value }
            return Scene.Tabs(frame: frame, titles: bar.windows.compactMap { looks[$0]?.title }, active: bar.active)
        }
        return Scene(windows: windows, tabs: tabs, caption: caption, captionAlpha: min(1, captionAge / 0.2), fingers: fingers)
    }
}

struct Caption: Equatable {
    var keys: [String]
    var text: String
    var trackpad = false
}

struct Scene {
    struct Window {
        var rect: CGRect
        var look: Look
        var focused: Bool
        var alpha: Double
    }
    struct Tabs {
        var frame: CGRect
        var titles: [String]
        var active: Int
    }
    var windows: [Window]
    var tabs: [Tabs]
    var caption: Caption?
    var captionAlpha: Double
    /// Swipe progress 0...1 while fingers are down.
    var fingers: Double?
}
