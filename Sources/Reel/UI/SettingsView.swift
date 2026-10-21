import AppKit
import ReelCore
import SwiftUI

/// Live engine facts for the settings window.
final class EngineState: ObservableObject {
    static let shared = EngineState()
    @Published var running = false
    @Published var trusted = AX.isTrusted
    @Published var displays: [Display] = []
    private var timer: Timer?
    /// Set by the snapshot renderer so the pictures show a running engine.
    static var showsAsRunning = false

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let wm = WindowManager.shared
        let r = wm.running || Self.showsAsRunning
        if running != r { running = r }
        let t = AX.isTrusted || Self.showsAsRunning
        if trusted != t { trusted = t }
        let d = Displays.current()
        if d != displays { displays = d }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case layout = "Layout"
    case appearance = "Appearance"
    case input = "Trackpad & Mouse"
    case shortcuts = "Shortcuts"
    case rules = "Window Rules"
    case displays = "Displays"
    case setup = "Mac Setup"
    case automation = "Automation"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .layout: return "rectangle.split.3x1"
        case .appearance: return "paintbrush"
        case .input: return "hand.draw"
        case .shortcuts: return "keyboard"
        case .rules: return "list.bullet.rectangle"
        case .displays: return "display"
        case .setup: return "checklist"
        case .automation: return "terminal"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineState
    @State private var page: SettingsPage?
    /// Room above the sidebar for traffic lights, when rendered outside a real window.
    private let titleBarInset: CGFloat

    init(page: SettingsPage = .general, titleBarInset: CGFloat = 0) {
        _page = State(initialValue: page)
        self.titleBarInset = titleBarInset
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .top) { Color.clear.frame(height: titleBarInset) }
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch page ?? .general {
                    case .general: GeneralPage()
                    case .layout: LayoutPage()
                    case .appearance: AppearancePage()
                    case .input: InputPage()
                    case .shortcuts: ShortcutsPage()
                    case .rules: RulesPage()
                    case .displays: DisplaysPage()
                    case .setup: MacSetupPage()
                    case .automation: AutomationPage()
                    case .about: AboutPage()
                    }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle((page ?? .general).rawValue)
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            Circle().fill(engine.running ? Color.green : (engine.trusted ? Color.orange : Color.red)).frame(width: 8, height: 8)
            Text(engine.running ? "Running" : (engine.trusted ? "Stopped" : "Needs permission"))
                .font(.callout)
            Spacer()
            Button(engine.running ? "Stop" : "Start") {
                if engine.running { WindowManager.shared.stop() } else { AppDelegate.shared?.startWhenTrusted() }
                engine.refresh()
            }
            .controlSize(.small)
        }
        .padding(12)
    }
}

// MARK: - Building blocks

struct Section<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { "\(Int($0)) px" }

    var body: some View {
        HStack {
            Text(title).frame(width: 170, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(format(value)).monospacedDigit().frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
        }
    }
}

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

// MARK: - Pages

struct GeneralPage: View {
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineState

