import AppKit
import ReelCore
import SwiftUI
import UniformTypeIdentifiers

struct RulesPage: View {
    @EnvironmentObject var store: ConfigStore
    @State private var picking = false

    var body: some View {
        Section(title: "Rules", footer: "Float keeps an app off the strip. Always tile tiles it even if it looks like a dialog. Fixed slot always opens it at the same place on the strip (0 means last).") {
            if store.config.rules.isEmpty {
                Text("No rules yet. Dialogs, Quick Look, fixed-size windows and Reel's own windows already float on their own.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach($store.config.rules) { $rule in
                RuleRow(rule: $rule) {
                    store.config.rules.removeAll { $0.id == rule.id }
                }
                Divider()
            }
            HStack {
                Button("Add Rule for a Running App…") { picking = true }
                    .popover(isPresented: $picking) {
                        AppPicker { app in
                            picking = false
                            guard let app else { return }
                            store.config.rules.append(WindowRule(bundleID: app.bundleID, appName: app.name, action: .float))
                        }
                    }
                Button("Choose from Applications…") { chooseFromDisk() }
            }
        }
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let b = Bundle(url: url), let bid = b.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        store.config.rules.append(WindowRule(bundleID: bid, appName: name, action: .float))
    }
}

struct RuleRow: View {
    @Binding var rule: WindowRule
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let icon = AppPicker.icon(for: rule.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                Text(rule.appName).fontWeight(.medium)
                Text(rule.bundleID).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            HStack(spacing: 14) {
                Picker("", selection: $rule.action) {
                    ForEach(WindowRule.Action.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                if rule.action == .slot {
                    Stepper("Place \(rule.slot == 0 ? "last" : "\(rule.slot)")", value: $rule.slot, in: 0...20)
                }
                if rule.action != .float {
                    Toggle("Width", isOn: Binding(get: { rule.width != nil }, set: { rule.width = $0 ? 0.5 : nil }))
                    if let w = rule.width {
                        Stepper("\(Int(w * 100))%", value: Binding(get: { w }, set: { rule.width = $0 }), in: 0.1...1, step: 0.05)
                    }
                }
                TextField("Title contains (optional)", text: $rule.titleContains)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
        }
    }
}

struct AppPicker: View {
    struct App: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
    }

    let onPick: (App?) -> Void
    @State private var query = ""

    private var apps: [App] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a -> App? in
                guard let bid = a.bundleIdentifier, seen.insert(bid).inserted else { return nil }
                return App(bundleID: bid, name: a.localizedName ?? bid)
            }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading) {
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            List(apps) { app in
                Button {
                    onPick(app)
                } label: {
                    HStack {
                        if let icon = Self.icon(for: app.bundleID) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                        Text(app.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 280)
        }
        .padding(10)
        .frame(width: 300)
    }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum RaycastScripts {
    static let actions: [(Command, String)] = [
        (.focus(.left), "Focus Left"), (.focus(.right), "Focus Right"),
        (.move(.left), "Move Window Left"), (.move(.right), "Move Window Right"),
        (.cycleWidth, "Cycle Width"), (.fullWidth, "Full Width"), (.center, "Centre Column"),
        (.toggleTabbed, "Tabbed Column"), (.toggleFloat, "Float Window"),
        (.pinLeft, "Pin Left"), (.pinRight, "Pin Right"), (.sendToNextDisplay, "Send to Next Display"),
        (.retile, "Re-tile Everything"), (.toggleRunning, "Start or Stop Reel"),
    ]

    static func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let folder = dir.appendingPathComponent("Reel", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (cmd, title) in actions {
            let script = """
            #!/bin/bash

            # @raycast.schemaVersion 1
            # @raycast.title \(title)
            # @raycast.mode silent
            # @raycast.packageName Reel
            # @raycast.icon 🎞️

            open -g "reel://\(cmd.name)"

            """
            let url = folder.appendingPathComponent("reel-\(cmd.name).sh")
            try? script.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
