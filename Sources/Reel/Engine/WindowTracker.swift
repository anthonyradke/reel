import AppKit
import ApplicationServices
import ReelCore

/// One app the tracker watches.
final class TrackedApp {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let element: AXUIElement
    var observer: AXObserver?
    let mover: WindowMover
    var failures = 0

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        name = app.localizedName ?? app.bundleIdentifier ?? "App"
        element = AXUIElementCreateApplication(pid)
        // A frozen app must never freeze the window manager.
        AXUIElementSetMessagingTimeout(element, 0.5)
        mover = WindowMover(name: name)
    }

    var runningApp: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    var icon: NSImage? { runningApp?.icon }
}

/// One window the tracker knows about.
final class TrackedWindow {
    let id: WindowID
    let element: AXUIElement
    let app: TrackedApp
    var title: String
    var subrole: String
    /// Height when the window first appeared, for Keep Original Height.
    var originalHeight: CGFloat
    /// Width the window settled at when it refused the width we asked for.
    var minWidth: CGFloat?
    /// The id the strip uses for this window's native tab group (its own id when not tabbed).
    var group: WindowID
    /// Last frame we asked for, and when, to tell our own moves from the user's.
    var lastCommanded: CGRect?
    var lastCommandedAt: CFTimeInterval = 0

    init(id: WindowID, element: AXUIElement, app: TrackedApp, title: String, subrole: String, height: CGFloat) {
        self.id = id
        self.element = element
        self.app = app
        self.title = title
        self.subrole = subrole
        self.originalHeight = height
        self.group = id
    }

    var frame: CGRect? { AX.frame(element) }
    var isMinimized: Bool { AX.bool(element, kAXMinimizedAttribute) ?? false }
    var isFullscreen: Bool { AX.bool(element, "AXFullScreen") ?? false }
}

protocol WindowTrackerDelegate: AnyObject {
    func tracker(_ t: WindowTracker, didAdd window: TrackedWindow)
    func tracker(_ t: WindowTracker, didRemove window: TrackedWindow)
    func tracker(_ t: WindowTracker, focusChangedTo window: TrackedWindow?)
    func tracker(_ t: WindowTracker, windowMoved window: TrackedWindow)
    func tracker(_ t: WindowTracker, windowResized window: TrackedWindow)
    func tracker(_ t: WindowTracker, minimizedChanged window: TrackedWindow, minimized: Bool)
    func tracker(_ t: WindowTracker, appHidden app: TrackedApp, hidden: Bool)
    func tracker(_ t: WindowTracker, titleChanged window: TrackedWindow)
    func tracker(_ t: WindowTracker, sizeRefused window: TrackedWindow, asked: CGSize, actual: CGSize)
}

