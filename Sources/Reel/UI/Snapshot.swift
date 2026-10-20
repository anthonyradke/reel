import AppKit
import SwiftUI

/// Debug aid: `REEL_SNAPSHOT=/tmp/shots Reel` renders every settings page and the onboarding
/// steps to PNGs, so the UI can be checked without screen recording permission.
enum Snapshot {
    static func run(into dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            for page in SettingsPage.allCases {
                let view = SettingsView(page: page)
                    .environmentObject(ConfigStore.shared)
                    .environmentObject(EngineState.shared)
                    .frame(width: 860, height: 640)
                render(view, size: NSSize(width: 860, height: 640), appearance: appearance,
                       to: dir.appendingPathComponent("settings-\(page.id.lowercased().replacingOccurrences(of: " ", with: "-"))-\(suffix).png"))
            }
            let onboarding = OnboardingView(onFinish: {}).environmentObject(EngineState.shared)
            render(onboarding, size: NSSize(width: 620, height: 470), appearance: appearance,
                   to: dir.appendingPathComponent("onboarding-\(suffix).png"))
        }
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        // Let SwiftUI lay out and finish its first pass.
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
