import AppKit
import ReelCore
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var permissionTimer: Timer?

    var wm: WindowManager { WindowManager.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        setUpStatusItem()
        ConfigStore.shared.onChange = { [weak self] new, old in
            self?.wm.configChanged(new, old: old)
            if new.launchAtLogin != old.launchAtLogin { LoginItem.set(new.launchAtLogin) }
        }
        wm.onStateChange = { [weak self] in self?.refreshStatusIcon() }
        IPCServer.shared.start()
        Log.engine("Reel \(Self.version) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let config = ConfigStore.shared.config
        if !config.hasCompletedOnboarding {
            showOnboarding()
        } else if config.startOnLaunch {
            startWhenTrusted()
        }
        UpdateChecker.shared.checkInBackground()
    }

    func applicationWillTerminate(_ notification: Notification) {
        wm.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(nil)
        return true
    }

    /// Starts now if Accessibility is granted, otherwise asks and waits for it.
    func startWhenTrusted() {
        if AX.isTrusted {
            wm.start()
            return
        }
        AX.promptForTrust()
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard AX.isTrusted else { return }
            t.invalidate()
            self?.wm.start()
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: - URL scheme: reel://focus-left, reel://move-to-3, reel://scroll:200

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        let name = ((url.host ?? "") + url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let cmd = Command(name: name.replacingOccurrences(of: "/", with: "-")) else {
            Log.engine("url: unknown command \(name)")
            return
        }
        wm.perform(cmd)
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusIcon()
    }

    func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.image = StatusIcon.image(running: wm.running)
        button.toolTip = wm.running ? "Reel is running" : "Reel is stopped"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = NSMenuItem(title: wm.running ? "Running" : (AX.isTrusted ? "Stopped" : "Needs Accessibility permission"), action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if wm.running {
            menu.addItem(item("Stop", #selector(stopEngine)))
            menu.addItem(item("Restart", #selector(restartEngine)))
        } else {
            menu.addItem(item("Start", #selector(startEngine)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Reel…", #selector(openSettings(_:)), key: ","))
        menu.addItem(item("Show Strip", #selector(showIndicator)))
        menu.addItem(item("Re-tile Everything", #selector(retile)))
        menu.addItem(.separator())
        menu.addItem(item("Open Configuration File", #selector(revealConfig)))
        menu.addItem(item("Reveal Engine Log", #selector(revealLog)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Reel", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc func startEngine() { startWhenTrusted() }
    @objc func stopEngine() { wm.stop() }
    @objc func restartEngine() { wm.restart() }
    @objc func showIndicator() { wm.perform(.showIndicator) }
    @objc func retile() { wm.perform(.retile) }
    @objc func revealConfig() { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url]) }
    @objc func revealLog() {
        Log.engine("log revealed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSWorkspace.shared.activateFileViewerSelecting([Log.url])
        }
    }
    @objc func checkForUpdates() { UpdateChecker.shared.checkInteractively() }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - Windows

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(ConfigStore.shared).environmentObject(EngineState.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Reel"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 820, height: 600))
            w.minSize = NSSize(width: 720, height: 480)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("ReelSettings")
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
            settingsWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let host = NSHostingController(rootView: OnboardingView(onFinish: { [weak self] in
                ConfigStore.shared.config.hasCompletedOnboarding = true
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                NSApp.setActivationPolicy(.accessory)
                self?.startWhenTrusted()
            }).environmentObject(EngineState.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Welcome to Reel"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.center()
            onboardingWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

enum LoginItem {
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.engine("launch at login: \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
}

/// The menu bar icon: three columns on a strip, the middle one in focus.
enum StatusIcon {
    static func image(running: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { r in
            let alpha: CGFloat = running ? 1 : 0.45
            NSColor.black.withAlphaComponent(alpha).setFill()
            NSColor.black.withAlphaComponent(alpha).setStroke()
            let left = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 3.25, width: 4, height: 9.5), xRadius: 1.2, yRadius: 1.2)
            left.lineWidth = 1.2
            left.stroke()
            NSBezierPath(roundedRect: NSRect(x: 6.5, y: 2, width: 7, height: 12), xRadius: 1.6, yRadius: 1.6).fill()
            let right = NSBezierPath(roundedRect: NSRect(x: 15.25, y: 3.25, width: 4, height: 9.5), xRadius: 1.2, yRadius: 1.2)
            right.lineWidth = 1.2
            right.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}