/// Watches every regular app through AXObservers and keeps a table of their windows.
final class WindowTracker {
    weak var delegate: WindowTrackerDelegate?
    private(set) var apps: [pid_t: TrackedApp] = [:]
    private(set) var windows: [WindowID: TrackedWindow] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Give a launching app a moment to create its windows and AX tree.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.watch(app) }
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.unwatch(pid: app.processIdentifier)
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if self.apps[app.processIdentifier] == nil { self.watch(app) }
            self.reportFocus(pid: app.processIdentifier)
        })
        for app in NSWorkspace.shared.runningApplications { watch(app) }
    }

    func stop() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        for pid in Array(apps.keys) { unwatch(pid: pid, notify: false) }
        windows.removeAll()
    }

    // MARK: - Apps

    func watch(_ running: NSRunningApplication, attempt: Int = 0) {
        let pid = running.processIdentifier
        guard pid != selfPID, apps[pid] == nil, running.activationPolicy == .regular, !running.isTerminated else { return }
        let app = TrackedApp(running)

        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else {
            Log.engine("could not observe \(app.name)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, app.element, kAXWindowCreatedNotification as CFString, refcon)
        guard err == .success || err == .notificationAlreadyRegistered else {
            // An app that's still launching doesn't answer yet. Try again shortly.
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 + 0.1 * Double(attempt)) { [weak self] in
                    self?.watch(running, attempt: attempt + 1)
                }
            } else if attempt == 20 {
                Log.engine("gave up observing \(app.name) (\(err.rawValue))")
            }
            return
        }
        for n in [kAXFocusedWindowChangedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(observer, app.element, n as CFString, refcon)
        }
        app.observer = observer
        app.mover.onSizeRefused = { [weak self] id, asked, actual in
            guard let self, let w = self.windows[id] else { return }
            self.delegate?.tracker(self, sizeRefused: w, asked: asked, actual: actual)
        }
        apps[pid] = app
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        scanWindows(of: app)
        // Windows an app opens while it finishes launching can slip past the notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.apps[pid] === app else { return }
            self.scanWindows(of: app)
        }
    }

    private func unwatch(pid: pid_t, notify: Bool = true) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        if let obs = app.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        for w in windows.values where w.app.pid == pid {
            windows[w.id] = nil
            if notify { delegate?.tracker(self, didRemove: w) }
        }
    }

    /// Looks for windows we haven't seen yet in every app (after a Space change, wake, etc.).
    func rescan() {
        for app in NSWorkspace.shared.runningApplications where apps[app.processIdentifier] == nil {
            watch(app)
        }
        for app in apps.values { scanWindows(of: app) }
        pruneDeadWindows()
    }

    func scanWindows(of app: TrackedApp) {
        for el in AX.elements(app.element, kAXWindowsAttribute) {
            addWindow(el, app: app)
        }
    }

    /// Drops windows the window server no longer has (closed without telling us).
    func pruneDeadWindows() {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
        let alive = Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        for w in windows.values where !alive.contains(w.id) {
            windows[w.id] = nil
            delegate?.tracker(self, didRemove: w)
        }
    }

    // MARK: - Windows

    @discardableResult
    func addWindow(_ el: AXUIElement, app: TrackedApp) -> TrackedWindow? {
        guard let id = AX.windowID(el) else { return nil }
        if let existing = windows[id] { return existing }
        guard AX.string(el, kAXRoleAttribute) == kAXWindowRole else { return nil }
        let subrole = AX.string(el, kAXSubroleAttribute) ?? ""
        let title = AX.string(el, kAXTitleAttribute) ?? ""
        let size = AX.size(el) ?? .zero
        let w = TrackedWindow(id: id, element: el, app: app, title: title, subrole: subrole, height: size.height)
        windows[id] = w
        if let obs = app.observer {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for n in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
                AXObserverAddNotification(obs, el, n as CFString, refcon)
            }
        }
        delegate?.tracker(self, didAdd: w)
        return w
    }

    func window(for el: AXUIElement) -> TrackedWindow? {
        guard let id = AX.windowID(el) else {
            // Destroyed elements no longer answer; fall back to identity.
            return windows.values.first { CFEqual($0.element, el) }
        }
        return windows[id]
    }

    func focusedWindow(pid: pid_t? = nil) -> TrackedWindow? {
        let pid = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid, let app = apps[pid], let el = AX.element(app.element, kAXFocusedWindowAttribute) else { return nil }
        return window(for: el) ?? addWindow(el, app: app)
    }

    private func reportFocus(pid: pid_t) {
        delegate?.tracker(self, focusChangedTo: focusedWindow(pid: pid))
    }

    fileprivate func handle(_ notification: String, element: AXUIElement, observer: AXObserver) {
        guard let app = apps.values.first(where: { $0.observer == observer }) else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            // New windows often finish setting up their subrole and title a beat later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.apps[app.pid] != nil else { return }
                self.addWindow(element, app: app)
            }
        case kAXFocusedWindowChangedNotification:
            if let w = window(for: element) ?? addWindow(element, app: app) {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid {
                    delegate?.tracker(self, focusChangedTo: w)
                }
            }
        case kAXApplicationHiddenNotification:
            delegate?.tracker(self, appHidden: app, hidden: true)
        case kAXApplicationShownNotification:
            delegate?.tracker(self, appHidden: app, hidden: false)
        case kAXUIElementDestroyedNotification:
            if let w = windows.values.first(where: { CFEqual($0.element, element) }) {
                windows[w.id] = nil
                delegate?.tracker(self, didRemove: w)
            }
        case kAXMovedNotification:
            if let w = window(for: element) { delegate?.tracker(self, windowMoved: w) }
        case kAXResizedNotification:
            if let w = window(for: element) { delegate?.tracker(self, windowResized: w) }
        case kAXWindowMiniaturizedNotification:
            if let w = window(for: element) { delegate?.tracker(self, minimizedChanged: w, minimized: true) }
        case kAXWindowDeminiaturizedNotification:
            if let w = window(for: element) { delegate?.tracker(self, minimizedChanged: w, minimized: false) }
        case kAXTitleChangedNotification:
            if let w = window(for: element) {
                w.title = AX.string(element, kAXTitleAttribute) ?? w.title
                delegate?.tracker(self, titleChanged: w)
            }
        default:
            break
        }
    }

    /// Windows the window server currently draws, front to back.
    static func onScreenWindowIDs() -> [WindowID] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handle(notification as String, element: element, observer: observer)
}

/// Sets window frames on a per-app background queue. A slow app only slows its own windows,
/// and if it can't keep up, intermediate animation frames are dropped rather than queued.
final class WindowMover {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private struct Move {
        var window: AXUIElement
        var app: AXUIElement
        var origin: CGPoint
        var size: CGSize?
        /// Where to stand while resizing. macOS won't let a resize push a window past the edge
        /// of its display, so a window growing near the edge has to be resized somewhere it fits.
        var resizeAt: CGPoint?
    }
    private var pending: [WindowID: Move] = [:]
    private var scheduled = false
    /// Called on the main thread when a window ends up wider than we asked: the app has a
    /// minimum width. Gets the window, the size asked for and the size it actually took.
    var onSizeRefused: ((WindowID, CGSize, CGSize) -> Void)?

    init(name: String) {
        queue = DispatchQueue(label: "reel.mover.\(name)", qos: .userInteractive)
    }

    func set(_ window: AXUIElement, app: AXUIElement, id: WindowID, origin: CGPoint, size: CGSize?, resizeAt: CGPoint? = nil) {
        lock.lock()
        let prev = pending[id]
        pending[id] = Move(window: window, app: app, origin: origin, size: size ?? prev?.size,
                           resizeAt: size != nil ? resizeAt : prev?.resizeAt)
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { queue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            let work = pending
            pending.removeAll()
            if work.isEmpty { scheduled = false; lock.unlock(); return }
            lock.unlock()
            guard let app = work.first?.value.app else { continue }
            AX.withoutEnhancedUI(app) {
                for (id, item) in work {
                    let el = item.window, origin = item.origin
                    if let size = item.size {
                        // Position, size, position: some apps clamp the size against the old
                        // position, and some move themselves when resized.
                        AX.setPosition(el, item.resizeAt ?? origin)
                        AX.setSize(el, size)
                        if let actual = AX.size(el), actual.width > size.width + 4 {
                            // Some apps (Chromium, Electron) take the new size a moment later.
                            // Look again before deciding the window has a minimum width.
                            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                                guard let actual = AX.size(el), actual.width > size.width + 4 else { return }
                                let report = self?.onSizeRefused
                                DispatchQueue.main.async { report?(id, size, actual) }
                            }
                        }
                    }
                    AX.setPosition(el, origin)
                }
            }
        }
    }
}
