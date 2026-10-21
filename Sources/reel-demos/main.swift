import AppKit
import ReelCore

// Renders the animated demos for the README. Every frame comes from the real strip model and
// layout code, stepped with the same spring the app uses, so the motion is Reel's own.
//
//     swift run -c release reel-demos docs

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ name: String, _ script: (Stage) -> Void) {
    let stage = Stage()
    script(stage)
    let url = out.appendingPathComponent("demo-\(name).gif")
    GIF.write(stage.frames, fps: Stage.fps, to: url)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("wrote \(url.path) (\(stage.frames.count) frames, \(size / 1024) KB)")
}

let half = ColumnWidth.proportion(0.5)
let third = ColumnWidth.proportion(1.0 / 3)
let twoThirds = ColumnWidth.proportion(2.0 / 3)

render("scroll") { s in
    s.open([(.notes, half), (.browser, twoThirds), (.code, half), (.terminal, third), (.mail, half)], focus: 0)
    s.say("Every window is a column on one long strip, wider than the screen.", hold: 1.8)
    s.act(["⌃", "⌥", "→"], "Focus the next column. The strip scrolls to keep it in view.", hold: 1.1) { st, _ in st.focusRight() }
    s.act(["⌃", "⌥", "→"], "Focus the next column. The strip scrolls to keep it in view.", hold: 1.1) { st, _ in st.focusRight() }
    s.act(["⌃", "⌥", "→"], "Focus the next column. The strip scrolls to keep it in view.", hold: 1.1) { st, _ in st.focusRight() }
    s.act(["⌃", "⌥", "1"], "Jump straight to a column by number.", hold: 1.6) { st, _ in st.focusColumn(0) }
}

render("widths") { s in
    s.open([(.browser, half), (.code, half), (.notes, half)], focus: 0)
    s.hold(0.8)
    for _ in 0..<3 {
        s.act(["⌃", "⌥", "R"], "Cycle the column through preset widths.", hold: 1.0) { st, geo in
            st.cycleWidth(presets: s.config.sortedPresets, forward: true, viewportWidth: geo.viewportWidth, gap: s.config.gap)
        }
    }
    s.act(["⌃", "⌥", "F"], "Full width, and back.", hold: 1.2) { st, _ in st.toggleFullWidth() }
    s.act(["⌃", "⌥", "F"], "Full width, and back.", hold: 1.4) { st, _ in st.toggleFullWidth() }
}

render("stack") { s in
    s.open([(.code, half), (.terminal, third), (.browser, half)], focus: 1)
    s.hold(0.8)
    s.act(["⌃", "⌥", "["], "Stack the window into the column on its left.", hold: 1.3) { st, _ in st.stackInto(.left) }
    s.act(["⌃", "⌥", "↑"], "Move between the windows in a stack.", hold: 1.0) { st, _ in st.focusVertical(-1) }
    s.act(["⌃", "⌥", "⇧", "T"], "Show the stack as tabs.", hold: 1.4) { st, _ in st.toggleTabbed() }
    s.act(["⌃", "⌥", "⇧", "T"], "Show the stack as tabs.", hold: 0.8) { st, _ in st.toggleTabbed() }
    s.act(["⌃", "⌥", "⇧", "]"], "Take a window back out into its own column.", hold: 1.5) { st, _ in st.popOut(.right) }
}

render("open") { s in
    s.open([(.notes, half), (.browser, half), (.mail, half)], focus: 0)
    s.hold(1.0)
    s.add(.terminal, width: third, caption: "A new window opens beside the focused one. Nothing gets squeezed.", hold: 1.5)
    s.add(.music, width: half, caption: "A new window opens beside the focused one. Nothing gets squeezed.", hold: 1.8)
}

render("swipe") { s in
    s.open([(.browser, half), (.code, half), (.notes, third), (.mail, half), (.music, half)], focus: 0)
    s.hold(0.8)
    s.swipe(by: 900, over: 1.1, caption: "Swipe with three or four fingers. The strip follows them, then settles on a column.")
    s.hold(1.2)
    s.swipe(by: -900, over: 1.0, caption: "Swipe with three or four fingers. The strip follows them, then settles on a column.")
    s.hold(1.3)
}
