import AppKit
import ReelCore
import SwiftUI

struct ShortcutsPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var recording: String?
    @State private var filter = ""

    private var groups: [(String, [Command])] {
        var order: [String] = []
        var map: [String: [Command]] = [:]
        for c in Command.all {
            if !filter.isEmpty && !c.title.localizedCaseInsensitiveContains(filter) { continue }
            if map[c.group] == nil { order.append(c.group) }
            map[c.group, default: []].append(c)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        HStack {
            TextField("Search actions", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            Spacer()
            Button("Restore Defaults") { store.resetShortcuts() }
        }
        Text("Defaults use ⌃⌥ (Control-Option) so plain ⌥ stays free for typing. Click + to add another key for an action.")
            .font(.callout).foregroundStyle(.secondary)
        ForEach(groups, id: \.0) { group, commands in
            Section(title: group) {
                ForEach(commands, id: \.name) { cmd in
                    ShortcutRow(command: cmd, recording: $recording)
                    if cmd != commands.last { Divider() }
                }
            }
        }
    }
}

struct ShortcutRow: View {
    @EnvironmentObject var store: ConfigStore
    let command: Command
    @Binding var recording: String?

    private var combos: [KeyCombo] { store.config.bindings[command.name] ?? [] }

    var body: some View {
        HStack {
            Text(command.title)
            Spacer()
            ForEach(Array(combos.enumerated()), id: \.offset) { i, combo in
                HStack(spacing: 3) {
                    Text(KeyNames.describe(combo)).font(.system(.body, design: .rounded)).monospacedDigit()
                    Button {
                        var list = combos
                        list.remove(at: i)
                        store.config.bindings[command.name] = list
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                .help(conflict(for: combo).map { "Also used by \($0)" } ?? "")
                .overlay(conflict(for: combo) == nil ? nil : RoundedRectangle(cornerRadius: 5).stroke(Color.orange))
            }
            if recording == command.name {
                KeyRecorder { combo in
                    recording = nil
                    guard let combo else { return }
                    var list = combos
                    if !list.contains(combo) { list.append(combo) }
                    store.config.bindings[command.name] = list
                }
                .frame(width: 130, height: 22)
            } else {
                Button { recording = command.name } label: { Image(systemName: "plus") }
                    .controlSize(.small)
                    .help("Record a shortcut")
            }
        }
    }

    private func conflict(for combo: KeyCombo) -> String? {
        for (name, list) in store.config.bindings where name != command.name && list.contains(combo) {
            return Command(name: name)?.title ?? name
        }
        return nil
    }
}

/// Captures the next key press with modifiers. Escape cancels.
struct KeyRecorder: NSViewRepresentable {
    let onDone: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onDone = onDone
        return v
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {}

    final class RecorderView: NSView {
        var onDone: ((KeyCombo?) -> Void)?
        private var monitor: Any?
        private let label = NSTextField(labelWithString: "Press keys…")

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 5
            layer?.borderWidth = 1.5
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else {
                if window == nil { finish(nil) }
                return
            }
            // Hot keys would swallow the combination we're trying to record.
            HotkeyManager.shared.paused = true
            UnregisterAllForRecording.begin()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
                guard let self else { return e }
                if e.type == .flagsChanged {
                    let m = HotkeyManager.modifiers(from: e.modifierFlags)
                    self.label.stringValue = m.isEmpty ? "Press keys…" : m.symbols
                    return nil
                }
                if e.keyCode == 53 { self.finish(nil); return nil } // Escape
                let mods = HotkeyManager.modifiers(from: e.modifierFlags)
                guard !mods.isEmpty else {
                    NSSound.beep()
                    self.label.stringValue = "Add a modifier"
                    return nil
                }
                self.finish(KeyCombo(UInt32(e.keyCode), mods))
                return nil
            }
        }

        private func finish(_ combo: KeyCombo?) {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
            HotkeyManager.shared.paused = false
            UnregisterAllForRecording.end()
            let done = onDone
            onDone = nil
            DispatchQueue.main.async { done?(combo) }
        }
    }
}

/// Carbon hot keys are grabbed before the settings window sees the key, so while recording
/// they're switched off and then restored.
enum UnregisterAllForRecording {
    static func begin() {
        HotkeyManager.shared.disable(keepStartBinding: false)
    }

    static func end() {
        if WindowManager.shared.running {
            HotkeyManager.shared.enable(bindings: ConfigStore.shared.config.bindings)
        } else {
            HotkeyManager.shared.disable(keepStartBinding: true)
        }
    }
}