    var body: some View {
        if !engine.trusted {
            Section(title: "Permission needed") {
                Text("Reel moves windows through the Accessibility API, so macOS needs your OK first. It's the only permission Reel asks for, and nothing leaves your Mac.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings") {
                    AX.promptForTrust()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
        Section(title: "Startup") {
            Toggle("Launch Reel at login", isOn: $store.config.launchAtLogin)
            Toggle("Start tiling as soon as Reel opens", isOn: $store.config.startOnLaunch)
            Toggle("Bring back the strip after a restart", isOn: $store.config.restoreSession)
        }
        Section(title: "New windows") {
            Picker("Open new windows", selection: $store.config.newWindowPlacement) {
                ForEach(NewWindowPlacement.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Float windows that can't be resized (like Calculator)", isOn: $store.config.floatFixedSizeWindows)
        }
        Section(title: "Strip indicator", footer: "Hold ⌃⌥ to keep the indicator up, click a tile to jump to that window, or drag a tile to reorder the strip.") {
            Toggle("Show the strip indicator while moving around", isOn: $store.config.showIndicator)
        }
        Section(title: "Need a hand?") {
            HStack {
                Button("Show the Welcome Tour") { AppDelegate.shared?.showOnboarding() }
                Button("Re-tile Everything") { WindowManager.shared.perform(.retile) }
            }
        }
    }
}

struct LayoutPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var newPreset = 0.75

    var body: some View {
        Section(title: "Gaps") {
            SliderRow(title: "Between windows", value: $store.config.gap, range: 0...48)
            SliderRow(title: "At the screen edges", value: $store.config.outerGap, range: 0...48)
            Toggle("Keep windows clear of the Dock", isOn: $store.config.respectDock)
        }
        Section(title: "Widths", footer: "Cycle width steps through these. Wider and narrower change the width by the step.") {
            SliderRow(title: "New windows open at", value: $store.config.defaultWidth, range: 0.2...1, step: 0.05, format: percent)
            SliderRow(title: "Wider / narrower step", value: $store.config.widthStep, range: 0.05...0.25, step: 0.05, format: percent)
            HStack(alignment: .center) {
                Text("Preset widths").frame(width: 170, alignment: .leading)
                ForEach(store.config.sortedPresets, id: \.self) { p in
                    HStack(spacing: 2) {
                        Text(percent(p)).monospacedDigit()
                        Button {
                            store.config.presetWidths.removeAll { abs($0 - p) < 0.001 }
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
            }
            HStack {
                Text("").frame(width: 170)
                Stepper(value: $newPreset, in: 0.1...1, step: 0.05) {
                    Text("Add \(percent(newPreset))").monospacedDigit()
                }
                Button("Add") {
                    if !store.config.presetWidths.contains(where: { abs($0 - newPreset) < 0.001 }) {
                        store.config.presetWidths.append(newPreset)
                    }
                }
                Button("Reset") { store.config.presetWidths = Config().presetWidths }
            }
        }
        Section(title: "Scrolling") {
            Picker("Centre the focused column", selection: $store.config.centerMode) {
                ForEach(CenterMode.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Animate", isOn: $store.config.animate)
            SliderRow(title: "Animation speed", value: $store.config.springResponse, range: 10...40, step: 1, format: { v in
                v < 16 ? "Gentle" : (v < 26 ? "Normal" : "Snappy")
            })
            .disabled(!store.config.animate)
        }
        Section(title: "Heights and pins") {
            Toggle("Keep original height (top-aligned) instead of filling the screen", isOn: $store.config.keepOriginalHeight)
            SliderRow(title: "Pinned column width", value: $store.config.pinnedWidth, range: 0.2...0.6, step: 0.05, format: percent)
        }
    }
}

struct AppearancePage: View {
    @EnvironmentObject var store: ConfigStore

    private var borderColor: Binding<Color> {
        Binding(get: {
            let c = store.config.focusBorderColor
            return Color(nsColor: NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a))
        }, set: { color in
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
            store.config.focusBorderColor = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
        })
    }

    var body: some View {
        Section(title: "Focus border") {
            Toggle("Draw a border around the focused window", isOn: $store.config.focusBorder)
            Group {
                ColorPicker("Colour", selection: borderColor)
                SliderRow(title: "Thickness", value: $store.config.focusBorderWidth, range: 1...10)
                SliderRow(title: "Corner radius", value: $store.config.focusBorderRadius, range: 0...20)
            }
            .disabled(!store.config.focusBorder)
        }
        Section(title: "Dimming") {
            Toggle("Dim windows that aren't focused", isOn: $store.config.dimInactive)
            SliderRow(title: "Amount", value: $store.config.dimAmount, range: 0.05...0.6, step: 0.05, format: percent)
                .disabled(!store.config.dimInactive)
        }
        Section(title: "Tabbed columns") {
            SliderRow(title: "Tab bar height", value: $store.config.tabBarHeight, range: 20...40)
        }
    }
}

struct InputPage: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        Section(title: "Swipe to scroll the strip", footer: "macOS acts on every swipe too. If a swipe also switches desktops, see Mac Setup.") {
            Picker("Fingers", selection: $store.config.swipeFingers) {
                Text("Off").tag(0)
                Text("3 fingers").tag(3)
                Text("4 fingers").tag(4)
            }
            .pickerStyle(.segmented)
            Toggle("Natural direction (the strip follows your fingers)", isOn: $store.config.naturalSwipe)
            SliderRow(title: "Sensitivity", value: $store.config.swipeSensitivity, range: 0.4...2.5, step: 0.1, format: { String(format: "%.1f×", $0) })
            Toggle("Smooth swipe (moves pictures of the windows, needs Screen Recording)", isOn: $store.config.smoothSwipe)
        }
        Section(title: "Mouse") {
            Toggle("Focus follows mouse", isOn: $store.config.focusFollowsMouse)
            Toggle("Mouse follows focus", isOn: $store.config.mouseFollowsFocus)
            Toggle("Drag a window onto another column to reorder", isOn: $store.config.dragToReorder)
        }
    }
}

struct DisplaysPage: View {
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineState

    var body: some View {
        Section(title: "Managed displays", footer: "Switch Reel off for a display and its windows stay exactly where you put them. Handy for a presentation screen or a portrait monitor.") {
            ForEach(engine.displays, id: \.uuid) { d in
                Toggle(isOn: Binding(get: { !store.config.disabledDisplays.contains(d.uuid) }, set: { on in
                    store.config.disabledDisplays.removeAll { $0 == d.uuid }
                    if !on { store.config.disabledDisplays.append(d.uuid) }
                })) {
                    VStack(alignment: .leading) {
                        Text(d.name)
                        Text("\(Int(d.frame.width)) × \(Int(d.frame.height))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct MacSetupPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var checks: [MacSetupCheck] = []

    var body: some View {
        Section(title: "Checks", footer: "Some of these only take effect after you log out and back in.") {
            ForEach(checks) { c in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: c.status == .ok ? "checkmark.circle.fill" : (c.status == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                        .foregroundStyle(c.status == .ok ? .green : (c.status == .warning ? .orange : .red))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).fontWeight(.medium)
                        Text(c.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if c.status != .ok, let url = c.settingsURL {
                        Button("Open") { NSWorkspace.shared.open(URL(string: url)!) }.controlSize(.small)
                    }
                }
                if c.id != checks.last?.id { Divider() }
            }
        }
        Button("Check Again") { reload() }
            .onAppear(perform: reload)
    }

    private func reload() {
        checks = MacSetup.run(swipeFingers: store.config.swipeFingers, smoothSwipe: store.config.smoothSwipe)
    }
}

struct AutomationPage: View {
    @State private var cliMessage = ""

    var body: some View {
        Section(title: "URL scheme", footer: "Every shortcut action has a URL. Use them from Shortcuts, Alfred, Keyboard Maestro or a browser bookmark.") {
            ForEach(["reel://focus-right", "reel://cycle-width", "reel://move-to-1", "reel://pin-left", "reel://scroll:300"], id: \.self) { u in
                HStack {
                    Text(u).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Try") { NSWorkspace.shared.open(URL(string: u)!) }.controlSize(.small)
                }
            }
        }
        Section(title: "Command line", footer: "reelctl talks to the running app over a local socket. Try reelctl status, reelctl focus-left or reelctl set gap 12.") {
            HStack {
                Button("Install reelctl in ~/.local/bin") { installCLI() }
                Text(cliMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        Section(title: "Raycast") {
            Text("Script commands for the common actions. Add the folder in Raycast › Extensions › Script Commands.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Save Raycast Scripts…") { RaycastScripts.export() }
        }
    }

    private func installCLI() {
        guard let src = Bundle.main.url(forAuxiliaryExecutable: "reelctl") ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("reelctl") else {
            cliMessage = "reelctl isn't in this build."
            return
        }
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("reelctl")
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
            cliMessage = "Linked \(dst.path)"
        } catch {
            cliMessage = error.localizedDescription
        }
    }
}

struct AboutPage: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("Reel").font(.title.bold())
                Text("Version \(AppDelegate.version)").foregroundStyle(.secondary)
                Text("A scrolling window manager for macOS.").foregroundStyle(.secondary)
            }
        }
        Section(title: "Files") {
            HStack {
                Button("Reveal Engine Log") { AppDelegate.shared?.revealLog() }
                Button("Open Configuration File") { AppDelegate.shared?.revealConfig() }
                Button("Check for Updates…") { AppDelegate.shared?.checkForUpdates() }
            }
        }
        Section(title: "Privacy") {
            Text("Reel has no analytics and no account. It reads window positions and titles to arrange them, keeps its settings on this Mac, and only goes online to look for updates on GitHub.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
