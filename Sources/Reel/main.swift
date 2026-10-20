import AppKit

// One copy at a time: a second launch just opens the first one's settings.
let bundleID = Bundle.main.bundleIdentifier ?? "app.reel"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if let other = others.first, Bundle.main.bundleIdentifier != nil {
    other.activate(options: [])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
